#!/usr/bin/env python
"""HTTP server for .pck resource packs (/pck/manifest.json, /pck/<name>.pck) and country map files (/pck/region/)."""

import asyncio
import os
import json
import urllib.parse

from core import paths
from core.constants import PCK_PACKAGES_DIR, PCK_MANIFEST_FILE, PCK_HTTP_SERVER_PORT, EXTERNAL_DOMAIN


def _disk_version(pck_path):
    """A pack's version: the content hash in <pack>.pck.version (so a rebuild is not re-downloaded), else size and mtime."""
    try:
        with open(pck_path + ".version", "r") as f:
            version = f.read().strip()
        if version:
            return version
    except OSError:
        pass
    try:
        st = os.stat(pck_path)
        return f"{st.st_size}-{int(st.st_mtime)}"
    except OSError:
        return "0"


def _read_static_manifest():
    """The parsed pck_manifest.json, or None when it is missing or unreadable."""
    if not os.path.exists(PCK_MANIFEST_FILE):
        return None
    try:
        with open(PCK_MANIFEST_FILE, "r") as f:
            return json.load(f)
    except Exception as e:
        print(f"[PCK Server] Error reading manifest: {e}")
        return None


def _add_discovered_packs(packages):
    """Add every .pck on disk that the manifest does not list; a listed entry wins."""
    if not os.path.isdir(PCK_PACKAGES_DIR):
        return
    for filename in sorted(os.listdir(PCK_PACKAGES_DIR)):
        if not filename.endswith(".pck"):
            continue
        pack_name = filename[:-len(".pck")]
        if pack_name in packages:
            continue
        packages[pack_name] = {
            "version": _disk_version(os.path.join(PCK_PACKAGES_DIR, filename)),
            "filename": filename,
        }


def get_pck_manifest():
    """pck_manifest.json's entries plus every other .pck on disk (optional, not instantiated); blanks filled from disk."""
    manifest = {"packages": {}}

    loaded = _read_static_manifest()
    if isinstance(loaded, dict) and isinstance(loaded.get("packages"), dict):
        manifest = loaded
        manifest.setdefault("packages", {})
    packages = manifest["packages"]
    for pack_name, info in list(packages.items()):
        if not isinstance(info, dict):
            continue
        filename = info.get("filename") or (pack_name + ".pck")
        info["filename"] = filename
        if not info.get("version"):
            info["version"] = _disk_version(os.path.join(PCK_PACKAGES_DIR, filename))

    try:
        _add_discovered_packs(packages)
    except Exception as e:
        print(f"[PCK Server] Error scanning {PCK_PACKAGES_DIR}: {e}")
    return manifest


def get_manifest_for_client(use_ssl=True):
    """The manifest with the public download URL (https://<domain>/pck/); `use_ssl` is unused."""
    manifest = get_pck_manifest()
    manifest["download_base_url"] = f"https://{EXTERNAL_DOMAIN}/pck/"
    return manifest


def _parse_range(header, size):
    """'bytes=a-b' as clamped (a, b), 'unsatisfiable' past the end, None (whole file) when not a single plain range."""
    if not header or not header.startswith('bytes=') or size == 0:
        return None
    first, _, last = header[6:].split(',')[0].strip().partition('-')
    if not first.isdigit():
        return None
    start = int(first)
    if start >= size:
        return 'unsatisfiable'
    end = int(last) if last.isdigit() else size - 1
    if end < start:
        return 'unsatisfiable'
    return start, min(end, size - 1)


REGION_DIR = paths.assets("region")
REGION_PREFIX = '/pck/region/'


def region_file(rel):
    """Absolute path of a region file, or None when `rel` is empty or leaves the region folder."""
    rel = urllib.parse.unquote(rel.split('?', 1)[0])
    if not rel or '\x00' in rel:
        return None
    root = os.path.realpath(REGION_DIR)
    full = os.path.realpath(os.path.join(root, rel))
    if not full.startswith(root + os.sep):
        return None
    return full


