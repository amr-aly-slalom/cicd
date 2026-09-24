# Research: Kafka Connect Support

**Date**: 2026-07-21

---

## §1 — Kafka Connect system topic isolation

**Decision**: Each `KafkaConnectRegistration` receives its own set of prefixed system topics: `<name>-connect-config`, `<name>-connect-offsets`, `<name>-connect-status` (and `<name>-confluent-license` for the Confluent variant).

**Rationale**: Kafka Connect distributed mode uses three internal coordination topics — `connect-config` (connector/task configuration), `connect-offsets` (source connector read checkpoints), and `connect-status` (connector/task lifecycle state) — as a coordination bus among workers sharing the same `group.id`. If two separate Kafka Connect clusters write to the same unqualified topic names, their connector configs and offsets collide, making recovery after failure unpredictable and causing operational confusion. Prefixing by registration name ensures each logical Kafka Connect cluster has its own isolated set.

**Alternatives considered**:
- Shared topics (`connect-config` etc.) — rejected: would conflate independent connect clusters' metadata and offsets on the shared MSK cluster.
- Environment-qualified names (`edp-<env>-ue-connect-config`) — deferred: while MSK already scopes topics per cluster instance (one cluster per env), adding `edp-<env>-` to system topics doesn't match Kafka Connect's default `config.storage.topic`, `offset.storage.topic`, `status.storage.topic` configuration keys. The connect server's distributed config would need these overridden. The simpler `<name>-connect-config` pattern (no env prefix) is sufficient given the MSK cluster is already environment-scoped; the connect server config needs only three overrides regardless.

---

## §2 — System topic configuration values

**Decision**:

| Topic suffix | Partitions | Cleanup policy | Retention |
|---|---|---|---|
| `connect-config` | 1 | `compact` | -1 (infinite) |
| `connect-offsets` | 25 | `compact` | -1 (infinite) |
| `connect-status` | 5 | `compact,delete` | 86400000 ms (1 day) |
| `confluent-license` | 1 | `compact` | -1 (infinite) |

**Rationale**: These values follow Confluent's and Apache Kafka's documented recommendations for Kafka Connect internal topics. `connect-config` holds only current connector configs — 1 partition, compacted, never deleted. `connect-offsets` holds fine-grained source partition offsets — 25 partitions is the default recommended to allow parallelism across many source partitions without hitting Kafka's per-broker partition limits. `connect-status` tracks task lifecycle events which are low-frequency and short-lived — 5 partitions, compact+delete with 1-day retention, matching the Confluent default. `_confluent-license` is compact-only (a configuration topic for license metadata).

**Alternatives considered**:
- Parameterising partition counts in the YAML — rejected: these are infrastructure internals, not business configuration. The spec's goal is a zero-Terraform-change onboarding path; hardcoding the standard values achieves that.

---

## §3 — producer-schema.json: making `producer` optional

**Decision**: Relax `required: ["events", "producer"]` to `required: ["events"]` in `producer-schema.json`. The Python CI script (`validate-topic-names.py`) enforces the cross-file invariant: a `TopicRegistration` with no `producer` block must appear as a source in exactly one active `KafkaConnectRegistration`.

**Rationale**: JSON Schema cannot enforce cross-file relationships. The current constraint `required: ["producer"]` would need to be weakened to allow connect-owned apps. Moving the cross-file validation to the Python CI script is consistent with the existing pattern — `validate-topic-names.py` already validates cross-file rules (consumer cross-reference, duplicate slugs, file placement). The schema remains the format validator; the Python script is the semantic validator.

**Alternatives considered**:
- Keep `producer` required and add a sentinel `producer: {ownedByConnect: true}` flag — rejected: adds schema complexity and a new concept for no benefit over simply omitting the block.
- Introduce a separate `TopicOnlyRegistration` kind — rejected: breaks backwards compatibility and requires migrating all existing files.

---

## §4 — IAM permission set for Kafka Connect workers

**Decision**: Connect IAM policy includes:
1. `kafka-cluster:Connect` + `kafka-cluster:DescribeCluster` on the cluster ARN
2. `kafka-cluster:DescribeTopic` + `kafka-cluster:WriteData` on all source business topic ARNs
3. `kafka-cluster:DescribeTopic` + `kafka-cluster:WriteData` + `kafka-cluster:ReadData` on all system topic ARNs (connect workers both produce and consume their system topics)
4. `kafka-cluster:AlterGroup` + `kafka-cluster:DescribeGroup` on `<name>-*` consumer group ARN (connect workers use internal consumer groups for offset management)

**Rationale**: Kafka Connect source connectors write to business topics (produce only). However, all Kafka Connect workers — source and sink — read from and write to the system topics (`connect-config`, `connect-offsets`, `connect-status`) as part of distributed coordination. The consumer group permission is needed because Kafka Connect uses consumer groups internally for partition assignment and rebalancing.

**Alternatives considered**:
- Separate policies for business topics and system topics — rejected: no benefit; a single merged policy is simpler and easier to audit.
- Granting `ReadData` on all business topics too — rejected: the UE connect server is a source connector (producer), not a sink. Least-privilege means write-only for business topics.

---

## §5 — Migration approach: two-phase vs. atomic

**Decision**: Document the atomic single-PR migration path as the default, with a two-phase option called out as a lower-risk alternative.

**Atomic (single PR)**: Add `ue-connect.yaml` + remove `producer` blocks from `ue/siq.yaml` and `ue/uiq.yaml` in one PR. `terraform apply` destroys the two old producer roles and creates the one connect role in a single operation. There is a brief window during apply where neither the old nor the new role exists. Mitigate by applying during a maintenance window.

**Two-phase (lower risk)**: PR 1 — add `ue-connect.yaml` only; `terraform apply` creates the new role without touching the old ones. Validate the new role works. PR 2 — remove `producer` blocks from `ue/siq.yaml` and `ue/uiq.yaml`; `terraform apply` destroys the old roles. The two-phase approach is recommended if the UE team cannot tolerate even a brief access gap.

**Rationale**: The two-phase approach is safer for production but requires two PRs and two applies. The spec calls it out so implementers can choose based on the UE team's availability for a maintenance window.
