@tool
class_name GalaxyMap
extends Node3D
## A seeded 3D spiral galaxy: the interactive map (build) or sky geometry only (build_world).

signal planet_clicked(region_id: String)
signal deselected

const SEED := 20090901
const ARMS := 3
## How far each arm wraps around the core.
const ARM_WIND := 2.3 * PI
const ARM_R0 := 3.5
const ARM_R1 := 58.0
const PLANET_RADIUS := 0.65
const DEFAULT_INFLUENCE := 8.0
## Must match MAXP in PLANE_SHADER.
const MAX_PLANETS := 48
const PAN_LIMIT := 75.0
## Colour of a planet without one.
const UNCLAIMED := Color("6b7a8f")

const PLANE_SHADER := "
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

const int MAXP = 48;
uniform int count = 0;
uniform vec3 positions[MAXP];
uniform vec4 fill_colors[MAXP];
uniform float radii[MAXP];
uniform float fill_alpha : hint_range(0.0, 1.0) = 0.34;
uniform float view_fade : hint_range(0.0, 1.0) = 1.0;
uniform sampler2D noise_tex : filter_linear, repeat_enable;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world_pos.xz;
	// domain warp: organic, hand-drawn-looking borders
	vec2 nuv = p * 0.02;
	float n1 = texture(noise_tex, nuv).r - 0.5;
	float n2 = texture(noise_tex, nuv + vec2(0.41, 0.17)).r - 0.5;
	p += vec2(n1, n2) * 4.0;

	// pass 1: nearest zone decides which owner this point belongs to
	float d1 = 1e9;
	int b = 0;
	for (int i = 0; i < MAXP; i++) {
		if (i >= count) { break; }
		float d = distance(p, positions[i].xz) - radii[i];
		if (d < d1) { d1 = d; b = i; }
	}
	vec3 owner = fill_colors[b].rgb;

	// pass 2: SMOOTH-union every zone of that owner (same fill color) into
	// one distance field — neighboring same-owner zones melt into a single
	// organic territory, no seam, no waist. Other owners keep a plain min.
	float d_own = 1e9;
	float d_oth = 1e9;
	for (int i = 0; i < MAXP; i++) {
		if (i >= count) { break; }
		float d = distance(p, positions[i].xz) - radii[i];
		if (distance(fill_colors[i].rgb, owner) < 0.02) {
			float h = clamp(0.5 + 0.5 * (d_own - d) / 2.5, 0.0, 1.0);
			d_own = mix(d_own, d, h) - 2.5 * h * (1.0 - h);
		} else {
			d_oth = min(d_oth, d);
		}
	}

	float fill = (1.0 - smoothstep(-1.4, 0.0, d_own)) * fill_alpha;
	// outer border: the edge of the united territory
	float outer = 1.0 - smoothstep(0.0, 0.7, abs(d_own));
	// shared border: the line against a DIFFERENT owner, where both reach
	float both_inside = 1.0 - smoothstep(-0.4, 0.2, max(d_own, d_oth));
	float shared = (1.0 - smoothstep(0.0, 0.9, abs(d_oth - d_own))) * both_inside;
	float border = max(shared, outer);
	vec3 bcol = clamp(owner * 1.7 + vec3(0.18), 0.0, 1.0);
	ALBEDO = mix(owner, bcol, smoothstep(0.0, 1.0, border));
	ALPHA = clamp(max(fill, border * 0.9), 0.0, 1.0) * view_fade;
}
"

## rid -> {node, mesh, label, beacon, ring, pos, has_data, radius}
var planets := {}
var home_rid := ""
## True after build_world(): geometry only, no camera or input.
var world_mode := false
## Star and nebula instances, faded by GalaxyInWorld in daylight.
var sky_layers: Array = []

# Camera state; each value eases towards its *_t target every frame.
var camera: Camera3D
var focus := Vector3.ZERO
var focus_t := Vector3.ZERO
var yaw := 0.7
var yaw_t := 0.7
var pitch := 0.95
var pitch_t := 0.95
## Frames the whole galaxy.
var dist := 125.0
var dist_t := 125.0

