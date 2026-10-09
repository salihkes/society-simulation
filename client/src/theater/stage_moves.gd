extends RefCounted
class_name StageMoves
## Named kata that expand into timed partial poses: [{dt: seconds after cue start, pose: partial, degrees}].

const TURN_RATE := deg_to_rad(60.0)     # slow whole-body turn, rad/s
const SLIDE_SPEED := 1.0                # hakobi, stage units per second
const STRIDE_SPEED := 3.0               # ordinary walk


static func names() -> Array:
	return _REGISTRY.keys()


static func has(move: String) -> bool:
	return _REGISTRY.has(move)


## Returns [] for an unknown movement.
static func frames(move: String, params: Dictionary, ctx: Dictionary) -> Array:
	if not _REGISTRY.has(move):
		return []
	return (_REGISTRY[move] as Callable).call(params, ctx)


## A limb of `ctx` (radians) as [pitch, spread, flex] in degrees.
static func _limb_deg(ctx: Dictionary, limb: String) -> Array:
	var e: Array = ctx[limb]
	return [rad_to_deg(float(e[0])), rad_to_deg(float(e[1])), rad_to_deg(float(e[2]))]


static func _side(params: Dictionary, fallback := "right") -> String:
	return String(params.get("side", fallback))


static func _arm(side: String) -> String:
	return "left_arm" if side == "left" else "right_arm"


static func _leg(side: String) -> String:
	return "left_leg" if side == "left" else "right_leg"


static func _other(side: String) -> String:
	return "left" if side == "right" else "right"


static func _pos(ctx: Dictionary) -> Vector2:
	return Vector2(float(ctx.x), float(ctx.z))


static func _frame(dt: float, pose: Dictionary) -> Dictionary:
	return {"dt": dt, "pose": pose}


const KAMAE := {
	"": {"arm": [25.0, 15.0, 60.0], "leg": [12.0, 4.0, 12.0]},
	"feminine": {"arm": [22.0, 8.0, 65.0], "leg": [12.0, 0.0, 10.0]},
	"martial": {"arm": [30.0, 35.0, 55.0], "leg": [14.0, 12.0, 16.0]},
}


## Ready stance: knees soft, arms ringed in front, closed fan in the right hand.
static func kamae(params: Dictionary, _ctx: Dictionary) -> Array:
	var mode: Dictionary = KAMAE.get(String(params.get("mode", "")), KAMAE[""])
	return [_frame(float(params.get("dur", 1.2)), {
		"left_arm": mode.arm, "right_arm": mode.arm, "left_leg": mode.leg, "right_leg": mode.leg,
		"bow": 0.0, "head_pitch": 0.0, "head_yaw": 0.0, "fan": "hand", "fan_open": 0.0,
	})]


## Plain standing: everything straight, nothing in hand.
static func stand(params: Dictionary, ctx: Dictionary) -> Array:
	var out := []
	var t := 0.0
	if StagePose.seated(ctx):
		t = 0.8
		out.append(_frame(t, _kneel_pose("right")))
	t += float(params.get("dur", 1.0))
	out.append(_frame(t, {
		"left_arm": [0, 0, 0], "right_arm": [0, 0, 0], "left_leg": [0, 0, 0], "right_leg": [0, 0, 0],
		"bow": 0.0, "head_pitch": 0.0, "head_yaw": 0.0,
	}))
	return out


## Palms together at the chest, head a little down.
static func prayer(params: Dictionary, _ctx: Dictionary) -> Array:
	return [_frame(float(params.get("dur", 1.5)), {
		"left_arm": [40.0, -80.0, 75.0], "right_arm": [40.0, -80.0, 75.0], "head_pitch": -8.0,
	})]


## Slide gait to `to` [x, z], then optionally turn to `face` degrees.
static func hakobi(params: Dictionary, ctx: Dictionary) -> Array:
	return _travel(params, ctx, "slide", SLIDE_SPEED)


## With the humanoid's own stride.
static func walk(params: Dictionary, ctx: Dictionary) -> Array:
	return _travel(params, ctx, "stride", STRIDE_SPEED)


