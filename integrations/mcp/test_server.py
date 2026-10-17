"""All RPC execution in this suite is mocked; no live booking or read calls."""

import base64
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from unittest.mock import Mock

import anyio
import pytest
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp.server.fastmcp.exceptions import ToolError
from mcp.types import CallToolResult

from server import RpcClient, create_server

PROJECT = Path(__file__).resolve().parent
UV = shutil.which("uv")
SLOT = {
    "court_id": "court-1",
    "date": "2026-10-12",
    "start_time": "17:00:00",
    "end_time": "18:00:00",
}
EXPECTED = {**SLOT, "date": "2026-10-11"}
NORMALIZED_SLOT = {
    **SLOT,
    "court_name": "Synthetic Court",
    "slot_id": "slot-1",
    "fee_aed": 40,
    "eligibility": {"eligible": True, "reason": None},
}
NORMALIZED_BOOKING = {
    **EXPECTED,
    "booking_id": "booking-1",
    "reference": "REF-SYNTHETIC-1",
    "court_name": "Synthetic Court",
    "status": "confirmed",
}
READ_FIXTURES = {
    "availability": {
        "courts": [{"court_id": "court-1", "court_name": "Synthetic Court"}],
        "slots": [NORMALIZED_SLOT],
        "errors": [],
    },
    "bookings": {"bookings": [NORMALIZED_BOOKING]},
}


@pytest.fixture(autouse=True)
def clean_config(monkeypatch):
    monkeypatch.delenv("LACUNA_CONTAINER", raising=False)
    monkeypatch.delenv("LACUNA_RPC_TIMEOUT_SECONDS", raising=False)


def invoke(server, name, params):
    async def call():
        return await server.call_tool(name, params)

    return anyio.run(call)


def runner_output(stdout, returncode=0, stderr="SENSITIVE_DOCKER_STDERR"):
    return Mock(return_value=subprocess.CompletedProcess([], returncode, stdout, stderr))


def test_fixed_expression_contains_only_base64_user_payload():
    calls = []
    params = {"court_ids": ['evil")); System.cmd("sh", ["-c", "false"]); # 漢字']}

    def runner(args, **kwargs):
        calls.append((args, kwargs))
        return subprocess.CompletedProcess(
            args, 0, 'incidental log\nLACUNA_AGENT_JSON:{"ok":true,"data":{"slots":[]}}\n'
        )

    assert RpcClient(runner=runner).dispatch("availability", params) == {
        "ok": True,
        "data": {"slots": []},
    }
    args, kwargs = calls[0]
    assert args[:5] == ["docker", "exec", "lacuna", "/app/bin/lacuna", "rpc"]
    match = re.fullmatch(
        r'IO\.puts\("LACUNA_AGENT_JSON:" <> Lacuna\.Agent\.dispatch_json\(Base\.decode64!\("([A-Za-z0-9+/=]+)"\)\)\)',
        args[5],
    )
    assert match is not None
    assert json.loads(base64.b64decode(match[1])) == {
        "operation": "availability",
        "params": params,
    }
    assert kwargs == {
        "stdin": subprocess.DEVNULL,
        "capture_output": True,
        "text": True,
        "encoding": "utf-8",
        "timeout": 60.0,
        "check": False,
        "shell": False,
    }


@pytest.mark.parametrize("operation", ["availability", "bookings"])
def test_success_keeps_normalized_read_fields_and_partial_errors(operation):
    data = READ_FIXTURES[operation]
    if operation == "availability":
        data = {
            **data,
            "errors": [
                {"court_id": "court-2", "date": "2026-10-12", "code": "provider_unavailable"}
            ],
        }
    envelope = {"ok": True, "data": data}
    runner = runner_output(
        "log before\nLACUNA_AGENT_JSON:" + json.dumps(envelope) + "\nlog after\n"
    )
    assert RpcClient(runner).dispatch(operation, {}) == envelope


