#!/bin/bash
set -euo pipefail
export HOME=/root
exec > /var/log/noxos-bootstrap.log 2>&1

cat > /etc/apt/apt.conf.d/99noxos-fast-fail <<'APTCONF'
Acquire::http::Timeout "10";
Acquire::https::Timeout "10";
Acquire::Retries "5";
APTCONF

apt-get update -y
apt-get install -y awscli git

imds_token() { curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300"; }
imds() { curl -s -H "X-aws-ec2-metadata-token: $(imds_token)" "http://169.254.169.254/latest/meta-data/$1"; }

REGION=$(imds placement/region)
AZ=$(imds placement/availability-zone)
INSTANCE_ID=$(imds instance-id)
export AWS_DEFAULT_REGION="$REGION"

LOG_BUCKET="noxos-releases"
LOG_PREFIX="logs/${INSTANCE_ID}"
push_logs() {
  aws s3 cp /var/log/ "s3://${LOG_BUCKET}/${LOG_PREFIX}/$(date -u +%Y%m%dT%H%M%SZ)/" \
    --recursive --exclude '*' --include 'noxos-*.log' 2>/dev/null || true
}
trap push_logs EXIT

VOL_TAG_NAME="noxos-aosp-src"

SNAP_ID=$(aws ec2 describe-snapshots --owner-ids self \
  --filters "Name=tag:Name,Values=$VOL_TAG_NAME" "Name=status,Values=completed" \
  --query 'sort_by(Snapshots,&StartTime)[-1].SnapshotId' --output text)
USE_VOL=$(aws ec2 create-volume --availability-zone "$AZ" --snapshot-id "$SNAP_ID" \
  --volume-type gp3 --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=$VOL_TAG_NAME}]" \
  --query 'VolumeId' --output text)
aws ec2 wait volume-available --volume-ids "$USE_VOL"

aws ec2 attach-volume --volume-id "$USE_VOL" --instance-id "$INSTANCE_ID" --device /dev/sdf
aws ec2 wait volume-in-use --volume-ids "$USE_VOL"
aws ec2 modify-instance-attribute --instance-id "$INSTANCE_ID" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sdf\",\"Ebs\":{\"DeleteOnTermination\":true}}]"
sleep 5

ROOT_DEV=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null || echo nvme0n1)
DEV="/dev/$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}' | grep -v "^${ROOT_DEV}$" | head -1)"

mkdir -p /mnt/aosp
mount "$DEV" /mnt/aosp || { mkfs.ext4 -F "$DEV"; mount "$DEV" /mnt/aosp; }

git config --global --add safe.directory '*'
if [ -d /opt/noxos-os/.git ]; then
  git -C /opt/noxos-os pull --ff-only
else
  git clone --depth 1 https://github.com/parrothacker1/noxos-os.git /opt/noxos-os
fi
bash /opt/noxos-os/infra/setup-instance.sh

cat > /root/watch-interrupt.sh <<EOF
#!/bin/bash
exec > /var/log/noxos-watcher.log 2>&1
export AWS_DEFAULT_REGION="$REGION"
while true; do
  TOK=\$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
  CODE=\$(curl -s -H "X-aws-ec2-metadata-token: \$TOK" -o /dev/null -w "%{http_code}" "http://169.254.169.254/latest/meta-data/spot/instance-action")
  if [ "\$CODE" = "200" ]; then
    aws s3 cp /var/log/ "s3://$LOG_BUCKET/$LOG_PREFIX/\$(date -u +%Y%m%dT%H%M%SZ)-interrupt/" \
      --recursive --exclude '*' --include 'noxos-*.log' 2>/dev/null || true
    aws ec2 create-snapshot --volume-id "$USE_VOL" --description "noxos-aosp-src interrupt snapshot" \
      --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$VOL_TAG_NAME}]"
    break
  fi
  sleep 10
done
EOF
chmod +x /root/watch-interrupt.sh

cat > /root/resume-build.sh <<EOF
#!/bin/bash
exec > /var/log/noxos-build.log 2>&1
export AWS_DEFAULT_REGION="$REGION"
export HOME=/root

chown -R ubuntu:ubuntu /mnt/aosp
rm -f /etc/.repo_gitconfig.json

set +e
sudo -u ubuntu -H bash -c "cd /mnt/aosp && bash /opt/noxos-os/infra/sync.sh && bash /opt/noxos-os/infra/build.sh"
BUILD_EXIT=\$?
set -e

echo "=== build.sh exited with code \$BUILD_EXIT ==="
echo "--- out/dist listing ---"
ls -la out/dist 2>&1 || echo "(out/dist does not exist)"
echo "--- out/ top-level listing (mtime order) ---"
ls -lat out 2>&1 | head -40

aws s3 cp /var/log/ "s3://$LOG_BUCKET/$LOG_PREFIX/\$(date -u +%Y%m%dT%H%M%SZ)-build/" \
  --recursive --exclude "*" --include "noxos-*.log"

if [ "\$BUILD_EXIT" -ne 0 ]; then
  echo "build.sh failed - leaving instance up for inspection instead of terminating"
  exit 0
fi

FLEET_ID=\$(aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=aws:ec2:fleet-id" \
  --query 'Tags[0].Value' --output text)
if [ -n "\$FLEET_ID" ] && [ "\$FLEET_ID" != "None" ]; then
  aws ec2 modify-fleet --fleet-id "\$FLEET_ID" --target-capacity 0 --no-terminate-instances
fi

aws ec2 create-snapshot --volume-id "$USE_VOL" --description "noxos-aosp-src build-complete snapshot" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$VOL_TAG_NAME}]"

aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
EOF
chmod +x /root/resume-build.sh

systemd-run --unit=noxos-watcher --collect --setenv=HOME=/root bash /root/watch-interrupt.sh
systemd-run --unit=noxos-build --collect --setenv=HOME=/root bash /root/resume-build.sh