var _rng := RandomNumberGenerator.new()
var _dot_tex: ImageTexture
var _puff_tex: ImageTexture
var _ring_tex: ImageTexture
var _drag_accum := 0.0
var _dragging := false
var _pan_last := Vector2.ZERO
var _plane_mat: ShaderMaterial
var _plane: MeshInstance3D
var _org_mat: ShaderMaterial
var _org_plane: MeshInstance3D
## rid per shader slot of the zone plane.
var _plane_order: Array = []


## regions: rid -> planet def; colors: rid -> zone colour; org_colors: rid -> organisation colour.
func build(regions: Dictionary, colors: Dictionary = {}, org_colors: Dictionary = {}) -> void:
	_rng.seed = SEED
	_dot_tex = _make_dot_texture()
	_puff_tex = _make_puff_texture()

	_build_environment()
	_build_star_field()
	_build_nebula()
	_build_backdrop()

	for rid in regions:
		var def: Dictionary = regions[rid]
		add_planet(str(rid), def, colors.get(rid, UNCLAIMED))
	_build_influence_plane()
	set_map_colors(colors)
	_build_org_plane(org_colors)

	camera = Camera3D.new()
	camera.near = 0.05
	camera.far = 1500.0
	camera.fov = 55.0
	add_child(camera)
	camera.current = true
	_apply_camera()


## Geometry only, into an existing world: no camera, input, overlays or backdrop.
func build_world(regions: Dictionary, colors: Dictionary = {}, skip_rids: Array = []) -> void:
	world_mode = true
	set_process_unhandled_input(false)
	_rng.seed = SEED
	_dot_tex = _make_dot_texture()
	_puff_tex = _make_puff_texture()
	_build_star_field()
	_build_nebula()
	for rid in regions:
		if rid in skip_rids:
			continue
		add_planet(str(rid), regions[rid], colors.get(rid, UNCLAIMED))


func _process(delta: float) -> void:
	if not world_mode and camera == null:
		return
	if world_mode:
		for rid in planets:
			planets[rid]["mesh"].rotate_y(delta * 0.15)
		return
	_ease_camera(delta)
	var cam := camera
	if cam == null:
		return
	# Distances in galaxy units, whatever this node's scale.
	var unit := maxf(global_transform.basis.get_scale().x, 0.0001)
	for rid in planets:
		var p: Dictionary = planets[rid]
		p["mesh"].rotate_y(delta * 0.15)
		var d: float = cam.global_position.distance_to(p["node"].global_position) / unit
		if p["label"]:
			p["label"].modulate.a = clampf((150.0 - d) / 60.0, 0.30, 1.0)
		p["beacon"].get_surface_override_material(0).albedo_color.a = clampf(d / 60.0, 0.0, 0.85)


func _ease_camera(delta: float) -> void:
	_key_pan(delta)
	var k := 1.0 - exp(-6.0 * delta)
	focus = focus.lerp(focus_t, k)
	yaw = lerpf(yaw, yaw_t, k)
	pitch = lerpf(pitch, pitch_t, k)
	dist = lerpf(dist, dist_t, k)
	_apply_camera()
	if _plane_mat:
		# The political overlays fade out when zoomed in on a planet.
		var vf := clampf((dist - 6.0) / 22.0, 0.0, 1.0)
		_plane_mat.set_shader_parameter("view_fade", vf)
		if _org_mat:
			_org_mat.set_shader_parameter("view_fade", vf)


func _apply_camera() -> void:
	var dir := Vector3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
	camera.position = focus + dir * dist
	camera.look_at(focus, Vector3.UP)


