// Sandy seabed under the city sea, in model units: a shelf with sandbars dropping away seaward.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

group_uniforms Profile;
// x (model) of the waterline; land is on the shore_sign side of it.
uniform float shore_x = 113.5;
uniform float shore_sign = 1.0;
uniform float shore_depth : hint_range(0.0, 20.0) = 2.5;
uniform float shelf_slope : hint_range(0.0, 0.5) = 0.035;
uniform float shelf_depth : hint_range(0.0, 40.0) = 9.0;
uniform float drop_start = 90.0;
uniform float drop_end = 420.0;
uniform float drop_depth : hint_range(0.0, 200.0) = 45.0;
uniform sampler2D bar_noise : filter_linear_mipmap, repeat_enable;
uniform float bar_scale = 140.0;
uniform float bar_height : hint_range(0.0, 4.0) = 0.9;

group_uniforms Sand;
uniform vec3 sand_color : source_color = vec3(0.66, 0.58, 0.42);
uniform vec3 sand_color_dark : source_color = vec3(0.48, 0.40, 0.28);
uniform sampler2D grain_noise : filter_linear_mipmap, repeat_enable;
uniform sampler2D ripple_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float ripple_scale = 6.0;
uniform float ripple_strength : hint_range(0.0, 2.0) = 0.8;
uniform float roughness : hint_range(0.0, 1.0) = 0.9;

group_uniforms Water;
uniform sampler2D caustic_noise : filter_linear_mipmap, repeat_enable;
uniform float caustic_scale = 5.5;
uniform float caustic_speed = 0.25;
uniform float caustic_strength : hint_range(0.0, 3.0) = 1.4;
// Absorption of the sunlight on its way down (per model unit of depth).
uniform vec3 light_absorption = vec3(0.12, 0.05, 0.03);

varying vec3 v_pos;     // model position after displacement
varying float v_depth;  // model units below sea level (sea level = y 0)

float profile(vec2 p) {
	float d = max((shore_x - p.x) * shore_sign, 0.0);
	float shelf = min(d * shelf_slope, shelf_depth);
	float drop = smoothstep(drop_start, drop_end, d) * drop_depth;
	float bars = (textureLod(bar_noise, p / bar_scale, 0.0).r - 0.5) * 2.0 * bar_height;
	// Sandbars fade in over the first 25 units from the waterline.
	bars *= clamp(d / 25.0, 0.0, 1.0);
	return shore_depth + shelf + drop + bars;
}

void vertex() {
	vec2 p = VERTEX.xz;
	float h = profile(p);
	VERTEX.y -= h;
	float e = 2.0;
	float hx = profile(p + vec2(e, 0.0));
	float hz = profile(p + vec2(0.0, e));
	NORMAL = normalize(vec3(hx - h, e, hz - h));
	v_pos = VERTEX;
	v_depth = h;
}

void fragment() {
	vec2 uv = v_pos.xz;
	float g1 = texture(grain_noise, uv / 37.0).r;
	float g2 = texture(grain_noise, uv / 4.1 + vec2(0.37, 0.11)).r;
	float g3 = texture(grain_noise, uv / 0.9).r;
	float tone = clamp(g1 * 0.55 + g2 * 0.3 + g3 * 0.15, 0.0, 1.0);
	vec3 col = mix(sand_color_dark, sand_color, smoothstep(0.25, 0.75, tone));

	// Ripples run along the shore.
	vec3 rn = texture(ripple_normal, vec2(uv.x / (ripple_scale * 0.35), uv.y / (ripple_scale * 3.0))).xyz * 2.0 - 1.0;
	vec3 rn2 = texture(ripple_normal, uv / (ripple_scale * 9.0)).xyz * 2.0 - 1.0;
	// NORMAL_MAP takes the raw [0,1] texture encoding, not a signed vector.
	NORMAL_MAP = normalize(vec3((rn.xy + rn2.xy * 0.5) * ripple_strength, 1.0)) * 0.5 + 0.5;

	// Caustics: two drifting layers multiplied, strongest in the shallows.
	float t = TIME * caustic_speed;
	float c1 = texture(caustic_noise, uv / caustic_scale + vec2(t * 0.11, t * 0.07)).r;
	float c2 = texture(caustic_noise, uv / (caustic_scale * 1.37) + vec2(-t * 0.09, t * 0.13)).r;
	float caus = c1 * c2;
	caus = caus * caus * 4.0;
	float caus_fade = exp(-v_depth * 0.16);
	col *= 1.0 + caus * caustic_strength * caus_fade;

	// Sunlight already absorbed on the way down.
	col *= exp(-light_absorption * v_depth);

	ALBEDO = col;
	ROUGHNESS = roughness;
	SPECULAR = 0.2;
}
