extends CanvasLayer

# Ten labeled slots instead of two -- covers multi-collector tests (e.g.
# the profile card 3-copy depletion lifecycle needs at least 4 distinct
# accounts: one placer plus three collectors) without needing to come
# back and wire up more accounts later. An OptionButton + one Switch
# button instead of one button per account, since that would just keep
# growing the panel every time testing needs another identity.
const TEST_USER_LABELS := [
	"Test User A", "Test User B", "Test User C", "Test User D", "Test User E",
	"Test User F", "Test User G", "Test User H", "Test User I", "Test User J",
]

@onready var position_label: Label = $Panel/VBoxContainer/PositionLabel
@onready var lat_edit: LineEdit = $Panel/VBoxContainer/LatEdit
@onready var lng_edit: LineEdit = $Panel/VBoxContainer/LngEdit
@onready var set_button: Button = $Panel/VBoxContainer/SetButton
@onready var user_label: Label = $Panel/VBoxContainer/UserLabel
@onready var test_user_option: OptionButton = $Panel/VBoxContainer/TestUserOption
@onready var test_user_switch_button: Button = $Panel/VBoxContainer/TestUserSwitchButton
@onready var hide_button: Button = $Panel/VBoxContainer/HideButton


func _ready() -> void:
	set_button.pressed.connect(_on_set_button_pressed)
	for label in TEST_USER_LABELS:
		test_user_option.add_item(label)
	test_user_switch_button.pressed.connect(_on_test_user_switch_pressed)
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
func _on_test_user_switch_pressed() -> void:
	await SupabaseClient.switch_to_test_account(TEST_USER_LABELS[test_user_option.selected])


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
	test_user_option.visible = not collapse
	test_user_switch_button.visible = not collapse
	hide_button.text = "Show" if collapse else "Hide"


func _update_label() -> void:
	position_label.text = "Lat: %.5f  Lng: %.5f" % [DevLocation.current_lat, DevLocation.current_lng]


func _update_user_label() -> void:
	user_label.text = "User: %s (%s)" % [SupabaseClient.current_test_label, SupabaseClient.user_id.left(8)]
