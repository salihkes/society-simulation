// Regional weather at a world XZ point: regional_weather.gd's field over five (x, z, value) centres.
uniform bool regional_enabled = false;
uniform vec4 regional_values[5];
uniform float regional_scale = 1.0;

float regional_field(vec2 world_xz) {
	float total = 0.0;
	float value = 0.0;
	for (int i = 0; i < 5; i++) {
		vec2 delta = (world_xz - regional_values[i].xy) / max(regional_scale, 0.0001);
		float d = dot(delta, delta) / 100000000.0;
		float weight = 1.0 / max(d * d, 0.000001);
		total += weight;
		value += regional_values[i].z * weight;
	}
	return value / max(total, 0.000001);
}
