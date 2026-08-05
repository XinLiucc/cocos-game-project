extends Node2D

# 占位数值：学徒实习任务先用固定值，不接车型资源，等机制成熟再细化
const APPRENTICE_PRACTICE_TIME := 2.0
const APPRENTICE_PRACTICE_PAYOUT := 5
const APPRENTICE_PRACTICE_XP := 15

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
@onready var facility_label: Label = $FacilityLabel
@onready var upgrade_button: Button = $UpgradeButton
@onready var day_label: Label = $DayLabel
@onready var apprentice_label: Label = $ApprenticeLabel
@onready var hire_apprentice_button: Button = $HireApprenticeButton
@onready var practice_button: Button = $PracticeButton
@onready var exam_button: Button = $ExamButton
@onready var practice_timer: Timer = $PracticeTimer
@onready var game_state: Node = get_node("/root/GameState")

var repairing := false
var current_order: Resource
var practicing := false


func _ready() -> void:
	repair_timer.one_shot = true
	repair_timer.timeout.connect(_on_repair_complete)
	practice_timer.one_shot = true
	practice_timer.timeout.connect(_on_practice_complete)
	repair_button.pressed.connect(_on_repair_button_pressed)
	hire_button.pressed.connect(_on_hire_button_pressed)
	upgrade_button.pressed.connect(_on_upgrade_button_pressed)
	hire_apprentice_button.pressed.connect(_on_hire_apprentice_button_pressed)
	practice_button.pressed.connect(_on_practice_button_pressed)
	exam_button.pressed.connect(_on_exam_button_pressed)
	game_state.money_changed.connect(_on_state_changed)
	game_state.reputation_changed.connect(_on_state_changed)
	game_state.worker_count_changed.connect(_on_worker_count_changed)
	game_state.facility_level_changed.connect(_on_facility_level_changed)
	game_state.day_changed.connect(_on_day_changed)
	game_state.month_changed.connect(_on_month_changed)
	game_state.apprentice_count_changed.connect(_on_apprentice_changed)
	game_state.apprentice_level_changed.connect(_on_apprentice_changed)
	game_state.apprentice_xp_changed.connect(_on_apprentice_changed)
	_update_labels()


func _on_repair_button_pressed() -> void:
	if repairing:
		return
	repairing = true
	var available_orders := ORDER_TYPES.filter(func(o: Resource) -> bool: return game_state.reputation >= o.min_reputation)
	current_order = available_orders[randi() % available_orders.size()]
	repair_button.disabled = true
	var actual_time: float = current_order.repair_time * game_state.repair_time_multiplier()
	order_label.text = "维修中：%s（预计 %.1fs）" % [current_order.car_name, actual_time]
	repair_timer.wait_time = actual_time
	repair_timer.start()


func _on_hire_button_pressed() -> void:
	game_state.hire_worker()


func _on_upgrade_button_pressed() -> void:
	game_state.upgrade_facility()


func _on_repair_complete() -> void:
	var actual_payout: int = roundi(current_order.payout * game_state.payout_multiplier())
	game_state.add_money(actual_payout)
	game_state.add_reputation(current_order.reputation_gain)
	order_label.text = "完成：%s，收入 %d，口碑 +%d" % [current_order.car_name, actual_payout, current_order.reputation_gain]
	repairing = false
	repair_button.disabled = false


func _on_state_changed(_new_amount: int) -> void:
	_update_labels()


func _on_worker_count_changed(_new_count: int) -> void:
	_update_labels()


func _on_facility_level_changed(_new_level: int) -> void:
	_update_labels()


func _on_day_changed(_new_day: int) -> void:
	_update_labels()


func _on_month_changed(_new_month: int) -> void:
	_update_labels()


func _on_apprentice_changed(_value: int) -> void:
	_update_labels()


func _on_hire_apprentice_button_pressed() -> void:
	game_state.hire_apprentice()


func _on_practice_button_pressed() -> void:
	if practicing or game_state.apprentice_count <= 0:
		return
	practicing = true
	practice_button.disabled = true
	practice_timer.wait_time = APPRENTICE_PRACTICE_TIME
	practice_timer.start()


func _on_practice_complete() -> void:
	game_state.add_money(APPRENTICE_PRACTICE_PAYOUT)
	game_state.add_apprentice_xp(APPRENTICE_PRACTICE_XP)
	practicing = false
	practice_button.disabled = false


func _on_exam_button_pressed() -> void:
	game_state.take_exam()


func _update_labels() -> void:
	money_label.text = "金钱: %d   口碑: %d" % [game_state.money, game_state.reputation]
	worker_label.text = "工人: %d（月薪 %d/人）" % [game_state.worker_count, game_state.WORKER_SALARY_PER_HEAD]
	hire_button.text = "雇佣工人 (%d)" % game_state.next_hire_cost()
	hire_button.disabled = game_state.money < game_state.next_hire_cost()
	facility_label.text = "工位等级: %d" % game_state.facility_level
	upgrade_button.text = "升级工位 (%d)" % game_state.next_upgrade_cost()
	upgrade_button.disabled = game_state.money < game_state.next_upgrade_cost()
	day_label.text = "第%d月 第%d天" % [game_state.month, game_state.day]
	apprentice_label.text = "学徒: %d（等级 %d, 经验 %d/%d, 月薪 %d/人）" % [
		game_state.apprentice_count,
		game_state.apprentice_level,
		game_state.apprentice_xp,
		game_state.apprentice_xp_required(),
		game_state.apprentice_salary_per_head(),
	]
	hire_apprentice_button.text = "招学徒 (%d)" % game_state.next_apprentice_hire_cost()
	hire_apprentice_button.disabled = not game_state.can_hire_apprentice()
	practice_button.disabled = practicing or game_state.apprentice_count <= 0
	exam_button.disabled = not game_state.can_take_exam()
