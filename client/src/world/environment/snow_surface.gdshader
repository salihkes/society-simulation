// Snow layer around the player; tracks texture: r depth, g expiry time, b ground height, a track id.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D tracks : filter_linear, repeat_disable;
uniform float snow_depth = 0.0;
uniform float snowfall = 0.0;
uniform float snow_time = 0.0;
uniform float first_track = 1.0;
uniform vec2 tile_origin;
uniform float tile_size = 8.0;
uniform vec2 view_center;
uniform float view_radius = 48.0;
varying vec3 ground_position;
varying vec3 ground_normal;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f*f*(3.0-2.0*f);
	return mix(mix(hash(i),hash(i+vec2(1,0)),f.x), mix(hash(i+vec2(0,1)),hash(i+vec2(1,1)),f.x),f.y);
}

// How far footprints pressed the snow at uv, net of snow fallen since.
float compression(vec2 uv, float ground_y) {
	vec4 t = texture(tracks, clamp(uv, vec2(0.0), vec2(1.0)));
	// Only depth is filtered: filtered ids or height sentinels make moving footprint edges flicker.
	vec4 meta = texelFetch(tracks, clamp(ivec2(uv * 128.0), ivec2(0), ivec2(127)), 0);
	float valid = step(first_track - 0.5, meta.a) * step(snow_time, meta.g) * (1.0 - smoothstep(0.10, 0.3, abs(meta.b - ground_y)));
	return max(0.0, t.r - snowfall) * valid;
}

float height_at(vec2 uv, vec3 p) {
	float slope = smoothstep(0.55, 0.85, ground_normal.y);
	float undisturbed = snow_depth * slope * (0.88 + 0.12 * noise(p.xz * 1.8));
	return max(0.001, undisturbed - compression(uv, p.y));
}

void vertex() {
	ground_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	ground_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
	vec2 uv = (ground_position.xz - tile_origin) / tile_size;
	VERTEX.y += height_at(uv, ground_position) + 0.0015;
}

void fragment() {
	if (snow_depth < 0.001) { discard; }
	vec2 uv = (ground_position.xz - tile_origin) / tile_size;
	vec2 edge = abs(ground_position.xz - view_center);
	float coverage = 1.0 - smoothstep(view_radius - min(8.0, view_radius * 0.25), view_radius, max(edge.x, edge.y));
	// Thin cover starts as irregular patches rather than a uniform white.
	coverage *= smoothstep(0.0005, 0.007, snow_depth * (0.5 + noise(ground_position.xz * 5.0)));
	if (hash(floor(ground_position.xz * 170.0)) > coverage) { discard; }
	float step_uv = 1.0 / 128.0;
	float metres = tile_size * step_uv;
	float dx = height_at(uv + vec2(step_uv, 0), ground_position) - height_at(uv - vec2(step_uv, 0), ground_position);
	float dz = height_at(uv + vec2(0, step_uv), ground_position) - height_at(uv - vec2(0, step_uv), ground_position);
	vec3 n = normalize(ground_normal + vec3(-dx, 0.0, -dz) / (metres * 2.0));
	float grain_x = noise(ground_position.xz * 170.0) - 0.5;
	float grain_z = noise(ground_position.zx * 193.0) - 0.5;
	n = normalize(n + vec3(grain_x, 0, grain_z) * 0.07);
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	float packed = clamp(compression(uv, ground_position.y) / max(snow_depth, 0.005), 0.0, 1.0);
	float grain = noise(ground_position.xz * 75.0);
	ALBEDO = mix(vec3(0.87, 0.92, 0.98), vec3(0.65, 0.73, 0.82), packed * 0.35) * (0.965 + grain * 0.035);
	ROUGHNESS = mix(0.88, 0.56, packed);
	SPECULAR = 0.28;
	AO = 1.0 - packed * 0.12;
}
