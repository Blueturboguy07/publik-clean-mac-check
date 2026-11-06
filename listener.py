# A local stand-in for the publik endpoint: writes each POST body as one line. Answers 204.
import http.server, sys
port, path = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("content-length") or 0); b = self.rfile.read(n).decode("utf-8", "replace")
        if "/telemetry" in self.path:
            open(path, "a").write(b.replace("\n", " ") + "\n")
        self.send_response(204); self.end_headers()
    def do_GET(self):
        self.send_response(404); self.end_headers()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
