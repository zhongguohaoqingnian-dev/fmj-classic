extends RefCounted
## Shared browse → inspect → act UI. Browsing never mutates the session.
const Details = preload("res://src/chapter1/chapter_item_details.gd")
const Cell = preload("res://src/chapter1/chapter_item_cell.gd")
const Icons = preload("res://src/chapter1/chapter_item_icons.gd")
const BagDrop = preload("res://src/chapter1/chapter_item_drop.gd")
const PAGE_SIZE := 20
var app: Control
var category := "装备"
var selected := ""
var accessory_slot := 0
var target_slot := 0
var actor_slot := 0
var rows: Array = []
var current_mode := ""
var detail: Control
var list: Container
var gear_rows: Array = []
var gear_buttons: Array[Button] = []
var scroll: ScrollContainer
var page := 0
var browser_token := 0
var page_label: Label
var previous_page: Button
var next_page: Button

func _init(owner_app: Control) -> void:
	app = owner_app

func inventory() -> void:
	current_mode = "inventory"
	var during_battle: bool = not app.session.runtime().get("combat", {}).is_empty()
	if during_battle: category = "装备"
	actor_slot = clampi(actor_slot,0,app.session.state.party.size()-1)
	target_slot = clampi(target_slot,0,app.session.state.party.size()-1)
	app.menu_open = true
	var p := _inventory_shell()
	for i in range(1 if during_battle else 4):
		var tab: String = ["装备", "药品", "特殊物品", "术法"][i]
		var b: Button = app._button(p, tab, Rect2(312 + i * 100, 80, 94, 38), func(): category = tab; selected = ""; page = 0; inventory())
		b.toggle_mode = true
		b.button_pressed = category == tab
	_actor_selector(p)
	rows = []
	gear_rows = []
	var actor := _actor()
	for slot in [7,5,2,3,4,6,0,1]:
		var id: String = actor.equipment_ids[slot]
		gear_rows.append({"key": "slot:%d" % slot, "id": id, "slot": slot, "worn": true,
			"label": "%s · %s" % [Details.slot_name(slot), "空位" if id.is_empty() else app.content.goods[id].name]})
	for id in app.session.state.inventory:
		if int(app.session.state.inventory[id]) <= 0: continue
		var goods: Dictionary = app.content.goods[id]
		var kind := int(goods.type)
		if (category == "装备" and kind in range(1,8)) or (category == "药品" and kind in [9,10,11]) or (category == "特殊物品" and kind in [8,12,13,14]):
			rows.append({"key": id, "id": id, "label": "%s × %d" % [goods.name, app.session.state.inventory[id]]})
	if category == "术法":
		for id in _known_spells(actor):
			var spell: Dictionary = app.content.magics[id]
			rows.append({"key": id, "id": id, "magic": true, "label": "%s · 真气 %d" % [spell.name, int(spell.get("cost_mp",0))]})
	_equipment_columns(p)
	_fill_rows()
	app._label(p,"点击查看 · 双击穿脱 · 拖动装备至装备位或背包",Vector2(312,584),16,Color("a6bdb0"))
	if during_battle:
		app._label(p,"换装不消耗行动",Vector2(418,88),18,Color("b6cabe"))
		app._button(p,"返回战斗指令",Rect2(24,580,266,40),app._close_inventory)
	else:
		app._button(p,"返回菜单",Rect2(24,580,266,40),app._menu)

func shop(request: Dictionary) -> void:
	current_mode = "shop"
	gear_rows = []
	var p := _shell(str(app.session.runtime().get("scene_name","商店")), "ShopBrowser")
	app._label(p,"选中商品查看说明，再购买。",Vector2(24,100),18,Color("b6cabe"))
	rows = []
	for id in request.goods:
		var goods: Dictionary = app.content.goods[id]
		rows.append({"key": id, "id": id, "label": "%s · %d 两" % [goods.name,goods.buy_price]})
	_fill_rows()
	app._button(p,"离开商店",Rect2(24,570,1008,40),app._respond)

