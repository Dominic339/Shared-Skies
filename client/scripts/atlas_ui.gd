extends CanvasLayer

# Minimal Atlas: "where have I been?" -- every published Landmark grouped
# by Community, visited ones highlighted with their first-visit date,
# unvisited ones present but dimmed (a collection book, not just a visit
# log) so the shared visits table gets a permanent, player-visible home.

signal closed

@onready var panel: PanelContainer = $Panel
@onready var total_visits_label: Label = $Panel/VBoxContainer/TotalVisitsLabel
@onready var entries_container: VBoxContainer = $Panel/VBoxContainer/ScrollContainer/EntriesContainer
@onready var close_button: Button = $Panel/VBoxContainer/CloseButton

@onready var details_panel: PanelContainer = $DetailsPanel
@onready var details_name_label: Label = $DetailsPanel/VBoxContainer/NameLabel
@onready var details_category_label: Label = $DetailsPanel/VBoxContainer/CategoryLabel
@onready var details_code_label: Label = $DetailsPanel/VBoxContainer/CodeLabel
@onready var details_visited_label: Label = $DetailsPanel/VBoxContainer/VisitedLabel
@onready var details_postcard_label: Label = $DetailsPanel/VBoxContainer/PostcardLabel
@onready var details_close_button: Button = $DetailsPanel/VBoxContainer/CloseButton

const VISITED_COLOR := Color(1, 1, 1)
const UNVISITED_COLOR := Color(0.45, 0.45, 0.45)
const COMMUNITY_HEADER_FONT_SIZE := 22


func _ready() -> void:
	close_button.pressed.connect(_on_close_pressed)
	details_close_button.pressed.connect(_on_details_close_pressed)
	details_panel.hide()
	hide()


func show_atlas() -> void:
	details_panel.hide()
	show()
	await _load_entries()


# Single query joining every published Landmark to the calling
# wayfinder's own visit record (see atlas_view migration) -- avoids
# stitching landmarks + visits together client-side.
func _load_entries() -> void:
	for child in entries_container.get_children():
		child.queue_free()

	var rows: Array = await SupabaseClient.get_table(
		"atlas_view",
		"select=landmark_id,code,name,category,community_name,first_visited_at,visited,has_postcard"
		+ "&order=community_name,name"
	)

	var visited_count := 0
	var current_community := ""
	for row: Dictionary in rows:
		var community_name: String = row.get("community_name", "")
		if community_name != current_community:
			current_community = community_name
			var header := Label.new()
			header.text = community_name
			header.add_theme_font_size_override("font_size", COMMUNITY_HEADER_FONT_SIZE)
			entries_container.add_child(header)

		var visited: bool = row.get("visited", false)
		if visited:
			visited_count += 1

		var entry_button := Button.new()
		entry_button.text = row.get("name", "")
		entry_button.modulate = VISITED_COLOR if visited else UNVISITED_COLOR
		entry_button.pressed.connect(_on_entry_pressed.bind(row))
		entries_container.add_child(entry_button)

	total_visits_label.text = "Landmarks visited: %d" % visited_count


func _on_entry_pressed(row: Dictionary) -> void:
	details_name_label.text = row.get("name", "")
	details_category_label.text = "Category: %s" % row.get("category", "")
	details_code_label.text = row.get("code", "")
	if row.get("visited", false):
		details_visited_label.text = "First visited: %s" % row.get("first_visited_at", "")
	else:
		details_visited_label.text = "Not yet visited"
	details_postcard_label.text = (
		"Postcard collected" if row.get("has_postcard", false) else "No postcard yet"
	)
	details_panel.show()


func _on_details_close_pressed() -> void:
	details_panel.hide()


func _on_close_pressed() -> void:
	hide()
	closed.emit()
