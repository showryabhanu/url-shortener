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
TAG_NAME="${TAG_NAME:-url-shortener-server}"
KEY_NAME="${KEY_NAME:-url-shortener-key}"
SHORT_DOMAIN="${SHORT_DOMAIN:-cc7.duckdns.org}"

echo "=============================================="
echo "Launching EC2 Instance & Elastic IP"
echo "Region: ${AWS_REGION}"
echo "=============================================="

# 1. Query latest Amazon Linux 2023 AMI via SSM parameter (fallback to describe-images)
echo "Resolving latest Amazon Linux 2023 AMI..."
AMI_ID=""
if AMI_ID=$(aws ssm get-parameter \
    --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
    --region "${AWS_REGION}" \
    --query 'Parameter.Value' \
    --output text 2>/dev/null); then
  echo "Found AMI via SSM: ${AMI_ID}"
else
  echo "SSM parameter lookup denied or unavailable. Falling back to describe-images..."
  AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*x86_64" "Name=state,Values=available" \
    --query 'reverse(sort_by(Images, &CreationDate))[0].ImageId' \
    --region "${AWS_REGION}" \
    --output text)
  echo "Found AMI via describe-images: ${AMI_ID}"
fi

# 2. Check if instance already exists
EXISTING_INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${TAG_NAME}" "Name=instance-state-name,Values=running,pending,stopped" \
  --region "${AWS_REGION}" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text 2>/dev/null || echo "None")

if [ "${EXISTING_INSTANCE_ID}" != "None" ] && [ -n "${EXISTING_INSTANCE_ID}" ]; then
  echo "EC2 Instance already exists: ${EXISTING_INSTANCE_ID}"
  INSTANCE_ID="${EXISTING_INSTANCE_ID}"

  # Start if stopped
  STATE=$(aws ec2 describe-instances \
    --instance-ids "${INSTANCE_ID}" \
    --region "${AWS_REGION}" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text)
  if [ "${STATE}" == "stopped" ]; then
    echo "Instance is stopped. Starting it..."
    aws ec2 start-instances --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}"
  fi
else
  echo "Launching new t3.micro EC2 instance with LabInstanceProfile..."
  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "${AMI_ID}" \
    --instance-type t3.micro \
    --key-name "${KEY_NAME}" \
    --security-group-ids "${SG_ID}" \
    --subnet-id "${SUBNET_ID}" \
    --iam-instance-profile Name=LabInstanceProfile \
    --associate-public-ip-address \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${TAG_NAME}},{Key=Project,Value=url-shortener}]" \
    --region "${AWS_REGION}" \
    --query 'Instances[0].InstanceId' \
    --output text)
  echo "Launched instance: ${INSTANCE_ID}"
fi

echo "Waiting for instance ${INSTANCE_ID} to be in running state..."
aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}"

# 3. Elastic IP Allocation & Association
echo "Configuring Elastic IP..."
EIP_ALLOC=$(aws ec2 describe-addresses \
  --filters "Name=tag:Project,Values=url-shortener" \
  --region "${AWS_REGION}" \
  --query 'Addresses[0].AllocationId' \
  --output text 2>/dev/null || echo "None")

if [ "${EIP_ALLOC}" == "None" ] || [ -z "${EIP_ALLOC}" ]; then
  echo "Allocating new Elastic IP..."
  ALLOC_JSON=$(aws ec2 allocate-address \
    --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=url-shortener-eip},{Key=Project,Value=url-shortener}]" \
    --region "${AWS_REGION}" \
    --output json)
  EIP_ALLOC=$(echo "${ALLOC_JSON}" | grep -o '"AllocationId": "[^"]*' | cut -d'"' -f4)
  ELASTIC_IP=$(echo "${ALLOC_JSON}" | grep -o '"PublicIp": "[^"]*' | cut -d'"' -f4)
else
  ELASTIC_IP=$(aws ec2 describe-addresses \
    --allocation-ids "${EIP_ALLOC}" \
    --region "${AWS_REGION}" \
    --query 'Addresses[0].PublicIp' \
    --output text)
fi

echo "Associating Elastic IP (${ELASTIC_IP}) with instance (${INSTANCE_ID})..."
aws ec2 associate-address \
  --instance-id "${INSTANCE_ID}" \
  --allocation-id "${EIP_ALLOC}" \
  --allow-reassociation \
  --region "${AWS_REGION}" >/dev/null

# Append to state file
cat <<EOF >> "${ROOT_DIR}/.infra_state"
AMI_ID=${AMI_ID}
INSTANCE_ID=${INSTANCE_ID}
EIP_ALLOC=${EIP_ALLOC}
ELASTIC_IP=${ELASTIC_IP}
EOF

echo ""
echo "=========================================================================="
echo " AWS INFRASTRUCTURE READY"
echo "=========================================================================="
echo " EC2 Instance ID : ${INSTANCE_ID}"
echo " Elastic IP      : ${ELASTIC_IP}"
echo " Domain          : ${SHORT_DOMAIN}"
echo "--------------------------------------------------------------------------"
echo " ACTION REQUIRED: Update your DNS A record now!"
echo "   Record Type : A"
echo "   Host / Name : ${SHORT_DOMAIN}"
echo "   Target / IP : ${ELASTIC_IP}"
echo "=========================================================================="
