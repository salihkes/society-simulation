extends RefCounted
## A resident's schedule without a body, hashed so every peer agrees on the same plan.

const HOME_RADIUS := 2.0


## Shifted by up to +-"jitter" hours.
static func entry_hour(ped_id: String, entry: Dictionary, idx: int, day: int) -> float:
	var h := float(entry.get("hour", 0.0))
	var jitter := float(entry.get("jitter", 0.0))
	if jitter > 0.0:
		var r := _unit_hash("%s|%d|%d|h" % [ped_id, day, idx])
		h += (r - 0.5) * 2.0 * jitter
	return clampf(h, 0.0, 23.99)


## Uses the entry's "days" (Monday = 0) and "chance".
static func active_today(ped_id: String, entry: Dictionary, idx: int, day: int, weekday: int) -> bool:
	if entry.has("days"):
		var today := false
		for d in entry.get("days", []):
			if int(d) == weekday:
				today = true
				break
		if not today:
			return false
	var chance := float(entry.get("chance", 1.0))
	if chance >= 1.0:
		return true
	return _unit_hash("%s|%d|%d|c" % [ped_id, day, idx]) < chance


## A stable number in [0, 1).
static func _unit_hash(key: String) -> float:
	return float(hash(key) % 10000) / 10000.0


## [{entry, at, idx}] in order.
static func plan(def: Dictionary, ped_id: String, day: int, weekday: int) -> Array:
	var out := []
	var routine: Array = def.get("routine", [])
	for idx in routine.size():
		var entry: Dictionary = routine[idx]
		if not active_today(ped_id, entry, idx, day, weekday):
			continue
		out.append({"entry": entry, "at": entry_hour(ped_id, entry, idx, day), "idx": idx})
	out.sort_custom(func(a, b): return float(a.at) < float(b.at) or (float(a.at) == float(b.at) and int(a.idx) < int(b.idx)))
	return out


## The latest entry whose hour has passed, else yesterday's last one.
static func current_entry(def: Dictionary, ped_id: String, hour: float, day: int, weekday: int) -> Dictionary:
	var today := plan(def, ped_id, day, weekday)
	if today.is_empty():
		return {}
	var best: Dictionary = {}
	for it in today:
		if float(it.at) <= hour:
			best = it.entry
	if best.is_empty():
		best = today[-1].entry
	return best


static func entry_pos(entry: Dictionary) -> Vector3:
	var p = entry.get("pos", null)
	if typeof(p) == TYPE_ARRAY and p.size() >= 3:
		return Vector3(float(p[0]), float(p[1]), float(p[2]))
	return Vector3.INF


## The last routine entry's "pos", else Vector3.INF.
static func home_pos(def: Dictionary) -> Vector3:
	var routine: Array = def.get("routine", [])
	for i in range(routine.size() - 1, -1, -1):
		var p := entry_pos(routine[i])
		if p != Vector3.INF:
			return p
	return Vector3.INF


static func is_extra(def: Dictionary) -> bool:
	if str(def.get("script", "")) != "":
		return false
	var life = def.get("life", true)
	return life is bool and not life


static func entry_is_away(def: Dictionary, entry: Dictionary) -> bool:
	if entry.is_empty():
		return false
	if str(entry.get("do", "")) != "" or entry.has("place") or entry.has("marker"):
		return true
	var p := entry_pos(entry)
	var home := home_pos(def)
	if p == Vector3.INF:
		return false
	if home == Vector3.INF:
		return true
	return p.distance_to(home) > HOME_RADIUS


static func on_the_map(def: Dictionary, ped_id: String, hour: float, day: int, weekday: int) -> bool:
	if not is_extra(def):
		return true
	return entry_is_away(def, current_entry(def, ped_id, hour, day, weekday))
