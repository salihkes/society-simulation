"""Local, baked city terrain fits. The prefab is never stretched or edited.

Original country pages remain immutable. Only affected tiles are written as
versioned overrides, and the runtime uses the same bounded streaming window.
"""
from functools import lru_cache
import hashlib
import json
import math
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def smooth(a, b, value):
    t = np.clip((value - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


class BaseField:
    def __init__(self, meta, output):
        self.meta, self.output = meta, Path(output)
        self.size, self.quads = meta["tile_size"], meta["quads"]

    @lru_cache(maxsize=32)
    def tile(self, tx, tz):
        side = self.quads + 3
        count = side * side * 4
        page_side = self.meta["page_side"]
        path = self.output / self.meta["tiles_dir"] / f"{tx // page_side}_{tz // page_side}.bin"
        offset = ((tz % page_side) * page_side + tx % page_side) * count
        with path.open("rb") as f:
            f.seek(offset)
            raw = f.read(count)
        if len(raw) != count:
            raise ValueError(f"Missing base terrain tile {tx},{tz}")
        return np.frombuffer(raw, "<f4").reshape(side, side)

    def sample(self, x, z):
        from build_region import sample_grid
        shape = x.shape
        x, z = x.ravel(), z.ravel()
        tx, tz = np.floor(x / self.size).astype(int), np.floor(z / self.size).astype(int)
        b = self.meta["tile_bounds"]
        if np.any((tx < b[0]) | (tx >= b[2]) | (tz < b[1]) | (tz >= b[3])):
            raise ValueError("City terrain fit reaches outside baked country coverage")
        result = np.empty(x.shape, np.float32)
        for a, c in np.unique(np.stack([tx, tz], axis=1), axis=0):
            use = (tx == a) & (tz == c)
            result[use] = sample_grid(self.tile(int(a), int(c)),
                (x[use] - a * self.size) * self.quads / self.size + 1,
                (z[use] - c * self.size) * self.quads / self.size + 1)
        return result.reshape(shape)


class CityStamp:
    def __init__(self, config, projection, sea_y, height_scale=.5, offline=True):
        from overlay_mapping import OverlayMapping
        from coastline import Coastline, ensure_coastline
        from build_region import Elevation
        self.config, self.projection, self.sea_y = config, projection, sea_y
        self.height_scale = height_scale
        accepted = json.loads((HERE/config["accepted_overlay"]).read_text())
        self.mapping = OverlayMapping(accepted, projection)
        self.origin, self.rotation = self.mapping.origin, self.mapping.rotation
        self.y_shift = sea_y-config["model_sea_y"]
        self.inner, self.outer = config["inner_radius"], config["outer_radius"]
        if not 0 < self.inner < self.outer:
            raise ValueError("City transition radii must be positive and ordered")
        # The core is exactly the approved picture transform. Only the outer
        # transition returns gradually to the existing country projection.
        axis = np.arange(-self.outer,self.outer+32,32.)
        mx,mz = np.meshgrid(axis,axis)
        world = self.model_to_world(np.stack([mx,mz],axis=-1))
        sx,sz = self.geographic_source(world[...,0],world[...,1])
        source_local = self.world_to_model(sx,sz)
        dx_x,dz_x = np.gradient(source_local[...,0],32,axis=1),np.gradient(source_local[...,0],32,axis=0)
        dx_z,dz_z = np.gradient(source_local[...,1],32,axis=1),np.gradient(source_local[...,1],32,axis=0)
        determinant=dx_x*dz_z-dz_x*dx_z
        self.minimum_jacobian=float(determinant.min())
        if self.minimum_jacobian<=0:
            raise ValueError("Terrain scale transition folds geography; widen the transition")
        path=HERE/config["coastline_file"]
        ensure_coastline(path,config["coastline_bbox"],offline)
        self.coast=Coastline(path,config["coastline_bbox"],projection)
        axis=np.linspace(-self.outer-1100,self.outer+1100,9)
        x,z=np.meshgrid(axis,axis)
        ll=self.mapping.model_lonlat(np.stack([x,z],axis=-1))
        self.dem=Elevation(config["dem_zoom"],ll[...,0],ll[...,1],offline)
        with np.load(HERE/config["ground_file"]) as ground:
            self.ground={k:ground[k].copy() for k in ground.files}

    def weight(self,radius):
        return 1-smooth(self.inner,self.outer,radius)

    def model_to_world(self,model):
        return self.mapping.model_to_world(model)

    def world_to_model(self,x,z):
        return self.mapping.world_to_model(x,z)

    def geographic_source(self,x,z):
        """One inverse transform for geographic elevation, coast and future data."""
        from geography import geographic_source
        return geographic_source(self.mapping,self.inner,self.outer,x,z)

    def apply(self,x,z,base):
        from build_region import sample_grid
        source_x,source_z=self.geographic_source(x,z)
        lon,lat=self.projection.to_lonlat(source_x,source_z)
        geographic_height=self.dem.sample(lon,lat)*self.height_scale+self.sea_y
        distance=self.coast.signed_distance(source_x,source_z)
        model=self.world_to_model(x,z)
        mx,mz=model[...,0],model[...,1]
        ground=self.ground
        fx=(mx-float(ground["x0"]))/float(ground["cell"])
        fz=(mz-float(ground["z0"]))/float(ground["cell"])
        floor=sample_grid(ground["height"],fx,fz)+self.y_shift
        outside=np.hypot(np.maximum(np.maximum(-fx,fx-ground["height"].shape[1]+1),0),
                         np.maximum(np.maximum(-fz,fz-ground["height"].shape[0]+1),0))*float(ground["cell"])
        ground_distance=sample_grid(ground["distance"],fx,fz)+outside
        floor_weight=1-smooth(0,self.config["ground_blend_distance"],ground_distance)
        land=np.maximum(self.sea_y+.6,geographic_height)
        land=land*(1-floor_weight)+floor*floor_weight
        shore=smooth(0,self.config["coast_width"],distance)
        land=(self.sea_y-.6)*(1-shore)+land*shore
        sea=self.sea_y-.6-np.minimum(50,np.maximum(-distance,0)*.3)
        fitted=np.where(distance>0,land,sea)
        influence=self.weight(np.hypot(mx,mz))
        # Unmodified base at the outer edge guarantees exact tile/halo seams.
        original=base.sample(x,z)
        return (original*(1-influence)+fitted*influence).astype("<f4")

    def placement(self):
        yaw=math.atan2(-self.rotation[0,1],self.rotation[0,0])
        return {"id":self.config["id"],"model_scene":self.config["model_scene"],
                "position":[float(self.origin[0]),self.y_shift,float(self.origin[1])],
                "rotation_y":yaw,"model_scale":1.0,
                "model_sea_y":self.config["model_sea_y"],"country_sea_y":self.sea_y,
                "accepted_overlay":self.mapping.accepted,
                "terrain_source_scale_axes":self.mapping.source_scales.tolist(),
                "terrain_source_area_scale":self.mapping.source_area_scale,
                "inner_radius":self.inner,"outer_radius":self.outer,
                "minimum_warp_jacobian":self.minimum_jacobian,
                "load_distance":5000.,"unload_distance":6500.,
                "note":"User-approved overhead overlay. Original model geometry and scale; terrain absorbs geographic scale. Pera road edges are inland, not coast constraints. No point-pair fitting."}


def apply_configured_stamps(config, meta, output, offline=False):
    from build_region import Projection
    output = Path(output)
    base = BaseField(meta, output)
    if config["far_compression"] != meta["projection"]["far_compression"]:
        raise ValueError("Compression changed: rebuild country pages before fitting cities")
    projection = Projection(meta["projection"], meta["projection"]["far_compression"])
    overrides, placements, stamps = {}, [], []
    for relative in config.get("city_stamps", []):
        path = HERE / relative
        city_config = json.loads(path.read_text())
        stamp = CityStamp(city_config, projection, meta["sea_y"], meta["far_height_scale"], offline)
        for other in stamps:
            if np.linalg.norm(stamp.origin-other.origin) < stamp.outer+other.outer:
                raise ValueError("Overlapping city terrain stamps need an explicit blending policy")
        stamps.append(stamp)
        digest = hashlib.sha256(path.read_bytes() + (HERE / city_config["ground_file"]).read_bytes()
                                + meta["tiles_dir"].encode() + Path(__file__).read_bytes()
                                + (HERE/"coastline.py").read_bytes()
                                + (HERE/"overlay_mapping.py").read_bytes()
                                + (HERE/"geography.py").read_bytes()
                                + (HERE/city_config["accepted_overlay"]).read_bytes()
                                + (HERE/city_config["coastline_file"]).read_bytes())
        version = digest.hexdigest()[:16]
        folder = output / "stamps" / version
        folder.mkdir(parents=True, exist_ok=True)
        size, quads = meta["tile_size"], meta["quads"]
        low = np.floor((stamp.origin-stamp.outer-size/quads) / size).astype(int)
        high = np.floor((stamp.origin+stamp.outer+size/quads) / size).astype(int)
        axis = np.arange(-1, quads+2) * size/quads
        count = 0
        for tz in range(low[1], high[1]+1):
            for tx in range(low[0], high[0]+1):
                x, z = np.meshgrid(tx*size+axis, tz*size+axis)
                if np.min(np.hypot(x-stamp.origin[0], z-stamp.origin[1])) > stamp.outer:
                    continue
                destination = folder / f"{tx}_{tz}.f32"
                if not destination.exists():
                    heights = stamp.apply(x, z, base)
                    if not np.isfinite(heights).all():
                        raise ValueError("Non-finite city terrain")
                    temp = destination.with_suffix(".tmp")
                    heights.tofile(temp)
                    temp.replace(destination)
                overrides[f"{tx}_{tz}"] = destination.relative_to(output).as_posix()
                count += 1
        placement = stamp.placement()
        placement["terrain_version"] = version
        placement["override_tiles"] = count
        placements.append(placement)
        destination = ROOT / city_config["placement_output"]
        destination.parent.mkdir(parents=True, exist_ok=True)
        temp = destination.with_suffix(".tmp")
        temp.write_text(json.dumps(placement, indent=2)+"\n")
        temp.replace(destination)
        print(f"City {city_config['id']}: {count} terrain overrides; approved overlay; prefab scale stays 1", flush=True)
    meta["tile_overrides"] = overrides
    meta["cities"] = placements
    base.tile.cache_clear()
    return meta
