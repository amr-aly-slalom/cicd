#!/bin/bash
# Uploads startup.sh, plugins.zip, the canary isolation marker, edp_dbt's
# venv, and dags/ to the MWAA S3 bucket. Invoked by the local-exec
# provisioner on terraform_data.mwaa_s3_bootstrap (see terraform/mwaa.tf).
#
# Kept as its own file, not an inline heredoc in mwaa.tf: triggers_replace
# on that resource hashes this file directly, so an edit here forces the
# provisioner to re-run on the next apply. Editing unrelated resources in
# mwaa.tf does NOT touch this file, so it won't spuriously trigger a full
# MWAA environment update (~30 min) for changes that have nothing to do
# with the S3 bootstrap. See EDP-597: a fix to this script's logic once
# shipped invisibly because triggers_replace only hashed the script's
# *inputs* (startup.sh, plugins/**, dags/**), not the script itself - the
# empty-zip bug it introduced went undetected through a full apply cycle.
#
# Expects BUCKET, REGION, ROLE_ARN, KMS_KEY, DAGS_SRC, PLUGINS_SRC,
# STARTUP as env vars, set via the provisioner's `environment` block.
#
# Structured as function-defs-then-guarded-main so tests/test_build_plugins_zip.py
# can `source` this file (safe: only creates an empty scratch dir, makes no
# AWS calls) and call build_plugins_zip directly, without running main.
set -euo pipefail

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

s3_cp() {
  aws s3 cp "$1" "$2" --region "$REGION" --sse aws:kms --sse-kms-key-id "$KMS_KEY" --quiet
}

s3_cp_if_changed() {
  local src="$1" dest="$2"
  local bucket="${dest#s3://}" key local_hash remote_hash
  key="${bucket#*/}"
  bucket="${bucket%%/*}"
  echo "  Checking [$dest]..."
  local_hash=$(md5sum "$src" | awk '{print $1}')
  remote_hash=$(aws s3api head-object --bucket "$bucket" --key "$key" --region "$REGION" \
    --query 'Metadata.contentmd5' --output text 2>/dev/null || true)
  if [ "$remote_hash" = "$local_hash" ]; then
    echo "  Unchanged, skipping [$dest]."
    return 0
  fi
  aws s3 cp "$src" "$dest" --region "$REGION" --sse aws:kms --sse-kms-key-id "$KMS_KEY" \
    --metadata "contentmd5=$local_hash" --quiet
  echo "  Uploaded [$dest]."
}

# Builds wheels for $requirements' entire dependency closure at $out (both
# scratch paths - $out gets synced to its real S3 key by ensure_wheels()
# below, not read from here directly). CI has real PyPI access (unlike a
# worker - see airflow/dags/edp_dbt/README.md); this is where that access
# actually gets used - the worker-side venv build is always --no-index.
#
# `pip wheel`, not `pip download`, run under a real Python 3.12 (CI installs
# one via `uv venv` before `terraform apply`) - `pip wheel` has no
# --platform/--python-version/--abi to cross-target with, unlike `download`,
# so this only produces worker-compatible wheels if it's genuinely running
# on the same OS/arch/ABI the workers do (linux x86_64, cp312). --no-deps:
# $requirements already pins the full transitive closure directly, not just
# the packages a DAG author would think to list - so an unrelated upstream
# release can't change which wheels get built on its own.
#
# Deliberately NOT a pre-built venv (tried, and confirmed dead live): a venv
# built with `python3 -m venv` bakes the *building* machine's own Python
# installation path into pyvenv.cfg, and a worker doesn't have whatever the
# CI runner happens to have there ("No module named 'encodings'" trying to
# even start the copied interpreter). Wheels carry no such path - just a
# platform/ABI tag - so the worker-side venv (built by
# edp_dbt/operators.py's _resolve_local_venv(), not here) is always native
# to whatever machine actually builds it.
build_wheels() {
  local requirements="$1" out="$2"
  rm -rf "$out"
  python3 -m pip wheel --no-deps -r "$requirements" -w "$out"
}

# Syncs built wheels at $1 to the dags/ prefix at $2 (e.g.
# s3://bucket/dags/edp_dbt_wheels/) - continuous sync, no MWAA environment
# update needed to pick up a change, unlike plugins.zip/requirements.txt/
# startup.sh. --quiet suppresses the per-file upload/delete lines - CI has
# no use for that level of detail on a routine run.
sync_wheels() {
  local src="$1" dest="$2"
  aws s3 sync "$src/" "$dest" \
    --region "$REGION" \
    --sse aws:kms --sse-kms-key-id "$KMS_KEY" \
    --delete --quiet
}

# Rebuilds and syncs wheels only if $requirements has actually changed
# since the last apply - rebuilding needs a real `pip wheel` against live
# PyPI, not worth doing on every apply regardless of whether anything
# changed. The hash marker lives outside dags/ entirely (build-markers/,
# not synced to MWAA at all) - it's this script's own bookkeeping; the
# consuming operator fingerprints its own worker-local venv cache by
# hashing $requirements directly instead (already synced via dags/
# regardless of this function, so there's nothing extra to ship for it -
# see edp_dbt/operators.py's _resolve_local_venv()). Generic - dbt is the
# first consumer, not the only one.
ensure_wheels() {
  local name="$1" requirements="$2" dest="$3"
  local marker_key="build-markers/${name}.hash" local_hash remote_hash
  local_hash=$(md5sum "$requirements" | awk '{print $1}')
  remote_hash=$(aws s3api head-object --bucket "$BUCKET" --key "$marker_key" --region "$REGION" \
    --query 'Metadata.contentmd5' --output text 2>/dev/null || true)
  if [ "$local_hash" = "$remote_hash" ]; then
    echo "  [$name] requirements unchanged, skipping wheel rebuild."
    return 0
  fi

  echo "  [$name] requirements changed, rebuilding wheels..."
  local out="$SCRATCH/${name}_wheels"
  build_wheels "$requirements" "$out"
  sync_wheels "$out" "$dest"

  : > "$SCRATCH/${name}.hash-marker"
  aws s3 cp "$SCRATCH/${name}.hash-marker" "s3://$BUCKET/$marker_key" \
    --region "$REGION" --sse aws:kms --sse-kms-key-id "$KMS_KEY" \
    --metadata "contentmd5=$local_hash" --quiet
  echo "  [$name] wheels rebuilt and synced."
}

