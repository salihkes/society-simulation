// CRT tube on the glass: the picture is emission from a curved mesh, reflections are ordinary PBR.
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D signal_tex : filter_linear, repeat_disable;
uniform vec2 size = vec2(0.53, 0.40);       // glass, metres
uniform vec3 glass_tint : source_color = vec3(0.1, 0.1, 0.11);
uniform float roughness = 0.06;
uniform float brightness = 1.7;
uniform float crt_gamma = 2.4;
uniform float energy = 1.0;                  // power ramp, fed by crt_tv.gd
uniform vec2 squeeze = vec2(1.0);            // power-off collapse
uniform vec2 raster_scale = vec2(1.0);       // breathing and warm-up, fed per frame
uniform float tilt = 0.0;                    // raster rotation, radians
uniform float overscan = 0.06;
uniform float geometry = 0.03;
uniform float corner = 0.25;
uniform float edge_soft = 0.004;
uniform float lines = 480.0;
uniform float refresh = 59.94;
uniform int progressive = 0;
uniform float scanline = 0.5;
uniform float beam_min = 0.3;
uniform float beam_max = 0.5;
uniform float interlace_flicker = 0.15;
uniform float bloom_spread = 0.0;
uniform float focus_falloff = 0.0;
uniform float convergence = 0.0;             // metres at the corner
uniform int mask_type = 1;                   // 0 none, 1 slot, 2 aperture grille
uniform float mask_pitch = 0.00078;
uniform float mask_strength = 0.5;
uniform float mask_dim = 0.25;               // other two phosphors through this one's slot
uniform float slot_height = 2.2;             // slot mask: slot length in pitches
uniform int damper_wires = 0;
uniform float halation = 0.12;
uniform float halation_radius = 0.02;
uniform mat3 phosphor = mat3(1.0);
uniform float degauss = 0.0;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x), mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), f.x), f.y);
}

// One signal sample with the beams landed apart and the spot spread sideways; returns gamma-encoded.
vec3 tap(vec2 uv, vec2 conv, float hblur) {
	vec3 c;
	c.r = texture(signal_tex, uv + conv).r;
	c.g = texture(signal_tex, uv).g;
	c.b = texture(signal_tex, uv - conv).b;
	if (hblur > 0.0) {
		vec2 d = vec2(hblur, 0.0);
		vec3 l;
		vec3 r;
		l.r = texture(signal_tex, uv + conv - d).r;
		l.g = texture(signal_tex, uv - d).g;
		l.b = texture(signal_tex, uv - conv - d).b;
		r.r = texture(signal_tex, uv + conv + d).r;
		r.g = texture(signal_tex, uv + d).g;
		r.b = texture(signal_tex, uv - conv + d).b;
		c = c * 0.5 + (l + r) * 0.25;
	}
	return c;
}

vec3 lin(vec3 c) {
	return pow(c, vec3(crt_gamma));
}

