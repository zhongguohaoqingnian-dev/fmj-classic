extends RefCounted
## Native turn resolution. No original text, resource bytes or upstream code included.
## Rule evidence and unresolved reverse-engineering details: docs/chapter1/combat.md.

const FORMAT := 1
const RULESET := "bbk-a100-candidate-v1"
const RULE_SOURCE := "erduoniba/baye-fmj-app@60c41ea2d9932b295833ece7004394497610596a:Fmj/fmj_c_engine/engine.c"
const STATUS_BITS := {"poison": 8, "confusion": 4, "seal": 2, "sleep": 1}
const STAT_KEYS := ["max_hp", "max_mp", "attack", "defense", "speed", "lingli", "luck"]

var _catalog: Dictionary = {}
var _options: Dictionary = {}
var _state: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _events: Array = []
var _error := ""

func configure(catalog: Dictionary, options: Dictionary = {}) -> void:
	_catalog = catalog.duplicate(true)
	_options = options.duplicate(true)

func begin(party: Array, enemies: Array, rng_seed: int) -> Dictionary:
	if party.is_empty() or enemies.is_empty() or party.size() > 3 or enemies.size() > 3:
		return _failure("Combat requires 1–3 party members and 1–3 enemies")
	var p: Array = []
	var e: Array = []
	for side in [party, enemies]:
		for input in side:
			if not input is Dictionary:
				return _failure("Fighter must be a Dictionary")
			for key in ["id", "name", "hp", "max_hp", "mp", "max_mp", "attack", "defense", "speed", "luck", "lingli", "level"]:
				if not input.has(key):
					return _failure("Fighter %s missing source field %s" % [input.get("id", "?"), key])
			if int(input.hp) < 0 or int(input.hp) > int(input.max_hp) or int(input.mp) < 0 or int(input.mp) > int(input.max_mp):
				return _failure("Fighter HP/MP outside source limits")
	for input in party:
		p.append(_fighter(input, "party", p.size()))
	for input in enemies:
		e.append(_fighter(input, "enemies", e.size()))
	if _living(p).is_empty() or _living(e).is_empty():
		return _failure("Both sides must contain a living fighter")
	_rng.seed = rng_seed
	_state = {"version": FORMAT, "ruleset": RULESET, "rules_source": RULE_SOURCE,
		"rules_verified_original": false, "party": p, "enemies": e, "round": 0,
		"phase": "select", "pending": [], "rewards": {"money": 0, "experience": 0, "goods": {}},
		"inventory": _options.get("inventory", {}).duplicate(true),
		"options": _options.duplicate(true), "rng_seed": str(rng_seed), "rng_state": str(_rng.state),
		"resolved_actions": 0, "outcome": "", "event_rounds_seen": [], "drops": {}}
	_events = [{"type": "battle_started", "round": 0, "party_count": p.size(), "enemy_count": e.size()}]
	_error = ""
	_check_round_events()
	return _result()

func snapshot() -> Dictionary:
	if not _state.is_empty():
		_state.rng_state = str(_rng.state)
	return _plain(_state)

func restore(saved: Dictionary) -> Dictionary:
	var problem := _validate_saved_combat(saved)
	if not problem.is_empty():
		return _failure(problem)
	_state = _plain(saved)
	_options = _state.options.duplicate(true)
	_rng.seed = int(str(saved.rng_seed))
	_rng.state = int(str(saved.rng_state))
	_events = []
	_error = ""
	return _result()

func action(command: Dictionary) -> Dictionary:
	if _state.is_empty():
		return _failure("Combat has not begun")
	if _state.phase == "finished":
		return _failure("Combat is already finished; rewards cannot be claimed twice")
	var before := snapshot()
	_events = []
	_error = ""
	if _state.phase == "event":
		if command.get("type") != "resume_event":
			return _failure("A source battle event must be resolved before selecting an action")
		_state.phase = "select"
		return _result()
	var actor_index := int(command.get("actor", _next_actor()))
	if actor_index != _next_actor():
		return _failure("Select the next living party member's action")
	var selected := command.duplicate(true)
	selected.actor = actor_index
	selected.side = "party"
	var validation := _validate_command(selected)
	if not validation.is_empty():
		return _failure(validation)
	_state.pending.append(selected)
	_events.append({"type": "action_selected", "actor": actor_index, "command": selected.duplicate(true)})
	if _next_actor() < 0:
		_resolve_round()
	if not _error.is_empty():
		var problem := _error
		restore(before)
		return _failure(problem)
	return _result()

