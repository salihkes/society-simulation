"""The province map: its replicated state, each player's owner colour, and peace treaties."""

import asyncio
import json
import os
import time
import uuid

from core.constants import MAP_REQUIRE_ONLINE_TO_OCCUPY, MAP_STATE_FILE, TREATY_TIMEOUT_SECONDS
from net import state
from accounts.users import assign_user_map_owner, get_user_map_owner

TREATY_SWEEP_SECONDS = 5


def load():
    """Read the saved map state into state.map_state (empty when missing or unreadable)."""
    if not os.path.exists(MAP_STATE_FILE):
        print("No map state file found, starting with empty map state")
        return
    try:
        with open(MAP_STATE_FILE, "r") as f:
            state.map_state = json.load(f)
        print(f"Loaded map state: {len(state.map_state.get('owners', []))} owners, "
              f"{len(state.map_state.get('provinces', []))} provinces")
    except Exception as e:
        print(f"Error loading map state: {e}")
        state.map_state = {"owners": [], "provinces": []}


def persist_map_state():
    try:
        with open(MAP_STATE_FILE, "w") as f:
            json.dump(state.map_state, f, indent="\t")
    except Exception as e:
        print(f"Error saving map state: {e}")


async def _relay_full_map():
    await state.relay({"type": "map_full_update", "state": state.map_state})


def _ensure_owner_entry(owner_id, color):
    """Add or recolour the owner's entry in the map state, saving when it changed."""
    owners = state.map_state.setdefault("owners", [])
    existing = next((o for o in owners if o.get("id") == owner_id), None)
    if existing is None:
        owners.append({"id": owner_id, "name": owner_id, "color": color})
        persist_map_state()
    elif existing.get("color", "").lower() != color.lower():
        existing["color"] = color
        persist_map_state()


async def assign_map_owner_on_login(username, websocket):
    """Give a player their map owner and colour (assigning one if new) and tell everyone."""
    info = get_user_map_owner(username)
    if info is None:
        info = assign_user_map_owner(username)
    owner_id = info["owner_id"]
    color = info["color"]
    _ensure_owner_entry(owner_id, color)
    await websocket.send(json.dumps({
        "type": "map_player_owner",
        "owner_id": owner_id,
        "color": color
    }))
    await _relay_full_map()
    print(f"[Map] Sent owner info to {username}: owner_id={owner_id}, color={color}")
    await broadcast_map_online_owners()


def _online_owner_ids():
    online = []
    for cid, c in list(state.clients.items()):
        if not c.get("authenticated"):
            continue
        info = get_user_map_owner(c["username"])
        if info:
            online.append(info["owner_id"])
    return online


async def broadcast_map_online_owners():
    """Send every client the online owners and whether occupying requires them online."""
    await state.relay({
        "type": "map_online_owners",
        "online_owner_ids": _online_owner_ids(),
        "require_online": MAP_REQUIRE_ONLINE_TO_OCCUPY,
    })


async def on_map_full_update(client_id, websocket, data):
    """A client replaced the whole map (painting, loading): save it and pass it on."""
    state.map_state = data.get("state", {"owners": [], "provinces": []})
    persist_map_state()
    for cid, client in list(state.clients.items()):
        if cid == client_id:
            continue
        try:
            await client["websocket"].send(json.dumps({
                "type": "map_full_update",
                "state": state.map_state
            }))
        except Exception as e:
            print(f"Error broadcasting map state to client {cid}: {e}")
    owner_count = len(state.map_state.get("owners", []))
    prov_count = len(state.map_state.get("provinces", []))
    print(f"Map state updated by client {client_id} "
          f"({owner_count} owners, {prov_count} provinces)")


async def on_map_request_state(client_id, websocket, data):
    await websocket.send(json.dumps({"type": "map_state", "state": state.map_state}))


def _online_client_id(username):
    for cid, c in list(state.clients.items()):
        if c.get("username") == username and c.get("authenticated"):
            return cid
    return None


def _treaty_pending_between(a, b):
    return any({t["proposer"], t["target"]} == {a, b} for t in state.pending_treaties.values())


