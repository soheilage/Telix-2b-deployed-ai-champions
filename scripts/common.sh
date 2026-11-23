#!/usr/bin/env bash
# Shared helpers for scripts/*.sh – source this file, do not run it.
# shellcheck shell=bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

# ---- colours ---------------------------------------------------------------
if [[ -t 1 ]]; then
  C_INFO=$'\e[1;34m'; C_OK=$'\e[1;32m'; C_WARN=$'\e[1;33m'; C_ERR=$'\e[1;31m'; C_END=$'\e[0m'
else
  C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_END=""
fi
info() { echo "${C_INFO}==>${C_END} $*"; }
ok()   { echo "${C_OK}✔${C_END} $*"; }
warn() { echo "${C_WARN}⚠${C_END} $*" >&2; }
die()  { echo "${C_ERR}✖${C_END} $*" >&2; exit 1; }

# ---- config ----------------------------------------------------------------
load_env() {
  [[ -f "$ENV_FILE" ]] || die "Missing $ENV_FILE. Run: cp .env.example .env  (then edit it)"
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a

  : "${PROJECT_ID:?PROJECT_ID must be set in .env}"
  : "${REGION:=us-central1}"
  : "${DEPLOYER_SA_NAME:=ge-agent-deployer}"
  : "${TF_STATE_BUCKET:=${PROJECT_ID}-agent-tfstate}"
  : "${GE_APP_ID:=}"

  PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' 2>/dev/null)" \
    || die "Cannot read project '$PROJECT_ID'. Check 'gcloud auth list' and that the project exists."
  DEPLOYER_SA_EMAIL="${DEPLOYER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
  export PROJECT_ID REGION PROJECT_NUMBER DEPLOYER_SA_NAME DEPLOYER_SA_EMAIL TF_STATE_BUCKET GE_APP_ID
}

require_bin() {
  for b in "$@"; do
    command -v "$b" >/dev/null 2>&1 || die "Required tool '$b' not found on PATH."
  done
}

check_gcloud_auth() {
  local acct
  acct="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
  [[ -n "$acct" ]] || die "No active gcloud account. Run: gcloud auth login"
  ok "gcloud account: $acct   project: $PROJECT_ID ($PROJECT_NUMBER)   region: $REGION"
}

# Map an agent short name to its directory and display name.
#   agent_dir biocompass -> biocompass-agent
agent_dir() {
  case "$1" in
    biocompass|paperbanana|argus) echo "$1-agent" ;;
    *) die "Unknown agent '$1'. Valid: biocompass | paperbanana | argus" ;;
  esac
}

# Discovery Engine REST base URL for a GE location (global | us | eu).
de_endpoint() {
  case "$1" in
    global) echo "https://discoveryengine.googleapis.com" ;;
    *)      echo "https://$1-discoveryengine.googleapis.com" ;;
  esac
}

# Extract the location segment from a GE app resource name.
ge_location() { echo "$1" | awk -F/ '{print $4}'; }

# Write/replace KEY=VALUE in .env (keeps the rest of the file intact).
set_env_value() {
  local key="$1" value="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    # Use a temp file to stay portable between GNU and BSD sed.
    local tmp; tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k {print k"="v; next} {print}' "$ENV_FILE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

# Authenticated GET against a Google API; prints the JSON body.
gapi_get() {
  curl -sS -H "Authorization: Bearer $(gcloud auth print-access-token)" \
       -H "X-Goog-User-Project: ${PROJECT_ID}" "$1"
}
