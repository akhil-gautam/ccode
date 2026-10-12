#!/usr/bin/env python3
"""Session-owned background work, independent from an already finished main turn."""
import json
import sys
from pathlib import Path

root = "async-root"
directory = None
jobs = {}
stops = []
cancels = 0
fail_stop = False

def send(**message):
    print(json.dumps(dict(jsonrpc="2.0", **message)), flush=True)

def update(owner, **value):
    send(method="session/update", params=dict(sessionId=owner, update=value))

def spawn(owner, task):
    path = directory / (task + ".output")
    path.write_text("Fixture task output: " + task + "\n")
    jobs[task] = dict(owner=owner, state="running")
    update(owner, sessionUpdate="async_task_spawned", asyncTaskId=task, name=task, description="Disposable task", taskType="shell", showInTranscript=True, canStop=True, outputFilePath=str(path))

for line in sys.stdin:
    message = json.loads(line)
    method, ident, params = message.get("method"), message.get("id"), message.get("params", {})
    if method == "initialize":
        send(id=ident, result=dict(protocolVersion=1, agentInfo=dict(name="async-fixture", version="1"), agentCapabilities={}, _meta=dict(ccode=dict(asyncTasks=dict(version=1, stopMethod="_session/async_task/stop")))))
    elif method == "session/new":
        directory = Path(params["cwd"])
        send(id=ident, result=dict(sessionId=root))
    elif method == "session/fork":
        send(id=ident, result=dict(sessionId=root + "-fork"))
    elif method == "session/prompt":
        update(root, sessionUpdate="subagent_spawned", subagentSessionId="child", name="Child", capabilities={})
        update(root, sessionUpdate="subagent_state_update", subagentSessionId="child", state="completed")
        spawn(root, "build")
        spawn("child", "checks")
        update(root, sessionUpdate="agent_message_chunk", content=dict(type="text", text="Main turn finished while tasks continue"))
        send(id=ident, result=dict(stopReason="end_turn"))
    elif method == "_session/async_task/stop":
        stops.append(params)
        task = params.get("asyncTaskId")
        if fail_stop:
            fail_stop = False
            send(id=ident, error=dict(code=-32000, message="Fixture stop failed"))
        elif params.get("sessionId") != root or task not in jobs or jobs[task]["state"] != "running":
            send(id=ident, result=dict(stopped=False))
        else:
            jobs[task]["state"] = "stopped"
            update(jobs[task]["owner"], sessionUpdate="async_task_state_update", asyncTaskId=task, state="stopped")
            send(id=ident, result=dict(stopped=True))
    elif method == "session/cancel":
        cancels += 1
    elif method == "fixture/state":
        send(id=ident, result=dict(stops=stops, cancels=cancels, jobs=jobs))
    elif method == "fixture/complete":
        task = params["task"]
        jobs[task]["state"] = "completed"
        update(jobs[task]["owner"], sessionUpdate="async_task_state_update", asyncTaskId=task, state="completed", summary="Completed independently")
        send(id=ident, result={})
    elif method == "fixture/fail-next-stop":
        fail_stop = True
        send(id=ident, result={})
    elif ident is not None:
        send(id=ident, result={})
