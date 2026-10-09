extends SceneTree
## Headless check of the movement layer: the kata reel compiles, every named
## movement expands, the essential movements put the body where they should,
## and playback is a pure function of time.
##
##   Godot --headless --path client --script res://tests/test_stage_moves.gd

const StageShow := preload("res://src/theater/stage_performance.gd")
var failures := 0


func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("FAIL: " + message)


func _initialize() -> void:
	call_deferred("run")


func performer_named(show, who: String):
	for p in show.performers:
		if p.name == who:
			return p
	return null


func track_named(show, who: String) -> Array:
	for i in show.score.cast.size():
		if String(show.score.cast[i].name) == who:
			return show.score.tracks[i]
	return []


## Model-space y of the lowest point along a leg's centreline, and the spread
## of the last (shin) samples' heights.
func shin_profile(p, slot: String) -> Array:
	var limb = p.rig.get(slot)
	var pose = StageScore.sample(track_named(_show, p.name), _show.elapsed)
	var entry: Array = pose[slot]
	var pts = HumanoidPoses.limb_points(p.rig, limb, {"basis": StagePose.limb_basis(slot, [entry[0], entry[1]]), "flex": float(entry[2])})
	var lowest := INF
	var shin_min := INF
	var shin_max := -INF
	for i in pts.size():
		lowest = minf(lowest, pts[i].y)
		if i >= 16:
			shin_min = minf(shin_min, pts[i].y)
			shin_max = maxf(shin_max, pts[i].y)
	return [lowest, shin_max - shin_min]


var _show


