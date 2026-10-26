#!/usr/bin/env python3
"""Local stand-in for a model API, for offline launch checks.

Usage: python3 -I capture_server.py PORT OUT

Every POST body is appended to OUT as one line (`PATH BODY`) and answered
with HTTP 400, so the CLI under test gives up without a model ever being
called. Point the CLI's API address at http://127.0.0.1:PORT and give it a
scratch home and a dummy key: no request leaves the machine.
"""
import http.server
import json
import sys

OUT = sys.argv[2]
REPLY = json.dumps(
    {"type": "error", "error": {"type": "invalid_request_error", "message": "capture only"}}
).encode()


class Capture(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(OUT, "ab") as handle:
            handle.write(self.path.encode() + b" " + body + b"\n")
        self.send_response(400)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(REPLY)))
        self.end_headers()
        self.wfile.write(REPLY)

    def do_GET(self):
        self.send_response(404)
        self.end_headers()

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Capture).serve_forever()