static func _travel(params: Dictionary, ctx: Dictionary, gait: String, default_speed: float) -> Array:
	var out := []
	var from := _pos(ctx)
	var to_arr: Array = params.get("to", [from.x, from.y])
	var to := Vector2(float(to_arr[0]), float(to_arr[1]))
	var speed := float(params.get("speed", default_speed))
	var yaw := float(ctx.yaw)
	var t := 0.0
	var dist := from.distance_to(to)
	if dist > 1e-3:
		var heading := StagePose.yaw_toward(from, to)
		t += absf(angle_difference(yaw, heading)) / TURN_RATE
		out.append(_frame(t, {"yaw": rad_to_deg(heading), "gait": gait}))
		t += dist / maxf(speed, 1e-3)
		out.append(_frame(t, {"x": to.x, "z": to.y, "yaw": rad_to_deg(heading), "gait": gait}))
		yaw = heading
	if params.has("face"):
		var face := deg_to_rad(float(params.face))
		t += maxf(absf(angle_difference(yaw, face)) / TURN_RATE, 0.1)
		out.append(_frame(t, {"yaw": params.face}))
	if out.is_empty():
		out.append(_frame(0.1, {}))
	return out


## To `face` (degrees, 0 = the house) or by `by` degrees.
static func turn(params: Dictionary, ctx: Dictionary) -> Array:
	var yaw := float(ctx.yaw)
	var target := yaw + deg_to_rad(float(params.by)) if params.has("by") else deg_to_rad(float(params.get("face", 0.0)))
	var t := maxf(absf(angle_difference(yaw, target)) / TURN_RATE, 0.1)
	return [_frame(t, {"yaw": rad_to_deg(target)})]


## `steps` (default 1) of `step` units (default 0.4, negative for back), without turning.
static func step(params: Dictionary, ctx: Dictionary) -> Array:
	var n := int(params.get("steps", 1))
	var length := float(params.get("step", 0.4))
	var head := StagePose.heading(float(ctx.yaw))
	var to := _pos(ctx) + head * length * n
	var t := absf(length * n) / SLIDE_SPEED
	return [_frame(maxf(t, 0.1), {"x": to.x, "z": to.y, "gait": "slide"})]


## One foot lifts a hand's width and comes down flat; `count` repeats.
static func stamp(params: Dictionary, ctx: Dictionary) -> Array:
	var leg := _leg(_side(params))
	var rest := _limb_deg(ctx, leg)
	var out := []
	var t := 0.0
	for i in int(params.get("count", 1)):
		t += 0.25
		out.append(_frame(t, {leg: [rest[0] + 20.0, rest[1], rest[2] + 35.0]}))
		t += 0.25
		out.append(_frame(t, {leg: rest}))
	return out


const SEIZA_LEGS := [30.0, 0.0, 120.0]
const SEIZA_ARMS := [12.0, -14.0, 24.0]


## The `side` knee down, the other foot planted ahead.
static func _kneel_pose(side: String) -> Dictionary:
	var out := {_leg(side): [0.0, 3.0, 90.0], _leg(_other(side)): [90.0, 8.0, 90.0]}
	out["left_arm"] = [10.0, -10.0, 20.0]
	out["right_arm"] = [10.0, -10.0, 20.0]
	return out


## Kneel to sit: one knee down, then the other, then settle on the heels.
static func seiza(params: Dictionary, _ctx: Dictionary) -> Array:
	var side := _side(params)
	var dur := float(params.get("dur", 2.0))
	return [
		_frame(dur * 0.4, _kneel_pose(side)),
		_frame(dur, {"left_leg": SEIZA_LEGS, "right_leg": SEIZA_LEGS, "left_arm": SEIZA_ARMS, "right_arm": SEIZA_ARMS,
			"bow": 0.0, "fan": "floor", "fan_open": 0.0}),
	]


## Rise from seiza through the one-knee kneel into kamae.
static func rise(params: Dictionary, ctx: Dictionary) -> Array:
	var side := _side(params)
	var dur := float(params.get("dur", 2.0))
	var out := [_frame(dur * 0.5, _kneel_pose(side))]
	for f in kamae(params, ctx):
		f.dt += dur
		out.append(f)
	return out


## Katahiza: the rest between phrases, the pose for prayer.
static func kneel(params: Dictionary, _ctx: Dictionary) -> Array:
	return [_frame(float(params.get("dur", 1.2)), _kneel_pose(_side(params)))]


## `depth` degrees (default 30) for `hold` seconds; seated, the hands go to the floor (rei).
static func bow(params: Dictionary, ctx: Dictionary) -> Array:
	var depth := float(params.get("depth", 30.0))
	var down := float(params.get("dur", 1.2))
	var hold := float(params.get("hold", 0.8))
	var seated := StagePose.seated(ctx)
	var arms_in := {"left_arm": [35.0, -20.0, 0.0], "right_arm": [35.0, -20.0, 0.0]} if seated else {}
	var arms_out := {"left_arm": _limb_deg(ctx, "left_arm"), "right_arm": _limb_deg(ctx, "right_arm")} if seated else {}
	var dip := {"bow": depth, "head_pitch": -5.0}
	dip.merge(arms_in)
	var up := {"bow": 0.0, "head_pitch": 0.0}
	up.merge(arms_out)
	return [_frame(down, dip), _frame(down + hold, dip), _frame(down + hold + down, up)]


