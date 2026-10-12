#!/usr/bin/env python3
"""Interactive ACP fixture: waits for actual form/URL answers and records replies."""
import json
import sys

pending = None
replies = []
capabilities = {}
audit_path = next((arg.split("=", 1)[1] for arg in sys.argv if arg.startswith("--audit-path=")), None)

def send(**message):
    print(json.dumps(dict(jsonrpc="2.0", **message)), flush=True)

def update(text):
    send(method="session/update", params=dict(sessionId="interactive-session", update=dict(sessionUpdate="agent_message_chunk", content=dict(type="text", text=text))))

for line in sys.stdin:
    message = json.loads(line)
    if audit_path:
        with open(audit_path, "a") as audit:
            audit.write(json.dumps(message) + "\n")
    method = message.get("method")
    ident = message.get("id")
    params = message.get("params", {})
    if method == "initialize":
        capabilities = params.get("clientCapabilities", {})
        send(id=ident, result=dict(protocolVersion=1, agentInfo=dict(name="interaction-fixture", version="1"), agentCapabilities={}))
    elif method in ("session/new", "session/load"):
        if "--request-scope" in sys.argv:
            send(id="setup-interaction", method="elicitation/create", params=dict(mode="form", requestId=ident, message="Confirm launch", requestedSchema=dict(type="object", properties=dict(ready=dict(type="boolean")))))
            setup_request = ident
            continue
        send(id=ident, result=dict(sessionId="interactive-session"))
    elif ident == "setup-interaction":
        replies.append(message)
        send(id=setup_request, result=dict(sessionId="interactive-session"))
    elif method == "session/prompt":
        pending = ident
        text = " ".join(block.get("text", "") for block in params.get("prompt", []))
        if "url" in text:
            send(id="interaction-1", method="elicitation/create", params=dict(mode="url", sessionId="interactive-session", elicitationId="auth-id", url="https://example.com/authorize", message="Connect fixture"))
        elif "wrong owner" in text:
            send(id="interaction-1", method="elicitation/create", params=dict(mode="form", sessionId="other-session", message="Wrong chat", requestedSchema=dict(type="object", properties={})))
        else:
            send(id="interaction-1", method="elicitation/create", params=dict(mode="form", sessionId="interactive-session", toolCallId="ask-1", message="Which storage should I use?", requestedSchema=dict(type="object", required=["storage"], properties=dict(storage=dict(type="string", oneOf=[dict(const="sqlite", title="SQLite"), dict(const="files", title="Files")]), note=dict(type="string", title="Notes")))))
    elif ident == "interaction-1":
        replies.append(message)
        if pending is not None:
            result = message.get("result", {})
            update("Answer received: " + json.dumps(result))
            send(id=pending, result=dict(stopReason="cancelled" if result.get("action") == "cancel" else "end_turn"))
            pending = None
    elif method == "session/cancel":
        if pending is not None:
            send(id=pending, result=dict(stopReason="cancelled"))
            pending = None
    elif method == "fixture/state":
        send(id=ident, result=dict(capabilities=capabilities, replies=replies))
    elif method == "fixture/complete-url":
        send(method="elicitation/complete", params=dict(elicitationId=params.get("elicitationId")))
        send(id=ident, result={})
    elif method == "fixture/exit":
        sys.exit(0)
