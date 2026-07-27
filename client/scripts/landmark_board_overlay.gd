extends CanvasLayer

# The kiosk board's presentation content AND every interaction a player
# needs while looking at a Landmark -- description, tags, visited/favorite
# state, collecting/leaving a profile card. This used to share the screen
# with a separate dev-style popup that duplicated some of this; that popup
# is gone now; everything lives here, on the one UI meant to represent
# "looking at the sign itself." Shown once a
# Landmark is focused (tapped), not while just walking past it in range;
# an earlier version showed on proximity instead, but that made it pop up
# during ordinary exploration rather than only when you actually stop to
# look at a sign. A single 2D screen-space overlay reused for whatever
# marker is currently focused, not a 3D texture baked per-marker -- this
# sidesteps two problems a first attempt at a 3D-projected board hit: no
# blind 3D-mesh-alignment guesswork (this reuses the exact same
# camera.unproject_position() screen-anchoring technique already proven
# working elsewhere), and no need to ever render more than one of these
# regardless of how many signs happen to be nearby simultaneously.

signal closed

const TAG_LABELS := {
	"wheelchair_accessible": "Wheelchair Accessible",
	"family_friendly": "Family Friendly",
	"historic": "Historic",
	"scenic": "Scenic",
	"outdoors": "Outdoors",
	"good_for_photos": "Good for Photos",
	"pet_friendly": "Pet Friendly",
}

# Every piece below lives in its own fixed-rect box directly under Panel
# (a plain Panel, not a PanelContainer/VBoxContainer/HBoxContainer chain)
# -- each box's position/size is authored explicitly in Main.tscn instead
# of being computed by a parent container from its children's content.
# The previous auto-fit layout hit a real Godot layout trap: an autowrap
# Label's minimum-size negotiation inside an HBoxContainer collapsed to a
# near-zero width, which ballooned its height, which then stretched a
# sibling TextureRect to match. Fixed-rect boxes sidestep that whole class
# of bug -- each element just clips/wraps within its own authored rect,
# regardless of how long its content happens to be.
@onready var panel: Panel = $Panel
@onready var title_label: Label = $Panel/HeaderPanel/TitleLabel
@onready var subtitle_label: Label = $Panel/HeaderPanel/SubtitleLabel
@onready var leave_card_button: Button = $Panel/HeaderPanel/LeaveCardButton
@onready var collect_button: Button = $Panel/HeaderPanel/CollectButton
@onready var close_button: Button = $Panel/HeaderPanel/CloseButton
@onready var photo_rect: TextureRect = $Panel/PhotoRect
@onready var description_label: RichTextLabel = $Panel/DescriptionLabel
@onready var favorite_button: Button = $Panel/FavoriteButton
# Tags (wheelchair accessible, historic, etc.) sit bottom-left; status
# badges (Visited, Favorited, Card available) sit bottom-right -- two
# separate fixed-rect boxes rather than one shared row, since a single
# mixed row read as one big pile with no clear grouping.
@onready var tag_row: HFlowContainer = $Panel/TagRow
@onready var badge_row: HFlowContainer = $Panel/BadgeRow

var _marker: LandmarkMarker = null
var _camera: Camera3D = null
# Both fetched together in _load_data() -- _set_description_display() just
# swaps which one is on screen, no extra round-trip needed.
var _short_description: String = ""
var _long_description: String = ""
var _showing_long_description: bool = false
var _is_favorited: bool = false
var _has_empty_slot: bool = false
var _already_placed_card: bool = false


func _ready() -> void:
	hide()
	leave_card_button.pressed.connect(_on_leave_card_pressed)
	collect_button.pressed.connect(_on_collect_pressed)
	close_button.pressed.connect(_on_close_pressed)
	favorite_button.pressed.connect(_on_favorite_pressed)
	description_label.meta_clicked.connect(_on_description_meta_clicked)


# Called from main.gd's tap handler.
func show_for(marker: LandmarkMarker, camera: Camera3D) -> void:
	_camera = camera
	if _marker == marker:
		return
	_marker = marker
	show()
	_update_position()
	await _load_data()


func hide_overlay() -> void:
	_marker = null
	hide()


func _on_close_pressed() -> void:
	hide_overlay()
	closed.emit()


