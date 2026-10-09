@tool
extends Node3D
## Editor tool: city road exit markers, loaded from and saved to the road bake's exit JSON.

@export_tool_button("Load saved exits") var load_exits = _load_exits
@export_tool_button("Save exits for road bake") var save_exits = _save_exits


func _path() -> String:
	return ProjectSettings.globalize_path("res://").path_join("../tools/bake/regionforge/roads/city_exits.json").simplify_path()


func _ready() -> void:
	if Engine.is_editor_hint():
		_load_exits()


func _load_exits() -> void:
	var file := FileAccess.open(_path(), FileAccess.READ)
	if file == null:
		push_error("City exit JSON is missing: " + _path())
		return
	var data: Variant = JSON.parse_string(file.get_as_text())
	if not data is Dictionary:
		return
	for port: Dictionary in data.get("ports", []):
		var marker := find_child(str(port.id), true, false) as Marker3D
		if marker == null:
			continue
		marker.position = Vector3(port.position[0], port.position[1], port.position[2])
		marker.rotation = Vector3(0, atan2(-float(port.outward_xz[0]), -float(port.outward_xz[1])), 0)
		marker.set_meta("width", float(port.width))
		marker.set_meta("grade", float(port.grade))
		marker.set_meta("city", str(port.city))


## Refuses when a marker is invalid or the file is unreadable.
func _save_exits() -> void:
	var ports: Variant = _marker_ports()
	if ports == null:
		return
	if ports.size() != 2:
		push_error("Expected both prototype exit markers")
		return
	var existing: Variant = JSON.parse_string(FileAccess.get_file_as_string(_path()))
	if not existing is Dictionary:
		push_error("Cannot read existing exits; refusing to overwrite them")
		return
	var merged: Dictionary = {}
	for port: Dictionary in existing.get("ports", []):
		merged[str(port.id)] = port
	for port: Dictionary in ports:
		merged[str(port.id)] = port
	existing["ports"] = merged.values()
	var temporary := _path() + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write exit JSON: " + _path())
		return
	file.store_string(JSON.stringify(existing, "  ") + "\n")
	file.close()
	if DirAccess.rename_absolute(temporary, _path()) != OK:
		push_error("Could not publish saved road exits")
		return
	print("Saved road exits. Rebuild with tools/bake/regionforge/build_roads.py --offline")


## null after an error.
func _marker_ports() -> Variant:
	var ports: Array = []
	for node in find_children("*", "Marker3D", true, false):
		var marker := node as Marker3D
		if not marker.has_meta("city"):
			continue
		var outward := -marker.basis.z
		var direction := Vector2(outward.x, outward.z).normalized()
		if direction.length() < 0.9 or float(marker.get_meta("width", 0)) <= 0:
			push_error("Exit needs a horizontal direction and positive width")
			return null
		ports.append({"id": str(marker.name), "city": str(marker.get_meta("city")),
			"position": [marker.position.x, marker.position.y, marker.position.z],
			"outward_xz": [direction.x, direction.y], "width": float(marker.get_meta("width")),
			"grade": float(marker.get_meta("grade", 0)), "provisional": true})
	return ports
