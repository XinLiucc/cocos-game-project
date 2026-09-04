extends Node2D

# 占位数值：超时流失机制的超时时长/惩罚还是随手定的，之后再平衡。队列容量和生成间隔已经
# 按口碑分档（见 _order_tier 系列函数），档位门槛直接复用车型解锁的 0/10/25，不必再发明
# 一套新门槛——口碑判断用的是实时值，堆单超时扣口碑会自动把档位打回低档，形成自我稳定
const MAX_QUEUE_CAPACITY := 5
const QUEUE_CAPACITY_BY_TIER := [3, 4, 5]
const ORDER_SPAWN_INTERVAL_BY_TIER := [10.0, 8.0, 6.0]
# 2026-09-04：ORDER_TIMEOUT 本身仍是不随口碑档位走的死数字（那道老账还没动），但现在会被
# GameState.order_timeout_multiplier() 按在岗前台的"效率"属性再乘一道——两个轴互不影响
const ORDER_TIMEOUT := 15.0
const REPUTATION_LOSS_ON_EXPIRE_BY_TIER := [1, 2, 3]

const ORDER_TYPES: Array[Resource] = [
	preload("res://resources/orders/sedan.tres"),
	preload("res://resources/orders/suv.tres"),
	preload("res://resources/orders/sports_car.tres"),
]

const WORKER_TRAINING_COURSES: Array[Resource] = [
	preload("res://resources/courses/mechanical.tres"),
	preload("res://resources/courses/electrical.tres"),
	preload("res://resources/courses/bodywork.tres"),
]
const FRONT_DESK_TRAINING_COURSES: Array[Resource] = [
	preload("res://resources/courses/communication.tres"),
	preload("res://resources/courses/affinity.tres"),
	preload("res://resources/courses/efficiency.tres"),
]

const ATTRIBUTE_SHORT_NAMES := {
	"mechanical": "机械", "electrical": "电气", "bodywork": "钣喷",
	"communication": "沟通", "affinity": "亲和", "efficiency": "效率",
}

# 2026-09-01：工位可视化场景占位配色（几何图形，之后替换成像素美术）；三态面板底色按
# visual_state（0空闲/1已绑人/2工作中）索引，运行时建成 StyleBoxFlat 只建一次、按引用整体替换
const STATION_COLOR_EMPTY := Color(0.22, 0.22, 0.25)
const STATION_COLOR_IDLE := Color(0.20, 0.32, 0.48)
const STATION_COLOR_WORKING := Color(0.18, 0.42, 0.28)
const WORKER_TOKEN_COLOR := Color(0.90, 0.70, 0.20)
const APPRENTICE_TOKEN_COLOR := Color(0.55, 0.85, 0.95)
# 2026-09-02：前台是二元开关（front_desk_on_duty），没有坑位数/进行中订单/进度条这些概念，
# 不套工位盒子的三态样式，改成固定的"柜台"一条：只有关/开两态（暗灰/暖金），在岗学徒
# 显示成色块+名字挂在柜台上，人数不固定但只增不减
const FRONT_DESK_COLOR_OFF := Color(0.22, 0.22, 0.25)
const FRONT_DESK_COLOR_ON := Color(0.55, 0.42, 0.12)

