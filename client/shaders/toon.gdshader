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

// Optional base color texture -- e.g. a printed/stamped design (a book
// cover's title and border art) multiplied on top of albedo_tint, same
// UV-transform-reproduction reasoning as the normal texture below.
uniform sampler2D albedo_texture : source_color, repeat_disable;
uniform bool use_albedo_texture = false;
uniform vec2 albedo_uv_offset = vec2(0.0);
uniform vec2 albedo_uv_scale = vec2(1.0);

// Optional normal map -- lets baked relief/engraving detail (e.g. an
// embossed book cover design) still read correctly under the banded
// lighting response, instead of being discarded whenever this shader
// replaces a model's imported material (as _apply_toon_demo_material-style
// code does to apply the tint/vertex-color system above). uv_offset/
// uv_scale reproduce whatever UV transform (KHR_texture_transform) the
// original imported material had for this texture -- taking over the
// material means Godot's automatic handling of that transform no longer
// applies, so it has to be reproduced here from the original material's
// own uv1_offset/uv1_scale.
uniform sampler2D normal_texture : hint_normal;
uniform bool use_normal_texture = false;
uniform vec2 normal_uv_offset = vec2(0.0);
uniform vec2 normal_uv_scale = vec2(1.0);

// For meshes with no curved surfaces at all (e.g. the Landmark sign,
// built entirely from flat boards) -- a flat quad is still two
// triangles, and if their vertex normals aren't perfectly averaged
// (flat/non-smoothed export, or just floating-point drift), each
// triangle's interpolated NORMAL differs just enough that the hard
// banding below quantizes them into different bands, showing up as a
// visible diagonal seam splitting the "flat" face into two differently
// shaded triangles. Recomputing the normal per-fragment from screen-space
// derivatives of VERTEX guarantees every fragment on the same flat face
// gets the exact same normal regardless of how it's triangulated or how
// its authored vertex normals were smoothed. Don't enable this on curved
// models -- it replaces smooth per-vertex normals with a hard per-face
// one, which would make curved geometry look faceted/low-poly.
uniform bool use_flat_face_normal = false;

void fragment() {
	vec4 base_color = albedo_tint;
	if (use_vertex_color) {
		base_color *= COLOR;
	}
	if (use_albedo_texture) {
		vec2 transformed_uv = UV * albedo_uv_scale + albedo_uv_offset;
		base_color *= texture(albedo_texture, transformed_uv);
	}
	ALBEDO = base_color.rgb;

	if (use_normal_texture) {
		vec2 transformed_uv = UV * normal_uv_scale + normal_uv_offset;
		NORMAL_MAP = texture(normal_texture, transformed_uv).rgb;
	}

	if (use_flat_face_normal) {
		NORMAL = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	}
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
