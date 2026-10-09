shader_type spatial;

// Box-humanoid face drawn in the skin atlas face square, as a material_overlay that survives skin swaps.

const vec2 FACE_ORIGIN = vec2(0.875, 0.0);
const vec2 ATLAS_PX = vec2(1024.0, 512.0);
// The cheek pixel (23, 45) lies outside this region, so the other head faces discard.
const vec2 REGION_MIN = vec2(27.0, 6.0);
const vec2 REGION_MAX = vec2(101.0, 122.0);

// Layout measured from the painted default face.
const float CENTER_X = 63.5;
const float EYE_Y = 39.0;
const float EYE_DX = 10.75;
const vec2 EYE_RADIUS = vec2(3.0, 7.0);
const float BROW_Y = 25.0;
const float BROW_HALF_LEN = 6.0;
const float BROW_STROKE = 3.5;
const float MOUTH_Y = 76.5;
const float MOUTH_HALF_W = 19.5;
const float MOUTH_SAG = 16.0;   // sagitta of the arc at mouth_curve = 1
const float STROKE = 5.0;
const vec3 INK = vec3(0.02);

uniform vec4 skin_color : source_color = vec4(0.992, 0.918, 0.553, 1.0);
uniform float eye_open : hint_range(0.0, 1.0) = 1.0;
uniform float eye_size : hint_range(0.3, 2.0) = 1.0;
uniform vec2 eye_look = vec2(0.0, 0.0);
uniform float brow_show : hint_range(0.0, 1.0) = 0.0;
uniform float brow_angle : hint_range(-1.0, 1.0) = 0.0;  // + inner end down (angry), - inner end up (sad, afraid)
uniform float brow_lift : hint_range(-1.0, 1.0) = 0.0;
uniform float mouth_curve : hint_range(-1.5, 1.5) = 1.0;  // + smile, - frown, 0 straight
uniform float mouth_width : hint_range(0.2, 1.6) = 1.0;
uniform float mouth_open : hint_range(0.0, 1.0) = 0.0;

float sd_ellipse(vec2 p, vec2 c, vec2 r) {
	vec2 q = (p - c) / r;
	return (length(q) - 1.0) * min(r.x, r.y);
}

float sd_segment(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h);
}

// Arc through (-hw, 0), (0, s) and (hw, 0), at most a semicircle, with round caps.
float sd_arc(vec2 p, float hw, float s) {
	if (abs(s) < 0.25) {
		return sd_segment(p, vec2(-hw, 0.0), vec2(hw, 0.0));
	}
	float r = (hw * hw + s * s) / (2.0 * abs(s));
	vec2 c = vec2(0.0, s - sign(s) * r);
	if (sign(s) * p.y >= 0.0) {
		return abs(length(p - c) - r);
	}
	return min(length(p - vec2(-hw, 0.0)), length(p - vec2(hw, 0.0)));
}

float fill(float d, float aa) {
	return 1.0 - smoothstep(-aa, aa, d);
}

float face_ink(vec2 p) {
	float aa = length(fwidth(p)) * 0.7 + 1e-4;
	float ink = 0.0;

	// A blink squashes the eyes down to a thin line.
	vec2 er = EYE_RADIUS * eye_size;
	er.y *= max(eye_open, 0.1);
	vec2 look = eye_look * 3.0;
	for (int i = 0; i < 2; i++) {
		float side = (i == 0) ? -1.0 : 1.0;
		vec2 eye = vec2(CENTER_X + side * EYE_DX, EYE_Y);
		ink = max(ink, fill(sd_ellipse(p, eye + look, er), aa));

		if (brow_show > 0.001) {
			float y = BROW_Y - brow_lift * 6.0 - (eye_size - 1.0) * 6.0;
			vec2 mid = vec2(eye.x, y);
			float tilt = brow_angle * 4.0;
			vec2 outer = mid + vec2(side * BROW_HALF_LEN, -tilt);
			vec2 inner = mid + vec2(-side * BROW_HALF_LEN, tilt);
			float d = sd_segment(p, outer, inner) - BROW_STROKE * 0.5;
			ink = max(ink, fill(d, aa) * brow_show);
		}
	}

	vec2 mp = p - vec2(CENTER_X, MOUTH_Y);
	float hw = MOUTH_HALF_W * mouth_width;
	float sag = MOUTH_SAG * mouth_curve * mouth_width;
	// A wide-open straight mouth is an O, so its lip line fades out.
	float lip = 1.0 - mouth_open * (1.0 - clamp(abs(mouth_curve) * 2.0, 0.0, 1.0));
	ink = max(ink, fill(sd_arc(mp, hw, sag) - STROKE * 0.5, aa) * lip);

	if (mouth_open > 0.001) {
		float half_h = 3.0 + 10.0 * mouth_open;
		vec2 oc = vec2(0.0, sag * 0.55 + half_h * 0.3);
		vec2 orad = vec2(max(hw * 0.7, 5.0), half_h);
		ink = max(ink, fill(sd_ellipse(mp, oc, orad), aa));
	}
	return ink;
}

void fragment() {
	vec2 p = (UV - FACE_ORIGIN) * ATLAS_PX;
	if (any(lessThan(p, REGION_MIN)) || any(greaterThan(p, REGION_MAX))) {
		discard;
	}
	ALBEDO = mix(skin_color.rgb, INK, face_ink(p));
}
