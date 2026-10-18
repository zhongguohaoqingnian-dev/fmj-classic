class_name ChapterWorld
extends Node2D
## Presentation only. Source grid, visibility, events and combat remain in session.
signal visual_event(event: Dictionary)
const TILE_PIXELS := 32
const PATCH_PIXELS := 64
const NATURAL_MATERIALS := ["grass", "flowers", "moss", "dry_grass", "path", "gravel", "sand", "earth", "cave_floor", "shale", "sandstone", "path_plain", "grass_plain", "grass_shadow", "cave_plain"]
const FLOOR_MODULES := ["bagua_floor", "taiji_floor", "woven_mat", "bridge_vertical", "bridge_horizontal", "stairs", "chasm", "ravine_void", "water", "furniture_shadow"]
var session: ChapterSession
var view_size := Vector2(1120, 720)
var pixel_scale := 2
var tile_size := float(TILE_PIXELS * 2)
var camera := Vector2.ZERO
var diagnostic_camera_focus: Variant = null
var clock := 0.0
var textures: Dictionary = {}
var atlas: Dictionary = {}
var tile_mapping: Dictionary = {}
var visual_player := Vector2.ZERO
var previous_map := ""
var _observed_map_load_sequence := -1
var atlas_loaded := false
var diagnostics: Dictionary = {}
var _background: ColorRect
var _terrain: Sprite2D
var _backdrop_material: ShaderMaterial
var _terrain_material: ShaderMaterial
var _material_ids: Dictionary = {}
var _material_texture: ImageTexture
var _valley_enabled := false
var _map_cache: Dictionary = {}
var _map_draws: Array = []
var _dressing: Array = []
var _entity_positions: Dictionary = {}
var _was_in_combat := false
var _battle_cursor := 0
var _battle_queue: Array = []
var _active_action: Dictionary = {}
var _action_age := 0.0
var _battle_hp: Dictionary = {}
var _battle_floaters: Array = []
var _battle_presented_round := 1
var _presentation_token := ""
var _presentation_age := 0.0
var _motion_pose: Dictionary = {}
var _movie_resource := ""
var _observed_state: Dictionary = {}
var _font: SystemFont

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_font = SystemFont.new()
	_font.font_names = PackedStringArray(["PingFang SC", "Microsoft YaHei", "Noto Sans CJK SC", "Heiti SC", "Arial"])
	_background = ColorRect.new()
	_background.color = Color("101d24")
	_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_background.z_index = -20
	_backdrop_material = ShaderMaterial.new()
	_backdrop_material.shader = load("res://src/chapter1/chapter_backdrop.gdshader")
	_background.material = _backdrop_material
	add_child(_background)
	_terrain = Sprite2D.new()
	_terrain.centered = false
	_terrain.z_index = -10
	_terrain.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_terrain_material = ShaderMaterial.new()
	_terrain_material.shader = load("res://src/chapter1/chapter_terrain.gdshader")
	_terrain.material = _terrain_material
	add_child(_terrain)
	_reload_art()

func _reload_art() -> void:
	textures.clear()
	_map_cache.clear()
	diagnostics.clear()
	atlas = _read_dictionary("res://assets/chapter1/atlas.json")
	tile_mapping = _read_dictionary("res://data/chapter1/tile_mapping.json")
	for catalog_path in ["res://assets/chapter2/atlas.json", "res://assets/chapter2/terrain-atlas.json", "res://assets/chapter2/npc-atlas.json", "res://assets/chapter3/atlas.json", "res://assets/chapter3/character-atlas.json", "res://assets/chapter45/atlas.json", "res://assets/chapter45/character-atlas.json", "res://assets/chapter67/atlas.json", "res://assets/chapter67/character-atlas.json"]:
		if FileAccess.file_exists(catalog_path): atlas.merge(_read_dictionary(catalog_path), true)
	for mapping_path in ["res://data/chapter2/tile_mapping.json", "res://data/chapter3/tile_mapping.json", "res://data/chapter45/tile_mapping.json", "res://data/chapter67/tile_mapping.json"]:
		if not FileAccess.file_exists(mapping_path): continue
		var supplement := _read_dictionary(mapping_path)
		for section in ["tiles", "map_overrides"]:
			if not tile_mapping.has(section): tile_mapping[section] = {}
			tile_mapping[section].merge(supplement.get(section, {}), true)
	atlas_loaded = not atlas.is_empty()
	previous_map = ""
	_build_material_atlas()

func _read_dictionary(path: String) -> Dictionary:
	if not FileAccess.file_exists(path): return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}

func _texture(item: Dictionary) -> Texture2D:
	var path := str(item.get("path", ""))
	if not textures.has(path):
		if not ResourceLoader.exists(path):
			_missing("texture:" + path)
			return null
		textures[path] = load(path)
	return textures[path]

func _build_material_atlas() -> void:
	_material_ids = {"": 0}
	for key in atlas:
		if atlas[key].get("kind") == "ground" and not atlas[key].has("provisional_alias"):
			_material_ids[key] = _material_ids.size()
	var image := Image.create(PATCH_PIXELS * _material_ids.size(), PATCH_PIXELS, false, Image.FORMAT_RGBA8)
	image.fill(Color("17242a"))
	for key in _material_ids:
		if str(key).is_empty(): continue
		var item: Dictionary = atlas[key]
		var texture := _texture(item)
		if texture == null: continue
		var r: Array = item.rect
		var patch := texture.get_image().get_region(Rect2i(int(r[0]), int(r[1]), int(r[2]), int(r[3])))
		patch.convert(Image.FORMAT_RGBA8)
		# v2 patches are already 64 square; legacy sizes are diagnostic only.
		if patch.get_size() != Vector2i(PATCH_PIXELS, PATCH_PIXELS):
			_missing("non_native_ground:" + str(key))
			patch.resize(PATCH_PIXELS, PATCH_PIXELS, Image.INTERPOLATE_NEAREST)
		image.blit_rect(patch, Rect2i(0, 0, PATCH_PIXELS, PATCH_PIXELS), Vector2i(int(_material_ids[key]) * PATCH_PIXELS, 0))
	_material_texture = ImageTexture.create_from_image(image)
	_terrain_material.set_shader_parameter("materials", _material_texture)
	_terrain_material.set_shader_parameter("material_count", float(_material_ids.size()))
	_terrain_material.set_shader_parameter("grass_id", float(_material_ids.get("grass", -1)))
	_terrain_material.set_shader_parameter("dry_grass_id", float(_material_ids.get("dry_grass", -1)))

