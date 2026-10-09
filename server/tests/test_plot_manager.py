import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT))
spec = importlib.util.spec_from_file_location('plots_under_test', ROOT / 'world' / 'plots.py')
pm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pm)

# An L shape: a 40x40 square missing its +x/+z quarter.
L_SHAPE = [[0, 0], [40, 0], [40, 20], [20, 20], [20, 40], [0, 40]]


def geom(points=L_SHAPE, floor=1.0, ceiling=51.0):
    return {"points": [[float(x), float(z)] for x, z in points], "floor": floor, "ceiling": ceiling}


class PointTests(unittest.TestCase):
    def test_point_in_polygon(self):
        self.assertTrue(pm.point_in_polygon(10, 10, L_SHAPE))
        self.assertFalse(pm.point_in_polygon(30, 30, L_SHAPE))   # the notch
        self.assertTrue(pm.point_in_polygon(0, 10, L_SHAPE))     # on the edge
        self.assertFalse(pm.point_in_polygon(-1, 10, L_SHAPE))
        self.assertFalse(pm.point_in_polygon(1, 1, [[0, 0], [1, 0]]))

    def test_area_and_centroid(self):
        self.assertAlmostEqual(pm.polygon_area(L_SHAPE), 1200.0)
        cx, cz = pm.polygon_centroid([[0, 0], [10, 0], [10, 10], [0, 10]])
        self.assertEqual((cx, cz), (5.0, 5.0))

    def test_height(self):
        g = geom()
        self.assertTrue(pm.is_point_in_plot((10, 30, 10), g))       # floating is fine
        self.assertFalse(pm.is_point_in_plot((10, 60, 10), g))      # above the ceiling
        self.assertFalse(pm.is_point_in_plot((10, -5, 10), g))      # below the floor


class PlacementTests(unittest.TestCase):
    def setUp(self):
        self.config = {
            "house": {"plot_id": "house", "owner": "owner1", "name": "Owner's House"},
            "shed": {"plot_id": "shed", "owner": "", "name": "shed"},
        }
        self.geometry = {"house": geom(), "shed": geom([[100, 100], [110, 100], [110, 110], [100, 110]], 0, 8)}

    def test_footprint_from_message(self):
        pts = pm.footprint_from_message({"footprint": [[1, 2, 3], [4, 5, 6]]})
        self.assertEqual(pts, [(1.0, 2.0, 3.0), (4.0, 5.0, 6.0)])
        self.assertEqual(pm.footprint_from_message({"local": {"x": 1, "y": 2, "z": 3}}), [(1.0, 2.0, 3.0)])
        # Legacy clients send a global position in metres: scaled to workspace units.
        self.assertEqual(pm.footprint_from_message({"position": {"x": 2, "y": 1, "z": 2}}), [(10.0, 5.0, 10.0)])
        self.assertEqual(pm.footprint_from_message({}), [])

    def test_owner_may_place_inside(self):
        ok, pid, reason = pm.can_user_place_object("Owner1", [(10, 2, 10), (12, 4, 12)], self.config, self.geometry)
        self.assertTrue(ok, reason)
        self.assertEqual(pid, "house")

    def test_corner_poking_out_is_refused(self):
        ok, pid, reason = pm.can_user_place_object("owner1", [(10, 2, 10), (22, 2, 22)], self.config, self.geometry, "house")
        self.assertFalse(ok)
        self.assertEqual(pid, "house")
        self.assertIn("stick out", reason)

    def test_other_users_plot_and_unowned(self):
        ok, pid, reason = pm.can_user_place_object("tester", [(10, 2, 10)], self.config, self.geometry)
        self.assertFalse(ok)
        self.assertIn("owner1", reason)
        ok, pid, reason = pm.can_user_place_object("owner1", [(105, 2, 105)], self.config, self.geometry)
        self.assertFalse(ok)
        self.assertIn("no owner", reason)

    def test_outside_every_plot(self):
        ok, pid, reason = pm.can_user_place_object("owner1", [(-10, 2, -10)], self.config, self.geometry)
        self.assertFalse(ok)
        self.assertIsNone(pid)

    def test_claimed_plot_must_contain_the_footprint(self):
        # Claiming "house" for a point in the shed fails on the polygon, not on the owner.
        ok, pid, reason = pm.can_user_place_object("owner1", [(105, 2, 105)], self.config, self.geometry, "house")
        self.assertFalse(ok)
        self.assertEqual(pid, "house")

    def test_plot_center_and_description(self):
        c = pm.plot_center("house", self.geometry)
        self.assertAlmostEqual(c["x"], 20.0 / pm.WORLD_SCALE)
        self.assertAlmostEqual(c["y"], 1.0 / pm.WORLD_SCALE + 1.0)
        self.geometry["house"]["world_pos"] = [3.0, 0.5, 4.0]
        self.assertEqual(pm.plot_center("house", self.geometry), {"x": 3.0, "y": 1.5, "z": 4.0})
        self.assertIsNone(pm.plot_center("nope", self.geometry))
        text = pm.describe_plot("house", self.config, self.geometry, 3)
        self.assertIn("Owner's House", text)
        self.assertIn("6-sided", text)
        self.assertIn("3 objects", text)


