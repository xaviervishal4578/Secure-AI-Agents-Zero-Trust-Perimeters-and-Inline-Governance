#!/usr/bin/env bash
# ==============================================================================
# Step 2: Deploy Cloud Run MCP Tool & ADK Agent Runtime + Register in Agent Registry
# ==============================================================================
set -euo pipefail

export PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project)}"
export REGION="${REGION:-us-central1}"
export AGENT_NAME="${AGENT_NAME:-hello-world-agent}"
export PROJECT_NUMBER="${PROJECT_NUMBER:-$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")}"
export ORGANIZATION_ID="${ORGANIZATION_ID:-$(gcloud projects get-ancestors "${PROJECT_ID}" --format=json 2>/dev/null | jq -r '.[] | select(.type=="organization") | .id')}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "[1/5] Deploying serverless MCP tool service (agents-everywhere-sample-tool) to Cloud Run..."
gcloud run deploy agents-everywhere-sample-tool \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --source="${REPO_ROOT}/src/mcp-servers/sample-tool" \
  --memory=4Gi \
  --cpu=1 \
  --min-instances=1 \
  --max-instances=10 \
  --concurrency=8 \
  --allow-unauthenticated \
  --no-cpu-throttling \
  --port=8080 \
  --service-account="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --update-env-vars=AGENT_VERSION=0.1.0

export TOOL_URL="$(gcloud run services describe agents-everywhere-sample-tool --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)')"
echo "Deployed MCP Tool URL: ${TOOL_URL}"

echo "[2/5] Registering MCP tool service in regional Agent Registry..."
envsubst < "${REPO_ROOT}/config/sample-tool-registry-spec.json" > /tmp/sample-tool-registry-spec.rendered.json
curl -s -X POST "https://agentregistry.googleapis.com/v1alpha/projects/${PROJECT_ID}/locations/${REGION}/services?serviceId=agents-everywhere-sample-tool" \
  -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
  -H "Content-Type: application/json" \
  -H "X-Goog-User-Project: ${PROJECT_ID}" \
  -d @/tmp/sample-tool-registry-spec.rendered.json

echo "[3/5] Deploying ADK Agent (${AGENT_NAME}) to Vertex AI Agent Runtime with Workload Identity..."
pushd "${REPO_ROOT}/src/agents/hello_agent" >/dev/null
agents-cli deploy \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --agent-identity \
  --no-confirm-project
popd >/dev/null

export INSTANCE_ID="$(curl -s -X GET "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines" \
  -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
  -H "X-Goog-User-Project: ${PROJECT_ID}" | jq -r '.reasoningEngines[]? | select(.displayName == "'"${AGENT_NAME}"'" or .displayName == "'"${AGENT_NAME//-/_}"'") | .name' | awk -F'/' '{print $NF}' | head -n 1)"

echo "Deployed Agent Runtime Instance ID: ${INSTANCE_ID}"

echo "[4/5] Attaching zero-trust Agent Gateway (gateway-egress) to Agent Runtime..."
export ENV_CONFIG='[{"name":"GOOGLE_API_ENABLE_RUNTIME_BOUND_TOKEN","value":"false"},{"name":"GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES","value":"false"}]'
export PACKAGE_SPEC="$(curl -s -X GET "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${INSTANCE_ID}" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "X-Goog-User-Project: ${PROJECT_ID}" | jq -c '.spec.packageSpec // empty')"

if [[ -n "${PACKAGE_SPEC}" && "${PACKAGE_SPEC}" != "null" ]]; then
  export UPDATE_MASK="spec.deploymentSpec.agentGatewayConfig,spec.deploymentSpec.env,spec.packageSpec"
  export PATCH_PAYLOAD="{\"spec\": {\"packageSpec\": ${PACKAGE_SPEC}, \"deploymentSpec\": {\"agentGatewayConfig\": {\"agentToAnywhereConfig\": {\"agentGateway\": \"projects/${PROJECT_ID}/locations/${REGION}/agentGateways/gateway-egress\"}}, \"env\": ${ENV_CONFIG}}}}"
else
  export UPDATE_MASK="spec.deploymentSpec.agentGatewayConfig,spec.deploymentSpec.env"
  export PATCH_PAYLOAD="{\"spec\": {\"deploymentSpec\": {\"agentGatewayConfig\": {\"agentToAnywhereConfig\": {\"agentGateway\": \"projects/${PROJECT_ID}/locations/${REGION}/agentGateways/gateway-egress\"}}, \"env\": ${ENV_CONFIG}}}}"
fi

curl -i -X PATCH "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${INSTANCE_ID}?updateMask=${UPDATE_MASK}" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -H "X-Goog-User-Project: ${PROJECT_ID}" \
  -d "${PATCH_PAYLOAD}"

echo "[5/5] Granting discovery permissions and registering ${AGENT_NAME} in Agent Registry..."
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="principalSet://agents.global.org-${ORGANIZATION_ID}.system.id.goog/attribute.platformContainer/aiplatform/projects/${PROJECT_NUMBER}" \
  --role="roles/browser" --quiet

gcloud alpha agent-registry services create "${AGENT_NAME}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --display-name="${AGENT_NAME}" \
  --description="${AGENT_NAME} ADK Agent managed by REST framework." \
  --agent-spec-type=no-spec \
  --interfaces="url=https://${REGION}-aiplatform.googleapis.com/reasoningEngines/v1/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${INSTANCE_ID}/api,protocolBinding=HTTP_JSON"
