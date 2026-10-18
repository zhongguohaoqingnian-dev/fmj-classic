class_name ChapterSession
extends RefCounted
## Sole mutation owner for the source adapter. Source coordinates and addresses survive saves.
signal changed
signal recorded(record: Dictionary)
var content: ChapterContent
var state: Dictionary = {}
var trace: Array = []
## Presentation epoch: LOADMAP can enter another road using the same MAP resource.
var map_load_sequence := 0
const DIRECTIONS := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]

func _init(catalog: ChapterContent) -> void:
	content = catalog

func start_new(seed_value: int = 20260905) -> Dictionary:
	state = {"schema_version": 1, "content_id": "fmj-chapter1-candidate", "content_hash": content.identity,
		"mode": "candidate", "event_sequence": 0, "world": {"map_id": "", "x": 0, "y": 0, "camera_x": 0, "camera_y": 0, "facing": 2, "step": 1},
		"party": [], "actors": {}, "inventory": {}, "currency": 0, "flags": {}, "event": {},
		"source_runtime": {"adapter_version": 1, "script": "", "pc": 0, "active": false, "variables": {}, "objects": {}, "scene_name": "", "encounter": [], "request": {}, "save_enabled": true, "error": "", "steps": 0},
		"rng": {"seed": str(seed_value), "state": str(seed_value)}, "playtime_ms": 0}
	trace.clear()
	_start_script("1:1:1")
	_note({"kind": "new_game", "seed": seed_value})
	return pump()

func snapshot() -> Dictionary:
	return _plain(state)

func runtime() -> Dictionary:
	return state.source_runtime

func request() -> Dictionary:
	return runtime().request.duplicate(true)

func ready() -> bool:
	return not state.is_empty() and not runtime().active and runtime().request.is_empty() and runtime().error.is_empty()

func _start_script(id: String) -> void:
	if not content.scripts.has(id):
		_fail("missing_script:" + id)
		return
	var rt := runtime()
	rt.script = id
	rt.pc = int(content.scripts[id].instructions[0].address)
	rt.active = true
	rt.objects = {}
	for index in range(200, 240):
		rt.variables.erase(str(index))

func _jump(address: int) -> void:
	if content.instruction(runtime().script, address).is_empty():
		_fail("invalid_script_address:%s/%d" % [runtime().script, address])
	else:
		runtime().pc = address

func _trigger(event_id: int) -> bool:
	var address := content.event_address(runtime().script, event_id)
	if address == 0:
		return false
	runtime().active = true
	_jump(address)
	_note({"kind": "event_trigger", "event": event_id, "script": runtime().script, "address": address})
	return true

func move(direction: Vector2i) -> Dictionary:
	if not ready() or direction not in DIRECTIONS:
		return Checks.failure("not_ready")
	var w: Dictionary = state.world
	w.facing = DIRECTIONS.find(direction)
	w.step = (int(w.step) + 1) % 4
	var x := int(w.x) + direction.x
	var y := int(w.y) + direction.y
	var cell := content.cell(w.map_id, x, y)
	var event_id := int(cell.get("event", 0))
	# Source order: attempt tile event before collision; script runs after this step.
	if event_id != 0:
		_trigger(event_id + 40)
	var moved := bool(cell.get("walkable", false)) and _object_at(x, y).is_empty()
	if moved:
		w.x = x
		w.y = y
		w.camera_x = int(w.camera_x) + direction.x
		w.camera_y = int(w.camera_y) + direction.y
		runtime().steps = int(runtime().steps) + 1
	_note({"kind": "move", "dx": direction.x, "dy": direction.y, "moved": moved})
	if event_id == 0 and moved:
		_try_encounter()
	if ready(): tick_world("command")
	return pump()

func interact() -> Dictionary:
	if not ready():
		return Checks.failure("not_ready")
	var w: Dictionary = state.world
	var d: Vector2i = DIRECTIONS[int(w.facing)]
	var x := int(w.x) + d.x
	var y := int(w.y) + d.y
	var cell := content.cell(w.map_id, x, y)
	var triggered := false
	if not cell.is_empty():
		# A real map event keeps priority (doors can overlap decoration). A map
		# reused by a different chapter can retain an event number with no entry;
		# that empty entry must not hide an active chest/NPC interaction.
		var raw_event := int(cell.get("event", 0))
		var event_id := ((raw_event + 40) & 255) if raw_event != 0 else 0
		if event_id > 0 and event_id <= 80 and content.event_address(runtime().script,event_id) != 0:
			triggered = _trigger(event_id)
		else:
			var target := _object_at(x, y)
			if not target.is_empty():
				triggered = _trigger(int(target.slot))
	_note({"kind": "interact", "triggered": triggered})
	if ready(): tick_world("command")
	return pump()

