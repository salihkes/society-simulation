// Procedural asphalt for the junction preview; grain fades out where it would alias.
shader_type spatial;
render_mode cull_disabled;

void fragment() {
	vec2 p = UV;
	float grain = fract(sin(dot(floor(p * 35.0), vec2(127.1,311.7))) * 43758.5453);
	float coarse = sin(p.x * 0.53 + sin(p.y * 0.019)) * sin(p.y * 0.097);
	float fade = 1.0-smoothstep(0.015,0.15,max(fwidth(p.x),fwidth(p.y)));
	float wheels = exp(-pow((mod(p.x+3.5,12.5)-3.0)/1.0,2.0)) + exp(-pow((mod(p.x+3.5,12.5)-9.0)/1.0,2.0));
	ALBEDO = vec3(0.12,0.125,0.13) + coarse * 0.009 + (grain-0.5)*0.05*fade - wheels*0.009;
	ROUGHNESS = 0.96;
}
