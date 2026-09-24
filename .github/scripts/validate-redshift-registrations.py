#!/usr/bin/env python3
"""CI validation script for Redshift namespace registrations.

Validates namespace YAMLs (redshift/namespaces/*.yaml) against their JSON
Schema, checks for duplicates, and cross-references each namespace against an
existing non-decommissioned airflow/mwaa/<name>.yaml (this registers
Redshift access *for* an MWAA namespace, not a standalone concept).
"""

import json
import sys
from pathlib import Path

import yaml

try:
    import jsonschema
except ImportError:
    sys.exit("ERROR: jsonschema package not installed. Run: pip install jsonschema")


class DuplicateNamespaceError(Exception):
    pass


def load_schema(schema_path: Path) -> dict:
    with schema_path.open() as f:
        return json.load(f)


def get_repo_root() -> Path:
    return Path(__file__).parent.parent.parent


def get_redshift_root() -> Path:
    return get_repo_root() / "redshift"


def get_active_mwaa_namespaces(repo_root: Path) -> set[str]:
    """Names of every airflow/mwaa/*.yaml not marked spec.decommission: true."""
    names = set()
    for yaml_path in sorted((repo_root / "airflow" / "mwaa").glob("*.yaml")):
        with yaml_path.open() as f:
            data = yaml.safe_load(f)
        if not data.get("spec", {}).get("decommission", False):
            names.add(data["metadata"]["name"])
    return names


def validate_namespaces(
    redshift_root: Path, namespace_schema: dict, mwaa_namespaces: set[str]
) -> list[dict]:
    validator = jsonschema.Draft7Validator(namespace_schema)
    namespaces = []
    errors = []

    for yaml_path in sorted((redshift_root / "namespaces").glob("*.yaml")):
        with yaml_path.open() as f:
            data = yaml.safe_load(f)

        validation_errors = list(validator.iter_errors(data))
        if validation_errors:
            for e in validation_errors:
                errors.append(f"  {yaml_path}: {e.message}")
            continue

        declared_name = data["metadata"]["name"]
        if yaml_path.stem != declared_name:
            errors.append(
                f"  {yaml_path}: file stem '{yaml_path.stem}' != metadata.name '{declared_name}'"
            )
            continue

        if declared_name not in mwaa_namespaces:
            errors.append(
                f"  {yaml_path}: metadata.name '{declared_name}' has no matching "
                "active airflow/mwaa/<name>.yaml - Redshift access is registered "
                "for an existing MWAA namespace, not a standalone one"
            )
            continue

        namespaces.append(data)

    if errors:
        sys.exit("Redshift namespace YAML validation errors:\n" + "\n".join(errors))

    active = [n for n in namespaces if not n.get("spec", {}).get("decommission", False)]
    names = [n["metadata"]["name"] for n in active]
    seen: set[str] = set()
    dupes: set[str] = set()
    for n in names:
        if n in seen:
            dupes.add(n)
        seen.add(n)
    if dupes:
        raise DuplicateNamespaceError(f"Duplicate namespace values detected: {sorted(dupes)}")

    return namespaces


def main() -> None:
    repo_root = get_repo_root()
    redshift_root = get_redshift_root()
    namespace_schema = load_schema(redshift_root / "schema" / "namespace.schema.json")
    mwaa_namespaces = get_active_mwaa_namespaces(repo_root)

    validate_namespaces(redshift_root, namespace_schema, mwaa_namespaces)

    print("All Redshift namespace registrations valid. No duplicates detected.")


if __name__ == "__main__":
    main()