func run() -> void:
	# Every movement expands from a standing pose, and from seiza.
	var standing := StagePose.standing()
	var seated := StagePose.merge(standing, StagePose.from_degrees({"left_leg": StageMoves.SEIZA_LEGS, "right_leg": StageMoves.SEIZA_LEGS}))
	check(StageMoves.names().size() >= 30, "The dictionary lists the essential movements")
	for move in StageMoves.names():
		var params := {"to": [2.0, 1.0], "at": [0.0, 0.0], "face": 45.0}
		var frames := StageMoves.frames(move, params, standing)
		check(not frames.is_empty(), "'%s' expands from standing" % move)
		check(StageMoves.frames(move, params, seated).size() > 0, "'%s' expands from seiza" % move)
		var last := -1.0
		for f in frames:
			check(float(f.dt) >= last, "'%s' frames are in time order" % move)
			last = float(f.dt)

	# The compiler holds poses between cues and never overlaps them.
	var keys := StageScore.compile_track([{"t": 10.0, "move": "stamp"}, {"t": 1.0, "move": "shiori"}], "x")
	check(keys[0].t == 0.0 or keys[0].t == 1.0, "First key at the first cue")
	var t_prev := -1.0
	for k in keys:
		check(float(k.t) >= t_prev, "Compiled keys are monotonic")
		t_prev = float(k.t)
	check(StageScore.sample(keys, 5.0).right_arm[2] > 1.0 and StageScore.sample(keys, 5.0).right_arm[0] > 1.0, "Shiori holds until the next cue")

	var world := Node3D.new()
	world.scale = Vector3.ONE * 0.2
	root.add_child(world)
	var theater: Node3D = load("res://assets/art/models/theater/theater.tscn").instantiate()
	world.add_child(theater)
	var show := StageShow.new()
	show.score_path = "res://assets/entities/theater/plays/kata_reel.json"
	show.autoplay = false
	show.stage_path = NodePath("../theater/Stage")
	world.add_child(show)
	_show = show
	check(show.channels, "The reel is a cue score")
	check(show.performers.size() == 9, "Nine performers")
	check(show.audio.stream == null, "A silent score has no soundtrack")

	var shite = performer_named(show, "Shite")
	var waki = performer_named(show, "Waki")
	var chorus = performer_named(show, "Chorus1")
	check(shite.rig.has_joint(shite.rig.right_leg), "Performers have knees")
	check(shite.find_child("Mask", true, false) != null, "The shite wears a mask")

	# Keys are finite, inside the stage, and travel only grows.
	for track in show.score.tracks:
		var travel := -1.0
		for k in track:
			check(absf(float(k.x)) <= 10.0 and absf(float(k.z)) <= 6.0, "Key inside the stage")
			check(float(k.travel) >= travel, "Travel is cumulative")
			travel = float(k.travel)

	# Kamae: soft knees, arms ringed, fan in hand.
	show.seek(2.5)
	check(shite.rig.flex_of(shite.rig.right_arm) > 0.5, "Kamae bends the elbows")
	check(shite.rig.flex_of(shite.rig.right_leg) > 0.1, "Kamae softens the knees")
	check(shite._fan.visible and not shite._fan_paper.visible, "Kamae holds a closed fan")
	check(shite.drop() < 0.05, "Standing, the body does not drop")

	# Hakobi: slides toward the mark with the slide gait, no arm swing.
	show.seek(6.0)
	var mid := StageScore.sample(track_named(show, "Shite"), 6.0)
	check(float(mid.speed) > 0.5, "Walking at %.2f u/s" % float(mid.speed))
	check(String(mid.gait) == "slide", "Hakobi uses the slide gait")
	check(shite.position.x > -5.0 and shite.position.x < 0.0, "Between the jo-za and centre")
	var arm_a: Transform3D = shite.rig.right_arm.transform
	show.seek(6.3)
	check(shite.rig.right_arm.transform.basis.is_equal_approx(arm_a.basis), "No arm swing in the slide")
	show.seek(11.5)
	check(shite.position.distance_to(Vector3(0, shite.position.y, 0)) < 0.05, "Arrived at centre")
	check(absf(shite.rotation.y) < 0.02, "Faces the house after hakobi")

	# Shikake: the fan hand out ahead at shoulder height.
	show.seek(14.0)
	var hand: Vector3 = shite.hand_position("right_arm")
	check(hand.z < -1.2 and hand.y > 0.0, "Shikake hand ahead at shoulder height %s" % hand)
	check(shite.position.z > 0.5, "Shikake advanced toward the house")

	# Sashi: hand at eye height, gaze lifted.
	show.seek(17.5)
	hand = shite.hand_position("right_arm")
	check(hand.y > 0.9 and hand.z < -0.8, "Sashi hand at eye height %s" % hand)
	check(StageScore.sample(track_named(show, "Shite"), 17.5).head_pitch > 0.1, "Sashi lifts the gaze")

	# Hiraki: back and both arms open.
	show.seek(22.2)
	check(shite.position.z < 0.5, "Hiraki retreats")
	var l: Vector3 = shite.hand_position("left_arm")
	var r: Vector3 = shite.hand_position("right_arm")
	check(l.x < -1.6 and r.x > 1.6, "Hiraki opens both arms %s %s" % [l, r])

	# Stamp: the right foot lifts and returns.
	show.seek(25.25)
	var s := StageScore.sample(track_named(show, "Shite"), 25.25)
	check(s.right_leg[0] > s.left_leg[0] + 0.2, "Stamp lifts the right leg")
	show.seek(26.0)
	s = StageScore.sample(track_named(show, "Shite"), 26.0)
	check(absf(s.right_leg[0] - s.left_leg[0]) < 0.01, "Stamp returns the leg to the stance")

	# Shiori: the hand before the eyes, head down.
	show.seek(30.0)
	hand = shite.hand_position("right_arm")
	check(hand.y > 0.9 and hand.z < -0.2 and hand.z > -1.3 and absf(hand.x) < 1.0, "Shiori hand before the face %s" % hand)
	check(StageScore.sample(track_named(show, "Shite"), 30.0).head_pitch < -0.1, "Shiori lowers the head")

	# Mask: cloud lowers the face, shine lifts it.
	var mask: Node3D = shite.find_child("Mask", true, false).get_child(0)
	show.seek(35.0)
	var clouded: float = shite.model.to_local(mask.global_position).y
	show.seek(38.0)
	var shone: float = shite.model.to_local(mask.global_position).y
	show.seek(2.5)
	var level: float = shite.model.to_local(mask.global_position).y
	check(clouded < level and shone > level, "Mask tilts down for kumorasu (%.2f), up for terasu (%.2f), level %.2f" % [clouded, shone, level])

	# Look: the waki's head turns toward the shite; the shite looks at the waki.
	show.seek(40.5)
	var wk := StageScore.sample(track_named(show, "Waki"), 40.5)
	check(float(wk.head_yaw) < -0.2, "Waki, facing across, turns the head right toward the shite (head yaw %.2f)" % float(wk.head_yaw))
	var sh := StageScore.sample(track_named(show, "Shite"), 40.5)
	check(float(sh.head_yaw) > 0.3, "Shite turns the head left toward the waki at audience right (head yaw %.2f)" % float(sh.head_yaw))

	# Fan opens and closes.
	show.seek(43.5)
	check(shite._fan_paper.visible, "Fan opens")
	show.seek(47.5)
	check(not shite._fan_paper.visible, "Fan closes")

	# Bow: torso pitched forward, head with it.
	show.seek(49.6)
	var head_bow: float = shite.model.to_local(shite.rig.head.global_position).z
	show.seek(2.5)
	var head_level: float = shite.model.to_local(shite.rig.head.global_position).z
	check(head_bow < head_level - 0.3, "Bow brings the head forward")

	# Seiza: shins flat, body down on the heels; the fan on the floor.
	show.seek(56.0)
	var profile := shin_profile(shite, "right_leg")
	check(profile[1] < 0.05, "Seiza shins lie flat (spread %.3f)" % profile[1])
	check(shite.drop() > 0.4, "Seiza drops the body (%.2f)" % shite.drop())
	check(shite._floor_fan.visible and not shite._fan.visible, "Seated, the fan lies on the floor")
	check(absf(shite.model.position.y - (3.0 - shite.drop())) < 1e-4, "Model lowered by the drop")
	show.seek(53.7)
	check(shite.drop() > 0.15 and shite.drop() < 0.6, "One knee down on the way into seiza (%.2f)" % shite.drop())

	# Seated bow: hands come forward to the floor.
	show.seek(58.6)
	hand = shite.hand_position("right_arm")
	check(hand.z < -0.5, "Rei brings the hands forward %s" % hand)

	# Rise: back to kamae, standing.
	show.seek(66.0)
	check(shite.drop() < 0.05, "Risen")
	check(shite.rig.flex_of(shite.rig.right_arm) > 0.5, "Back in kamae")

	# Chorus and musicians sit, rock, and carry their instruments.
	show.seek(10.0)
	check(chorus.drop() > 0.4, "Chorus sits in seiza")
	var bow_a: float = StageScore.sample(track_named(show, "Chorus1"), 10.0).bow
	var bow_b: float = StageScore.sample(track_named(show, "Chorus1"), 10.6).bow
	check(absf(bow_a - bow_b) > 0.01, "Chorus rocks on the beat")
	for who in ["Kotsuzumi", "Otsuzumi", "Nohkan", "Taiko"]:
		var player = performer_named(show, who)
		var prop = player.find_child(who, true, false)
		check(prop != null and prop.visible, "%s holds its instrument" % who)
		check(player.drop() > 0.4, "%s sits" % who)
	check(waki.drop() > 0.4, "Waki sits")

	# Garments: the seated cast wears the fitted montsuki hakama, and the
	# garment's leg rings follow the knees into seiza.
	check(chorus.garments.size() == 1, "Chorus wears the hakama")
	var flute = performer_named(show, "Nohkan")
	check(flute.garments.size() == 1, "Musicians wear the hakama without an intersecting kataginu")
	var hakama: Node3D = chorus.garments[0]
	var skel: Skeleton3D = hakama.skeleton
	var shin := skel.find_bone("left_leg_ring_8")
	check(shin >= 0 and skel.get_bone_count() == 58, "Garment has the 37 rig bones plus drape corrections")
	show.seek(10.0)
	var seated_pose: Transform3D = skel.get_bone_global_pose(shin)
	var bow_pose: Transform3D = skel.get_bone_global_pose(skel.find_bone("torso"))
	show.seek(10.6)
	check(not bow_pose.is_equal_approx(skel.get_bone_global_pose(skel.find_bone("torso"))), "Hakama torso bone rocks with the chant")
	check(seated_pose.origin.y < -1.0, "Hakama shin ring sits low in seiza (%.2f)" % seated_pose.origin.y)
	for m in hakama.meshes:
		check(m.visible and m.mesh != null, "Garment mesh present")

	# Sounds: the drum loops carry strokes and calls as events on keys; they
	# play only when playback crosses the key going forward, never on a seek.
	var drum_keys := track_named(show, "Otsuzumi")
	var with_sound := 0
	for k in drum_keys:
		if k.has("sound"):
			with_sound += 1
	check(with_sound > 100, "Otsuzumi track carries strokes and calls (%d)" % with_sound)
	check(StageMoves.kit_duration("otsuzumi/chon_1", -1.0) > 0.3, "kit.json lists the strokes")
	check(load("res://src/theater/performer.gd").kit_stream("otsuzumi/chon_1") != null, "Kit wav loads")
	check(load("res://src/theater/performer.gd").kit_stream("nohkan/hagoromo") != null, "Kit long piece loads")
	var drummer = performer_named(show, "Otsuzumi")
	show.seek(20.0)
	show.seek(40.0)
	check(drummer.sounds_played == 0, "Seeking makes no sound")
	show.seek(20.0)
	show.playing = true
	for i in 40:
		show._physics_process(0.05)
	show.pause()
	check(drummer.sounds_played >= 2, "Two seconds of playback strike the hip drum (%d sounds)" % drummer.sounds_played)
	var flute_sounds := 0
	for k in track_named(show, "Nohkan"):
		if k.has("sound"):
			flute_sounds += 1
	check(flute_sounds >= 4 and flute_sounds <= 8, "Flute plays one phrase per period (%d phrases in 80 s)" % flute_sounds)
	var single := StageScore.compile_track([{"t": 1.0, "move": "hit", "sound": "calls/taiko_yo"}], "x")
	var found := false
	for k in single:
		found = found or String(k.get("sound", "")) == "calls/taiko_yo"
	check(found, "A hit cue puts its sound on a key")

	# Pure function of time: any route to a time shows the same figure.
	var snapshot := func() -> Array:
		var out := []
		for p in show.performers:
			out.append(Transform3D(p.basis, Vector3(p.position.x, 0.0, p.position.z)))   # y is the floor's
			out.append(p.model.transform)
			for limb in [p.rig.left_arm, p.rig.right_arm, p.rig.left_leg, p.rig.right_leg, p.rig.head, p.rig.torso]:
				out.append(limb.transform)
				out.append(p.rig.flex_of(limb))
		return out
	show.seek(30.0)
	var a: Array = snapshot.call()
	show.seek(70.0)
	show.seek(5.0)
	show.seek(30.0)
	var b: Array = snapshot.call()
	var same := a.size() == b.size()
	for i in mini(a.size(), b.size()):
		if a[i] is Transform3D:
			same = same and (a[i] as Transform3D).is_equal_approx(b[i])
		else:
			same = same and is_equal_approx(float(a[i]), float(b[i]))
	check(same, "Seeking is rewindable: 30 s looks the same from either side")
	# Forward playback lands on the same pose as a direct seek.
	show.seek(28.0)
	show.playing = true
	for i in 40:
		show._physics_process(0.05)
	var c: Array = snapshot.call()
	show.pause()
	var close := true
	for i in mini(a.size(), c.size()):
		if a[i] is Transform3D:
			close = close and (a[i] as Transform3D).origin.distance_to((c[i] as Transform3D).origin) < 0.05
	check(close, "Playing forward to 30 s matches seeking to 30 s")

	# The play: compiles, hides the bridge, keeps the Librarian and the
	# masked Student apart, rings the bell, keys the lights.
	var play := StageShow.new()
	play.score_path = "res://assets/entities/theater/plays/birikim.json"
	play.autoplay = false
	play.stage_path = NodePath("../theater/Stage")
	world.add_child(play)
	check(play.performers.size() == 11, "Birikim has eleven performers")
	check(play.find_child("Desk", true, false) != null, "The desk is on the stage")
	var librarian = performer_named(play, "Librarian")
	var student = performer_named(play, "Student")
	check(student.find_child("Mask", true, false) != null and librarian.find_child("Mask", true, false) == null, "Only the Student is masked")
	play.seek(0.0)
	check(not librarian.visible and not student.visible, "Nobody waits visibly at the bridge")
	play.seek(200.0)
	check(librarian.visible and not student.visible, "The Librarian is on stage in the mondo")
	play.seek(640.0)
	check(not librarian.visible and student.visible, "The Student is on stage after the bell")
	var rang := 0
	for key in track_named(play, "Student"):
		if String(key.get("sound", "")).begins_with("bell/"):
			rang += 1
	check(rang == 3, "The bell rings three times (%d)" % rang)
	play.seek(736.0)
	var dark: float = play._spots[0].light_energy
	play.seek(739.0)
	check(dark < 0.2 and play._spots[0].light_energy > 2.0, "The classroom light comes on at 738 s")
	check(String(play.caption.text).begins_with("Chorus:"), "The chorus line is up when the light comes on")

	world.queue_free()
	await process_frame
	print("MOVES TEST: ", "PASS" if failures == 0 else "FAIL", " (", failures, " failures)")
	quit(1 if failures else 0)
