extends CanvasLayer

# Community Board: Bounties (existing) plus Rumor Quests -- "someone
# reported a possible Landmark near here, go find and confirm it" --
# folded into this same screen instead of Rumors living as their own
# separate tab. A Rumor never gets an exact pin/3D marker before it's
# confirmed (see main.gd's _load_landmarks, which only ever renders
# lifecycle_state seeded/published Landmarks) -- the hint shown here is
# a rough banded distance + 8-point compass direction ("hot zone"), not
# the Rumor's exact coordinates, so there's still something to actually
# go looking for.

signal closed

const LANDMARK_CATEGORIES := [
	"park", "trail", "museum", "historic_site", "garden", "overlook",
	"beach", "business", "memorial", "covered_bridge", "other",
]
const REPORT_CATEGORIES := ["unsafe", "inaccessible", "duplicate", "inappropriate"]
# Stub only -- no camera hardware exists to test real capture against in
# this dev environment, and this is what actually gets uploaded (see
# submit_rumor()'s p_photo_ref) to the private rumor-photos Storage
# bucket right now. A real device camera replaces where these bytes
# come from later without needing any change to the upload path itself.
const PHOTO_PLACEHOLDERS := ["none", "placeholder_a", "placeholder_b", "placeholder_c"]
const DEFAULT_NUDGE_RADIUS_METERS := 75.0
const COMPASS_DIRECTIONS := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

@onready var panel: PanelContainer = $Panel
@onready var entries_container: VBoxContainer = $Panel/VBoxContainer/ScrollContainer/EntriesContainer
@onready var rumor_entries_container: VBoxContainer = $Panel/VBoxContainer/RumorScrollContainer/RumorEntriesContainer
@onready var rumor_name_edit: LineEdit = $Panel/VBoxContainer/RumorSubmitControls/RumorNameEdit
@onready var rumor_description_edit: LineEdit = $Panel/VBoxContainer/RumorSubmitControls/RumorDescriptionEdit
@onready var rumor_category_option: OptionButton = $Panel/VBoxContainer/RumorSubmitControls/RumorCategoryOption
@onready var rumor_photo_option: OptionButton = $Panel/VBoxContainer/RumorSubmitControls/RumorPhotoOption
@onready var rumor_nudge_hint: Label = $Panel/VBoxContainer/RumorSubmitControls/RumorNudgeHint
@onready var rumor_nudge_north_slider: HSlider = $Panel/VBoxContainer/RumorSubmitControls/RumorNudgeNorthSlider
@onready var rumor_nudge_east_slider: HSlider = $Panel/VBoxContainer/RumorSubmitControls/RumorNudgeEastSlider
@onready var rumor_submit_button: Button = $Panel/VBoxContainer/RumorSubmitControls/RumorSubmitButton
@onready var rumor_status_label: Label = $Panel/VBoxContainer/RumorStatusLabel
@onready var close_button: Button = $Panel/VBoxContainer/CloseButton

@onready var rumor_report_panel: PanelContainer = $RumorReportPanel
@onready var rumor_report_category_option: OptionButton = $RumorReportPanel/VBoxContainer/ReportCategoryOption
@onready var rumor_report_details_edit: LineEdit = $RumorReportPanel/VBoxContainer/ReportDetailsEdit
@onready var rumor_report_submit_button: Button = $RumorReportPanel/VBoxContainer/ReportSubmitButton
@onready var rumor_report_close_button: Button = $RumorReportPanel/VBoxContainer/CloseButton

@onready var photo_preview_panel: PanelContainer = $PhotoPreviewPanel
@onready var photo_preview_texture: TextureRect = $PhotoPreviewPanel/VBoxContainer/PhotoTexture
@onready var photo_preview_close_button: Button = $PhotoPreviewPanel/VBoxContainer/CloseButton

var _report_landmark_id: String = ""
var _nudge_radius_meters: float = DEFAULT_NUDGE_RADIUS_METERS