## Cloud the mask: tilt down, sorrow. `angle` degrees (default 15).
static func kumorasu(params: Dictionary, _ctx: Dictionary) -> Array:
	return [_frame(float(params.get("dur", 1.5)), {"head_pitch": -absf(float(params.get("angle", 15.0)))})]


## Shine the mask: tilt up, joy.
static func terasu(params: Dictionary, _ctx: Dictionary) -> Array:
	return [_frame(float(params.get("dur", 1.5)), {"head_pitch": absf(float(params.get("angle", 15.0)))})]


static func head_level(params: Dictionary, _ctx: Dictionary) -> Array:
	return [_frame(float(params.get("dur", 1.0)), {"head_pitch": 0.0, "head_yaw": 0.0})]


## `at` [x, z] or a track name, or `yaw`/`pitch` degrees relative to the body.
static func look(params: Dictionary, ctx: Dictionary) -> Array:
	var dur := float(params.get("dur", 1.0))
	var pose := {"head_pitch": float(params.get("pitch", 0.0))}
	if params.has("at") and params.at is Array:
		var target := Vector2(float(params.at[0]), float(params.at[1]))
		var world_yaw := StagePose.yaw_toward(_pos(ctx), target)
		pose["head_yaw"] = rad_to_deg(angle_difference(float(ctx.yaw), world_yaw))
	elif params.has("at"):
		pose["look_track"] = String(params.at)   # the compiler fills head_yaw
	else:
		pose["head_yaw"] = float(params.get("yaw", 0.0))
	return [_frame(dur, pose)]


## Forward point: two short slides while the fan hand rises to shoulder height.
static func shikake(params: Dictionary, ctx: Dictionary) -> Array:
	var arm := _arm(_side(params))
	var head := StagePose.heading(float(ctx.yaw))
	var to := _pos(ctx) + head * float(params.get("advance", 0.8))
	return [_frame(float(params.get("dur", 2.0)), {arm: [80.0, -5.0, 15.0], "x": to.x, "z": to.y, "gait": "slide"})]


## Pointing far: the fan hand draws back, then arcs forward to the eyes, gaze lifting.
static func sashi(params: Dictionary, _ctx: Dictionary) -> Array:
	var arm := _arm(_side(params))
	var dur := float(params.get("dur", 2.5))
	return [
		_frame(dur * 0.3, {arm: [30.0, 10.0, 30.0]}),
		_frame(dur, {arm: [110.0, 0.0, 5.0], "head_pitch": 10.0}),
	]


## Open retreat: three slides back while both arms open outward, then kamae.
static func hiraki(params: Dictionary, ctx: Dictionary) -> Array:
	var dur := float(params.get("dur", 4.0))
	var head := StagePose.heading(float(ctx.yaw))
	var to := _pos(ctx) - head * float(params.get("retreat", 1.2))
	var open := [30.0, 45.0, 20.0]
	var settle: Dictionary = KAMAE[""]
	return [
		_frame(dur * 0.8, {"left_arm": open, "right_arm": open, "x": to.x, "z": to.y, "gait": "slide", "head_pitch": 0.0}),
		_frame(dur, {"left_arm": settle.arm, "right_arm": settle.arm}),
	]


## Scooping point: the fan hand dips low, then rises into a forward point.
static func kaikomi(params: Dictionary, _ctx: Dictionary) -> Array:
	var arm := _arm(_side(params))
	var dur := float(params.get("dur", 2.0))
	return [_frame(dur * 0.4, {arm: [10.0, 30.0, 10.0]}), _frame(dur, {arm: [85.0, 0.0, 10.0]})]


## Weeping: a hand before the eyes, head down; `side` right, left or both.
static func shiori(params: Dictionary, _ctx: Dictionary) -> Array:
	var side := _side(params)
	var hand := [85.0, -55.0, 80.0]
	var pose := {"head_pitch": -12.0}
	if side == "both":
		pose["left_arm"] = hand
		pose["right_arm"] = hand
	else:
		pose[_arm(side)] = hand
	return [_frame(float(params.get("dur", 1.5)), pose)]


