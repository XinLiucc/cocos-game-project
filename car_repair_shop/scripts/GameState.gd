extends Node

signal money_changed(new_amount: int)
signal reputation_changed(new_amount: int)

var money: int = 0
var reputation: int = 0


func add_money(amount: int) -> void:
	money += amount
	money_changed.emit(money)


func add_reputation(amount: int) -> void:
	reputation += amount
	reputation_changed.emit(reputation)
