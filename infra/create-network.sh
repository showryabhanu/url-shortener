#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${ROOT_DIR}/.env" ]; then
  set -a
  source "${ROOT_DIR}/.env"
  set +a
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
SG_NAME="${SG_NAME:-url-shortener-sg}"
KEY_NAME="${KEY_NAME:-url-shortener-key}"
KEY_PATH="${HOME}/.ssh/${KEY_NAME}.pem"

echo "=============================================="
echo "Configuring Network & Security"
echo "Region: ${AWS_REGION}"
echo "=============================================="

# 1. Discover Default VPC
echo "Discovering default VPC..."
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --region "${AWS_REGION}" \
  --query 'Vpcs[0].VpcId' \
  --output text)

if [ "${VPC_ID}" == "None" ] || [ -z "${VPC_ID}" ]; then
  echo "Default VPC not found. Querying first available VPC..."
  VPC_ID=$(aws ec2 describe-vpcs \
    --region "${AWS_REGION}" \
    --query 'Vpcs[0].VpcId' \
    --output text)
fi
echo "Using VPC: ${VPC_ID}"

# 2. Discover Public Subnet
SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --region "${AWS_REGION}" \
  --query 'Subnets[0].SubnetId' \
  --output text)
echo "Using Subnet: ${SUBNET_ID}"

# 3. Detect current public IP
echo "Detecting current public IP..."
MY_IP=$(curl -s --max-time 5 https://checkip.amazonaws.com || curl -s --max-time 5 https://ifconfig.me)
MY_IP=$(echo "${MY_IP}" | tr -d '[:space:]')
if [ -z "${MY_IP}" ]; then
  echo "Warning: Could not detect public IP. Falling back to 0.0.0.0/0 for SSH."
  SSH_CIDR="0.0.0.0/0"
else
  SSH_CIDR="${MY_IP}/32"
fi
echo "Your IP: ${MY_IP} (SSH access will be restricted to ${SSH_CIDR})"

# 4. Security Group
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --region "${AWS_REGION}" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

if [ "${SG_ID}" == "None" ] || [ -z "${SG_ID}" ]; then
  echo "Creating Security Group '${SG_NAME}'..."
  SG_ID=$(aws ec2 create-security-group \
    --group-name "${SG_NAME}" \
    --description "Security group for Bitly-style URL shortener" \
    --vpc-id "${VPC_ID}" \
    --region "${AWS_REGION}" \
    --output text \
    --query 'GroupId')
  echo "Created Security Group: ${SG_ID}"
else
  echo "Security Group '${SG_NAME}' already exists: ${SG_ID}"
fi

# Inbound rules (idempotent, suppress 'already exists' errors)
echo "Authorizing HTTP (80) from 0.0.0.0/0..."
aws ec2 authorize-security-group-ingress \
  --group-id "${SG_ID}" \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0 \
  --region "${AWS_REGION}" >/dev/null 2>&1 || true

echo "Authorizing HTTPS (443) from 0.0.0.0/0..."
aws ec2 authorize-security-group-ingress \
  --group-id "${SG_ID}" \
  --protocol tcp \
  --port 443 \
  --cidr 0.0.0.0/0 \
  --region "${AWS_REGION}" >/dev/null 2>&1 || true

echo "Authorizing SSH (22) from ${SSH_CIDR}..."
aws ec2 authorize-security-group-ingress \
  --group-id "${SG_ID}" \
  --protocol tcp \
  --port 22 \
  --cidr "${SSH_CIDR}" \
  --region "${AWS_REGION}" >/dev/null 2>&1 || true

# 5. EC2 Key Pair
mkdir -p "${HOME}/.ssh"
KEY_EXISTS_AWS=$(aws ec2 describe-key-pairs \
  --key-names "${KEY_NAME}" \
  --region "${AWS_REGION}" \
  --query 'KeyPairs[0].KeyName' \
  --output text 2>/dev/null || echo "None")

if [ "${KEY_EXISTS_AWS}" != "None" ] && [ -f "${KEY_PATH}" ]; then
  echo "Key pair '${KEY_NAME}' already exists both in AWS and at ${KEY_PATH}."
elif [ "${KEY_EXISTS_AWS}" != "None" ] && [ ! -f "${KEY_PATH}" ]; then
  echo "Key pair exists in AWS but private key is missing locally. Re-creating key pair..."
  aws ec2 delete-key-pair --key-name "${KEY_NAME}" --region "${AWS_REGION}"
  aws ec2 create-key-pair \
    --key-name "${KEY_NAME}" \
    --query 'KeyMaterial' \
    --output text \
    --region "${AWS_REGION}" > "${KEY_PATH}"
  chmod 400 "${KEY_PATH}"
  echo "Saved new key to: ${KEY_PATH}"
else
  echo "Creating new key pair '${KEY_NAME}'..."
  aws ec2 create-key-pair \
    --key-name "${KEY_NAME}" \
    --query 'KeyMaterial' \
    --output text \
    --region "${AWS_REGION}" > "${KEY_PATH}"
  chmod 400 "${KEY_PATH}"
  echo "Saved key to: ${KEY_PATH}"
fi

# Save state
cat <<EOF > "${ROOT_DIR}/.infra_state"
VPC_ID=${VPC_ID}
SUBNET_ID=${SUBNET_ID}
SG_ID=${SG_ID}
KEY_NAME=${KEY_NAME}
KEY_PATH=${KEY_PATH}
EOF

echo "Network & Security configuration completed."
