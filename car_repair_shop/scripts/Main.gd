extends Node2D

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
@onready var facility_label: Label = $UI/FacilityRow/FacilityLabel
@onready var upgrade_button: Button = $UI/FacilityRow/UpgradeButton
@onready var day_label: Label = $UI/DayLabel
@onready var hire_button: Button = $UI/WorkerHeaderRow/HireButton
@onready var worker_list_container: VBoxContainer = $UI/WorkerListContainer
@onready var hire_apprentice_button: Button = $UI/ApprenticeHeaderRow/HireApprenticeButton
@onready var apprentice_list_container: VBoxContainer = $UI/ApprenticeListContainer
@onready var station_list_container: VBoxContainer = $UI/StationListContainer
@onready var order_list_container: VBoxContainer = $UI/OrderListContainer
@onready var result_label: Label = $UI/ResultLabel
@onready var game_state: Node = get_node("/root/GameState")

# 每个工位一个进行中任务：{"order": Resource, "timer": Timer, "employee_id": int, "station_id": int}
var active_jobs: Array[Dictionary] = []
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
# 工位同工人/学徒一样只增不减，下标复用；待处理订单队列长度不超过 QUEUE_CAPACITY，
# 预先建好固定数量的行、按下标复用，不用的行隐藏即可，不需要动态增删节点
var _station_rows: Array[Dictionary] = []
var _order_rows: Array[Dictionary] = []
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
	hire_button.pressed.connect(_on_hire_button_pressed)
	upgrade_button.pressed.connect(_on_upgrade_button_pressed)
	hire_apprentice_button.pressed.connect(_on_hire_apprentice_button_pressed)
	game_state.money_changed.connect(_on_int_state_changed)
	game_state.reputation_changed.connect(_on_int_state_changed)
	game_state.facility_level_changed.connect(_on_int_state_changed)
	game_state.day_changed.connect(_on_int_state_changed)
	game_state.month_changed.connect(_on_int_state_changed)
	game_state.employees_changed.connect(_on_employees_changed)
	game_state.stations_changed.connect(_on_stations_changed)
	for i in range(QUEUE_CAPACITY):
		_order_rows.append(_create_order_row())
	_update_all()


func _process(_delta: float) -> void:
	_update_dynamic_texts()
	if _ui_dirty:
		_update_all()
		_ui_dirty = false


func _get_available_orders() -> Array[Resource]:
	return ORDER_TYPES.filter(func(o: Resource) -> bool: return game_state.reputation >= o.min_reputation)


func _find_by_employee(jobs: Array[Dictionary], employee_id: int) -> Dictionary:
	for j in jobs:
		if j["employee_id"] == employee_id:
			return j
	return {}


func _find_job_by_station(station_id: int) -> Dictionary:
	for j in active_jobs:
		if j.get("station_id", -1) == station_id:
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


func _on_assign_order_pressed(pending: Dictionary, station_option: OptionButton) -> void:
	if not pending_orders.has(pending) or station_option.selected < 0:
		return
	var station_id: int = station_option.get_item_metadata(station_option.selected)
	var station: Dictionary = game_state.get_station(station_id)
	if station.is_empty() or station["worker_id"] == -1:
		return
	var worker: Dictionary = game_state.get_employee(station["worker_id"])
	if worker.is_empty() or worker["busy"]:
		return
	_start_job(station_id, worker, pending)


func _start_job(station_id: int, worker: Dictionary, pending: Dictionary) -> void:
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

	var skill_value: int = worker["attributes"].get(order.primary_attribute, game_state.REPAIR_TIME_BASELINE_ATTR)
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = order.repair_time * game_state.repair_time_multiplier(skill_value)
	add_child(timer)
	var job := {
		"order": order, "timer": timer, "employee_id": worker["id"],
		"apprentice_id": apprentice_id, "station_id": station_id,
	}
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


func _on_bind_station_pressed(station_id: int, worker_option: OptionButton) -> void:
	if worker_option.selected < 0:
		return
	var worker_id: int = worker_option.get_item_metadata(worker_option.selected)
	game_state.bind_worker_station(worker_id, station_id)
	_ui_dirty = true


func _on_unbind_station_pressed(station_id: int) -> void:
	game_state.unbind_worker_station(station_id)
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


func _on_stations_changed() -> void:
	_ui_dirty = true


func _station_status_text(station: Dictionary) -> String:
	var worker_id: int = station["worker_id"]
	var bound_text := "，绑定工人 #%d" % worker_id if worker_id != -1 else "，未绑定"
	var job := _find_job_by_station(station["id"])
	var status_text := "空闲"
	if not job.is_empty():
		var order: Resource = job["order"]
		var timer: Timer = job["timer"]
		status_text = "工作中（%s 剩余 %.1fs）" % [order.car_name, timer.time_left]
	return "工位 #%d：%s%s" % [station["id"], status_text, bound_text]


