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
# 中文文本的排版开销远高于英文（实测每个中文 Label 约 7ms，跟字体无关），列表每帧全量
# queue_free()+重建就是卡顿的真正根因。改成常驻行控件、按下标复用（员工只增不减，下标稳定），
# 每次只在算出来的文字真的变了时才写 .text（触发排版），按钮 disabled/visible 是纯布尔状态，
# 随便更新不会有排版开销。数组下标与 game_state.workers()/apprentices() 的返回顺序一一对应
var _worker_rows: Array[Dictionary] = []
var _apprentice_rows: Array[Dictionary] = []
# 单次操作里 game_state 信号可能连环触发好几次 _update_all()（比如接单要连续
# set_employee_busy 师傅+学徒两次），改成只打脏标记、_process() 里每帧最多重建一次列表，
# 避免一次点击引发好几倍的列表重建（这是"点接单修车卡顿"的根因）
var _ui_dirty := false


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
	if _ui_dirty:
		_update_all()
		_ui_dirty = false


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
	_ui_dirty = true


func _on_pending_order_expired(pending: Dictionary) -> void:
	var order: Resource = pending["order"]
	pending_orders.erase(pending)
	(pending["timer"] as Timer).queue_free()
	game_state.add_reputation(-REPUTATION_LOSS_ON_EXPIRE)
	last_result_text = "流失：%s 超时未处理，口碑 -%d" % [order.car_name, REPUTATION_LOSS_ON_EXPIRE]
	_ui_dirty = true


func _on_repair_button_pressed() -> void:
	if not _can_start_job() or pending_orders.is_empty():
		return
	var worker: Dictionary = game_state.idle_workers()[0]
	var pending: Dictionary = pending_orders[0]
	pending_orders.erase(pending)
	(pending["timer"] as Timer).queue_free()
	var order: Resource = pending["order"]

	# 师傅带着学徒是长期绑定关系：只要绑定的学徒此刻空闲，接单时自动一起算带教，
	# 不需要玩家每次单独选人触发；学徒不空闲（在实习/训练/考试）时师傅照常独自接单
	var apprentice_id: int = worker.get("mentor_apprentice_id", -1)
	if apprentice_id != -1:
		var apprentice: Dictionary = game_state.get_employee(apprentice_id)
		if apprentice.is_empty() or apprentice["busy"]:
			apprentice_id = -1

	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = order.repair_time
	if apprentice_id != -1:
		timer.wait_time *= (1.0 - game_state.MENTOR_TIME_REDUCTION_RATIO)
	add_child(timer)
	var job := {"order": order, "timer": timer, "employee_id": worker["id"], "apprentice_id": apprentice_id}
	timer.timeout.connect(_on_job_complete.bind(job))
	active_jobs.append(job)
	game_state.set_employee_busy(worker["id"], true)
	if apprentice_id != -1:
		game_state.set_employee_busy(apprentice_id, true)
	timer.start()
	_ui_dirty = true


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
	_ui_dirty = true


func _find_mentor_job_by_apprentice(apprentice_id: int) -> Dictionary:
	for j in active_jobs:
		if j.get("apprentice_id", -1) == apprentice_id:
			return j
	return {}


func _on_bind_mentor_pressed(worker_id: int, apprentice_option: OptionButton) -> void:
	if apprentice_option.selected < 0:
		return
	var apprentice_id: int = apprentice_option.get_item_metadata(apprentice_option.selected)
	game_state.bind_mentor(worker_id, apprentice_id)
	_ui_dirty = true


func _on_unbind_mentor_pressed(worker_id: int) -> void:
	game_state.unbind_mentor(worker_id)
	_ui_dirty = true


func _on_allocate_button_pressed(apprentice_id: int, attribute_key: String) -> void:
	game_state.allocate_attribute_point(apprentice_id, attribute_key)
	_ui_dirty = true


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
	_ui_dirty = true


