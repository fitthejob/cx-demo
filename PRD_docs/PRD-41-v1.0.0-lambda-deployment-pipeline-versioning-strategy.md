# PRD-41 — Lambda Deployment Pipeline & Versioning Strategy

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-41 |
| **Version** | 1.2.0 |
| **Status** | Green |
| **Author** | — |
| **Last Updated** | 2026-04-06 |
| **Layer** | 4 — Compute Foundation |
| **Depends On** | PRD-01 (GitHub Actions workflows), PRD-40 (shared Lambda platform and artifacts bucket) |
| **Blocks** | Lambda-heavy service modules that opt into the shared Lambda deployment model |
| **Optional** | Yes — conditional foundation for Lambda-heavy profiles |

---

## 2. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

Lambda functions are updated more frequently than infrastructure resources. A contact flow change might happen quarterly; a Lambda function handling voicemail transcription might be updated weekly as the prompt changes or a bug is fixed. Without a dedicated Lambda deployment pipeline, every function update requires a full Terraform apply — slow, risky, and inappropriate for code-only changes that have no infrastructure side effects.

This PRD establishes a Lambda-specific deployment pipeline that is fast, safe, and separate from the Terraform infrastructure pipeline. It handles layer rebuilds, function code updates, alias promotion, and traffic shifting — all without touching Terraform state. It is intended for services that opt into the shared Lambda platform from PRD-40, not as a mandatory prerequisite for every Lambda in the system.

### What Problem It Solves

- Provides a GitHub Actions workflow for fast Lambda function code updates (publish new version, update alias — no Terraform required)
- Provides a layer rebuild workflow that packages dependencies and SDK, uploads to S3, and triggers a Terraform layer version bump
- Establishes the Lambda alias strategy (LIVE alias → current stable version, CANARY alias → new version during traffic shifting)
- Provides a canary deployment pattern for gradual traffic shifting to new Lambda versions
- Documents the rollback procedure for Lambda function versions

### How It Fits the Overall Architecture

PRD-41 provides the fast-path deployment mechanism for Lambda code changes. Infrastructure changes (new functions, new IAM permissions, new environment variables) still go through Terraform via PRD-01. Code-only changes (updating `index.py`, bumping a dependency) go through the Lambda pipeline defined here. The two pipelines are separate concerns and never conflict.

PRD-41 is a workflow-only control-plane document. It owns repository workflows and release-automation conventions, not Terraform-managed resources or a module backend.

---

## 3. REPO-OWNED MODULARITY & GOVERNANCE

This PRD follows the repo's manifest/catalog model. Feature activation is controlled by the module catalog and per-environment deployment manifest. `deployment_profile` is used only for runtime shape such as scale, topology, and capacity.

### Module Classification

| Field | Value |
|---|---|
| **classification** | conditional-foundation |
| **minimum_deployment_profile** | standard |
| **can_be_omitted_from_bare_bones** | yes |
| **introduces_new_hard_dependencies_into_lower_layers** | no |

### Catalog / Ownership

| Field | Value |
|---|---|
| **Catalog Entry** | None for this PRD. PRD-41 is workflow-only and does not introduce a Terraform module directory. |
| **Owned Deliverables** | `.github/workflows/lambda-deploy.yml`, `.github/workflows/lambda-layer-rebuild.yml`, `.github/workflows/lambda-canary-promote.yml` |
| **Runner Convention** | The standard `connect-pbx/scripts/tf-run.sh` / `tf-plan-audit.sh` path validates the deployment manifest, derives `state_key` from the catalog, and loads `global.tfvars` plus any catalog-declared domain tfvars. PRD-41 does not introduce a root tfvars or custom backend pattern. |

### Shared Sink Behavior

| Field | Value |
|---|---|
| **optional_shared_sinks** | PRD-03 alarm and audit sinks |
| **sink_behavior** | optional input only; mirror deployment records or alerts when the audit-operations pack is enabled, but do not make PRD-03 a prerequisite for PRD-41 |

### Destroy / Retention Posture

| Field | Value |
|---|---|
| **destroy_posture** | protected |
| **retention_notes** | No Terraform-managed resources, no state transfer, and no manual `terraform state rm` path are owned by this PRD. Workflow files remain repo-owned control-plane artifacts. |

### Control Plane Statement

> This PRD follows the repo's manifest/catalog model. Feature activation is controlled by the module catalog and per-environment deployment manifest. `deployment_profile` is used only for runtime shape such as scale, topology, and capacity.