# Used by main.gd's global Escape handler, same pattern every other panel
# in this game already follows. Returns whether it actually closed anything.
func close_topmost() -> bool:
	if not visible:
		return false
	_on_close_pressed()
	return true


# Re-fetches without changing which marker is targeted -- called after
# an action (recommend, collect a card) that might change this same
# Landmark's own badges.
func refresh_if_showing(marker: LandmarkMarker) -> void:
	if _marker == marker:
		await _load_data()


func _process(_delta: float) -> void:
	if visible and _marker != null and _camera != null:
		_update_position()


# Only a fraction of the panel's width sits to the left of the anchor
# (not the full width) -- keeps it mostly beside the sign rather than
# pushed entirely off to the left of it.
const LEFT_OVERLAP_FRACTION := 0.48
const SIDE_GAP_FROM_SIGN := 12.0
# Extra drop below the sign's structure-top anchor, on top of the
# top-anchoring below -- pushes the whole panel further down the screen,
# away from the corner UI/popup crowding near the anchor height itself.
const VERTICAL_DROP := 82.0


func _update_position() -> void:
	var anchor := _marker.global_position + Vector3(0, LandmarkMarker.STRUCTURE_TOP_HEIGHT_METERS, 0)
	var screen_point := _camera.unproject_position(anchor)
	# Mostly to the LEFT of the sign's anchor point, not stacked above it,
	# since that's the anchor the sign's own top edge sits at too.
	#
	# Top-anchored at the sign's structure height (plus VERTICAL_DROP),
	# extending DOWNWARD from there -- vertically centering on an anchor
	# that's already near the top of the sign pushed half the panel even
	# higher, overlapping the corner UI. Anchoring the top edge here
	# instead keeps it lower on screen regardless of the panel's own height.
	panel.position = Vector2(
		screen_point.x - panel.size.x * LEFT_OVERLAP_FRACTION - SIDE_GAP_FROM_SIGN,
		screen_point.y + VERTICAL_DROP
	)


func _load_data() -> void:
	if _marker == null:
		return
	var landmark_id := _marker.landmark_id

	var rows: Array = await SupabaseClient.get_table(
		"landmark_board_view",
		(
			"select=name,category,community_name,short_description,long_description,tags,"
			+ "cover_image_url,visited,recommendation_count&id=eq.%s" % landmark_id
		)
	)
	# The target may have changed (or the overlay closed) while this
	# request was in flight -- don't clobber whatever's showing now with
	# a stale response for a Landmark we've already moved on from.
	if rows.is_empty() or _marker == null or _marker.landmark_id != landmark_id:
		return
	var data: Dictionary = rows[0]

	title_label.text = data.get("name", "")
	subtitle_label.text = "%s · %s" % [
		String(data.get("category", "")).capitalize(), data.get("community_name", "")
	]
	var short_description: Variant = data.get("short_description")
	var long_description: Variant = data.get("long_description")
	_short_description = short_description if short_description != null else ""
	_long_description = long_description if long_description != null else _short_description
	# Always re-collapse on a fresh load (a new Landmark, or a refresh of
	# this same one) -- otherwise refresh_if_showing() after some unrelated
	# action (a favorite toggle) would keep an expanded description
	# expanded even though nothing asked for that.
	_showing_long_description = false
	_set_description_display()

	_load_photo(data.get("cover_image_url"))

	for child in tag_row.get_children():
		child.queue_free()
	for child in badge_row.get_children():
		child.queue_free()
	_populate_tags(data.get("tags", []))

	var slot_summary := await _fetch_card_slot_summary(landmark_id)
	if _marker == null or _marker.landmark_id != landmark_id:
		return
	_has_empty_slot = slot_summary.has_empty_slot
	_already_placed_card = slot_summary.already_placed_card
	_populate_badges(data.get("visited", false), data.get("recommendation_count", 0), slot_summary.has_collectible_card)
	collect_button.disabled = not slot_summary.has_collectible_card or not _marker.in_range
	leave_card_button.disabled = _already_placed_card or not _has_empty_slot or not _marker.in_range

	await _load_favorite_state()
	if _marker == null or _marker.landmark_id != landmark_id:
		return

	_update_position()


const READ_MORE_LINK_COLOR := Color(0.68, 0.82, 1.0)

