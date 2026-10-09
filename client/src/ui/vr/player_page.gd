extends Control
## The shell's player page: dark around a rounded window where the video layer shows through.

const BG := Color(0.031, 0.039, 0.055, 1.0)
const HOLE_RADIUS := 26.0

## Local pixels; empty means all dark.
var hole_rect := Rect2():
	set(v):
		hole_rect = v
		queue_redraw()


func _draw() -> void:
	var s := size
	if hole_rect.size.x < 2.0 or hole_rect.size.y < 2.0:
		draw_rect(Rect2(Vector2.ZERO, s), BG)
		return
	var h := hole_rect
	var r := minf(HOLE_RADIUS, minf(h.size.x, h.size.y) * 0.5)
	if h.position.y > 0.5:
		draw_rect(Rect2(0, 0, s.x, h.position.y), BG)
	if h.end.y < s.y - 0.5:
		draw_rect(Rect2(0, h.end.y, s.x, s.y - h.end.y), BG)
	if h.position.x > 0.5:
		draw_rect(Rect2(0, h.position.y, h.position.x, h.size.y), BG)
	if h.end.x < s.x - 0.5:
		draw_rect(Rect2(h.end.x, h.position.y, s.x - h.end.x, h.size.y), BG)
	# Rounded inner corners of the window.
	_cap(h.position, h.position + Vector2(r, r), r, PI, PI * 1.5)
	_cap(Vector2(h.end.x, h.position.y), Vector2(h.end.x - r, h.position.y + r), r,
			PI * 1.5, PI * 2.0)
	_cap(h.end, h.end - Vector2(r, r), r, 0.0, PI * 0.5)
	_cap(Vector2(h.position.x, h.end.y), Vector2(h.position.x + r, h.end.y - r), r,
			PI * 0.5, PI)


## Fills the area between a corner and the arc of radius r around center.
func _cap(corner: Vector2, center: Vector2, r: float, from: float, to: float) -> void:
	var points := PackedVector2Array([corner])
	var steps := 14
	for i in steps + 1:
		var a := from + (to - from) * float(i) / steps
		points.append(center + Vector2(cos(a), sin(a)) * r)
	draw_colored_polygon(points, BG)
