"""Run with: python -m unittest discover -s tools/bake/regionforge -v"""
import json
from pathlib import Path
import tempfile
import unittest

import numpy as np

from build_region import CITY, REGION, Landscape, Projection, bake, Elevation


class RegionTests(unittest.TestCase):
    def setUp(self):
        if not (CITY / "meta.json").exists():
            self.skipTest(f"no home city terrain at {CITY}")
        self.config = dict(REGION)
        self.land = Landscape(self.config, synthetic=True)

    def test_projection_roundtrip_and_monotonic_distances(self):
        projection = self.land.projection
        lon = np.array([19.1, 22.943, 28.98, 29.4, 36, 44])
        lat = np.array([43.5, 40.6283, 41.01, 38.5, 36, 33])
        x, z = projection.from_lonlat(lon, lat)
        actual_lon, actual_lat = projection.to_lonlat(x, z)
        np.testing.assert_allclose(actual_lon, lon, atol=1e-8)
        np.testing.assert_allclose(actual_lat, lat, atol=1e-8)
        for compression in [1, 4, 12]:
            p = Projection(self.land.meta, compression)
            self.assertTrue(np.all(np.diff(p.real_radius(np.linspace(0, 500000, 10000))) > 0))

    def test_tiles_share_edges_and_normal_halo(self):
        step = self.config["tile_size"] / self.config["quads"]
        axis = np.arange(-1, self.config["quads"] + 2) * step
        for tx, tz in [(-1, -1), (0, 0), (29, -18)]:
            x, z = np.meshgrid(tx * 1024 + axis, tz * 1024 + axis)
            a = self.land.sample(x, z)
            b = self.land.sample(x + 1024, z)
            c = self.land.sample(x, z + 1024)
            np.testing.assert_array_equal(a[:, -3:], b[:, :3])
            np.testing.assert_array_equal(a[-3:, :], c[:3, :])

    def test_city_heights_preserved(self):
        x, z = np.meshgrid(np.arange(-480, 777, 16), np.arange(-896, 561, 16))
        np.testing.assert_allclose(self.land.sample(x, z), self.land.city_sample("inner", x, z), atol=1e-5)

    def test_bake_resume_extension_and_page_addressing(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            first = bake(self.config, out, synthetic=True, tile_bounds=[-1, -1, 1, 1])
            page = out / first["tiles_dir"] / "-1_-1.bin"
            tile_bytes = (self.config["quads"] + 3) ** 2 * 4
            offset = 255 * tile_bytes  # tile (-1,-1) in page (-1,-1)
            original = page.read_bytes()[offset:offset + tile_bytes]
            second = bake(self.config, out, synthetic=True, tile_bounds=[-2, -2, 2, 2])
            self.assertEqual(first["tiles_dir"], second["tiles_dir"])
            self.assertEqual(page.read_bytes()[offset:offset + tile_bytes], original)
            self.assertEqual(json.loads((out / "meta.json").read_text())["tile_bounds"], [-2, -2, 2, 2])

    def test_offline_missing_dem_fails_instead_of_flat_land(self):
        with self.assertRaises(FileNotFoundError):
            Elevation(0, np.array([0., 1.]), np.array([0., 1.]), offline=True)


if __name__ == "__main__":
    unittest.main()
