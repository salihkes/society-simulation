#!/usr/bin/env python3
"""Bake independently loadable terrain tiles, aligned with workspace_local.

No network at runtime. Missing DEM data is an error, including in offline mode.
Tile coordinates/projection do not depend on coverage bounds. Enlarging bbox
therefore preserves existing positions and reuses already baked tiles.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
import json
import math
from pathlib import Path
import sys
import time
import urllib.request

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def region_file():
    """region.json, the world's coverage and home city; else the tracked example."""
    path = HERE / "region.json"
    if path.exists():
        return path
    print("using region.example.json; copy it to region.json and edit", file=sys.stderr)
    return HERE / "region.example.json"


REGION = json.loads(region_file().read_text())
CITY = ROOT / REGION["home_geo"]
DEFAULT_OUT = ROOT / "client/assets/world/region/data"
CACHE = HERE / "cache"
URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"


def smooth(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


class Projection:
    def __init__(self, city_meta, compression):
        self.meta = city_meta
        self.compression = compression
        self.anchor = np.array(city_meta["anchor_xz"])
        self.lon, self.lat = city_meta["real_anchor_lonlat"]
        self.angle = math.radians(city_meta["bearing_x_deg"])
        self.a = (city_meta["far_real"] - city_meta["far_game"]) / (city_meta["far_game"] - city_meta["d0"]) ** 2
        # Beyond every corner of the old raster, smoothly approach a fixed
        # compression instead of letting its quadratic grow without bound.
        self.join = 22000.0
        self.slope = 1 + 2 * self.a * (self.join - city_meta["d0"])
        self.join_real = self.join + self.a * (self.join - city_meta["d0"]) ** 2

    def real_radius(self, d):
        near = d + self.a * np.maximum(d - self.meta["d0"], 0) ** 2
        t = np.maximum(d - self.join, 0)
        far = self.join_real + self.slope * t + (self.compression - self.slope) * (t - 15000 * (-np.expm1(-t / 15000)))
        return np.where(d <= self.join, near, far)

    def to_lonlat(self, x, z):
        dx, dz = x - self.anchor[0], z - self.anchor[1]
        d = np.hypot(dx, dz)
        k = np.divide(self.real_radius(d), d, out=np.ones_like(d, dtype=float), where=d > 1e-9)
        east = (dx * math.sin(self.angle) + dz * math.cos(self.angle)) * k
        north = (dx * math.cos(self.angle) - dz * math.sin(self.angle)) * k
        return self.lon + east / (111320 * math.cos(math.radians(self.lat))), self.lat + north / 110574

    def from_lonlat(self, lon, lat):
        east = (np.asarray(lon) - self.lon) * (111320 * math.cos(math.radians(self.lat)))
        north = (np.asarray(lat) - self.lat) * 110574
        real_d = np.hypot(east, north)
        lo, hi = np.zeros_like(real_d), real_d.copy()
        for _ in range(48):
            mid = (lo + hi) * 0.5
            below = self.real_radius(mid) < real_d
            lo, hi = np.where(below, mid, lo), np.where(below, hi, mid)
        k = np.divide((lo + hi) * 0.5, real_d, out=np.ones_like(real_d), where=real_d > 1e-9)
        return (self.anchor[0] + (east * math.sin(self.angle) + north * math.cos(self.angle)) * k,
                self.anchor[1] + (east * math.cos(self.angle) - north * math.sin(self.angle)) * k)


def pixel(lon, lat, zoom):
    n = 256 * 2 ** zoom
    return (lon + 180) / 360 * n, (1 - np.arcsinh(np.tan(np.radians(lat))) / math.pi) * 0.5 * n


def sample_grid(a, fx, fz):
    fx = np.clip(fx, 0, a.shape[1] - 1.000001)
    fz = np.clip(fz, 0, a.shape[0] - 1.000001)
    ix, iz = fx.astype(int), fz.astype(int)
    tx, tz = fx - ix, fz - iz
    return ((a[iz, ix] * (1 - tx) + a[iz, ix + 1] * tx) * (1 - tz)
            + (a[iz + 1, ix] * (1 - tx) + a[iz + 1, ix + 1] * tx) * tz)


class Elevation:
    def __init__(self, zoom, lon, lat, offline):
        self.zoom = zoom
        px, py = pixel(lon, lat, zoom)
        self.x0, self.y0 = int(np.floor(px.min() / 256)), int(np.floor(py.min() / 256))
        x1, y1 = int(np.floor(px.max() / 256)), int(np.floor(py.max() / 256))
        coords = [(x, y) for y in range(self.y0, y1 + 1) for x in range(self.x0, x1 + 1)]
        print(f"DEM: {len(coords)} tiles at zoom {zoom}", flush=True)
        self.data = np.empty(((y1 - self.y0 + 1) * 256, (x1 - self.x0 + 1) * 256), np.float32)

        def fetch(coord):
            x, y = coord
            path = CACHE / str(zoom) / f"{x}_{y}.png"
            if not path.exists():
                if offline:
                    raise FileNotFoundError(f"Missing DEM tile {path}; run without --offline")
                path.parent.mkdir(parents=True, exist_ok=True)
                for attempt in range(4):
                    try:
                        with urllib.request.urlopen(URL.format(z=zoom, x=x, y=y), timeout=30) as response:
                            raw = response.read()
                        # Validate before caching so interrupted/invalid downloads cannot poison a bake.
                        Image.open(io.BytesIO(raw)).verify()
                        temp = path.with_suffix(".tmp")
                        temp.write_bytes(raw)
                        temp.replace(path)
                        break
                    except Exception:
                        if attempt == 3:
                            raise
                        time.sleep(attempt + 1)
            rgb = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32)
            return x, y, rgb[..., 0] * 256 + rgb[..., 1] + rgb[..., 2] / 256 - 32768

        with ThreadPoolExecutor(max_workers=8) as pool:
            for i, (x, y, heights) in enumerate(pool.map(fetch, coords)):
                ox, oy = (x - self.x0) * 256, (y - self.y0) * 256
                self.data[oy:oy + 256, ox:ox + 256] = heights
                if (i + 1) % 50 == 0:
                    print(f"  DEM {i + 1}/{len(coords)}", flush=True)

    def sample(self, lon, lat):
        px, py = pixel(lon, lat, self.zoom)
        fx, fy = px - self.x0 * 256, py - self.y0 * 256
        if fx.min() < 0 or fy.min() < 0 or fx.max() >= self.data.shape[1] - 1 or fy.max() >= self.data.shape[0] - 1:
            raise ValueError("DEM coverage does not contain requested sample")
        return sample_grid(self.data, fx, fy)