func _object_at(x: int, y: int) -> Dictionary:
	for object in runtime().objects.values():
		if int(object.x) == x and int(object.y) == y:
			return object
	return {}

func pump(budget: int = 256) -> Dictionary:
	var rt := runtime()
	for _i in range(budget):
		if not rt.error.is_empty():
			return Checks.failure(rt.error)
		if not rt.active or not rt.request.is_empty():
			changed.emit()
			return Checks.success(request())
		var op := content.instruction(rt.script, int(rt.pc))
		if op.is_empty():
			return _fail("missing_opcode:%s/%d" % [rt.script, rt.pc])
		rt.pc = int(op.address) + int(op.size)
		_execute(op)
	changed.emit()
	return Checks.success(request())

func _execute(op: Dictionary) -> void:
	var a: Array = op.args
	var rt := runtime()
	var w: Dictionary = state.world
	match str(op.name):
		"CALLBACK", "RETURN":
			if bool(rt.get("battle_event", false)):
				_resume_battle_event()
			else:
				rt.active = false
		"GOTO": _jump(int(a[0]))
		"IF":
			if flag(int(a[0])): _jump(int(a[1]))
		"IFCMP":
			if int(rt.variables.get(str(int(a[0])), 0)) == int(a[1]): _jump(int(a[2]))
		"SET": rt.variables[str(int(a[0]))] = int(a[1])
		"ADD":
			# Source VM stores signed 32-bit variables; operands are unsigned LE16.
			var key := str(int(a[0]))
			var total := int(rt.variables.get(key, 0)) + int(a[1])
			rt.variables[key] = ((total + 2147483648) & 0xffffffff) - 2147483648
		"SETEVENT": state.flags[str(int(a[0]))] = 1
		"CLREVENT": state.flags.erase(str(int(a[0])))
		"STARTCHAPTER": _start_script("1:%d:%d" % [a[0], a[1]])
		"LOADMAP":
			var id := "2:%d:%d" % [a[0], a[1]]
			if not content.maps.has(id):
				_fail("missing_map:" + id)
				return
			var screen_x := int(w.x) - int(w.camera_x)
			var screen_y := int(w.y) - int(w.camera_y)
			w.map_id = id
			w.camera_x = int(a[2])
			w.camera_y = int(a[3])
			w.x = screen_x + int(a[2])
			w.y = screen_y + int(a[3])
			map_load_sequence += 1
			_note({"kind": "map_loaded", "map": id, "x": w.x, "y": w.y, "source": op.absolute_offset})
		"CREATEACTOR":
			var id := "3:1:%d" % a[0]
			if not content.actors.has(id):
				_fail("missing_actor:" + id)
				return
			if not state.actors.has(id): state.actors[id] = content.actors[id].duplicate(true)
			if not state.party.has(id): state.party.append(id)
			if state.party[0] == id:
				w.x = int(w.camera_x) + int(a[1])
				w.y = int(w.camera_y) + int(a[2])
		"DELETEACTOR":
			state.party.erase("3:1:%d" % a[0])
		"CREATENPC", "CREATEBOX":
			var kind := 2 if op.name == "CREATENPC" else 4
			var id := "3:%d:%d" % [kind, a[1]]
			var definition: Dictionary = content.actors.get(id, {})
			var object := {"slot": int(a[0]), "resource": id, "index": int(a[1]), "kind": kind,
				"name": definition.get("name", ""), "x": int(a[2]), "y": int(a[3]),
				"facing": int(definition.get("direction", 0)), "step": int(definition.get("step", 1)),
				"move_mode": int(definition.get("state", 0)), "delay": int(definition.get("delay",0)), "countdown": int(definition.get("delay",0)), "target_x": int(a[2]), "target_y": int(a[3]), "hidden": kind == 4 and int(a[1]) == 18}
			rt.objects[str(int(a[0]))] = object
		"DELETEBOX", "DELETENPC": rt.objects.erase(str(int(a[0])))
		"DELALLNPC": rt.objects = {}
		"SETSCENENAME": rt.scene_name = a[0]
		"SHOWSCENENAME": _presentation(op, "scene_name", {"text": rt.scene_name, "duration": 0.65})
		"SHOWSCREEN": _presentation(op, "screen", {"duration": 0.1})
		"SHOWGUT": _presentation(op, "prologue", {"text": str(a[2]).strip_edges(), "images": [a[0], a[1]]})
		"SAY": _presentation(op, "dialogue", {"portrait": int(a[0]), "text": str(a[1])})
		"MESSAGE": _presentation(op, "dialogue", {"portrait": 0, "text": str(a[0])})
		"CHOICE": _presentation(op, "choice", {"choices": [a[0], a[1]], "target": int(a[2])})
		"NPCSTEP":
			var actor := _visual_actor(int(a[0]))
			if actor.is_empty():
				_fail("missing_visual_actor:%d" % a[0])
				return
			actor.facing = int(a[1])
			actor.step = int(a[2])
			_presentation(op, "pose", {"duration": 0.3})
		"NPCMOVEMOD":
			var actor := _visual_actor(int(a[0]))
			if actor.is_empty(): _fail("missing_visual_actor")
			else: actor.move_mode = 0 if int(a[1]) == 0 else (3 if int(a[1]) == 1 else 4)
		"FACETOFACE":
			var first := _visual_actor(int(a[0]))
			var second := _visual_actor(int(a[1]))
			if first.is_empty() or second.is_empty(): _fail("missing_visual_actor")
			elif first.x != second.x: second.facing = 1 if first.x > second.x else 3
			elif first.y != second.y: second.facing = 2 if first.y > second.y else 0
		"MOVE":
			var actor := _visual_actor(int(a[0]))
			if actor.is_empty(): _fail("missing_move_actor")
			else: _presentation(op, "movement", {"slot": int(a[0]), "x": int(a[1]), "y": int(a[2]), "origin_x": actor.x, "origin_y": actor.y})
		"MOVIE": _presentation(op, "movie", {"resource": "5:%d:%d" % [a[0], a[1]], "args": a.duplicate(), "duration": 2.0})
		"SETMONEY": state.currency = int(a[0])
		"USEMONEY": state.currency = maxi(0, int(state.currency) - int(a[0]))
		"GAINMONEY": state.currency = int(state.currency) + int(a[0])
		"LEARNMAGIC":
			var actor_id := "3:1:%d" % a[0]
			var magic_id := "4:%d:%d" % [a[1], a[2]]
			if not state.party.has(actor_id) or not content.magics.has(magic_id):
				_fail("invalid_learn_magic_resource")
				return
			var learned: Array = state.actors[actor_id].get("learned_extra_magic_ids", []).duplicate()
			learned.append(magic_id)
			state.actors[actor_id].learned_extra_magic_ids = learned
			_presentation(op, "reward", {"text":"%s学会了「%s」" % [state.actors[actor_id].name, content.magics[magic_id].name]})
		"GAINGOODS":
			var id := "6:%d:%d" % [a[0], a[1]]
			if not content.goods.has(id):
				_fail("missing_goods:" + id)
				return
			state.inventory[id] = int(state.inventory.get(id, 0)) + 1
			_presentation(op, "reward", {"text": "获得「%s」" % content.goods[id].name, "goods": id})
		"USEGOODS":
			var id := "6:%d:%d" % [a[0], a[1]]
			if int(state.inventory.get(id, 0)) > 0: _take_good(id)
			else: _jump(int(a[2]))
		"BUY":
			var list: Array = []
			for index in range(0, a[0].size(), 2):
				list.append("6:%d:%d" % [a[0][index + 1], a[0][index]])
			_presentation(op, "shop", {"goods": list})
		"SALE": _presentation(op, "sale", {})
		"RESUMEACTORHP":
			var id := "3:1:%d" % a[0]
			if not state.actors.has(id): _fail("missing_heal_actor")
			else: state.actors[id].hp = int(int(state.actors[id].max_hp) * int(a[1]) / 100)
		"INITFIGHT": rt.encounter = a.duplicate()
		"FIGHTDISENABLE": rt.encounter = []
		"ENTERFIGHT":
			_presentation(op, "battle", {"args": a.duplicate(), "random": false, "enemies": a.slice(1, 4), "loss": int(a[13]), "win": int(a[14])})
		"GAMEOVER":
			rt.active = false
			# 终场显示缺口修复：成功叙事终止(1:2:18@1893)与真败北(1:2:18@377)同为 GAMEOVER opcode，
			# 但请求载荷一律带“胜败乃兵家常事”会误导显示。按源位置精确区分，仅成功终场改用“全剧终”。
			# story_complete() 的 1893 精确判定与普通战败 377 的失败语义均保持不变。
			var over_text := "胜败乃兵家常事。"
			if rt.get("script", "") == "1:2:18":
				var ending := content.instruction("1:2:18", 1893)
				if not ending.is_empty() and ending.name == "GAMEOVER" and int(op.absolute_offset) == int(ending.absolute_offset):
					over_text = "全剧终"
			_presentation(op, "gameover", {"text": over_text})
		_:
			_fail("unsupported_opcode:%s@0x%X" % [op.name, op.absolute_offset])
	_note({"kind": "opcode", "opcode": op.name, "source": op.absolute_offset})

