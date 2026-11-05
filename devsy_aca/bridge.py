"""Remote subprocess multiplexer used inside an ACA raw PTY.

The current preview closes stdin on non-PTY exec. A raw PTY carries this
ASCII/base64 protocol; the child gets ordinary pipes, including separate
stderr, rather than a terminal. Only the local adapter decodes child bytes.
"""
import base64
import json
import os
import signal
import subprocess
import sys
import threading

READY = "DEVSY_ACA_BRIDGE_READY_V1"


def main():
    lock = threading.Lock()

    def emit(kind, data=None, code=None):
        frame = {"type": kind}
        if data is not None:
            frame["data"] = base64.b64encode(data).decode("ascii")
        if code is not None:
            frame["exitCode"] = code
        with lock:
            sys.stdout.write(json.dumps(frame, separators=(",", ":")) + "\n")
            sys.stdout.flush()

    child = subprocess.Popen(
        ["/bin/sh", "-c", sys.argv[1]],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=True,
    )

    def cancel(signum, _frame):
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os._exit(128 + signum)

    signal.signal(signal.SIGHUP, cancel)
    signal.signal(signal.SIGTERM, cancel)

    def drain(stream, kind):
        while True:
            data = os.read(stream.fileno(), 16384)
            if not data:
                return
            emit(kind, data)

    def feed():
        try:
            for line in sys.stdin.buffer:
                frame = json.loads(line)
                if frame["type"] == "stdin":
                    child.stdin.write(base64.b64decode(frame["data"], validate=True))
                    child.stdin.flush()
                elif frame["type"] == "closeStdin":
                    child.stdin.close()
                    return
                else:
                    raise ValueError("Unknown bridge input frame")
        except (BrokenPipeError, OSError):
            pass
        finally:
            try:
                child.stdin.close()
            except (BrokenPipeError, OSError):
                pass

    # No stdin is sent by the client until raw mode is active and this marker
    # arrives. This prevents terminal echo/control handling from corrupting it.
    sys.stdout.write(READY + "\n")
    sys.stdout.flush()
    readers = [threading.Thread(target=drain, args=(child.stdout, "stdout")),
               threading.Thread(target=drain, args=(child.stderr, "stderr"))]
    for thread in readers:
        thread.start()
    threading.Thread(target=feed, daemon=True).start()
    code = child.wait()
    for thread in readers:
        thread.join()
    emit("exit_code", code=code if code >= 0 else 128 - code)
    # The daemon input thread may still be blocked on a live PTY when a child
    # exits without reading stdin. Avoid CPython finalizing its buffered I/O.
    os._exit(0)


if __name__ == "__main__":
    main()