func sale(_request: Dictionary) -> void:
	current_mode = "sale"
	gear_rows = []
	var p := _shell(str(app.session.runtime().get("scene_name","商店")) + " · 出售", "SaleBrowser")
	app._label(p,"选择背包物品查看售价，确认后出售 1 件。",Vector2(24,100),18,Color("b6cabe"))
	rows = []
	for id in app.session.state.inventory:
		var goods: Dictionary = app.content.goods[id]
		var quantity := int(app.session.state.inventory[id])
		if quantity <= 0 or not app.session.can_sell(id): continue
		rows.append({"key":id,"id":id,"label":"%s × %d · %d 两" % [goods.name,quantity,int(goods.sell_price)]})
	_fill_rows()
	app._button(p,"离开商店",Rect2(24,570,1008,40),app._respond)

func battle(kind: String) -> void:
	target_slot = clampi(target_slot,0,app.session.runtime().combat.party.size()-1)
	current_mode = kind
	gear_rows = []
	var p := _shell("战斗 · 术法" if kind == "magic" else "战斗 · 道具", "BattleSelection")
	app._label(p,"选择后查看效果与目标；确认才消耗行动。",Vector2(24,100),18,Color("b6cabe"))
	rows = []
	var options: Dictionary = app.session.combat_actions()
	var ids: Array = _known_spells(app.session.runtime().combat.party[int(options.actor)]) if kind == "magic" else app.session.state.inventory.keys()
	for id in ids:
		var definition: Dictionary = app.content.magics[id] if kind == "magic" else app.content.goods[id]
		if kind != "magic" and (int(app.session.state.inventory[id]) <= 0 or int(definition.type) not in [7,8,9,10,11,12]): continue
		rows.append({"key": id, "id": id, "magic": kind == "magic", "label": "%s · %s" % [definition.name, "真气 %d" % int(definition.get("cost_mp",0)) if kind == "magic" else "× %d" % int(app.session.state.inventory[id])]})
	_fill_rows()
	app._button(p,"返回战斗指令",Rect2(24,570,1008,40),func(): app.token = ""; app._refresh())

func _shell(title: String, node_name: String) -> Panel:
	app._clear_overlay()
	gear_buttons.clear()
	var p: Panel = app._panel(Rect2(32,32,1056,626))
	p.name = node_name
	app._label(p,title,Vector2(24,18),28,Color("e6c786"))
	var actor := _actor()
	app._label(p,"%s · 等级 %d   银两 %d" % [actor.name,actor.level,app.session.state.currency],Vector2(265,24),18,Color("c4cbb7"))
	app._label(p,"生命  %d / %d   真气  %d / %d" % [actor.hp,actor.max_hp,actor.mp,actor.max_mp],Vector2(660,24),18,Color("c4dbb2"))
	app._label(p,"攻击 %d   防御 %d   身法 %d   灵力 %d   吉运 %d" % [actor.attack,actor.defense,actor.speed,actor.lingli,actor.get("luck",0)],Vector2(24,62),18,Color("b6cabe"))
	scroll = ScrollContainer.new()
	scroll.follow_focus = true
	scroll.position = Vector2(24,148)
	scroll.size = Vector2(376,400)
	p.add_child(scroll)
	list = VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation",6)
	scroll.add_child(list)
	detail = Control.new()
	detail.position = Vector2(424,148)
	detail.size = Vector2(608,400)
	p.add_child(detail)
	return p