---

## 4. GOALS

### Goals

- Provision Lambda function aliases (`LIVE` and `CANARY`) on Lambda functions that opt into the shared deployment model
- Define the GitHub Actions workflow `lambda-deploy.yml` for fast function code updates
- Define the GitHub Actions workflow `lambda-layer-rebuild.yml` for rebuilding and publishing layers
- Establish the canary deployment pattern with configurable traffic weight
- Document the rollback procedure for Lambda function versions
- Export the `LIVE` alias ARN pattern for service PRDs that opt into the shared Lambda deployment model

### Non-Goals

- This PRD does not provision any Lambda functions — those are in their respective service PRDs
- This PRD does not modify Terraform state during code deployments — that is intentional
- This PRD does not implement blue/green deployment at the infrastructure level — that is PRD-120
- This PRD does not implement Lambda container images — all functions use zip deployments

---

## 5. PERSONAS & USER STORIES

### Personas

**Platform Engineer** — Uses the Lambda deployment pipeline for rapid iteration on function code without full Terraform applies.

**Service Developer** — Pushes a code fix to a Lambda function and sees it deployed to dev within 3 minutes via the Lambda deploy workflow.

**Operations Engineer** — Uses canary deployment to gradually shift traffic to a new function version, monitoring error rates before completing the rollout.

### User Stories

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-41-01 | Service Developer | As a service developer, I want to deploy a Lambda code change without running terraform apply so that code updates are fast | Lambda deploy workflow publishes new version and updates LIVE alias within 3 minutes |
| US-41-02 | Operations Engineer | As an operations engineer, I want to deploy a new Lambda version to 10% of traffic first so that I can monitor error rates before full rollout | Canary deployment sets LIVE alias to 90% old / 10% new; metrics monitored before full cutover |
| US-41-03 | Platform Engineer | As the platform engineer, I want to rebuild Lambda layers without a full Terraform apply so that dependency updates are fast | Layer rebuild workflow builds zip, uploads to S3, bumps version variable, and triggers Terraform layer apply only |
| US-41-04 | Operations Engineer | As an operations engineer, I want to instantly roll back a Lambda function to the previous version so that incidents are recovered in under 2 minutes | Rollback workflow updates LIVE alias to previous version number; completes in < 2 minutes |

---

## 6. FUNCTIONAL REQUIREMENTS

### FR-001 — Lambda Alias Strategy
Every Lambda function that opts into the shared Lambda deployment model should have two aliases:
- `LIVE` — points to the current stable version. All EventBridge rules, S3 notifications, and scheduled events must target the `LIVE` alias ARN, never the function ARN directly. This makes version updates transparent to callers.
- `CANARY` — points 100% to the candidate version during a canary deployment and is kept aligned with the stable version when no canary is active. Traffic shifting is performed only through the `LIVE` alias routing configuration.

### FR-002 — Lambda Deploy Workflow: lambda-deploy.yml
Provision a GitHub Actions workflow (YAML) named `lambda-deploy.yml` that accepts `function_name`, `artifact_prefix`, `environment`, and `canary_weight` (default 0, meaning full immediate deployment) as inputs. The workflow must:
1. Check out the repository
2. Package the Lambda function source (zip the relevant `lambda-src/` directory)
3. Upload the zip to the artifacts bucket under `lambda/packages/{artifact_prefix}/{github_run_id}.zip`
4. Call `aws lambda update-function-code` to upload the new zip
5. Wait for the update to complete (`aws lambda wait function-updated`)
6. Publish a new version (`aws lambda publish-version`)
7. If `canary_weight = 0`: update the `LIVE` alias to 100% of the new version
8. If `canary_weight > 0`: update the `LIVE` alias to `(100 - canary_weight)%` old version, `canary_weight%` new version
9. Write a deployment record to `s3://{state_bucket}/audit/lambda-deployments/{environment}/{function_name}/{date}/{run_id}.json`

### FR-003 — Layer Rebuild Workflow: lambda-layer-rebuild.yml
Provision a GitHub Actions workflow (YAML) named `lambda-layer-rebuild.yml` that accepts `layer_name` (`dependencies` or `platform-sdk`) and `environment` as inputs. The workflow must:
1. Build the layer zip (pip install for dependencies, copy SDK for platform-sdk)
2. Upload the zip to the artifacts bucket
3. Bump the layer version input in the catalog-owned environment tfvars file for the selected environment via a commit
4. Hand off to the standard `connect-pbx/scripts/tf-run.sh` / `tf-apply.yml` manifest-and-catalog runner path for the `l4-lambda-baseline` module only

