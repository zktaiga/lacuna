# Lacuna local MCP primitives

Local stdio adapter for the existing authenticated Lacuna release. It exposes
exactly five tools: `availability`, `bookings`, `book`, `replace`, and `cancel`.
Availability includes the court catalog; there is no planner, optimizer, general
RPC tool, preference store, HTTP listener, or separate provider login.

## Install and launch

From the repository root, sync the isolated project environment:

```sh
uv sync --locked --directory integrations/mcp
```

The stdio launch command (verified by the real MCP discovery test) is:

```sh
uv run --locked --directory integrations/mcp python server.py
```

`uv` manages the local `.venv`; nothing is installed into system Python or the
Hermes runtime. `uv.lock` locks the official MCP Python SDK 1.30.0 and its
transitive dependencies. The `<2` dependency bound intentionally uses the SDK's
supported FastMCP v1 maintenance line, not the separate `fastmcp` package.
This directory does not configure Hermes, deploy Lacuna, or start a public port.
The target release must provide `Lacuna.Agent.dispatch_json/1` before real tool
reads or mutations can work.

Optional environment variables:

| Name | Default | Validation |
| --- | --- | --- |
| `LACUNA_CONTAINER` | `lacuna` | Docker name: leading alphanumeric, then alphanumeric, `_`, `.`, `-`; at most 128 characters |
| `LACUNA_RPC_TIMEOUT_SECONDS` | `60` | Finite number from 1 through 300 seconds |

The adapter runs an argument-array subprocess, never a shell:
`docker exec <container> /app/bin/lacuna rpc <fixed expression>`.
Only base64-encoded JSON is inserted into the fixed dispatch expression. The
release response must contain exactly one `LACUNA_AGENT_JSON:` line with a valid
`{ok: true, data: {...}}` or `{ok: false, error: {code, message}}` envelope.
Incidental stdout logs are ignored; stderr, invalid stdout, and exception details
are not returned to clients. Replacement errors retain Lacuna's optional
`old_booking_cancelled` and sanitized `cause` fields.

## Tool contract and approval

- `availability(date_from, date_to, court_ids=None)` reads the inclusive
  court-local date range. Dates use `YYYY-MM-DD`. Lacuna enforces its booking
  window and returns catalog, normalized slots, eligibility, fee, timestamps,
  and partial-read errors. An unsuccessful read is not an empty calendar.
- `bookings()` reads current upcoming bookings and readable references.
- `book(slot, confirmed=False)` books the exact approved slot without silently
  cancelling another reservation.
- `replace(slot, booking_id, expected_booking, confirmed=False)` cancels the
  identified booking and attempts the exact target. **The old booking may be
  lost if the replacement fails; no rollback is promised.**
- `cancel(booking_id, expected_booking, confirmed=False)` cancels only the
  explicitly approved booking after Lacuna checks its expected identity.

`slot` and `expected_booking` each require exactly `court_id`, `date`,
`start_time`, and `end_time`. Times are court-local `HH:MM` or `HH:MM:SS`; copy
identities from fresh reads rather than rewriting them. IDs are strings.
Unknown nested slot fields are rejected. Normalized slot fields include
`court_id`, `court_name`, `date`, `start_time`, `end_time`, `slot_id`, `fee_aed`,
and `eligibility`; booking fields include `booking_id`, `reference`, `court_id`,
`court_name`, `date`, `start_time`, `end_time`, and `status`. Domain data comes
from Lacuna, not from a duplicate provider implementation.

The model should read, reason about a proposal in conversation, and wait for
explicit user approval of every exact action before calling any mutation.
Replacement approval must include both cancellation and creation, with the
loss risk disclosed. `confirmed=true` is only a caller acknowledgement; it is
**not an authorization mechanism**. Missing/false confirmation makes no RPC.
Never silently substitute slots. On failure, stop, read bookings, and report the
actual state before requesting approval for anything further. A timeout only
ends the Docker client wait; it cannot establish whether a provider mutation
completed. Do not assume rollback or automatically retry.

## Verification

```sh
uv run --locked --directory integrations/mcp pytest -q
uv run --locked --directory integrations/mcp ruff check server.py test_server.py
uv run --locked --directory integrations/mcp ruff format --check server.py test_server.py
```

Tests cover routing, safe payload encoding, normalized fixture responses,
replacement-loss metadata, sanitized transport errors, timeouts, configuration,
invalid inputs, confirmation guards, and malformed/duplicate response markers.
A real MCP client initializes the production entrypoint using the exact launch
command and checks all five tool schemas, annotations, and unconfirmed guards.
A separate real stdio client invokes both read tools against a **test-only mock
RPC runner with synthetic data**. No test issues live Docker RPC reads or
mutations; no production fixture mode exists.

SDK references used: the official `modelcontextprotocol/python-sdk` repository's
`v1.30.0` `README.md`, `docs/server.md`, and `docs/client.md`, plus inspected
installed SDK APIs. The current main branch describes v2; use versioned v1
references for this adapter's FastMCP and ClientSession APIs.
