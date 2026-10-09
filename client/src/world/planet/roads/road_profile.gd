@tool
class_name RoadProfile
extends Resource
## Cross-section and behaviour of one kind of planet road; world units, about 2.5 per real metre.

const JsonData := preload("res://src/core/json_data.gd")
const DATA_PATH := "res://assets/world/planet/roads/road_profiles.json"

## Kind -> property values for make_default.
static var PRESETS: Dictionary = _presets()

@export var display_name := "Road"
@export var width := 15.0
## Blended terrain on each side of the deck.
@export var shoulder := 10.0
## Terrain is pulled to (road elevation - embed_depth) under the deck.
@export var embed_depth := 0.6
## Clearance over unstamped terrain above which the road is a bridge (no stamping, sides and piers).
@export var bridge_threshold := 10.0
@export var deck_thickness := 2.0
@export var pier_interval := 55.0
@export var pier_radius := 2.5
## Null uses a default asphalt material.
@export var deck_material: Material
@export var deck_color := Color(0.22, 0.22, 0.24)
## Road length per UV repeat.
@export var uv_length := 20.0
## [{scene, interval, side: -1 left / 1 right / 2 both / 0 centre, offset, alternate}]
@export var attachments: Array[Dictionary] = []


## A preset from road_profiles.json; an unknown kind is asphalt.
static func make_default(kind := "asphalt") -> RoadProfile:
	var p := RoadProfile.new()
	var preset: Dictionary = PRESETS.get(kind, PRESETS.get("asphalt", {}))
	for key in preset:
		p.set(key, preset[key])
	return p


static func _presets() -> Dictionary:
	var table := JsonData.read(DATA_PATH)
	for kind in table:
		var c = table[kind].get("deck_color")
		if c is Array:
			table[kind]["deck_color"] = Color(c[0], c[1], c[2])
	return table
