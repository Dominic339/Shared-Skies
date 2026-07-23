extends CanvasLayer

# Minimal postcard collection browser -- gives the postcard system (auto-
# created on first Landmark visit) an actual place to be seen, instead of
# dead-ending at a single "Postcard collected" line in the Atlas details
# panel. No postcard artwork exists yet (artwork_render_url is null until
# that pipeline is built), so entries show the placeholder season/
# weather/time_of_day + collected date rather than an image.

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
@onready var details_close_button: Button = $DetailsPanel/VBoxContainer/CloseButton


func _ready() -> void:
	close_button.pressed.connect(_on_close_pressed)
	details_close_button.pressed.connect(_on_details_close_pressed)
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
		"select=code,landmark_name,community_name,season,weather,time_of_day,collected_at"
		+ "&order=collected_at.desc"
	)

	for row: Dictionary in rows:
		var entry_button := Button.new()
		entry_button.text = "%s -- %s" % [row.get("landmark_name", ""), row.get("community_name", "")]
		entry_button.pressed.connect(_on_entry_pressed.bind(row))
		entries_container.add_child(entry_button)

	total_label.text = "Postcards collected: %d" % rows.size()


func _on_entry_pressed(row: Dictionary) -> void:
	details_name_label.text = row.get("landmark_name", "")
	details_community_label.text = "Community: %s" % row.get("community_name", "")
	details_conditions_label.text = "%s, %s, %s" % [
		row.get("season", ""), row.get("weather", ""), row.get("time_of_day", "")
	]
	details_collected_label.text = "Collected: %s" % row.get("collected_at", "")
	details_panel.show()


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
