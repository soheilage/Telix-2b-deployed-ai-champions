#!/usr/bin/env bash
# Deploy all three agents sequentially (safer than parallel: they share
# project-level IAM and the Terraform state bucket).
#
#   scripts/deploy_all.sh [--no-register]

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
for a in biocompass paperbanana argus; do
  info "──────── $a ────────"
  "$REPO_ROOT/scripts/deploy.sh" "$a" "$@"
done
ok "All agents deployed. Run: scripts/verify.sh all"
