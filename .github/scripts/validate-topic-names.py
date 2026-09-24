#!/usr/bin/env python3
"""
Validate Kafka topic YAML files for naming, placement, and decommission invariants.

Usage:
    python3 validate-topic-names.py kafka/producers/
    python3 validate-topic-names.py kafka/consumers/ --consumer
    python3 validate-topic-names.py kafka/producers/ kafka/consumers/ kafka/connect/ --connect
"""

import argparse
import json
import re
import sys
from pathlib import Path

import yaml

FIELD_PATTERN = re.compile(r"^[a-z][a-z0-9-]*$")
MAX_CONSUMER_TOPICS = 80
MAX_RETENTION_MS_DEV_TEST = 2_592_000_000


def load_yaml(path: Path):
    with path.open() as f:
        return yaml.safe_load(f)


def validate_producer_file(path: Path, root: Path, errors: list, warnings: list):
    try:
        doc = load_yaml(path)
    except yaml.YAMLError as e:
        errors.append(f"{path}: YAML parse error: {e}")
        return

    spec = doc.get("spec", {})
    metadata = doc.get("metadata", {})
    business_name = metadata.get("businessName", "")
    app_name = metadata.get("appName", "")
    event_names = [e["name"] for e in spec.get("events") or [] if isinstance(e, dict) and "name" in e]
    decommissioned_events = spec.get("decommissionedEvents") or []

    if not FIELD_PATTERN.match(business_name):
        errors.append(
            f"{path}: metadata.businessName '{business_name}' does not match required pattern "
            r"^[a-z][a-z0-9-]*$"
        )

    if not FIELD_PATTERN.match(app_name):
        errors.append(
            f"{path}: metadata.appName '{app_name}' does not match required pattern "
            r"^[a-z][a-z0-9-]*$"
        )

    if not event_names:
        errors.append(f"{path}: spec.events must be non-empty")
    else:
        for event_name in event_names:
            if not FIELD_PATTERN.match(event_name):
                errors.append(
                    f"{path}: spec.events entry name '{event_name}' does not match required pattern "
                    r"^[a-z][a-z0-9-]*$"
                )

    # Duplicate event names within the same file (JSON Schema draft-07 cannot enforce uniqueItems on object arrays)
    if len(event_names) != len(set(event_names)):
        errors.append(f"{path}: spec.events contains duplicate event names")

    # Block any event appearing in both spec.events and spec.decommissionedEvents
    overlap = set(event_names) & set(decommissioned_events)
    if overlap:
        errors.append(
            f"{path}: event name(s) {sorted(overlap)} appear in both spec.events and spec.decommissionedEvents"
        )

    # Placement check: path.parts[-2] == businessName, path.stem == appName
    if business_name and path.parent.name != business_name:
        errors.append(
            f"{path}: file directory '{path.parent.name}' does not match metadata.businessName '{business_name}' "
            f"(file must be at kafka/producers/{business_name}/{app_name}.yaml)"
        )

    if app_name and path.stem != app_name:
        errors.append(
            f"{path}: file stem '{path.stem}' does not match metadata.appName '{app_name}'"
        )

    for event in spec.get("events") or []:
        if not isinstance(event, dict):
            continue
        retention_ms = event.get("retentionMs")
        if retention_ms is not None and retention_ms > MAX_RETENTION_MS_DEV_TEST:
            warnings.append(
                f"{path}: event '{event.get('name', '?')}' retentionMs {retention_ms} exceeds the 30-day cap "
                f"({MAX_RETENTION_MS_DEV_TEST} ms) enforced for dev/test environments"
            )


