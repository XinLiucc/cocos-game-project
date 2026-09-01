extends Node

signal money_changed(new_amount: int)
signal reputation_changed(new_amount: int)
signal facility_level_changed(new_level: int)
signal day_changed(new_day: int)
signal month_changed(new_month: int)
signal employees_changed()
signal stations_changed()

# 2026-08-20：招人价格固定，不再随人数递增——更贴近现实（不会因为多雇一个人就把工资
# 行情抬高）。约束招人数量的是工资本身：工位数固定，多雇的人只能当备用/轮班，工资照发，
# 雇多了自然亏钱，不需要额外的人数硬上限（2026-09-01 去掉了声望驱动的编制上限）
const WORKER_HIRE_COST := 100
const WORKER_SALARY_PER_HEAD := 20

# 占位数值：设施升级机制也没细化，先用递增费用 + 固定收入加成代替
# 2026-08-06：设施升级还决定"工位数"（同时能干活的人数上限），worker_count 只是员工总数，
# 两者解耦——员工可以比工位多（备用），但同时干活人数被工位卡住
const BASE_UPGRADE_COST := 150
const UPGRADE_COST_STEP := 100
const FACILITY_PAYOUT_BONUS := 0.15
const BASE_STATION_COUNT := 1
const STATION_PER_FACILITY_LEVEL := 1
# 2026-08-18：工位数封顶在 5 个，设施等级也跟着封顶（到顶即终局形态，收入倍率定格）——
# 不封顶的话工位/费用会无限往上滚，游戏没有"设施线已经点满"的终点感
const MAX_STATION_COUNT := 5

# 2026-09-01：去掉了曾经的声望驱动编制上限（08-20，理由是"避免招了人却没工位可用"）——
# 工位数本身就是产能硬约束（08-06），工资是更自然的经济制衡，多雇人自己会亏钱，
# 不需要额外的人数硬限制

# 占位数值：一天等于多少秒，开发阶段调短方便测试，正式数值以后再定
const DAYS_PER_MONTH := 30
var seconds_per_day: float = 3.0

# 占位数值：学徒工资/考试门槛还是随手定的，之后要重新平衡
const APPRENTICE_HIRE_COST := 30
const APPRENTICE_SALARY_BASE := 15
const APPRENTICE_SALARY_LEVEL_STEP := 5

# 2026-08-09：员工属性系统骨架。5 项属性（机械/电气/钣喷偏硬技能，细心/沟通偏软技能）。
# 2026-08-10：区分工人/学徒的起始值——工人是已出师的熟练工，随机值贴近一级考试线；
# 学徒是白纸，五项统一从最低值起步，全靠训练/带教走方向分化。
# 考试通过率、车型属性权重仍未做，占位数值随手定
const ATTRIBUTE_KEYS: Array[String] = ["mechanical", "electrical", "bodywork", "precision", "communication"]
const WORKER_ATTR_MIN := 15
const WORKER_ATTR_MAX := 25
const APPRENTICE_ATTR_BASE := 5

# 员工命名：入职时随机分配姓氏+双字名，不可修改，UI 里用名字完全替代 #编号显示
const _SURNAMES := [
	"王", "李", "张", "刘", "陈", "杨", "赵", "黄", "周", "吴",
	"徐", "孙", "马", "朱", "胡", "郭", "何", "高", "林", "罗",
	"郑", "梁", "谢", "宋", "唐", "许", "韩", "冯", "邓", "曹",
]
const _GIVEN_NAME_CHARS := [
	"伟", "芳", "娜", "敏", "静", "丽", "强", "磊", "军", "洋",
	"勇", "艳", "杰", "娟", "涛", "明", "超", "霞", "平", "刚",
	"兰", "秀", "英", "华", "玉", "梅", "燕", "婷", "慧", "萍",
	"洁", "欣", "悦", "宇", "浩", "辰", "阳", "宁", "昊", "睿",
	"轩", "泽", "宸", "航", "博", "晨", "曦", "瑞", "嘉", "雨",
]

# 训练：学徒花钱选一门课，精准培养对应属性。属性总和越接近软上限，单次涨幅越小
# （留个尾部不会完全练不动），具体课程数值见 resources/courses/*.tres
const ATTRIBUTE_SOFT_CAP := 150.0
const ATTRIBUTE_GROWTH_FLOOR_RATIO := 0.1

