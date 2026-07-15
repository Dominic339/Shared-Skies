extends Area3D

signal tapped(marker: Area3D)

var landmark_id: String = ""
var code: String = ""
var landmark_name: String = ""
var category: String = ""

var in_range: bool = false
var visited: bool = false

@onready var in_range_indicator: MeshInstance3D = $InRangeIndicator
@onready var visited_indicator: MeshInstance3D = $VisitedIndicator


func _ready() -> void:
	input_ray_pickable = true
	input_event.connect(_on_input_event)
	in_range_indicator.visible = false
	visited_indicator.visible = false


func set_in_range(value: bool) -> void:
	in_range = value
	in_range_indicator.visible = value


func set_visited(value: bool) -> void:
	visited = value
	visited_indicator.visible = value


func _on_input_event(
	_camera: Node, event: InputEvent, _position: Vector3, _normal: Vector3, _shape_idx: int
) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		tapped.emit(self)
	elif event is InputEventScreenTouch and event.pressed:
		tapped.emit(self)
