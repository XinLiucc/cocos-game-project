extends Node2D

const REPAIR_TIME := 0.1
const REPAIR_PAYOUT := 50
const REPAIR_REPUTATION := 1

@onready var money_label: Label = $MoneyLabel
@onready var order_label: Label = $OrderLabel
@onready var repair_button: Button = $RepairButton
@onready var repair_timer: Timer = $RepairTimer
@onready var game_state: Node = get_node("/root/GameState")

var repairing := false


func _ready() -> void:
	repair_timer.wait_time = REPAIR_TIME
	repair_timer.one_shot = true
	repair_timer.timeout.connect(_on_repair_complete)
	repair_button.pressed.connect(_on_repair_button_pressed)
	game_state.money_changed.connect(_on_state_changed)
	game_state.reputation_changed.connect(_on_state_changed)
	_update_labels()


func _on_repair_button_pressed() -> void:
	if repairing:
		return
	repairing = true
	repair_button.disabled = true
	order_label.text = "维修中..."
	repair_timer.start()


func _on_repair_complete() -> void:
	game_state.add_money(REPAIR_PAYOUT)
	game_state.add_reputation(REPAIR_REPUTATION)
	repairing = false
	repair_button.disabled = false
	order_label.text = "等待接单"


func _on_state_changed(_new_amount: int) -> void:
	_update_labels()


func _update_labels() -> void:
	money_label.text = "金钱: %d   口碑: %d" % [game_state.money, game_state.reputation]