func _on_practice_complete(practice: Dictionary) -> void:
	var order: Resource = practice["order"]
	var payout: int = roundi(order.payout * APPRENTICE_PAYOUT_RATE)
	var xp: int = order.reputation_gain * APPRENTICE_XP_PER_REPUTATION
	game_state.add_money(payout)
	game_state.add_apprentice_xp(practice["employee_id"], xp)
	active_practices.erase(practice)
	(practice["timer"] as Timer).queue_free()
	game_state.set_employee_busy(practice["employee_id"], false)
	_ui_dirty = true


func _on_exam_button_pressed(employee_id: int) -> void:
	var result: Dictionary = game_state.take_exam(employee_id)
	if result.is_empty():
		return
	if result["passed"]:
		var e: Dictionary = game_state.get_employee(employee_id)
		last_result_text = "考试：学徒 #%d 通过（概率%.0f%%），晋升至 Lv%d" % [employee_id, result["rate"], e["level"]]
	else:
		last_result_text = "考试：学徒 #%d 未通过（概率%.0f%%），报名费 %d 打水漂" % [employee_id, result["rate"], game_state.EXAM_COST]
	_ui_dirty = true


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
	_ui_dirty = true


func _on_training_complete(training: Dictionary) -> void:
	var course: Resource = training["course"]
	game_state.complete_training(training["employee_id"], course)
	active_trainings.erase(training)
	(training["timer"] as Timer).queue_free()
	_ui_dirty = true


func _on_int_state_changed(_value: int) -> void:
	_ui_dirty = true


func _on_employees_changed() -> void:
	_ui_dirty = true


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


func _rebuild_worker_action_widgets(entry: Dictionary, worker_id: int, mentor_id: int, available_ids: Array) -> void:
	var action_container: HBoxContainer = entry["action_container"]
	for child in action_container.get_children():
		child.queue_free()
	if mentor_id != -1:
		var unbind_button := Button.new()
		unbind_button.text = "解除带教"
		unbind_button.pressed.connect(_on_unbind_mentor_pressed.bind(worker_id))
		action_container.add_child(unbind_button)
	elif not available_ids.is_empty():
		var apprentice_option := OptionButton.new()
		for a_id in available_ids:
			apprentice_option.add_item("学徒 #%d" % a_id)
			apprentice_option.set_item_metadata(apprentice_option.item_count - 1, a_id)
		action_container.add_child(apprentice_option)

		var bind_button := Button.new()
		bind_button.text = "带徒弟"
		bind_button.pressed.connect(_on_bind_mentor_pressed.bind(worker_id, apprentice_option))
		action_container.add_child(bind_button)
	entry["mentor_id"] = mentor_id
	entry["available_ids"] = available_ids


func _update_worker_list() -> void:
	var bound_apprentice_ids: Array = game_state.bound_apprentice_ids()
	var workers: Array[Dictionary] = game_state.workers()
	for i in range(workers.size()):
		var w: Dictionary = workers[i]
		var entry: Dictionary
		if i < _worker_rows.size():
			entry = _worker_rows[i]
		else:
			var row := HBoxContainer.new()
			var new_label := Label.new()
			row.add_child(new_label)
			var action_container := HBoxContainer.new()
			row.add_child(action_container)
			entry = {"row": row, "label": new_label, "action_container": action_container, "mentor_id": -2, "available_ids": [-2]}
			_worker_rows.append(entry)
			worker_list_container.add_child(row)

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

		var mentor_id: int = w.get("mentor_apprentice_id", -1)
		var mentor_text := "，带教学徒 #%d" % mentor_id if mentor_id != -1 else ""

		var new_text := "工人 #%d：%s%s [%s]" % [w["id"], status_text, mentor_text, _format_attributes(w["attributes"])]
		var label: Label = entry["label"]
		if label.text != new_text:
			label.text = new_text

		var available_ids: Array = []
		if mentor_id == -1:
			for a in game_state.apprentices():
				if not bound_apprentice_ids.has(a["id"]):
					available_ids.append(a["id"])

		if mentor_id != entry["mentor_id"] or available_ids != entry["available_ids"]:
			_rebuild_worker_action_widgets(entry, w["id"], mentor_id, available_ids)