func _ready() -> void:
	close_button.pressed.connect(_on_close_pressed)

	for category in LANDMARK_CATEGORIES:
		rumor_category_option.add_item(category)
	for placeholder in PHOTO_PLACEHOLDERS:
		rumor_photo_option.add_item(placeholder)
	for category in REPORT_CATEGORIES:
		rumor_report_category_option.add_item(category)

	rumor_nudge_north_slider.value_changed.connect(_on_nudge_changed)
	rumor_nudge_east_slider.value_changed.connect(_on_nudge_changed)

	rumor_submit_button.pressed.connect(_on_rumor_submit_pressed)
	rumor_report_submit_button.pressed.connect(_on_rumor_report_submit_pressed)
	rumor_report_close_button.pressed.connect(_on_rumor_report_close_pressed)
	photo_preview_close_button.pressed.connect(_on_photo_preview_close_pressed)

	rumor_report_panel.hide()
	photo_preview_panel.hide()
	hide()


func show_board() -> void:
	rumor_status_label.text = ""
	rumor_report_panel.hide()
	photo_preview_panel.hide()
	show()
	await _load_nudge_radius()
	await _load_bounties()
	await _load_rumor_quests()


# How far the submitted location can be nudged from the player's actual
# GPS fix -- configurable (rumors.location_nudge_radius_meters in
# app_settings) rather than a number baked into this script, same
# reasoning submit_rumor() itself uses server-side.
func _load_nudge_radius() -> void:
	var rows: Array = await SupabaseClient.get_table(
		"app_settings", "select=value&key=eq.rumors.location_nudge_radius_meters"
	)
	if not rows.is_empty():
		_nudge_radius_meters = float(rows[0].get("value", str(DEFAULT_NUDGE_RADIUS_METERS)))
	rumor_nudge_north_slider.min_value = -_nudge_radius_meters
	rumor_nudge_north_slider.max_value = _nudge_radius_meters
	rumor_nudge_east_slider.min_value = -_nudge_radius_meters
	rumor_nudge_east_slider.max_value = _nudge_radius_meters
	rumor_nudge_north_slider.value = 0
	rumor_nudge_east_slider.value = 0
	_on_nudge_changed(0.0)


func _load_bounties() -> void:
	for child in entries_container.get_children():
		child.queue_free()

	var rows: Array = await SupabaseClient.get_table(
		"community_bounty_status_view",
		"select=bounty_id,community_name,title,description,reward_amount,claimed,requirement_met"
		+ "&order=community_name"
	)

	for row: Dictionary in rows:
		var row_box := HBoxContainer.new()
		var label := Label.new()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var claimed: bool = row.get("claimed", false)
		var requirement_met: bool = row.get("requirement_met", false)
		var status := "claimed" if claimed else ("ready" if requirement_met else "not yet met")
		label.text = "%s -- %s (%d Waymarks) [%s]" % [
			row.get("community_name", ""), row.get("title", ""), row.get("reward_amount", 0), status
		]
		row_box.add_child(label)

		if not claimed:
			var claim_button := Button.new()
			claim_button.text = "Claim"
			claim_button.disabled = not requirement_met
			claim_button.pressed.connect(_on_claim_pressed.bind(row.get("bounty_id", "")))
			row_box.add_child(claim_button)

		entries_container.add_child(row_box)


