"""The country map route: /pck/region/<path> serves published files with
byte ranges, and nothing outside the region folder."""
import asyncio
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))

from services import pck  # noqa: E402


async def fetch(port, path, headers=()):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    writer.write((f"GET {path} HTTP/1.1\r\nHost: x\r\n" + "".join(f"{h}\r\n" for h in headers) + "\r\n").encode())
    await writer.drain()
    raw = await reader.read()
    writer.close()
    head, _, body = raw.partition(b"\r\n\r\n")
    lines = head.decode().split("\r\n")
    status = int(lines[0].split()[1])
    hdrs = dict(l.split(": ", 1) for l in lines[1:] if ": " in l)
    return status, hdrs, body


class RegionRouteTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "region"
        (self.root / "abc").mkdir(parents=True)
        self.page = bytes(range(256)) * 64
        (self.root / "abc/0_0.bin").write_bytes(self.page)
        (self.root / "index.json").write_text('{"files": {}}')
        (Path(self.tmp.name) / "secret.txt").write_text("no")
        patcher = patch.object(pck, "REGION_DIR", str(self.root))
        patcher.start()
        self.addCleanup(patcher.stop)

    def serve(self, *requests):
        async def main():
            server = await asyncio.start_server(pck.handle_http_request, "127.0.0.1", 0)
            port = server.sockets[0].getsockname()[1]
            try:
                return [await fetch(port, path, headers) for path, headers in requests]
            finally:
                server.close()
                await server.wait_closed()
        return asyncio.run(main())

    def test_a_tile_is_a_byte_range_of_its_page(self):
        (status, hdrs, body), = self.serve(("/pck/region/abc/0_0.bin", ("Range: bytes=100-299",)))
        self.assertEqual(status, 206)
        self.assertEqual(body, self.page[100:300])
        self.assertEqual(hdrs["Content-Range"], f"bytes 100-299/{len(self.page)}")

    def test_a_whole_file_and_the_uncached_index(self):
        (s1, _, body), (s2, hdrs, _) = self.serve(("/pck/region/abc/0_0.bin", ()), ("/pck/region/index.json", ()))
        self.assertEqual((s1, body), (200, self.page))
        self.assertEqual(s2, 200)
        self.assertEqual(hdrs.get("Cache-Control"), "no-cache")

    def test_nothing_outside_the_region_folder(self):
        results = self.serve(("/pck/region/../secret.txt", ()), ("/pck/region/%2e%2e/secret.txt", ()),
                             ("/pck/region/abc/missing.bin", ()))
        self.assertEqual([r[0] for r in results], [403, 403, 404])
        self.assertIsNone(pck.region_file(os.path.join("..", "secret.txt")))

    def test_packs_still_served(self):
        (status, _, _), = self.serve(("/pck/region", ()),)
        self.assertEqual(status, 403)   # /pck/region without a file is a pack name, not a .pck


if __name__ == "__main__":
    unittest.main()
