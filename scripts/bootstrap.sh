#!/usr/bin/env bash
# One-time project bootstrap for all agents (idempotent – safe to re-run).
#
#   scripts/bootstrap.sh
#
# What it does:
#   1. Enables the required Google Cloud APIs.
#   2. Creates the Cloud Build deployer service account and grants its roles.
#   3. Creates the GCS bucket for Terraform remote state (versioned).
#   4. Lets Gemini Enterprise invoke Agent Runtime (Discovery Engine service agent IAM).
#   5. Auto-detects the Gemini Enterprise app and stores GE_APP_ID in .env.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_bin gcloud curl python3
load_env
check_gcloud_auth

# ---------------------------------------------------------------------------
info "1/5 Enabling APIs"
gcloud services enable \
  aiplatform.googleapis.com \
  agentregistry.googleapis.com \
  cloudbuild.googleapis.com \
  cloudresourcemanager.googleapis.com \
  discoveryengine.googleapis.com \
  iam.googleapis.com \
  logging.googleapis.com \
  secretmanager.googleapis.com \
  serviceusage.googleapis.com \
  storage.googleapis.com \
  bigquery.googleapis.com \
  bigqueryconnection.googleapis.com \
  --project="$PROJECT_ID" --quiet
ok "APIs enabled"

# ---------------------------------------------------------------------------
info "2/5 Deployer service account: $DEPLOYER_SA_EMAIL"
if ! gcloud iam service-accounts describe "$DEPLOYER_SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$DEPLOYER_SA_NAME" \
    --display-name="Gemini Enterprise Agent Deployer" \
    --description="Cloud Build identity that runs Terraform + agents-cli for the Telix GE agents" \
    --project="$PROJECT_ID"
  ok "created"
else
  ok "already exists"
fi

# Roles from the upstream pipeline README (Agent Platform admin, storage,
# IAM for agent identity, GE registration, logging, BigQuery for BioCompass,
# Secret Manager, Service Usage).
DEPLOYER_ROLES=(
  roles/aiplatform.admin
  roles/storage.objectAdmin
  roles/storage.admin
  roles/resourcemanager.projectIamAdmin
  roles/discoveryengine.agentspaceAdmin
  roles/logging.logWriter
  roles/bigquery.admin
  roles/secretmanager.admin
  roles/serviceusage.serviceUsageAdmin
  roles/iam.serviceAccountUser
)
for role in "${DEPLOYER_ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${DEPLOYER_SA_EMAIL}" --role="$role" \
    --condition=None --quiet >/dev/null
  echo "   • $role"
done
# Let the caller (you) submit builds that run as the deployer SA.
CALLER="$(gcloud auth list --filter=status:ACTIVE --format='value(account)')"
gcloud iam service-accounts add-iam-policy-binding "$DEPLOYER_SA_EMAIL" \
  --member="user:${CALLER}" --role="roles/iam.serviceAccountUser" --project="$PROJECT_ID" --quiet >/dev/null || \
  warn "Could not grant serviceAccountUser to $CALLER on the deployer SA (fine if you are project Owner)."
ok "roles granted"

# ---------------------------------------------------------------------------
info "3/5 Terraform state bucket: gs://$TF_STATE_BUCKET"
if ! gcloud storage buckets describe "gs://$TF_STATE_BUCKET" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://$TF_STATE_BUCKET" \
    --project="$PROJECT_ID" --location="$REGION" \
    --uniform-bucket-level-access --public-access-prevention
  gcloud storage buckets update "gs://$TF_STATE_BUCKET" --versioning
  ok "created"
else
  ok "already exists"
fi
set_env_value TF_STATE_BUCKET "$TF_STATE_BUCKET"

# ---------------------------------------------------------------------------
info "4/5 Allow Gemini Enterprise to call Agent Runtime"
# Ensure the Discovery Engine service agent exists, then let it invoke
# Reasoning Engines (required for ADK-type registrations).
gcloud beta services identity create --service=discoveryengine.googleapis.com \
  --project="$PROJECT_ID" --quiet >/dev/null 2>&1 || true
DE_SA="service-${PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${DE_SA}" --role="roles/aiplatform.user" \
  --condition=None --quiet >/dev/null
ok "$DE_SA → roles/aiplatform.user"

# ---------------------------------------------------------------------------
info "5/5 Gemini Enterprise app"
if [[ -n "$GE_APP_ID" ]]; then
  ok "GE_APP_ID already set in .env: $GE_APP_ID"
else
  FOUND=()
  for loc in global us eu; do
    body="$(gapi_get "$(de_endpoint "$loc")/v1/projects/${PROJECT_ID}/locations/${loc}/collections/default_collection/engines" || true)"
    while IFS= read -r line; do [[ -n "$line" ]] && FOUND+=("$line"); done < <(
      printf '%s' "$body" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for e in d.get("engines", []):
    print(e["name"] + "\t" + e.get("displayName", ""))' )
  done
  case "${#FOUND[@]}" in
    0) warn "No Gemini Enterprise app found in $PROJECT_ID (global/us/eu)."
       warn "Create one: Console → Gemini Enterprise → Apps → Create app, then set GE_APP_ID in .env and re-run." ;;
    1) GE_APP_ID="${FOUND[0]%%$'\t'*}"
       set_env_value GE_APP_ID "$GE_APP_ID"
       ok "detected '${FOUND[0]#*$'\t'}' → GE_APP_ID=$GE_APP_ID (saved to .env)" ;;
    *) warn "Several Gemini Enterprise apps found – set GE_APP_ID in .env to one of:"
       printf '   %s\n' "${FOUND[@]}" ;;
  esac
fi

echo
ok "Bootstrap complete. Next: scripts/deploy.sh <biocompass|paperbanana|argus>"
