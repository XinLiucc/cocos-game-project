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

const TRAINING_COURSES: Array[Resource] = [
	preload("res://resources/courses/mechanical.tres"),
	preload("res://resources/courses/electrical.tres"),
	preload("res://resources/courses/bodywork.tres"),
	preload("res://resources/courses/precision.tres"),
	preload("res://resources/courses/communication.tres"),
]

const ATTRIBUTE_SHORT_NAMES := {
	"mechanical": "机械", "electrical": "电气", "bodywork": "钣喷",
	"precision": "细心", "communication": "沟通",
}

@onready var money_label: Label = $UI/MoneyLabel
@onready var order_label: Label = $UI/OrderLabel
@onready var repair_button: Button = $UI/RepairButton
@onready var facility_label: Label = $UI/FacilityRow/FacilityLabel
@onready var upgrade_button: Button = $UI/FacilityRow/UpgradeButton
@onready var day_label: Label = $UI/DayLabel
@onready var hire_button: Button = $UI/WorkerHeaderRow/HireButton
@onready var worker_list_container: VBoxContainer = $UI/WorkerListContainer
@onready var hire_apprentice_button: Button = $UI/ApprenticeHeaderRow/HireApprenticeButton
@onready var apprentice_list_container: VBoxContainer = $UI/ApprenticeListContainer
@onready var game_state: Node = get_node("/root/GameState")

# 每个工位一个进行中任务：{"order": Resource, "timer": Timer, "employee_id": int}
var active_jobs: Array[Dictionary] = []
# 每个学徒最多一个进行中实习：{"order": Resource, "timer": Timer, "employee_id": int}
var active_practices: Array[Dictionary] = []
# 每个学徒最多一个进行中训练：{"course": Resource, "timer": Timer, "employee_id": int}
var active_trainings: Array[Dictionary] = []
# 待处理订单队列：{"order": Resource, "timer": Timer}，timer 到期即流失
var pending_orders: Array[Dictionary] = []
var order_spawn_timer: Timer
var last_result_text := "尚未完成过订单"


func _ready() -> void:
	order_spawn_timer = Timer.new()
	order_spawn_timer.wait_time = ORDER_SPAWN_INTERVAL
	order_spawn_timer.autostart = true
	order_spawn_timer.timeout.connect(_on_order_spawn_timer_timeout)
	add_child(order_spawn_timer)
	repair_button.pressed.connect(_on_repair_button_pressed)
	hire_button.pressed.connect(_on_hire_button_pressed)
	upgrade_button.pressed.connect(_on_upgrade_button_pressed)
	hire_apprentice_button.pressed.connect(_on_hire_apprentice_button_pressed)
	game_state.money_changed.connect(_on_int_state_changed)
	game_state.reputation_changed.connect(_on_int_state_changed)
	game_state.facility_level_changed.connect(_on_int_state_changed)
	game_state.day_changed.connect(_on_int_state_changed)
	game_state.month_changed.connect(_on_int_state_changed)
	game_state.employees_changed.connect(_on_employees_changed)
	_update_all()


func _process(_delta: float) -> void:
	_update_order_label()


func _get_available_orders() -> Array[Resource]:
	return ORDER_TYPES.filter(func(o: Resource) -> bool: return game_state.reputation >= o.min_reputation)


func _can_start_job() -> bool:
	return active_jobs.size() < game_state.station_count() and not game_state.idle_workers().is_empty()


func _find_by_employee(jobs: Array[Dictionary], employee_id: int) -> Dictionary:
	for j in jobs:
		if j["employee_id"] == employee_id:
			return j
	return {}


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
	_update_all()


func _on_pending_order_expired(pending: Dictionary) -> void:
	var order: Resource = pending["order"]
	pending_orders.erase(pending)
	(pending["timer"] as Timer).queue_free()
	game_state.add_reputation(-REPUTATION_LOSS_ON_EXPIRE)
	last_result_text = "流失：%s 超时未处理，口碑 -%d" % [order.car_name, REPUTATION_LOSS_ON_EXPIRE]
	_update_all()