## Validate a checkpoint without assigning it to the live driver or drawing RNG values.
func _validate_saved_combat(saved: Dictionary) -> String:
	if not _saved_json(saved):
		return "Combat checkpoint is not finite JSON data"
	if not _saved_integer(saved.get("version"), FORMAT, FORMAT) or saved.get("ruleset") != RULESET or saved.get("rules_source") != RULE_SOURCE or saved.get("rules_verified_original") != false:
		return "Unsupported combat save version or ruleset"
	for key in ["party", "enemies", "pending", "event_rounds_seen"]:
		if not saved.get(key) is Array: return "Malformed combat array: " + key
	for key in ["options", "inventory", "drops", "rewards"]:
		if not saved.get(key) is Dictionary: return "Malformed combat dictionary: " + key
	for key in ["round", "resolved_actions"]:
		if not _saved_integer(saved.get(key)): return "Invalid combat counter: " + key
	for key in ["rng_seed", "rng_state"]:
		var value: Variant = saved.get(key)
		if not value is String or not value.is_valid_int() or str(int(value)) != value:
			return "Invalid saved combat random state"
	if saved.get("phase") not in ["select", "event", "finished"] or not saved.get("outcome") is String:
		return "Malformed combat phase"
	for side in ["party", "enemies"]:
		if saved[side].is_empty() or saved[side].size() > 3: return "Combat side must have 1–3 fighters"
		for slot in saved[side].size():
			var fighter: Variant = saved[side][slot]
			var problem := _validate_saved_fighter(fighter, side, slot)
			if not problem.is_empty(): return problem
	for key in ["inventory", "drops"]:
		var problem := _validate_saved_goods(saved[key])
		if not problem.is_empty(): return problem
	var rewards: Dictionary = saved.rewards
	if not _saved_integer(rewards.get("money")) or not _saved_integer(rewards.get("experience")) or not rewards.get("goods") is Dictionary:
		return "Malformed combat reward record"
	var goods_problem := _validate_saved_goods(rewards.goods)
	if not goods_problem.is_empty(): return goods_problem
	var options: Dictionary = saved.options
	if options.has("inventory"):
		if not options.inventory is Dictionary: return "Malformed initial inventory"
		var problem := _validate_saved_goods(options.inventory)
		if not problem.is_empty(): return problem
	if options.has("random_fight") and not options.random_fight is bool: return "Malformed random battle option"
	if options.has("max_rounds") and not _saved_integer(options.max_rounds): return "Malformed round limit"
	if options.has("leader_slot") and not _saved_integer(options.leader_slot, 0, saved.party.size() - 1): return "Invalid party leader slot"
	var round_events: Variant = options.get("round_events", [])
	if not round_events is Array: return "Malformed battle event table"
	var possible_events: Array = []
	var current_event := false
	for event in round_events:
		if not event is Dictionary or not _saved_integer(event.get("round")) or not _saved_integer(event.get("event_id"), 0, 255): return "Invalid source battle event"
		possible_events.append(str(int(event.event_id)))
		if int(event.round) == int(saved.round) and str(int(event.event_id)) in saved.event_rounds_seen: current_event = true
	var seen: Array = []
	for event in saved.event_rounds_seen:
		if not event is String or event not in possible_events or event in seen: return "Invalid completed battle event"
		seen.append(event)
	if options.has("balance_version") and not _saved_integer(options.balance_version,1,1): return "Unknown balance version"
	var living_party := _living(saved.party)
	var living_enemies := _living(saved.enemies)
	if saved.phase == "finished":
		if not saved.pending.is_empty() or saved.outcome not in ["won", "lost", "fled", "timeout"]: return "Invalid finished battle"
		if saved.outcome == "won":
			if not living_enemies.is_empty() or living_party.is_empty(): return "Victory conflicts with surviving fighters"
			var money := 0
			var experience := 0
			for enemy in saved.enemies:
				money += int(enemy.get("reward_money", 0))
				experience += int(enemy.get("reward_exp", 0))
			if int(rewards.money) != money or int(rewards.experience) != experience or rewards.goods != saved.drops: return "Victory reward record conflicts with resolved enemies"
		elif saved.outcome == "lost" and (not living_party.is_empty() or living_enemies.is_empty()): return "Defeat conflicts with surviving fighters"
		elif saved.outcome == "fled" and not bool(options.get("random_fight", false)): return "A scripted battle cannot have fled"
		elif saved.outcome == "timeout" and int(options.get("max_rounds", 0)) <= 0: return "Battle timeout requires a round limit"
	else:
		if not saved.outcome.is_empty() or living_party.is_empty() or living_enemies.is_empty(): return "Unfinished battle has invalid outcome or empty living side"
		if saved.phase == "event" and (not saved.pending.is_empty() or not current_event): return "Battle event pause has no current source event"
	if saved.outcome != "won" and (int(rewards.money) != 0 or int(rewards.experience) != 0 or not rewards.goods.is_empty()): return "Unwon battle cannot contain claimed rewards"
	if saved.phase == "select" and saved.pending.size() >= living_party.size(): return "Fully selected round cannot remain queued"
	# Reuse the real command validator against an isolated prefix queue. This validates
	# learned spells, target sides, MP, item types and reservations without resolving turns.
	var validator = get_script().new()
	validator._catalog = _catalog
	validator._state = saved.duplicate(true)
	validator._state.pending = []
	for command in saved.pending:
		if not command is Dictionary or not command.get("type") is String or command.get("side") != "party" or not _saved_integer(command.get("actor"), 0, saved.party.size() - 1): return "Malformed saved action"
		if int(command.actor) != validator._next_actor(): return "Saved actions are not the living party prefix"
		if command.has("target") and not _saved_integer(command.target, -1, 2): return "Malformed action target"
		if command.has("token") and not command.token is String: return "Malformed action token"
		for key in ["magic_id", "goods_id"]:
			if command.has(key) and not command[key] is String: return "Malformed action resource reference"
		# A legal equipment change may lower MP after this command was selected.
		# Execution already falls back to attack when MP is no longer sufficient.
		var problem: String = validator._validate_command(command, false)
		if not problem.is_empty(): return "Invalid saved action: " + problem
		validator._state.pending.append(command)
	return ""

func _validate_saved_fighter(fighter: Variant, side: String, slot: int) -> String:
	if not fighter is Dictionary: return "Malformed saved fighter"
	for key in ["id", "name"]:
		if not fighter.get(key) is String or fighter[key].is_empty(): return "Saved fighter missing " + key
	if fighter.get("side") != side or not _saved_integer(fighter.get("slot"), slot, slot): return "Saved fighter slot or side does not match its array"
	for key in ["hp", "max_hp", "mp", "max_mp", "attack", "defense"]:
		if not _saved_integer(fighter.get(key), 0, 65535): return "Invalid saved fighter word: " + key
	for key in ["speed", "luck", "lingli", "level"]:
		if not _saved_integer(fighter.get(key), 0, 255): return "Invalid saved fighter byte: " + key
	if side == "party" and int(fighter.level) < 1: return "Player growth level must start at one"
	if int(fighter.hp) > int(fighter.max_hp) or int(fighter.mp) > int(fighter.max_mp): return "Saved fighter HP/MP outside limits"
	if not _saved_integer(fighter.get("experience")) or not fighter.get("defending") is bool: return "Malformed saved fighter runtime fields"
	for key in ["reward_exp", "reward_money", "next_level_exp", "magic_learn_count"]:
		if fighter.has(key) and not _saved_integer(fighter[key]): return "Invalid fighter counter: " + key
	for key in ["hp_per_round", "mp_per_round", "immune_mask_raw", "base_immune_mask_raw", "attack_mask_raw", "attack_rounds", "status_rounds", "iq", "intelligence"]:
		if fighter.has(key) and not _saved_integer(fighter[key], 0, 255): return "Invalid fighter source byte: " + key
	if fighter.has("status_recovery_rounds") and not _saved_integer(fighter.status_recovery_rounds,0,2): return "Invalid status recovery duration"
	if not fighter.get("status") is Dictionary or not fighter.get("modifiers") is Dictionary: return "Malformed saved fighter effects"
	for effect in fighter.status:
		if effect not in STATUS_BITS or not _saved_integer(fighter.status[effect], 1, 256): return "Invalid saved status or remaining duration"
	for stat in fighter.modifiers:
		var modifier: Variant = fighter.modifiers[stat]
		if stat not in ["attack", "defense", "speed"] or not modifier is Dictionary: return "Invalid saved stat modifier"
		if not _saved_integer(modifier.get("value"), -65535, 65535) or not _saved_integer(modifier.get("rounds"), 0, 255): return "Invalid saved modifier amount or duration"
	for key in ["magic_ids", "learned_extra_magic_ids", "equipment_ids"]:
		if not fighter.has(key): continue
		if not fighter[key] is Array or (key == "equipment_ids" and fighter[key].size() != 8): return "Malformed fighter resource list"
		for id in fighter[key]:
			if not id is String: return "Invalid fighter resource identity"
			if id.is_empty() and key != "equipment_ids": return "Empty magic identity"
			var section := "goods_by_id" if key == "equipment_ids" else "magics_by_id"
			if not id.is_empty() and not _catalog.get(section, {}).is_empty() and not _catalog[section].has(id): return "Unknown fighter resource " + id
	for key in ["magic_chain", "level_chain"]:
		if not fighter.has(key): continue
		if not fighter[key] is String: return "Malformed fighter chain reference"
		var section := "magic_chains_by_id" if key == "magic_chain" else "levelup_chains_by_id"
		if not fighter[key].is_empty() and not _catalog.get(section, {}).is_empty() and not _catalog[section].has(fighter[key]): return "Unknown fighter chain " + fighter[key]
	for key in ["carry_goods_raw", "drop_goods_raw"]:
		if not fighter.has(key): continue
		if not fighter[key] is Array or fighter[key].size() != 3: return "Malformed enemy goods tuple"
		for value in fighter[key]:
			if not _saved_integer(value, 0, 255): return "Invalid enemy goods tuple value"
	if fighter.has("equipment_ids") and not _catalog.get("goods_by_id", {}).is_empty():
		var equipment_types := [6, 6, 5, 3, 7, 2, 4, 1]
		for index in 8:
			var id: String = fighter.equipment_ids[index]
			if not id.is_empty() and _resource_type(_catalog.goods_by_id[id]) != equipment_types[index]: return "Saved equipment type does not match its slot"
	return ""