@onready var money_label: Label = $UIRoot/Margin/Layout/UI/MoneyLabel
@onready var facility_label: Label = $UIRoot/Margin/Layout/UI/FacilityRow/FacilityLabel
@onready var upgrade_button: Button = $UIRoot/Margin/Layout/UI/FacilityRow/UpgradeButton
@onready var day_label: Label = $UIRoot/Margin/Layout/UI/DayLabel
@onready var hire_button: Button = $UIRoot/Margin/Layout/UI/WorkerHeaderRow/HireButton
@onready var worker_list_container: VBoxContainer = $UIRoot/Margin/Layout/UI/WorkerListContainer
@onready var hire_worker_apprentice_button: Button = $UIRoot/Margin/Layout/UI/ApprenticeHeaderRow/HireWorkerApprenticeButton
@onready var hire_front_desk_apprentice_button: Button = $UIRoot/Margin/Layout/UI/ApprenticeHeaderRow/HireFrontDeskApprenticeButton
@onready var apprentice_list_container: VBoxContainer = $UIRoot/Margin/Layout/UI/ApprenticeListContainer
@onready var floor_vbox: VBoxContainer = $UIRoot/Margin/Layout/StationFloorPanel/FloorMargin/FloorVBox
@onready var station_slots_container: VBoxContainer = $UIRoot/Margin/Layout/StationFloorPanel/FloorMargin/FloorVBox/StationSlotsContainer
@onready var order_list_container: VBoxContainer = $UIRoot/Margin/Layout/UI/OrderListContainer
@onready var result_label: Label = $UIRoot/Margin/Layout/UI/ResultLabel
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
# 工位同工人/学徒一样只增不减，下标复用；待处理订单队列长度不超过当前档位容量（最高
# MAX_QUEUE_CAPACITY），预先按上限建好固定数量的行、按下标复用，不用的行隐藏即可
var _station_rows: Array[Dictionary] = []
var _order_rows: Array[Dictionary] = []
# 三态面板底色，_ready() 里按 STATION_COLOR_* 常量建一次，索引即 visual_state
var _station_style_by_state: Array[StyleBoxFlat] = []
# 前台柜台的关/开两态底色，同上按引用整体替换
var _front_desk_style_by_state: Array[StyleBoxFlat] = []
# 前台柜台：{"panel":PanelContainer, "badges_container":HBoxContainer, "visual_state":-1}
var _front_desk_panel: Dictionary = {}
# 在岗前台学徒的色块+名字，按 game_state.apprentices() 下标复用（学徒只增不减，下标稳定），
# 不是前台赛道/未转正的学徒对应行直接隐藏
var _front_desk_badge_rows: Array[Dictionary] = []
# 单次操作里 game_state 信号可能连环触发好几次 _update_all()（比如接单要连续
# set_employee_busy 师傅+学徒两次），改成只打脏标记、_process() 里每帧最多重建一次列表，
# 避免一次点击引发好几倍的列表重建（这是"点接单修车卡顿"的根因）
var _ui_dirty := false


func _ready() -> void:
	for color in [STATION_COLOR_EMPTY, STATION_COLOR_IDLE, STATION_COLOR_WORKING]:
		var style := StyleBoxFlat.new()
		style.bg_color = color
		style.corner_radius_top_left = 6
		style.corner_radius_top_right = 6
		style.corner_radius_bottom_left = 6
		style.corner_radius_bottom_right = 6
		_station_style_by_state.append(style)
	for color in [FRONT_DESK_COLOR_OFF, FRONT_DESK_COLOR_ON]:
		var style := StyleBoxFlat.new()
		style.bg_color = color
		style.corner_radius_top_left = 6
		style.corner_radius_top_right = 6
		style.corner_radius_bottom_left = 6
		style.corner_radius_bottom_right = 6
		_front_desk_style_by_state.append(style)
	_front_desk_panel = _create_front_desk_panel()
	floor_vbox.add_child(_front_desk_panel["panel"])
	floor_vbox.move_child(_front_desk_panel["panel"], 0)
	order_spawn_timer = Timer.new()
	order_spawn_timer.wait_time = ORDER_SPAWN_INTERVAL_BY_TIER[0]
	order_spawn_timer.autostart = true
	order_spawn_timer.timeout.connect(_on_order_spawn_timer_timeout)
	add_child(order_spawn_timer)
	hire_button.pressed.connect(_on_hire_button_pressed)
	upgrade_button.pressed.connect(_on_upgrade_button_pressed)
	hire_worker_apprentice_button.pressed.connect(_on_hire_worker_apprentice_button_pressed)
	hire_front_desk_apprentice_button.pressed.connect(_on_hire_front_desk_apprentice_button_pressed)
	game_state.money_changed.connect(_on_int_state_changed)
	game_state.reputation_changed.connect(_on_int_state_changed)
	game_state.facility_level_changed.connect(_on_int_state_changed)
	game_state.day_changed.connect(_on_int_state_changed)
	game_state.month_changed.connect(_on_int_state_changed)
	game_state.employees_changed.connect(_on_employees_changed)
	game_state.stations_changed.connect(_on_stations_changed)
	for i in range(MAX_QUEUE_CAPACITY):
		_order_rows.append(_create_order_row())
	_update_all()