func _load_rumor_quests() -> void:
	for child in rumor_entries_container.get_children():
		child.queue_free()

	var rows: Array = await SupabaseClient.get_table(
		"rumor_landmarks_view",
		"select=id,name,category,lat,lng,required_verifications,confirmation_count,already_confirmed,"
		+ "is_own_submission,awaiting_review,photo_ref&order=name"
	)

	for row: Dictionary in rows:
		var row_box := HBoxContainer.new()
		var label := Label.new()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var awaiting_review: bool = row.get("awaiting_review", false)
		var hint := _hot_zone_hint(row.get("lat", 0.0), row.get("lng", 0.0))
		label.text = "%s (%s) -- %s -- %s" % [
			row.get("name", ""), row.get("category", ""), hint,
			"Under Review" if awaiting_review else "Confirmations: %d/%d" % [
				row.get("confirmation_count", 0), row.get("required_verifications", 5)
			]
		]
		row_box.add_child(label)

		var landmark_id: String = row.get("id", "")
		var is_own: bool = row.get("is_own_submission", false)
		var already_confirmed: bool = row.get("already_confirmed", false)
		var photo_ref: String = row.get("photo_ref", "")

		if photo_ref != "" and photo_ref != null:
			var photo_button := Button.new()
			photo_button.text = "View Photo"
			photo_button.pressed.connect(_on_view_photo_pressed.bind(photo_ref))
			row_box.add_child(photo_button)

		# The threshold has done its job once a Rumor is under review --
		# further confirmations wouldn't change anything. Hidden entirely
		# rather than shown-disabled, since there's nothing left for this
		# button to do.
		if not awaiting_review:
			var confirm_button := Button.new()
			confirm_button.text = "Confirm"
			confirm_button.disabled = is_own or already_confirmed
			confirm_button.pressed.connect(_on_rumor_confirm_pressed.bind(landmark_id))
			row_box.add_child(confirm_button)

		var report_button := Button.new()
		report_button.text = "Report"
		report_button.pressed.connect(_on_rumor_report_pressed.bind(landmark_id))
		row_box.add_child(report_button)

		rumor_entries_container.add_child(row_box)


# Rough banded distance + 8-point compass direction from the player's
# current position to a Rumor's true location -- deliberately not exact
# coordinates, so there's still a "go find it" hot zone to search
# instead of a GPS pin landing you right on top of it. GeoProjection's
# own convention (+X = east, -Z = north) is what the bearing formula
# below is built from.
func _hot_zone_hint(lat: float, lng: float) -> String:
	var rumor_pos := GeoProjection.to_local(lat, lng)
	var player_pos := GeoProjection.to_local(DevLocation.current_lat, DevLocation.current_lng)
	var delta := rumor_pos - player_pos
	var distance := Vector2(delta.x, delta.z).length()
	var bearing_degrees := fposmod(rad_to_deg(atan2(delta.x, -delta.z)), 360.0)
	var octant := int(round(bearing_degrees / 45.0)) % 8
	var banded_distance := int(round(distance / 25.0)) * 25
	return "~%dm %s" % [banded_distance, COMPASS_DIRECTIONS[octant]]


func _on_claim_pressed(bounty_id: String) -> void:
	var result: Variant = await SupabaseClient.call_rpc("claim_bounty", {"p_bounty_id": bounty_id})
	if result is Dictionary and result.is_empty():
		print("Failed to claim bounty %s" % bounty_id)
	await _load_bounties()


func _on_nudge_changed(_value: float) -> void:
	rumor_nudge_hint.text = "Fine-tune location: %dm N, %dm E (up to %dm)" % [
		int(rumor_nudge_north_slider.value), int(rumor_nudge_east_slider.value), int(_nudge_radius_meters)
	]


func _on_rumor_submit_pressed() -> void:
	if rumor_name_edit.text.strip_edges().is_empty():
		return

	var offset := GeoProjection.local_delta_to_lat_lng(
		rumor_nudge_east_slider.value, rumor_nudge_north_slider.value
	)
	var photo_ref: Variant = await _upload_chosen_photo()

	var result: Variant = await SupabaseClient.call_rpc("submit_rumor", {
		"p_name": rumor_name_edit.text,
		"p_description": rumor_description_edit.text,
		"p_category": LANDMARK_CATEGORIES[rumor_category_option.selected],
		"p_player_lat": DevLocation.current_lat,
		"p_player_lng": DevLocation.current_lng,
		"p_lat": DevLocation.current_lat + offset.x,
		"p_lng": DevLocation.current_lng + offset.y,
		"p_photo_ref": photo_ref,
	})
	if result is Dictionary and result.is_empty():
		rumor_status_label.text = SupabaseClient.last_error_message
	else:
		rumor_status_label.text = ""
		rumor_name_edit.text = ""
		rumor_description_edit.text = ""
		rumor_photo_option.selected = 0
		rumor_nudge_north_slider.value = 0
		rumor_nudge_east_slider.value = 0
		await _load_rumor_quests()


