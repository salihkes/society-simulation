@tool
class_name GalaxyPlanets
## The authored planet catalogue and its politics (entities, organisations, zone colours).

const HOME_RID := "planet_8"
## Light-years per galaxy map unit.
const UNIT_LY := 862.0

const JsonData := preload("res://src/core/json_data.gd")
const DATA_PATH := "res://assets/world/galaxy/planets.json"
const DEFAULT_ORG := "hre"

static var _tables: Dictionary = JsonData.read(DATA_PATH)
## Organisations, each drawn with one outer border.
static var ORGS: Dictionary = _with_colors(_tables.get("orgs", {}))
## Multi-planet states, whose planets share one zone colour.
static var ENTITIES: Dictionary = _with_colors(_tables.get("entities", {}))
## "galaxy": {"arm": 0..2, "t": 0..1, "side", "y"} or "position": [x, y, z]; optional "entity", "org" ("" opts out), "scene".
static var PLANETS: Dictionary = _planets(_tables.get("planets", {}))


## rid -> zone colour; zones of the same colour merge into one territory in the shader.
static func colors() -> Dictionary:
	var out := {}
	for rid in PLANETS:
		var e := str(PLANETS[rid].get("entity", ""))
		out[rid] = ENTITIES[e]["color"] if ENTITIES.has(e) else _planet_color(str(rid))
	return out


## rid -> organisation colour for the macro overlay, for planets in one.
static func org_colors() -> Dictionary:
	var out := {}
	for rid in PLANETS:
		var o := org_of(str(rid))
		if ORGS.has(o):
			out[rid] = ORGS[o]["color"]
	return out


static func org_of(rid: String) -> String:
	return str(PLANETS.get(rid, {}).get("org", DEFAULT_ORG))


## Entity and organisation names joined with " · ", or "Unaligned".
static func describe(rid: String) -> String:
	var def: Dictionary = PLANETS.get(rid, {})
	var parts: Array[String] = []
	var e := str(def.get("entity", ""))
	if ENTITIES.has(e):
		parts.append(str(ENTITIES[e]["name"]))
	var o := org_of(rid)
	if ORGS.has(o):
		parts.append(str(ORGS[o]["name"]))
	return " · ".join(parts) if not parts.is_empty() else "Unaligned"


static func _planet_color(rid: String) -> Color:
	return Color.from_hsv(float(posmod(rid.hash(), 360)) / 360.0, 0.52, 0.85)


static func _with_colors(table: Dictionary) -> Dictionary:
	for key in table:
		var c: Array = table[key]["color"]
		table[key]["color"] = Color(c[0], c[1], c[2])
	return table


static func _planets(table: Dictionary) -> Dictionary:
	for rid in table:
		var galaxy = table[rid].get("galaxy")
		if galaxy is Dictionary and galaxy.has("arm"):
			galaxy["arm"] = int(galaxy["arm"])
	return table