func _process(_delta: float) -> void:
	_update_dynamic_visuals()
	if _ui_dirty:
		_update_all()
		_ui_dirty = false


func _get_available_orders() -> Array[Resource]:
	return ORDER_TYPES.filter(func(o: Resource) -> bool: return game_state.reputation >= o.min_reputation)


# 档位直接等于当前解锁的车型数量（1/2/3），跟车型解锁门槛（0/10/25 口碑）天然对齐，
# 不用另外维护一套门槛常量
func _order_tier() -> int:
	return _get_available_orders().size() - 1


func _current_queue_capacity() -> int:
	return QUEUE_CAPACITY_BY_TIER[_order_tier()]


func _current_spawn_interval() -> float:
	return ORDER_SPAWN_INTERVAL_BY_TIER[_order_tier()] * game_state.front_desk_spawn_interval_multiplier()


func _current_reputation_loss_on_expire() -> int:
	return REPUTATION_LOSS_ON_EXPIRE_BY_TIER[_order_tier()]


# 档位 0 不批量；档位 1 有 20% 概率这次多生成 1 单；档位 2 有 30% 概率多 1 单、
# 另有 10% 概率多 2 单（先判定小概率的更大批量，避免区间算重）
func _roll_extra_order_count() -> int:
	var roll := randf()
	match _order_tier():
		1:
			if roll < 0.2:
				return 1
		2:
			if roll < 0.1:
				return 2
			elif roll < 0.4:
				return 1
	return 0


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
	# 下一轮生成间隔跟着这次算出的档位走，口碑档位变化时间隔会在下一次触发时才生效
	order_spawn_timer.wait_time = _current_spawn_interval()
	var capacity := _current_queue_capacity()
	if pending_orders.size() >= capacity:
		return
	var available_orders := _get_available_orders()
	var spawn_count: int = min(1 + _roll_extra_order_count(), capacity - pending_orders.size())
	for i in range(spawn_count):
		var order: Resource = available_orders[randi() % available_orders.size()]
		var timer := Timer.new()
		timer.one_shot = true
		timer.wait_time = ORDER_TIMEOUT * game_state.order_timeout_multiplier()
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
	var loss := _current_reputation_loss_on_expire()
	game_state.add_reputation(-loss)
	last_result_text = "流失：%s 超时未处理，口碑 -%d" % [order.car_name, loss]
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
	timer.wait_time = order.repair_time * game_state.repair_time_multiplier(skill_value) \
		* game_state.skill_time_multiplier(skill_value)
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
	var actual_reputation_gain: int = roundi(order.reputation_gain * game_state.reputation_gain_multiplier())
	game_state.add_money(actual_payout)
	game_state.add_reputation(actual_reputation_gain)
	var apprentice_id: int = job.get("apprentice_id", -1)
	if apprentice_id != -1:
		var points: int = game_state.mentor_points_earned()
		game_state.add_attribute_points(apprentice_id, points)
		game_state.set_employee_busy(apprentice_id, false)
		var apprentice: Dictionary = game_state.get_employee(apprentice_id)
		last_result_text = "带教完成：%s，收入 %d，口碑 +%d，学徒 %s 获得 %d 点属性点" % [
			order.car_name, actual_payout, actual_reputation_gain, apprentice["name"], points,
		]
	else:
		last_result_text = "完成：%s，收入 %d，口碑 +%d" % [order.car_name, actual_payout, actual_reputation_gain]
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


func _on_hire_worker_apprentice_button_pressed() -> void:
	game_state.hire_worker_apprentice()


func _on_hire_front_desk_apprentice_button_pressed() -> void:
	game_state.hire_front_desk_apprentice()


func _on_exam_button_pressed(employee_id: int) -> void:
	var result: Dictionary = game_state.take_exam(employee_id)
	if result.is_empty():
		return
	var e: Dictionary = game_state.get_employee(employee_id)
	if result["passed"]:
		last_result_text = "考试：学徒 %s 通过（概率%.0f%%），晋升至 Lv%d" % [e["name"], result["rate"], e["level"]]
	else:
		last_result_text = "考试：学徒 %s 未通过（概率%.0f%%），报名费 %d 打水漂" % [e["name"], result["rate"], game_state.EXAM_COST]
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


