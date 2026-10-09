class_name NavCache
extends RefCounted
## The school's sampled floors on disk: the building's fingerprint, and reading and writing user://navcache.

# GAME_NAV_NOCACHE/_DEBUG/_FINGERPRINT_ONLY=1 env knobs; a change too thin for a probe ray needs user://navcache deleted.

const NavScript := preload("res://src/life/interior_nav.gd")
const FORMAT := 1  # bump when what the cache holds changes shape
const DIR := "user://navcache"
const BUNDLED_DIR := "res://assets/entities/ambient/navcache"
const PROBE_STRIDE := 4  # the fingerprint's ray grid: every 4th cell, at every sampling height

var path := ""
var loaded := false
var _nav: BuildingNav = null  # its tuning constants and its frames
var _world: Node3D = null


func _init(nav: BuildingNav, world: Node3D) -> void:
	_nav = nav
	_world = world


static func file_name(key: String) -> String:
	return "school_%s.nav" % key.substr(0, 20)


## Await it.
func key(floors: Array, heights: Array, entries: Array, seeds: Array, landings: Array, footprint: AABB,
		lowest: float, top: float, exclude: Array) -> String:
	var parts := PackedStringArray()
	parts.append("format=%d godot=%s" % [FORMAT, str(Engine.get_version_info().get("string", ""))])
	parts.append("const=%s" % str([_nav.CELL, _nav.STEP, _nav.HEADROOM, _nav.LAYER_GAP, _nav.FIRST_LAYER_ABOVE,
		_nav.DEDUPE, _nav.DOOR_REACH, _nav.DOOR_COST, NavScript.MASK, PROBE_STRIDE]))
	parts.append("floors=%s heights=%s footprint=%s" % [str(floors), str(heights), str(footprint)])
	for sp in seeds:
		parts.append("seed=" + _v(sp))
	for lp in landings:
		parts.append("landing=" + _v(lp))
	for e in entries:
		parts.append("entry=" + _v(e))
	var t_shapes := Time.get_ticks_msec()
	var shapes: String = await _geometry_descriptors(footprint, lowest - 15.0, top + 15.0)
	var t_probe := Time.get_ticks_msec()
	var probe: String = await _probe(footprint, heights, exclude)
	if OS.get_environment("GAME_NAV_DEBUG") == "1":
		print("[BuildingNav] fingerprint parts: setup %s, shapes %s (%d ms), probe %s (%d ms)" %
			["\n".join(parts).md5_text().substr(0, 8), shapes.md5_text().substr(0, 8), t_probe - t_shapes,
			probe.md5_text().substr(0, 8), Time.get_ticks_msec() - t_probe])
	parts.append(shapes)
	parts.append(probe)
	return "\n".join(parts).md5_text()


static func _v(p: Vector3) -> String:
	return str(p.snapped(Vector3(0.01, 0.01, 0.01)))


static func _basis(b: Basis) -> String:
	return "%.3f %.3f %.3f / %.3f %.3f %.3f / %.3f %.3f %.3f" % [b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z,
		b.z.x, b.z.y, b.z.z]


## Await it. Includes any large trimesh wherever it stands.
func _geometry_descriptors(footprint: AABB, y0: float, y1: float) -> String:
	var grown := footprint.grow(14.0)
	var inv := _world.global_transform.affine_inverse()
	var lines := PackedStringArray()
	var frame_start := Time.get_ticks_msec()
	for cs in _world.find_children("*", "CollisionShape3D", true, false):
		if Time.get_ticks_msec() - frame_start > float(_nav.BUDGET_MS) * 2.0:
			await _nav.get_tree().process_frame
			frame_start = Time.get_ticks_msec()
		var body := cs.get_parent()
		if not (body is StaticBody3D) or body is AnimatableBody3D or (body.collision_layer & NavScript.MASK) == 0:
			continue  # only what the rays meet and what stays put
		var shape: Shape3D = cs.shape
		var faces := 0
		if shape is ConcavePolygonShape3D:
			faces = shape.get_faces().size()
		var xf: Transform3D = inv * cs.global_transform
		var o := xf.origin
		var inside := o.x >= grown.position.x and o.x <= grown.end.x and o.z >= grown.position.z \
			and o.z <= grown.end.z and o.y >= y0 and o.y <= y1
		if not inside and faces < 30000:
			continue
		lines.append("%s|%s|%s|%s|%s" % [str(cs.get_path()), _v(o), _basis(xf.basis), _shape_desc(shape, faces),
			str(cs.disabled)])
	lines.sort()
	return "shapes=%d\n%s" % [lines.size(), "\n".join(lines)]


