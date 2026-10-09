extends SceneTree
## A real resident body across midnight: what is in hand (a life order
## asleep in bed, a walk bound to the hour's entry) survives the new day's
## plan; a clock jump still starts the day over. And someone with no
## household is off the map while at their home spot, back on it when an
## entry takes them elsewhere. No city, server or model.

class Body extends "res://src/life/resident_npc.gd":
	func play_door_sound(): pass

class Life extends RefCounted:
	var orders := {}

class Manager extends RefCounted:
	var day := 100
	var hour := 23.9
	var house = null
	var life_controller = Life.new()
	func current_day(): return day
	func current_hour(): return hour
	func current_weekday(): return 1
	func household_of(_pid): return house

const HOME := [0.0, 0.0, 0.0]
const ROUTINE := [
	{"hour": 7.0, "pos": HOME, "name": "breakfast at home", "action": "stay"},
	{"hour": 8.2, "pos": [100.0, 0.0, 0.0], "name": "work"},
	{"hour": 22.8, "pos": HOME, "name": "night", "action": "stay"},
]

var failures := 0

func check(ok: bool, what: String):
	if not ok:
		failures += 1
		push_error(what)

func body_at(m: Manager) -> Body:
	var b := Body.new()
	b.ped_id = "r_uncle"
	b.resident_def = {"routine": ROUTINE}
	b.manager = m
	return b

func _initialize():
	# Asleep at 23:54 under a life order; the day turns over.
	var m := Manager.new()
	var b := body_at(m)
	b.push_intent({"do": "sleep", "pos": HOME, "then": "stay", "for": 120.0, "life_id": "sleep-1"})
	m.life_controller.orders["r_uncle"] = {"id": "sleep-1"}
	b.active_entry = b.current_entry()
	b._action_running = true
	check(b.life_arrived("sleep-1"), "the sleep should have started before midnight")
	m.day = 101
	m.hour = 0.05
	var after := b.current_entry()
	check(str(after.get("life_id", "")) == "sleep-1", "midnight must not drop the life order in hand")
	check(after == b.active_entry and b.life_arrived("sleep-1"), "the sleep must go on counting down after midnight")

	# A walk bound to the hour's entry (no duration): still bound after
	# midnight, over when the next scheduled entry comes.
	var m2 := Manager.new()
	var b2 := body_at(m2)
	b2.push_intent({"do": "go", "pos": [5.0, 0.0, 0.0], "name": "a late walk"})
	m2.day = 101
	m2.hour = 0.05
	check(str(b2.current_entry().get("name", "")) == "a late walk", "a reaction bound to the night entry must survive midnight")
	m2.hour = 7.1
	check(str(b2.current_entry().get("name", "")) == "breakfast at home", "the reaction must end when the next entry comes")

	# A clock jump still starts the day over: nothing carried.
	var m3 := Manager.new()
	var b3 := body_at(m3)
	b3.push_intent({"do": "sleep", "pos": HOME, "then": "stay", "for": 120.0, "life_id": "sleep-2"})
	m3.life_controller.orders["r_uncle"] = {"id": "sleep-2"}
	b3.reset_day()
	check(str(b3.current_entry().get("life_id", "")) == "", "reset_day must still drop what was in hand")

	# At home without a house: off the map once there, back on when leaving.
	var m4 := Manager.new()
	var b4 := body_at(m4)
	var night := b4.current_entry()
	b4.active_entry = night
	b4._action_running = true
	check(b4._hide_at_home_now(), "someone with no house, at home for the night, should be off the map")
	b4._set_home_hidden(true)
	check(not b4.visible and b4.collision_layer == 0, "off the map: not drawn, not bumped into")
	check(AmbientManager.off_map(b4), "the manager must see them as off the map")
	# The mind's "sleep" at the same spot replaces the night entry: still home.
	b4._action_running = false
	b4.active_entry = {"do": "sleep", "pos": HOME, "then": "stay", "life_id": "sleep-3"}
	check(b4._hide_at_home_now(), "one at-home entry giving way to another must not bring them into view")
	# Off to work: back on the map.
	b4.active_entry = {"hour": 8.2, "pos": [100.0, 0.0, 0.0], "name": "work"}
	check(not b4._hide_at_home_now(), "an entry elsewhere must bring them back")
	b4._set_home_hidden(false)
	check(b4.visible and b4.collision_layer != 0 and not AmbientManager.off_map(b4), "back on the map: drawn and solid again")
	# A meal, even one at the home spot, is not being at home.
	b4.active_entry = {"do": "eat", "place": "Restaurant"}
	b4._action_running = true
	check(not b4._hide_at_home_now(), "a meal out is never off the map")
	# With a household, home is a real place: never hidden.
	m4.house = RefCounted.new()
	b4.active_entry = night
	check(not b4._hide_at_home_now(), "someone with a household is at their real home, not off the map")

	for x in [b, b2, b3, b4]:
		x.free()
	if failures == 0:
		print("test_resident_midnight: ok")
	quit(0 if failures == 0 else 1)
