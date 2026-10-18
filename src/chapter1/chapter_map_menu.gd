extends Panel
## Discovered-world atlas and read-only local map inspection.
var app: Control
var canvas: Control
var global_canvas: Control
var detail_canvas: Control
var subtitle: Label
var footer: Label
var side := Control.new()
var area_picker := OptionButton.new()
var capture: SubViewport
var map_world: ChapterWorld
var selected_key := ""
var render_ready := false
var mask_cells := PackedByteArray()
var visible_bounds := Rect2()
var global_button: Button
var region_button: Button

func _init(owner_app: Control) -> void:
	app = owner_app
	name = "MapBrowser"

func _ready() -> void:
	position = Vector2(24,20)
	size = Vector2(1072,644)
	var style := StyleBoxFlat.new()
	style.bg_color = Color("102a30")
	style.border_color = Color("bba976")
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	add_theme_stylebox_override("panel",style)
	app._label(self,"探索地图",Vector2(28,18),29,Color("f1d99e"))
	subtitle = app._label(self,"",Vector2(184,26),19,Color("d7e2cf"))
	app._button(self,"关闭  M / Esc",Rect2(856,18,188,42),app._close_map)
	global_button = app._button(self,"世界路线",Rect2(24,73,142,42),_show_global)
	region_button = app._button(self,"区域地图",Rect2(178,73,142,42),_return_here)
	app._label(self,"仅显示到访地点",Vector2(350,82),16,Color("a9c1b6"))
	global_canvas = preload("res://src/chapter1/chapter_overworld_canvas.gd").new()
	global_canvas.name = "GlobalMapCanvas"
	detail_canvas = preload("res://src/chapter1/chapter_map_canvas.gd").new()
	detail_canvas.name = "MapCanvas"
	for view in [global_canvas,detail_canvas]:
		view.position = Vector2(24,125)
		view.size = Vector2(758,450)
		add_child(view)
	global_canvas.region_selected.connect(_select_place)
	global_canvas.region_opened.connect(_show_region)
	detail_canvas.exit_selected.connect(_show_region)
	side.position = Vector2(806,125)
	side.size = Vector2(238,450)
	add_child(side)
	area_picker.position=Vector2(656,73)
	area_picker.size=Vector2(388,42)
	area_picker.add_theme_font_size_override("font_size",16)
	global_canvas.show_world(app.content,app.map_journal)
	var known: Dictionary = app.map_journal.data.regions
	var ordered: Array = known.keys()
	ordered.sort_custom(func(a,b): return int(known[a].order)<int(known[b].order) if known[a].order!=known[b].order else str(a)<str(b))
	for key in ordered:
		area_picker.add_item(global_canvas.places.label(key,app.map_journal))
		area_picker.set_item_metadata(area_picker.item_count-1,key)
	area_picker.item_selected.connect(func(index:int):
		var key := str(area_picker.get_item_metadata(index))
		if canvas==global_canvas: _select_place(key); global_canvas.focus_route()
		else: _show_region(key))
	add_child(area_picker)
	footer = app._label(self,"",Vector2(30,591),16,Color("eed599"))
	app._button(self,"−",Rect2(392,584,48,40),func(): canvas.zoom_by(1.0/1.2))
	app._button(self,"＋",Rect2(448,584,48,40),func(): canvas.zoom_by(1.2))
	app._button(self,"适应全图",Rect2(508,584,112,40),func(): canvas.fit_map())
	app._button(self,"我的位置",Rect2(636,584,146,40),_return_here)
	app._label(self,"拖动浏览 · 滚轮缩放",Vector2(808,595),16,Color("d7e2cf"))
	_show_global()

func _return_here() -> void:
	_show_region(app.map_journal.current_key)
	detail_canvas.center_player()

func _select_place(key: String) -> void:
	selected_key = key
	global_canvas.select_region(global_canvas.places.world_key(key))
	# Preserve the actual selected indoor target in route planning.
	global_canvas.route_edges = app.map_journal.route_to(key)
	_update_side(key)

func _set_tabs(global_view: bool) -> void:
	global_button.modulate = Color("fff0c8") if global_view else Color("96aaa5")
	region_button.modulate = Color("96aaa5") if global_view else Color("fff0c8")