## Scroll zooms, left drag pans (a short drag is a click), middle or right drag orbits, Esc unfocuses.
func _unhandled_input(event: InputEvent) -> void:
	if world_mode:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			dist_t = clampf(dist_t * 0.87, 1.8, 170.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			dist_t = clampf(dist_t * 1.15, 1.8, 170.0)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_drag_accum = 0.0
				_dragging = false
				_pan_last = event.position
			elif not _dragging:
				_click(event.position)
	elif event is InputEventMouseMotion:
		if event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			_drag_pan(event)
		elif event.button_mask & (MOUSE_BUTTON_MASK_MIDDLE | MOUSE_BUTTON_MASK_RIGHT):
			yaw_t -= event.relative.x * 0.007
			pitch_t = clampf(pitch_t + event.relative.y * 0.006, 0.12, 1.5)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		unfocus()


## Starts only once the drag has moved more than 6 pixels.
func _drag_pan(event: InputEventMouseMotion) -> void:
	_drag_accum += event.relative.length()
	if _drag_accum > 6.0:
		_dragging = true
	if _dragging:
		var a := _plane_point(_pan_last)
		var b := _plane_point(event.position)
		focus_t += a - b
		focus_t.x = clampf(focus_t.x, -PAN_LIMIT, PAN_LIMIT)
		focus_t.z = clampf(focus_t.z, -PAN_LIMIT, PAN_LIMIT)
		_pan_last = event.position


func _key_pan(delta: float) -> void:
	var pan := Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		pan.y += 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		pan.y -= 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		pan.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		pan.x += 1.0
	if pan == Vector2.ZERO:
		return
	# Screen-up on the plane.
	var fwd := Vector2(-sin(yaw), -cos(yaw))
	var right := Vector2(-fwd.y, fwd.x)
	var move := (fwd * pan.y + right * pan.x).normalized() * dist * 0.7 * delta
	focus_t += Vector3(move.x, 0.0, move.y)
	focus_t.x = clampf(focus_t.x, -PAN_LIMIT, PAN_LIMIT)
	focus_t.z = clampf(focus_t.z, -PAN_LIMIT, PAN_LIMIT)


## Where a screen ray meets the galactic plane (y = 0), else the focus.
func _plane_point(screen_pos: Vector2) -> Vector3:
	var origin := camera.project_ray_origin(screen_pos)
	var ray := camera.project_ray_normal(screen_pos)
	if absf(ray.y) < 0.0001:
		return focus
	var t := -origin.y / ray.y
	if t < 0.0:
		return focus
	return origin + ray * t


func _click(screen_pos: Vector2) -> void:
	var origin := camera.project_ray_origin(screen_pos)
	var ray := camera.project_ray_normal(screen_pos)
	var best_rid := ""
	var best_err := INF
	for rid in planets:
		var pos: Vector3 = planets[rid]["pos"]
		var u := (pos - origin).dot(ray)
		if u <= 0.0:
			continue
		var err := (origin + ray * u).distance_to(pos)
		if err < maxf(PLANET_RADIUS * 1.8, u * 0.02) and err < best_err:
			best_err = err
			best_rid = rid
	if best_rid != "":
		focus_planet(best_rid)
		planet_clicked.emit(best_rid)


func focus_planet(rid: String) -> void:
	if not planets.has(rid):
		return
	focus_t = planets[rid]["pos"]
	dist_t = clampf(dist_t, 2.6, 7.0)


func unfocus() -> void:
	focus_t = Vector3.ZERO
	dist_t = maxf(dist_t, 45.0)
	deselected.emit()


## Its "position", else its arm point offset sideways by "side", else the origin.
func placement(def: Dictionary) -> Vector3:
	if def.has("position"):
		var arr: Array = def["position"]
		return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	if def.has("galaxy"):
		var g: Dictionary = def["galaxy"]
		var t := float(g.get("t", 0.5))
		var arm := int(g.get("arm", 0))
		var pos := _arm_point(arm, t)
		var tangent := (_arm_point(arm, t + 0.02) - pos).normalized()
		pos += tangent.cross(Vector3.UP) * float(g.get("side", 0.0))
		pos.y = float(g.get("y", 0.0))
		return pos
	return Vector3.ZERO


## Map mode adds a label; world mode adds a halo ring, stronger for planets with a scene.
func add_planet(rid: String, def: Dictionary, tint: Color) -> void:
	var pos := placement(def)

	var node := Node3D.new()
	node.position = pos
	add_child(node)

	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = PLANET_RADIUS
	sphere.height = PLANET_RADIUS * 2.0
	sphere.radial_segments = 32
	sphere.rings = 16
	mesh.mesh = sphere
	var pmat := StandardMaterial3D.new()
	pmat.albedo_texture = _make_planet_texture(tint, rid.hash())
	pmat.roughness = 0.85
	pmat.emission_enabled = true
	pmat.emission = tint * 0.16
	mesh.material_override = pmat
	node.add_child(mesh)

	var label: Label3D = null
	if not world_mode:
		label = _make_label(rid, def)
		node.add_child(label)

	var bc := tint.lerp(Color.WHITE, 0.55) if world_mode else tint
	var beacon := _make_beacon(bc)
	node.add_child(beacon)

	var ring: MeshInstance3D = null
	if world_mode:
		ring = _make_ring(bc, 0.65 if def.has("scene") else 0.28)
		node.add_child(ring)

	var has_data := true
	planets[rid] = {"node": node, "mesh": mesh, "label": label,
		"beacon": beacon, "ring": ring, "pos": pos, "has_data": has_data,
		"radius": float(def.get("influence_radius", DEFAULT_INFLUENCE))}


func _make_label(rid: String, def: Dictionary) -> Label3D:
	var label := Label3D.new()
	label.text = str(def.get("name", rid))
	label.position = Vector3(0, 1.5, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = Color(0.95, 0.96, 1.0)
	label.fixed_size = true
	label.no_depth_test = true
	label.pixel_size = 0.0011
	label.font_size = 22
	label.outline_size = 8
	if rid == home_rid:
		label.text = "◈ " + label.text
		label.font_size = 26
		label.modulate = Color(1.0, 0.87, 0.45)
	return label


## A pin on the map, a small glint in the world.
func _make_beacon(bc: Color) -> MeshInstance3D:
	var beacon := MeshInstance3D.new()
	var bq := QuadMesh.new()
	bq.size = Vector2(0.6, 0.6) if world_mode else Vector2(2.4, 2.4)
	beacon.mesh = bq
	var bmat := _billboard_material(_dot_tex)
	bmat.vertex_color_use_as_albedo = false
	bmat.albedo_color = Color(bc.r, bc.g, bc.b, 0.85)
	bmat.no_depth_test = not world_mode
	beacon.set_surface_override_material(0, bmat)
	return beacon


func _make_ring(bc: Color, ring_alpha: float) -> MeshInstance3D:
	if _ring_tex == null:
		_ring_tex = _make_ring_texture()
	var ring := MeshInstance3D.new()
	var rq := QuadMesh.new()
	rq.size = Vector2(1.7, 1.7)
	ring.mesh = rq
	var rmat := _billboard_material(_ring_tex)
	rmat.vertex_color_use_as_albedo = false
	rmat.albedo_color = Color(bc.r, bc.g, bc.b, ring_alpha)
	ring.set_surface_override_material(0, rmat)
	return ring


func set_borders_visible(on: bool) -> void:
	if _plane:
		_plane.visible = on
	if _org_plane:
		_org_plane.visible = on


## A 170 x 170 quad at height y; not yet added to the tree.
func _make_overlay(y: float, noise_seed: int) -> MeshInstance3D:
	var plane := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(170, 170)
	plane.mesh = quad
	plane.rotation_degrees.x = -90.0
	plane.position.y = y
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = PLANE_SHADER
	mat.shader = sh
	mat.set_shader_parameter("noise_tex", _make_zone_noise(noise_seed))
	plane.material_override = mat
	return plane


## Coloured later by set_map_colors().
func _build_influence_plane() -> void:
	var plane := _make_overlay(-0.12, SEED + 3)
	_plane = plane
	_plane_mat = plane.material_override
	# Under the additive star layers.
	_plane_mat.render_priority = -2
	add_child(plane)

	_plane_order = []
	for rid in planets:
		if planets[rid]["has_data"]:
			_plane_order.append(rid)
	var positions := PackedVector3Array()
	var radii := PackedFloat32Array()
	for i in MAX_PLANETS:
		if i < _plane_order.size():
			positions.append(planets[_plane_order[i]]["pos"])
			radii.append(planets[_plane_order[i]]["radius"])
		else:
			positions.append(Vector3.ZERO)
			radii.append(0.0)
	_plane_mat.set_shader_parameter("positions", positions)
	_plane_mat.set_shader_parameter("radii", radii)
	_plane_mat.set_shader_parameter("count", mini(_plane_order.size(), MAX_PLANETS))


## Members share their organisation's colour, so they merge into one shape with one border.
func _build_org_plane(org_colors: Dictionary) -> void:
	if org_colors.is_empty():
		return
	# Another warp seed, so the two sets of borders do not trace each other.
	var plane := _make_overlay(-0.10, SEED + 4)
	_org_plane = plane
	_org_mat = plane.material_override
	_org_mat.set_shader_parameter("fill_alpha", 0.07)
	_org_mat.render_priority = -1
	plane.visible = _plane.visible if _plane else true
	add_child(plane)

	var members: Array = []
	for rid in planets:
		if org_colors.has(rid):
			members.append(rid)
	var positions := PackedVector3Array()
	var radii := PackedFloat32Array()
	var cols := PackedColorArray()
	for i in MAX_PLANETS:
		if i < members.size():
			positions.append(planets[members[i]]["pos"])
			# Slightly wider, so the border rings just outside the zones.
			radii.append(float(planets[members[i]]["radius"]) + 1.5)
			cols.append(org_colors[members[i]])
		else:
			positions.append(Vector3.ZERO)
			radii.append(0.0)
			cols.append(Color.BLACK)
	_org_mat.set_shader_parameter("positions", positions)
	_org_mat.set_shader_parameter("radii", radii)
	_org_mat.set_shader_parameter("fill_colors", cols)
	_org_mat.set_shader_parameter("count", mini(members.size(), MAX_PLANETS))


func _make_zone_noise(noise_seed: int) -> NoiseTexture2D:
	var fn := FastNoiseLite.new()
	fn.seed = noise_seed
	fn.frequency = 0.012
	fn.fractal_octaves = 3
	var nt := NoiseTexture2D.new()
	nt.noise = fn
	nt.seamless = true
	nt.width = 256
	nt.height = 256
	return nt


## colors: rid -> Color.
func set_map_colors(colors: Dictionary) -> void:
	if _plane_mat == null:
		return
	var arr := PackedColorArray()
	for i in MAX_PLANETS:
		if i < _plane_order.size():
			arr.append(colors.get(_plane_order[i], Color(0.4, 0.4, 0.4)))
		else:
			arr.append(Color.BLACK)
	_plane_mat.set_shader_parameter("fill_colors", arr)


## The point at t (0 core .. 1 tip) along a spiral arm.
func _arm_point(arm: int, t: float) -> Vector3:
	var theta := t * ARM_WIND + float(arm) * TAU / float(ARMS)
	var r := lerpf(ARM_R0, ARM_R1, pow(clampf(t, 0.0, 1.0), 0.85))
	return Vector3(cos(theta) * r, 0.0, sin(theta) * r)


func _build_environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.012, 0.010, 0.028)
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.glow_enabled = true
	env.glow_intensity = 1.5
	env.glow_bloom = 0.35
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.glow_hdr_threshold = 0.55
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -30, 0)
	sun.light_energy = 1.1
	add_child(sun)