def validate_consumer_file(path: Path, root: Path, errors: list, warnings: list,
                            known_topics: set):
    try:
        doc = load_yaml(path)
    except yaml.YAMLError as e:
        errors.append(f"{path}: YAML parse error: {e}")
        return

    topics = doc.get("spec", {}).get("topics") or []
    metadata_name = doc.get("metadata", {}).get("name", "")

    # Flat placement check: parent dir must be 'consumers', stem must equal metadata.name
    if path.parent.name != "consumers":
        errors.append(
            f"{path}: consumer YAML must be at kafka/consumers/<consumer_slug>.yaml (flat), "
            f"but found in directory '{path.parent.name}'"
        )

    if metadata_name and path.stem != metadata_name:
        errors.append(
            f"{path}: file stem '{path.stem}' does not match metadata.name '{metadata_name}'"
        )

    seen_topics: set = set()
    for topic in topics:
        if not isinstance(topic, dict):
            errors.append(f"{path}: spec.topics entries must be objects with businessName/appName/eventName fields")
            continue

        for field in ("businessName", "appName", "eventName"):
            val = topic.get(field, "")
            if not val:
                errors.append(f"{path}: spec.topics entry missing required field '{field}'")
            elif not FIELD_PATTERN.match(val):
                errors.append(
                    f"{path}: spec.topics entry field '{field}' value '{val}' does not match "
                    r"^[a-z][a-z0-9-]*$"
                )

        key = (topic.get("businessName", ""), topic.get("appName", ""), topic.get("eventName", ""))
        if key in seen_topics:
            errors.append(
                f"{path}: duplicate topic reference ({key[0]}, {key[1]}, {key[2]}) in spec.topics"
            )
        else:
            seen_topics.add(key)
        if key not in known_topics:
            errors.append(
                f"{path}: references topic ({key[0]}, {key[1]}, {key[2]}) but no corresponding "
                f"active producer registration was found"
            )

    if len(topics) > MAX_CONSUMER_TOPICS:
        warnings.append(
            f"{path}: references {len(topics)} topics which exceeds the advisory limit of "
            f"{MAX_CONSUMER_TOPICS} (IAM policy 6 KB size limit may be reached)"
        )


def collect_known_topics(producers_root: Path) -> set:
    """Return set of (businessName, appName, eventName) tuples for all active events."""
    topics = set()
    for yaml_file in producers_root.rglob("*.yaml"):
        try:
            doc = load_yaml(yaml_file)
            if doc.get("spec", {}).get("decommission", False):
                continue
            spec = doc.get("spec", {})
            business_name = doc.get("metadata", {}).get("businessName", "")
            app_name = doc.get("metadata", {}).get("appName", "")
            event_names = [e["name"] for e in spec.get("events") or [] if isinstance(e, dict) and "name" in e]
            decommissioned_events = set(spec.get("decommissionedEvents") or [])
            for event_name in event_names:
                if event_name not in decommissioned_events:
                    topics.add((business_name, app_name, event_name))
        except (yaml.YAMLError, OSError):
            pass
    return topics


def check_duplicate_topic_names(producers_root: Path, errors: list):
    seen: dict[tuple, Path] = {}
    for yaml_file in producers_root.rglob("*.yaml"):
        try:
            doc = load_yaml(yaml_file)
            if doc.get("spec", {}).get("decommission", False):
                continue
            spec = doc.get("spec", {})
            business_name = doc.get("metadata", {}).get("businessName", "")
            app_name = doc.get("metadata", {}).get("appName", "")
            event_names = [e["name"] for e in spec.get("events") or [] if isinstance(e, dict) and "name" in e]
            decommissioned_events = set(spec.get("decommissionedEvents") or [])
            for event_name in event_names:
                if event_name in decommissioned_events:
                    continue
                key = (business_name, app_name, event_name)
                if not all(key):
                    continue
                if key in seen:
                    errors.append(
                        f"Duplicate topic ({business_name}, {app_name}, {event_name}) declared in both "
                        f"'{seen[key]}' and '{yaml_file}'"
                    )
                else:
                    seen[key] = yaml_file
        except (yaml.YAMLError, OSError):
            pass


def check_consumer_slug_uniqueness(consumer_files: list[Path], errors: list):
    seen: dict[str, Path] = {}
    for yaml_file in consumer_files:
        try:
            doc = load_yaml(yaml_file)
            name = doc.get("metadata", {}).get("name", "")
            if not name:
                continue
            if name in seen:
                errors.append(
                    f"Duplicate consumer metadata.name '{name}' in both '{seen[name]}' and '{yaml_file}'"
                )
            else:
                seen[name] = yaml_file
        except (yaml.YAMLError, OSError):
            pass