async def _send_file(writer, filepath, label, range_header, cors, no_cache=False):
    """Stream one file, honouring a single byte Range; 404 when absent."""
    if not (os.path.exists(filepath) and os.path.isfile(filepath)):
        print(f"[PCK Server] File not found: {label}")
        writer.write(f'HTTP/1.1 404 Not Found\r\n{cors}Content-Length: 0\r\n\r\n'.encode())
        return
    file_size = os.path.getsize(filepath)
    span = _parse_range(range_header, file_size)
    if span == 'unsatisfiable':
        writer.write(
            f'HTTP/1.1 416 Range Not Satisfiable\r\n{cors}'
            f'Content-Range: bytes */{file_size}\r\n'
            f'Content-Length: 0\r\n\r\n'.encode())
        return
    start, end = span if span else (0, file_size - 1)
    length = max(0, end - start + 1)
    # Map tiles are small and many: only packs get a log line.
    quiet = label.endswith(('.f32', '.bin'))
    if not quiet:
        print(f"[PCK Server] Serving: {label} "
              f"({length:,} of {file_size:,} bytes"
              f"{' partial' if span else ''})")
    status = '206 Partial Content' if span else '200 OK'
    headers = (
        f'HTTP/1.1 {status}\r\n'
        f'{cors}'
        f'Content-Type: application/octet-stream\r\n'
        f'Content-Length: {length}\r\n'
        f'Accept-Ranges: bytes\r\n'
        + (f'Content-Range: bytes {start}-{end}/{file_size}\r\n' if span else '')
        + ('Cache-Control: no-cache\r\n' if no_cache else '')
        + f'Content-Disposition: attachment; filename="{os.path.basename(label)}"\r\n'
        f'\r\n'
    )
    writer.write(headers.encode())
    await writer.drain()
    with open(filepath, 'rb') as f:
        f.seek(start)
        left = length
        while left > 0:
            chunk = f.read(min(65536, left))
            if not chunk:
                break
            left -= len(chunk)
            writer.write(chunk)
            await writer.drain()
    if not quiet:
        print(f"[PCK Server] Completed: {label}")


# CORS, plus CORP so a cross-origin-isolated web build may fetch packs from another origin.
CORS_HEADERS = (
    "Access-Control-Allow-Origin: *\r\n"
    "Access-Control-Allow-Methods: GET, OPTIONS\r\n"
    "Access-Control-Allow-Headers: *\r\n"
    "Cross-Origin-Resource-Policy: cross-origin\r\n"
)
REQUEST_TIMEOUT_SECONDS = 10


def _empty_response(writer, status):
    writer.write(f'HTTP/1.1 {status}\r\n{CORS_HEADERS}Content-Length: 0\r\n\r\n'.encode())


async def _read_request(reader):
    """(method, path, Range header or None); None for an empty or malformed request line."""
    request_line = await asyncio.wait_for(reader.readline(), timeout=REQUEST_TIMEOUT_SECONDS)
    if not request_line:
        return None
    parts = request_line.decode('utf-8', errors='replace').strip().split(' ')
    if len(parts) < 3:
        return None
    range_header = None
    while True:
        header_line = await asyncio.wait_for(reader.readline(), timeout=REQUEST_TIMEOUT_SECONDS)
        if header_line in (b'\r\n', b'\n', b''):
            break
        name, sep, value = header_line.decode('latin-1').partition(':')
        if sep and name.strip().lower() == 'range':
            range_header = value.strip()
    return parts[0], parts[1], range_header


def _write_manifest(writer):
    body = json.dumps(get_pck_manifest(), indent=2).encode()
    headers = (
        f'HTTP/1.1 200 OK\r\n'
        f'{CORS_HEADERS}'
        f'Content-Type: application/json\r\n'
        f'Content-Length: {len(body)}\r\n'
        f'Cache-Control: no-cache\r\n'
        f'\r\n'
    )
    writer.write(headers.encode() + body)


