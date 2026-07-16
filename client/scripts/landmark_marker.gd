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

# Signs are real-world scale (~2.5m), which is correct up close but
# shrinks to an unreadable speck once the camera pulls back far enough
# to see real street-scale distances. Same fix every GPS-based map game
# uses for points of interest: stay true-to-life size up close (never
# below MIN_DISTANCE_SCALE, effectively 1x/true size), then grow to
# counteract perspective shrinkage as the camera pulls back, hard capped
# at MAX_DISTANCE_SCALE -- reached by (CLOSE_DISTANCE_METERS *
# MAX_DISTANCE_SCALE) meters, deliberately close enough to hit during
# normal play, not just in theory at extreme zoom. Not meant to make a
# sign readable from any distance -- just visible; reading it is still
# what walking up to one is for.
const CLOSE_DISTANCE_METERS := 25.0
const MIN_DISTANCE_SCALE := 1.0
const MAX_DISTANCE_SCALE := 3.0  # plateaus at 75m -- well within normal zoomed-out map view

var landmark_id: String = ""
var code: String = ""
var landmark_name: String = ""
var category: String = ""

var in_range: bool = false
var visited: bool = false
var selected: bool = false

@onready var in_range_indicator: MeshInstance3D = $InRangeIndicator
@onready var visited_indicator: MeshInstance3D = $VisitedIndicator
@onready var category_tag: MeshInstance3D = $CategoryTag
@onready var name_label: Label3D = $NameLabel3D
@onready var sign_model: Node3D = $SignModel

const ToonShader := preload("res://shaders/toon.gdshader")


func _ready() -> void:
	input_ray_pickable = true
	input_event.connect(_on_input_event)
	in_range_indicator.visible = false
	visited_indicator.visible = false
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
func setup(p_landmark_id: String, p_code: String, p_name: String, p_category: String) -> void:
	landmark_id = p_landmark_id
	code = p_code
	landmark_name = p_name
	category = p_category

	name_label.text = landmark_name
	# Sub-resources (like this material) are shared across every instance
	# of a scene by default -- duplicate before mutating, or every marker
	# would end up the same color as whichever was set up last.
	var tag_material := (category_tag.get_surface_override_material(0) as StandardMaterial3D).duplicate() as StandardMaterial3D
	tag_material.albedo_color = CATEGORY_COLORS.get(category, CATEGORY_COLORS["other"])
	category_tag.set_surface_override_material(0, tag_material)


func set_in_range(value: bool) -> void:
	in_range = value
	in_range_indicator.visible = value


func set_visited(value: bool) -> void:
	visited = value
	visited_indicator.visible = value


func set_selected(value: bool) -> void:
	selected = value
	name_label.modulate = NAME_COLOR_SELECTED if value else NAME_COLOR


# Called every frame by main.gd with the camera's actual distance to
# this marker -- scales the whole marker (sign, indicators, label, and
# its collision shape, so tapping stays just as easy at a distance) as
# a single unit to counteract perspective shrinkage.
func update_distance_scale(camera_distance: float) -> void:
	var factor := camera_distance / CLOSE_DISTANCE_METERS
	scale = Vector3.ONE * clampf(factor, MIN_DISTANCE_SCALE, MAX_DISTANCE_SCALE)


# Degrees added after look_at() to correct for the sign model's authored
# front direction not matching Godot's look_at() default (local -Z is
# "forward"). If the sign ends up facing away from the player once
# tested, this is the one number to change -- try 90, -90, or 180.
const FRONT_AXIS_CORRECTION_DEGREES := -90.0


# Rotates the whole marker (board + collision + indicators together, so
# they stay aligned) around the vertical axis only -- never tilts up/
# down -- to keep the sign's readable face toward the player regardless
# of which side they approach from.
func face_player(player_global_position: Vector3) -> void:
	var target := player_global_position
	target.y = global_position.y
	if target.distance_to(global_position) < 0.01:
		return
	look_at(target, Vector3.UP)
	rotate_y(deg_to_rad(FRONT_AXIS_CORRECTION_DEGREES))


func _on_input_event(
	_camera: Node, event: InputEvent, _position: Vector3, _normal: Vector3, _shape_idx: int
) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		tapped.emit(self)
	elif event is InputEventScreenTouch and event.pressed:
		tapped.emit(self)
