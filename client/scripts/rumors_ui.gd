extends CanvasLayer

# Smallest safe Rumor lifecycle: submit one at your current (dev)
# location, see nearby open Rumors with confirmation progress, confirm
# one you're physically near (never your own submission, never twice),
# or report a problem with one. Reaching the confirmation threshold
# moves it to admin review (Supabase Studio, for now) -- it does NOT
# publish automatically. Community recommendations are a related but
# separate submission type and aren't part of this screen.

signal closed

const LANDMARK_CATEGORIES := [
	"park", "trail", "museum", "historic_site", "garden", "overlook",
	"beach", "business", "memorial", "covered_bridge", "other",
]
const REPORT_CATEGORIES := ["unsafe", "inaccessible", "duplicate", "inappropriate"]

@onready var panel: PanelContainer = $Panel
@onready var name_edit: LineEdit = $Panel/VBoxContainer/SubmitControls/NameEdit
@onready var description_edit: LineEdit = $Panel/VBoxContainer/SubmitControls/DescriptionEdit
@onready var category_option: OptionButton = $Panel/VBoxContainer/SubmitControls/CategoryOption
@onready var submit_button: Button = $Panel/VBoxContainer/SubmitControls/SubmitButton
@onready var entries_container: VBoxContainer = $Panel/VBoxContainer/ScrollContainer/EntriesContainer
@onready var status_label: Label = $Panel/VBoxContainer/StatusLabel
@onready var close_button: Button = $Panel/VBoxContainer/CloseButton

@onready var report_panel: PanelContainer = $ReportPanel
@onready var report_category_option: OptionButton = $ReportPanel/VBoxContainer/ReportCategoryOption
@onready var report_details_edit: LineEdit = $ReportPanel/VBoxContainer/ReportDetailsEdit
@onready var report_submit_button: Button = $ReportPanel/VBoxContainer/ReportSubmitButton
@onready var report_close_button: Button = $ReportPanel/VBoxContainer/CloseButton

var _report_landmark_id: String = ""


func _ready() -> void:
	for category in LANDMARK_CATEGORIES:
		category_option.add_item(category)
	for category in REPORT_CATEGORIES:
		report_category_option.add_item(category)

	submit_button.pressed.connect(_on_submit_pressed)
	report_submit_button.pressed.connect(_on_report_submit_pressed)
	report_close_button.pressed.connect(_on_report_close_pressed)
	close_button.pressed.connect(_on_close_pressed)
	report_panel.hide()
	hide()


func show_rumors() -> void:
	status_label.text = ""
	report_panel.hide()
	show()
	await _load_rumors()


func _load_rumors() -> void:
	for child in entries_container.get_children():
		child.queue_free()

	var rows: Array = await SupabaseClient.get_table(
		"rumor_landmarks_view",
		"select=id,name,category,required_verifications,confirmation_count,already_confirmed,is_own_submission,awaiting_review"
		+ "&order=name"
	)

	for row: Dictionary in rows:
		var row_box := HBoxContainer.new()
		var label := Label.new()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var awaiting_review: bool = row.get("awaiting_review", false)
		label.text = "%s (%s) -- %s" % [
			row.get("name", ""), row.get("category", ""),
			"Under Review" if awaiting_review else "Needs confirmations: %d/%d" % [
				row.get("confirmation_count", 0), row.get("required_verifications", 5)
			]
		]
		row_box.add_child(label)

		var landmark_id: String = row.get("id", "")
		var is_own: bool = row.get("is_own_submission", false)
		var already_confirmed: bool = row.get("already_confirmed", false)

		# The threshold has done its job once a Rumor is under review --
		# further confirmations wouldn't change anything and would just
		# send more players toward an unreviewed location. Hidden
		# entirely rather than shown-disabled, since there's nothing
		# left for this button to do.
		if not awaiting_review:
			var confirm_button := Button.new()
			confirm_button.text = "Confirm"
			confirm_button.disabled = is_own or already_confirmed
			confirm_button.pressed.connect(_on_confirm_pressed.bind(landmark_id))
			row_box.add_child(confirm_button)

		var report_button := Button.new()
		report_button.text = "Report"
		report_button.pressed.connect(_on_report_pressed.bind(landmark_id))
		row_box.add_child(report_button)

		entries_container.add_child(row_box)


func _on_submit_pressed() -> void:
	if name_edit.text.strip_edges().is_empty():
		return

	var result: Variant = await SupabaseClient.call_rpc("submit_rumor", {
		"p_name": name_edit.text,
		"p_description": description_edit.text,
		"p_category": LANDMARK_CATEGORIES[category_option.selected],
		"p_lat": DevLocation.current_lat,
		"p_lng": DevLocation.current_lng,
	})
	if result is Dictionary and result.is_empty():
		status_label.text = SupabaseClient.last_error_message
	else:
		status_label.text = ""
		name_edit.text = ""
		description_edit.text = ""
		await _load_rumors()


func _on_confirm_pressed(landmark_id: String) -> void:
	var result: Variant = await SupabaseClient.call_rpc("confirm_rumor", {
		"p_landmark_id": landmark_id,
		"p_lat": DevLocation.current_lat,
		"p_lng": DevLocation.current_lng,
	})
	if result is Dictionary and result.is_empty():
		status_label.text = SupabaseClient.last_error_message
	else:
		status_label.text = ""
		await _load_rumors()


func _on_report_pressed(landmark_id: String) -> void:
	_report_landmark_id = landmark_id
	report_details_edit.text = ""
	report_panel.show()


func _on_report_submit_pressed() -> void:
	var result: Variant = await SupabaseClient.call_rpc("report_rumor", {
		"p_landmark_id": _report_landmark_id,
		"p_report_category": REPORT_CATEGORIES[report_category_option.selected],
		"p_details": report_details_edit.text,
	})
	if result is Dictionary and result.is_empty():
		status_label.text = SupabaseClient.last_error_message
	else:
		status_label.text = "Report submitted."
	report_panel.hide()


func _on_report_close_pressed() -> void:
	report_panel.hide()


func _on_close_pressed() -> void:
	hide()
	closed.emit()


# Used by main.gd's global Escape handler, same pattern as the other UIs.
func close_topmost() -> bool:
	if not visible:
		return false
	if report_panel.visible:
		_on_report_close_pressed()
	else:
		_on_close_pressed()
	return true
