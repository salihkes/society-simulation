## Places of a workspace: venues, schools, chambers, districts and markers, and their amb_state.
class_name AmbientPlaces
extends RefCounted

const PARLIAMENT_SCRIPT := preload("res://src/life/ambient_parliament.gd")

var restaurants: Array = []  # "rest"
var courses: Array = []  # "crs"
var shops: Array = []
var schools: Array = []  # "sch"
var parliaments: Array = []  # "par"
var districts: Array = []  # {name, poly: PackedVector2Array, area}

var _m: AmbientManager = null


func _init(manager: AmbientManager):
	_m = manager


func register_restaurant(r):
	if not restaurants.has(r):
		restaurants.append(r)
		_m.mark_report_dirty(2.0)


func register_shop(s):
	if not shops.has(s):
		shops.append(s)
		_m.mark_report_dirty(2.0)


func register_course(c):
	if not courses.has(c):
		courses.append(c)
		_m.mark_report_dirty(2.0)


func find_schools():
	var world: Node3D = _m.world()
	if world == null:
		return
	for lect in world.find_children("TeacherStandsHereFacingTheClass", "Marker3D", true, false):
		var room := lect.get_parent() as Node3D
		if room == null or schools.any(func(s): return s._room == room):
			continue
		var school := AmbientSchool.new()
		school.name = "AmbientSchool"
		room.add_child(school)
		school.setup(_m, room)
		schools.append(school)
		_m.mark_report_dirty(2.0)


func find_parliaments():
	var world: Node3D = _m.world()
	if world == null:
		return
	for ros in world.find_children("SpeakerStandsHereFacingTheHouse", "Marker3D", true, false):
		var room := ros.get_parent() as Node3D
		if room == null or parliaments.any(func(p): return p._room == room):
			continue
		var par = PARLIAMENT_SCRIPT.new()
		par.name = "AmbientParliament"
		room.add_child(par)
		par.setup(_m, room)
		parliaments.append(par)
		_m.mark_report_dirty(2.0)


func school(place: String):
	for s in schools:
		if s != null and is_instance_valid(s) and s.matches_place(place):
			return s
	return null


func parliament(place: String = ""):
	for p in parliaments:
		if p != null and is_instance_valid(p) and (place == "" or p.key() == place):
			return p
	return null


func build_districts():
	districts = []
	var world: Node3D = _m.world()
	if world == null:
		return
	var node = world.get_node_or_null("AmbientLayout")
	if node == null or not node.has_method("districts"):
		return
	for d in node.districts():
		var pts: PackedVector3Array = d.points
		var poly := PackedVector2Array()
		for p in pts:
			poly.append(Vector2(p.x, p.z))
		var area := 0.0
		for i in poly.size():
			area += poly[i].cross(poly[(i + 1) % poly.size()])
		districts.append({"name": d.name, "poly": poly, "area": absf(area) * 0.5})
	districts.sort_custom(func(a, b): return a.area < b.area)


## Most specific first.
func district_names_at(pos_local: Vector3) -> Array:
	var out := []
	var p2 := Vector2(pos_local.x, pos_local.z)
	for d in districts:
		if Geometry2D.is_point_in_polygon(p2, d.poly):
			out.append(d.name)
	return out


func collect_places() -> Array:
	if _m.world() == null:
		return []
	var places: Array = []
	var seen: Dictionary = {}
	_district_places(places, seen)
	_plot_places(places, seen)
	_venue_places(places, seen)
	_school_places(places, seen)
	_home_and_device_places(places, seen)
	_marker_places(places, seen)
	return places


func _district_places(places: Array, seen: Dictionary):
	for d in districts:
		var poly: PackedVector2Array = d.poly
		var c := Vector2.ZERO
		for pt in poly:
			c += pt
		if poly.size() > 0:
			c /= float(poly.size())
		places.append({"id": str(d.name), "kind": "district",
			"pos": [snappedf(c.x, 0.1), 0.0, snappedf(c.y, 0.1)], "area": snappedf(float(d.area), 1.0)})
		seen[str(d.name)] = true


## The server validates placements against them.
func _plot_places(places: Array, seen: Dictionary):
	var world: Node3D = _m.world()
	for plot in BuildPlots.all_plots(world):
		var poly: PackedVector2Array = plot.poly
		var c := BuildPlots.polygon_centroid(poly)
		var pts := []
		for pt in poly:
			pts.append([snappedf(pt.x, 0.01), snappedf(pt.y, 0.01)])
		var local_c := Vector3(c.x, float(plot.floor), c.y)
		var pid := "plot:" + str(plot.id)
		places.append({"id": pid, "kind": "plot", "plot": str(plot.id), "name": str(plot.name),
			"pos": v3(local_c), "world_pos": v3(world.to_global(local_c)),
			"points": pts, "floor": snappedf(float(plot.floor), 0.01),
			"ceiling": snappedf(float(plot.ceiling), 0.01),
			"area": snappedf(float(plot.area), 1.0), "district": district_names_at(local_c)})
		seen[pid] = true


