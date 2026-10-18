extends Button
## Inventory card: selection is separate from the explicit equip/use action.
var entry: Dictionary = {}
var owner_token := 0
var activate: Callable
var accept_drop: Callable
var apply_drop: Callable
var icon_texture: Texture2D

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed and event.double_click:
		if activate.is_valid(): activate.call(entry)
		accept_event()

func _get_drag_data(_at: Vector2) -> Variant:
	if str(entry.get("id", "")).is_empty() or bool(entry.get("magic",false)): return null
	var preview := TextureRect.new()
	preview.texture = icon_texture
	preview.custom_minimum_size = Vector2(48,48)
	preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	set_drag_preview(preview)
	return {"inventory_owner":owner_token,"entry":entry.duplicate()}

func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	return accept_drop.is_valid() and accept_drop.call(data,int(entry.get("slot",-1)))

func _drop_data(_at: Vector2, data: Variant) -> void:
	if apply_drop.is_valid(): apply_drop.call(data,int(entry.get("slot",-1)))
