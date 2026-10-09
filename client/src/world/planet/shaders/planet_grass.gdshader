// PlanetTerrain grass blades; UV.y is 0 at the tip and 1 at the root.
shader_type spatial;
render_mode cull_disabled;

uniform vec3 base_color : source_color = vec3(0.28, 0.50, 0.19);
uniform vec3 tip_color : source_color = vec3(0.55, 0.72, 0.25);
uniform float sway_amount = 0.12;
uniform float sway_speed = 1.8;

varying float v_tip;
varying float v_hash;

void vertex() {
	v_tip = 1.0 - UV.y;
	vec3 inst_origin = MODEL_MATRIX[3].xyz;
	v_hash = fract(sin(dot(inst_origin.xy + inst_origin.zz, vec2(12.9898, 78.233))) * 43758.5453);
	float phase = TIME * sway_speed + v_hash * 6.28;
	vec3 sway = vec3(sin(phase), 0.0, cos(phase * 0.7)) * sway_amount * v_tip * v_tip;
	VERTEX += sway;
}

void fragment() {
	vec3 col = mix(base_color, tip_color, v_tip);
	col *= 0.85 + 0.3 * v_hash;
	ALBEDO = col;
	ROUGHNESS = 0.9;
	ALBEDO *= 0.6 + 0.4 * v_tip;
}
