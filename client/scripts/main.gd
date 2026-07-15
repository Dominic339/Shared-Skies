extends Node3D

@onready var camera: Camera3D = $Camera3D
@onready var player_marker: Node3D = $PlayerMarker


func _ready() -> void:
	print("Shared Skies booted.")
	if not SupabaseClient.is_ready:
		await SupabaseClient.authenticated
	print("Signed in anonymously as %s" % SupabaseClient.user_id)


func _process(_delta: float) -> void:
	player_marker.position = GeoProjection.to_local(DevLocation.current_lat, DevLocation.current_lng)
	camera.update_around(player_marker.global_position)
