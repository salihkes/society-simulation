"""Receives OBJ/MTL text from the ExportOBJ Studio plugin and writes the files.

Studio plugins cannot write to disk, so the plugin POSTs each model here in
chunks. Started by tools/art/roblox_export.sh; listens on 127.0.0.1 only.

    POST /open?name=Export_Foo   start (truncates Export_Foo.obj / .mtl)
    POST /obj?name=Export_Foo    append text to the .obj
    POST /mtl?name=Export_Foo    append text to the .mtl
    POST /done?name=Export_Foo   body = one-line summary, printed here
    POST /log                    body printed (the end-of-run report)
    GET  /ping                   "ok"
"""

import os
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("ROBLOX_EXPORT_PORT", "34900"))
OUT = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/Desktop/Roblox Export")


def safe(name):
    name = re.sub(r'[\\/:*?"<>|\x00-\x1f]', "_", name).strip(" .")
    return name or "unnamed"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, text):
        data = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply(200, "ok" if self.path.startswith("/ping") else "?")

    def do_POST(self):
        url = urlparse(self.path)
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8", "replace")
        name = safe(parse_qs(url.query).get("name", ["unnamed"])[0])
        obj = os.path.join(OUT, name + ".obj")
        mtl = os.path.join(OUT, name + ".mtl")
        if url.path == "/open":
            os.makedirs(OUT, exist_ok=True)
            with open(obj, "w") as f:
                f.write(f"# exported from Roblox Studio by tools/art/roblox_export\nmtllib {name}.mtl\n")
            open(mtl, "w").close()
        elif url.path == "/obj":
            with open(obj, "a") as f:
                f.write(body)
        elif url.path == "/mtl":
            with open(mtl, "a") as f:
                f.write(body)
        elif url.path == "/done":
            print(f"  wrote {name}.obj  {body}", flush=True)
        elif url.path == "/log":
            print(body, flush=True)
        else:
            return self.reply(404, "?")
        self.reply(200, "ok")


if __name__ == "__main__":
    print(f"[roblox_export] files go to {OUT}", flush=True)
    print(f"[roblox_export] listening on 127.0.0.1:{PORT} — in Studio press Plugins > Export_ to OBJ. Ctrl+C stops.", flush=True)
    try:
        HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        pass
