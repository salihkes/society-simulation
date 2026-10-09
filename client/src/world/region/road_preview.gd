extends "res://src/world/region/travel_preview.gd"
## Preview of the baked road corridor on its own terrain bake, with keys to jump between stations.

const BakeLoader = preload("res://src/world/region/road_bake_loader.gd")

var _manifest: Dictionary = {}
var _station := 0


func _enter_tree() -> void:
	_manifest = BakeLoader.read_bake()
	if not _manifest.is_empty():
		# Runs before the terrain child enters and loads its data_dir.
		$CityTerrain.data_dir = BakeLoader.ROAD_MANIFEST.get_base_dir().path_join(str(_manifest.terrain_dir))
	else:
		$CountryRoads.process_mode = Node.PROCESS_MODE_DISABLED


func _ready() -> void:
	super._ready()
	if _manifest.is_empty():
		label.text = "Road data missing: run tools/bake/regionforge/build_roads.py"
		return
	speed = 120
	for port: Dictionary in _manifest.ports:
		var marker := Marker3D.new()
		marker.name = str(port.id)
		marker.position = Vector3(port.position[0], port.position[1], port.position[2])
		marker.set_meta("provisional", true)
		add_child(marker)
		var title := Label3D.new()
		title.text = str(port.id).replace("_", " ") + "\nPROVISIONAL EXIT"
		title.position.y = 30
		title.pixel_size = 0.15
		title.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		marker.add_child(title)
	_jump(0)


func _unhandled_input(event: InputEvent) -> void:
	super._unhandled_input(event)
	if event is InputEventKey and event.pressed and not event.echo and not _manifest.is_empty():
		match event.keycode:
			KEY_HOME: _jump(0)
			KEY_END: _jump(_manifest.inspection_stations.size() - 1)
			KEY_PAGEUP: _jump(_station + 8)
			KEY_PAGEDOWN: _jump(_station - 8)


func _jump(index: int) -> void:
	var samples: Array = _manifest.inspection_stations
	_station = clampi(index, 0, samples.size() - 1)
	var p: Array = samples[_station]
	var q: Array = samples[mini(_station + 1, samples.size() - 1)]
	var target := Vector3(p[0], p[1], p[2])
	var direction := (Vector3(q[0], q[1], q[2]) - target).normalized()
	if direction.length_squared() < 0.1:
		direction = Vector3.FORWARD
	camera.position = target - direction * 170 + Vector3.UP * 95
	camera.look_at(target + direction * 100)


func _process(delta: float) -> void:
	super._process(delta)
	if _manifest.is_empty():
		return
	var stats: Dictionary = $CountryRoads.get_streaming_stats()
	# The base HUD text only refreshes every 0.25 s; strip the previous suffix.
	label.text = label.text.split("\nRoad corridor")[0] + ("\nRoad corridor · %d chunks · %d colliders · %d triangles"
		+ "\nHome/End: cities · PgUp/PgDn: along route"
		+ "\nProvisional exits · source tunnels shown as OPEN CUTTINGS") % [stats.chunks, stats.colliders, stats.triangles]
