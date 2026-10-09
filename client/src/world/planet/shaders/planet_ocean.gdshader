// Planet ocean shell: sphere-normal waves, depth-buffer water colour, shore and crest foam.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 shallow_color : source_color = vec4(0.22, 0.65, 0.72, 0.55);
uniform vec4 deep_color : source_color = vec4(0.03, 0.22, 0.42, 0.92);
uniform float depth_fade = 12.0;
uniform vec4 foam_color : source_color = vec4(1.0, 1.0, 1.0, 0.9);
uniform float foam_depth = 1.4;
uniform float wave_amplitude = 0.25;
uniform float wave_frequency = 0.35;
uniform float wave_speed = 1.2;
uniform float roughness_v : hint_range(0.0, 1.0) = 0.08;

uniform sampler2D depth_texture : hint_depth_texture, filter_linear;

varying vec3 v_pos;

float wave_h(vec3 p, float t) {
	return sin(p.x * wave_frequency + t * wave_speed)
	     + sin(p.z * wave_frequency * 0.83 + t * wave_speed * 1.31)
	     + sin((p.x + p.y) * wave_frequency * 0.61 + t * wave_speed * 0.77);
}

void vertex() {
	v_pos = VERTEX;
	vec3 up = normalize(VERTEX);
	VERTEX += up * wave_h(VERTEX, TIME) * wave_amplitude * 0.33;
}

void fragment() {
	float scene_depth_raw = texture(depth_texture, SCREEN_UV).r;
	vec4 view_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene_depth_raw, 1.0);
	view_pos.xyz /= view_pos.w;
	float water_col = length(view_pos.xyz) - length(VERTEX);
	water_col = max(water_col, 0.0);

	float depth_t = clamp(water_col / depth_fade, 0.0, 1.0);
	vec4 col = mix(shallow_color, deep_color, depth_t);

	float crest = smoothstep(2.1, 2.9, wave_h(v_pos, TIME));
	float foam = 1.0 - smoothstep(0.0, foam_depth, water_col);
	foam = max(foam * 0.9, crest * 0.25);
	col = mix(col, foam_color, foam);

	vec3 nrm = normalize(mat3(VIEW_MATRIX) * normalize(v_pos));
	float fresnel = pow(1.0 - clamp(dot(nrm, -normalize(VERTEX)), 0.0, 1.0), 3.0);

	ALBEDO = col.rgb;
	ALPHA = clamp(col.a + fresnel * 0.25, 0.0, 1.0);
	METALLIC = 0.1;
	ROUGHNESS = roughness_v;
	SPECULAR = 0.6;
}
