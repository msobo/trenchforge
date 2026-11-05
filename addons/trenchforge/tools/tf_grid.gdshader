shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, blend_mix;

// 0 = plane normal along X, 1 = Y, 2 = Z.
uniform int axis = 1;
uniform float grid_size = 1.0;
uniform int major_every = 8;
uniform vec3 center = vec3(0.0);
uniform float fade_radius = 24.0;
uniform vec4 minor_color : source_color = vec4(1.0, 1.0, 1.0, 0.18);
uniform vec4 major_color : source_color = vec4(1.0, 1.0, 1.0, 0.4);

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float grid_line(vec2 coord, float size) {
	vec2 c = coord / size;
	vec2 d = fwidth(c);
	vec2 g = abs(fract(c - 0.5) - 0.5) / max(d, vec2(1e-5));
	return 1.0 - min(min(g.x, g.y), 1.0);
}

void fragment() {
	vec2 coord = axis == 0 ? world_pos.yz : (axis == 1 ? world_pos.xz : world_pos.xy);
	float minor = grid_line(coord, grid_size);
	float major = grid_line(coord, grid_size * float(major_every));
	float fade = 1.0 - smoothstep(fade_radius * 0.5, fade_radius, distance(world_pos, center));
	vec4 color = mix(minor_color * minor, major_color, major);
	ALBEDO = color.rgb;
	ALPHA = max(minor * minor_color.a, major * major_color.a) * fade;
}