func _process(delta: float) -> void:
	clock += delta
	tile_size = float(TILE_PIXELS * pixel_scale)
	view_size = get_viewport_rect().size
	_background.size = view_size
	_backdrop_material.set_shader_parameter("viewport_pixels", view_size)
	if session == null or session.state.is_empty():
		_clear_map_view()
		queue_redraw()
		return
	if not is_same(_observed_state, session.state):
		# restore_snapshot/new game replace the root dictionary. Presentation
		# must restart even on the same map and with equal battle-log length.
		_observed_state = session.state
		_clear_map_view()
		_presentation_token = ""
		_presentation_age = 0.0
	_update_source_presentation(delta)
	var w: Dictionary = session.state.world
	var target := Vector2(float(w.x), float(w.y))
	var map: Dictionary = session.content.maps.get(w.map_id, {})
	if map.is_empty():
		_clear_map_view()
		queue_redraw()
		return
	if previous_map != str(w.map_id) or _observed_map_load_sequence != session.map_load_sequence:
		_observed_map_load_sequence = session.map_load_sequence
		visual_player = target
		_entity_positions.clear()
		previous_map = str(w.map_id)
		_prepare_map(map)
	else:
		visual_player = visual_player.move_toward(target, delta * 8.0)
	if int(_motion_pose.get("slot", -1)) == 0: visual_player = _motion_pose.position
	for object in session.runtime().get("objects", {}).values():
		var id := str(object.get("slot", ""))
		var position := Vector2(float(object.x), float(object.y))
		_entity_positions[id] = Vector2(_entity_positions.get(id, position)).move_toward(position, delta * 8.0)
		if int(_motion_pose.get("slot", -1)) == int(object.get("slot", -2)): _entity_positions[id] = _motion_pose.position
	var extent := Vector2(float(map.width), float(map.height)) * tile_size
	var camera_focus: Vector2 = diagnostic_camera_focus if diagnostic_camera_focus is Vector2 else visual_player
	camera = (camera_focus + Vector2(0.5, 0.5)) * tile_size - view_size * Vector2(0.5, 0.48)
	camera.x = clampf(camera.x, 0.0, maxf(0.0, extent.x - view_size.x)) if extent.x >= view_size.x else (extent.x - view_size.x) * 0.5
	camera.y = clampf(camera.y, 0.0, maxf(0.0, extent.y - view_size.y)) if extent.y >= view_size.y else (extent.y - view_size.y) * 0.5
	camera = (camera / float(pixel_scale)).round() * float(pixel_scale)
	_backdrop_material.set_shader_parameter("map_rect", Vector4(-camera.x, -camera.y, extent.x, extent.y))
	_terrain.position = -camera
	if _valley_enabled:
		_terrain_material.set_shader_parameter("camera_native", camera / float(pixel_scale))
		_terrain_material.set_shader_parameter("viewport_native", view_size / float(pixel_scale))
	_terrain.scale = Vector2.ONE * tile_size
	var combat: Dictionary = session.runtime().get("combat", {})
	_terrain.visible = combat.is_empty()
	_update_battle(combat, delta)
	queue_redraw()

func _clear_map_view() -> void:
	previous_map = ""
	# This list may reference cached room commands. Detach it; clearing the
	# shared Array would erase buildings when returning to the same room.
	_map_draws = []
	_dressing.clear()
	_entity_positions.clear()
	_terrain.visible = false
	_valley_enabled = false
	_terrain.texture = null
	_update_battle({}, 0.0)
	camera = Vector2.ZERO
	_backdrop_material.set_shader_parameter("map_rect", Vector4.ZERO)

func _update_source_presentation(delta: float) -> void:
	var request := session.request()
	var token := str(request.get("token", ""))
	if token != _presentation_token:
		_presentation_token = token
		_presentation_age = 0.0
	else:
		_presentation_age += delta
	_motion_pose.clear()
	_movie_resource = str(request.get("resource", "")) if request.get("kind") == "movie" else ""
	if request.get("kind") != "movement": return
	var origin := Vector2(float(request.origin_x), float(request.origin_y))
	var target := Vector2(float(request.x), float(request.y))
	var distance := target - origin
	var travelled := minf(_presentation_age / 0.12, absf(distance.x) + absf(distance.y))
	var position := origin
	var facing := 2
	# Source MOVE lasts Manhattan-distance * .12 seconds. Visual travel follows
	# the horizontal leg then the vertical leg without touching the source actor.
	if travelled < absf(distance.x):
		position.x += signf(distance.x) * travelled
		facing = 1 if distance.x > 0.0 else 3
	else:
		position.x = target.x
		position.y += signf(distance.y) * minf(maxf(0.0, travelled - absf(distance.x)), absf(distance.y))
		if distance.y != 0.0: facing = 2 if distance.y > 0.0 else 0
		elif distance.x != 0.0: facing = 1 if distance.x > 0.0 else 3
	var step := int(_presentation_age / 0.09) % 4
	if position.is_equal_approx(target): step = 1
	_motion_pose = {"slot": int(request.slot), "position": position, "facing": facing, "step": step}

func presentation_busy() -> bool:
	if session == null or session.state.is_empty() or session.runtime().get("combat", {}).is_empty(): return false
	return not is_same(_observed_state, session.state) or not _was_in_combat or session.runtime().get("battle_log", []).size() != _battle_cursor or not _battle_queue.is_empty() or not _active_action.is_empty() or not _battle_floaters.is_empty()

func battle_display_round() -> int:
	if session == null or session.state.is_empty(): return 1
	var combat: Dictionary = session.runtime().get("combat", {})
	if combat.is_empty(): return 1
	var log: Array = session.runtime().get("battle_log", [])
	# A restored snapshot must never inherit the previous state's action queue,
	# even before the next process frame clears the presentation cache.
	if not is_same(_observed_state, session.state) or not _was_in_combat or log.size() < _battle_cursor:
		return _settled_battle_round(combat, log)
	if not _active_action.is_empty(): return int(_active_action.round)
	if not _battle_queue.is_empty(): return int(_battle_queue[0].round)
	if not _battle_floaters.is_empty(): return _battle_presented_round
	# Combat resolves synchronously; the UI may refresh before the world has
	# consumed its events. Show the first pending round, not the next selection.
	for i in range(_battle_cursor, log.size()):
		if log[i].get("type") == "round_started": return int(log[i].round) + 1
	return _settled_battle_round(combat, log)

func _settled_battle_round(combat: Dictionary, log: Array) -> int:
	if combat.get("phase") == "finished":
		# Victory/flee stop inside the round; timeout increments the counter first.
		# The last actual round event is authoritative for every result screen.
		for i in range(log.size() - 1, -1, -1):
			if log[i].get("type") == "round_started": return int(log[i].round) + 1
	return maxi(1, int(combat.get("round", 0)) + 1)

func _entry(map: Dictionary, cell: Dictionary) -> Dictionary:
	var source_key := "%d:%d" % [int(map.tile_set), int(cell.tile)]
	var entry: Dictionary = tile_mapping.get("tiles", {}).get(source_key, {})
	var overrides: Dictionary = tile_mapping.get("map_overrides", {}).get(previous_map, {})
	entry = overrides.get(str(int(cell.tile)), entry)
	if entry.is_empty():
		_missing("source_tile:" + source_key)
		return {}
	for alternative in entry.get("conditional_assets", []):
		var matches := true
		for field in alternative.get("when", {}):
			if cell.get(field) != alternative.when[field]: matches = false
		if matches:
			entry = entry.duplicate(true)
			entry.merge(alternative, true)
			break
	return entry

