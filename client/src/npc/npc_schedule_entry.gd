class_name NpcScheduleEntry
extends Resource
## One entry of an NPC's daily schedule: from `hour` on, go to a waypoint and run an action.

## Hour of day (0-24) when this entry becomes active.
@export_range(0, 24, 0.5) var hour: float = 9.0

## Name of a Marker3D node under the "Waypoints" container.
@export var waypoint_name: String = ""

## Action name, e.g. "teaching" or "patrolling"; empty means idle.
@export var action_name: String = ""
