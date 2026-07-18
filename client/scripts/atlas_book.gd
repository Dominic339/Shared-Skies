extends Node3D

# First visual pass for the Atlas book -- assembles the three provided
# pieces (front cover, back cover, one page) into a simple closed-book
# stack so the leather recoloring and normal-map preservation can be
# checked before any open/turn animation logic is built. The actual
# multi-page assembly (static + dynamic pages, hinge animation) is a
# separate, later step -- this is just "do the pieces load and look
# right."

const FrontCoverScene := preload("res://assets/models/atlas_book_front.glb")
const BackCoverScene := preload("res://assets/models/atlas_book_back.glb")
const PageScene := preload("res://assets/models/atlas_book_page.glb")

const ToonShader := preload("res://shaders/toon.gdshader")

# The provided models are flat gray placeholders (base_color 0.8,0.8,0.8)
# with no real color baked in, so this is a plain flat tint rather than
# preserving/recoloring an existing authored color (contrast with the
# sign's toon material setup, which reads the model's own colors).
const LEATHER_COLOR := Color(0.36, 0.20, 0.11)
# The page isn't leather, and its material-0 face is what will eventually
# carry the SubViewport-projected Atlas UI -- it should read as a light
# page, not a cover.
const PAPER_COLOR := Color(0.93, 0.90, 0.82)

# Real measured half-thicknesses (from each glb's own scale, not a guess):
# front/back covers are 0.01m thick, the page is 0.005m. GAP keeps
# adjacent surfaces from sitting exactly coincident (avoids z-fighting),
# not a meaningful physical gap.
const FRONT_HALF_THICKNESS := 0.005
const BACK_HALF_THICKNESS := 0.005
const PAGE_HALF_THICKNESS := 0.0025
const GAP := 0.0005


func _ready() -> void:
	var front := FrontCoverScene.instantiate()
	add_child(front)
	front.position = Vector3(0, 0, PAGE_HALF_THICKNESS + GAP + FRONT_HALF_THICKNESS)
	_apply_toon_material(front, LEATHER_COLOR)

	var page := PageScene.instantiate()
	add_child(page)
	page.position = Vector3.ZERO
	_apply_toon_material(page, PAPER_COLOR)

	var back := BackCoverScene.instantiate()
	add_child(back)
	back.position = Vector3(0, 0, -(PAGE_HALF_THICKNESS + GAP + BACK_HALF_THICKNESS))
	# Every piece's material-0 face is its own local +Z ("outward"); the
	# back cover needs to face the opposite way from the front cover, not
	# the same way, so its outward face points away from the book rather
	# than into it.
	back.rotation.y = PI
	_apply_toon_material(back, LEATHER_COLOR)


# Recursively replaces each surface's imported material with the toon
# shader using a flat tint (these models have no real authored color to
# preserve), but carries over the original base color texture (the
# printed cover design) and normal map -- if either is present -- along
# with each one's own UV transform, so the actual cover art still reads
# correctly instead of being discarded.
func _apply_toon_material(node: Node, tint: Color) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		for surface_idx in mesh_instance.mesh.get_surface_count():
			var original := mesh_instance.mesh.surface_get_material(surface_idx) as StandardMaterial3D
			var material := ShaderMaterial.new()
			material.shader = ToonShader
			material.set_shader_parameter("albedo_tint", tint)
			material.set_shader_parameter("use_vertex_color", false)
			material.set_shader_parameter("light_bands", 3)
			material.set_shader_parameter("band_softness", 0.15)
			if original and original.albedo_texture:
				material.set_shader_parameter("use_albedo_texture", true)
				material.set_shader_parameter("albedo_texture", original.albedo_texture)
				# Deliberately NOT reapplying original.uv1_offset/uv1_scale here
				# (contrast with the normal_texture handling below) -- doing so
				# shifted the design off-center, which means Godot's glTF
				# import is very likely already applying KHR_texture_transform
				# itself (e.g. baked into the mesh's own UV data) before this
				# code ever runs, and reapplying it here was double-transforming.
				# Sampling the raw UV directly (the shader's default identity
				# offset/scale) matches what's actually centered correctly.
			if original and original.normal_enabled and original.normal_texture:
				material.set_shader_parameter("use_normal_texture", true)
				material.set_shader_parameter("normal_texture", original.normal_texture)
				material.set_shader_parameter(
					"normal_uv_offset", Vector2(original.uv1_offset.x, original.uv1_offset.y)
				)
				material.set_shader_parameter(
					"normal_uv_scale", Vector2(original.uv1_scale.x, original.uv1_scale.y)
				)
			mesh_instance.set_surface_override_material(surface_idx, material)
	for child in node.get_children():
		_apply_toon_material(child, tint)