func _on_repair_button_pressed() -> void:
	if not _can_start_job() or pending_orders.is_empty():
		return
	var worker: Dictionary = game_state.idle_workers()[0]
	var pending: Dictionary = pending_orders[0]
	pending_orders.erase(pending)
	(pending["timer"] as Timer).queue_free()
	var order: Resource = pending["order"]
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = order.repair_time
	add_child(timer)
	var job := {"order": order, "timer": timer, "employee_id": worker["id"]}
	timer.timeout.connect(_on_job_complete.bind(job))
	active_jobs.append(job)
	game_state.set_employee_busy(worker["id"], true)
	timer.start()
	_update_all()


func _on_job_complete(job: Dictionary) -> void:
	var order: Resource = job["order"]
	var actual_payout: int = roundi(order.payout * game_state.payout_multiplier())
	game_state.add_money(actual_payout)
	game_state.add_reputation(order.reputation_gain)
	var apprentice_id: int = job.get("apprentice_id", -1)
	if apprentice_id != -1:
		var master: Dictionary = game_state.get_employee(job["employee_id"])
		var points: int = game_state.mentor_points_earned(master["attributes"]["precision"])
		game_state.add_attribute_points(apprentice_id, points)
		game_state.set_employee_busy(apprentice_id, false)
		last_result_text = "带教完成：%s，收入 %d，口碑 +%d，学徒 #%d 获得 %d 点属性点" % [
			order.car_name, actual_payout, order.reputation_gain, apprentice_id, points,
		]
	else:
		last_result_text = "完成：%s，收入 %d，口碑 +%d" % [order.car_name, actual_payout, order.reputation_gain]
	active_jobs.erase(job)
	(job["timer"] as Timer).queue_free()
	game_state.set_employee_busy(job["employee_id"], false)
	_update_all()


func _find_mentor_job_by_apprentice(apprentice_id: int) -> Dictionary:
	for j in active_jobs:
		if j.get("apprentice_id", -1) == apprentice_id:
			return j
	return {}


func _on_mentor_button_pressed(apprentice_id: int, worker_option: OptionButton) -> void:
	if worker_option.selected < 0:
		return
	var worker_id: int = worker_option.get_item_metadata(worker_option.selected)
	if not game_state.can_start_mentoring(worker_id, apprentice_id):
		return
	if active_jobs.size() >= game_state.station_count() or pending_orders.is_empty():
		return
	var pending: Dictionary = pending_orders[0]
	pending_orders.erase(pending)
	(pending["timer"] as Timer).queue_free()
	var order: Resource = pending["order"]
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = order.repair_time * (1.0 - game_state.MENTOR_TIME_REDUCTION_RATIO)
	add_child(timer)
	var job := {"order": order, "timer": timer, "employee_id": worker_id, "apprentice_id": apprentice_id}
	timer.timeout.connect(_on_job_complete.bind(job))
	active_jobs.append(job)
	game_state.set_employee_busy(worker_id, true)
	game_state.set_employee_busy(apprentice_id, true)
	timer.start()
	_update_all()


func _on_allocate_button_pressed(apprentice_id: int, attribute_key: String) -> void:
	game_state.allocate_attribute_point(apprentice_id, attribute_key)
	_update_all()


func _on_hire_button_pressed() -> void:
	game_state.hire_worker()


func _on_upgrade_button_pressed() -> void:
	game_state.upgrade_facility()


func _on_hire_apprentice_button_pressed() -> void:
	game_state.hire_apprentice()


func _on_practice_button_pressed(employee_id: int) -> void:
	var e: Dictionary = game_state.get_employee(employee_id)
	if e.is_empty() or e["busy"]:
		return
	var available_orders := _get_available_orders()
	var order: Resource = available_orders[randi() % available_orders.size()]
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = order.repair_time
	add_child(timer)
	var practice := {"order": order, "timer": timer, "employee_id": employee_id}
	timer.timeout.connect(_on_practice_complete.bind(practice))
	active_practices.append(practice)
	game_state.set_employee_busy(employee_id, true)
	timer.start()
	_update_all()