func _validate_saved_goods(goods: Dictionary) -> String:
	for id in goods:
		if not id is String or id.is_empty() or not _saved_integer(goods[id]): return "Invalid saved item quantity or identity"
		if not _catalog.get("goods_by_id", {}).is_empty() and not _catalog.goods_by_id.has(id): return "Unknown saved item " + id
	return ""

static func _saved_integer(value: Variant, minimum: int = 0, maximum: int = 2147483647) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floor(float(value)) and value >= minimum and value <= maximum

static func _saved_json(value: Variant, depth: int = 0) -> bool:
	if depth > 32: return false
	if value is Dictionary:
		for key in value:
			if not key is String or not _saved_json(value[key], depth + 1): return false
		return true
	if value is Array:
		for item in value:
			if not _saved_json(item, depth + 1): return false
		return true
	if value is float: return is_finite(value) and absf(value) <= 9007199254740991.0
	if value is int: return value >= -9007199254740991 and value <= 9007199254740991
	return value == null or value is bool or value is String

func available_actions(actor_index: int = -1) -> Dictionary:
	if _state.is_empty() or _state.phase != "select":
		return {}
	if actor_index < 0:
		actor_index = _next_actor()
	if actor_index < 0 or actor_index >= _state.party.size():
		return {}
	var actor: Dictionary = _state.party[actor_index]
	var magic_ids: Array = []
	for id in _known_magics(actor):
		var magic := _magic(str(id))
		if not magic.is_empty() and not _has_status(actor, "seal") and int(actor.mp) >= _cost(magic):
			magic_ids.append(id)
	var goods_ids: Array = []
	for id in _state.inventory:
		var reserved := 0
		for pending in _state.pending:
			if pending.get("goods_id") == id: reserved += 1
		if int(_state.inventory[id]) > reserved and _catalog.get("goods_by_id", {}).has(id):
			var item: Dictionary = _catalog.goods_by_id[id]
			if _resource_type(item) in [7, 8, 9, 10, 11, 12]:
				goods_ids.append(id)
	return {"actor": actor_index, "attack": true, "defend": true,
		"flee": bool(_options.get("random_fight", false)), "magic_ids": magic_ids,
		"goods_ids": goods_ids, "enemy_targets": _living(_state.enemies), "ally_targets": range(_state.party.size())}

## Equipment is a menu operation during selection, never a combat action.
## Retain this engine's existing item reservation policy; the C/Kotlin
## reservation disagreement is recorded separately from this common behavior.
func equip_during_selection(goods_id: String, slot: int, actor_index: int) -> Dictionary:
	if _state.is_empty() or _state.phase != "select":
		return _failure("Equipment requires battle command selection")
	if actor_index < 0 or actor_index >= _state.party.size():
		return _failure("Equipment recipient does not exist")
	var result := equip_actor(_state.party[actor_index], _state.inventory, goods_id, slot)
	if not result.ok: return _failure(str(result.error))
	var reserved := {}
	for command in _state.pending:
		if command.get("type") in ["item", "throw"]:
			var id := str(command.goods_id)
			reserved[id] = int(reserved.get(id, 0)) + 1
	for id in reserved:
		if int(result.inventory.get(id, 0)) < int(reserved[id]):
			return _failure("Equipment is reserved by a selected item action")
	_state.party[actor_index] = result.actor
	_state.inventory = result.inventory
	_events = result.events
	_error = ""
	return _result()

## Applies a field item without entering battle or altering an active combat instance.
func use_field_item(party: Array, inventory: Dictionary, goods_id: String, target: int) -> Dictionary:
	if not _catalog.get("goods_by_id", {}).has(goods_id):
		return {"ok": false, "error": "Missing source goods %s" % goods_id}
	if target < 0 or target >= party.size() or int(inventory.get(goods_id, 0)) < 1:
		return {"ok": false, "error": "Invalid field item target or empty inventory"}
	var goods: Dictionary = _catalog.goods_by_id[goods_id]
	var kind := _resource_type(goods)
	if kind == 13:
		return {"ok": true, "party": party.duplicate(true), "inventory": inventory.duplicate(true),
			"events": [{"type": "field_script_event", "event_id": 255, "goods_id": goods_id}]}
	if kind not in [9, 10, 11]:
		return {"ok": false, "error": "This goods class has no field healing effect"}
	var isolated = get_script().new()
	isolated.configure(_catalog)
	var actors: Array = []
	for entry in party:
		actors.append(_fighter(entry, "party", actors.size()))
	isolated._state = {"party": actors, "enemies": [], "inventory": inventory.duplicate(true), "drops": {}}
	isolated._use_goods(actors[target], {"type": "item", "goods_id": goods_id, "target": target})
	if not isolated._error.is_empty():
		return {"ok": false, "error": isolated._error}
	return {"ok": true, "party": _plain(actors), "inventory": _plain(isolated._state.inventory), "events": _plain(isolated._events)}

func use_field_magic(party: Array, actor_index: int, magic_id: String, target: int) -> Dictionary:
	if actor_index < 0 or actor_index >= party.size() or target < 0 or target >= party.size():
		return {"ok": false, "error": "Field magic actor or target is outside party"}
	var spell := _magic(magic_id)
	if spell.is_empty() or _resource_type(spell) not in [3, 4]:
		return {"ok": false, "error": "Only source restoration or revival magic can be used in the field"}
	if magic_id not in _known_magics(party[actor_index]) or int(party[actor_index].mp) < _cost(spell) or int(party[actor_index].hp) <= 0:
		return {"ok": false, "error": "Field spell not learned, insufficient MP, or caster is down"}
	var actors: Array = []
	for entry in party:
		actors.append(_fighter(entry, "party", actors.size()))
	if _has_status(actors[actor_index], "seal"):
		return {"ok": false, "error": "Caster is sealed"}
	var isolated = get_script().new()
	isolated.configure(_catalog)
	isolated._state = {"party": actors, "enemies": [], "drops": {}}
	isolated._cast(actors[actor_index], {"magic_id": magic_id, "target": target})
	if not isolated._error.is_empty():
		return {"ok": false, "error": isolated._error}
	return {"ok": true, "party": _plain(actors), "events": _plain(isolated._events)}