async def on_treaty_propose(client_id, websocket, data):
    """Offer another online player a peace treaty that expires after TREATY_TIMEOUT_SECONDS."""
    proposer = state.clients[client_id].get("username")
    target = data.get("target", "")
    if not state.clients[client_id].get("authenticated"):
        await state.system_message(websocket, "You must be logged in to propose a treaty.")
        return
    if not target:
        await state.system_message(websocket, "No target player specified.")
        return
    target_cid = _online_client_id(target)
    if target_cid is None:
        await state.system_message(websocket, f"Player '{target}' is not online.")
        return
    prop_info = get_user_map_owner(proposer)
    targ_info = get_user_map_owner(target)
    if not prop_info or not targ_info:
        await state.system_message(websocket, "Both players must have map owners assigned.")
        return
    if _treaty_pending_between(proposer, target):
        await state.system_message(websocket, "A treaty is already pending between you two.")
        return
    treaty_id = str(uuid.uuid4())[:8]
    state.pending_treaties[treaty_id] = {
        "proposer": proposer,
        "target": target,
        "expires_at": time.time() + TREATY_TIMEOUT_SECONDS,
    }
    print(f"[Treaty] {proposer} -> {target} (id={treaty_id}, timeout={TREATY_TIMEOUT_SECONDS}s)")
    await websocket.send(json.dumps({
        "type": "treaty_pending",
        "treaty_id": treaty_id,
        "target": target,
        "expires_in": TREATY_TIMEOUT_SECONDS,
    }))
    await state.clients[target_cid]["websocket"].send(json.dumps({
        "type": "treaty_incoming",
        "treaty_id": treaty_id,
        "proposer": proposer,
        "expires_in": TREATY_TIMEOUT_SECONDS,
    }))


def _settle_occupations(proposer_owner, target_owner):
    """Each side gains ownership of the other's provinces it occupies."""
    for prov in state.map_state.get("provinces", []):
        occ = prov.get("occupier", "")
        owner = prov.get("owner", "")
        if owner == target_owner and occ == proposer_owner:
            prov["owner"] = proposer_owner
            prov["occupier"] = ""
        elif owner == proposer_owner and occ == target_owner:
            prov["owner"] = target_owner
            prov["occupier"] = ""


async def _accept_treaty(treaty):
    proposer_owner = (get_user_map_owner(treaty["proposer"]) or {}).get("owner_id")
    target_owner = (get_user_map_owner(treaty["target"]) or {}).get("owner_id")
    if proposer_owner and target_owner:
        _settle_occupations(proposer_owner, target_owner)
        persist_map_state()
        await _relay_full_map()
    print(f"[Treaty] ACCEPTED {treaty['proposer']} <-> {treaty['target']}")


async def on_treaty_respond(client_id, websocket, data):
    treaty_id = data.get("treaty_id", "")
    accept = data.get("accept", False)
    responder = state.clients[client_id].get("username")
    treaty = state.pending_treaties.pop(treaty_id, None)
    if treaty is None:
        await state.system_message(websocket, "Treaty not found or already expired.")
        return
    if treaty["target"] != responder:
        state.pending_treaties[treaty_id] = treaty
        await state.system_message(websocket, "You are not the target of this treaty.")
        return
    if treaty["expires_at"] < time.time():
        await send_treaty_resolved(treaty, False)
        return
    if accept:
        await _accept_treaty(treaty)
    else:
        print(f"[Treaty] REJECTED {treaty['proposer']} <-> {treaty['target']}")
    await send_treaty_resolved(treaty, accept)


async def send_treaty_resolved(treaty, accepted):
    """Tell both parties (their first connection each) how a treaty ended."""
    for role in ("proposer", "target"):
        username = treaty[role]
        for cid, c in list(state.clients.items()):
            if c.get("username") != username:
                continue
            try:
                await c["websocket"].send(json.dumps({
                    "type": "treaty_resolved",
                    "treaty_id": "",
                    "accepted": accepted,
                    "proposer": treaty["proposer"],
                    "target": treaty["target"],
                }))
            except Exception:
                pass
            break


async def treaty_cleanup():
    """Forever: expire stale pending treaties every TREATY_SWEEP_SECONDS."""
    while True:
        try:
            now = time.time()
            expired = [tid for tid, t in state.pending_treaties.items() if t["expires_at"] < now]
            for tid in expired:
                treaty = state.pending_treaties.pop(tid)
                print(f"[Treaty] EXPIRED {treaty['proposer']} <-> {treaty['target']}")
                await send_treaty_resolved(treaty, False)
            await asyncio.sleep(TREATY_SWEEP_SECONDS)
        except Exception as e:
            print(f"Error in treaty cleanup: {e}")
            await asyncio.sleep(TREATY_SWEEP_SECONDS)