# 倒计时文字/进度条每帧都在变，但只是给已存在的常驻节点重设数值属性或短文字（不新建节点），
# 实测文字重设这个开销可以忽略（~26 微秒级），进度条数值更没有排版成本，不需要挂在 _ui_dirty
# 脏标记后面
func _update_dynamic_visuals() -> void:
	for i in range(MAX_QUEUE_CAPACITY):
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
		var job := _find_job_by_station(game_state.stations[i]["id"])
		if job.is_empty():
			continue
		var timer: Timer = job["timer"]
		var progress: float = 1.0 - timer.time_left / timer.wait_time if timer.wait_time > 0.0 else 1.0
		(entry["progress_bar"] as ProgressBar).value = progress
		(entry["time_label"] as Label).text = "%.1fs" % timer.time_left


const _ATTRIBUTE_ONE_CHAR := {
	"mechanical": "机", "electrical": "电", "bodywork": "钣",
	"communication": "沟", "affinity": "亲", "efficiency": "效",
}


func _format_attributes(attrs: Dictionary) -> String:
	var parts: Array[String] = []
	for key in attrs:
		var value: int = attrs[key]
		var marker := "★" if game_state.has_attribute_skill(value) else ""
		parts.append("%s%d%s" % [_ATTRIBUTE_ONE_CHAR[key], value, marker])
	return " ".join(parts)


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
			apprentice_option.add_item("学徒 %s" % game_state.get_employee(a_id)["name"])
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
					status_text = "带教中（%s，学徒%s）" % [order.car_name, game_state.get_employee(apprentice_id)["name"]]
				else:
					status_text = "工作中（%s）" % order.car_name
			else:
				status_text = "工作中"

		var mentor_id: int = w.get("mentor_apprentice_id", -1)
		var mentor_text := "，带教学徒 %s" % game_state.get_employee(mentor_id)["name"] if mentor_id != -1 else ""

		var station_id: int = game_state.station_of_worker(w["id"])
		var station_text := "，工位 #%d" % station_id if station_id != -1 else ""

		var new_text := "工人 %s：%s%s%s [%s]" % [w["name"], status_text, station_text, mentor_text, _format_attributes(w["attributes"])]
		var label: Label = entry["label"]
		if label.text != new_text:
			label.text = new_text

		var available_ids: Array = []
		if mentor_id == -1:
			for a in game_state.apprentices():
				if not bound_apprentice_ids.has(a["id"]) and not a.get("qualified", false):
					available_ids.append(a["id"])

		if mentor_id != entry["mentor_id"] or available_ids != entry["available_ids"]:
			_rebuild_worker_action_widgets(entry, w["id"], mentor_id, available_ids)


func _training_courses_for_track(track: String) -> Array[Resource]:
	return FRONT_DESK_TRAINING_COURSES if track == "front_desk" else WORKER_TRAINING_COURSES


func _attribute_keys_for_track(track: String) -> Array[String]:
	return game_state.FRONT_DESK_ATTRIBUTE_KEYS if track == "front_desk" else game_state.WORKER_ATTRIBUTE_KEYS


# 招募时就定型（工人学徒/前台学徒是两种不同职业，见 GameState.gd 2026-09-03 注释），
# 课程/属性分配按钮从这一刻起就是固定的那条线，不再需要运行时按"赛道选没选"切换
func _create_apprentice_row(apprentice_id: int, track: String) -> Dictionary:
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
	var courses := _training_courses_for_track(track)
	for course in courses:
		var train_button := Button.new()
		train_button.text = "训练：%s" % course.course_name
		train_button.pressed.connect(_on_train_button_pressed.bind(apprentice_id, course))
		course_row.add_child(train_button)
		course_buttons.append(train_button)

	var alloc_row := HBoxContainer.new()
	alloc_row.visible = false
	block.add_child(alloc_row)
	for key in _attribute_keys_for_track(track):
		var alloc_button := Button.new()
		alloc_button.text = "+%s" % ATTRIBUTE_SHORT_NAMES[key]
		alloc_button.pressed.connect(_on_allocate_button_pressed.bind(apprentice_id, key))
		alloc_row.add_child(alloc_button)

	apprentice_list_container.add_child(block)
	return {
		"block": block, "status_label": status_label,
		"exam_button": exam_button, "course_buttons": course_buttons, "courses": courses,
		"alloc_row": alloc_row,
	}


