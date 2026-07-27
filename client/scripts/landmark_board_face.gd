extends SubViewport

# Renders a Landmark's kiosk board face -- name, cover photo, short
# description, tag chips, and tiny visited/recommended/new-card status
# -- as a plain 2D layout, baked into this SubViewport's texture and
# applied directly onto the physical sign's board surface (see
# landmark_marker.gd's apply_board_texture()). Deliberately pure
# presentation, no interactive controls here -- Recommend, card
# collection, and "read the rest" all stay in the existing tap-to-open
# 2D popup (landmark_display_ui.gd) rather than inventing 3D-click-to-
# UV-forwarding for this first pass.

const TAG_LABELS := {
	"wheelchair_accessible": "Wheelchair Accessible",
	"family_friendly": "Family Friendly",
	"historic": "Historic",
	"scenic": "Scenic",
	"outdoors": "Outdoors",
	"good_for_photos": "Good for Photos",
	"pet_friendly": "Pet Friendly",
}

@onready var title_label: Label = $Root/Margin/VBox/TitleLabel
@onready var subtitle_label: Label = $Root/Margin/VBox/SubtitleLabel
@onready var photo_rect: TextureRect = $Root/Margin/VBox/PhotoRect
@onready var description_label: Label = $Root/Margin/VBox/DescriptionLabel
@onready var tag_row: HBoxContainer = $Root/Margin/VBox/TagRow
@onready var badge_row: HBoxContainer = $Root/Margin/VBox/BadgeRow


func render_board(data: Dictionary, has_uncollected_card: bool) -> void:
	title_label.text = data.get("name", "")
	subtitle_label.text = "%s · %s" % [
		String(data.get("category", "")).capitalize(), data.get("community_name", "")
	]
	# Nullable columns -- read as Variant and fall back explicitly,
	# rather than a hard `: String` cast whose default only applies to
	# an absent key, not a present-but-null one (see
	# community_board_ui.gd's photo_ref fix earlier this project).
	var short_description: Variant = data.get("short_description")
	description_label.text = short_description if short_description != null else ""

	_load_photo(data.get("cover_image_url"))
	_populate_tags(data.get("tags", []))
	_populate_badges(
		data.get("visited", false), data.get("recommendation_count", 0), has_uncollected_card
	)


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
		chip.add_theme_font_size_override("font_size", 15)
		chip.add_theme_color_override("font_color", Color(0.3, 0.24, 0.14, 1))
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