func _prepare_map(map: Dictionary) -> void:
	if not _map_cache.has(previous_map):
		var ids := Image.create(int(map.width), int(map.height), false, Image.FORMAT_RGBA8)
		var draws: Array = []
		var source_trees := _cemetery_trees(map)
		draws.append_array(source_trees.draws)
		var valley_available := previous_map == "2:1:4" and atlas.has("valley_depth")
		var surface_links: Dictionary = {}
		for cell in map.cells:
			var mapped := _entry(map, cell)
			var asset := str(mapped.get("asset", ""))
			var support := str(mapped.get("base_asset", ""))
			if asset.is_empty() or support.is_empty(): continue
			if not surface_links.has(asset): surface_links[asset] = []
			if support not in surface_links[asset]: surface_links[asset].append(support)
		for cell in map.cells:
			var entry := _entry(map, cell)
			if entry.get("asset", "") in ["bridge_horizontal", "bridge_vertical"]:
				entry = _bridge_cap_entry(map,cell,entry)
			if entry.get("asset", "") == "rock" and entry.has("module"):
				entry = entry.duplicate(true)
				entry.variant_seed = _module_variant_seed(map,cell,entry.module)
			var key := str(entry.get("asset", ""))
			if previous_map == "2:1:2":
				if key in ["flowers", "dry_grass"]: key = "grass"
				elif key == "path" and _material_ids.has("path_plain"): key = "path_plain"
			var is_ground: bool = _material_ids.has(key) and not key.is_empty() and not entry.has("edge") and entry.get("draw_mode") != "module_part"
			var base := key if is_ground else str(entry.get("base_asset", ""))
			var valley_base: bool = valley_available and base in ["ravine_void", "chasm"]
			var valley_cell: bool = valley_available and (valley_base or key in ["ravine_void", "chasm"])
			if not base.is_empty() and not _material_ids.has(base) and not valley_base:
				# Some inspected bases are surfaces from a structure (altar top,
				# brick backing). Keep them below props even before ground packing.
				draws.append({"type": "tile", "x": float(cell.x), "y": float(cell.y), "sort_y": -20000.0, "entry": {"asset": base, "draw_mode": "tile"}})
			var material := _underlying_material(base, surface_links)
			ids.set_pixel(int(cell.x), int(cell.y), Color(float(_material_ids.get(material, 0)) / 255.0, 1.0 if material in NATURAL_MATERIALS else 0.0, 1.0 if valley_cell else 0.0, 1.0))
			if not is_ground and not key.is_empty() and not (valley_available and key in ["ravine_void", "chasm"]) and not source_trees.covered.has(Vector2i(int(cell.x), int(cell.y))):
				var module: Dictionary = entry.get("module", {})
				var origin := Vector2(float(cell.x), float(cell.y))
				var foot_y := float(cell.y) + 1.0
				if not module.is_empty():
					origin -= Vector2(float(module.part[0]), float(module.part[1]))
					foot_y = _module_foot(map, cell, module, origin)
				# Repeated pieces use their source part and share the module's foot
				# row; never draw a full tree/roof for every source fragment.
				var sort_y := -10000.0 if key in FLOOR_MODULES else foot_y
				draws.append({"type": "tile", "x": float(cell.x), "y": float(cell.y), "sort_y": sort_y, "entry": entry, "origin": origin})
		draws.append_array(_courtyard_entrances(map))
		_map_cache[previous_map] = {"texture": ImageTexture.create_from_image(ids), "draws": draws}
	_terrain.texture = _map_cache[previous_map].texture
	_terrain_material.set_shader_parameter("map_data", _terrain.texture)
	_terrain.scale = Vector2.ONE * tile_size
	_valley_enabled = previous_map == "2:1:4" and atlas.has("valley_depth")
	_terrain_material.set_shader_parameter("valley_enabled", _valley_enabled)
	if _valley_enabled:
		var valley_item := _asset_item("valley_depth")
		var valley_texture := _texture(valley_item)
		if valley_texture != null:
			var valley_rect := _item_rect(valley_item)
			_terrain_material.set_shader_parameter("valley_depth", valley_texture)
			_terrain_material.set_shader_parameter("valley_region", Vector4(valley_rect.position.x,valley_rect.position.y,valley_rect.size.x,valley_rect.size.y))
			_terrain_material.set_shader_parameter("valley_image_size", Vector2(valley_texture.get_size()))
	_terrain_material.set_shader_parameter("map_cells", Vector2(float(map.width), float(map.height)))
	_terrain_material.set_shader_parameter("tile_pixels", float(TILE_PIXELS))
	_map_draws = _map_cache[previous_map].draws
	_dressing = _meadow_dressing(map)

func _courtyard_entrances(map: Dictionary) -> Array:
	var entrances: Array = []
	if str(map.id) != "2:1:1": return entrances
	# These six public doorways are the inspected side-room connections in
	# GUT1:2:1 events46..51. Never infer door art from arbitrary/hidden events.
	for row in 3:
		var y := 25 + row * 3
		for side in 2:
			var x := 15 if side == 0 else 30
			var expected_event := 6 + row * 2 + side
			var cell: Dictionary = map.cells[y * int(map.width) + x]
			var entry := _entry(map, cell)
			var module: Dictionary = entry.get("module", {})
			if int(cell.get("event",0)) != expected_event or str(module.get("id","")) != "1_long_gabled_roof":
				_missing("courtyard_entrance_source:%d:%d" % [x,y])
				continue
			var origin := Vector2(x,y) - Vector2(module.part[0],module.part[1])
			var facade_depth := _module_foot(map,cell,module,origin)
			entrances.append({"type":"dressing", "asset":"courtyard_door_east" if side == 0 else "courtyard_door_west",
				"x":float(x) + 0.5, "y":float(y) + 1.0, "sort_y":facade_depth + 0.01,
				"shade":1.0, "flip":false, "source_entrance":Vector2i(x,y), "source_event":expected_event})
	return entrances

func _bridge_cap_entry(map: Dictionary, cell: Dictionary, entry: Dictionary) -> Dictionary:
	var module: Dictionary = entry.get("module", {})
	var axis := str(module.get("repeat_axis", ""))
	if axis not in ["x", "y"]: return entry
	var adjacent: Array[bool] = []
	for direction in [-1,1]:
		var x: int = int(cell.x) + (direction if axis == "x" else 0)
		var y: int = int(cell.y) + (direction if axis == "y" else 0)
		var connected := false
		if x >= 0 and x < int(map.width) and y >= 0 and y < int(map.height):
			var neighbor := _entry(map,map.cells[y*int(map.width)+x])
			connected = neighbor.get("module",{}).get("id", "") == module.id
		adjacent.append(connected)
	if adjacent[0] and adjacent[1]: return entry
	var result := entry.duplicate(true)
	result.module_cap = "single" if not adjacent[0] and not adjacent[1] else ("start" if not adjacent[0] else "end")
	return result