# Builds plugins.zip at $2 from the airflow/plugins/ tree at $1, excluding
# README.md, .gitkeep, test-only files, and locally-built __pycache__
# (running the tests leaves .pyc behind; shipping a developer's stale
# bytecode to every worker is at best pointless).
#
# Uses the zip CLI directly rather than reimplementing it in Python - zip
# is confirmed present on these runners. But zip's own directory-traversal
# order isn't guaranteed stable, and it stores each entry's real mtime, so
# the archive is built from a staged copy with every file re-stamped to a
# fixed mtime and added in sorted order. That determinism is required, not
# cosmetic: s3_cp_if_changed hashes these bytes to decide whether to
# re-upload, and a mtime-only difference from checkout timing isn't a real
# content change (see EDP-597 - this exact non-determinism once forced a
# spurious MWAA environment update on every apply). `cp -p` preserves the
# source files' real permissions into the staged copy, and zip preserves
# those into the archive by default - a from-scratch zip builder shipped
# without this once and broke every worker (see EDP-597).
build_plugins_zip() {
  local src="$1" dest="$2"
  local stage="$SCRATCH/plugins-stage"
  mkdir -p "$stage"

  while IFS= read -r -d '' rel; do
    mkdir -p "$stage/$(dirname "$rel")"
    cp -p "$src/$rel" "$stage/$rel"
  done < <(
    cd "$src" && find . -type f \
      ! -name "README.md" ! -name ".gitkeep" \
      ! -path "./tests/*" \
      ! -path "*/__pycache__/*" \
      -printf '%P\0'
  )

  find "$stage" -exec touch -d '1980-01-01 00:00:00' {} +

  ( cd "$stage" && find . -type f -printf '%P\n' | sort | zip -X -q "$dest" -@ )
}

main() {
  echo "MWAA S3 bootstrap starting..."

  # Assume the same role as the AWS provider so s3 cp uses the same identity.
  echo "  Assuming role [$ROLE_ARN]..."
  local creds
  creds=$(aws sts assume-role \
    --role-arn "$ROLE_ARN" \
    --role-session-name "TerraformMWAABootstrap" \
    --duration-seconds 900 \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text)
  export AWS_ACCESS_KEY_ID=$(echo "$creds" | awk '{print $1}')
  export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | awk '{print $2}')
  export AWS_SESSION_TOKEN=$(echo "$creds" | awk '{print $3}')
  echo "  Role [$ROLE_ARN] assumed."

  # startup.sh — no longer builds anything itself (see airflow/startup.sh);
  # kept as a real object because aws_mwaa_environment.airflow's
  # startup_script_s3_object_version always points at something.
  s3_cp_if_changed "$STARTUP" "s3://$BUCKET/startup/startup.sh"

  # plugins.zip
  build_plugins_zip "$PLUGINS_SRC" "$SCRATCH/plugins.zip"
  s3_cp_if_changed "$SCRATCH/plugins.zip" "s3://$BUCKET/plugins/plugins.zip"

  # edp_dbt's wheels — see ensure_wheels() above and airflow/dags/edp_dbt/README.md.
  ensure_wheels "edp_dbt" "$DAGS_SRC/edp_dbt/requirements.txt" "s3://$BUCKET/dags/edp_dbt_wheels/"

  # Canary isolation prefix marker — only needed once; idempotent.
  echo "  Checking [dags/canary_namespace_for_isolation_test/.keep]..."
  if ! aws s3 ls "s3://$BUCKET/dags/canary_namespace_for_isolation_test/.keep" \
      --region "$REGION" >/dev/null 2>&1; then
    : > "$SCRATCH/empty"
    s3_cp "$SCRATCH/empty" "s3://$BUCKET/dags/canary_namespace_for_isolation_test/.keep"
    echo "  Uploaded [dags/canary_namespace_for_isolation_test/.keep]."
  else
    echo "  Unchanged, skipping [dags/canary_namespace_for_isolation_test/.keep]."
  fi

  # DAGs — sync the whole dags/ tree (not just .py files - models, YAML
  # configs, etc. included); uploads new/changed, skips unchanged.
  # edp_dbt/tests/ excluded same as it was from plugins.zip pre-move - test
  # code (imports pytest, not present on any real environment) has no
  # business shipping anywhere real. __pycache__ excluded for the same
  # reason build_plugins_zip() already does - a developer's local test run
  # leaves bytecode behind that has nothing to do with a real content
  # change (see EDP-597 in this file's own header for why that distinction
  # matters beyond just tidiness).
  echo "  Syncing DAGs from [$DAGS_SRC] to [s3://$BUCKET/dags/]..."
  aws s3 sync "$DAGS_SRC/" "s3://$BUCKET/dags/" \
    --region "$REGION" \
    --sse aws:kms --sse-kms-key-id "$KMS_KEY" \
    --exclude "README.md" \
    --exclude "edp_dbt/tests/*" \
    --exclude "*__pycache__*"
  echo "  DAGs synced."

  echo "Bootstrap complete."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
