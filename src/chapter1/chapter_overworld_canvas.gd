extends Control
## Directed junction diagram. Audited components preserve exit directions.
signal region_selected(key: String)
signal region_opened(key: String)
const Atlas = preload("res://src/chapter1/chapter_road_atlas.gd")
const SPACING := Vector2(240,112)
const CARD := Vector2(150,64)
const DIRS := [Vector2.UP,Vector2.RIGHT,Vector2.DOWN,Vector2.LEFT]
var regions: Dictionary = {}
var edges: Array = []
var current_key := ""
var labels: Dictionary = {}
var positions: Dictionary = {}
var bounds := Rect2()
var zoom := 1.0
var fitted_zoom := 1.0
var offset := Vector2.ZERO
var dragging := false
var travel := 0.0
var journal: RefCounted
var places = preload("res://src/chapter1/chapter_map_places.gd").new()
var actual_current_key := ""
var selected_key := ""
var hovered_key := ""
var route_edges: Array = []
var group_boxes: Array = []
var label_rects: Dictionary = {}
var degrees: Dictionary = {}
var route_focus := false

func _ready() -> void:
	clip_contents = true
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_DRAG
	resized.connect(fit_map)

func show_world(content: ChapterContent, history: RefCounted) -> void:
	journal = history
	var snapshot: Dictionary = journal.snapshot()
	places.rebuild(content,snapshot.regions)
	regions.clear()
	for key in snapshot.regions:
		if not places.parent.has(key): regions[key] = snapshot.regions[key]
	edges = []
	for key in regions:
		edges.append_array(journal.exits_from(key))
	actual_current_key = journal.current_key
	current_key = places.world_key(actual_current_key)
	positions.clear()
	labels.clear()
	for key in snapshot.regions: labels[key] = places.label(key,journal)
	_layout_regions()
	degrees.clear()
	for edge in edges:
		for key in [edge.from,edge.to]: degrees[key] = int(degrees.get(key,0))+1
	selected_key = current_key
	select_region(current_key)
	fit_map()

func _layout_regions() -> void:
	# Preserve each audited four-direction grid; join connected components using
	# actual departure directions. Only disconnected networks are packed freely.
	var groups: Dictionary = {}
	var membership: Dictionary = {}
	var local: Dictionary = {}
	var ordered: Array = regions.keys()
	ordered.sort_custom(func(a,b): return int(regions[a].order)<int(regions[b].order))
	for key in ordered:
		var source: Dictionary = Atlas.region(key)
		var group: String = "component:"+str(source.component) if not source.is_empty() else "unplaced:"+key
		if not groups.has(group):groups[group]=[]
		groups[group].append(key)
		membership[key]=group
		local[key]=Vector2(source.grid[0],source.grid[1])*SPACING if not source.is_empty() else Vector2.ZERO
	var seeds: Array = groups.keys()
	seeds.sort_custom(func(a,b):return groups[a].size()>groups[b].size())
	var placed: Dictionary = {}
	var networks: Array = []
	for seed in seeds:
		if placed.has(seed):continue
		var members: Array = []
		var pending: Array = [seed]
		placed[seed]=true
		for key in groups[seed]:positions[key]=local[key];members.append(key)
		while not pending.is_empty():
			var group: String = pending.pop_front()
			for edge in edges:
				if not membership.has(edge.from) or not membership.has(edge.to):continue
				var forward: bool = membership[edge.from]==group
				if not forward and membership[edge.to]!=group:continue
				var origin: String = edge.from if forward else edge.to
				var destination: String = edge.to if forward else edge.from
				var next: String = membership[destination]
				if placed.has(next):continue
				var direction: Vector2 = DIRS[edge.direction] if edge.direction>=0 and edge.direction<4 else Vector2.RIGHT
				if not forward:direction=-direction
				var shift: Vector2 = positions[origin]+direction*SPACING-local[destination]
				# Longer straight roads retain direction when another node occupies
				# the nearest grid square. Never collapse distinct route identities.
				for distance in range(1,128):
					shift=positions[origin]+direction*SPACING*distance-local[destination]
					var collision:=false
					for key in groups[next]:
						for taken in members:
							if Rect2(local[key]+shift-CARD*0.5,CARD).grow(12).intersects(_rect(taken)):collision=true;break
						if collision:break
					if not collision:break
				for key in groups[next]:positions[key]=local[key]+shift;members.append(key)
				placed[next]=true
				pending.append(next)
		networks.append(members)
	var packed: Array[Rect2] = []
	var first:=true
	group_boxes.clear()
	for members in networks:
		var local_bounds: Rect2 = _rect(members[0])
		for key in members:local_bounds=local_bounds.merge(_rect(key))
		var group_size: Vector2 = local_bounds.size+Vector2(32,32)
		var cursor:=Vector2.ZERO
		var candidates: Array[Vector2]=[Vector2.ZERO]
		for box in packed:
			candidates.append(Vector2(box.end.x+48,box.position.y))
			candidates.append(Vector2(box.position.x,box.end.y+48))
		var best_cost:=INF
		for candidate in candidates:
			var trial:=Rect2(candidate,group_size)
			var collision:=false
			for taken in packed:
				if trial.grow(12).intersects(taken):collision=true;break
			if collision:continue
			var total: Rect2 = trial if first else bounds.merge(trial)
			var cost:=pow(maxf(total.size.x/1.6,total.size.y),2)*1.6+total.get_area()*0.1
			if cost<best_cost:best_cost=cost;cursor=candidate
		var shift:=cursor-local_bounds.position+Vector2(16,16)
		for key in members:positions[key]+=shift
		var box:=Rect2(cursor,group_size)
		group_boxes.append({"rect":box,"title":labels[members[0]],"count":members.size()})
		bounds=box if first else bounds.merge(box)
		first=false
		packed.append(box)