func _cemetery_trees(map: Dictionary) -> Dictionary:
	var result := {"draws":[], "covered":{}}
	if int(map.tile_set) != 9 and str(map.id) != "2:1:35": return result
	# TIL9 reuses canopy/branch pieces for saplings and extended trunks as well
	# as 3x3 trees. Each terminal source trunk anchors one complete native tree.
	# Cutting every form from a large crown produces suspended leaf rectangles.
	var visited: Dictionary = {}
	for cell in map.cells:
		var position := Vector2i(int(cell.x), int(cell.y))
		if _tree_tile(map, int(cell.x), int(cell.y)) not in [2,3,4,5,6,7,8] or visited.has(position): continue
		var pending: Array[Vector2i] = [position]
		var component: Array[Vector2i] = []
		var has_trunk := false
		while not pending.is_empty():
			var at: Vector2i = pending.pop_back()
			if visited.has(at) or _tree_tile(map, at.x, at.y) not in [2,3,4,5,6,7,8]: continue
			visited[at] = true
			component.append(at)
			has_trunk = has_trunk or _tree_tile(map, at.x, at.y) == 8
			for direction in [Vector2i.UP,Vector2i.DOWN,Vector2i.LEFT,Vector2i.RIGHT]:
				pending.append(at + direction)
		# Crown-only fragments behind the original southern boundary stay crown
		# fragments. Do not invent a tree trunk in the source boundary or path.
		if has_trunk:
			for at in component: result.covered[at] = true
	for cell in map.cells:
		var x := int(cell.x)
		var y := int(cell.y)
		if _tree_tile(map, int(cell.x), int(cell.y)) == 24:
			result.covered[Vector2i(x,y)] = true
			if _tree_tile(map, x, y + 1) == 24: continue
			var bare_top := y
			while _tree_tile(map, x, bare_top - 1) == 24: bare_top -= 1
			var bare_cells: Array[Vector2i] = []
			for row in range(bare_top, y + 1): bare_cells.append(Vector2i(x,row))
			result.draws.append({"type":"dressing", "asset":"thin_tree_bare_small" if y == bare_top else "thin_tree_bare",
				"x":float(x) + 0.5, "y":float(y) + 1.0, "sort_y":float(y) + 1.0, "shade":1.0, "flip":false,
				"source_tree":true, "source_trunk":Vector2i(x,y), "source_trunk_cells":bare_cells, "source_span":Vector2i(1,y - bare_top + 1)})
			continue
		if _tree_tile(map, int(cell.x), int(cell.y)) != 8 or _tree_tile(map, x, y + 1) == 8: continue
		var trunk_top := y
		while _tree_tile(map, x, trunk_top - 1) == 8: trunk_top -= 1
		var trunk_cells: Array[Vector2i] = []
		for row in range(trunk_top, y + 1): trunk_cells.append(Vector2i(x,row))
		var crown_top := trunk_top
		while trunk_top - crown_top < 2 and _tree_tile(map, x, crown_top - 1) in [2,3,4,5,6,7]: crown_top -= 1
		var left := false
		var right := false
		for row in range(crown_top, trunk_top):
			left = left or _tree_tile(map, x - 1, row) in [2,5]
			right = right or _tree_tile(map, x + 1, row) in [4,7]
		var width := 1 + int(left) + int(right)
		var height := y - crown_top + 1
		var key := "thin_tree_%dx%d" % [width * 32, height * 32]
		if width == 3 and height == 3: key = "thin_tree"
		elif width == 1 and height == 2: key = "thin_tree_small"
		elif width == 2 and height == 3: key = "thin_tree_medium"
		result.draws.append({"type":"dressing", "asset":key, "x":float(x) + 0.5, "y":float(y) + 1.0,
			"sort_y":float(y) + 1.0, "shade":1.0, "flip":false, "source_tree":true,
			"source_trunk":Vector2i(x,y), "source_trunk_cells":trunk_cells, "source_span":Vector2i(width,height)})
	return result

func _tree_tile(map: Dictionary, x: int, y: int) -> int:
	var tile := _source_tile(map, x, y)
	# The seven TIL2 tree pieces are byte-identical to TIL9 frames2..8.
	if int(map.tile_set) == 2:
		return tile - 101 if tile >= 103 and tile <= 109 else -1
	return tile

func _source_tile(map: Dictionary, x: int, y: int) -> int:
	if x < 0 or y < 0 or x >= int(map.width) or y >= int(map.height): return -1
	return int(map.cells[y * int(map.width) + x].tile)

func _module_variant_seed(map: Dictionary, cell: Dictionary, module: Dictionary) -> int:
	var origin_x := int(cell.x) - int(module.part[0])
	var origin_y := int(cell.y) - int(module.part[1])
	if str(module.get("repeat_axis", "")) == "x" and origin_y >= 0 and origin_y < int(map.height):
		# The source left piece starts each repeated rock. Every row consults
		# that same top row, so extended middle pieces never choose independently.
		for x in range(int(cell.x), -1, -1):
			var reference := _entry(map,map.cells[origin_y*int(map.width)+x])
			var other: Dictionary = reference.get("module",{})
			if str(other.get("id","")) != str(module.id): break
			origin_x = x - int(other.part[0])
			if int(other.part[0]) == 0: break
	return absi((origin_x * 73856093) ^ (origin_y * 19349663))

func _underlying_material(asset: String, links: Dictionary) -> String:
	# A vessel can stand on a counter that in turn stands on a stone floor.
	# Resolve only support links explicitly present in this original map.
	var visited: Dictionary = {}
	while not asset.is_empty():
		if _material_ids.has(asset):
			# The authored quiet cave floor preserves the same source terrain
			# without a repeated bright crystal cluster under every actor/prop.
			if asset == "cave_floor" and _material_ids.has("cave_plain"): return "cave_plain"
			return asset
		if visited.has(asset):
			_missing("surface_cycle:" + asset)
			return ""
		visited[asset] = true
		var bases: Array = links.get(asset, [])
		if bases.size() != 1:
			if bases.size() > 1: _missing("ambiguous_surface:" + asset)
			return ""
		asset = str(bases[0])
	return ""

