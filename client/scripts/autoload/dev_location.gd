extends Node

# Developer-mode simulated GPS -- core infrastructure per the Phase 1 plan,
# not a later debugging afterthought, since neither device GPS nor
# real-world field testing against Nashua landmarks is practical during
# normal development. Just a position store: move() and
# set_position_manual() both land on current_lat/current_lng. Input
# handling (WASD, camera-relative direction) lives in main.gd, where the
# camera reference already exists -- this autoload doesn't know or care
# what's driving it.

signal position_changed

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
