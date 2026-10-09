"""Client of the Assistant app (the NPCs' conversational brain); one short websocket per request."""
import asyncio
import json
import logging
import os

import websockets

logger = logging.getLogger(__name__)

ASSISTANT_WS_URL = os.environ.get("ASSISTANT_WS_URL", "ws://127.0.0.1:8766")
ASSISTANT_WS_TIMEOUT = float(os.environ.get("ASSISTANT_WS_TIMEOUT", "130"))
_MAX_SIZE = 8 * 1024 * 1024  # the connector's max_size; voice turns are large


async def _await_reply(ws, expect_type: str) -> dict:
    """Read messages until one of type `expect_type` arrives; others are skipped."""
    while True:
        raw = await asyncio.wait_for(ws.recv(), timeout=ASSISTANT_WS_TIMEOUT)
        msg = json.loads(raw)
        if msg.get("type") == expect_type:
            return msg


async def _request(payload: dict, expect_type: str) -> dict | None:
    """Send one request and return the first reply of type `expect_type`, or None on error."""
    try:
        async with websockets.connect(ASSISTANT_WS_URL, max_size=_MAX_SIZE) as ws:
            await ws.send(json.dumps(payload))
            return await _await_reply(ws, expect_type)
    except (OSError, asyncio.TimeoutError, websockets.WebSocketException) as e:
        logger.warning("[AssistantBridge] %s request failed: %s", payload.get("type"), e)
        return None
    except json.JSONDecodeError as e:
        logger.warning("[AssistantBridge] bad response: %s", e)
        return None


async def chat(npc_id: str, speaker: str, text: str,
               world_state: dict | None = None) -> dict | None:
    """Send a text turn. Returns {"text": str, "audio": str|None} or None."""
    msg = await _request({
        "type": "npc_chat",
        "npc_id": npc_id,
        "speaker": speaker,
        "text": text,
        "world_state": world_state or {},
    }, "npc_chat_response")
    return _shape(msg)


async def voice_chat(npc_id: str, speaker: str, audio_b64: str,
                     world_state: dict | None = None) -> dict | None:
    """Send a voice turn (the Assistant transcribes it). Returns {"text", "audio"} or None."""
    msg = await _request({
        "type": "npc_voice_chat",
        "npc_id": npc_id,
        "speaker": speaker,
        "audio_b64": audio_b64,
        "world_state": world_state or {},
    }, "npc_chat_response")
    return _shape(msg)


async def fetch_schedule(npc_id: str) -> list | None:
    """The NPC's daily schedule from the Assistant, or None on failure."""
    msg = await _request({"type": "npc_schedule_request", "npc_id": npc_id},
                         "npc_schedule")
    if msg is None:
        return None
    return msg.get("schedule", [])


def _shape(msg: dict | None) -> dict | None:
    """A connector reply as {"text", "audio"} (from audio_b64), or None; an error reply adds "error": True."""
    if msg is None:
        return None
    if msg.get("error"):
        return {"text": str(msg.get("text", "(no response)")), "audio": None, "error": True}
    return {"text": str(msg.get("text", "")), "audio": msg.get("audio_b64")}
