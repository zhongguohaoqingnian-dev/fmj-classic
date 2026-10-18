extends Control
## The UI sends player commands and consumes serializable presentation requests.
var content := ChapterContent.new()
var session: ChapterSession
var map_journal = preload("res://src/chapter1/chapter_map_journal.gd").new()
var _restoring_map := false
var _journal_epoch := -1
var _map_departure: Dictionary = {}
var saves := SaveStore.new("user://chapter1-saves")
var world := ChapterWorld.new()
var overlay := Control.new()
var hud := Control.new()
var field_hud := preload("res://src/chapter1/chapter_hud.gd").new()
var notice := Label.new()
var token := ""
var elapsed := 0.0
var input_delay := 0.0
var menu_open := false
var started := false
var font := SystemFont.new()
var log_file: FileAccess
var replay_directory := "user://chapter1-replays"
var battle_target := 0
var world_tick_elapsed := 0.0
var playtime_elapsed := 0.0
var pending_move := Vector2i.ZERO
var toast_time := 0.0
var toast_text := ""
var item_menu: RefCounted
var sound: Node = preload("res://src/chapter1/chapter_audio.gd").new()

func _ready() -> void:
	item_menu = preload("res://src/chapter1/chapter_item_menu.gd").new(self)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	font.font_names = PackedStringArray(["PingFang SC", "Microsoft YaHei", "Noto Sans CJK SC", "Heiti SC", "Arial"])
	var theme_new := Theme.new()
	theme_new.default_font = font
	theme_new.default_font_size = 20
	for state_name in ["normal", "hover", "focus", "pressed", "disabled"]:
		var button_style := StyleBoxFlat.new()
		button_style.bg_color = Color("274944") if state_name in ["hover", "focus", "pressed"] else Color("152f33")
		button_style.border_color = Color("d3ba79") if state_name in ["hover", "focus"] else Color("567e79")
		button_style.set_border_width_all(1)
		button_style.set_content_margin_all(9)
		theme_new.set_stylebox(state_name, "Button", button_style)
	theme_new.set_color("font_color", "Button", Color("ecedcf"))
	theme = theme_new
	add_child(world)
	add_child(sound)
	world.visual_event.connect(sound.visual_event)
	sound.ambience(false,false)
	add_child(hud)
	hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(field_hud)
	notice.position = Vector2(38, 677)
	notice.add_theme_font_size_override("font_size", 15)
	notice.add_theme_color_override("font_color", Color("d6d8c6"))
	add_child(overlay)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(notice)
	notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var data_path := "res://data/game/classic.json"
	var result := content.load_file(data_path)
	if not result.ok:
		_error(str(result.error))
		return
	session = ChapterSession.new(content)
	session.changed.connect(_refresh)
	session.recorded.connect(_write_record)
	session.recorded.connect(_track_map_command)
	session.recorded.connect(sound.on_record)
	world.session = session
	DirAccess.make_dir_recursive_absolute(replay_directory)
	log_file = FileAccess.open(replay_directory.path_join("play-%d.jsonl" % Time.get_unix_time_from_system()), FileAccess.WRITE)
	_title()

func _title() -> void:
	_clear_overlay()
	hud.visible = false
	notice.visible = false
	var background := TextureRect.new()
	var art_path := "res://assets/chapter1/native/battle_meadow.png"
	if ResourceLoader.exists(art_path): background.texture = load(art_path)
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	background.size = Vector2(1120,720)
	background.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(background)
	var shade := TextureRect.new()
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0,0.36,0.75,1])
	gradient.colors = PackedColorArray([Color("071c25f5"),Color("0b2535d9"),Color("0b253530"),Color("0b253500")])
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill_to = Vector2(1,0)
	shade.texture = texture
	shade.size = Vector2(1120,720)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(shade)
	_label(overlay,"三清山下  ·  尘缘初起",Vector2(103,155),18,Color("a8d2ca"))
	var title := _label(overlay,"伏 魔 记",Vector2(94,197),70,Color("fff1c6"))
	var title_font := SystemFont.new()
	title_font.font_names = PackedStringArray(["Songti SC","SimSun","Noto Serif CJK SC","STSong","PingFang SC","Microsoft YaHei"])
	title.add_theme_font_override("font",title_font)
	title.add_theme_color_override("font_shadow_color",Color("092c3b"))
	title.add_theme_constant_override("shadow_offset_y",3)
	_label(overlay,"伏魔剑  ·  下山除蛇妖",Vector2(104,297),23,Color("e4cca0"))
	_button(overlay,"初入江湖",Rect2(104,397,334,54),_new_game)
	_button(overlay,"继续前缘",Rect2(104,467,334,54),func(): _save_menu(false))
	_label(overlay,"方向键 / WASD 行走   ·   E / 空格 交互",Vector2(104,592),15,Color("b2c8bc"))
	_label(overlay,"B 背包   ·   M 地图   ·   Esc 菜单与存档   ·   F5 快存   F9 快读",Vector2(104,621),14,Color("95afa8"))

