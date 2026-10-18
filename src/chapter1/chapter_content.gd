class_name ChapterContent
extends RefCounted
## Read-only source resource catalog. No original payload is embedded in source control.
var data: Dictionary = {}
var maps: Dictionary = {}
var scripts: Dictionary = {}
var actors: Dictionary = {}
var goods: Dictionary = {}
var magics: Dictionary = {}
var instructions: Dictionary = {}
var scene_name_scripts: Dictionary = {}
var identity := ""

func load_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return Checks.failure("请先导入本地原作资源包。")
	var raw := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(raw)
	if not parsed is Dictionary or not parsed.has("source"):
		return Checks.failure("资源目录格式不正确")
	data = parsed
	identity = str(data.source.sha256)
	maps = _index("maps")
	scripts = _index("scripts")
	actors = _index("actors")
	goods = _index("goods").duplicate(true)
	for id in goods:
		var original: Dictionary = goods[id].duplicate(true)
		goods[id].buy_price = preload("res://src/chapter1/chapter_balance.gd").buy_price(original)
		goods[id].sell_price = preload("res://src/chapter1/chapter_balance.gd").sell_price(original)
	magics = _index("magics")
	scene_name_scripts.clear()
	for id in scripts:
		var code: Dictionary = {}
		for instruction in scripts[id].instructions:
			code[str(int(instruction.address))] = instruction
			if instruction.name == "SETSCENENAME": scene_name_scripts[id] = true
		instructions[id] = code
	if not maps.has("2:1:2") or not scripts.has("1:1:1"):
		return Checks.failure("缺少开场资源")
	return Checks.success()

func display_scene_name(snapshot: Dictionary) -> String:
	var runtime: Dictionary = snapshot.get("source_runtime", {})
	var source_name := str(runtime.get("scene_name", ""))
	if scene_name_scripts.has(str(runtime.get("script", ""))) and not source_name.is_empty(): return source_name
	# Source cutscenes can change maps without resetting their transient title.
	# The persistent remake HUD and save browser follow the actual MAP in that case.
	var map: Dictionary = maps.get(str(snapshot.get("world", {}).get("map_id", "")), {})
	return str(map.get("name", source_name if not source_name.is_empty() else "序章"))

func _index(kind: String) -> Dictionary:
	if data.get(kind + "_by_id") is Dictionary:
		return data[kind + "_by_id"]
	var out: Dictionary = {}
	var collection: Variant = data.get(kind, [])
	if collection is Dictionary:
		return collection
	for resource in collection:
		var r: Array = resource.resource
		out["%d:%d:%d" % [r[0], r[1], r[2]]] = resource
	return out

func cell(map_id: String, x: int, y: int) -> Dictionary:
	var m: Dictionary = maps.get(map_id, {})
	if m.is_empty() or x < 0 or y < 0 or x >= int(m.width) or y >= int(m.height):
		return {}
	return m.cells[y * int(m.width) + x]

func event_address(script_id: String, event_id: int) -> int:
	for event in scripts.get(script_id, {}).get("events", []):
		if int(event.event) == event_id:
			return int(event.address)
	return 0

func instruction(script_id: String, address: int) -> Dictionary:
	return instructions.get(script_id, {}).get(str(address), {})

func resource_name(kind: String, id: String) -> String:
	return str(data.get(kind + "_by_id", {}).get(id, {}).get("name", id))