func _show_global() -> void:
	canvas = global_canvas
	global_canvas.show()
	detail_canvas.hide()
	subtitle.text = "%d 个地点 · %d 间室内" % [global_canvas.regions.size(),global_canvas.places.parent.size()]
	footer.text = "箭头：通行方向  金色：到达路线"
	_set_tabs(true)
	if selected_key.is_empty(): selected_key=global_canvas.current_key
	_select_place(selected_key)
	global_canvas.grab_focus()
	render_ready = true

func _show_region(key: String) -> void:
	if not app.map_journal.data.regions.has(key): return
	selected_key = key
	canvas = detail_canvas
	global_canvas.hide()
	detail_canvas.show()
	subtitle.text = str(global_canvas.labels.get(key,app.map_journal.data.regions[key].title))
	footer.text = "箭头：你的位置  数字：出口" if key==app.map_journal.current_key else "到访区域 · 黑色为区域外"
	_set_tabs(false)
	detail_canvas.grab_focus()
	_update_side(key)
	_build_map()

static func region_mask(map: Dictionary, at: Vector2i) -> Dictionary:
	return preload("res://src/chapter1/chapter_map_geometry.gd").region_mask(map,at)

func _side_label(list: VBoxContainer, text: String, font_size: int = 16, color := Color("adc6b7")) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size",font_size)
	label.add_theme_color_override("font_color",color)
	label.custom_minimum_size = Vector2(216,0)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	list.add_child(label)
	return label

func _side_button(list: VBoxContainer, text: String, action: Callable) -> Button:
	var button: Button = app._button(list,text,Rect2(0,0,216,42),action)
	button.custom_minimum_size = Vector2(216,42)
	button.add_theme_font_size_override("font_size",17)
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	button.tooltip_text = text
	return button

func _update_side(key:String) -> void:
	for index in area_picker.item_count:
		if str(area_picker.get_item_metadata(index))==key: area_picker.select(index); break
	for child in side.get_children(): child.queue_free(); side.remove_child(child)
	var scroll := ScrollContainer.new()
	scroll.name = "PlaceDetailsScroll"
	scroll.size = side.size
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	side.add_child(scroll)
	var list := VBoxContainer.new()
	list.name = "PlaceDetails"
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation",9)
	scroll.add_child(list)
	_side_label(list,app.map_journal.title_for(key),23,Color("f1d99e"))
	var places: RefCounted = global_canvas.places
	var here: String = app.map_journal.current_key
	var location := "当前位置" if key==here else "已探索区域"
	if key!=here and places.world_key(here)==key: location = "你在这里 · "+app.map_journal.title_for(here)
	_side_label(list,location,15)
	_side_button(list,"打开区域地图" if canvas==global_canvas else "返回世界路线",func():
		if canvas==global_canvas: _show_region(key)
		else: _show_global())
	if places.parent.has(key):
		var parent_key: String = places.parent[key]
		_side_button(list,"所属城镇 · "+app.map_journal.title_for(parent_key),func(): _show_region(parent_key))
	var rooms: Array = places.children.get(key,[])
	var exits: Array = app.map_journal.exits_from(key,true)
	var visible_exits: Array = exits
	_side_label(list,"已记录的出口",18,Color("e4d5b1"))
	for edge_value in visible_exits:
		var edge: Dictionary = edge_value
		var direction: String = ["↑ 北口","→ 东口","↓ 南口","← 西口"][edge.direction] if edge.direction>=0 else "场景连接"
		if places.parent.get(key,"")==edge.to: direction = "出门"
		var number: int = exits.find(edge)+1
		var label: String = "%d  %s  %s" % [number,direction,app.map_journal.title_for(edge.to)]
		var button := _side_button(list,label,func(): _show_region(edge.to))
		button.disabled = not app.map_journal.data.regions.has(edge.to)
	if visible_exits.is_empty(): _side_label(list,"尚无可显示的已知出口。剧情条件可能影响通行。",15)
	var extra_rooms: Array = rooms.filter(func(room): return not exits.any(func(edge):return edge.to==room))
	if not extra_rooms.is_empty():
		_side_label(list,"已探索的房屋 · %d" % extra_rooms.size(),18,Color("e4d5b1"))
		for room_value in extra_rooms:
			var room: String = room_value
			var room_title: String = places.title_for(room,app.map_journal)
			if room==here: room_title += " · 当前位置"
			var button := _side_button(list,room_title,func(): _show_region(room))
			button.set_meta("room_key",room)
	var route: Array = app.map_journal.route_to(key)
	if key==here or places.world_key(here)==key:
		_side_label(list,"选择地点查看路线；数字出口对应区域图。",17,Color("eed599"))
	elif route.is_empty():
		_side_label(list,"尚无从当前位置到这里的导航记录。可查看出口继续探索。",17,Color("eed599"))
	else:
		_side_label(list,"从当前位置出发 · %d 次换区" % route.size(),18,Color("f1d99e"))
		_side_button(list,"在世界图上查看路线",func(): _show_global(); global_canvas.focus_route())
		for index in route.size():
			var step: Dictionary = route[index]
			var direction: String = ["北口","东口","南口","西口"][step.direction] if step.direction>=0 else "连接处"
			_side_label(list,"%d. %s → %s" % [index+1,direction,app.map_journal.title_for(step.to)],17)
		var has_unwalked := route.any(func(edge): return not bool(edge.get("observed",false)))
		if has_unwalked: _side_label(list,"包含尚未实际走过的地图连接。",16,Color("a9c1b6"))

