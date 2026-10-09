"""Offline road alignment, constrained grades, and continuous terrain shaping."""
from functools import lru_cache
import numpy as np
from scipy.ndimage import gaussian_filter1d
from scipy.spatial import cKDTree
from city_stamps import BaseField


class ActiveField(BaseField):
    @lru_cache(maxsize=64)
    def tile(self, tx, tz):
        override = self.meta.get('tile_overrides', {}).get(f'{tx}_{tz}')
        if override:
            data = np.fromfile(self.output/override, '<f4')
            return data.reshape(self.quads+3, self.quads+3)
        return super().tile(tx, tz)


def stations(points):
    return np.r_[0, np.cumsum(np.linalg.norm(np.diff(points, axis=0), axis=1))]


def resample(points, step):
    s = stations(points)
    keep = np.r_[True, np.diff(s) > 1e-5]
    points, s = points[keep], s[keep]
    if len(points) < 2:
        raise ValueError('Road has no length')
    axis = np.linspace(0, s[-1], max(2, int(np.ceil(s[-1]/step))+1))
    return np.stack([np.interp(axis, s, points[:, i]) for i in range(points.shape[1])], axis=1)


def unit(v):
    length = np.linalg.norm(v, axis=-1, keepdims=True)
    if np.any(length < 1e-9):
        raise ValueError('Road direction is zero')
    return v/length


def approach(a, direction_a, b, direction_b, step):
    length = np.linalg.norm(b-a)
    handle = length*.35
    t = np.linspace(0, 1, max(8, int(np.ceil(length/step))+1))[:, None]
    return (1-t)**3*a + 3*(1-t)**2*t*(a+direction_a*handle) + 3*(1-t)*t*t*(b-direction_b*handle) + t**3*b


def alignment(source, start, end, step, trim, smoothing=8.0):
    """Source polyline remains authoritative away from editable approaches.

    Ports' outward directions point out of each city. At the destination,
    direction of travel is therefore the negative of its outward direction.
    """
    s = stations(source)
    if s[-1] <= 2*trim:
        raise ValueError('Route too short for configured approaches')
    a = max(1, int(np.searchsorted(s, trim)))
    b = min(len(source)-2, int(np.searchsorted(s, s[-1]-trim)))
    middle = resample(source[a:b+1], step)
    # Remove tiny OSM digitization kinks without moving the approach joins.
    middle[1:-1] = gaussian_filter1d(middle, max(smoothing/step, .1), axis=0, mode='nearest')[1:-1]
    out_a, out_b = unit(np.array(start['outward_xz'])), unit(np.array(end['outward_xz']))
    first = approach(np.array(start['position'])[[0, 2]], out_a, middle[0], unit(middle[1]-middle[0]), step)
    last = approach(middle[-1], unit(middle[-1]-middle[-2]), np.array(end['position'])[[0, 2]], -out_b, step)
    points = resample(np.concatenate([first[:-1], middle, last[1:]]), step)
    # Short straight leads make the mesh seam and endpoint grade exact.
    points[1] = points[0]+out_a*min(step, np.linalg.norm(points[1]-points[0]))
    points[-2] = points[-1]+out_b*min(step, np.linalg.norm(points[-2]-points[-1]))
    return points, stations(first)[-1], stations(last)[-1]


def lower_cones(values, s, grade):
    left = np.maximum.accumulate(values+grade*s)-grade*s
    right = np.maximum.accumulate((values-grade*s)[::-1])[::-1]+grade*s
    return np.maximum(left, right)


def upper_cones(values, s, grade):
    left = np.minimum.accumulate(values-grade*s)+grade*s
    right = np.minimum.accumulate((values+grade*s)[::-1])[::-1]-grade*s
    return np.minimum(left, right)


