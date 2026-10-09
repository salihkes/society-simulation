"""Geographic land/water classification from directed OSM coastline linework."""
import json
import os
from pathlib import Path

import numpy as np
from scipy.spatial import cKDTree
import shapely
from shapely.geometry import LineString, Polygon, box
from shapely.ops import polygonize, unary_union


def ensure_coastline(path, bounds, offline):
    path = Path(path)
    if path.exists():
        return
    if offline:
        raise FileNotFoundError(f"Missing coastline {path}; run without --offline")
    import urllib.request
    import urllib.parse
    west, south, east, north = bounds
    query = f'[out:json][timeout:90];way["natural"="coastline"]({south},{west},{north},{east});out geom;'
    request = urllib.request.Request('https://overpass-api.de/api/interpreter',
        data=urllib.parse.urlencode({'data': query}).encode(),
        headers={'User-Agent': os.environ.get('GAME_USER_AGENT', 'game-terrain-bake/1.0')})
    with urllib.request.urlopen(request, timeout=100) as response:
        raw = response.read()
    if not json.loads(raw).get('elements'):
        raise ValueError('Coastline download is empty')
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix('.tmp')
    temp.write_bytes(raw)
    temp.replace(path)


class Coastline:
    def __init__(self, path, bounds, projection):
        ways = json.loads(Path(path).read_text())["elements"]
        clip = box(*bounds)
        lines, segments = [], []
        for way in ways:
            coords = np.array([[p["lon"], p["lat"]] for p in way.get("geometry", [])])
            if len(coords) < 2:
                continue
            lines.append(LineString(coords).intersection(clip))
            segments.extend(zip(coords[:-1], coords[1:]))
        geo_segments = np.array(segments)
        units = np.array([84000, 110574])
        a, b = geo_segments[:, 0]*units, geo_segments[:, 1]*units
        # Densify for robust nearest-segment selection even on long way edges.
        dense, owners = [], []
        for i, (start, end) in enumerate(zip(a, b)):
            n = max(1, int(np.ceil(np.linalg.norm(end-start)/20)))
            dense.extend(start + ((np.arange(n)+.5)/n)[:,None]*(end-start))
            owners.extend([i]*n)
        nearest = cKDTree(dense)
        owners = np.array(owners)
        network = unary_union([*lines, clip.boundary])
        lands = []
        for polygon in polygonize(network):
            point = np.array(polygon.representative_point().coords[0])*units
            _, candidates = nearest.query(point, k=8)
            candidate = owners[candidates]
            delta = b[candidate]-a[candidate]
            t = np.clip(np.sum((point-a[candidate])*delta, axis=1)/np.maximum(np.sum(delta*delta, axis=1),1e-12),0,1)
            j = np.argmin(np.sum((a[candidate]+t[:,None]*delta-point)**2,axis=1))
            d, v = delta[j], point-a[candidate[j]]
            if d[0]*v[1]-d[1]*v[0] > 0:  # OSM: land is left of directed coast.
                lands.append(polygon)
        if not lands:
            raise ValueError("Coastline does not form any land polygons")
        def project_ring(ring):
            ll = np.array(ring.coords)
            return np.stack(projection.from_lonlat(ll[:,0], ll[:,1]),axis=1)
        self.land = unary_union([Polygon(project_ring(p.exterior), [project_ring(r) for r in p.interiors]) for p in lands])
        shapely.prepare(self.land)
        # Project real coast segments, excluding artificial clipping-box edges.
        x,z = projection.from_lonlat(geo_segments[...,0],geo_segments[...,1])
        self.a = np.stack([x[:,0],z[:,0]],axis=1)
        self.delta = np.stack([x[:,1]-x[:,0],z[:,1]-z[:,0]],axis=1)
        self.length2 = np.maximum(np.sum(self.delta**2,axis=1),1e-12)
        dense, owners = [], []
        for i,(start,delta) in enumerate(zip(self.a,self.delta)):
            n=max(1,int(np.ceil(np.linalg.norm(delta)/8)))
            dense.extend(start+((np.arange(n)+.5)/n)[:,None]*delta)
            owners.extend([i]*n)
        self.nearest=cKDTree(dense)
        self.owners=np.array(owners)

    def signed_distance(self,x,z):
        shape=x.shape
        points=np.stack([x.ravel(),z.ravel()],axis=1)
        _, candidates=self.nearest.query(points,k=6)
        indices=self.owners[candidates]
        a,d=self.a[indices],self.delta[indices]
        v=points[:,None,:]-a
        t=np.clip(np.sum(v*d,axis=2)/self.length2[indices],0,1)
        distance=np.sqrt(np.min(np.sum((v-t[...,None]*d)**2,axis=2),axis=1))
        land=shapely.contains_xy(self.land,points[:,0],points[:,1])
        return (distance*np.where(land,1,-1)).reshape(shape)
