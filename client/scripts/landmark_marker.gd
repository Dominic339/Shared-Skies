class_name LandmarkMarker
extends Area3D

signal tapped(marker: LandmarkMarker)

# Color-coded tag, not unique per-category art -- deliberately simple
# until there's a reason to invest in real category iconography.
const CATEGORY_COLORS := {
	"park": Color(0.3, 0.7, 0.3),
	"trail": Color(0.55, 0.4, 0.2),
	"museum": Color(0.6, 0.3, 0.7),
	"historic_site": Color(0.65, 0.5, 0.25),
	"garden": Color(0.4, 0.8, 0.4),
	"overlook": Color(0.4, 0.6, 0.8),
	"beach": Color(0.9, 0.8, 0.5),
	"business": Color(0.5, 0.5, 0.5),
	"memorial": Color(0.6, 0.6, 0.65),
	"covered_bridge": Color(0.6, 0.35, 0.15),
	"other": Color(0.7, 0.7, 0.7),
}

const NAME_COLOR := Color(1, 1, 1)
const NAME_COLOR_SELECTED := Color(1, 0.85, 0.3)

# Fixed scale, not distance-compensated -- an earlier version grew the
# sign as the camera pulled back to counteract perspective shrinkage, but
# that made it visibly resize/shrink relative to the camera in a way that
# read as wrong rather than helpful. Signs are just a set size now, same
# as everything else in the world. 2x true model scale for a bigger visual
# presence (closer to how prominent Pokestop/gym markers read in Pokemon
# GO), not real-world accuracy -- if this scales the whole marker,
# remember STRUCTURE_TOP_HEIGHT_METERS below and main.gd's
# FOCUS_TARGET_HEIGHT_METERS are world-space constants added to
# global_position directly (not local child transforms), so they need to
# scale by the same factor to still point at the sign's actual top/center.
const SIGN_SCALE := 2.0

var landmark_id: String = ""
var code: String = ""
var landmark_name: String = ""
var category: String = ""
var facing_degrees: float = 0.0

var in_range: bool = false
var visited: bool = false
var selected: bool = false

@onready var in_range_indicator: MeshInstance3D = $InRangeIndicator
@onready var visited_indicator: MeshInstance3D = $VisitedIndicator
@onready var category_tag: MeshInstance3D = $CategoryTag
@onready var name_label: Label3D = $NameLabel3D
@onready var sign_model: Node3D = $SignModel
@onready var card_holders: Node3D = $CardHolders
@onready var wind_swirl: GPUParticles3D = $WindSwirl

const ToonShader := preload("res://shaders/toon.gdshader")
const ProfileCardHolderScene := preload("res://assets/models/profile_card_holder.glb")

# Card/holder models are each authored at their own local origin (0,0,0)
# in their own files -- they don't carry a baked position relative to
# the sign, so placement has to happen here. FIRST_SLOT_POSITION is a
# real reference point (converted from Blender Z-up to Godot Y-up:
# X same, Y<-Blender Z, Z<-(-Blender Y)) taken from an example
# arrangement Dominic had in his working scene, not a guess -- but
# SLOT_SPACING (the vertical gap between stacked holders) IS an
# estimate, derived from the card's own ~6.9cm height plus a small gap,
# since no second reference point was available to measure spacing
# directly. Check both once visible in Godot.
# Z shifted by +1.173 along with every other child in LandmarkMarker.tscn
# (SignModel included) -- the sign model's own local origin turned out to
# sit at its edge (mesh Z spans -2.301..-0.045, center -1.173), not its
# visual center, which is what made the marker rotate like a door hinge
# instead of spinning in place, and made camera-focus/panel-anchor code
# aim at that edge instead of the board. Shifting everything the same
# amount re-centers the origin on the sign without moving anything
# relative to the model itself.
const FIRST_SLOT_POSITION := Vector3(0.04, 1.7999, -1.0884)
const SLOT_SPACING := 0.09

# Real measured height of the sign structure (parsed directly from
# landmark_sign.glb's mesh accessor bounds + its node transform, not a
# screenshot estimate): ~2.54m tall at true (1x) scale, ~2.26m wide.
# Multiplied by SIGN_SCALE since this is a world-space offset added to
# global_position directly, not a local child transform -- it doesn't
# get scaled automatically the way the sign mesh and other child nodes
# do. Used as the anchor height for the info panel so it tracks the
# actual sign top instead of the marker's ground-level origin --
# anchoring to ground was what let the panel overlap the sign as it got
# closer/bigger on screen.
const STRUCTURE_TOP_HEIGHT_METERS := 2.54 * SIGN_SCALE


func _ready() -> void:
	input_ray_pickable = true
	input_event.connect(_on_input_event)
	in_range_indicator.visible = false
	visited_indicator.visible = false
	scale = Vector3.ONE * SIGN_SCALE
	_apply_toon_demo_material(sign_model)


