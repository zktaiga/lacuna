"""Local stdio primitives; authenticated provider work stays in Lacuna."""

from __future__ import annotations

import base64
import json
import math
import os
import re
import subprocess
from collections.abc import Callable
from datetime import date as calendar_date
from typing import Annotated, Any, Literal

from mcp.server.fastmcp import FastMCP
from mcp.types import CallToolResult, TextContent, ToolAnnotations
from pydantic import AfterValidator, BaseModel, ConfigDict, Field, TypeAdapter, ValidationError

MARKER = "LACUNA_AGENT_JSON:"
OPERATIONS = frozenset({"availability", "bookings", "book", "replace", "cancel"})


def validate_date(value: str) -> str:
    calendar_date.fromisoformat(value)
    return value


DateString = Annotated[
    str, Field(strict=True, pattern=r"^\d{4}-\d{2}-\d{2}$"), AfterValidator(validate_date)
]
TimeString = Annotated[str, Field(strict=True, pattern=r"^(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?$")]
Identifier = Annotated[str, Field(strict=True, min_length=1, max_length=256)]
Confirmation = Annotated[bool, Field(strict=True)]


class Slot(BaseModel):
    """Exact court-local slot identity copied from availability or bookings."""

    model_config = ConfigDict(extra="forbid", strict=True)
    court_id: Identifier
    date: DateString
    start_time: TimeString
    end_time: TimeString