func _presentation(op: Dictionary, kind: String, values: Dictionary) -> void:
	values.kind = kind
	values.source = op.absolute_offset
	state.event_sequence = int(state.get("event_sequence", 0)) + 1
	values.token = "%s:%d:%d" % [runtime().script, int(op.address), state.event_sequence]
	runtime().request = values

func respond(response: Dictionary) -> Dictionary:
	var r := request()
	if r.is_empty() or response.get("token") != r.token:
		return Checks.failure("stale_response")
	match str(r.kind):
		"choice":
			if response.get("choice") not in [0, 1]: return Checks.failure("invalid_choice")
			if int(response.choice) == 1: _jump(int(r.target))
		"movement":
			var actor := _visual_actor(int(r.slot))
			actor.x = int(r.x)
			actor.y = int(r.y)
		"battle": return Checks.failure("battle_requires_combat_result")
		"battle_result":
			_finish_battle_presentation(r)
			return pump()
		"shop", "sale":
			if response.get("action", "close") != "close": return Checks.failure("use_shop_command")
		"gameover": return Checks.failure("game_over")
	runtime().request = {}
	_note({"kind": "respond", "response": response.duplicate(true), "request_kind": r.kind})
	return pump()

func _take_good(id: String) -> void:
	state.inventory[id] = int(state.inventory[id]) - 1
	if int(state.inventory[id]) <= 0: state.inventory.erase(id)

