#!/usr/bin/env python
"""Plots: where players may build, who owns each, and whether a placement fits; coordinates are workspace units."""

import json
import os

from core import identity
from core.constants import PLOTS_CONFIG_FILE, PLOTS_DATA_DIR, PLOT_GEOMETRY_FILE

WORLD_SCALE = 5.0  # workspace units per metre


def _config_entry(plot_id, raw):
    """A plots.json entry normalised to {"plot_id", "owner", "name"}."""
    return {
        "plot_id": plot_id,
        "owner": str(raw.get("owner", "") or ""),
        "name": str(raw.get("name", "") or plot_id.replace("_", " ")),
    }


def load_plots_config(path=None):
    """{plot_id: {"plot_id", "owner", "name"}}, writing defaults when missing; a "boundaries" box becomes legacy_boundaries."""
    path = path or PLOTS_CONFIG_FILE
    if not os.path.exists(path):
        default_config = {"plots": identity.get("default_plots")}
        try:
            with open(path, "w") as f:
                json.dump(default_config, f, indent=2)
            print(f"Created default plots configuration: {path}")
        except Exception as e:
            print(f"Error creating plots config: {e}")
            return {}
    try:
        with open(path, "r") as f:
            config = json.load(f)
    except Exception as e:
        print(f"Error loading plots config: {e}")
        return {}
    plots = {}
    for raw in config.get("plots", []):
        pid = str(raw.get("plot_id", "") or "").strip()
        if not pid:
            continue
        entry = _config_entry(pid, raw)
        if isinstance(raw.get("boundaries"), dict):
            entry["legacy_boundaries"] = raw["boundaries"]
        plots[pid] = entry
    return plots


def save_plots_config(plots_config, path=None):
    """Write plots.json atomically; False on failure."""
    path = path or PLOTS_CONFIG_FILE
    data = {"plots": [
        {"plot_id": pid, "owner": p.get("owner", ""), "name": p.get("name", pid)}
        for pid, p in sorted(plots_config.items())
    ]}
    try:
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, path)
        return True
    except Exception as e:
        print(f"Error saving plots config: {e}")
        return False


def get_user_plots(username, plots_config):
    """[(plot_id, data)] owned by an account, in id order."""
    u = (username or "").lower()
    return [(pid, p) for pid, p in sorted(plots_config.items())
            if p.get("owner", "").lower() == u and u != ""]


def get_user_plot(username, plots_config):
    """The first plot owned by a user: (plot_id, data) or (None, None)."""
    owned = get_user_plots(username, plots_config)
    return owned[0] if owned else (None, None)


def get_plot_info_for_client(plots_config):
    """What clients need: ownership only. They have the polygons in the scene."""
    return [{"plot_id": pid, "owner": p.get("owner", ""), "name": p.get("name", pid)}
            for pid, p in sorted(plots_config.items())]


def _legacy_polygon(b):
    """A rectangle geometry from a min/max boundaries box, or None if it is malformed."""
    try:
        return {
            "points": [[float(b["min_x"]), float(b["min_z"])],
                       [float(b["max_x"]), float(b["min_z"])],
                       [float(b["max_x"]), float(b["max_z"])],
                       [float(b["min_x"]), float(b["max_z"])]],
            "floor": float(b.get("min_y", 0.0)),
            "ceiling": float(b.get("max_y", 50.0)),
            "source": "legacy",
        }
    except (KeyError, TypeError, ValueError):
        return None


def _read_geometry_file(path):
    """The raw geometry file, or {} when it does not exist."""
    if not os.path.exists(path):
        return {}
    with open(path, "r") as f:
        return json.load(f)


def load_plot_geometry(plots_config=None, path=None):
    """{plot_id: {"points": [[x, z], ...], "floor", "ceiling", "world_pos"?}}."""
    path = path or PLOT_GEOMETRY_FILE
    geometry = {}
    try:
        for pid, g in _read_geometry_file(path).items():
            g = _clean_geometry(g)
            if g:
                geometry[pid] = g
    except Exception as e:
        print(f"Error loading plot geometry: {e}")
    for pid, p in (plots_config or {}).items():
        if pid not in geometry and p.get("legacy_boundaries"):
            g = _legacy_polygon(p["legacy_boundaries"])
            if g:
                geometry[pid] = g
    return geometry


