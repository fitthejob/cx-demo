#!/bin/bash
#run from: connect-pbx/modules/bootstrap/

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_SLUG="$(basename "${REPO_ROOT}")"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
PROFILE_NAME="${AWS_PROFILE:-default}"

if [[ -n "${CONNECT_PBX_BOOTSTRAP_DIR:-}" ]]; then
  BOOTSTRAP_ARTIFACT_DIR="${CONNECT_PBX_BOOTSTRAP_DIR}"
elif [[ -n "${LOCALAPPDATA:-}" ]]; then
  BOOTSTRAP_ARTIFACT_DIR="${LOCALAPPDATA}/connect-pbx/${REPO_SLUG}/bootstrap"
else
  BOOTSTRAP_ARTIFACT_DIR="${HOME}/.connect-pbx/${REPO_SLUG}/bootstrap"
fi

BACKEND_ARTIFACT_PATH="${BOOTSTRAP_ARTIFACT_DIR}/backend-${PROFILE_NAME}.hcl"

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

cat > backend.tf <<EOF
terraform {
  backend "s3" {
    bucket         = "${BUCKET_NAME}"
    key            = "bootstrap/terraform.tfstate"
    region         = "${AWS_REGION:-us-east-1}"
    encrypt        = true
    kms_key_id     = "${KMS_KEY_ARN}"
    dynamodb_table = "${LOCK_TABLE}"
  }
}
EOF

mkdir -p "${BOOTSTRAP_ARTIFACT_DIR}"

cat > "${BACKEND_ARTIFACT_PATH}" <<EOF
bucket         = "${BUCKET_NAME}"
key            = "bootstrap/terraform.tfstate"
region         = "${AWS_REGION:-us-east-1}"
encrypt        = true
kms_key_id     = "${KMS_KEY_ARN}"
dynamodb_table = "${LOCK_TABLE}"
EOF

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
echo "Bootstrap backend artifact: ${BACKEND_ARTIFACT_PATH}"
echo "Commit the updated backend.tf. DO NOT commit bootstrap.tfstate."
echo "Add bootstrap.tfstate to .gitignore immediately."