# 2026-08-11：考试不再靠经验值门槛，改成随时可考、通过率由五维属性总和决定——
# 达到门槛必过，每差 1 点扣一定百分比，钳制在 [1%, 100%] 之间留运气成分。
# 考试本身要花钱（报名费），无论成败都不退，防止无脑连点重考。门槛/扣分率/报名费占位待平衡
const EXAM_COST := 20
const EXAM_ATTRIBUTE_THRESHOLD_BASE := 100
const EXAM_ATTRIBUTE_THRESHOLD_LEVEL_STEP := 40
const EXAM_PASS_RATE_PENALTY_PER_POINT := 8.0
const EXAM_PASS_RATE_MIN := 1.0
const EXAM_PASS_RATE_MAX := 100.0

# 2026-08-19：考试改定位为"资质认证"——第一次通过就转正为普工（qualified=true），
# 自动脱离带教关系、获得绑定工位独立接单的资格，工资按普通工人打折（内部培养成本已经花过了）。
# 后续考试用于冲更高职级（工程师等），具体设计和门槛这次先不做，只留级别上限占位。
const MAX_APPRENTICE_LEVEL := 10
const QUALIFIED_SALARY_RATIO := 0.8

# 2026-08-12：带教——属性成长第二条路径。工人可以"带"一个学徒，这是长期绑定关系而不是每次
# 手动触发的动作：师傅接单干活时，只要绑定的学徒当前空闲，就自动一起进这单（完工后学徒获得
# 整数属性点），学徒不空闲时师傅照常独自接单。点数数量由师傅的"细心"属性决定（细心越高教得
# 越好），具体加到哪项属性仍由玩家手动分配，不自动指定。
# 2026-08-18：去掉带教自带的固定耗时折扣——跟车型按主技能加权耗时的机制重复了。耗时现在完全
# 只看工位上工人自己的技能属性；"特定技能减少维修时间"这类效果以后走专门的技能系统设计，
# 不再由"带教"这个动作本身自带 buff。
const MENTOR_POINTS_BASE := 1
const MENTOR_PRECISION_DIVISOR := 10

# 2026-08-16：车型按属性加权耗时——每种车型对应一项主技能（OrderType.primary_attribute），
# 工人该项技能值以基准线（贴近 WORKER_ATTR_MIN/MAX 的中点）为 1.0x 倍率，每高/低于基准 1 点
# 耗时 ±3%，钳制在 [0.7x, 1.3x] 避免极端值把耗时压到不合理区间。数值占位待平衡
const REPAIR_TIME_BASELINE_ATTR := 20
const REPAIR_TIME_PERCENT_PER_POINT := 0.03
const REPAIR_TIME_MULTIPLIER_MIN := 0.7
const REPAIR_TIME_MULTIPLIER_MAX := 1.3

# 2026-08-30：技能系统第一个技能——"熟练技工"，区别于五维属性的连续曲线，是个离散
# 阈值效果：某项硬技能练到远超常规均值（软上限 150/5 项=30，这里要求 35，得靠训练/带教
# 刻意专精单项才够）即解锁，接该项对应车型时在 repair_time_multiplier 基础上再打折，
# 且不受该函数 [0.7x, 1.3x] 钳制——专精技能就是要能突破常规曲线的天花板
const SKILL_ATTRIBUTE_THRESHOLD := 35
const SKILL_TIME_MULTIPLIER := 0.9

# 2026-08-31：技能系统第二个技能——"金牌前台"，复用同一套离散阈值（同一个
# SKILL_ATTRIBUTE_THRESHOLD），但挂在"沟通"这项软技能上：这项属性此前对工人赛道完全没用
# （只有前台赛道选择门槛看它），转正前台的沟通值达标后，解锁进单间隔再打折——前台越会
# 沟通，招揽来的顾客越多，呼应"沟通"字面含义
const SKILL_SPAWN_INTERVAL_MULTIPLIER := 0.9

const STARTING_MONEY := 100

var money: int = STARTING_MONEY
var reputation: int = 0
var facility_level: int = 0
var day: int = 1
var month: int = 1

