// Cable and decoder: encodes `source_tex` as RGB, S-Video, composite, RF or tape and decodes it, a sample per pixel.
shader_type canvas_item;

uniform sampler2D source_tex : filter_linear, repeat_disable;
uniform vec2 src_offset = vec2(0.0);   // where the source sits in the raster
uniform vec2 src_scale = vec2(1.0);

// Set by crt_tv.gd from CRTPreset.standard.
uniform float cycles_per_line = 188.3; // subcarrier cycles across the active line
uniform float line_phase = 3.14159265; // subcarrier phase step per line
uniform float frame_phase = 3.14159265; // per frame
uniform float frame_rate = 29.97;
uniform int pal = 0;                   // 1: U/V axes and PAL matrix
uniform vec2 samples = vec2(720.0, 480.0);

// Cable: 0 RGB, 1 S-Video, 2 composite, 3 RF, 4 tape
uniform int cable = 2;
uniform float luma_cut = 0.21;   // cycles per sample; subcarrier is at 1/spc
uniform float i_cut = 0.04;
uniform float q_cut = 0.04;
uniform float rgb_cut = 0.38;
uniform float comb = 0.0;        // 0 notch, 1 three-line comb
uniform int prefilter = 1;       // band-limit the source before encoding
uniform float noise = 0.0;
uniform float ghost = 0.0;
uniform float ghost_delay = 9.0; // samples
uniform float tape_wear = 0.3;
uniform float signal_present = 1.0;

uniform float peaking = 0.0;
uniform float saturation = 1.0;
uniform float contrast = 1.0;
uniform float black_lift = 0.0;
uniform vec3 white_point : source_color = vec3(1.0);

const int TAPS = 12;
const float PI2 = 6.28318530718;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float sinc(float x) {
	return abs(x) < 1e-4 ? 1.0 : sin(PI * x) / (PI * x);
}

// Windowed sinc tap k for a low-pass at fc cycles per sample.
float lp(int k, float fc) {
	float kf = float(k);
	return 2.0 * fc * sinc(2.0 * fc * kf) * (0.5 + 0.5 * cos(PI * kf / float(TAPS + 1)));
}

vec3 fetch1(float sx, float ly) {
	vec2 uv = ((vec2(sx, ly) + 0.5) / samples - src_offset) / src_scale;
	float inside = step(0.0, uv.x) * step(0.0, uv.y) * step(uv.x, 1.0) * step(uv.y, 1.0);
	return texture(source_tex, uv).rgb * inside;
}

// With prefilter, a two-tap box limits the source as a camera chain or VTR would.
vec3 fetch(float sx, float ly) {
	if (prefilter == 1) {
		return 0.5 * (fetch1(sx - 0.5, ly) + fetch1(sx + 0.5, ly));
	}
	return fetch1(sx, ly);
}

float luma(vec3 c) {
	return dot(c, vec3(0.299, 0.587, 0.114));
}

vec2 chroma(vec3 c, float y) {
	if (pal == 1) {
		return vec2(0.492 * (c.b - y), 0.877 * (c.r - y));
	}
	return vec2(0.596 * c.r - 0.274 * c.g - 0.322 * c.b, 0.211 * c.r - 0.523 * c.g + 0.312 * c.b);
}

vec3 to_rgb(float y, vec2 c) {
	if (pal == 1) {
		return vec3(y + 1.140 * c.y, y - 0.395 * c.x - 0.581 * c.y, y + 2.032 * c.x);
	}
	return vec3(y + 0.956 * c.x + 0.621 * c.y, y - 0.272 * c.x - 0.647 * c.y, y - 1.106 * c.x + 1.703 * c.y);
}

// Luma in .x, modulated chroma in .y.
vec2 encode(float sx, float ly, float ph0, float spc, float frame, float namp, float dropout) {
	vec3 c = signal_present > 0.5 ? fetch(sx, ly) : vec3(0.0);
	float y = luma(c);
	vec2 cq = chroma(c, y);
	float ph = PI2 * sx / spc + ph0;
	float mod_c = cq.x * cos(ph) + cq.y * sin(ph);
	float n = (hash12(vec2(sx, ly + frame * samples.y)) - 0.5) * namp;
	y = mix(y, 0.95, dropout);
	return vec2(y + n, mod_c * (1.0 - dropout) + n * 0.7);
}

