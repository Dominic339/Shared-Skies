extends Node3D

const LandmarkMarkerScene := preload("res://scenes/LandmarkMarker.tscn")
const CommunityCenterMarkerScene := preload("res://scenes/CommunityCenterMarker.tscn")
const MOVE_SPEED_METERS_PER_SEC := 30.0  # dev-only testing convenience -- real gameplay uses actual device GPS, not this
const PROXIMITY_RADIUS_METERS := 25.0
const FOCUS_ZOOM := 5.5  # tighter than free-roam ever needs -- fills the frame with the ~4.5m (2x-scaled) sign structure
const FOCUS_PITCH_DEGREES := 0.0  # fully level -- flat-on with the board, not looking down at it from above
# Board's face sits roughly at this height above the marker's (ground-level)
# origin -- orbiting around the ground would tilt the framing toward the
# sign's base instead of centering the board itself. Matches the board's
# vertical center per its CollisionShape3D (position.y = 1.27), scaled by
# LandmarkMarker.SIGN_SCALE since this is a world-space offset added to
# global_position directly, not a local child transform that scales
# automatically with the marker. This now correctly lines up with the
# sign's true horizontal center too -- LandmarkMarker.tscn's children
# (including the sign model itself) were previously offset from the
# marker's own origin, which is what made the camera aim at the sign's
# edge instead of its middle; see landmark_marker.gd's FIRST_SLOT_POSITION
# comment for the fix.
const FOCUS_TARGET_HEIGHT_METERS := 1.3 * LandmarkMarker.SIGN_SCALE

@onready var camera: Camera3D = $Camera3D
@onready var ground: Node3D = $Ground
@onready var player_marker: Node3D = $PlayerMarker
@onready var landmark_markers: Node3D = $LandmarkMarkers
@onready var landmark_display: CanvasLayer = $LandmarkDisplay
@onready var atlas_button: Button = $AtlasButton/Button
@onready var atlas_ui: CanvasLayer = $AtlasUI
@onready var postcards_button: Button = $PostcardsButton/Button
@onready var postcards_ui: CanvasLayer = $PostcardsUI
@onready var profile_cards_button: Button = $ProfileCardsButton/Button
@onready var profile_cards_ui: CanvasLayer = $ProfileCardsUI
@onready var waymarks_button: Button = $WaymarksButton/Button
@onready var waymarks_ui: CanvasLayer = $WaymarksUI
@onready var community_board_button: Button = $CommunityBoardButton/Button
@onready var community_board_ui: CanvasLayer = $CommunityBoardUI
@onready var mailbox_button: Button = $MailboxButton/Button
@onready var mailbox_ui: CanvasLayer = $MailboxUI
@onready var museum_button: Button = $MuseumButton/Button
@onready var museum_ui: CanvasLayer = $MuseumUI
@onready var community_recommendations_button: Button = $CommunityRecommendationsButton/Button
@onready var community_recommendations_ui: CanvasLayer = $CommunityRecommendationsUI
@onready var community_center_markers: Node3D = $CommunityCenterMarkers
@onready var community_center_ui: CanvasLayer = $CommunityCenterUI
@onready var nearby_ui: CanvasLayer = $NearbyUI

var markers_by_landmark_id: Dictionary = {}
var focused_marker: LandmarkMarker = null
var _zoom_before_focus: float = 50.0
var _pitch_before_focus: float = 55.0
var _yaw_before_focus: float = 0.0


func _ready() -> void:
	print("Shared Skies booted.")
	get_viewport().physics_object_picking = true
	landmark_display.closed.connect(_on_landmark_display_closed)
	atlas_button.pressed.connect(_on_atlas_button_pressed)
	postcards_button.pressed.connect(_on_postcards_button_pressed)
	profile_cards_button.pressed.connect(_on_profile_cards_button_pressed)
	waymarks_button.pressed.connect(_on_waymarks_button_pressed)
	community_board_button.pressed.connect(_on_community_board_button_pressed)
	mailbox_button.pressed.connect(_on_mailbox_button_pressed)
	museum_button.pressed.connect(_on_museum_button_pressed)
	community_recommendations_button.pressed.connect(_on_community_recommendations_button_pressed)
	community_center_ui.setup_links(
		community_board_ui, museum_ui, mailbox_ui, community_recommendations_ui
	)
	nearby_ui.setup(landmark_markers, community_center_markers, player_marker, PROXIMITY_RADIUS_METERS)
	nearby_ui.landmark_tapped.connect(_on_landmark_marker_tapped)
	nearby_ui.community_center_tapped.connect(_on_community_center_marker_tapped)

	if not SupabaseClient.is_ready:
		await SupabaseClient.authenticated
	print("Signed in anonymously as %s" % SupabaseClient.user_id)

	await _load_landmarks()
	await _load_existing_visits()
	await _load_community_centers()

	# Connected only now, after the initial load above completes -- fires
	# on a later re-authentication (a dev test-account switch mid-session),
	# refreshing per-account visited state. Landmarks themselves don't
	# need re-fetching, they're the same public data for everyone.
	# Deliberately not connected any earlier: this same signal is also
	# what the await above resumes on, and firing this handler against the
	# still-empty markers_by_landmark_id before _load_landmarks() has even
	# run would silently do nothing.
	SupabaseClient.authenticated.connect(_on_supabase_reauthenticated)


func _on_supabase_reauthenticated() -> void:
	print("Signed in anonymously as %s" % SupabaseClient.user_id)
	for marker: LandmarkMarker in markers_by_landmark_id.values():
		marker.set_visited(false)
	await _load_existing_visits()