# 每个工人/学徒都是独立个体，不是数字：{id, kind: "worker"|"apprentice", busy, level}
# level 只对学徒有意义（考试晋级），工人恒为 0。qualified 只对学徒有意义——
# 考试第一次通过后转正为"普工"，能独立接单，但仍保留 kind="apprentice"
# 好继续训练/考更高职级（见 take_exam）
var employees: Array[Dictionary] = []
var _next_employee_id: int = 1

# 2026-08-15：工位从"设施等级决定的纯数字"变成可见实体，工人要绑定到具体工位才能接单——
# 参考带教的"标准关系优于一次性动作"模式，绑一次持续生效，不是每次手动选。
# {id, worker_id: -1 表示未绑定}。工位只会随设施升级增多，不会减少，不需要删除逻辑
var stations: Array[Dictionary] = []
var _next_station_id: int = 1

var _day_timer: Timer


func _ready() -> void:
	_day_timer = Timer.new()
	_day_timer.wait_time = seconds_per_day
	_day_timer.autostart = true
	_day_timer.timeout.connect(_on_day_tick)
	add_child(_day_timer)
	_sync_station_count()


func _on_day_tick() -> void:
	day += 1
	if day > DAYS_PER_MONTH:
		day = 1
		month += 1
		month_changed.emit(month)
		_on_month_end()
	day_changed.emit(day)


func _on_month_end() -> void:
	var total_salary := 0
	for e in employees:
		if e["kind"] == "worker":
			total_salary += WORKER_SALARY_PER_HEAD
		elif e.get("qualified", false):
			total_salary += qualified_apprentice_salary()
		else:
			total_salary += apprentice_salary_for_level(e["level"])
	if total_salary <= 0:
		return
	money -= total_salary
	money_changed.emit(money)


func add_money(amount: int) -> void:
	money += amount
	money_changed.emit(money)


func add_reputation(amount: int) -> void:
	reputation = max(0, reputation + amount)
	reputation_changed.emit(reputation)


func _random_worker_attributes() -> Dictionary:
	var attrs := {}
	for key in ATTRIBUTE_KEYS:
		attrs[key] = randi_range(WORKER_ATTR_MIN, WORKER_ATTR_MAX)
	return attrs


func _random_employee_name() -> String:
	var existing_names: Array = employees.map(func(e: Dictionary) -> String: return e.get("name", ""))
	var candidate := ""
	var attempts := 0
	while attempts < 50:
		var surname: String = _SURNAMES[randi() % _SURNAMES.size()]
		var given := "%s%s" % [
			_GIVEN_NAME_CHARS[randi() % _GIVEN_NAME_CHARS.size()],
			_GIVEN_NAME_CHARS[randi() % _GIVEN_NAME_CHARS.size()],
		]
		candidate = surname + given
		if not existing_names.has(candidate):
			break
		attempts += 1
	return candidate


func _base_apprentice_attributes() -> Dictionary:
	var attrs := {}
	for key in ATTRIBUTE_KEYS:
		attrs[key] = APPRENTICE_ATTR_BASE
	return attrs


func attribute_sum(attrs: Dictionary) -> int:
	var total := 0
	for key in ATTRIBUTE_KEYS:
		total += attrs[key]
	return total


func workers() -> Array[Dictionary]:
	return employees.filter(func(e: Dictionary) -> bool: return e["kind"] == "worker")


func apprentices() -> Array[Dictionary]:
	return employees.filter(func(e: Dictionary) -> bool: return e["kind"] == "apprentice")


# 转正学徒（qualified=true）跟正式工人一样能绑工位独立接单，工位分配面板用这个而不是 workers()；
# 前台赛道的转正学徒不接工位活，排除在外
func station_eligible_employees() -> Array[Dictionary]:
	return employees.filter(func(e: Dictionary) -> bool:
		return e["kind"] == "worker" or (e.get("qualified", false) and e.get("track", "") == "worker"))


# 是否有转正前台在岗——前台机制是二元开关：只要有一个在岗，待处理订单就自动分配到空闲工位，
# 不做人数叠加的连续效率数值
func front_desk_on_duty() -> bool:
	for e in employees:
		if e["kind"] == "apprentice" and e.get("track", "") == "front_desk" and e.get("qualified", false):
			return true
	return false


