#!/usr/bin/env bash
# ==============================================================================
# Step 4: Enable Inline Content Safety Guardrails (Model Armor & Cloud DLP)
# ==============================================================================
set -euo pipefail

export PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project)}"
export REGION="${REGION:-us-central1}"
export PROJECT_NUMBER="${PROJECT_NUMBER:-$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")}"
export ORGANIZATION_ID="${ORGANIZATION_ID:-$(gcloud projects get-ancestors "${PROJECT_ID}" --format=json 2>/dev/null | jq -r '.[] | select(.type=="organization") | .id')}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../deployment/terraform"

echo "[1/2] Provisioning Model Armor & Sensitive Data Protection (DLP) templates and attaching CONTENT_AUTHZ policy..."
terraform -chdir="${TF_DIR}" apply -auto-approve -lock-timeout=600s \
  -var="project_id=${PROJECT_ID}" \
  -var="project_number=${PROJECT_NUMBER}" \
  -var="region=${REGION}" \
  -var="organization_id=${ORGANIZATION_ID}" \
  -var="enable_iap_enforcement=true" \
  -var="agent_gateway_name=gateway-egress" \
  -var="artifact_registry_repo=agent-repo" \
  -var="vpc_network_name=governed-agent-vpc" \
  -var="subnet_name=agent-private-subnet" \
  -var="network_attachment_name=gateway-egress-na" \
  -var="enable_model_armor=true" \
  -var="enable_vertex_ai_integration=true" \
  -var="vertex_ai_inspect_only=false" \
  -var="model_armor_request_template_id=agw-request-template" \
  -var="model_armor_response_template_id=agw-response-template" \
  -var="model_armor_inspect_template_id=agw-ssn-inspect-template" \
  -var="model_armor_deidentify_template_id=agw-ssn-redaction-template" \
  -target=module.model_armor \
  -target=module.gateway.google_network_services_authz_extension.model_armor \
  -target=module.gateway.google_network_security_authz_policy.model_armor \
  -target=module.gateway.google_project_iam_member.service_extensions_sa

echo "[2/2] Verifying active Model Armor request template..."
curl -s -X GET "https://modelarmor.${REGION}.rep.googleapis.com/v1alpha/projects/${PROJECT_ID}/locations/${REGION}/templates/agw-request-template" \
  -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" | grep -o '"name": "[^"]*'
echo ""