## Equipment ARS totals already include worn goods. Replace their contribution once.
## Slots follow importer: accessory1, accessory2, wrist, feet, weapon, body, shoulder, head.
func equip_actor(actor_input: Dictionary, inventory_input: Dictionary, goods_id: String, requested_slot: int = -1) -> Dictionary:
	var actor := actor_input.duplicate(true)
	var inventory := inventory_input.duplicate(true)
	var equipment: Array = actor.get("equipment_ids", ["", "", "", "", "", "", "", ""]).duplicate()
	if equipment.size() != 8:
		return {"ok": false, "error": "Source equipment array must contain eight slots"}
	var incoming: Dictionary = {}
	var slot := requested_slot
	if not goods_id.is_empty():
		incoming = _catalog.get("goods_by_id", {}).get(goods_id, {})
		if incoming.is_empty():
			return {"ok": false, "error": "Missing source equipment %s" % goods_id}
		var kind := _resource_type(incoming)
		if kind < 1 or kind > 7:
			return {"ok": false, "error": "Goods is not equipment"}
		var actor_number := int(actor.get("index", str(actor.id).get_slice(":", 2)))
		if actor_number <= 0 or not (int(incoming.get("enable_mask_raw", 0)) & (1 << (actor_number - 1))):
			return {"ok": false, "error": "Source equipment restriction excludes this actor"}
		var slots := {1: 7, 2: 5, 3: 3, 4: 6, 5: 2, 7: 4}
		if kind == 6:
			if slot < 0:
				slot = 0 if str(equipment[0]).is_empty() else 1
			if slot not in [0, 1]:
				return {"ok": false, "error": "Decoration must use an accessory slot"}
		else:
			if slot >= 0 and slot != int(slots[kind]):
				return {"ok": false, "error": "Equipment type does not match requested slot"}
			slot = int(slots[kind])
		if int(inventory.get(goods_id, 0)) <= 0 and equipment[slot] != goods_id:
			return {"ok": false, "error": "Equipment is absent from inventory"}
	if slot < 0 or slot > 7:
		return {"ok": false, "error": "An equipment slot is required when removing gear"}
	var old_id := str(equipment[slot])
	if old_id == goods_id:
		return {"ok": true, "actor": actor, "inventory": inventory, "events": []}
	var outgoing: Dictionary = {}
	if not old_id.is_empty():
		outgoing = _catalog.get("goods_by_id", {}).get(old_id, {})
		if outgoing.is_empty():
			return {"ok": false, "error": "Missing currently equipped source goods %s" % old_id}
	for stat in STAT_KEYS:
		var old_bonus := _equipment_bonus(outgoing, stat)
		var new_bonus := _equipment_bonus(incoming, stat)
		actor[stat] = clampi(int(actor.get(stat, 0)) - old_bonus + new_bonus, 0, 999 if stat in ["max_hp", "max_mp", "attack", "defense"] else 99)
	for stat in ["hp_per_round", "mp_per_round"]:
		actor[stat] = int(actor.get(stat, 0)) - int(outgoing.get(stat, 0)) + int(incoming.get(stat, 0))
	var old_equipped_mask := 0
	for id in equipment:
		var item: Dictionary = _catalog.get("goods_by_id", {}).get(str(id), {})
		if _resource_type(item) in [1, 2, 3, 4, 5]:
			old_equipped_mask |= int(item.get("effect_mask_raw", 0))
	actor.base_immune_mask_raw = int(actor.get("base_immune_mask_raw", int(actor.get("immune_mask_raw", 0)) & ~old_equipped_mask))
	if not old_id.is_empty():
		inventory[old_id] = int(inventory.get(old_id, 0)) + 1
	if not goods_id.is_empty():
		inventory[goods_id] = int(inventory.get(goods_id, 0)) - 1
	equipment[slot] = goods_id
	actor.equipment_ids = equipment
	actor.immune_mask_raw = int(actor.base_immune_mask_raw)
	for id in equipment:
		var item: Dictionary = _catalog.get("goods_by_id", {}).get(str(id), {})
		if _resource_type(item) in [1, 2, 3, 4, 5]:
			actor.immune_mask_raw = int(actor.immune_mask_raw) | int(item.get("effect_mask_raw", 0))
	if slot == 4:
		actor.attack_mask_raw = int(incoming.get("effect_mask_raw", 0))
		actor.attack_rounds = int(incoming.get("rounds", 0))
	actor.hp = mini(int(actor.hp), int(actor.max_hp))
	actor.mp = mini(int(actor.mp), int(actor.max_mp))
	var changes: Array = [{"type": "equipment_changed", "slot": slot, "old_id": old_id, "goods_id": goods_id}]
	if int(outgoing.get("event_id", 0)) != 0:
		changes.append({"type": "source_flag", "flag": int(outgoing.event_id), "value": 0})
	if int(incoming.get("event_id", 0)) != 0:
		changes.append({"type": "source_flag", "flag": int(incoming.event_id), "value": 1})
	return {"ok": true, "actor": _plain(actor), "inventory": _plain(inventory), "events": changes}

func _equipment_bonus(goods: Dictionary, stat: String) -> int:
	if goods.is_empty():
		return 0
	if stat in ["max_hp", "max_mp"]:
		return int(goods.get(stat + "_effect", goods.get(stat + "_delta", 0)))
	return int(goods.get(stat, 0))

func _fighter(input: Dictionary, side: String, slot: int) -> Dictionary:
	var out := input.duplicate(true)
	out.side = side
	out.slot = slot
	out.status = input.get("status", {}).duplicate(true)
	out.modifiers = input.get("modifiers", {}).duplicate(true)
	out.defending = false
	out.experience = int(input.get("experience", 0))
	return out

func _next_actor() -> int:
	for i in _living(_state.party):
		var chosen := false
		for cmd in _state.pending:
			if int(cmd.actor) == i:
				chosen = true
		if not chosen:
			return i
	return -1

func _validate_command(cmd: Dictionary, selecting: bool = true) -> String:
	var actor: Dictionary = _state.party[int(cmd.actor)]
	var kind := str(cmd.get("type", ""))
	if kind not in ["attack", "defend", "flee", "magic", "item", "throw", "coop"]:
		return "Unknown combat command: %s" % kind
	if kind == "coop":
		return "Cooperative attack parameters require source actor ordering; not inferred"
	if kind in ["attack", "magic", "item", "throw"]:
		var target := int(cmd.get("target", -1))
		var help := kind == "item"
		if kind == "magic":
			var id := str(cmd.get("magic_id", ""))
			var spell := _magic(id)
			if spell.is_empty():
				return "Missing source magic %s" % id
			if id not in _known_magics(actor):
				return "Actor has not learned %s" % id
			if _has_status(actor, "seal"):
				return "Actor is sealed"
			if selecting and int(actor.mp) < _cost(spell):
				return "Insufficient MP"
			help = _resource_type(spell) in [2, 3, 4]
		if kind in ["item", "throw"]:
			var id := str(cmd.get("goods_id", ""))
			if not _catalog.get("goods_by_id", {}).has(id):
				return "Missing source goods %s" % id
			var reserved := 0
			for pending in _state.pending:
				if pending.get("goods_id") == id:
					reserved += 1
			if int(_state.inventory.get(id, 0)) <= reserved:
				return "No remaining item %s" % id
			var item_type := _resource_type(_catalog.goods_by_id[id])
			if (kind == "throw" and item_type not in [7, 8]) or (kind == "item" and item_type not in [9, 10, 11, 12]):
				return "Goods cannot be used with this command"
		var targets: Array = _state.party if help else _state.enemies
		if target < 0 or target >= targets.size():
			return "Target index is outside the correct side"
	return ""

