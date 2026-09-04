#!/bin/bash
exec > /var/log/noxos-watcher.log 2>&1
export AWS_DEFAULT_REGION="us-east-1"
while true; do
  TOK=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
  CODE=$(curl -s -H "X-aws-ec2-metadata-token: $TOK" -o /dev/null -w "%{http_code}" "http://169.254.169.254/latest/meta-data/spot/instance-action")
  if [ "$CODE" = "200" ]; then
    echo "interruption notice received, snapshotting"
    aws ec2 create-snapshot --volume-id vol-04f36bb86126e3ab8 \
      --description "noxos-aosp-src interrupt snapshot" \
      --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=noxos-aosp-src}]"
    break
  fi
  sleep 10
done