### FR-004 — Canary Promotion Workflow: lambda-canary-promote.yml
Provision a workflow that accepts `function_name`, `environment`, and `action` (`promote` or `rollback`) as inputs. On `promote`: update `LIVE` alias to 100% of the current canary version, clear weighted routing, and align the `CANARY` alias to the same version. On `rollback`: read the `latest-success.json` deployment pointer for that function and environment, revert `LIVE` alias to the recorded `previous_version`, clear weighted routing, and align `CANARY` to the restored stable version.

### FR-005 — Lambda Version Tracking
Every Lambda deployment must write an immutable JSON record to `s3://{state_bucket}/audit/lambda-deployments/{environment}/{function_name}/{YYYY}/{MM}/{DD}/{run_id}.json` with the following fields: `timestamp`, `function_name`, `environment`, `previous_version`, `new_version`, `canary_weight`, `github_run_id`, `github_actor`, `outcome`. Successful deployments must also refresh `s3://{state_bucket}/audit/lambda-deployments/{environment}/{function_name}/latest-success.json` with the same payload for rollback lookup.

### FR-006 — EventBridge Rule Alias Convention
Downstream service PRDs that opt into the shared Lambda deployment model should reference the function's `LIVE` alias ARN rather than the base function ARN or a specific version ARN. This is a Terraform convention only for opted-in services — downstream PRDs should use `aws_lambda_alias.live.arn` as the target ARN when the shared Lambda deployment model is enabled.

### FR-007 — Alias Provisioning in Service PRDs
Every Lambda function provisioned in a service PRD that opts into the shared Lambda deployment model should include the following alias resources. This is the only Terraform content related to Lambda deployment in each service PRD — the rest of the deployment lifecycle is handled by this PRD's workflows:

```hcl
resource "aws_lambda_alias" "live" {
  name             = "LIVE"
  function_name    = aws_lambda_function.service.function_name
  function_version = aws_lambda_function.service.version
  # Updated by lambda-deploy.yml — not managed by Terraform after initial creation
  lifecycle { ignore_changes = [function_version, routing_config] }
}

resource "aws_lambda_alias" "canary" {
  name             = "CANARY"
  function_name    = aws_lambda_function.service.function_name
  function_version = aws_lambda_function.service.version
  lifecycle { ignore_changes = [function_version, routing_config] }
}
```

---

## 7. NON-FUNCTIONAL REQUIREMENTS

### Deployment Speed

| Operation | Target |
|---|---|
| Lambda code update (no canary) | < 3 minutes end-to-end |
| Lambda canary initiation | < 3 minutes |
| Canary promotion to 100% | < 1 minute |
| Rollback to previous version | < 2 minutes |
| Layer rebuild + Terraform layer apply | < 10 minutes |

### Safety
- No Terraform state changes during code-only Lambda deployments
- Canary weight is bounded: 1-50% maximum (prevents routing majority of traffic to unverified version)
- Rollback always targets the previous version number — recorded in the deployment audit log

### Security
- Lambda deploy workflow uses the same OIDC role as the Terraform pipeline — no separate credentials
- Deployment audit records written to the state bucket (same access controls as Terraform audit log)
- Layer zips are stored in the central artifacts bucket owned by PRD-40

---

## 8. ARCHITECTURE

### Lambda Deployment Pipeline

```
Code Change (function or layer)
          │
          ├── Infrastructure change (new function, new IAM, new env var)
          │         │
          │         └── Terraform pipeline (PRD-01)
          │               plan → review → apply
          │
          └── Code-only change (updated handler, bug fix)
                    │
                    └── Lambda deploy pipeline (PRD-41)
                          │
                          ▼
                    lambda-deploy.yml
                          │
                    ├── zip → S3 artifacts
                    ├── update-function-code
                    ├── publish-version
                    ├── update LIVE alias (full or canary split)
                    └── write audit record

Lambda Function Version Model:
      Version 1 (initial Terraform deploy)
      Version 2 (first lambda-deploy.yml run)
      Version 3 (second lambda-deploy.yml run)
            │
            ├── LIVE alias → Version 3 (stable, 100%)
            └── CANARY alias → Version 3 (same as stable when idle)

Canary Deployment:
      LIVE alias → Version 3 (90%) + Version 4 (10%)
      CANARY alias → Version 4 (100%)
          │
          ├── Monitor: error rate, latency, DLQ depth
          │
          ├── Promote: LIVE → Version 4 (100%)
          └── Rollback: LIVE → Version 3 (100%)
```

