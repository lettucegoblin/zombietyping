shader_type spatial;
render_mode cull_back, depth_draw_opaque, specular_disabled;
// Cel-shaded world material: vertex colour x atlas texture, light quantized into bands.
// UV tiles in metres; UV2 selects the atlas cell (0,0 = plain white => vertex colour only).
// Anti-repetition: each tile repeat gets a random flip keyed by its world tile, and a
// low-frequency value-noise mask darkens patches (weathering). After the palette snap the
// patches read as discrete stains rather than a visible grid.

uniform sampler2D atlas : source_color, filter_nearest, hint_default_white;
uniform float atlas_cells = 4.0;
uniform float band_hi = 0.55;
uniform float band_lo = 0.18;
uniform float mid_level = 0.55;
uniform float grime_amount : hint_range(0.0, 1.0) = 0.16;
uniform float grime_scale = 0.22;

varying vec2 v_cell;
varying vec3 v_world;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	v_cell = UV2;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	bool tiling = (v_cell.y < 1.5) && !(v_cell.x < 0.5 && v_cell.y < 0.5);   // rows 0-1 minus plain
	vec2 f = fract(UV);
	if (tiling) {
		float h = hash21(floor(UV) + v_cell * 7.0);
		if (h < 0.25) { f.x = 1.0 - f.x; }
		else if (h < 0.5) { f.y = 1.0 - f.y; }
		else if (h < 0.75) { f = 1.0 - f; }
	}
	vec2 uv = (f + v_cell) / atlas_cells;
	vec4 t = texture(atlas, uv);
	vec3 col = COLOR.rgb * t.rgb;
	if (tiling) {
		float n = vnoise(v_world.xz * grime_scale + v_world.y * 0.31);
		float n2 = vnoise(v_world.xz * grime_scale * 3.1 + 7.7 + v_world.y * 0.9);
		float g = smoothstep(0.55, 0.75, n * 0.7 + n2 * 0.3);
		col *= 1.0 - g * grime_amount;
	}
	ALBEDO = col;
	ALPHA = t.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

void light() {
	float lit = clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION;
	float s = lit > band_hi ? 1.0 : (lit > band_lo ? mid_level : 0.0);
	DIFFUSE_LIGHT += s * LIGHT_COLOR / PI;
}