## Cloud fan: open fan raised high while stepping back, gaze up.
static func kumo_no_ogi(params: Dictionary, ctx: Dictionary) -> Array:
	var dur := float(params.get("dur", 4.0))
	var head := StagePose.heading(float(ctx.yaw))
	var to := _pos(ctx) - head * 1.0
	return [
		_frame(dur * 0.3, {"left_arm": [60.0, -25.0, 40.0], "right_arm": [60.0, -25.0, 40.0], "fan": "hand", "fan_open": 1.0}),
		_frame(dur, {"left_arm": [20.0, 40.0, 10.0], "right_arm": [120.0, 25.0, 10.0], "head_pitch": 20.0,
			"x": to.x, "z": to.y, "gait": "slide"}),
	]


## Fan flourish: the open fan sweeps across the body.
static func yuken(params: Dictionary, _ctx: Dictionary) -> Array:
	var arm := _arm(_side(params))
	var dur := float(params.get("dur", 1.4))
	return [
		_frame(dur * 0.3, {arm: [90.0, 60.0, 10.0], "fan": "hand", "fan_open": 1.0}),
		_frame(dur, {arm: [90.0, -20.0, 10.0]}),
	]


## Fan: `state` "open", "closed", "floor" (laid down ahead), "none".
static func fan(params: Dictionary, _ctx: Dictionary) -> Array:
	var dur := float(params.get("dur", 0.8))
	match String(params.get("state", "closed")):
		"open":
			return [_frame(dur, {"fan": "hand", "fan_open": 1.0})]
		"floor":
			return [_frame(dur, {"fan": "floor", "fan_open": 0.0})]
		"none":
			return [_frame(dur, {"fan": "", "fan_open": 0.0})]
		_:
			return [_frame(dur, {"fan": "hand", "fan_open": 0.0})]


## Every kit sound's duration (from tools/art/theater/cut_hayashi.py).
const KIT_MANIFEST := "res://assets/art/sound/theater/hayashi/kit.json"
static var _kit := {}
static var _kit_loaded := false


## name -> {duration, ...}, read once.
static func kit() -> Dictionary:
	if not _kit_loaded:
		_kit_loaded = true
		if FileAccess.file_exists(KIT_MANIFEST):
			var parsed = JSON.parse_string(FileAccess.get_file_as_string(KIT_MANIFEST))
			if parsed is Dictionary:
				_kit = parsed
	return _kit


static func kit_duration(name: String, fallback := 1.0) -> float:
	return float(kit().get(name, {}).get("duration", fallback))


## Repeats `pulses` [period fraction, partial pose, optional sound or sounds] every `period` for `dur` seconds.
static func _loop(params: Dictionary, base: Dictionary, default_period: float, pulses: Array) -> Array:
	var period := float(params.get("period", default_period))
	var dur := float(params.get("dur", period * 4.0))
	var lead := float(params.get("lead", 0.6))   # settle into the base pose first
	var out := [_frame(lead, base)]
	var t := lead
	var beat := 0
	var ordered := pulses.duplicate()
	ordered.sort_custom(func(a, b): return float(a[0]) < float(b[0]))   # frames must be in time order
	while t + period <= dur + lead + 1e-6:
		for pulse in ordered:
			out.append(_frame(t + float(pulse[0]) * period, _pulse_pose(pulse, beat)))
		t += period
		beat += 1
	return out


static func _pulse_pose(pulse: Array, beat: int) -> Dictionary:
	var pose: Dictionary = (pulse[1] as Dictionary).duplicate()
	if pulse.size() <= 2:
		return pose
	var sound = pulse[2]
	if sound is Array:
		sound = sound[beat % sound.size()]
	if String(sound) != "":
		pose["sound"] = String(sound)
	return pose


## Chorus chant: seiza, hands on the thighs, a two-degree rock on the beat.
static func chant(params: Dictionary, _ctx: Dictionary) -> Array:
	var base := {"left_leg": SEIZA_LEGS, "right_leg": SEIZA_LEGS, "left_arm": SEIZA_ARMS, "right_arm": SEIZA_ARMS, "bow": 0.0, "fan": "floor"}
	var rock := float(params.get("rock", 2.0))
	return _loop(params, base, 1.2, [[0.0, {"bow": rock, "head_pitch": 2.0}], [0.5, {"bow": 0.0, "head_pitch": 0.0}]])


