class_name ChapterRoadAtlas
extends RefCounted
## Audited source topology, not exploration history. Callers decide which nodes are visible.
const PATH := "res://data/chapter2/road_atlas.json"
const CH45_PATH := "res://data/chapter45/road_atlas.json"
static var _data: Dictionary = {}

static func _read() -> Dictionary:
	if _data.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
		if parsed is Dictionary and parsed.get("version") == 1:
			_data = parsed
			var extension: Variant = JSON.parse_string(FileAccess.get_file_as_string(CH45_PATH)) if FileAccess.file_exists(CH45_PATH) else null
			if extension is Dictionary and extension.get("version") == 1 and extension.get("content_identity") == _data.get("content_identity"):
				for section in ["selectors", "regions"]:
					for key in extension.get(section, {}):
						assert(not _data[section].has(key), "CH45 atlas may not replace old catalog entries")
						_data[section][key] = extension[section][key]
				_data.exits.append_array(extension.get("exits", []))
	return _data

static func catalog() -> Dictionary:
	return _read().duplicate(true)

static func region(key: String) -> Dictionary:
	return _read().get("regions", {}).get(key, {}).duplicate(true)

static func exits_from(key: String) -> Array:
	var result: Array = []
	for entry in _read().get("exits", []):
		if entry.from == key: result.append(entry.duplicate(true))
	return result

static func _base(content: ChapterContent, state: Dictionary) -> String:
	if content == null: return ""
	var world: Variant = state.get("world")
	var runtime: Variant = state.get("source_runtime")
	if not world is Dictionary or not runtime is Dictionary: return ""
	var map_id: Variant = world.get("map_id")
	var script: Variant = runtime.get("script")
	if not map_id is String or not script is String: return ""
	if not content.maps.has(map_id) or not content.scripts.has(script): return ""
	return map_id + "|" + script

static func _set_flag(value: Variant) -> bool:
	if value is bool: return value
	if value is int: return value != 0
	if value is float and is_finite(value): return int(value) != 0
	return false

static func resolve(content: ChapterContent, state: Dictionary) -> String:
	var base := _base(content, state)
	if base.is_empty() or content.identity != _read().get("content_identity", ""): return base
	var script: String = state.source_runtime.script
	var selector: Dictionary = _read().get("selectors", {}).get(script, {})
	if selector.is_empty() or state.world.map_id not in selector.get("map_ids", [selector.map_id]): return base
	var flags: Variant = state.get("flags", {})
	if not flags is Dictionary: return base
	# Ordered source IF chains, not every true route flag or an assumed numeric range.
	for flag in selector.ordered_flags:
		if _set_flag(flags.get(str(int(flag)), 0)): return base + "|r:" + str(int(flag))
	# The actual source chain falls through to CALLBACK; do not invent a route.
	return base

static func legacy_candidates(content: ChapterContent, oldrecord: Dictionary) -> Array[String]:
	var result: Array[String] = []
	var base := _base(content, {"world":{"map_id":oldrecord.get("map_id")},
		"source_runtime":{"script":oldrecord.get("script")}})
	if base.is_empty(): return result
	var oldkey: Variant = oldrecord.get("key")
	if not oldkey is String: return result
	var selector: Dictionary = _read().get("selectors", {}).get(oldrecord.script, {})
	if content.identity != _read().get("content_identity", ""): return result
	if selector.is_empty() or oldrecord.map_id not in selector.get("map_ids", [selector.map_id]):
		if oldkey == base: result.append(base)
		return result
	if selector.get("legacy_key_schema", "") == "base" or (selector.get("v2_base_was_merged", false) and oldkey == base):
		if oldkey != base: return result
		for flag in selector.ordered_flags: result.append(base + "|r:" + str(int(flag)))
		return result
	var old_tested: Array[int] = []
	for flag in selector.ordered_flags:
		if int(flag) >= 101 and int(flag) <= 113: old_tested.append(int(flag))
	var active: Array[int] = []
	if old_tested.is_empty():
		if oldkey != base: return result
	else:
		var prefix := base + "|r:"
		if not oldkey.begins_with(prefix): return result
		var suffix: String = oldkey.substr(prefix.length())
		if not suffix.is_empty():
			for part in suffix.split(",", true):
				if not part.is_valid_int() or str(int(part)) != part: return result
				var flag := int(part)
				if flag not in old_tested or flag in active: return result
				active.append(flag)
			var sorted := active.duplicate()
			sorted.sort()
			if sorted != active: return result
	# Each candidate must be capable of winning before any known-true old selector.
	# Unknown earlier flags may be false; flags absent from the old key were false.
	for flag_value in selector.ordered_flags:
		var flag := int(flag_value)
		if flag not in old_tested or flag in active: result.append(base + "|r:" + str(flag))
		if flag in active: break
	return result

static func ambiguous_merged_base(map_id: String, script: String, key: String) -> bool:
	var selector: Dictionary = _read().get("selectors", {}).get(script, {})
	return bool(selector.get("v2_base_was_merged", false)) and key == map_id + "|" + script and map_id in selector.get("map_ids", [selector.get("map_id", "")])
