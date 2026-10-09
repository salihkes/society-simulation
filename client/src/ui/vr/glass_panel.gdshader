shader_type canvas_item;
// Glass panel: rounded rectangle with a gradient fill and fading border; rect_size must follow the control.

uniform vec2 rect_size = vec2(400.0, 300.0);
uniform float corner_radius = 28.0;
uniform float border_width = 1.6;
uniform vec4 fill_top : source_color = vec4(0.32, 0.34, 0.40, 0.52);
uniform vec4 fill_bottom : source_color = vec4(0.08, 0.09, 0.12, 0.78);
uniform vec4 border_top : source_color = vec4(1.0, 1.0, 1.0, 0.50);
uniform vec4 border_bottom : source_color = vec4(1.0, 1.0, 1.0, 0.07);
// Brightening of the upper area.
uniform float sheen_strength = 0.06;

float sd_round_rect(vec2 p, vec2 half_size, float r) {
	vec2 q = abs(p) - half_size + vec2(r);
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

void fragment() {
	vec2 half_size = rect_size * 0.5;
	vec2 p = UV * rect_size - half_size;
	float r = min(corner_radius, min(half_size.x, half_size.y));
	float d = sd_round_rect(p, half_size, r);

	float mask = 1.0 - smoothstep(-1.0, 0.5, d);

	vec4 fill = mix(fill_top, fill_bottom, clamp(UV.y, 0.0, 1.0));
	float sheen = sheen_strength * (1.0 - smoothstep(0.0, 0.45, UV.y));
	fill.rgb += vec3(sheen);

	float half_border = border_width * 0.5;
	float band = 1.0 - smoothstep(half_border, half_border + 1.0, abs(d + half_border));
	vec4 border_col = mix(border_top, border_bottom, clamp(UV.y, 0.0, 1.0));

	vec4 col = fill;
	col.rgb = mix(col.rgb, border_col.rgb, band * border_col.a);
	col.a = max(col.a, band * border_col.a);
	COLOR = vec4(col.rgb, col.a * mask);
}
