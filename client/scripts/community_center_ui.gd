extends CanvasLayer

# The Community Center hub -- a temporary flat menu standing in for the
# real building/interior. Opens the SAME screens and backend functions
# already built for the Board, Museum, Post Office, Recommendations,
# and now the Stamp Desk rather than reimplementing any of them -- this
# is purely a front door.

signal closed

@onready var panel: PanelContainer = $Panel
@onready var name_label: Label = $Panel/VBoxContainer/NameLabel
@onready var board_button: Button = $Panel/VBoxContainer/BoardButton
@onready var museum_button: Button = $Panel/VBoxContainer/MuseumButton
@onready var post_office_button: Button = $Panel/VBoxContainer/PostOfficeButton
@onready var recommendations_button: Button = $Panel/VBoxContainer/RecommendationsButton
@onready var stamp_desk_button: Button = $Panel/VBoxContainer/StampDeskButton
@onready var postcard_reprints_button: Button = $Panel/VBoxContainer/PostcardReprintsButton
@onready var close_button: Button = $Panel/VBoxContainer/CloseButton

var _community_board_ui: CanvasLayer
var _museum_ui: CanvasLayer
var _mailbox_ui: CanvasLayer
var _community_recommendations_ui: CanvasLayer
var _stamp_desk_ui: CanvasLayer
var _community_id: String = ""


func _ready() -> void:
	board_button.pressed.connect(_on_board_pressed)
	museum_button.pressed.connect(_on_museum_pressed)
	post_office_button.pressed.connect(_on_post_office_pressed)
	recommendations_button.pressed.connect(_on_recommendations_pressed)
	stamp_desk_button.pressed.connect(_on_stamp_desk_pressed)
	close_button.pressed.connect(_on_close_pressed)
	# Not built yet -- postcard reprints is still just a reserved place
	# in the hub menu.
	postcard_reprints_button.disabled = true
	hide()


# Wired once by main.gd after every other UI screen already exists, so
# this hub never needs its own duplicate logic for any of them.
func setup_links(
	community_board_ui: CanvasLayer, museum_ui: CanvasLayer,
	mailbox_ui: CanvasLayer, community_recommendations_ui: CanvasLayer,
	stamp_desk_ui: CanvasLayer
) -> void:
	_community_board_ui = community_board_ui
	_museum_ui = museum_ui
	_mailbox_ui = mailbox_ui
	_community_recommendations_ui = community_recommendations_ui
	_stamp_desk_ui = stamp_desk_ui


func show_hub(community_id: String, center_name: String) -> void:
	_community_id = community_id
	name_label.text = center_name
	show()


func _on_board_pressed() -> void:
	hide()
	_community_board_ui.show_board()


func _on_museum_pressed() -> void:
	hide()
	_museum_ui.show_museum()


func _on_post_office_pressed() -> void:
	hide()
	_mailbox_ui.show_mailbox()


func _on_recommendations_pressed() -> void:
	hide()
	_community_recommendations_ui.show_recommendations()


func _on_stamp_desk_pressed() -> void:
	hide()
	_stamp_desk_ui.show_stamp_desk(_community_id)


func _on_close_pressed() -> void:
	hide()
	closed.emit()


# Used by main.gd's global Escape handler, same pattern as the other UIs.
func close_topmost() -> bool:
	if not visible:
		return false
	_on_close_pressed()
	return true
