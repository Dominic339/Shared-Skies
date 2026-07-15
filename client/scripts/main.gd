extends Node3D

const LandmarkMarkerScene := preload("res://scenes/LandmarkMarker.tscn")

@onready var camera: Camera3D = $Camera3D
@onready var player_marker: Node3D = $PlayerMarker
@onready var landmark_markers: Node3D = $LandmarkMarkers
@onready var landmark_display: CanvasLayer = $LandmarkDisplay


func _ready() -> void:
	print("Shared Skies booted.")
	get_viewport().physics_object_picking = true

	if not SupabaseClient.is_ready:
		await SupabaseClient.authenticated
	print("Signed in anonymously as %s" % SupabaseClient.user_id)

	await _load_landmarks()


func _process(_delta: float) -> void:
	player_marker.position = GeoProjection.to_local(DevLocation.current_lat, DevLocation.current_lng)
	camera.update_around(player_marker.global_position)


func _load_landmarks() -> void:
	var rows: Array = await SupabaseClient.get_table(
		"landmarks_map_view", "select=id,code,name,category,lat,lng"
	)
	print("Fetched %d published landmark(s)." % rows.size())

	for row: Dictionary in rows:
		var marker: Area3D = LandmarkMarkerScene.instantiate()
		landmark_markers.add_child(marker)
		marker.landmark_id = row.get("id", "")
		marker.code = row.get("code", "")
		marker.landmark_name = row.get("name", "")
		marker.category = row.get("category", "")
		marker.position = GeoProjection.to_local(row.get("lat", 0.0), row.get("lng", 0.0))
		marker.tapped.connect(_on_landmark_marker_tapped)


func _on_landmark_marker_tapped(marker: Area3D) -> void:
	landmark_display.show_landmark(marker)
