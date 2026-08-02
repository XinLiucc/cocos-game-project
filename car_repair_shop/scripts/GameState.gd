extends Node

signal money_changed(new_amount: int)
signal reputation_changed(new_amount: int)
signal worker_count_changed(new_count: int)

# 占位数值：招人机制还没细化，这里先用一个简单的递增费用 + 固定加速效果代替
const BASE_HIRE_COST := 100
const HIRE_COST_STEP := 50
const WORKER_SPEED_BONUS := 0.1

var money: int = 0
var reputation: int = 0
var worker_count: int = 0


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
