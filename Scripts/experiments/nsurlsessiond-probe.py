#!/usr/bin/env python3
"""Match two localhost background URLSession sockets to their log owners."""

import csv
from collections import defaultdict
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
from queue import Empty, Queue
import re
import shutil
import subprocess
from tempfile import TemporaryDirectory
from threading import Event, Thread
from time import monotonic, sleep
from uuid import uuid4


SIZES = {"/a": 32 * 1024, "/b": 64 * 1024}
NETTOP_SOCKET = re.compile(r"tcp4 127\.0\.0\.1[:.](\d+)<->127\.0\.0\.1[:.](\d+)")
LOG_SOCKET = re.compile(r"127\.0\.0\.1:(\d+)<->[^\]\n]+[:.](\d+)\]")


def command(*args, timeout=15):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=timeout).stdout


def make_probe(directory, bundle_id, binary):
    bundle = directory / f"{bundle_id}.app"
    executable = bundle / "Contents" / "MacOS" / "Probe"
    executable.parent.mkdir(parents=True)
    (bundle / "Contents" / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": bundle_id,
        "CFBundleExecutable": "Probe",
        "CFBundlePackageType": "APPL",
        "LSUIElement": True,
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
    }))
    shutil.copy2(binary, executable)
    command("/usr/bin/codesign", "--force", "--sign", "-", str(bundle))
    return executable


def sample_sockets(server_port, client_ports):
    raw = command("/usr/bin/nettop", "-n", "-x", "-L", "1", "-p", "nsurlsessiond",
                  "-J", "time,interface,bytes_in,bytes_out")
    sockets = {}
    pid = None
    for row in csv.reader(raw.splitlines()):
        if len(row) < 5:
            continue
        _, name, interface, received, sent = row[:5]
        if not interface:
            process = re.fullmatch(r"nsurlsessiond\.(\d+)", name)
            pid = int(process[1]) if process else None
            continue
        address = NETTOP_SOCKET.fullmatch(name)
        if pid is None or interface != "lo0" or not address:
            continue
        local, remote = map(int, address.groups())
        if remote == server_port and local in client_ports and received.isdigit() and sent.isdigit():
            sockets[pid, interface, local, remote] = (int(received), int(sent))
    return sockets


def read_close_owners(start, prefix):
    predicate = (
        'process == "nsurlsessiond" AND subsystem == "com.apple.network" '
        f'AND category == "connection" AND eventMessage CONTAINS "{prefix}" '
        'AND eventMessage CONTAINS "bytes in/out:"'
    )
    raw = command("/usr/bin/log", "show", "--start", start, "--style", "ndjson",
                  "--predicate", predicate)
    owners = defaultdict(set)
    bundle_id = re.compile(rf"bundle id: ({re.escape(prefix)}\.[ab]),")
    for line in raw.splitlines():
        row = json.loads(line)
        message = row.get("eventMessage", "")
        owner = bundle_id.search(message)
        socket = LOG_SOCKET.search(message)
        interface = re.search(r"interface: (lo0)\b", message)
        if owner and socket and interface and " cancelled\n" in message:
            local, remote = map(int, socket.groups())
            owners[row["processID"], interface[1], local, remote].add(owner[1])
    return owners


def run_probe(directory):
    prefix = f"org.networkmonitor.sessionprobe.r{uuid4().hex[:12]}"
    binary = directory / "Probe"
    source = Path(__file__).with_suffix(".swift")
    command("/usr/bin/xcrun", "swiftc", "-module-cache-path", str(directory / "modules"),
            str(source), "-o", str(binary), timeout=120)
    bundles = {path: prefix + path.replace("/", ".") for path in SIZES}
    apps = {path: make_probe(directory, bundle_id, binary) for path, bundle_id in bundles.items()}

    ready = Queue()
    release = Event()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            size = SIZES.get(self.path)
            if size is None:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(size))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(bytes(size // 2))
            ready.put((self.path, self.client_address[1]))
            if release.wait(timeout=20):
                self.wfile.write(bytes(size // 2))

        def log_message(self, *args):
            pass

    start = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        serving = Thread(target=server.serve_forever, daemon=True)
        serving.start()
        processes = {}
        try:
            for path, executable in apps.items():
                processes[path] = subprocess.Popen(
                    [str(executable), f"http://127.0.0.1:{server.server_port}{path}"],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                )
            ports = {}
            deadline = monotonic() + 12
            while len(ports) < len(apps):
                try:
                    path, port = ready.get(timeout=max(0, deadline - monotonic()))
                except Empty:
                    raise RuntimeError("Both background requests must reach localhost within 12 seconds") from None
                if path in ports:
                    raise RuntimeError("A transfer retried before sampling")
                ports[path] = port

            for _ in range(3):
                sockets = sample_sockets(server.server_port, ports.values())
                sampled_ports = {key[2] for key, (received, _) in sockets.items() if received > 0}
                if sampled_ports == set(ports.values()):
                    break
                sleep(0.25)
            else:
                raise RuntimeError("nettop did not report received bytes for both active sockets")
            if len(sockets) != len(ports) or len({key[0] for key in sockets}) != 1:
                raise RuntimeError("Expected two sockets under one nsurlsessiond PID")

            release.set()
            for path, process in processes.items():
                stdout, stderr = process.communicate(timeout=15)
                if process.returncode != 0 or stdout.strip() != str(SIZES[path]):
                    raise RuntimeError(f"Download {path} failed or returned the wrong size: {stderr.strip()}")
        finally:
            release.set()
            for process in processes.values():
                if process.poll() is None:
                    process.kill()
                process.communicate()
            server.shutdown()
            serving.join()

    for _ in range(5):
        owners = read_close_owners(start, prefix)
        if all(key in owners for key in sockets):
            break
        sleep(1)

    expected_by_port = {port: bundles[path] for path, port in ports.items()}
    counts_by_owner = {}
    for key, counts in sockets.items():
        expected_owner = expected_by_port[key[2]]
        if owners[key] != {expected_owner}:
            raise RuntimeError(
                "No unique matching close summary for both sockets. "
                "Check unified-log access and whether this macOS version emits the expected fields."
            )
        counts_by_owner[expected_owner] = counts

    before = tuple(map(sum, zip(*sockets.values())))
    after = tuple(map(sum, zip(*counts_by_owner.values())))
    if before != after:
        raise RuntimeError("Attribution changed the measured totals")
    for path, bundle_id in bundles.items():
        received, sent = counts_by_owner[bundle_id]
        print(f"App {path[1:].upper()}: {SIZES[path]} payload bytes downloaded, "
              f"nettop snapshot {received} received / {sent} sent")
    print(f"One daemon PID, two distinct owners. Snapshot total: "
          f"{before[0]} received / {before[1]} sent before and after attribution.")


if __name__ == "__main__":
    try:
        with TemporaryDirectory(prefix="nsurlsessiond-probe-") as temp:
            run_probe(Path(temp).resolve())
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"{error.cmd[0]} failed: {error.stderr.strip()}") from None
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        raise SystemExit(str(error)) from None