## Courses are roster-only: known to the mind, never a destination.
func _venue_places(places: Array, seen: Dictionary):
	for r in restaurants:
		if r == null or not is_instance_valid(r):
			continue
		var rp: Vector3 = r.place_pos() if r.has_method("place_pos") else _m.world().to_local(r.global_position)
		places.append({"id": r.rest_key(), "kind": "restaurant", "pos": v3(rp),
			"open": [float(r.get("open_hour")), float(r.get("close_hour"))],
			"verbs": ["eat"], "district": district_names_at(rp)})
		seen[r.rest_key()] = true
	for sh in shops:
		if sh == null or not is_instance_valid(sh):
			continue
		var entry: Dictionary = sh.place_entry()
		entry["district"] = district_names_at(sh.place_pos())
		places.append(entry)
		seen[sh.key()] = true
	for c in courses:
		if c == null or not is_instance_valid(c):
			continue
		places.append({"id": c.course_key(), "kind": "course", "pos": v3(c.place_pos()),
			"sessions": c.sessions_info(), "verbs": [], "district": district_names_at(c.place_pos())})
		seen[c.course_key()] = true


## A room's "place_alias" is a second entry, so routines addressed to the alias still work.
func _school_places(places: Array, seen: Dictionary):
	for sch in schools:
		if sch == null or not is_instance_valid(sch):
			continue
		var entry: Dictionary = sch.place_entry()
		entry["district"] = district_names_at(sch.place_pos())
		places.append(entry)
		seen[sch.key()] = true
		var alias := str(sch._room.get_meta("place_alias", ""))
		if alias != "" and alias != sch.key() and not seen.has(alias):
			var alias_entry := entry.duplicate(true)
			alias_entry["id"] = alias
			alias_entry["alias_of"] = sch.key()
			places.append(alias_entry)
			seen[alias] = true
	for par in parliaments:
		if par == null or not is_instance_valid(par):
			continue
		places.append({"id": par.key(), "kind": "parliament", "pos": v3(par.place_pos()),
			"seats": par.seat_counts(), "verbs": [], "district": district_names_at(par.place_pos())})
		seen[par.key()] = true


func _home_and_device_places(places: Array, seen: Dictionary):
	var world: Node3D = _m.world()
	for hh in _m.households():
		var he: Dictionary = hh.place_entry()
		var hp := Vector3(he.pos[0], he.pos[1], he.pos[2])
		he["district"] = district_names_at(hp)
		places.append(he)
		seen[str(he.id)] = true
	for pc in _m.get_tree().get_nodes_in_group("computers"):
		if pc == null or not is_instance_valid(pc) or not pc.has_method("place_entry"):
			continue
		var pe: Dictionary = pc.place_entry(world)
		pe["district"] = district_names_at(world.to_local(pc.global_position))
		places.append(pe)
		seen[str(pe.get("id", ""))] = true
	for elevator in _m.get_tree().get_nodes_in_group("elevators"):
		for entry in elevator.place_entries(world):
			places.append(entry)
			seen[str(entry.id)] = true


## A duplicate name is prefixed with its owning scene.
func _marker_places(places: Array, seen: Dictionary):
	var world: Node3D = _m.world()
	var layout_node = world.get_node_or_null("AmbientLayout")
	for m in world.find_children("*", "Marker3D", true, false):
		if m.name == "Example" or under_restaurant(m) or under_course(m) or under_school(m) or under_parliament(m):
			continue
		if m.get_parent() != null and m.get_parent().is_in_group("computers"):
			continue
		if layout_node != null and layout_node.is_ancestor_of(m):
			continue
		var mp: Vector3 = world.to_local(m.global_position)
		var owner_name := _owner_scene_name(m)
		var id := str(m.name)
		if seen.has(id):
			id = owner_name + "/" + id if owner_name != "" else id + "#" + str(seen.size())
		seen[id] = true
		places.append({"id": id, "kind": "marker", "name": str(m.name), "pos": v3(mp),
			"owner": owner_name, "walkable": _m.nav.is_walkable(Vector2(mp.x, mp.z)),
			"district": district_names_at(mp)})


static func v3(v: Vector3) -> Array:
	return [snappedf(v.x, 0.1), snappedf(v.y, 0.1), snappedf(v.z, 0.1)]


## Ancestors below the world only.
func _has_ancestor(n: Node, test: Callable) -> bool:
	var world: Node3D = _m.world()
	var p := n.get_parent()
	while p != null and p != world:
		if test.call(p):
			return true
		p = p.get_parent()
	return false


