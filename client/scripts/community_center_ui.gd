extends CanvasLayer

# The Community Center hub -- a temporary flat menu standing in for the
# real building/interior. Opens the SAME screens and backend functions
# already built for the Board, Museum, Post Office, and Recommendations
# rather than reimplementing any of them -- this is purely a front door.

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


func _ready() -> void:
	board_button.pressed.connect(_on_board_pressed)
	museum_button.pressed.connect(_on_museum_pressed)
	post_office_button.pressed.connect(_on_post_office_pressed)
	recommendations_button.pressed.connect(_on_recommendations_pressed)
	close_button.pressed.connect(_on_close_pressed)
	# Not built yet -- Community Stamps and postcard reprints are
	# planned next, this just reserves their place in the hub menu.
	stamp_desk_button.disabled = true
	postcard_reprints_button.disabled = true
	hide()


# Wired once by main.gd after every other UI screen already exists, so
# this hub never needs its own duplicate logic for any of them.
func setup_links(
	community_board_ui: CanvasLayer, museum_ui: CanvasLayer,
	mailbox_ui: CanvasLayer, community_recommendations_ui: CanvasLayer
) -> void:
	_community_board_ui = community_board_ui
	_museum_ui = museum_ui
	_mailbox_ui = mailbox_ui
	_community_recommendations_ui = community_recommendations_ui


func show_hub(center_name: String) -> void:
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


func _on_close_pressed() -> void:
	hide()
	closed.emit()


# Used by main.gd's global Escape handler, same pattern as the other UIs.
func close_topmost() -> bool:
	if not visible:
		return false
	_on_close_pressed()
	return true
