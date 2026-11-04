#!/usr/bin/env python3
"""API37-only real Runtime/Service evidence. HTTP stays in this host process across force-stop.
Run from the repository root. Does not install SDKs, change target, or grant background exemptions.
"""
import argparse
import http.server
import json
import os
import subprocess
import threading
import time
import xml.etree.ElementTree as ET
from pathlib import Path

ADB = '/Users/wang/Library/Android/sdk/platform-tools/adb'
JBR = '/Applications/Android Studio.app/Contents/jbr/Contents/Home'
PACKAGE = 'com.example.downloader'
RUNNER = PACKAGE + '.test/com.example.downloader.downloader.ExecutionJournalTest'
ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    output = Path(args.output)
    if output.exists() and any(output.iterdir()):
        parser.error('--output must be empty so failed-run evidence is preserved')
    output.mkdir(parents=True, exist_ok=True)
    requests = []
    lock = threading.Lock()

    def record(item):
        with lock:
            requests.append(item)
            with (output / 'http.jsonl').open('a') as file:
                file.write(json.dumps(item) + '\n')

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass

        def do_GET(self):
            total = 8 * 1024 * 1024
            range_header = self.headers.get('Range')
            offset = int(range_header.removeprefix('bytes=').removesuffix('-')) if range_header else 0
            record({'time': time.time(), 'path': self.path, 'range': range_header,
                    'ifRange': self.headers.get('If-Range'), 'status': 206 if range_header else 200})
            self.send_response(206 if range_header else 200)
            self.send_header('ETag', '"runtime-v1"')
            self.send_header('Content-Length', str(total - offset))
            if range_header:
                self.send_header('Content-Range', f'bytes {offset}-{total - 1}/{total}')
            self.end_headers()
            try:
                for position in range(offset, total, 8192):
                    self.wfile.write(bytes(i % 251 for i in range(position, min(position + 8192, total))))
                    self.wfile.flush()
                    time.sleep(.08)
            except (BrokenPipeError, ConnectionResetError):
                pass  # The client intentionally pauses/cancels/force-stops the real connection.

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 18765), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()

    def adb(*parts):
        result = subprocess.run([ADB, '-s', 'emulator-5554', *parts], text=True, capture_output=True, timeout=30)
        with (output / 'adb-operations.log').open('a') as file:
            file.write(repr(parts) + f' exit={result.returncode}\n' + result.stdout + result.stderr)
        result.check_returncode()
        return result.stdout

    def count():
        with lock:
            return len(requests)

    def gradle(mode):
        command = ['./gradlew', '-Pandroid.builder.sdkDownload=false',
                   '-Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true',
                   f'-Pandroid.testInstrumentationRunnerArguments.runtimeMode={mode}',
                   ':app:connectedDebugAndroidTest']
        with (output / f'{mode}.log').open('w') as file:
            result = subprocess.run(command, cwd=ROOT / 'android', env={**os.environ, 'JAVA_HOME': JBR, 'ANDROID_SERIAL': 'emulator-5554'}, stdout=file, stderr=subprocess.STDOUT, timeout=180)
        (output / f'{mode}.exit').write_text(str(result.returncode))
        (output / f'{mode}-logcat.txt').write_text(adb('logcat', '-d'))
        # Preserve exact Gradle XML before the next invocation replaces it, including failures.
        cases = []
        for index, path in enumerate((ROOT / 'build/app/outputs/androidTest-results/connected').rglob('*.xml')):
            text = path.read_text()
            (output / f'{mode}-{index}.xml').write_text(text)
            tree = ET.fromstring(text)  # noqa: S314 - trusted local Gradle-generated XML
            if result.returncode == 0:
                assert [int(tree.get(key, '0')) for key in ('tests', 'failures', 'errors', 'skipped')] == [1, 0, 0, 0], f'{mode}: invalid suite counts'
            cases.extend(tree.iter('testcase'))
        result.check_returncode()
        assert len(cases) == 1, f'{mode}: expected one unique actual device case, got {len(cases)}'
        assert not any(list(case) for case in cases), f'{mode}: failure/error/skip in XML'
        assert cases[0].get('name') == mode, f'{mode}: unexpected case identity'
        return cases[0].attrib

    summary = {}
    seed = None
    owns_reverse = False
    try:
        summary['sdk'] = adb('shell', 'getprop', 'ro.build.version.sdk').strip()
        summary['model'] = adb('shell', 'getprop', 'ro.product.model').strip()
        assert summary['sdk'] == '37'
        reverse = [line.split() for line in adb('reverse', '--list').splitlines()]
        existing = [parts[-1] for parts in reverse if len(parts) >= 3 and parts[-2] == 'tcp:18765']
        assert not existing or existing == ['tcp:18765'], 'port reverse belongs to another target'
        if not existing:
            adb('reverse', 'tcp:18765', 'tcp:18765')
            owns_reverse = True
        adb('logcat', '-c')
        # Normal APK install, before permission grant. Retain package data across test phases.
        adb('install', '-r', str(ROOT / 'build/app/outputs/apk/debug/app-debug.apk'))
        adb('install', '-r', str(ROOT / 'build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk'))
        adb('shell', 'pm', 'grant', PACKAGE, 'android.permission.POST_NOTIFICATIONS')
        summary['lifecycle'] = gradle('lifecycle')
        assert count() == 2, f'lifecycle expected initial GET and actual 206, got {count()}'
        assert requests[1]['status'] == 206 and requests[1]['ifRange'] == '"runtime-v1"'
        before = count()
        for mode in ('revokedBeforePauseCallback', 'revokedBeforeCancelCallback', 'permissionChangedBeforeCallback'):
            adb('shell', 'am', 'force-stop', PACKAGE)
            summary[mode] = gradle(mode)
            assert count() == before, f'{mode}: revoked token issued HTTP'
        adb('shell', 'am', 'force-stop', PACKAGE)
        adb('shell', 'pm', 'revoke', PACKAGE, 'android.permission.POST_NOTIFICATIONS')
        summary['denied'] = gradle('denied')
        assert count() == before, 'permission denial issued HTTP'
        adb('shell', 'am', 'force-stop', PACKAGE)
        summary['deniedPromotion'] = gradle('deniedPromotion')
        assert count() == before, 'denied promotion issued HTTP'
        adb('shell', 'pm', 'grant', PACKAGE, 'android.permission.POST_NOTIFICATIONS')
        adb('logcat', '-c')
        with (output / 'seedKill.log').open('w') as file:
            seed = subprocess.Popen([ADB, '-s', 'emulator-5554', 'shell', 'am', 'instrument', '-w', '-e', 'runtimeMode', 'seedKill', RUNNER], stdout=file, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 45
            while 'KILL_READY' not in adb('logcat', '-d', '-s', 'ServiceRuntimeEvidence:I'):
                assert time.monotonic() < deadline, 'kill seed did not reach actual bytes'
                time.sleep(.25)
            (output / 'active-service.txt').write_text(adb('shell', 'dumpsys', 'activity', 'services', PACKAGE))
            adb('shell', 'am', 'force-stop', PACKAGE)
            seed.wait(timeout=15)
            (output / 'seedKill.exit').write_text(str(seed.returncode))
        before = count()
        summary['inspectAfterKill'] = gradle('inspectAfterKill')
        time.sleep(2)
        assert count() == before, 'reopen/inspect issued a new GET'
        summary['httpCount'] = count()
        assert summary['httpCount'] == 3, f'expected exactly three GETs, got {count()}'
        summary['killReopenNewGET'] = count() - before
        summary['status'] = 'passed'
    finally:
        try:
            if seed is not None and seed.poll() is None:
                # Only stop this project's seed and the adb client created above.
                try:
                    adb('shell', 'am', 'force-stop', PACKAGE)
                finally:
                    seed.terminate()
                    seed.wait(timeout=15)
            (output / 'logcat.txt').write_text(adb('logcat', '-d'))
        finally:
            try:
                if owns_reverse:
                    adb('reverse', '--remove', 'tcp:18765')
            finally:
                (output / 'summary.json').write_text(json.dumps(summary, indent=2))
                server.shutdown()
                server.server_close()
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
