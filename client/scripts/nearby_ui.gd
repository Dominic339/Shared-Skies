extends CanvasLayer

# Small always-on corner widget, Pokemon-GO-style -- not a modal panel
# (no Close button, not wired into main.gd's Escape handler chain), just
# a passive distance-sorted readout of the closest Landmarks/Community
# Centers that updates on an interval rather than every frame, and lets
# the player tap an entry to jump straight to it (same as tapping the
# marker itself in the world).

signal landmark_tapped(marker: LandmarkMarker)
signal community_center_tapped(marker: CommunityCenterMarker)

const UPDATE_INTERVAL_SECONDS := 0.5
const MAX_ENTRIES := 5

@onready var entry_buttons: Array[Button] = [
	$Panel/VBoxContainer/Entry1,
	$Panel/VBoxContainer/Entry2,
	$Panel/VBoxContainer/Entry3,
	$Panel/VBoxContainer/Entry4,
	$Panel/VBoxContainer/Entry5,
]

var _landmark_markers: Node3D
var _community_center_markers: Node3D
var _player_marker: Node3D
var _proximity_radius_meters: float = 25.0
var _timer_seconds: float = 0.0
var _entry_markers: Array = []


func _ready() -> void:
	for i in entry_buttons.size():
		entry_buttons[i].visible = false
		entry_buttons[i].pressed.connect(_on_entry_pressed.bind(i))
		_entry_markers.append(null)


func setup(
	landmark_markers: Node3D, community_center_markers: Node3D,
	player_marker: Node3D, proximity_radius_meters: float
) -> void:
	_landmark_markers = landmark_markers
	_community_center_markers = community_center_markers
	_player_marker = player_marker
	_proximity_radius_meters = proximity_radius_meters
	_refresh()


func _process(delta: float) -> void:
	_timer_seconds += delta
	if _timer_seconds < UPDATE_INTERVAL_SECONDS:
		return
	_timer_seconds = 0.0
	_refresh()


func _refresh() -> void:
	if _landmark_markers == null or _player_marker == null:
		return

	var entries: Array = []
	for marker: LandmarkMarker in _landmark_markers.get_children():
		entries.append({
			"marker": marker,
			"name": marker.landmark_name,
			"distance": _player_marker.global_position.distance_to(marker.global_position),
		})
	for marker: CommunityCenterMarker in _community_center_markers.get_children():
		entries.append({
			"marker": marker,
			"name": marker.center_name,
			"distance": _player_marker.global_position.distance_to(marker.global_position),
		})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["distance"] < b["distance"])

	for i in entry_buttons.size():
		if i < entries.size():
			var entry: Dictionary = entries[i]
			var suffix := "  (in range)" if entry["distance"] <= _proximity_radius_meters else ""
			entry_buttons[i].text = "%s — %dm%s" % [entry["name"], int(entry["distance"]), suffix]
			entry_buttons[i].visible = true
			_entry_markers[i] = entry["marker"]
		else:
			entry_buttons[i].visible = false
			_entry_markers[i] = null


func _on_entry_pressed(index: int) -> void:
	var marker: Variant = _entry_markers[index]
	if marker is LandmarkMarker:
		landmark_tapped.emit(marker)
	elif marker is CommunityCenterMarker:
		community_center_tapped.emit(marker)