static func _shape_desc(shape: Shape3D, faces: int) -> String:
	if shape == null:
		return "none"
	var desc := shape.get_class()
	if shape.resource_path != "":
		desc += ":" + shape.resource_path
	if shape is ConcavePolygonShape3D:
		desc += ":%d" % faces
	elif shape is ConvexPolygonShape3D:
		desc += ":%d" % shape.points.size()
	elif shape is BoxShape3D:
		desc += ":" + str(shape.size)
	elif shape is SphereShape3D:
		desc += ":%s" % shape.radius
	elif shape is CapsuleShape3D or shape is CylinderShape3D:
		desc += ":%s/%s" % [shape.radius, shape.height]
	return desc


## Await it. What the physics actually answers under the school.
func _probe(footprint: AABB, heights: Array, exclude: Array) -> String:
	var space := _world.get_world_3d().direct_space_state
	var grown := footprint.grow(12.0)  # as interior_nav._prepare() lays the grid
	var cell := float(_nav.CELL)
	var cols := int(ceil(grown.size.x / cell)) + 1
	var rows := int(ceil(grown.size.z / cell)) + 1
	var bottom := grown.position.y - 12.0
	var out := PackedFloat32Array()
	var frame_start := Time.get_ticks_msec()
	for h in heights:
		for r in range(0, rows, PROBE_STRIDE):
			_probe_row(space, grown, cols, r, float(h), bottom, exclude, out)
			if Time.get_ticks_msec() - frame_start > float(_nav.BUDGET_MS) * 2.0:
				await _nav.get_tree().process_frame
				frame_start = Time.get_ticks_msec()
				space = _world.get_world_3d().direct_space_state
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(out.to_byte_array())
	return "probe=%d:%s" % [out.size(), ctx.finish().hex_encode()]


## -1e9 for none.
func _probe_row(space: PhysicsDirectSpaceState3D, grown: AABB, cols: int, r: int, h: float, bottom: float,
		exclude: Array, out: PackedFloat32Array) -> void:
	var cell := float(_nav.CELL)
	for c in range(0, cols, PROBE_STRIDE):
		var x := grown.position.x + (float(c) + 0.5) * cell
		var z := grown.position.z + (float(r) + 0.5) * cell
		var q := PhysicsRayQueryParameters3D.create(_world.to_global(Vector3(x, h, z)),
			_world.to_global(Vector3(x, bottom, z)), NavScript.MASK, exclude)
		q.hit_from_inside = true
		var hit := space.intersect_ray(q)
		out.append(snappedf(_world.to_local(hit.position).y, 0.05) if not hit.is_empty() else -1e9)


