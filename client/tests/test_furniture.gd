extends SceneTree
## Headless check that everything under assets/assets/Objects/ is actually
## placeable: discovered the way plot_object_tool.gd discovers it, the right
## real-world size once parented to the 0.2-scaled workspace, and carrying a
## collider so the build tools can select it and pieces can rest on it.
##
##   Godot --headless --path client --script res://tests/test_furniture.gd

const OBJECTS_DIR := "res://assets/assets/Objects"
const UNITS_PER_M := 5.0

var failures := 0


func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("FAIL: " + message)


func _initialize() -> void:
	call_deferred("run")


## The same scan plot_object_tool.gd does: a folder is an object when it
## holds mesh.tscn (preferred) or mesh.glb.
func discover() -> Dictionary:
	var found := {}
	var dir := DirAccess.open(OBJECTS_DIR)
	if dir == null:
		return found
	for name in dir.get_directories():
		if name.begins_with("."):
			continue
		var tscn := OBJECTS_DIR + "/" + name + "/mesh.tscn"
		var glb := OBJECTS_DIR + "/" + name + "/mesh.glb"
		if FileAccess.file_exists(tscn):
			found[name] = tscn
		elif FileAccess.file_exists(glb):
			found[name] = glb
	return found


func has_collider(node: Node) -> bool:
	var stack: Array = [node]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current is CollisionObject3D:
			return true
		for child in current.get_children():
			stack.push_back(child)
	return false


func _gather_bodies(node: Node, out: Array) -> void:
	if node is CollisionObject3D:
		out.append(node)
	for child in node.get_children():
		_gather_bodies(child, out)


func meta_for(name: String) -> Dictionary:
	var path := OBJECTS_DIR + "/" + name + "/object.json"
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


## The furniture folder is heavy (well over 100 MB) and the browser cannot
## hold the city, so it must stream: declared as a pack in tools/packs.json
## AND excluded from the Web Local export preset, the way every other bulk
## folder is. Forgetting either half silently bloats the web main pck, which
## is the download players wait on before they can play at all.
func check_web_streaming() -> void:
	var packs_json := "res://tools/packs.json"
	var f := FileAccess.open(packs_json, FileAccess.READ)
	check(f != null, "tools/packs.json is readable")
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	check(typeof(parsed) == TYPE_DICTIONARY, "packs.json parses")
	if typeof(parsed) != TYPE_DICTIONARY:
		return

	var declared := ""
	for pack_name in parsed.get("packs", {}):
		var roots: Array = parsed["packs"][pack_name].get("roots", [])
		for root in roots:
			if str(root).begins_with(OBJECTS_DIR):
				declared = str(pack_name)
	check(declared != "", "packs.json declares a pack whose roots cover " + OBJECTS_DIR)

	# The tool that rebuilds the list at runtime must name that same pack.
	var tool_script := FileAccess.open("res://src/build/plot_object_tool.gd", FileAccess.READ)
	if tool_script != null and declared != "":
		var body := tool_script.get_as_text()
		check(body.contains('OBJECTS_PACK := "%s"' % declared),
			"plot_object_tool.gd waits on the pack named in packs.json ('%s')" % declared)

	var presets := FileAccess.open("res://export_presets.cfg", FileAccess.READ)
	check(presets != null, "export_presets.cfg is readable")
	if presets == null:
		return
	# Only the web preset must exclude it; desktop bundles everything.
	var in_web_local := false
	var current := ""
	while not presets.eof_reached():
		var line := presets.get_line()
		if line.begins_with("name="):
			current = line.substr(5).strip_edges().trim_prefix('"').trim_suffix('"')
		elif line.begins_with("exclude_filter=") and current == "Web Local":
			in_web_local = line.contains("assets/assets/Objects")
	check(in_web_local, "the 'Web Local' preset excludes assets/assets/Objects (else it ships in the main pck)")
	print("streaming: pack '%s', excluded from Web Local" % declared)


func run() -> void:
	# A stand-in for the workspace: plot objects are children of it, and it is
	# scaled 0.2, so an object's own units are five per metre.
	var workspace := Node3D.new()
	workspace.name = "localworkspace"
	workspace.scale = Vector3(0.2, 0.2, 0.2)
	get_root().add_child(workspace)
	current_scene = workspace

	var objects := discover()
	check(not objects.is_empty(), "at least one object under " + OBJECTS_DIR)
	print("discovered %d object(s)" % objects.size())

	for name in objects:
		var path: String = objects[name]
		var scene = load(path)
		check(scene != null, "%s: %s loads" % [name, path])
		if scene == null:
			continue
		var instance = scene.instantiate()
		check(instance is Node3D, "%s: instantiates as a Node3D" % name)
		if not (instance is Node3D):
			continue
		workspace.add_child(instance)

		# Selectable and rest-able: the build tools raycast bodies.
		check(has_collider(instance), "%s: has a collider (else it cannot be selected or landed on)" % name)

		# ...but it must not stand in the player's way. The player body is on
		# layer 1, so furniture must be off layer 1 and must not mask layer 1.
		var bodies: Array = []
		_gather_bodies(instance, bodies)
		for b in bodies:
			var co := b as CollisionObject3D
			check(co.collision_layer & 1 == 0,
				"%s: collides on the player's layer 1 — you would be stopped by the furniture" % name)
			check(co.collision_mask == 0,
				"%s: pushes against other bodies; furniture should be inert" % name)

		# The bounds BuildPlots measures a piece by, turned into metres.
		var aabb: AABB = BuildSelectable.get_aabb(instance)
		var world: Vector3 = aabb.size * instance.global_transform.basis.get_scale()
		var longest: float = maxf(world.x, maxf(world.y, world.z))
		check(longest > 0.0, "%s: has visible geometry" % name)

		var meta := meta_for(name)
		if meta.has("size_m"):
			# A declared size that the scene matches is the scaled import, however
			# small the thing is (a mug is 12 cm and that is right).
			var want: float = float(meta.size_m)
			check(absf(longest - want) < 0.02,
				"%s: longest side %.2f m, object.json asks for %.2f m" % [name, longest, want])
		else:
			check(longest >= 0.1 and longest <= 20.0,
				"%s: %.2f m is not a plausible size for furniture" % [name, longest])
			# Anything much smaller than a shoebox is the un-scaled 1-unit import.
			check(longest > 0.25, "%s: %.2f m — looks like a raw unit-scale model" % [name, longest])

		print("  %-22s %-22s %.2f x %.2f x %.2f m%s" %
			[name, str(meta.get("label", "")), world.x, world.y, world.z,
			"" if has_collider(instance) else "   [NO COLLIDER]"])
		instance.queue_free()

	check_web_streaming()

	if failures == 0:
		print("test_furniture: all checks passed")
	else:
		print("test_furniture: %d FAILURES" % failures)
	quit(1 if failures > 0 else 0)
