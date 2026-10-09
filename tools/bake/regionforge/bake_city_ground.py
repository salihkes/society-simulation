"""Rasterize the city mesh's low ground envelope; never use roofs to lift land.

Input is exported by client/tools/export_region_city_mesh.gd.
The cached binary interchange is an offline tool artifact, not a game asset.
"""
import argparse
import json
from pathlib import Path
import struct

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import distance_transform_edt, binary_closing

HERE = Path(__file__).resolve().parent


def bake(source, destination, config):
    cell = 4
    polygons = []
    with Path(source).open("rb") as f:
        while length := f.read(4):
            header = json.loads(f.read(struct.unpack("<I", length)[0]))
            v = np.frombuffer(f.read(header["vertices"]*12), "<f4").reshape(-1,3)
            indices = np.frombuffer(f.read(header["indices"]*4), "<i4")
            v = v @ np.array(header["basis"]) + header["origin"]
            triangles = v[indices.reshape(-1,3)] if len(indices) else v.reshape(-1,3)
            cross = np.cross(triangles[:,1]-triangles[:,0], triangles[:,2]-triangles[:,0])
            area = np.linalg.norm(cross, axis=1)
            y = triangles[:,:,1]
            # Include both winding conventions: the minimum envelope also
            # captures thin road undersides, which is desirable clearance.
            use = (abs(cross[:,1]) > area*.98) & (area > 4) & (y.min(1) > config["model_sea_y"]+.5) & (y.max(1) < 45)
            for tri in triangles[use]:
                polygons.append((float(tri[:,1].min()), tri[:,[0,2]]))
    # The raster spans the model's own footprint, so a larger city needs no
    # edit here. A 128-unit margin leaves room for the blend past its edge.
    corners = np.concatenate([p for _, p in polygons])
    x0, z0 = np.floor((corners.min(0)-128)/cell)*cell
    x1, z1 = np.ceil((corners.max(0)+128)/cell)*cell
    # Painting higher surfaces first produces a lower envelope where buildings
    # overlap roads/base geometry. Empty spaces stay at the low city floor.
    image = Image.new("F", (int((x1-x0)/cell)+1, int((z1-z0)/cell)+1), 10000)
    draw = ImageDraw.Draw(image)
    for height, polygon in sorted(polygons, key=lambda p: p[0], reverse=True):
        draw.polygon(((polygon-[x0,z0])/cell).ravel().tolist(), fill=height-config["ground_clearance"])
    heights = np.asarray(image).copy()
    covered = heights < 1000
    # Close only small gaps between adjacent road/base triangles. Large empty
    # areas retain geographic relief instead of becoming an AABB-sized pad.
    covered = binary_closing(covered, iterations=3)
    distance = distance_transform_edt(~covered)*cell
    _, nearest = distance_transform_edt(~covered, return_indices=True)
    heights = np.minimum(heights, config["fallback_ground_y"])
    heights = heights[tuple(nearest)]
    # A one-cell minimum filter gives the terrain a margin under quay steps.
    padded = np.pad(heights, 1, mode="edge")
    heights = np.minimum.reduce([padded[z:z+heights.shape[0], x:x+heights.shape[1]] for z in range(3) for x in range(3)])
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(destination, height=heights.astype("<f4"), distance=distance.astype("<f4"), x0=x0, z0=z0, cell=cell)
    print(f"City ground: {len(polygons)} mesh triangles -> {heights.shape} over x {x0:.0f}..{x1:.0f}, z {z0:.0f}..{z1:.0f}; height {heights.min():.2f}..{heights.max():.2f}")


if __name__ == "__main__":
    from build_region import REGION
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--out", type=Path, help="default: the city config's ground_file")
    parser.add_argument("--config", type=Path, default=HERE / REGION["city_stamps"][0])
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    bake(args.source, args.out or HERE / config["ground_file"], config)
