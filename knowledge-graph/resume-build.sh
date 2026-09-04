#!/bin/bash
set -euo pipefail
exec > /var/log/noxos-build.log 2>&1

imds_token() { curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300"; }
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $(imds_token)" http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $(imds_token)" http://169.254.169.254/latest/meta-data/placement/region)
export AWS_DEFAULT_REGION="$REGION"
USE_VOL="vol-04f36bb86126e3ab8"
VOL_TAG_NAME="noxos-aosp-src"

cd /mnt/aosp
bash /root/noxos-os/infra/sync.sh
bash /root/noxos-os/infra/build.sh

FLEET_ID=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=aws:ec2:fleet-id" \
  --query 'Tags[0].Value' --output text)
if [ -n "$FLEET_ID" ] && [ "$FLEET_ID" != "None" ]; then
  aws ec2 modify-fleet --fleet-id "$FLEET_ID" --target-capacity 0 --no-terminate-instances
fi

aws ec2 create-snapshot --volume-id "$USE_VOL" \
  --description "noxos-aosp-src build-complete snapshot" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$VOL_TAG_NAME}]"

aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
