extends Node2D

# 占位数值：学徒实习复用 OrderType 车型池，报酬/经验按车型难度打折，具体系数之后再平衡
const APPRENTICE_PAYOUT_RATE := 0.3
const APPRENTICE_XP_PER_REPUTATION := 15

# 占位数值：订单队列/超时流失机制刚搭骨架，容量/间隔/超时/惩罚都是随手定的，之后再平衡
const QUEUE_CAPACITY := 3
const ORDER_SPAWN_INTERVAL := 10.0
const ORDER_TIMEOUT := 15.0
const REPUTATION_LOSS_ON_EXPIRE := 1

const ORDER_TYPES: Array[Resource] = [
	preload("res://resources/orders/sedan.tres"),
	preload("res://resources/orders/suv.tres"),
	preload("res://resources/orders/sports_car.tres"),
]

@onready var money_label: Label = $MoneyLabel
@onready var order_label: Label = $OrderLabel
@onready var repair_button: Button = $RepairButton
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

# 每个工位一个进行中任务：{"order": Resource, "timer": Timer}
var active_jobs: Array[Dictionary] = []
# 待处理订单队列：{"order": Resource, "timer": Timer}，timer 到期即流失
var pending_orders: Array[Dictionary] = []
var order_spawn_timer: Timer
var last_result_text := "尚未完成过订单"
var practicing := false
var current_practice_order: Resource


func _ready() -> void:
	order_spawn_timer = Timer.new()
	order_spawn_timer.wait_time = ORDER_SPAWN_INTERVAL
	order_spawn_timer.autostart = true
	order_spawn_timer.timeout.connect(_on_order_spawn_timer_timeout)
	add_child(order_spawn_timer)
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


func _process(_delta: float) -> void:
	_update_order_label()


func _get_available_orders() -> Array[Resource]:
	return ORDER_TYPES.filter(func(o: Resource) -> bool: return game_state.reputation >= o.min_reputation)


func _can_start_job() -> bool:
	return active_jobs.size() < game_state.station_count() and active_jobs.size() < game_state.worker_count


func _on_order_spawn_timer_timeout() -> void:
	if pending_orders.size() >= QUEUE_CAPACITY:
		return
	var available_orders := _get_available_orders()
	var order: Resource = available_orders[randi() % available_orders.size()]
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = ORDER_TIMEOUT
	add_child(timer)
	var pending := {"order": order, "timer": timer}
	timer.timeout.connect(_on_pending_order_expired.bind(pending))
	pending_orders.append(pending)
	timer.start()
	_update_labels()


func _on_pending_order_expired(pending: Dictionary) -> void:
	var order: Resource = pending["order"]
	pending_orders.erase(pending)
	(pending["timer"] as Timer).queue_free()
	game_state.add_reputation(-REPUTATION_LOSS_ON_EXPIRE)
	last_result_text = "流失：%s 超时未处理，口碑 -%d" % [order.car_name, REPUTATION_LOSS_ON_EXPIRE]
	_update_labels()


func _on_repair_button_pressed() -> void:
	if not _can_start_job() or pending_orders.is_empty():
		return
	var pending: Dictionary = pending_orders[0]
	pending_orders.erase(pending)
	(pending["timer"] as Timer).queue_free()
	var order: Resource = pending["order"]
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = order.repair_time
	add_child(timer)
	var job := {"order": order, "timer": timer}
	timer.timeout.connect(_on_job_complete.bind(job))
	active_jobs.append(job)
	timer.start()
	_update_labels()


func _on_job_complete(job: Dictionary) -> void:
	var order: Resource = job["order"]
	var actual_payout: int = roundi(order.payout * game_state.payout_multiplier())
	game_state.add_money(actual_payout)
	game_state.add_reputation(order.reputation_gain)
	last_result_text = "完成：%s，收入 %d，口碑 +%d" % [order.car_name, actual_payout, order.reputation_gain]
	active_jobs.erase(job)
	(job["timer"] as Timer).queue_free()
	_update_labels()


func _on_hire_button_pressed() -> void:
	game_state.hire_worker()


func _on_upgrade_button_pressed() -> void:
	game_state.upgrade_facility()


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
	var available_orders := _get_available_orders()
	current_practice_order = available_orders[randi() % available_orders.size()]
	practice_timer.wait_time = current_practice_order.repair_time
	practice_timer.start()


func _on_practice_complete() -> void:
	var payout: int = roundi(current_practice_order.payout * APPRENTICE_PAYOUT_RATE)
	var xp: int = current_practice_order.reputation_gain * APPRENTICE_XP_PER_REPUTATION
	game_state.add_money(payout)
	game_state.add_apprentice_xp(xp)
	practicing = false
	practice_button.disabled = false


func _on_exam_button_pressed() -> void:
	game_state.take_exam()


func _update_order_label() -> void:
	var lines: Array[String] = []
	lines.append("待处理订单：%d/%d" % [pending_orders.size(), QUEUE_CAPACITY])
	for pending in pending_orders:
		var order: Resource = pending["order"]
		var timer: Timer = pending["timer"]
		lines.append("- %s 剩余 %.1fs（超时流失）" % [order.car_name, timer.time_left])
	lines.append("工位使用中：%d/%d" % [active_jobs.size(), game_state.station_count()])
	for job in active_jobs:
		var order: Resource = job["order"]
		var timer: Timer = job["timer"]
		lines.append("- %s 剩余 %.1fs" % [order.car_name, timer.time_left])
	lines.append("最近动态：" + last_result_text)
	order_label.text = "\n".join(lines)


func _update_labels() -> void:
	money_label.text = "金钱: %d   口碑: %d" % [game_state.money, game_state.reputation]
	worker_label.text = "工人: %d（空闲 %d，月薪 %d/人）" % [
		game_state.worker_count,
		game_state.worker_count - active_jobs.size(),
		game_state.WORKER_SALARY_PER_HEAD,
	]
	hire_button.text = "雇佣工人 (%d)" % game_state.next_hire_cost()
	hire_button.disabled = game_state.money < game_state.next_hire_cost()
	facility_label.text = "设施等级: %d（工位数 %d）" % [game_state.facility_level, game_state.station_count()]
	upgrade_button.text = "升级工位 (%d)" % game_state.next_upgrade_cost()
	upgrade_button.disabled = game_state.money < game_state.next_upgrade_cost()
	repair_button.disabled = not _can_start_job() or pending_orders.is_empty()
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
