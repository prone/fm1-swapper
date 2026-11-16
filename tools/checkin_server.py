#!/usr/bin/env python3
"""Check-in server for FM-1 Swapper installs (read-only status sharing).

Each install of the app (iPhone, iPad) PUTs a report of what it has: the firmware on its FM-1,
its library with versions, install history, SMC-PAD state. Every install can GET all reports, so
each one can show what the others have. Reports land in checkins/<install-id>.json, and
checkins/SUMMARY.md is rewritten on every check-in for people and Claude Code to read.

  python3 tools/checkin_server.py [--port 8765]

Advertised on the local network over Bonjour as _fm1checkin._tcp (macOS dns-sd), so the app
finds it with no setup. Local network only; anyone on the Wi-Fi could post, so keep it at home.
"""
import argparse
import datetime as dt
import http.server
import json
import pathlib
import re
import socket
import subprocess
import threading

ROOT = pathlib.Path(__file__).resolve().parent.parent
STORE = ROOT / "checkins"
ID = re.compile(r"^[A-Za-z0-9-]{8,64}$")
MAX_BODY = 512 * 1024
LOCK = threading.Lock()


def load_all():
    out = []
    for f in sorted(STORE.glob("*.json")):
        try:
            out.append(json.loads(f.read_text()))
        except (OSError, ValueError):
            continue
    return out


def ago(iso):
    try:
        t = dt.datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except (AttributeError, ValueError):
        return "?"
    s = (dt.datetime.now(dt.timezone.utc) - t).total_seconds()
    for unit, n in (("d", 86400), ("h", 3600), ("min", 60)):
        if s >= n:
            return f"{int(s // n)} {unit} ago"
    return "just now"


def write_summary():
    lines = ["# FM-1 Swapper check-ins", "",
             f"Updated {dt.datetime.now().strftime('%Y-%m-%d %H:%M')}. One section per app install; "
             "newest report from each. Raw data: checkins/<install>.json.", ""]
    for c in sorted(load_all(), key=lambda c: c.get("receivedAt", ""), reverse=True):
        inst = c.get("install", {})
        fm1 = c.get("fm1") or {}
        lines.append(f"## {inst.get('deviceName', '?')} ({inst.get('deviceModel', '?')})")
        lines.append(f"- Checked in {ago(c.get('receivedAt'))} ({c.get('receivedAt', '?')}), "
                     f"app {inst.get('appVersion', '?')} ({inst.get('build', '?')}), install `{inst.get('id', '?')}`")
        if fm1.get("identity"):
            lines.append(f"- FM-1: **{fm1.get('firmwareName') or fm1.get('identity')}** (`{fm1.get('identity')}`, "
                         f"{fm1.get('family', '?')}), {'connected' if fm1.get('connected') else 'last seen ' + ago(fm1.get('lastSeen'))}")
        else:
            lines.append("- FM-1: never seen by this install")
        last = c.get("lastInstall")
        if last:
            lines.append(f"- Last install: {last.get('firmware')} `{last.get('to')}` on {last.get('date', '?')[:16]} "
                         f"({'ok' if last.get('success') else 'FAILED: ' + last.get('message', '')})")
        pads = c.get("pads") or {}
        if pads.get("connected") or pads.get("padFirmware"):
            lines.append(f"- SMC-PAD: {', '.join(pads.get('connected') or []) or 'not connected'}"
                         + (f", firmware {pads['padFirmware']}" if pads.get("padFirmware") else ""))
        lib = c.get("library") or []
        lines.append(f"- Library ({len(lib)}):")
        for f in lib:
            v = f.get("version") or f.get("product")
            inst_at = f.get("lastInstalled")
            lines.append(f"  - {f.get('name')} — {v} (`{f.get('product')}`, sha {f.get('sha256', '')[:12]}), "
                         f"{f.get('status')}{', installed ' + inst_at[:10] if inst_at else ''}"
                         f"{'' if f.get('hasPackage') else ', no file'}")
        lines.append("")
    (STORE / "SUMMARY.md").write_text("\n".join(lines))


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "FM1CheckIn/1"

    def send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            return self.send(200, {"ok": True, "host": socket.gethostname()})
        if self.path.rstrip("/") == "/checkins":
            with LOCK:
                return self.send(200, {"host": socket.gethostname(), "checkins": load_all()})
        self.send(404, {"error": "not found"})

    def do_PUT(self):
        m = re.fullmatch(r"/checkins/([^/]+)", self.path)
        if not m or not ID.match(m[1]):
            return self.send(400, {"error": "bad install id"})
        n = int(self.headers.get("Content-Length") or 0)
        if not 0 < n <= MAX_BODY:
            return self.send(413, {"error": "body too large or empty"})
        try:
            c = json.loads(self.rfile.read(n))
        except ValueError:
            return self.send(400, {"error": "not JSON"})
        if not isinstance(c, dict) or not isinstance(c.get("install"), dict) or c["install"].get("id") != m[1]:
            return self.send(400, {"error": "report must have install.id matching the URL"})
        c["receivedAt"] = dt.datetime.now(dt.timezone.utc).isoformat()
        c["fromAddress"] = self.client_address[0]
        with LOCK:
            tmp = STORE / f".{m[1]}.tmp"
            tmp.write_text(json.dumps(c, indent=2, sort_keys=True))
            tmp.replace(STORE / f"{m[1]}.json")
            write_summary()
        self.log_message("check-in from %s (%s)", c["install"].get("deviceName"), m[1])
        self.send(200, {"ok": True})

    do_POST = do_PUT


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    a = ap.parse_args()
    STORE.mkdir(exist_ok=True)
    httpd = http.server.ThreadingHTTPServer(("0.0.0.0", a.port), Handler)
    name = f"FM-1 Swapper on {socket.gethostname().split('.')[0]}"
    adv = subprocess.Popen(["dns-sd", "-R", name, "_fm1checkin._tcp", "local", str(a.port)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"check-in server on :{a.port}, advertised as '{name}', storing in {STORE}")
    try:
        httpd.serve_forever()
    finally:
        adv.terminate()


if __name__ == "__main__":
    main()
