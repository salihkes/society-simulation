// Landscape around the city in model units (1 unit ~ 1 m), layered by height, slope and noise.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform float sea_y = -8.6957;
uniform vec2 city_xz = vec2(-232.0, -238.0);
// Distant snow tint, matching the detailed snow cover near the player.
#include "res://src/world/environment/regional_field.gdshaderinc"
varying vec2 snow_world_xz;
uniform float snow_depth = 0.0;

group_uniforms Palette;
uniform vec3 sand_color : source_color = vec3(0.66, 0.58, 0.42);
uniform vec3 sand_dark : source_color = vec3(0.48, 0.40, 0.28);
uniform vec3 grass_dry : source_color = vec3(0.60, 0.52, 0.30);
uniform vec3 grass_green : source_color = vec3(0.30, 0.42, 0.17);
uniform vec3 scrub_color : source_color = vec3(0.33, 0.36, 0.19);
uniform vec3 forest_color : source_color = vec3(0.12, 0.21, 0.10);
uniform vec3 rock_color : source_color = vec3(0.58, 0.55, 0.50);
uniform vec3 rock_dark : source_color = vec3(0.33, 0.31, 0.29);
uniform vec3 soil_color : source_color = vec3(0.47, 0.36, 0.24);
uniform vec3 urban_light : source_color = vec3(0.66, 0.62, 0.56);
uniform vec3 urban_roof : source_color = vec3(0.56, 0.41, 0.33);
uniform vec3 urban_shade : source_color = vec3(0.42, 0.42, 0.43);
uniform vec3 field_a : source_color = vec3(0.52, 0.46, 0.24);
uniform vec3 field_b : source_color = vec3(0.36, 0.44, 0.20);
uniform vec3 field_c : source_color = vec3(0.50, 0.38, 0.26);

group_uniforms Rules;
uniform float beach_top = 1.2;
uniform float rock_slope_deg = 30.0;
uniform float forest_min = 120.0;
uniform float forest_max = 900.0;
uniform float forest_amount : hint_range(0.0, 1.0) = 0.55;
uniform float urban_radius = 4200.0;
uniform float urban_amount : hint_range(0.0, 1.0) = 0.5;
uniform float field_scale = 210.0;
uniform float alpine_start = 850.0;
uniform vec3 light_absorption = vec3(0.12, 0.05, 0.03);
uniform float caustic_strength : hint_range(0.0, 3.0) = 1.4;

group_uniforms Textures;
uniform sampler2D macro_noise : filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_noise : filter_linear_mipmap, repeat_enable;
uniform sampler2D cells : filter_linear_mipmap, repeat_enable;
uniform sampler2D grain : filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D caustic_noise : filter_linear_mipmap, repeat_enable;
uniform float macro_scale = 2600.0;
uniform float detail_scale = 55.0;
uniform float grain_scale = 5.0;
uniform float cell_scale = 70.0;

varying vec3 v_pos;
varying vec3 v_norm;
varying float v_model_scale;

void vertex() {
	snow_world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	v_pos = VERTEX;
	v_norm = NORMAL;
	v_model_scale = length(MODEL_MATRIX[0].xyz);
}

