"""Check both permission/cancel orderings against the deterministic ACP fixture."""
import json
import pathlib
import subprocess
import sys

fixture = pathlib.Path(__file__).resolve().parents[1] / "Tests/CCodeCoreTests/Fixtures/agent.py"
cancel = dict(method="session/cancel", params=dict(sessionId="fixture-session"))
reply = dict(id="permission-1", result=dict(outcome=dict(outcome="cancelled")))
for ordering in [(cancel, reply), (reply, cancel)]:
    messages = [
        dict(id=1, method="initialize", params=dict(protocolVersion=1)),
        dict(id=2, method="session/new", params=dict(cwd="/tmp", mcpServers=[])),
        dict(id=3, method="session/prompt", params=dict(sessionId="fixture-session", prompt=[dict(type="text", text="Cancel test")])),
        *ordering,
        dict(id=4, method="fixture/config", params={}),
    ]
    run = subprocess.run([sys.executable, str(fixture)], input="".join(json.dumps(dict(jsonrpc="2.0", **m)) + "\n" for m in messages), text=True, capture_output=True, timeout=5, check=True)
    responses = [json.loads(line) for line in run.stdout.splitlines() if "method" not in json.loads(line)]
    assert all(isinstance(m.get("id"), int) for m in responses), responses
    completed = [m for m in responses if m["id"] == 3]
    assert len(completed) == 1 and completed[0]["result"]["stopReason"] == "cancelled", completed
    assert any(m["id"] == 4 for m in responses), responses
print("Both permission/cancel orderings return one valid cancelled response and retain the connection.")
