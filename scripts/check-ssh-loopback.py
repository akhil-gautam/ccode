#!/usr/bin/env python3
"""Authenticated SSH acceptance on an isolated localhost server; no system setup."""
import getpass
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
root = Path(tempfile.mkdtemp(prefix="ssh-loopback-", dir=repo / ".build"))
metadata = {"directory": str(root), "accepted": False, "native_accepted": False}
server = None


def quoted(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


try:
    for name in ["host-key", "client-key"]:
        subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)], check=True)
    (root / "authorized_keys").write_text((root / "client-key.pub").read_text())
    (root / "authorized_keys").chmod(0o600)
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    metadata["port"] = port
    (root / "sshd_config").write_text(f"""Port {port}
ListenAddress 127.0.0.1
HostKey {quoted(root / 'host-key')}
PidFile {quoted(root / 'server.pid')}
AuthorizedKeysFile {quoted(root / 'authorized_keys')}
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
AllowUsers {getpass.getuser()}
AllowTcpForwarding no
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
LogLevel ERROR
""")
    public = (root / "host-key.pub").read_text().split()
    (root / "known_hosts").write_text(f"[127.0.0.1]:{port} {public[0]} {public[1]}\n")
    (root / "ssh_config").write_text(f"""Host ccode-disposable-loopback
 HostName 127.0.0.1
 Port {port}
 User {getpass.getuser()}
 IdentityFile {quoted(root / 'client-key')}
 IdentitiesOnly yes
 UserKnownHostsFile {quoted(root / 'known_hosts')}
 GlobalKnownHostsFile /dev/null
""")
    wrapper = root / "ssh-wrapper"
    wrapper.write_text("#!/bin/sh\nexec /usr/bin/ssh -F " + shlex.quote(str(root / "ssh_config")) + ' "$@"\n')
    wrapper.chmod(0o700)
    check = subprocess.run(["/usr/sbin/sshd", "-t", "-f", str(root / "sshd_config")], capture_output=True, text=True)
    metadata.update(configuration_check_exit=check.returncode, configuration_check_error=check.stderr.strip())
    if check.returncode:
        raise RuntimeError("Disposable SSH configuration is unavailable: " + check.stderr.strip())
    proof = root / "proof.json"
    proof.write_text(json.dumps(metadata, indent=2) + "\n")
    with (root / "sshd.log").open("wb") as log:
        server = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(root / "sshd_config")], stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    # Wait for this exact server to listen; no password or host-key bootstrap.
    import time
    deadline = time.monotonic() + 5
    while True:
        if server.poll() is not None:
            raise RuntimeError("Disposable SSH server exited: " + (root / "sshd.log").read_text())
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                break
        except OSError:
            if time.monotonic() >= deadline:
                raise RuntimeError("Disposable SSH server did not start.")
            time.sleep(0.05)
    environment = dict(os.environ, CCODE_SSH_LOOPBACK_PROOF=str(proof))
    with (root / "tests.log").open("wb") as log:
        result = subprocess.run(["sh", "scripts/swift-check.sh", "test", "--filter", os.environ.get("CCODE_SSH_TEST_FILTER", "RemoteWorkflowTests|RealSSHTests")], cwd=repo, env=environment, stdout=log, stderr=subprocess.STDOUT)
    metadata["test_exit"] = result.returncode
    if result.returncode:
        raise RuntimeError("Remote workflow checks failed; see " + str(root / "tests.log"))
    verified = json.loads((root / "verified-transport.json").read_text())
    if verified.get("accepted") is not True:
        raise RuntimeError("No accepted SSH transport receipt.")
    metadata["accepted"] = True
    if os.environ.get("CCODE_REAL_SSH_AGENT"):
        actual = json.loads((root / "verified-real-agent.json").read_text())
        if actual.get("accepted") is not True:
            raise RuntimeError("No accepted real-agent SSH receipt")
        metadata["real_agent_accepted"] = True
finally:
    if server is not None:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
        metadata["server_stopped"] = server.poll() is not None
    # Credentials were authorized only by this test daemon. Preserve public
    # evidence/config/logs, discard its private keys and authorization file.
    for name in ["host-key", "client-key", "authorized_keys"]:
        (root / name).unlink(missing_ok=True)
    metadata["private_keys_removed"] = True
    (root / "proof.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(metadata, indent=2))
