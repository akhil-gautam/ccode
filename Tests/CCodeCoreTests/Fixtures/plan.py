"""Interactive plan peer. Exact opaque choices, cancellation and real client writes."""
import json
import sys

def send(**message):
    print(json.dumps(dict(jsonrpc="2.0", **message)), flush=True)

session = "plan-session"
active = None
permissions = {}
prompts = []
choices = []
root = None
revision = False

def permission(ident, name, raw=None):
    permissions[ident] = name
    options = [dict(optionId="opaque-accept:" + ident, name="Approve exactly this action", kind="allow_once"),
               dict(optionId="opaque-reject:" + ident, name="No, keep planning" if name == "ExitPlanMode" else "Deny", kind="reject_once")]
    send(id=ident, method="session/request_permission", params=dict(sessionId=session, toolCall=dict(toolCallId=ident, title="Approve Plan" if name == "ExitPlanMode" else name, kind="switch_mode", rawInput=raw or {}, name=name), options=options))

def exit_plan():
    ident = "exit-revised" if revision else "exit-original"
    plan = "# Implementation plan\n\n" + ("Use SQLite, then run the test." if revision else "Use a JSON file, then run the test.")
    send(method="session/update", params=dict(sessionId=session, update=dict(sessionUpdate="tool_call", toolCallId=ident + "-write", name="Write", title="Write plan", kind="edit", status="completed", rawInput=dict(file_path=root + "/.claude/plans/fixture.md", content=plan))))
    send(method="session/update", params=dict(sessionId=session, update=dict(sessionUpdate="tool_call", toolCallId=ident, name="ExitPlanMode", title="Approve Plan", kind="switch_mode", status="pending", rawInput={})))
    # Permission input may omit the plan already carried by the identified tool update.
    permission(ident, "ExitPlanMode")

for line in sys.stdin:
    message = json.loads(line)
    method, ident = message.get("method"), message.get("id")
    if method == "initialize":
        send(id=ident, result=dict(protocolVersion=1, agentInfo=dict(name="@agentclientprotocol/claude-agent-acp", version="0.84.0"), agentCapabilities=dict(loadSession=True)))
    elif method in ("session/new", "session/load"):
        root = message["params"]["cwd"]
        send(id=ident, result=dict(sessionId=session))
    elif method == "session/prompt":
        if active is not None:
            send(id=ident, error=dict(code=-32000, message="Concurrent prompt"))
            continue
        active = ident
        prompts.append(message["params"])
        text = " ".join(b.get("text", "") for b in message["params"]["prompt"])
        revision = len(prompts) > 1
        if "simultaneous" in text:
            permission("parallel-one", "Bash", dict(command="printf one"))
            permission("parallel-two", "Bash", dict(command="printf two"))
        elif revision:
            exit_plan()
        else:
            permission("enter", "EnterPlanMode")
    elif ident in permissions:
        name = permissions.pop(ident)
        outcome = message.get("result", {}).get("outcome", {})
        choices.append(dict(id=ident, outcome=outcome))
        accepted = outcome.get("optionId") == "opaque-accept:" + ident
        if ident.startswith("parallel"):
            if not permissions:
                send(id=active, result=dict(stopReason="end_turn")); active = None
        elif name == "EnterPlanMode" and accepted:
            exit_plan()
        elif name == "ExitPlanMode" and accepted:
            send(id="write", method="fs/write_text_file", params=dict(sessionId=session, path=root + "/plan-result.txt", content="sqlite" if revision else "json"))
        else:
            send(id=active, result=dict(stopReason="cancelled")); active = None
    elif ident == "write":
        send(method="session/update", params=dict(sessionId=session, update=dict(sessionUpdate="agent_message_chunk", content=dict(type="text", text="Implemented the approved plan."))))
        send(id=active, result=dict(stopReason="end_turn")); active = None
    elif method == "session/cancel":
        permissions.clear()
        if active is not None:
            send(id=active, result=dict(stopReason="cancelled")); active = None
    elif method == "fixture/state":
        send(id=ident, result=dict(prompts=prompts, choices=choices))
    elif method:
        send(id=ident, error=dict(code=-32601, message="Unknown method"))