### GitHub Actions Workflow Files

```
.github/workflows/
├── lambda-deploy.yml          # YAML — fast Lambda code deployment
├── lambda-layer-rebuild.yml   # YAML — layer rebuild and version bump
└── lambda-canary-promote.yml  # YAML — canary promote or rollback
```

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `lambda_deploy_workflow` | File: `lambda-deploy.yml` | Fast Lambda deployment workflow | All service PRDs — referenced in CI/CD sections |
| `lambda_layer_rebuild_workflow` | File: `lambda-layer-rebuild.yml` | Layer rebuild workflow | PRD-40 layer version management |
| `lambda_canary_promote_workflow` | File: `lambda-canary-promote.yml` | Canary promotion and rollback | Operations runbooks |
| `alias_convention` | Standard | LIVE alias target convention for event-driven rules targeting opted-in PRD-41-managed Lambdas | Downstream PRDs that opt into the shared deployment model |

---

## 9. TERRAFORM SPECIFICATION

### No Terraform Module for This PRD

PRD-41 provisions no Terraform-managed AWS resources. Its primary deliverables are GitHub Actions workflow YAML files and repository commit conventions that feed the standard manifest/catalog runner path. The alias resources described in FR-007 are provisioned by each service PRD, not by this PRD.

### GitHub Actions Workflow Files (YAML)

#### lambda-deploy.yml

```yaml
# .github/workflows/lambda-deploy.yml
# Fast Lambda code deployment — no Terraform required for code-only changes.
# YAML is required by the GitHub Actions platform.

name: Lambda Deploy

on:
  workflow_call:
    inputs:
      function_name:
        required: true
        type: string
      artifact_prefix:
        required: true
        type: string
        description: "Producer-owned prefix under lambda/packages/ in the PRD-40 artifacts bucket"
      environment:
        required: true
        type: string
      canary_weight:
        required: false
        type: number
        default: 0
      source_path:
        required: true
        type: string
        description: "Path to the Lambda source directory (e.g., modules/l6-voicemail/lambda-src/voicemail-recorder)"

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: ${{ inputs.environment }}
    permissions:
      id-token: write
      contents: read

    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.TF_EXEC_ROLE_ARN }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Package Lambda function
        run: |
          cd ${{ inputs.source_path }}
          zip -r /tmp/${{ inputs.function_name }}-${{ github.run_id }}.zip .

      - name: Validate canary weight
        run: |
          CANARY=${{ inputs.canary_weight }}
          if [ "$CANARY" -lt 0 ] || [ "$CANARY" -gt 50 ]; then
            echo "canary_weight must be between 0 and 50"
            exit 1
          fi

      - name: Upload to artifacts bucket
        run: |
          aws s3 cp /tmp/${{ inputs.function_name }}-${{ github.run_id }}.zip \
            s3://${{ secrets.ARTIFACTS_BUCKET }}/lambda/packages/${{ inputs.artifact_prefix }}/${{ github.run_id }}.zip \
            --sse aws:kms --sse-kms-key-id ${{ secrets.ENV_KMS_KEY_ARN }}

      - name: Update function code
        id: update
        run: |
          aws lambda update-function-code \
            --function-name ${{ inputs.function_name }} \
            --s3-bucket ${{ secrets.ARTIFACTS_BUCKET }} \
            --s3-key lambda/packages/${{ inputs.artifact_prefix }}/${{ github.run_id }}.zip
          aws lambda wait function-updated --function-name ${{ inputs.function_name }}

      - name: Publish new version
        id: publish
        run: |
          VERSION=$(aws lambda publish-version \
            --function-name ${{ inputs.function_name }} \
            --description "Deployed by GitHub Actions run ${{ github.run_id }}" \
            --query Version --output text)
          echo "new_version=${VERSION}" >> $GITHUB_OUTPUT

      - name: Get current LIVE alias version
        id: current
        run: |
          ALIAS_INFO=$(aws lambda get-alias \
            --function-name ${{ inputs.function_name }} \
            --name LIVE)
          CURRENT=$(echo "$ALIAS_INFO" | jq -r '.FunctionVersion')
          echo "previous_version=${CURRENT}" >> $GITHUB_OUTPUT

      - name: Update CANARY alias to candidate version
        run: |
          aws lambda update-alias \
            --function-name ${{ inputs.function_name }} \
            --name CANARY \
            --function-version ${{ steps.publish.outputs.new_version }}

      - name: Update LIVE alias
        run: |
          NEW_VERSION=${{ steps.publish.outputs.new_version }}
          CANARY=${{ inputs.canary_weight }}
          if [ "$CANARY" -eq "0" ]; then
            aws lambda update-alias \
              --function-name ${{ inputs.function_name }} \
              --name LIVE \
              --function-version ${NEW_VERSION} \
              --routing-config 'AdditionalVersionWeights={}'
          else
            PREV=${{ steps.current.outputs.previous_version }}
            WEIGHT=$(awk "BEGIN { printf \"%.2f\", ${CANARY}/100 }")
            aws lambda update-alias \
              --function-name ${{ inputs.function_name }} \
              --name LIVE \
              --function-version ${PREV} \
              --routing-config "AdditionalVersionWeights={${NEW_VERSION}=${WEIGHT}}"
          fi

      - name: Write deployment audit record
        if: always()
        run: |
          DATE=$(date -u +%Y/%m/%d)
          TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
          cat > /tmp/deploy-record.json <<EOF
          {
            "timestamp": "${TIMESTAMP}",
            "function_name": "${{ inputs.function_name }}",
            "environment": "${{ inputs.environment }}",
            "previous_version": "${{ steps.current.outputs.previous_version }}",
            "new_version": "${{ steps.publish.outputs.new_version }}",
            "canary_weight": ${{ inputs.canary_weight }},
            "github_run_id": "${{ github.run_id }}",
            "github_actor": "${{ github.actor }}",
            "outcome": "${{ job.status }}"
          }
          EOF
          aws s3 cp /tmp/deploy-record.json \
            s3://${{ secrets.STATE_BUCKET }}/audit/lambda-deployments/${{ inputs.environment }}/${{ inputs.function_name }}/${DATE}/${{ github.run_id }}.json \
            --sse aws:kms --sse-kms-key-id ${{ secrets.ENV_KMS_KEY_ARN }}

      - name: Refresh latest successful deployment pointer
        if: success()
        run: |
          aws s3 cp /tmp/deploy-record.json \
            s3://${{ secrets.STATE_BUCKET }}/audit/lambda-deployments/${{ inputs.environment }}/${{ inputs.function_name }}/latest-success.json \
            --sse aws:kms --sse-kms-key-id ${{ secrets.ENV_KMS_KEY_ARN }}
```