func _new_game() -> void:
	hud.visible = true
	started = true
	menu_open = false
	map_journal.clear()
	_journal_epoch = -1
	var result := session.start_new()
	if not result.ok: _error(str(result.error))
	_refresh()

func _process(delta: float) -> void:
	input_delay = maxf(0, input_delay - delta)
	if toast_time > 0:
		toast_time = maxf(0,toast_time-delta)
		if toast_time == 0: _refresh_notice()
	if not started or menu_open or session == null: return
	if not session.runtime().error.is_empty(): return
	playtime_elapsed += delta
	if playtime_elapsed >= 1:
		session.add_playtime(int(playtime_elapsed*1000))
		playtime_elapsed = 0
	if session.ready():
		world_tick_elapsed += delta
		if world_tick_elapsed >= 0.5:
			session.tick_world()
			world_tick_elapsed = 0
	else: world_tick_elapsed = 0
	var r := session.request()
	if not r.is_empty() and token.is_empty() and not world.presentation_busy(): _refresh()
	if r.is_empty():
		if bool(session.runtime().active): session.pump()
		if input_delay <= 0:
			if pending_move != Vector2i.ZERO:
				var direction := pending_move
				pending_move = Vector2i.ZERO
				session.move(direction)
				input_delay = 0.15
				return
			for pair in [[KEY_W, KEY_UP, Vector2i.UP], [KEY_S, KEY_DOWN, Vector2i.DOWN], [KEY_A, KEY_LEFT, Vector2i.LEFT], [KEY_D, KEY_RIGHT, Vector2i.RIGHT]]:
				if Input.is_physical_key_pressed(pair[0]) or Input.is_physical_key_pressed(pair[1]):
					session.move(pair[2])
					input_delay = 0.15
					break
	else:
		elapsed += delta
		if r.kind in ["pose", "scene_name", "screen", "movie", "movement"]:
			var duration := float(r.get("duration", 0.5))
			if r.kind == "movement": duration = (absf(r.x - r.origin_x) + absf(r.y - r.origin_y)) * 0.12
			if elapsed >= duration: _respond()

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo or session == null: return
	if event.keycode == KEY_B and started:
		if overlay.has_node("InventoryBrowser"): _close_inventory()
		elif not menu_open and session.ready(): item_menu.inventory()
		get_viewport().set_input_as_handled()
		return
	if event.keycode == KEY_M and started:
		if overlay.has_node("MapBrowser"): _close_map()
		elif not menu_open and session.ready(): _open_map()
		get_viewport().set_input_as_handled()
		return
	if event.keycode == KEY_F12:
		_capture()
		return
	if event.keycode == KEY_F5 and started:
		var saved := saves.save_slot(1, _save_snapshot())
		_toast("已快速保存至存档 1" if saved.ok else _save_failure_message(str(saved.error)))
		return
	if event.keycode == KEY_F9:
		var saved := saves.load_slot(1, "fmj-chapter1-candidate", content.identity)
		var recovered := bool(saved.get("recovered",false))
		if saved.ok: saved = _restore_save(saved.value)
		if saved.ok:
			started = true
			menu_open = false
			token = ""
			_refresh()
			_toast("已从备份恢复存档 1" if recovered else "已读取存档 1")
		else: _toast(_save_failure_message(str(saved.error)))
		return
	if event.keycode == KEY_ESCAPE and started:
		if overlay.has_node("MapBrowser"):
			_close_map()
		elif menu_open and overlay.has_node("SaveConfirm"):
			_save_menu(bool(overlay.get_node("SaveConfirm").get_meta("saving")))
		elif menu_open and overlay.has_node("InventoryBrowser"):
			if not session.runtime().get("combat", {}).is_empty(): _close_inventory()
			else: _menu()
		elif menu_open:
			menu_open = false
			token = ""
			_refresh()
		elif overlay.has_node("BattleSelection") and not world.presentation_busy():
			token = ""
			_refresh()
		elif session.ready(): _menu()
		return
	if menu_open or not started: return
	if session.ready():
		for pair in [[KEY_W,KEY_UP,Vector2i.UP],[KEY_S,KEY_DOWN,Vector2i.DOWN],[KEY_A,KEY_LEFT,Vector2i.LEFT],[KEY_D,KEY_RIGHT,Vector2i.RIGHT]]:
			if event.physical_keycode in [pair[0],pair[1]]:
				pending_move = pair[2]
				return
	if event.keycode in [KEY_E, KEY_SPACE, KEY_ENTER]:
		var r := session.request()
		if r.is_empty(): session.interact()
		elif r.kind in ["dialogue", "prologue", "reward", "battle_result"]: _respond()