func _build_map() -> void:
	render_ready = false
	if is_instance_valid(capture):
		remove_child(capture)
		capture.queue_free()
	var record: Dictionary = app.map_journal.data.regions[selected_key]
	var source: Dictionary = app.session.snapshot()
	source.world.map_id = record.map_id
	source.world.x = record.at[0]
	source.world.y = record.at[1]
	source.world.facing = record.facing
	source.source_runtime.script = record.script
	source.party = []
	var map: Dictionary = app.content.maps[source.world.map_id]
	var derived := ChapterSession.new(app.content)
	derived.state = source.duplicate(true)
	# Map artwork shows the terrain, never the locations of NPCs or rewards.
	derived.runtime().objects = {}
	derived.runtime().request = {}
	derived.runtime().combat = {}
	var at := Vector2i(int(source.world.x),int(source.world.y))
	var area := region_mask(map,at)
	mask_cells = area.cells
	visible_bounds = area.bounds
	capture = SubViewport.new()
	capture.name = "MapRender"
	capture.size = Vector2i(int(map.width)*32,int(map.height)*32)
	capture.disable_3d = true
	capture.gui_disable_input = true
	capture.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(capture)
	map_world = ChapterWorld.new()
	map_world.pixel_scale = 1
	map_world.session = derived
	capture.add_child(map_world)
	map_world.set_process(false)
	map_world._process(0.0)
	var mask_image := Image.create(int(map.width),int(map.height),false,Image.FORMAT_R8)
	for index in mask_cells.size():
		var entry: Dictionary = map_world._entry(map,map.cells[index])
		# The source sometimes marks roof or water artwork as walkable even
		# though its surrounding structure prevents access. Do not punch holes
		# in these exterior landmarks when filtering disconnected floor cells.
		if str(entry.get("asset","")) in ["temple_facade","water"]: mask_cells[index] = 1
		mask_image.set_pixel(index % int(map.width),index / int(map.width),Color.WHITE if mask_cells[index] != 0 else Color.BLACK)
	var exits:Array=[]
	for edge in app.map_journal.exits_from(selected_key,true):
		exits.append({"number":exits.size()+1,"target_key":str(edge.to) if app.map_journal.data.regions.has(edge.to) else "","at":Vector2(edge.trigger[0],edge.trigger[1])*32.0+Vector2(16,16),"direction":edge.direction,"title":app.map_journal.title_for(edge.to),"special":bool(edge.get("special",false))})
	canvas.exit_markers=exits
	canvas.show_map(capture.get_texture(),ImageTexture.create_from_image(mask_image),visible_bounds,Vector2(at)*32.0+Vector2(16,16),int(source.world.facing),selected_key==app.map_journal.current_key)
	render_ready = true
