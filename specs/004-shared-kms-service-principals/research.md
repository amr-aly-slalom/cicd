# Research: Shared KMS Key for Multiple Similar Service Principals

**Feature**: `004-shared-kms-service-principals`
**Date**: 2026-06-30
**Status**: Complete — no NEEDS CLARIFICATION items remain

---

## Decision 1: Variable type for `service_principals`

**Decision**: Use `type = set(string)` for the new `service_principals` variable.

**Rationale**: Terraform's `set(string)` type provides native, silent deduplication — if a caller passes duplicate values the Terraform type system collapses them to unique values before any resources are evaluated. This directly satisfies the clarified requirement (silently deduplicate, set semantics, no error raised). Additionally, sets are always sorted alphabetically when converted to a list with `tolist()`, making the generated KMS policy document deterministic and plan-stable regardless of input order.

**Alternatives considered**:
- `list(string)` with explicit `distinct()` call in the policy — rejected: requires implementing deduplication manually and relies on caller awareness; `distinct()` preserves order but not sort order, making policy documents non-deterministic on re-apply.
- Keep `type = string` with a comma-separated convention — rejected: non-idiomatic HCL; requires callers to format strings manually; incompatible with `identifiers` which accepts a native list.

---

## Decision 2: Variable rename — `service_principal` → `service_principals`

**Decision**: Rename the variable from `service_principal` (singular) to `service_principals` (plural).

**Rationale**: Plural naming clearly communicates the set/list nature of the input and prevents callers from mistakenly passing a bare string. The rename is a breaking change at the module interface level, but the caller update in `terraform/locals.tf` is atomic with the module change in the same commit, so no intermediate broken state exists.

**Alternatives considered**:
- Keep `service_principal` and change its type — rejected: a singular-named variable of type `set(string)` is semantically inconsistent and would confuse future contributors.

---

## Decision 3: Validation — reject empty set at plan time

**Decision**: Add a Terraform `validation` block requiring `length(var.service_principals) > 0`.

**Rationale**: Terraform `validation` blocks fire during `terraform plan` before any AWS API calls are made, surfacing a clear, human-readable error message. An empty set passed to `identifiers` in the policy document would produce a malformed policy statement, which would fail with a cryptic AWS API error only during `terraform apply`.

**Alternatives considered**:
- No validation, rely on AWS API error — rejected: deferred error reporting leads to slow feedback loops and opaque error messages that are hard to trace back to the configuration mistake.

---

## Decision 4: KMS key policy structure — one shared statement vs. N dynamic statements

**Decision**: Keep a single `AllowServiceAccess` statement and set `identifiers = tolist(var.service_principals)`.

**Rationale**: A single statement is the minimal change from the current design (which uses `identifiers = [var.service_principal]`). AWS KMS evaluates all principals listed in a single `identifiers` array identically to separate statements. Keeping one statement means that when `service_principals` has a single element, the generated policy JSON is byte-for-byte identical to the pre-change policy, guaranteeing the `terraform plan` zero-change requirement for existing entries.

**Alternatives considered**:
- `dynamic` statement block with one statement per principal — rejected: more complex Terraform code; a single-element `dynamic` block produces different plan output from the current non-dynamic approach, meaning existing entries would show a plan diff (violates SC-002).

---

## Decision 5: Backward compatibility — updating `kms_services` in `locals.tf`

**Decision**: Update all 4 existing `kms_services` entries from `service_principal = "..."` to `service_principals = ["..."]` in the same commit as the module change.

**Rationale**: The module variable rename (`service_principal` → `service_principals`) is a breaking change at the module API level. All callers must be updated atomically to avoid a broken intermediate state. Wrapping the existing single string in a one-element list is a mechanical, non-semantic change. The AWS provider serialises a single-element list `["x"]` in `identifiers` identically to the previous `["x"]` from the old `[var.service_principal]` form — so `terraform plan` shows zero changes for all 4 entries.

**Alternatives considered**:
- Keep old variable alongside new variable with a deprecation notice — rejected: adds unnecessary complexity and a dead code path; the module is internal to this repository with only 4 call sites, all of which are updated atomically.

---

## Decision 6: Checkov compliance impact

**Decision**: Existing 3 Checkov skip annotations remain unchanged; no new Checkov violations are introduced.

**Rationale**:
- `CKV_AWS_109` (wildcard resource in policy): existing root admin statement; unaffected by principal list change.
- `CKV_AWS_111` (IAM wildcard actions): same root admin statement; unaffected.
- `CKV_AWS_356` (policy allows `*` actions): same root admin statement; unaffected.
No Checkov rule targets the number of service principals in a `Service`-type principal statement. The `AllowServiceAccess` statement already passes all principal-related checks when granting only named actions (not `*`).

**Alternatives considered**: None — Checkov rule set was reviewed and no applicable rules exist for multi-principal service statements.

---

## Summary: All unknowns resolved

| Unknown | Resolution |
|---------|------------|
| Variable type for multi-principal | `set(string)` — native deduplication, deterministic order |
| Variable name | `service_principals` (plural) — renamed atomically with caller updates |
| Empty-set handling | `validation` block at plan time with descriptive error |
| Policy structure | Single `AllowServiceAccess` statement; `identifiers = tolist(var.service_principals)` |
| Backward compat | All 4 existing entries updated atomically; plan shows zero changes |
| Checkov impact | None — existing 3 skips remain; no new violations |