func _respond(extra: Dictionary = {}) -> void:
	var r := session.request()
	if r.is_empty() or (r.kind == "battle_result" and world.presentation_busy()): return
	extra.token = r.token
	var result := session.respond(extra)
	if not result.ok: _error(str(result.error))

func _track_map_command(record: Dictionary) -> void:
	var command: Dictionary = record.get("command",{})
	match str(command.get("kind","")):
		"new_game", "load": _map_departure = {}
		"move":
			var direction := Vector2i(int(command.dx),int(command.dy))
			var w: Dictionary = session.state.world
			var at := Vector2i(int(w.x),int(w.y))
			if not bool(command.get("moved",false)): at += direction
			_map_departure = {"from":map_journal.current_key,"direction":ChapterSession.DIRECTIONS.find(direction),
				"trigger":[at.x,at.y],"event":int(content.cell(w.map_id,at.x,at.y).get("event",0))+40,"loaded":false}
		"interact": _map_departure = {}
		"map_loaded":
			if not _map_departure.is_empty(): _map_departure.loaded = true

func _save_snapshot() -> Dictionary:
	_observe_map()
	var saved: Dictionary = session.snapshot()
	saved["explored_world"] = map_journal.snapshot()
	return saved

func _restore_save(saved: Dictionary) -> Dictionary:
	var source := saved.duplicate(true)
	var explored: Variant = source.get("explored_world",{})
	source.erase("explored_world")
	var problem: String = session._validate_snapshot(source)
	if not problem.is_empty(): return Checks.failure(problem)
	_restoring_map = true
	var result := session.restore_snapshot(source)
	_restoring_map = false
	if not result.ok: return result
	map_journal.restore(content,explored if explored is Dictionary else {})
	if session.ready(): map_journal.observe(content,session.state,false)
	_journal_epoch = session.map_load_sequence
	return result

func _observe_map() -> void:
	if _restoring_map or session == null or session.state.is_empty() or not session.ready(): return
	var previous: String = map_journal.current_key
	var changed_region: bool = map_journal.observe(content,session.state,true,_map_departure if bool(_map_departure.get("loaded",false)) else {})
	_map_departure = {}
	if _journal_epoch != session.map_load_sequence and not previous.is_empty():
		_toast(("发现区域 · " if changed_region else "进入区域 · ")+map_journal.title_for(map_journal.current_key))
	_journal_epoch = session.map_load_sequence