func _update_apprentice_list() -> void:
	var apprentices: Array[Dictionary] = game_state.apprentices()
	for i in range(apprentices.size()):
		var a: Dictionary = apprentices[i]
		var entry: Dictionary
		if i < _apprentice_rows.size():
			entry = _apprentice_rows[i]
		else:
			entry = _create_apprentice_row(a["id"], a.get("track", ""))
			_apprentice_rows.append(entry)

		var track: String = a.get("track", "")
		var qualified: bool = a.get("qualified", false)

		var status_text := "空闲"
		if a["busy"]:
			var training := _find_by_employee(active_trainings, a["id"])
			var own_job := _find_by_employee(active_jobs, a["id"])
			var mentor_job := _find_mentor_job_by_apprentice(a["id"])
			if not training.is_empty():
				var course: Resource = training["course"]
				status_text = "训练中（%s）" % course.course_name
			elif not own_job.is_empty():
				var order: Resource = own_job["order"]
				status_text = "工作中（%s）" % order.car_name
			elif not mentor_job.is_empty():
				var order: Resource = mentor_job["order"]
				status_text = "带教中（%s，师傅%s）" % [order.car_name, game_state.get_employee(mentor_job["employee_id"])["name"]]
			else:
				status_text = "忙碌中"
		elif qualified and track == "front_desk":
			status_text = "在岗中（自动分配）"

		var salary: int = game_state.qualified_apprentice_salary() if qualified else game_state.apprentice_salary_for_level(a["level"])
		var qualified_tag := "[已转正] " if qualified else ""
		var track_tag := ""
		if track == "worker":
			track_tag = "[工人赛道] "
		elif track == "front_desk":
			track_tag = "[前台赛道] "
		var pending_points: int = a.get("pending_points", 0)
		var mentor_worker_id: int = game_state.mentor_of(a["id"])
		var mentor_text := "，带教师傅 %s" % game_state.get_employee(mentor_worker_id)["name"] if mentor_worker_id != -1 else ""
		var station_id: int = game_state.station_of_worker(a["id"])
		var station_text := "，工位 #%d" % station_id if station_id != -1 else ""
		var new_status_text := "%s%s学徒 %s：Lv%d，月薪 %d，待分配点数 %d，%s%s%s [%s]" % [
			qualified_tag,
			track_tag,
			a["name"],
			a["level"],
			salary,
			pending_points,
			status_text,
			mentor_text,
			station_text,
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
		var courses: Array = entry["courses"]
		for j in range(courses.size()):
			(course_buttons[j] as Button).disabled = not game_state.can_start_training(a["id"], courses[j])

		(entry["alloc_row"] as HBoxContainer).visible = pending_points > 0


func _update_labels() -> void:
	money_label.text = "金钱: %d   口碑: %d   编制: %d人" % [
		game_state.money, game_state.reputation, game_state.total_headcount(),
	]
	hire_button.text = "雇佣工人 (%d)" % game_state.next_hire_cost()
	hire_button.disabled = not game_state.can_hire_worker()
	facility_label.text = "设施等级: %d（工位数 %d）" % [game_state.facility_level, game_state.station_count()]
	if game_state.is_facility_maxed():
		upgrade_button.text = "已满级"
		upgrade_button.disabled = true
	else:
		upgrade_button.text = "升级工位 (%d)" % game_state.next_upgrade_cost()
		upgrade_button.disabled = game_state.money < game_state.next_upgrade_cost()
	day_label.text = "第%d月 第%d天" % [game_state.month, game_state.day]
	hire_worker_apprentice_button.text = "招工人学徒 (%d)" % game_state.next_apprentice_hire_cost()
	hire_worker_apprentice_button.disabled = not game_state.can_hire_apprentice()
	hire_front_desk_apprentice_button.text = "招前台学徒 (%d)" % game_state.next_apprentice_hire_cost()
	hire_front_desk_apprentice_button.disabled = not game_state.can_hire_apprentice()
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
	for i in range(MAX_QUEUE_CAPACITY):
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
			worker_option.add_item("工人 %s" % game_state.get_employee(w_id)["name"])
			worker_option.set_item_metadata(worker_option.item_count - 1, w_id)
		action_container.add_child(worker_option)

		var bind_button := Button.new()
		bind_button.text = "绑定"
		bind_button.pressed.connect(_on_bind_station_pressed.bind(station_id, worker_option))
		action_container.add_child(bind_button)
	entry["bound_worker_id"] = worker_id
	entry["available_worker_ids"] = available_worker_ids


func _create_front_desk_panel() -> Dictionary:
	# 柜台是固定的一条（不随人数变多），跟工位盒子同款的 PanelContainer+MarginContainer 外壳，
	# 但只有关/开两态、没有坑位数/进度条概念；在岗学徒的色块+名字挂在 badges_container 里
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", _front_desk_style_by_state[0])

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 8)
	panel.add_child(margin)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(row)

	var title_label := Label.new()
	title_label.text = "前台"
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(title_label)

	var badges_container := HBoxContainer.new()
	badges_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(badges_container)

	return {"panel": panel, "badges_container": badges_container, "visual_state": -1}