def _load_connect_schema(repo_root: Path):
    """Load the connect JSON Schema for validation."""
    schema_path = repo_root / "kafka" / "schema" / "connect-schema.json"
    if not schema_path.exists():
        return None
    with schema_path.open() as f:
        return json.load(f)


def _jsonschema_validate(instance: dict, schema: dict) -> list:
    """Validate instance against schema using jsonschema if available; return error strings."""
    try:
        import jsonschema
        validator = jsonschema.Draft7Validator(schema)
        return [str(e.message) for e in sorted(validator.iter_errors(instance), key=lambda e: list(e.path))]
    except ImportError:
        return []


def validate_connect_registrations(producers_root: Path, connect_root: Path, errors: list):
    """
    Five checks for KafkaConnectRegistration files:
    1. Schema validation against connect-schema.json
    2. metadata.name uniqueness
    3. Every source resolves to an existing TopicRegistration
    4. Every TopicRegistration without a producer block is claimed, per environment, by
       at most one active registration - two registrations may claim the same source as
       long as their spec.connect.environments don't overlap (e.g. one server for test,
       separate servers per business unit for uat)
    5. IAM role name length <= 64 for all declared environments
    """
    repo_root = producers_root.parent.parent
    schema = _load_connect_schema(repo_root)

    # Load all connect files
    connect_docs: list[tuple[Path, dict]] = []
    for yaml_file in sorted(connect_root.rglob("*.yaml")):
        try:
            doc = load_yaml(yaml_file)
        except yaml.YAMLError as e:
            errors.append(f"{yaml_file}: YAML parse error: {e}")
            continue
        if not isinstance(doc, dict):
            errors.append(f"{yaml_file}: document is not a YAML mapping")
            continue

        # Check 1: schema validation
        if schema:
            schema_errors = _jsonschema_validate(doc, schema)
            for se in schema_errors:
                errors.append(f"{yaml_file}: schema validation error: {se}")

        connect_docs.append((yaml_file, doc))

    # Check 2: metadata.name uniqueness
    seen_names: dict[str, Path] = {}
    for yaml_file, doc in connect_docs:
        name = doc.get("metadata", {}).get("name", "")
        if not name:
            continue
        if name in seen_names:
            errors.append(
                f"Duplicate connect registration name '{name}' in both "
                f"'{seen_names[name]}' and '{yaml_file}'"
            )
        else:
            seen_names[name] = yaml_file

    # Build set of known (businessName, appName) pairs from producers
    known_apps: set[tuple] = set()
    for yaml_file in producers_root.rglob("*.yaml"):
        try:
            doc = load_yaml(yaml_file)
            if doc.get("spec", {}).get("decommission", False):
                continue
            bn = doc.get("metadata", {}).get("businessName", "")
            an = doc.get("metadata", {}).get("appName", "")
            if bn and an:
                known_apps.add((bn, an))
        except (yaml.YAMLError, OSError):
            pass

    # Check 3: source cross-reference
    # Also build mapping of (businessName, appName) -> list of (registration name, the
    # environments it declares under spec.connect.environments) that claim it. The
    # environments travel with each claim so Check 4 can tell "claimed twice" apart from
    # "claimed once each by two environment-scoped registrations" - the same source can
    # legitimately be aggregated by a different Connect server per environment.
    app_claimed_by: dict[tuple, list[tuple[str, frozenset]]] = {}
    for yaml_file, doc in connect_docs:
        reg_name = doc.get("metadata", {}).get("name", "")
        reg_envs = frozenset(doc.get("spec", {}).get("connect", {}).get("environments", {}))
        for src in doc.get("spec", {}).get("sources", []):
            bn = src.get("businessName", "")
            an = src.get("appName", "")
            key = (bn, an)
            if key not in known_apps:
                errors.append(
                    f"{yaml_file}: source ({bn}, {an}) does not resolve to any active TopicRegistration"
                )
            app_claimed_by.setdefault(key, []).append((reg_name, reg_envs))

    # Check 4: orphaned TopicRegistrations (no producer block, not claimed by exactly one registration)
    for yaml_file in producers_root.rglob("*.yaml"):
        try:
            doc = load_yaml(yaml_file)
        except (yaml.YAMLError, OSError):
            continue
        if doc.get("spec", {}).get("decommission", False):
            continue
        spec = doc.get("spec", {})
        if "producer" not in spec:
            bn = doc.get("metadata", {}).get("businessName", "")
            an = doc.get("metadata", {}).get("appName", "")
            key = (bn, an)
            claims = app_claimed_by.get(key, [])
            if len(claims) == 0:
                errors.append(
                    f"{yaml_file}: TopicRegistration ({bn}/{an}) has no 'producer' block "
                    f"and is not claimed by any KafkaConnectRegistration"
                )
            else:
                # Two claims only conflict if they cover the same environment - Terraform
                # itself scopes every connect resource by
                # spec.connect.environments[local.environment], so disjoint environments
                # never collide (see kafka.tf).
                claimants_by_env: dict[str, set[str]] = {}
                for reg_name, reg_envs in claims:
                    for env in reg_envs:
                        claimants_by_env.setdefault(env, set()).add(reg_name)
                conflicts = {
                    env: sorted(names) for env, names in claimants_by_env.items() if len(names) > 1
                }
                if conflicts:
                    errors.append(
                        f"{yaml_file}: TopicRegistration ({bn}/{an}) is claimed by more than "
                        f"one KafkaConnectRegistration in the same environment: {conflicts}"
                    )

    # Check 5: IAM role name length <= 64 for all declared environments
    MAX_ENVIRONMENTS = ("dev", "test", "uat", "prod")
    for yaml_file, doc in connect_docs:
        name = doc.get("metadata", {}).get("name", "")
        if not name:
            continue
        envs = doc.get("spec", {}).get("connect", {}).get("environments", {})
        for env in envs:
            role_name = f"edp-{env}-kafka-connect-{name}"
            if len(role_name) > 64:
                errors.append(
                    f"{yaml_file}: IAM role name '{role_name}' ({len(role_name)} chars) exceeds 64 characters. "
                    f"Shorten registration name '{name}'."
                )


