@tool
class_name PlanetRoadNetwork
extends Node3D
## Holds a planet's PlanetRoads: their terrain stamps, decks after each bake and furniture.

const ATTACHMENT_GROUP := "road_attachment"


func _enter_tree() -> void:
	add_to_group("planet_height_stampers")
	add_to_group("planet_bake_listeners")


func roads() -> Array[PlanetRoad]:
	var out: Array[PlanetRoad] = []
	for child in get_children():
		if child is PlanetRoad:
			out.append(child)
	return out


func get_height_stamps(terrain: PlanetTerrain) -> Array:
	var out: Array = []
	for road in roads():
		out.append_array(road.get_height_stamps(terrain))
	return out


func on_field_baked(terrain: PlanetTerrain, field: PlanetHeightField) -> void:
	for road in roads():
		road.rebuild_mesh(terrain, field)
	_respawn_attachments(terrain, field)


## Default profile is asphalt; the road is owned by the edited scene.
func new_road(profile: RoadProfile = null) -> PlanetRoad:
	var road := PlanetRoad.new()
	road.name = "Road%d" % (roads().size() + 1)
	road.profile = profile if profile else RoadProfile.make_default()
	add_child(road)
	if Engine.is_editor_hint() and owner:
		road.owner = owner
	elif Engine.is_editor_hint() and get_tree().edited_scene_root:
		road.owner = get_tree().edited_scene_root
	return road


func _respawn_attachments(terrain: PlanetTerrain, field: PlanetHeightField) -> void:
	for old in get_tree().get_nodes_in_group(ATTACHMENT_GROUP):
		if old.get_parent() == self:
			old.queue_free()
	if terrain.data == null:
		return
	var r: float = terrain.data.radius
	for road in roads():
		var prof := road.profile
		if prof == null or prof.attachments.is_empty():
			continue
		var samples: Array = road.sample_spline(r)
		if samples.is_empty():
			continue
		for att in prof.attachments:
			_spawn_attachment(att, prof, samples, r, field)


## On both-sided attachments, "alternate" swaps sides each time.
func _spawn_attachment(att: Dictionary, prof: RoadProfile, samples: Array, r: float,
		field: PlanetHeightField) -> void:
	var scene_path := str(att.get("scene", ""))
	if scene_path == "" or not ResourceLoader.exists(scene_path):
		return
	var packed: PackedScene = load(scene_path)
	if packed == null:
		return
	var interval := float(att.get("interval", 20.0))
	var side := int(att.get("side", 2))
	var lateral := prof.width * 0.5 + 2.5 + float(att.get("offset", 0.0))
	var next_at := interval * 0.5
	var flip := false
	for s in samples:
		if s["dist"] < next_at:
			continue
		next_at += interval
		var sides: Array = [-1, 1] if side == 2 else [side]
		if side == 2 and interval > 0.0 and att.get("alternate", false):
			sides = [-1 if flip else 1]
			flip = not flip
		for sgn in sides:
			_place(packed.instantiate(), s, lateral * float(sgn), r, field)


## On the ground but never below the road, facing along it.
func _place(inst: Node, s: Dictionary, lateral: float, r: float, field: PlanetHeightField) -> void:
	var d: Vector3 = (s["dir"] + s["lateral"] * (lateral / r)).normalized()
	var h: float = field.sample_dir(d)
	var pos: Vector3 = d * (r + maxf(h, s["elev"]))
	if inst is Node3D:
		var up: Vector3 = d
		var fwd: Vector3 = s["tangent"]
		fwd = (fwd - up * fwd.dot(up)).normalized()
		inst.transform = Transform3D(Basis(up.cross(fwd).normalized(), up, fwd), pos)
	inst.add_to_group(ATTACHMENT_GROUP)
	add_child(inst)
