extends MainLoop
## Compiles GDScript files and prints FAIL <path> for each that does not parse,
## then "check_scripts: N files, M failed". A bare MainLoop, so no autoload
## starts and nothing connects to a server. MainLoop cannot set an exit code;
## read the summary line.
##
##   godot --headless --path client --script res://tools/check_scripts.gd
##   godot --headless --path client --script res://tools/check_scripts.gd -- res://src/net

const DEFAULT_ROOTS := ["res://src", "res://tools", "res://tests", "res://addons"]


var _failed := 0


func _initialize() -> void:
	var roots := OS.get_cmdline_user_args()
	if roots.is_empty():
		roots = PackedStringArray(DEFAULT_ROOTS)
	var files := PackedStringArray()
	for root in roots:
		if root.ends_with(".gd"):
			files.append(root)
		else:
			_collect(root, files)
	for path in files:
		if not _compiles(path):
			_failed += 1
	print("check_scripts: %d files, %d failed" % [files.size(), _failed])


func _process(_delta: float) -> bool:
	return true



## Compiles one file; Godot prints the parse error itself.
func _compiles(path: String) -> bool:
	var script := GDScript.new()
	script.source_code = FileAccess.get_file_as_string(path)
	script.resource_path = path
	var err := script.reload()
	if err != OK:
		printerr("FAIL ", path)
		return false
	return true


func _collect(dir_path: String, out: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for name in dir.get_directories():
		_collect(dir_path.path_join(name), out)
	for name in dir.get_files():
		if name.ends_with(".gd"):
			out.append(dir_path.path_join(name))
