// Thin window glass: Fresnel reflection plus the screen behind times the tint; too thin to refract.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, specular_schlick_ggx;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;

uniform vec3 tint : source_color = vec3(0.85, 0.92, 0.95);
// Soda-lime float glass.
uniform float ior : hint_range(1.0, 2.0) = 1.52;
// Polished glass. A little above zero so the sun's highlight has a size.
uniform float roughness : hint_range(0.0, 1.0) = 0.04;
// Light lost to the pane besides its tint (coatings, dirt, absorption).
uniform float transmission : hint_range(0.0, 1.0) = 0.92;

void fragment() {
	float f0 = pow((ior - 1.0) / (ior + 1.0), 2.0);
	float cos_theta = clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0);
	float fresnel = f0 + (1.0 - f0) * pow(1.0 - cos_theta, 5.0);

	vec3 behind = textureLod(screen_tex, SCREEN_UV, 0.0).rgb;

	ALBEDO = vec3(0.0);
	METALLIC = 0.0;
	ROUGHNESS = roughness;
	// Godot's SPECULAR 0.5 is F0 = 0.04; scale so F0 follows the IOR.
	SPECULAR = clamp(f0 / 0.08, 0.0, 1.0);
	EMISSION = behind * tint * transmission * (1.0 - fresnel);
	ALPHA = 1.0;
}
