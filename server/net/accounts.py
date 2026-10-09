"""Accounts: registering, password login and website single sign-on."""

import json
import uuid

from world import countryballs
from net import state
from net.sso import validate_sso_token
from net.world_map import assign_map_owner_on_login
from world.textures import send_flag_texture_data, send_texture_data, user_has_texture
from accounts.users import get_user_accessories, get_user_character_type, load_user_data


async def on_register(client_id, websocket, data):
    success, message = state.auth_manager.register_user(data["username"], data["password"])
    await websocket.send(json.dumps({
        "type": "register_response",
        "success": success,
        "message": message
    }))


async def _send_appearance_texture(username, character_type, flag_code, tag):
    """Send a newly signed-in player's texture to everyone; returns the flag send's success, else None."""
    if countryballs.wears_flag(character_type) and flag_code:
        success, actual_flag_code = await send_flag_texture_data(
            username, flag_code, state.clients.values(), character_type)
        if success:
            print(f"{tag}Sent flag texture {actual_flag_code} for {username}")
        else:
            print(f"{tag}Failed to send flag texture for {username}, flag_code: {flag_code}")
        return success
    if character_type == "custom":
        # Custom characters carry their own embedded materials.
        print(f"{tag}Custom character for {username}, skipping texture send")
        return None
    has_texture = user_has_texture(username, character_type)
    await send_texture_data(username, character_type, state.clients.values())
    if has_texture:
        print(f"{tag}Sent custom {character_type} texture for {username}")
    else:
        print(f"{tag}Sent default countryball.png for {username} (no custom texture found)")
    return None


async def _sign_in(client_id, websocket, username, display_name, tag):
    """Make the connection the account `username`; returns the flag texture send's success, else None."""
    client = state.clients[client_id]
    old_username = client["username"]
    client["username"] = username
    client["authenticated"] = True
    client["display_name"] = display_name
    accessories = get_user_accessories(username)
    client["accessories"] = accessories
    print(f"{tag}User {username} has accessories: {accessories}")
    character_type = get_user_character_type(username)
    client["character_type"] = character_type
    print(f"{tag}User {username} has character type: {character_type}")
    flag_code = None
    if countryballs.wears_flag(character_type):
        flag_code = load_user_data(username).get("flag_code", "")
        client["flag_code"] = flag_code
        print(f"{tag}User {username} has flag_code: {flag_code}")
    await state.broadcast({"type": "system_message",
                           "message": f"{old_username} is now known as {username}"})
    client["texture"] = username
    flag_ok = await _send_appearance_texture(username, character_type, flag_code, tag)
    await state.broadcast({
        "type": "accessories_data",
        "player_id": client_id,
        "username": username,
        "accessories": accessories
    })
    transform = {
        "type": "character_transform",
        "player_id": client_id,
        "username": username,
        "character_type": character_type
    }
    if countryballs.wears_flag(character_type) and flag_code:
        transform["flag_code"] = flag_code
    await state.broadcast(transform)
    await assign_map_owner_on_login(username, websocket)
    return flag_ok


async def on_login(client_id, websocket, data):
    """Password login; a failed flag texture send turns the reply into a failure."""
    username = data["username"]
    success, result = state.auth_manager.authenticate_user(username, data["password"])
    if success:
        flag_ok = await _sign_in(client_id, websocket, username, result["display_name"], "")
        if flag_ok is not None:
            success = flag_ok
    await websocket.send(json.dumps({
        "type": "login_response",
        "success": success,
        "message": "Login successful" if success else result
    }))


async def _login_failed(websocket, message):
    await websocket.send(json.dumps({
        "type": "login_response",
        "success": False,
        "message": message
    }))


async def _sso_username(websocket, token):
    """The token's username, or None; a banned user is told so first."""
    username = validate_sso_token(token)
    if not username:
        return None
    banned, ancestor = state.auth_manager.is_effectively_banned(username)
    if not banned:
        return username
    print(f"[SSO] Refusing banned user {username} (ancestor={ancestor})")
    cascade = f" (cascade from {ancestor})" if ancestor != username else ""
    await _login_failed(websocket, "Account banned" + cascade)
    return None


async def on_token_login(client_id, websocket, data):
    """Log in with a website SSO token, creating the game account on first use."""
    username = await _sso_username(websocket, data.get("token", ""))
    if not username:
        await _login_failed(websocket, "Invalid or expired token")
        return
    user_data = state.auth_manager.get_user_data(username)
    if not user_data:
        print(f"[SSO] File for {username} missing. Auto-creating...")
        state.auth_manager.register_user(username, str(uuid.uuid4()))
        user_data = state.auth_manager.get_user_data(username)
    if not user_data:
        await _login_failed(websocket, "User data not found")
        return
    await _sign_in(client_id, websocket, username, username, "[SSO] ")
    await websocket.send(json.dumps({"type": "login_success", "username": username}))
    await websocket.send(json.dumps({
        "type": "login_response",
        "success": True,
        "message": "SSO login successful"
    }))
    print(f"[SSO] Token login successful for {username}")
