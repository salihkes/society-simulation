"""Cached OSM highway graph. Only shared node IDs create junctions.

This extracts a prototype corridor, not a navigation service: turn-restriction
relations are not imported. Source way IDs/tags survive in the review output.
"""
import heapq
import json
import os
from pathlib import Path
import urllib.parse
import urllib.request
import numpy as np


def ensure_roads(path, bbox, offline=False):
    path = Path(path)
    if path.exists():
        return json.loads(path.read_text())
    if offline:
        raise FileNotFoundError(f'Missing OSM roads: {path}; run without --offline')
    west, south, east, north = bbox
    query = ('[out:json][timeout:180];way["highway"~"^(motorway|trunk|motorway_link|'
             f'trunk_link|primary|primary_link)$"]({south},{west},{north},{east});out body;>;out skel qt;')
    req = urllib.request.Request('https://overpass-api.de/api/interpreter',
        data=urllib.parse.urlencode({'data': query}).encode(),
        headers={'User-Agent': os.environ.get('GAME_USER_AGENT', 'game-terrain-bake/1.0')})
    with urllib.request.urlopen(req, timeout=210) as response:
        raw = response.read()
    doc = json.loads(raw)
    if doc.get('remark') or not doc.get('elements'):
        raise ValueError(doc.get('remark', 'Empty OSM highway response'))
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix('.tmp')
    temp.write_bytes(raw)
    temp.replace(path)
    return doc


def metres(a, b):
    a, b = np.asarray(a), np.asarray(b)
    d = np.radians(b-a)
    t = np.sin(d[..., 1]/2)**2 + np.cos(np.radians(a[..., 1]))*np.cos(np.radians(b[..., 1]))*np.sin(d[..., 0]/2)**2
    return 6371000*2*np.arcsin(np.sqrt(np.clip(t, 0, 1)))


class RoadGraph:
    def __init__(self, doc):
        if doc.get('remark'):
            raise ValueError(doc['remark'])
        self.nodes = {e['id']: [e['lon'], e['lat']] for e in doc['elements'] if e['type'] == 'node'}
        self.ways, self.edges = {}, {}
        for way in doc['elements']:
            if way['type'] != 'way':
                continue
            tags = way.get('tags', {})
            access = tags.get('motor_vehicle', tags.get('vehicle', tags.get('access', 'yes')))
            if access in ('no', 'private') or tags.get('highway') in ('construction', 'proposed'):
                continue
            self.ways[way['id']] = way
            direction = tags.get('oneway', 'yes' if tags.get('highway') == 'motorway' or tags.get('junction') == 'roundabout' else 'no')
            factor = 1.0 if tags.get('highway', '').startswith('motorway') else 1.12 if tags.get('highway', '').startswith('trunk') else 1.4
            for a, b in zip(way['nodes'][:-1], way['nodes'][1:]):
                if a not in self.nodes or b not in self.nodes:
                    raise ValueError(f'Incomplete OSM way {way["id"]}')
                cost = float(metres(self.nodes[a], self.nodes[b]))*factor
                if direction != '-1':
                    self.edges.setdefault(a, []).append((b, cost, way['id']))
                if direction not in ('yes', '1', 'true'):
                    self.edges.setdefault(b, []).append((a, cost, way['id']))

    def nearest(self, lonlat, max_distance=5000):
        ids = list(self.edges)
        if not ids:
            raise ValueError('OSM highway graph is empty')
        distances = metres(lonlat, np.array([self.nodes[i] for i in ids]))
        index = int(np.argmin(distances))
        if distances[index] > max_distance:
            raise ValueError(f'No highway within {max_distance} real metres of {lonlat}')
        return ids[index]

    def route(self, start, end):
        start, end = self.nearest(start), self.nearest(end)
        queue, costs, previous = [(0., start)], {start: 0.}, {}
        while queue:
            cost, node = heapq.heappop(queue)
            if cost != costs[node]:
                continue
            if node == end:
                break
            for other, weight, way in self.edges.get(node, []):
                candidate = cost+weight
                if candidate < costs.get(other, float('inf')):
                    costs[other] = candidate
                    previous[other] = (node, way)
                    heapq.heappush(queue, (candidate, other))
        if end not in costs:
            raise ValueError('No connected highway route; expand source coverage or change gateway nodes')
        nodes, ways = [end], []
        while nodes[-1] != start:
            node, way = previous[nodes[-1]]
            nodes.append(node)
            ways.append(way)
        nodes.reverse()
        ways.reverse()
        if len(nodes) < 2:
            raise ValueError('Route gateways resolve to the same node')
        return {'lonlat': [self.nodes[i] for i in nodes], 'nodes': nodes, 'ways': ways,
                'tags': [self.ways[i].get('tags', {}) for i in ways]}