func qualified_apprentice_salary() -> int:
	return roundi(WORKER_SALARY_PER_HEAD * QUALIFIED_SALARY_RATIO)


func worker_count() -> int:
	return workers().size()


func apprentice_count() -> int:
	return apprentices().size()


func idle_workers() -> Array[Dictionary]:
	return workers().filter(func(e: Dictionary) -> bool: return not e["busy"])


func get_employee(id: int) -> Dictionary:
	for e in employees:
		if e["id"] == id:
			return e
	return {}


func set_employee_busy(id: int, busy: bool) -> void:
	var e := get_employee(id)
	if e.is_empty():
		return
	e["busy"] = busy
	employees_changed.emit()


func total_headcount() -> int:
	return employees.size()


func next_hire_cost() -> int:
	return WORKER_HIRE_COST


func can_hire_worker() -> bool:
	return money >= WORKER_HIRE_COST


func hire_worker() -> bool:
	if not can_hire_worker():
		return false
	money -= WORKER_HIRE_COST
	employees.append({
		"id": _next_employee_id, "kind": "worker", "busy": false, "level": 0,
		"attributes": _random_worker_attributes(), "mentor_apprentice_id": -1,
		"name": _random_employee_name(),
	})
	_next_employee_id += 1
	money_changed.emit(money)
	employees_changed.emit()
	return true


func max_facility_level() -> int:
	return (MAX_STATION_COUNT - BASE_STATION_COUNT) / STATION_PER_FACILITY_LEVEL


func is_facility_maxed() -> bool:
	return facility_level >= max_facility_level()


func next_upgrade_cost() -> int:
	return BASE_UPGRADE_COST + UPGRADE_COST_STEP * facility_level


func upgrade_facility() -> bool:
	if is_facility_maxed():
		return false
	var cost := next_upgrade_cost()
	if money < cost:
		return false
	money -= cost
	facility_level += 1
	money_changed.emit(money)
	facility_level_changed.emit(facility_level)
	_sync_station_count()
	return true


func payout_multiplier() -> float:
	return 1.0 + FACILITY_PAYOUT_BONUS * facility_level


func station_count() -> int:
	return BASE_STATION_COUNT + STATION_PER_FACILITY_LEVEL * facility_level


func _sync_station_count() -> void:
	var target := station_count()
	while stations.size() < target:
		stations.append({"id": _next_station_id, "worker_id": -1})
		_next_station_id += 1
	stations_changed.emit()


func get_station(id: int) -> Dictionary:
	for s in stations:
		if s["id"] == id:
			return s
	return {}


func station_of_worker(worker_id: int) -> int:
	for s in stations:
		if s["worker_id"] == worker_id:
			return s["id"]
	return -1


func bound_worker_ids() -> Array:
	return stations.filter(func(s: Dictionary) -> bool: return s["worker_id"] != -1) \
		.map(func(s: Dictionary) -> int: return s["worker_id"])


# 每个工人同时只能绑一个工位：绑到新工位时，先把这个工人从原工位那解绑
func bind_worker_station(worker_id: int, station_id: int) -> bool:
	var worker := get_employee(worker_id)
	var station := get_station(station_id)
	if worker.is_empty() or station.is_empty():
		return false
	if worker["kind"] != "worker" and not worker.get("qualified", false):
		return false
	for s in stations:
		if s["worker_id"] == worker_id:
			s["worker_id"] = -1
	station["worker_id"] = worker_id
	stations_changed.emit()
	return true


func unbind_worker_station(station_id: int) -> void:
	var station := get_station(station_id)
	if station.is_empty():
		return
	station["worker_id"] = -1
	stations_changed.emit()


# 有工人绑定、且该工人当前空闲，才算能接新单的工位
func idle_stations() -> Array[Dictionary]:
	return stations.filter(func(s: Dictionary) -> bool:
		if s["worker_id"] == -1:
			return false
		var w := get_employee(s["worker_id"])
		return not w.is_empty() and not w["busy"])


func next_apprentice_hire_cost() -> int:
	return APPRENTICE_HIRE_COST


func apprentice_salary_for_level(level: int) -> int:
	return APPRENTICE_SALARY_BASE + APPRENTICE_SALARY_LEVEL_STEP * level


