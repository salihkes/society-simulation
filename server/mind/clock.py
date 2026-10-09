"""The world clock everyone shares; data/world/clock.json picks the mode: real, fixed or scaled."""
import json
import os
import time
from datetime import date

from . import regions

EPOCH_ORDINAL = date(1970, 1, 1).toordinal()    # 719163: unix day 0
WEEKDAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]


class WorldClock:
    def __init__(self, path: str):
        self.path = path
        self.mode = "real"
        self.rate = 1.0
        self._fixed_hour = 21.0
        self._anchor_hour = 8.0
        self._anchor_real = time.time()
        self._anchor_day = 0
        self.weekday_override = None
        self._mtime = None
        self._config = None
        self._progress_path = os.path.join(os.path.dirname(path), "clock_progress.json")
        self.reload()

    def reload(self):
        """Apply clock.json if it changed since the last call."""
        try:
            mtime = os.path.getmtime(self.path)
        except OSError:
            mtime = None
        if mtime == self._mtime:
            return
        self._mtime = mtime
        cfg = {}
        if mtime is not None:
            try:
                with open(self.path, "r", encoding="utf-8") as f:
                    cfg = json.load(f) or {}
            except Exception as e:
                print(f"[Clock] bad clock.json ({e}); staying in {self.mode}")
                return
        previous_config = self._config
        self._config = {k: cfg.get(k) for k in ("mode", "rate", "hour")}
        self.mode = str(cfg.get("mode", "real"))
        self.weekday_override = _weekday_index(cfg.get("weekday", None))
        if self.mode == "fixed":
            self._fixed_hour = float(cfg.get("hour", 21.0))
            self.rate = 0.0
        elif self.mode == "scaled":
            self.rate = float(cfg.get("rate", 60.0))
            if previous_config != self._config:
                self._anchor_scaled(cfg, first=previous_config is None)
        else:
            self.mode = "real"
            self.rate = 1.0
        print(f"[Clock] mode={self.mode} rate={self.rate} hour={self.hour():.2f} day={self.day()}")

    def _anchor_scaled(self, cfg: dict, first: bool):
        """Start a scaled run now; on the first load, resume saved progress."""
        self._anchor_hour = float(cfg.get("hour", 8.0))
        self._anchor_real = time.monotonic()
        self._anchor_day = self._real_day()
        if not first:
            return
        try:
            with open(self._progress_path, encoding="utf-8") as f:
                progress = json.load(f)
            if progress.get("config") == self._config:
                self._anchor_hour = float(progress["hour"])
                self._anchor_day = int(progress["day"])
        except (OSError, ValueError, KeyError, TypeError):
            pass

    @staticmethod
    def _offset(region=None) -> float:
        return regions.utc_offset(region) * 3600.0

    def _real_day(self) -> int:
        """Today's ordinal on the home region's calendar."""
        return int((time.time() + self._offset()) // 86400) + EPOCH_ORDINAL

    def utc(self) -> float:
        """The world instant, unix seconds."""
        if self.mode == "fixed":
            local = (self._real_day() - EPOCH_ORDINAL) * 86400.0 + (self._fixed_hour % 24.0) * 3600.0
            return local - self._offset()
        if self.mode == "scaled":
            elapsed = (time.monotonic() - self._anchor_real) * self.rate
            local = (self._anchor_day - EPOCH_ORDINAL) * 86400.0 + self._anchor_hour * 3600.0 + elapsed
            return local - self._offset()
        return time.time()

    def hour(self, region=None) -> float:
        """Clock hour, 0 <= h < 24, in `region` (default: home)."""
        return ((self.utc() + self._offset(region)) / 3600.0) % 24.0

    def day(self, region=None) -> int:
        """Day index (a date ordinal); consecutive game days get consecutive numbers."""
        return int((self.utc() + self._offset(region)) // 86400) + EPOCH_ORDINAL

    def weekday(self) -> int:
        """0 = Monday … 6 = Sunday, for today's game day (or the override)."""
        if self.weekday_override is not None:
            return self.weekday_override
        try:
            return date.fromordinal(self.day()).weekday()
        except (ValueError, OverflowError):
            return date.today().weekday()

    def checkpoint(self):
        """Save scaled-mode progress so a restart with the same settings resumes it."""
        if self.mode != "scaled":
            return
        tmp = self._progress_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"config": self._config, "hour": self.hour(), "day": self.day()}, f)
        os.replace(tmp, self._progress_path)

    def message(self) -> dict:
        return {"type": "world_clock", "mode": self.mode, "hour": round(self.hour(), 4),
                "day": self.day(), "rate": self.rate, "weekday": self.weekday(),
                "utc": round(self.utc(), 3), "home": regions.home()}


def _weekday_index(wd):
    """0-6 for a weekday name or index, None for anything else."""
    if isinstance(wd, str) and wd.lower()[:3] in WEEKDAYS:
        return WEEKDAYS.index(wd.lower()[:3])
    if isinstance(wd, int) and 0 <= wd <= 6:
        return wd
    return None
