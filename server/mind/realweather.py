"""Real observed Open-Meteo weather for regions marked real_weather; on failure the simulated weather stands."""
import asyncio
import json
import os
import time
import urllib.parse
import urllib.request

from core import identity
from . import regions

# Used when a region has no lonlat of its own.
LAT, LON = identity.get("real_weather_default_latlon")
ENDPOINT = "https://api.open-meteo.com/v1/forecast"
REFRESH = 900.0        # seconds; Open-Meteo publishes a new reading every 15 min
TIMEOUT = 8.0
WINDY_KPH = 32.0       # above this, a clear-but-blowing sky is reported as windy

# WMO present-weather codes -> the world's weather types (nearest match).
WMO = {
    0: "clear",
    1: "partly", 2: "partly",
    3: "overcast",
    45: "fog", 48: "fog",
    51: "drizzle", 53: "drizzle", 55: "drizzle", 56: "drizzle", 57: "drizzle",
    61: "rain", 63: "rain", 65: "rain", 66: "rain", 67: "rain",
    71: "snow", 73: "snow", 75: "snow", 77: "snow",
    80: "rain", 81: "rain", 82: "storm",
    85: "snow", 86: "snow",
    95: "storm", 96: "storm", 99: "storm",
}


def enabled() -> bool:
    """False when GAME_REAL_WEATHER is 0/false/no/off."""
    return (os.environ.get("GAME_REAL_WEATHER", "1") or "").strip().lower() \
        not in ("0", "false", "no", "off")


def _latlon(region=None):
    """(lat, lon) to observe for a region (default: home)."""
    region = region or regions.home()
    if region == regions.home():
        override = _env_latlon()
        if override is not None:
            return override
    ll = regions.lonlat(region)
    if ll is not None:
        return ll[1], ll[0]
    return LAT, LON


def _env_latlon():
    """A valid (lat, lon) from GAME_WEATHER_LATLON, or None."""
    raw = (os.environ.get("GAME_WEATHER_LATLON") or "").strip()
    if not raw:
        return None
    try:
        lat, lon = (float(x) for x in raw.split(",", 1))
    except ValueError:
        return None
    if -90 <= lat <= 90 and -180 <= lon <= 180:
        return lat, lon
    return None


def observe(region=None):
    """The current observation {"type", "temperature_c", "humidity_percent", "wind_kph", "observed"}, or None."""
    lat, lon = _latlon(region)
    url = ENDPOINT + "?" + urllib.parse.urlencode({
        "latitude": lat, "longitude": lon,
        "current": "temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m",
        "timezone": "UTC"})
    try:
        with urllib.request.urlopen(url, timeout=TIMEOUT) as r:
            data = json.load(r)
        now = data["current"]
        temperature = float(now["temperature_2m"])
        humidity = float(now["relative_humidity_2m"])
        code = int(now["weather_code"])
        wind = float(now.get("wind_speed_10m") or 0.0)
    except Exception as e:
        print(f"[Weather] the real sky for {region or regions.home()} not reached "
              f"({type(e).__name__}); the simulation stands")
        return None
    if not (-80 <= temperature <= 60 and 0 <= humidity <= 100):
        print(f"[Weather] implausible reading ({temperature} °C, {humidity}%); ignored")
        return None
    kind = WMO.get(code, "partly")
    # WMO has no code for "windy".
    if kind in ("clear", "partly", "overcast") and wind >= WINDY_KPH:
        kind = "windy"
    return {"type": kind, "temperature_c": round(temperature, 1),
            "humidity_percent": round(humidity, 1), "wind_kph": round(wind, 1),
            "observed": str(now.get("time", ""))}


class RealWeather:
    """Keeps marked regions in step with the real weather; weather set by hand is left alone."""
    MARK = identity.get("real_weather_label")
    REGION = identity.get("real_weather_region")

    def __init__(self, world_weather):
        self.weather = world_weather
        self._next = 0.0
        self._last = {}

    @classmethod
    def mark(cls, region):
        """The source label written with a region's real reading."""
        return cls.MARK if region == cls.REGION else "real"

    def _ours(self, region) -> bool:
        """True when the region is unset or was last written by this class."""
        try:
            current = (self.weather.status().get("regions") or {}).get(region) or {}
        except Exception:
            return False
        if not current:
            return True
        return current.get("source") == self.mark(region)

    async def tick(self):
        """Every REFRESH seconds, observe and write each region still ours."""
        if not enabled() or time.time() < self._next:
            return
        self._next = time.time() + REFRESH
        for region in regions.real_weather_regions():
            if not self._ours(region):
                if self._last.pop(region, None) is not None:
                    print(f"[Weather] {region} was set by hand; leaving the real sky out of it")
                continue
            seen = await asyncio.to_thread(observe, region)
            if seen is None:
                continue
            reading = (seen["type"], seen["temperature_c"], seen["humidity_percent"])
            if self._last.get(region) == reading:
                continue
            self._last[region] = reading
            try:
                self.weather.set(seen["type"], region=region,
                                 temperature_c=seen["temperature_c"],
                                 humidity_percent=seen["humidity_percent"],
                                 source=self.mark(region))
            except Exception as e:
                print(f"[Weather] could not apply the reading to {region}: {e}")
                continue
            print(f"[Weather] {region} {seen['observed']}Z: {seen['type']}, "
                  f"{seen['temperature_c']} °C, {seen['humidity_percent']}% "
                  f"(wind {seen['wind_kph']} km/h)")
