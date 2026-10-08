#!/usr/bin/env python3
"""Loopback test server for BTR-iOS host tests.

Serves a deterministic media file with HTTP Range support, a fake JSON playurl API and a fake
gRPC PlayViewUnite endpoint (gzip-compressed frame). Modes: ok, forbidden, slow.
"""
import gzip
import json
import random
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
MODE = sys.argv[2] if len(sys.argv) > 2 else "ok"
MEDIA_PORT = int(sys.argv[3]) if len(sys.argv) > 3 else PORT
SIZE = 7_340_033
DATA = random.Random(42).randbytes(SIZE)

VIDEO = f"http://127.0.0.1:{MEDIA_PORT}/upgcxcode/11/22/333-1-100026.m4s?deadline=1999999999&upsig=abc"
VIDEO_BACKUP = f"http://localhost:{MEDIA_PORT}/upgcxcode/11/22/333-1-100026.m4s?deadline=1999999999&upsig=def"
AUDIO = f"http://127.0.0.1:{MEDIA_PORT}/upgcxcode/11/22/333-1-30280.m4s?deadline=1999999999"


def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def field(num, wire, payload):
    tag = varint((num << 3) | wire)
    if wire == 2:
        return tag + varint(len(payload)) + payload
    return tag + payload


def s(num, text):
    return field(num, 2, text.encode())


def grpc_reply():
    dash_video = s(1, VIDEO) + s(2, VIDEO_BACKUP) + field(3, 0, varint(2048000))
    stream = field(1, 0, varint(80)) + field(2, 2, dash_video)
    audio = field(1, 0, varint(30280)) + s(2, AUDIO) + s(3, AUDIO + "&b=1")
    vod = field(1, 0, varint(1)) + field(5, 2, stream) + field(6, 2, audio) + s(9, "plain text with no url")
    return field(1, 2, vod) + field(2, 0, varint(7))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send_body(self, code, body, ctype, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(length)
        if "PlayViewUnite" in self.path:
            payload = gzip.compress(grpc_reply())
            frame = bytes([1]) + len(payload).to_bytes(4, "big") + payload
            self.send_body(200, frame, "application/grpc", {"grpc-encoding": "gzip", "grpc-status": "0"})
        else:
            self.send_body(404, b"", "text/plain")

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/x/player/playurl":
            body = {
                "code": 0,
                "data": {
                    "dash": {
                        "video": [{"id": 80, "base_url": VIDEO, "baseUrl": VIDEO, "backup_url": [VIDEO_BACKUP], "backupUrl": [VIDEO_BACKUP]}],
                        "audio": [{"id": 30280, "base_url": AUDIO, "baseUrl": AUDIO, "backup_url": [], "backupUrl": []}],
                    }
                },
            }
            self.send_body(200, json.dumps(body).encode(), "application/json")
            return
        if not path.endswith(".m4s"):
            self.send_body(404, b"", "text/plain")
            return
        if MODE == "forbidden":
            self.send_body(403, b"", "text/plain")
            return
        rng = self.headers.get("Range")
        if not rng:
            self.send_body(200, DATA, "video/mp4")
            return
        spec = rng.split("=", 1)[1]
        a, b = spec.split("-")
        start = int(a)
        end = int(b) if b else SIZE - 1
        if start >= SIZE:
            self.send_body(416, b"", "text/plain", {"Content-Range": f"bytes */{SIZE}"})
            return
        end = min(end, SIZE - 1)
        chunk = DATA[start : end + 1]
        self.send_response(206)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(len(chunk)))
        self.send_header("Content-Range", f"bytes {start}-{end}/{SIZE}")
        self.end_headers()
        if self.command == "HEAD":
            return
        try:
            if MODE == "slow":
                for i in range(0, len(chunk), 65536):
                    self.wfile.write(chunk[i : i + 65536])
                    time.sleep(0.02)
            else:
                self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass


ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
