# First-time setup on a fresh clone is just:
#
#     make setup
#
# which needs only `uv` on PATH (https://docs.astral.sh/uv/). uv creates
# .venv/, fetches Python 3.12 if you don't have it, and installs the exact
# versions in uv.lock.

# Paths that are lint-clean and typechecked today. The rest of the repo's
# Python (lambda/*/handler.py, .github/scripts/*.py, airflow/dags/) has never
# been checked and does not pass yet; add paths here as they are cleaned up.
PY_LINT_PATHS := airflow/dags/edp_dbt airflow/dags/edp_secrets airflow/plugins/airflow_local_settings.py airflow/plugins/tests terraform/mwaa/scripts tests/post_deploy
PY_TEST_PATHS := airflow/dags/edp_dbt/tests airflow/dags/edp_secrets/tests airflow/plugins/tests terraform/mwaa/scripts/tests

# terraform_data.mwaa_s3_bootstrap's triggers_replace hashes every file under
# airflow/plugins/ via fileset() (see terraform/mwaa/mwaa.tf) - a stray
# __pycache__/*.pyc there from `make test` changes fileset()'s raw result,
# not just what gets hashed. CI plans and applies that resource in separate
# jobs against separate checkouts; if only the plan job's checkout has run
# tests, fileset() returns two different results for the same saved plan and
# `terraform apply` fails with "Inconsistent results for fileset()" (EDP-597).
export PYTHONDONTWRITEBYTECODE := 1

TF_DIR := terraform

TOOLS_DIR := $(CURDIR)/.tools

TFLINT_VERSION := v0.52.0

TRIVY_VERSION := 0.74.0
TRIVY_IMAGE := aquasec/trivy:$(TRIVY_VERSION)

.PHONY: setup check precommit py-check lint typecheck test post-deploy-test fmt \
        validate validate-kafka-schema validate-kafka-topics-producers \
        validate-kafka-topics-consumers validate-kafka-topics-connect \
        validate-s3-registrations \
        validate-redshift-registrations validate-s3tables-yaml \
        validate-lakeformation-yaml \
        tf-check tf-fmt tf-lint tf-trivy tf-tools clean

## setup: create .venv, install pinned dev dependencies, install tflint, and
## wire up the pre-commit hook (.githooks/pre-commit runs `make precommit`
## before each commit)
setup: tf-tools
	uv sync
	git config core.hooksPath .githooks
	chmod +x .githooks/pre-commit

## check: every static gate - Python, Terraform, and repo-content validation
check: py-check tf-check validate

## precommit: every gate `check` runs except tf-trivy, which needs Docker -
## not something a commit should be blocked on not having installed. Run
## `make tf-trivy` (or `make check`) by hand, and it still runs in CI.
precommit: py-check tf-fmt tf-lint validate

## py-check: the Python gates CI runs
py-check: lint typecheck test

## lint: ruff (config in pyproject.toml)
lint:
	uv run ruff check $(PY_LINT_PATHS)

## typecheck: ty (Astral's Rust-based checker), replacing mypy. Still
## 0.0.x/beta (no stable API), and surfaces diagnostics against paths mypy
## previously passed cleanly - not yet triaged, so this does not fail the
## build (locally, in the pre-commit hook, or in CI - see tf-deploy.yaml's
## Typecheck step) until they are. Diagnostics still print; only the exit
## code is suppressed, so `make check`/`make precommit` can't silently
## start passing for an unrelated reason if ty's own invocation breaks.
typecheck:
	uv run ty check $(PY_LINT_PATHS) || true

## test: pytest
test:
	uv run pytest $(PY_TEST_PATHS)

## fmt: apply ruff's autofixes and formatter. Opt-in: `make check` does NOT
## enforce formatting, so running this is a deliberate choice, not a gate.
fmt:
	uv run ruff check --fix $(PY_LINT_PATHS)
	uv run ruff format $(PY_LINT_PATHS)

## post-deploy-test: run post-deploy tests against a live environment.
## Requires ENVIRONMENT to be set (dev, test, uat, prod) and AWS credentials
## with permission to assume chedaws-edp-ci-runner in the target account.
## Not included in `make test` because it needs live AWS; run explicitly:
##     ENVIRONMENT=dev make post-deploy-test
post-deploy-test:
	uv run pytest tests/post_deploy/ -v --tb=short

# --- Repo content validation -------------------------------------------

## validate: every repo-content check CI runs before planning Terraform -
## Kafka/S3/Redshift registrations, MWAA namespaces, and JSON Schema
## validation for Kafka, S3 Tables, and Lake Formation YAMLs.
validate: validate-kafka-schema validate-kafka-topics-producers \
	validate-kafka-topics-consumers validate-kafka-topics-connect \
	validate-s3-registrations \
	validate-redshift-registrations validate-s3tables-yaml \
	validate-lakeformation-yaml

