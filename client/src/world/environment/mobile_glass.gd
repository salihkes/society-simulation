extends Node
## Turns the city's opaque-painted glazing into glass: city_glass.gdshader, or glass_vr.tres on Android.

const GLASS := "res://src/world/environment/city_glass.gdshader"
const GLASS_VR := "res://assets/world/environment/glass_vr.tres"

## Name prefix of glazing nodes (and of the chunks the city bake splits them into).
const GLASS_NODE_PREFIX := "model_001"
## Meta on a city's root naming a different glazing prefix for that city.
const GLASS_META := "glass_node_prefix"

## Desktop: how far the tint moves from clear towards the (far too dark) authored paint colour.
const TINT_STRENGTH := 0.5

## Android: how much of the authored tint survives, and the pane's opacity.
const TINT_KEEP := 0.92
const PANE_ALPHA := 0.82

var _shader: Shader
var _base: StandardMaterial3D
## Source material -> its glass.
var _variants := {}
var use_shader := not OS.has_feature("android")
var _pending: Array[MeshInstance3D] = []
var _done := {}
var swapped := 0


func _ready() -> void:
	start()


## Queues every glazing mesh now and as nodes are added; returns at once if already started.
func start() -> void:
	if get_tree().node_added.is_connected(_on_node_added):
		return
	if use_shader:
		_shader = load(GLASS)
	else:
		_base = load(GLASS_VR)
	if _shader == null and _base == null:
		push_warning("[MobileGlass] %s missing; city glazing left as authored"
			% (GLASS if use_shader else GLASS_VR))
		set_process(false)
		return
	get_tree().node_added.connect(_on_node_added)
	_scan(get_tree().root)
	set_process(not _pending.is_empty())


func _scan(node: Node) -> void:
	_on_node_added(node)
	for c in node.get_children():
		_scan(c)


func _on_node_added(node: Node) -> void:
	if node is MeshInstance3D and is_glazing(node):
		_pending.append(node)
		set_process(true)


## Applies glass a frame after the meshes enter the tree, once their surfaces are set.
func _process(_delta: float) -> void:
	for mi in _pending:
		if is_instance_valid(mi):
			apply_to(mi)
	_pending.clear()
	set_process(false)


## Overrides every paint or baked-glass surface of mi once; returns how many.
func apply_to(mi: MeshInstance3D) -> int:
	if mi.mesh == null or _done.has(mi):
		return 0
	_done[mi] = true
	var n := 0
	for s in mi.mesh.get_surface_count():
		var src := mi.mesh.surface_get_material(s)
		var authored: Variant = _authored_color(src)
		if authored == null:
			continue
		# Already baked glass.
		if use_shader and src is ShaderMaterial:
			continue
		mi.set_surface_override_material(s, _variant_for(src, authored))
		n += 1
	swapped += n
	return n


## True when the name starts with the nearest GLASS_META prefix, else GLASS_NODE_PREFIX.
static func is_glazing(node: Node) -> bool:
	var prefix := GLASS_NODE_PREFIX
	var n := node
	while n != null:
		if n.has_meta(GLASS_META):
			prefix = n.get_meta(GLASS_META)
			break
		n = n.get_parent()
	return node.name.begins_with(prefix)


## The bake calls this too.
static func desktop_glass(src: BaseMaterial3D, shader: Shader) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.resource_name = src.resource_name + "_glass"
	sm.shader = shader
	var tint := Color.WHITE.lerp(src.albedo_color, TINT_STRENGTH)
	sm.set_shader_parameter("tint", Vector3(tint.r, tint.g, tint.b))
	# The headset rebuilds its own glass from the paint, not from the tint.
	sm.set_meta("authored_color", src.albedo_color)
	return sm


## The pane's authored paint, whether the surface is still paint or baked glass.
func _authored_color(m: Material) -> Variant:
	if m is BaseMaterial3D:
		return (m as BaseMaterial3D).albedo_color
	if m is ShaderMaterial and m.has_meta("authored_color"):
		return m.get_meta("authored_color")
	return null


## Cached glass for src: shader glass on desktop, a tinted copy of the base material on Android.
func _variant_for(src: Material, authored: Color) -> Material:
	var cached: Material = _variants.get(src)
	if cached != null:
		return cached
	var m: Material
	if use_shader:
		m = desktop_glass(src as BaseMaterial3D, _shader)
	else:
		var vm: StandardMaterial3D = _base.duplicate()
		var tint := authored.lerp(Color.WHITE, 1.0 - TINT_KEEP)
		vm.albedo_color = Color(tint.r, tint.g, tint.b, PANE_ALPHA)
		m = vm
	_variants[src] = m
	return m
