#!/usr/bin/env bash
# Decides whether a Terraform stack can be planned yet: every stack it depends
# on (reads through terraform_remote_state, or otherwise needs to exist - e.g.
# rds looks up a KMS alias that core creates) must already be deployed in this
# environment, i.e. have applied state with at least one output.
#
# Without this, a brand-new environment can't get past its first plan job:
# every stack is planned before anything is applied, so a stack reading
# core's outputs fails on a core that has no state yet. With it, a new
# environment fills in over successive pipeline runs - core first, then the
# stacks that only need core, then the ones that also need redshift.
#
# Usage: tf-upstreams-deployed.sh <stack-name> <environment> <upstream-dir>...
#   Initializes and selects the workspace in each upstream dir itself (init
#   is cheap here - the provider cache is baked into the image, no network
#   involved) rather than assuming an earlier step in the same job already
#   did so: an upstream's own Terraform Init is skipped whenever ITS plan
#   is (see tf-deploy.yaml's own comment on prepare's plan_<stack> outputs),
#   which is unrelated to whether something else needs to read its output.
#   No -or-create on the workspace select, unlike every stack's own plan-
#   time init - a workspace that doesn't exist yet genuinely means this
#   upstream isn't deployed in this environment, which is exactly the
#   "missing" case below, not something to paper over.
#
# Writes ready=true|false to $GITHUB_OUTPUT, and a notice naming what's
# missing when it skips.
set -euo pipefail

stack="${1:?stack name}"
environment="${2:?environment}"
shift 2

missing=()
for dir in "$@"; do
  if ! terraform -chdir="$dir" init -input=false >/dev/null 2>&1; then
    missing+=("$dir")
    continue
  fi
  if ! terraform -chdir="$dir" workspace select "$environment" >/dev/null 2>&1; then
    missing+=("$dir")
    continue
  fi
  # `terraform output -json` prints sensitive outputs in plaintext - keep it
  # in this variable and only ever test it, never echo it.
  if ! outputs=$(terraform -chdir="$dir" output -json 2>/dev/null); then
    missing+=("$dir")
  elif [ "$(printf '%s' "$outputs" | tr -d '[:space:]')" = "{}" ]; then
    missing+=("$dir")
  fi
done
unset outputs

if [ "${#missing[@]}" -eq 0 ]; then
  echo "ready=true" >>"$GITHUB_OUTPUT"
  echo "$stack: all upstream stacks are deployed"
else
  echo "ready=false" >>"$GITHUB_OUTPUT"
  echo "::notice title=Skipped ${stack} plan::Not deployed in this environment yet: ${missing[*]}. ${stack} depends on it, so its plan and apply are skipped this run - re-run the pipeline once it has been applied."
fi