func select_region(key: String) -> void:
	route_focus=false
	selected_key = key
	route_edges = journal.route_to(key) if journal != null else []
	queue_redraw()

func focus_route() -> void:
	route_focus=true
	var points: Array = [current_key,selected_key]
	for edge in route_edges:
		points.append(places.world_key(edge.from))
		points.append(places.world_key(edge.to))
	var box := Rect2()
	var initial := true
	for key in points:
		if not positions.has(key): continue
		box = _rect(key) if initial else box.merge(_rect(key))
		initial = false
	if initial: return
	zoom = clampf(minf((size.x-80)/box.size.x,(size.y-100)/box.size.y),0.1,1.25)
	offset = size*0.5-box.get_center()*zoom
	queue_redraw()

func _rect(key: String) -> Rect2:
	return Rect2(positions[key]-CARD*0.5,CARD)

func fit_map() -> void:
	route_focus=false
	if regions.is_empty(): return
	fitted_zoom=minf((size.x-48.0)/bounds.size.x,(size.y-48.0)/bounds.size.y)
	zoom=clampf(fitted_zoom,0.1,1.25)
	offset=size*0.5-bounds.get_center()*zoom
	queue_redraw()

func center_player() -> void:
	if not positions.has(current_key): return
	zoom=maxf(zoom,1.0)
	offset=size*0.5-positions[current_key]*zoom
	queue_redraw()

func zoom_by(factor: float, anchor := Vector2(-1,-1)) -> void:
	if anchor.x<0: anchor=size*0.5
	var point:Vector2=(anchor-offset)/zoom
	zoom=clampf(zoom*factor,minf(fitted_zoom*0.6,0.3),2.0)
	offset=anchor-point*zoom
	_place()

func _place() -> void:
	offset.x=clampf(offset.x,48.0-bounds.end.x*zoom,size.x-48.0-bounds.position.x*zoom)
	offset.y=clampf(offset.y,48.0-bounds.end.y*zoom,size.y-48.0-bounds.position.y*zoom)
	queue_redraw()

func _hit_region(at: Vector2) -> String:
	for key in label_rects:
		if label_rects[key].has_point(at):return str(key)
	var nearest := ""
	var distance := 14.0
	for key in regions:
		if not _display_key(key):continue
		var gap: float=at.distance_to(positions[key]*zoom+offset)
		if gap<distance:nearest=key;distance=gap
	return nearest

