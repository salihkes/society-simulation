// Road surface; UV2.x is the road width in metres, UV.y the distance along the road.
shader_type spatial;
render_mode cull_disabled;

uniform float road_length = 1000000.0;

float line(float distance_to_line, float width, float aa) {
	return 1.0 - smoothstep(width * 0.5 - aa, width * 0.5 + aa, abs(distance_to_line));
}

void fragment() {
	float width = max(UV2.x, 1.0);
	float lateral = (UV.x - 0.5) * width;
	float d = abs(lateral);
	float aa = max(fwidth(lateral), 0.025);
	float outer_edge = max(width * 0.5 - 9.0, width * 0.30);
	float inner_edge = min(6.0, outer_edge * 0.25);
	float divider = (inner_edge + outer_edge) * 0.5;
	float edges = max(line(d - inner_edge, 0.53, aa), line(d - outer_edge, 0.53, aa));
	float dash = line(d - divider, 0.53, aa) * (1.0 - smoothstep(21.1, 21.7, mod(UV.y, 42.84)));
	vec2 grain_position = floor(vec2(lateral, mod(UV.y, 1024.0)) * 40.0);
	float grain = fract(sin(dot(grain_position, vec2(127.1, 311.7))) * 43758.5453);
	float grain_fade = 1.0 - smoothstep(0.01, 0.05, max(fwidth(lateral), fwidth(UV.y)));
	vec3 asphalt = vec3(0.12, 0.125, 0.13) + (grain - 0.5) * 0.035 * grain_fade;
	vec3 color = mix(asphalt, vec3(0.72, 0.71, 0.65), clamp(edges + dash, 0.0, 1.0));
	float median = (1.0 - smoothstep(1.3, 1.5, d)) * smoothstep(40.0, 160.0, min(UV.y, road_length - UV.y));
	color = mix(color, vec3(0.12, 0.125, 0.09), median);
	if (UV.x < 0.0 || UV.x > 1.0) { color = vec3(0.18, 0.17, 0.14); }
	if (UV.x < -0.5) { color = vec3(0.25, 0.255, 0.24); }
	if (UV.x < -1.5) { color = vec3(0.47, 0.50, 0.52); }
	ALBEDO = color;
	METALLIC = UV.x < -1.5 ? 0.6 : 0.0;
	ROUGHNESS = UV.x < -1.5 ? 0.55 : 0.96;
}
