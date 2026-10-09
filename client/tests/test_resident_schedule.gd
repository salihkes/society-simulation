extends SceneTree
## An extra ("life": false) is on the map only for their outings; the schedule
## reads the routine the way the body plans it. No city, no server.
##   Godot --headless --path <project> --script res://tests/test_resident_schedule.gd

const Schedule = preload("res://src/life/resident_schedule.gd")

var failures := 0


func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("FAIL: " + message)


func _initialize() -> void:
	var home := [163.3, 3, -148.7]
	var student := {"id": "student_01", "student": true, "life": false, "routine": [
		{"hour": 7.6, "name": "morning before school", "days": [0, 1, 2, 3, 4], "pos": home},
		{"hour": 7.6, "name": "morning at home", "days": [5, 6], "pos": home},
		{"hour": 8.3, "name": "school", "days": [0, 1, 2, 3, 4], "place": "School/12C", "do": "attend"},
		{"hour": 15.6, "name": "after school", "days": [0, 1, 2, 3, 4], "pos": [-31.8, 2, -58.3]},
		{"hour": 15.6, "name": "out with friends", "days": [5, 6], "chance": 0.6, "pos": [-31.8, 2, -58.3]},
		{"hour": 19.2, "name": "evening", "pos": home},
		{"hour": 22.4, "name": "night", "pos": home},
	]}
	var pid := "r_student_01"
	check(Schedule.is_extra(student), "life false makes an extra")
	check(not Schedule.is_extra({"life": true}) and not Schedule.is_extra({}) and not Schedule.is_extra({"life": false, "script": "x.gd"}),
		"people with a life, no life field, or a script are not extras")
	check(Schedule.home_pos(student) == Vector3(163.3, 3, -148.7), "home is the night spot")

	# Monday (0), day 10
	check(not Schedule.on_the_map(student, pid, 7.8, 10, 0), "before school, at home: not on the map")
	check(Schedule.on_the_map(student, pid, 10.0, 10, 0), "in school: on the map")
	check(Schedule.on_the_map(student, pid, 16.5, 10, 0), "after school elsewhere: on the map")
	check(not Schedule.on_the_map(student, pid, 20.0, 10, 0), "evening at home: not on the map")
	check(not Schedule.on_the_map(student, pid, 2.0, 10, 0), "night, carried over: not on the map")
	check(Schedule.current_entry(student, pid, 10.0, 10, 0).get("name") == "school", "the current entry at ten is school")

	# Saturday (5): no school; the outing depends on its chance, the same
	# roll the body makes, so map presence and the entry agree either way.
	check(not Schedule.on_the_map(student, pid, 10.0, 10, 5), "Saturday morning at home: not on the map")
	var sat: Dictionary = Schedule.current_entry(student, pid, 16.5, 10, 5)
	check(Schedule.on_the_map(student, pid, 16.5, 10, 5) == (sat.get("name") == "out with friends"),
		"Saturday afternoon: on the map exactly when the outing happens")
	var went := 0
	for day in 30:
		if Schedule.current_entry(student, pid, 16.5, day, 5).get("name") == "out with friends":
			went += 1
	check(went > 5 and went < 30, "a 0.6 chance outing happens on some Saturdays, not all (%d of 30)" % went)

	# People with a life are always there; jitter is stable per day.
	check(Schedule.on_the_map({"life": true, "routine": student.routine}, pid, 2.0, 10, 0), "a person with a life is always on the map")
	var e := {"hour": 8.0, "jitter": 0.5}
	check(Schedule.entry_hour(pid, e, 0, 10) == Schedule.entry_hour(pid, e, 0, 10), "jitter is deterministic")
	check(absf(Schedule.entry_hour(pid, e, 0, 10) - 8.0) <= 0.5, "jitter stays within its range")
	check(Schedule.entry_is_away(student, {"hour": 9, "marker": "Bench"}) and not Schedule.entry_is_away(student, {}),
		"a marker is somewhere; nothing is home")

	print("Resident schedule tests: ", "PASS" if failures == 0 else "FAIL ", failures)
	quit(0 if failures == 0 else 1)