func _get_tooltip(at: Vector2) -> String:
	for key in regions:
		if _hit_region(at)==key:
			var parts:Array[String]=[labels[key]]
			for room in places.children.get(key,[]): parts.append("室内 · "+journal.title_for(room))
			for edge in journal.exits_from(key,true):
				parts.append((["北 ↑","东 →","南 ↓","西 ←"][edge.direction] if edge.direction>=0 else "连接")+"  "+journal.title_for(edge.to))
			return "\n".join(parts)
	return "拖动浏览全部已探索区域；滚轮缩放，点选查看出口。"

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index==MOUSE_BUTTON_WHEEL_UP and event.pressed: zoom_by(1.2,event.position)
		elif event.button_index==MOUSE_BUTTON_WHEEL_DOWN and event.pressed: zoom_by(1.0/1.2,event.position)
		elif event.button_index==MOUSE_BUTTON_LEFT:
			if event.pressed:
				if event.double_click:
					for key in regions:
						if _hit_region(event.position)==key: region_opened.emit(key); return
				dragging=true
				travel=0.0
				grab_focus()
			else:
				if dragging and travel<6.0:
					var at: Vector2 = (event.position-offset)/zoom
					for key in regions:
						if _hit_region(event.position)==key:
							select_region(key)
							region_selected.emit(key)
							break
				dragging=false
		accept_event()
	elif event is InputEventMouseMotion and not dragging:
		hovered_key = ""
		for key in regions:
			if _hit_region(event.position)==key: hovered_key=key; break
		queue_redraw()
	elif event is InputEventMouseMotion and dragging:
		travel+=event.relative.length()
		offset+=event.relative
		_place()
		accept_event()
	elif event is InputEventMagnifyGesture:
		zoom_by(event.factor,event.position)
		accept_event()
	elif event is InputEventPanGesture:
		offset-=event.delta*16.0
		_place()
		accept_event()
	elif event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_EQUAL,KEY_PLUS,KEY_KP_ADD: zoom_by(1.2)
			KEY_MINUS,KEY_KP_SUBTRACT: zoom_by(1.0/1.2)
			KEY_0,KEY_HOME: fit_map()
			KEY_UP: offset.y+=36.0; _place()
			KEY_DOWN: offset.y-=36.0; _place()
			KEY_LEFT: offset.x+=36.0; _place()
			KEY_RIGHT: offset.x-=36.0; _place()
			KEY_ENTER,KEY_SPACE: if regions.has(selected_key): region_opened.emit(selected_key)
			_: return
		accept_event()

func _arrow(at: Vector2, direction: Vector2, color: Color) -> void:
	var tip:=at
	var tail:=at-direction*8.0
	var perpendicular:=direction.orthogonal()*3.8
	draw_colored_polygon(PackedVector2Array([tip,tail+perpendicular,tail-perpendicular]),color)

func _display_key(key: String) -> bool:
	if not route_focus or key in [current_key,selected_key]:return true
	for step in route_edges:
		if key in [places.world_key(step.from),places.world_key(step.to)]:return true
	return false

func _edge_on_route(edge: Dictionary) -> bool:
	for step in route_edges:
		if places.world_key(step.from)==edge.from and places.world_key(step.to)==edge.to: return true
	return false

func _node_size(key: String) -> Vector2:
	var font:=get_theme_default_font()
	var font_size:=clampi(int(30*zoom),9,18)
	var lines:PackedStringArray=str(labels[key]).replace(" · ","\n").split("\n")
	var result:=Vector2(0,lines.size()*(font_size+2)+4)
	for line in lines:result.x=maxf(result.x,font.get_string_size(line,HORIZONTAL_ALIGNMENT_LEFT,-1,font_size).x+8)
	return result

