extends Node

signal money_changed(new_amount: int)
signal reputation_changed(new_amount: int)
signal facility_level_changed(new_level: int)
signal day_changed(new_day: int)
signal month_changed(new_month: int)
signal employees_changed()

# 占位数值：招人机制还没细化，这里先用一个简单的递增费用代替
const BASE_HIRE_COST := 100
const HIRE_COST_STEP := 50
const WORKER_SALARY_PER_HEAD := 20

# 占位数值：设施升级机制也没细化，先用递增费用 + 固定收入加成代替
# 2026-08-06：设施升级还决定"工位数"（同时能干活的人数上限），worker_count 只是员工总数，
# 两者解耦——员工可以比工位多（备用），但同时干活人数被工位卡住
const BASE_UPGRADE_COST := 150
const UPGRADE_COST_STEP := 100
const FACILITY_PAYOUT_BONUS := 0.15
const BASE_STATION_COUNT := 1
const STATION_PER_FACILITY_LEVEL := 1

# 占位数值：一天等于多少秒，开发阶段调短方便测试，正式数值以后再定
const DAYS_PER_MONTH := 30
var seconds_per_day: float = 3.0

# 占位数值：学徒机制还在搭骨架，招募费用/工资/考试门槛都是随手定的，之后要重新平衡
const BASE_APPRENTICE_HIRE_COST := 30
const APPRENTICE_HIRE_COST_STEP := 10
const APPRENTICE_SALARY_BASE := 15
const APPRENTICE_SALARY_LEVEL_STEP := 5
const APPRENTICE_XP_BASE := 50
const APPRENTICE_XP_LEVEL_STEP := 20

const STARTING_MONEY := 100

var money: int = STARTING_MONEY
var reputation: int = 0
var facility_level: int = 0
var day: int = 1
var month: int = 1

# 每个工人/学徒都是独立个体，不是数字：{id, kind: "worker"|"apprentice", busy, level, xp}
# level/xp 只对学徒有意义，工人恒为 0
var employees: Array[Dictionary] = []
var _next_employee_id: int = 1

var _day_timer: Timer


func _ready() -> void:
	_day_timer = Timer.new()
	_day_timer.wait_time = seconds_per_day
	_day_timer.autostart = true
	_day_timer.timeout.connect(_on_day_tick)
	add_child(_day_timer)


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


func workers() -> Array[Dictionary]:
	return employees.filter(func(e: Dictionary) -> bool: return e["kind"] == "worker")


func apprentices() -> Array[Dictionary]:
	return employees.filter(func(e: Dictionary) -> bool: return e["kind"] == "apprentice")


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


func next_hire_cost() -> int:
	return BASE_HIRE_COST + HIRE_COST_STEP * worker_count()


func hire_worker() -> bool:
	var cost := next_hire_cost()
	if money < cost:
		return false
	money -= cost
	employees.append({"id": _next_employee_id, "kind": "worker", "busy": false, "level": 0, "xp": 0})
	_next_employee_id += 1
	money_changed.emit(money)
	employees_changed.emit()
	return true


func next_upgrade_cost() -> int:
	return BASE_UPGRADE_COST + UPGRADE_COST_STEP * facility_level


func upgrade_facility() -> bool:
	var cost := next_upgrade_cost()
	if money < cost:
		return false
	money -= cost
	facility_level += 1
	money_changed.emit(money)
	facility_level_changed.emit(facility_level)
	return true


func payout_multiplier() -> float:
	return 1.0 + FACILITY_PAYOUT_BONUS * facility_level


func station_count() -> int:
	return BASE_STATION_COUNT + STATION_PER_FACILITY_LEVEL * facility_level


func next_apprentice_hire_cost() -> int:
	return BASE_APPRENTICE_HIRE_COST + APPRENTICE_HIRE_COST_STEP * apprentice_count()


func apprentice_salary_for_level(level: int) -> int:
	return APPRENTICE_SALARY_BASE + APPRENTICE_SALARY_LEVEL_STEP * level


func can_hire_apprentice() -> bool:
	return worker_count() >= 1 and money >= next_apprentice_hire_cost()


func hire_apprentice() -> bool:
	if not can_hire_apprentice():
		return false
	money -= next_apprentice_hire_cost()
	employees.append({"id": _next_employee_id, "kind": "apprentice", "busy": false, "level": 0, "xp": 0})
	_next_employee_id += 1
	money_changed.emit(money)
	employees_changed.emit()
	return true


func apprentice_xp_required_for_level(level: int) -> int:
	return APPRENTICE_XP_BASE + APPRENTICE_XP_LEVEL_STEP * level


func add_apprentice_xp(id: int, amount: int) -> void:
	var e := get_employee(id)
	if e.is_empty():
		return
	e["xp"] += amount
	employees_changed.emit()


func can_take_exam(id: int) -> bool:
	var e := get_employee(id)
	if e.is_empty() or e["kind"] != "apprentice":
		return false
	return e["xp"] >= apprentice_xp_required_for_level(e["level"])


func take_exam(id: int) -> bool:
	if not can_take_exam(id):
		return false
	var e := get_employee(id)
	e["xp"] -= apprentice_xp_required_for_level(e["level"])
	e["level"] += 1
	employees_changed.emit()
	return true
