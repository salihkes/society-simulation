class_name GravitySource
extends RefCounted
## Duck-typed gravity source: any node with get_gravity_force(), get_surface_normal() and is_on_surface().


static func is_gravity_source(node: Node) -> bool:
	return (node.has_method("get_gravity_force")
		and node.has_method("get_surface_normal")
		and node.has_method("is_on_surface"))


static func get_priority(node: Node) -> int:
	if node.has_method("get_gravity_priority"):
		return node.get_gravity_priority()
	return 0
