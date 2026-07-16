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


func _ready() -> void:
	input_ray_pickable = true
	input_event.connect(_on_input_event)
	in_range_indicator.visible = false
	visited_indicator.visible = false


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


func _on_input_event(
	_camera: Node, event: InputEvent, _position: Vector3, _normal: Vector3, _shape_idx: int
) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		tapped.emit(self)
	elif event is InputEventScreenTouch and event.pressed:
		tapped.emit(self)
