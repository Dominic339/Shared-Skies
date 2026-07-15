extends Camera3D

# Pokemon-GO-style map camera: orbits freely around the player via drag,
# tilts up/down within a clamped range, and zooms within a clamped range
# via scroll/pinch -- always looking straight at the player, since
# position/orientation are fully recomputed every frame from
# (yaw, pitch, zoom) rather than relying on a hand-authored transform, so
# there's no way for the camera to end up aimed somewhere wrong.

@export var min_zoom: float = 6.0
@export var max_zoom: float = 20.0
@export var drag_degrees_per_pixel: float = 0.3
@export var zoom_step: float = 1.5

# 15-degree buffer off both extremes -- never fully edge-on (0 deg, camera
# in the ground plane) and never fully top-down (90 deg, straight overhead)
# -- leaving a 60-degree range of motion in between.
const MIN_PITCH_DEGREES := 15.0
const MAX_PITCH_DEGREES := 75.0

var yaw_degrees: float = 0.0
var pitch_degrees: float = 55.0
var zoom: float = 12.0

var _dragging: bool = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom = clampf(zoom - zoom_step, min_zoom, max_zoom)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom = clampf(zoom + zoom_step, min_zoom, max_zoom)
	elif event is InputEventMouseMotion and _dragging:
		_apply_drag(event.relative)
	elif event is InputEventScreenDrag:
		_apply_drag(event.relative)
	elif event is InputEventMagnifyGesture:
		zoom = clampf(zoom / event.factor, min_zoom, max_zoom)


func _apply_drag(relative: Vector2) -> void:
	yaw_degrees -= relative.x * drag_degrees_per_pixel
	# Dragging down tilts the camera further overhead (higher pitch);
	# dragging up brings it back toward eye level.
	pitch_degrees = clampf(
		pitch_degrees + relative.y * drag_degrees_per_pixel, MIN_PITCH_DEGREES, MAX_PITCH_DEGREES
	)


func update_around(target_global_position: Vector3) -> void:
	var pitch_rad := deg_to_rad(pitch_degrees)
	var yaw_rad := deg_to_rad(yaw_degrees)
	var offset := Vector3(
		zoom * cos(pitch_rad) * sin(yaw_rad),
		zoom * sin(pitch_rad),
		zoom * cos(pitch_rad) * cos(yaw_rad)
	)
	global_position = target_global_position + offset
	look_at(target_global_position, Vector3.UP)
