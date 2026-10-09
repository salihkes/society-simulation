@tool
extends EditorExportPlugin
## Teaches the Android export about media3.
##
## `bin/media3-decoder-ffmpeg.aar` is built from source (androidx/media +
## ffmpeg 6.0, arm64 only) and carries the software decoders a Quest does not
## ship: AC-3, E-AC-3, DTS, MLP and TrueHD. `bin/media-bridge.aar`
## is the thin static class GDScript drives through JavaClassWrapper.
##
## Everything else media3 needs comes from Maven — Godot's Gradle build reads
## _get_android_dependencies() and fetches it, so there is no need to vendor a
## dozen transitive .aar files by hand.

const MEDIA3 := "1.8.0"


func _get_name() -> String:
	return "MediaBridge"


func _supports_platform(platform: EditorExportPlatform) -> bool:
	return platform is EditorExportPlatformAndroid


## Paths are relative to res://addons/.
func _get_android_libraries(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
	return PackedStringArray([
		"media_bridge/bin/media3-decoder-ffmpeg.aar",
		"media_bridge/bin/media-bridge.aar",
	])


func _get_android_dependencies(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
	return PackedStringArray([
		"androidx.media3:media3-exoplayer:" + MEDIA3,
		"androidx.media3:media3-exoplayer-hls:" + MEDIA3,
		"androidx.media3:media3-common:" + MEDIA3,
	])