def main():
    parser = argparse.ArgumentParser(description="Validate Kafka topic YAML files")
    parser.add_argument("directories", nargs="+",
                        help="Directories to scan. For --connect: pass producers/, consumers/, connect/ in order.")
    parser.add_argument("--consumer", action="store_true", help="Validate consumer YAMLs")
    parser.add_argument("--connect", action="store_true",
                        help="Validate connect registrations (requires producers/, consumers/, connect/ args)")
    args = parser.parse_args()

    errors = []
    warnings = []

    if args.connect:
        if len(args.directories) < 3:
            print(
                "ERROR: --connect requires three directory arguments: "
                "kafka/producers/ kafka/consumers/ kafka/connect/.",
                file=sys.stderr,
            )
            sys.exit(1)
        producers_root = Path(args.directories[0])
        connect_root = Path(args.directories[2])
        for d in (producers_root, connect_root):
            if not d.is_dir():
                print(f"ERROR: directory [{d}] does not exist.", file=sys.stderr)
                sys.exit(1)
        validate_connect_registrations(producers_root, connect_root, errors)

        for w in warnings:
            print(f"WARNING: {w}")
        if errors:
            for e in errors:
                print(f"ERROR: {e}", file=sys.stderr)
            sys.exit(1)
        print("OK: all connect registration files passed validation.")
        return

    # Legacy single-directory mode
    root = Path(args.directories[0])
    if not root.is_dir():
        print(f"ERROR: directory [{root}] does not exist.", file=sys.stderr)
        sys.exit(1)

    if args.consumer:
        repo_root = Path(__file__).resolve().parent.parent.parent
        producers_root = repo_root / "kafka" / "producers"
        known_topics = collect_known_topics(producers_root) if producers_root.is_dir() else set()

        consumer_files = list(root.rglob("*.yaml"))
        check_consumer_slug_uniqueness(consumer_files, errors)
        for yaml_file in consumer_files:
            validate_consumer_file(yaml_file, root, errors, warnings, known_topics)
    else:
        check_duplicate_topic_names(root, errors)
        for yaml_file in root.rglob("*.yaml"):
            validate_producer_file(yaml_file, root, errors, warnings)

    for w in warnings:
        print(f"WARNING: {w}")

    if errors:
        for e in errors:
            print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"OK: all YAML files in [{root}] passed validation.")


if __name__ == "__main__":
    main()