#### lambda-canary-promote.yml

```yaml
# .github/workflows/lambda-canary-promote.yml
# Promotes a canary deployment to 100% or rolls back to the previous version.
# YAML is required by the GitHub Actions platform.

name: Lambda Canary Promote

on:
  workflow_dispatch:
    inputs:
      function_name:
        required: true
        type: string
      environment:
        required: true
        type: choice
        options: [dev, staging, prod]
      action:
        required: true
        type: choice
        options: [promote, rollback]

jobs:
  canary-action:
    runs-on: ubuntu-latest
    environment: ${{ inputs.environment }}
    permissions:
      id-token: write
      contents: read

    steps:
      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.TF_EXEC_ROLE_ARN }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Get current LIVE alias config
        id: alias
        run: |
          ALIAS_INFO=$(aws lambda get-alias \
            --function-name ${{ inputs.function_name }} \
            --name LIVE)
          CANARY_INFO=$(aws lambda get-alias \
            --function-name ${{ inputs.function_name }} \
            --name CANARY)
          MAIN_VER=$(echo $ALIAS_INFO | jq -r '.FunctionVersion')
          CANARY_VER=$(echo $CANARY_INFO | jq -r '.FunctionVersion')
          echo "main_version=${MAIN_VER}" >> $GITHUB_OUTPUT
          echo "canary_version=${CANARY_VER}" >> $GITHUB_OUTPUT

      - name: Execute action
        run: |
          if [ "${{ inputs.action }}" == "promote" ]; then
            # Promote canary to 100%
            CANARY_VER=${{ steps.alias.outputs.canary_version }}
            if [ -z "$CANARY_VER" ]; then
              echo "No canary version found. Nothing to promote."
              exit 0
            fi
            aws lambda update-alias \
              --function-name ${{ inputs.function_name }} \
              --name LIVE \
              --function-version ${CANARY_VER} \
              --routing-config 'AdditionalVersionWeights={}'
            aws lambda update-alias \
              --function-name ${{ inputs.function_name }} \
              --name CANARY \
              --function-version ${CANARY_VER}
            echo "Promoted version ${CANARY_VER} to 100%"
          else
            PREVIOUS_VERSION=$(aws s3 cp \
              "s3://${{ secrets.STATE_BUCKET }}/audit/lambda-deployments/${{ inputs.environment }}/${{ inputs.function_name }}/latest-success.json" - \
              | jq -r '.previous_version')
            aws lambda update-alias \
              --function-name ${{ inputs.function_name }} \
              --name LIVE \
              --function-version ${PREVIOUS_VERSION} \
              --routing-config 'AdditionalVersionWeights={}'
            aws lambda update-alias \
              --function-name ${{ inputs.function_name }} \
              --name CANARY \
              --function-version ${PREVIOUS_VERSION}
            echo "Rolled back to version ${PREVIOUS_VERSION}"
          fi
```

