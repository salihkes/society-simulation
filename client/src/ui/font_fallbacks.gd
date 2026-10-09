extends Node
## Chains the Latin and CJK fonts as each other's fallbacks, so no glyph depends on OS fonts.

const LATIN := "res://assets/art/fonts/tahoma.ttf"
const LATIN_BOLD := "res://assets/art/fonts/tahomabd.ttf"
const CJK := "res://assets/art/fonts/KleeOne-SemiBold.ttf"


func _ready() -> void:
	var latin := _font(LATIN)
	var latin_bold := _font(LATIN_BOLD)
	var cjk := _font(CJK)
	if latin == null or latin_bold == null or cjk == null:
		return
	_chain(latin, cjk)
	_chain(latin_bold, cjk)
	# Godot silently drops a fallback that closes a cycle, so CJK falls back
	# to a copy of the Latin face with the copied chain cleared.
	var plain_latin: FontFile = latin.duplicate()
	plain_latin.fallbacks = [] as Array[Font]
	_chain(cjk, plain_latin)
	# Controls that name no font use Godot's default, which lacks CJK too.
	var builtin := ThemeDB.fallback_font
	if builtin is FontFile and builtin != cjk:
		_chain(builtin, cjk)
	var theme_default := ThemeDB.get_default_theme().default_font
	if theme_default is FontFile and theme_default != builtin and theme_default != cjk:
		_chain(theme_default, cjk)
	print("[Fonts] Latin ↔ CJK fallbacks chained; no glyph depends on the OS")


func _font(path: String) -> FontFile:
	var f = load(path)
	if f is FontFile:
		return f
	push_warning("[Fonts] missing %s — text using it will be blank on web" % path)
	return null


## Rebuilt and assigned because mutating the getter's copy does not stick.
func _chain(font: FontFile, fallback: FontFile) -> void:
	var chain: Array[Font] = []
	for f in font.fallbacks:
		if f == fallback:
			return
		chain.append(f)
	chain.append(fallback)
	font.fallbacks = chain
