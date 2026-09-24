#!/bin/bash

set -euo pipefail

# Nothing to do here any more - edp_dbt's venv is now pre-built at
# `terraform apply` time and synced continuously via the dags/ prefix
# instead of being built on each worker at boot. See
# terraform/mwaa/scripts/mwaa_s3_bootstrap.sh's build_venv()/sync_venv()
# and airflow/dags/edp_dbt/README.md for why: a change to
# requirements.txt now takes effect within the dags/ sync window (~1 min)
# rather than a full ~20-30 min MWAA environment update, since startup.sh
# itself is one of the artifacts that only gets re-read on that slower
# cycle. Kept as a real, harmless script (not removed) because
# aws_mwaa_environment.airflow's startup_script_s3_object_version always
# points at something.
exit 0
