"""Validation of the garment ids a player wears; resource paths are never accepted."""
import re

MAX_GARMENTS = 12

_ID = re.compile(r"[A-Za-z0-9_-]{1,48}\Z")


def parse_outfit(value):
    """The sorted, de-duplicated garment ids in `value`, or None if it is not a valid outfit."""
    if not isinstance(value, list) or len(value) > MAX_GARMENTS:
        return None
    if any(not isinstance(item, str) or not _ID.fullmatch(item) for item in value):
        return None
    return sorted(set(value))