## Shoulder drum: the call comes late in the beat, the stroke on the next downbeat.
static func kotsuzumi(params: Dictionary, _ctx: Dictionary) -> Array:
	var base := {"left_leg": SEIZA_LEGS, "right_leg": SEIZA_LEGS, "left_arm": [125.0, -70.0, 5.0], "right_arm": [15.0, -70.0, 120.0], "prop": "kotsuzumi", "fan": ""}
	return _loop(params, base, 1.0, [
		[0.0, {"right_arm": [35.0, -70.0, 120.0]}, ["kotsuzumi/pon_1", "kotsuzumi/pon_2", "kotsuzumi/ta_1", "kotsuzumi/pon_1", "kotsuzumi/pu_1", "kotsuzumi/pon_2", "kotsuzumi/chi_1", "kotsuzumi/pon_1"]],
		[0.12, {"right_arm": [15.0, -70.0, 120.0]}],
		[0.55, {"head_pitch": 6.0}, ["calls/kotsuzumi_yo", "", "calls/kotsuzumi_ho", "", "", "calls/kotsuzumi_iya", "", ""]],
		[0.8, {"head_pitch": 0.0}],
	])


## Hip drum: right arm raised high and brought down hard; the call precedes the stroke.
static func otsuzumi(params: Dictionary, _ctx: Dictionary) -> Array:
	var base := {"left_leg": SEIZA_LEGS, "right_leg": SEIZA_LEGS, "left_arm": [0.0, -25.0, 90.0], "right_arm": [120.0, 20.0, 10.0], "prop": "otsuzumi", "fan": ""}
	return _loop(params, base, 1.0, [
		[0.1, {"head_pitch": 6.0}, ["calls/otsuzumi_yo", "", "calls/otsuzumi_ho", "", "calls/otsuzumi_iya", "", "", ""]],
		[0.4, {"right_arm": [125.0, 22.0, 10.0], "head_pitch": 0.0}],
		[0.5, {"right_arm": [45.0, -60.0, 5.0]}, ["otsuzumi/chon_1", "otsuzumi/chon_2", "otsuzumi/don_1", "otsuzumi/chon_1", "otsuzumi/chin_1", "otsuzumi/chon_2", "otsuzumi/don_2", "otsuzumi/chon_1"]],
		[0.75, {"right_arm": [120.0, 20.0, 10.0]}],
	])


## Stick drum on a stand in front: alternating strikes, a call now and then.
static func taiko(params: Dictionary, _ctx: Dictionary) -> Array:
	var base := {"left_leg": SEIZA_LEGS, "right_leg": SEIZA_LEGS, "left_arm": [55.0, -25.0, 60.0], "right_arm": [55.0, -25.0, 60.0], "prop": "taiko", "fan": ""}
	return _loop(params, base, 1.0, [
		[0.0, {"right_arm": [40.0, -25.0, 50.0]}, ["taiko/chunobachi_1", "taiko/dainobachi_1", "taiko/chunobachi_2", "taiko/katanobachi_1"]],
		[0.15, {"right_arm": [70.0, -25.0, 65.0]}],
		[0.5, {"left_arm": [40.0, -25.0, 50.0]}, ["taiko/osaerubachi_1", "taiko/chunobachi_1", "taiko/osaerubachi_2", "taiko/dainobachi_2"]],
		[0.65, {"left_arm": [70.0, -25.0, 65.0]}],
		[0.3, {"head_pitch": 5.0}, ["", "", "", "calls/taiko_yo", "", "", "", "calls/taiko_ho"]],
		[0.45, {"head_pitch": 0.0}],
	])


## Flute: each period plays one kit phrase (`phrases`), then rests `rest`.
static func nohkan(params: Dictionary, _ctx: Dictionary) -> Array:
	var base := {"left_leg": SEIZA_LEGS, "right_leg": SEIZA_LEGS, "left_arm": [140.0, -55.0, 0.0], "right_arm": [90.0, -20.0, 100.0], "head_yaw": -15.0, "prop": "nohkan", "fan": ""}
	var phrases: Array = params.get("phrases", ["nohkan/jonomai_1", "nohkan/jonomai_2", "nohkan/jonomai_3", "nohkan/jonomai_4"])
	var longest := 0.0
	for name in phrases:
		longest = maxf(longest, kit_duration(String(name), 8.0))
	var period := float(params.get("period", longest + float(params.get("rest", 2.0))))
	var loop_params := params.duplicate()
	loop_params["period"] = period
	return _loop(loop_params, base, period, [[0.0, {"head_pitch": 3.0}, phrases], [0.5, {"head_pitch": 0.0}]])


