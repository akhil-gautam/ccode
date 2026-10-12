import os
import subprocess
import sys
for line in sys.stdin:
    if "--stream" in sys.argv:
        subprocess.Popen([sys.executable, "-c", 'import json, time\nwhile True:\n print(json.dumps({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"child","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"x"}}}}), flush=True); time.sleep(0.01)'])
    else:
        subprocess.Popen(["/bin/sleep", "10"])
    os._exit(2)