func _on_practice_complete(practice: Dictionary) -> void:
	var order: Resource = practice["order"]
	var payout: int = roundi(order.payout * APPRENTICE_PAYOUT_RATE)
	var xp: int = order.reputation_gain * APPRENTICE_XP_PER_REPUTATION
	game_state.add_money(payout)
	game_state.add_apprentice_xp(practice["employee_id"], xp)
	active_practices.erase(practice)
	(practice["timer"] as Timer).queue_free()
	game_state.set_employee_busy(practice["employee_id"], false)
	_update_all()


func _on_exam_button_pressed(employee_id: int) -> void:
	var result: Dictionary = game_state.take_exam(employee_id)
	if result.is_empty():
		return
	if result["passed"]:
		var e: Dictionary = game_state.get_employee(employee_id)
		last_result_text = "考试：学徒 #%d 通过（概率%.0f%%），晋升至 Lv%d" % [employee_id, result["rate"], e["level"]]
	else:
		last_result_text = "考试：学徒 #%d 未通过（概率%.0f%%），报名费 %d 打水漂" % [employee_id, result["rate"], game_state.EXAM_COST]
	_update_all()


func _on_train_button_pressed(employee_id: int, course: Resource) -> void:
	if not game_state.start_training(employee_id, course):
		return
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = course.duration
	add_child(timer)
	var training := {"course": course, "timer": timer, "employee_id": employee_id}
	timer.timeout.connect(_on_training_complete.bind(training))
	active_trainings.append(training)
	timer.start()
	_update_all()


func _on_training_complete(training: Dictionary) -> void:
	var course: Resource = training["course"]
	game_state.complete_training(training["employee_id"], course)
	active_trainings.erase(training)
	(training["timer"] as Timer).queue_free()
	_update_all()


func _on_int_state_changed(_value: int) -> void:
	_update_all()


func _on_employees_changed() -> void:
	_update_all()


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


func _format_attributes(attrs: Dictionary) -> String:
	return "机%d 电%d 钣%d 细%d 沟%d" % [
		attrs["mechanical"], attrs["electrical"], attrs["bodywork"], attrs["precision"], attrs["communication"],
	]


func _update_worker_list() -> void:
	for child in worker_list_container.get_children():
		child.queue_free()
	for w in game_state.workers():
		var row := Label.new()
		var status_text := "空闲"
		if w["busy"]:
			var job := _find_by_employee(active_jobs, w["id"])
			if not job.is_empty():
				var order: Resource = job["order"]
				var apprentice_id: int = job.get("apprentice_id", -1)
				if apprentice_id != -1:
					status_text = "带教中（%s，学徒#%d）" % [order.car_name, apprentice_id]
				else:
					status_text = "工作中（%s）" % order.car_name
			else:
				status_text = "工作中"
		row.text = "工人 #%d：%s [%s]" % [w["id"], status_text, _format_attributes(w["attributes"])]
		worker_list_container.add_child(row)


