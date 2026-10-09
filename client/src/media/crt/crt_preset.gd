extends Resource
class_name CRTPreset
## One television model's signal path, tube and cabinet, fed to the CRT shaders by crt_tv.gd; distances in metres.

enum Standard { NTSC_J, NTSC_M, PAL }
enum Cable { RGB, SVIDEO, COMPOSITE, RF, TAPE }
enum Mask { NONE, SLOT, APERTURE_GRILLE }
enum Controls { NONE, FLAP, KNOBS }

@export var display_name := "CRT"

@export_group("Glass")
## Visible picture area of the glass (width, height).
@export var screen_size := Vector2(0.53, 0.40)
## Bulge of the glass centre past its edges, per axis; a Trinitron has curve.y = 0.
@export var curve := Vector2(0.006, 0.005)
## Phosphor screen colour seen through the glass when the set is off.
@export var glass_tint := Color(0.10, 0.10, 0.11)
## Glossy glass ~0.06; an etched anti-glare faceplate ~0.35.
@export_range(0.0, 1.0) var roughness := 0.06

@export_group("Signal")
@export var standard := Standard.NTSC_J
@export var cable := Cable.COMPOSITE
## Cycles per sample (720 per active line); the NTSC subcarrier sits at 0.26.
@export_range(0.05, 0.5) var luma_cut := 0.21
## Cycles per sample; NTSC gives I 0.09 and Q 0.03, a cheap decoder 0.04 for both.
@export_range(0.01, 0.2) var i_cut := 0.04
@export_range(0.01, 0.2) var q_cut := 0.04
## Cutoff for the RGB input's amplifiers. 6 MHz on a PVM is 0.42.
@export_range(0.05, 0.5) var rgb_cut := 0.38
## 0 = notch filter, 1 = three-line comb (less dot crawl, softer verticals).
@export_range(0.0, 1.0) var comb := 0.0
## Band-limit the source before encoding; off for a console.
@export var prefilter := true
## The consumer "sharpness" circuit: rings every edge.
@export_range(0.0, 2.0) var peaking := 0.0
@export_range(0.0, 2.0) var saturation := 1.0
@export_range(0.5, 1.5) var contrast := 1.0
## Positive lifts blacks to grey, negative crushes them.
@export_range(-0.1, 0.2) var black_lift := 0.0
## Decoder white balance. Leave white; the tube's white point is `phosphor`.
@export var white_point := Color(1.0, 1.0, 1.0)
## Noise added to the signal on the cable; snow.
@export_range(0.0, 1.0) var noise := 0.0
## RF ghosting: a delayed echo of the picture.
@export_range(0.0, 0.5) var ghost := 0.0
## TAPE only: how worn the cassette and the heads are.
@export_range(0.0, 1.0) var tape_wear := 0.3

@export_group("Tube")
## 240p: both fields land on the same lines and leave black gaps.
@export var progressive := false
@export_range(0.0, 1.0) var scanline := 0.5
## Beam spot size in line pitches for black and for white.
@export_range(0.1, 1.0) var beam_min := 0.3
@export_range(0.1, 1.0) var beam_max := 0.5
@export_range(0.0, 1.0) var interlace_flicker := 0.15
## The spot also widens sideways on bright detail.
@export_range(0.0, 2.0) var bloom_spread := 0.0
## Beam width growth towards the corners: focus is set for the centre.
@export_range(0.0, 2.0) var focus_falloff := 0.0
## Red and blue miss green by this at the corners (28" consumer ~0.6 mm, PVM under 0.1 mm).
@export_range(0.0, 0.003) var convergence := 0.0
## Raster growth from a black to a white picture as the high voltage sags.
@export_range(0.0, 0.05) var breathing := 0.0
## Signal RGB to perceived linear light; identity is sRGB primaries at D65.
@export var phosphor := Basis.IDENTITY
@export var mask := Mask.SLOT
## Triad pitch on the glass.
@export var mask_pitch := 0.00078
@export_range(0.0, 1.0) var mask_strength := 0.5
## Trinitron damper wires: 0 on a 9 inch, 1 on a 14, 2 on a 20.
@export_range(0, 2) var damper_wires := 0
## Raster rotation in degrees, positive counter-clockwise seen from the front.
@export_range(-15.0, 15.0) var tilt := 0.0
## Negative underscans to a black border (a PVM's switch is -0.03).
@export_range(-0.1, 0.15) var overscan := 0.06
## Positive bows the picture out (barrel), negative pulls the sides in.
@export_range(-0.1, 0.1) var geometry := 0.03
@export_range(0.0, 1.0) var corner := 0.25
@export_range(0.0, 0.5) var halation := 0.12
@export_range(0.0, 0.1) var halation_radius := 0.02
## Emission energy of a white picture.
@export_range(0.0, 10.0) var brightness := 1.7
@export_range(1.8, 2.8) var crt_gamma := 2.4
## Seconds from power-on until the cathode is hot and a picture appears.
@export_range(0.0, 20.0) var warmup := 3.5
## Colour purity stains at power-on until the degauss pulse clears them.
@export_range(0.0, 1.0) var degauss := 0.8

@export_group("Room")
## Light the picture throws on the room.
@export_range(0.0, 4.0) var glow := 0.6
@export_range(-60.0, 0.0) var whine_db := -34.0
## Loudness of the set's speaker.
@export_range(-40.0, 6.0) var speaker_db := -6.0

@export_group("Cabinet")
## Needs a part named `model_screen` covering the picture area; without a model a placeholder is built.
@export var model: PackedScene
@export var model_screen := "Screen"
@export var model_front := Vector3(0, 0, 1)
@export var bezel := 0.045
## Extra height under the screen for the controls.
@export var chin := 0.0
@export var cabinet_depth := 0.45
@export var bezel_color := Color(0.72, 0.72, 0.70)
@export var body_color := Color(0.55, 0.55, 0.54)
@export var controls := Controls.FLAP