func _inventory_shell() -> Panel:
	app._clear_overlay()
	app.pending_move = Vector2i.ZERO
	gear_buttons.clear()
	var p: Panel = app._panel(Rect2(24,20,1072,644))
	p.name = "InventoryBrowser"
	browser_token = p.get_instance_id()
	var backdrop: StyleBoxFlat = p.get_theme_stylebox("panel").duplicate()
	backdrop.bg_color = Color("122c32")
	p.add_theme_stylebox_override("panel",backdrop)
	app._label(p,"行 囊",Vector2(24,18),28,Color("e6c786"))
	app._label(p,"银两  %d" % int(app.session.state.currency),Vector2(738,26),19,Color("e6c786"))
	app._button(p,"关闭  B",Rect2(932,18,112,38),app._close_inventory)
	_section(p,Rect2(16,72,282,486))
	_section(p,Rect2(304,128,410,430))
	_section(p,Rect2(724,72,332,486))
	app._label(p,"物品详情",Vector2(740,90),20,Color("e6c786"))
	scroll = BagDrop.new()
	scroll.name = "BagGrid"
	scroll.position = Vector2(314,140)
	scroll.size = Vector2(390,344)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	scroll.accept_drop = _can_drop
	scroll.apply_drop = func(data: Variant, slot: int): _drop.call_deferred(data,slot)
	p.add_child(scroll)
	list = GridContainer.new()
	list.columns = 5
	list.add_theme_constant_override("h_separation",6)
	list.add_theme_constant_override("v_separation",6)
	scroll.add_child(list)
	detail = Control.new()
	detail.position = Vector2(740,130)
	detail.size = Vector2(300,414)
	p.add_child(detail)
	previous_page = app._button(p,"上一页",Rect2(316,508,86,34),func(): _change_page(-1))
	previous_page.name = "PreviousPage"
	next_page = app._button(p,"下一页",Rect2(610,508,86,34),func(): _change_page(1))
	next_page.name = "NextPage"
	page_label = app._label(p,"",Vector2(408,514),16,Color("d6d5b9"))
	page_label.size.x = 196
	page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return p

func _equipment_columns(p: Panel) -> void:
	var actor := _actor()
	app._label(p,"%s  ·  等级 %d" % [actor.name,actor.level],Vector2(32,132),19,Color("e6c786"))
	var portrait := TextureRect.new()
	portrait.name = "EquipmentPortrait"
	portrait.position = Vector2(100,220)
	portrait.size = Vector2(114,172)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	portrait.texture = load("res://assets/chapter3/native/yuan_south_1.png" if str(actor.id) == "3:1:3" else "res://assets/chapter2/native/xiaomei_south_0.png" if str(actor.id) == "3:1:2" else "res://assets/chapter1/native/hero_south_0.png")
	p.add_child(portrait)
	for i in range(gear_rows.size()):
		var row: Dictionary = gear_rows[i]
		var b := _card(row,Vector2(64,66))
		b.name = "EquipmentSlot%d" % int(row.slot)
		b.position = Vector2(28 if i < 4 else 220,166+(i%4)*72)
		p.add_child(b)
		gear_buttons.append(b)
	var bars: Array = [["生命",actor.hp,actor.max_hp,"739e79"],["真气",actor.mp,actor.max_mp,"618dba"]]
	for i in bars.size():
		var values: Array = bars[i]
		var bar := ProgressBar.new()
		bar.position = Vector2(30,464+i*26)
		bar.size = Vector2(254,20)
		bar.max_value = maxi(1,int(values[2]))
		bar.value = int(values[1])
		bar.show_percentage = false
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var track := StyleBoxFlat.new()
		track.bg_color = Color("10292a")
		var fill := StyleBoxFlat.new()
		fill.bg_color = Color(values[3])
		bar.add_theme_stylebox_override("background",track)
		bar.add_theme_stylebox_override("fill",fill)
		p.add_child(bar)
		var label: Label = app._label(p,"%s  %d / %d" % [values[0],values[1],values[2]],Vector2(34,463+i*26),14,Color("f1e9ce"))
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	app._label(p,"攻击 %d   防御 %d   身法 %d" % [actor.attack,actor.defense,actor.speed],Vector2(30,518),15,Color("d4d7be"))
	app._label(p,"灵力 %d   吉运 %d" % [actor.lingli,actor.get("luck",0)],Vector2(30,538),15,Color("a8c4b2"))