void fragment() {
	float sx = floor(SCREEN_UV.x * samples.x);
	float ly = floor(SCREEN_UV.y * samples.y);
	float frame = floor(TIME * frame_rate);
	float spc = samples.x / cycles_per_line;
	float ph0 = ly * line_phase + frame * frame_phase;
	float namp = signal_present > 0.5 ? noise * (cable == 3 ? 1.5 : 1.0) : 0.8;
	float lc = luma_cut;
	float ic = i_cut;
	float qc = q_cut;
	float dropout = 0.0;

	if (cable == 4 && signal_present > 0.5) {
		// VHS: band-limited luma, colour-under chroma, noise, jitter, hue wobble, dropouts, head-switching tear.
		lc = min(lc, 0.19);
		ic = min(ic, 0.035);
		qc = min(qc, 0.035);
		namp += 0.05 * tape_wear;
		float lh = hash12(vec2(ly, frame));
		sx += (lh - 0.5) * 2.0 * tape_wear;
		ph0 += (hash12(vec2(ly * 3.1, frame)) - 0.5) * 0.4 * tape_wear;
		float tear = smoothstep(samples.y - 9.0, samples.y - 6.0, ly);
		sx += tear * 14.0 * tape_wear * (hash12(vec2(frame, 5.0)) - 0.3);
		namp += tear * 0.5;
		if (hash12(vec2(ly, frame * 7.0)) < 0.004 * tape_wear) {
			float x0 = hash12(vec2(ly * 7.0, frame)) * samples.x;
			float len = 20.0 + 80.0 * hash12(vec2(ly, frame * 3.0));
			dropout = step(x0, sx) * step(sx, x0 + len);
		}
	}

	float y = 0.0;
	float soft = 0.0;
	vec2 cq = vec2(0.0);
	vec3 rgb = vec3(0.0);

	if (cable == 0) {
		vec3 acc = vec3(0.0);
		float wsum = 0.0;
		float ssum = 0.0;
		float swsum = 0.0;
		for (int k = -TAPS; k <= TAPS; k++) {
			vec3 c = signal_present > 0.5 ? fetch(sx + float(k), ly) : vec3(hash12(vec2(sx + float(k), ly + frame * samples.y)) * 0.8);
			float w = lp(k, rgb_cut);
			acc += w * c;
			wsum += w;
			float ws = lp(k, 0.08);
			ssum += ws * luma(c);
			swsum += ws;
		}
		rgb = acc / wsum;
		y = luma(rgb);
		soft = ssum / swsum;
	} else {
		float ysum = 0.0;
		float ywsum = 0.0;
		float ssum = 0.0;
		float swsum = 0.0;
		float isum = 0.0;
		float iwsum = 0.0;
		float qsum = 0.0;
		float qwsum = 0.0;
		for (int k = -TAPS; k <= TAPS; k++) {
			float x = sx + float(k);
			float ph = PI2 * x / spc + ph0;
			vec2 e = encode(x, ly, ph0, spc, frame, namp, dropout);
			if (ghost > 0.0) {
				e += encode(x - ghost_delay, ly, ph0, spc, frame, namp, 0.0) * ghost;
			}
			float lum_in;
			float chr_in;
			if (cable == 1) {
				lum_in = e.x;
				chr_in = e.y;
			} else {
				float s = e.x + e.y;
				lum_in = s;
				chr_in = s;
				if (comb > 0.0) {
					// NTSC chroma inverts line to line, so the weighted sum is luma and the difference chroma.
					vec2 e1 = encode(x, ly - 1.0, ph0 - line_phase, spc, frame, namp, 0.0);
					vec2 e2 = encode(x, ly + 1.0, ph0 + line_phase, spc, frame, namp, 0.0);
					float s1 = e1.x + e1.y;
					float s2 = e2.x + e2.y;
					lum_in = mix(s, 0.5 * s + 0.25 * (s1 + s2), comb);
					chr_in = mix(s, 0.5 * s - 0.25 * (s1 + s2), comb);
				}
			}
			float wy = lp(k, lc);
			ysum += wy * lum_in;
			ywsum += wy;
			float ws = lp(k, 0.08);
			ssum += ws * lum_in;
			swsum += ws;
			float wi = lp(k, ic);
			isum += wi * chr_in * cos(ph) * 2.0;
			iwsum += wi;
			float wq = lp(k, qc);
			qsum += wq * chr_in * sin(ph) * 2.0;
			qwsum += wq;
		}
		y = ysum / ywsum;
		soft = ssum / swsum;
		cq = vec2(isum / iwsum, qsum / qwsum);
	}

	float ring = peaking * (y - soft);
	y += ring;
	y = (y - 0.5) * contrast + 0.5;
	y = y * (1.0 - black_lift) + black_lift;
	cq *= saturation;
	if (cable == 0) {
		rgb = (rgb - 0.5) * contrast + 0.5;
		rgb = rgb * (1.0 - black_lift) + black_lift + ring;
	} else {
		rgb = to_rgb(y, cq);
	}
	COLOR = vec4(clamp(rgb * white_point, 0.0, 1.0), 1.0);
}
