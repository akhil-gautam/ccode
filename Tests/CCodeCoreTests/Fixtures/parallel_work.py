import json
import os
import sys

label = sys.argv[1]
session = "parallel-" + label
cwd = None
pending = None
text = None

def send(value):
    value["jsonrpc"] = "2.0"
    print(json.dumps(value), flush=True)

def update(value):
    send(dict(method="session/update", params=dict(sessionId=session, update=value)))

for line in sys.stdin:
    message = json.loads(line)
    method, ident = message.get("method"), message.get("id")
    if method == "initialize":
        send(dict(id=ident, result=dict(protocolVersion=1, agentCapabilities=dict(loadSession=True), agentInfo=dict(name="parallel fixture", version="1"))))
    elif method in ("session/new", "session/load"):
        cwd = message["params"]["cwd"]
        send(dict(id=ident, result=dict(sessionId=session)))
    elif method == "session/prompt":
        if "--no-decision" in sys.argv:
            update(dict(sessionUpdate="agent_message_chunk", content=dict(type="text", text="Done without tools")))
            send(dict(id=ident, result=dict(stopReason="end_turn")))
            continue
        pending = ident
        text = "".join(block.get("text", "") for block in message["params"]["prompt"])
        update(dict(sessionUpdate="tool_call", toolCallId="write", title="Write " + label + ".txt", kind="edit", status="pending"))
        send(dict(id="decision", method="session/request_permission", params=dict(sessionId=session,
            toolCall=dict(toolCallId="write", title="Write " + label + ".txt", kind="edit", status="pending"),
            options=[dict(optionId="allow", name="Allow once", kind="allow_once"), dict(optionId="deny", name="Deny", kind="reject_once")])))
    elif ident == "decision":
        if message.get("result", {}).get("outcome", {}).get("optionId") == "allow":
            send(dict(id="write-file", method="fs/write_text_file", params=dict(sessionId=session, path=os.path.join(cwd, label + ".txt"), content=text)))
        else:
            update(dict(sessionUpdate="tool_call_update", toolCallId="write", status="failed"))
            send(dict(id=pending, result=dict(stopReason="cancelled")))
            pending = None
    elif ident == "write-file":
        update(dict(sessionUpdate="tool_call_update", toolCallId="write", status="failed" if "error" in message else "completed"))
        update(dict(sessionUpdate="agent_message_chunk", content=dict(type="text", text="Finished " + label)))
        send(dict(id=pending, result=dict(stopReason="end_turn")))
        pending = None
    elif method == "fixture/identity":
        send(dict(id=ident, result=dict(pid=os.getpid(), cwd=cwd, session=session, text=text)))
    elif method == "session/cancel":
        if pending is not None:
            send(dict(id=pending, result=dict(stopReason="cancelled")))
            pending = None
    elif method:
        send(dict(id=ident, error=dict(code=-32601, message="Unknown method")))
