class_name GameState
extends RefCounted
## Schema owned here. Persistence transports it; UI never mutates it.
const SCHEMA_VERSION := 1
const RNG_ENGINE := "godot-4.7.2-pcg32"

static func initial(catalog: ContentCatalog, seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var world := catalog.entry()
	world["facing"] = "down"
	return {
		"schema_version": SCHEMA_VERSION,
		"content_id": catalog.content_id(), "content_hash": catalog.content_hash(),
		"mode": "validation" if catalog.baseline().verification == "synthetic" else "faithful",
		"world": world, "party": [], "actors": {}, "inventory": {}, "currency": 0,
		"flags": {}, "event": {}, "event_sequence": 0, "playtime_ms": 0,
		"rng": {"engine": RNG_ENGINE, "seed": str(rng.seed), "state": str(rng.state)},
		# Opaque, JSON-only adapter checkpoint; unknown source opcodes still fail in their adapter.
		# Reserved for global vars, local frames, timers and per-map object/actor state.
		"source_runtime": {"adapter_version": 0, "globals": {}, "frames": [], "timers": [], "map_objects": {}}
	}

static func validate(state: Dictionary, catalog: ContentCatalog) -> Dictionary:
	if catalog.content_id().is_empty() or catalog.content_hash().is_empty():
		return Checks.failure("content_not_loaded")
	if not Checks.integer(state.get("schema_version"), SCHEMA_VERSION, SCHEMA_VERSION):
		return Checks.failure("unsupported_state_schema")
	if not Checks.text(state.get("content_id")) or not Checks.text(state.get("content_hash")) or state.content_id != catalog.content_id() or state.content_hash != catalog.content_hash():
		return Checks.failure("state_content_mismatch")
	var expected_mode := "validation" if catalog.baseline().verification == "synthetic" else "faithful"
	if not Checks.text(state.get("mode")) or state.mode != expected_mode:
		return Checks.failure("state_mode_mismatch")
	for key in ["world", "actors", "inventory", "flags", "event", "rng", "source_runtime"]:
		if not state.get(key) is Dictionary:
			return Checks.failure("invalid_state_section:%s" % key)
	var w: Dictionary = state.world
	if not Checks.text(w.get("map_id")) or not Checks.integer(w.get("x")) or not Checks.integer(w.get("y")):
		return Checks.failure("invalid_world_position")
	if not catalog.passable(w.map_id, int(w.x), int(w.y)) or w.get("facing") not in ["up", "down", "left", "right"]:
		return Checks.failure("invalid_world_position")
	if not state.get("party") is Array:
		return Checks.failure("invalid_party")
	var seen: Array = []
	for actor_id in state.party:
		if not actor_id is String or actor_id in seen or not state.actors.has(actor_id):
			return Checks.failure("invalid_party_member")
		seen.append(actor_id)
	for actor_id in state.actors:
		if not actor_id is String or not catalog.has_id("actors", actor_id) or not state.actors[actor_id] is Dictionary:
			return Checks.failure("invalid_actor_state")
	for item_id in state.inventory:
		if not item_id is String or not catalog.has_id("items", item_id) or not Checks.integer(state.inventory[item_id], 1):
			return Checks.failure("invalid_inventory")
	for flag in state.flags:
		if not Checks.text(flag) or not Checks.integer(state.flags[flag]):
			return Checks.failure("invalid_flag")
	if not Checks.integer(state.get("currency"), 0) or not Checks.integer(state.get("playtime_ms"), 0, 9007199254740991):
		return Checks.failure("invalid_counter")
	if not Checks.integer(state.get("event_sequence"), 0):
		return Checks.failure("invalid_event_sequence")
	if not Checks.text(state.rng.get("engine")) or state.rng.engine != RNG_ENGINE:
		return Checks.failure("unsupported_rng_engine")
	for key in ["seed", "state"]:
		var number: Variant = state.rng.get(key)
		if not number is String or not number.is_valid_int() or str(int(number)) != number:
			return Checks.failure("invalid_rng_%s" % key)
	if not Checks.json_value(state):
		return Checks.failure("non_json_state")
	return Checks.success()