#### lambda-layer-rebuild.yml

```yaml
# .github/workflows/lambda-layer-rebuild.yml
# Rebuilds a Lambda Layer, uploads to S3, and triggers Terraform layer version bump.
# YAML is required by the GitHub Actions platform.

name: Lambda Layer Rebuild

on:
  workflow_dispatch:
    inputs:
      layer_name:
        required: true
        type: choice
        options: [dependencies, platform-sdk]
      environment:
        required: true
        type: choice
        options: [dev, staging, prod]

jobs:
  rebuild:
    runs-on: ubuntu-latest
    environment: ${{ inputs.environment }}
    permissions:
      id-token: write
      contents: write   # Required to commit version bump
      pull-requests: write

    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.TF_EXEC_ROLE_ARN }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Compute layer version
        id: version
        run: |
          NEW_VERSION="$(date -u +%Y.%m.%d)-${{ github.run_id }}"
          echo "new_version=${NEW_VERSION}" >> $GITHUB_OUTPUT

      - name: Build dependencies layer
        if: inputs.layer_name == 'dependencies'
        run: |
          mkdir -p dist/dependencies-layer/python/lib/python3.12/site-packages
          pip install \
            boto3==1.34.0 botocore==1.34.0 pydantic==2.5.0 requests==2.31.0 \
            aws-lambda-powertools==2.30.0 aws-xray-sdk==2.12.0 \
            --target dist/dependencies-layer/python/lib/python3.12/site-packages \
            --platform manylinux2014_x86_64 --only-binary=:all: --quiet
          mkdir -p modules/l4-lambda-baseline/dist
          cd dist/dependencies-layer && zip -r ../../modules/l4-lambda-baseline/dist/dependencies-layer.zip .

      - name: Build platform SDK layer
        if: inputs.layer_name == 'platform-sdk'
        run: |
          mkdir -p dist/platform-sdk-layer/python/lib/python3.12/site-packages
          cp -r modules/l4-lambda-baseline/sdk/connect_pbx \
            dist/platform-sdk-layer/python/lib/python3.12/site-packages/
          mkdir -p modules/l4-lambda-baseline/dist
          cd dist/platform-sdk-layer && zip -r ../../modules/l4-lambda-baseline/dist/platform-sdk-layer.zip .

      - name: Upload rebuilt layer artifact
        run: |
          if [ "${{ inputs.layer_name }}" = "dependencies" ]; then
            FILE_PATH="modules/l4-lambda-baseline/dist/dependencies-layer.zip"
            OBJECT_KEY="lambda/layers/dependencies/${{ steps.version.outputs.new_version }}.zip"
          else
            FILE_PATH="modules/l4-lambda-baseline/dist/platform-sdk-layer.zip"
            OBJECT_KEY="lambda/layers/platform-sdk/${{ steps.version.outputs.new_version }}.zip"
          fi
          aws s3 cp "${FILE_PATH}" \
            "s3://${{ secrets.ARTIFACTS_BUCKET }}/${OBJECT_KEY}" \
            --sse aws:kms --sse-kms-key-id ${{ secrets.ENV_KMS_KEY_ARN }}

      - name: Bump layer version in tfvars
        run: |
          NEW_VERSION="${{ steps.version.outputs.new_version }}"
          TFVARS_FILE="environments/${{ inputs.environment }}/global.tfvars"
          if [ "${{ inputs.layer_name }}" = "platform-sdk" ]; then
            TFVAR_NAME="platform_sdk_layer_version"
          else
            TFVAR_NAME="dependencies_layer_version"
          fi
          sed -i "s/${TFVAR_NAME} = \".*\"/${TFVAR_NAME} = \"${NEW_VERSION}\"/" \
            "${TFVARS_FILE}"
          echo "Bumped ${TFVAR_NAME} to ${NEW_VERSION} in ${TFVARS_FILE}"

      - name: Create branch and open PR for version bump
        run: |
          BRANCH="chore/layer-bump-${{ inputs.layer_name }}-${{ github.run_id }}"
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git checkout -b "${BRANCH}"
          git add environments/${{ inputs.environment }}/global.tfvars
          git commit -m "chore: bump ${{ inputs.layer_name }} layer version [${{ github.run_id }}]"
          git push -u origin "${BRANCH}"
          gh pr create \
            --title "chore: bump ${{ inputs.layer_name }} layer version" \
            --body "Automated layer rebuild triggered by workflow run ${{ github.run_id }}. Merging this PR will trigger the Terraform apply for l4-lambda-baseline." \
            --base main
```

