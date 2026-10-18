extends RefCounted
## One source map tick. Session owns time, RNG and applying the returned objects.
## This uses documented intent repairs, not a verified original-engine movement oracle.
const DIRECTIONS := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]
const SOURCE := "erduoniba/baye-fmj-app@60c41ea2d9932b295833ece7004394497610596a:Fmj/fmj_c_engine/engine.c"
const INTENT_REPAIRS := ["patrol_while_not_at_target", "full_width_map_index"]

static func tick(content: ChapterContent, world: Dictionary, objects: Dictionary, random: Callable) -> Dictionary:
	if not world.get("map_id") is String or not content.maps.has(world.map_id) or not _integer(world.get("x")) or not _integer(world.get("y")):
		return _failure(objects, "Invalid NPC world checkpoint")
	if not random.is_valid(): return _failure(objects, "NPC tick requires the session random callback")
	var slots: Array = objects.keys()
	# C scans the forty source slots in numeric order, not Dictionary insertion order.
	for key in slots:
		if not key is String or not key.is_valid_int() or int(key) < 1 or int(key) > 40:
			return _failure(objects, "Invalid source NPC slot")
		var object: Variant = objects[key]
		if not object is Dictionary: return _failure(objects, "Invalid source NPC object")
		for field in ["x", "y", "facing", "step", "move_mode"]:
			if not _integer(object.get(field)): return _failure(objects, "Missing NPC motion field: " + field)
		if int(object.facing) > 3 or int(object.step) > 3 or int(object.move_mode) > 4:
			return _failure(objects, "Invalid NPC direction, step or runtime mode")
		var definition: Dictionary = content.actors.get(str(object.get("resource", "")), {})
		var delay: Variant = object.get("delay", definition.get("delay", 0))
		if not _integer(delay): return _failure(objects, "Invalid source NPC delay")
		for field in ["countdown", "target_x", "target_y"]:
			if object.has(field) and not _integer(object[field]): return _failure(objects, "Invalid NPC runtime counter or target")
	slots.sort_custom(func(a: String, b: String) -> bool: return int(a) < int(b))
	var updated := objects.duplicate(true)
	var events: Array = []
	for key in slots:
		var object: Dictionary = updated[key]
		var mode := int(object.move_mode)
		if mode == 0: continue
		if mode == 4:
			object["step"] = (int(object.step) + 1) % 4
			events.append({"type": "npc_step", "slot": int(key), "step": object.step})
			continue
		var definition: Dictionary = content.actors.get(str(object.get("resource", "")), {})
		var delay := int(object.get("delay", definition.get("delay", 0)))
		if mode == 3:
			# The C counter is an unsigned byte. A saved zero wraps to 255.
			object["countdown"] = (int(object.get("countdown", delay)) - 1) & 255
			if int(object.countdown) == 0:
				var value: Variant = random.call(200)
				if not _integer(value, 199): return _failure(objects, "NPC random callback returned a value outside 0..199")
				var roll := int(value)
				object["facing"] = roll % 4
				var direction: Vector2i = DIRECTIONS[int(object.facing)]
				object["target_x"] = (int(object.x) + direction.x * (roll % 5)) & 255
				object["target_y"] = (int(object.y) + direction.y * (roll % 5)) & 255
				object["move_mode"] = 2
				events.append({"type": "npc_patrol_selected", "slot": int(key), "facing": object.facing,
					"target_x": object.target_x, "target_y": object.target_y})
			continue
		var x := int(object.x)
		var y := int(object.y)
		var target_x := int(object.get("target_x", x))
		var target_y := int(object.get("target_y", y))
		if x == target_x and y == target_y:
			_pause(object, delay)
			events.append({"type": "npc_paused", "slot": int(key), "reason": "arrived"})
			continue
		# Intent repair: patrol while a target remains. The decompiled C equality
		# condition contradicts its target selection. cell() also avoids its u8 index.
		var direction: Vector2i = DIRECTIONS[int(object.facing)]
		var next_x := x + direction.x
		var next_y := y + direction.y
		var cell := content.cell(world.map_id, next_x, next_y)
		var blocked := not bool(cell.get("walkable", false)) or (next_x == int(world.x) and next_y == int(world.y))
		if not blocked:
			for other_key in slots:
				if other_key != key and int(updated[other_key].x) == next_x and int(updated[other_key].y) == next_y:
					blocked = true
					break
		if blocked:
			_pause(object, delay)
			events.append({"type": "npc_paused", "slot": int(key), "reason": "blocked"})
			continue
		object["x"] = next_x
		object["y"] = next_y
		object["step"] = (int(object.step) + 1) % 4
		# As in the source loop, arrival is noticed at the following tick.
		events.append({"type": "npc_moved", "slot": int(key), "from_x": x, "from_y": y,
			"x": next_x, "y": next_y, "step": object.step})
	return {"ok": true, "objects": updated, "events": events, "changed": updated != objects,
		"rules_verified_original": false, "intent_repairs": INTENT_REPAIRS.duplicate()}

static func _pause(object: Dictionary, delay: int) -> void:
	object["target_x"] = int(object.x)
	object["target_y"] = int(object.y)
	object["move_mode"] = 3
	object["countdown"] = delay

static func _integer(value: Variant, maximum: int = 255) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floor(float(value)) and value >= 0 and value <= maximum

static func _failure(objects: Dictionary, message: String) -> Dictionary:
	return {"ok": false, "error": message, "objects": objects.duplicate(true), "events": [], "changed": false}
