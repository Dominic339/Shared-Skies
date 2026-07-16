extends Node3D

const LandmarkMarkerScene := preload("res://scenes/LandmarkMarker.tscn")
const MOVE_SPEED_METERS_PER_SEC := 8.0
const PROXIMITY_RADIUS_METERS := 25.0

@onready var camera: Camera3D = $Camera3D
@onready var player_marker: Node3D = $PlayerMarker
@onready var landmark_markers: Node3D = $LandmarkMarkers
@onready var landmark_display: CanvasLayer = $LandmarkDisplay

var markers_by_landmark_id: Dictionary = {}


func _ready() -> void:
	print("Shared Skies booted.")
	get_viewport().physics_object_picking = true

	if not SupabaseClient.is_ready:
		await SupabaseClient.authenticated
	print("Signed in anonymously as %s" % SupabaseClient.user_id)

	await _load_landmarks()
	await _load_existing_visits()


func _process(delta: float) -> void:
	_handle_movement_input(delta)
	player_marker.position = GeoProjection.to_local(DevLocation.current_lat, DevLocation.current_lng)
	camera.update_around(player_marker.global_position)
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
		marker.landmark_id = row.get("id", "")
		marker.code = row.get("code", "")
		marker.landmark_name = row.get("name", "")
		marker.category = row.get("category", "")
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
	landmark_display.show_landmark(marker)
	if marker.in_range:
		await _record_visit(marker)


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
