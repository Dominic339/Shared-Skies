extends CanvasLayer

# Temporary flat Stamp Desk screen -- opened from a specific Community
# Center (see community_center_ui.gd) and scoped to THAT Center's own
# Community, rather than a picker across every Community the way
# Museum/Board/Recommended Places have -- collecting is proximity-gated
# to the correct Center anyway (collect_stamp() checks server-side), so
# a picker letting you select a different Community while standing here
# would just always fail. Shows every published Stamp for this
# Community (currently always exactly one) with collected/missing state.

signal closed

@onready var panel: PanelContainer = $Panel
@onready var entries_container: VBoxContainer = $Panel/VBoxContainer/ScrollContainer/EntriesContainer
@onready var status_label: Label = $Panel/VBoxContainer/StatusLabel
@onready var close_button: Button = $Panel/VBoxContainer/CloseButton

var _community_id: String = ""


func _ready() -> void:
	close_button.pressed.connect(_on_close_pressed)
	hide()


func show_stamp_desk(community_id: String) -> void:
	_community_id = community_id
	status_label.text = ""
	show()
	await _load_stamps()


func _load_stamps() -> void:
	for child in entries_container.get_children():
		child.queue_free()

	var rows: Array = await SupabaseClient.get_table(
		"stamp_progress_view",
		(
			"select=stamp_definition_id,stamp_name,description,collected,collected_at"
			+ "&community_id=eq.%s&order=stamp_name" % _community_id
		)
	)

	for row: Dictionary in rows:
		var row_box := HBoxContainer.new()
		var label := Label.new()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var collected: bool = row.get("collected", false)
		if collected:
			label.text = "%s -- collected %s" % [row.get("stamp_name", ""), row.get("collected_at", "")]
		else:
			label.text = "%s -- not yet collected" % row.get("stamp_name", "")
		row_box.add_child(label)

		if not collected:
			var collect_button := Button.new()
			collect_button.text = "Collect"
			collect_button.pressed.connect(_on_collect_pressed.bind(row.get("stamp_definition_id", "")))
			row_box.add_child(collect_button)

		entries_container.add_child(row_box)


func _on_collect_pressed(stamp_definition_id: String) -> void:
	var result: Variant = await SupabaseClient.call_rpc("collect_stamp", {
		"p_stamp_definition_id": stamp_definition_id,
		"p_lat": DevLocation.current_lat,
		"p_lng": DevLocation.current_lng,
	})
	if result is Dictionary and result.is_empty():
		status_label.text = SupabaseClient.last_error_message
	else:
		status_label.text = "Stamp collected!"
		await _load_stamps()


func _on_close_pressed() -> void:
	hide()
	closed.emit()


# Used by main.gd's global Escape handler, same pattern as the other UIs.
func close_topmost() -> bool:
	if not visible:
		return false
	_on_close_pressed()
	return true
