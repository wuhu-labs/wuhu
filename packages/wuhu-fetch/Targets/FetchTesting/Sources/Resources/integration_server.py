#!/usr/bin/env python3

import argparse
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


gated_sse_events = {}
gated_sse_events_lock = threading.Lock()


def gated_sse_event(identifier):
    with gated_sse_events_lock:
        event = gated_sse_events.get(identifier)
        if event is None:
            event = threading.Event()
            gated_sse_events[identifier] = event
        return event


def release_gated_sse_event(identifier):
    with gated_sse_events_lock:
        event = gated_sse_events.get(identifier)
        if event is None:
            event = threading.Event()
            gated_sse_events[identifier] = event
        event.set()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self._handle()

    def do_POST(self):
        self._handle()

    def do_PUT(self):
        self._handle()

    def do_PATCH(self):
        self._handle()

    def do_DELETE(self):
        self._handle()

    def _read_body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            body = b""
            while True:
                size = int(self.rfile.readline().split(b";", 1)[0].strip(), 16)
                if size == 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                        pass
                    return body
                body += self.rfile.read(size)
                self.rfile.readline()
        content_length = int(self.headers.get("Content-Length", "0"))
        if content_length == 0:
            return b""
        return self.rfile.read(content_length)

    def _write_response(self, status_code, body, content_type="text/plain; charset=utf-8"):
        self.send_response(status_code)
        self.send_header("Content-Type", content_type)
        self.send_header("Connection", "close")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def _handle(self):
        parsed = urlparse(self.path)

        if parsed.path == "/early-error":
            self.send_response(400)
            self.send_header("Content-Length", "1")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.flush()
            time.sleep(0.01)
            self.connection.settimeout(1)
            try:
                self._read_body()
            except (TimeoutError, ConnectionError):
                pass
            self.wfile.write(b"!")
            self.wfile.flush()
            self.close_connection = True
            return

        if parsed.path == "/error-after-first-chunk":
            # The 400 head goes out only after the first chunk has arrived, so
            # the client had already written it when the head paused its
            # upload. The response end then waits for the terminating chunk:
            # "!" once it has arrived, "?" if the client never sent it.
            self.rfile.read(int(self.rfile.readline().split(b";", 1)[0].strip(), 16))
            self.rfile.readline()
            self.send_response(400)
            self.send_header("Content-Length", "1")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.flush()
            # This bound only covers teardown when a client never ends its upload.
            self.connection.settimeout(30)
            try:
                self._read_body()
                ended = True
            except (TimeoutError, ConnectionError, ValueError):
                ended = False
            self.wfile.write(b"!" if ended else b"?")
            self.wfile.flush()
            self.close_connection = True
            return

        if parsed.path == "/echo":
            body = self._read_body()
            payload = {
                "method": self.command,
                "path": parsed.path,
                "query": parse_qs(parsed.query),
                "headers": dict(self.headers.items()),
                "body": body.decode("utf-8", errors="replace"),
            }
            self._write_response(200, json.dumps(payload).encode("utf-8"), "application/json")
            return

        if parsed.path.startswith("/status/"):
            code = int(parsed.path.split("/")[-1])
            self._write_response(code, f"status:{code}".encode("utf-8"))
            return

        if parsed.path == "/stream":
            query = parse_qs(parsed.query)
            count = int(query.get("count", ["3"])[0])
            delay = float(query.get("delay", ["0.01"])[0])
            prefix = query.get("prefix", ["chunk"])[0]
            chunks = [f"{prefix}-{index}\n".encode("utf-8") for index in range(count)]

            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Connection", "close")
            self.send_header("Content-Length", str(sum(len(chunk) for chunk in chunks)))
            self.end_headers()

            for chunk in chunks:
              self.wfile.write(chunk)
              self.wfile.flush()
              time.sleep(delay)
            self.close_connection = True
            return

        if parsed.path == "/sse":
            body = (
                "event: greeting\n"
                "id: 42\n"
                "retry: 1500\n"
                "data: hello\n"
                "data: world\n"
                "\n"
            ).encode("utf-8")

            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
            self.close_connection = True
            return

        if parsed.path == "/sse-gated":
            identifier = parse_qs(parsed.query).get("id", [""])[0]
            event = gated_sse_event(identifier)

            first = (
                "event: greeting\n"
                "id: 1\n"
                "data: first\n"
                "\n"
            ).encode("utf-8")
            second = (
                "event: greeting\n"
                "id: 2\n"
                "data: second\n"
                "\n"
            ).encode("utf-8")
            timeout = (
                "event: error\n"
                "data: timed out waiting for release\n"
                "\n"
            ).encode("utf-8")

            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()

            self.wfile.write(first)
            self.wfile.flush()
            if event.wait(timeout=10):
                self.wfile.write(second)
            else:
                self.wfile.write(timeout)
            self.wfile.flush()
            self.close_connection = True
            return

        if parsed.path == "/release-sse":
            identifier = parse_qs(parsed.query).get("id", [""])[0]
            release_gated_sse_event(identifier)
            self._write_response(200, b"released")
            return

        if parsed.path == "/sse-stream":
            delay = float(parse_qs(parsed.query).get("delay", ["0.75"])[0])
            events = [
                (
                    "event: greeting\n"
                    "id: 1\n"
                    "data: first\n"
                    "\n"
                ).encode("utf-8"),
                (
                    "event: greeting\n"
                    "id: 2\n"
                    "data: second\n"
                    "\n"
                ).encode("utf-8"),
            ]

            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.send_header("Content-Length", str(sum(len(event) for event in events)))
            self.end_headers()

            self.wfile.write(events[0])
            self.wfile.flush()
            time.sleep(delay)
            self.wfile.write(events[1])
            self.wfile.flush()
            self.close_connection = True
            return

        self._write_response(404, b"not found")

    def log_message(self, format, *args):
        return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(args.port_file, "w", encoding="utf-8") as file:
        file.write(str(server.server_port))
        file.flush()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
