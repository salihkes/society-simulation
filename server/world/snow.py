"""Keeps the authority's snow cover for late joiners; the server never simulates snow."""
import base64
import binascii
import math
import struct


def _valid_numbers(n):
    if not all(math.isfinite(v) for v in n.values()):
        return False
    if not 0 <= n["depth"] <= .30 or min(n["fall"], n["time"]) < 0:
        return False
    return 0 <= n["max"] <= .30 and 0 <= n["rate"] <= .10 and 0 <= n["melt"] <= .10


class SnowCache:
    """The latest snow header and per-track records, built from full and delta packets."""

    STRIDE = 40  # ten little-endian float32 values per track, matching SnowState
    MAX_TRACKS = 32768

    def __init__(self):
        self.header = None
        self.records = b""

    def _parse(self, packet):
        """The packet's fields, checked and decoded; None when a value is out of range."""
        epoch = str(packet["epoch"])
        first, last, start = (int(packet[k]) for k in ("first", "last", "start"))
        numbers = {k: float(packet[k]) for k in ("depth", "fall", "time")}
        numbers.update({k: float(packet.get(k, default)) for k, default in
                        (("max", .18), ("rate", .006), ("melt", .002))})
        if not _valid_numbers(numbers):
            return None
        if (first < 1 or last < first - 1 or not first <= start <= last + 1
                or last - first + 1 > self.MAX_TRACKS):
            return None
        encoded = packet["data"]
        if not isinstance(encoded, str) or len(encoded) > self.MAX_TRACKS * self.STRIDE * 2:
            return None
        raw = base64.b64decode(encoded, validate=True)
        if len(raw) != (last - start + 1) * self.STRIDE:
            return None
        if any(not math.isfinite(v[0]) for v in struct.iter_unpack("<f", raw)):
            return None
        return {"epoch": epoch, "first": first, "last": last, "start": start,
                "numbers": numbers, "raw": raw, "full": bool(packet.get("full", False))}

    def _merge(self, p):
        """The records after applying a parsed packet, or None if it does not follow on."""
        previous = self.header
        same_epoch = bool(previous) and previous["epoch"] == p["epoch"]
        if same_epoch and (p["last"] < previous["last"]
                           or p["numbers"]["time"] < previous["time"] - .001):
            return None
        if p["full"] or not same_epoch:
            if p["start"] != p["first"]:
                return None
            records = p["raw"]
        else:
            if p["start"] > previous["last"] + 1 or p["first"] < previous["first"]:
                return None
            retained = self.records[max(0, p["first"] - previous["first"]) * self.STRIDE:]
            new = p["raw"][max(0, previous["last"] + 1 - p["start"]) * self.STRIDE:]
            records = retained + new
        if len(records) != (p["last"] - p["first"] + 1) * self.STRIDE:
            return None
        return records

    def accept(self, packet):
        """Take a snow packet; malformed, gapped or stale data is refused and changes nothing."""
        if not isinstance(packet, dict):
            return False
        try:
            parsed = self._parse(packet)
            records = self._merge(parsed) if parsed else None
        except (KeyError, ValueError, TypeError, OverflowError, binascii.Error):
            return False
        if records is None:
            return False
        self.records = records
        self.header = {**parsed["numbers"], "epoch": parsed["epoch"], "first": parsed["first"],
                       "last": parsed["last"], "command": str(packet.get("command", ""))}
        return True

    def snapshot(self):
        """The whole cached cover as one full packet, or {} when there is none."""
        if self.header is None:
            return {}
        return {**self.header, "full": True, "start": self.header["first"],
                "data": base64.b64encode(self.records).decode("ascii")}

    def weather_for_join(self, weather):
        """`weather` with the cached snow cover added, for a client that just joined."""
        result = dict(weather)
        if self.header is not None:
            result["snow"] = self.snapshot()
        return result
