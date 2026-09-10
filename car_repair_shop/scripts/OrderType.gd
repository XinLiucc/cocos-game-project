extends Resource

@export var car_name: String = ""
@export var repair_time: float = 1.0
@export var payout: int = 0
@export var reputation_gain: int = 1
# 占位数值：解锁门槛的具体数字还没有细化过，等招人/学徒机制定下来后可能整体重新调
@export var min_reputation: int = 0
# 2026-08-16：这种车型最吃工人的哪项硬技能（对应 GameState.WORKER_ATTRIBUTE_KEYS），决定实际耗时。
# 2026-09-10：车型扩充到四大类（日常/性能娱乐/商用/工程重型）后，很多车型的维修横跨两项
# 技能（比如工程车机械+车身各占一半），单一字符串字段不够用，改成"属性: 权重"字典，
# 权重之和约定为 1.0。原来的单属性车型（轿车/跑车）等价于权重 100% 在一项上，天然兼容。
@export var attribute_weights: Dictionary = {"mechanical": 1.0}
# 2026-09-01：工位可视化场景里车辆色块的颜色，占位几何美术阶段的车型识别方式
@export var color: Color = Color.WHITE


# 离散技能"熟练技工"（GameState.has_attribute_skill）只看单一属性达标，多属性车型下
# 约定绑权重最高的那项——专精主科才算触发技能，副科权重只影响耗时曲线、不参与技能判定
func primary_attribute() -> String:
	var best_key := ""
	var best_weight := -INF
	for key in attribute_weights:
		if attribute_weights[key] > best_weight:
			best_weight = attribute_weights[key]
			best_key = key
	return best_key
