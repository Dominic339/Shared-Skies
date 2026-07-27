extends CanvasLayer

# "Recommended Places" board -- the top most-Favorited Landmarks in a
# Community, read-only. Favoriting itself now happens from the board
# overlay of a visited Landmark (landmark_board_overlay.gd's star button,
# still backed by the same recommend_landmark()/unrecommend_landmark()
# vote this screen ranks), not here -- this screen is purely the second
# Community Center board GPT/Dominic described, showing the ranking that
# produces.
#
# How many entries show is community_centers.recommendation_slot_count,
# not a number hardcoded here -- Community Centers are already planned
# to grow through tiers (a wooden sign -> a board -> a full visitor
# center) as a Community gets more active, and that progression will
# update this column later. No such progression system exists yet, so
# it stays at its seeded default (3) everywhere for now.

signal closed

const DEFAULT_SLOT_COUNT := 3

@onready var panel: PanelContainer = $Panel
@onready var community_option: OptionButton = $Panel/VBoxContainer/CommunityOption
@onready var entries_container: VBoxContainer = $Panel/VBoxContainer/ScrollContainer/EntriesContainer
@onready var close_button: Button = $Panel/VBoxContainer/CloseButton

var _community_ids: Array = []


func _ready() -> void:
	community_option.item_selected.connect(_on_community_selected)
	close_button.pressed.connect(_on_close_pressed)
	hide()


func show_recommendations() -> void:
	show()
	await _load_communities()
	if not _community_ids.is_empty():
		await _load_entries(_community_ids[0])


func _load_communities() -> void:
	community_option.clear()
	_community_ids.clear()
	var rows: Array = await SupabaseClient.get_table(
		"communities", "select=id,name&publication_state=eq.published&order=name"
	)
	for row: Dictionary in rows:
		community_option.add_item(row.get("name", ""))
		_community_ids.append(row.get("id", ""))


func _on_community_selected(index: int) -> void:
	if index >= 0 and index < _community_ids.size():
		await _load_entries(_community_ids[index])


func _load_slot_count(community_id: String) -> int:
	var rows: Array = await SupabaseClient.get_table(
		"community_centers_view", "select=recommendation_slot_count&community_id=eq.%s" % community_id
	)
	if rows.is_empty():
		return DEFAULT_SLOT_COUNT
	return int(rows[0].get("recommendation_slot_count", DEFAULT_SLOT_COUNT))


func _load_entries(community_id: String) -> void:
	for child in entries_container.get_children():
		child.queue_free()

	var slot_count := await _load_slot_count(community_id)

	var rows: Array = await SupabaseClient.get_table(
		"community_top_recommendations_view",
		(
			"select=landmark_name,landmark_category,recommendation_count"
			+ "&community_id=eq.%s&order=recommendation_count.desc&limit=%d" % [community_id, slot_count]
		)
	)

	if rows.is_empty():
		var empty_label := Label.new()
		empty_label.text = "No recommended Landmarks yet -- recommend one from its info panel after visiting!"
		entries_container.add_child(empty_label)
		return

	for row: Dictionary in rows:
		var entry := Label.new()
		entry.text = "%s (%s) -- recommended %d time(s)" % [
			row.get("landmark_name", ""), row.get("landmark_category", ""), row.get("recommendation_count", 0)
		]
		entries_container.add_child(entry)


func _on_close_pressed() -> void:
	hide()
	closed.emit()


# Used by main.gd's global Escape handler, same pattern as the other UIs.
func close_topmost() -> bool:
	if not visible:
		return false
	_on_close_pressed()
	return true