# Uploads the chosen bundled placeholder image (see PHOTO_PLACEHOLDERS)
# to the private rumor-photos bucket under this player's own folder --
# stands in for real device camera capture, which can't be exercised in
# this dev environment. Returns null if "none" was chosen or the upload
# failed, matching submit_rumor()'s p_photo_ref default.
func _upload_chosen_photo() -> Variant:
	var chosen: String = PHOTO_PLACEHOLDERS[rumor_photo_option.selected]
	if chosen == "none":
		return null

	var file := FileAccess.open("res://assets/placeholder_photos/%s.png" % chosen, FileAccess.READ)
	if file == null:
		return null
	var bytes := file.get_buffer(file.get_length())

	var object_path := "%s/%s_%d.png" % [SupabaseClient.user_id, chosen, Time.get_ticks_msec()]
	var uploaded_path := await SupabaseClient.upload_file("rumor-photos", object_path, bytes, "image/png")
	return uploaded_path if uploaded_path != "" else null


func _on_rumor_confirm_pressed(landmark_id: String) -> void:
	var result: Variant = await SupabaseClient.call_rpc("confirm_rumor", {
		"p_landmark_id": landmark_id,
		"p_lat": DevLocation.current_lat,
		"p_lng": DevLocation.current_lng,
	})
	if result is Dictionary and result.is_empty():
		rumor_status_label.text = SupabaseClient.last_error_message
	else:
		rumor_status_label.text = ""
		await _load_rumor_quests()


func _on_rumor_report_pressed(landmark_id: String) -> void:
	_report_landmark_id = landmark_id
	rumor_report_details_edit.text = ""
	rumor_report_panel.show()


func _on_rumor_report_submit_pressed() -> void:
	var result: Variant = await SupabaseClient.call_rpc("report_rumor", {
		"p_landmark_id": _report_landmark_id,
		"p_report_category": REPORT_CATEGORIES[rumor_report_category_option.selected],
		"p_details": rumor_report_details_edit.text,
	})
	if result is Dictionary and result.is_empty():
		rumor_status_label.text = SupabaseClient.last_error_message
	else:
		rumor_status_label.text = "Report submitted."
	rumor_report_panel.hide()


func _on_rumor_report_close_pressed() -> void:
	rumor_report_panel.hide()


func _on_view_photo_pressed(photo_ref: String) -> void:
	var bytes := await SupabaseClient.download_file("rumor-photos", photo_ref)
	if bytes.is_empty():
		rumor_status_label.text = "Could not load photo."
		return
	var image := Image.new()
	if image.load_png_from_buffer(bytes) != OK:
		rumor_status_label.text = "Could not decode photo."
		return
	photo_preview_texture.texture = ImageTexture.create_from_image(image)
	photo_preview_panel.show()


func _on_photo_preview_close_pressed() -> void:
	photo_preview_panel.hide()


func _on_close_pressed() -> void:
	hide()
	closed.emit()


# Used by main.gd's global Escape handler, same pattern as the other UIs.
func close_topmost() -> bool:
	if not visible:
		return false
	if photo_preview_panel.visible:
		_on_photo_preview_close_pressed()
	elif rumor_report_panel.visible:
		_on_rumor_report_close_pressed()
	else:
		_on_close_pressed()
	return true
