# Pre-built CI image: Terraform CLI + every stack's provider cache, AND the
# full uv-managed Python environment (apache-airflow, ruff, ty, pytest,
# boto3, ...), baked in - so build's static-check and plan steps download
# nothing at runtime. Also bakes in tflint and Trivy, which replaced mypy
# and checkov entirely (see pyproject.toml/Makefile).
#
# ZERO package-manager calls AND ZERO network calls anywhere in this file -
# every RUN instruction below just moves already-fetched files into place.
# Confirmed, not assumed, that this matters: an earlier version of this
# Dockerfile curled Terraform/tflint/Trivy and ran `terraform init`/
# `uv sync` directly in RUN instructions, and the Terraform download timed
# out on a real publish run even though the exact same host reaches
# releases.hashicorp.com fine via networkanalytics-actions/
# hashicorp-setup-terraform (confirmed by reading that action's own
# source - it resolves the identical releasesUrl). The difference is WHERE
# the network call runs: that action's Node process runs directly on the
# runner; a Dockerfile RUN instruction executes inside `docker build`'s own
# isolated network namespace, which does not automatically inherit
# whatever proxy/egress config gets this runner to the public internet.
# Every fetch - Terraform, tflint, Trivy, the Python venv (uv sync), and
# the provider cache (terraform init) - now happens on the runner itself,
# in .github/actions/publish-ci-image (the same network context
# setup-terraform and setup-python-uv already use successfully today),
# staged into this build context. This file only COPYs the results in.
#
# tar/make/git/unzip/gzip are ALSO staged from the runner, but for a
# different reason (no network involved for these) - see
# .github/actions/publish-ci-image's own comment: `make` specifically is
# confirmed present there (chedaws' GitHub team installed it directly on
# the runner image, after EDP-597's dnf-install attempt failed the exact
# same way), and since the build runs on that same runner and base image
# (Amazon Linux), its native binaries are already the right glibc build to
# copy in directly.
#
# Build context MUST be the repo root, so the staged-* directories below
# resolve correctly:
#   docker build -f docker/ci-image/Dockerfile .
#
# Rebuild whenever a stack's .terraform.lock.hcl changes, a tool version in
# .github/actions/publish-ci-image/action.yaml is bumped, or uv.lock
# changes - publish-ci-image.yaml triggers on exactly those paths (plus
# this Dockerfile itself).
FROM amazonlinux:2023

# This runner's own CA trust store, not the image's default (public-CA-only)
# one - confirmed, not assumed, this is needed: a real run hit "self-signed
# certificate in certificate chain" cloning github.domain.prd.int from
# inside the container, even though the identical `git` binary clones fine
# directly on the runner that built this image. Overwriting the extracted
# bundle a fresh amazonlinux:2023 ships (rather than adding just the one
# relevant CA) makes the image trust exactly what the runner already does -
# see .github/actions/publish-ci-image's matching staging step.
#
# SSL_CERT_FILE/REQUESTS_CA_BUNDLE, not just the system file: Python's
# requests/urllib3 (and so boto3) default to their own vendored `certifi`
# bundle instead of the system trust store unless told otherwise - without
# these, git would trust this CA but boto3/terraform's S3 backend calls
# still wouldn't.
COPY docker/ci-image/staged-ca-bundle/tls-ca-bundle.pem /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
ENV SSL_CERT_FILE=/etc/pki/tls/certs/ca-bundle.crt
ENV REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt

# UV_PROJECT_ENVIRONMENT, not the default project-local .venv: a real job
# checks the repo out to /github/workspace (GitHub Actions always mounts a
# container job's workspace there), which would shadow anything baked
# under /workspace. /opt is outside that mount, so the baked venv survives
# whatever gets checked out at runtime.
ENV UV_PROJECT_ENVIRONMENT=/opt/venv
ENV PATH="/opt/venv/bin:${PATH}"
COPY docker/ci-image/staged-venv/ /opt/venv/

# venv/bin/python is an absolute symlink OUT to a separately managed
# interpreter, not something uv installs inside the venv itself - see
# .github/actions/publish-ci-image's matching staging step for why this
# has to land at exactly this path (GitHub Actions always sets
# $HOME=/github/home for container: jobs - confirmed directly from a real
# run's own traceback) rather than /opt alongside everything else here.
COPY docker/ci-image/staged-uv-python/ /github/home/.local/share/uv/python/

# TF_PLUGIN_CACHE_DIR is the exact mechanism the workflow uses at runtime;
# baking it here just means that step finds everything already present
# instead of downloading it (the hashicorp/aws provider alone is large -
# hundreds of MB uncompressed - and every one of this repo's 8 stacks
# pins it, so this is the single biggest saving in this image).
ENV TF_PLUGIN_CACHE_DIR=/opt/terraform-plugin-cache
COPY docker/ci-image/staged-provider-cache/ /opt/terraform-plugin-cache/

# terraform, tflint, trivy - fetched and extracted on the runner (see this
# file's own header comment for why), not curled here.
COPY docker/ci-image/staged-bin/ /usr/local/bin/

# trivy's own "checks bundle", primed on the runner for the same reason as
# everything else above - confirmed, not assumed, that `trivy config`
# otherwise downloads this from the internet on first use. TRIVY_CACHE_DIR,
# not trivy's own $HOME-relative default (/root/.cache/trivy) - confirmed
# directly that a container: job's $HOME is /github/home, not /root, the
# same reason the venv's own interpreter symlink above needs its own fix
# rather than trusting $HOME to match between staging and runtime.
ENV TRIVY_CACHE_DIR=/opt/trivy-cache
COPY docker/ci-image/staged-trivy-cache/ /opt/trivy-cache/

# tar/make/git/unzip/gzip + the shared libraries make actually needs beyond
# libc (AL2023's `make` is built with GNU Guile scripting support, needing
# libguile/libgc/libltdl that nothing here uses but the binary still
# requires to start) + git's HTTPS-clone helpers.
COPY docker/ci-image/staged-lib/ /lib64/
COPY docker/ci-image/staged-git-core/ /usr/libexec/git-core/

WORKDIR /workspace