# The description's own box when collapsed (its normal, authored size in
# Main.tscn) vs. expanded to take over the space TagRow/BadgeRow/
# FavoriteButton would otherwise occupy -- there's nowhere else on this
# fixed-rect panel to put a much longer long_description without either
# cutting it off or overlapping something, so expanding "into" the space
# below (hiding those pieces while it does) is what actually fits.
const DESCRIPTION_RECT_COLLAPSED := Rect2(332, 68, 482, 150)
const DESCRIPTION_RECT_EXPANDED := Rect2(332, 68, 482, 376)


# Appends a clickable "Read more..."/"Show less" link right after the
# description text itself (BBCode [url], via meta_clicked below) -- this
# used to be a hotspot on the physical 3D sign, but the sign's flat board
# has no printed text or button art on it at all, so a 3D hotspot there
# wasn't actually discoverable as an interaction; a link at the end of the
# text it belongs to is.
func _set_description_display() -> void:
	var body := _long_description if _showing_long_description else _short_description
	var escaped := body.replace("[", "[lb]").replace("]", "[rb]")
	var has_more := _long_description != _short_description and _long_description != ""

	var rect := DESCRIPTION_RECT_EXPANDED if _showing_long_description else DESCRIPTION_RECT_COLLAPSED
	description_label.position = rect.position
	description_label.size = rect.size
	tag_row.visible = not _showing_long_description
	badge_row.visible = not _showing_long_description
	favorite_button.visible = not _showing_long_description

	if not has_more:
		description_label.text = escaped
		return
	var link_text := "Show less" if _showing_long_description else "Read more..."
	description_label.text = "%s  [url=toggle][color=#%s]%s[/color][/url]" % [
		escaped, READ_MORE_LINK_COLOR.to_html(false), link_text
	]


func _on_description_meta_clicked(_meta: Variant) -> void:
	_showing_long_description = not _showing_long_description
	_set_description_display()


func _on_collect_pressed() -> void:
	if _marker:
		_marker.quick_collect()


func _on_leave_card_pressed() -> void:
	if _marker == null:
		return
	var slot_id := await _find_empty_slot_id(_marker.landmark_id)
	if slot_id == "":
		return
	var row := await SupabaseClient.insert_row("profile_card_placements", {
		"slot_id": slot_id,
		"placed_by": SupabaseClient.user_id,
	})
	if row.is_empty():
		print("Failed to leave card for %s" % _marker.landmark_id)
		return
	await _marker.refresh_card_slots()
	await _load_data()


func _find_empty_slot_id(landmark_id: String) -> String:
	var rows: Array = await SupabaseClient.get_table(
		"profile_card_slots_view",
		"select=slot_id,occupied&landmark_id=eq.%s&order=slot_index" % landmark_id
	)
	for row: Dictionary in rows:
		if not row.get("occupied", false):
			return row.get("slot_id", "")
	return ""


# "Favorited" -- a star toggle in the panel's bottom corner, replacing what
# used to be a "Recommend This Place" text button. Same underlying vote
# (recommend_landmark()/unrecommend_landmark()) and the same "must have
# visited first" server-side rule -- just reframed client-side as a
# favorite rather than a named recommendation, and moved out of the way of
# the main content instead of taking up a full text-button row.
func _load_favorite_state() -> void:
	if _marker == null:
		return

	favorite_button.disabled = not _marker.visited

	var rows: Array = await SupabaseClient.get_table(
		"community_recommendations_view",
		(
			"select=id&landmark_id=eq.%s&author_wayfinder_id=eq.%s&status=eq.published"
			% [_marker.landmark_id, SupabaseClient.user_id]
		)
	)
	_is_favorited = not rows.is_empty()
	_update_favorite_button_look()


const FAVORITE_GOLD := Color(1, 0.85, 0.2, 1)
const FAVORITE_HOLLOW_COLOR := Color(0.9, 0.9, 0.88, 1)


func _update_favorite_button_look() -> void:
	favorite_button.text = "★" if _is_favorited else "☆"
	favorite_button.add_theme_color_override(
		"font_color", FAVORITE_GOLD if _is_favorited else FAVORITE_HOLLOW_COLOR
	)


func _on_favorite_pressed() -> void:
	if _marker == null:
		return

	var result: Variant
	if _is_favorited:
		result = await SupabaseClient.call_rpc("unrecommend_landmark", {"p_landmark_id": _marker.landmark_id})
	else:
		result = await SupabaseClient.call_rpc("recommend_landmark", {"p_landmark_id": _marker.landmark_id})

	if result is Dictionary and result.is_empty():
		print("Failed to update favorite state for %s" % _marker.landmark_id)
	else:
		await _load_data()