func _build_star_field() -> void:
	var counts := {"arm": 16000, "bulge": 2600, "halo": 1400}
	var total: int = counts["arm"] + counts["bulge"] + counts["halo"]
	var mmi := _make_multimesh(total)
	var mm := mmi.multimesh
	var i := 0
	for n in counts["arm"]:
		var arm := _rng.randi() % ARMS
		var t := pow(_rng.randf(), 0.75)
		var p := _arm_point(arm, t)
		var spread := lerpf(1.2, 3.6, t)
		p += Vector3(_rng.randfn(0.0, spread), _rng.randfn(0.0, lerpf(0.8, 0.3, t)), _rng.randfn(0.0, spread))
		var s := _rng.randf_range(0.12, 0.40)
		if _rng.randf() < 0.02:
			s = _rng.randf_range(0.6, 1.1)
		_set_star(mm, i, p, s, _star_color(t))
		i += 1
	for n in counts["bulge"]:
		var p := Vector3(_rng.randfn(0.0, 3.1), _rng.randfn(0.0, 1.5), _rng.randfn(0.0, 3.1))
		var c := Color(1.0, 0.93, 0.8, _rng.randf_range(0.5, 1.0))
		_set_star(mm, i, p, _rng.randf_range(0.1, 0.3), c)
		i += 1
	for n in counts["halo"]:
		var ang := _rng.randf() * TAU
		var r := sqrt(_rng.randf()) * 66.0
		var p := Vector3(cos(ang) * r, _rng.randfn(0.0, 1.4), sin(ang) * r)
		_set_star(mm, i, p, _rng.randf_range(0.08, 0.2), Color(0.7, 0.75, 1.0, 0.25))
		i += 1
	sky_layers.append(mmi)
	add_child(mmi)