void fragment() {
	float local_snow_depth = regional_enabled ? regional_field(snow_world_xz) : snow_depth;
	float h = v_pos.y - sea_y;
	vec3 n = normalize(v_norm);
	float slope = degrees(acos(clamp(n.y, 0.0, 1.0)));
	vec2 uv = v_pos.xz;
	float cam_dist = length(VERTEX) / v_model_scale;
	float near = 1.0 / (1.0 + cam_dist / 600.0);

	float m1 = texture(macro_noise, uv / macro_scale).r;
	float m2 = texture(macro_noise, uv / (macro_scale * 0.31) + vec2(0.37, 0.61)).r;
	float d1 = texture(detail_noise, uv / detail_scale).r;
	float d2 = texture(detail_noise, uv / (detail_scale * 0.23) + vec2(0.5, 0.1)).r;
	float g = texture(grain, uv / grain_scale).r;

	// Open ground: dry grass with greener hollows, scrub higher up.
	vec3 grass = mix(grass_green, grass_dry, smoothstep(0.2, 0.6, m1 * 0.7 + d1 * 0.3));
	grass *= 0.85 + 0.3 * d2;
	float scrub_w = smoothstep(0.35, 0.65, m2 + 0.2 * (d1 - 0.5)) * smoothstep(20.0, 60.0, h);
	vec3 ground = mix(grass, scrub_color * (0.8 + 0.4 * d1), scrub_w);
	ground *= 0.9 + 0.2 * g;

	// Bare earth on moderate slopes.
	float soil_w = smoothstep(18.0, 28.0, slope + 8.0 * (d2 - 0.5)) * (1.0 - smoothstep(rock_slope_deg - 4.0, rock_slope_deg + 4.0, slope));
	ground = mix(ground, soil_color * (0.85 + 0.3 * g), soil_w * 0.7);

	// Forest on the hills.
	float forest_n = 0.55 * texture(macro_noise, uv / (macro_scale * 0.45) + vec2(0.71, 0.13)).r
		+ 0.45 * texture(macro_noise, vec2(uv.y, -uv.x) / (macro_scale * 1.7) + vec2(0.2, 0.9)).r;
	float forest_w = smoothstep(0.5 - forest_amount * 0.3, 0.62, forest_n + 0.15 * (d1 - 0.5))
		* smoothstep(forest_min - 40.0, forest_min + 60.0, h)
		* (1.0 - smoothstep(forest_max - 150.0, forest_max + 100.0, h))
		* (1.0 - smoothstep(30.0, 42.0, slope));
	ground = mix(ground, forest_color * (0.75 + 0.5 * d2), forest_w);

	// Thin grey ground high up.
	float alp = smoothstep(alpine_start, alpine_start + 300.0, h);
	ground = mix(ground, mix(rock_color, grass_dry, 0.4) * (0.8 + 0.3 * d1), alp * 0.6);

	// Rock on steep faces, with strata.
	float rock_w = smoothstep(rock_slope_deg - 5.0 + 10.0 * (d1 - 0.5), rock_slope_deg + 6.0, slope);
	float strata = texture(detail_noise, vec2(uv.x / (detail_scale * 2.0), v_pos.y / (detail_scale * 0.25))).r;
	vec3 rock = mix(rock_dark, rock_color, 0.35 + 0.65 * strata) * (0.8 + 0.3 * g);
	vec3 col = mix(ground, rock, rock_w);

	// Fields on the flat plain.
	float f1 = texture(cells, uv / field_scale).r;
	float f2 = texture(cells, uv / (field_scale * 0.53) + vec2(0.61, 0.17)).r;
	vec3 field = mix(field_a, field_b, smoothstep(0.25, 0.75, f1 * 0.7 + m2 * 0.3));
	field = mix(field, field_c, smoothstep(0.6, 0.85, f2) * 0.5);
	field = mix(field, ground, 0.35);
	field *= 0.85 + 0.2 * d1 + 0.1 * g;
	float field_w = (1.0 - smoothstep(2.5, 6.0, slope)) * (1.0 - smoothstep(60.0, 140.0, h)) * smoothstep(0.2, 0.45, m1 + 0.2);
	col = mix(col, field, field_w * 0.8);

	// Suburbs on gentle low ground around the city.
	float dcity = distance(uv, city_xz);
	float c1 = texture(cells, uv / cell_scale).r;
	float c2 = texture(cells, uv / (cell_scale * 0.37) + vec2(0.29, 0.83)).r;
	vec3 urb = mix(urban_light, urban_roof, smoothstep(0.35, 0.65, c1));
	urb = mix(urb, urban_shade, smoothstep(0.55, 0.8, c2) * 0.6);
	float urban_w = urban_amount
		* (1.0 - smoothstep(urban_radius * 0.45, urban_radius, dcity))
		* (1.0 - smoothstep(12.0, 22.0, slope))
		* (1.0 - smoothstep(180.0, 320.0, h))
		* smoothstep(0.3, 0.5, m2 + 0.25);
	col = mix(col, mix(col, urb, 0.7), urban_w);

	// Sand at the waterline.
	col = mix(sand_color * (0.9 + 0.2 * g), col, smoothstep(beach_top, beach_top + 1.2 + 1.5 * d1, h));

	float snow_cover = smoothstep(0.0005, 0.012, local_snow_depth * (0.5 + d1))
		* smoothstep(0.55, 0.85, n.y) * smoothstep(0.1, 0.4, h);
	col = mix(col, vec3(0.87, 0.92, 0.98) * (0.965 + g * 0.035), snow_cover);

	// Seabed: sand with caustics, losing light with depth.
	float depth = max(-h, 0.0);
	vec3 seabed = mix(sand_dark, sand_color, smoothstep(0.25, 0.75, g * 0.4 + d1 * 0.6));
	float t = TIME * 0.25;
	float ca = texture(caustic_noise, uv / 5.5 + vec2(t * 0.11, t * 0.07)).r;
	float cb = texture(caustic_noise, uv / 7.5 + vec2(-t * 0.09, t * 0.13)).r;
	float caus = ca * cb;
	caus = caus * caus * 4.0;
	seabed *= 1.0 + caus * caustic_strength * exp(-depth * 0.16);
	seabed *= exp(-light_absorption * depth);
	float under = 1.0 - smoothstep(-0.3, 0.3, h);
	col = mix(col, seabed, under);

	// Normal detail: strong on rock, faint elsewhere, gone in the distance.
	vec3 rn = texture(rock_normal, uv / 9.0).xyz * 2.0 - 1.0;
	vec3 rn2 = texture(rock_normal, uv / 41.0 + vec2(0.3)).xyz * 2.0 - 1.0;
	float nstr = (0.25 + 0.9 * rock_w) * near;
	vec3 n_model = normalize(n + vec3(rn.x + rn2.x * 0.6, 0.0, rn.y + rn2.y * 0.6) * nstr);
	NORMAL = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(n_model, 0.0)).xyz);

	ALBEDO = col;
	ROUGHNESS = mix(0.95, 0.82, rock_w);
	SPECULAR = mix(0.12, 0.2, under);
}
