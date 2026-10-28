#!/usr/bin/env bash
# ==============================================================================
# Step 3: Enforce Zero-Trust IAP Access Control Policies on Agent Gateway
# ==============================================================================
set -euo pipefail

export PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project)}"
export REGION="${REGION:-us-central1}"
export AGENT_NAME="${AGENT_NAME:-hello-world-agent}"
export PROJECT_NUMBER="${PROJECT_NUMBER:-$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")}"
export ORGANIZATION_ID="${ORGANIZATION_ID:-$(gcloud projects get-ancestors "${PROJECT_ID}" --format=json 2>/dev/null | jq -r '.[] | select(.type=="organization") | .id')}"

export INSTANCE_ID="${INSTANCE_ID:-$(curl -s -X GET "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines" \
  -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
  -H "X-Goog-User-Project: ${PROJECT_ID}" | jq -r '.reasoningEngines[]? | select(.displayName == "'"${AGENT_NAME}"'" or .displayName == "'"${AGENT_NAME//-/_}"'") | .name' | awk -F'/' '{print $NF}' | head -n 1)}"

AGENT_PRINCIPAL="principal://agents.global.org-${ORGANIZATION_ID}.system.id.goog/resources/aiplatform/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${INSTANCE_ID}"
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

echo "[1/4] Granting Cloud Run Invoker (roles/run.invoker) on agents-everywhere-sample-tool..."
gcloud run services add-iam-policy-binding agents-everywhere-sample-tool \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:${COMPUTE_SA}" \
  --role="roles/run.invoker" --quiet

gcloud run services add-iam-policy-binding agents-everywhere-sample-tool \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --member="${AGENT_PRINCIPAL}" \
  --role="roles/run.invoker" --quiet

echo "[2/4] Granting Service Account Token Creator (roles/iam.serviceAccountTokenCreator) for impersonation fallback..."
gcloud iam service-accounts add-iam-policy-binding "${COMPUTE_SA}" \
  --project="${PROJECT_ID}" \
  --member="${AGENT_PRINCIPAL}" \
  --role="roles/iam.serviceAccountTokenCreator" --quiet

echo "[3/4] Retrieving dynamic MCP Server UUID and binding IAP Egressor (roles/iap.egressor)..."
export MCP_SERVER_UUID="$(curl -s "https://agentregistry.googleapis.com/v1alpha/projects/${PROJECT_ID}/locations/${REGION}/services/agents-everywhere-sample-tool" \
  -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
  -H "X-Goog-User-Project: ${PROJECT_ID}" | grep -o '"registryResource": "[^"]*' | cut -d'/' -f6)"

echo "MCP Server UUID: ${MCP_SERVER_UUID}"

gcloud beta iap web add-iam-policy-binding \
  --resource-type=agent-registry \
  --region="${REGION}" \
  --mcp-server="${MCP_SERVER_UUID}" \
  --member="${AGENT_PRINCIPAL}" \
  --role="roles/iap.egressor" \
  --project="${PROJECT_ID}" --quiet

echo "[4/4] Switching Agent Gateway IAP extension from DRY_RUN to active enforcement..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../deployment/terraform"

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
  -var="enable_model_armor=false" \
  -var="model_armor_request_template_id=agw-request-template" \
  -var="model_armor_response_template_id=agw-response-template" \
  -var="model_armor_inspect_template_id=agw-ssn-inspect-template" \
  -var="model_armor_deidentify_template_id=agw-ssn-redaction-template" \
  -var="enable_vertex_ai_integration=true" \
  -var="vertex_ai_inspect_only=false" \
  -target=module.gateway