func _meadow_dressing(map: Dictionary) -> Array:
	var decorations: Array = []
	if previous_map != "2:1:2": return decorations
	for cell in map.cells:
		var x := int(cell.x)
		var y := int(cell.y)
		var seed := absi((x * 73856093) ^ (y * 19349663))
		var tile := int(cell.tile)
		# Source flowers and sparse grass retain their source cells, but use
		# transparent small growth over the same quiet meadow surface.
		if tile in [15, 17]:
			var patch := "flower_cluster" if tile == 17 else "dry_grass_cluster"
			decorations.append({"type":"dressing","asset":patch,"x":float(x)+0.4+float(seed%5)*0.04,"y":float(y)+0.82,
				"sort_y":float(y)+0.82,"flip":seed%2==0,"shade":0.94+float(seed%3)*0.03})
		# Tree/understory stems occupy only inspected original blocked grass.
		# Adjacent crowns may overhang; they never add collision or event hints.
		if bool(cell.walkable) or tile not in [15,16]: continue
		var key := ""
		if y == 2:
			if x in [0,1,2,6,7,8,9,10,12,13,17,18,19]: key = "tree"
			elif x in [3,4,5,11]: key = "bamboo"
		elif y == 13:
			if x in [6,7,8,9,14,15,16,21,22,23]: key = "tree"
			elif x in [11,12,18,19]: key = "bamboo"
		elif x == 23 and y == 10: key = "tree"
		elif x in [4,7] and y in [6,7,9]: key = "bamboo"
		elif y == 5 and x in [8,9,10]: key = "shrub"
		elif seed % 5 == 0: key = "shrub"
		if key.is_empty(): continue
		if key == "shrub" and atlas.has("fern"): key = "fern"
		var stem_x := float(x) + 0.25 + float((seed >> 3) % 6) * 0.1
		var stem_y := float(y) + 0.48 + float((seed >> 5) % 5) * 0.1
		var shade := 0.84 + float(seed % 4) * 0.04
		if key == "tree" and y in [2,13]:
			var back_row := x % 2 == 0
			stem_y = float(y) + (0.13 if back_row else 0.82) + float(seed % 3) * 0.06
			shade = 0.76 if back_row else 0.94
		decorations.append({"type":"dressing","asset":key,"x":stem_x,"y":stem_y,
			"sort_y":stem_y,"flip":seed%3==0,"shade":shade})
	return decorations

func _draw_dressing(command: Dictionary) -> void:
	var item := _asset_item(str(command.asset))
	if item.is_empty(): return
	var at := Vector2(float(command.x), float(command.y)) * tile_size - camera
	var size := _native_size(item) * float(pixel_scale)
	var destination := Rect2(at - size * _anchor(item), size)
	if not destination.intersects(Rect2(Vector2.ZERO, view_size)): return
	var texture := _texture(item)
	if texture == null: return
	var region := _item_rect(item)
	if bool(command.flip):
		destination.position.x += destination.size.x
		destination.size.x = -destination.size.x
	var shade := float(command.shade)
	var alpha := 1.0
	var player_foot := (visual_player + Vector2(0.5, 0.88)) * tile_size - camera
	# Foreground edge leaves can overlap the path visually. Keep the player
	# readable beneath them without removing or moving their original grid.
	if str(command.asset) in ["tree", "bamboo"] and Rect2(at - size, size * Vector2(2.0, 1.0)).has_point(player_foot): alpha = 0.52
	var tint := Color(shade, shade, shade, alpha)
	if str(command.asset) == "shrub": tint = Color(shade * 1.12, shade, shade * 0.62, alpha)
	draw_texture_rect_region(texture, Rect2(destination.position.round(), destination.size), region, tint)

func _module_foot(map: Dictionary, cell: Dictionary, module: Dictionary, origin: Vector2) -> float:
	var foot := origin.y + float(module.size[1])
	var repeat_axis := str(module.get("repeat_axis", ""))
	if repeat_axis not in ["", "x", "y"]:
		_missing("repeat_axis:" + repeat_axis)
	if repeat_axis == "y":
		# A vertical repeat belongs to the same physical structure until its
		# final source row. The upper roof must not sort in front of its base.
		var y := int(cell.y) + 1
		while y < int(map.height):
			var next: Dictionary = map.cells[y * int(map.width) + int(cell.x)]
			var next_entry := _entry(map, next)
			if next_entry.get("module", {}).get("id", "") != module.id: break
			foot = maxf(foot, float(y + 1))
			y += 1
	return foot

func _draw() -> void:
	if session == null or session.state.is_empty(): return
	if previous_map.is_empty(): return
	var combat: Dictionary = session.runtime().get("combat", {})
	if not combat.is_empty():
		_draw_battle(combat)
		return
	var draw_list: Array = _map_draws.duplicate()
	draw_list.append_array(_dressing)
	for object in session.runtime().get("objects", {}).values():
		if bool(object.get("hidden", false)) or bool(object.get("invisible", false)): continue
		var entity: Dictionary = object.duplicate()
		var at: Vector2 = _entity_positions.get(str(object.get("slot", "")), Vector2(float(object.x), float(object.y)))
		entity.x = at.x
		entity.y = at.y
		entity.presentation_moving = not at.is_equal_approx(Vector2(float(object.x), float(object.y)))
		if int(_motion_pose.get("slot", -1)) == int(object.get("slot", -2)):
			entity.presentation_moving = true
			entity.facing = _motion_pose.facing
			entity.step = _motion_pose.step
		draw_list.append({"type": "entity", "sort_y": _entity_sort_y(entity), "entity": entity})
	var w: Dictionary = session.state.world
	if not session.state.party.is_empty():
		var player := {"kind": 1, "index": 1, "x": visual_player.x, "y": visual_player.y, "facing": int(_motion_pose.facing) if int(_motion_pose.get("slot", -1)) == 0 else int(w.facing), "step": int(_motion_pose.step) if int(_motion_pose.get("slot", -1)) == 0 else int(w.step)}
		draw_list.append({"type": "entity", "sort_y": _entity_sort_y(player), "entity": player})
	draw_list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.sort_y) < float(b.sort_y))
	for command in draw_list:
		if command.type == "entity":
			_draw_entity(command.entity)
		elif command.type == "dressing":
			_draw_dressing(command)
		else:
			var at := Vector2(float(command.x), float(command.y)) * tile_size - camera
			if Rect2(-Vector2.ONE * 96.0, view_size + Vector2.ONE * 192.0).has_point(at):
				_draw_tile(command.entry, Rect2(at, Vector2.ONE * tile_size))
	_draw_atmosphere()
	_draw_movie()

func _draw_tile(entry: Dictionary, destination: Rect2) -> void:
	var key := str(entry.get("asset", ""))
	var item := _asset_item(key, entry)
	if item.is_empty(): return
	var rect := _item_rect(item)
	if entry.get("draw_mode") == "module_part":
		var module: Dictionary = entry.module
		var size := Vector2(float(module.size[0]), float(module.size[1]))
		var part := Vector2(float(module.part[0]), float(module.part[1]))
		var span := rect.size / size
		if span != Vector2.ONE * TILE_PIXELS: _missing("module_native_span:" + str(module.id))
		rect = Rect2(rect.position + part * span, span)
	elif rect.size != Vector2.ONE * TILE_PIXELS:
		_missing("tile_native_span:" + key + (":" + str(entry.edge) if entry.has("edge") else ""))
	_draw_item(item, destination, rect)