def test_domain_error_is_preserved_and_marked_as_mcp_error():
    envelope = {
        "ok": False,
        "error": {
            "code": "replacement_failed_after_cancellation",
            "message": "Old booking cancelled; new booking failed.",
        },
    }
    runner = runner_output("LACUNA_AGENT_JSON:" + json.dumps(envelope))
    result = invoke(
        create_server(RpcClient(runner)),
        "replace",
        {
            "slot": SLOT,
            "booking_id": "booking-1",
            "expected_booking": EXPECTED,
            "confirmed": True,
        },
    )
    assert isinstance(result, CallToolResult)
    assert result.isError is True
    assert result.structuredContent == envelope
    assert json.loads(result.content[0].text) == envelope


def test_replacement_failure_keeps_verified_cancellation_and_safe_cause():
    envelope = {
        "ok": False,
        "error": {
            "code": "replacement_failed",
            "message": "Old booking cancelled; replacement failed. Re-read bookings.",
            "old_booking_cancelled": True,
            "cause": {"code": "transport", "message": "The provider request failed in transport."},
        },
    }
    runner = runner_output("LACUNA_AGENT_JSON:" + json.dumps(envelope))
    result = invoke(
        create_server(RpcClient(runner)),
        "replace",
        {
            "slot": SLOT,
            "booking_id": "booking-1",
            "expected_booking": EXPECTED,
            "confirmed": True,
        },
    )
    assert result.isError is True
    assert result.structuredContent == envelope


@pytest.mark.parametrize(
    "stdout",
    [
        "",
        "incidental logs only",
        "SENSITIVE_STDOUT",
        'LACUNA_AGENT_JSON:{"ok":true,"data":{}}\nLACUNA_AGENT_JSON:{"ok":true,"data":{}}',
        'log with LACUNA_AGENT_JSON: in it\nLACUNA_AGENT_JSON:{"ok":true,"data":{}}',
        'prefix LACUNA_AGENT_JSON:{"ok":true,"data":{}}',
        "LACUNA_AGENT_JSON:not json",
        "LACUNA_AGENT_JSON:null",
        "LACUNA_AGENT_JSON:[]",
        'LACUNA_AGENT_JSON:{"ok":true}',
        'LACUNA_AGENT_JSON:{"ok":true,"data":[]}',
        'LACUNA_AGENT_JSON:{"ok":true,"data":{},"error":{"code":"x","message":"y"}}',
        'LACUNA_AGENT_JSON:{"ok":false,"error":{"code":"x"}}',
        'LACUNA_AGENT_JSON:{"ok":false,"error":{"code":1,"message":"x"}}',
        'LACUNA_AGENT_JSON:{"ok":false,"error":{"code":"","message":"x"}}',
        'LACUNA_AGENT_JSON:{"ok":"true","data":{}}',
        'LACUNA_AGENT_JSON:{"ok":1,"data":{}}',
        'LACUNA_AGENT_JSON:{"ok":true,"ok":false,"data":{}}',
        'LACUNA_AGENT_JSON:{"ok":true,"data":{"value":NaN}}',
        'LACUNA_AGENT_JSON:{"ok":true,"data":{}} trailing',
        'LACUNA_AGENT_JSON:{"ok":true,\n"data":{}}',
    ],
)
def test_malformed_or_ambiguous_stdout_is_sanitized(stdout):
    result = RpcClient(runner_output(stdout)).dispatch("bookings", {})
    assert result["ok"] is False
    assert result["error"]["code"] == "invalid_response"
    assert "SENSITIVE" not in json.dumps(result)


def test_nonzero_exit_ignores_even_valid_stdout_and_private_stderr():
    runner = runner_output('LACUNA_AGENT_JSON:{"ok":true,"data":{}}', returncode=1)
    result = RpcClient(runner).dispatch("bookings", {})
    assert result["error"]["code"] == "rpc_failed"
    assert "SENSITIVE" not in json.dumps(result)


