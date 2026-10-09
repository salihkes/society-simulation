extends RefCounted

## One workspace's ambient layout: walk zones and directed traffic lanes, workspace-local.

## Closed polygons (PackedVector3Array), last point not repeated.
var zones: Array = []
## Directed polylines (PackedVector3Array).
var lanes: Array = []


static func _dir_path() -> String:
	return "user://ambient_layouts"


static func file_path_for(workspace_name: String) -> String:
	return _dir_path() + "/" + workspace_name + ".json"


static func bundled_path_for(workspace_name: String) -> String:
	return "res://assets/entities/ambient/layouts/" + workspace_name + ".json"


## user:// override first, bundled res:// default second.
func load_from(workspace_name: String) -> void:
	var path := file_path_for(workspace_name)
	if not FileAccess.file_exists(path):
		path = bundled_path_for(workspace_name)
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) == TYPE_DICTIONARY:
		_from_dict(parsed)


## False when the file cannot open.
func save_for(workspace_name: String) -> bool:
	DirAccess.make_dir_recursive_absolute(_dir_path())
	var f := FileAccess.open(file_path_for(workspace_name), FileAccess.WRITE)
	if f == null:
		push_warning("[AmbientLayout] Cannot write " + file_path_for(workspace_name))
		return false
	f.store_string(JSON.stringify(to_dict(), "\t"))
	f.close()
	return true


func to_dict() -> Dictionary:
	var packed_zones := []
	for z in zones:
		packed_zones.append(_pack_points(z))
	var packed_lanes := []
	for l in lanes:
		packed_lanes.append(_pack_points(l))
	return {
		"version": 1,
		"zones": packed_zones,
		"lanes": packed_lanes,
	}


func _from_dict(d: Dictionary) -> void:
	zones = []
	lanes = []
	for raw in d.get("zones", []):
		var pts := _unpack_points(raw)
		if pts.size() >= 3:
			zones.append(pts)
	for raw in d.get("lanes", []):
		var pts := _unpack_points(raw)
		if pts.size() >= 2:
			lanes.append(pts)


static func _pack_points(points: PackedVector3Array) -> Array:
	var out := []
	for p in points:
		out.append([snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)])
	return out


static func _unpack_points(raw) -> PackedVector3Array:
	var pts := PackedVector3Array()
	if typeof(raw) == TYPE_DICTIONARY:
		raw = raw.get("points", [])
	if typeof(raw) != TYPE_ARRAY:
		return pts
	for entry in raw:
		if typeof(entry) == TYPE_ARRAY and entry.size() >= 3:
			pts.append(Vector3(float(entry[0]), float(entry[1]), float(entry[2])))
	return pts
