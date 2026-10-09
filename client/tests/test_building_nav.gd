extends SceneTree
## The school on sampled floors: loads the real world, waits for the school's
## navigation, and asks for a route from the street door to every classroom
## and back down again. Prints the folded floor picture with the door (D),
## the lift landings (L) and the rooms (R) marked. About two minutes.
##   Godot --headless --path client --script res://tests/test_building_nav.gd

const WORLD := "res://assets/scenes/workspace_local.tscn"

var failures := 0


func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("FAIL: " + message)


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	# The first sampler must sample (a cache from an earlier run would make
	# the slice measurement below meaningless); the second one reads back.
	OS.set_environment("GAME_NAV_NOCACHE", "1")
	var world = load(WORLD).instantiate()
	get_root().add_child(world)
	current_scene = world
	var manager = null
	for i in 30:
		await physics_frame
		manager = world.find_child("AmbientManager", true, false)
		if manager != null:
			break
	check(manager != null, "the ambient manager is in the world")
	if manager == null:
		_finish()
		return
	var nav = null
	var waited := 0
	var worst_gap := 0
	var last_ms := Time.get_ticks_msec()
	while waited < 240 * 60:
		await physics_frame
		var now_ms := Time.get_ticks_msec()
		worst_gap = maxi(worst_gap, now_ms - last_ms)
		last_ms = now_ms
		waited += 1
		nav = manager.get("school_nav")
		if nav != null and nav.ready_ok:
			break
	check(nav != null and nav.ready_ok, "the school's navigation becomes ready (%.0f s)" % (waited / 60.0))
	# The world's own loading hitches while the school samples (half a second
	# with the sampler switched off entirely), so the sampler is judged by
	# its own longest slice of work between two yields.
	print("[BuildingNav] longest gap between frames while sampling: %d ms; the sampler's longest work slice: %d ms" % [worst_gap, int(nav.worst_slice_ms)])
	check(int(nav.worst_slice_ms) < 120, "sampling never holds the game for long (longest work slice %d ms)" % int(nav.worst_slice_ms))
	if nav == null or not nav.ready_ok:
		_finish()
		return
	var rooms: Array = []
	for sch in manager.places.schools:
		if sch != null and is_instance_valid(sch):
			rooms.append(sch)
	check(rooms.size() > 0, "the school has rooms to reach (%d)" % rooms.size())
	var door: Vector3 = nav.seam()
	var marks: Array = [[door, "D"]]
	for i in nav._landing_nodes.size():
		if nav._landing_nodes[i] >= 0:
			marks.append([nav.node_pos(nav._landing_nodes[i]), "L"])
	for sch in rooms:
		marks.append([sch.place_pos(), "R"])
	print("[BuildingNav] ---- all layers folded (D door, L lift landings, R rooms) ----")
	print(nav.ascii_all(110, marks))
	check(door != Vector3.INF and nav.covers(door), "the street door is on the sampled floor")
	var comps := {}
	for i in nav._landing_nodes.size():
		var id: int = nav._landing_nodes[i]
		comps["landing %d" % i] = nav._comp[id] if id >= 0 else -1
	var dn: int = nav._node_of(door)
	comps["door"] = nav._comp[dn] if dn >= 0 else -1
	for sch in rooms:
		var id: int = nav._node_of(sch.place_pos())
		comps[sch.key()] = nav._comp[id] if id >= 0 else -1
	print("[BuildingNav] components: %s" % str(comps))
	var reached := 0
	var by_lift := 0
	var t0 := Time.get_ticks_msec()
	for sch in rooms:
		var target: Vector3 = sch.place_pos()
		var r: Dictionary = nav.route(door, target)
		var ok: bool = bool(r.reached)
		if ok:
			reached += 1
		if not r.lifts.is_empty():
			by_lift += 1
		print("[BuildingNav] %-14s at %s: %s, %d waypoints%s%s" % [sch.key(), str(target.round()),
			"reached" if ok else ("NOT reached (%d points)" % r.points.size()), r.points.size(),
			(", lift " + str(r.lifts.values())) if not r.lifts.is_empty() else "",
			(" — " + str(r.get("why", ""))) if r.has("why") else (" (%d expanded%s)" % [int(r.get("expanded", 0)), (", via lift " + str(r.via_lift)) if r.has("via_lift") else ""])])
	var ms := Time.get_ticks_msec() - t0
	# For each disconnected component: where it comes closest to the door's.
	var door_comp: int = nav._comp[dn] if dn >= 0 else -1
	var seen_comps := {}
	for sch in rooms:
		var id: int = nav._node_of(sch.place_pos())
		if id < 0 or nav._comp[id] == door_comp or seen_comps.has(nav._comp[id]):
			continue
		seen_comps[nav._comp[id]] = true
		var near: Dictionary = nav.nearest_between(door_comp, nav._comp[id])
		if near.is_empty():
			print("[BuildingNav] component %d (%s) never comes within 6 cells of the reachable floor" % [nav._comp[id], sch.key()])
		else:
			print("[BuildingNav] component %d (%s, %d cells): closest to the reachable floor at %s vs %s: %.1f cells apart, height difference %.1f" %
				[nav._comp[id], sch.key(), int(near.small_size), str(near.from.round()), str(near.to.round()), float(near.cells), float(near.dh)])
	# For each room not reached: a window of its own layer. 'o' floor in the
	# door's component, '.' floor in the room's own, ':' other floor, '#' a
	# surface that is not floor, ' ' nothing, 'R' the room. Heights of the
	# '#' cells on the row through the room follow, relative to the room.
	for sch in rooms:
		var target: Vector3 = sch.place_pos()
		var id: int = nav._node_of(target)
		if id < 0 or nav._comp[id] == door_comp:
			continue
		var k: int = id / nav._per
		var ci: int = id % nav._per
		var cc: int = ci % nav._cols
		var cr: int = ci / nav._cols
		var g = nav._layers[k]
		var room_h: float = g._heights[ci]
		print("[BuildingNav] ---- %s: layer %d (sampled from %.0f), floor at %.1f, component %d ----" % [sch.key(), k, float(nav._heights[k]), room_h, nav._comp[id]])
		for r in range(cr - 18, cr + 19):
			var line := ""
			for c in range(cc - 40, cc + 41):
				if r < 0 or c < 0 or r >= nav._rows or c >= nav._cols:
					line += " "
					continue
				var i: int = r * nav._cols + c
				var ch := " "
				if r == cr and c == cc:
					ch = "R"
				elif g._cells[i] == 2:
					var comp: int = nav._comp[k * nav._per + i]
					ch = "o" if comp == door_comp else ("." if comp == nav._comp[id] else ":")
				elif g._cells[i] == 1:
					ch = ","
				elif g._heights[i] != -INF:
					var dh: float = g._heights[i] - room_h
					ch = "#" if absf(dh) > 6.0 else ("+" if dh > 0.0 else "-")
				line += ch
			print("[BuildingNav] " + line)
		var hs := ""
		for c in range(cc - 40, cc + 41):
			if c < 0 or c >= nav._cols:
				continue
			var i: int = cr * nav._cols + c
			var hv: float = g._heights[i]
			hs += (" %+.1f" % (hv - room_h)) if hv != -INF else "  ---"
		print("[BuildingNav] row heights: " + hs)
	# Whole-layer pictures for the storeys in question: 'o' the door's
	# component, '.' other routable floor, ',' floor not routable, '#' a
	# surface that is not floor, with the lift landings (L) and rooms (R).
	for k in [5, 6, 7, 8, 9, 10]:
		if k >= nav._layers.size():
			continue
		var g = nav._layers[k]
		print("[BuildingNav] ---- layer %d (sampled from %.0f): %d floor cells ----" % [k, float(nav._heights[k]), g.floor_cells])
		for r in range(0, nav._rows, 2):
			var line := ""
			for c in range(0, nav._cols, 2):
				var i: int = r * nav._cols + c
				var ch := " "
				if g._cells[i] == 2:
					ch = "o" if nav._comp[k * nav._per + i] == door_comp else "."
				elif g._cells[i] == 1:
					ch = ","
				elif g._heights[i] != -INF:
					ch = "#"
				for m in marks:
					var mc: Vector2i = nav._layers[0].cell_of(m[0])
					if mc.x / 2 == c / 2 and mc.y / 2 == r / 2 and absf(m[0].y - float(nav._heights[k])) < 12.0:
						ch = str(m[1])
				line += ch
			print("[BuildingNav] " + line)
	print("[BuildingNav] %d of %d rooms reached from the door (%d via the lift) in %d ms" % [reached, rooms.size(), by_lift, ms])
	check(reached == rooms.size(), "every room is reached from the street door (%d of %d)" % [reached, rooms.size()])
	check(ms < 4000, "routing all rooms is quick (%d ms)" % ms)
	var top = null
	for sch in rooms:
		if top == null or sch.place_pos().y > top.place_pos().y:
			top = sch
	if top != null:
		var back: Dictionary = nav.route(top.place_pos(), door)
		check(bool(back.reached), "the highest room comes back down to the door (%d points)" % back.points.size())
		check(manager.nav.is_walkable(Vector2(door.x, door.z)), "the door stands on the street's walk network")
	# The cache: what was just sampled is on disk, and a second sampler
	# comes back from it in a moment with the same answers.
	OS.set_environment("GAME_NAV_NOCACHE", "")
	check(nav.cache.path != "" and FileAccess.file_exists(nav.cache.path), "the floors were written to the cache (%s)" % nav.cache.path)
	var nav2 = load("res://src/life/building_nav.gd").new()
	nav2.name = "SchoolNavAgain"
	world.add_child(nav2)
	nav2.setup(manager, world)
	var waited2 := 0
	while waited2 < 60 * 60 and not nav2.ready_ok:
		await physics_frame
		waited2 += 1
	check(nav2.ready_ok and nav2.cache.loaded, "a second sampler reads the floors back from the cache (%s)" % nav2.cache.path)
	check(nav2.build_ms < 5000, "reading back is quick (%d ms, including the fingerprint's rays)" % nav2.build_ms)
	var same := true
	for sch in rooms:
		var a: Dictionary = nav.route(door, sch.place_pos())
		var b: Dictionary = nav2.route(door, sch.place_pos())
		if bool(a.reached) != bool(b.reached) or a.points.size() != b.points.size() or a.lifts.size() != b.lifts.size():
			same = false
	check(same, "routes over the cached floors match the sampled ones")
	print("[BuildingNav] cache: %s, read back in %d ms" % [nav.cache.path, nav2.build_ms])
	_finish()


func _finish() -> void:
	print("Building nav tests: ", "PASS" if failures == 0 else "FAIL ", failures)
	quit(0 if failures == 0 else 1)
