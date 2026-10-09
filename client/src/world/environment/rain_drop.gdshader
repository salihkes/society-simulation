// Rain streaks: a world-space drop field around the camera, stretched along the fall.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, skip_vertex_transform;

#include "rain_surface.gdshaderinc"

uniform float fall_distance = 0.0;
uniform vec2 wind_offset;
uniform vec3 fall_velocity = vec3(0.5, -8.0, 0.2);
varying float visibility;

void vertex() {
	// Three drops in four stay in a small near volume, where streaks resolve.
	bool nearby = (INSTANCE_ID % 4) != 0;
	vec3 volume = nearby ? vec3(16.0, 12.0, 16.0) : vec3(36.0, 20.0, 36.0);
	float variation = mix(0.82, 1.18, INSTANCE_CUSTOM.w);
	// Motion is analytic in world space; the camera only picks the window.
	vec3 travel = vec3(wind_offset.x, -fall_distance * variation, wind_offset.y);
	vec3 drop = mod(INSTANCE_CUSTOM.xyz * volume + travel - rain_center + volume * 0.5, volume)
		- volume * 0.5 + rain_center;
	vec3 relative = drop - rain_center;
	float distance_to_eye = length(relative);
	visibility = smoothstep(0.35, 1.2, distance_to_eye)
		* (1.0 - smoothstep(volume.x * 0.33, volume.x * 0.5, length(relative.xz)))
		* (1.0 - smoothstep(volume.y * 0.35, volume.y * 0.5, abs(relative.y)));
	visibility *= smoothstep(0.02, 0.16, drop.y - rain_surface(drop.xz).x);
	vec3 down = normalize(fall_velocity);
	vec3 to_eye = normalize(INV_VIEW_MATRIX[3].xyz - drop);
	vec3 across = cross(down, to_eye);
	across /= max(length(across), 0.001);
	float width = mix(0.008, 0.016, INSTANCE_CUSTOM.w);
	float streak = length(fall_velocity) * variation / 45.0;
	vec3 world_vertex = drop + across * VERTEX.x * width + down * VERTEX.y * streak;
	VERTEX = (VIEW_MATRIX * vec4(world_vertex, 1.0)).xyz;
	NORMAL = normalize((VIEW_MATRIX * vec4(to_eye, 0.0)).xyz);
}

void fragment() {
	float side = (UV.x - 0.5) * 2.0;
	float taper = smoothstep(0.0, 0.18, UV.y) * (1.0 - smoothstep(0.65, 1.0, UV.y));
	ALBEDO = vec3(0.72, 0.76, 0.8);
	ROUGHNESS = 0.35;
	SPECULAR = 0.5;
	ALPHA = exp(-side * side * 4.0) * taper * visibility * mix(0.3, 0.55, intensity);
}