void fragment() {
	// Glass to raster: overscan, bow, breathing (raster_scale) and power-off squeeze.
	vec2 p = (UV - 0.5) * 2.0;
	p /= max(squeeze, vec2(0.002));
	p /= raster_scale;
	if (tilt != 0.0) {
		// Aspect-correct rotation: the raster turns as a picture, not as uv.
		vec2 q = p * size;
		float cs = cos(tilt);
		float sn = sin(tilt);
		q = vec2(cs * q.x - sn * q.y, sn * q.x + cs * q.y);
		p = q / size;
	}
	float r2 = dot(p, p);
	vec2 pp = p * (1.0 + geometry * r2) * (1.0 - overscan);
	vec2 puv = pp * 0.5 + 0.5;
	vec2 e = smoothstep(vec2(0.0), vec2(edge_soft), puv) * smoothstep(vec2(0.0), vec2(edge_soft), 1.0 - puv);
	float inside = e.x * e.y;
	puv = clamp(puv, 0.0, 1.0);

	// Red lands outward, blue inward, up to `convergence` metres at |p| = 1.
	vec2 conv = p * (convergence / size);
	// Spot spread from brightness and corner defocus, in raster uv (720 samples across).
	float lum0 = texture(signal_tex, puv).g;
	float hblur = (bloom_spread * lum0 + focus_falloff * r2 * 0.5) * 1.2 / 720.0;

	// Sum the three nearest lines as area-normalised Gaussians so a flat field stays flat.
	float pitch = progressive == 1 ? 2.0 : 1.0;
	float ly = puv.y * lines;
	float n = floor(ly / pitch);
	float field = mod(floor(TIME * refresh), 2.0);
	float lpp = fwidth(ly);
	float sl = scanline * (1.0 - smoothstep(0.5, 1.3, lpp));
	vec3 base = lin(tap(puv, conv, hblur));
	if (progressive == 0) {
		base *= 1.0 - 0.5 * interlace_flicker;
	}
	vec3 col = base;
	if (sl > 0.001) {
		vec3 acc = vec3(0.0);
		float focus = 1.0 + focus_falloff * r2;
		for (int j = -1; j <= 1; j++) {
			float nj = n + float(j);
			float c = (nj + 0.5) * pitch;
			float on = step(0.0, c) * step(c, lines);
			vec3 sg = tap(vec2(puv.x, c / lines), conv, hblur);
			vec3 s = lin(sg);
			float lum = dot(sg, vec3(0.299, 0.587, 0.114));
			float w = mix(beam_min, beam_max, lum) * focus;
			float d = (ly - c) / pitch;
			float g = exp(-d * d / (2.0 * w * w)) / (w * 2.5066283);
			float lit = 1.0;
			if (progressive == 0) {
				lit = mod(nj, 2.0) == field ? 1.0 : 1.0 - interlace_flicker;
			}
			acc += s * g * lit * on;
		}
		col = mix(base, acc, sl);
	}

	// Halation: light scattering inside the glass around bright areas.
	if (halation > 0.0) {
		vec3 h = vec3(0.0);
		for (int i = 0; i < 8; i++) {
			float a = float(i) * 0.7853982;
			h += lin(texture(signal_tex, puv + vec2(cos(a), sin(a)) * halation_radius).rgb);
		}
		col += h * (halation / 8.0);
	}

	// Mask, in metres on the glass.
	float xm = (UV.x - 0.5) * size.x;
	float ym = (UV.y - 0.5) * size.y;
	if (mask_type > 0) {
		float tri = xm / mask_pitch;
		float ms = mask_strength * (1.0 - smoothstep(0.28, 0.65, fwidth(tri)));
		if (ms > 0.001) {
			float ph = fract(tri);
			vec3 m = vec3(step(ph, 1.0 / 3.0), step(1.0 / 3.0, ph) * step(ph, 2.0 / 3.0), step(2.0 / 3.0, ph));
			vec3 mask = mix(vec3(mask_dim), vec3(1.0), m);
			float avg = (1.0 + 2.0 * mask_dim) / 3.0;
			if (mask_type == 1) {
				float off = mod(floor(tri), 2.0) * 0.5;
				float sy = ym / (mask_pitch * slot_height) + off;
				float gap = smoothstep(0.0, 0.12, fract(sy)) * smoothstep(0.0, 0.12, 1.0 - fract(sy));
				mask *= mix(0.3, 1.0, gap);
				avg *= 0.9;
			}
			col *= mix(vec3(1.0), mask / avg, ms);
		}
	}
	for (int i = 1; i <= damper_wires; i++) {
		float yw = (float(i) / float(damper_wires + 1) - 0.5) * size.y;
		float dw = abs(ym - yw);
		float vis = 1.0 - smoothstep(0.3, 1.0, fwidth(ym) / 0.0002);
		col *= 1.0 - 0.7 * vis * (1.0 - smoothstep(0.0, 0.00022, dw));
	}

	// Purity: a magnetised mask mislands the beams in patches until degauss clears it.
	if (degauss > 0.001) {
		float a = (vnoise(UV * 3.0 + 7.0) - 0.5) * 0.9 * degauss;
		float b = (vnoise(UV * 2.0 + 21.0) - 0.5) * 0.6 * degauss;
		col *= vec3(1.0 + a, 1.0 - a * 0.8 + b * 0.3, 1.0 - b);
	}

	col *= 1.0 - corner * smoothstep(0.5, 1.4, r2);
	// The phosphors: their primaries and white point, in linear light.
	col = phosphor * col;
	col *= inside * brightness * energy;

	// Schlick glass, 4% at normal incidence, so only bright things in the room show.
	ALBEDO = glass_tint;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
	SPECULAR = 0.5;
	EMISSION = col;
}
