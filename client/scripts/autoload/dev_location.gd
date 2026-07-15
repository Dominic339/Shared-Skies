extends Node

# Developer-mode simulated GPS -- core infrastructure per the Phase 1 plan,
# not a later debugging afterthought, since neither device GPS nor
# real-world field testing against Nashua landmarks is practical during
# normal development. Two input paths, both landing on the same
# current_lat/current_lng the rest of the game reads: WASD/arrow-key local
# movement for minute-to-minute dev work, and set_position_manual() for
# jumping straight to a specific coordinate (wired to the on-screen dev
# panel in Main.tscn).

signal position_changed

const MOVE_SPEED_METERS_PER_SEC := 8.0

var current_lat: float = 42.7654  # Nashua, NH default
var current_lng: float = -71.4676


func move(east_meters: float, north_meters: float) -> void:
	var delta := GeoProjection.local_delta_to_lat_lng(east_meters, north_meters)
	current_lat += delta.x
	current_lng += delta.y
	position_changed.emit()


func set_position_manual(lat: float, lng: float) -> void:
	current_lat = lat
	current_lng = lng
	position_changed.emit()


func _process(delta: float) -> void:
	var input_dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		input_dir.y += 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		input_dir.y -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		input_dir.x += 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		input_dir.x -= 1.0

	if input_dir != Vector2.ZERO:
		input_dir = input_dir.normalized() * MOVE_SPEED_METERS_PER_SEC * delta
		move(input_dir.x, input_dir.y)
