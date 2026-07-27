extends CanvasLayer

# Appears attached to the tapped sign's screen position (a callout above
# it) rather than as an unrelated fixed-corner menu -- tracks the sign
# every frame while open, since the camera can still be dragged/zoomed
# while a Landmark is focused.

signal closed

const SCREEN_MARGIN_ABOVE_SIGN := 40.0

@onready var panel: PanelContainer = $Panel
@onready var name_label: Label = $Panel/VBoxContainer/NameLabel
@onready var category_label: Label = $Panel/VBoxContainer/CategoryLabel
@onready var code_label: Label = $Panel/VBoxContainer/CodeLabel
@onready var description_label: Label = $Panel/VBoxContainer/DescriptionLabel
@onready var card_slots_container: VBoxContainer = $Panel/VBoxContainer/CardSlotsContainer
@onready var recommend_button: Button = $Panel/VBoxContainer/RecommendButton
@onready var recommend_status_label: Label = $Panel/VBoxContainer/RecommendStatusLabel
@onready var close_button: Button = $Panel/VBoxContainer/CloseButton

var _camera: Camera3D = null
var _marker: LandmarkMarker = null
var _has_recommended: bool = false
var _board_overlay: CanvasLayer = null


func _ready() -> void:
	close_button.pressed.connect(_on_close_pressed)
	recommend_button.pressed.connect(_on_recommend_pressed)
	hide()


# Wired once by main.gd -- lets actions taken here (recommend, leave/
# collect a card) refresh the ambient board overlay's badges if it
# happens to be showing this same Landmark right now.
func set_board_overlay(board_overlay: CanvasLayer) -> void:
	_board_overlay = board_overlay


func show_landmark(marker: LandmarkMarker, camera: Camera3D) -> void:
	_marker = marker
	_camera = camera
	name_label.text = marker.landmark_name
	category_label.text = "Category: %s" % marker.category
	code_label.text = marker.code
	show()
	_update_position()
	await _load_description()
	await _load_card_slots()
	await _load_recommendation_state()


# The board's own physical sign only ever shows the SHORT description
# (see landmark_board_face.gd) -- tapping the sign to open this panel
# is "reading more": show the long version outright here rather than
# adding a separate expand/collapse toggle, since there's already
# plenty of room in this popup and no board-face space constraint to
# work around.
func _load_description() -> void:
	description_label.text = ""
	if _marker == null:
		return

	var rows: Array = await SupabaseClient.get_table(
		"landmark_board_view",
		"select=short_description,long_description&id=eq.%s" % _marker.landmark_id
	)
	if rows.is_empty():
		return

	var long_description: Variant = rows[0].get("long_description")
	var short_description: Variant = rows[0].get("short_description")
	if long_description != null and long_description != "":
		description_label.text = long_description
	elif short_description != null and short_description != "":
		description_label.text = short_description


func _process(_delta: float) -> void:
	if visible and _marker != null and _camera != null:
		_update_position()


func _update_position() -> void:
	# Anchor above the sign's actual top (real measured height, not the
	# marker's ground-level origin) -- anchoring to ground let the panel
	# increasingly overlap the sign as it got bigger/closer on screen.
	var anchor := _marker.global_position + Vector3(0, LandmarkMarker.STRUCTURE_TOP_HEIGHT_METERS, 0)
	var screen_point := _camera.unproject_position(anchor)
	var target_bottom_y := screen_point.y - SCREEN_MARGIN_ABOVE_SIGN
	panel.position = Vector2(screen_point.x - panel.size.x / 2.0, target_bottom_y - panel.size.y)


const OWN_CARD_COLOR := Color(1, 0.85, 0.3)
const COLLECTED_COLOR := Color(0.45, 0.45, 0.45)


