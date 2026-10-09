// Country terrain colour from height, slope and noise, with snow from the regional field or global snow depth.
shader_type spatial;
render_mode diffuse_burley;

instance uniform vec2 tile_origin = vec2(0.0);
uniform float sea_y = -8.6957;
#include "res://src/world/environment/regional_field.gdshaderinc"
varying vec2 snow_world_xz;
uniform float snow_depth = 0.0;
varying vec3 terrain_position;
varying vec3 terrain_normal;

void vertex() {
	snow_world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	terrain_position = VERTEX + vec3(tile_origin.x, 0.0, tile_origin.y);
	terrain_normal = NORMAL;
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f*f*(3.0-2.0*f);
	vec4 v = fract(sin(vec4(dot(i, vec2(127.1,311.7)), dot(i+vec2(1,0),vec2(127.1,311.7)),
		dot(i+vec2(0,1),vec2(127.1,311.7)), dot(i+vec2(1,1),vec2(127.1,311.7)))) * 43758.5453);
	return mix(mix(v.x,v.y,f.x), mix(v.z,v.w,f.x),f.y);
}

void fragment() {
	float local_snow_depth = regional_enabled ? regional_field(snow_world_xz) : snow_depth;
	float height = terrain_position.y - sea_y;
	float slope = 1.0 - normalize(terrain_normal).y;
	float broad = noise(terrain_position.xz / 700.0);
	float detail = noise(terrain_position.xz / 40.0);
	vec3 ground = mix(vec3(.36,.40,.21), vec3(.57,.49,.31), broad);
	float forest = smoothstep(.40,.70,broad) * smoothstep(30.0,180.0,height) * (1.0-smoothstep(700.0,1200.0,height));
	ground = mix(ground, vec3(.17,.26,.13), forest * .8);
	ground = mix(ground, vec3(.55,.53,.47), smoothstep(.12,.38,slope));
	ground *= .90 + detail*.16;
	ground = mix(vec3(.62,.55,.40), ground, smoothstep(0.0,4.0,height));
	ground = mix(ground, vec3(.87,.91,.95), smoothstep(.001,.015,local_snow_depth) * smoothstep(.5,.9,terrain_normal.y) * smoothstep(.2,1.0,height));
	ALBEDO = ground;
	ROUGHNESS = .94;
	SPECULAR = .12;
}