func _unhandled_input(event: InputEvent) -> void:
	# Global Escape/back handler -- every menu should be closeable this
	# way regardless of whether its own Close button happens to be
	# reachable on screen (a real layout bug already found once on the
	# Atlas panel). Tries the topmost/most-recently-opened one first.
	if event.is_action_pressed("ui_cancel"):
		if atlas_ui.close_topmost():
			return
		if postcards_ui.close_topmost():
			return
		if profile_cards_ui.close_topmost():
			return
		if waymarks_ui.close_topmost():
			return
		if community_board_ui.close_topmost():
			return
		if mailbox_ui.close_topmost():
			return
		if museum_ui.close_topmost():
			return
		if community_recommendations_ui.close_topmost():
			return
		if community_center_ui.close_topmost():
			return
		if landmark_display.close_topmost():
			return


func _process(delta: float) -> void:
	_handle_movement_input(delta)
	player_marker.position = GeoProjection.to_local(DevLocation.current_lat, DevLocation.current_lng)
	# The camera follows whichever Landmark is focused (tapped sign), or
	# the player otherwise -- this is what makes "camera moves closer
	# when clicked" work without a separate cinematic system.
	var camera_target := (
		focused_marker.global_position + Vector3(0, FOCUS_TARGET_HEIGHT_METERS, 0)
		if focused_marker
		else player_marker.global_position
	)
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
		var player_distance := player_marker.global_position.distance_to(marker.global_position)
		marker.set_in_range(player_distance <= PROXIMITY_RADIUS_METERS)
	for marker: CommunityCenterMarker in community_center_markers.get_children():
		var player_distance := player_marker.global_position.distance_to(marker.global_position)
		marker.set_in_range(player_distance <= PROXIMITY_RADIUS_METERS)


func _load_landmarks() -> void:
	var rows: Array = await SupabaseClient.get_table(
		"landmarks_map_view",
		"select=id,code,name,category,lat,lng,profile_card_slot_count,facing_degrees"
	)
	print("Fetched %d published landmark(s)." % rows.size())

	for row: Dictionary in rows:
		var marker: LandmarkMarker = LandmarkMarkerScene.instantiate()
		landmark_markers.add_child(marker)
		var lat: float = row.get("lat", 0.0)
		var lng: float = row.get("lng", 0.0)
		# null facing_degrees means no manual override has been set for
		# this Landmark yet -- fall back to auto-facing the nearest road;
		# if even that finds nothing nearby (outside the exported map
		# area), 0.0 is a reasonable last-resort default.
		var facing_degrees: Variant = row.get("facing_degrees")
		if facing_degrees == null:
			facing_degrees = RoadFacing.compute_facing_degrees(lat, lng)
		if facing_degrees == null:
			facing_degrees = 0.0
		marker.setup(
			row.get("id", ""),
			row.get("code", ""),
			row.get("name", ""),
			row.get("category", ""),
			row.get("profile_card_slot_count", 3),
			facing_degrees
		)
		marker.position = GeoProjection.to_local(lat, lng)
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


func _load_community_centers() -> void:
	var rows: Array = await SupabaseClient.get_table(
		"community_centers_view", "select=id,community_id,name,lat,lng"
	)
	print("Fetched %d Community Center(s)." % rows.size())

	for row: Dictionary in rows:
		var marker: CommunityCenterMarker = CommunityCenterMarkerScene.instantiate()
		community_center_markers.add_child(marker)
		marker.setup(row.get("id", ""), row.get("community_id", ""), row.get("name", ""))
		marker.position = GeoProjection.to_local(row.get("lat", 0.0), row.get("lng", 0.0))
		marker.tapped.connect(_on_community_center_marker_tapped)


func _on_landmark_marker_tapped(marker: LandmarkMarker) -> void:
	if focused_marker == null:
		_zoom_before_focus = camera.zoom
		_pitch_before_focus = camera.pitch_degrees
		_yaw_before_focus = camera.yaw_degrees
	elif focused_marker != marker:
		focused_marker.set_selected(false)

	focused_marker = marker
	marker.set_selected(true)
	# The sign itself never rotates (it's a static object, like a real
	# signpost) -- the camera swings to the sign's own fixed facing_degrees
	# instead, so focus still lands on a consistent, correctly-framed front
	# view of THIS Landmark's actual orientation rather than an arbitrary
	# shared angle.
	camera.yaw_degrees = marker.facing_degrees
	camera.locked = true
	camera.animate_zoom_to(FOCUS_ZOOM)
	camera.animate_pitch_to(FOCUS_PITCH_DEGREES)

	landmark_display.show_landmark(marker, camera)
	if marker.in_range:
		await _record_visit(marker)


func _on_landmark_display_closed() -> void:
	if focused_marker:
		focused_marker.set_selected(false)
	focused_marker = null
	camera.locked = false
	camera.yaw_degrees = _yaw_before_focus
	camera.animate_zoom_to(_zoom_before_focus)
	camera.animate_pitch_to(_pitch_before_focus)


func _on_atlas_button_pressed() -> void:
	atlas_ui.show_atlas()


func _on_postcards_button_pressed() -> void:
	postcards_ui.show_postcards()


func _on_profile_cards_button_pressed() -> void:
	profile_cards_ui.show_profile_cards()


func _on_waymarks_button_pressed() -> void:
	waymarks_ui.show_waymarks()


func _on_community_board_button_pressed() -> void:
	community_board_ui.show_board()


func _on_mailbox_button_pressed() -> void:
	mailbox_ui.show_mailbox()


func _on_museum_button_pressed() -> void:
	museum_ui.show_museum()


func _on_community_recommendations_button_pressed() -> void:
	community_recommendations_ui.show_recommendations()


func _on_community_center_marker_tapped(marker: CommunityCenterMarker) -> void:
	community_center_ui.show_hub(marker.center_name)


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
