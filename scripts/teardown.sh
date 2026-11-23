#!/usr/bin/env bash
# Remove one agent: unregister it from Gemini Enterprise, then destroy its
# Terraform-managed infrastructure (Reasoning Engine, buckets, IAM) via Cloud Build.
#
#   scripts/teardown.sh <biocompass|paperbanana|argus>

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_bin gcloud curl python3
[[ $# -eq 1 ]] || die "Usage: scripts/teardown.sh <biocompass|paperbanana|argus>"
AGENT="$1"; AGENT_DIR="$(agent_dir "$AGENT")"
load_env
check_gcloud_auth

read -r -p "This deletes the '$AGENT' Reasoning Engine and its buckets in $PROJECT_ID. Type '$AGENT' to confirm: " ans
[[ "$ans" == "$AGENT" ]] || die "aborted"

# 1. Unregister from GE (best effort – match on the reasoning engine id in TF state).
if [[ -n "$GE_APP_ID" ]]; then
  loc="$(ge_location "$GE_APP_ID")"
  AGENT_ID_TOML="$(python3 -c 'import tomllib,sys; print(tomllib.load(open(sys.argv[1],"rb"))["project"]["name"])' "$REPO_ROOT/$AGENT_DIR/pyproject.toml")"
  ENGINE="$(gcloud storage cat "gs://${TF_STATE_BUCKET}/terraform/${AGENT_ID_TOML}/default.tfstate" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("outputs",{}).get("reasoning_engine_id",{}).get("value",""))' || true)"
  if [[ -n "$ENGINE" ]]; then
    for name in $(gapi_get "$(de_endpoint "$loc")/v1alpha/${GE_APP_ID}/assistants/default_assistant/agents" \
        | python3 -c '
import sys, json
eng = sys.argv[1]
for a in json.load(sys.stdin).get("agents", []):
    if a.get("adkAgentDefinition", {}).get("provisionedReasoningEngine", {}).get("reasoningEngine", "").split("/")[-1] == eng.split("/")[-1]:
        print(a["name"])' "$ENGINE"); do
      info "Unregistering $name"
      curl -sS -X DELETE -H "Authorization: Bearer $(gcloud auth print-access-token)" \
        -H "X-Goog-User-Project: ${PROJECT_ID}" "$(de_endpoint "$loc")/v1alpha/${name}" >/dev/null && ok "unregistered"
    done
  fi
fi

# 2. terraform destroy inside Cloud Build (same identity/state as deploy).
cd "$REPO_ROOT"
gcloud builds submit . \
  --config=shared/cloudbuild-destroy.yaml \
  --substitutions="^|^_AGENT_DIR=${AGENT_DIR}|_REGION=${REGION}|_TF_STATE_BUCKET=${TF_STATE_BUCKET}" \
  --service-account="projects/${PROJECT_ID}/serviceAccounts/${DEPLOYER_SA_EMAIL}" \
  --project="$PROJECT_ID"
ok "$AGENT infrastructure destroyed"