func under_school(n: Node) -> bool:
	return _has_ancestor(n, func(p): return schools.any(func(s): return s._room == p))


func under_parliament(n: Node) -> bool:
	return _has_ancestor(n, func(p): return parliaments.any(func(par): return par._room == p))


func under_restaurant(n: Node) -> bool:
	return _has_ancestor(n, func(p): return restaurants.has(p) or p.is_in_group("restaurant_layouts"))


func under_course(n: Node) -> bool:
	return _has_ancestor(n, func(p): return courses.has(p))


## Else "".
func _owner_scene_name(n: Node) -> String:
	var world: Node3D = _m.world()
	var p := n.get_parent()
	while p != null and p != world:
		if p.scene_file_path != "":
			return str(p.name)
		p = p.get_parent()
	return ""


## Null when unknown.
func place_position(place: String):
	var world: Node3D = _m.world()
	for elevator in _m.get_tree().get_nodes_in_group("elevators"):
		for entry in elevator.place_entries(world):
			if entry.id == place:
				return Vector3(entry.pos[0], entry.pos[1], entry.pos[2])
	for p in parliaments:
		if p != null and is_instance_valid(p):
			var pp = p.place_position(place)
			if pp != null:
				return pp
	var sch = school(place)
	if sch != null and place != "":
		return sch.place_pos()
	var venue = _venue_position(place)
	if venue != null:
		return venue
	if world != null:
		for marker in world.find_children("*", "Marker3D", true, false):
			if str(marker.name) == place or _owner_scene_name(marker) + "/" + str(marker.name) == place:
				return world.to_local(marker.global_position)
	return _district_centre(place)


func _venue_position(place: String):
	for r in restaurants:
		if r != null and is_instance_valid(r) and r.rest_key() == place:
			if r.has_method("approach_pos"):
				return r.approach_pos()
			if r.has_method("place_pos"):
				return r.place_pos()
	for sh in shops:
		if sh != null and is_instance_valid(sh) and sh.key() == place:
			return sh.approach_pos()
	for c in courses:
		if c != null and is_instance_valid(c) and c.course_key() == place:
			return c.approach_pos()
	return null


func _district_centre(place: String):
	for district in districts:
		if str(district.name) == place and district.poly.size() > 0:
			var centre := Vector2.ZERO
			for point in district.poly:
				centre += point
			centre /= district.poly.size()
			return Vector3(centre.x, 0.0, centre.y)
	return null


## A "sit" intent takes its facing from it.
func place_marker(place: String) -> Node3D:
	for p in parliaments:
		if p != null and is_instance_valid(p):
			var m: Node3D = p.place_marker(place)
			if m != null:
				return m
	return null


func set_authority(is_auth: bool):
	for r in restaurants:
		if r != null and is_instance_valid(r):
			r.set_authority(is_auth)
	for c in courses:
		if c != null and is_instance_valid(c):
			c.set_authority(is_auth)


## The "rest", "crs", "sch" and "par" sections of amb_state.
func states() -> Dictionary:
	var rest := {}
	for r in restaurants:
		if r != null and is_instance_valid(r):
			rest[r.rest_key()] = r.snapshot()
	var crs := {}
	for c in courses:
		if c != null and is_instance_valid(c):
			crs[c.course_key()] = c.snapshot()
	var sch := {}
	for s in schools:
		if s != null and is_instance_valid(s):
			sch[s.key()] = s.snapshot()
	var par := {}
	for p in parliaments:
		if p != null and is_instance_valid(p):
			par[p.key()] = p.snapshot()
	return {"rest": rest, "crs": crs, "sch": sch, "par": par}


## The "lifts" section too.
func apply_remote(data: Dictionary):
	var rest: Dictionary = data.get("rest", {})
	for r in restaurants:
		if r != null and is_instance_valid(r) and rest.has(r.rest_key()):
			r.apply_snapshot(rest[r.rest_key()])
	var crs: Dictionary = data.get("crs", {})
	for c in courses:
		if c != null and is_instance_valid(c) and crs.has(c.course_key()):
			c.apply_snapshot(crs[c.course_key()])
	var schs: Dictionary = data.get("sch", {})
	var lifts: Dictionary = data.get("lifts", {})
	for elevator in _m.get_tree().get_nodes_in_group("elevators"):
		if lifts.has(elevator.elevator_id):
			elevator.apply_snapshot(lifts[elevator.elevator_id])
	for s in schools:
		if s != null and is_instance_valid(s) and schs.has(s.key()):
			s.apply_snapshot(schs[s.key()])
	var pars: Dictionary = data.get("par", {})
	for p in parliaments:
		if p != null and is_instance_valid(p) and pars.has(p.key()):
			p.apply_snapshot(pars[p.key()])
