extends CanvasLayer

# Postal Network inbox: mail addressed to the current wayfinder that
# hasn't been collected yet (with a Collect button), plus a flat history
# of everything else (sent by me, or already delivered to me) below it.
# Sending itself happens from the Postcards screen (pick a held
# postcard -> pick a recipient from your collected profile cards).

signal closed

const CANNED_MESSAGE_LABELS := {
	"greetings_from": "Greetings from here!",
	"check_out": "You should check this place out!",
}

@onready var panel: PanelContainer = $Panel
@onready var incoming_container: VBoxContainer = $Panel/VBoxContainer/IncomingContainer
@onready var history_container: VBoxContainer = $Panel/VBoxContainer/ScrollContainer/HistoryContainer
@onready var close_button: Button = $Panel/VBoxContainer/CloseButton

var _user_id: String = ""


func _ready() -> void:
	close_button.pressed.connect(_on_close_pressed)
	hide()


func show_mailbox() -> void:
	_user_id = SupabaseClient.user_id
	show()
	await _load_mail()


func _load_mail() -> void:
	for child in incoming_container.get_children():
		child.queue_free()
	for child in history_container.get_children():
		child.queue_free()

	var rows: Array = await SupabaseClient.get_table(
		"postcard_mailings_view",
		"select=mailing_id,sender_id,sender_display_name,recipient_id,recipient_display_name,"
		+ "message_kind,canned_message_key,landmark_name,community_name,mailed_at,delivered_at"
		+ "&order=mailed_at.desc"
	)

	for row: Dictionary in rows:
		var message_text := _message_text(row)
		var recipient_id: String = row.get("recipient_id", "")
		var delivered_at: Variant = row.get("delivered_at")

		if recipient_id == _user_id and delivered_at == null:
			var row_box := HBoxContainer.new()
			var label := Label.new()
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			label.text = "From %s -- %s, %s: \"%s\"" % [
				row.get("sender_display_name", "a wayfinder"),
				row.get("landmark_name", ""), row.get("community_name", ""), message_text
			]
			row_box.add_child(label)

			var collect_button := Button.new()
			collect_button.text = "Collect"
			collect_button.pressed.connect(_on_collect_pressed.bind(row.get("mailing_id", "")))
			row_box.add_child(collect_button)

			incoming_container.add_child(row_box)
		else:
			var entry := Label.new()
			var direction := "To %s" % row.get("recipient_display_name", "a wayfinder") \
				if row.get("sender_id", "") == _user_id \
				else "From %s" % row.get("sender_display_name", "a wayfinder")
			entry.text = "%s -- %s, %s: \"%s\"%s" % [
				direction, row.get("landmark_name", ""), row.get("community_name", ""),
				message_text, "" if delivered_at != null else " (in transit)"
			]
			history_container.add_child(entry)

	if rows.is_empty():
		var empty_label := Label.new()
		empty_label.text = "No mail yet -- mail a postcard from the Postcards screen to get started."
		history_container.add_child(empty_label)

	panel.reset_size()


func _message_text(row: Dictionary) -> String:
	if row.get("message_kind", "") == "freetext":
		return row.get("message_text", "")
	return CANNED_MESSAGE_LABELS.get(row.get("canned_message_key", ""), "")


func _on_collect_pressed(mailing_id: String) -> void:
	var result: Variant = await SupabaseClient.call_rpc("deliver_postcard", {"p_mailing_id": mailing_id})
	if result is Dictionary and result.is_empty():
		print("Failed to collect mail %s" % mailing_id)
	await _load_mail()


func _on_close_pressed() -> void:
	hide()
	closed.emit()


# Used by main.gd's global Escape handler, same pattern as the other UIs.
func close_topmost() -> bool:
	if not visible:
		return false
	_on_close_pressed()
	return true
