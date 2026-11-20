#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load configuration
if [ -f "${ROOT_DIR}/.env" ]; then
  # export variables from .env
  set -a
  source "${ROOT_DIR}/.env"
  set +a
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
TABLE_NAME="${TABLE_NAME:-short_links}"

echo "=============================================="
echo "Creating DynamoDB Table: ${TABLE_NAME}"
echo "Region: ${AWS_REGION}"
echo "=============================================="

# Check if table already exists
if aws dynamodb describe-table --table-name "${TABLE_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo "Table '${TABLE_NAME}' already exists. Skipping creation."
else
  echo "Table '${TABLE_NAME}' does not exist. Creating with on-demand (PAY_PER_REQUEST) billing..."
  aws dynamodb create-table \
    --table-name "${TABLE_NAME}" \
    --attribute-definitions AttributeName=code,AttributeType=S \
    --key-schema AttributeName=code,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${AWS_REGION}" \
    --tags Key=Project,Value=url-shortener
fi

echo "Waiting for table '${TABLE_NAME}' to reach ACTIVE status..."
aws dynamodb wait table-exists --table-name "${TABLE_NAME}" --region "${AWS_REGION}"

TABLE_STATUS=$(aws dynamodb describe-table \
  --table-name "${TABLE_NAME}" \
  --region "${AWS_REGION}" \
  --query 'Table.TableStatus' \
  --output text)

echo "Success! DynamoDB Table '${TABLE_NAME}' is ${TABLE_STATUS}."