func _card(row: Dictionary, dimensions: Vector2) -> Button:
	var b := Cell.new()
	b.entry = row
	b.owner_token = browser_token
	b.activate = _activate_card
	b.accept_drop = _can_drop
	b.apply_drop = func(data: Variant, slot: int): _drop.call_deferred(data,slot)
	b.custom_minimum_size = dimensions
	b.size = dimensions
	b.toggle_mode = true
	b.set_meta("entry_key",row.key)
	b.tooltip_text = row.label
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color("203b3b")
	normal.border_color = Color("4b6e62")
	normal.set_border_width_all(1)
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = Color("304b44")
	hover.border_color = Color("d9ba7c")
	var pressed: StyleBoxFlat = hover.duplicate()
	pressed.set_border_width_all(2)
	b.add_theme_stylebox_override("normal",normal)
	b.add_theme_stylebox_override("hover",hover)
	b.add_theme_stylebox_override("pressed",pressed)
	b.add_theme_stylebox_override("hover_pressed",pressed)
	b.add_theme_stylebox_override("focus",pressed)
	var id := str(row.id)
	var worn := bool(row.get("worn",false))
	var magic := bool(row.get("magic",false))
	var definition: Dictionary = (app.content.magics[id] if magic else app.content.goods[id]) if not id.is_empty() else {}
	var kind := int(definition.get("type",{7:1,5:2,3:3,6:4,2:5,0:6,1:6,4:7}.get(int(row.get("slot",-1)),0)))
	b.icon_texture = Icons.texture(kind,magic,str(definition.get("name","")))
	var icon := TextureRect.new()
	icon.texture = b.icon_texture
	icon.position = Vector2((dimensions.x-40)/2,6)
	icon.size = Vector2(40,40)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if id.is_empty(): icon.modulate = Color(1,1,1,0.23)
	b.add_child(icon)
	var label := Label.new()
	label.text = Details.slot_name(int(row.slot)) if worn else str(definition.get("name",""))
	label.position = Vector2(3,dimensions.y-23)
	label.size = Vector2(dimensions.x-6,20)
	label.add_theme_font_size_override("font_size",13 if worn else 14)
	label.add_theme_color_override("font_color",Color("dcd9bf"))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(label)
	if not worn and not magic:
		var quantity: Label = app._label(b,str(int(app.session.state.inventory.get(id,0))),Vector2(dimensions.x-27,1),13,Color("f5e4b6"))
		quantity.size.x = 22
		quantity.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		quantity.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.pressed.connect(func(): _select_card(row))
	b.focus_entered.connect(func():
		if selected != row.key: _select_card(row))
	return b

func _select_card(row: Dictionary) -> void:
	selected = row.key
	if bool(row.get("worn",false)) and int(row.slot) in [0,1]: accessory_slot = int(row.slot)
	_update_selection()
	_show_detail(row)

func _activate_card(row: Dictionary) -> void:
	_select_card(row)
	# Medicines and magic retain explicit target/confirmation; double-click only wears gear.
	if bool(row.get("magic",false)) or str(row.id).is_empty(): return
	if int(app.content.goods[row.id].type) not in range(1,8): return
	var action := detail.get_node_or_null("ItemAction") as Button
	if action != null and not action.disabled: action.pressed.emit()

func _can_drop(data: Variant, slot: int) -> bool:
	if not data is Dictionary or int(data.get("inventory_owner",0)) != browser_token: return false
	if not app.overlay.has_node("InventoryBrowser") or app.overlay.get_node("InventoryBrowser").get_instance_id() != browser_token: return false
	var row: Dictionary = data.get("entry",{})
	var id := str(row.get("id",""))
	if id.is_empty() or not app.content.goods.has(id) or int(app.content.goods[id].type) not in range(1,8): return false
	if bool(row.get("worn",false)):
		return slot == -1 and str(_actor().equipment_ids[int(row.slot)]) == id and bool(Details.equipment_preview(app.content,_actor(),app.session.state.inventory,"",int(row.slot)).ok)
	return slot >= 0 and bool(Details.equipment_preview(app.content,_actor(),app.session.state.inventory,id,slot).ok)

