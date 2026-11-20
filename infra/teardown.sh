#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${ROOT_DIR}/.env" ]; then
  set -a
  source "${ROOT_DIR}/.env"
  set +a
fi

if [ -f "${ROOT_DIR}/.infra_state" ]; then
  set -a
  source "${ROOT_DIR}/.infra_state"
  set +a
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
TABLE_NAME="${TABLE_NAME:-short_links}"
SG_NAME="${SG_NAME:-url-shortener-sg}"
KEY_NAME="${KEY_NAME:-url-shortener-key}"
TAG_NAME="${TAG_NAME:-url-shortener-server}"

echo "=============================================="
echo "Tearing Down URL Shortener Infrastructure"
echo "Region: ${AWS_REGION}"
echo "=============================================="

# 1. Terminate EC2 Instance
INSTANCE_ID="${INSTANCE_ID:-$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${TAG_NAME}" "Name=instance-state-name,Values=running,stopped,pending" --region "${AWS_REGION}" --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || echo "None")}"

if [ "${INSTANCE_ID}" != "None" ] && [ -n "${INSTANCE_ID}" ]; then
  echo "Terminating EC2 Instance: ${INSTANCE_ID}..."
  aws ec2 terminate-instances --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}" >/dev/null
  echo "Waiting for instance to terminate..."
  aws ec2 wait instance-terminated --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}"
  echo "Instance terminated."
else
  echo "No active EC2 instance found."
fi

# 2. Release Elastic IP
EIP_ALLOC="${EIP_ALLOC:-$(aws ec2 describe-addresses --filters "Name=tag:Project,Values=url-shortener" --region "${AWS_REGION}" --query 'Addresses[0].AllocationId' --output text 2>/dev/null || echo "None")}"

if [ "${EIP_ALLOC}" != "None" ] && [ -n "${EIP_ALLOC}" ]; then
  echo "Releasing Elastic IP allocation: ${EIP_ALLOC}..."
  aws ec2 release-address --allocation-id "${EIP_ALLOC}" --region "${AWS_REGION}" >/dev/null || true
  echo "Elastic IP released."
else
  echo "No Elastic IP allocation found."
fi

# 3. Delete Security Group
SG_ID="${SG_ID:-$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${SG_NAME}" --region "${AWS_REGION}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")}"

if [ "${SG_ID}" != "None" ] && [ -n "${SG_ID}" ]; then
  echo "Deleting Security Group: ${SG_ID}..."
  # Wait slightly for network interfaces to detach
  sleep 5
  aws ec2 delete-security-group --group-id "${SG_ID}" --region "${AWS_REGION}" >/dev/null || true
  echo "Security Group deleted."
else
  echo "No Security Group found."
fi

# 4. Delete Key Pair
if aws ec2 describe-key-pairs --key-names "${KEY_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo "Deleting Key Pair: ${KEY_NAME}..."
  aws ec2 delete-key-pair --key-name "${KEY_NAME}" --region "${AWS_REGION}" >/dev/null
  rm -f "${HOME}/.ssh/${KEY_NAME}.pem"
  echo "Key Pair deleted."
fi

# 5. Delete DynamoDB Table
if aws dynamodb describe-table --table-name "${TABLE_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo "Deleting DynamoDB Table: ${TABLE_NAME}..."
  aws dynamodb delete-table --table-name "${TABLE_NAME}" --region "${AWS_REGION}" >/dev/null
  echo "DynamoDB table deleted."
fi

rm -f "${ROOT_DIR}/.infra_state"
echo "Teardown complete!"
