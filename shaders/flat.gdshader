shader_type spatial;
render_mode cull_back, depth_draw_opaque, unshaded;
// Interior material: flat comic fills. Shading is baked into vertex colours (walls darken
// toward the floor), so no light-falloff blobs survive the palette snap.

uniform sampler2D atlas : source_color, filter_nearest, hint_default_white;
uniform float atlas_cells = 4.0;

varying vec2 v_cell;

void vertex() {
	v_cell = UV2;
}

void fragment() {
	vec2 uv = (fract(UV) + v_cell) / atlas_cells;
	vec4 t = texture(atlas, uv);
	ALBEDO = COLOR.rgb * t.rgb;
	ALPHA = t.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