func _resolve_round() -> void:
	var queue: Array = _state.pending.duplicate(true)
	for cmd in queue:
		_state.party[int(cmd.actor)].defending = cmd.type == "defend"
	for i in _living(_state.enemies):
		queue.append({"side": "enemies", "actor": i, "type": "ai"})
	for n in queue.size():
		queue[n].priority = _priority(queue[n])
		queue[n].order = n
	queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.order) < int(b.order) if int(a.priority) == int(b.priority) else int(a.priority) > int(b.priority))
	_events.append({"type": "round_started", "round": int(_state.round), "order": queue.duplicate(true)})
	for queued in queue:
		if _outcome():
			break
		var actor: Dictionary = _state[queued.side][int(queued.actor)]
		if int(actor.hp) <= 0:
			continue
		if queued.side == "party":
			_change(actor, int(actor.get("hp_per_round", 0)), int(actor.get("mp_per_round", 0)), "regeneration")
		if _has_status(actor, "sleep"):
			_events.append(_actor_event("sleep", actor))
		elif _has_status(actor, "confusion"):
			_self_attack(actor)
		else:
			var cmd: Dictionary = _enemy_action(actor) if queued.type == "ai" else queued
			_execute(actor, cmd)
		if not _error.is_empty():
			return
		if _state.phase == "finished":
			return
		if int(actor.hp) > 0 and _has_status(actor, "poison"):
			_change(actor, -(int(actor.hp) >> 2), 0, "poison")
		_decay(actor)
		_state.resolved_actions = int(_state.resolved_actions) + 1
	if _outcome():
		return
	_state.pending = []
	_state.round = int(_state.round) + 1
	for actor in _state.party:
		actor.defending = false
	if int(_options.get("max_rounds", 0)) > 0 and int(_state.round) > int(_options.max_rounds):
		_finish("timeout")
	else:
		_check_round_events()

func _priority(cmd: Dictionary) -> int:
	var actor: Dictionary = _state[cmd.side][int(cmd.actor)]
	var speed := _stat(actor, "speed")
	if cmd.side == "party":
		if cmd.type == "magic" and _resource_type(_magic(str(cmd.magic_id))) in [3, 4]:
			speed += speed >> 1
		elif cmd.type == "item" and _resource_type(_catalog.goods_by_id[str(cmd.goods_id)]) in [9, 10]:
			speed += speed >> 1
	return speed & 255

func _enemy_action(actor: Dictionary) -> Dictionary:
	var roll := _random()
	var targets := _living(_state.party)
	var chosen := _next_living(_state.party, roll % 3)
	var cmd := {"type": "attack", "side": "enemies", "actor": int(actor.slot), "target": chosen}
	var magic_ids := _known_magics(actor)
	var iq := int(actor.get("iq", actor.get("intelligence", 0)))
	if roll % 100 >= 100 - iq and not magic_ids.is_empty() and not _has_status(actor, "seal"):
		var id := str(magic_ids[(roll % 100) % magic_ids.size()])
		var magic := _magic(id)
		if magic.is_empty():
			_error = "Missing enemy magic %s" % id
		elif int(actor.mp) >= _cost(magic):
			cmd.type = "magic"
			cmd.magic_id = id
			if _resource_type(magic) in [2, 3, 4]:
				cmd.target = _next_living(_state.enemies, roll % 3)
	return cmd

func _execute(actor: Dictionary, cmd: Dictionary) -> void:
	_events.append({"type": "action", "side": actor.side, "actor": int(actor.slot), "command": cmd.type,
		"target": int(cmd.get("target", -1)), "resource_id": cmd.get("magic_id", cmd.get("goods_id", ""))})
	match str(cmd.type):
		"attack":
			var group: Array = _opponents(actor)
			var target := _retarget(group, int(cmd.get("target", 0)))
			if target < 0:
				return
			var all := int(actor.get("attack_mask_raw", 0)) > 15
			for i in (_living(group) if all else [target]):
				_physical(actor, group[i])
		"defend":
			_events.append(_actor_event("defend", actor))
		"flee":
			var success := false
			if bool(_options.get("random_fight", false)):
				var foe: Dictionary = _state.enemies[0]
				var roll := _random()
				success = roll % (int(actor.luck) + 1) + roll % (int(actor.speed) + 1) > roll % (int(foe.luck) + 1) + roll % (int(foe.speed) + 1)
			_events.append({"type": "flee", "side": actor.side, "actor": int(actor.slot), "success": success})
			if success:
				_finish("fled")
		"magic":
			if _has_status(actor, "seal") or int(actor.mp) < _cost(_magic(str(cmd.magic_id))):
				_execute(actor, {"type": "attack", "target": 0})
			else:
				_cast(actor, cmd)
		"item", "throw":
			_use_goods(actor, cmd)
		_:
			_error = "Unimplemented combat command %s" % cmd.type

func _physical(actor: Dictionary, target: Dictionary) -> void:
	var roll := _random()
	var threshold := _stat(target, "speed") + 50 - _stat(actor, "speed")
	if threshold <= 0:
		threshold = 10
	if roll % 200 < threshold:
		_events.append(_actor_event("miss", target))
		return
	var guard := bool(target.get("defending", false))
	if target.side == "party" and not guard and not _has_status(target, "sleep") and not _has_status(target, "confusion"):
		guard = _random() % 100 > 90
		if guard:
			_events.append(_actor_event("automatic_guard", target))
	var damage := physical_damage(int(_stat(actor, "attack")), int(_stat(target, "defense")), roll, target.side == "party", guard)
	if _options.get("balance_version",0) == 1 and target.side == "enemies":
		damage = balanced_physical_damage(_stat(actor,"attack"),_stat(target,"defense"),roll)
	_change(target, -damage, 0, "physical")
	_apply_status(target, int(actor.get("attack_mask_raw", 0)) & 15, int(actor.get("attack_rounds", actor.get("status_rounds", 0))), true)

static func balanced_physical_damage(attack:int, defense:int, roll:int) -> int:
	var base:=maxi(int(attack*0.35),attack-int(defense*0.5))
	return maxi(1,base + roll % maxi(1,int(base*0.2)))

static func physical_damage(attack: int, defense: int, roll: int, target_is_party: bool, guard: bool = false) -> int:
	var denominator := (defense >> 3) + 1 if target_is_party else maxi(defense >> 3, 1)
	var span := (attack >> 4) + 1 if target_is_party else (attack >> 2)
	if span == 0:
		span = 10
	var damage := int(attack / denominator) + roll % span
	return damage >> 1 if guard and target_is_party else damage

