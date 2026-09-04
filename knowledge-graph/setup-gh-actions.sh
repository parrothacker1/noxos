#!/bin/bash
set -euo pipefail

ACCOUNT_ID="139229021586"
REPO="parrothacker1/noxos-os"

aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 1c58a3a8518e8759bf075b76b750d4f2df264fcd \
  || echo "provider may already exist, continuing"

cat > /tmp/gh-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
        "StringLike": { "token.actions.githubusercontent.com:sub": "repo:${REPO}:*" }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name noxos-gh-actions-role \
  --assume-role-policy-document file:///tmp/gh-trust-policy.json

cat > /tmp/gh-actions-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateFleet",
        "ec2:RunInstances",
        "ec2:CreateTags",
        "ec2:DescribeFleets",
        "ec2:DescribeFleetInstances",
        "ec2:DescribeInstances",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:DescribeVolumes"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/noxos-rom-compile-role",
      "Condition": { "StringEquals": { "iam:PassedToService": "ec2.amazonaws.com" } }
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::noxos-releases"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": "arn:aws:s3:::noxos-releases/*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name noxos-gh-actions-role \
  --policy-name noxos-gh-actions-policy \
  --policy-document file:///tmp/gh-actions-policy.json

ROLE_ARN=$(aws iam get-role --role-name noxos-gh-actions-role --query 'Role.Arn' --output text)
echo "role arn: ${ROLE_ARN}"

if command -v gh >/dev/null 2>&1; then
  gh secret set AWS_GH_ACTIONS_ROLE_ARN --repo "${REPO}" --body "${ROLE_ARN}"
  echo "gh secret AWS_GH_ACTIONS_ROLE_ARN set on ${REPO}"
else
  echo "gh CLI not found - add ${ROLE_ARN} as repo secret AWS_GH_ACTIONS_ROLE_ARN manually"
fi

rm -f /tmp/gh-trust-policy.json /tmp/gh-actions-policy.json
