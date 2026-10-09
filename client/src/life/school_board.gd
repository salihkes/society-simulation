## The blackboard: what the teacher says, written in vertical columns, right to left.
class_name SchoolBoard
extends RefCounted

const FONT := "res://assets/art/fonts/KleeOne-SemiBold.ttf"
const CJK_FONTS := ["Hiragino Sans", "Yu Gothic UI", "Meiryo", "Noto Sans CJK JP", "Noto Sans JP"]
const GLYPH := 0.30  # local units per character
const LINE := 0.38  # vertical advance per character
const COL := 0.46  # advance between columns
const MARGIN := 0.7  # kept clear around the writing
# Punctuation takes its vertical form: the horizontal marks lie wrong in a column.
const VERT := {"、": "︑", "。": "︒", "「": "﹁", "」": "﹂", "『": "﹃", "』": "﹄", "（": "︵", "）": "︶",
	"(": "︵", ")": "︶", "ー": "｜", "…": "︙", "—": "︱", "－": "｜", "-": "｜", "，": "︐", "．": "︒", ",": "︐"}

var _m: AmbientManager = null
var _pos := Vector3.INF  # the "BoardLocation" quad
var _normal := Vector3.FORWARD
var _size := Vector2(14.0, 6.0)
var _blocks: Array = []  # per written beat: Array of column strings
var _cols: Array = []  # Label3D per column, right to left


func _init(manager: AmbientManager):
	_m = manager


## "BoardLocation", else "Board": hidden, it only marks where the writing goes.
func find(room: Node3D, w: Node3D, lectern: Vector3):
	var board: Node3D = room.find_child("BoardLocation", true, false)
	if board == null:
		board = room.find_child("Board", true, false)
	if board == null:
		return
	var bx: Transform3D = w.global_transform.affine_inverse() * board.global_transform
	_pos = bx.origin
	_normal = bx.basis.z.normalized()
	_size = Vector2(bx.basis.x.length(), bx.basis.y.length())
	if board is MeshInstance3D and board.mesh is QuadMesh:
		_size *= (board.mesh as QuadMesh).size
	if board is MeshInstance3D:
		(board as MeshInstance3D).visible = false
	if lectern != Vector3.INF and (lectern - _pos).dot(_normal) < 0.0:
		_normal = -_normal


## Wipes the oldest beats (or a long beat's tail) to fit the board.
func write(text: String):
	if _pos == Vector3.INF or text.strip_edges() == "" or not _m.is_authority():
		return
	_blocks.append(_columns(text))
	var total := 0
	for b in _blocks:
		total += b.size()
	while total > _max_cols() and _blocks.size() > 1:
		total -= (_blocks.pop_front() as Array).size()
	if total > _max_cols():
		_blocks = [_blocks[-1].slice(0, _max_cols())]
	_render()
	print("[School] board: %d columns (%d beats) at %s" % [_flat().size(), _blocks.size(), _pos])


func clear():
	if not _m.is_authority():
		return
	_blocks = []
	_render()


## The "bd" key of the school's snapshot.
func write_snapshot(snap: Dictionary):
	if not _blocks.is_empty():
		snap["bd"] = _flat()


func apply_snapshot(bd):
	if typeof(bd) != TYPE_ARRAY:
		return
	var cols: Array = []
	for c in bd:
		cols.append(str(c))
	if cols != _flat():
		_blocks = [cols] if not cols.is_empty() else []
		_render()


func _col_chars() -> int:
	return maxi(int((_size.y - 2.0 * MARGIN) / LINE), 4)


func _max_cols() -> int:
	return maxi(int((_size.x - 2.0 * MARGIN) / COL), 2)


## Whitespace dropped, punctuation vertical, the first column indented one full-width space.
func _columns(text: String) -> Array:
	var chars: Array = []
	for ch in text.strip_edges():
		if ch == "\n" or ch == " " or ch == "　":
			continue
		chars.append(str(VERT.get(ch, ch)))
	var n: int = _col_chars()
	var cols: Array = []
	var col := "　"
	for ch in chars:
		if col.length() >= n:
			cols.append(col)
			col = ""
		col += ch
	if col != "":
		cols.append(col)
	return cols


func _flat() -> Array:
	var cols: Array = []
	for b in _blocks:
		cols.append_array(b)
	return cols


## A system CJK font is the fallback.
func _font() -> Font:
	var hand = load(FONT)
	var sysf := SystemFont.new()
	sysf.font_names = PackedStringArray(CJK_FONTS)
	if hand is FontFile:
		var fb: Array[Font] = [sysf]
		(hand as FontFile).fallbacks = fb
		return hand
	return sysf


## Right to left from the board's top right; spare labels are hidden.
func _render():
	var cols: Array = _flat()
	var right: Vector3 = Vector3.UP.cross(_normal).normalized()  # the reader's right
	# One line higher than the margin alone: the label's top alignment adds leading.
	var top: Vector3 = _pos + _normal * 0.05 + Vector3.UP * (_size.y * 0.5 - MARGIN + LINE * 1.75)
	var x0: float = _size.x * 0.5 - MARGIN - COL * 0.5
	var font: Font = null
	for i in cols.size():
		var lbl: Label3D
		if i < _cols.size() and is_instance_valid(_cols[i]):
			lbl = _cols[i]
		else:
			if font == null:
				font = _font()
			lbl = _make_label(font)
			if i < _cols.size():
				_cols[i] = lbl
			else:
				_cols.append(lbl)
		var chars: Array = []
		for ch in str(cols[i]):
			chars.append(ch)
		lbl.text = "\n".join(chars)
		lbl.visible = true
		# look_at wants a global target (the world is scaled).
		var p: Vector3 = top + right * (x0 - i * COL)
		lbl.position = p
		lbl.look_at(lbl.get_parent().to_global(p - _normal), Vector3.UP)
	for i in range(cols.size(), _cols.size()):
		if is_instance_valid(_cols[i]):
			_cols[i].visible = false


func _make_label(font: Font) -> Label3D:
	var lbl := Label3D.new()
	lbl.pixel_size = 0.01
	lbl.font_size = int(GLYPH / lbl.pixel_size)
	lbl.font = font
	lbl.line_spacing = (LINE - GLYPH * 1.15) / lbl.pixel_size
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	lbl.modulate = Color(0.94, 0.94, 0.86)
	lbl.outline_size = 0
	lbl.double_sided = true
	lbl.no_depth_test = true  # never lost inside the board's own mesh
	_m.container().add_child(lbl)
	return lbl