func _self_attack(actor: Dictionary) -> void:
	var attack := _stat(actor, "attack")
	var defense := _stat(actor, "defense")
	var roll := _random()
	var shift := 2 if actor.side == "party" else 3
	var random_shift := 4 if actor.side == "party" else 2
	var damage := int(attack / ((defense >> shift) + 1)) + roll % ((attack >> random_shift) + 1)
	_change(actor, -damage, 0, "confusion")

func _cast(actor: Dictionary, cmd: Dictionary) -> void:
	var spell := _magic(str(cmd.magic_id))
	var kind := _resource_type(spell)
	if kind not in [1, 2, 3, 4, 5]:
		_error = "Unknown or unvalidated magic class %d" % kind
		return
	var help := kind in [2, 3, 4]
	var group: Array = _allies(actor) if help else _opponents(actor)
	var chosen := int(cmd.target)
	if kind != 4:
		chosen = _retarget(group, chosen)
	if chosen < 0 or chosen >= group.size():
		_error = "Magic target is invalid"
		return
	var targets: Array = range(group.size()) if _for_all(spell) else [chosen]
	_change(actor, 0, -_cost(spell), "magic_cost")
	for i in targets:
		var target: Dictionary = group[i]
		match kind:
			1:
				if int(target.hp) <= 0:
					continue
				var roll := _random()
				var miss_threshold := maxi(_stat(target, "speed") + 20 - _stat(actor, "speed"), 0)
				if _options.get("balance_version",0) == 1: miss_threshold = clampi(miss_threshold,5,25)
				if roll % 100 < miss_threshold:
					_events.append(_actor_event("miss", target))
					continue
				var hp_effect := _effect(spell, "hp_effect")
				var mp_effect := _effect(spell, "mp_effect")
				var hp_damage := magic_damage(absi(hp_effect), int(actor.lingli), int(target.lingli), roll, false)
				if _options.get("balance_version", 0) == 1:
					hp_damage = balanced_magic_damage(absi(hp_effect), int(actor.lingli), int(target.lingli), roll, target.side == "party")
				var mp_damage := magic_damage(absi(mp_effect), int(actor.lingli), int(target.lingli), roll, target.side == "party")
				if target.side == "party" and bool(target.defending):
					hp_damage -= hp_damage >> 2
				hp_damage = mini(hp_damage, int(target.hp))
				mp_damage = mini(mp_damage, int(target.mp))
				_change(target, -hp_damage, -mp_damage, "magic")
				if hp_effect < 0 or mp_effect < 0:
					_change(actor, hp_damage if hp_effect < 0 else 0, mp_damage if mp_effect < 0 else 0, "absorb")
				_apply_status(target, _status_mask(spell), _rounds(spell), true)
				_apply_modifiers(target, spell, -1)
			2:
				if int(target.hp) > 0:
					_apply_modifiers(target, spell, 1)
			3:
				if int(target.hp) > 0:
					_change(target, _effect(spell, "hp_effect"), 0, "restore")
					_cure(target, _status_mask(spell))
			4:
				if int(target.hp) == 0:
					_change(target, int(int(target.max_hp) * _effect(spell, "hp_effect") / 100), 0, "revive")
			5:
				_steal(actor, target)

## Playability balance: bounded spirit ratio avoids zero damage and explosive
## sequential scaling. Enemy spell pressure is sized for 300–500 HP parties.
static func balanced_magic_damage(base: int, caster_spirit: int, target_spirit: int, roll: int, target_is_party: bool = false) -> int:
	if base == 0: return 0
	var amount := maxi(1, int(float(base) * (100 + caster_spirit) / (100 + target_spirit)))
	if target_is_party: amount = maxi(1, int(amount * 0.35))
	return amount + ((roll % amount) >> 4)

static func magic_damage(base: int, caster_spirit: int, target_spirit: int, roll: int, reverse_spirit: bool = false) -> int:
	if base == 0:
		return 0
	var amount := base
	if reverse_spirit:
		amount -= caster_spirit * (amount >> 6)
		amount += target_spirit * (amount >> 6)
	else:
		amount += caster_spirit * (amount >> 6)
		amount -= target_spirit * (amount >> 6)
	if amount <= 0:
		return 0
	return amount + ((roll % amount) >> 4)

func _use_goods(actor: Dictionary, cmd: Dictionary) -> void:
	var id := str(cmd.goods_id)
	if int(_state.inventory.get(id, 0)) < 1:
		_error = "Item exhausted before action %s" % id
		return
	var goods: Dictionary = _catalog.goods_by_id[id]
	var kind := _resource_type(goods)
	var group: Array = _allies(actor) if cmd.type == "item" else _opponents(actor)
	var target := int(cmd.target)
	var targets: Array = range(group.size()) if _for_all(goods) else [target]
	if kind == 13:
		_error = "Source goods class %d requires unvalidated throw/earth-escape semantics" % kind
		return
	_state.inventory[id] = int(_state.inventory[id]) - 1
	_events.append({"type": "item_consumed", "goods_id": id, "quantity": 1})
	for i in targets:
		var dst: Dictionary = group[i]
		match kind:
			7:
				_throw_weapon(actor, dst, goods)
			8:
				if int(dst.hp) > 0:
					var hp := _effect(goods, "hp_effect")
					var mp := _effect(goods, "mp_effect")
					_change(dst, -absi(hp), -absi(mp), "throw")
					# C _00241014 restores the full encoded magnitude per target;
					# it does not limit absorption to the target's remaining resource.
					_change(actor, -hp if hp < 0 else 0, -mp if mp < 0 else 0, "absorb")
					_apply_status(dst, _status_mask(goods), _rounds(goods), true)
			9:
				if int(dst.hp) > 0:
					_change(dst, _effect(goods, "hp_effect"), _effect(goods, "mp_effect"), "medicine")
					_cure(dst, _status_mask(goods))
			10:
				if int(dst.hp) == 0:
					_change(dst, int(int(dst.max_hp) * int(goods.get("restore_percent_raw", _effect(goods, "hp_effect"))) / 100), 0, "life_medicine")
			11:
				for stat in STAT_KEYS:
					var value := int(goods.get(stat + "_effect", goods.get(stat, 0)))
					dst[stat] = clampi(int(dst[stat]) + value, 0, 999 if stat in ["max_hp", "max_mp", "attack", "defense"] else 99)
				_events.append(_actor_event("permanent_growth", dst))
			12:
				_apply_modifiers(dst, goods, 1)
			_:
				_error = "Unknown goods effect type %d" % kind

func _apply_modifiers(actor: Dictionary, resource: Dictionary, direction: int) -> void:
	var rounds := _rounds(resource)
	for stat in ["attack", "defense", "speed"]:
		var percent := int(resource.get(stat + "_percent", 0))
		if percent == 0:
			continue
		actor.modifiers[stat] = {"value": int(int(actor[stat]) * percent / 100) * direction, "rounds": rounds}
		_events.append({"type": "modifier", "side": actor.side, "actor": int(actor.slot), "stat": stat, "value": actor.modifiers[stat].value, "rounds": rounds})