func _drop(data: Variant, slot: int) -> void:
	if not _can_drop(data,slot): return
	var row: Dictionary = data.entry
	var removing := bool(row.get("worn",false))
	var actual_slot := int(row.slot) if removing else slot
	var result: Dictionary = app.session.equip("" if removing else str(row.id),actual_slot,actor_slot)
	if result.ok:
		selected = str(row.id) if removing else "slot:%d" % actual_slot
		app._toast(("已卸下 " if removing else "已装备 ")+str(app.content.goods[row.id].name))
		inventory()
	else: app._toast(app._action_failure_message(str(result.error)))

func _change_page(delta: int) -> void:
	var target := clampi(page+delta,0,maxi(0,ceili(float(rows.size())/PAGE_SIZE)-1))
	if target == page: return
	page = target
	selected = str(rows[page*PAGE_SIZE].key)
	inventory()

func _section(parent: Control, rect: Rect2) -> void:
	var background := Panel.new()
	background.position = rect.position
	background.size = rect.size
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color("183b3c")
	style.border_color = Color("3b6460")
	style.set_border_width_all(1)
	background.add_theme_stylebox_override("panel",style)
	parent.add_child(background)
	parent.move_child(background,0)

func _update_selection() -> void:
	for child in list.get_children() + gear_buttons:
		if child is Button and child.has_meta("entry_key"): child.set_pressed_no_signal(child.get_meta("entry_key") == selected)

func _fill_rows() -> void:
	var found := false
	for row in rows + gear_rows:
		if row.key == selected: found = true
	if not found: selected = str(rows[0].key) if not rows.is_empty() else str(gear_rows[0].key) if not gear_rows.is_empty() else ""
	if current_mode == "inventory":
		page = clampi(page,0,maxi(0,ceili(float(rows.size())/PAGE_SIZE)-1))
		for i in rows.size():
			if rows[i].key == selected: page = i / PAGE_SIZE
		for i in PAGE_SIZE:
			var index := page*PAGE_SIZE+i
			if index < rows.size():
				var row: Dictionary = rows[index]
				var b := _card(row,Vector2(72,80))
				b.name = "Entry%d" % index
				list.add_child(b)
				if row.key == selected: _show_detail(row)
			else:
				var blank := Panel.new()
				blank.custom_minimum_size = Vector2(72,80)
				blank.mouse_filter = Control.MOUSE_FILTER_IGNORE
				var style := StyleBoxFlat.new()
				style.bg_color = Color("173334")
				style.border_color = Color("2b4c47")
				style.set_border_width_all(1)
				blank.add_theme_stylebox_override("panel",style)
				list.add_child(blank)
		page_label.text = "%d / %d 页 · %d 种" % [page+1,maxi(1,ceili(float(rows.size())/PAGE_SIZE)),rows.size()]
		previous_page.disabled = page == 0
		next_page.disabled = (page+1)*PAGE_SIZE >= rows.size()
		_update_selection()
		for row in gear_rows:
			if row.key == selected: _show_detail(row)
		if rows.is_empty(): app._label(scroll.get_parent(),"此分类暂无物品",Vector2(436,486),15,Color("a8bcb0"))
		return
	for row in rows:
		var b := Button.new()
		b.text = row.label
		b.name = "Entry%d" % list.get_child_count()
		b.set_meta("entry_key",row.key)
		b.custom_minimum_size = Vector2(scroll.size.x - 24,48)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		b.toggle_mode = true
		b.button_pressed = row.key == selected
		b.pressed.connect(func():
			selected = row.key
			_update_selection()
			_show_detail(row))
		b.focus_entered.connect(func():
			if selected != row.key:
				selected = row.key
				_update_selection()
				_show_detail(row))
		list.add_child(b)
		if row.key == selected:
			_show_detail(row)
			scroll.call_deferred("ensure_control_visible",b)
	_update_selection()
	for row in gear_rows:
		if row.key == selected: _show_detail(row)
	if rows.is_empty() and gear_rows.is_empty(): app._label(detail,"这个分类暂无物品。",Vector2(0,0),21,Color("c4cbb7"))

