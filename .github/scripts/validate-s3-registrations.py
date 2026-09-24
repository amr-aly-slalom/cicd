#!/usr/bin/env python3
"""CI validation script for S3 producer registrations.

Validates namespace YAMLs (s3/*.yaml) and table YAMLs (s3/*/*.yaml) against
their JSON Schemas, enforces path/name consistency, and checks for duplicates.
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


class DuplicateRegistrationError(Exception):
    pass


def load_schema(schema_path: Path) -> dict:
    with schema_path.open() as f:
        return json.load(f)


def get_s3_root() -> Path:
    return Path(__file__).parent.parent.parent / "s3"


def validate_namespaces(s3_root: Path, namespace_schema: dict) -> list[dict]:
    validator = jsonschema.Draft7Validator(namespace_schema)
    namespaces = []
    errors = []

    for yaml_path in sorted(s3_root.glob("*.yaml")):
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

        namespaces.append(data)

    if errors:
        sys.exit("Namespace YAML validation errors:\n" + "\n".join(errors))

    # Duplicate check
    names = [d["metadata"]["name"] for d in namespaces]
    seen = set()
    dupes = set()
    for n in names:
        if n in seen:
            dupes.add(n)
        seen.add(n)
    if dupes:
        raise DuplicateNamespaceError(
            f"Duplicate namespace values detected: {sorted(dupes)}"
        )

    return namespaces


def validate_tables(s3_root: Path, table_schema: dict) -> list[dict]:
    validator = jsonschema.Draft7Validator(table_schema)
    tables = []
    errors = []

    for yaml_path in sorted(s3_root.glob("*/*.yaml")):
        with yaml_path.open() as f:
            data = yaml.safe_load(f)

        validation_errors = list(validator.iter_errors(data))
        if validation_errors:
            for e in validation_errors:
                errors.append(f"  {yaml_path}: {e.message}")
            continue

        declared_namespace = data["metadata"]["namespace"]
        declared_name = data["metadata"]["name"]

        if yaml_path.parent.name != declared_namespace:
            errors.append(
                f"  {yaml_path}: parent dir '{yaml_path.parent.name}' != metadata.namespace '{declared_namespace}'"
            )
            continue

        if yaml_path.stem != declared_name:
            errors.append(
                f"  {yaml_path}: file stem '{yaml_path.stem}' != metadata.name '{declared_name}'"
            )
            continue

        tables.append(data)

    if errors:
        sys.exit("Table YAML validation errors:\n" + "\n".join(errors))

    # Duplicate check on active (non-decommissioned) tables
    active_tables = [t for t in tables if not t.get("spec", {}).get("decommission", False)]
    slugs = [
        f"{t['metadata']['namespace']}/{t['metadata']['name']}"
        for t in active_tables
    ]
    seen = set()
    dupes = set()
    for s in slugs:
        if s in seen:
            dupes.add(s)
        seen.add(s)
    if dupes:
        raise DuplicateRegistrationError(
            f"Duplicate active (namespace, name) pairs detected: {sorted(dupes)}"
        )

    return tables


def main() -> None:
    s3_root = get_s3_root()
    schema_dir = s3_root / "schema"
    namespace_schema = load_schema(schema_dir / "namespace-schema.json")
    table_schema = load_schema(schema_dir / "table-schema.json")

    validate_namespaces(s3_root, namespace_schema)
    validate_tables(s3_root, table_schema)

    print("All registrations valid. No duplicates detected.")


if __name__ == "__main__":
    main()