# TEMPORARY: applies toon/cel-shading on top of the sign model's own
# authored colors (read from each surface's original imported material)
# rather than forcing one hardcoded tint -- preserves whatever Dominic
# actually set up per material slot in Blender (e.g. the board's dark
# wood body vs. its lighter trim color) while still adding the banded
# lighting response. Revisit once the sign's real materials/textures are
# finalized -- this is a reasonable default, not the final art pass.
func _apply_toon_demo_material(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		for surface_idx in mesh_instance.mesh.get_surface_count():
			var original := mesh_instance.mesh.surface_get_material(surface_idx) as StandardMaterial3D
			var material := ShaderMaterial.new()
			material.shader = ToonShader
			material.set_shader_parameter(
				"albedo_tint", original.albedo_color if original else Color(0.4, 0.27, 0.15)
			)
			material.set_shader_parameter("use_vertex_color", false)
			material.set_shader_parameter("light_bands", 3)
			material.set_shader_parameter("band_softness", 0.15)
			mesh_instance.set_surface_override_material(surface_idx, material)
	for child in node.get_children():
		_apply_toon_demo_material(child)


# Single entry point for populating a freshly-instantiated marker --
# keeps the 3D name tag/category color in sync with the data instead of
# needing every caller to remember to update them separately.
func setup(
	p_landmark_id: String, p_code: String, p_name: String, p_category: String,
	p_slot_count: int = 3, p_facing_degrees: float = 0.0
) -> void:
	landmark_id = p_landmark_id
	code = p_code
	landmark_name = p_name
	category = p_category
	facing_degrees = p_facing_degrees

	name_label.text = landmark_name
	# Set once, here, and never touched again -- signs are static world
	# objects like Pokestops, not billboards that track the camera.
	# FRONT_AXIS_CORRECTION_DEGREES compensates for the sign model's
	# authored front direction not lining up with facing_degrees=0.
	rotation.y = deg_to_rad(facing_degrees) + deg_to_rad(FRONT_AXIS_CORRECTION_DEGREES)
	# Sub-resources (like this material) are shared across every instance
	# of a scene by default -- duplicate before mutating, or every marker
	# would end up the same color as whichever was set up last.
	var tag_material := (category_tag.get_surface_override_material(0) as StandardMaterial3D).duplicate() as StandardMaterial3D
	tag_material.albedo_color = CATEGORY_COLORS.get(category, CATEGORY_COLORS["other"])
	category_tag.set_surface_override_material(0, tag_material)

	_spawn_card_holders(p_slot_count)


# One holder per profile_card_slot_count -- as a Landmark upgrades and
# gains slots, this just spawns more holders stacked above the first,
# not a new system. Holders are permanent sign fixtures (unlike the
# cards themselves, which only exist once a player actually places one
# -- that's a separate, not-yet-built system).
func _spawn_card_holders(slot_count: int) -> void:
	for existing in card_holders.get_children():
		existing.queue_free()
	for i in slot_count:
		var holder := ProfileCardHolderScene.instantiate()
		card_holders.add_child(holder)
		holder.position = FIRST_SLOT_POSITION + Vector3(0, SLOT_SPACING * i, 0)
		# Holders are permanent sign fixtures; cards are not spawned here
		# -- real gameplay only shows a card once a player has actually
		# left one, which isn't built yet. The fit test that used to spawn
		# a card in every holder confirmed the placement/orientation
		# works: preload("res://assets/models/profile_card.glb").instantiate()
		# as a child of `holder`, no rotation correction needed (the model
		# now has its upright + 20 deg forward lean pre-baked to match the
		# holder), and card.position = Vector3(0.002, 0.03, 0) to sit
		# correctly in the holder's pocket. Reuse these exact values when
		# building real card placement.


func set_in_range(value: bool) -> void:
	# Rising edge only -- a one-shot burst when you actually arrive, not a
	# permanent ambient loop (was always emitting before, regardless of
	# distance). Re-entering range later (walk away, come back) plays it
	# again via restart(), same as the first arrival.
	if value and not in_range:
		wind_swirl.restart()
	in_range = value
	in_range_indicator.visible = value


func set_visited(value: bool) -> void:
	visited = value
	visited_indicator.visible = value


func set_selected(value: bool) -> void:
	selected = value
	# The floating in-world name tag is sized for browsing from a distance
	# -- at focus range it's many times wider than the sign itself (a long
	# name at Label3D's world scale dwarfs the ~2.26m board), and the info
	# panel already shows the name up close, so keeping both up is both
	# redundant and what was actually overflowing the screen on focus.
	name_label.visible = not value
	name_label.modulate = NAME_COLOR_SELECTED if value else NAME_COLOR


# Degrees added on top of facing_degrees to correct for the sign model's
# authored front direction not matching Godot's look_at() default (local
# -Z is "forward"). If the sign ends up facing the wrong way once tested,
# this is the one number to change -- try 90, -90, or 180.
const FRONT_AXIS_CORRECTION_DEGREES := -90.0


func _on_input_event(
	_camera: Node, event: InputEvent, _position: Vector3, _normal: Vector3, _shape_idx: int
) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		tapped.emit(self)
	elif event is InputEventScreenTouch and event.pressed:
		tapped.emit(self)