func _show_detail(row: Dictionary) -> void:
	for child in detail.get_children():
		detail.remove_child(child)
		child.queue_free()
	var id := str(row.id)
	if id.is_empty():
		app._rich(detail,"%s · 空位\n\n在背包格子里选择装备，查看替换效果。" % Details.slot_name(int(row.slot)),Rect2(0,0,detail.size.x,250),21)
		return
	var magic := bool(row.get("magic",false))
	var definition: Dictionary = app.content.magics[id] if magic else app.content.goods[id]
	var kind := int(definition.type)
	var text: String = Details.magic_text(definition) if magic else Details.goods_text(definition)
	if not magic:
		text += "\n\n行囊数量：%d" % int(app.session.state.inventory.get(id,0))
		if kind in range(1,8): text += "\n" + Details.usable_actors_text(app.content,definition)
	var action := ""
	var enabled := true
	var reason := ""
	var invoke := Callable()
	if current_mode == "inventory" and not magic and kind in range(1,8):
		var removing := bool(row.get("worn",false))
		var slot := int(row.slot) if removing else (accessory_slot if kind == 6 else -1)
		var preview: Dictionary = Details.equipment_preview(app.content,_actor(),app.session.state.inventory,"" if removing else id,slot)
		text = ("卸下预览" if removing else "替换预览") + "\n" + str(preview.get("text","")) + "\n\n物品说明\n" + text
		enabled = bool(preview.ok)
		if not enabled: reason = app._action_failure_message(str(preview.get("error","")))
		if kind == 6 and not removing:
			for i in range(2):
				var choice: Button = app._button(detail,"佩饰 %d%s" % [i+1," · 已选" if accessory_slot == i else ""],Rect2(i*(detail.size.x+8)/2,290,(detail.size.x-8)/2,34),func(): accessory_slot = i; _show_detail(row))
				choice.toggle_mode = true
				choice.button_pressed = accessory_slot == i
		action = "卸下装备" if removing else "装备到此位置"
		invoke = func():
			var result: Dictionary = app.session.equip("" if removing else id,slot,actor_slot)
			app._toast(("已卸下 " if removing else "已装备 ")+str(definition.name) if result.ok else app._action_failure_message(str(result.error)))
			inventory()
	elif current_mode == "inventory" and not magic and kind == 13:
		enabled = app.content.event_address(app.session.runtime().script,255) > 0
		action = "使用"+str(definition.name)
		reason = "" if enabled else "此处无法使用该道具。"
		text += "\n\n可从设有归途的迷宫离开。" if enabled else "\n\n此处无法使用。"
		invoke = func():
			var result: Dictionary = app.session.field_use(id)
			if result.ok: app._close_inventory()
			else: app._toast(app._action_failure_message(str(result.error)))
	elif current_mode == "inventory":
		var field_allowed := kind in [3,4] if magic else kind in [9,10,11]
		action = "施展术法" if magic else "使用 1 件"
		if field_allowed:
			var preview := _field_preview(id,magic)
			enabled = bool(preview.ok)
			reason = str(preview.reason)
			text += ("\n\n施法者："+str(_actor().name) if magic else "") + "\n\n"+str(preview.text)
			invoke = func():
				var before := _party().duplicate(true)
				var result: Dictionary = app.session.field_magic(id,target_slot,actor_slot) if magic else app.session.field_use(id,target_slot)
				app._toast(str(definition.name)+"："+_vital_changes(before,_party()) if result.ok else app._action_failure_message(str(result.error)))
				inventory()
			_targets(row,false)
		else:
			enabled = false
			reason = "剧情物品由剧情使用，可在这里查看说明。" if kind == 14 else "此物品有特殊用途，探索时不能直接使用。" if kind == 13 else "战斗中使用；进入战斗后在指令菜单选择。"
	elif current_mode == "sale":
		var price := int(definition.sell_price)
		var after := mini(99999,int(app.session.state.currency)+price)
		text += "\n\n出售数量：1 件\n单价：%d 两\n出售后持有：%d 件\n出售后银两：%d → %d" % [price,int(app.session.state.inventory.get(id,0))-1,int(app.session.state.currency),after]
		if after-int(app.session.state.currency) < price: text += "\n银两上限 99999，多出部分无法获得。"
		if kind == 14: text = "此卡与支线交换有关，出售会失去卡片。\n\n" + text
		enabled = int(app.session.state.inventory.get(id,0)) > 0 and app.session.can_sell(id)
		action = "确认出售 1 件 · %d 两" % price
		invoke = func():
			var result: Dictionary = app.session.shop_sell(id,1)
			app._toast("已出售 %s × 1，银两 %d" % [definition.name,app.session.state.currency] if result.ok else app._action_failure_message(str(result.error)))
			sale(app.session.request())

	elif current_mode == "shop":
		var price := int(definition.buy_price)
		text += "\n\n单价：%d 两" % price
		if int(app.session.state.currency) >= price: text += "\n购买后银两：%d" % (int(app.session.state.currency)-price)
		enabled = int(app.session.state.currency) >= price and int(app.session.state.inventory.get(id,0)) < 99
		reason = "银两不足。" if int(app.session.state.currency) < price else "已达持有上限 99 件。" if not enabled else ""
		action = "购买 1 件 · %d 两" % price
		invoke = func():
			var result: Dictionary = app.session.shop_buy(id)
			app._toast("已购买 %s × 1，花费 %d 两" % [definition.name,price] if result.ok else app._action_failure_message(str(result.error)))
			shop(app.session.request())
	else:
		var options: Dictionary = app.session.combat_actions()
		var help := kind in [2,3,4] if magic else kind in [9,10,11,12]
		var actor: Dictionary = app.session.runtime().combat.party[int(options.actor)]
		enabled = id in options.magic_ids if magic else id in options.goods_ids
		if magic and not enabled: reason = "封魔中，无法施法。" if actor.status.has("seal") else "真气不足。"
		elif not magic and not enabled: reason = "本轮剩余物品已由其他队员选用。"
		var target: Dictionary = app.session.runtime().combat.party[target_slot] if help else app.session.runtime().combat.enemies[app.battle_target]
		text += "\n\n当前目标：%s · 生命 %d / %d" % [target.name,target.hp,target.max_hp]
		if magic: text += "\n施法者真气：%d / %d" % [actor.mp,actor.max_mp]
		if not magic and kind == 7: text += "\n投掷会消耗行囊中的这件武器。"
		action = "确认施法" if magic else "确认使用" if help else "确认投掷"
		invoke = func():
			var command := {"type":"magic" if magic else "item" if help else "throw","target":target_slot if help else app.battle_target}
			command["magic_id" if magic else "goods_id"] = id
			app._do_combat(command)
		_targets(row,not help)
	var is_grid := current_mode == "inventory"
	if is_grid:
		var icon := TextureRect.new()
		icon.texture = Icons.texture(kind,magic,str(definition.get("name","")))
		icon.position = Vector2(0,0)
		icon.size = Vector2(48,48)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		detail.add_child(icon)
		app._label(detail,str(definition.name),Vector2(60,0),22,Color("e8cd94"))
		app._label(detail,"术法" if magic else Details.goods_kind_name(definition),Vector2(60,30),15,Color("9fb9ab"))
	var body: RichTextLabel = app._rich(detail,("" if is_grid else str(definition.name)+"\n\n")+text,Rect2(0,62 if is_grid else 0,detail.size.x,216 if is_grid else 278),17 if is_grid else 20)
	body.name = "ItemDetails"
	body.scroll_active = true
	if is_grid: body.add_theme_constant_override("line_separation",4)
	var explanation: RichTextLabel = app._rich(detail,reason,Rect2(0,326,detail.size.x,46),16)
	explanation.name = "ActionReason"
	if is_grid:
		explanation.add_theme_constant_override("line_separation",2)
		explanation.add_theme_font_size_override("normal_font_size",15)
	var button: Button = app._button(detail,action,Rect2(0,376,detail.size.x,40),func(): if invoke.is_valid(): invoke.call())
	button.name = "ItemAction"
	button.disabled = not enabled

