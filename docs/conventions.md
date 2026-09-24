# Logging and Error-Handling Conventions

Applies to every runtime in this repo that logs anything - Lambda handlers,
Airflow DAGs/operators, MWAA bootstrap scripts, CI validation scripts. The
goal is that a log line reads the same way regardless of which part of the
codebase emitted it, and regardless of whether a human or an AI tool is the
one reading it.

## Format

Prefer structured (JSON) logs over free-form text, wherever the runtime's
logging setup supports it. Structured fields are what make logs searchable
and machine-parseable after the fact - a free-form message can still carry
the human-readable summary as one field within that structure.

This is a default, not a mandate: for human-facing output - CI/CD pipeline
steps, CLI validation scripts, anything whose primary reader is a person
watching a terminal or an Actions log in the moment, not a log aggregator -
use judgement on structured vs. plain text. JSON logs in CI/CD output are
genuinely harder for a human to scan, and these scripts usually don't have
anything downstream parsing them. The other rules on this page (pairing,
suffixes, bracketed values, log levels) still apply either way.

Never put PII in a log message or a structured field - no raw user
identifiers, emails, or similar.

## Message conventions

- Suffix a message with `...` when it announces the **start** of an
  operation: `Sending request to [https://x]...`
- Suffix a message with `.` when it confirms **completion**:
  `Received response from [https://x].`
- Pair every start-of-operation log with an end-of-operation log, for any
  operation that has failure potential. An unmatched `Sending request to
  X...` with nothing following it is the most common way to lose the actual
  failure signal - if the operation fails, that has to be visible in the
  logs too, not just the fact that it was attempted.
- Wrap any value interpolated directly into a message in square brackets:
  `Sending request to [https://x]...`, not `Sending request to https://x...`.
  This makes truncation and unexpected or empty values visually obvious - a
  message ending in a stray `[` or containing `[]` is an immediate tell,
  where a bare interpolated value just blends into the surrounding text.
- In Python, build the message with an f-string rather than the stdlib
  `logging` module's lazy `%s` args - keeps the interpolation and its
  brackets visually together at the call site instead of split across a
  format string and a separate args list.

## Log levels

The distinction is **recoverable vs. unrecoverable**, not **expected vs.
unexpected**. Code catching an exception and turning it into a clean `FAIL`
result instead of crashing the process is expected, handled control flow -
but if the operation itself still didn't achieve its goal (it timed out,
exhausted its retries, or otherwise never completed), that's a real failure
and belongs at ERROR regardless of how gracefully it was handled. Handling a
failure well doesn't make the underlying event non-erroneous.

- **ERROR**: the operation didn't complete as intended - timed out,
  exhausted retries, or otherwise failed to achieve its goal. The test is
  "did this operation fail," not "did the code crash."
- **WARN**: the operation still succeeded, but by a degraded or notable
  path - a retry that then succeeded, a fallback used because the preferred
  path wasn't available, or a best-effort/optional step that didn't succeed
  but wasn't required for the surrounding operation's success.
