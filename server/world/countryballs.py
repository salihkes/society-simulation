"""Countryball flavours: which wear a flag and which faces each has; mirrors client/src/character/countryball_types.gd."""

CLASSIC = "countryball"
ONESIDE = "countryball_oneside"
QWC = "countryball_qwc"

CLASSIC_EMOTIONS = ["neutral", "happy", "sad", "serious"]
QWC_EMOTIONS = ["neutral", "happy", "sad", "serious",
                "angry", "afraid", "scarystare", "shocked"]

# Not a countryball, but its procedurally drawn face (humanoid_face.gd) has every expression.
HUMANOID = "humanoid"
HUMANOID_EMOTIONS = QWC_EMOTIONS

TYPES = {
    CLASSIC: {"emotions": CLASSIC_EMOTIONS, "flagged": False},
    ONESIDE: {"emotions": CLASSIC_EMOTIONS, "flagged": True},
    QWC: {"emotions": QWC_EMOTIONS, "flagged": True},
}

# Values of the optional subtype in "/countryball <flag> [subtype]"; omitted means one-side.
SUBTYPE_ALIASES = {
    "": ONESIDE,
    "classic": ONESIDE,
    "default": ONESIDE,
    "oneside": ONESIDE,
    "qwc": QWC,
    "mqwc": QWC,
    "quincyform": QWC,
}

SUBTYPE_NAMES = ["classic", "qwc"]


def wears_flag(character_type):
    """True if this flavour shows a flag texture sent by the server."""
    return TYPES.get(character_type, {}).get("flagged", False)


def resolve_subtype(subtype_arg):
    """Map a '/countryball <flag> [subtype]' argument to a character type; None if unrecognised."""
    return SUBTYPE_ALIASES.get((subtype_arg or "").strip().lower())


def emotions_for(character_type):
    """Emotions accepted by this character type (empty for custom models)."""
    if character_type == HUMANOID:
        return HUMANOID_EMOTIONS
    return TYPES.get(character_type, {}).get("emotions", [])


def supports_emotion(character_type, emotion):
    """True if this character type has the face `emotion` (case and spaces ignored)."""
    return emotion.strip().lower() in emotions_for(character_type)


def all_emotions():
    """Every emotion any countryball flavour has, in first-seen order (for command matching)."""
    names = []
    for meta in TYPES.values():
        for emotion in meta["emotions"]:
            if emotion not in names:
                names.append(emotion)
    return names
