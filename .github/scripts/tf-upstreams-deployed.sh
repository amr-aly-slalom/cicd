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
# Usage: tf-upstreams-deployed.sh <stack-name> <upstream-dir>...
#   Each upstream dir is expected to have been `terraform init`-ed with the
#   target workspace selected by an earlier step in the same job. An upstream
#   that wasn't - because its own plan was skipped for the same reason -
#   counts as not deployed.
#
# Writes ready=true|false to $GITHUB_OUTPUT, and a notice naming what's
# missing when it skips.
set -euo pipefail

stack="${1:?stack name}"
shift

missing=()
for dir in "$@"; do
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
