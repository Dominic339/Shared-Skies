extends CanvasLayer

# Wallet balance (gold/silver split) + transaction history, plus
# temporary developer grant/spend controls for exercising the ledger
# before any real bounty or shop exists to drive it. Hiding these
# controls is NOT what protects them -- dev_grant_waymarks() itself
# refuses any account the developer hasn't explicitly allowlisted
# (profiles.dev_grants_enabled), regardless of whether this button is
# visible. spend_waymarks() needs no such gate -- it can only ever spend
# the calling wayfinder's own currency.

signal closed

@onready var panel: PanelContainer = $Panel
@onready var total_label: Label = $Panel/VBoxContainer/TotalLabel
@onready var silver_label: Label = $Panel/VBoxContainer/SilverLabel
@onready var gold_label: Label = $Panel/VBoxContainer/GoldLabel
@onready var history_container: VBoxContainer = $Panel/VBoxContainer/ScrollContainer/HistoryContainer
@onready var dev_amount_edit: LineEdit = $Panel/VBoxContainer/DevControls/DevAmountEdit
@onready var dev_grant_button: Button = $Panel/VBoxContainer/DevControls/DevGrantButton
@onready var dev_spend_button: Button = $Panel/VBoxContainer/DevControls/DevSpendButton
@onready var close_button: Button = $Panel/VBoxContainer/CloseButton


func _ready() -> void:
	close_button.pressed.connect(_on_close_pressed)
	dev_grant_button.pressed.connect(_on_dev_grant_pressed)
	dev_spend_button.pressed.connect(_on_dev_spend_pressed)
	hide()


func show_waymarks() -> void:
	show()
	await _load_wallet()


func _load_wallet() -> void:
	var balance_rows: Array = await SupabaseClient.get_table(
		"wallet_balance_view", "select=paid_balance,earned_balance,total_balance"
	)
	if balance_rows.size() > 0:
		var balance: Dictionary = balance_rows[0]
		total_label.text = "Waymarks: %d total" % balance.get("total_balance", 0)
		silver_label.text = "Silver -- %d earned" % balance.get("earned_balance", 0)
		gold_label.text = "Gold -- %d purchased" % balance.get("paid_balance", 0)

	for child in history_container.get_children():
		child.queue_free()

	var history_rows: Array = await SupabaseClient.get_table(
		"wallet_history_view",
		"select=operation_type,total_amount,description,created_at&order=created_at.desc"
	)
	for row: Dictionary in history_rows:
		var entry := Label.new()
		var sign_prefix := "+" if row.get("operation_type", "") == "award" else "-"
		entry.text = "%s%d -- %s" % [
			sign_prefix, row.get("total_amount", 0), row.get("description", "")
		]
		history_container.add_child(entry)


# Dev-only -- exercises the ledger's award path without a real bounty or
# store purchase to drive it yet. Fails silently (server-side) for any
# account that isn't allowlisted, which is the actual protection here.
func _on_dev_grant_pressed() -> void:
	if not dev_amount_edit.text.is_valid_int():
		return
	var result: Variant = await SupabaseClient.call_rpc("dev_grant_waymarks", {
		"p_amount": dev_amount_edit.text.to_int(),
		"p_description": "Dev grant",
	})
	if result is Dictionary and result.is_empty():
		print("Dev grant failed -- account not allowlisted (dev_grants_enabled)?")
	await _load_wallet()


# Not gated the way the grant path is -- spend_waymarks can only ever
# draw down the calling wayfinder's own balance, so any account is safe
# to let exercise it.
func _on_dev_spend_pressed() -> void:
	if not dev_amount_edit.text.is_valid_int():
		return
	var result: Variant = await SupabaseClient.call_rpc("spend_waymarks", {
		"p_amount": dev_amount_edit.text.to_int(),
		"p_context_type": "dev_test",
		"p_context_id": null,
		"p_description": "Dev test spend",
		"p_idempotency_key": null,
	})
	if result is Dictionary and result.is_empty():
		print("Dev spend failed -- insufficient balance?")
	await _load_wallet()


func _on_close_pressed() -> void:
	hide()
	closed.emit()


# Used by main.gd's global Escape handler, same pattern as the other UIs.
func close_topmost() -> bool:
	if not visible:
		return false
	_on_close_pressed()
	return true
