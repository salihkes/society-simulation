// Time-of-day sky blended from the sun's elevation; no depth texture, so it runs on Compatibility.
shader_type sky;

// Unit vector from the observer towards the sun, in world space.
uniform vec3 sun_direction = vec3(0.0, 0.40, -0.92);

uniform vec3 day_zenith    : source_color = vec3(0.16, 0.34, 0.66);
uniform vec3 day_horizon   : source_color = vec3(0.66, 0.78, 0.88);
uniform vec3 dusk_zenith   : source_color = vec3(0.22, 0.20, 0.38);
uniform vec3 dusk_horizon  : source_color = vec3(0.95, 0.51, 0.26);
uniform vec3 night_zenith  : source_color = vec3(0.015, 0.030, 0.075);
uniform vec3 night_horizon : source_color = vec3(0.050, 0.070, 0.130);
uniform vec3 ground_color  : source_color = vec3(0.12, 0.11, 0.10);

uniform vec3 sun_tint  : source_color = vec3(1.0, 0.96, 0.88);
uniform vec3 moon_tint : source_color = vec3(0.82, 0.85, 0.95);

uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.48;
uniform float cloud_speed    = 0.010;
uniform float cloud_scale    = 1.7;
uniform float cloud_softness : hint_range(0.01, 0.6) = 0.22;

uniform float star_density : hint_range(0.0, 1.0) = 0.10;

float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noise(vec3 x) {
	vec3 p = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(p + vec3(0, 0, 0)), hash(p + vec3(1, 0, 0)), f.x),
				   mix(hash(p + vec3(0, 1, 0)), hash(p + vec3(1, 1, 0)), f.x), f.y),
			   mix(mix(hash(p + vec3(0, 0, 1)), hash(p + vec3(1, 0, 1)), f.x),
				   mix(hash(p + vec3(0, 1, 1)), hash(p + vec3(1, 1, 1)), f.x), f.y), f.z);
}

float fbm(vec3 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * noise(p);
		p *= 2.0;
		a *= 0.5;
	}
	return v;
}

void sky() {
	vec3 dir = EYEDIR;

	// sun_direction.y is sin(elevation).
	float elev  = sun_direction.y;
	float day   = smoothstep(0.06, 0.28, elev);
	float night = 1.0 - smoothstep(-0.22, -0.05, elev);
	float dusk  = clamp(1.0 - day - night, 0.0, 1.0);

	vec3 zenith  = day * day_zenith  + dusk * dusk_zenith  + night * night_zenith;
	vec3 horizon = day * day_horizon + dusk * dusk_horizon + night * night_horizon;

	float h = clamp(dir.y, 0.0, 1.0);
	float grad = pow(1.0 - h, 2.4);
	vec3 col = mix(zenith, horizon, grad);

	float sd = dot(dir, sun_direction);
	float toward_sun = max(sd, 0.0);
	vec3 halo_tint = mix(vec3(1.0, 0.62, 0.30), sun_tint, day);
	col += halo_tint * pow(toward_sun, 5.0) * (0.35 + 0.95 * dusk) * (1.0 - night);

	if (dir.y > -0.05) {
		// Dome projection: clouds stretch towards the horizon.
		vec2 uv = dir.xz / (abs(dir.y) + 0.22);
		vec3 cp = vec3(uv * cloud_scale, 0.0)
				+ vec3(TIME * cloud_speed, TIME * cloud_speed * 0.3, TIME * cloud_speed * 0.6);
		float c = fbm(cp);
		float cover = mix(0.78, 0.30, cloud_coverage);
		float cloud = smoothstep(cover, cover + cloud_softness, c);
		cloud *= smoothstep(-0.02, 0.18, dir.y);
		float lit = pow(toward_sun, 2.0);
		vec3 cloud_lo = mix(vec3(0.40, 0.42, 0.48), vec3(0.06, 0.07, 0.11), night);
		vec3 cloud_hi = mix(mix(vec3(1.0), vec3(1.0, 0.72, 0.45), dusk),
							vec3(0.14, 0.16, 0.22), night);
		vec3 cloud_col = mix(cloud_lo, cloud_hi, lit);
		col = mix(col, cloud_col, cloud * 0.92);
	}

	if (night > 0.01 && dir.y > 0.0) {
		vec3 cell = floor(dir * 320.0);
		float s = hash(cell);
		float star = step(1.0 - star_density * 0.06, s);
		// Separate hashes for twinkle: all visible stars share a tiny range of s.
		float phase = hash(cell + 11.7) * 6.2831853;
		float speed = 2.0 + hash(cell + 41.3) * 3.0;
		star *= 0.55 + 0.45 * sin(TIME * speed + phase);
		col += vec3(star) * night * smoothstep(0.0, 0.25, dir.y);
	}

	float md = dot(dir, -sun_direction);
	float moon = smoothstep(0.9988, 0.9994, md) * night;
	col = mix(col, moon_tint, moon);
	col += moon_tint * pow(max(md, 0.0), 220.0) * night * 0.5;

	float sun = smoothstep(0.99955, 0.99975, sd);
	sun *= smoothstep(-0.10, 0.0, elev);
	vec3 sun_col = mix(vec3(1.0, 0.55, 0.25), sun_tint, day);
	col = mix(col, sun_col * 1.6, sun);

	if (dir.y < 0.0) {
		float g = smoothstep(0.0, -0.15, dir.y);
		col = mix(col, ground_color * (0.3 + 0.7 * day), g);
	}

	COLOR = col;
}