### Alias Convention Reference (HCL)

This is the canonical pattern that every service PRD must use when defining EventBridge rule targets:

```hcl
# CORRECT — targets LIVE alias, version-transparent
resource "aws_cloudwatch_event_target" "service" {
  rule           = aws_cloudwatch_event_rule.service.name
  event_bus_name = local.event_bus_name
  target_id      = "service-lambda-live"
  arn            = aws_lambda_alias.live.arn

  dead_letter_config { arn = local.eventbridge_dlq_arn }
  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 3
  }
}

# WRONG — targets specific version, must update on every deployment
# arn = "${aws_lambda_function.service.arn}:5"  # Never do this
```

---

## 10. EVENT SCHEMA

PRD-41 produces no EventBridge events.

### Lambda Deployment Audit Schema

Written to `s3://{state_bucket}/audit/lambda-deployments/{environment}/{function_name}/{YYYY}/{MM}/{DD}/{run_id}.json`, with the latest successful payload mirrored to `.../latest-success.json`:

```json
{
  "timestamp":        "ISO 8601 UTC",
  "function_name":    "string",
  "environment":      "dev | staging | prod",
  "previous_version": "string — Lambda version number",
  "new_version":      "string — Lambda version number",
  "canary_weight":    "number — 0-50",
  "github_run_id":    "string",
  "github_actor":     "string",
  "outcome":          "success | failure"
}
```

---

## 11. API / INTERFACE CONTRACT

PRD-41 exposes no Terraform outputs. Its contract is the three YAML workflow files and the alias convention documented in Section 8.

---

## 12. DATA MODEL

### Lambda Version Lineage

```
s3://{org}-tfstate-{acct}/
└── audit/
    └── lambda-deployments/
        └── {environment}/
            └── {function_name}/
                ├── latest-success.json
                └── {YYYY}/{MM}/{DD}/
                    └── {run_id}.json
```

---

## 13. CI/CD SPECIFICATION

PRD-41 defines CI/CD workflows rather than consuming them. Its own deployment is the same one-time file commit pattern as PRD-01:

```
1. Copy lambda-deploy.yml, lambda-canary-promote.yml,
   lambda-layer-rebuild.yml to .github/workflows/
2. Commit and push to main
3. Verify workflows appear in GitHub Actions tab
4. Test lambda-deploy.yml against a dev function (PRD-60 voicemail Lambda is a good first test)
```

### Rollback

Lambda function rollback procedure (applicable to service PRDs that opt into this deployment model):

```bash
# Option 1: Use the canary-promote workflow with action=rollback
# Dispatches via GitHub UI or CLI

# Option 2: Manual immediate rollback via CLI (< 2 minutes)
FUNCTION_NAME="{org}-{service}-{env}"
PREVIOUS_VERSION=$(aws s3 cp "s3://{state_bucket}/audit/lambda-deployments/{env}/{function_name}/latest-success.json" - \
  | jq -r '.previous_version')

aws lambda update-alias \
  --function-name $FUNCTION_NAME \
  --name LIVE \
  --function-version $PREVIOUS_VERSION \
  --routing-config 'AdditionalVersionWeights={}'

echo "Rolled back $FUNCTION_NAME to version $PREVIOUS_VERSION"
```

---

## 14. OBSERVABILITY SPECIFICATION

### Alarms

**ALARM-41-01: Lambda Deployment Failure**
- Source: S3 audit record with `"outcome": "failure"` in `audit/lambda-deployments/{env}/{function_name}/`
- Detection: Optional shared sink via PRD-03 when the audit-operations pack is enabled; otherwise the S3 record is the primary source
- Severity: High

