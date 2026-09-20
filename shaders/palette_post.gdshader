shader_type canvas_item;
// Palette post-process: every pixel of the low-res 3D view snaps to the nearest game
// palette colour (perceptually weighted), with optional ordered dithering for texture.
// Sprites are already in-palette, so they pass through unchanged.

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;
uniform float dither_strength : hint_range(0.0, 0.25) = 0.06;
uniform float enabled = 1.0;

const int N = 21;
const vec3 PALETTE[21] = vec3[](
	vec3(0.0706, 0.0392, 0.1216),
	vec3(0.1765, 0.1059, 0.3059),
	vec3(0.3569, 0.1647, 0.5255),
	vec3(0.5569, 0.2667, 0.6784),
	vec3(0.7647, 0.6078, 0.8275),
	vec3(0.9922, 0.9647, 0.8902),
	vec3(0.0588, 0.4627, 0.4314),
	vec3(0.0784, 0.7216, 0.6510),
	vec3(0.6000, 0.9647, 0.8941),
	vec3(0.2118, 0.3255, 0.0784),
	vec3(0.5176, 0.8000, 0.0863),
	vec3(0.8510, 0.9765, 0.6157),
	vec3(0.4863, 0.1765, 0.0706),
	vec3(0.9176, 0.3451, 0.0471),
	vec3(0.9922, 0.7294, 0.4549),
	vec3(0.2000, 0.2549, 0.3333),
	vec3(0.5804, 0.6392, 0.7216),
	vec3(0.7451, 0.0706, 0.2353),
	vec3(1.0000, 0.1765, 0.3333),
	vec3(1.0000, 0.4353, 0.7098),
	vec3(0.9804, 0.8000, 0.0824)
);

float bayer4(vec2 p) {
	int x = int(mod(p.x, 4.0));
	int y = int(mod(p.y, 4.0));
	int idx = x + y * 4;
	int m[16] = int[](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
	return (float(m[idx]) + 0.5) / 16.0 - 0.5;
}

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	if (enabled < 0.5) {
		COLOR = vec4(c, 1.0);
	} else {
		c += bayer4(FRAGCOORD.xy) * dither_strength;
		vec3 w = vec3(0.30, 0.59, 0.11) * 2.0 + 0.5;  // luma-weighted distance
		vec3 best = PALETTE[0];
		float bd = 1e9;
		for (int i = 0; i < N; i++) {
			vec3 d = (c - PALETTE[i]);
			float dist = dot(d * d, w);
			if (dist < bd) { bd = dist; best = PALETTE[i]; }
		}
		COLOR = vec4(best, 1.0);
	}
}