func can_hire_apprentice() -> bool:
	return worker_count() >= 1 and money >= APPRENTICE_HIRE_COST


func hire_apprentice() -> bool:
	if not can_hire_apprentice():
		return false
	money -= APPRENTICE_HIRE_COST
	employees.append({
		"id": _next_employee_id, "kind": "apprentice", "busy": false, "level": 0,
		"attributes": _base_apprentice_attributes(), "pending_points": 0, "qualified": false,
		"name": _random_employee_name(), "track": "",
	})
	_next_employee_id += 1
	money_changed.emit(money)
	employees_changed.emit()
	return true


func exam_attribute_threshold(level: int) -> int:
	return EXAM_ATTRIBUTE_THRESHOLD_BASE + EXAM_ATTRIBUTE_THRESHOLD_LEVEL_STEP * level


# 工人赛道看机械/电气/钣喷/细心四维总和；前台赛道只看沟通这一维——
# 两条赛道的训练成本/成长曲线本来就对称（五门课 base_growth/cost 完全一样，
# 攻速只跟属性总和的软上限挂钩，跟点在哪维无关），所以门槛公式可以直接复用，
# 不用给前台另开一套数值
func _track_core_attribute_value(attrs: Dictionary, track: String) -> int:
	if track == "front_desk":
		return attrs["communication"]
	return attrs["mechanical"] + attrs["electrical"] + attrs["bodywork"] + attrs["precision"]


func can_choose_track(id: int) -> bool:
	var e := get_employee(id)
	if e.is_empty() or e["kind"] != "apprentice" or e.get("track", "") != "":
		return false
	return attribute_sum(e["attributes"]) >= exam_attribute_threshold(0)


# 赛道选定后不可改——选错了只能靠以后的解雇机制重新招人，这次不做转岗
func choose_track(id: int, track: String) -> bool:
	if not can_choose_track(id):
		return false
	if track != "worker" and track != "front_desk":
		return false
	var e := get_employee(id)
	e["track"] = track
	employees_changed.emit()
	return true


func exam_pass_rate(id: int) -> float:
	var e := get_employee(id)
	if e.is_empty():
		return 0.0
	var threshold := exam_attribute_threshold(e["level"])
	var core_value := _track_core_attribute_value(e["attributes"], e.get("track", ""))
	var deficit: int = max(0, threshold - core_value)
	var rate := EXAM_PASS_RATE_MAX - EXAM_PASS_RATE_PENALTY_PER_POINT * deficit
	return clamp(rate, EXAM_PASS_RATE_MIN, EXAM_PASS_RATE_MAX)


func can_take_exam(id: int) -> bool:
	var e := get_employee(id)
	if e.is_empty() or e["kind"] != "apprentice" or e["busy"]:
		return false
	if e.get("track", "") == "":
		return false
	if e["level"] >= MAX_APPRENTICE_LEVEL:
		return false
	return money >= EXAM_COST


# 返回空字典表示没能开考；否则 {"passed": bool, "rate": float}——报名费无论成败都扣。
# 第一次通过（qualified 从 false 变 true）即视为拿到资质转正：自动脱离带教关系，
# 之后能绑工位独立接单、工资改走 qualified_apprentice_salary()
func take_exam(id: int) -> Dictionary:
	if not can_take_exam(id):
		return {}
	var rate := exam_pass_rate(id)
	money -= EXAM_COST
	var passed := randf() * 100.0 < rate
	if passed:
		var e := get_employee(id)
		var newly_qualified: bool = not e.get("qualified", false)
		e["level"] += 1
		if newly_qualified:
			e["qualified"] = true
			_unbind_apprentice_from_mentor(id)
	money_changed.emit(money)
	employees_changed.emit()
	return {"passed": passed, "rate": rate}


func can_start_training(id: int, course: Resource) -> bool:
	var e := get_employee(id)
	if e.is_empty() or e["kind"] != "apprentice" or e["busy"]:
		return false
	return money >= course.cost


func start_training(id: int, course: Resource) -> bool:
	if not can_start_training(id, course):
		return false
	money -= course.cost
	var e := get_employee(id)
	e["busy"] = true
	money_changed.emit(money)
	employees_changed.emit()
	return true


