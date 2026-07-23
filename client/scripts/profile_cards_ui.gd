extends CanvasLayer

# Minimal "cards I've collected from other wayfinders" browser -- the
# collection-facing half of the profile card loop, distinct from the
# Atlas (places visited) and Postcards (souvenirs from your own first
# visits). Mirrors postcards_ui.gd's structure. Cards you've LEFT for
# others aren't shown here -- their state already lives on the
# Landmark's own card holders (see landmark_display_ui.gd).

signal closed

@onready var panel: PanelContainer = $Panel
@onready var total_label: Label = $Panel/VBoxContainer/TotalLabel
@onready var entries_container: VBoxContainer = $Panel/VBoxContainer/ScrollContainer/EntriesContainer
@onready var close_button: Button = $Panel/VBoxContainer/CloseButton

@onready var details_panel: PanelContainer = $DetailsPanel
@onready var details_name_label: Label = $DetailsPanel/VBoxContainer/NameLabel
@onready var details_from_label: Label = $DetailsPanel/VBoxContainer/FromLabel
@onready var details_collected_label: Label = $DetailsPanel/VBoxContainer/CollectedLabel
@onready var details_close_button: Button = $DetailsPanel/VBoxContainer/CloseButton


func _ready() -> void:
	close_button.pressed.connect(_on_close_pressed)
	details_close_button.pressed.connect(_on_details_close_pressed)
	details_panel.hide()
	hide()


func show_profile_cards() -> void:
	details_panel.hide()
	show()
	await _load_entries()


func _load_entries() -> void:
	for child in entries_container.get_children():
		child.queue_free()

	var rows: Array = await SupabaseClient.get_table(
		"profile_card_collection_view",
		"select=landmark_name,landmark_code,placed_by_display_name,collected_at"
		+ "&order=collected_at.desc"
	)

	for row: Dictionary in rows:
		var entry_button := Button.new()
		entry_button.text = "%s -- from %s" % [
			row.get("landmark_name", ""), row.get("placed_by_display_name", "a wayfinder")
		]
		entry_button.pressed.connect(_on_entry_pressed.bind(row))
		entries_container.add_child(entry_button)

	total_label.text = "Profile cards collected: %d" % rows.size()


func _on_entry_pressed(row: Dictionary) -> void:
	details_name_label.text = row.get("landmark_name", "")
	details_from_label.text = "From: %s" % row.get("placed_by_display_name", "a wayfinder")
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