func _edge_path(edge: Dictionary) -> PackedVector2Array:
	var a: Vector2 = positions[edge.from]*zoom+offset
	var b: Vector2 = positions[edge.to]*zoom+offset
	var direction: Vector2 = DIRS[edge.direction] if edge.direction>=0 and edge.direction<4 else Vector2.RIGHT
	var delta:=b-a
	var source_size:=_node_size(edge.from)
	var target_size:=_node_size(edge.to)
	var source_radius:float=(source_size.x if absf(direction.x)>0.5 else source_size.y)*0.5+2
	var target_radius:float=(target_size.x if absf(direction.x)>0.5 else target_size.y)*0.5+2
	var start:=a+direction*source_radius
	var finish:=b-direction*target_radius
	if absf(delta.cross(direction))<0.1 and delta.dot(direction)>source_radius+target_radius:
		return PackedVector2Array([start,finish])
	var departure:=a+direction*(source_radius+maxf(12,SPACING.y*zoom*0.2))
	var approach:=b-direction*(target_radius+maxf(12,SPACING.y*zoom*0.2))
	var points: Array[Vector2]=[start,departure]
	# Orthogonal bends carry a connection around the schematic without claiming
	# that a diagonal screen segment is a different in-game exit direction.
	if absf(direction.y)>0.5:
		var lane: float=(a.x+b.x)*0.5 if absf(delta.x)>48 else maxf(a.x,b.x)+48
		points.append(Vector2(lane,departure.y));points.append(Vector2(lane,approach.y))
	else:
		var lane: float=(a.y+b.y)*0.5 if absf(delta.y)>48 else maxf(a.y,b.y)+48
		points.append(Vector2(departure.x,lane));points.append(Vector2(approach.x,lane))
	points.append(approach);points.append(finish)
	var result:=PackedVector2Array()
	for point in points:
		if result.is_empty() or point.distance_to(result[-1])>0.01:result.append(point)
	return result

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO,size),Color("101f24"))
	var font:=get_theme_default_font()
	for group in group_boxes:
		if route_focus or group.count<2: continue
		var rect: Rect2 = group.rect
		var screen := Rect2(rect.position*zoom+offset,rect.size*zoom)
		var style := StyleBoxFlat.new()
		style.bg_color=Color("182d30")
		style.border_color=Color("2b4544")
		style.set_border_width_all(1)
		style.set_corner_radius_all(24)
		draw_style_box(style,screen)
	# All connectors are roads, including edges with the legacy layout-only
	# special flag. Arrows express verified travel direction, never teleportation.
	for edge in edges:
		if not positions.has(edge.from) or not positions.has(edge.to):continue
		if route_focus and not _edge_on_route(edge):continue
		var active:=_edge_on_route(edge)
		var adjacent: bool = edge.from==selected_key or edge.to==selected_key
		var color:=Color("f2ce87") if active else (Color("87b6a3") if adjacent else Color("52746d"))
		var path:=_edge_path(edge)
		var width:=3.0 if active else 1.4
		for i in range(1,path.size()):draw_line(path[i-1],path[i],color,width,true)
		if path.size()>1:
			_arrow(path[-1],(path[-1]-path[-2]).normalized(),color)
			if active:_arrow(path[0].lerp(path[1],0.7),(path[1]-path[0]).normalized(),color)
		if active:
			var step_number:=1
			for step in route_edges:
				if places.world_key(step.from)==edge.from and places.world_key(step.to)==edge.to:break
				step_number+=1
			var departure:String=["北口","东口","南口","西口"][edge.direction] if edge.direction>=0 else "连接处"
			var text:="%d · %s"%[step_number,departure]
			var at:Vector2=path[0].lerp(path[1],0.5)
			var direction:Vector2=(path[1]-path[0]).normalized()
			at+=Vector2(48,0) if absf(direction.y)>0.5 else Vector2(0,-20)
			draw_rect(Rect2(at-Vector2(38,14),Vector2(76,28)),Color("14282b"))
			draw_string(font,at+Vector2(-30,6),text,HORIZONTAL_ALIGNMENT_LEFT,-1,16,Color("f2ce87"))
	label_rects.clear()
	var font_size:=clampi(int(30*zoom),9,18)
	var occupied: Dictionary = {}
	for key in regions:
		if not _display_key(key):continue
		var at: Vector2=positions[key]*zoom+offset
		if not Rect2(Vector2.ZERO,size).grow(40).has_point(at):continue
		var current:bool=key==current_key
		var selected:bool=key==selected_key
		var text: String=labels[key]
		var lines: PackedStringArray=text.replace(" · ","\n").split("\n")
		var label_size:=Vector2(0,lines.size()*(font_size+2)+4)
		for line in lines:label_size.x=maxf(label_size.x,font.get_string_size(line,HORIZONTAL_ALIGNMENT_LEFT,-1,font_size).x+8)
		var box:=Rect2(at-label_size*0.5,label_size)
		# Source can reuse an identical schematic position for distinct identities.
		# Keep independently selectable stacked cards at that one junction.
		var stack:int=occupied.get(at,0)
		occupied[at]=stack+1
		box.position.y+=stack*(label_size.y+3)
		label_rects[key]=box
		var color:=Color("f2ce87") if selected else (Color("a4d5b4") if current else Color("638d7d"))
		var style:=StyleBoxFlat.new()
		style.bg_color=Color("34493a") if selected else Color("132b2d")
		style.border_color=color
		style.set_border_width_all(2 if current or selected else 1)
		style.set_corner_radius_all(4)
		draw_style_box(style,box)
		for index in lines.size():
			var line_width:=font.get_string_size(lines[index],HORIZONTAL_ALIGNMENT_LEFT,-1,font_size).x
			draw_string(font,Vector2(box.get_center().x-line_width*0.5,box.position.y+2+font_size+index*(font_size+2)),lines[index],HORIZONTAL_ALIGNMENT_LEFT,-1,font_size,Color("ffe0a2") if selected else Color("dce6d5"))
		if current:
			draw_circle(box.position+Vector2(4,4),3,Color("b9f0cc"))

	draw_rect(Rect2(Vector2.ZERO,size),Color("607f77"),false,1.0)

func _label_priority(key: String) -> int:
	if key==selected_key:return 100
	if key==current_key:return 99
	if key==hovered_key:return 98
	if places.children.has(key):return 90
	if not "|r:" in key:return 80
	return int(degrees.get(key,0))