func _asset_item(key: String, entry: Dictionary = {}) -> Dictionary:
	var edge := str(entry.get("edge", ""))
	if not edge.is_empty() and atlas.has(key + "__" + edge): return atlas[key + "__" + edge]
	if not atlas.has(key):
		_missing("asset:" + key)
		return {}
	var item: Dictionary = atlas[key]
	if item.has("provisional_alias"):
		_missing("provisional_alias:" + key)
		return {}
	if entry.get("draw_mode") == "tile" and edge.is_empty() and item.get("tile") is Dictionary:
		item = item.duplicate(true)
		item.merge(item.tile, true)
	var module_id := str(entry.get("module", {}).get("id", ""))
	if module_id == "1_long_gabled_roof" and not item.get("modules", {}).has(module_id):
		# The standalone pagoda roof has a mostly empty 64x96 canvas; it is not
		# an acceptable three-row wall/roof repeat even though its size matches.
		_missing("module_shape:" + module_id)
		return {}
	if module_id == "9_thin_tree_canopy_and_trunk" and not item.get("modules", {}).has(module_id):
		# TIL9 has only a central bottom trunk tile. The generic broad-root
		# tree is visibly cropped by that source layout and needs a real variant.
		_missing("module_shape:" + module_id)
	if item.get("modules", {}).has(module_id):
		item = item.duplicate(true)
		item.merge(item.modules[module_id], true)
	var variants: Array = item.get("variants", [])
	if entry.has("variant_seed") and not variants.is_empty():
		var variant: Dictionary = variants[posmod(int(entry.variant_seed),variants.size())]
		item = item.duplicate(true)
		item.merge(variant,true)
	var cap := str(entry.get("module_cap", ""))
	if not cap.is_empty() and item.get("caps", {}).has(cap):
		item = item.duplicate(true)
		item.merge(item.caps[cap],true)
	if not edge.is_empty():
		if item.get("edges", {}).has(edge):
			item = item.duplicate(true)
			item.merge(item.edges[edge], true)
		else:
			_missing("edge:" + key + ":" + edge)
			return {}
	return item

func _item_rect(item: Dictionary) -> Rect2:
	var r: Array = item.get("rect", [0, 0, 0, 0])
	return Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3]))

func _draw_item(item: Dictionary, destination: Rect2, region := Rect2(), modulate := Color.WHITE) -> bool:
	var texture := _texture(item)
	if texture == null: return false
	if region.size == Vector2.ZERO: region = _item_rect(item)
	draw_texture_rect_region(texture, Rect2(destination.position.round(), destination.size.round()), region, modulate)
	return true

static func sprite_frame(step: int) -> int:
	return [0, 1, 2, 1][posmod(step, 4)]

func _entity_art_key(entity: Dictionary) -> String:
	var key := "hero" if int(entity.kind) == 1 else "npc_%d" % int(entity.index)
	if int(entity.kind) == 2:
		if int(entity.index) == 6: key = "xiaomei"
		elif int(entity.index) == 7: key = "yuan"
		elif int(entity.index) == 10: key = "npc_11"
		elif int(entity.index) == 26: key = "npc_12"
	var frame := sprite_frame(int(entity.get("step", 1)))
	if int(entity.kind) == 2 and int(entity.get("move_mode", 0)) in [0,3] and not bool(entity.get("presentation_moving", false)):
		frame = 1
	if int(entity.kind) == 4:
		key = "object_%d" % int(entity.index)
		# SceneObj uses a single north-facing strip: frame is the source step,
		# never facing. Lamp frame zero is extinguished; one/two contain fire.
		var state_key := key + "_%d" % frame
		return state_key if atlas.has(state_key) else key
	var facing := clampi(int(entity.get("facing", 2)), 0, 3)
	var numeric := key + "_%d_%d" % [facing, frame]
	var named := key + "_%s_%d" % [["north", "east", "south", "west"][facing], frame]
	if atlas.has(numeric): return numeric
	if atlas.has(named): return named
	if int(entity.kind) == 2:
		# The first NPC pack explicitly contains four real standing poses.
		# Keep them visible while reporting missing walking frames separately.
		var standing := key + "_%d_1" % facing
		if not atlas.has(standing): standing = key + "_%s_1" % ["north", "east", "south", "west"][facing]
		if atlas.has(standing):
			_missing("animation_frame:" + numeric)
			return standing
	return numeric

func _entity_sort_y(entity: Dictionary) -> float:
	var item: Dictionary = atlas.get(_entity_art_key(entity), {})
	var grid_anchor: Array = item.get("grid_anchor", [0.5, 0.88])
	return float(entity.y) + float(grid_anchor[1])

func _draw_entity(entity: Dictionary) -> void:
	var key := _entity_art_key(entity)
	var item := _asset_item(key)
	if item.is_empty(): return
	var grid_anchor: Array = item.get("grid_anchor", [0.5, 0.88])
	var at := (Vector2(float(entity.x), float(entity.y)) + Vector2(float(grid_anchor[0]), float(grid_anchor[1]))) * tile_size - camera
	var size := _native_size(item) * float(pixel_scale)
	var anchor := _anchor(item)
	_draw_shadow(at, size.x * 0.3)
	_draw_item(item, Rect2(at - size * anchor, size))

func _native_size(item: Dictionary) -> Vector2:
	var size: Array = item.get("native_size", item.get("logical_size", [_item_rect(item).size.x, _item_rect(item).size.y]))
	return Vector2(float(size[0]), float(size[1]))

func _anchor(item: Dictionary) -> Vector2:
	var value: Variant = item.get("anchor", "bottom_center")
	if value is Array:
		var anchor := Vector2(float(value[0]), float(value[1]))
		return anchor / _native_size(item) if anchor.x > 1.0 or anchor.y > 1.0 else anchor
	return Vector2(0.5, 1.0) if value == "bottom_center" else Vector2(0.5, 0.5)

func _draw_shadow(at: Vector2, radius: float) -> void:
	# Small pixel rows keep sprite shadows at the same integer pixel scale.
	for row in range(-2, 3):
		var width := floorf(radius * (1.0 - absf(float(row)) * 0.13))
		draw_line((at + Vector2(-width, row)).round(), (at + Vector2(width, row)).round(), Color(0.02, 0.06, 0.08, 0.22), 1.0)

func _draw_atmosphere() -> void:
	# Glows are presentation for existing visible lit lamps only.
	for object in session.runtime().get("objects", {}).values():
		if bool(object.get("hidden", false)) or bool(object.get("invisible", false)): continue
		if int(object.kind) == 4 and int(object.index) == 7 and sprite_frame(int(object.get("step", 0))) != 0:
			var at := (Vector2(float(object.x), float(object.y)) + Vector2(0.5, 0.0)) * tile_size - camera
			for radius in range(5, 0, -1):
				draw_circle(at.round(), float(radius * 9), Color(0.95, 0.65, 0.25, 0.018))