def save_plot_geometry(geometry, path=None):
    """Write plot_geometry.json atomically; False on failure."""
    path = path or PLOT_GEOMETRY_FILE
    try:
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(geometry, f, indent=2)
        os.replace(tmp, path)
        return True
    except Exception as e:
        print(f"Error saving plot geometry: {e}")
        return False


def _clean_geometry(g):
    """Validated geometry with float points, floor below ceiling; None when unusable."""
    if not isinstance(g, dict):
        return None
    pts = []
    for p in g.get("points", []):
        try:
            pts.append([float(p[0]), float(p[1])])
        except (TypeError, ValueError, IndexError):
            return None
    if len(pts) < 3:
        return None
    out = {"points": pts,
           "floor": float(g.get("floor", 0.0)),
           "ceiling": float(g.get("ceiling", 0.0))}
    if out["ceiling"] <= out["floor"]:
        out["ceiling"] = out["floor"] + 50.0
    wp = g.get("world_pos")
    if isinstance(wp, (list, tuple)) and len(wp) >= 3:
        out["world_pos"] = [float(wp[0]), float(wp[1]), float(wp[2])]
    if g.get("source"):
        out["source"] = str(g["source"])
    return out


def apply_world_plots(places, plots_config, geometry):
    """Take the world's reported "plot" places as the geometry, listing new ones unowned; returns (config_changed, geometry_changed)."""
    reported = {}
    for place in places or []:
        if not isinstance(place, dict) or place.get("kind") != "plot":
            continue
        pid = str(place.get("plot", "") or place.get("id", "")).strip()
        if pid.startswith("plot:"):
            pid = pid[5:]
        g = _clean_geometry({
            "points": place.get("points", []),
            "floor": place.get("floor", 0.0),
            "ceiling": place.get("ceiling", 0.0),
            "world_pos": place.get("world_pos"),
        })
        if pid and g:
            reported[pid] = g
    if not reported:
        return False, False
    geometry_changed = reported != geometry
    geometry.clear()
    geometry.update(reported)
    config_changed = False
    for pid in reported:
        if pid not in plots_config:
            plots_config[pid] = {"plot_id": pid, "owner": "", "name": pid.replace("_", " ")}
            config_changed = True
    for p in plots_config.values():
        if p.pop("legacy_boundaries", None) is not None:
            config_changed = True
    return config_changed, geometry_changed


def point_in_polygon(x, z, points):
    """Even-odd ray cast; boundary points count as inside."""
    n = len(points)
    if n < 3:
        return False
    inside = False
    j = n - 1
    for i in range(n):
        xi, zi = points[i]
        xj, zj = points[j]
        if _on_segment(x, z, xi, zi, xj, zj):
            return True
        if (zi > z) != (zj > z):
            x_cross = (xj - xi) * (z - zi) / (zj - zi) + xi
            if x < x_cross:
                inside = not inside
        j = i
    return inside


def _on_segment(x, z, x1, z1, x2, z2, eps=1e-6):
    """True if (x, z) lies on the segment between the two points, within eps."""
    cross = (x2 - x1) * (z - z1) - (z2 - z1) * (x - x1)
    if abs(cross) > eps * max(1.0, abs(x2 - x1) + abs(z2 - z1)):
        return False
    return (min(x1, x2) - eps <= x <= max(x1, x2) + eps and
            min(z1, z2) - eps <= z <= max(z1, z2) + eps)


def polygon_area(points):
    """Unsigned area by the shoelace formula."""
    a = 0.0
    n = len(points)
    for i in range(n):
        x1, z1 = points[i]
        x2, z2 = points[(i + 1) % n]
        a += x1 * z2 - x2 * z1
    return abs(a) * 0.5


def polygon_centroid(points):
    """The mean of the vertices (not the area centroid)."""
    if not points:
        return 0.0, 0.0
    return (sum(p[0] for p in points) / len(points), sum(p[1] for p in points) / len(points))


def is_point_in_plot(point, geom, slack=0.02):
    """True if (x, y, z) in workspace units is inside the polygon and between floor and ceiling."""
    x, y, z = point
    if not point_in_polygon(x, z, geom["points"]):
        return False
    return geom["floor"] - slack <= y <= geom["ceiling"] + slack


def get_plot_by_position(point, geometry, only_ids=None):
    """The smallest plot containing a point: (plot_id, geom) or (None, None)."""
    best = (None, None)
    best_area = None
    for pid, g in geometry.items():
        if only_ids is not None and pid not in only_ids:
            continue
        if not is_point_in_plot(point, g):
            continue
        area = polygon_area(g["points"])
        if best_area is None or area < best_area:
            best, best_area = (pid, g), area
    return best