func _apply_status(actor: Dictionary, mask: int, rounds: int, test_luck: bool) -> void:
	if mask == 0 or int(actor.hp) <= 0:
		return
	if test_luck:
		var roll := _random() % 90
		if int(actor.luck) >= roll and roll <= 60:
			return
	for name in STATUS_BITS:
		var bit: int = STATUS_BITS[name]
		if mask & bit and not (int(actor.get("immune_mask_raw", 0)) & bit):
			if actor.side == "party" and _options.get("balance_version",0) == 1 and name in ["sleep","confusion","seal"]:
				if int(actor.get("status_recovery_rounds",0)) > 0 or actor.status.has(name): continue
				var limit := 2 if name == "seal" else 1
				actor.status[name] = mini(rounds,limit) if rounds > 0 else limit
			else:
				actor.status[name] = rounds if rounds > 0 else 256
			_events.append({"type": "status", "side": actor.side, "actor": int(actor.slot), "status": name, "rounds": actor.status[name]})

func _cure(actor: Dictionary, mask: int) -> void:
	for name in STATUS_BITS:
		if mask & int(STATUS_BITS[name]) and actor.status.has(name):
			actor.status.erase(name)
			if actor.side == "party" and _options.get("balance_version",0) == 1 and name in ["sleep","confusion","seal"]: actor.status_recovery_rounds = 2
			_events.append({"type": "cured", "side": actor.side, "actor": int(actor.slot), "status": name})

func _decay(actor: Dictionary) -> void:
	if int(actor.get("status_recovery_rounds",0)) > 0: actor.status_recovery_rounds = int(actor.status_recovery_rounds)-1
	for name in actor.status.keys():
		actor.status[name] = int(actor.status[name]) - 1
		if int(actor.status[name]) <= 0:
			actor.status.erase(name)
			if actor.side == "party" and _options.get("balance_version",0) == 1 and name in ["sleep","confusion","seal"]: actor.status_recovery_rounds = 2
			_events.append({"type": "status_expired", "side": actor.side, "actor": int(actor.slot), "status": name})
	for key in actor.modifiers.keys():
		actor.modifiers[key].rounds = int(actor.modifiers[key].rounds) - 1
		if int(actor.modifiers[key].rounds) <= 0:
			actor.modifiers.erase(key)

func _outcome() -> bool:
	if _state.phase == "finished":
		return true
	if _living(_state.enemies).is_empty():
		_finish("won")
		return true
	if _living(_state.party).is_empty():
		_finish("lost")
		return true
	return false

func _finish(outcome: String) -> void:
	if _state.phase == "finished":
		return
	if outcome == "won":
		var exp := 0
		var money := 0
		for enemy in _state.enemies:
			exp += int(enemy.get("reward_exp", 0))
			money += int(enemy.get("reward_money", 0))
		_state.rewards = {"experience": exp, "money": money, "goods": {}}
		var recovery := _random() % 10 + 15
		for actor in _state.party:
			if int(actor.hp) <= 0:
				_change(actor, 1, 0, "victory_revive")
				continue
			_change(actor, int((int(actor.max_hp) - int(actor.hp)) * recovery / 100), int((int(actor.max_mp) - int(actor.mp)) * recovery / 100), "victory_recovery")
			actor.experience = int(actor.experience) + exp
			_level_up(actor)
			if not _error.is_empty():
				return
		_drop_rewards()
	elif outcome == "fled":
		for actor in _state.party:
			if int(actor.hp) <= 0:
				_change(actor, 1, 0, "escape_revive")
	for actor in _state.party:
		actor.status.clear()
		actor.modifiers.clear()
		actor.defending = false
	_state.outcome = outcome
	_state.phase = "finished"
	_state.pending = []
	_events.append({"type": "battle_finished", "outcome": outcome, "rewards": _state.rewards.duplicate(true)})

func _level_up(actor: Dictionary) -> void:
	var chain_id := str(actor.get("level_chain", ""))
	if chain_id.is_empty():
		if int(actor.get("next_level_exp", 0)) > 0 and int(actor.experience) > int(actor.next_level_exp):
			_error = "Missing source level chain for %s" % actor.id
		return
	var chains: Dictionary = _catalog.get("levelup_chains_by_id", {})
	if not chains.has(chain_id):
		_error = "Missing source level chain %s" % chain_id
		return
	var chain: Dictionary = chains[chain_id]
	var rows: Array = chain.get("levels", chain.get("records", []))
	if rows.is_empty():
		_error = "Source level chain has no records"
		return
	var initial_level := int(actor.level)
	var old_row := _level_record(rows, initial_level)
	if old_row.is_empty():
		_error = "Source level chain lacks level %d" % initial_level
		return
	var current := old_row
	while int(actor.level) < rows.size():
		var threshold := int(current.get("next_exp", current.get("next_level_exp", current.get("experience", 0))))
		if threshold <= 0 or int(actor.experience) <= threshold:
			break
		var next := _level_record(rows, int(actor.level) + 1)
		if next.is_empty():
			_error = "Source level chain lacks next level"
			return
		actor.experience = int(actor.experience) - threshold
		actor.level = int(actor.level) + 1
		current = next
	if int(actor.level) == initial_level:
		return
	var roll := _random()
	for key in STAT_KEYS:
		if not current.has(key) or not old_row.has(key):
			_error = "Missing level growth field %s" % key
			return
		var difference := int(current[key]) - int(old_row[key])
		var extra := (roll % difference) >> 3 if key in ["max_hp", "max_mp"] and difference > 0 else 0
		actor[key] = clampi(int(actor[key]) + difference + extra, 0, 999 if key in ["max_hp", "max_mp", "attack", "defense"] else 99)
	actor.hp = int(actor.max_hp)
	actor.mp = int(actor.max_mp)
	actor.next_level_exp = int(current.get("next_exp", current.get("next_level_exp", 0)))
	actor.magic_learn_count = _learned_count(actor)
	_events.append({"type": "level_up", "side": actor.side, "actor": int(actor.slot), "old_level": initial_level, "level": int(actor.level), "magic_ids": _known_magics(actor)})

func _roll_drop(enemy: Dictionary) -> void:
	var drop: Array = enemy.get("drop_goods_raw", [])
	if drop.size() < 3 or int(drop[0]) <= 0 or int(drop[1]) <= 0 or int(drop[2]) <= 0:
		return
	var lead: Dictionary = _state.party[clampi(int(_options.get("leader_slot", 0)), 0, _state.party.size() - 1)]
	if int(lead.luck) <= 0 or int(enemy.luck) <= 0:
		_error = "Original drop formula has undefined zero-luck modulo"
		return
	var roll := _random()
	if roll % int(lead.luck) + 1 > roll % int(enemy.luck) and roll % 4 != 0:
		var id := "6:%d:%d" % [int(drop[0]), int(drop[1])]
		_state.drops[id] = int(_state.drops.get(id, 0)) + 1

func _drop_rewards() -> void:
	_state.rewards.goods = _state.drops.duplicate(true)

