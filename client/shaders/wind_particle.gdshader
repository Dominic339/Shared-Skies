shader_type spatial;
render_mode blend_add, cull_disabled, unshaded, depth_draw_never, shadows_disabled, billboard;

// Soft round wisp for the ambient wind-swirl effect around Landmark signs
// (see WindSwirl.tscn) -- a plain QuadMesh drawn with a radial alpha
// falloff computed from UV distance-to-center, so it reads as a soft
// puff/leaf instead of a hard-edged square. No texture asset needed.
// billboard always faces the quad at the camera (particles have no
// natural "forward" of their own); blend_add + depth_draw_never is the
// standard combo for overlapping additive particles -- additive blending
// is order-independent, so skipping the depth write avoids z-fighting
// between particles without needing them sorted, while depth TESTING
// (still on by default) still lets the sign itself occlude particles
// that drift behind it.

uniform vec4 tint : source_color = vec4(0.95, 0.92, 0.8, 1.0);

void fragment() {
	vec2 centered = UV - vec2(0.5);
	float dist = length(centered) * 2.0;
	float falloff = 1.0 - smoothstep(0.0, 1.0, dist);
	ALBEDO = tint.rgb;
	ALPHA = falloff * tint.a * COLOR.a;
}