func _create_front_desk_badge(badges_container: HBoxContainer) -> Dictionary:
	var row := HBoxContainer.new()
	row.visible = false
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var token := ColorRect.new()
	token.custom_minimum_size = Vector2(12, 12)
	token.color = APPRENTICE_TOKEN_COLOR
	token.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(token)
	var name_label := Label.new()
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(name_label)
	badges_container.add_child(row)
	return {"row": row, "label": name_label}


func _update_front_desk_panel() -> void:
	var state := 1 if game_state.front_desk_on_duty() else 0
	if state != _front_desk_panel["visual_state"]:
		(_front_desk_panel["panel"] as PanelContainer).add_theme_stylebox_override("panel", _front_desk_style_by_state[state])
		_front_desk_panel["visual_state"] = state

	var badges_container: HBoxContainer = _front_desk_panel["badges_container"]
	var apprentices: Array[Dictionary] = game_state.apprentices()
	for i in range(apprentices.size()):
		var a: Dictionary = apprentices[i]
		var entry: Dictionary
		if i < _front_desk_badge_rows.size():
			entry = _front_desk_badge_rows[i]
		else:
			entry = _create_front_desk_badge(badges_container)
			_front_desk_badge_rows.append(entry)

		var on_duty: bool = a.get("track", "") == "front_desk" and a.get("qualified", false)
		(entry["row"] as HBoxContainer).visible = on_duty
		if on_duty:
			var name_label: Label = entry["label"]
			if name_label.text != a["name"]:
				name_label.text = a["name"]


