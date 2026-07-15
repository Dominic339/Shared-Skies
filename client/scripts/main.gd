extends Node3D

@onready var camera_rig: Node3D = $CameraRig
@onready var player_marker: Node3D = $PlayerMarker


func _ready() -> void:
	print("Shared Skies booted.")
	if not SupabaseClient.is_ready:
		await SupabaseClient.authenticated
	print("Signed in anonymously as %s" % SupabaseClient.user_id)


func _process(_delta: float) -> void:
	camera_rig.global_position = player_marker.global_position
