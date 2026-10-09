@tool
class_name PlanetRoad
extends Node3D
## One planet road: a spline of planet-local directions and elevations, stamped into terrain or bridged.

## Metres between spline samples.
const SAMPLE_STEP := 2.0

@export var profile: RoadProfile
## Planet-local.
@export var point_dirs: PackedVector3Array = PackedVector3Array()
## Metres above sea level.
@export var point_elevs: PackedFloat32Array = PackedFloat32Array()

var _mesh_instance: MeshInstance3D


func _ready() -> void:
	if profile == null:
		profile = RoadProfile.make_default()


func point_count() -> int:
	return mini(point_dirs.size(), point_elevs.size())


func add_point(dir: Vector3, elev: float) -> void:
	point_dirs.append(dir.normalized())
	point_elevs.append(elev)


func remove_last_point() -> void:
	if point_count() > 0:
		point_dirs.remove_at(point_dirs.size() - 1)
		point_elevs.remove_at(point_elevs.size() - 1)


func snap_to_ground(terrain: PlanetTerrain, clearance := 0.3) -> void:
	for i in point_count():
		point_elevs[i] = terrain.base_height_at_dir(point_dirs[i]) + clearance


## Array of {dir, elev, dist, tangent, lateral}; tangent and lateral lie in the tangent plane at dir.
func sample_spline(radius: float) -> Array:
	var n := point_count()
	if n < 2:
		return []
	var out: Array = []
	var total := 0.0
	for seg in n - 1:
		var p0 := point_dirs[maxi(seg - 1, 0)]
		var p1 := point_dirs[seg]
		var p2 := point_dirs[seg + 1]
		var p3 := point_dirs[mini(seg + 2, n - 1)]
		var e0 := point_elevs[maxi(seg - 1, 0)]
		var e1 := point_elevs[seg]
		var e2 := point_elevs[seg + 1]
		var e3 := point_elevs[mini(seg + 2, n - 1)]
		var seg_len := CubeSphere.angle_between(p1, p2) * radius
		var steps := maxi(int(ceil(seg_len / SAMPLE_STEP)), 1)
		for s in steps:
			var t := float(s) / steps
			var d := CubeSphere.catmull_rom_dir(p0, p1, p2, p3, t)
			var e := CubeSphere.catmull_rom_f(e0, e1, e2, e3, t)
			out.append({"dir": d, "elev": e, "dist": total})
			total += seg_len / steps
	out.append({"dir": point_dirs[n - 1], "elev": point_elevs[n - 1], "dist": total})
	_add_frames(out)
	return out


static func _add_frames(out: Array) -> void:
	for i in out.size():
		var d: Vector3 = out[i]["dir"]
		var prev: Vector3 = out[maxi(i - 1, 0)]["dir"]
		var next: Vector3 = out[mini(i + 1, out.size() - 1)]["dir"]
		var tan: Vector3 = next - prev
		tan = (tan - d * tan.dot(d))
		if tan.length_squared() < 1.0e-12:
			tan = CubeSphere.tangent_frame(d)[0]
		tan = tan.normalized()
		out[i]["tangent"] = tan
		out[i]["lateral"] = d.cross(tan).normalized()


## Bridge spans leave the terrain alone.
func get_height_stamps(terrain: PlanetTerrain) -> Array:
	if profile == null or point_count() < 2 or terrain.data == null:
		return []
	var samples := sample_spline(terrain.data.radius)
	var stamps: Array = []
	for s in samples:
		var ground: float = terrain.base_height_at_dir(s["dir"])
		if s["elev"] - ground > profile.bridge_threshold:
			continue
		stamps.append({
			"dir": s["dir"],
			"target": s["elev"] - profile.embed_depth,
			"half": profile.width * 0.5 + 0.3,
			"falloff": profile.shoulder,
		})
	return stamps


## Bridge piers reach down to the baked field. Called through PlanetRoadNetwork.on_field_baked.
func rebuild_mesh(terrain: PlanetTerrain, field: PlanetHeightField) -> void:
	if _mesh_instance == null or not is_instance_valid(_mesh_instance):
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "deck"
		add_child(_mesh_instance)
	if profile == null or point_count() < 2 or terrain.data == null:
		_mesh_instance.mesh = null
		return
	var r := terrain.data.radius
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_sweep_deck(st, sample_spline(r), r, terrain, field)
	st.index()
	var mesh := st.commit()
	_mesh_instance.mesh = mesh
	_rebuild_deck_collision(mesh)
	if profile.deck_material:
		_mesh_instance.material_override = profile.deck_material
	else:
		var m := StandardMaterial3D.new()
		m.albedo_color = profile.deck_color
		m.roughness = 0.95
		# Decks, sides and piers are thin walls seen from both sides.
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_mesh_instance.material_override = m


