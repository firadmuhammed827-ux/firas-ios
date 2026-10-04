"""Loopback-only synthetic HTTP fixtures for the real Swift APIClient.

Mac runner starts this as one child process, passes --port-file, and terminates
that exact child PID in a finally/trap. No production URL, account, API key or
body/header logging is used. Only counters, synthetic byte sizes and digests
are available through /fixture/state. The server binds 127.0.0.1 port0.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import gzip
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading
import struct
from urllib.parse import parse_qs, urlsplit


PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aRZkAAAAASUVORK5CYII="
)
IMAGE_LENGTH = 1_048_576
IMAGE_CHUNK = b"\0" * 65_536
IMAGE_DIGEST = hashlib.sha256(PNG + bytes(IMAGE_LENGTH - len(PNG))).hexdigest()
MP4 = b"\0\0\0\x18ftypisom\0\0\0\0isomiso2\0\0\0\x08mdat"
WAV = b"RIFF" + struct.pack("<I", 44) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 8000, 16000, 2, 16) + b"data" + struct.pack("<I", 8) + bytes(8)
KEY_CASES = {character * 64: name for character, name in [
    ("a", "normal"), ("b", "unknown_length"), ("c", "declared_cap"),
    ("d", "stream_cap"), ("e", "mime_mismatch"), ("f", "random_bytes"),
    ("1", "truncated"), ("2", "same_origin_redirect"), ("3", "foreign_origin_redirect"),
    ("4", "encoded_response"), ("5", "unauthorized"), ("6", "cancel"),
    ("7", "credential_change"), ("8", "stale_before_http"), ("9", "cancel_before_http"),
]}


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False

    def __init__(self):
        super().__init__(("127.0.0.1", 0), FixtureHandler)
        self.state_lock = threading.Lock()
        self.requests: dict[str, int] = {}
        self.frozen_cookie_seen: dict[str, bool] = {}
        self.post_count = 0
        self.post_bytes: list[int] = []
        self.post_frozen_cookie_seen = True
        self.redirect_target_hits = 0
        self.gates = {name: threading.Event() for name in ["cancel", "credential_change"]}

    def record(self, name: str, cookie: str):
        # Synthetic fixture cookie only. Never retain the whole request header.
        matches = "firas_media_fixture_auth=owner-a" in cookie
        with self.state_lock:
            self.requests[name] = self.requests.get(name, 0) + 1
            self.frozen_cookie_seen[name] = self.frozen_cookie_seen.get(name, True) and matches

    def summary(self):
        with self.state_lock:
            return {"requests": dict(self.requests), "frozenCookieSeen": dict(self.frozen_cookie_seen),
                    "postCount": self.post_count, "postBytes": list(self.post_bytes),
                    "postFrozenCookieSeen": self.post_frozen_cookie_seen,
                    "redirectTargetHits": self.redirect_target_hits,
                    "imageBytes": IMAGE_LENGTH, "imageSHA256": IMAGE_DIGEST}


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def respond(self, status, mime="image/png", length=None, headers=None):
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Set-Cookie", "firas_media_fixture_poison=changed; Path=/; SameSite=Lax")
        self.send_header("Content-Disposition", 'attachment; filename="../../untrusted.png"')
        if length is not None:
            self.send_header("Content-Length", str(length))
        else:
            self.send_header("Connection", "close")
            self.close_connection = True
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()

    def json_response(self, payload):
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.respond(200, "application/json", len(data))
        self.wfile.write(data)

    def write_zeros(self, length):
        while length:
            data = IMAGE_CHUNK[:min(length, len(IMAGE_CHUNK))]
            self.wfile.write(data)
            self.wfile.flush()
            length -= len(data)

    def do_GET(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query, keep_blank_values=True)
        if url.path == "/fixture/state":
            self.json_response(self.server.summary())
            return
        if url.path == "/fixture/release":
            names = query.get("case", [])
            if len(names) == 1 and names[0] in self.server.gates:
                self.server.gates[names[0]].set()
                self.json_response({"ok": True})
            else:
                self.respond(400, "application/json", 0)
            return
        if url.path == "/fixture/redirect-target":
            with self.server.state_lock:
                self.server.redirect_target_hits += 1
            self.respond(200, length=len(PNG))
            self.wfile.write(PNG)
            return
        # Match the actual saved MediaAssetPolicy paths; do not add fake assets.
        expected_query = {"/api/image": "key", "/api/video/file": "id", "/api/music/file": "id"}.get(url.path)
        values = query.get(expected_query, []) if expected_query else []
        if expected_query is None or set(query) != {expected_query} or len(values) != 1:
            self.respond(404, "application/json", 0)
            return
        case = KEY_CASES.get(values[0])
        if case is None:
            self.respond(404, "application/json", 0)
            return
        self.server.record(case, self.headers.get("Cookie", ""))
        try:
            if case == "normal" and url.path in ["/api/video/file", "/api/music/file"]:
                data, mime = (MP4, "video/mp4") if url.path == "/api/video/file" else (WAV, "audio/wav")
                self.respond(200, mime, len(data))
                self.wfile.write(data)
            elif case in ["same_origin_redirect", "foreign_origin_redirect"]:
                host = "127.0.0.1" if case == "same_origin_redirect" else "localhost"
                target = f"http://{host}:{self.server.server_port}/fixture/redirect-target"
                self.respond(302, length=0, headers={"Location": target})
            elif case == "declared_cap":
                # Rejected from the header, without sending25MB into the client.
                self.respond(200, length=25_000_001)
                self.close_connection = True
            elif case == "stream_cap":
                # No Content-Length: the real delegate must enforce received bytes.
                self.respond(200)
                self.wfile.write(PNG)
                self.write_zeros(25_000_001 - len(PNG))
            elif case == "mime_mismatch":
                self.respond(200, "image/jpeg", len(PNG))
                self.wfile.write(PNG)
            elif case == "random_bytes":
                data = b"synthetic bytes are not a PNG container"
                self.respond(200, length=len(data))
                self.wfile.write(data)
            elif case == "truncated":
                self.respond(200, length=4_096)
                self.wfile.write(PNG)
                self.wfile.flush()
                self.close_connection = True
            elif case == "encoded_response":
                data = gzip.compress(PNG, mtime=0)
                self.respond(200, length=len(data), headers={"Content-Encoding": "gzip"})
                self.wfile.write(data)
            elif case == "unauthorized":
                data = b'{"error":"fixture_unavailable"}'
                self.respond(401, "application/json", len(data))
                self.wfile.write(data)
            elif case in self.server.gates:
                self.respond(200, length=IMAGE_LENGTH)
                self.wfile.write(PNG)
                self.wfile.write(IMAGE_CHUNK)
                self.wfile.flush()
                if self.server.gates[case].wait(timeout=15):
                    self.write_zeros(IMAGE_LENGTH - len(PNG) - len(IMAGE_CHUNK))
                self.close_connection = True
            else:
                self.respond(200, "application/octet-stream" if case == "unknown_length" else "image/png",
                             None if case == "unknown_length" else IMAGE_LENGTH)
                self.wfile.write(PNG)
                self.write_zeros(IMAGE_LENGTH - len(PNG))
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            # A rejection or cancelled transfer closes its own connection.
            pass

    def do_POST(self):
        if urlsplit(self.path).path != "/api/chats":
            self.respond(404, "application/json", 0)
            return
        count = int(self.headers.get("Content-Length", "0"))
        remaining = count
        while remaining:
            chunk = self.rfile.read(min(65_536, remaining))
            if not chunk:
                break
            remaining -= len(chunk)
        with self.server.state_lock:
            self.server.post_count += 1
            self.server.post_bytes.append(count - remaining)
            self.server.post_frozen_cookie_seen &= "firas_media_fixture_auth=owner-a" in self.headers.get("Cookie", "")
        self.json_response({"ok": remaining == 0})


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args()
    server = FixtureServer()
    path = Path(args.port_file).resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(str(server.server_port) + "\n", encoding="utf-8")
    print("synthetic_media_fixture_ready", flush=True)
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        server.server_close()