**ALARM-41-02: Canary Error Rate Spike**
- Source: CloudWatch Lambda `Errors` metric filtered by the canary version alias
- Threshold: Error rate > 5% during canary window
- Action: SNS alert — operations team must decide to promote or rollback
- Severity: High

### SOC 2 Evidence

| Artifact | Demonstrates |
|---|---|
| Lambda deployment audit records in S3 | SOC 2 CC8.1 — change management for application code |
| Canary deployment records | SOC 2 CC7.1 — testing before full deployment |

---

## 15. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-41-01 | lambda-deploy.yml exists in .github/workflows/ | File present in repository |
| AC-41-02 | lambda-canary-promote.yml exists | File present in repository |
| AC-41-03 | lambda-layer-rebuild.yml exists | File present in repository |
| AC-41-04 | Lambda deploy workflow publishes new version and updates LIVE alias | Run workflow against dev function; confirm new version and alias update |
| AC-41-05 | Canary deployment routes correct traffic split | Set canary_weight=20; confirm LIVE alias routing config shows 80/20 split |
| AC-41-06 | Promote action resolves canary to 100% | Run canary-promote with action=promote; confirm LIVE alias points to single version |
| AC-41-07 | Rollback action reverts LIVE alias to previous version | Run canary-promote with action=rollback; confirm LIVE alias points to previous version |
| AC-41-08 | Deployment audit record written to S3 | Run deploy workflow; confirm JSON record in audit/lambda-deployments/ |
| AC-41-09 | Layer rebuild workflow builds and uploads zip | Run layer-rebuild for platform-sdk; confirm new zip in artifacts bucket |
| AC-41-10 | Layer version bump committed to repository | Run layer-rebuild; confirm tfvars version string updated in Git |

---

## 16. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Canary deployment left at split — never promoted or rolled back | Medium | Medium | ALARM-41-02 monitors canary error rate. Operations runbook requires canary resolution within 24 hours. |
| Lambda version limit (10,000 versions per function) reached over time | Very Low | High | Lambda automatically deletes oldest versions when limit is approached. Monitoring via CloudWatch Lambda metrics. |
| Layer rebuild commits to main without PR review | Low | Medium | Mitigated: workflow updated to create a feature branch and open a PR via `gh pr create`. Branch protection rules enforce review before merge. |
| lambda-deploy.yml used for infrastructure changes (new env vars, IAM changes) | Medium | Medium | Documentation and training. Infrastructure changes require Terraform pipeline. The deploy workflow rejects attempts to change non-code attributes. |

---

## 17. OPEN QUESTIONS

| ID | Question | Status |
|---|---|---|
| OQ-41-01 | Should lambda-layer-rebuild.yml commit directly to main or open a PR? Direct commit is faster but bypasses branch protection. Opening a PR adds safety but requires a review cycle. | **Resolved** — workflow updated to create a feature branch and open a PR via `gh pr create`. Merging the PR triggers the Terraform apply via the standard pipeline. |
| OQ-41-02 | Should the ARTIFACTS_BUCKET secret be added to GitHub Actions environments now or wait until PRD-40 is applied? | Resolved — add ARTIFACTS_BUCKET to GitHub environment secrets after PRD-40 apply, alongside ENV_KMS_KEY_ARN. |

---

## 18. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.2.0 | 2026-04-06 | — | Implementation-readiness hardening: aligned package uploads to PRD-40 prefix ownership, made deployment audit records function-scoped, added a `latest-success.json` rollback pointer, defined CANARY alias behavior explicitly, corrected rollback to use recorded previous versions, and completed the layer rebuild workflow with versioned artifact uploads and current repo-root paths. |
| 1.0.0 | 2026-03-16 | — | Initial release. Three workflow files. LIVE alias convention established. Canary deployment pattern with promote/rollback workflow. Lambda deployment audit schema locked. Layer 4 Compute Foundation complete. |
| 1.1.0 | 2026-03-30 | — | Normalized PRD-41 as a conditional foundation for Lambda-heavy profiles. Updated artifacts dependency from PRD-30 to PRD-40 and clarified that alias and canary conventions apply to services that opt into the shared Lambda deployment model. |
| 1.1.1 | 2026-04-05 | — | Governance normalization: added repo-owned modularity/control-plane guidance, scoped alias conventions to opted-in services, treated PRD-03 sinks as optional shared inputs, replaced stale root tfvars/backend guidance with current runner conventions, and corrected rollback/artifact-commit sample drift. |
