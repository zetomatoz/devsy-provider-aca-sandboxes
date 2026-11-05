"""Binary-safe exec over ACA's authenticated HTTPS/WebSocket API."""
from __future__ import annotations

import base64
import json
import os
import shlex
import ssl
import sys
import threading
from importlib.resources import files
from urllib.parse import quote

import truststore
from websockets.sync.client import connect
from websockets.exceptions import ConnectionClosed

READY = b"DEVSY_ACA_BRIDGE_READY_V1\n"


def websocket_url(config, sandbox_id: str) -> str:
    parts = ["subscriptions", config.subscription_id, "resourceGroups",
             config.resource_group, "sandboxGroups", config.sandbox_group,
             "sandboxes", sandbox_id, "exec", "stream"]
    return (f"wss://management.{config.location}.azuredevcompute.io/"
            + "/".join(quote(part, safe="") for part in parts)
            + "?api-version=2026-02-01-preview")


def bridge_command(command: str) -> str:
    source = files("devsy_aca").joinpath("bridge.py").read_text()
    encoded = base64.b64encode(source.encode()).decode("ascii")
    loader = "import base64;exec(compile(base64.b64decode(" + repr(encoded) + "),'<aca-bridge>','exec'))"
    return ("stty raw -echo && exec python3 -u -c " + shlex.quote(loader)
            + " " + shlex.quote(command))


def run_command(config, sandbox_id: str, credential, command: str,
                stdin=None, stdout=None, stderr=None) -> int:
    """Run a command without opening any sandbox network port.

    stdin/stdout/stderr are byte streams. EOF and remote exit status cross the
    bridge explicitly. The Entra token is sent only in the TLS upgrade header.
    """
    stdin = sys.stdin.buffer if stdin is None else stdin
    stdout = sys.stdout.buffer if stdout is None else stdout
    stderr = sys.stderr.buffer if stderr is None else stderr
    token = credential.get_token("https://dynamicsessions.io/.default").token
    ready = threading.Event()
    stop = threading.Event()
    pending = bytearray()
    exit_code = None
    outer_exit = None
    sender_errors = []
    # truststore uses the OS trust store, including corporate CA roots. Never
    # disable TLS verification for the API or WebSocket.
    context = truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    with connect(websocket_url(config, sandbox_id), ssl=context,
                 additional_headers={"Authorization": "Bearer " + token},
                 open_timeout=30, close_timeout=3, max_size=8 * 1024 * 1024,
                 ping_interval=20, ping_timeout=60) as ws:
        ws.send(json.dumps({"type": "start", "start": {
            "command": "/bin/sh", "args": ["-c", bridge_command(command)],
            "tty": True, "stdin": True, "height": 24, "width": 80,
        }}))

        def send_input():
            ready.wait()
            if stop.is_set():
                return
            try:
                while not stop.is_set():
                    try:
                        data = os.read(stdin.fileno(), 4096)
                    except (AttributeError, OSError):
                        data = stdin.read(4096)
                    if not data:
                        frame = {"type": "closeStdin"}
                    else:
                        frame = {"type": "stdin", "data": base64.b64encode(data).decode("ascii")}
                    wire = (json.dumps(frame, separators=(",", ":")) + "\n").encode("ascii")
                    ws.send(json.dumps({"type": "stdin", "data": base64.b64encode(wire).decode("ascii")}))
                    if not data:
                        return
            except ConnectionClosed:
                pass
            except Exception as exc:
                sender_errors.append(exc)
                ws.close()

        threading.Thread(target=send_input, daemon=True).start()
        try:
            while exit_code is None:
                raw = ws.recv(timeout=None if ready.is_set() else 45)
                frame = json.loads(raw)
                kind = frame.get("type")
                if kind == "error":
                    raise RuntimeError("ACA exec: " + str(frame.get("data", "unknown service error")))
                if kind == "exit_code":
                    outer_exit = frame.get("exitCode")
                    break
                if kind not in ("stdout", "stderr"):
                    continue
                data = base64.b64decode(frame.get("data") or "", validate=True)
                if kind == "stderr":
                    stderr.write(data)
                    stderr.flush()
                    continue
                pending.extend(data)
                while b"\n" in pending:
                    line, _, rest = pending.partition(b"\n")
                    pending[:] = rest
                    if not ready.is_set():
                        if line + b"\n" == READY:
                            ready.set()
                        else:
                            raise RuntimeError("Unexpected output before ACA bridge readiness: " + repr(line[:200]))
                        continue
                    message = json.loads(line)
                    if message["type"] in ("stdout", "stderr"):
                        dest = stdout if message["type"] == "stdout" else stderr
                        dest.write(base64.b64decode(message.get("data", ""), validate=True))
                        dest.flush()
                    elif message["type"] == "exit_code":
                        exit_code = int(message["exitCode"])
        except ConnectionClosed as exc:
            raise RuntimeError(f"ACA exec WebSocket closed unexpectedly: {exc}") from exc
        finally:
            stop.set()
            ready.set()
    if sender_errors:
        raise RuntimeError("Unable to forward stdin over ACA exec") from sender_errors[0]
    if exit_code is None:
        raise RuntimeError(f"ACA exec ended without the subprocess exit status (outer status {outer_exit!r})")
    return exit_code