func _draw_movie() -> void:
	if _movie_resource == "5:1:3":
		# Original SRS alternates black rows from the top and bottom inward.
		var progress := clampf(_presentation_age / 2.0, 0.0, 1.0)
		var height := floorf(progress * 24.0) / 24.0 * view_size.y * 0.5
		draw_rect(Rect2(Vector2.ZERO, Vector2(view_size.x, height)), Color.BLACK)
		draw_rect(Rect2(Vector2(0, view_size.y - height), Vector2(view_size.x, height)), Color.BLACK)
		return
	if _movie_resource == "5:1:4":
		# Original last movie enlarges a single ending character in four stages.
		draw_rect(Rect2(Vector2.ZERO, view_size), Color("102832"))
		var stage := mini(3, int(_presentation_age / 0.25))
		var size: int = [32, 48, 64, 96][stage]
		var width := _font.get_string_size("完", HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		draw_string(_font, Vector2((view_size.x - width) * 0.5, view_size.y * 0.5 + size * 0.35).round(), "完", HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color("e6c786"))
		return
	# MOVIE 5:1:1 follows the sword chamber collapse. Other movie identities
	# remain distinct; the opening movie must never become falling rocks.
	if _movie_resource != "5:1:1": return
	var item := _asset_item("rock")
	if item.is_empty(): return
	for i in range(7):
		var elapsed := _presentation_age - float(i) * 0.16
		if elapsed < 0.0: continue
		var anchor := (visual_player + Vector2(0.5, 0.8)) * tile_size - camera
		anchor += Vector2(float((i * 83) % 300) - 150.0, float((i * 47) % 110) - 60.0)
		var height := maxf(0.0, 220.0 - elapsed * elapsed * 460.0)
		var size := _native_size(item) * float(pixel_scale)
		var alpha := clampf((2.0 - _presentation_age) * 3.0, 0.0, 0.9)
		_draw_item(item, Rect2(anchor - size * _anchor(item) - Vector2(0, height), size), Rect2(), Color(0.8, 0.84, 0.86, alpha))

func _missing(key: String) -> void:
	if diagnostics.has(key): return
	diagnostics[key] = true
	push_warning("Chapter art unavailable: " + key)

func _update_battle(combat: Dictionary, delta: float) -> void:
	if combat.is_empty():
		_was_in_combat = false
		_battle_cursor = 0
		_battle_queue.clear()
		_active_action.clear()
		_battle_floaters.clear()
		_battle_hp.clear()
		_battle_presented_round = 1
		return
	var log: Array = session.runtime().get("battle_log", [])
	if not _was_in_combat or log.size() < _battle_cursor:
		_was_in_combat = true
		_battle_cursor = 0
		_battle_queue.clear()
		_active_action.clear()
		_battle_floaters.clear()
		_battle_hp.clear()
		_battle_presented_round = _settled_battle_round(combat, log)
		for side in ["party", "enemies"]:
			for fighter in combat.get(side, []):
				_battle_hp[_fighter_id(side, int(fighter.slot))] = int(fighter.hp)
		# When restoring a battle, begin at its saved health rather than replaying
		# earlier damage. A new battle only has battle_started in the log.
		_battle_cursor = log.size()
	var batch: Dictionary = {}
	var batch_round := _battle_presented_round
	for i in range(_battle_cursor, log.size()):
		var event: Dictionary = log[i]
		if event.type == "round_started":
			if not batch.is_empty(): _battle_queue.append(batch)
			batch = {}
			batch_round = int(event.round) + 1
		elif event.type == "action":
			if not batch.is_empty(): _battle_queue.append(batch)
			batch = {"action": event, "events": [], "round": batch_round}
		elif event.type in ["vitals", "miss", "defend", "automatic_guard", "status", "cured", "flee", "level_up"]:
			if batch.is_empty(): batch = {"action": {}, "events": [], "round": batch_round}
			batch.events.append(event)
	if not batch.is_empty(): _battle_queue.append(batch)
	_battle_cursor = log.size()
	if _active_action.is_empty() and not _battle_queue.is_empty():
		_active_action = _battle_queue.pop_front()
		_battle_presented_round = int(_active_action.round)
		_active_action.applied = false
		_action_age = 0.0
		if not _active_action.action.is_empty(): visual_event.emit(_active_action.action.duplicate(true))
	if not _active_action.is_empty():
		_action_age += delta
		if _action_age >= 0.25 and not bool(_active_action.applied):
			_active_action.applied = true
			for event in _active_action.events: _present_event(event)
		if _action_age >= 0.68: _active_action.clear()
	for floater in _battle_floaters: floater.age += delta
	_battle_floaters = _battle_floaters.filter(func(f: Dictionary) -> bool: return float(f.age) < 1.0)

func _fighter_id(side: String, slot: int) -> String:
	return "%s:%d" % [side, slot]

func _present_event(event: Dictionary) -> void:
	visual_event.emit(event.duplicate(true))
	var side := str(event.get("side", "party"))
	var slot := int(event.get("actor", 0))
	var text := ""
	var color := Color("e9e4cb")
	match str(event.type):
		"vitals":
			_battle_hp[_fighter_id(side, slot)] = int(event.hp)
			var delta_hp := int(event.get("hp_delta", 0))
			if delta_hp == 0: return
			text = str(-delta_hp) if delta_hp < 0 else "+%d" % delta_hp
			color = Color("f4dcae") if delta_hp < 0 else Color("9ddd9b")
		"miss": text = "闪避"
		"defend", "automatic_guard": text = "防御"
		"status": text = {"poison": "中毒", "sleep": "睡眠", "seal": "封魔", "confusion": "混乱"}.get(str(event.get("status", "")), "状态")
		"cured": text = "恢复"
		"flee": text = "脱离" if bool(event.get("success", false)) else "未能逃离"
		"level_up": text = "升级"
	if text.is_empty(): return
	var damage: bool = event.type == "vitals" and int(event.get("hp_delta", 0)) < 0
	# Damage and its status effect arrive together. Keep both readable instead
	# of placing two strings at the same pixel; event/audio dispatch is unchanged.
	for floater in _battle_floaters:
		if floater.side == side and int(floater.slot) == slot and float(floater.age) == 0.0:
			floater.text = str(floater.text) + " · " + text
			floater.damage = bool(floater.get("damage", false)) or damage
			return
	_battle_floaters.append({"side":side,"slot":slot,"text":text,"color":color,"age":0.0,"damage":damage})

func _draw_battle(combat: Dictionary) -> void:
	var map: Dictionary = session.content.maps.get(previous_map, {})
	var background_key := "battle_cave" if int(map.get("tile_set", 0)) == 8 else "battle_meadow"
	var item := _asset_item(background_key)
	if not item.is_empty():
		var size := _native_size(item)
		var scale_factor := maxf(1.0, floorf(minf(view_size.x / size.x, 456.0 / size.y)))
		var output := size * scale_factor
		_draw_item(item, Rect2(Vector2((view_size.x - output.x) * 0.5, 40.0), output))
	# Top and lower strips are interface space; all battlers and feedback stay
	# above the dialogue/action panels at y=474/491 respectively.
	draw_rect(Rect2(0, 0, view_size.x, 94), Color(0.04, 0.09, 0.12, 0.78))
	var round_text := "第 %d 回合" % battle_display_round()
	_draw_text(round_text, Vector2(view_size.x - 180, 55), 20, Color("dbc69a"))
	var battlers: Array = []
	for side in ["party", "enemies"]:
		for fighter in combat.get(side, []):
			battlers.append({"side": side, "fighter": fighter, "at": _battle_position(side, int(fighter.slot), combat.get(side, []).size())})
	battlers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return Vector2(a.at).y < Vector2(b.at).y)
	for battler in battlers: _draw_battler(battler.fighter, str(battler.side), battler.at)
	_draw_attack_effect(combat)
	for floater in _battle_floaters:
		var group: Array = combat.get(str(floater.side), [])
		var position := _battle_position(str(floater.side), int(floater.slot), group.size())
		var age := float(floater.age)
		var at := Vector2(position.x, maxf(position.y - 114.0, 182.0) - age * 28.0)
		var color: Color = floater.color
		color.a = minf(1.0, (1.0 - age) * 4.0)
		_draw_text(str(floater.text), at, 24, color, true)
	if not _active_action.is_empty():
		var action: Dictionary = _active_action.get("action", {})
		if not action.is_empty():
			var name := ""
			var actors: Array = combat.get(str(action.side), [])
			if int(action.actor) < actors.size(): name = str(actors[int(action.actor)].name)
			var command_name: String = {"attack": "攻击", "defend": "防御", "flee": "逃跑", "magic": "施法", "item": "使用物品", "throw": "投掷"}.get(str(action.command), "行动")
			_draw_text(name + " · " + command_name, Vector2(view_size.x * 0.5, 126), 20, Color("f2d9a8"), true)

