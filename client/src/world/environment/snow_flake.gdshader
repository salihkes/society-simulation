// Falling snow flakes: camera-facing quads wrapped around the player, hidden below the ground.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, skip_vertex_transform;

#include "rain_surface.gdshaderinc"

uniform float snow_time = 0.0;
varying float visibility;

void vertex() {
	vec3 volume = vec3(28.0, 16.0, 28.0);
	float speed = mix(0.35, 1.05, INSTANCE_CUSTOM.w);
	float phase = INSTANCE_CUSTOM.w * 62.83;
	vec3 travel = vec3(snow_time * 0.25 + sin(snow_time * 0.7 + phase) * 0.35,
		-snow_time * speed, snow_time * 0.1 + cos(snow_time * 0.55 + phase) * 0.4);
	vec3 flake = mod(INSTANCE_CUSTOM.xyz * volume + travel - rain_center + volume * 0.5, volume) - volume * 0.5 + rain_center;
	vec3 relative = flake - rain_center;
	visibility = smoothstep(0.18, 0.7, length(relative))
		* (1.0 - smoothstep(9.0, 14.0, length(relative.xz)))
		* (1.0 - smoothstep(5.5, 8.0, abs(relative.y)))
		* smoothstep(0.01, 0.12, flake.y - rain_surface(flake.xz).x);
	float size = mix(0.008, 0.026, INSTANCE_CUSTOM.w);
	vec3 across = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	vec3 p = flake + (across * VERTEX.x + up * VERTEX.y) * size;
	VERTEX = (VIEW_MATRIX * vec4(p, 1.0)).xyz;
	NORMAL = vec3(0, 0, 1);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float shape = 1.0 - smoothstep(0.2, 1.0, length(p));
	ALBEDO = vec3(0.88, 0.94, 1.0);
	ROUGHNESS = 0.95;
	ALPHA = shape * visibility * 0.8;
}
