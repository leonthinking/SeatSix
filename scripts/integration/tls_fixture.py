#!/usr/bin/env python3
"""Loopback-only TLS fixture for pin, Range, HLS and real AVPlayer relay tests.

The caller supplies a disposable certificate/key and an optional synthetic MP4.
This fixture never connects to another server and never logs request URLs.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlsplit


class Fixture(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_HEAD(self):
        self.serve(head=True)

    def do_GET(self):
        self.serve(head=False)

    def serve(self, head):
        parts = urlsplit(self.path)
        # Missing inherited authentication must fail, including nested HLS resources.
        if parse_qs(parts.query).get("api_key") != ["fixture-only-token"]:
            self.send_empty(401)
            return
        if parts.path == "/redirect.mp4":
            self.send_response(302)
            self.send_header("Location", "/bytes.bin?" + urlencode({"api_key": "fixture-only-token"}))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        manifests = {
            "/hls/playlist": '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\n/segment.bin\n#EXT-X-ENDLIST\n',
            "/master.m3u8": '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nvariant.m3u8\n',
            "/variant.m3u8": '#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXT-X-MAP:URI="init.bin"\n#EXTINF:6,\nsegment.bin\n#EXT-X-ENDLIST\n',
            "/unsafe.m3u8": '#EXTM3U\n#EXTINF:6,\nhttps://unapproved.invalid/secret.ts\n',
        }
        if parts.path in manifests:
            payload = manifests[parts.path].encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/vnd.apple.mpegurl")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if not head:
                self.wfile.write(payload)
            return
        media = self.server.media if parts.path == "/video.mp4" else None
        hls = False
        if parts.path.startswith("/hls/") and self.server.hls is not None:
            name = parts.path.removeprefix("/hls/")
            if "/" not in name and not name.startswith("."):
                candidate = self.server.hls / name
                if candidate.is_file():
                    media = candidate
                    hls = True
        if not hls and (parts.path not in {"/video.mp4", "/bytes.bin", "/key.bin", "/init.bin", "/segment.bin"} or (parts.path == "/video.mp4" and media is None)):
            self.send_empty(404)
            return
        length = media.stat().st_size if media else 2 * 1024 * 1024
        start, end = 0, length - 1
        range_header = self.headers.get("Range")
        if range_header:
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", range_header)
            if not match or not any(match.groups()):
                self.send_empty(416, length)
                return
            lower, upper = match.groups()
            if not lower:
                start = max(0, length - int(upper))
            else:
                start = int(lower)
                end = min(end, int(upper)) if upper else end
            if start >= length or end < start:
                self.send_empty(416, length)
                return
        self.send_response(206 if range_header else 200)
        content_type = "application/vnd.apple.mpegurl" if hls and media.suffix == ".m3u8" else "video/mp2t" if hls else "video/mp4" if media else "application/octet-stream"
        self.send_header("Content-Type", content_type)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if range_header:
            self.send_header("Content-Range", f"bytes {start}-{end}/{length}")
        self.end_headers()
        if head:
            return
        stream = media.open("rb") if media else None
        try:
            if stream:
                stream.seek(start)
            position = start
            while position <= end:
                count = min(16384, end - position + 1)
                payload = stream.read(count) if stream else bytes((position + i) % 251 for i in range(count))
                self.wfile.write(payload)
                position += len(payload)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass
        finally:
            if stream:
                stream.close()

    def send_empty(self, status, length=None):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        if length is not None:
            self.send_header("Content-Range", f"bytes */{length}")
        self.end_headers()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--certificate", type=Path, required=True)
    parser.add_argument("--key", type=Path, required=True)
    parser.add_argument("--ready", type=Path, required=True)
    parser.add_argument("--media", type=Path)
    parser.add_argument("--hls", type=Path)
    options = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    server.daemon_threads = True
    server.media = options.media
    server.hls = options.hls
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(options.certificate, options.key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    options.ready.write_text(json.dumps({"port": server.server_port}))
    server.serve_forever()


if __name__ == "__main__":
    main()