## One kit sound, with its playing motion for a drum or bell: {"move": "hit", "sound": "otsuzumi/chon_1"}.
static func hit(params: Dictionary, ctx: Dictionary) -> Array:
	var sound := String(params.get("sound", ""))
	var out := []
	if sound.begins_with("otsuzumi/"):
		out.append(_frame(0.15, {"right_arm": [125.0, 22.0, 10.0]}))
		out.append(_frame(0.25, {"right_arm": [45.0, -60.0, 5.0], "sound": sound}))
		out.append(_frame(0.6, {"right_arm": _limb_deg(ctx, "right_arm")}))
	elif sound.begins_with("kotsuzumi/"):
		out.append(_frame(0.05, {"right_arm": [35.0, -70.0, 120.0], "sound": sound}))
		out.append(_frame(0.2, {"right_arm": _limb_deg(ctx, "right_arm")}))
	elif sound.begins_with("taiko/"):
		out.append(_frame(0.05, {"right_arm": [40.0, -25.0, 50.0], "sound": sound}))
		out.append(_frame(0.2, {"right_arm": _limb_deg(ctx, "right_arm")}))
	elif sound.begins_with("calls/"):
		out.append(_frame(0.05, {"head_pitch": 6.0, "sound": sound}))
		out.append(_frame(0.6, {"head_pitch": 0.0}))
	elif sound.begins_with("bell/"):
		# A hand bell: the right arm lifts and swings for as long as it rings.
		var ring := kit_duration(sound, 1.0)
		out.append(_frame(0.3, {"right_arm": [70.0, 10.0, 70.0], "sound": sound}))
		var t := 0.3
		while t + 0.3 < ring:
			t += 0.3
			out.append(_frame(t, {"right_arm": [80.0 if int(t / 0.3) % 2 == 0 else 60.0, 10.0, 70.0]}))
		out.append(_frame(ring + 0.4, {"right_arm": _limb_deg(ctx, "right_arm")}))
	else:
		out.append(_frame(0.0, {"sound": sound}))
		out.append(_frame(maxf(float(params.get("dur", kit_duration(sound, 1.0))), 0.1), {}))
	return out


static func hold(params: Dictionary, _ctx: Dictionary) -> Array:
	return [_frame(float(params.get("dur", 1.0)), {})]


## Sets x, z, yaw (degrees) and any channel at once, for people already seated when the play opens.
static func place(params: Dictionary, _ctx: Dictionary) -> Array:
	var pose := {}
	for key in params:
		if key == "move" or key == "t" or key == "dur":
			continue
		if key == "pose":
			pose.merge(_named_pose(String(params.pose)))
			continue
		pose[key] = params[key]
	return [_frame(0.0, pose)]


## {} if unknown.
static func _named_pose(name: String) -> Dictionary:
	match name:
		"seiza":
			return {"left_leg": SEIZA_LEGS, "right_leg": SEIZA_LEGS, "left_arm": SEIZA_ARMS, "right_arm": SEIZA_ARMS, "fan": "floor"}
		"kneel":
			return _kneel_pose("right")
		"kamae":
			var k: Dictionary = KAMAE[""]
			return {"left_arm": k.arm, "right_arm": k.arm, "left_leg": k.leg, "right_leg": k.leg, "fan": "hand"}
	return {}


static var _REGISTRY := {
	"kamae": kamae, "ready": kamae,
	"stand": stand,
	"prayer": prayer,
	"hakobi": hakobi, "slide": hakobi,
	"walk": walk,
	"turn": turn, "mawari": turn,
	"step": step,
	"stamp": stamp, "ashibyoshi": stamp,
	"seiza": seiza, "sit": seiza,
	"rise": rise,
	"kneel": kneel, "katahiza": kneel,
	"bow": bow, "rei": bow,
	"kumorasu": kumorasu, "cloud": kumorasu,
	"terasu": terasu, "shine": terasu,
	"head_level": head_level,
	"look": look,
	"shikake": shikake,
	"sashi": sashi,
	"hiraki": hiraki,
	"kaikomi": kaikomi,
	"shiori": shiori, "weep": shiori,
	"kumo_no_ogi": kumo_no_ogi,
	"yuken": yuken,
	"fan": fan,
	"chant": chant,
	"kotsuzumi": kotsuzumi,
	"otsuzumi": otsuzumi,
	"taiko": taiko,
	"nohkan": nohkan,
	"hit": hit, "sound": hit,
	"hold": hold, "freeze": hold,
	"place": place,
}