func _build_nebula() -> void:
	var entries: Array = []
	for arm in ARMS:
		for k in 90:
			var t := 0.04 + 0.96 * (float(k) + _rng.randf()) / 90.0
			var p := _arm_point(arm, t)
			var spread := lerpf(0.8, 2.2, t)
			p += Vector3(_rng.randfn(0.0, spread), _rng.randfn(0.0, 0.5), _rng.randfn(0.0, spread))
			var c := Color(0.30, 0.42, 1.0).lerp(Color(0.62, 0.36, 1.0), t)
			if _rng.randf() < 0.15:
				c = Color(0.85, 0.40, 0.90)
			c.a = _rng.randf_range(0.10, 0.17)
			entries.append([p, _rng.randf_range(3.5, 8.0), c])
	for n in 400:
		var arm := _rng.randi() % ARMS
		var t := pow(_rng.randf(), 0.7)
		var p := _arm_point(arm, t)
		var spread := lerpf(2.0, 5.5, t)
		p += Vector3(_rng.randfn(0.0, spread), _rng.randfn(0.0, 0.9), _rng.randfn(0.0, spread))
		var c := _haze_color(t)
		c.a = _rng.randf_range(0.05, 0.10)
		entries.append([p, _rng.randf_range(6.0, 13.0), c])
	# Core glow and a bright centre for the bloom.
	for n in 60:
		var p := Vector3(_rng.randfn(0.0, 2.2), _rng.randfn(0.0, 1.0), _rng.randfn(0.0, 2.2))
		entries.append([p, _rng.randf_range(4.0, 9.0), Color(1.0, 0.9, 0.78, 0.12)])
	entries.append([Vector3.ZERO, 18.0, Color(1.0, 0.90, 0.75, 0.30)])
	entries.append([Vector3.ZERO, 9.0, Color(1.0, 0.95, 0.85, 0.55)])
	entries.append([Vector3.ZERO, 4.5, Color(1.0, 1.0, 0.95, 0.90)])

	var mmi := _make_multimesh(entries.size(), _puff_tex)
	var mm := mmi.multimesh
	for i in entries.size():
		_set_star(mm, i, entries[i][0], entries[i][1], entries[i][2])
	sky_layers.append(mmi)
	add_child(mmi)


