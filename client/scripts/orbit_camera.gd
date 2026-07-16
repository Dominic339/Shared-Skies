extends Camera3D

# Pokemon-GO-style map camera: orbits freely around the player via drag,
# tilts up/down within a clamped range, and zooms within a clamped range
# via scroll/pinch -- always looking straight at the player, since
# position/orientation are fully recomputed every frame from
# (yaw, pitch, zoom) rather than relying on a hand-authored transform, so
# there's no way for the camera to end up aimed somewhere wrong.

@export var min_zoom: float = 4.0  # lowered so the sign-focus camera can sit closer than free-roam ever needed before
@export var max_zoom: float = 200.0  # real street geometry spans hundreds of meters, not ~20
@export var drag_degrees_per_pixel: float = 0.3
@export var zoom_step: float = 10.0

# 15-degree buffer off both extremes -- never fully edge-on (0 deg, camera
# in the ground plane) and never fully top-down (90 deg, straight overhead)
# -- leaving a 60-degree range of motion in between.
const MIN_PITCH_DEGREES := 15.0
const MAX_PITCH_DEGREES := 75.0

var yaw_degrees: float = 0.0
var pitch_degrees: float = 55.0
var zoom: float = 50.0

# Set while a sign is focused -- the focus view is meant to be one fixed,
# deliberately-framed shot, not something the player can drag/zoom out of.
var locked: bool = false

var _dragging: bool = false


func _unhandled_input(event: InputEvent) -> void:
	if locked:
		return
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


# Smoothly animates zoom to a new value (e.g. moving closer to focus on
# a tapped Landmark sign) without touching yaw/pitch or the orbit target
# itself -- callers decide what update_around() is centered on.
func animate_zoom_to(target_zoom: float, duration: float = 0.4) -> void:
	var tween := create_tween()
	tween.tween_property(self, "zoom", clampf(target_zoom, min_zoom, max_zoom), duration).set_trans(Tween.TRANS_SINE)


# Companion to animate_zoom_to(), used to bring the camera down to a more
# level, head-on angle when focusing a sign -- the free-roam default pitch
# (55 deg, chosen for a good overhead map view) looks down at the ground
# too steeply for a nice "reading the board" framing up close. Deliberately
# NOT clamped to MIN_PITCH_DEGREES/MAX_PITCH_DEGREES -- that clamp exists
# to keep free-roam dragging (_apply_drag) from going fully edge-on, but a
# programmatic focus view is a separate, controlled camera state that can
# go all the way to a truly flat 0 deg without the same concern.
func animate_pitch_to(target_pitch_degrees: float, duration: float = 0.4) -> void:
	var tween := create_tween()
	tween.tween_property(
		self, "pitch_degrees", clampf(target_pitch_degrees, 0.0, 90.0), duration
	).set_trans(Tween.TRANS_SINE)


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
