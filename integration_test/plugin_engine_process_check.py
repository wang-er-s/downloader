"""Real macOS process termination regression; run from the repository root.

Only kills a newly launched executable at this checkout's exact app path.
Temporary files and logs are retained for independent inspection.
"""
import hashlib
import http.server
import json
import os
import signal
import subprocess
import tempfile
import threading
import time
from pathlib import Path

sandbox_tmp = Path.home() / "Library/Containers/com.example.downloader/Data/tmp"
sandbox_tmp.mkdir(parents=True, exist_ok=True)
root = Path(tempfile.mkdtemp(prefix="plugin-engine-process-", dir=sandbox_tmp))
requests = []
request_phases = []


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append(self.headers.get("Range"))
        request_phases.append((root / "manual-request").exists())
        offset = int(self.headers.get("Range", "bytes=0-").split("=")[1].split("-")[0])
        self.send_response(206 if self.headers.get("Range") else 200)
        if self.headers.get("Range"):
            self.send_header("Content-Range", f"bytes {offset}-{2*1024*1024-1}/{2*1024*1024}")
        self.send_header("ETag", '"process"')
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(1024 * 1024 * 2 - offset))
        self.end_headers()
        try:
            for start in range(offset, 2*1024*1024, 8192):
                self.wfile.write(bytes(i % 251 for i in range(start, min(start+8192, 2*1024*1024))))
                self.wfile.flush()
                time.sleep(0.03)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, format, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
config = root / "host.xcconfig"
config.write_text("MACOSX_DEPLOYMENT_TARGET = 12.0\n")
environment = dict(os.environ, XCODE_XCCONFIG_FILE=str(config))
executable = str(Path("build/macos/Build/Products/Debug/downloader.app/Contents/MacOS/downloader").resolve())


def app_pids():
    result = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True, check=True)
    return {int(row.strip().split(None, 1)[0]) for row in result.stdout.splitlines()
            if len(row.strip().split(None, 1)) == 2 and row.strip().split(None, 1)[1] == executable}


def command(phase):
    return ["flutter", "test", "integration_test/plugin_engine_process_test.dart", "-d", "macos",
            "--reporter", "expanded", f"--dart-define=ENGINE_PROCESS_ROOT={root}",
            f"--dart-define=ENGINE_PROCESS_URL=http://127.0.0.1:{server.server_port}/data",
            f"--dart-define=ENGINE_PROCESS_PHASE={phase}"]


before = app_pids()
process = None
try:
    with (root / "prepare.log").open("w") as output:
        process = subprocess.Popen(command("prepare"), env=environment, stdout=output, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 90
        while not (root / "ready").exists():
            if process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError(f"prepare did not reach a durable checkpoint: {root}")
            time.sleep(0.1)
        time.sleep(0.12)  # Leave an uncommitted tail beyond the first checkpoint.
        targets = app_pids() - before
        if len(targets) != 1:
            raise RuntimeError(f"expected one new application process, found {targets}")
        os.kill(targets.pop(), signal.SIGKILL)
        process.wait(timeout=30)
    count = len(requests)
    assert count == 1, requests
    execution = next(path for path in (root / "execution").iterdir() if path.is_dir())
    versions = sorted(execution.glob("*.json"), key=lambda path: int(path.stem))
    checkpoint = json.loads(versions[-1].read_text())
    original = Path(checkpoint["resumeData"]["data"])
    original_size = original.stat().st_size
    original_hash = hashlib.sha256(original.read_bytes()).hexdigest()
    offset = checkpoint["resumeData"]["requiredStartByte"]
    assert original_size > offset, (original_size, offset)
    with (root / "inspect.log").open("w") as output:
        result = subprocess.run(command("inspect"), env=environment, stdout=output,
                                stderr=subprocess.STDOUT, timeout=90)
    assert result.returncode == 0, root / "inspect.log"
    assert (root / "verified").exists(), root
    assert len(requests) == count + 1, requests
    assert requests[0] is None and requests[1] == f"bytes={offset}-", requests
    assert request_phases == [False, True], request_phases
    assert original.stat().st_size == original_size
    assert hashlib.sha256(original.read_bytes()).hexdigest() == original_hash
    print(f"PASS: SIGKILL actual transfer process; re-open waitingRecovery; automatic requests=0; checkpoint={offset}; originalTailLength={original_size}; manualRange={requests[1]}; original unchanged; exact content verified; evidence={root}")
finally:
    if process is not None and process.poll() is None:
        # Terminate only the runner we created; never touch other app processes.
        process.terminate()
    server.shutdown()
