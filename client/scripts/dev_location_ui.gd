extends CanvasLayer

@onready var position_label: Label = $Panel/VBoxContainer/PositionLabel
@onready var lat_edit: LineEdit = $Panel/VBoxContainer/LatEdit
@onready var lng_edit: LineEdit = $Panel/VBoxContainer/LngEdit
@onready var set_button: Button = $Panel/VBoxContainer/SetButton
@onready var user_label: Label = $Panel/VBoxContainer/UserLabel
@onready var test_user_a_button: Button = $Panel/VBoxContainer/TestUserAButton
@onready var test_user_b_button: Button = $Panel/VBoxContainer/TestUserBButton
@onready var hide_button: Button = $Panel/VBoxContainer/HideButton


func _ready() -> void:
	set_button.pressed.connect(_on_set_button_pressed)
	test_user_a_button.pressed.connect(_on_test_user_a_pressed)
	test_user_b_button.pressed.connect(_on_test_user_b_pressed)
	hide_button.pressed.connect(_on_hide_button_pressed)
	DevLocation.position_changed.connect(_update_label)
	SupabaseClient.authenticated.connect(_update_user_label)
	_update_label()
	_update_user_label()


func _on_set_button_pressed() -> void:
	if lat_edit.text.is_valid_float() and lng_edit.text.is_valid_float():
		DevLocation.set_position_manual(lat_edit.text.to_float(), lng_edit.text.to_float())


# Dev-only -- lets profile-card placement/collection (and any other
# player-to-player feature) be tested by swapping identities in the same
# running game, instead of reinstalling or clearing session data to get a
# second account.
func _on_test_user_a_pressed() -> void:
	await SupabaseClient.switch_to_test_account("Test User A")


func _on_test_user_b_pressed() -> void:
	await SupabaseClient.switch_to_test_account("Test User B")


# Collapses everything except this button itself (rather than hiding the
# whole panel), since hiding hide_button along with the rest would leave
# no way to bring the panel back.
func _on_hide_button_pressed() -> void:
	var collapse := position_label.visible
	position_label.visible = not collapse
	lat_edit.visible = not collapse
	lng_edit.visible = not collapse
	set_button.visible = not collapse
	user_label.visible = not collapse
	test_user_a_button.visible = not collapse
	test_user_b_button.visible = not collapse
	hide_button.text = "Show" if collapse else "Hide"


func _update_label() -> void:
	position_label.text = "Lat: %.5f  Lng: %.5f" % [DevLocation.current_lat, DevLocation.current_lng]


func _update_user_label() -> void:
	user_label.text = "User: %s (%s)" % [SupabaseClient.current_test_label, SupabaseClient.user_id.left(8)]