func _targets(row: Dictionary, enemies: bool) -> void:
	var party: Array = app.session.runtime().combat.enemies if enemies else (_party() if current_mode == "inventory" else app.session.runtime().combat.party)
	if party.size() <= 1: return
	var width := (detail.size.x - 8 * (party.size()-1)) / party.size()
	for i in range(party.size()):
		if enemies and int(party[i].hp) <= 0: continue
		var chosen: bool = (app.battle_target if enemies else target_slot) == i
		var b: Button = app._button(detail,("目标 · " if chosen else "")+str(party[i].name),Rect2(i*(width+8),290,width,34),func():
			if enemies: app.battle_target = i
			else: target_slot = i
			_show_detail(row))
		b.name = "Target%d" % i
		b.toggle_mode = true
		b.button_pressed = chosen
		b.add_theme_font_size_override("font_size",16)
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS

func _actor_selector(p: Panel) -> void:
	if app.session.state.party.size() <= 1:
		app._label(p,"身上装备",Vector2(30,94),20,Color("e6c786"))
		return
	var choice := OptionButton.new()
	choice.name = "PartyActor"
	choice.position = Vector2(30,82)
	choice.size = Vector2(254,32)
	choice.add_theme_font_size_override("font_size",18)
	choice.get_popup().add_theme_font_size_override("font_size",18)
	for actor in _party(): choice.add_item(str(actor.name))
	choice.select(actor_slot)
	choice.item_selected.connect(func(index: int):
		actor_slot = index
		selected = ""
		inventory())
	p.add_child(choice)