## From user:// or the bundled res:// copy: the floors with their layers rebuilt, or {} when neither fits.
func read(key: String, n_landings: int) -> Dictionary:
	for dir in [DIR, BUNDLED_DIR]:
		var p: String = dir.path_join(file_name(key))
		if not FileAccess.file_exists(p):
			continue
		var f := FileAccess.open_compressed(p, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
		if f == null:
			continue
		var d = f.get_var(false)
		f.close()
		if not (d is Dictionary) or int(d.get("format", -1)) != FORMAT or str(d.get("key", "")) != key:
			print("[BuildingNav] %s is from another build of the sampler; sampling again" % p)
			continue
		var graph := _graph_from(d, n_landings)
		if graph.is_empty():
			print("[BuildingNav] %s does not fit this building; sampling again" % p)
			continue
		path = p
		loaded = true
		return graph
	return {}


## {} when its sizes do not fit this building.
func _graph_from(d: Dictionary, n_landings: int) -> Dictionary:
	var heights = d.get("heights")
	var layers = d.get("layers")
	if not (heights is Array) or not (layers is Array) or layers.is_empty() or layers.size() != heights.size():
		return {}
	var cols := int(d.get("cols", 0))
	var rows := int(d.get("rows", 0))
	var per := cols * rows
	if per <= 0:
		return {}
	var built: Array = []
	for ld in layers:
		var g = _layer_from(ld, cols, rows)
		if g == null:
			return {}
		built.append(g)
	var n := built.size() * per
	var graph := {"heights": heights, "cols": cols, "rows": rows, "layers": built,
		"column": d.get("column", []) as Array,
		"comp": d.get("comp", PackedInt32Array()) as PackedInt32Array,
		"landing_nodes": d.get("landing_nodes", []) as Array,
		"door_edges": d.get("door_edges", {}) as Dictionary,
		"dense": d.get("dense", PackedInt32Array()) as PackedInt32Array,
		"dense_n": int(d.get("dense_n", 0)),
		"dist": d.get("dist", []) as Array,
		"parent": d.get("parent", []) as Array,
		"pkind": d.get("pkind", []) as Array,
		"bounds": d.get("bounds", AABB()) as AABB}
	if graph.column.size() != per or graph.comp.size() != n or graph.dense.size() != n:
		return {}
	if graph.landing_nodes.size() != n_landings or graph.dist.size() != n_landings \
			or graph.parent.size() != n_landings or graph.pkind.size() != n_landings:
		return {}
	return graph


## Null when it does not fit the grid.
func _layer_from(ld, cols: int, rows: int):
	if not (ld is Dictionary):
		return null
	var g = NavScript.new()
	g.cell_size = _nav.CELL
	g.headroom = _nav.HEADROOM
	g.erode_cells = 0
	g.origin = ld.get("origin", Vector3.INF)
	g.floor_y = float(ld.get("floor_y", 0.0))
	g.cols = int(ld.get("cols", 0))
	g.rows = int(ld.get("rows", 0))
	g.built = bool(ld.get("built", false))
	g.floor_cells = int(ld.get("floor_cells", 0))
	g._cells = ld.get("cells", PackedByteArray()) as PackedByteArray
	g._heights = ld.get("hts", PackedFloat32Array()) as PackedFloat32Array
	var per := cols * rows
	if g.cols != cols or g.rows != rows or g._cells.size() != per or g._heights.size() != per:
		return null
	return g


## graph holds the same keys read() returns.
func write(key: String, graph: Dictionary) -> void:
	var d := _file_data(key, graph)
	var fname := file_name(key)
	var dirs: Array = [DIR]
	if OS.has_feature("editor") and OS.get_environment("GAME_PUBLISH_NAV") == "1":
		dirs.append(BUNDLED_DIR)
	for dir in dirs:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
		_prune_dir(dir, fname)
		var p: String = dir.path_join(fname)
		var f := FileAccess.open_compressed(p, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
		if f == null:
			print("[BuildingNav] could not write %s (%s)" % [p, error_string(FileAccess.get_open_error())])
			continue
		f.store_var(d, false)
		f.close()
		path = p
		var rf := FileAccess.open(p, FileAccess.READ)
		var kb: int = int(rf.get_length() / 1024) if rf != null else 0
		print("[BuildingNav] floors cached: %s (%d KB); next launch reads them back" % [p, kb])


func _file_data(key: String, graph: Dictionary) -> Dictionary:
	var layers: Array = []
	for g in graph.layers:
		layers.append({"origin": g.origin, "floor_y": g.floor_y, "cols": g.cols, "rows": g.rows, "built": g.built,
			"floor_cells": g.floor_cells, "cells": g._cells, "hts": g._heights})
	return {"format": FORMAT, "key": key, "heights": graph.heights, "cols": graph.cols, "rows": graph.rows,
		"layers": layers, "column": graph.column, "comp": graph.comp, "landing_nodes": graph.landing_nodes,
		"door_edges": graph.door_edges, "dense": graph.dense, "dense_n": graph.dense_n, "dist": graph.dist,
		"parent": graph.parent, "pkind": graph.pkind, "bounds": graph.bounds}


## Keeps the newest two: an editor and a test may sample the same building under two names.
func _prune_dir(dir: String, fname: String) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	var olds: Array = []
	for old in da.get_files():
		if old.begins_with("school_") and old.ends_with(".nav") and old != fname:
			olds.append([FileAccess.get_modified_time(dir.path_join(old)), old])
	olds.sort()
	while olds.size() > 2:
		da.remove(str(olds.pop_front()[1]))
