extends CanvasLayer

# Appears attached to the tapped sign's screen position (a callout above
# it) rather than as an unrelated fixed-corner menu -- tracks the sign
# every frame while open, since the camera can still be dragged/zoomed
# while a Landmark is focused.

signal closed

const SCREEN_MARGIN_ABOVE_SIGN := 40.0

@onready var panel: PanelContainer = $Panel
@onready var name_label: Label = $Panel/VBoxContainer/NameLabel
@onready var category_label: Label = $Panel/VBoxContainer/CategoryLabel
@onready var code_label: Label = $Panel/VBoxContainer/CodeLabel
@onready var close_button: Button = $Panel/VBoxContainer/CloseButton

var _camera: Camera3D = null
var _marker: LandmarkMarker = null


func _ready() -> void:
	close_button.pressed.connect(_on_close_pressed)
	hide()


func show_landmark(marker: LandmarkMarker, camera: Camera3D) -> void:
	_marker = marker
	_camera = camera
	name_label.text = marker.landmark_name
	category_label.text = "Category: %s" % marker.category
	code_label.text = marker.code
	show()
	_update_position()


func _process(_delta: float) -> void:
	if visible and _marker != null and _camera != null:
		_update_position()


func _update_position() -> void:
	# Anchor above the sign's actual top (real measured height, not the
	# marker's ground-level origin) -- anchoring to ground let the panel
	# increasingly overlap the sign as it got bigger/closer on screen.
	var anchor := _marker.global_position + Vector3(0, LandmarkMarker.STRUCTURE_TOP_HEIGHT_METERS, 0)
	var screen_point := _camera.unproject_position(anchor)
	var target_bottom_y := screen_point.y - SCREEN_MARGIN_ABOVE_SIGN
	panel.position = Vector2(screen_point.x - panel.size.x / 2.0, target_bottom_y - panel.size.y)


func _on_close_pressed() -> void:
	hide()
	_marker = null
	closed.emit()


# Used by main.gd's global Escape handler. Returns whether it actually
# closed anything.
func close_topmost() -> bool:
	if not visible:
		return false
	_on_close_pressed()
	return true
