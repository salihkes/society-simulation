// Planet surface colour from elevation and slope in planet-local space (chunks sit untransformed); holes discard.
shader_type spatial;

uniform float planet_radius = 600.0;
uniform float beach_top = 4.0;
uniform float rock_slope_deg = 38.0;
uniform float snow_start = 65.0;

uniform vec3 sand_color : source_color = vec3(0.87, 0.78, 0.55);
uniform vec3 grass_color : source_color = vec3(0.32, 0.55, 0.22);
uniform vec3 grass_color_dry : source_color = vec3(0.52, 0.58, 0.25);
uniform vec3 rock_color : source_color = vec3(0.45, 0.41, 0.38);
uniform vec3 snow_color : source_color = vec3(0.95, 0.96, 1.0);
uniform vec3 seabed_color : source_color = vec3(0.75, 0.70, 0.52);

uniform sampler2D grass_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform float grass_tex_amount : hint_range(0.0, 1.0) = 0.35;
uniform float tex_scale = 0.15;

// Surface holes: xyz = planet-local unit direction, w = cos(angular radius).
uniform int hole_count = 0;
uniform vec4 holes[32];

varying vec3 v_pos;    // planet-local position
varying vec3 v_norm;   // planet-local normal

void vertex() {
	v_pos = VERTEX;
	v_norm = NORMAL;
}

float hash31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash31(i);
	float n100 = hash31(i + vec3(1, 0, 0));
	float n010 = hash31(i + vec3(0, 1, 0));
	float n110 = hash31(i + vec3(1, 1, 0));
	float n001 = hash31(i + vec3(0, 0, 1));
	float n101 = hash31(i + vec3(1, 0, 1));
	float n011 = hash31(i + vec3(0, 1, 1));
	float n111 = hash31(i + vec3(1, 1, 1));
	return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
	           mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

vec3 triplanar(sampler2D tex, vec3 p, vec3 n, float scale) {
	vec3 w = abs(n);
	w = w / (w.x + w.y + w.z);
	vec3 x = texture(tex, p.yz * scale).rgb;
	vec3 y = texture(tex, p.xz * scale).rgb;
	vec3 z = texture(tex, p.xy * scale).rgb;
	return x * w.x + y * w.y + z * w.z;
}

void fragment() {
	float elev = length(v_pos) - planet_radius;
	vec3 up = normalize(v_pos);
	for (int i = 0; i < hole_count; i++) {
		if (dot(up, holes[i].xyz) > holes[i].w) {
			discard;
		}
	}
	vec3 n = normalize(v_norm);
	float slope = degrees(acos(clamp(dot(n, up), -1.0, 1.0)));

	float band_wobble = (vnoise(v_pos * 0.08) - 0.5) * 3.0;
	float macro = vnoise(v_pos * 0.02);

	vec3 col;
	float e = elev + band_wobble;
	if (e < 0.0) {
		col = mix(seabed_color, seabed_color * 0.45, clamp(-e * 0.08, 0.0, 1.0));
	} else {
		vec3 grass = mix(grass_color, grass_color_dry, macro);
		grass = mix(grass, grass * triplanar(grass_tex, v_pos, n, tex_scale) * 1.8, grass_tex_amount);
		float beach_w = 1.0 - smoothstep(beach_top * 0.6, beach_top * 1.4, e);
		float snow_w = smoothstep(snow_start - 6.0, snow_start + 6.0, e);
		col = mix(grass, sand_color, beach_w);
		col = mix(col, snow_color, snow_w);
	}

	float rock_w = smoothstep(rock_slope_deg - 6.0, rock_slope_deg + 6.0, slope + band_wobble * 2.0);
	vec3 rock = rock_color * (0.8 + 0.4 * vnoise(v_pos * 0.3));
	col = mix(col, rock, rock_w);

	float wet = 1.0 - smoothstep(0.0, 1.2, abs(elev - 0.2));
	col = mix(col, col * 0.55, wet * 0.7);

	ALBEDO = col;
	ROUGHNESS = mix(0.95, 0.75, rock_w);
	SPECULAR = 0.2;
}
