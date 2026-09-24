#!/bin/bash
# Provisions the Redshift-side schema + group + GRANTs for one namespace, via
# the Redshift Data API - no direct network path to the cluster is needed
# from CI/local, same reasoning as mwaa_s3_bootstrap.sh's use of the AWS CLI
# for S3 instead of a direct network connection.
#
# Does NOT create the per-namespace DB user (<namespace>_mwaa) - that's
# created lazily by redshift:GetClusterCredentials's AutoCreate=true on
# first real use (see redshift/README.md). This script only provisions
# what GetClusterCredentials itself never creates: the schema, the group,
# and the group's schema GRANTs.
#
# Expects CLUSTER_ID, DATABASE, SECRET_ARN, REGION, NAMESPACE, ROLE_ARN as
# env vars, set via the provisioner's `environment` block (see
# terraform/mwaa/redshift_namespaces.tf).
set -euo pipefail

# Assume the same role as the AWS provider so redshift-data calls use the
# same identity - local-exec provisioners don't inherit the provider
# block's assumed role, only its own ambient credentials. See
# mwaa_s3_bootstrap.sh for the same pattern.
creds=$(aws sts assume-role \
  --role-arn "$ROLE_ARN" \
  --role-session-name "TerraformRedshiftNamespaceBootstrap" \
  --duration-seconds 900 \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
  --output text)
export AWS_ACCESS_KEY_ID=$(echo "$creds" | awk '{print $1}')
export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | awk '{print $2}')
export AWS_SESSION_TOKEN=$(echo "$creds" | awk '{print $3}')

# Polls a Data API statement to completion. Fails loudly on FAILED/ABORTED.
wait_for_statement() {
  local id="$1" status
  while :; do
    status=$(aws redshift-data describe-statement --id "$id" --region "$REGION" \
      --query Status --output text)
    case "$status" in
      FINISHED) return 0 ;;
      FAILED | ABORTED)
        echo "Statement $id $status:" >&2
        aws redshift-data describe-statement --id "$id" --region "$REGION" \
          --query Error --output text >&2
        return 1
        ;;
    esac
    sleep 2
  done
}

# Runs $1 to completion, prints the statement id (for statement_has_rows).
run_sql() {
  local id
  id=$(aws redshift-data execute-statement \
    --cluster-identifier "$CLUSTER_ID" \
    --database "$DATABASE" \
    --secret-arn "$SECRET_ARN" \
    --region "$REGION" \
    --sql "$1" \
    --query Id --output text)
  wait_for_statement "$id"
  echo "$id"
}

# True if a previous run_sql (a SELECT) returned at least one row.
statement_has_rows() {
  local rows
  rows=$(aws redshift-data get-statement-result --id "$1" --region "$REGION" \
    --query 'length(Records)' --output text)
  [ "$rows" -gt 0 ]
}

# CREATE SCHEMA IF NOT EXISTS is supported directly by Redshift.
run_sql "CREATE SCHEMA IF NOT EXISTS \"$NAMESPACE\";" >/dev/null
echo "  Schema ensured: $NAMESPACE"

# Redshift has no CREATE GROUP IF NOT EXISTS (and no DO/PL-pgSQL blocks to
# fake one) - check pg_group first.
group="${NAMESPACE}_group"
check_id=$(run_sql "SELECT 1 FROM pg_group WHERE groname = '$group';")
if statement_has_rows "$check_id"; then
  echo "  Group already exists: $group"
else
  run_sql "CREATE GROUP \"$group\";" >/dev/null
  echo "  Group created: $group"
fi

# Idempotent: re-granting the same privileges is a no-op.
run_sql "GRANT USAGE, CREATE ON SCHEMA \"$NAMESPACE\" TO GROUP \"$group\";" >/dev/null
echo "  Granted USAGE, CREATE on schema \"$NAMESPACE\" to group \"$group\""