func _refresh() -> void:
	if session == null or session.state.is_empty(): return
	_observe_map()
	hud.visible = started and not _ending_fullscreen()
	var map: Dictionary = content.maps.get(session.state.world.map_id,{})
	sound.ambience(int(map.get("tile_set",0)) == 8, not session.runtime().get("combat",{}).is_empty())
	field_hud.update_snapshot(session.snapshot(),not session.runtime().get("combat",{}).is_empty(),started,map_journal.title_for(map_journal.current_key) if session.ready() and not map_journal.current_key.is_empty() else content.display_scene_name(session.state))
	_refresh_notice()
	if not session.runtime().error.is_empty():
		_error(session.runtime().error)
		return
	if menu_open: return
	var r := session.request()
	if r.is_empty():
		token = ""
		_clear_overlay()
		return
	if r.kind in ["battle", "battle_result"] and world.presentation_busy():
		token = ""
		if overlay.has_node("BattleCommands"):
			_disable_buttons(overlay.get_node("BattleCommands"))
		elif not overlay.has_node("BattleWaiting"):
			_clear_overlay()
			var waiting := _panel(Rect2(32,491,1056,190))
			waiting.name = "BattleWaiting"
			_label(waiting,"行动中…",Vector2(24,26),20,Color("a8bea9"))
		return
	if str(r.token) == token: return
	token = str(r.token)
	elapsed = 0
	_clear_overlay()
	match str(r.kind):
		"dialogue", "reward", "battle_result":
			var p := _panel(Rect2(45, 474, 1030, 197))
			var portrait := int(r.get("portrait", 0))
			var speaker := str(content.actors.get("3:1:%d" % portrait, {}).get("name", "")) if portrait in [1, 2, 3] else ""
			if not speaker.is_empty():
				var name_label := _label(p, speaker, Vector2(31, 18), 21, Color("e6c786"))
				name_label.name = "DialogueSpeaker"
			var text := _rich(p, str(r.text), Rect2(32, 54 if not speaker.is_empty() else 28, 960, 92), 23)
			text.scroll_active = true
			_button(p, "继续  ›", Rect2(856, 144, 140, 36), _respond)
		"prologue":
			var p := _panel(Rect2(160, 55, 800, 610))
			var credits: bool = session.runtime().script == "1:2:18"
			_label(p, "制作名单" if credits else "序", Vector2(48, 27), 34, Color("e6c786"))
			_rich(p, str(r.text), Rect2(48, 88, 704, 424), 22)
			_button(p, "继续  ›" if credits else "二十年后  ›", Rect2(516, 538, 236, 43), _respond)
		"choice":
			var p := _panel(Rect2(360, 275, 400, 180))
			for i in range(r.choices.size()):
				_button(p, str(r.choices[i]), Rect2(28, 23 + i * 66, 344, 52), func(): _respond({"choice": i}))
		"shop": _shop(r)
		"sale": item_menu.sale(r)
		"battle": _battle(r)
		"gameover":
			var p := _panel(Rect2(320, 200, 480, 300))
			_label(p, "全剧终" if session.story_complete() else "胜败乃兵家常事", Vector2(43, 40), 28, Color("ead5ad"))
			_button(p, "读取存档", Rect2(43, 119, 394, 53), func(): _save_menu(false))
			_button(p, "重新开始", Rect2(43, 190, 394, 53), _new_game)

func _menu() -> void:
	pending_move = Vector2i.ZERO
	menu_open = true
	_clear_overlay()
	var p := _panel(Rect2(280, 100, 560, 520))
	_label(p, "行囊", Vector2(34, 24), 30, Color("e6c786"))
	_label(p, "银两  %d" % session.state.currency, Vector2(366, 32), 18, Color("c5ceb8"))
	var summaries: Array[String] = []
	for id in session.state.party:
		var actor: Dictionary = session.state.actors[id]
		summaries.append("%s · 等级 %d\n生命 %d / %d    真气 %d / %d" % [actor.name,actor.level,actor.hp,actor.max_hp,actor.mp,actor.max_mp])
	var summary := _rich(p,"\n".join(summaries),Rect2(34,82,492,120),20)
	summary.scroll_active = true
	_button(p,"人物装备",Rect2(34,216,235,48),func(): item_menu.category = "装备"; item_menu.selected = ""; _inventory())
	_button(p,"背包物品",Rect2(291,216,235,48),func(): item_menu.category = "药品"; item_menu.selected = ""; _inventory())
	_button(p,"术法",Rect2(34,280,235,48),func(): item_menu.category = "术法"; item_menu.selected = ""; _inventory())
	_button(p,"地图  M",Rect2(291,280,235,48),_open_map)
	_button(p,"声音设置",Rect2(34,344,235,48),_settings)
	_button(p,"保存",Rect2(291,344,235,48),func(): _save_menu(true))
	_button(p,"读取",Rect2(34,408,235,48),func(): _save_menu(false))
	_button(p,"返回游戏",Rect2(291,408,235,48),func(): menu_open = false; token = ""; _refresh())

func _open_map() -> void:
	if session == null or not started or not session.ready(): return
	if not content.maps.has(session.state.world.map_id): return
	_observe_map()
	pending_move = Vector2i.ZERO
	menu_open = true
	_clear_overlay()
	overlay.add_child(preload("res://src/chapter1/chapter_map_menu.gd").new(self))

