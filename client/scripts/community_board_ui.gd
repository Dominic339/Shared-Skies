extends CanvasLayer

# Minimal Community Board: a plain list of every Community's bounty with
# a Claim button, gated by whether the requirement is currently met and
# whether it's already been claimed. This will eventually be a proper
# in-world menu inside each Community's community center -- this flat
# list is deliberately just the functional version until that visual
# piece gets built (same "functionality first" call already made for
# the sign board and Atlas book).

signal closed

@onready var panel: PanelContainer = $Panel
@onready var entries_container: VBoxContainer = $Panel/VBoxContainer/ScrollContainer/EntriesContainer
@onready var close_button: Button = $Panel/VBoxContainer/CloseButton


func _ready() -> void:
	close_button.pressed.connect(_on_close_pressed)
	hide()


func show_board() -> void:
	show()
	await _load_bounties()


func _load_bounties() -> void:
	for child in entries_container.get_children():
		child.queue_free()

	var rows: Array = await SupabaseClient.get_table(
		"community_bounty_status_view",
		"select=bounty_id,community_name,title,description,reward_amount,claimed,requirement_met"
		+ "&order=community_name"
	)

	for row: Dictionary in rows:
		var row_box := HBoxContainer.new()
		var label := Label.new()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var claimed: bool = row.get("claimed", false)
		var requirement_met: bool = row.get("requirement_met", false)
		var status := "claimed" if claimed else ("ready" if requirement_met else "not yet met")
		label.text = "%s -- %s (%d Waymarks) [%s]" % [
			row.get("community_name", ""), row.get("title", ""), row.get("reward_amount", 0), status
		]
		row_box.add_child(label)

		if not claimed:
			var claim_button := Button.new()
			claim_button.text = "Claim"
			claim_button.disabled = not requirement_met
			claim_button.pressed.connect(_on_claim_pressed.bind(row.get("bounty_id", "")))
			row_box.add_child(claim_button)

		entries_container.add_child(row_box)


func _on_claim_pressed(bounty_id: String) -> void:
	var result: Variant = await SupabaseClient.call_rpc("claim_bounty", {"p_bounty_id": bounty_id})
	if result is Dictionary and result.is_empty():
		print("Failed to claim bounty %s" % bounty_id)
	await _load_bounties()


func _on_close_pressed() -> void:
	hide()
	closed.emit()


# Used by main.gd's global Escape handler, same pattern as the other UIs.
func close_topmost() -> bool:
	if not visible:
		return false
	_on_close_pressed()
	return true
