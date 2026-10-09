#!/usr/bin/env python3
"""Publish the country map's files for the web build to stream and keep.

The browser build ships only the small JSON manifests of the country
(client/assets/world/region/data/*.json); the terrain tiles and road
chunks are fetched from the server as the player comes near them, and kept in
the browser's own storage (user://regioncache) so each is downloaded once.

This copies the files the game actually reads — the live terrain bake, the
city stamps it names, the live road bake — into
server/assets/region/ (hard links where the disk allows, so no
second gigabyte), and writes index.json: every file's size and content hash.
A browser compares its cached copy against that hash, so a rebaked file is
fetched again even when its name has not changed, and files that are no
longer published are removed from its storage.

Stale bakes left in the data folder are not published. Run after every
regionforge bake (build_region.py, city_stamps.py, build_roads.py).
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "client/assets/world/region/data"
OUT = ROOT / "server/assets/region"


def live_files():
    """Relative paths (under DATA) of everything the streamers can read."""
    files = set()

    def terrain(meta_rel):
        meta_path = DATA / meta_rel
        meta = json.loads(meta_path.read_text())
        base = meta_path.parent
        files.add(meta_rel)
        tiles = (base / meta["tiles_dir"]).resolve()
        for page in sorted(tiles.glob("*.bin")):
            files.add(str(page.relative_to(DATA.resolve())))
        for rel in meta.get("tile_overrides", {}).values():
            files.add(str((base / rel).resolve().relative_to(DATA.resolve())))

    terrain("meta.json")
    manifest_path = DATA / "roads/manifest.json"
    if manifest_path.exists():
        roads = json.loads(manifest_path.read_text())
        files.add("roads/manifest.json")
        for chunk in roads["chunks"]:
            files.add("roads/" + chunk["file"])
        terrain("roads/" + roads["terrain_dir"] + "/meta.json")
    return sorted(files)


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()[:16]


def place(src, dst):
    if dst.exists() and dst.stat().st_size == src.stat().st_size and dst.stat().st_mtime >= src.stat().st_mtime:
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(dst.name + ".tmp")
    if tmp.exists():
        tmp.unlink()
    try:
        os.link(src, tmp)
    except OSError:
        shutil.copy2(src, tmp)
    os.replace(tmp, dst)


def main():
    if not (DATA / "meta.json").exists():
        sys.exit(f"no country bake at {DATA}")
    rels = live_files()
    previous = {}
    index_path = OUT / "index.json"
    if index_path.exists():
        try:
            previous = json.loads(index_path.read_text()).get("files", {})
        except ValueError:
            pass
    index = {}
    total = 0
    for i, rel in enumerate(rels):
        src = DATA / rel
        dst = OUT / rel
        place(src, dst)
        size = src.stat().st_size
        old = previous.get(rel)
        # Rehash only what may have changed: same size and not newer keeps the hash.
        if old and old.get("size") == size and old.get("mtime") == int(src.stat().st_mtime):
            entry = old
        else:
            entry = {"size": size, "hash": digest(src), "mtime": int(src.stat().st_mtime)}
        index[rel] = entry
        total += size
        if (i + 1) % 500 == 0:
            print(f"[region] {i + 1}/{len(rels)}", flush=True)
    # Anything published before and no longer live is withdrawn.
    removed = 0
    for path in sorted(OUT.rglob("*"), reverse=True):
        rel = str(path.relative_to(OUT))
        if path.is_file() and rel != "index.json" and rel not in index:
            path.unlink()
            removed += 1
        elif path.is_dir() and not any(path.iterdir()):
            path.rmdir()
    version = hashlib.sha256(json.dumps({k: v["hash"] for k, v in index.items()}, sort_keys=True).encode()).hexdigest()[:16]
    OUT.mkdir(parents=True, exist_ok=True)
    tmp = index_path.with_suffix(".tmp")
    tmp.write_text(json.dumps({"format_version": 1, "version": version, "files": index}, separators=(",", ":")))
    os.replace(tmp, index_path)
    print(f"[region] published {len(index)} files, {total / 1e6:.0f} MB, version {version}"
          f" ({removed} withdrawn) -> {OUT}")


if __name__ == "__main__":
    main()
