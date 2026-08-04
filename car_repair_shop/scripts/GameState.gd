extends Node

signal money_changed(new_amount: int)
signal reputation_changed(new_amount: int)
signal worker_count_changed(new_count: int)
signal facility_level_changed(new_level: int)
signal day_changed(new_day: int)
signal month_changed(new_month: int)

# 占位数值：招人机制还没细化，这里先用一个简单的递增费用 + 固定加速效果代替
const BASE_HIRE_COST := 100
const HIRE_COST_STEP := 50
const WORKER_SPEED_BONUS := 0.1

# 占位数值：设施升级机制也没细化，先用递增费用 + 固定收入加成代替，跟招人是独立的两条杠杆
const BASE_UPGRADE_COST := 150
const UPGRADE_COST_STEP := 100
const FACILITY_PAYOUT_BONUS := 0.15

# 占位数值：一天等于多少秒，开发阶段调短方便测试，正式数值以后再定
const DAYS_PER_MONTH := 30
var seconds_per_day: float = 3.0

var money: int = 0
var reputation: int = 0
var worker_count: int = 0
var facility_level: int = 0
var day: int = 1
var month: int = 1

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
	pass


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
