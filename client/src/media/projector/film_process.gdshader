// Worn 16mm newsreel look over the projector SubViewport; the SpotLight3D projects the result.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;

uniform vec3 tint_dark : source_color = vec3(0.02, 0.06, 0.06);
uniform vec3 tint_light : source_color = vec3(0.78, 0.92, 0.82);
uniform float contrast = 1.4;
uniform float lift = 0.04;          // faded print: blacks never reach zero
uniform float grain_amount = 0.16;
uniform float weave_amount = 0.006; // gate weave, in UV units
uniform float flicker = 1.0;        // fed per frame by film_projector.gd
uniform float vignette = 0.55;
uniform float edge_softness = 0.035;
uniform float scratch_amount = 0.5;
uniform float dust_amount = 0.6;
uniform float fps = 24.0;
uniform float softness = 0.5;       // mip bias: a print is never pin sharp
// Only the texture's inscribed circle reaches the wall, so a 4:3 picture spans 80% x 60%.
uniform vec2 pic_min = vec2(0.1, 0.2);
uniform vec2 pic_max = vec2(0.9, 0.8);

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float noise1(float t) {
	float i = floor(t);
	float f = fract(t);
	f = f * f * (3.0 - 2.0 * f);
	return mix(hash12(vec2(i, 7.0)), hash12(vec2(i + 1.0, 7.0)), f);
}

void fragment() {
	// Quantize time to the frame rate so grain and weave step like film does.
	float frame = floor(TIME * fps);
	float ft = frame / fps;

	// Gate weave: the whole frame drifts a little, mostly vertically.
	vec2 weave = vec2(noise1(ft * 3.1) - 0.5, noise1(ft * 2.3 + 11.0) - 0.5) * weave_amount * vec2(0.6, 1.0);
	vec2 puv = (UV - pic_min) / (pic_max - pic_min);
	float inside = step(0.0, puv.x) * step(0.0, puv.y) * step(puv.x, 1.0) * step(puv.y, 1.0);
	puv = clamp(puv, 0.0, 1.0);
	vec2 uv = puv + weave;

	vec3 src = textureLod(screen_tex, mix(pic_min, pic_max, uv), softness).rgb;

	// Monochrome, contrast around mid grey, lifted blacks.
	float lum = dot(src, vec3(0.299, 0.587, 0.114));
	lum = clamp((lum - 0.5) * contrast + 0.5, 0.0, 1.0);
	lum = lift + lum * (1.0 - lift);

	// Grain: per pixel, per frame, stronger in the mids.
	float g = hash12(FRAGCOORD.xy + vec2(frame * 17.0, frame * 3.0)) - 0.5;
	lum += g * grain_amount * (0.35 + 0.65 * (1.0 - abs(lum - 0.5) * 2.0));

	// Scratches: a few vertical lines that live for a handful of frames.
	float sx = hash12(vec2(floor(frame / 6.0), 3.0));
	float scratch = smoothstep(0.0015, 0.0, abs(uv.x - sx)) * step(hash12(vec2(floor(frame / 6.0), 9.0)), scratch_amount);
	lum += scratch * 0.35;

	// Dust: sparse dark specks that appear for a single frame.
	vec2 cell = floor(uv * 60.0);
	float d = hash12(cell + vec2(frame, frame * 0.7));
	float dust = step(1.0 - 0.004 * dust_amount, d) * smoothstep(0.5, 0.2, length(fract(uv * 60.0) - 0.5));
	lum -= dust * 0.6;

	// Frame edge and vignette: the gate is slightly rounded and the lens falls off.
	vec2 c = uv - 0.5;
	float r = length(c * vec2(1.0, 1.15));
	float vig = 1.0 - vignette * smoothstep(0.35, 0.75, r);
	vec2 edge = smoothstep(vec2(0.0), vec2(edge_softness), uv) * smoothstep(vec2(0.0), vec2(edge_softness), 1.0 - uv);
	float gate = edge.x * edge.y;

	lum = clamp(lum, 0.0, 1.0) * vig * gate * flicker;
	COLOR = vec4(mix(tint_dark, tint_light, lum) * inside, 1.0);
}
