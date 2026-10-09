// Simple animated water with crest foam; freezes flat, opaque and pale where the ice field is high.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

#include "res://src/world/environment/regional_field.gdshaderinc"
uniform float frozen_surface_offset = 0.0;
varying vec2 ice_world_xz;
uniform float wave_speed : hint_range(0.0, 5.0) = 2.0;
uniform float wave_amplitude : hint_range(0.0, 1.0) = 0.1;
uniform float wave_frequency : hint_range(0.0, 10.0) = 2.0;
uniform vec4 water_color : source_color = vec4(0.2, 0.6, 0.8, 0.7);
uniform vec4 deep_water_color : source_color = vec4(0.1, 0.3, 0.5, 0.9);
uniform float transparency : hint_range(0.0, 1.0) = 0.7;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.1;
uniform sampler2D water_normal : source_color;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform float foam_threshold : hint_range(0.0, 1.0) = 0.8;
uniform vec4 foam_color : source_color = vec4(1.0, 1.0, 1.0, 0.8);

varying vec3 world_position;
varying vec3 world_normal;

void vertex() {
	ice_world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	float ice = regional_enabled ? smoothstep(0.0, 0.95, regional_field(ice_world_xz)) : 0.0;
	world_position = VERTEX;
	world_normal = NORMAL;

	float wave1 = sin(world_position.x * wave_frequency + TIME * wave_speed) * wave_amplitude;
	float wave2 = sin(world_position.z * wave_frequency * 0.7 + TIME * wave_speed * 1.3) * wave_amplitude * 0.5;

	VERTEX.y += (wave1 + wave2) * (1.0 - ice) + frozen_surface_offset * ice;
}

void fragment() {
	float ice = regional_enabled ? smoothstep(0.0, 0.95, regional_field(ice_world_xz)) : 0.0;
	vec2 uv_offset = world_position.xz * 0.1;
	vec2 animated_uv = uv_offset + TIME * 0.1 * (1.0 - ice);

	vec3 normal_map = texture(water_normal, animated_uv).rgb;
	normal_map = normal_map * 2.0 - 1.0;
	normal_map *= normal_strength;

	float wave_height = sin(world_position.x * wave_frequency + TIME * wave_speed) +
			sin(world_position.z * wave_frequency * 0.7 + TIME * wave_speed * 1.3);
	wave_height = (wave_height + 2.0) / 4.0;

	vec4 final_color = mix(deep_water_color, water_color, wave_height);

	if (wave_height > foam_threshold) {
		float foam_intensity = (wave_height - foam_threshold) / (1.0 - foam_threshold);
		final_color = mix(final_color, foam_color, foam_intensity * 0.5);
	}

	ALBEDO = mix(final_color.rgb, vec3(0.67, 0.80, 0.86), ice);
	ALPHA = mix(final_color.a * transparency, 1.0, ice);
	METALLIC = metallic;
	ROUGHNESS = mix(roughness, 0.65, ice);
	NORMAL_MAP = mix(normal_map, vec3(0.5, 0.5, 1.0), ice);
}
