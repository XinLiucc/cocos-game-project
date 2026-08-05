extends Node

signal money_changed(new_amount: int)
signal reputation_changed(new_amount: int)
signal worker_count_changed(new_count: int)
signal facility_level_changed(new_level: int)
signal day_changed(new_day: int)
signal month_changed(new_month: int)
signal apprentice_count_changed(new_count: int)
signal apprentice_level_changed(new_level: int)
signal apprentice_xp_changed(new_xp: int)

# 占位数值：招人机制还没细化，这里先用一个简单的递增费用 + 固定加速效果代替
const BASE_HIRE_COST := 100
const HIRE_COST_STEP := 50
const WORKER_SPEED_BONUS := 0.1
const WORKER_SALARY_PER_HEAD := 20

# 占位数值：设施升级机制也没细化，先用递增费用 + 固定收入加成代替，跟招人是独立的两条杠杆
const BASE_UPGRADE_COST := 150
const UPGRADE_COST_STEP := 100
const FACILITY_PAYOUT_BONUS := 0.15

# 占位数值：一天等于多少秒，开发阶段调短方便测试，正式数值以后再定
const DAYS_PER_MONTH := 30
var seconds_per_day: float = 3.0

# 占位数值：学徒机制还在搭骨架，招募费用/工资/考试门槛都是随手定的，之后要重新平衡
# 学徒等级这版先当成一个共享池子的属性（不区分个体学徒），简化实现
const BASE_APPRENTICE_HIRE_COST := 30
const APPRENTICE_HIRE_COST_STEP := 10
const APPRENTICE_SALARY_BASE := 15
const APPRENTICE_SALARY_LEVEL_STEP := 5
const APPRENTICE_XP_BASE := 50
const APPRENTICE_XP_LEVEL_STEP := 20

var money: int = 0
var reputation: int = 0
var worker_count: int = 0
var facility_level: int = 0
var day: int = 1
var month: int = 1
var apprentice_count: int = 0
var apprentice_level: int = 0
var apprentice_xp: int = 0

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
	var total_salary := worker_count * WORKER_SALARY_PER_HEAD + apprentice_count * apprentice_salary_per_head()
	if total_salary <= 0:
		return
	money -= total_salary
	money_changed.emit(money)


func add_money(amount: int) -> void:
	money += amount
	money_changed.emit(money)


func add_reputation(amount: int) -> void:
	reputation += amount
	reputation_changed.emit(reputation)


func next_hire_cost() -> int:
	return BASE_HIRE_COST + HIRE_COST_STEP * worker_count


func hire_worker() -> bool:
	var cost := next_hire_cost()
	if money < cost:
		return false
	money -= cost
	worker_count += 1
	money_changed.emit(money)
	worker_count_changed.emit(worker_count)
	return true


func repair_time_multiplier() -> float:
	return 1.0 / (1.0 + WORKER_SPEED_BONUS * worker_count)


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


func next_apprentice_hire_cost() -> int:
	return BASE_APPRENTICE_HIRE_COST + APPRENTICE_HIRE_COST_STEP * apprentice_count


func apprentice_salary_per_head() -> int:
	return APPRENTICE_SALARY_BASE + APPRENTICE_SALARY_LEVEL_STEP * apprentice_level


func can_hire_apprentice() -> bool:
	return worker_count >= 1 and money >= next_apprentice_hire_cost()


func hire_apprentice() -> bool:
	if not can_hire_apprentice():
		return false
	money -= next_apprentice_hire_cost()
	apprentice_count += 1
	money_changed.emit(money)
	apprentice_count_changed.emit(apprentice_count)
	return true


func apprentice_xp_required() -> int:
	return APPRENTICE_XP_BASE + APPRENTICE_XP_LEVEL_STEP * apprentice_level


func add_apprentice_xp(amount: int) -> void:
	apprentice_xp += amount
	apprentice_xp_changed.emit(apprentice_xp)


func can_take_exam() -> bool:
	return apprentice_count > 0 and apprentice_xp >= apprentice_xp_required()


func take_exam() -> bool:
	if not can_take_exam():
		return false
	apprentice_xp -= apprentice_xp_required()
	apprentice_level += 1
	apprentice_xp_changed.emit(apprentice_xp)
	apprentice_level_changed.emit(apprentice_level)
	return true