validate-kafka-schema:
	@for pair in "kafka/producers:kafka/schema/producer-schema.json" \
	             "kafka/consumers:kafka/schema/consumer-schema.json" \
	             "kafka/connect:kafka/schema/connect-schema.json"; do \
		dir="$${pair%%:*}"; schema="$${pair#*:}"; \
		files=$$(find "$$dir" -name '*.yaml' 2>/dev/null); \
		if [ -z "$$files" ]; then \
			echo "No YAMLs found in $$dir - skipping schema validation"; \
		else \
			for f in $$files; do \
				echo "Validating $$f"; \
				uv run check-jsonschema --schemafile "$$schema" "$$f"; \
			done; \
		fi; \
	done

validate-kafka-topics-producers:
	uv run python3 .github/scripts/validate-topic-names.py kafka/producers/

validate-kafka-topics-consumers:
	uv run python3 .github/scripts/validate-topic-names.py kafka/consumers/ --consumer

validate-kafka-topics-connect:
	uv run python3 .github/scripts/validate-topic-names.py kafka/producers/ kafka/consumers/ kafka/connect/ --connect

validate-s3-registrations:
	uv run python3 .github/scripts/validate-s3-registrations.py

validate-redshift-registrations:
	uv run python3 .github/scripts/validate-redshift-registrations.py

validate-s3tables-yaml:
	uv run check-jsonschema --schemafile ./s3tables/schema/namespace.schema.json s3tables/namespaces/*.yaml
	# uv run check-jsonschema --schemafile ./s3tables/schema/table.schema.json s3tables/tables/*.yaml    # Enable once the S3 creation branch merges

validate-lakeformation-yaml:
	@for pair in "DatabaseAccess:database-access.schema.json" \
	             "TableAccess:database-access.schema.json" \
	             "AccessGrant:access-grant.schema.json" \
	             "TagAssignments:tag-assignments.schema.json"; do \
		kind="$${pair%%:*}"; schema="./lakeformation/schemas/$${pair#*:}"; \
		files=$$(grep -rl "^kind: $${kind}$$" --include="*.yaml" lakeformation || true); \
		if [ -n "$$files" ]; then \
			echo "Validating kind=$$kind against $$schema"; \
			uv run check-jsonschema --schemafile "$$schema" $$files; \
		fi; \
	done

# --- Terraform -------------------------------------------------------------

## tf-check: every Terraform static gate
tf-check: tf-fmt tf-lint tf-trivy

## tf-fmt: terraform fmt
tf-fmt:
	terraform fmt -check -recursive -diff $(TF_DIR)

## tf-lint: tflint (TF_WORKSPACE=dev, as CI sets it)
tf-lint:
	@PATH="$(TOOLS_DIR):$$PATH" command -v tflint >/dev/null 2>&1 || { \
	  echo "tflint not found. Run 'make tf-tools' to install it into $(TOOLS_DIR)."; \
	  exit 1; }
	cd $(TF_DIR) && PATH="$(TOOLS_DIR):$$PATH" sh -c \
	  'tflint --init && TF_WORKSPACE=dev tflint --minimum-failure-severity=error --recursive'

## tf-trivy: replaces checkov as the real Terraform security gate (removed
## entirely, matching the POC - see docker/ci-image/Dockerfile and
## tf-deploy.yaml's Run Trivy step, a compiled Go binary baked into the CI
## image there instead of a Docker-container Action needing its own image
## pull on every run). Uses its own check IDs (AVD-AWS-*), not checkov's
## (CKV_*) - a different ruleset, not a faster version of the same one;
## --exit-code 1 restores checkov's hard-fail-on-findings behaviour
## (trivy's own default is 0 regardless of findings). --tf-exclude-
## downloaded-modules stops trivy independently re-resolving/scanning
## vendored module sources (terraform-aws-modules/*) - see tf-deploy.yaml's
## Run Trivy step for why this matters beyond just noise (a real local run
## without it hung trying to `git clone` straight to github.com).
tf-trivy:
	@command -v docker >/dev/null 2>&1 || { \
	  echo "docker not found. tf-trivy runs $(TRIVY_IMAGE) - install Docker to run it locally."; \
	  exit 1; }

	docker run --rm -v "$(CURDIR):/tf" -w /tf $(TRIVY_IMAGE) \
	  config --exit-code 1 --skip-dirs '.venv,terraform-legacy,**/.terraform/**' --tf-exclude-downloaded-modules $(TF_DIR)

## tf-tools: install tflint into .tools/ (no sudo; the upstream installer
## defaults to /usr/local/bin, which needs root)
tf-tools:
	mkdir -p $(TOOLS_DIR)
	curl -sSL https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh \
	  | TFLINT_VERSION=$(TFLINT_VERSION) TFLINT_INSTALL_PATH=$(TOOLS_DIR) bash
	@$(TOOLS_DIR)/tflint --version

## clean: remove the venv and tool caches
clean:
	rm -rf .venv .mypy_cache .ruff_cache .pytest_cache
	find . -name __pycache__ -type d -not -path './.venv/*' -exec rm -rf {} + 2>/dev/null || true