func _actor() -> Dictionary:
	if current_mode in ["magic","item"]: return app.session.runtime().combat.party[int(app.session.combat_actions().actor)]
	return app.session.state.actors[app.session.state.party[clampi(actor_slot,0,app.session.state.party.size()-1)]]

func _party() -> Array:
	var party: Array = []
	for id in app.session.state.party: party.append(app.session.state.actors[id])
	return party

func _known_spells(actor: Dictionary) -> Array:
	var driver = preload("res://src/chapter1/chapter_combat.gd").new()
	driver.configure({"magic_chains_by_id":app.content.data.magic_chains_by_id})
	return driver._known_magics(actor)

func _field_preview(id: String, magic: bool) -> Dictionary:
	var driver = preload("res://src/chapter1/chapter_combat.gd").new()
	driver.configure(app.content.data)
	var party := _party()
	target_slot = clampi(target_slot,0,party.size()-1)
	var result: Dictionary = driver.use_field_magic(party,actor_slot,id,target_slot) if magic else driver.use_field_item(party,app.session.state.inventory,id,target_slot)
	if not result.ok: return {"ok":false,"reason":app._action_failure_message(str(result.error)),"text":"当前目标："+str(party[target_slot].name)}
	var text := _vital_changes(party,result.party)
	var effective := false
	for i in range(party.size()):
		for key in ["hp","max_hp","max_mp","attack","defense","speed","lingli","luck","status"] + ([] if magic else ["mp"]):
			if party[i].get(key,{} if key == "status" else 0) != result.party[i].get(key,{} if key == "status" else 0): effective = true
	return {"ok":effective,"reason":"" if effective else "当前目标无需此效果，未消耗物品或真气。","text":"使用预览 · "+str(party[target_slot].name)+"\n"+text}

func _vital_changes(before: Array, after: Array) -> String:
	var changes: Array[String] = []
	for i in range(before.size()):
		for pair in [["hp","生命"],["mp","真气"],["max_hp","生命上限"],["max_mp","真气上限"],["attack","攻击"],["defense","防御"],["speed","身法"],["lingli","灵力"],["luck","吉运"]]:
			if int(before[i].get(pair[0],0)) != int(after[i].get(pair[0],0)): changes.append("%s%s %d → %d" % [(str(before[i].name)+" · ") if before.size() > 1 else "",pair[1],before[i].get(pair[0],0),after[i].get(pair[0],0)])
		for status in before[i].get("status",{}):
			if not after[i].get("status",{}).has(status): changes.append("解除"+str({"poison":"中毒","seal":"封魔","sleep":"睡眠","confusion":"混乱"}.get(status,status)))
	return "；".join(changes) if not changes.is_empty() else "当前状态无需恢复。"
