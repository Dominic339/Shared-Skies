extends CanvasLayer

# "People in this Community recommend visiting X, here's why" -- not a
# new-Community proposal tool (that's deferred; Community Centers are
# being premade/seeded separately). Pick a Community, see published
# recommendations for it (plus your own still-pending ones), and
# recommend one of that Community's published Landmarks yourself.

signal closed

@onready var panel: PanelContainer = $Panel
@onready var community_option: OptionButton = $Panel/VBoxContainer/CommunityOption
@onready var entries_container: VBoxContainer = $Panel/VBoxContainer/ScrollContainer/EntriesContainer
@onready var landmark_option: OptionButton = $Panel/VBoxContainer/RecommendControls/LandmarkOption
@onready var body_edit: LineEdit = $Panel/VBoxContainer/RecommendControls/BodyEdit
@onready var submit_button: Button = $Panel/VBoxContainer/RecommendControls/SubmitButton
@onready var status_label: Label = $Panel/VBoxContainer/StatusLabel
@onready var close_button: Button = $Panel/VBoxContainer/CloseButton

var _community_ids: Array = []
var _landmark_ids: Array = []


func _ready() -> void:
	community_option.item_selected.connect(_on_community_selected)
	submit_button.pressed.connect(_on_submit_pressed)
	close_button.pressed.connect(_on_close_pressed)
	hide()


func show_recommendations() -> void:
	status_label.text = ""
	show()
	await _load_communities()
	if not _community_ids.is_empty():
		await _load_landmarks_for_community(_community_ids[0])
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
		var community_id: String = _community_ids[index]
		await _load_landmarks_for_community(community_id)
		await _load_entries(community_id)


func _load_landmarks_for_community(community_id: String) -> void:
	landmark_option.clear()
	_landmark_ids.clear()
	# atlas_view (not landmarks_map_view, which has no community_id
	# column) is already correctly scoped to published/seeded Landmarks.
	var rows: Array = await SupabaseClient.get_table(
		"atlas_view", "select=landmark_id,name&community_id=eq.%s&order=name" % community_id
	)
	for row: Dictionary in rows:
		landmark_option.add_item(row.get("name", ""))
		_landmark_ids.append(row.get("landmark_id", ""))
	submit_button.disabled = _landmark_ids.is_empty()


func _load_entries(community_id: String) -> void:
	for child in entries_container.get_children():
		child.queue_free()

	var rows: Array = await SupabaseClient.get_table(
		"community_recommendations_view",
		"select=landmark_name,body,status,author_display_name,created_at"
		+ "&community_id=eq.%s&order=created_at.desc" % community_id
	)

	for row: Dictionary in rows:
		var entry := Label.new()
		var status: String = row.get("status", "published")
		entry.text = "%s -- \"%s\" (by %s)%s" % [
			row.get("landmark_name", ""), row.get("body", ""),
			row.get("author_display_name", "a wayfinder"),
			"" if status == "published" else " [%s]" % status
		]
		entries_container.add_child(entry)


func _on_submit_pressed() -> void:
	if _landmark_ids.is_empty() or _community_ids.is_empty():
		return
	if body_edit.text.strip_edges().length() < 10:
		status_label.text = "Please explain why this Landmark is worth visiting (at least 10 characters)."
		return

	var landmark_id: String = _landmark_ids[landmark_option.selected]
	var community_id: String = _community_ids[community_option.selected]

	var result: Variant = await SupabaseClient.call_rpc("recommend_landmark", {
		"p_landmark_id": landmark_id,
		"p_body": body_edit.text,
	})
	if result is Dictionary and result.is_empty():
		status_label.text = SupabaseClient.last_error_message
	else:
		status_label.text = "Recommendation submitted -- awaiting review."
		body_edit.text = ""
		await _load_entries(community_id)


func _on_close_pressed() -> void:
	hide()
	closed.emit()


# Used by main.gd's global Escape handler, same pattern as the other UIs.
func close_topmost() -> bool:
	if not visible:
		return false
	_on_close_pressed()
	return true
