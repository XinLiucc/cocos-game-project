extends Node2D

const ORDER_TYPES: Array[Resource] = [
	preload("res://resources/orders/sedan.tres"),
	preload("res://resources/orders/suv.tres"),
	preload("res://resources/orders/sports_car.tres"),
]

@onready var money_label: Label = $MoneyLabel
@onready var order_label: Label = $OrderLabel
@onready var repair_button: Button = $RepairButton
@onready var repair_timer: Timer = $RepairTimer
@onready var worker_label: Label = $WorkerLabel
@onready var hire_button: Button = $HireButton
@onready var game_state: Node = get_node("/root/GameState")

var repairing := false
var current_order: Resource


func _ready() -> void:
	repair_timer.one_shot = true
	repair_timer.timeout.connect(_on_repair_complete)
	repair_button.pressed.connect(_on_repair_button_pressed)
	hire_button.pressed.connect(_on_hire_button_pressed)
	game_state.money_changed.connect(_on_state_changed)
	game_state.reputation_changed.connect(_on_state_changed)
	game_state.worker_count_changed.connect(_on_worker_count_changed)
	_update_labels()


func _on_repair_button_pressed() -> void:
	if repairing:
		return
	repairing = true
	current_order = ORDER_TYPES[randi() % ORDER_TYPES.size()]
	repair_button.disabled = true
	var actual_time: float = current_order.repair_time * game_state.repair_time_multiplier()
	order_label.text = "维修中：%s（预计 %.1fs）" % [current_order.car_name, actual_time]
	repair_timer.wait_time = actual_time
	repair_timer.start()


func _on_hire_button_pressed() -> void:
	game_state.hire_worker()


func _on_repair_complete() -> void:
	game_state.add_money(current_order.payout)
	game_state.add_reputation(current_order.reputation_gain)
	order_label.text = "完成：%s，收入 %d，口碑 +%d" % [current_order.car_name, current_order.payout, current_order.reputation_gain]
	repairing = false
	repair_button.disabled = false


func _on_state_changed(_new_amount: int) -> void:
	_update_labels()


func _on_worker_count_changed(_new_count: int) -> void:
	_update_labels()


func _update_labels() -> void:
	money_label.text = "金钱: %d   口碑: %d" % [game_state.money, game_state.reputation]
	worker_label.text = "工人: %d" % game_state.worker_count
	hire_button.text = "雇佣工人 (%d)" % game_state.next_hire_cost()
	hire_button.disabled = game_state.money < game_state.next_hire_cost()