# Read-only access to other, already-existing schemas (spec.additional_schemas
# - see redshift/README.md), comma-separated in $ADDITIONAL_SCHEMAS. Unlike
# NAMESPACE above, these are never created here - only GoldenGate CDC or
# another namespace's own bootstrap owns them. Re-run whenever a new table
# lands in one, since this only grants against tables that exist right now.
#
# A missing schema fails the run rather than being skipped: a skipped run
# still completes, so terraform_data records it as done and nothing re-runs
# it when the schema appears later - the grant would silently never happen.
# Entries are declared per environment (redshift/namespaces/*.yaml), so a
# schema that only exists in some environments is simply not listed in the
# others.
IFS=',' read -ra additional_schemas <<<"${ADDITIONAL_SCHEMAS:-}"
for schema in "${additional_schemas[@]}"; do
  [ -z "$schema" ] && continue
  check_id=$(run_sql "SELECT 1 FROM pg_namespace WHERE nspname = '$schema';")
  if ! statement_has_rows "$check_id"; then
    echo "  ERROR: additional schema \"$schema\" does not exist (namespace \"$NAMESPACE\" does not own it, so this script cannot create it)" >&2
    exit 1
  fi
  run_sql "GRANT USAGE ON SCHEMA \"$schema\" TO GROUP \"$group\";" >/dev/null
  run_sql "GRANT SELECT ON ALL TABLES IN SCHEMA \"$schema\" TO GROUP \"$group\";" >/dev/null
  echo "  Granted USAGE, SELECT on schema \"$schema\" to group \"$group\""
done

# Read-write access to schemas some other principal owns
# (spec.writable_schemas), comma-separated in $WRITABLE_SCHEMAS. Same
# never-created-here rule as ADDITIONAL_SCHEMAS above; the difference is
# CREATE on the schema plus DML and TRUNCATE on its tables (DELETE doesn't
# imply TRUNCATE, which dbt seed needs), for a namespace that must write into
# a schema it doesn't own.
#
# ALTER DEFAULT PRIVILEGES is set FOR the schema's owner, so tables that
# owner creates *later* are writable without a re-apply. ADDITIONAL_SCHEMAS
# above has no equivalent and so does need re-running - see redshift/README.md.
IFS=',' read -ra writable_schemas <<<"${WRITABLE_SCHEMAS:-}"
for schema in "${writable_schemas[@]}"; do
  [ -z "$schema" ] && continue
  owner_id=$(run_sql "SELECT u.usename FROM pg_namespace n JOIN pg_user u ON u.usesysid = n.nspowner WHERE n.nspname = '$schema';")
  if ! statement_has_rows "$owner_id"; then
    echo "  ERROR: writable schema \"$schema\" does not exist (namespace \"$NAMESPACE\" does not own it, so this script cannot create it)" >&2
    exit 1
  fi
  owner=$(aws redshift-data get-statement-result --id "$owner_id" --region "$REGION" \
    --query 'Records[0][0].stringValue' --output text)
  run_sql "GRANT USAGE, CREATE ON SCHEMA \"$schema\" TO GROUP \"$group\";" >/dev/null
  run_sql "GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA \"$schema\" TO GROUP \"$group\";" >/dev/null
  run_sql "ALTER DEFAULT PRIVILEGES FOR USER \"$owner\" IN SCHEMA \"$schema\" GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON TABLES TO GROUP \"$group\";" >/dev/null
  echo "  Granted USAGE, CREATE + DML/TRUNCATE on schema \"$schema\" (owned by $owner) to group \"$group\""
done

# Databases in which this namespace may create its own schemas
# (spec.writable_databases), comma-separated in $WRITABLE_DATABASES. This is
# what lets a dbt project run CREATE SCHEMA for names that aren't known at
# apply time: the namespace owns each schema it creates, so it gets full
# DDL/DML inside without any further grant, and still gets nothing on
# schemas other teams already own.
#
# GRANT ... ON DATABASE updates the cluster-wide catalog, so every one of
# these runs over this same connection to $DATABASE - confirmed against the
# dev cluster; no per-database connection is needed.
IFS=',' read -ra writable_databases <<<"${WRITABLE_DATABASES:-}"
for db in "${writable_databases[@]}"; do
  [ -z "$db" ] && continue
  check_id=$(run_sql "SELECT 1 FROM pg_database WHERE datname = '$db';")
  if ! statement_has_rows "$check_id"; then
    echo "  ERROR: database \"$db\" does not exist (writable_databases only grants against databases, it never creates one)" >&2
    exit 1
  fi
  run_sql "GRANT CREATE ON DATABASE \"$db\" TO GROUP \"$group\";" >/dev/null
  echo "  Granted CREATE on database \"$db\" to group \"$group\""
done
