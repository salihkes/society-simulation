extends RefCounted
## World geography: region catalog, map projection, region clocks, and the sun for a UTC instant at a longitude/latitude.

const CATALOG_PATH := "res://assets/world/region/regions.json"
const META_PATH := "res://assets/world/region/data/meta.json"
static var FALLBACK_HOME: String = Identity.value("home_region")
const FALLBACK_OFFSET := 3.0

static var _catalog: Dictionary = {}
static var _projection: Dictionary = {}
static var _projection_loaded := false


## A single home region at the origin when regions.json is missing or invalid.
static func catalog() -> Dictionary:
	if _catalog.is_empty():
		var parsed: Variant = null
		if FileAccess.file_exists(CATALOG_PATH):
			parsed = JSON.parse_string(FileAccess.get_file_as_string(CATALOG_PATH))
		if parsed is Dictionary and parsed.get("regions") is Array and not parsed.regions.is_empty():
			_catalog = parsed
		else:
			push_warning("[WorldGeo] %s missing or invalid; one region at the origin" % CATALOG_PATH)
			_catalog = {"home": FALLBACK_HOME, "regions": [{"id": FALLBACK_HOME, "center": [0, 0],
				"lonlat": Identity.value("home_lonlat"), "utc_offset": FALLBACK_OFFSET,
				"climate": {"winter": 6.0, "summer": 27.0, "humidity": 65.0}}]}
	return _catalog


static func regions() -> Array:
	return catalog().regions


static func home_id() -> String:
	return str(catalog().get("home", FALLBACK_HOME))


static func region(id: String) -> Dictionary:
	for r in regions():
		if str(r.get("id", "")) == id:
			return r
	return {}


static func center(r: Dictionary) -> Vector2:
	var c: Array = r.get("center", [0, 0])
	return Vector2(float(c[0]), float(c[1]))


## Builds-frame XZ.
static func region_at(xz: Vector2) -> Dictionary:
	var best: Dictionary = {}
	var best_d := INF
	for r in regions():
		var d := xz.distance_squared_to(center(r))
		if d < best_d:
			best_d = d
			best = r
	return best


## Hours a region's clocks are ahead of UTC.
static func utc_offset(id: String) -> float:
	var r := region(id)
	var v = r.get("utc_offset", FALLBACK_OFFSET)
	return float(v) if (v is float or v is int) else FALLBACK_OFFSET


static func home_offset() -> float:
	return utc_offset(home_id())


## 0..24.
static func local_hour(utc: float, id: String) -> float:
	return fposmod(utc / 3600.0 + utc_offset(id), 24.0)


## Unix days.
static func local_day(utc: float, id: String) -> int:
	return floori((utc + utc_offset(id) * 3600.0) / 86400.0)


## The unscaled Builds frame the catalog, the terrain and the projection all use.
static func builds_frame(tree: SceneTree) -> Node3D:
	if tree == null or tree.current_scene == null:
		return null
	var builds := tree.current_scene.get_node_or_null("Builds") as Node3D
	return builds if builds != null else tree.current_scene as Node3D


static func to_builds(tree: SceneTree, global_point: Vector3) -> Vector2:
	var frame := builds_frame(tree)
	var p := frame.to_local(global_point) if frame != null else global_point
	return Vector2(p.x, p.z)


## From the terrain bake's meta.json, or {} without one.
static func projection() -> Dictionary:
	if _projection_loaded:
		return _projection
	_projection_loaded = true
	if not FileAccess.file_exists(META_PATH):
		return _projection
	var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(META_PATH))
	if not (meta is Dictionary and meta.get("projection") is Dictionary):
		return _projection
	var p: Dictionary = meta.projection
	var d0 := float(p.d0)
	var a := (float(p.far_real) - float(p.far_game)) / pow(float(p.far_game) - d0, 2.0)
	var join := float(p.get("join", 22000.0))
	_projection = {
		"anchor": Vector2(float(p.anchor_xz[0]), float(p.anchor_xz[1])),
		"lon": float(p.real_anchor_lonlat[0]), "lat": float(p.real_anchor_lonlat[1]),
		"angle": deg_to_rad(float(p.bearing_x_deg)),
		"d0": d0, "a": a, "join": join,
		"slope": 1.0 + 2.0 * a * (join - d0),
		"join_real": join + a * pow(join - d0, 2.0),
		"compression": float(p.get("far_compression", 4.0)),
	}
	return _projection


## Map distance d to real: stretched near the anchor, compressed beyond the join.
static func _real_radius(p: Dictionary, d: float) -> float:
	if d <= p.join:
		return d + p.a * pow(maxf(d - p.d0, 0.0), 2.0)
	var t: float = d - p.join
	return p.join_real + p.slope * t + (p.compression - p.slope) * (t - 15000.0 * (1.0 - exp(-t / 15000.0)))


