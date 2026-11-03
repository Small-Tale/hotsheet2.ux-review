"""One-shot file exchange between the host and a Parallels test guest (HS2-GR8A2A).

Serves only the files in --serve over GET and stores PUT uploads only into --receive,
bound to the host-only Parallels address. It holds no credentials and exits when the
parent runner closes it (or after --idle-timeout seconds without request or transfer progress), so nothing
keeps listening between runs.
"""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re
import sys
import threading
import time

NAME = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')
CHUNK = 1 << 20


def handler(serve: Path, receive: Path, activity: list):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def _name(self):
            activity[0] = time.monotonic()
            name = self.path.lstrip('/')
            if not NAME.match(name):
                self.send_error(400, 'invalid name')
                return None
            return name

        def do_GET(self):
            name = self._name()
            if name is None:
                return
            source = serve / name
            if not source.is_file():
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Length', str(source.stat().st_size))
            self.end_headers()
            with source.open('rb') as data:
                while chunk := data.read(CHUNK):
                    self.wfile.write(chunk)
                    activity[0] = time.monotonic()

        def do_PUT(self):
            name = self._name()
            if name is None:
                return
            try:
                remaining = int(self.headers.get('Content-Length', ''))
            except ValueError:
                self.send_error(411)
                return
            partial = receive / (name + '.partial')
            with partial.open('wb') as out:
                while remaining > 0:
                    chunk = self.rfile.read(min(CHUNK, remaining))
                    if not chunk:
                        break
                    out.write(chunk)
                    remaining -= len(chunk)
                    activity[0] = time.monotonic()
            if remaining:
                partial.unlink(missing_ok=True)
                self.send_error(400, 'truncated upload')
                return
            partial.replace(receive / name)
            self.send_response(201)
            self.send_header('Content-Length', '0')
            self.end_headers()

    return Handler


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('--bind', required=True)
    parser.add_argument('--port', type=int, default=0)
    parser.add_argument('--serve', type=Path, required=True)
    parser.add_argument('--receive', type=Path, required=True)
    parser.add_argument('--idle-timeout', type=float, default=1800)
    args = parser.parse_args(argv)
    args.receive.mkdir(parents=True, exist_ok=True)
    activity = [time.monotonic()]
    server = ThreadingHTTPServer((args.bind, args.port),
                                 handler(args.serve.resolve(), args.receive.resolve(), activity))
    print(server.server_address[1], flush=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        while time.monotonic() - activity[0] < args.idle_timeout:
            time.sleep(0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
    return 0


if __name__ == '__main__':
    sys.exit(main())
