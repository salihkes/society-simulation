extends SceneTree
const Performer = preload("res://src/theater/performer.gd")
class Garment extends Node3D:
 var updates := 0
 func update_pose(): updates += 1
class PhysicsBurst extends Node:
 var performer: Node3D
 var immediate_updates := -1
 func _physics_process(_delta):
  for i in 8: performer._pose_garments()
  immediate_updates = performer.garments[0].updates
  set_physics_process(false)
var failures := 0
func check(ok: bool, label: String):
 if not ok:
  failures += 1
  push_error("FAIL: " + label)
func _initialize(): run.call_deferred()
func run():
 var performer := Performer.new()
 root.add_child(performer)
 performer.set_process(false)
 var garment := Garment.new()
 performer.add_child(garment)
 performer.garments.append(garment)
 var burst := PhysicsBurst.new()
 burst.performer = performer
 root.add_child(burst)
 await physics_frame
 await process_frame
 await process_frame
 check(burst.immediate_updates == 0, "catch-up physics poses do not skin immediately")
 check(garment.updates == 1, "eight requested poses skin once before rendering")
 await process_frame
 check(garment.updates == 1, "idle performer does not keep skinning")
 performer._pose_garments()
 check(garment.updates == 2, "explicit non-physics pose remains immediate for tools and seeking")
 burst.free()
 performer.free()
 print("COSTUME SCHEDULE: %d failures" % failures)
 quit(1 if failures else 0)