class WorldReportTests(unittest.TestCase):
    def test_apply_world_plots(self):
        config = {"house": {"plot_id": "house", "owner": "owner1", "name": "Owner's House",
                            "legacy_boundaries": {"min_x": 0, "max_x": 1, "min_y": 0, "max_y": 1, "min_z": 0, "max_z": 1}}}
        geometry = {"house": geom([[0, 0], [1, 0], [1, 1], [0, 1]], 0, 1)}
        places = [
            {"id": "Sakura", "kind": "district"},
            {"id": "plot:house", "kind": "plot", "plot": "house", "points": L_SHAPE, "floor": 1, "ceiling": 51,
             "world_pos": [4.0, 0.2, 4.0]},
            {"id": "plot:garden", "kind": "plot", "plot": "garden", "points": [[50, 50], [60, 50], [60, 60], [50, 60]],
             "floor": 0, "ceiling": 20},
            {"id": "plot:bad", "kind": "plot", "plot": "bad", "points": [[0, 0]], "floor": 0, "ceiling": 1},
        ]
        cfg_changed, geo_changed = pm.apply_world_plots(places, config, geometry)
        self.assertTrue(cfg_changed and geo_changed)
        self.assertEqual(set(geometry), {"house", "garden"})
        self.assertEqual(geometry["house"]["points"][2], [40.0, 20.0])
        self.assertEqual(geometry["house"]["world_pos"], [4.0, 0.2, 4.0])
        self.assertEqual(config["garden"], {"plot_id": "garden", "owner": "", "name": "garden"})
        self.assertNotIn("legacy_boundaries", config["house"])
        self.assertEqual(config["house"]["owner"], "owner1")
        # The same report again changes nothing.
        self.assertEqual(pm.apply_world_plots(places, config, geometry), (False, False))
        # A report without plots is ignored (the world may not have loaded them).
        self.assertEqual(pm.apply_world_plots([{"id": "x", "kind": "district"}], config, geometry), (False, False))
        self.assertEqual(set(geometry), {"house", "garden"})

    def test_files_round_trip_and_legacy_migration(self):
        with tempfile.TemporaryDirectory() as d:
            cfg_path = os.path.join(d, "plots.json")
            geo_path = os.path.join(d, "plot_geometry.json")
            with open(cfg_path, "w") as f:
                json.dump({"plots": [
                    {"plot_id": "plot_1", "owner": "owner1", "name": "Owner's Plot",
                     "boundaries": {"min_x": -50, "max_x": -30, "min_y": 0, "max_y": 50, "min_z": -50, "max_z": -30}},
                    {"plot_id": "", "owner": "ghost"},
                ]}, f)
            config = pm.load_plots_config(cfg_path)
            self.assertEqual(list(config), ["plot_1"])
            geometry = pm.load_plot_geometry(config, geo_path)
            self.assertEqual(geometry["plot_1"]["source"], "legacy")
            self.assertTrue(pm.is_point_in_plot((-40, 10, -40), geometry["plot_1"]))
            ok, pid, _ = pm.can_user_place_object("owner1", [(-40, 10, -40)], config, geometry)
            self.assertTrue(ok and pid == "plot_1")
            # Saving drops the boundaries; geometry persists on its own.
            self.assertTrue(pm.save_plots_config(config, cfg_path))
            with open(cfg_path) as f:
                saved = json.load(f)
            self.assertEqual(saved["plots"], [{"plot_id": "plot_1", "owner": "owner1", "name": "Owner's Plot"}])
            self.assertTrue(pm.save_plot_geometry(geometry, geo_path))
            again = pm.load_plot_geometry({}, geo_path)
            self.assertEqual(again["plot_1"]["points"], geometry["plot_1"]["points"])
            self.assertEqual(pm.get_plot_info_for_client(config), [{"plot_id": "plot_1", "owner": "owner1", "name": "Owner's Plot"}])
            self.assertEqual(pm.get_user_plots("OWNER1", config)[0][0], "plot_1")
            self.assertEqual(pm.get_user_plot("nobody", config), (None, None))

    def test_default_config_is_created(self):
        with tempfile.TemporaryDirectory() as d:
            cfg_path = os.path.join(d, "plots.json")
            config = pm.load_plots_config(cfg_path)
            self.assertIn("plot_1", config)
            self.assertTrue(os.path.exists(cfg_path))


if __name__ == "__main__":
    unittest.main()
