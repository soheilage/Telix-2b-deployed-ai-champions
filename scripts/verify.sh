#!/usr/bin/env bash
# Verify that an agent is deployed on Agent Runtime and registered in the
# Gemini Enterprise app; optionally send it a smoke-test prompt.
#
#   scripts/verify.sh <biocompass|paperbanana|argus> [--smoke ["custom prompt"]]
#
# Checks: Reasoning Engine exists · required runtime env var present ·
# registered in the GE app · (--smoke) answers through Gemini Enterprise
# (the same path as the GE UI) and directly through Agent Runtime.
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

  # Deterministic guard for the most common GE failure (401 on model calls).
  info "[$agent] Runtime env check"
  local flag
  flag="$(gapi_get "https://${REGION}-aiplatform.googleapis.com/v1/${engine}" | python3 -c '
import sys, json
d = json.load(sys.stdin)
env = d.get("spec", {}).get("deploymentSpec", {}).get("env", [])
print(next((e.get("value") for e in env if e.get("name") == "GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES"), "MISSING"))')"
  if [[ "$flag" == "false" ]]; then
    ok "GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=false"
  else
    warn "GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES is '$flag' – the agent will fail with 401 when called from the GE UI. Redeploy with scripts/deploy.sh $agent"
    return 1
  fi

  local ge_agent=""
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
      ge_agent="$(echo "$reg" | cut -f1)"
      ok "registered in GE as '$(echo "$reg" | cut -f2)'  [$(echo "$reg" | cut -f3)]"
      echo "   $ge_agent"
    else
      warn "not registered in GE app $GE_APP_ID – run: scripts/deploy.sh $agent"
      return 1
    fi
  else
    warn "GE_APP_ID not set – skipping registration check"
  fi

  if [[ "$SMOKE" == "1" ]]; then
    # 1) Through Gemini Enterprise itself (same path as the GE UI: GE → Agent
    #    Runtime with the end-user credential). This is the test that matters.
    if [[ -n "$ge_agent" ]]; then
      local loc; loc="$(ge_location "$GE_APP_ID")"
      info "[$agent] Smoke test via Gemini Enterprise (streamAssist)"
      local reply
      reply="$(curl -sS -X POST \
        -H "Authorization: Bearer $(gcloud auth print-access-token)" \
        -H "X-Goog-User-Project: ${PROJECT_ID}" -H "Content-Type: application/json" \
        "$(de_endpoint "$loc")/v1alpha/${GE_APP_ID}/assistants/default_assistant:streamAssist" \
        -d "{\"query\":{\"text\":\"Reply with exactly the two words: AGENT OK\"},\"agentsConfig\":{\"agent\":\"${ge_agent}\"}}" \
        | python3 -c '
import sys, json
try:
    items = json.load(sys.stdin)
except Exception as e:
    print("PARSE_ERROR"); sys.exit()
items = items if isinstance(items, list) else [items]
out = []
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == "text" and isinstance(v, str): out.append(v)
            walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(items)
err = next((i["error"] for i in items if "error" in i), None)
print(("ERROR " + json.dumps(err)) if err else " ".join(out).strip())')"
      if [[ "$reply" == *"AGENT OK"* ]]; then
        ok "GE path works: \"$reply\""
      else
        warn "GE path failed. Reply: ${reply:-<empty>}"
        warn "Check: gcloud logging read 'resource.type=\"aiplatform.googleapis.com/ReasoningEngine\" AND resource.labels.reasoning_engine_id=\"${engine##*/}\" AND severity>=ERROR' --project=$PROJECT_ID --limit=20"
        return 1
      fi
    fi

    # 2) Directly against Agent Runtime with your own credential (functional check).
    local p="${PROMPT:-$(default_prompt "$agent")}"
    info "[$agent] Smoke test via Agent Runtime: \"$p\""
    local url="https://${REGION}-aiplatform.googleapis.com/v1/${engine}"
    ( cd "$REPO_ROOT/$(agent_dir "$agent")" && \
      uvx google-agents-cli@1.2.1 run --url "$url" --mode adk "$p" ) || { warn "Agent Runtime smoke test failed for $agent"; return 1; }
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