## A sample is a bridge when it clears the unstamped terrain by more than bridge_threshold.
func _sweep_deck(st: SurfaceTool, samples: Array, r: float, terrain: PlanetTerrain,
		field: PlanetHeightField) -> void:
	var half := profile.width * 0.5
	var prev_l := Vector3.ZERO
	var prev_rt := Vector3.ZERO
	var prev_bridge := false
	var last_pier_dist := -1.0e9
	for i in samples.size():
		var s: Dictionary = samples[i]
		var d: Vector3 = s["dir"]
		var lat: Vector3 = s["lateral"]
		var elev: float = s["elev"]
		var ground: float = field.sample_dir(d)
		var bridge: bool = elev - terrain.base_height_at_dir(d) > profile.bridge_threshold
		var center: Vector3 = d * (r + elev)
		var lv: Vector3 = center - lat * half
		var rv: Vector3 = center + lat * half
		var uv_y: float = s["dist"] / profile.uv_length
		if i > 0:
			_quad(st, prev_l, prev_rt, rv, lv, d, uv_y)
			if bridge or prev_bridge:
				_bridge_sides(st, prev_l, prev_rt, lv, rv, lat, d, uv_y)
		if bridge and s["dist"] - last_pier_dist >= profile.pier_interval:
			last_pier_dist = s["dist"]
			_pier(st, d, r, elev - profile.deck_thickness, ground)
		prev_l = lv
		prev_rt = rv
		prev_bridge = bridge


func _bridge_sides(st: SurfaceTool, prev_l: Vector3, prev_rt: Vector3, lv: Vector3, rv: Vector3,
		lat: Vector3, d: Vector3, uv_y: float) -> void:
	var thick: float = profile.deck_thickness
	var pl2: Vector3 = prev_l - prev_l.normalized() * thick
	var pr2: Vector3 = prev_rt - prev_rt.normalized() * thick
	var l2: Vector3 = lv - lv.normalized() * thick
	var r2: Vector3 = rv - rv.normalized() * thick
	_quad(st, pl2, prev_l, lv, l2, -lat, uv_y)
	_quad(st, prev_rt, pr2, r2, rv, lat, uv_y)
	_quad(st, pr2, pl2, l2, r2, -d, uv_y)


## Not built in the editor.
func _rebuild_deck_collision(mesh: ArrayMesh) -> void:
	if Engine.is_editor_hint():
		return
	var body: StaticBody3D = get_node_or_null("deck_col")
	if body == null:
		body = StaticBody3D.new()
		body.name = "deck_col"
		var cs := CollisionShape3D.new()
		cs.name = "shape"
		body.add_child(cs)
		add_child(body)
	var shape: CollisionShape3D = body.get_node("shape")
	shape.shape = mesh.create_trimesh_shape()


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		normal: Vector3, uv_y: float) -> void:
	st.set_normal(normal)
	_vertex(st, a, 0.0, uv_y)
	_vertex(st, d, 0.0, uv_y)
	_vertex(st, c, 1.0, uv_y)
	st.set_normal(normal)
	_vertex(st, a, 0.0, uv_y)
	_vertex(st, c, 1.0, uv_y)
	_vertex(st, b, 1.0, uv_y)


static func _vertex(st: SurfaceTool, v: Vector3, u: float, uv_y: float) -> void:
	st.set_uv(Vector2(u, uv_y))
	st.add_vertex(v)


## From the deck underside to 2 m into the ground.
func _pier(st: SurfaceTool, d: Vector3, radius: float, top_elev: float, ground_elev: float) -> void:
	if top_elev <= ground_elev:
		return
	var frame := CubeSphere.tangent_frame(d)
	var top: Vector3 = d * (radius + top_elev)
	var bottom: Vector3 = d * (radius + ground_elev - 2.0)
	var pr := profile.pier_radius
	var ring_top: Array[Vector3] = []
	var ring_bot: Array[Vector3] = []
	for k in 6:
		var a := TAU * k / 6.0
		var off: Vector3 = (frame[0] * cos(a) + frame[1] * sin(a)) * pr
		ring_top.append(top + off)
		ring_bot.append(bottom + off)
	for k in 6:
		var k2 := (k + 1) % 6
		var n := (ring_top[k] - top).normalized()
		_quad(st, ring_bot[k], ring_bot[k2], ring_top[k2], ring_top[k], n, 0.0)
