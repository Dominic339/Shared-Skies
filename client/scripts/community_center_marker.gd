class_name CommunityCenterMarker
extends Area3D

# Deliberately simple compared to LandmarkMarker -- no card holders, no
# category tag, no visited state. This stands in for the real building/
# interior until that gets built; tapping it always opens the hub
# (no proximity requirement to open, matching how a Landmark's info
# panel is always tappable from a distance too -- none of the hub's
# sub-screens are location-gated to standing at the center specifically).

signal tapped(marker: CommunityCenterMarker)

var community_center_id: String = ""
var community_id: String = ""
var center_name: String = ""

var in_range: bool = false

@onready var in_range_indicator: MeshInstance3D = $InRangeIndicator
@onready var name_label: Label3D = $NameLabel3D


func _ready() -> void:
	input_ray_pickable = true
	input_event.connect(_on_input_event)
	in_range_indicator.visible = false


func setup(p_id: String, p_community_id: String, p_name: String) -> void:
	community_center_id = p_id
	community_id = p_community_id
	center_name = p_name
	name_label.text = p_name


func set_in_range(value: bool) -> void:
	in_range = value
	in_range_indicator.visible = value


func _on_input_event(
	_camera: Node, event: InputEvent, _position: Vector3, _normal: Vector3, _shape_idx: int
) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		tapped.emit(self)
	elif event is InputEventScreenTouch and event.pressed:
		tapped.emit(self)
