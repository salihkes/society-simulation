"""Bidirectional geographic placement, including the accepted city deformation.

No DEM downloads or terrain regeneration are needed to place vector features.
The forward solve is checked against the same inverse used by city_stamps.
"""
import numpy as np
from build_region import Projection
from overlay_mapping import OverlayMapping


def geographic_source(mapping, inner, outer, x, z):
    model = mapping.world_to_model(x, z)
    target = np.stack([x, z], axis=-1)
    t = np.clip((np.linalg.norm(model, axis=-1) - inner) / (outer - inner), 0, 1)
    weight = 1 - t*t*(3-2*t)
    result = target + (mapping.source_country(model)-target)*weight[..., None]
    return result[..., 0], result[..., 1]


class Geography:
    def __init__(self, meta):
        self.projection = Projection(meta['projection'], meta['projection']['far_compression'])
        self.cities = [(OverlayMapping(c['accepted_overlay'], self.projection),
                        c['inner_radius'], c['outer_radius']) for c in meta.get('cities', [])]
        for i, (a, _, ar) in enumerate(self.cities):
            for b, _, br in self.cities[:i]:
                if np.linalg.norm(a.origin-b.origin) < ar+br:
                    raise ValueError('Overlapping geographic deformations need a blending policy')

    def source(self, points):
        points = np.asarray(points, float)
        result = points.copy()
        for mapping, inner, outer in self.cities:
            x, z = geographic_source(mapping, inner, outer, points[..., 0], points[..., 1])
            result += np.stack([x, z], axis=-1)-points
        return result

    def from_lonlat(self, lonlat):
        ll = np.asarray(lonlat, float)
        shape = ll.shape
        target = np.stack(self.projection.from_lonlat(ll[..., 0], ll[..., 1]), axis=-1).reshape(-1, 2)
        world = target.copy()
        # Newton's method, with numerical Jacobians and bounded steps. Solving
        # the full blend avoids a discontinuity at the edge of the city core.
        for _ in range(25):
            source = self.source(world)
            error = source-target
            active = np.linalg.norm(error, axis=1) > 1e-6
            if not active.any():
                return world.reshape(shape)
            p = world[active]
            base = source[active]
            jx = (self.source(p+[.1, 0])-base)/.1
            jz = (self.source(p+[0, .1])-base)/.1
            jacobian = np.stack([jx, jz], axis=-1)
            if np.any(np.linalg.det(jacobian) <= 0):
                raise ValueError('Folded geographic mapping')
            step = np.linalg.solve(jacobian, error[active, :, None])[..., 0]
            step *= np.minimum(1, 1000/np.maximum(np.linalg.norm(step, axis=1), 1e-9))[:, None]
            world[active] -= step
        raise ValueError('Geographic placement failed to converge')

    def to_lonlat(self, points):
        source = self.source(points)
        return np.stack(self.projection.to_lonlat(source[..., 0], source[..., 1]), axis=-1)