func _close_map() -> void:
	pending_move = Vector2i.ZERO
	input_delay = 0.15
	menu_open = false
	token = ""
	_refresh()

func _save_menu(saving: bool) -> void:
	menu_open = true
	_clear_overlay()
	var p := _panel(Rect2(220,110,680,500))
	p.name = "SaveBrowser"
	_label(p,"保存前缘" if saving else "重续前缘",Vector2(32,24),30,Color("e6c786"))
	_label(p,"选择存档位查看旅程；快存 / 快读仍为 F5 / F9。",Vector2(32,72),17,Color("b6cabe"))
	for slot in range(1,4):
		var saved: Dictionary = saves.load_slot(slot,"fmj-chapter1-candidate",content.identity)
		var caption := "存档 %d · 空白" % slot
		if saved.ok:
			var data: Dictionary = saved.value
			var hero: Dictionary = data.actors[data.party[0]] if not data.party.is_empty() else {}
			var minutes := int(data.get("playtime_ms",0)) / 60000
			caption = "存档 %d · %s\n%s · 等级 %d · 游玩 %02d:%02d%s" % [slot,content.display_scene_name(data),hero.get("name",""),int(hero.get("level",1)),minutes/60,minutes%60," · 可恢复备份" if bool(saved.get("recovered",false)) else ""]
		elif saved.error != "not_found": caption = "存档 %d · 无法读取（原文件保留）" % slot
		var button := _button(p,caption,Rect2(32,112+(slot-1)*88,616,74),func():
			if saved.ok and (saving or started): _confirm_slot(slot,saving,caption)
			else: _execute_slot(slot,saving))
		button.add_theme_font_size_override("font_size",18)
	_button(p,"返回",Rect2(32,412,616,46),func():
		if started and session.ready(): _menu()
		else:
			menu_open = false
			token = ""
			if started: _refresh()
			else: _title())

func _confirm_slot(slot: int, saving: bool, caption: String) -> void:
	_clear_overlay()
	var p := _panel(Rect2(260,170,600,360))
	p.name = "SaveConfirm"
	p.set_meta("saving",saving)
	_label(p,"覆盖这个存档？" if saving else "读取这个存档？",Vector2(32,24),28,Color("e6c786"))
	_rich(p,caption+"\n\n"+("该槽原进度将保留为上一份备份。" if saving else "当前尚未保存的进度将被替换。"),Rect2(32,84,536,160),20)
	_button(p,"取消",Rect2(32,280,254,46),func(): _save_menu(saving))
	_button(p,"确认覆盖" if saving else "确认读取",Rect2(308,280,260,46),func(): _execute_slot(slot,saving))

func _execute_slot(slot: int, saving: bool) -> void:
	var result: Dictionary
	var recovered := false
	if saving: result = saves.save_slot(slot,_save_snapshot())
	else:
		result = saves.load_slot(slot,"fmj-chapter1-candidate",content.identity)
		recovered = bool(result.get("recovered",false))
		if result.ok: result = _restore_save(result.value)
	if result.ok:
		started = true
		menu_open = false
		token = ""
		_refresh()
		_toast("已保存至存档 %d" % slot if saving else ("已从备份恢复存档 %d" % slot if recovered else "已读取存档 %d" % slot))
	else: _toast(_save_failure_message(str(result.error)))

func _inventory() -> void:
	item_menu.inventory()

func _shop(r: Dictionary) -> void:
	item_menu.shop(r)