func _haze_color(t: float) -> Color:
	if t < 0.18:
		return Color(1.0, 0.85, 0.8)
	var roll := _rng.randf()
	if roll < 0.45:
		return Color(0.3, 0.4, 1.0)
	elif roll < 0.8:
		return Color(0.55, 0.35, 1.0)
	return Color(0.8, 0.35, 0.9)


func _build_backdrop() -> void:
	var mmi := _make_multimesh(1200)
	var mm := mmi.multimesh
	for i in 1200:
		var v := Vector3(_rng.randfn(0, 1), _rng.randfn(0, 1), _rng.randfn(0, 1)).normalized() * 800.0
		var c := Color(0.85, 0.88, 1.0, _rng.randf_range(0.2, 0.6))
		_set_star(mm, i, v, _rng.randf_range(0.9, 2.2), c)
	add_child(mmi)


func _star_color(t: float) -> Color:
	var roll := _rng.randf()
	var c: Color
	if roll < 0.55:
		c = Color(0.78, 0.85, 1.0)
	elif roll < 0.75:
		c = Color(0.72, 0.55, 1.0)
	elif roll < 0.9:
		c = Color(1.0, 0.88, 0.7)
	else:
		c = Color(1.0, 0.62, 0.85)
	c = c.lerp(Color(1.0, 0.93, 0.8), clampf(1.0 - t, 0.0, 1.0) * 0.5)
	c.a = _rng.randf_range(0.45, 1.0)
	return c


