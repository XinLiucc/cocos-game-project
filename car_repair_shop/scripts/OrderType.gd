extends Resource

@export var car_name: String = ""
@export var repair_time: float = 1.0
@export var payout: int = 0
@export var reputation_gain: int = 1
# 占位数值：解锁门槛的具体数字还没有细化过，等招人/学徒机制定下来后可能整体重新调
@export var min_reputation: int = 0
# 2026-08-16：这种车型最吃工人的哪项硬技能（对应 GameState.ATTRIBUTE_KEYS），决定实际耗时
@export var primary_attribute: String = "mechanical"
