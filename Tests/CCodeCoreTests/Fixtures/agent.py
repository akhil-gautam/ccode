"""Deterministic ACP peer: exercises real stdio, no network or model."""
import json
import os
import signal
import sys
import time

if "--resist-term" in sys.argv:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)

def send(message, fragmented=True):
    raw = json.dumps(dict(jsonrpc="2.0", **message), ensure_ascii=False).encode() + b"\n"
    # Split UTF-8 and frame boundaries across actual pipe writes.
    step = 7 if fragmented else len(raw)
    for i in range(0, len(raw), step):
        sys.stdout.buffer.write(raw[i:i + step])
        sys.stdout.buffer.flush()

pending = None
authenticated = False
show_tools = False
session = "fixture-session"
config = [
    dict(id="mode", name="Mode", category="mode", type="select", currentValue="default", options=[dict(value="default", name="Manual"), dict(value="plan", name="Plan")]),
    dict(id="model", name="Model", category="model", type="select", currentValue="small", options=[dict(value="small", name="Small"), dict(value="large", name="Large")]),
    dict(id="effort", name="Effort", category="thought_level", type="select", currentValue="normal", options=[dict(group="levels", name="Levels", options=[dict(value="normal", name="Normal")])]),
    dict(id="fast", name="Fast mode", type="boolean", currentValue=False),
]
last_prompt_config = None
legacy = dict(modeId="default", modelId="small")
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    ident = message.get("id")
    config_switch_path = next((arg.split("=", 1)[1] for arg in sys.argv if arg.startswith("--config-switch-path=")), None)
    list_path = next((arg.split("=", 1)[1] for arg in sys.argv if arg.startswith("--list-path=")), None)
    modern_config = "--config" in sys.argv or (config_switch_path is not None and os.path.exists(config_switch_path))
    audit_path = next((arg.split("=", 1)[1] for arg in sys.argv if arg.startswith("--audit-path=")), None)
    if audit_path and method:
        with open(audit_path, "a") as audit_file:
            audit_file.write(json.dumps(dict(method=method, pid=os.getpid(), params=message.get("params", {}))) + "\n")
    if method == "initialize":
        capabilities = {} if "--no-resume" in sys.argv else dict(loadSession=True)
        if "--http-mcp" in sys.argv:
            capabilities["mcpCapabilities"] = dict(http=True)
        if "--attachments" in sys.argv:
            capabilities["promptCapabilities"] = dict(image=True, audio=True)
        session_capabilities = {"list": {}} if list_path else {}
        if any(flag in sys.argv for flag in ["--fork", "--bad-fork", "--slow-fork"]):
            session_capabilities["fork"] = {}
        if "--additional-directories" in sys.argv:
            session_capabilities["additionalDirectories"] = {}
        if "--resume" in sys.argv:
            session_capabilities["resume"] = {}
        if session_capabilities:
            capabilities["sessionCapabilities"] = session_capabilities
        send(dict(id=ident, result=dict(protocolVersion=1, agentCapabilities=capabilities, agentInfo=dict(name="fixture", version="1"), authMethods=[dict(id="fixture-login", name="Fixture login", type="agent")] if "--needs-auth" in sys.argv else [])))
    elif method == "session/list":
        if "--stall-list" in sys.argv:
            time.sleep(60)
        with open(list_path) as catalog_file:
            catalog = json.load(catalog_file)
        offset = int(message.get("params", {}).get("cursor", "0"))
        if "--bad-list-page" in sys.argv and offset:
            send(dict(id=ident, error=dict(code=-32603, message="Catalog unavailable")))
            continue
        page = catalog["sessions"][offset:offset + 2]
        result = dict(sessions=page)
        if offset + 2 < len(catalog["sessions"]):
            result["nextCursor"] = str(offset if "--repeat-list-cursor" in sys.argv else offset + 2)
        send(dict(id=ident, result=result))
    elif method == "authenticate":
        authenticated = message["params"].get("methodId") == "fixture-login"
        send(dict(id=ident, result={}))
    elif method in ("session/new", "session/load", "session/resume"):
        if method in ("session/load", "session/resume") and "--unpersisted-new" in sys.argv:
            with open(audit_path) as audit_file:
                persisted = any(json.loads(line).get("method") == "session/prompt" for line in audit_file)
            if not persisted:
                send(dict(id=ident, error=dict(code=-32002, message="Resource not found: session has no persisted prompt")))
                continue
        if method == "session/load" and "--slow-load" in sys.argv:
            time.sleep(1)
        if "--stall-new" in sys.argv:
            time.sleep(60)
        if "--slow-new" in sys.argv:
            time.sleep(1)
        if "--needs-auth" in sys.argv and not authenticated:
            send(dict(id=ident, error=dict(code=-32000, message="Authentication required")))
            continue
        session = message["params"].get("sessionId", "fixture-session")
        if method == "session/load" and list_path:
            send(dict(method="session/update", params=dict(sessionId=session, update=dict(sessionUpdate="session_info_update", title="Agent replay title"))))
            send(dict(method="session/update", params=dict(sessionId=session, update=dict(sessionUpdate="user_message_chunk", content=dict(type="text", text="Existing external question")))))
            send(dict(method="session/update", params=dict(sessionId=session, update=dict(sessionUpdate="agent_message_chunk", content=dict(type="text", text="Existing external answer")))))
        send(dict(id=ident, result=dict(sessionId=session, modes=dict(currentModeId=legacy["modeId"], availableModes=[dict(id="default", name="Manual"), dict(id="plan", name="Plan")]), **(dict(models=dict(currentModelId=legacy["modelId"], availableModels=[dict(modelId="small", name="Small"), dict(modelId="large", name="Large")])) if "--legacy-models" in sys.argv else {}), **(dict(configOptions=config) if modern_config else {}))))
        if modern_config:
            send(dict(method="session/update", params=dict(sessionId=session, update=dict(sessionUpdate="config_option_update", configOptions=config))))
        send(dict(method="session/update", params=dict(sessionId=session, update=dict(sessionUpdate="available_commands_update", availableCommands=[dict(name="help", description="Fixture help", input=None)]))))
    elif method == "session/set_config_option":
        if "--stall-mode" in sys.argv and message["params"].get("configId") == "mode" and not (audit_path and os.path.exists(audit_path + ".continue")):
            time.sleep(60)
        option = next((item for item in config if item["id"] == message["params"].get("configId")), None)
        if "--reject-config" in sys.argv or option is None:
            send(dict(id=ident, error=dict(code=-32602, message="Configuration rejected")))
        else:
            value = message["params"].get("value")
            if option["type"] == "boolean" and (message["params"].get("type") != "boolean" or not isinstance(value, bool)):
                send(dict(id=ident, error=dict(code=-32602, message="Boolean discriminator missing")))
            else:
                option["currentValue"] = value
                if option["id"] == "model":
                    config[2]["options"][0]["options"] = [dict(value="normal", name="Normal")] + ([dict(value="high", name="High")] if value == "large" else [])
                    config[2]["currentValue"] = "normal"
                    if "--model-hides-fast" in sys.argv and value == "large":
                        config[:] = [item for item in config if item["id"] != "fast"]
                send(dict(id=ident, result=dict(configOptions=config)))
    elif method in ("session/set_mode", "session/set_model"):
        key = "modeId" if method == "session/set_mode" else "modelId"
        value = message["params"].get(key)
        allowed = ["default", "plan"] if key == "modeId" else (["small", "large"] if "--legacy-models" in sys.argv else [])
        if "--reject-legacy" in sys.argv or value not in allowed:
            send(dict(id=ident, error=dict(code=-32602, message="Legacy choice rejected")))
        else:
            legacy[key] = value
            send(dict(id=ident, result={}))
            send(dict(method="session/update", params=dict(sessionId=session, update=dict(sessionUpdate="current_mode_update" if key == "modeId" else "current_model_update", **{"currentModeId" if key == "modeId" else "currentModelId": value}))))
    elif method == "fixture/update-only":
        send(dict(method="session/update", params=dict(sessionId=session, update=dict(sessionUpdate="agent_message_chunk", content=dict(type="text", text="Transcript-only update")))))
        send(dict(id=ident, result={}))
    elif method == "fixture/config":
        send(dict(id=ident, result=dict(current={item["id"]: item["currentValue"] for item in config}, legacy=legacy, lastPrompt=last_prompt_config)))
    elif method == "session/fork":
        if "--slow-fork" in sys.argv:
            time.sleep(0.3)
        send(dict(id=ident, result=dict(sessionId=session if "--bad-fork" in sys.argv else "fixture-fork")))
    elif method == "session/prompt":
        pending = ident
        last_prompt_config = {item["id"]: item["currentValue"] for item in config}
        if not modern_config:
            last_prompt_config = dict(legacy)
        prompt_text = " ".join(block.get("text", "") for block in message["params"].get("prompt", []))
        if "stress transcript" in prompt_text.lower():
            for i in range(600):
                send(dict(method="session/update", params=dict(sessionId=session, update=dict(sessionUpdate="agent_message_chunk", messageId="stress-" + str(i), content=dict(type="text", text=f"### Step {i + 1}\n\n" + "A native streaming transcript workload. " * 12)))), fragmented=False)
                send(dict(method="session/update", params=dict(sessionId=session, update=dict(sessionUpdate="tool_call", toolCallId="stress-tool-" + str(i), title=f"Read file {i + 1}", kind="read", status="completed"))), fragmented=False)
                time.sleep(0.05)
            send(dict(id=ident, result=dict(stopReason="end_turn")))
            pending = None
            continue
        if "render markdown" in prompt_text.lower():
            send(dict(method="session/update", params=dict(sessionId=session, update=dict(sessionUpdate="agent_message_chunk", messageId="markdown", content=dict(type="text", text="# Native Markdown\n\nA **bold** paragraph with `inline code`.\n\n1. First item\n2. Second item\n   - Nested item\n\n> A quoted paragraph.\n\n| Name | Status |\n|:---|---:|\n| Parser | Ready |\n| Renderer | Native |\n\n```swift\nlet client = ACPConnection()\n```\n")))))
        show_tools = any("tools" in block.get("text", "").lower() for block in message["params"].get("prompt", []))
        if show_tools:
            send(dict(method="session/update", params=dict(sessionId=session, update=dict(sessionUpdate="agent_thought_chunk", content=dict(type="text", text="Checking the workspace before editing.")))))
            send(dict(method="session/update", params=dict(sessionId=session, update=dict(sessionUpdate="plan", entries=[dict(content="Read the project", priority="high", status="in_progress"), dict(content="Review changes", priority="medium", status="pending")] ))))
            send(dict(method="session/update", params=dict(sessionId=session, update=dict(sessionUpdate="tool_call", toolCallId="t1", title="Read README.md", kind="read", status="in_progress", rawInput=dict(path="README.md")))))
        send(dict(method="session/update", params=dict(sessionId=session, update=dict(sessionUpdate="agent_message_chunk", content=dict(type="text", text="Hello 🦉")))))
        send(dict(id="permission-1", method="session/request_permission", params=dict(sessionId=session, toolCall=dict(toolCallId="t1", title="Read project", kind="read", status="pending"), options=[dict(optionId="allow", name="Allow once", kind="allow_once"), dict(optionId="deny", name="Deny", kind="reject_once")])) )
    elif ident == "permission-1":
        if pending is None:
            continue
        outcome = message.get("result", {}).get("outcome", {})
        if show_tools:
            send(dict(method="session/update", params=dict(sessionId=session, update=dict(sessionUpdate="tool_call_update", toolCallId="t1", status="completed", content=[dict(type="content", content=dict(type="text", text="Project file read successfully."))]))))
        if outcome.get("optionId") == "allow":
            send(dict(method="session/update", params=dict(sessionId=session, update=dict(sessionUpdate="agent_message_chunk", content=dict(type="text", text=" — approved")))))
        send(dict(id=pending, result=dict(stopReason="cancelled" if outcome.get("outcome") == "cancelled" else "end_turn")))
        pending = None
    elif method == "session/cancel":
        if pending is not None:
            send(dict(id=pending, result=dict(stopReason="cancelled")))
            pending = None
    elif method == "fixture/exit":
        sys.exit(3)
    elif method == "fixture/final-exit":
        send(dict(method="session/update", params=dict(sessionId=session, update=dict(sessionUpdate="agent_message_chunk", content=dict(type="text", text="Final")))))
        time.sleep(0.06)
        send(dict(id=ident, result=dict(ok=True)))
        sys.exit(0)
    elif method == "fixture/hang":
        pass
    elif method == "fixture/flood":
        sys.stderr.write("x" * 100000)
        sys.stderr.flush()
        send(dict(id=ident, result=dict(ok=True)))
    elif method == "fixture/bad":
        sys.stdout.write("not json\n")
        sys.stdout.flush()
    elif method == "fixture/fractional":
        send(dict(id=ident + 0.5, result=dict(ok=True)))
    elif method:
        send(dict(id=ident, error=dict(code=-32601, message="Unknown method")))

if "--resist-eof" in sys.argv:
    time.sleep(60)
