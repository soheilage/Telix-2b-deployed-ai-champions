#!/usr/bin/env bash
# Verify that an agent is deployed on Agent Runtime and registered in the
# Gemini Enterprise app; optionally send it a smoke-test prompt.
#
#   scripts/verify.sh <biocompass|paperbanana|argus> [--smoke ["custom prompt"]]
#   scripts/verify.sh all

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_bin gcloud curl python3
[[ $# -ge 1 ]] || die "Usage: scripts/verify.sh <biocompass|paperbanana|argus|all> [--smoke [prompt]]"

TARGET="$1"; shift
SMOKE=0; PROMPT=""
if [[ "${1:-}" == "--smoke" ]]; then SMOKE=1; PROMPT="${2:-}"; fi

load_env
check_gcloud_auth

# Display names come from each agent's terraform/main.tf.
display_name() {
  case "$1" in
    biocompass)  echo "BioCompass on Gemini Enterprise" ;;
    paperbanana) echo "PaperBanana on Gemini Enterprise" ;;
    argus)       echo "Argus — Life Sciences M&A Diligence" ;;
  esac
}
default_prompt() {
  case "$1" in
    biocompass)  echo "In two sentences, what is the mechanism of action of pembrolizumab? Cite one PubMed ID." ;;
    paperbanana) echo "Describe in 3 bullet points how you would turn a results table into a publication figure. Do not generate an image." ;;
    argus)       echo "In three sentences, what does Argus do and which data sources can it query?" ;;
  esac
}

verify_one() {
  local agent="$1" name; name="$(display_name "$agent")"
  echo
  info "[$agent] Agent Runtime (region $REGION)"
  local engines
  engines="$(gapi_get "https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines" \
    | python3 -c '
import sys, json
want = sys.argv[1]
d = json.load(sys.stdin)
for e in d.get("reasoningEngines", []):
    if e.get("displayName") == want:
        print(e["name"] + "\t" + e.get("updateTime", ""))' "$name")"
  if [[ -z "$engines" ]]; then
    warn "no Reasoning Engine named '$name' found"
    return 1
  fi
  local engine="${engines%%$'\t'*}"
  ok "Reasoning Engine: $engine (updated ${engines#*$'\t'})"

  if [[ -n "$GE_APP_ID" ]]; then
    local loc; loc="$(ge_location "$GE_APP_ID")"
    info "[$agent] Gemini Enterprise registration (app location $loc)"
    local reg
    reg="$(gapi_get "$(de_endpoint "$loc")/v1alpha/${GE_APP_ID}/assistants/default_assistant/agents" \
      | python3 -c '
import sys, json
engine = sys.argv[1]
d = json.load(sys.stdin)
for a in d.get("agents", []):
    re_ = a.get("adkAgentDefinition", {}).get("provisionedReasoningEngine", {}).get("reasoningEngine", "")
    if re_ == engine or re_.split("/")[-1] == engine.split("/")[-1]:
        print(a["name"] + "\t" + a.get("displayName", "") + "\t" + a.get("state", ""))' "$engine")"
    if [[ -n "$reg" ]]; then
      ok "registered in GE as '$(echo "$reg" | cut -f2)'  [$(echo "$reg" | cut -f3)]"
      echo "   $(echo "$reg" | cut -f1)"
    else
      warn "not registered in GE app $GE_APP_ID – run: scripts/deploy.sh $agent"
    fi
  else
    warn "GE_APP_ID not set – skipping registration check"
  fi

  if [[ "$SMOKE" == "1" ]]; then
    local p="${PROMPT:-$(default_prompt "$agent")}"
    info "[$agent] Smoke test: \"$p\""
    local url="https://${REGION}-aiplatform.googleapis.com/v1/${engine}"
    ( cd "$REPO_ROOT/$(agent_dir "$agent")" && \
      uvx google-agents-cli@1.2.1 run --url "$url" --mode adk "$p" ) || warn "smoke test failed for $agent"
  fi
}

STATUS=0
if [[ "$TARGET" == "all" ]]; then
  for a in biocompass paperbanana argus; do verify_one "$a" || STATUS=1; done
else
  agent_dir "$TARGET" >/dev/null
  verify_one "$TARGET" || STATUS=1
fi

echo
if [[ -n "$GE_APP_ID" ]]; then
  APP_ID="${GE_APP_ID##*/}"
  info "Open the app: https://console.cloud.google.com/gen-app-builder/locations/$(ge_location "$GE_APP_ID")/engines/${APP_ID}/agents?project=${PROJECT_ID}"
  info "End-user UI: Gemini Enterprise → your app → Agents gallery"
fi
exit $STATUS