func _load_photo(url: Variant) -> void:
	photo_rect.texture = null
	if url == null or url == "":
		return
	var path: String = url
	if path.begins_with("res://"):
		photo_rect.texture = load(path)
	# else: a real http(s) cover image URL -- not implemented yet, no
	# Landmark has one outside this bundled test asset. Add a fetch +
	# Image.load_*_from_buffer path (same technique already used for
	# Rumor photos in community_board_ui.gd) once the enrichment
	# pipeline actually produces a remotely-hosted photo.


const TAG_CHIP_COLOR := Color(0.62, 0.48, 0.24, 1)
const TAG_CHIP_TEXT_COLOR := Color(0.98, 0.95, 0.88, 1)
const VISITED_CHIP_COLOR := Color(0.3, 0.55, 0.32, 1)
const VISITED_CHIP_TEXT_COLOR := Color(0.97, 0.98, 0.95, 1)
const RECOMMENDED_CHIP_COLOR := Color(0.78, 0.58, 0.18, 1)
const RECOMMENDED_CHIP_TEXT_COLOR := Color(0.22, 0.15, 0.03, 1)
const CARD_CHIP_COLOR := Color(0.27, 0.47, 0.68, 1)
const CARD_CHIP_TEXT_COLOR := Color(0.96, 0.98, 1, 1)


# Small rounded, colored pill -- a plain Label reads as a debug value,
# not a real UI element. Built in script rather than authored per-chip
# in the .tscn since the actual set of tags/badges is only known once
# the Landmark's own data loads.
func _make_chip(text: String, bg_color: Color, text_color: Color) -> PanelContainer:
	var style := StyleBoxFlat.new()
	style.bg_color = bg_color
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_right = 8
	style.corner_radius_bottom_left = 8
	style.content_margin_left = 8.0
	style.content_margin_right = 8.0
	style.content_margin_top = 3.0
	style.content_margin_bottom = 3.0

	var chip := PanelContainer.new()
	chip.add_theme_stylebox_override("panel", style)

	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", text_color)
	chip.add_child(label)

	return chip


func _populate_tags(tags: Array) -> void:
	for tag: String in tags:
		tag_row.add_child(_make_chip(TAG_LABELS.get(tag, tag), TAG_CHIP_COLOR, TAG_CHIP_TEXT_COLOR))


func _populate_badges(visited: bool, recommendation_count: int, has_collectible_card: bool) -> void:
	if visited:
		badge_row.add_child(_make_chip("Visited", VISITED_CHIP_COLOR, VISITED_CHIP_TEXT_COLOR))
	if recommendation_count > 0:
		badge_row.add_child(_make_chip(
			"Favorited (%d)" % recommendation_count, RECOMMENDED_CHIP_COLOR, RECOMMENDED_CHIP_TEXT_COLOR
		))
	if has_collectible_card:
		badge_row.add_child(_make_chip("Card available", CARD_CHIP_COLOR, CARD_CHIP_TEXT_COLOR))


# One combined fetch (rather than three separate ones) for everything the
# Collect and Leave My Card buttons need to know: whether there's an
# uncollected card here (Collect), whether there's an empty slot and
# whether you've already placed a card of your own here (Leave My Card).
func _fetch_card_slot_summary(landmark_id: String) -> Dictionary:
	var rows: Array = await SupabaseClient.get_table(
		"profile_card_slots_view",
		"select=occupied,is_own_card,already_collected&landmark_id=eq.%s" % landmark_id
	)
	var has_collectible_card := false
	var has_empty_slot := false
	var already_placed_card := false
	for row: Dictionary in rows:
		var occupied: bool = row.get("occupied", false)
		var is_own_card: bool = row.get("is_own_card", false)
		var already_collected: bool = row.get("already_collected", false)
		if occupied and not is_own_card and not already_collected:
			has_collectible_card = true
		if not occupied:
			has_empty_slot = true
		if is_own_card:
			already_placed_card = true
	return {
		"has_collectible_card": has_collectible_card,
		"has_empty_slot": has_empty_slot,
		"already_placed_card": already_placed_card,
	}
