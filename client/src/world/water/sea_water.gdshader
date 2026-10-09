// City coast sea in model units (1 unit ~ 1 m), divided by model scale so it works under a scaled parent.
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, diffuse_burley, specular_schlick_ggx;

#include "res://src/world/environment/regional_field.gdshaderinc"
uniform float frozen_surface_offset = 0.0;
varying vec2 ice_world_xz;

group_uniforms Colour;
// Water albedo is very low; its look comes from what lies under it and the sky, so these stay dark.
uniform vec3 shallow_color : source_color = vec3(0.06, 0.28, 0.30);
uniform vec3 deep_color : source_color = vec3(0.02, 0.09, 0.18);
uniform vec3 horizon_color : source_color = vec3(0.32, 0.42, 0.55);
uniform vec3 scatter_color : source_color = vec3(0.05, 0.30, 0.28);
// Beer-Lambert absorption per model unit of light path (r absorbed fastest).
uniform vec3 absorption = vec3(0.40, 0.18, 0.11);
uniform float depth_fade : hint_range(1.0, 60.0) = 12.0;

group_uniforms Waves;
uniform float wave_scale : hint_range(0.0, 3.0) = 1.0;
uniform float wave_speed : hint_range(0.0, 3.0) = 0.8;
uniform float wave_steepness : hint_range(0.0, 1.0) = 0.5;
uniform vec2 wind_dir = vec2(-0.85, 0.35);
uniform float wave_fade_start = 260.0;
uniform float wave_fade_end = 650.0;

group_uniforms Detail;
uniform sampler2D normal_a : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_b : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float detail_scale_a = 19.0;
uniform float detail_scale_b = 53.0;
uniform float detail_strength : hint_range(0.0, 2.0) = 0.55;
uniform float detail_fade = 350.0;

group_uniforms Foam;
uniform sampler2D foam_noise : filter_linear_mipmap, repeat_enable;
uniform vec3 foam_color : source_color = vec3(0.90, 0.93, 0.94);
uniform float shore_foam_width : hint_range(0.0, 20.0) = 4.5;
uniform float crest_foam : hint_range(0.0, 2.0) = 0.6;

group_uniforms Optics;
uniform float refraction_strength : hint_range(0.0, 0.2) = 0.045;
uniform float roughness_near : hint_range(0.0, 1.0) = 0.07;
uniform float roughness_far : hint_range(0.0, 1.0) = 0.32;
uniform float specular_level : hint_range(0.0, 1.0) = 0.5;
uniform float edge_fade : hint_range(0.0, 2.0) = 0.25;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;

// Undisplaced model xz with the displaced y.
varying vec3 v_model_pos;
varying vec3 v_wave_normal;
// Swell height at this vertex, about -1..1.
varying float v_crest;
varying float v_model_scale;

const float SEA_G = 9.8;

vec2 rotate2(vec2 v, float deg) {
	float a = radians(deg);
	float c = cos(a);
	float s = sin(a);
	return vec2(c * v.x - s * v.y, s * v.x + c * v.y);
}

void gerstner(vec2 p, float t, vec2 dir, float wavelength, float amp, float steep,
		inout vec3 disp, inout vec3 nrm) {
	if (amp <= 0.0001) {
		return;
	}
	float k = TAU / wavelength;
	float c = sqrt(SEA_G / k);
	vec2 d = normalize(dir);
	float f = k * (dot(d, p) - c * t);
	float q = steep / (k * amp * 4.0);
	float s = sin(f);
	float co = cos(f);
	disp.x += q * amp * d.x * co;
	disp.z += q * amp * d.y * co;
	disp.y += amp * s;
	float wa = k * amp;
	nrm.x -= d.x * wa * co;
	nrm.z -= d.y * wa * co;
	nrm.y -= q * wa * s;
}

void vertex() {
	float ms = length(MODEL_MATRIX[0].xyz);
	v_model_scale = ms;
	vec3 world_v = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float cam_dist = distance(world_v, CAMERA_POSITION_WORLD) / ms;
	float fade = 1.0 - smoothstep(wave_fade_start, wave_fade_end, cam_dist);
	ice_world_xz = world_v.xz;
	float ice = regional_enabled ? smoothstep(0.0, 0.95, regional_field(world_v.xz)) : 0.0;
	float a = wave_scale * fade * (1.0 - ice);
	VERTEX.y += frozen_surface_offset * ice;

	vec2 p = VERTEX.xz;
	float t = TIME * wave_speed;
	vec2 wd = normalize(wind_dir);
	vec3 disp = vec3(0.0);
	vec3 n = vec3(0.0, 1.0, 0.0);
	gerstner(p, t, rotate2(wd, 0.0), 46.0, 0.50 * a, wave_steepness, disp, n);
	gerstner(p, t, rotate2(wd, 24.0), 27.0, 0.30 * a, wave_steepness, disp, n);
	gerstner(p, t, rotate2(wd, -33.0), 14.0, 0.15 * a, wave_steepness * 0.8, disp, n);
	gerstner(p, t, rotate2(wd, 61.0), 7.0, 0.06 * a, wave_steepness * 0.6, disp, n);

	VERTEX += disp;
	v_model_pos = vec3(p.x, VERTEX.y, p.y);
	v_wave_normal = normalize(n);
	v_crest = disp.y / max(1.01 * a, 0.001);
	NORMAL = v_wave_normal;
}

