extends ScrollContainer
## Dropping worn equipment in the bag uses the same validated unequip operation.
var accept_drop: Callable
var apply_drop: Callable
func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	return accept_drop.is_valid() and accept_drop.call(data,-1)
func _drop_data(_at: Vector2, data: Variant) -> void:
	if apply_drop.is_valid(): apply_drop.call(data,-1)
