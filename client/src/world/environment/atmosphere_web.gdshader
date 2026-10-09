// Planet atmosphere for the web renderer: ray-casts the planet and writes DEPTH, no depth texture.
// Derived from atmosphere_fbcosentino.gdshader by Fernando Cosentino (MIT).
shader_type spatial;
render_mode blend_mix, depth_draw_never, unshaded;

uniform sampler2D height_profile_curve: source_color, filter_linear, repeat_disable;
uniform sampler2D height_profile_main_colors: source_color, filter_linear, repeat_disable;
uniform sampler2D height_profile_back_colors: source_color, filter_linear, repeat_disable;

uniform sampler2D direction_profile_curve: source_color, filter_linear, repeat_disable;
uniform sampler2D direction_profile_main_colors: source_color, filter_linear, repeat_disable;
uniform sampler2D direction_profile_back_colors: source_color, filter_linear, repeat_disable;

uniform sampler2D water_depth_profile_colors: source_color, filter_linear, repeat_disable;

uniform float sea_level = 100.0;
uniform float atmosphere_radius = 120.0;
uniform float atmosphere_density = 0.2;
uniform float water_density_factor = 0.0;


// Ray against the origin-centred sphere: (t_enter, t_exit), or vec2(-1) on a miss.
vec2 ray_sphere_intersect(vec3 start, vec3 dir, float max_dist, float radius) {
	float a = dot(dir, dir);
	float b = 2.0 * dot(dir, start);
	float c = dot(start, start) - (radius * radius);
	float d = (b * b) - 4.0 * a * c;

	if (d < 0.0) return vec2(-1.0);

	vec2 ray_length = vec2(
		max((-b - sqrt(d)) / (2.0 * a), 0.0),
		min((-b + sqrt(d)) / (2.0 * a), max_dist)
	);

	return ray_length;
}

// Distance from the origin to the ray's closest point ahead of ro.
float get_average_height(vec3 ro, vec3 rd) {
	float t = (dot(-ro, rd));
	if (t < 0.0) {
		return length(ro);
	}
	vec3 P = ro + rd * t;
	return length(P);
}


varying vec3 cam_position;
varying vec3 light_direction;

void vertex() {
	cam_position = MODELVIEW_MATRIX[3].xyz;
	light_direction = -normalize(MODELVIEW_MATRIX[2].xyz);
}

void fragment() {
	DEPTH = FRAGCOORD.z;

	// The ray stops at the planet; closest approach also covers a camera on the surface.
	float far_limit = atmosphere_radius * 3.0 + length(cam_position);

	float t_closest = -dot(cam_position, VIEW) / dot(VIEW, VIEW);
	float max_distance;

	if (t_closest > 0.0) {
		float r_min = length(cam_position + VIEW * t_closest);
		if (r_min < sea_level) {
			vec2 planet_hit = ray_sphere_intersect(cam_position, VIEW, far_limit, sea_level);
			if (planet_hit.x > 0.001) {
				max_distance = planet_hit.x;
			} else {
				// Camera on or inside the planet, heading inward.
				max_distance = 0.0;
			}
		} else {
			max_distance = far_limit;
		}
	} else {
		max_distance = far_limit;
	}

	vec2 atmo_sphere_intersect = ray_sphere_intersect(cam_position, VIEW, max_distance, atmosphere_radius);
	if ((atmo_sphere_intersect.x < 0.0) || (atmo_sphere_intersect.y < 0.0)) {
		discard;
	}
	float ray_length = atmo_sphere_intersect.y - atmo_sphere_intersect.x;

	vec3 atmo_normal = normalize(cam_position + VIEW * max(0.0, min(atmo_sphere_intersect.y, atmo_sphere_intersect.x)));
	float atmo_normal_dot = dot(atmo_normal, light_direction);
	float atmo_normal_side_dot = clamp(dot(VIEW, light_direction), 0.0, 1.0);
	float back_looking_fac = clamp(-atmo_normal_dot * atmo_normal_side_dot * 2.0, 0.0, 1.0);

	float atmo_height = (atmosphere_radius - sea_level);
	float height_avg = get_average_height(cam_position, VIEW);
	float height_above_surface = clamp((height_avg - sea_level) / atmo_height, 0.0, 1.0);
	vec2 height_uv = vec2(height_above_surface, 0.0);
	float height_fac = texture(height_profile_curve, height_uv).r;
	vec4 height_color = mix(
		texture(height_profile_main_colors, height_uv),
		texture(height_profile_back_colors, height_uv),
		back_looking_fac
	);

	vec2 direction_uv = vec2(atmo_normal_dot * 0.5 + 0.5, 0.0);
	float direction_fac = texture(direction_profile_curve, direction_uv).r;
	vec4 direction_color = mix(
		texture(direction_profile_main_colors, direction_uv),
		texture(direction_profile_back_colors, direction_uv),
		back_looking_fac
	);
	float light_dir_factor = clamp(direction_fac, 0.0, 1.0);

	ALBEDO = height_color.rgb * direction_color.rgb;
	ALPHA = clamp(
		(ray_length / sea_level) * height_fac * light_dir_factor * atmosphere_density * height_color.a * direction_color.a,
		0.0, 1.0);

	if (water_density_factor > 0.0) {
		vec2 water_sphere_intersect = ray_sphere_intersect(cam_position, VIEW, max_distance, sea_level);

		if ((water_sphere_intersect.x >= 0.0) && (water_sphere_intersect.y >= 0.0)) {
			float water_ray_length = water_sphere_intersect.y - water_sphere_intersect.x;
			float water_ray_length_fac = clamp(abs(water_ray_length * water_density_factor), 0.0, 1.0);
			vec2 depth_uv = vec2(water_ray_length_fac, 0.0);
			vec4 depth_color = texture(water_depth_profile_colors, depth_uv);
			ALBEDO *= depth_color.rgb;
			ALPHA = max(0.0, water_ray_length_fac * depth_color.a);
		}
	}

	// Depth at the midpoint of the atmosphere segment: nearer objects hide it.
	float t_atmo_mid = (atmo_sphere_intersect.x + atmo_sphere_intersect.y) * 0.5;
	vec3  atmo_view_pos = cam_position + VIEW * t_atmo_mid;
	vec4  atmo_clip = PROJECTION_MATRIX * vec4(atmo_view_pos, 1.0);
	DEPTH = atmo_clip.z / atmo_clip.w;
}