# 倒计时文字每帧都在变，但只是给已存在的常驻 Label 重设 .text（不新建节点），
# 实测这个开销可以忽略（~26 微秒级），不需要挂在 _ui_dirty 脏标记后面
func _update_dynamic_texts() -> void:
	for i in range(QUEUE_CAPACITY):
		var entry: Dictionary = _order_rows[i]
		var row: HBoxContainer = entry["row"]
		if i < pending_orders.size():
			row.visible = true
			var pending: Dictionary = pending_orders[i]
			var order: Resource = pending["order"]
			var timer: Timer = pending["timer"]
			var text := "%d. %s 剩余 %.1fs" % [i + 1, order.car_name, timer.time_left]
			var label: Label = entry["label"]
			if label.text != text:
				label.text = text
		else:
			row.visible = false

	for i in range(_station_rows.size()):
		if i >= game_state.stations.size():
			break
		var entry: Dictionary = _station_rows[i]
		var text := _station_status_text(game_state.stations[i])
		var label: Label = entry["label"]
		if label.text != text:
			label.text = text


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

		var station_id: int = game_state.station_of_worker(w["id"])
		var station_text := "，工位 #%d" % station_id if station_id != -1 else ""

		var new_text := "工人 #%d：%s%s%s [%s]" % [w["id"], status_text, station_text, mentor_text, _format_attributes(w["attributes"])]
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
		"block": block, "status_label": status_label,
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
			var training := _find_by_employee(active_trainings, a["id"])
			var mentor_job := _find_mentor_job_by_apprentice(a["id"])
			if not training.is_empty():
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
		var new_status_text := "学徒 #%d：Lv%d，月薪 %d，待分配点数 %d，%s%s [%s]" % [
			a["id"],
			a["level"],
			game_state.apprentice_salary_for_level(a["level"]),
			pending_points,
			status_text,
			mentor_text,
			_format_attributes(a["attributes"]),
		]
		var status_label: Label = entry["status_label"]
		if status_label.text != new_status_text:
			status_label.text = new_status_text

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
	day_label.text = "第%d月 第%d天" % [game_state.month, game_state.day]
	hire_apprentice_button.text = "招学徒 (%d)" % game_state.next_apprentice_hire_cost()
	hire_apprentice_button.disabled = not game_state.can_hire_apprentice()
	var result_text := "最近动态：" + last_result_text
	if result_label.text != result_text:
		result_label.text = result_text


func _create_order_row() -> Dictionary:
	var row := HBoxContainer.new()
	var status_label := Label.new()
	row.add_child(status_label)
	var action_container := HBoxContainer.new()
	row.add_child(action_container)
	order_list_container.add_child(row)
	return {
		"row": row, "label": status_label, "action_container": action_container,
		"cached_pending": {}, "cached_idle_station_ids": [-2],
	}


func _rebuild_order_action_widgets(entry: Dictionary, pending: Dictionary, idle_station_ids: Array) -> void:
	var action_container: HBoxContainer = entry["action_container"]
	for child in action_container.get_children():
		child.queue_free()
	if not pending.is_empty():
		if idle_station_ids.is_empty():
			var hint_label := Label.new()
			hint_label.text = "无可用工位"
			action_container.add_child(hint_label)
		else:
			var station_option := OptionButton.new()
			for s_id in idle_station_ids:
				station_option.add_item("工位 #%d" % s_id)
				station_option.set_item_metadata(station_option.item_count - 1, s_id)
			action_container.add_child(station_option)

			var assign_button := Button.new()
			assign_button.text = "分配"
			assign_button.pressed.connect(_on_assign_order_pressed.bind(pending, station_option))
			action_container.add_child(assign_button)
	entry["cached_pending"] = pending
	entry["cached_idle_station_ids"] = idle_station_ids


func _update_pending_order_list() -> void:
	var idle_station_ids: Array = game_state.idle_stations().map(func(s: Dictionary) -> int: return s["id"])
	for i in range(QUEUE_CAPACITY):
		var entry: Dictionary = _order_rows[i]
		var pending: Dictionary = pending_orders[i] if i < pending_orders.size() else {}
		if pending != entry["cached_pending"] or idle_station_ids != entry["cached_idle_station_ids"]:
			_rebuild_order_action_widgets(entry, pending, idle_station_ids)


func _rebuild_station_action_widgets(entry: Dictionary, station_id: int, worker_id: int, available_worker_ids: Array) -> void:
	var action_container: HBoxContainer = entry["action_container"]
	for child in action_container.get_children():
		child.queue_free()
	if worker_id != -1:
		var unbind_button := Button.new()
		unbind_button.text = "解绑"
		unbind_button.pressed.connect(_on_unbind_station_pressed.bind(station_id))
		action_container.add_child(unbind_button)
	elif not available_worker_ids.is_empty():
		var worker_option := OptionButton.new()
		for w_id in available_worker_ids:
			worker_option.add_item("工人 #%d" % w_id)
			worker_option.set_item_metadata(worker_option.item_count - 1, w_id)
		action_container.add_child(worker_option)

		var bind_button := Button.new()
		bind_button.text = "绑定"
		bind_button.pressed.connect(_on_bind_station_pressed.bind(station_id, worker_option))
		action_container.add_child(bind_button)
	entry["bound_worker_id"] = worker_id
	entry["available_worker_ids"] = available_worker_ids


func _update_station_list() -> void:
	var bound_worker_ids: Array = game_state.bound_worker_ids()
	for i in range(game_state.stations.size()):
		var s: Dictionary = game_state.stations[i]
		var entry: Dictionary
		if i < _station_rows.size():
			entry = _station_rows[i]
		else:
			var row := HBoxContainer.new()
			var label := Label.new()
			row.add_child(label)
			var action_container := HBoxContainer.new()
			row.add_child(action_container)
			entry = {
				"row": row, "label": label, "action_container": action_container,
				"bound_worker_id": -2, "available_worker_ids": [-2],
			}
			_station_rows.append(entry)
			station_list_container.add_child(row)

		var worker_id: int = s["worker_id"]
		var available_worker_ids: Array = []
		if worker_id == -1:
			for w in game_state.workers():
				if not bound_worker_ids.has(w["id"]):
					available_worker_ids.append(w["id"])

		if worker_id != entry["bound_worker_id"] or available_worker_ids != entry["available_worker_ids"]:
			_rebuild_station_action_widgets(entry, s["id"], worker_id, available_worker_ids)


func _update_all() -> void:
	_update_labels()
	_update_worker_list()
	_update_apprentice_list()
	_update_station_list()
	_update_pending_order_list()