func _battle(_request: Dictionary) -> void:
	if session.runtime().get("combat", {}).is_empty():
		session.begin_battle()
		return
	var options := session.combat_actions()
	if options.is_empty(): return
	var battle: Dictionary = session.runtime().combat
	if battle_target not in options.enemy_targets: battle_target = int(options.enemy_targets[0])
	var p := _panel(Rect2(32, 491, 1056, 190))
	p.name = "BattleCommands"
	_label(p, "第 %d 回合" % world.battle_display_round(), Vector2(24, 14), 18, Color("a8bea9"))
	var target: Dictionary = battle.enemies[battle_target]
	_label(p, "目标  %s" % target.name, Vector2(192, 14), 18, Color("e6c786"))
	for i in range(battle.enemies.size()):
		if int(battle.enemies[i].hp) > 0:
			_button(p, str(battle.enemies[i].name), Rect2(473 + i * 177, 10, 162, 36), func(): battle_target = i; token = ""; _refresh())
	_button(p, "攻击", Rect2(24, 65, 156, 51), func(): _do_combat({"type": "attack", "target": battle_target}))
	_button(p, "术法", Rect2(196, 65, 156, 51), func(): _combat_list("magic"))
	_button(p, "道具", Rect2(368, 65, 156, 51), func(): _combat_list("item"))
	_button(p, "装备", Rect2(540, 65, 156, 51), func():
		if world.presentation_busy(): return
		item_menu.category = "装备"
		item_menu.selected = ""
		item_menu.inventory())
	_button(p, "防御", Rect2(712, 65, 156, 51), func(): _do_combat({"type": "defend"}))
	if bool(options.flee): _button(p, "逃跑", Rect2(884, 65, 148, 51), func(): _do_combat({"type": "flee"}))
	var summary := _combat_summary()
	_label(p, summary, Vector2(25, 136), 16, Color("d4dac2"))

func _do_combat(command: Dictionary) -> void:
	if world.presentation_busy(): return
	command["token"] = session.request().token
	var result := session.combat_action(command)
	if not result.ok: _toast(str(result.error))
	token = ""
	_refresh()

func _combat_list(kind: String) -> void:
	item_menu.selected = ""
	item_menu.target_slot = 0
	item_menu.battle(kind)

func _combat_summary() -> String:
	var log: Array = session.runtime().get("battle_log", [])
	var parts: Array[String] = []
	for event in log.slice(maxi(0, log.size() - 14)):
		if event.type == "vitals" and int(event.hp_delta) != 0:
			var group: Array = session.runtime().combat.get(str(event.side), [])
			if int(event.actor) < group.size():
				parts.append("%s %s%d" % [group[int(event.actor)].name, "生命 +" if int(event.hp_delta) > 0 else "受到 ", abs(int(event.hp_delta))])
		elif event.type == "miss": parts.append("攻击未命中")
	var summary := "  ·  ".join(parts.slice(maxi(0, parts.size() - 3)))
	var names := {"poison":"中毒","seal":"封魔","sleep":"睡眠","confusion":"混乱"}
	var states: Array[String] = []
	for actor in session.runtime().combat.get("party",[]):
		for status in actor.get("status",{}):
			if names.has(status): states.append("%s · %s" % [actor.name,names[status]])
	if not states.is_empty(): summary += "\n"+"  /  ".join(states)
	return summary

func _close_inventory() -> void:
	pending_move = Vector2i.ZERO
	input_delay = 0.15
	menu_open = false
	token = ""
	_refresh()

func _clear_overlay() -> void:
	for child in overlay.get_children():
		overlay.remove_child(child)
		child.queue_free()

func _panel(rect: Rect2) -> Panel:
	var p := Panel.new()
	p.position = rect.position
	p.size = rect.size
	var style := StyleBoxFlat.new()
	style.bg_color = Color("102832f5")
	style.border_color = Color("a19d75")
	style.set_border_width_all(1)
	style.set_corner_radius_all(0)
	style.shadow_color = Color(0, 0, 0, 0.45)
	style.shadow_size = 16
	p.add_theme_stylebox_override("panel", style)
	overlay.add_child(p)
	return p

