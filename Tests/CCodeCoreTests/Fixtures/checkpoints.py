"""Disposable checkpoint protocol fixture; never invokes a model."""
import json
import sys
import time
import uuid
import os

connection = str(uuid.uuid4())
remote = str(uuid.uuid4())
supported = "--no-checkpoints" not in sys.argv
receipts = {}
submissions = []
previews = 0
restores = 0
tokens = set()
pending_restore = None
def send(**message):
    print(json.dumps(dict(jsonrpc="2.0", **message)), flush=True)

for line in sys.stdin:
    frame = json.loads(line)
    method, ident, params = frame.get("method"), frame.get("id"), frame.get("params", {})
    if method == "initialize":
        enabled = supported and params.get("clientCapabilities", {}).get("_meta", {}).get("ccode", {}).get("fileCheckpoints") is True
        cap = dict(version=1, connectionId=connection, previewMethod="_ccode/checkpoint/preview", notificationMethod="_ccode/checkpoint")
        recovery = params.get("clientCapabilities", {}).get("_meta", {}).get("ccode", {}).get("fileCheckpointRecoveryDirectory")
        if "--restoration" in sys.argv and recovery:
            cap["restoreMethod"] = "_ccode/checkpoint/restore"
        send(id=ident, result=dict(protocolVersion=1, agentInfo=dict(name="@agentclientprotocol/claude-agent-acp", version="0.84.0"), agentCapabilities=dict(sessionCapabilities=dict(resume={})), _meta=dict(ccode=dict(fileCheckpoints=cap)) if enabled else {}))
    elif method in ["session/new", "session/resume"]:
        remote = params.get("sessionId", remote)
        send(id=ident, result=dict(sessionId=remote))
    elif method == "session/prompt":
        local = params.get("_meta", {}).get("ccode", {}).get("promptId")
        submissions.append(local)
        if enabled and local:
            receipt = dict(version=1, connectionId=connection, sessionId=remote, promptId=local, checkpointId=str(uuid.uuid4()))
            receipts[local] = receipt
            send(method="_ccode/checkpoint", params=receipt)
            send(method="_ccode/checkpoint", params=receipt)
        send(method="session/update", params=dict(sessionId=remote, update=dict(sessionUpdate="agent_message_chunk", content=dict(type="text", text="Fixture answer"))))
        send(id=ident, result=dict(stopReason="end_turn"))
    elif method == "_ccode/checkpoint/preview":
        previews += 1
        receipt = receipts.get(params.get("promptId"))
        if not enabled or not receipt or any(params.get(key) != receipt[key] for key in ["sessionId", "promptId", "checkpointId", "connectionId"]):
            send(id=ident, error=dict(code=-32602, message="Unknown checkpoint"))
        else:
            if "--slow-preview" in sys.argv:
                time.sleep(0.2)
            value = dict(receipt, canRewind=True, filesChanged=["answer.py"], insertions=2, deletions=1, declaredComplete=False)
            if "restoreMethod" in cap:
                token = str(uuid.uuid4()); tokens.add(token); value["previewToken"] = token
            if "--bad-preview" in sys.argv:
                value["sessionId"] = str(uuid.uuid4())
            send(id=ident, result=value)
    elif method == "fixture/release-restore":
        if pending_restore:
            send(id=pending_restore[0], result=pending_restore[1]); pending_restore = None
        send(id=ident, result={})
    elif method == "_ccode/checkpoint/restore":
        token = params.get("previewToken")
        if token not in tokens:
            send(id=ident, error=dict(code=-32602, message="Unknown preview"))
        else:
            tokens.remove(token); restores += 1
            if "--slow-restore" in sys.argv:
                time.sleep(0.2)
            directory = os.path.join(recovery, "restore-" + str(uuid.uuid4()))
            os.mkdir(directory, 0o700)
            value = dict(receipts[params["promptId"]], status="completed", recoveryDirectory=directory, skippedLinks=0, declaredComplete=False)
            if "--bad-restore" in sys.argv:
                value["sessionId"] = str(uuid.uuid4())
            if "--held-restore" in sys.argv:
                pending_restore = (ident, value)
            else:
                send(id=ident, result=value)
    elif method == "fixture/state":
        send(id=ident, result=dict(submissions=submissions, previews=previews, restores=restores))
    elif method == "session/cancel":
        pass
    elif ident is not None:
        send(id=ident, error=dict(code=-32601, message="Unknown fixture method"))
