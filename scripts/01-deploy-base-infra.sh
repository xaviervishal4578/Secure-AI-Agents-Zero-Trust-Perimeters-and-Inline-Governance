#!/usr/bin/env bash
# ==============================================================================
# Step 1: Provision Base Networking & Regional Agent Gateway Infrastructure
# ==============================================================================
set -euo pipefail

export PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project)}"
export REGION="${REGION:-us-central1}"
export AGENT_NAME="${AGENT_NAME:-hello-world-agent}"
export PROJECT_NUMBER="${PROJECT_NUMBER:-$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")}"
export ORGANIZATION_ID="${ORGANIZATION_ID:-$(gcloud projects get-ancestors "${PROJECT_ID}" --format=json 2>/dev/null | jq -r '.[] | select(.type=="organization") | .id')}"
export USER_PROJECT_OVERRIDE=true
export GOOGLE_BILLING_PROJECT="${PROJECT_ID}"

echo "[1/3] Ensuring Vertex AI Service Agent exists..."
gcloud beta services identity create \
  --service=aiplatform.googleapis.com \
  --project="${PROJECT_ID}" \
  --quiet

echo "[2/3] Initializing and applying foundational Terraform infrastructure (DRY_RUN mode)..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../deployment/terraform"

terraform -chdir="${TF_DIR}" init

terraform -chdir="${TF_DIR}" apply -auto-approve -lock-timeout=600s \
  -var="project_id=${PROJECT_ID}" \
  -var="project_number=${PROJECT_NUMBER}" \
  -var="region=${REGION}" \
  -var="organization_id=${ORGANIZATION_ID}" \
  -var="enable_iap_enforcement=false" \
  -var="agent_gateway_name=gateway-egress" \
  -var="artifact_registry_repo=agent-repo" \
  -var="vpc_network_name=governed-agent-vpc" \
  -var="subnet_name=agent-private-subnet" \
  -var="network_attachment_name=gateway-egress-na" \
  -var="enable_model_armor=false" \
  -var="model_armor_request_template_id=agw-request-template" \
  -var="model_armor_response_template_id=agw-response-template" \
  -var="model_armor_inspect_template_id=agw-ssn-inspect-template" \
  -var="model_armor_deidentify_template_id=agw-ssn-redaction-template" \
  -var="enable_vertex_ai_integration=true" \
  -var="vertex_ai_inspect_only=false"

echo "[3/3] Verifying Private Service Connect (PSC) network attachment..."
gcloud compute network-attachments describe gateway-egress-na \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format="value(connectionPreference)"