# Rebuilds the card-holder rows from scratch every time the panel opens
# (rather than diffing) -- slot occupancy changes from OTHER players too
# (someone else leaving/collecting), so a stale cached view would be
# actively wrong, and there are only ever a handful of slots per Landmark.
func _load_card_slots() -> void:
	for child in card_slots_container.get_children():
		child.queue_free()

	if _marker == null:
		return

	var rows: Array = await SupabaseClient.get_table(
		"profile_card_slots_view",
		(
			"select=slot_id,landmark_id,slot_index,placement_id,placed_by,"
			+ "placed_by_display_name,remaining_copies,occupied,is_own_card,already_collected"
			+ "&landmark_id=eq.%s&order=slot_index" % _marker.landmark_id
		)
	)

	# A wayfinder may only have one active placement per Landmark (enforced
	# DB-side too, see profile_card_placements_active_landmark_idx) -- if
	# any slot already carries their card, every empty slot's "Leave My
	# Card" button should be disabled rather than letting the request round
	# -trip just to be rejected by RLS/the unique index.
	var already_placed_here := rows.any(func(r: Dictionary) -> bool: return r.get("is_own_card", false))

	for row: Dictionary in rows:
		var row_box := HBoxContainer.new()
		var state_label := Label.new()
		state_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row_box.add_child(state_label)

		var occupied: bool = row.get("occupied", false)
		if not occupied:
			state_label.text = "Slot %d: empty" % (row.get("slot_index", 0) + 1)
			var leave_button := Button.new()
			leave_button.text = "Leave My Card"
			leave_button.disabled = already_placed_here or not _marker.in_range
			leave_button.pressed.connect(_on_leave_card_pressed.bind(row.get("slot_id", "")))
			row_box.add_child(leave_button)
		elif row.get("is_own_card", false):
			state_label.text = "Slot %d: your card (%d left)" % [
				row.get("slot_index", 0) + 1, row.get("remaining_copies", 0)
			]
			state_label.modulate = OWN_CARD_COLOR
		else:
			var placer_name: String = row.get("placed_by_display_name", "a wayfinder")
			var collected: bool = row.get("already_collected", false)
			state_label.text = "Slot %d: %s's card%s" % [
				row.get("slot_index", 0) + 1, placer_name, " (collected)" if collected else ""
			]
			if collected:
				state_label.modulate = COLLECTED_COLOR
			else:
				var collect_button := Button.new()
				collect_button.text = "Collect"
				collect_button.disabled = not _marker.in_range
				collect_button.pressed.connect(_on_collect_card_pressed.bind(row.get("placement_id", "")))
				row_box.add_child(collect_button)

		card_slots_container.add_child(row_box)

	# The panel's rect is otherwise fixed (authored in Main.tscn, not
	# inside a layout Container that would auto-fit it) -- reset_size()
	# recomputes it from the children's actual minimum size now that the
	# slot count is known, instead of a hardcoded box that's either too
	# cramped for a Landmark with more slots or wastefully empty for one
	# with fewer. Same overflow failure mode the Atlas panel's CloseButton
	# hit earlier, avoided here by not hardcoding a height at all.
	panel.reset_size()
	_update_position()


# "Recommend this place" is a simple unique vote made from right here
# (you're already looking at the Landmark), not a separate pick-from-a-
# list screen -- requires having actually visited it first, one active
# vote per player per Landmark (both checked server-side too, see
# recommend_landmark()/unrecommend_landmark()). Text reviews are a
# separate, not-yet-built feature; this is purely the ranking signal
# that feeds the Community Center's Recommended Places board.
func _load_recommendation_state() -> void:
	recommend_status_label.text = ""
	if _marker == null:
		return

	recommend_button.disabled = not _marker.visited
	if not _marker.visited:
		recommend_status_label.text = "Visit this Landmark before recommending it."

	var rows: Array = await SupabaseClient.get_table(
		"community_recommendations_view",
		(
			"select=id&landmark_id=eq.%s&author_wayfinder_id=eq.%s&status=eq.published"
			% [_marker.landmark_id, SupabaseClient.user_id]
		)
	)
	_has_recommended = not rows.is_empty()
	recommend_button.text = "Remove Recommendation" if _has_recommended else "Recommend This Place"


func _on_recommend_pressed() -> void:
	if _marker == null:
		return

	var result: Variant
	if _has_recommended:
		result = await SupabaseClient.call_rpc("unrecommend_landmark", {"p_landmark_id": _marker.landmark_id})
	else:
		result = await SupabaseClient.call_rpc("recommend_landmark", {"p_landmark_id": _marker.landmark_id})

	if result is Dictionary and result.is_empty():
		recommend_status_label.text = SupabaseClient.last_error_message
	else:
		await _load_recommendation_state()
		_board_overlay.refresh_if_showing(_marker)


func _on_leave_card_pressed(slot_id: String) -> void:
	var row := await SupabaseClient.insert_row("profile_card_placements", {
		"slot_id": slot_id,
		"placed_by": SupabaseClient.user_id,
	})
	if row.is_empty():
		print("Failed to leave card in slot %s" % slot_id)
	await _load_card_slots()
	_board_overlay.refresh_if_showing(_marker)
	# The marker's own physical card objects are a separate fetch from this
	# popup's slot list -- without this, a card left/collected here would
	# leave the 3D holder showing stale (or no) card until something else
	# happened to refresh it.
	await _marker.refresh_card_slots()


func _on_collect_card_pressed(placement_id: String) -> void:
	var row := await SupabaseClient.insert_row("profile_card_collections", {
		"placement_id": placement_id,
		"collected_by": SupabaseClient.user_id,
	})
	if row.is_empty():
		print("Failed to collect card for placement %s" % placement_id)
	await _load_card_slots()
	_board_overlay.refresh_if_showing(_marker)
	await _marker.refresh_card_slots()


# Called by main.gd when a direct in-world action (a tap on the physical
# sign, not this popup) changed this same Landmark's own card slots --
# e.g. the quick-collect button, or tapping a card directly.
func refresh_card_slots_if_showing(marker: LandmarkMarker) -> void:
	if _marker == marker:
		await _load_card_slots()


func _on_close_pressed() -> void:
	hide()
	_marker = null
	closed.emit()


# Used by main.gd's global Escape handler. Returns whether it actually
# closed anything.
func close_topmost() -> bool:
	if not visible:
		return false
	_on_close_pressed()
	return true
