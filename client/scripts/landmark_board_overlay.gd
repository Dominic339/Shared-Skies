extends CanvasLayer

# Ambient "you're near this Landmark" info panel -- shows automatically
# for whichever Landmark marker is currently closest and in range, not
# on tap (tapping still opens landmark_display_ui.gd for the long
# description/card slots/Recommend). A single 2D screen-space overlay
# tracking whatever marker is currently relevant, not a 3D texture
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

const SCREEN_MARGIN_ABOVE_SIGN := 20.0

@onready var panel: PanelContainer = $Panel
@onready var title_label: Label = $Panel/VBoxContainer/TitleLabel
@onready var subtitle_label: Label = $Panel/VBoxContainer/SubtitleLabel
@onready var photo_rect: TextureRect = $Panel/VBoxContainer/PhotoRect
@onready var description_label: Label = $Panel/VBoxContainer/DescriptionLabel
@onready var tag_row: HBoxContainer = $Panel/VBoxContainer/TagRow
@onready var badge_row: HBoxContainer = $Panel/VBoxContainer/BadgeRow

var _marker: LandmarkMarker = null
var _camera: Camera3D = null


func _ready() -> void:
	hide()


# No-op if already showing this same marker -- called every frame from
# main.gd's proximity check, so this must be cheap when nothing changed.
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


func _update_position() -> void:
	var anchor := _marker.global_position + Vector3(0, LandmarkMarker.STRUCTURE_TOP_HEIGHT_METERS, 0)
	var screen_point := _camera.unproject_position(anchor)
	panel.position = Vector2(
		screen_point.x - panel.size.x / 2.0, screen_point.y - SCREEN_MARGIN_ABOVE_SIGN - panel.size.y
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


func _populate_tags(tags: Array) -> void:
	for child in tag_row.get_children():
		child.queue_free()
	for tag: String in tags:
		var chip := Label.new()
		chip.text = TAG_LABELS.get(tag, tag)
		chip.add_theme_font_size_override("font_size", 14)
		tag_row.add_child(chip)


func _populate_badges(visited: bool, recommendation_count: int, has_uncollected_card: bool) -> void:
	for child in badge_row.get_children():
		child.queue_free()
	if visited:
		var visited_badge := Label.new()
		visited_badge.text = "Visited"
		visited_badge.add_theme_font_size_override("font_size", 14)
		badge_row.add_child(visited_badge)
	if recommendation_count > 0:
		var recommended_badge := Label.new()
		recommended_badge.text = "Recommended (%d)" % recommendation_count
		recommended_badge.add_theme_font_size_override("font_size", 14)
		badge_row.add_child(recommended_badge)
	if has_uncollected_card:
		var card_badge := Label.new()
		card_badge.text = "Card available"
		card_badge.add_theme_font_size_override("font_size", 14)
		badge_row.add_child(card_badge)


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
