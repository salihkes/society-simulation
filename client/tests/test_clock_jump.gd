extends SceneTree
## The clock set by hand: every resident starts the hour over. Loads the
## real city, turns the people on, pins 08:00 then 13:00 through the same
## path a world_clock from the server takes, and checks the plans were drawn
## again and the active entries follow the new hour.
##   Godot --headless --path client -s res://tests/test_clock_jump.gd

var failures := 0

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("FAIL: " + message)
	else:
		print("  ok   " + message)

func _initialize() -> void:
	call_deferred("run")

func frames(n: int) -> void:
	for i in n:
		await physics_frame

func run() -> void:
	var world = load("res://assets/scenes/workspace_local.tscn").instantiate()
	get_root().add_child(world)
	current_scene = world
	var manager = null
	for i in 30:
		await physics_frame
		manager = world.find_child("AmbientManager", true, false)
		if manager != null:
			break
	check(manager != null, "the ambient manager is in the world")
	if manager == null:
		_finish()
		return
	manager.npcs_enabled = true
	var day: int = manager.current_day()
	var wd: int = manager.current_weekday()
	# Evening first, so people are home and settled.
	manager.handle_world_clock({"mode": "fixed", "hour": 21.0, "day": day, "rate": 1.0, "weekday": wd})
	await frames(60 * 8)
	var bodies: Array = []
	for b in manager.residents().values():
		if b != null and is_instance_valid(b) and b.has_method("reset_day"):
			bodies.append(b)
	check(bodies.size() > 0, "residents are on the map at 21:00 (%d)" % bodies.size())
	var before := {}
	for b in bodies:
		before[b.ped_id] = b.current_entry(true).duplicate()
	# The jump: 08:00.
	manager.handle_world_clock({"mode": "fixed", "hour": 8.0, "day": day, "rate": 1.0, "weekday": wd})
	check(absf(manager.current_hour() - 8.0) < 0.05, "the world's hour is 08:00 now (%.2f)" % manager.current_hour())
	var reset := 0
	for b in bodies:
		if is_instance_valid(b) and b._plan_day == -1 and b.active_entry.is_empty():
			reset += 1
	check(reset == bodies.size(), "every resident dropped what they had in hand and will plan again (%d of %d)" % [reset, bodies.size()])
	await frames(60 * 10)   # long enough for a lift ride between two legs of the morning
	var morning := 0
	var followed := 0
	var alive := 0
	var planned := 0   # residents with a routine for today (a mind-driven person may have none)
	for b in manager.residents().values():
		if b == null or not is_instance_valid(b) or not b.has_method("reset_day"):
			continue
		alive += 1
		var e: Dictionary = b.current_entry(true)
		if e.is_empty():
			continue   # no routine today: the mind drives this person
		var latest := -1.0
		for it in b._plan:
			if not it.get("imm", false):
				latest = maxf(latest, float(it.get("at", 0.0)))
		if float(e.get("at", 0.0)) <= 8.0 or float(e.get("at", 0.0)) == latest:
			morning += 1   # the morning entry, or yesterday's last one wrapping round
		# Following the hour: on the way to the entry, standing at it, or held
		# by whoever it belongs to (a household's breakfast table seats people).
		if b._plan_day == day and (not b.active_entry.is_empty() or b.sitting or b._state == 1):
			followed += 1
		planned += 1
	for b in manager.residents().values():
		if b != null and is_instance_valid(b) and b.has_method("reset_day"):
			var e: Dictionary = b.current_entry(true)
			print("[ClockJump] %s: plan_day %d (day %d) state %s idle %.1f action %s sitting %s errand %s active=%s/%s current=%s/%s@%s" % [b.ped_id, b._plan_day, day, str(b._state), b.idle_timer, str(b._action_running), str(b.sitting), str(b.errand_owner != null), str(b.active_entry.get("do", "")), str(b.active_entry.get("at", "")), str(e.get("do", "")), str(e.get("marker", e.get("place", ""))), str(e.get("at", ""))])
	check(alive > 0, "people are on the map at 08:00 (%d)" % alive)
	check(morning == planned, "every routine entry active is the one 08:00 calls for (%d of %d)" % [morning, planned])
	check(planned > 0 and followed == planned, "every resident with a routine took up their new entry (%d of %d)" % [followed, planned])
	# And again: 13:00 — the entries move on with the hour.
	var at8 := {}
	for b in manager.residents().values():
		if b != null and is_instance_valid(b) and b.has_method("reset_day"):
			at8[b.ped_id] = b.current_entry(true).duplicate()
	manager.handle_world_clock({"mode": "fixed", "hour": 13.0, "day": day, "rate": 1.0, "weekday": wd})
	await frames(60 * 3)
	var moved := 0
	var same := 0
	for b in manager.residents().values():
		if b == null or not is_instance_valid(b) or not b.has_method("reset_day") or not at8.has(b.ped_id):
			continue
		var e: Dictionary = b.current_entry(true)
		if str(e.get("do", "")) + str(e.get("marker", e.get("place", ""))) + str(e.get("at", "")) != str(at8[b.ped_id].get("do", "")) + str(at8[b.ped_id].get("marker", at8[b.ped_id].get("place", ""))) + str(at8[b.ped_id].get("at", "")):
			moved += 1
		else:
			same += 1
	print("[ClockJump] 08:00 → 13:00: %d residents changed entry, %d kept the same one" % [moved, same])
	check(moved > 0, "the afternoon has people doing different things than the morning (%d changed)" % moved)
	_finish()

func _finish() -> void:
	print("Clock jump tests: ", "PASS" if failures == 0 else "FAIL ", failures)
	quit(0 if failures == 0 else 1)
