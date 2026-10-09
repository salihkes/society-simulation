// Ground (height, normal y) from RainSystem's 40 m top-down height map; far below off the map.
uniform sampler2D surface_map : filter_nearest, repeat_disable;
uniform vec2 surface_origin;
uniform bool surface_ready = false;
uniform vec3 rain_center;
uniform float intensity = 0.6;

vec2 rain_surface(vec2 world_xz) {
	vec2 uv = (world_xz - surface_origin) / 40.0;
	if (!surface_ready || any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
		return vec2(-10000.0, 0.0);
	}
	return textureLod(surface_map, uv, 0.0).rg;
}
