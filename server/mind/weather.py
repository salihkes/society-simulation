"""The world's weather setting, stored in the environment JSON file the server watches."""
import json
import math
import os
from pathlib import Path
import tempfile
import uuid

from . import regions


WEATHER_TYPES = ("auto", "clear", "partly", "overcast", "fog", "drizzle", "rain", "storm", "windy", "snow")

REGIONS = regions.ids()


class WorldWeather:
    def __init__(self, path):
        self.path = Path(path)

    def _read(self):
        """The environment file as a dict; {} when it does not exist."""
        try:
            with self.path.open(encoding="utf-8") as f:
                environment = json.load(f)
        except FileNotFoundError:
            return {}
        if not isinstance(environment, dict):
            raise ValueError("world environment must be a JSON object")
        return environment

    def status(self):
        weather = self._read().get("weather", {"type": "auto"})
        configured = weather.get("type", "auto") if isinstance(weather, dict) else weather
        normalized = str(configured).strip().lower()
        if normalized == "raining":
            normalized = "rain"
        result = {"configured": configured,
                  "mode": "fixed" if normalized in WEATHER_TYPES[1:] else "auto",
                  "available": list(WEATHER_TYPES)}
        result["snow"] = weather.get("snow", {}) if isinstance(weather, dict) else {}
        result["regions"] = weather.get("regions", {}) if isinstance(weather, dict) else {}
        result["available_regions"] = list(REGIONS)
        for key in ("temperature_c", "humidity_percent"):
            result[key] = weather.get(key) if isinstance(weather, dict) else None
        result["snow_note"] = "Snow settings use metres and metres per real minute; current depth is simulated by the world owner."
        if result["mode"] == "auto":
            result["note"] = "The headless world owner advances regional climate and water ice; viewers sample their own location."
        return result

    def set(self, preset, snow=None, region=None, temperature_c=None, humidity_percent=None,
            source=None):
        """Store a weather preset globally or for one region; source names an automatic writer, None a person."""
        preset = str(preset).strip().lower()
        _validate(preset, region, temperature_c, humidity_percent)
        environment = self._read()
        weather = environment.get("weather", {})
        weather = dict(weather) if isinstance(weather, dict) else {}
        target = weather
        if region is not None:
            regions = dict(weather.get("regions", {}))
            target = dict(regions.get(region, {}))
            regions[region] = target
            weather["regions"] = regions
        target["type"] = preset
        if source is None:
            target.pop("source", None)
        else:
            target["source"] = str(source)
        _apply_climate(target, preset, region, temperature_c, humidity_percent)
        if snow:
            target["snow"] = _snow_settings(target, snow)
        environment["weather"] = weather
        self._write(environment)
        return {"type": "weather_update", "weather": weather}

    def _write(self, environment):
        """Replace the file atomically so the file monitor never sees half of it."""
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=self.path.parent,
                                             prefix=self.path.name + ".", delete=False) as f:
                tmp = f.name
                json.dump(environment, f, ensure_ascii=False, indent=4)
                f.write("\n")
            os.replace(tmp, self.path)
        finally:
            if tmp is not None and os.path.exists(tmp):
                os.unlink(tmp)


def _validate(preset, region, temperature_c, humidity_percent):
    """Raise ValueError for an unknown preset or region or an out-of-range value."""
    if preset not in WEATHER_TYPES:
        raise ValueError("Unknown weather '%s'; choose: %s" % (preset, ", ".join(WEATHER_TYPES)))
    if region is not None and region not in REGIONS:
        raise ValueError("Unknown weather region: %s" % region)
    for name, value, low, high in (("temperature_c", temperature_c, -80, 60),
                                  ("humidity_percent", humidity_percent, 0, 100)):
        if value is not None and (isinstance(value, bool) or not isinstance(value, (int, float))
                                  or not math.isfinite(value) or not low <= value <= high):
            raise ValueError("Invalid %s (allowed %s..%s)" % (name, low, high))


def _apply_climate(target, preset, region, temperature_c, humidity_percent):
    for name, value in (("temperature_c", temperature_c), ("humidity_percent", humidity_percent)):
        if value is not None:
            target[name] = float(value)
        elif preset != "auto":
            continue
        elif region is not None:
            # An explicit null on a region resumes its climate rather than inheriting a forced global.
            target[name] = None
        else:
            target.pop(name, None)


def _snow_settings(target, snow) -> dict:
    limits = {"depth": .30, "max_depth": .30, "rate": .10, "melt": .10}
    settings = dict(target.get("snow", {}))
    for name, value in snow.items():
        if name not in limits or not math.isfinite(float(value)) or not 0 <= float(value) <= limits[name]:
            raise ValueError("Invalid snow %s (allowed 0..%s)" % (name, limits.get(name, "?")))
        settings[name] = float(value)
    # Only depth is a one-shot command; a rate change must not reapply it.
    if "depth" in snow:
        settings["command"] = uuid.uuid4().hex
    return settings
