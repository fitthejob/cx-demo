#!/bin/bash
#run from: connect-pbx/modules/bootstrap/

set -euo pipefail

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Bootstrapping account: ${ACCOUNT_ID}"

echo "[1/5] Initializing with local backend..."
terraform init

echo "[2/5] Applying with local state..."
terraform apply -auto-approve

echo "[3/5] Capturing outputs..."
BUCKET_NAME=$(terraform output -raw state_bucket_name)
KMS_KEY_ARN=$(terraform output -raw bootstrap_kms_key_arn)
LOCK_TABLE=$(terraform output -raw lock_table_name)

echo " State bucket: ${BUCKET_NAME}"
echo " Bootstrap key: ${KMS_KEY_ARN}"
echo " Lock table: ${LOCK_TABLE}"

echo "[4/5] Migrating state to remote backend..."

sed -i.bak \
    -e 's|backend "local"|backend "s3"|'\
    backend.tf

terraform init \
    -migrate-state \
    -force-copy \
    -backend-config="bucket=${BUCKET_NAME}" \
    -backend-config="key=bootstrap/terraform.tfstate" \
    -backend-config="region=${AWS_REGION:-us-east-1}" \
    -backend-config="encrypt=true" \
    -backend-config="kms_key_id=${KMS_KEY_ARN}" \
    -backend-config="dynamodb_table=${LOCK_TABLE}"

echo "[5/5] Verifying remote state..."
terraform state list

echo ""
echo "Bootstrap complete."
echo "Commit the updated backend.tf. DO NOT commit bootstrap.tfstate."
echo "Add bootstrap.tfstate to .gitignore immediately."