func flag(id: int) -> bool:
	return int(state.flags.get(str(id), 0)) != 0

func _visual_actor(slot: int) -> Dictionary:
	return state.world if slot == 0 else runtime().objects.get(str(slot), {})

func _try_encounter() -> void:
	var config: Array = runtime().encounter
	if config.is_empty() or _random(100) > 3: return
	var candidates: Array = []
	for id in config.slice(0, 8):
		if int(id) == 0: break
		candidates.append(int(id))
	if candidates.is_empty():
		_fail("empty_encounter_table")
		return
	var enemies: Array = []
	for i in range(_random(3) + 1): enemies.append(candidates[_random(candidates.size())])
	_presentation({"absolute_offset": 0, "address": 0}, "battle", {"random": true, "enemies": enemies, "args": [], "loss": 0, "win": 0})


func _fail(error: String) -> Dictionary:
	runtime().error = error
	changed.emit()
	return Checks.failure(error)

func _note(command: Dictionary) -> void:
	var record := {"sequence": trace.size(), "command": command.duplicate(true), "state_hash": JSON.stringify(state, "", true).sha256_text()}
	trace.append(record)
	recorded.emit(record)

func restore_snapshot(candidate: Dictionary) -> Dictionary:
	var problem := _validate_snapshot(candidate)
	if not problem.is_empty(): return Checks.failure(problem)
	state = candidate.duplicate(true)
	_note({"kind": "load"})
	changed.emit()
	return Checks.success()

