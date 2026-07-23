extends CanvasLayer

# Minimal postcard collection browser -- gives the postcard system (auto-
# created on first Landmark visit) an actual place to be seen, instead of
# dead-ending at a single "Postcard collected" line in the Atlas details
# panel. No postcard artwork exists yet (artwork_render_url is null until
# that pipeline is built), so entries show the placeholder season/
# weather/time_of_day + collected date rather than an image.
#
# Also the entry point for the Postal Network: a held (never-mailed)
# postcard can be mailed to any wayfinder whose profile card you've
# collected -- reusing profile_card_collection_view as the recipient
# list instead of requiring a raw ID paste, since there's no friend/
# directory system yet.

signal closed

@onready var panel: PanelContainer = $Panel
@onready var total_label: Label = $Panel/VBoxContainer/TotalLabel
@onready var entries_container: VBoxContainer = $Panel/VBoxContainer/ScrollContainer/EntriesContainer
@onready var close_button: Button = $Panel/VBoxContainer/CloseButton

@onready var details_panel: PanelContainer = $DetailsPanel
@onready var details_name_label: Label = $DetailsPanel/VBoxContainer/NameLabel
@onready var details_community_label: Label = $DetailsPanel/VBoxContainer/CommunityLabel
@onready var details_conditions_label: Label = $DetailsPanel/VBoxContainer/ConditionsLabel
@onready var details_collected_label: Label = $DetailsPanel/VBoxContainer/CollectedLabel
@onready var mail_controls: VBoxContainer = $DetailsPanel/VBoxContainer/MailControls
@onready var recipient_option: OptionButton = $DetailsPanel/VBoxContainer/MailControls/RecipientOption
@onready var message_option: OptionButton = $DetailsPanel/VBoxContainer/MailControls/MessageOption
@onready var mail_button: Button = $DetailsPanel/VBoxContainer/MailControls/MailButton
@onready var details_close_button: Button = $DetailsPanel/VBoxContainer/CloseButton

# canned_message_key -> label shown in the picker. Free-text is gated
# behind feature_flags['mail.freetext_enabled'] server-side and isn't
# wired into this UI at all yet -- only these canned options exist until
# that flag flips (see 20260726000000_postal_network_feature_flag.sql).
const CANNED_MESSAGES := {
	"greetings_from": "Greetings from here!",
	"check_out": "You should check this place out!",
}

var _current_postcard_id: String = ""
var _recipient_ids: Array = []


func _ready() -> void:
	close_button.pressed.connect(_on_close_pressed)
	details_close_button.pressed.connect(_on_details_close_pressed)
	mail_button.pressed.connect(_on_mail_pressed)
	for key in CANNED_MESSAGES:
		message_option.add_item(CANNED_MESSAGES[key])
	details_panel.hide()
	hide()


func show_postcards() -> void:
	details_panel.hide()
	show()
	await _load_entries()


func _load_entries() -> void:
	for child in entries_container.get_children():
		child.queue_free()

	var rows: Array = await SupabaseClient.get_table(
		"postcard_collection_view",
		"select=id,code,landmark_name,community_name,season,weather,time_of_day,collected_at,status"
		+ "&order=collected_at.desc"
	)

	for row: Dictionary in rows:
		var entry_button := Button.new()
		var status: String = row.get("status", "held")
		entry_button.text = "%s -- %s%s" % [
			row.get("landmark_name", ""), row.get("community_name", ""),
			" (mailed)" if status != "held" else ""
		]
		entry_button.pressed.connect(_on_entry_pressed.bind(row))
		entries_container.add_child(entry_button)

	total_label.text = "Postcards collected: %d" % rows.size()


func _on_entry_pressed(row: Dictionary) -> void:
	_current_postcard_id = row.get("id", "")
	details_name_label.text = row.get("landmark_name", "")
	details_community_label.text = "Community: %s" % row.get("community_name", "")
	details_conditions_label.text = "%s, %s, %s" % [
		row.get("season", ""), row.get("weather", ""), row.get("time_of_day", "")
	]
	details_collected_label.text = "Collected: %s" % row.get("collected_at", "")

	var is_held: bool = row.get("status", "held") == "held"
	mail_controls.visible = is_held
	if is_held:
		await _load_recipients()
	details_panel.show()
	# MailControls' visibility changes this panel's real content height --
	# same fixed-box overflow failure mode already hit once on the
	# Landmark/Atlas panels, avoided here by resizing to fit instead of
	# hardcoding a box tall enough for the largest case.
	details_panel.reset_size()


# Candidate recipients are drawn from collected profile cards -- there's
# no friend list/directory yet, so this is the only way the client knows
# another real wayfinder's id at all.
func _load_recipients() -> void:
	recipient_option.clear()
	_recipient_ids.clear()

	var rows: Array = await SupabaseClient.get_table(
		"profile_card_collection_view", "select=placed_by,placed_by_display_name"
	)
	var seen: Dictionary = {}
	for row: Dictionary in rows:
		var placed_by: String = row.get("placed_by", "")
		if placed_by == "" or seen.has(placed_by):
			continue
		seen[placed_by] = true
		recipient_option.add_item(row.get("placed_by_display_name", "a wayfinder"))
		_recipient_ids.append(placed_by)

	mail_button.disabled = _recipient_ids.is_empty()


func _on_mail_pressed() -> void:
	if _recipient_ids.is_empty():
		return
	var recipient_id: String = _recipient_ids[recipient_option.selected]
	var canned_key: String = CANNED_MESSAGES.keys()[message_option.selected]

	var result: Variant = await SupabaseClient.call_rpc("mail_postcard", {
		"p_postcard_id": _current_postcard_id,
		"p_recipient_id": recipient_id,
		"p_message_kind": "canned",
		"p_canned_message_key": canned_key,
		"p_message_text": null,
	})
	if result is Dictionary and result.is_empty():
		print("Failed to mail postcard %s" % _current_postcard_id)
	else:
		details_panel.hide()
		await _load_entries()


func _on_details_close_pressed() -> void:
	details_panel.hide()


func _on_close_pressed() -> void:
	hide()
	closed.emit()


# Used by main.gd's global Escape handler, same pattern as atlas_ui.gd.
func close_topmost() -> bool:
	if not visible:
		return false
	if details_panel.visible:
		_on_details_close_pressed()
	else:
		_on_close_pressed()
	return true
