"""Building plots: loading them, the world's reported geometry, and placed objects."""

import time
import uuid

from net import state
from world.plots import (
    apply_world_plots, can_user_place_object, footprint_from_message, get_all_plot_objects,
    get_plot_info_for_client, load_plot_geometry, load_plot_objects, load_plots_config,
    save_plot_geometry, save_plot_objects, save_plots_config,
)


def load():
    state.plots_config = load_plots_config()
    print(f"Loaded {len(state.plots_config)} plots from configuration")
    state.plot_geometry = load_plot_geometry(state.plots_config)
    print(f"Loaded geometry for {len(state.plot_geometry)} plots")
    state.plot_objects = get_all_plot_objects(state.plots_config)
    total = sum(len(objs) for objs in state.plot_objects.values())
    print(f"Loaded {total} objects across all plots")


async def apply_reported_plots(places):
    """Take the plot polygons the world process reported; save and announce any change."""
    cfg_changed, geo_changed = apply_world_plots(places, state.plots_config, state.plot_geometry)
    if geo_changed:
        save_plot_geometry(state.plot_geometry)
    if cfg_changed:
        save_plots_config(state.plots_config)
    if not (cfg_changed or geo_changed):
        return
    for pid in state.plots_config:
        state.plot_objects.setdefault(pid, load_plot_objects(pid))
    unowned = [pid for pid, p in state.plots_config.items() if not p.get("owner")]
    print(f"[Plots] world reported {len(state.plot_geometry)} plots; unowned: {unowned or 'none'}")
    await state.send_all({"type": "plots_info",
                          "plots": get_plot_info_for_client(state.plots_config)})


def _owns_plot(username, plot_id):
    owner = state.plots_config.get(plot_id, {}).get("owner", "")
    return owner.lower() == username.lower()


def _has_object(plot_id, net_id):
    return plot_id in state.plot_objects and net_id in state.plot_objects[plot_id]


async def on_place_plot_object(client_id, websocket, data):
    """Place an object if every corner of its footprint lies in one of the player's plots."""
    if not state.clients[client_id]["authenticated"]:
        await state.system_message(websocket, "You must be logged in to place objects in plots")
        return
    username = state.clients[client_id]["username"]
    transform = data.get("transform", {})
    object_type = data.get("object_type", "unknown")
    net_id = str(data.get("net_id", uuid.uuid4()))
    points = footprint_from_message(data)
    can_place, plot_id, reason = can_user_place_object(
        username, points, state.plots_config, state.plot_geometry, data.get("plot_id", ""))
    if not can_place:
        await state.system_message(websocket, f"Cannot place object: {reason}")
        return
    if plot_id not in state.plot_objects:
        state.plot_objects[plot_id] = {}
    state.plot_objects[plot_id][net_id] = {
        "transform": transform,
        "object_type": object_type,
        "placed_by": username,
        "placed_at": time.time()
    }
    save_plot_objects(plot_id, state.plot_objects[plot_id])
    await state.broadcast({
        "type": "plot_object_spawn",
        "plot_id": plot_id,
        "net_id": net_id,
        "transform": transform,
        "object_type": object_type
    })
    print(f"User {username} placed object {net_id} in plot {plot_id}")


async def on_remove_plot_object(client_id, websocket, data):
    """Remove an object from the player's own plot."""
    if not state.clients[client_id]["authenticated"]:
        await state.system_message(websocket, "You must be logged in to remove objects from plots")
        return
    username = state.clients[client_id]["username"]
    net_id = str(data.get("net_id"))
    plot_id = data.get("plot_id")
    if not _has_object(plot_id, net_id):
        await state.system_message(websocket, "Object not found in plot")
        return
    if not _owns_plot(username, plot_id):
        await state.system_message(websocket, "You can only remove objects from your own plot")
        return
    del state.plot_objects[plot_id][net_id]
    save_plot_objects(plot_id, state.plot_objects[plot_id])
    await state.broadcast({"type": "plot_object_remove", "plot_id": plot_id, "net_id": net_id})
    print(f"User {username} removed object {net_id} from plot {plot_id}")


async def on_update_plot_object(client_id, websocket, data):
    """Move an object in the player's own plot; it must stay inside the plot."""
    if not state.clients[client_id]["authenticated"]:
        return
    username = state.clients[client_id]["username"]
    net_id = str(data.get("net_id"))
    plot_id = data.get("plot_id")
    transform = data.get("transform", {})
    if not _has_object(plot_id, net_id) or not _owns_plot(username, plot_id):
        return
    points = footprint_from_message(data)
    if points:
        ok, _pid, reason = can_user_place_object(
            username, points, state.plots_config, state.plot_geometry, plot_id)
        if not ok:
            await state.system_message(websocket, f"Not saved: {reason}")
            return
    state.plot_objects[plot_id][net_id]["transform"] = transform
    save_plot_objects(plot_id, state.plot_objects[plot_id])
    await state.broadcast({
        "type": "plot_object_update",
        "plot_id": plot_id,
        "net_id": net_id,
        "transform": transform
    }, skip=client_id)