func _validate_snapshot(saved: Dictionary) -> String:
	if saved.get("schema_version") != 1 or saved.get("content_id") != "fmj-chapter1-candidate" or saved.get("content_hash") != content.identity or saved.get("mode") != "candidate":
		return "存档与当前原作资源不一致"
	if not Checks.json_value(saved): return "invalid_json_state"
	for key in ["world", "actors", "inventory", "flags", "source_runtime", "rng"]:
		if not saved.get(key) is Dictionary: return "invalid_state_section:" + key
	for key in ["currency", "event_sequence", "playtime_ms"]:
		if not Checks.integer(saved.get(key), 0): return "invalid_state_number:" + key
	if not saved.get("party") is Array or saved.party.size() > 3: return "invalid_party"
	for key in ["seed", "state"]:
		if not saved.rng.get(key) is String or not saved.rng[key].is_valid_int(): return "invalid_random_state"
	for id in saved.party:
		if not id is String or not saved.actors.has(id): return "missing_party_actor"
	for id in saved.actors:
		var actor: Variant = saved.actors[id]
		if not content.actors.has(id) or not actor is Dictionary or actor.get("id") != id: return "invalid_actor_identity"
		for key in ["max_hp", "max_mp", "attack", "defense", "speed", "luck", "lingli", "level"]:
			if not Checks.integer(actor.get(key), 0, 65535): return "invalid_actor_stat:" + key
		if not Checks.integer(actor.get("hp"), 0, int(actor.max_hp)) or not Checks.integer(actor.get("mp"), 0, int(actor.max_mp)):
			return "invalid_actor_vitals"
	for id in saved.inventory:
		if not content.goods.has(id) or not Checks.integer(saved.inventory[id], 0, 65535): return "invalid_inventory"
	for id in saved.flags:
		if not id.is_valid_int() or not Checks.integer(saved.flags[id], 0, 1): return "invalid_flag"
	var rt: Dictionary = saved.source_runtime
	if rt.get("adapter_version") != 1 or not content.scripts.has(rt.get("script", "")): return "invalid_script_checkpoint"
	for key in ["request", "objects", "variables"]:
		if not rt.get(key) is Dictionary: return "invalid_runtime_section:" + key
	for key in ["active", "save_enabled"]:
		if not rt.get(key) is bool: return "invalid_runtime_switch:" + key
	if not rt.get("encounter") is Array or not rt.get("error") is String: return "invalid_runtime_state"
	if not Checks.integer(rt.get("pc"), 0) or not Checks.integer(rt.get("steps"), 0): return "invalid_runtime_counter"
	if rt.active and content.instruction(rt.script, int(rt.pc)).is_empty(): return "invalid_program_counter"
	var w: Dictionary = saved.world
	for key in ["x", "y", "camera_x", "camera_y"]:
		if not Checks.integer(w.get(key)): return "invalid_world_position"
	if not Checks.integer(w.get("facing"), 0, 3) or not Checks.integer(w.get("step"), 0, 3): return "invalid_world_pose"
	if w.get("map_id") == "" and saved.party.is_empty() and rt.script == "1:1:1": pass
	elif not content.maps.has(w.get("map_id", "")) or content.cell(w.map_id, int(w.x), int(w.y)).is_empty(): return "invalid_world_map"
	for slot in rt.objects:
		var object: Variant = rt.objects[slot]
		if not slot.is_valid_int() or not object is Dictionary or not content.actors.has(object.get("resource", "")): return "invalid_world_object"
		for key in ["slot", "x", "y", "facing", "step", "move_mode", "kind", "index"]:
			if not Checks.integer(object.get(key), 0): return "invalid_object_field:" + key
		if not object.get("hidden") is bool: return "invalid_object_visibility"
	var r: Dictionary = rt.request
	if not r.is_empty():
		if not Checks.text(r.get("token")) or not Checks.integer(r.get("source"), 0): return "invalid_request_token"
		if r.get("kind") not in ["scene_name", "screen", "prologue", "dialogue", "choice", "pose", "movement", "movie", "reward", "shop", "sale", "battle", "battle_result", "gameover"]: return "invalid_request_kind"
		if r.kind in ["scene_name", "prologue", "dialogue", "reward", "gameover", "battle_result"] and not r.get("text") is String: return "invalid_request_text"
		if r.kind == "choice" and (not r.get("choices") is Array or not Checks.integer(r.get("target"), 0)): return "invalid_choice_request"
		if r.kind == "shop" and not r.get("goods") is Array: return "invalid_shop_request"
		if r.kind in ["battle", "battle_result"] and (not r.get("enemies") is Array or not r.get("args") is Array or not r.get("random") is bool): return "invalid_battle_request"
	if not rt.get("combat", {}) is Dictionary: return "invalid_combat_state"
	if not rt.get("combat", {}).is_empty():
		var restored: Dictionary = _combat_driver().restore(rt.combat)
		if not restored.ok: return "invalid_combat_state:" + str(restored.error)
		if not rt.get("battle_request") is Dictionary or rt.battle_request.get("kind") != "battle": return "missing_battle_continuation"
		if not Checks.integer(rt.get("battle_resume_pc"), 0) or not rt.get("battle_resume_active") is bool or not rt.get("battle_log") is Array: return "invalid_battle_continuation"
		if rt.combat.phase == "event" and not bool(rt.get("battle_event", false)): return "missing_battle_event"
		if rt.combat.phase == "finished" and r.get("kind") != "battle_result": return "missing_battle_result"
		if rt.combat.phase == "select" and r.get("kind") != "battle": return "missing_battle_selection"
	return ""