func _label(parent: Control, text: String, position_: Vector2, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.position = position_
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label

func _rich(parent: Control, text: String, rect: Rect2, font_size: int) -> RichTextLabel:
	var label := RichTextLabel.new()
	label.text = text
	label.position = rect.position
	label.size = rect.size
	label.add_theme_font_size_override("normal_font_size", font_size)
	label.add_theme_color_override("default_color", Color("e7e3ce"))
	label.add_theme_constant_override("line_separation", 8)
	parent.add_child(label)
	return label

func _button(parent: Control, text: String, rect: Rect2, callback: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.position = rect.position
	b.size = rect.size
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color("263f39")
	normal.border_color = Color("74856a")
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(0)
	b.add_theme_stylebox_override("normal", normal)
	var hover := normal.duplicate()
	hover.bg_color = Color("3e5748")
	hover.border_color = Color("cabd88")
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("focus", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.add_theme_color_override("font_color", Color("ece6cc"))
	b.pressed.connect(func(): sound.play_effect("confirm"); callback.call())
	parent.add_child(b)
	return b

func _error(text: String) -> void:
	_clear_overlay()
	var p := _panel(Rect2(170, 220, 780, 280))
	_label(p, "运行检查", Vector2(32, 26), 28, Color("e7c995"))
	_rich(p, text, Rect2(32, 92, 716, 154), 20)
	push_error(text)

func _write_record(record: Dictionary) -> void:
	if log_file != null:
		log_file.store_line(JSON.stringify(record))
		log_file.flush()

func _settings() -> void:
	_clear_overlay()
	var p := _panel(Rect2(300,170,520,380))
	_label(p,"声音设置",Vector2(32,24),29,Color("e6c786"))
	var values := [float(sound.master),float(sound.music_level),float(sound.effects_level)]
	var names := ["总音量","音乐","音效"]
	for i in range(3):
		_label(p,names[i],Vector2(32,94+i*65),20,Color("d5ddcb"))
		var slider := HSlider.new()
		slider.position = Vector2(160,100+i*65)
		slider.size = Vector2(320,28)
		slider.min_value = 0
		slider.max_value = 1
		slider.step = 0.05
		slider.value = values[i]
		slider.value_changed.connect(func(value: float):
			values[i] = value
			sound.set_levels(values[0],values[1],values[2]))
		p.add_child(slider)
	_button(p,"返回",Rect2(32,305,456,42),_menu)

func _toast(text: String) -> void:
	toast_text = text
	toast_time = 3.5
	notice.text = text
	notice.visible = true

func _ending_fullscreen() -> bool:
	if session == null or session.state.is_empty() or session.runtime().get("script","") != "1:2:18": return false
	var r: Dictionary = session.request()
	return r.get("kind") == "prologue" or session.story_complete() or (r.get("kind") == "movie" and r.get("resource") in ["5:1:3","5:1:4"])

func _refresh_notice() -> void:
	if _ending_fullscreen():
		notice.visible = false
		return
	notice.visible = started or toast_time > 0
	if toast_time > 0:
		notice.text = toast_text
	elif session != null and session.chapter_three_complete():
		notice.text = "钟山事毕，已向师叔复命 · 第三章完成 · Esc 保存旅程"
	elif session != null and session.chapter_two_complete():
		notice.text = "已除蛇妖并返山复命 · 第二章完成 · Esc 保存旅程"
	elif session != null and session.chapter_complete():
		notice.text = "已取得伏魔剑并返回洞口 · 第一章完成 · Esc 保存旅程"
	else:
		notice.text = "方向键 / WASD 行走    E / 空格 交互    B 背包    M 地图    Esc 菜单与存档"

func _capture() -> void:
	await RenderingServer.frame_post_draw
	var directory := "user://chapter1-captures"
	DirAccess.make_dir_recursive_absolute(directory)
	var stamp := Time.get_datetime_string_from_system().replace(":","-")
	var path := directory.path_join(stamp+".png")
	var result := get_viewport().get_texture().get_image().save_png(path)
	if result == OK:
		_toast("画面已保存至游戏截图文件夹")
	else: _toast("截图保存失败")

func _disable_buttons(node: Node) -> void:
	if node is Button: node.disabled = true
	for child in node.get_children(): _disable_buttons(child)

func _save_failure_message(code: String) -> String:
	if code == "not_found": return "这个存档位还没有记录。"
	if "incompatible" in code or "content_hash" in code or "content_id" in code:
		return "存档与当前游戏版本不兼容，原文件已保留。"
	if "checksum" in code or "invalid_" in code or "file_too_large" in code:
		return "存档未通过检查，原文件已保留。请尝试另一个存档位。"
	return "暂时无法完成存档操作，请检查可用空间并重试。"

func _action_failure_message(code: String) -> String:
	if code == "Caster is sealed": return "封魔中，暂时无法施法。"
	if code == "Field spell not learned, insufficient MP, or caster is down": return "当前无法施法，请检查真气与生命。"
	if code == "This goods class has no field healing effect": return "此物品不能在探索时使用。"
	if code == "Invalid field item target or empty inventory": return "此物品已用尽，或当前没有合适的使用目标。"
	for i in range(code.length()):
		if code.unicode_at(i) > 127: return code
	return "当前无法使用，请检查物品用途或角色状态。"
