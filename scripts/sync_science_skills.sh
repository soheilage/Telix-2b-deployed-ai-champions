#!/usr/bin/env bash
# Argus prerequisite: publish Google DeepMind Science Skills (openFDA, ChEMBL,
# ClinicalTrials.gov, Open Targets, UniProt, PubMed, Europe PMC …) to Agent
# Registry in your project.  Argus loads them at runtime via SkillToolset.
#
#   scripts/sync_science_skills.sh [--dry-run|--force|--activate-all]
#
# Idempotent: already up-to-date skills are skipped.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_bin gcloud uv git
load_env
check_gcloud_auth

# gcloud alpha is needed for `gcloud alpha agent-registry`.
if ! gcloud alpha --help >/dev/null 2>&1; then
  info "Installing gcloud alpha components"
  gcloud components install alpha --quiet
fi

info "Syncing Science Skills → Agent Registry (project=$PROJECT_ID, location=global)"
cd "$REPO_ROOT/argus-agent"
SYNC=(uv run ../shared/scripts/sync_skills_to_registry.py --project "$PROJECT_ID" --location global)

if "${SYNC[@]}" "$@"; then
  ok "Science Skills synced"
  exit 0
fi

# Newly uploaded revisions cannot be activated until Agent Registry's security
# scan finishes ("pending scan results when scanning policy is ENABLED_BLOCKING").
# The upstream script retries only briefly, so give the scan time and activate
# whatever is still in draft state.
for attempt in 1 2 3 4 5; do
  warn "Some skills could not be activated yet (scan pending). Retry $attempt/5 in 60s…"
  sleep 60
  if "${SYNC[@]}" --activate-all; then
    ok "Science Skills synced and activated"
    exit 0
  fi
done
die "Skills still pending activation. Re-run later: scripts/sync_science_skills.sh --activate-all"
