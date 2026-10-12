#!/usr/bin/env python3
"""Standard subagent ACP fixture, with independent overlapping tool identities."""
import json
import sys

root = "work-root"
pending = None
outstanding = set()
replies = []
capabilities = {}

def send(**message):
    print(json.dumps(dict(jsonrpc="2.0", **message)), flush=True)

def update(owner, **value):
    send(method="session/update", params=dict(sessionId=owner, update=value))

def text(owner, value):
    update(owner, sessionUpdate="agent_message_chunk", content=dict(type="text", text=value))

def announce(owner, child, name):
    update(owner, sessionUpdate="subagent_spawned", subagentSessionId=child, name=name, task="Inspect fixture files", capabilities={})

def history():
    announce(root, "left", "Explorer")
    announce(root, "right", "Tester")
    announce("left", "nested", "Nested explorer")
    for owner in [root, "left", "right", "nested"]:
        update(owner, sessionUpdate="tool_call", toolCallId="same-id", title=owner, rawInput=dict(command="printf " + owner), status="completed")
        text(owner, "History of " + owner)

for line in sys.stdin:
    message = json.loads(line)
    method, ident, params = message.get("method"), message.get("id"), message.get("params", {})
    if method == "initialize":
        capabilities = params.get("clientCapabilities", {})
        send(id=ident, result=dict(protocolVersion=1, agentInfo=dict(name="subagent-fixture", version="1"), agentCapabilities=dict(loadSession=True, sessionCapabilities=dict(subagents={}))))
    elif method == "session/new":
        send(id=ident, result=dict(sessionId=root))
    elif method == "session/load":
        root = params.get("sessionId", root)
        history()
        for child, parent in [("left", root), ("right", root), ("nested", "left")]:
            update(parent, sessionUpdate="subagent_state_update", subagentSessionId=child, state="completed")
        send(id=ident, result=dict(sessionId=root))
    elif method == "session/fork":
        send(id=ident, result=dict(sessionId=root + "-fork"))
    elif method == "session/prompt":
        pending = ident
        history()
        for owner in ["left", "right"]:
            callback = "permission-" + owner
            outstanding.add(callback)
            send(id=callback, method="session/request_permission", params=dict(sessionId=owner, toolCall=dict(toolCallId="same-id", title="Thin child request"), options=[dict(optionId="allow-" + owner, name="Allow once", kind="allow_once"), dict(optionId="deny-" + owner, name="Deny", kind="reject_once")]))
        outstanding.add("question-nested")
        send(id="question-nested", method="elicitation/create", params=dict(sessionId="nested", mode="form", message="Which fixture choice?", requestedSchema=dict(type="object", required=["answer"], properties=dict(answer=dict(type="string")))))
    elif ident in outstanding and method is None:
        outstanding.remove(ident)
        replies.append(message)
        if not outstanding and pending is not None:
            for child, parent, state in [("left", root, "completed"), ("right", root, "failed"), ("nested", "left", "completed")]:
                update(parent, sessionUpdate="subagent_state_update", subagentSessionId=child, state=state)
            text(root, "Root finished")
            send(id=pending, result=dict(stopReason="end_turn"))
            pending = None
    elif method == "session/cancel":
        for child, parent in [("left", root), ("right", root), ("nested", "left")]:
            update(parent, sessionUpdate="subagent_state_update", subagentSessionId=child, state="cancelled")
        if pending is not None:
            send(id=pending, result=dict(stopReason="cancelled")); pending = None
    elif method == "fixture/state":
        send(id=ident, result=dict(capabilities=capabilities, replies=replies))
    elif method == "fixture/late-child":
        text("left", " output after main idle")
        send(id=ident, result={})
    elif method == "fixture/start-background":
        announce(root, "background", "Background checker")
        text("background", "Background work is running")
        send(id=ident, result={})
    elif method == "fixture/background-finished":
        text("background", " and now finished")
        update(root, sessionUpdate="subagent_state_update", subagentSessionId="background", state="completed")
        send(id=ident, result={})
    elif method == "fixture/idle-question":
        outstanding.add("question-idle")
        send(id="question-idle", method="elicitation/create", params=dict(sessionId="left", mode="form", message="Answer while main chat is idle", requestedSchema=dict(type="object", properties=dict(answer=dict(type="string")))))
        send(id=ident, result={})
    elif method == "fixture/unknown":
        text("foreign", "Never render this")
        send(id="unknown-permission", method="session/request_permission", params=dict(sessionId="foreign", toolCall=dict(toolCallId="same-id"), options=[]))
        send(id=ident, result={})
    elif ident == "unknown-permission":
        replies.append(message)
    elif method == "fixture/child-plan":
        outstanding.add("permission-plan")
        send(id="permission-plan", method="session/request_permission", params=dict(sessionId="left", toolCall=dict(toolCallId="plan", name="ExitPlanMode", rawInput=dict(plan="Child plan")), options=[dict(optionId="reject-plan", name="Revise", kind="reject_once")]))
        send(id=ident, result={})
