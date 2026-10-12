#!/usr/bin/env python3
"""Negotiated private child Stop, with explicit parent query ownership."""
import json
import sys
import time

root = "stop-root"
children = {}
stops = []
cancels = 0
failure = None
replies = []

def send(**message):
    print(json.dumps(dict(jsonrpc="2.0", **message)), flush=True)

def update(parent, **value):
    send(method="session/update", params=dict(sessionId=parent, update=value))

def announce(child):
    handle = "ccode-subagent:fixture-" + child
    children[child] = dict(handle=handle, state="running")
    update(root, sessionUpdate="subagent_spawned", subagentSessionId=child, name=child, task="Disposable task",
           capabilities=dict(_meta=dict(ccode=dict(stopTask=dict(version=1, method="_session/async_task/stop", taskId=handle)))))

for line in sys.stdin:
    message = json.loads(line)
    method, ident, params = message.get("method"), message.get("id"), message.get("params", {})
    if method is None:
        replies.append(message)
    elif method == "initialize":
        send(id=ident, result=dict(protocolVersion=1, agentInfo=dict(name="stop-fixture"),
             _meta=dict(ccode=dict(nativeSubagentStop=dict(version=1, stopMethod="_session/async_task/stop")))))
    elif method == "session/new":
        send(id=ident, result=dict(sessionId=root))
    elif method == "session/prompt":
        if not children:
            announce("left")
            announce("right")
        update(root, sessionUpdate="agent_message_chunk", content=dict(type="text", text="Parent response"))
        send(id=ident, result=dict(stopReason="end_turn"))
    elif method == "_session/async_task/stop":
        stops.append(params)
        time.sleep(0.03)
        if failure == "error":
            failure = None
            send(id=ident, error=dict(code=-32000, message="Child Stop rejected"))
        elif failure == "false":
            failure = None
            send(id=ident, result=dict(stopped=False))
        else:
            child = next((key for key, value in children.items() if value["handle"] == params.get("asyncTaskId") and value["state"] == "running"), None)
            if child is None or params.get("sessionId") != root:
                send(id=ident, result=dict(stopped=False))
            else:
                children[child]["state"] = "cancelled"
                update(root, sessionUpdate="subagent_state_update", subagentSessionId=child, state="cancelled")
                send(id=ident, result=dict(stopped=True))
    elif method == "session/cancel":
        cancels += 1
    elif method == "fixture/fail-next-stop":
        failure = params.get("kind", "error")
        send(id=ident, result={})
    elif method == "fixture/state":
        send(id=ident, result=dict(stops=stops, cancels=cancels, children=children, replies=replies))
    elif method == "fixture/child-tools":
        for owner in [root, "left", "right"]:
            update(owner, sessionUpdate="tool_call", toolCallId="same", name="Read", title="Read owned file", status="in_progress",
                   rawInput=dict(file_path=owner + "/file"))
        send(id=ident, result={})
    elif method == "fixture/decisions":
        for owner in [root, "left", "right"]:
            send(id="permission-" + owner, method="session/request_permission", params=dict(sessionId=owner,
                 toolCall=dict(toolCallId=owner, title="Disposable decision"),
                 options=[dict(optionId="allow", name="Allow once", kind="allow_once")]))
            send(id="question-" + owner, method="elicitation/create", params=dict(sessionId=owner, mode="form",
                 message="Disposable question", requestedSchema=dict(type="object", properties=dict(answer=dict(type="string")))))
        send(id=ident, result={})
    elif method == "fixture/announce":
        announce(params["child"])
        send(id=ident, result={})
    elif ident is not None:
        send(id=ident, result={})