func _create_station_slot(i: int) -> Dictionary:
	# 工位插槽是一个盒子（PanelContainer 背景色随三态切换），里面依次是：状态行
	# （编号+工人色块+工人名+带教学徒小色块+车辆色块+倒计时）、进度条、绑定/分配操作区
	# （= 原来的 action_container，绑定/解绑逻辑完全复用 _rebuild_station_action_widgets）。
	# ColorRect/ProgressBar 默认 mouse_filter=STOP 会挡住点击，纯装饰部分都要显式设成 IGNORE
	var slot := PanelContainer.new()
	slot.mouse_filter = Control.MOUSE_FILTER_PASS
	slot.add_theme_stylebox_override("panel", _station_style_by_state[0])

	var slot_margin := MarginContainer.new()
	slot_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "top", "right", "bottom"]:
		slot_margin.add_theme_constant_override("margin_%s" % side, 8)
	slot.add_child(slot_margin)

	var slot_vbox := VBoxContainer.new()
	slot_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot_margin.add_child(slot_vbox)

	var top_row := HBoxContainer.new()
	top_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot_vbox.add_child(top_row)

	var id_label := Label.new()
	id_label.text = "#%d" % (i + 1)
	id_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_row.add_child(id_label)

	var worker_token := ColorRect.new()
	worker_token.custom_minimum_size = Vector2(20, 20)
	worker_token.color = WORKER_TOKEN_COLOR
	worker_token.mouse_filter = Control.MOUSE_FILTER_IGNORE
	worker_token.visible = false
	top_row.add_child(worker_token)

	var worker_name_label := Label.new()
	worker_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_row.add_child(worker_name_label)

	var apprentice_token := ColorRect.new()
	apprentice_token.custom_minimum_size = Vector2(12, 12)
	apprentice_token.color = APPRENTICE_TOKEN_COLOR
	apprentice_token.mouse_filter = Control.MOUSE_FILTER_IGNORE
	apprentice_token.visible = false
	top_row.add_child(apprentice_token)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_row.add_child(spacer)

	var car_token := ColorRect.new()
	car_token.custom_minimum_size = Vector2(36, 20)
	car_token.mouse_filter = Control.MOUSE_FILTER_IGNORE
	car_token.visible = false
	top_row.add_child(car_token)

	var time_label := Label.new()
	time_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	time_label.visible = false
	top_row.add_child(time_label)

	var progress_bar := ProgressBar.new()
	progress_bar.min_value = 0.0
	progress_bar.max_value = 1.0
	progress_bar.show_percentage = false
	progress_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	progress_bar.visible = false
	slot_vbox.add_child(progress_bar)

	var action_container := HBoxContainer.new()
	slot_vbox.add_child(action_container)

	station_slots_container.add_child(slot)

	return {
		"slot": slot, "worker_token": worker_token, "worker_name_label": worker_name_label,
		"apprentice_token": apprentice_token, "car_token": car_token, "time_label": time_label,
		"progress_bar": progress_bar, "action_container": action_container,
		"visual_state": -1, "bound_worker_id": -2, "available_worker_ids": [-2],
	}


func _update_station_floor() -> void:
	var bound_worker_ids: Array = game_state.bound_worker_ids()
	for i in range(game_state.stations.size()):
		var s: Dictionary = game_state.stations[i]
		var entry: Dictionary
		if i < _station_rows.size():
			entry = _station_rows[i]
		else:
			entry = _create_station_slot(i)
			_station_rows.append(entry)

		var worker_id: int = s["worker_id"]
		var job := _find_job_by_station(s["id"])
		var visual_state := 0 if worker_id == -1 else (2 if not job.is_empty() else 1)
		if visual_state != entry["visual_state"]:
			(entry["slot"] as PanelContainer).add_theme_stylebox_override("panel", _station_style_by_state[visual_state])
			entry["visual_state"] = visual_state

		(entry["worker_token"] as ColorRect).visible = worker_id != -1
		var worker_name: String = game_state.get_employee(worker_id)["name"] if worker_id != -1 else ""
		var worker_name_label: Label = entry["worker_name_label"]
		if worker_name_label.text != worker_name:
			worker_name_label.text = worker_name

		var has_job := not job.is_empty()
		(entry["car_token"] as ColorRect).visible = has_job
		(entry["time_label"] as Label).visible = has_job
		(entry["progress_bar"] as ProgressBar).visible = has_job
		(entry["apprentice_token"] as ColorRect).visible = has_job and job.get("apprentice_id", -1) != -1
		if has_job:
			(entry["car_token"] as ColorRect).color = (job["order"] as Resource).color

		var available_worker_ids: Array = []
		if worker_id == -1:
			for w in game_state.station_eligible_employees():
				if not bound_worker_ids.has(w["id"]):
					available_worker_ids.append(w["id"])

		if worker_id != entry["bound_worker_id"] or available_worker_ids != entry["available_worker_ids"]:
			_rebuild_station_action_widgets(entry, s["id"], worker_id, available_worker_ids)


func _try_auto_assign_pending_orders() -> void:
	if not game_state.front_desk_on_duty():
		return
	while not pending_orders.is_empty():
		var idle_stations: Array[Dictionary] = game_state.idle_stations()
		if idle_stations.is_empty():
			break
		var station: Dictionary = idle_stations[0]
		var worker: Dictionary = game_state.get_employee(station["worker_id"])
		_start_job(station["id"], worker, pending_orders[0])


func _update_all() -> void:
	_try_auto_assign_pending_orders()
	_update_labels()
	_update_worker_list()
	_update_apprentice_list()
	_update_front_desk_panel()
	_update_station_floor()
	_update_pending_order_list()
