"""The configured weather: read from world_environment.json and pushed to clients."""

import asyncio
import json
import os

from core.constants import WORLD_ENVIRONMENT_FILE
from net import state

WEATHER_POLL_SECONDS = 5


def get_world_environment():
    """The world environment config; {"weather": {"type": "auto"}} when absent or unreadable."""
    if not os.path.exists(WORLD_ENVIRONMENT_FILE):
        return {"weather": {"type": "auto"}}
    try:
        with open(WORLD_ENVIRONMENT_FILE, "r") as f:
            return json.load(f)
    except Exception as e:
        print(f"Error reading world environment: {e}")
        return {"weather": {"type": "auto"}}


def configured_weather():
    """The "weather" entry of the environment config, "clear" when it has none."""
    return get_world_environment().get("weather", {"type": "clear"})


async def broadcast_weather_update():
    weather_data = configured_weather()
    print(f"Broadcasting weather update: {weather_data}")
    payload = json.dumps({"type": "weather_update", "weather": weather_data})
    for client_id, client in list(state.clients.items()):
        try:
            await client["websocket"].send(payload)
        except Exception as e:
            print(f"Error sending weather update to client {client_id}: {e}")


def _open_real_sky():
    """The real-weather feed that writes WORLD_ENVIRONMENT_FILE, or None if unavailable."""
    try:
        from mind.realweather import RealWeather
        from mind.weather import WorldWeather
        return RealWeather(WorldWeather(WORLD_ENVIRONMENT_FILE))
    except Exception as e:
        print(f"[Weather] real-sky feed unavailable: {e}")
        return None


async def _tick_real_sky(real_sky):
    """Advance the real-weather feed once; a failure is logged, not raised."""
    if real_sky is None:
        return
    try:
        await real_sky.tick()
    except Exception as e:
        print(f"[Weather] real-sky tick failed: {e}")


async def weather_monitor():
    """Forever: tick the real-weather feed and broadcast when the configured weather changes."""
    last_weather = None
    real_sky = _open_real_sky()
    while True:
        try:
            await _tick_real_sky(real_sky)
            current_weather = configured_weather()
            if current_weather != last_weather:
                print(f"Weather changed from {last_weather} to {current_weather}")
                await broadcast_weather_update()
                last_weather = current_weather
            await asyncio.sleep(WEATHER_POLL_SECONDS)
        except Exception as e:
            print(f"Error in weather monitor: {e}")
            await asyncio.sleep(WEATHER_POLL_SECONDS)