class Success(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    ok: Literal[True]
    data: dict[str, Any]


class DomainError(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    code: Annotated[str, Field(min_length=1)]
    message: Annotated[str, Field(min_length=1)]
    old_booking_cancelled: bool | None = None
    cause: DomainError | None = None


class Failure(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    ok: Literal[False]
    error: DomainError


ENVELOPE = TypeAdapter(Annotated[Success | Failure, Field(discriminator="ok")])


def error(code: str, message: str) -> dict[str, Any]:
    return {"ok": False, "error": {"code": code, "message": message}}


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key")
        result[key] = value
    return result


def reject_constant(value: str) -> None:
    raise ValueError("Non-JSON constant")


class RpcClient:
    """Only fixed operations and base64 JSON can enter the release expression."""

    def __init__(self, runner: Callable[..., subprocess.CompletedProcess[str]] | None = None):
        self.runner = runner if runner is not None else subprocess.run

    def dispatch(self, operation: str, params: dict[str, Any]) -> dict[str, Any]:
        if operation not in OPERATIONS:
            return error("invalid_operation", "Unsupported Lacuna operation.")
        container = os.environ.get("LACUNA_CONTAINER", "lacuna")
        try:
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", container):
                raise ValueError("Invalid container")
            timeout = float(os.environ.get("LACUNA_RPC_TIMEOUT_SECONDS", "60"))
            if not math.isfinite(timeout) or not 1 <= timeout <= 300:
                raise ValueError("Invalid timeout")
        except ValueError:
            return error("invalid_config", "Invalid Lacuna container or RPC timeout configuration.")

        try:
            payload = json.dumps(
                {"operation": operation, "params": params}, ensure_ascii=False, allow_nan=False
            ).encode("utf-8")
        except (TypeError, ValueError, UnicodeError):
            return error("invalid_request", "Could not encode Lacuna operation params.")
        encoded = base64.b64encode(payload).decode("ascii")
        expression = (
            'IO.puts("LACUNA_AGENT_JSON:" <> '
            f'Lacuna.Agent.dispatch_json(Base.decode64!("{encoded}")))'
        )
        try:
            completed = self.runner(
                ["docker", "exec", container, "/app/bin/lacuna", "rpc", expression],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                encoding="utf-8",
                timeout=timeout,
                check=False,
                shell=False,
            )
        except subprocess.TimeoutExpired:
            return error(
                "rpc_timeout",
                "Lacuna RPC timed out. A mutation may have completed; re-read bookings before "
                "retrying, and obtain approval for any further changes.",
            )
        except (OSError, subprocess.SubprocessError, UnicodeError):
            return error(
                "rpc_unavailable",
                "Could not complete Lacuna RPC. A mutation may have completed; "
                "re-read bookings before retrying.",
            )
        if completed.returncode != 0:
            return error(
                "rpc_failed",
                "Lacuna RPC failed. A mutation may have completed; re-read bookings before retrying.",
            )
        try:
            stdout = completed.stdout
            if not isinstance(stdout, str) or stdout.count(MARKER) != 1:
                raise ValueError("Expected exactly one marker")
            lines = [line[len(MARKER) :] for line in stdout.splitlines() if line.startswith(MARKER)]
            if len(lines) != 1:
                raise ValueError("Missing marker line")
            envelope = json.loads(
                lines[0], object_pairs_hook=unique_object, parse_constant=reject_constant
            )
            # bool must not be silently coerced from integers or strings.
            if not isinstance(envelope, dict) or type(envelope.get("ok")) is not bool:
                raise ValueError("Invalid status")
            return ENVELOPE.validate_python(envelope).model_dump(exclude_unset=True)
        except (ValueError, ValidationError, TypeError):
            return error(
                "invalid_response",
                "Lacuna returned an invalid RPC response. A mutation may have completed; "
                "re-read bookings before retrying.",
            )


def tool_result(envelope: dict[str, Any]) -> CallToolResult:
    return CallToolResult(
        content=[TextContent(type="text", text=json.dumps(envelope, ensure_ascii=False))],
        structuredContent=envelope,
        isError=not envelope["ok"],
    )


def create_server(rpc: RpcClient | None = None) -> FastMCP:
    client = rpc if rpc is not None else RpcClient()
    server = FastMCP(
        "lacuna",
        instructions=(
            "Use availability and bookings to reason about a proposal. There is no planning tool. "
            "Before any mutation, obtain explicit user approval for its exact slot and any "
            "cancellation. confirmed is a caller acknowledgement, not authorization. "
            "Never silently substitute a slot or assume rollback; after a failure, stop and "
            "re-read bookings to report the actual state."
        ),
    )
    read_annotations = ToolAnnotations(
        readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=True
    )

    def mutation_annotations(destructive: bool) -> ToolAnnotations:
        return ToolAnnotations(
            readOnlyHint=False,
            destructiveHint=destructive,
            idempotentHint=False,
            openWorldHint=True,
        )

    def mutate(operation: str, params: dict[str, Any], confirmed: bool) -> CallToolResult:
        if confirmed is not True:
            return tool_result(
                error(
                    "confirmation_required",
                    "Obtain explicit user approval of this exact action before setting confirmed=true. "
                    "No RPC was executed; confirmed is an acknowledgement, not authorization.",
                )
            )
        return tool_result(client.dispatch(operation, {**params, "confirmed": True}))

    @server.tool(annotations=read_annotations)
    def availability(
        date_from: DateString, date_to: DateString, court_ids: list[Identifier] | None = None
    ) -> CallToolResult:
        """Read court catalog and slots for an inclusive court-local date range; no booking changes.

        Includes held slots, eligibility, fees, observed timestamps and partial-read errors.
        Omit court_ids to include all courts. Use exact returned identities; do not treat a failed
        or partial read as an empty calendar. Lacuna enforces its supported booking window.
        """
        if date_from > date_to:
            return tool_result(error("invalid_request", "date_from must not be after date_to."))
        params: dict[str, Any] = {"date_from": date_from, "date_to": date_to}
        if court_ids is not None:
            params["court_ids"] = court_ids
        return tool_result(client.dispatch("availability", params))

    @server.tool(annotations=read_annotations)
    def bookings() -> CallToolResult:
        """Read upcoming account bookings, references, status and exact court/date/time identities.

        No booking changes. Use these identities as expected_booking for cancel or replace.
        """
        return tool_result(client.dispatch("bookings", {}))

    @server.tool(annotations=mutation_annotations(False))
    def book(slot: Slot, confirmed: Confirmation = False) -> CallToolResult:
        """Book only this exact slot after explicit user approval of court, date and start/end time.

        Set confirmed=true only after that approval; it is not an authorization mechanism.
        Does not silently cancel an existing booking or substitute another slot. Lacuna rechecks
        availability and eligibility. On failure, stop and re-read bookings before proposing changes.
        """
        return mutate("book", {"slot": slot.model_dump()}, confirmed)

    @server.tool(annotations=mutation_annotations(True))
    def replace(
        slot: Slot,
        booking_id: Identifier,
        expected_booking: Slot,
        confirmed: Confirmation = False,
    ) -> CallToolResult:
        """Cancel this exact existing booking then book the exact target, only with explicit approval.

        The user must approve BOTH the identified cancellation and the target court/date/start/end.
        expected_booking must match the current booking. Replacement may lose the old booking if
        the new booking fails; no rollback is promised. Disclose that risk before approval.
        confirmed is an acknowledgement, not authorization. Never silently substitute another slot.
        After any failure, stop and re-read bookings to report the verified state.
        """
        return mutate(
            "replace",
            {
                "slot": slot.model_dump(),
                "booking_id": booking_id,
                "expected_booking": expected_booking.model_dump(),
            },
            confirmed,
        )

    @server.tool(annotations=mutation_annotations(True))
    def cancel(
        booking_id: Identifier, expected_booking: Slot, confirmed: Confirmation = False
    ) -> CallToolResult:
        """Cancel only this exact booking after explicit user approval of that cancellation.

        Copy the booking_id and court/date/start/end into expected_booking from a fresh bookings
        read. Lacuna checks that identity before cancellation. confirmed is an acknowledgement,
        not authorization. On failure, stop and re-read bookings; do not silently retry or substitute.
        """
        return mutate(
            "cancel",
            {"booking_id": booking_id, "expected_booking": expected_booking.model_dump()},
            confirmed,
        )

    return server


if __name__ == "__main__":
    create_server().run(transport="stdio")
