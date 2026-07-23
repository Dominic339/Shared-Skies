extends CanvasLayer

@onready var position_label: Label = $Panel/VBoxContainer/PositionLabel
@onready var lat_edit: LineEdit = $Panel/VBoxContainer/LatEdit
@onready var lng_edit: LineEdit = $Panel/VBoxContainer/LngEdit
@onready var set_button: Button = $Panel/VBoxContainer/SetButton
@onready var hide_button: Button = $Panel/VBoxContainer/HideButton


func _ready() -> void:
	set_button.pressed.connect(_on_set_button_pressed)
	hide_button.pressed.connect(_on_hide_button_pressed)
	DevLocation.position_changed.connect(_update_label)
	_update_label()


func _on_set_button_pressed() -> void:
	if lat_edit.text.is_valid_float() and lng_edit.text.is_valid_float():
		DevLocation.set_position_manual(lat_edit.text.to_float(), lng_edit.text.to_float())


# Collapses everything except this button itself (rather than hiding the
# whole panel), since hiding hide_button along with the rest would leave
# no way to bring the panel back.
func _on_hide_button_pressed() -> void:
	var collapse := position_label.visible
	position_label.visible = not collapse
	lat_edit.visible = not collapse
	lng_edit.visible = not collapse
	set_button.visible = not collapse
	hide_button.text = "Show" if collapse else "Hide"


func _update_label() -> void:
	position_label.text = "Lat: %.5f  Lng: %.5f" % [DevLocation.current_lat, DevLocation.current_lng]
