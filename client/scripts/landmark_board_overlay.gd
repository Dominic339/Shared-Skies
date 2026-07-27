extends CanvasLayer

# The kiosk board's presentation content (name/photo/description/tags/
# badges) -- shown alongside landmark_display_ui.gd's interactive popup
# once a Landmark is focused (tapped), not while just walking past it
# in range; an earlier version showed on proximity instead, but that
# made it pop up during ordinary exploration rather than only when you
# actually stop to look at a sign. A single 2D screen-space overlay
# reused for whatever marker is currently focused, not a 3D texture
# baked per-marker -- this sidesteps two problems a first attempt at a
# 3D-projected board hit: no blind 3D-mesh-alignment guesswork (this
# reuses the exact same camera.unproject_position() screen-anchoring
# technique landmark_display_ui.gd already has proven working), and no
# need to ever render more than one of these regardless of how many
# signs happen to be nearby simultaneously.

const TAG_LABELS := {
	"wheelchair_accessible": "Wheelchair Accessible",
	"family_friendly": "Family Friendly",
	"historic": "Historic",
	"scenic": "Scenic",
	"outdoors": "Outdoors",
	"good_for_photos": "Good for Photos",
	"pet_friendly": "Pet Friendly",
}

@onready var panel: PanelContainer = $Panel
@onready var title_label: Label = $Panel/MainVBox/HeaderPanel/HeaderVBox/TitleLabel
@onready var subtitle_label: Label = $Panel/MainVBox/HeaderPanel/HeaderVBox/SubtitleLabel
@onready var photo_rect: TextureRect = $Panel/MainVBox/ContentMargin/ContentHBox/PhotoRect
@onready var description_label: Label = (
	$Panel/MainVBox/ContentMargin/ContentHBox/LeftColumn/DescriptionLabel
)
@onready var tag_row: HFlowContainer = $Panel/MainVBox/ContentMargin/ContentHBox/LeftColumn/TagRow
@onready var badge_row: HFlowContainer = (
	$Panel/MainVBox/ContentMargin/ContentHBox/LeftColumn/BadgeRow
)

var _marker: LandmarkMarker = null
var _camera: Camera3D = null


func _ready() -> void:
	hide()


# Called from main.gd's tap handler, alongside landmark_display.show_landmark().
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


# Re-fetches without changing which marker is targeted -- called after
# an action (recommend, collect a card) that might change this same
# Landmark's own badges.
func refresh_if_showing(marker: LandmarkMarker) -> void:
	if _marker == marker:
		await _load_data()


func _process(_delta: float) -> void:
	if visible and _marker != null and _camera != null:
		_update_position()


const SIDE_GAP_FROM_SIGN := 40.0


func _update_position() -> void:
	var anchor := _marker.global_position + Vector3(0, LandmarkMarker.STRUCTURE_TOP_HEIGHT_METERS, 0)
	var screen_point := _camera.unproject_position(anchor)
	# To the LEFT of the sign's anchor point, not stacked above it --
	# landmark_display_ui.gd's popup is centered on this exact same
	# anchor while focused (both panels are only ever visible together
	# now that this overlay shows on focus instead of on proximity), so
	# stacking vertically would overlap it regardless of either panel's
	# actual height. Check once both are visible together and adjust
	# the gap/side if it still crowds the popup.
	panel.position = Vector2(
		screen_point.x - panel.size.x - SIDE_GAP_FROM_SIGN, screen_point.y - panel.size.y / 2.0
	)


func _load_data() -> void:
	if _marker == null:
		return
	var landmark_id := _marker.landmark_id

	var rows: Array = await SupabaseClient.get_table(
		"landmark_board_view",
		(
			"select=name,category,community_name,short_description,tags,cover_image_url,"
			+ "visited,recommendation_count&id=eq.%s" % landmark_id
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
	description_label.text = short_description if short_description != null else ""

	_load_photo(data.get("cover_image_url"))
	_populate_tags(data.get("tags", []))

	var has_uncollected_card := await _has_uncollected_card(landmark_id)
	if _marker == null or _marker.landmark_id != landmark_id:
		return
	_populate_badges(data.get("visited", false), data.get("recommendation_count", 0), has_uncollected_card)

	panel.reset_size()
	_update_position()


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
	for child in tag_row.get_children():
		child.queue_free()
	for tag: String in tags:
		tag_row.add_child(_make_chip(TAG_LABELS.get(tag, tag), TAG_CHIP_COLOR, TAG_CHIP_TEXT_COLOR))


func _populate_badges(visited: bool, recommendation_count: int, has_uncollected_card: bool) -> void:
	for child in badge_row.get_children():
		child.queue_free()
	if visited:
		badge_row.add_child(_make_chip("Visited", VISITED_CHIP_COLOR, VISITED_CHIP_TEXT_COLOR))
	if recommendation_count > 0:
		badge_row.add_child(_make_chip(
			"Recommended (%d)" % recommendation_count, RECOMMENDED_CHIP_COLOR, RECOMMENDED_CHIP_TEXT_COLOR
		))
	if has_uncollected_card:
		badge_row.add_child(_make_chip("Card available", CARD_CHIP_COLOR, CARD_CHIP_TEXT_COLOR))


# Reuses profile_card_slots_view rather than a second query shape --
# an occupied slot that isn't this player's own card and hasn't been
# collected yet is exactly what the "Card available" badge means.
func _has_uncollected_card(landmark_id: String) -> bool:
	var rows: Array = await SupabaseClient.get_table(
		"profile_card_slots_view",
		"select=occupied,is_own_card,already_collected&landmark_id=eq.%s" % landmark_id
	)
	for row: Dictionary in rows:
		var occupied: bool = row.get("occupied", false)
		var is_own_card: bool = row.get("is_own_card", false)
		var already_collected: bool = row.get("already_collected", false)
		if occupied and not is_own_card and not already_collected:
			return true
	return false
