@tool
extends EditorPlugin
## Registers the export plugin below. Nothing runs at game time — this exists
## only so the Android export knows which .aar files to link and which Maven
## artifacts to fetch.

const ExportPluginScript := preload("res://addons/media_bridge/export_plugin.gd")

var _export_plugin: EditorExportPlugin


func _enter_tree() -> void:
	_export_plugin = ExportPluginScript.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	if _export_plugin:
		remove_export_plugin(_export_plugin)
		_export_plugin = null
