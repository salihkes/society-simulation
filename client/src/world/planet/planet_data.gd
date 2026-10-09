@tool
class_name PlanetData
extends Resource
## Per-planet authoring parameters; heights are metres above sea level, which is `radius` from the origin.

@export_group("Shape")
## Origin to sea level, world units.
@export var radius := 600.0
## Above sea level; bounds fallback generation and raycasts.
@export var max_height := 90.0
## Below sea level, positive.
@export var ocean_depth := 30.0

@export_group("Source data")
## Holds base.res or the height/ raw faces.
@export_dir var data_dir := ""
## For generated fallback terrain.
@export var face_resolution := 512
@export var generator_seed := 1071

@export_group("Surface look")
## Metres above sea level.
@export var beach_top := 4.0
## Degrees from horizontal.
@export var rock_slope_deg := 38.0
## Metres above sea level.
@export var snow_start := 65.0

@export_group("Clutter")
@export var grass_enabled := true
## Blades per square metre.
@export var grass_density := 0.35
## Metres from the camera.
@export var grass_distance := 120.0
