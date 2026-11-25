#!/usr/bin/env bash
# Deploy one agent to Agent Runtime and register it with Gemini Enterprise.
#
#   scripts/deploy.sh <biocompass|paperbanana|argus> [--no-register] [--async]
#
# Runs the shared Cloud Build pipeline (shared/cloudbuild.yaml) from the repo
# root as the deployer service account:
#   Terraform (Reasoning Engine + buckets + IAM)  →  agents-cli deploy  →
#   agents-cli publish gemini-enterprise
#
# Idempotent: re-running updates the same Reasoning Engine and GE registration.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_bin gcloud
[[ $# -ge 1 ]] || die "Usage: scripts/deploy.sh <biocompass|paperbanana|argus> [--no-register] [--async]"

AGENT="$1"; shift
REGISTER=1; ASYNC=0
for arg in "$@"; do
  case "$arg" in
    --no-register) REGISTER=0 ;;
    --async)       ASYNC=1 ;;
    *) die "Unknown flag: $arg" ;;
  esac
done

AGENT_DIR="$(agent_dir "$AGENT")"
load_env
check_gcloud_auth

# ---- per-agent runtime environment variables -------------------------------
# Semicolon-separated KEY=VALUE pairs (no commas – Cloud Build substitution rule).
#
# COMMON_ENV applies to every agent: when Gemini Enterprise invokes the agent it
# forwards the end user's credential; without this flag the GenAI client and the
# GCS telemetry uploader try to use that token for Vertex AI / GCS and fail with
# "401 UNAUTHENTICATED". Setting it to false makes them use the Agent Identity.
COMMON_ENV="GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=false"
case "$AGENT" in
  biocompass)
    ENV_VARS="$COMMON_ENV"
    [[ -n "${BIOCOMPASS_EXTRA_ENV:-}" ]] && ENV_VARS="${ENV_VARS};${BIOCOMPASS_EXTRA_ENV}"
    ;;
  paperbanana)
    ENV_VARS="$COMMON_ENV"
    [[ -n "${PAPERBANANA_EXTRA_ENV:-}" ]] && ENV_VARS="${ENV_VARS};${PAPERBANANA_EXTRA_ENV}"
    ;;
  argus)
    : "${EDGAR_USER_AGENT:?EDGAR_USER_AGENT must be set in .env for Argus (SEC EDGAR policy)}"
    [[ "$EDGAR_USER_AGENT" == *,* ]] && die "EDGAR_USER_AGENT must not contain commas."
    ENV_VARS="${COMMON_ENV};EDGAR_USER_AGENT=${EDGAR_USER_AGENT};AGENT_REGISTRY_LOCATION=global"
    [[ -n "${ARGUS_EXTRA_ENV:-}" ]] && ENV_VARS="${ENV_VARS};${ARGUS_EXTRA_ENV}"
    if [[ "${SKIP_SKILLS_SYNC:-0}" != "1" ]]; then
      info "Argus prerequisite: syncing Science Skills to Agent Registry"
      "$REPO_ROOT/scripts/sync_science_skills.sh"
    fi
    ;;
esac

GE_ARG=""
if [[ "$REGISTER" == "1" ]]; then
  [[ -n "$GE_APP_ID" ]] || die "GE_APP_ID is empty. Run scripts/bootstrap.sh or set it in .env (or pass --no-register)."
  GE_ARG="$GE_APP_ID"
fi

# ---- submit --------------------------------------------------------------------
# '^|^' switches the substitution delimiter to '|' so values may contain ';', '=' and spaces.
SUBS="^|^_AGENT_DIR=${AGENT_DIR}|_REGION=${REGION}|_TF_STATE_BUCKET=${TF_STATE_BUCKET}|_GEMINI_ENTERPRISE_APP_ID=${GE_ARG}|_ENV_VARS=${ENV_VARS}"

info "Deploying $AGENT ($AGENT_DIR) → project=$PROJECT_ID region=$REGION"
[[ "$REGISTER" == "1" ]] && info "Will register with GE app: $GE_APP_ID" || warn "Skipping GE registration (--no-register)"
echo "   env vars: ${ENV_VARS:-<none>}"

ASYNC_FLAG=()
[[ "$ASYNC" == "1" ]] && ASYNC_FLAG=(--async)

cd "$REPO_ROOT"
gcloud builds submit . \
  --config=shared/cloudbuild.yaml \
  --substitutions="$SUBS" \
  --service-account="projects/${PROJECT_ID}/serviceAccounts/${DEPLOYER_SA_EMAIL}" \
  --project="$PROJECT_ID" \
  --timeout=1800s \
  "${ASYNC_FLAG[@]}"

if [[ "$ASYNC" == "1" ]]; then
  ok "Build submitted. Follow it with: gcloud builds list --project=$PROJECT_ID --limit=3"
else
  ok "$AGENT deployed. Verify with: scripts/verify.sh $AGENT"
fi