// View-space depth from a raw depth sample, for either renderer.
float linear_depth(float raw, vec2 uv, mat4 inv_proj) {
	vec3 ndc = vec3(uv * 2.0 - 1.0, raw);
	if (CURRENT_RENDERER == RENDERER_COMPATIBILITY) {
		ndc.z = raw * 2.0 - 1.0;
	}
	vec4 v = inv_proj * vec4(ndc, 1.0);
	return -v.z / v.w;
}

void fragment() {
	float ms = v_model_scale;
	vec2 uv = v_model_pos.xz;
	vec2 wd = normalize(wind_dir);
	vec2 wp = vec2(-wd.y, wd.x);
	float ice = regional_enabled ? smoothstep(0.0, 0.95, regional_field(ice_world_xz)) : 0.0;
	float t = TIME * wave_speed * (1.0 - ice);
	float cam_dist = length(VERTEX) / ms;
	float detail_atten = 1.0 / (1.0 + cam_dist / detail_fade);

	// Detail normals: two scales along the wind, one fine cross ripple.
	vec3 n1 = texture(normal_a, uv / detail_scale_a + wd * t * 0.028).xyz * 2.0 - 1.0;
	vec3 n2 = texture(normal_b, uv / detail_scale_b + (wd * 0.6 + wp * 0.3) * t * 0.016).xyz * 2.0 - 1.0;
	vec3 n3 = texture(normal_a, uv / (detail_scale_a * 0.31) + wp * t * 0.05 - wd * t * 0.02).xyz * 2.0 - 1.0;
	vec2 dxy = (n1.xy + n2.xy * 0.8 + n3.xy * 0.45) * detail_strength * detail_atten * (1.0 - ice);
	vec3 n_model = normalize(vec3(v_wave_normal.x + dxy.x, v_wave_normal.y, v_wave_normal.z + dxy.y));
	vec3 n_view = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(n_model, 0.0)).xyz);
	if (!FRONT_FACING) {
		n_view = -n_view;
	}
	NORMAL = n_view;

	// Depth of the scene behind the surface, in model units.
	float water_z = -VERTEX.z;
	float scene_z = linear_depth(texture(depth_tex, SCREEN_UV).r, SCREEN_UV, INV_PROJECTION_MATRIX);
	float depth_m = max(scene_z - water_z, 0.0) / ms;

	// Refraction never pulls in things in front of the water.
	vec2 offs = n_model.xz * refraction_strength * clamp(depth_m / 3.0, 0.0, 1.0) / (1.0 + water_z / ms * 0.02);
	vec2 ruv = clamp(SCREEN_UV + offs, vec2(0.001), vec2(0.999));
	float scene_z_r = linear_depth(texture(depth_tex, ruv).r, ruv, INV_PROJECTION_MATRIX);
	if (scene_z_r < water_z) {
		ruv = SCREEN_UV;
	} else {
		depth_m = max(scene_z_r - water_z, 0.0) / ms;
	}
	vec3 refracted = texture(screen_tex, ruv).rgb;

	vec3 absorb = exp(-absorption * depth_m);
	float deep_t = 1.0 - exp(-depth_m / depth_fade);
	vec3 body = mix(shallow_color, deep_color, deep_t);
	vec3 col = mix(body, refracted, absorb);

	// Horizon tint; the engine's specular adds the sky reflection itself.
	float ndv = clamp(dot(n_view, VIEW), 0.0, 1.0);
	float fres = 0.02 + 0.98 * pow(1.0 - ndv, 5.0);
	col = mix(col, horizon_color, fres * 0.7);

	// Light scattered through the swell crests.
	col += scatter_color * clamp(v_crest, 0.0, 1.0) * (1.0 - fres) * 0.25 * detail_atten;

	float fn1 = texture(foam_noise, uv / 9.0 + wd * t * 0.022).r;
	float fn2 = texture(foam_noise, uv / 3.3 - wd * t * 0.031 + wp * t * 0.01).r;
	float foam_mask = fn1 * 0.6 + fn2 * 0.4;
	float shore = 1.0 - clamp(depth_m / shore_foam_width, 0.0, 1.0);
	shore = shore * shore;
	float shore_foam = shore * smoothstep(0.45, 0.8, foam_mask + shore * 0.4);
	float contact = 1.0 - smoothstep(0.0, 0.7, depth_m);
	shore_foam = max(shore_foam, contact * smoothstep(0.35, 0.75, foam_mask) * 0.55);
	float crest = smoothstep(0.55, 1.0, v_crest) * crest_foam * smoothstep(0.5, 0.75, foam_mask);
	float foam = clamp(shore_foam + crest, 0.0, 1.0) * clamp(detail_atten * 1.6, 0.0, 1.0);
	col = mix(col, foam_color, foam);

	float rough = mix(roughness_near, roughness_far, clamp(cam_dist / (detail_fade * 2.0), 0.0, 1.0));
	rough = mix(rough, 0.85, foam);

	float frost = texture(foam_noise, ice_world_xz / max(ms, 0.0001) / 7.0).r;
	col = mix(col, mix(vec3(0.32, 0.49, 0.57), vec3(0.79, 0.88, 0.91), frost), ice);
	rough = mix(rough, 0.48 + frost * 0.3, ice);
	ALBEDO = col;
	ROUGHNESS = rough;
	METALLIC = 0.0;
	SPECULAR = specular_level * (1.0 - foam * 0.8);
	ALPHA = mix(mix(1.0, smoothstep(0.0, edge_fade, depth_m), step(0.001, edge_fade)), 1.0, ice);
}