def profile(points, ground, kinds, start, end, grade, smoothing):
    s = stations(points)
    target = gaussian_filter1d(ground+.8, smoothing/max(np.median(np.diff(s)), .001), mode='nearest')
    lower = np.full(len(s), -np.inf)
    upper = np.full(len(s), np.inf)
    # First-pass bridge clearance is explicit gameplay geometry, not inferred
    # from OSM layer or alleged survey deck elevations.
    lower[kinds == 1] = ground[kinds == 1]+8.0
    pins = {0: start['position'][1], 1: start['position'][1]+start.get('grade', 0)*s[1],
            len(s)-1: end['position'][1], len(s)-2: end['position'][1]+end.get('grade', 0)*(s[-1]-s[-2])}
    for i, height in pins.items():
        lower[i] = upper[i] = height
    floor, ceiling = lower_cones(lower, s, grade), upper_cones(upper, s, grade)
    if np.any(floor > ceiling+1e-6):
        raise ValueError('Endpoint heights/grades and bridge clearance are incompatible with maximum grade')
    heights = upper_cones(np.clip(target, floor, ceiling), s, grade)
    if not np.isfinite(heights).all() or np.max(abs(np.diff(heights)/np.diff(s))) > grade+1e-7:
        raise ValueError('Invalid vertical road profile')
    return heights


class Corridor:
    def __init__(self, rows, cell):
        # Rows: x,y,z,lateral_x,lateral_z,width,station,kind,original_ground.
        self.rows = rows
        self.a = rows[:-1][:, [0, 2]]
        self.delta = rows[1:][:, [0, 2]]-self.a
        self.length2 = np.sum(self.delta**2, axis=1)
        if np.any(self.length2 < 1e-9):
            raise ValueError('Zero-length road segment')
        self.tree = cKDTree(self.a+self.delta*.5)
        self.cell = cell

    def nearest(self, points):
        shape = points.shape[:-1]
        p = np.asarray(points).reshape(-1, 2)
        # Uniformly sampled segments: nearby midpoint candidates include the
        # closest segment; extra candidates handle tight curves/junctions.
        k = min(16, len(self.a))
        _, ids = self.tree.query(p, k=k)
        ids = ids.reshape(len(p), k)
        delta = self.delta[ids]
        t = np.clip(np.sum((p[:, None]-self.a[ids])*delta, axis=-1)/self.length2[ids], 0, 1)
        d2 = np.sum((p[:, None]-self.a[ids]-t[..., None]*delta)**2, axis=-1)
        choice = np.argmin(d2, axis=1)
        row = np.arange(len(p))
        return (ids[row, choice].reshape(shape), t[row, choice].reshape(shape),
                np.sqrt(d2[row, choice]).reshape(shape))

    def stamp(self, x, z, original):
        points = np.stack([x, z], axis=-1)
        ids, t, distance = self.nearest(points)
        a, b = self.rows[ids], self.rows[ids+1]
        deck = a[..., 1]*(1-t)+b[..., 1]*t
        width = a[..., 5]*(1-t)+b[..., 5]*t
        # A full cell diagonal of support prevents the coarse terrain mesh
        # from poking through the narrow road between grid samples.
        support = width/2+self.cell*1.5
        weight = 1-np.clip((distance-support)/64., 0, 1)
        weight = weight*weight*(3-2*weight)
        bridge = (a[..., 7] == 1) | (b[..., 7] == 1)
        # Bridges never fill the valley underneath. At their abutments, allow
        # only cutting: grid interpolation must not leave a lump in the deck.
        # Clearance includes interpolation across the full 80-unit road deck.
        target = np.where(bridge, np.minimum(original, deck-4.8), deck-4.8)
        # Never extend the approach stamp backwards into the authored cities.
        for index, sign in ((0, 1), (-1, -1)):
            endpoint = self.rows[index, [0, 2]]
            direction = self.delta[0 if index == 0 else -1]*sign
            outside = np.sum((points-endpoint)*direction, axis=-1) < 0
            endpoint_near = np.linalg.norm(points-endpoint, axis=-1) < 150
            weight = np.where(outside & endpoint_near, 0., weight)
        return (original*(1-weight)+target*weight).astype('<f4')


def make_rows(points, heights, ground, kinds, start, end, width):
    s = stations(points)
    tangent = unit(np.gradient(points, axis=0))
    tangent[0] = unit(np.array(start['outward_xz']))
    tangent[-1] = -unit(np.array(end['outward_xz']))
    lateral = np.stack([-tangent[:, 1], tangent[:, 0]], axis=1)
    widths = np.full(len(s), width, dtype=float)
    for distance, port in ((s, start), (s[-1]-s, end)):
        t = np.clip(distance/200., 0, 1)
        widths += (port['width']-width)*(1-t*t*(3-2*t))
    return np.column_stack([points[:, 0], heights, points[:, 1], lateral, widths, s, kinds, ground, np.gradient(heights, s)])
