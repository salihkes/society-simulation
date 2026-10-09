@tool
class_name PlanetBaker
## Bakes a planet's height field: the base field plus every "planet_height_stampers" node's stamps.


## Null without a base field. Notifies every "planet_bake_listeners" node under the planet root.
static func bake(terrain: PlanetTerrain) -> PlanetHeightField:
	var base := terrain.get_base_field()
	if base == null:
		return null
	var field := base.duplicate_field()
	var planet_root := terrain.get_parent()
	if planet_root == null or not terrain.is_inside_tree():
		return field
	var stamps: Array = []
	for node in terrain.get_tree().get_nodes_in_group("planet_height_stampers"):
		if not under_planet(node, planet_root):
			continue
		if node.has_method("get_height_stamps"):
			stamps.append_array(node.get_height_stamps(terrain))
	if not stamps.is_empty():
		_apply_stamps(field, stamps, terrain.data.radius)
	for node in terrain.get_tree().get_nodes_in_group("planet_bake_listeners"):
		if under_planet(node, planet_root) and node.has_method("on_field_baked"):
			node.on_field_baked(terrain, field)
	return field


static func under_planet(node: Node, planet_root: Node) -> bool:
	var n := node
	while n != null:
		if n == planet_root:
			return true
		n = n.get_parent()
	return false


## A stamp is {dir, target, half, falloff, planar?}: full pull within half metres, fading over falloff; strongest weight wins.
static func _apply_stamps(field: PlanetHeightField, stamps: Array, radius: float) -> void:
	var res := field.resolution
	var wbufs: Array[PackedFloat32Array] = []
	var tbufs: Array[PackedFloat32Array] = []
	for i in CubeSphere.FACE_COUNT:
		var w := PackedFloat32Array()
		w.resize(res * res)
		w.fill(0.0)
		var t := PackedFloat32Array()
		t.resize(res * res)
		wbufs.append(w)
		tbufs.append(t)
	for stamp in stamps:
		_rasterize_stamp(stamp, res, radius, wbufs, tbufs)
	for face in CubeSphere.FACE_COUNT:
		var arr := field.faces[face]
		var wbuf := wbufs[face]
		var tbuf := tbufs[face]
		for idx in res * res:
			var w := wbuf[idx]
			if w > 0.0:
				arr[idx] = lerpf(arr[idx], tbuf[idx], w)


static func _rasterize_stamp(stamp: Dictionary, res: int, radius: float,
		wbufs: Array[PackedFloat32Array], tbufs: Array[PackedFloat32Array]) -> void:
	var dir: Vector3 = stamp["dir"]
	var fall_m: float = maxf(stamp["falloff"], 0.01)
	var outer_ang := (float(stamp["half"]) + fall_m) / radius
	var texel_ang := (PI * 0.5) / res
	# Near a face edge one radian spans up to about twice the texels.
	var win := int(ceil(outer_ang / texel_ang * 1.8)) + 2
	for face in CubeSphere.FACE_COUNT:
		var uv := CubeSphere.dir_uv_on_face(face, dir)
		if uv.is_empty():
			continue
		var cx := int(round(uv[0] * (res - 1)))
		var cy := int(round(uv[1] * (res - 1)))
		if cx < -win or cy < -win or cx >= res + win or cy >= res + win:
			continue
		var rect := Rect2i(Vector2i(maxi(cx - win, 0), maxi(cy - win, 0)), Vector2i.ZERO)
		rect.end = Vector2i(mini(cx + win + 1, res), mini(cy + win + 1, res))
		_rasterize_on_face(stamp, face, rect, res, radius, wbufs[face], tbufs[face])


## Planar stamps aim at the tangent plane through (radius + target) * dir, not a constant elevation.
static func _rasterize_on_face(stamp: Dictionary, face: int, rect: Rect2i, res: int,
		radius: float, wbuf: PackedFloat32Array, tbuf: PackedFloat32Array) -> void:
	var dir: Vector3 = stamp["dir"]
	var target: float = stamp["target"]
	var half_m: float = stamp["half"]
	var fall_m: float = maxf(stamp["falloff"], 0.01)
	var planar: bool = stamp.get("planar", false)
	var plane_r := radius + target
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var d := CubeSphere.face_uv_to_dir(face, float(x) / (res - 1), float(y) / (res - 1))
			var dist_m := CubeSphere.angle_between(d, dir) * radius
			if dist_m > half_m + fall_m:
				continue
			var w := 1.0 if dist_m <= half_m else smoothstep(1.0, 0.0, (dist_m - half_m) / fall_m)
			var idx := y * res + x
			if w <= wbuf[idx]:
				continue
			wbuf[idx] = w
			if planar:
				tbuf[idx] = plane_r / maxf(d.dot(dir), 0.7) - radius
			else:
				tbuf[idx] = target
