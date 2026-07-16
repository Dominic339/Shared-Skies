extends CanvasLayer

@onready var name_label: Label = $Panel/VBoxContainer/NameLabel
@onready var category_label: Label = $Panel/VBoxContainer/CategoryLabel
@onready var code_label: Label = $Panel/VBoxContainer/CodeLabel
@onready var close_button: Button = $Panel/VBoxContainer/CloseButton


func _ready() -> void:
	close_button.pressed.connect(hide)
	hide()


func show_landmark(marker: LandmarkMarker) -> void:
	name_label.text = marker.landmark_name
	category_label.text = "Category: %s" % marker.category
	code_label.text = marker.code
	show()