func _update_apprentice_list() -> void:
	for child in apprentice_list_container.get_children():
		child.queue_free()
	for a in game_state.apprentices():
		# 学徒行按钮已经超过单行 HBoxContainer 能容纳的宽度（超出窗口会点不到），
		# 拆成多个子行的 VBoxContainer：状态行 / 训练课程行 / 带教配对行 / 属性分配行
		var block := VBoxContainer.new()
		var row := HBoxContainer.new()
		block.add_child(row)

		var status_text := "空闲"
		if a["busy"]:
			var practice := _find_by_employee(active_practices, a["id"])
			var training := _find_by_employee(active_trainings, a["id"])
			var mentor_job := _find_mentor_job_by_apprentice(a["id"])
			if not practice.is_empty():
				var order: Resource = practice["order"]
				status_text = "实习中（%s）" % order.car_name
			elif not training.is_empty():
				var course: Resource = training["course"]
				status_text = "训练中（%s）" % course.course_name
			elif not mentor_job.is_empty():
				var order: Resource = mentor_job["order"]
				status_text = "带教中（%s，师傅#%d）" % [order.car_name, mentor_job["employee_id"]]
			else:
				status_text = "忙碌中"

		var pending_points: int = a.get("pending_points", 0)
		var status_label := Label.new()
		status_label.text = "学徒 #%d：Lv%d，经验 %d/%d，月薪 %d，待分配点数 %d，%s [%s]" % [
			a["id"],
			a["level"],
			a["xp"],
			game_state.apprentice_xp_required_for_level(a["level"]),
			game_state.apprentice_salary_for_level(a["level"]),
			pending_points,
			status_text,
			_format_attributes(a["attributes"]),
		]
		row.add_child(status_label)

		var practice_button := Button.new()
		practice_button.text = "实习"
		practice_button.disabled = a["busy"]
		practice_button.pressed.connect(_on_practice_button_pressed.bind(a["id"]))
		row.add_child(practice_button)

		var exam_button := Button.new()
		exam_button.text = "考试 (%d，通过率%.0f%%)" % [game_state.EXAM_COST, game_state.exam_pass_rate(a["id"])]
		exam_button.disabled = not game_state.can_take_exam(a["id"])
		exam_button.pressed.connect(_on_exam_button_pressed.bind(a["id"]))
		row.add_child(exam_button)

		var course_row := HBoxContainer.new()
		block.add_child(course_row)
		for course in TRAINING_COURSES:
			var train_button := Button.new()
			train_button.text = "训练：%s" % course.course_name
			train_button.disabled = not game_state.can_start_training(a["id"], course)
			train_button.pressed.connect(_on_train_button_pressed.bind(a["id"], course))
			course_row.add_child(train_button)

		if not a["busy"]:
			var idle_workers: Array[Dictionary] = game_state.idle_workers()
			if not idle_workers.is_empty():
				var mentor_row := HBoxContainer.new()
				block.add_child(mentor_row)

				var worker_option := OptionButton.new()
				for w in idle_workers:
					worker_option.add_item("师傅 #%d" % w["id"])
					worker_option.set_item_metadata(worker_option.item_count - 1, w["id"])
				mentor_row.add_child(worker_option)

				var mentor_button := Button.new()
				mentor_button.text = "带教修车"
				mentor_button.disabled = active_jobs.size() >= game_state.station_count() or pending_orders.is_empty()
				mentor_button.pressed.connect(_on_mentor_button_pressed.bind(a["id"], worker_option))
				mentor_row.add_child(mentor_button)

		if pending_points > 0:
			var alloc_row := HBoxContainer.new()
			block.add_child(alloc_row)
			for key in game_state.ATTRIBUTE_KEYS:
				var alloc_button := Button.new()
				alloc_button.text = "+%s" % ATTRIBUTE_SHORT_NAMES[key]
				alloc_button.pressed.connect(_on_allocate_button_pressed.bind(a["id"], key))
				alloc_row.add_child(alloc_button)

		apprentice_list_container.add_child(block)


func _update_labels() -> void:
	money_label.text = "金钱: %d   口碑: %d" % [game_state.money, game_state.reputation]
	hire_button.text = "雇佣工人 (%d)" % game_state.next_hire_cost()
	hire_button.disabled = game_state.money < game_state.next_hire_cost()
	facility_label.text = "设施等级: %d（工位数 %d）" % [game_state.facility_level, game_state.station_count()]
	upgrade_button.text = "升级工位 (%d)" % game_state.next_upgrade_cost()
	upgrade_button.disabled = game_state.money < game_state.next_upgrade_cost()
	repair_button.disabled = not _can_start_job() or pending_orders.is_empty()
	day_label.text = "第%d月 第%d天" % [game_state.month, game_state.day]
	hire_apprentice_button.text = "招学徒 (%d)" % game_state.next_apprentice_hire_cost()
	hire_apprentice_button.disabled = not game_state.can_hire_apprentice()


func _update_all() -> void:
	_update_labels()
	_update_worker_list()
	_update_apprentice_list()
