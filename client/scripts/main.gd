extends Node3D

const LandmarkMarkerScene := preload("res://scenes/LandmarkMarker.tscn")
const MOVE_SPEED_METERS_PER_SEC := 30.0  # dev-only testing convenience -- real gameplay uses actual device GPS, not this
const PROXIMITY_RADIUS_METERS := 25.0
const FOCUS_ZOOM := 15.0  # closer view when a sign is tapped, per the sign-first interaction design

@onready var camera: Camera3D = $Camera3D
@onready var ground: Node3D = $Ground
@onready var player_marker: Node3D = $PlayerMarker
@onready var landmark_markers: Node3D = $LandmarkMarkers
@onready var landmark_display: CanvasLayer = $LandmarkDisplay

var markers_by_landmark_id: Dictionary = {}
var focused_marker: LandmarkMarker = null
var _zoom_before_focus: float = 50.0


func _ready() -> void:
	print("Shared Skies booted.")
	get_viewport().physics_object_picking = true
	landmark_display.closed.connect(_on_landmark_display_closed)

	if not SupabaseClient.is_ready:
		await SupabaseClient.authenticated
	print("Signed in anonymously as %s" % SupabaseClient.user_id)

	await _load_landmarks()
	await _load_existing_visits()


func _process(delta: float) -> void:
	_handle_movement_input(delta)
	player_marker.position = GeoProjection.to_local(DevLocation.current_lat, DevLocation.current_lng)
	# The camera follows whichever Landmark is focused (tapped sign), or
	# the player otherwise -- this is what makes "camera moves closer
	# when clicked" work without a separate cinematic system.
	var camera_target := focused_marker.global_position if focused_marker else player_marker.global_position
	camera.update_around(camera_target)
	# Ground is a single static placeholder plane, not per-tile geometry
	# like roads/water -- recenter it on the player each frame so its
	# fixed size never runs out relative to wherever the player actually
	# roams. A real fix (ground as part of the tile system) can replace
	# this once habitat/land-cover rendering lands.
	ground.position = Vector3(player_marker.position.x, 0.0, player_marker.position.z)
	_check_proximity()


func _handle_movement_input(delta: float) -> void:
	var input_dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		input_dir.y += 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		input_dir.y -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		input_dir.x += 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		input_dir.x -= 1.0

	if input_dir == Vector2.ZERO:
		return
	input_dir = input_dir.normalized()

	# Camera-relative, not world-axis-locked: "forward" is always the
	# direction the camera is currently looking, flattened onto the
	# ground, regardless of how far the player has dragged it around.
	# Read straight from the camera's real transform rather than
	# re-deriving yaw trig by hand -- same lesson as the earlier
	# hand-authored camera transform bug.
	var cam_basis := camera.global_transform.basis
	var forward := -Vector3(cam_basis.z.x, 0.0, cam_basis.z.z).normalized()
	var right := Vector3(cam_basis.x.x, 0.0, cam_basis.x.z).normalized()

	var movement := (right * input_dir.x + forward * input_dir.y) * MOVE_SPEED_METERS_PER_SEC * delta
	DevLocation.move(movement.x, -movement.z)


func _check_proximity() -> void:
	for marker: LandmarkMarker in landmark_markers.get_children():
		var distance := player_marker.global_position.distance_to(marker.global_position)
		marker.set_in_range(distance <= PROXIMITY_RADIUS_METERS)


func _load_landmarks() -> void:
	var rows: Array = await SupabaseClient.get_table(
		"landmarks_map_view", "select=id,code,name,category,lat,lng"
	)
	print("Fetched %d published landmark(s)." % rows.size())

	for row: Dictionary in rows:
		var marker: LandmarkMarker = LandmarkMarkerScene.instantiate()
		landmark_markers.add_child(marker)
		marker.setup(row.get("id", ""), row.get("code", ""), row.get("name", ""), row.get("category", ""))
		marker.position = GeoProjection.to_local(row.get("lat", 0.0), row.get("lng", 0.0))
		marker.tapped.connect(_on_landmark_marker_tapped)
		markers_by_landmark_id[marker.landmark_id] = marker


func _load_existing_visits() -> void:
	var rows: Array = await SupabaseClient.get_table(
		"visits", "select=landmark_id&wayfinder_id=eq.%s" % SupabaseClient.user_id
	)
	for row: Dictionary in rows:
		var marker: LandmarkMarker = markers_by_landmark_id.get(row.get("landmark_id", ""))
		if marker:
			marker.set_visited(true)
	print("%d Landmark(s) already visited." % rows.size())


func _on_landmark_marker_tapped(marker: LandmarkMarker) -> void:
	if focused_marker == null:
		_zoom_before_focus = camera.zoom
	elif focused_marker != marker:
		focused_marker.set_selected(false)

	focused_marker = marker
	marker.set_selected(true)
	camera.animate_zoom_to(FOCUS_ZOOM)

	landmark_display.show_landmark(marker, camera)
	if marker.in_range:
		await _record_visit(marker)


func _on_landmark_display_closed() -> void:
	if focused_marker:
		focused_marker.set_selected(false)
	focused_marker = null
	camera.animate_zoom_to(_zoom_before_focus)


func _record_visit(marker: LandmarkMarker) -> void:
	var is_first := not marker.visited
	marker.set_visited(true)  # optimistic -- avoids double-recording if tapped again before this resolves

	var row := await SupabaseClient.insert_row("visits", {
		"wayfinder_id": SupabaseClient.user_id,
		"landmark_id": marker.landmark_id,
		"is_first_visit": is_first,
	})

	if row.is_empty():
		print("Failed to record visit for %s" % marker.code)
		if is_first:
			marker.set_visited(false)
	elif is_first:
		print("Visited %s for the first time!" % marker.landmark_name)
	else:
		print("Visited %s again." % marker.landmark_name)
