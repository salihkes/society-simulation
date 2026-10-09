extends RefCounted
class_name CountryballTypes
## Registry of countryball flavours: scene, emotions and whether it wears a flag.

const CLASSIC := "countryball"
const ONESIDE := "countryball_oneside"
const QWC := "countryball_qwc"

const CLASSIC_EMOTIONS := ["neutral", "happy", "sad", "serious"]
const QWC_EMOTIONS := ["neutral", "happy", "sad", "serious", "angry", "afraid", "scarystare",
	"shocked"]

## Not a countryball, but its drawn face (humanoid_face.gd) knows every QWC emotion.
const HUMANOID := "humanoid"
const HUMANOID_EMOTIONS := QWC_EMOTIONS

## "flagged": wears a server-sent flag texture on its Base mesh.
const TYPES := {
	CLASSIC: {
		"scene": "res://assets/entities/countryball/countryball.tscn",
		"emotions": CLASSIC_EMOTIONS,
		"flagged": false,
	},
	ONESIDE: {
		"scene": "res://assets/entities/countryball/countryballoneside.tscn",
		"emotions": CLASSIC_EMOTIONS,
		"flagged": true,
	},
	QWC: {
		"scene": "res://assets/entities/countryball_quincyform/countryball.tscn",
		"emotions": QWC_EMOTIONS,
		"flagged": true,
	},
}

## Subtypes for "/countryball <flag> [subtype]"; empty means the one-sided ball.
const SUBTYPE_ALIASES := {
	"": ONESIDE,
	"classic": ONESIDE,
	"default": ONESIDE,
	"oneside": ONESIDE,
	"qwc": QWC,
	"mqwc": QWC,
	"quincyform": QWC,
}


static func is_countryball(character_type: String) -> bool:
	return TYPES.has(character_type)


static func wears_flag(character_type: String) -> bool:
	return TYPES.get(character_type, {}).get("flagged", false)


## Returns "" for an unrecognised subtype so callers can report it.
static func resolve_subtype(subtype_arg: String) -> String:
	return SUBTYPE_ALIASES.get(subtype_arg.strip_edges().to_lower(), "")


static func scene_path(character_type: String) -> String:
	return TYPES.get(character_type, {}).get("scene", "")


## The humanoid counts as one.
static func emotions_for(character_type: String) -> Array:
	if character_type == HUMANOID:
		return HUMANOID_EMOTIONS
	return TYPES.get(character_type, {}).get("emotions", [])


static func supports_emotion(character_type: String, emotion: String) -> bool:
	return emotions_for(character_type).has(emotion.strip_edges().to_lower())


static func all_emotions() -> Array:
	var names := []
	for character_type in TYPES:
		for emotion in TYPES[character_type]["emotions"]:
			if not names.has(emotion):
				names.append(emotion)
	return names


## Aliases collapsed to one per type.
static func subtype_names() -> Array:
	return ["classic", "qwc"]