@pytest.mark.parametrize(
    "exception,code",
    [
        (
            subprocess.TimeoutExpired("SECRET_COMMAND", 60, output="SECRET", stderr="SECRET"),
            "rpc_timeout",
        ),
        (FileNotFoundError("SECRET_PATH"), "rpc_unavailable"),
        (PermissionError("SECRET_PATH"), "rpc_unavailable"),
        (subprocess.SubprocessError("SECRET"), "rpc_unavailable"),
        (UnicodeError("SECRET"), "rpc_unavailable"),
    ],
)
def test_runner_exceptions_do_not_reveal_sensitive_details(exception, code):
    result = RpcClient(Mock(side_effect=exception)).dispatch("book", {"slot": SLOT})
    assert result["error"]["code"] == code
    assert "SECRET" not in json.dumps(result)
    if code == "rpc_timeout":
        assert "may have completed" in result["error"]["message"]


@pytest.mark.parametrize("value", ["0", "-1", "301", "nan", "inf", "abc", "", "1e999"])
def test_invalid_timeout_configuration_does_not_execute(monkeypatch, value):
    monkeypatch.setenv("LACUNA_RPC_TIMEOUT_SECONDS", value)
    runner = Mock()
    result = RpcClient(runner).dispatch("bookings", {})
    assert result["error"]["code"] == "invalid_config"
    runner.assert_not_called()


@pytest.mark.parametrize("value", ["", "--privileged", "lacuna;id", "a b", "a\nsecret", "a" * 129])
def test_invalid_container_configuration_does_not_execute(monkeypatch, value):
    monkeypatch.setenv("LACUNA_CONTAINER", value)
    runner = Mock()
    result = RpcClient(runner).dispatch("bookings", {})
    assert result["error"]["code"] == "invalid_config"
    assert value not in result["error"]["message"] if value else True
    runner.assert_not_called()


def test_valid_configuration_controls_only_container_and_timeout(monkeypatch):
    monkeypatch.setenv("LACUNA_CONTAINER", "lacuna-test_1.2")
    monkeypatch.setenv("LACUNA_RPC_TIMEOUT_SECONDS", "12.5")
    runner = runner_output('LACUNA_AGENT_JSON:{"ok":true,"data":{}}')
    assert RpcClient(runner).dispatch("bookings", {})["ok"] is True
    assert runner.call_args.args[0][2] == "lacuna-test_1.2"
    assert runner.call_args.kwargs["timeout"] == 12.5


def test_non_utf8_payload_is_sanitized_without_executing_rpc():
    runner = Mock()
    result = RpcClient(runner).dispatch("availability", {"court_ids": ["\ud800"]})
    assert result == {
        "ok": False,
        "error": {
            "code": "invalid_request",
            "message": "Could not encode Lacuna operation params.",
        },
    }
    runner.assert_not_called()


def test_rpc_operation_allowlist():
    runner = Mock()
    assert RpcClient(runner).dispatch("eval", {})["error"]["code"] == "invalid_operation"
    runner.assert_not_called()


ROUTES = [
    (
        "availability",
        {"date_from": "2026-10-12", "date_to": "2026-10-13"},
        {"date_from": "2026-10-12", "date_to": "2026-10-13"},
    ),
    (
        "availability",
        {"date_from": "2026-10-12", "date_to": "2026-10-13", "court_ids": ["court-1"]},
        {"date_from": "2026-10-12", "date_to": "2026-10-13", "court_ids": ["court-1"]},
    ),
    ("bookings", {}, {}),
    ("book", {"slot": SLOT, "confirmed": True}, {"slot": SLOT, "confirmed": True}),
    (
        "replace",
        {"slot": SLOT, "booking_id": "booking-1", "expected_booking": EXPECTED, "confirmed": True},
        {"slot": SLOT, "booking_id": "booking-1", "expected_booking": EXPECTED, "confirmed": True},
    ),
    (
        "cancel",
        {"booking_id": "booking-1", "expected_booking": EXPECTED, "confirmed": True},
        {"booking_id": "booking-1", "expected_booking": EXPECTED, "confirmed": True},
    ),
]


@pytest.mark.parametrize("operation,arguments,expected_params", ROUTES)
def test_five_tools_route_exactly_without_planning_or_substitution(
    operation, arguments, expected_params
):
    envelope = {"ok": True, "data": {"verified": True}}
    rpc = Mock(spec=RpcClient)
    rpc.dispatch.return_value = envelope
    result = invoke(create_server(rpc), operation, arguments)
    assert result.isError is False
    assert result.structuredContent == envelope
    rpc.dispatch.assert_called_once_with(operation, expected_params)


