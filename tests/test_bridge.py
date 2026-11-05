import base64
import json
import subprocess
import sys
import unittest


class BridgeTests(unittest.TestCase):
    def test_binary_input_eof_distinct_output_streams_and_exit_status(self):
        binary = bytes(range(256)) * 64
        frames = [json.dumps({"type": "stdin", "data": base64.b64encode(binary).decode()}),
                  json.dumps({"type": "closeStdin"})]
        result = subprocess.run(
            [sys.executable, "-m", "devsy_aca.bridge", "cat; printf 'diagnostic' >&2; exit 7"],
            input=("\n".join(frames) + "\n").encode(), capture_output=True, timeout=15,
            check=True,
        )
        self.assertEqual(result.stderr, b"")
        ready, *messages = result.stdout.splitlines()
        self.assertEqual(ready, b"DEVSY_ACA_BRIDGE_READY_V1")
        frames = [json.loads(line) for line in messages]
        self.assertEqual(frames[-1], {"type": "exit_code", "exitCode": 7})
        self.assertEqual(self.data_for(frames, "stdout"), binary)
        self.assertEqual(self.data_for(frames, "stderr"), b"diagnostic")

    def test_child_can_exit_before_client_closes_input(self):
        with subprocess.Popen([sys.executable, "-m", "devsy_aca.bridge", "exit 42"],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE) as process:
            self.assertEqual(process.wait(timeout=10), 0)
            self.assertEqual(process.stderr.read(), b"")
            self.assertEqual(json.loads(process.stdout.read().splitlines()[-1])["exitCode"], 42)

    @staticmethod
    def data_for(frames, kind):
        return b"".join(base64.b64decode(frame["data"]) for frame in frames if frame["type"] == kind)