func _steal(actor: Dictionary, target: Dictionary) -> void:
	var carried: Array = target.get("carry_goods_raw", [])
	if carried.size() < 3 or int(carried[2]) <= 0:
		_events.append(_actor_event("steal_empty", target))
		return
	if int(actor.luck) <= 0 or int(target.luck) <= 0:
		_error = "Original steal formula has undefined zero-luck modulo"
		return
	var roll := _random()
	var span := 3 if int(actor.luck) > int(target.luck) else 2
	if roll % int(actor.luck) + 1 > roll % int(target.luck) and roll % span != 0:
		var id := "6:%d:%d" % [int(carried[0]), int(carried[1])]
		target.carry_goods_raw[2] = int(carried[2]) - 1
		_state.inventory[id] = int(_state.inventory.get(id, 0)) + 1
		_events.append({"type": "stolen", "goods_id": id, "quantity": 1})
	else:
		_events.append(_actor_event("steal_failed", target))

func _throw_weapon(_actor: Dictionary, target: Dictionary, goods: Dictionary) -> void:
	var bytes: Array = goods.get("effect_bytes_raw", [])
	if bytes.size() != 8:
		_error = "Weapon throw requires eight original goods effect bytes"
		return
	var damage := int(bytes[3]) & 127
	# C _00240841: little-endian word 3 low byte (6) sets 0x2000.
	var mapping := {6: 8192, 7: 4096, 4: 2048, 5: 1024, 0: 512, 1: 256, 2: 128}
	for i in mapping:
		if int(bytes[i]) != 0:
			damage |= int(mapping[i])
	_change(target, -damage, 0, "weapon_throw")
	_apply_status(target, _status_mask(goods), _rounds(goods), true)

func _check_round_events() -> void:
	for entry in _options.get("round_events", []):
		if int(entry.get("round", 0)) == int(_state.round) and not str(entry.get("event_id", "")) in _state.event_rounds_seen:
			_state.event_rounds_seen.append(str(entry.event_id))
			_state.phase = "event"
			_events.append({"type": "battle_script_event", "event_id": entry.event_id, "round": int(_state.round)})

func _change(actor: Dictionary, hp_delta: int, mp_delta: int, reason: String) -> void:
	var old_hp := int(actor.hp)
	var old_mp := int(actor.mp)
	actor.hp = clampi(old_hp + hp_delta, 0, int(actor.max_hp))
	actor.mp = clampi(old_mp + mp_delta, 0, int(actor.max_mp))
	if int(actor.hp) != old_hp or int(actor.mp) != old_mp:
		_events.append({"type": "vitals", "side": actor.side, "actor": int(actor.slot), "reason": reason,
			"hp_delta": int(actor.hp) - old_hp, "mp_delta": int(actor.mp) - old_mp, "hp": int(actor.hp), "mp": int(actor.mp)})
	if old_hp > 0 and int(actor.hp) == 0:
		actor.status.clear()
		actor.modifiers.clear()
		_events.append(_actor_event("knocked_out", actor))
		if actor.side == "enemies":
			_roll_drop(actor)

## Level tables may end their learning schedule with zero-filled rows. Those
## rows never unlearn skills. Scan the reached prefix, also repairing visibility
## for already affected saves without writing invented resources into them.
func _learned_count(actor: Dictionary) -> int:
	var count := int(actor.get("magic_learn_count",0))
	if actor.get("side", "party") != "party": return count
	var chain: Dictionary = _catalog.get("levelup_chains_by_id",{}).get(str(actor.get("level_chain","")),{})
	var rows: Array = chain.get("levels",chain.get("records",[]))
	for index in rows.size():
		var row: Dictionary = rows[index]
		if int(row.get("level",index+1)) > int(actor.level): break
		count = maxi(count,int(row.get("learn_count",row.get("magic_learn_count",0))))
	return count

func _known_magics(actor: Dictionary) -> Array:
	var chain_id := str(actor.get("magic_chain", ""))
	var chain: Dictionary = _catalog.get("magic_chains_by_id", {}).get(chain_id, {})
	var list: Array = chain.get("magic_ids", chain.get("entries", []))
	if list.is_empty() and actor.has("magic_ids"):
		return actor.magic_ids.duplicate()
	var count := mini(_learned_count(actor), list.size())
	var ids: Array = []
	for item in list.slice(0, count):
		ids.append(str(item.get("id", item.get("magic_id", ""))) if item is Dictionary else str(item))
	for id in actor.get("learned_extra_magic_ids", []):
		if id not in ids:
			ids.append(id)
	return ids

func _magic(id: String) -> Dictionary:
	return _catalog.get("magics_by_id", {}).get(id, {})

func _resource_type(resource: Dictionary) -> int:
	if resource.has("resource_type"):
		return int(resource.resource_type)
	if resource.has("type"):
		return int(resource.type)
	var pieces := str(resource.get("id", "")).split(":")
	return int(pieces[1]) if pieces.size() == 3 else -1

func _for_all(resource: Dictionary) -> bool:
	return bool(resource.get("target_all", resource.get("all_targets", int(resource.get("effect_mask_raw", 0)) > 15)))

func _cost(resource: Dictionary) -> int:
	return int(resource.get("cost_mp", resource.get("mp_cost", 0)))

func _effect(resource: Dictionary, key: String) -> int:
	return int(resource.get(key, resource.get("effects", {}).get(key, 0)))

func _status_mask(resource: Dictionary) -> int:
	return int(resource.get("status_mask", resource.get("status_mask_raw", resource.get("effect_mask_raw", 0)))) & 15

func _rounds(resource: Dictionary) -> int:
	return int(resource.get("rounds", resource.get("status_rounds", 0)))

func _stat(actor: Dictionary, key: String) -> int:
	return maxi(int(actor[key]) + int(actor.modifiers.get(key, {}).get("value", 0)), 0)

func _has_status(actor: Dictionary, name: String) -> bool:
	return int(actor.status.get(name, 0)) > 0

func _allies(actor: Dictionary) -> Array:
	return _state[actor.side]

func _opponents(actor: Dictionary) -> Array:
	return _state.enemies if actor.side == "party" else _state.party

func _living(group: Array) -> Array:
	var alive: Array = []
	for i in group.size():
		if int(group[i].hp) > 0:
			alive.append(i)
	return alive

func _next_living(group: Array, start: int) -> int:
	for delta in 3:
		var slot := (start + delta) % 3
		if slot < group.size() and int(group[slot].hp) > 0:
			return slot
	return -1

func _retarget(group: Array, index: int) -> int:
	if index >= 0 and index < group.size() and int(group[index].hp) > 0:
		return index
	return _next_living(group, 0)

func _level_record(rows: Array, level: int) -> Dictionary:
	for row in rows:
		if int(row.get("level", rows.find(row) + 1)) == level:
			return row
	return {}

func _random() -> int:
	return int(_rng.randi() & 65535)

func _actor_event(kind: String, actor: Dictionary) -> Dictionary:
	return {"type": kind, "side": actor.side, "actor": int(actor.slot)}

func _result() -> Dictionary:
	return {"ok": true, "snapshot": snapshot(), "events": _plain(_events), "next_actor": _next_actor() if _state.get("phase") == "select" else -1}

func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message, "snapshot": snapshot(), "events": []}

func _plain(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value:
			result[str(key)] = _plain(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item in value:
			result.append(_plain(item))
		return result
	if value is float and is_finite(value) and floor(value) == value:
		return int(value)
	if value is StringName:
		return str(value)
	return value
