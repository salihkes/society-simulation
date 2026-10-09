// Ring-shaped splashes on wet ground, wrapped in a 24 m tile around the player.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, skip_vertex_transform;

#include "rain_surface.gdshaderinc"

uniform float rain_time;
varying float age;
varying float visibility;

void vertex() {
	vec2 span = vec2(24.0);
	vec2 xz = mod(INSTANCE_CUSTOM.xz * span - rain_center.xz + span * 0.5, span)
		- span * 0.5 + rain_center.xz;
	vec2 surface = rain_surface(xz);
	age = fract(rain_time * mix(1.8, 3.2, INSTANCE_CUSTOM.y) + INSTANCE_CUSTOM.w);
	float radius = mix(0.012, 0.065, age);
	vec3 point = vec3(xz.x, surface.x + 0.012, xz.y);
	visibility = step(0.85, surface.y) * (1.0 - smoothstep(8.0, 12.0, length(xz - rain_center.xz)));
	vec3 world_vertex = point + vec3(VERTEX.x, 0.0, VERTEX.y) * radius * 2.0;
	VERTEX = (VIEW_MATRIX * vec4(world_vertex, 1.0)).xyz;
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
}

void fragment() {
	float radius = length((UV - vec2(0.5)) * 2.0);
	float ring = smoothstep(0.6, 0.8, radius) * (1.0 - smoothstep(0.8, 1.0, radius));
	ALBEDO = vec3(0.55, 0.61, 0.66);
	ROUGHNESS = 0.3;
	ALPHA = ring * (1.0 - age) * (1.0 - age) * visibility * intensity * 0.24;
}
