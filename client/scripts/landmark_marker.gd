extends Area3D

signal tapped(marker: Area3D)

var landmark_id: String = ""
var code: String = ""
var landmark_name: String = ""
var category: String = ""


func _ready() -> void:
	input_ray_pickable = true
	input_event.connect(_on_input_event)


func _on_input_event(
	_camera: Node, event: InputEvent, _position: Vector3, _normal: Vector3, _shape_idx: int
) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		tapped.emit(self)
	elif event is InputEventScreenTouch and event.pressed:
		tapped.emit(self)