class Landscape:
    def __init__(self, config, synthetic=False):
        self.config = config
        self.meta = json.loads((CITY / "meta.json").read_text())
        self.projection = Projection(self.meta, config["far_compression"])
        self.rasters = {k: np.fromfile(CITY / r["file"], dtype="<f4").reshape(r["px"], r["px"])
                        for k, r in self.meta["rasters"].items()}
        self.synthetic = synthetic
        self.dem = None

    def city_sample(self, key, x, z):
        r = self.meta["rasters"][key]
        return sample_grid(self.rasters[key], (x - r["x0"]) / r["units_per_px"] - 0.5,
                           (z - r["z0"]) / r["units_per_px"] - 0.5)

    def sample(self, x, z):
        lon, lat = self.projection.to_lonlat(x, z)
        elev = 180 * np.sin(x / 2200) * np.cos(z / 1700) if self.synthetic else self.dem.sample(lon, lat)
        d = np.maximum(abs(x - self.projection.anchor[0]), abs(z - self.projection.anchor[1]))
        vertical = 1 + (self.config["far_height_scale"] - 1) * smooth(15000, 30000, d)
        # Keep water below the sea even where DEM ocean pixels are exactly zero.
        regional = np.where(elev > 0.4, np.maximum(elev * vertical, 0.6), np.minimum(elev * vertical, -4)) + self.meta["sea_y"]
        inner_half = self.meta["rasters"]["inner"]["half"]
        blend = smooth(inner_half * 0.8, inner_half * 0.97, d)
        city = self.city_sample("inner", x, z) * (1 - blend) + self.city_sample("outer", x, z) * blend
        edge = smooth(12000, 14800, d)
        return (city * (1 - edge) + regional * edge).astype("<f4")