func _battle_position(side: String, slot: int, count: int) -> Vector2:
	if side == "party":
		if count >= 3:
			# Keep every name and HP line above the command panel at y=492.
			var trio := [Vector2(0.27, 235), Vector2(0.165, 343), Vector2(0.325, 418)]
			var point: Vector2 = trio[slot % trio.size()]
			return Vector2(view_size.x * point.x, point.y)
		return Vector2(view_size.x * 0.24 - float(slot % 2) * 58.0, 327.0 if count == 1 else 275.0 + float(slot) * 105.0)
	var positions := [Vector2(0.68, 294), Vector2(0.79, 357), Vector2(0.87, 254), Vector2(0.64, 400), Vector2(0.89, 412), Vector2(0.73, 206)]
	if count == 1: return Vector2(view_size.x * 0.73, 345)
	var at: Vector2 = positions[slot % positions.size()]
	return Vector2(view_size.x * at.x, at.y)

func _draw_attack_effect(combat: Dictionary) -> void:
	if _active_action.is_empty() or _action_age < 0.25 or _action_age >= 0.65: return
	if str(_active_action.get("action", {}).get("command", "")) != "attack": return
	var item := _asset_item("cut_%d" % mini(3, int((_action_age - 0.25) / 0.1)))
	if item.is_empty(): return
	for event in _active_action.get("events", []):
		if event.get("type") != "vitals" or int(event.get("hp_delta", 0)) >= 0: continue
		var side := str(event.get("side", "enemies"))
		var at := _battle_position(side, int(event.get("actor", 0)), combat.get(side, []).size()) + Vector2(0, -62)
		var size := _native_size(item) * 2.0
		_draw_item(item, Rect2(at.round() - size * _anchor(item), size))

func _draw_battler(fighter: Dictionary, side: String, at: Vector2) -> void:
	var slot := int(fighter.slot)
	var id := _fighter_id(side, slot)
	var hp := int(_battle_hp.get(id, fighter.hp))
	var phase := "idle"
	var offset := Vector2.ZERO
	if not _active_action.is_empty():
		var action: Dictionary = _active_action.get("action", {})
		if str(action.get("side", "")) == side and int(action.get("actor", -1)) == slot:
			phase = str(action.get("command", "idle"))
			if phase == "attack": offset.x = sin(clampf(_action_age / 0.55, 0.0, 1.0) * PI) * (38.0 if side == "party" else -38.0)
	for floater in _battle_floaters:
		if floater.side == side and int(floater.slot) == slot and float(floater.age) < 0.18 and bool(floater.get("damage", false)):
			phase = "hurt"
	if hp <= 0: phase = "down"
	var index := int(fighter.get("battle_sprite_index", fighter.get("index", 1)))
	var key := "hero_battle" if side == "party" else "enemy_%d" % index
	if side == "party" and str(fighter.get("id", "")) == "3:1:2": key = "xiaomei_battle"
	if side == "party" and str(fighter.get("id", "")) == "3:1:3": key = "yuan_battle"
	var phase_key := key + "_" + phase
	if phase == "attack" and _action_age < 0.16 and atlas.has(key + "_windup"): phase_key = key + "_windup"
	if atlas.has(phase_key):
		key = phase_key
	elif atlas.has(key + "_0"):
		var frame := int(clock * 4.0) % 2
		key += "_%d" % (frame if atlas.has(key + "_%d" % frame) else 0)
	var item := _asset_item(key)
	if not item.is_empty():
		var size := _native_size(item) * 2.0
		var modulate := Color.WHITE if hp > 0 else Color(0.62, 0.64, 0.68, 0.38)
		for floater in _battle_floaters:
			if floater.side == side and int(floater.slot) == slot and float(floater.age) < 0.14:
				modulate = Color(1.35, 1.35, 1.35)
		_draw_shadow(at + offset, size.x * 0.27)
		_draw_item(item, Rect2(at + offset - size * _anchor(item), size), Rect2(), modulate)
	var bar_at := (at + Vector2(-41, 10)).round()
	draw_rect(Rect2(bar_at - Vector2.ONE * 2.0, Vector2(86, 8)), Color("111c24"))
	draw_rect(Rect2(bar_at, Vector2(82, 4)), Color("383d43"))
	var ratio := clampf(float(hp) / maxf(1.0, float(fighter.max_hp)), 0.0, 1.0)
	draw_rect(Rect2(bar_at, Vector2(floorf(82.0 * ratio), 4)), Color("9dc690") if side == "party" else Color("cd846e"))
	_draw_text(str(fighter.name), at + Vector2(0, 36), 17, Color("e5deca"), true)
	if side == "party": _draw_text("%d / %d" % [hp, int(fighter.max_hp)], at + Vector2(0, 54), 14, Color("b8c6c2"), true)

func _draw_text(value: String, position: Vector2, size: int, color: Color, centered := false) -> void:
	if centered: position.x -= _font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x * 0.5
	draw_string_outline(_font, position.round(), value, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 4, Color(0.04, 0.08, 0.1, color.a))
	draw_string(_font, position.round(), value, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