func complete_training(id: int, course: Resource) -> void:
	var e := get_employee(id)
	if e.is_empty():
		return
	var attrs: Dictionary = e["attributes"]
	var factor: float = max(ATTRIBUTE_GROWTH_FLOOR_RATIO, 1.0 - float(attribute_sum(attrs)) / ATTRIBUTE_SOFT_CAP)
	var growth: int = roundi(course.base_growth * factor)
	attrs[course.attribute_key] += growth
	e["busy"] = false
	employees_changed.emit()


# 每个学徒同一时间只能被一个师傅带教：绑定新师傅时，先把这个学徒从原师傅那解绑
func bind_mentor(worker_id: int, apprentice_id: int) -> bool:
	var worker := get_employee(worker_id)
	var apprentice := get_employee(apprentice_id)
	if worker.is_empty() or worker["kind"] != "worker":
		return false
	if apprentice.is_empty() or apprentice["kind"] != "apprentice" or apprentice.get("qualified", false):
		return false
	for e in workers():
		if e.get("mentor_apprentice_id", -1) == apprentice_id:
			e["mentor_apprentice_id"] = -1
	worker["mentor_apprentice_id"] = apprentice_id
	employees_changed.emit()
	return true


func unbind_mentor(worker_id: int) -> void:
	var worker := get_employee(worker_id)
	if worker.is_empty():
		return
	worker["mentor_apprentice_id"] = -1
	employees_changed.emit()


func _unbind_apprentice_from_mentor(apprentice_id: int) -> void:
	for w in workers():
		if w.get("mentor_apprentice_id", -1) == apprentice_id:
			w["mentor_apprentice_id"] = -1


func bound_apprentice_ids() -> Array:
	return workers().filter(func(w: Dictionary) -> bool: return w.get("mentor_apprentice_id", -1) != -1) \
		.map(func(w: Dictionary) -> int: return w["mentor_apprentice_id"])


# 返回带教这个学徒的师傅 id，没人带则返回 -1
func mentor_of(apprentice_id: int) -> int:
	for w in workers():
		if w.get("mentor_apprentice_id", -1) == apprentice_id:
			return w["id"]
	return -1


func repair_time_multiplier(attribute_value: int) -> float:
	var diff := attribute_value - REPAIR_TIME_BASELINE_ATTR
	var multiplier := 1.0 - REPAIR_TIME_PERCENT_PER_POINT * diff
	return clamp(multiplier, REPAIR_TIME_MULTIPLIER_MIN, REPAIR_TIME_MULTIPLIER_MAX)


func has_attribute_skill(attribute_value: int) -> bool:
	return attribute_value >= SKILL_ATTRIBUTE_THRESHOLD


func skill_time_multiplier(attribute_value: int) -> float:
	return SKILL_TIME_MULTIPLIER if has_attribute_skill(attribute_value) else 1.0


# 前台"金牌"判定是二元开关（跟 front_desk_on_duty 同款：只要有一个达标在岗前台就生效，
# 不做人数叠加），不区分具体是哪个前台达标
func has_front_desk_skill() -> bool:
	for e in employees:
		if e["kind"] == "apprentice" and e.get("track", "") == "front_desk" and e.get("qualified", false):
			if has_attribute_skill(e["attributes"]["communication"]):
				return true
	return false


func front_desk_spawn_interval_multiplier() -> float:
	return SKILL_SPAWN_INTERVAL_MULTIPLIER if has_front_desk_skill() else 1.0


func mentor_points_earned(master_precision: int) -> int:
	return MENTOR_POINTS_BASE + master_precision / MENTOR_PRECISION_DIVISOR


func add_attribute_points(id: int, amount: int) -> void:
	var e := get_employee(id)
	if e.is_empty():
		return
	e["pending_points"] = int(e.get("pending_points", 0)) + amount
	employees_changed.emit()


# 玩家手动把学徒的一点待分配点数加到指定属性上，返回是否成功（没点数时失败）
func allocate_attribute_point(id: int, attribute_key: String) -> bool:
	var e := get_employee(id)
	if e.is_empty() or int(e.get("pending_points", 0)) <= 0:
		return false
	e["pending_points"] = int(e["pending_points"]) - 1
	var attrs: Dictionary = e["attributes"]
	attrs[attribute_key] = int(attrs[attribute_key]) + 1
	employees_changed.emit()
	return true