func _make_multimesh(count: int, tex: Texture2D = null) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	mm.mesh = quad
	mm.instance_count = count
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = _billboard_material(tex if tex else _dot_tex)
	return mmi


func _set_star(mm: MultiMesh, i: int, pos: Vector3, s: float, color: Color) -> void:
	var basis := Basis().scaled(Vector3(s, s, s))
	mm.set_instance_transform(i, Transform3D(basis, pos))
	mm.set_instance_color(i, color)


func _billboard_material(tex: Texture2D) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.billboard_keep_scale = true
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = tex
	m.disable_receive_shadows = true
	return m


func _make_dot_texture(size := 64) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var v := Vector2(x + 0.5, y + 0.5) / float(size) - Vector2(0.5, 0.5)
			var r := v.length() * 2.0
			var a := pow(clampf(1.0 - r, 0.0, 1.0), 2.6)
			a += pow(maxf(0.0, 1.0 - r * 3.0), 3.0) * 0.7
			img.set_pixel(x, y, Color(1, 1, 1, clampf(a, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


func _make_puff_texture(size := 128) -> ImageTexture:
	var noise := FastNoiseLite.new()
	noise.seed = SEED + 1
	noise.frequency = 0.05
	noise.fractal_octaves = 4
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var v := Vector2(x + 0.5, y + 0.5) / float(size) - Vector2(0.5, 0.5)
			var r := v.length() * 2.0
			var n := noise.get_noise_2d(x, y) * 0.5 + 0.5
			var a := pow(clampf(1.0 - r, 0.0, 1.0), 1.9) * (0.35 + 0.65 * n)
			img.set_pixel(x, y, Color(1, 1, 1, clampf(a, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


func _make_ring_texture(size := 96) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var v := Vector2(x + 0.5, y + 0.5) / float(size) - Vector2(0.5, 0.5)
			var r := v.length() * 2.0
			var a := exp(-pow((r - 0.72) / 0.10, 2.0))
			img.set_pixel(x, y, Color(1, 1, 1, clampf(a, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


func _make_planet_texture(base: Color, tex_seed: int) -> ImageTexture:
	var noise := FastNoiseLite.new()
	noise.seed = tex_seed
	noise.frequency = 0.03
	noise.fractal_octaves = 4
	var w := 256
	var h := 128
	var dark := base.darkened(0.65)
	var light := base.lightened(0.25)
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			# Sampled on the sphere, so the seam and the poles wrap.
			var lat := (float(y) / float(h) - 0.5) * PI
			var lon := float(x) / float(w) * TAU
			var d := Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon)) * 42.0
			var n := noise.get_noise_3d(d.x, d.y, d.z) * 0.5 + 0.5
			img.set_pixel(x, y, dark.lerp(light, n))
	return ImageTexture.create_from_image(img)