## Degrees; the nearest region's lonlat without a projection.
static func to_lonlat(xz: Vector2) -> Vector2:
	var p := projection()
	if p.is_empty():
		var r := region_at(xz)
		var ll: Array = r.get("lonlat", Identity.value("home_lonlat"))
		return Vector2(float(ll[0]), float(ll[1]))
	var dv: Vector2 = xz - p.anchor
	var d := dv.length()
	var k := _real_radius(p, d) / d if d > 1e-9 else 1.0
	var east := (dv.x * sin(p.angle) + dv.y * cos(p.angle)) * k
	var north := (dv.x * cos(p.angle) - dv.y * sin(p.angle)) * k
	return Vector2(p.lon + east / (111320.0 * cos(deg_to_rad(p.lat))), p.lat + north / 110574.0)


## Real north and east in the Builds frame; -Z north and +X east when not geographic.
static func compass(geographic: bool) -> Array[Vector2]:
	var p := projection()
	if not geographic or p.is_empty():
		return [Vector2(0, -1), Vector2(1, 0)]
	var a: float = p.angle
	return [Vector2(cos(a), -sin(a)), Vector2(sin(a), cos(a))]


## 1-based, UTC.
static func day_of_year(utc: float) -> int:
	var dt := Time.get_datetime_dict_from_unix_time(int(floor(utc)))
	var jan1 := Time.get_unix_time_from_datetime_dict({"year": dt.year, "month": 1, "day": 1,
		"hour": 0, "minute": 0, "second": 0})
	return int((floor(utc) - jan1) / 86400.0) + 1


## NOAA, about 1 degree accurate: {eqtime (minutes), decl (radians)}.
static func solar_terms(utc: float) -> Dictionary:
	var hour := fposmod(utc, 86400.0) / 3600.0
	var gamma := TAU / 365.0 * (float(day_of_year(utc)) - 1.0 + (hour - 12.0) / 24.0)
	var eqtime := 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
		- 0.014615 * cos(2.0 * gamma) - 0.040849 * sin(2.0 * gamma))
	var decl := (0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
		- 0.006758 * cos(2.0 * gamma) + 0.000907 * sin(2.0 * gamma)
		- 0.002697 * cos(3.0 * gamma) + 0.00148 * sin(3.0 * gamma))
	return {"eqtime": eqtime, "decl": decl}


## Radians; azimuth from north, clockwise to east.
static func sun_position(utc: float, lonlat: Vector2) -> Dictionary:
	var s := solar_terms(utc)
	var decl: float = s.decl
	var tst: float = fposmod(utc, 86400.0) / 60.0 + float(s.eqtime) + 4.0 * lonlat.x
	var ha := deg_to_rad(tst / 4.0 - 180.0)
	var lat := deg_to_rad(lonlat.y)
	var sin_e := clampf(sin(lat) * sin(decl) + cos(lat) * cos(decl) * cos(ha), -1.0, 1.0)
	var cos_e: float = maxf(sqrt(1.0 - sin_e * sin_e), 0.001)
	var sin_a := -cos(decl) * sin(ha) / cos_e
	var cos_a := (sin(decl) - sin(lat) * sin_e) / (cos(lat) * cos_e)
	return {"elevation": asin(sin_e), "azimuth": atan2(sin_a, cos_a)}


## +Y up.
static func sun_direction(utc: float, lonlat: Vector2, geographic_compass := false) -> Vector3:
	var sp := sun_position(utc, lonlat)
	var axes := compass(geographic_compass)
	var e: float = sp.elevation
	var az: float = sp.azimuth
	var flat: Vector2 = axes[0] * cos(az) * cos(e) + axes[1] * sin(az) * cos(e)
	return Vector3(flat.x, sin(e), flat.y).normalized()


## Unix seconds, plus that day's declination.
static func solar_noon(day_utc: float, lon: float) -> Dictionary:
	var midnight := floorf(day_utc / 86400.0) * 86400.0
	var s := solar_terms(midnight + 43200.0 - lon * 240.0)
	return {"noon": midnight + (720.0 - 4.0 * lon - float(s.eqtime)) * 60.0, "decl": s.decl}


## Clamped where the sun never reaches elev (radians).
static func hours_from_noon(lat_deg: float, decl: float, elev: float) -> float:
	var lat := deg_to_rad(lat_deg)
	var x := (sin(elev) - sin(lat) * sin(decl)) / (cos(lat) * cos(decl))
	return rad_to_deg(acos(clampf(x, -1.0, 1.0))) / 15.0