func _plain(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value: result[str(key)] = _plain(value[key])
		return result
	if value is Array:
		var result: Array = []
		for child in value: result.append(_plain(child))
		return result
	if value is StringName: return str(value)
	return value

func story_complete() -> bool:
	# Both original final choices converge here after the credits and last movie.
	# GAMEOVER also appears on battle loss; a flag alone cannot identify the ending.
	if state.is_empty(): return false
	var rt := runtime()
	var r := request()
	if rt.get("script", "") != "1:2:18" or r.get("kind", "") != "gameover": return false
	var ending := content.instruction("1:2:18", 1893)
	return not ending.is_empty() and ending.name == "GAMEOVER" and int(r.get("source", -1)) == int(ending.absolute_offset)

func chapter_complete() -> bool:
	if state.is_empty() or state.party.is_empty(): return false
	return int(state.inventory.get("6:14:12", 0)) > 0 and state.world.map_id == "2:1:6" and ready() and int(state.actors[state.party[0]].hp) > 0

func chapter_two_complete() -> bool:
	return not state.is_empty() and flag(216) and runtime().script == "1:2:2" and ready() and not state.party.is_empty() and int(state.actors[state.party[0]].hp) > 0

func chapter_three_complete() -> bool:
	return not state.is_empty() and flag(224) and runtime().script == "1:8:2" and ready() and not state.party.is_empty() and int(state.actors[state.party[0]].hp) > 0

func _random(modulus: int) -> int:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(state.rng.seed)
	rng.state = int(state.rng.state)
	var value := rng.randi()
	state.rng.state = str(rng.state)
	return int(value % modulus)

func _combat_catalog() -> Dictionary:
	var out: Dictionary = {}
	for key in ["goods_by_id", "magics_by_id", "magic_chains_by_id", "levelup_chains_by_id"]:
		out[key] = content.data.get(key, {})
	return out

func _combat_driver() -> RefCounted:
	var driver: RefCounted = load("res://src/chapter1/chapter_combat.gd").new()
	driver.configure(_combat_catalog())
	return driver

func begin_battle() -> Dictionary:
	var r := request()
	if r.get("kind") != "battle": return Checks.failure("no_battle_request")
	if not runtime().get("combat", {}).is_empty(): return Checks.success()
	var options := {"balance_version": 1, "inventory": state.inventory.duplicate(true), "random_fight": bool(r.random), "max_rounds": 0, "round_events": []}
	if not bool(r.random):
		options.max_rounds = int(r.args[0])
		for i in range(3):
			if int(r.args[10 + i]) != 0:
				options.round_events.append({"round": int(r.args[7 + i]), "event_id": int(r.args[10 + i])})
	var party: Array = []
	var enemies: Array = []
	for id in state.party: party.append(state.actors[id].duplicate(true))
	for index in r.enemies:
		if int(index) == 0: continue
		var id := "3:3:%d" % index
		if not content.actors.has(id): return _fail("missing_enemy:" + id)
		var enemy: Dictionary = preload("res://src/chapter1/chapter_balance.gd").enemy(content.actors[id])

		enemies.append(enemy)
	var driver := _combat_driver()
	driver.configure(_combat_catalog(), options)
	var result: Dictionary = driver.begin(party, enemies, _random(2147483647))
	if not result.ok: return _fail(str(result.error))
	runtime().battle_request = r
	runtime().battle_resume_pc = int(runtime().pc)
	runtime().battle_resume_active = bool(runtime().active)
	runtime().battle_log = []
	_note({"kind": "battle_started", "enemies": r.enemies, "random": r.random})
	return _accept_combat_result(result)

func combat_action(command: Dictionary) -> Dictionary:
	if command.get("token") != request().get("token"): return Checks.failure("stale_battle_command")
	if request().get("kind") != "battle" or runtime().get("combat", {}).is_empty():
		return Checks.failure("no_active_battle")
	var driver := _combat_driver()
	var restored: Dictionary = driver.restore(runtime().combat)
	if not restored.ok: return _fail(str(restored.error))
	var result: Dictionary = driver.action(command)
	if not result.ok: return Checks.failure(str(result.error))
	_note({"kind": "combat_action", "command": command.duplicate(true)})
	return _accept_combat_result(result)

func combat_actions() -> Dictionary:
	if runtime().get("combat", {}).is_empty(): return {}
	var driver := _combat_driver()
	if not driver.restore(runtime().combat).ok: return {}
	return driver.available_actions()

func _accept_combat_result(result: Dictionary) -> Dictionary:
	var rt := runtime()
	rt.combat = result.snapshot.duplicate(true)
	for actor in rt.combat.party: state.actors[actor.id] = actor.duplicate(true)
	state.inventory = rt.combat.inventory.duplicate(true)
	rt.battle_log.append_array(result.events)
	state.event_sequence = int(state.event_sequence) + 1
	var r: Dictionary = rt.battle_request.duplicate(true)
	r.token = "battle:%d" % state.event_sequence
	rt.request = r
	if rt.combat.phase == "event":
		for event in result.events:
			if event.type == "battle_script_event":
				rt.battle_event = true
				rt.request = {}
				if not _trigger(int(event.event_id)): return _fail("missing_battle_event:%d" % event.event_id)
				return pump()
	elif rt.combat.phase == "finished":
		r.kind = "battle_result"
		r.outcome = rt.combat.outcome
		r.rewards = rt.combat.rewards.duplicate(true)
		if r.outcome == "won":
			state.currency = int(state.currency) + int(r.rewards.money)
			for id in r.rewards.goods: state.inventory[id] = int(state.inventory.get(id, 0)) + int(r.rewards.goods[id])
			r.text = "战斗胜利  ·  获得银两 %d，经验 %d" % [r.rewards.money, r.rewards.experience]
		elif r.outcome == "fled": r.text = "成功脱离战斗。"
		else: r.text = "力竭倒下。"
		rt.request = r
		rt.active = false
	changed.emit()
	return Checks.success()

func _resume_battle_event() -> void:
	var rt := runtime()
	rt.battle_event = false
	rt.pc = int(rt.battle_resume_pc)
	rt.active = bool(rt.battle_resume_active)
	var driver := _combat_driver()
	var restored: Dictionary = driver.restore(rt.combat)
	if not restored.ok:
		_fail(str(restored.error))
		return
	_accept_combat_result(driver.action({"type": "resume_event"}))

func _finish_battle_presentation(r: Dictionary) -> void:
	var rt := runtime()
	rt.request = {}
	rt.combat = {}
	if bool(r.random):
		rt.active = false
		if r.outcome == "lost": _presentation({"absolute_offset": 0, "address": 0}, "gameover", {"text": "胜败乃兵家常事。"})
	else:
		rt.active = true
		_jump(int(r.win) if r.outcome in ["won", "timeout"] else int(r.loss))
	_note({"kind": "battle_settled", "outcome": r.outcome})

func shop_buy(goods_id: String, quantity: int = 1) -> Dictionary:
	var r := request()
	if r.get("kind") != "shop" or goods_id not in r.goods or quantity < 1 or quantity > 99:
		return Checks.failure("不能购买此物品")
	var price := int(content.goods[goods_id].buy_price) * quantity
	if int(state.currency) < price: return Checks.failure("银两不足")
	if int(state.inventory.get(goods_id, 0)) + quantity > 99: return Checks.failure("此物品已满 99 件")
	state.currency = int(state.currency) - price
	state.inventory[goods_id] = int(state.inventory.get(goods_id, 0)) + quantity
	_note({"kind": "shop_buy", "goods": goods_id, "quantity": quantity, "price": price})
	changed.emit()
	return Checks.success()

func can_sell(goods_id: String) -> bool:
	var goods: Dictionary = content.goods.get(goods_id, {})
	if goods_id == "6:11:6" and flag(240) and not flag(241): return false
	# Event-bearing goods protect story progression. Only the three optional
	# cards may be sold among special goods; keep the sword and final vessel.
	return not goods.is_empty() and int(goods.get("event_id", 0)) == 0 and (int(goods.type) != 14 or goods_id in ["6:14:5", "6:14:6", "6:14:7"])

func shop_sell(goods_id: String, quantity: int = 1) -> Dictionary:
	if request().get("kind") != "sale" or quantity < 1 or quantity > 99:
		return Checks.failure("此时不能出售")
	var goods: Dictionary = content.goods.get(goods_id, {})
	if not can_sell(goods_id): return Checks.failure("剧情物品不能出售")
	if int(state.inventory.get(goods_id, 0)) < quantity: return Checks.failure("背包数量不足")
	var price := int(goods.sell_price) * quantity
	state.inventory[goods_id] = int(state.inventory[goods_id]) - quantity
	state.currency = mini(99999, int(state.currency) + price)
	_note({"kind":"shop_sell", "goods":goods_id, "quantity":quantity, "price":price})
	changed.emit()
	return Checks.success()

func equip(goods_id: String, slot: int = -1, actor_index: int = 0) -> Dictionary:
	var battle_equipment: bool = request().get("kind") == "battle" and runtime().get("combat", {}).get("phase") == "select"
	if (not ready() and not battle_equipment) or state.party.is_empty(): return Checks.failure("此时不能换装")
	if actor_index < 0 or actor_index >= state.party.size(): return Checks.failure("队员不存在")
	var driver := _combat_driver()
	var id: String = state.party[actor_index]
	var result: Dictionary
	if battle_equipment:
		var restored: Dictionary = driver.restore(runtime().combat)
		if not restored.ok: return Checks.failure(str(restored.error))
		result = driver.equip_during_selection(goods_id, slot, actor_index)
	else:
		result = driver.equip_actor(state.actors[id], state.inventory, goods_id, slot)
	if not result.ok: return Checks.failure(str(result.error))
	if not battle_equipment:
		state.actors[id] = result.actor
		state.inventory = result.inventory
	for event in result.events:
		if event.type == "source_flag":
			if int(event.value) == 0: state.flags.erase(str(int(event.flag)))
			else: state.flags[str(int(event.flag))] = 1
	var command := {"kind": "equip", "goods": goods_id, "slot": slot}
	if actor_index != 0: command.actor_index = actor_index
	_note(command)
	if battle_equipment: return _accept_combat_result(result)
	changed.emit()
	return Checks.success()

func field_use(goods_id: String, target: int = 0) -> Dictionary:
	if not ready(): return Checks.failure("此时不能使用道具")
	var party: Array = []
	for id in state.party: party.append(state.actors[id])
	var result: Dictionary = _combat_driver().use_field_item(party, state.inventory, goods_id, target)
	if not result.ok: return Checks.failure(str(result.error))
	var script_event := 0
	for event in result.events:
		if event.type == "field_script_event":
			script_event = int(event.event_id)
			if content.event_address(runtime().script, script_event) == 0:
				return Checks.failure("此处无法使用该道具")
	for actor in result.party: state.actors[actor.id] = actor
	state.inventory = result.inventory
	_note({"kind": "field_item", "goods": goods_id, "target": target})
	if script_event > 0:
		_trigger(script_event)
		return pump()
	changed.emit()
	return Checks.success()

func field_magic(magic_id: String, target: int = 0, actor_index: int = 0) -> Dictionary:
	if not ready(): return Checks.failure("此时不能施法")
	var party: Array = []
	for id in state.party: party.append(state.actors[id])
	var result: Dictionary = _combat_driver().use_field_magic(party, actor_index, magic_id, target)
	if not result.ok: return Checks.failure(str(result.error))
	for actor in result.party: state.actors[actor.id] = actor
	var command := {"kind": "field_magic", "magic": magic_id, "target": target}
	if actor_index != 0: command.actor_index = actor_index
	_note(command)
	changed.emit()
	return Checks.success()

func tick_world(reason: String = "idle") -> Dictionary:
	if not ready(): return Checks.failure("not_ready")
	var result: Dictionary = preload("res://src/chapter1/chapter_npc_motion.gd").tick(content,state.world,runtime().objects,Callable(self,"_random"))
	if not result.ok: return _fail(str(result.error))
	runtime().objects = result.objects
	_note({"kind":"world_tick", "reason":reason, "events":result.events})
	if result.changed: changed.emit()
	return Checks.success()

func add_playtime(milliseconds: int) -> void:
	if not state.is_empty() and milliseconds > 0:
		state.playtime_ms = int(state.playtime_ms) + milliseconds
