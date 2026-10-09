// Recolours bodywork: mask from the base texture times UV2.x; UV2.y marks the roof.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D base_texture : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D orm_texture : filter_linear_mipmap_anisotropic;
// 0: red-dominant body; 1: light body with protected trim and a roof layer.
uniform int vehicle_kind = 0;
instance uniform vec4 body_color : source_color = vec4(0.14, 0.36, 0.60, 1.0);
instance uniform vec4 roof_color : source_color = vec4(0.84, 0.78, 0.65, 1.0);
// 0 keeps the delivered livery, 1 is a full repaint.
instance uniform float recolor_amount = 0.0;
// Debug view: above 0.5 shows the paint (green) and roof (purple) mask.
instance uniform float show_mask = 0.0;


void fragment() {
	vec3 base = texture(base_texture, UV).rgb;
	vec3 orm = texture(orm_texture, UV).rgb;
	float hi = max(base.r, max(base.g, base.b));
	float lo = min(base.r, min(base.g, base.b));
	float paint;
	if (vehicle_kind == 0) {
		paint = smoothstep(0.07, 0.20, (base.r - max(base.g, base.b)) / max(hi, 0.001));
	} else {
		paint = smoothstep(0.105, 0.22, lo)
				* (1.0 - smoothstep(0.27, 0.43, (hi - lo) / max(hi, 0.001)));
	}
	paint *= clamp(UV2.x, 0.0, 1.0);
	float roof = vehicle_kind == 0 ? 0.0 : clamp(UV2.y, 0.0, 1.0);
	vec3 tint = mix(body_color.rgb, roof_color.rgb, roof);
	float detail = clamp(hi / (vehicle_kind == 0 ? 0.55 : 0.78), 0.04, 1.3);
	ALBEDO = mix(base, tint * detail, paint * recolor_amount);
	METALLIC = orm.b;
	ROUGHNESS = orm.g;
	NORMAL_MAP = texture(normal_texture, UV).rgb;
	if (show_mask > 0.5) {
		vec3 mask_color = mix(vec3(0.08, 0.85, 0.30), vec3(0.75, 0.18, 0.85), roof);
		ALBEDO = mix(vec3(0.06), mask_color, paint);
		EMISSION = ALBEDO * 0.25;
		METALLIC = 0.0;
		ROUGHNESS = 1.0;
	}
}
