extends RefCounted
class_name StageScore
## Compiles a hand-written cue score (`"format": "cues"`) into full-pose keys StagePerformance can sample.


## Tracks become keys in radians; a cue looks like {"t": 3, "move": "hakobi", "to": [0, 0]}.
static func compile(score: Dictionary) -> Dictionary:
	var out := score.duplicate()
	var names := []
	for spec in score.get("cast", []):
		names.append(String(spec.get("name", "")))
	var cues: Array = score.get("tracks", [])
	var first := []
	for i in cues.size():
		first.append(compile_track(cues[i], String(names[i]) if i < names.size() else ""))
	var resolver := func(who: String, t: float) -> Variant:
		var idx := names.find(who)
		return position_at(first[idx], t) if idx >= 0 and idx < first.size() else null
	var tracks := []
	for i in cues.size():
		tracks.append(compile_track(cues[i], String(names[i]) if i < names.size() else "", resolver))
	for keys in tracks:
		_fill_travel(keys)
	out["tracks"] = tracks
	out["_compiled"] = true
	return out


## `resolver` maps (track name, time) to a stage position, for looks at another track.
static func compile_track(cues: Array, track_name := "", resolver := Callable()) -> Array:
	var keys := []
	var pose := StagePose.standing()
	var t_end := 0.0
	var sorted := cues.duplicate()
	sorted.sort_custom(func(a, b): return float(a.get("t", 0.0)) < float(b.get("t", 0.0)))
	for cue in sorted:
		var move := String(cue.get("move", "hold"))
		if not StageMoves.has(move):
			push_warning("StageScore: unknown move '%s' on %s" % [move, track_name])
			continue
		var start := maxf(float(cue.get("t", 0.0)), t_end)
		if start > t_end + 1e-6 or keys.is_empty():
			keys.append(_key(start, pose))   # hold the previous pose until the cue starts
		var frames := StageMoves.frames(move, cue, pose)
		if frames.is_empty():
			continue
		for frame in frames:
			var partial: Dictionary = frame.pose
			var sound := String(partial.get("sound", ""))
			var at := start + float(frame.dt)
			pose = _apply_frame(pose, partial, at, resolver)
			var key := _key(at, pose)
			if sound != "":
				key["sound"] = sound   # played when playback crosses this key
			if at <= t_end + 1e-6 and not keys.is_empty():
				keys[keys.size() - 1] = key   # a zero-length frame replaces the hold
			else:
				keys.append(key)
			t_end = maxf(t_end, at)
	return keys


## `sound` and `look_track` are not pose channels.
static func _apply_frame(pose: Dictionary, partial: Dictionary, at: float, resolver: Callable) -> Dictionary:
	var look_track := String(partial.get("look_track", ""))
	if partial.has("look_track") or partial.has("sound"):
		partial = partial.duplicate()
		partial.erase("look_track")
		partial.erase("sound")
	pose = StagePose.merge(pose, StagePose.from_degrees(partial))
	if look_track == "" or not resolver.is_valid():
		return pose
	var other = resolver.call(look_track, at)
	if other != null:
		var world_yaw := StagePose.yaw_toward(Vector2(float(pose.x), float(pose.z)), other)
		pose["head_yaw"] = angle_difference(float(pose.yaw), world_yaw)
	return pose


static func _key(t: float, pose: Dictionary) -> Dictionary:
	var key := StagePose.copy(pose)
	key["t"] = t
	return key


static func _fill_travel(keys: Array) -> void:
	var travel := 0.0
	for i in keys.size():
		if i > 0:
			var a: Dictionary = keys[i - 1]
			var b: Dictionary = keys[i]
			travel += Vector2(float(a.x), float(a.z)).distance_to(Vector2(float(b.x), float(b.z)))
		keys[i]["travel"] = travel


## Adds `speed`; `hint` is a key cursor the caller keeps for monotonic playback (-1 to search).
static func sample(keys: Array, t: float, hint := -1) -> Dictionary:
	if keys.is_empty():
		return StagePose.standing()
	var i := hint
	if i < 0 or i >= keys.size() or float(keys[i].t) > t:
		i = 0
	while i + 1 < keys.size() and float(keys[i + 1].t) <= t:
		i += 1
	var a: Dictionary = keys[i]
	var b: Dictionary = keys[mini(i + 1, keys.size() - 1)]
	var span := float(b.t) - float(a.t)
	var w := 0.0 if span <= 0.0 else clampf((t - float(a.t)) / span, 0.0, 1.0)
	var pose := StagePose.blend(a, b, w)
	pose["speed"] = 0.0 if span <= 0.0 else (float(b.travel) - float(a.travel)) / span
	pose["_cursor"] = i
	return pose


static func position_at(keys: Array, t: float) -> Vector2:
	var p := sample(keys, t)
	return Vector2(float(p.x), float(p.z))
