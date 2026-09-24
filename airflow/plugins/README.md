# MWAA Shared Plugins

The platform team manages shared Airflow plugins distributed to all MWAA namespaces via `plugins/plugins.zip` uploaded to the MWAA S3 bucket.

**This directory is the exception now, not the default location for new plugin code.** It holds only `airflow_local_settings.py` (the cluster policy - namespace-scoped `dag_id`/`access_control`/`aws_conn_id`), which has to live here for MWAA to load it. Everything else - `edp_dbt`, `edp_secrets`, and any future namespace-scoped plugin - lives under `airflow/dags/` instead: see `airflow/dags/README.md` for the general pattern and why (short version: `dags/` syncs in ~1 minute, `plugins.zip` needs a 20-30 minute environment update, and that's true whether or not your plugin needs process isolation).

## Adding or Updating Plugins

1. Add plugin files to this `airflow/plugins/` directory.
2. Commit and push. `terraform apply` (via CI or manually) automatically builds `plugins.zip` from this directory (excluding `README.md`) and uploads it to `s3://<bucket>/plugins/plugins.zip`.
3. The new `plugins.zip` takes effect on the next **MWAA environment update or restart** — typically 20-30 minutes, during which every namespace's workers restart.

The `terraform_data.mwaa_s3_bootstrap` resource tracks the content hash of every file in this directory - any addition or modification triggers a replace, which rebuilds and re-uploads the zip on the next apply.

> **`plugins.zip` is not hot-reloaded.** Unlike the `dags/` prefix — which MWAA syncs to workers continuously, so DAG edits (and anything else living under `dags/`, including `edp_dbt`/`edp_secrets` and their dependencies) appear within a minute or so — `plugins.zip` and `startup.sh` are read only when the environment starts. Uploading a new object version does not by itself deploy it. Budget an environment update for every change here, and put new plugin code in `airflow/dags/` instead - see `airflow/dags/README.md`.

## Version Pinning

By default, `plugins_s3_object_version = null` in `terraform/mwaa.tf`, which means MWAA uses the latest object version on each environment restart.

To pin a specific version:

1. Retrieve the version ID:

   ```bash
   aws s3api list-object-versions \
     --bucket chedaws-edp-mwaa-<env>-<account_id>-ap-southeast-2 \
     --prefix plugins/plugins.zip \
     --query 'Versions[?IsLatest==`true`].VersionId' \
     --output text
   ```

2. Set `plugins_s3_object_version = "<version_id>"` in `aws_mwaa_environment.airflow` in `terraform/mwaa.tf`.
3. Run `terraform apply` to apply the pin.

## Backwards Compatibility Policy

- **Additive changes** (new operators, hooks, or utility functions): safe to release immediately.
- **Breaking changes** (removed or renamed plugin APIs): coordinate with all namespace teams before release; provide a deprecation notice at least one sprint in advance.
- Version pinning via `plugins_s3_object_version` allows individual environments to remain on a known-good version while other environments upgrade.
