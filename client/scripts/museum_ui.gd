extends CanvasLayer

# Minimal Museum donation loop: pick a Community, see what's been
# donated there (with donor credit) vs. still missing, and donate one of
# your own eligible items to fill a missing slot. An item's exhibit slot
# only comes into existence at the moment of its first successful
# donation -- there's no curation tool yet deciding which items each
# Community "wants," so "missing" just means "not yet donated here"
# across every published, donatable item definition.

signal closed

@onready var panel: PanelContainer = $Panel
@onready var community_option: OptionButton = $Panel/VBoxContainer/CommunityOption
@onready var entries_container: VBoxContainer = $Panel/VBoxContainer/ScrollContainer/EntriesContainer
@onready var item_option: OptionButton = $Panel/VBoxContainer/DonateControls/ItemOption
@onready var donate_button: Button = $Panel/VBoxContainer/DonateControls/DonateButton
@onready var dev_item_option: OptionButton = $Panel/VBoxContainer/DevControls/DevItemOption
@onready var dev_grant_button: Button = $Panel/VBoxContainer/DevControls/DevGrantButton
@onready var close_button: Button = $Panel/VBoxContainer/CloseButton

var _community_ids: Array = []
var _item_instance_ids: Array = []
var _dev_item_definition_ids: Array = []


func _ready() -> void:
	community_option.item_selected.connect(_on_community_selected)
	donate_button.pressed.connect(_on_donate_pressed)
	dev_grant_button.pressed.connect(_on_dev_grant_pressed)
	close_button.pressed.connect(_on_close_pressed)
	hide()


func show_museum() -> void:
	show()
	await _load_communities()
	await _load_donatable_items()
	await _load_dev_items()
	if not _community_ids.is_empty():
		await _load_progress(_community_ids[0])


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
		await _load_progress(_community_ids[index])


func _load_progress(community_id: String) -> void:
	for child in entries_container.get_children():
		child.queue_free()

	var rows: Array = await SupabaseClient.get_table(
		"museum_progress_view",
		"select=item_name,category,donated,donor_display_name,donated_at"
		+ "&community_id=eq.%s&order=item_name" % community_id
	)

	for row: Dictionary in rows:
		var entry := Label.new()
		var donated: bool = row.get("donated", false)
		if donated:
			entry.text = "✓ %s -- donated by %s" % [
				row.get("item_name", ""), row.get("donor_display_name", "a wayfinder")
			]
		else:
			entry.text = "○ %s" % row.get("item_name", "")
		entries_container.add_child(entry)

	panel.reset_size()


func _load_donatable_items() -> void:
	item_option.clear()
	_item_instance_ids.clear()
	var rows: Array = await SupabaseClient.get_table(
		"my_donatable_items_view", "select=item_instance_id,item_name"
	)
	for row: Dictionary in rows:
		item_option.add_item(row.get("item_name", ""))
		_item_instance_ids.append(row.get("item_instance_id", ""))
	donate_button.disabled = _item_instance_ids.is_empty()


func _on_donate_pressed() -> void:
	if _item_instance_ids.is_empty() or _community_ids.is_empty():
		return
	var item_instance_id: String = _item_instance_ids[item_option.selected]
	var community_id: String = _community_ids[community_option.selected]

	var result: Variant = await SupabaseClient.call_rpc("donate_to_museum", {
		"p_item_instance_id": item_instance_id,
		"p_community_id": community_id,
	})
	if result is Dictionary and result.is_empty():
		print("Failed to donate item %s" % item_instance_id)
	else:
		await _load_donatable_items()
		await _load_progress(community_id)


# Dev-only -- lets the donation loop be tested without a real item-
# discovery system yet. Gated server-side by dev_grant_item()'s own
# allowlist check (profiles.dev_grants_enabled) -- hiding this button in
# a release build would not be what actually protects it.
func _load_dev_items() -> void:
	dev_item_option.clear()
	_dev_item_definition_ids.clear()
	var rows: Array = await SupabaseClient.get_table(
		"item_definitions",
		"select=id,name&publication_state=eq.published&category=in.(souvenir,decoration,token)&order=name"
	)
	for row: Dictionary in rows:
		dev_item_option.add_item(row.get("name", ""))
		_dev_item_definition_ids.append(row.get("id", ""))
	dev_grant_button.disabled = _dev_item_definition_ids.is_empty()


func _on_dev_grant_pressed() -> void:
	if _dev_item_definition_ids.is_empty():
		return
	var item_definition_id: String = _dev_item_definition_ids[dev_item_option.selected]
	var result: Variant = await SupabaseClient.call_rpc("dev_grant_item", {
		"p_item_definition_id": item_definition_id,
	})
	if result is Dictionary and result.is_empty():
		print("Dev item grant failed -- account not allowlisted?")
	else:
		await _load_donatable_items()


func _on_close_pressed() -> void:
	hide()
	closed.emit()


# Used by main.gd's global Escape handler, same pattern as the other UIs.
func close_topmost() -> bool:
	if not visible:
		return false
	_on_close_pressed()
	return true
