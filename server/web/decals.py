"""Decal upload API: a player's PNG for their humanoid or countryball, saved where the game server reads it."""

import base64

from aiohttp import web

from web.reply import fail, ok
from web.session import user
from world.textures import MAX_DECAL_BYTES, save_decal_texture

CHARACTER_TYPES = ("humanoid", "countryball")
# Room for the form fields around a file of the largest allowed size.
MAX_REQUEST_BYTES = MAX_DECAL_BYTES + 1024 * 1024


async def upload(request):
    """multipart/form-data with "file" (a .png) and "character_type"."""
    name = user(request)
    if not name:
        return fail(401, "User not authenticated")
    form = await request.post()
    upload_field = form.get("file")
    if not isinstance(upload_field, web.FileField):
        return fail(400, "No file provided")
    character_type = str(form.get("character_type", "humanoid")).lower()
    if character_type not in CHARACTER_TYPES:
        return fail(400, "Invalid character_type. Must be 'humanoid' or 'countryball'")
    if not upload_field.filename:
        return fail(400, "No file selected")
    if not upload_field.filename.lower().endswith(".png"):
        return fail(400, "Only PNG files are supported")
    data = upload_field.file.read()
    if len(data) > MAX_DECAL_BYTES:
        return fail(400, "File too large. Maximum size is 5MB")
    success, message, path = save_decal_texture(name, character_type,
                                                base64.b64encode(data).decode())
    if not success:
        return fail(500, message)
    return ok(message=message, character_type=character_type, file_path=path)


def add_routes(app):
    app.router.add_post("/api/upload-decal", upload)
