shader_type spatial;
render_mode blend_mix, cull_back, specular_disabled;

// Reusable cel/toon-shaded material for Shared Skies' stylized look.
// Two independent things combined into one shader:
//
//   1. Base color -- either a flat tint (albedo_tint), or, if the model
//      has vertex colors painted in Blender (e.g. a flower fading from
//      deep red at the base to pale red at the tips), the vertex color
//      itself. Authored once in Blender, exported via glTF, has nothing
//      to do with lighting.
//
//   2. A banded lighting response instead of Godot's normal smooth
//      diffuse falloff. This part can only live here, in a runtime
//      shader -- it depends on the actual light direction at any given
//      moment (time of day, etc.), which isn't known when the model is
//      exported from Blender.
//
// light_bands=1 with a high band_softness approximates a soft, smooth
// gradient ("slight gradient that changes in the light"); higher band
// counts with low softness give a harder, more classic flat-cel look.
// Tune both in the Inspector rather than editing this file per-model.

uniform vec4 albedo_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform bool use_vertex_color = true;
uniform int light_bands : hint_range(1, 6) = 3;
uniform float band_softness : hint_range(0.01, 0.5) = 0.15;

void fragment() {
	vec4 base_color = albedo_tint;
	if (use_vertex_color) {
		base_color *= COLOR;
	}
	ALBEDO = base_color.rgb;
}

void light() {
	float ndotl = dot(NORMAL, LIGHT);
	float bands = float(light_bands);
	float banded = floor(ndotl * bands) / bands;
	float next_band = banded + 1.0 / bands;
	float t = smoothstep(banded, banded + band_softness, ndotl);
	float shade = clamp(mix(banded, next_band, t), 0.0, 1.0);
	DIFFUSE_LIGHT += shade * ALBEDO * LIGHT_COLOR * ATTENUATION;
}