def perimeter(bounds, samples=1025):
    x0, z0, x1, z1 = bounds
    t = np.linspace(0, 1, samples)
    return (np.concatenate([x0 + (x1 - x0) * t, x0 + (x1 - x0) * t, np.full_like(t, x0), np.full_like(t, x1)]),
            np.concatenate([np.full_like(t, z0), np.full_like(t, z1), z0 + (z1 - z0) * t, z0 + (z1 - z0) * t]))


def bake(config, output, offline=False, synthetic=False, tile_bounds=None):
    landscape = Landscape(config, synthetic)
    size, quads = config["tile_size"], config["quads"]
    if quads < 8 or quads & (quads - 1) or size <= 0 or config["far_compression"] < 1:
        raise ValueError("quads must be a power of two >= 8, tile_size positive, compression >= 1")
    if tile_bounds is None:
        lon, lat = perimeter(config["bbox_lonlat"])
        x, z = landscape.projection.from_lonlat(lon, lat)
        tile_bounds = [math.floor(x.min() / size), math.floor(z.min() / size), math.ceil(x.max() / size), math.ceil(z.max() / size)]
    x0, z0, x1, z1 = tile_bounds  # max exclusive; IDs remain fixed when this changes
    signature = dict(config, synthetic=synthetic, city=landscape.meta, format_version=1)
    signature.pop("bbox_lonlat", None)
    signature.pop("description", None)
    # City fits patch a few tiles; they must not invalidate the base country.
    signature.pop("city_stamps", None)
    for pointer in ("home_geo", "home_city", "roads_config"):
        signature.pop(pointer, None)
    digest = hashlib.sha256(json.dumps(signature, sort_keys=True).encode())
    for r in landscape.meta["rasters"].values():
        digest.update((CITY / r["file"]).read_bytes())
    fingerprint = digest.hexdigest()[:16]
    # Versioned data keeps an existing bake playable until the new manifest is published.
    tiles_dir = CACHE / "bakes" / fingerprint
    tiles_dir.mkdir(parents=True, exist_ok=True)
    coords = [(x, z) for z in range(z0, z1) for x in range(x0, x1)]
    byte_count = (quads + 3) ** 2 * 4  # one-sample halo for seam-consistent normals
    missing = [(x, z) for x, z in coords if not (tiles_dir / f"{x}_{z}.f32").exists()
               or (tiles_dir / f"{x}_{z}.f32").stat().st_size != byte_count]
    print(f"Region: {len(coords)} tiles, {len(missing)} to bake, {len(coords) * byte_count / 1048576:.1f} MiB", flush=True)
    if missing and not synthetic:
        # Sample the whole world rectangle, including interior: the nonlinear
        # projection can attain a geographic extremum away from an edge.
        xs, zs = np.meshgrid(np.linspace(x0 * size - size, x1 * size + size, 257),
                             np.linspace(z0 * size - size, z1 * size + size, 257))
        lon, lat = landscape.projection.to_lonlat(xs, zs)
        landscape.dem = Elevation(config["dem_zoom"], np.array([lon.min() - .1, lon.max() + .1]),
                                  np.array([lat.min() - .1, lat.max() + .1]), offline)
    axis = np.arange(-1, quads + 2) * (size / quads)
    for i, (tx, tz) in enumerate(missing):
        x, z = np.meshgrid(tx * size + axis, tz * size + axis)
        heights = landscape.sample(x, z)
        if not np.isfinite(heights).all():
            raise ValueError(f"Non-finite height in tile {tx},{tz}")
        path = tiles_dir / f"{tx}_{tz}.f32"
        temp = path.with_suffix(".tmp")
        heights.tofile(temp)
        temp.replace(path)
        if (i + 1) % 250 == 0:
            print(f"  baked {i + 1}/{len(missing)}", flush=True)
    # Fixed 16x16 pages keep tens of thousands of raw tiles out of Godot's
    # filesystem scanner. Runtime seeks directly to one tile in a page.
    page_side = 16
    pages_dir = output / fingerprint
    pages_dir.mkdir(parents=True, exist_ok=True)
    for pz in range(z0 // page_side, (z1 - 1) // page_side + 1):
        for px in range(x0 // page_side, (x1 - 1) // page_side + 1):
            page = bytearray(byte_count * page_side * page_side)
            for iz in range(page_side):
                for ix in range(page_side):
                    tx, tz = px * page_side + ix, pz * page_side + iz
                    path = tiles_dir / f"{tx}_{tz}.f32"
                    if x0 <= tx < x1 and z0 <= tz < z1:
                        raw = path.read_bytes()
                        if len(raw) != byte_count:
                            raise ValueError(f"Invalid tile {path}")
                        offset = (iz * page_side + ix) * byte_count
                        page[offset:offset + byte_count] = raw
            path = pages_dir / f"{px}_{pz}.bin"
            temp = path.with_suffix(".tmp")
            temp.write_bytes(page)
            temp.replace(path)
    meta = dict(format_version=2, page_side=page_side, tile_size=size, quads=quads, tile_bounds=tile_bounds,
                tiles_dir=fingerprint, sea_y=landscape.meta["sea_y"], bbox_lonlat=config["bbox_lonlat"],
                projection=dict(landscape.meta, far_compression=config["far_compression"], join=22000),
                far_height_scale=config["far_height_scale"], synthetic=synthetic,
                source="Synthetic test fixture" if synthetic else "AWS Terrain Tiles (Terrarium; SRTM/other elevation sources)")
    if config.get("city_stamps") and not synthetic:
        from city_stamps import apply_configured_stamps
        meta = apply_configured_stamps(config, meta, output, offline)
    temp = output / "meta.tmp"
    temp.write_text(json.dumps(meta, indent=2) + "\n")
    temp.replace(output / "meta.json")
    # Small overview using the actual baked samples, including on resumed bakes.
    overview = np.empty(((z1 - z0) * 8, (x1 - x0) * 8), np.float32)
    for tx, tz in coords:
        h = np.fromfile(tiles_dir / f"{tx}_{tz}.f32", dtype="<f4").reshape(quads + 3, quads + 3)
        overview[(tz-z0)*8:(tz-z0+1)*8, (tx-x0)*8:(tx-x0+1)*8] = h[1:quads+1:quads//8, 1:quads+1:quads//8]
    h = overview - meta["sea_y"]
    rgb = np.empty(h.shape + (3,), np.float32)
    t = np.clip(h / 1500, 0, 1)
    for c, low, high, water in [(0,.32,.75,.08), (1,.46,.69,.28), (2,.22,.58,.42)]:
        rgb[..., c] = np.where(h > 0, low + (high-low)*t, water)
    dz, dx = np.gradient(overview, size / 8)
    shade = np.clip((1 - dx*.5 + dz*.4) / np.sqrt(1 + dx*dx + dz*dz), .2, 1)
    Image.fromarray((np.clip(rgb * shade[...,None], 0, 1) * 255).astype(np.uint8)).save(output / "overview.png")
    print(f"Published {output / 'meta.json'}", flush=True)
    return meta


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=region_file())
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--stamps-only", action="store_true", help="fit configured cities to an existing bake without rebuilding country pages")
    parser.add_argument("--synthetic", action="store_true", help="test fixtures only, never geographic terrain")
    parser.add_argument("--tile-bounds", nargs=4, type=int, help="small test bake: min-x min-z max-x max-z (exclusive)")
    args = parser.parse_args()
    if args.stamps_only:
        from city_stamps import apply_configured_stamps
        meta = json.loads((args.out / "meta.json").read_text())
        meta = apply_configured_stamps(json.loads(args.config.read_text()), meta, args.out, args.offline)
        temp = args.out / "meta.tmp"
        temp.write_text(json.dumps(meta, indent=2) + "\n")
        temp.replace(args.out / "meta.json")
        return
    bake(json.loads(args.config.read_text()), args.out, args.offline, args.synthetic, args.tile_bounds)


if __name__ == "__main__":
    main()