MUTATIONS = [
    ("book", {"slot": SLOT}),
    ("replace", {"slot": SLOT, "booking_id": "booking-1", "expected_booking": EXPECTED}),
    ("cancel", {"booking_id": "booking-1", "expected_booking": EXPECTED}),
]


@pytest.mark.parametrize("operation,arguments", MUTATIONS)
@pytest.mark.parametrize("confirmation", [None, False])
def test_absent_or_false_confirmation_never_executes_rpc(operation, arguments, confirmation):
    rpc = Mock(spec=RpcClient)
    params = dict(arguments)
    if confirmation is not None:
        params["confirmed"] = confirmation
    result = invoke(create_server(rpc), operation, params)
    assert result.isError is True
    assert result.structuredContent["error"]["code"] == "confirmation_required"
    rpc.dispatch.assert_not_called()


@pytest.mark.parametrize("value", ["true", "false", 1, 0, None])
def test_confirmation_must_be_boolean_and_invalid_input_never_executes(value):
    rpc = Mock(spec=RpcClient)
    with pytest.raises(ToolError):
        invoke(create_server(rpc), "book", {"slot": SLOT, "confirmed": value})
    rpc.dispatch.assert_not_called()


@pytest.mark.parametrize(
    "field,value",
    [
        ("court_id", ""),
        ("court_id", 123),
        ("date", "2026-02-30"),
        ("date", "2026-1-02"),
        ("start_time", "24:00"),
        ("start_time", "17:60"),
        ("end_time", "18:00:99"),
        ("unrecognized", "not allowed"),
    ],
)
def test_invalid_exact_slot_never_executes_rpc(field, value):
    rpc = Mock(spec=RpcClient)
    with pytest.raises(ToolError):
        invoke(create_server(rpc), "book", {"slot": {**SLOT, field: value}, "confirmed": True})
    rpc.dispatch.assert_not_called()


@pytest.mark.parametrize("operation", ["replace", "cancel"])
def test_expected_booking_is_required_for_destructive_actions(operation):
    rpc = Mock(spec=RpcClient)
    params = {"booking_id": "booking-1", "confirmed": True}
    if operation == "replace":
        params["slot"] = SLOT
    with pytest.raises(ToolError):
        invoke(create_server(rpc), operation, params)
    rpc.dispatch.assert_not_called()


def test_reversed_availability_range_never_executes_rpc():
    rpc = Mock(spec=RpcClient)
    result = invoke(
        create_server(rpc),
        "availability",
        {
            "date_from": "2026-10-13",
            "date_to": "2026-10-12",
        },
    )
    assert result.structuredContent["error"]["code"] == "invalid_request"
    rpc.dispatch.assert_not_called()


@pytest.mark.parametrize(
    "params",
    [
        {"date_from": "2026-02-30", "date_to": "2026-10-13"},
        {"date_from": "2026-10-12", "date_to": "2026-10-13", "court_ids": [1]},
    ],
)
def test_invalid_read_parameters_never_execute_rpc(params):
    rpc = Mock(spec=RpcClient)
    with pytest.raises(ToolError):
        invoke(create_server(rpc), "availability", params)
    rpc.dispatch.assert_not_called()


