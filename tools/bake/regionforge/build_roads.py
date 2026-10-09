#!/usr/bin/env python3
"""Bake a reviewable intercity road corridor and an isolated terrain manifest.

The accepted country bake and both source city models are never overwritten.
Run build_region.py first. Missing source data fails rather than inventing a
straight geographic route. Runtime needs no network or Python dependencies.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import numpy as np
from scipy.spatial import cKDTree
from build_region import HERE, ROOT, DEFAULT_OUT, REGION
from geography import Geography
from osm_roads import RoadGraph, ensure_roads, metres
from road_geometry import ActiveField, Corridor, alignment, profile, make_rows, stations, unit


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value, indent=2)+'\n')
    temp.replace(path)


def resolve_port(port, meta):
    result = dict(port)
    if port['city'] == REGION['home_city']:
        return result
    city = next(c for c in meta['cities'] if c['id'] == port['city'])
    angle = city['rotation_y']
    rotation = np.array([[np.cos(angle), -np.sin(angle)], [np.sin(angle), np.cos(angle)]])
    p = np.array(port['position'], float)
    p[[0, 2]] = p[[0, 2]]@rotation+np.array(city['position'])[[0, 2]]
    p[1] += city['position'][1]
    result['position'] = p.tolist()
    result['outward_xz'] = (unit(np.array(port['outward_xz']))@rotation).tolist()
    return result


def build(config_path, output, offline=False):
    config = json.loads(config_path.read_text())
    meta_path = DEFAULT_OUT/'meta.json'
    meta = json.loads(meta_path.read_text())
    geographic = Geography(meta)
    field = ActiveField(meta, DEFAULT_OUT)
    ports = json.loads((HERE/config['connections']).read_text())['ports']
    start, end = [resolve_port(next(p for p in ports if p['id'] == key), meta) for key in config['ports']]
    if config['sample_step'] <= 0 or config['width'] <= 0 or config['max_grade'] <= 0:
        raise ValueError('Road spacing, width and maximum grade must be positive')
    source_path = HERE/config['osm_cache']
    graph = RoadGraph(ensure_roads(source_path, config['source_bbox'], offline))
    route = graph.route(*config['gateways_lonlat'])
    source = geographic.from_lonlat(route['lonlat'])
    points, approach_a, approach_b = alignment(source, start, end, config['sample_step'], config['trim_route_ends'], config.get('alignment_smoothing', 8.0))
    s = stations(points)
    # Retain source tags; do not treat geometric road crossings as junctions.
    nearest = cKDTree((source[:-1]+source[1:])*.5)
    _, ids = nearest.query(points)
    source_kinds = np.array([1 if t.get('bridge', 'no') not in ('no', 'false', '0') else
                            2 if t.get('tunnel', 'no') not in ('no', 'false', '0') else 0 for t in route['tags']])
    kinds = source_kinds[ids]
    kinds[(s < approach_a) | (s > s[-1]-approach_b)] = 0
    ground = field.sample(points[:, 0], points[:, 1])
    # A real road can cross a water pixel in the coarse first-pass DEM even
    # without a source bridge tag. Keep these generated water crossings out
    # of the terrain stamp; report them separately for review.
    water_bridge = (ground < meta['sea_y']+.2) & (kinds == 0)
    water_bridge[:3] = water_bridge[-3:] = False
    kinds[water_bridge] = 1
    heights = profile(points, ground, kinds, start, end, config['max_grade'], config['profile_smoothing'])
    rows = make_rows(points, heights, ground, kinds, start, end, config['width'])
    digest = hashlib.sha256(config_path.read_bytes()+meta_path.read_bytes()+source_path.read_bytes()
        +(HERE/config['connections']).read_bytes())
    for module in ('build_roads.py', 'road_geometry.py', 'osm_roads.py', 'geography.py', 'overlay_mapping.py', 'build_region.py'):
        digest.update((HERE/module).read_bytes())
    version = digest.hexdigest()[:16]
    folder = output/version
    folder.mkdir(parents=True, exist_ok=True)
    terrain_dir = folder/'terrain'
    terrain_dir.mkdir(exist_ok=True)
    print(f'Road: {len(points)} samples, {s[-1]:.0f} city units; source {len(set(route["ways"]))} OSM ways', flush=True)
    # Mesh chunks share their boundary rows bit-for-bit, including global UV
    # distance and normals. Their coordinates are stored relative to origin.
    chunks, spatial = [], {}
    breaks = np.unique(np.r_[0, np.searchsorted(s, np.arange(config['chunk_length'], s[-1], config['chunk_length'])), len(s)-1])
    for a, b in zip(breaks[:-1], breaks[1:]):
        data = rows[a:b+1].copy()
        origin = [float(data[0, 0]), 0., float(data[0, 2])]
        data[:, 0] -= origin[0]
        data[:, 2] -= origin[2]
        path = folder/f'chunk_{len(chunks)}.bin'
        data.astype('<f4').tofile(path)
        low = points[a:b+1].min(0)-max(config['width'], start['width'], end['width'])
        high = points[a:b+1].max(0)+max(config['width'], start['width'], end['width'])
        record = {'file': path.relative_to(output).as_posix(), 'origin': origin,
                  'bounds': [*low.tolist(), *high.tolist()], 'rows': len(data), 'station': [float(s[a]), float(s[b])]}
        index = len(chunks)
        chunks.append(record)
        for tz in range(int(np.floor(low[1]/1024)), int(np.floor(high[1]/1024))+1):
            for tx in range(int(np.floor(low[0]/1024)), int(np.floor(high[0]/1024))+1):
                spatial.setdefault(f'{tx}_{tz}', []).append(index)
    terrain = dict(meta)
    terrain['tiles_dir'] = os.path.relpath(DEFAULT_OUT/meta['tiles_dir'], terrain_dir)
    terrain['tile_overrides'] = {k: os.path.relpath(DEFAULT_OUT/v, terrain_dir) for k, v in meta.get('tile_overrides', {}).items()}
    corridor = Corridor(rows, meta['tile_size']/meta['quads'])
    size, quads = meta['tile_size'], meta['quads']
    reach = max(config['width'], start['width'], end['width'])/2+size/quads*1.5+64+size/quads
    tiles = set()
    for p in points:
        low, high = np.floor((p-reach)/size).astype(int), np.floor((p+reach)/size).astype(int)
        for z in range(low[1], high[1]+1):
            for x in range(low[0], high[0]+1):
                tiles.add((x, z))
    axis = np.arange(-1, quads+2)*size/quads
    road_tiles = []
    for index, (tx, tz) in enumerate(sorted(tiles)):
        x, z = np.meshgrid(tx*size+axis, tz*size+axis)
        old = field.sample(x, z)
        new = corridor.stamp(x, z, old)
        if not np.isfinite(new).all():
            raise ValueError('Non-finite road terrain')
        if not np.array_equal(old, new):
            path = terrain_dir/f'{tx}_{tz}.f32'
            new.tofile(path)
            terrain['tile_overrides'][f'{tx}_{tz}'] = path.name
            road_tiles.append(f'{tx}_{tz}')
        if index % 100 == 0:
            print(f'  Ground shaping {index+1}/{len(tiles)} tiles', flush=True)
    terrain['road_preview_version'] = version
    terrain['road_tiles'] = road_tiles
    write_json(terrain_dir/'meta.json', terrain)
    samples = rows[::max(1, int(256/config['sample_step']))]
    review = {
        'id': config['id'], 'version': version, 'source_real_km': float(metres(np.array(route['lonlat'][:-1]), np.array(route['lonlat'][1:])).sum()/1000),
        'length_city_units': float(s[-1]), 'max_grade': float(np.max(abs(np.diff(heights)/np.diff(s)))),
        'chunks': len(chunks), 'terrain_override_tiles': len(road_tiles), 'ports': [start, end],
        'source_way_count': len(set(route['ways'])),
        'source_bridge_ways': sorted({w for w, k in zip(route['ways'], source_kinds) if k == 1}),
        'source_tunnel_ways': sorted({w for w, k in zip(route['ways'], source_kinds) if k == 2}),
        'generated_water_bridge_samples': int(water_bridge.sum()),
        'tunnel_policy': 'Open cuttings for this first terrain/road proof; enclosed tunnels and portals are not implemented.',
        'routing_limit': 'One source travel direction; no turn restriction relations or traffic lane graph. A fictional two-way deck is generated along that corridor.',
        'source_attribution': 'OpenStreetMap contributors, ODbL: https://www.openstreetmap.org/copyright',
        'source_timestamp': graph_timestamp(source_path),
        'provisional': True}
    write_json(folder/'review.json', review)
    write_json(folder/'source_route.json', route)
    rows.astype('<f4').tofile(folder/'alignment.bin')
    # Sparse inspection stations are tiny and avoid loading the full road just
    # to teleport or inspect it. Full geometry is loaded one chunk at a time.
    manifest = {'format_version': 1, 'id': config['id'], 'version': version, 'row_stride': 10,
        'terrain_dir': terrain_dir.relative_to(output).as_posix(), 'chunks': chunks, 'spatial_index': spatial,
        'ports': [start, end], 'inspection_stations': samples[:, :3].tolist(),
        'review_file': (folder/'review.json').relative_to(output).as_posix(), 'length': float(s[-1]),
        'terrain_signature': hashlib.sha256(meta_path.read_bytes()).hexdigest()}
    write_json(output/'manifest.json', manifest)  # publish only after all data exists
    write_json(ROOT/'output/road-prototype/review.json', review)
    print(json.dumps({k: review[k] for k in ('length_city_units', 'chunks', 'terrain_override_tiles', 'max_grade')}, indent=2))
    return manifest


def graph_timestamp(path):
    return json.loads(path.read_text()).get('osm3s', {}).get('timestamp_osm_base', 'unknown')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=HERE/REGION['roads_config'])
    parser.add_argument('--out', type=Path, default=DEFAULT_OUT/'roads')
    parser.add_argument('--offline', action='store_true')
    args = parser.parse_args()
    build(args.config, args.out, args.offline)