def footprint_from_message(data):
    """Workspace-local points a placement must satisfy: its bounding box corners, else its origin, else a scaled global "position"."""
    pts = []
    for c in data.get("footprint") or []:
        try:
            pts.append((float(c[0]), float(c[1]), float(c[2])))
        except (TypeError, ValueError, IndexError):
            pass
    if pts:
        return pts
    local = data.get("local")
    if isinstance(local, dict):
        try:
            return [(float(local["x"]), float(local["y"]), float(local["z"]))]
        except (KeyError, TypeError, ValueError):
            pass
    pos = data.get("position")
    if isinstance(pos, dict):
        try:
            return [(float(pos["x"]) * WORLD_SCALE, float(pos["y"]) * WORLD_SCALE,
                     float(pos["z"]) * WORLD_SCALE)]
        except (KeyError, TypeError, ValueError):
            pass
    return []


def can_user_place_object(username, points, plots_config, geometry, claimed_plot_id=""):
    """May `username` place an object with these corners? All must be in ONE of their plots; returns (ok, plot_id, reason)."""
    if not points:
        return False, None, "No position given"
    plot_id, geom = None, None
    claimed = str(claimed_plot_id or "")
    if claimed and claimed in geometry:
        plot_id, geom = claimed, geometry[claimed]
    else:
        plot_id, geom = get_plot_by_position(points[0], geometry)
    if plot_id is None:
        return False, None, "This position is not within any plot"
    for p in points:
        if not is_point_in_plot(p, geom):
            name = plots_config.get(plot_id, {}).get("name", plot_id)
            return False, plot_id, f"The object would stick out of plot '{name}'"
    owner = plots_config.get(plot_id, {}).get("owner", "")
    if not owner:
        return False, plot_id, "This plot has no owner yet"
    if owner.lower() != (username or "").lower():
        return False, plot_id, f"This plot belongs to {owner}"
    return True, plot_id, "OK"


def plot_center(plot_id, geometry):
    """Somewhere to teleport to: {x, y, z} in GLOBAL metres just above the floor at the polygon's centroid."""
    g = geometry.get(plot_id)
    if not g:
        return None
    wp = g.get("world_pos")
    if wp:
        return {"x": wp[0], "y": wp[1] + 1.0, "z": wp[2]}
    cx, cz = polygon_centroid(g["points"])
    return {"x": cx / WORLD_SCALE, "y": g["floor"] / WORLD_SCALE + 1.0, "z": cz / WORLD_SCALE}


def describe_plot(plot_id, plots_config, geometry, object_count=0):
    """One line for /plot: name, id, shape, area, height and object count."""
    p = plots_config.get(plot_id, {})
    name = p.get("name", plot_id)
    g = geometry.get(plot_id)
    if not g:
        return f"'{name}' ({plot_id}): not drawn in the world yet - {object_count} objects"
    area_m2 = polygon_area(g["points"]) / (WORLD_SCALE * WORLD_SCALE)
    height_m = (g["ceiling"] - g["floor"]) / WORLD_SCALE
    return (f"'{name}' ({plot_id}): {len(g['points'])}-sided, {area_m2:.0f} m2, "
            f"{height_m:.0f} m high - {object_count} objects")


def get_plot_data_path(plot_id):
    """data/plots/<plot_id>.json"""
    return os.path.join(PLOTS_DATA_DIR, f"{plot_id}.json")


def load_plot_objects(plot_id):
    """The objects placed in a plot: {net_id: {transform, object_type, ...}}."""
    plot_data_path = get_plot_data_path(plot_id)
    if not os.path.exists(plot_data_path):
        return {}
    try:
        with open(plot_data_path, "r") as f:
            return json.load(f)
    except Exception as e:
        print(f"Error loading plot objects for {plot_id}: {e}")
        return {}


def save_plot_objects(plot_id, objects):
    """Write a plot's objects; False on failure."""
    plot_data_path = get_plot_data_path(plot_id)
    try:
        with open(plot_data_path, "w") as f:
            json.dump(objects, f, indent=2)
        return True
    except Exception as e:
        print(f"Error saving plot objects for {plot_id}: {e}")
        return False


def get_all_plot_objects(plots_config):
    """{plot_id: objects} for every configured plot."""
    return {plot_id: load_plot_objects(plot_id) for plot_id in plots_config.keys()}