def assert_tool_schemas(tools):
    assert len(tools) == 5
    by_name = {tool.name: tool for tool in tools}
    assert set(by_name) == {"availability", "bookings", "book", "replace", "cancel"}
    expected = {
        "availability": ({"date_from", "date_to", "court_ids"}, {"date_from", "date_to"}),
        "bookings": (set(), set()),
        "book": ({"slot", "confirmed"}, {"slot"}),
        "replace": (
            {"slot", "booking_id", "expected_booking", "confirmed"},
            {"slot", "booking_id", "expected_booking"},
        ),
        "cancel": (
            {"booking_id", "expected_booking", "confirmed"},
            {"booking_id", "expected_booking"},
        ),
    }
    for name, tool in by_name.items():
        schema = tool.inputSchema
        fields, required = expected[name]
        assert set(schema["properties"]) == fields
        assert set(schema.get("required", [])) == required
        assert tool.annotations.openWorldHint is True
        if name in {"availability", "bookings"}:
            assert tool.annotations.readOnlyHint is True
            assert tool.annotations.destructiveHint is False
        else:
            assert tool.annotations.readOnlyHint is False
            assert tool.annotations.idempotentHint is False
            assert tool.annotations.destructiveHint is (name in {"replace", "cancel"})
            assert schema["properties"]["confirmed"]["type"] == "boolean"
            assert schema["properties"]["confirmed"]["default"] is False
            assert "explicit" in tool.description
            assert "authorization" in tool.description
            slot_schema = schema["$defs"]["Slot"]
            assert slot_schema["additionalProperties"] is False
            assert set(slot_schema["properties"]) == {
                "court_id",
                "date",
                "start_time",
                "end_time",
            }
            assert set(slot_schema["required"]) == set(slot_schema["properties"])
    assert "lose the old booking" in by_name["replace"].description
    return by_name


def test_real_mcp_initialization_and_five_schemas_with_exact_launch_command():
    """Real server/stdio; only discovery and unconfirmed mutations, never backend reads."""

    async def check():
        assert UV is not None, "Install uv and make it available on PATH"
        params = StdioServerParameters(
            command=UV,
            args=["run", "--locked", "--directory", str(PROJECT), "python", "server.py"],
            env={"TMPDIR": os.environ["TMPDIR"]} if os.environ.get("TMPDIR") else None,
        )
        with anyio.fail_after(30):
            async with (
                stdio_client(params) as (read, write),
                ClientSession(read, write) as session,
            ):
                initialized = await session.initialize()
                assert initialized.serverInfo.name == "lacuna"
                tools = await session.list_tools()
                assert tools.nextCursor is None
                assert_tool_schemas(tools.tools)
                assert (await session.list_resources()).resources == []
                assert (await session.list_prompts()).prompts == []
                for name, arguments in MUTATIONS:
                    result = await session.call_tool(name, arguments)
                    assert result.isError is True
                    assert result.structuredContent["error"]["code"] == "confirmation_required"

    anyio.run(check)


def test_real_mcp_read_invocation_uses_test_only_mock_rpc_runner():
    """Real MCP client/server routing, but explicitly synthetic provider data."""
    # No runtime environment flag or production entrypoint can activate this fixture runner.
    fixture_json = json.dumps(READ_FIXTURES)
    code = f"""
import base64, json, re, subprocess
from server import RpcClient, create_server
fixtures = json.loads({fixture_json!r})
def runner(args, **kwargs):
    assert args[:5] == ["docker", "exec", "lacuna", "/app/bin/lacuna", "rpc"]
    encoded = re.search(r'Base.decode64!\\("([A-Za-z0-9+/=]+)"\\)', args[5]).group(1)
    request = json.loads(base64.b64decode(encoded))
    assert request["operation"] in fixtures, "Mutations are forbidden in this read fixture"
    payload = {{"ok": True, "data": fixtures[request["operation"]]}}
    return subprocess.CompletedProcess(args, 0, "fixture log\\nLACUNA_AGENT_JSON:" + json.dumps(payload))
create_server(RpcClient(runner=runner)).run(transport="stdio")
"""

    async def check():
        params = StdioServerParameters(command=sys.executable, args=["-c", code], cwd=PROJECT)
        with anyio.fail_after(30):
            async with (
                stdio_client(params) as (read, write),
                ClientSession(read, write) as session,
            ):
                await session.initialize()
                assert_tool_schemas((await session.list_tools()).tools)
                for name, arguments in [
                    ("availability", {"date_from": "2026-10-12", "date_to": "2026-10-12"}),
                    ("bookings", {}),
                ]:
                    result = await session.call_tool(name, arguments)
                    assert result.isError is False
                    assert result.structuredContent == {"ok": True, "data": READ_FIXTURES[name]}
                    assert json.loads(result.content[0].text) == result.structuredContent

    anyio.run(check)