async def _route(writer, method, path, range_header):
    if method == 'OPTIONS':
        writer.write(f'HTTP/1.1 204 No Content\r\n{CORS_HEADERS}\r\n'.encode())
        return
    if method != 'GET':
        _empty_response(writer, '405 Method Not Allowed')
        return
    if path.startswith(REGION_PREFIX):
        filepath = region_file(path[len(REGION_PREFIX):])
        if filepath is None:
            _empty_response(writer, '403 Forbidden')
            return
        label = os.path.relpath(filepath, os.path.realpath(REGION_DIR))
        await _send_file(writer, filepath, label, range_header, CORS_HEADERS,
                         no_cache=filepath.endswith('index.json'))
        return
    if not path.startswith('/pck/'):
        _empty_response(writer, '404 Not Found')
        return
    filename = path[len('/pck/'):]
    if filename == 'manifest.json':
        _write_manifest(writer)
        return
    filename = os.path.basename(filename)   # no path traversal; packs only
    if not filename.endswith('.pck'):
        _empty_response(writer, '403 Forbidden')
        return
    await _send_file(writer, os.path.join(PCK_PACKAGES_DIR, filename), filename, range_header,
                     CORS_HEADERS)


async def handle_http_request(reader, writer):
    """Answer one HTTP request, then close the connection."""
    try:
        request = await _read_request(reader)
        if request is None:
            writer.close()
            return
        await _route(writer, *request)
        await writer.drain()
    except asyncio.TimeoutError:
        print("[PCK Server] Request timeout")
    except ConnectionResetError:
        pass
    except Exception as e:
        print(f"[PCK Server] Error handling request: {e}")
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except BaseException:     # closing must never fail the handler
            pass


def _sort_key(item):
    """Required packs first, then by priority, then the rest, as the client orders them."""
    name, info = item
    return (not info.get("required", False), "priority" not in info,
            info.get("priority", 0), name)


def _describe_pack(name, info):
    """One status line for a pack: version, file, presence, size and tags."""
    filename = info.get("filename", name + ".pck")
    version = info.get("version", "unknown")
    filepath = os.path.join(PCK_PACKAGES_DIR, filename)
    status = "OK" if os.path.exists(filepath) else "MISSING"
    size = ""
    if os.path.exists(filepath):
        size_bytes = os.path.getsize(filepath)
        if size_bytes > 1024 * 1024:
            size = f" ({size_bytes / (1024 * 1024):.1f} MB)"
        else:
            size = f" ({size_bytes / 1024:.1f} KB)"
    tags = []
    if info.get("required"):
        tags.append("REQUIRED")
    if "priority" in info:
        tags.append(f"prio={info['priority']}")
    if info.get("scene_path"):
        tags.append("scene")
    tag_str = (" {" + ", ".join(tags) + "}") if tags else ""
    return f"  - {name} v{version} ({filename}) [{status}]{size}{tag_str}"


async def start_pck_server(ssl_context=None):
    os.makedirs(PCK_PACKAGES_DIR, exist_ok=True)
    protocol = "https" if ssl_context else "http"
    server = await asyncio.start_server(
        handle_http_request,
        "0.0.0.0",
        PCK_HTTP_SERVER_PORT,
        ssl=ssl_context
    )
    print(f"[PCK Server] Listening on {protocol}://0.0.0.0:{PCK_HTTP_SERVER_PORT}")
    print(f"[PCK Server] Readers fetch these through the hub: https://{EXTERNAL_DOMAIN}/pck/")
    print(f"[PCK Server] This port ({PCK_HTTP_SERVER_PORT}) is for the annex agent "
          f"on loopback only.")
    packages = get_pck_manifest().get("packages", {})
    if packages:
        print(f"[PCK Server] Serving {len(packages)} package(s):")
        for name, info in sorted(packages.items(), key=_sort_key):
            print(_describe_pack(name, info))
    else:
        print(f"[PCK Server] No packages configured in {PCK_MANIFEST_FILE}")
        print("[PCK Server] To add packages:")
        print(f"  1. Place .pck files in {PCK_PACKAGES_DIR}/")
        print(f"  2. Edit {PCK_MANIFEST_FILE} to register them with versions")
    async with server:
        await server.serve_forever()