func _create_apprentice_row(apprentice_id: int) -> Dictionary:
	# 学徒行按钮已经超过单行 HBoxContainer 能容纳的宽度（超出窗口会点不到），
	# 拆成多个子行的 VBoxContainer：状态行 / 训练课程行 / 属性分配行。
	# 训练课程按钮文字固定不变（课程列表不会变），属性分配按钮文字也固定不变——
	# 两者都只建一次，之后只切换 disabled/visible，不再重新赋值 .text（避免中文排版开销）
	var block := VBoxContainer.new()
	var row := HBoxContainer.new()
	block.add_child(row)

	var status_label := Label.new()
	row.add_child(status_label)

	var practice_button := Button.new()
	practice_button.text = "实习"
	practice_button.pressed.connect(_on_practice_button_pressed.bind(apprentice_id))
	row.add_child(practice_button)

	var exam_button := Button.new()
	exam_button.pressed.connect(_on_exam_button_pressed.bind(apprentice_id))
	row.add_child(exam_button)

	var course_row := HBoxContainer.new()
	block.add_child(course_row)
	var course_buttons: Array[Button] = []
	for course in TRAINING_COURSES:
		var train_button := Button.new()
		train_button.text = "训练：%s" % course.course_name
		train_button.pressed.connect(_on_train_button_pressed.bind(apprentice_id, course))
		course_row.add_child(train_button)
		course_buttons.append(train_button)

	var alloc_row := HBoxContainer.new()
	alloc_row.visible = false
	block.add_child(alloc_row)
	for key in game_state.ATTRIBUTE_KEYS:
		var alloc_button := Button.new()
		alloc_button.text = "+%s" % ATTRIBUTE_SHORT_NAMES[key]
		alloc_button.pressed.connect(_on_allocate_button_pressed.bind(apprentice_id, key))
		alloc_row.add_child(alloc_button)

	apprentice_list_container.add_child(block)
	return {
		"block": block, "status_label": status_label, "practice_button": practice_button,
		"exam_button": exam_button, "course_buttons": course_buttons, "alloc_row": alloc_row,
	}


func _update_apprentice_list() -> void:
	var apprentices: Array[Dictionary] = game_state.apprentices()
	for i in range(apprentices.size()):
		var a: Dictionary = apprentices[i]
		var entry: Dictionary
		if i < _apprentice_rows.size():
			entry = _apprentice_rows[i]
		else:
			entry = _create_apprentice_row(a["id"])
			_apprentice_rows.append(entry)

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
		var mentor_worker_id: int = game_state.mentor_of(a["id"])
		var mentor_text := "，带教师傅 #%d" % mentor_worker_id if mentor_worker_id != -1 else ""
		var new_status_text := "学徒 #%d：Lv%d，经验 %d/%d，月薪 %d，待分配点数 %d，%s%s [%s]" % [
			a["id"],
			a["level"],
			a["xp"],
			game_state.apprentice_xp_required_for_level(a["level"]),
			game_state.apprentice_salary_for_level(a["level"]),
			pending_points,
			status_text,
			mentor_text,
			_format_attributes(a["attributes"]),
		]
		var status_label: Label = entry["status_label"]
		if status_label.text != new_status_text:
			status_label.text = new_status_text

		var practice_button: Button = entry["practice_button"]
		practice_button.disabled = a["busy"]

		var exam_button: Button = entry["exam_button"]
		var new_exam_text := "考试 (%d，通过率%.0f%%)" % [game_state.EXAM_COST, game_state.exam_pass_rate(a["id"])]
		if exam_button.text != new_exam_text:
			exam_button.text = new_exam_text
		exam_button.disabled = not game_state.can_take_exam(a["id"])

		var course_buttons: Array = entry["course_buttons"]
		for j in range(TRAINING_COURSES.size()):
			(course_buttons[j] as Button).disabled = not game_state.can_start_training(a["id"], TRAINING_COURSES[j])

		(entry["alloc_row"] as HBoxContainer).visible = pending_points > 0


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
