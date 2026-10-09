// Fake projector light shafts on a cone mesh; the only beam on web and Quest.
shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec3 color : source_color = vec3(0.55, 0.85, 0.9);
uniform float intensity = 0.35;
uniform float streaks = 28.0;
uniform float streak_contrast = 2.2;
uniform float drift = 0.05;
uniform float flicker = 1.0;

float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	return fract(p * p * 2.0);
}

float vnoise(float x) {
	float i = floor(x);
	float f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(hash11(i), hash11(i + 1.0), f);
}

varying float v_axis;
varying float v_angle;

void vertex() {
	// CylinderMesh v runs along the height; the node is rotated so the lens is at v = 0.
	v_axis = UV.y;
	v_angle = UV.x;
}

void fragment() {
	float a = v_angle * streaks + TIME * drift;
	float s = vnoise(a) * 0.6 + vnoise(a * 2.7 + 5.0) * 0.4;
	s = pow(s, streak_contrast);
	float along = pow(1.0 - v_axis, 1.6);
	// Softer near the very tip so the cone does not read as a hard shape.
	float tip = smoothstep(0.0, 0.08, v_axis);
	float rim = abs(dot(normalize(NORMAL), normalize(VIEW)));
	rim = smoothstep(0.0, 0.45, rim);
	float alpha = s * along * tip * rim * intensity * flicker;
	ALBEDO = color * alpha;
	ALPHA = 1.0;
}
