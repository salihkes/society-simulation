@tool
extends Node
## Points CityTerrain at the baked road terrain, or disables CountryRoads when the bake is missing or stale.

const ROAD_MANIFEST := "res://assets/world/region/data/roads/manifest.json"
const BASE_MANIFEST := "res://assets/world/region/data/meta.json"


## {} when the manifest is missing, invalid, or baked from a different country terrain.
static func read_bake() -> Dictionary:
	var file := FileAccess.open(ROAD_MANIFEST, FileAccess.READ)
	if file == null:
		push_error("Road bake missing. Run tools/bake/regionforge/build_roads.py")
		return {}
	var data: Variant = JSON.parse_string(file.get_as_text())
	if not data is Dictionary or data.get("format_version", 0) != 1:
		push_error("Invalid road bake")
		return {}
	if data.get("terrain_signature", "") != FileAccess.get_sha256(BASE_MANIFEST):
		push_error("Country terrain changed. Rebuild roads before using this preview.")
		return {}
	return data


func _enter_tree() -> void:
	var data := read_bake()
	if data.is_empty():
		var roads := get_node_or_null("../CountryRoads")
		if roads != null:
			roads.process_mode = Node.PROCESS_MODE_DISABLED
		return
	var terrain := get_node("../CityTerrain")
	terrain.data_dir = ROAD_MANIFEST.get_base_dir().path_join(str(data.terrain_dir))
