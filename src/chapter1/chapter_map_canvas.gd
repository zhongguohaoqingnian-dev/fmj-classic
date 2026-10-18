extends Control
## Read-only map camera. Zoom and panning never send movement to the game session.
signal exit_selected(target_key: String)
var drag_distance := 0.0
var pressed_exit := -1
var picture := TextureRect.new()
var marker := Control.new()
var map_pixels := Vector2.ONE
var region := Rect2()
var player := Vector2.ZERO
var facing := 2
var zoom := 1.0
var fitted_zoom := 1.0
var offset := Vector2.ZERO
var dragging := false
var available := false
var show_player := true
var exit_markers: Array = []

func _ready() -> void:
	clip_contents = true
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_DRAG
	picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(picture)
	marker.name = "PositionMarker"
	marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	marker.draw.connect(_draw_marker)
	add_child(marker)
	resized.connect(func(): if available: fit_map())

func show_map(texture: Texture2D, mask: Texture2D, bounds: Rect2, at: Vector2, direction: int, is_current: bool = true) -> void:
	show_player = is_current
	picture.texture = texture
	map_pixels = texture.get_size()
	region = bounds
	player = at
	facing = direction
	var material_new := ShaderMaterial.new()
	material_new.shader = preload("res://src/chapter1/chapter_map_mask.gdshader")
	material_new.set_shader_parameter("visibility_mask", mask)
	picture.material = material_new
	available = true
	fit_map()

func fit_map() -> void:
	if not available: return
	fitted_zoom = minf((size.x - 72.0) / maxf(32.0,region.size.x), (size.y - 72.0) / maxf(32.0,region.size.y))
	zoom = clampf(fitted_zoom, 0.1, 3.0)
	offset = size * 0.5 - region.get_center() * zoom
	_place()

func center_player() -> void:
	if not available: return
	if not show_player:
		fit_map()
		return
	offset = size * 0.5 - player * zoom
	_place()

func zoom_by(factor: float, anchor := Vector2(-1,-1)) -> void:
	if not available: return
	if anchor.x < 0: anchor = size * 0.5
	var point := (anchor - offset) / zoom
	zoom = clampf(zoom * factor, minf(fitted_zoom * 0.6, 0.5), 4.0)
	offset = anchor - point * zoom
	_place()

func _place() -> void:
	# Keep some of the mapped area in reach while dragging; no lost map off-screen.
	var start := region.position * zoom
	var end := region.end * zoom
	offset.x = clampf(offset.x, 48.0 - end.x, size.x - 48.0 - start.x)
	offset.y = clampf(offset.y, 48.0 - end.y, size.y - 48.0 - start.y)
	picture.position = offset
	picture.size = map_pixels * zoom
	queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed: zoom_by(1.2,event.position); accept_event()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed: zoom_by(1.0/1.2,event.position); accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				dragging = true
				drag_distance = 0.0
				pressed_exit = _exit_at(event.position)
			else:
				var chosen := _exit_at(event.position)
				var clicked := dragging and drag_distance < 6.0 and chosen >= 0 and chosen == pressed_exit
				dragging = false
				pressed_exit = -1
				if clicked:
					var target := str(exit_markers[chosen].get("target_key", ""))
					if not target.is_empty(): exit_selected.emit(target)
			grab_focus()
			accept_event()
	elif event is InputEventMouseMotion and dragging:
		drag_distance += event.relative.length()
		offset += event.relative
		_place()
		accept_event()
	elif event is InputEventMagnifyGesture:
		zoom_by(event.factor,event.position)
		accept_event()
	elif event is InputEventPanGesture:
		offset -= event.delta * 16.0
		_place()
		accept_event()
	elif event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_EQUAL, KEY_PLUS, KEY_KP_ADD: zoom_by(1.2); accept_event()
			KEY_MINUS, KEY_KP_SUBTRACT: zoom_by(1.0/1.2); accept_event()
			KEY_0, KEY_HOME: fit_map(); accept_event()
			KEY_UP: offset.y += 36.0; _place(); accept_event()
			KEY_DOWN: offset.y -= 36.0; _place(); accept_event()
			KEY_LEFT: offset.x += 36.0; _place(); accept_event()
			KEY_RIGHT: offset.x -= 36.0; _place(); accept_event()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO,size),Color("7da594"),false,1.0)
	marker.queue_redraw()

# All label geometry is in screen pixels, independent of terrain zoom.
# Fan overlapping exits out with leader lines, including exits under the player.
func _exit_layout() -> Array:
	var result: Array = []
	var occupied: Array[Rect2] = []
	if show_player:
		occupied.append(Rect2(offset + player * zoom - Vector2(21,21),Vector2(42,42)))
	var viewport := Rect2(Vector2.ZERO,size)
	for index in exit_markers.size():
		var entry: Dictionary = exit_markers[index]
		var anchor: Vector2 = offset + Vector2(entry.at) * zoom
		if not viewport.grow(18).has_point(anchor): continue
		var number := str(entry.get("number",index+1))
		var extent := Vector2(maxf(34,get_theme_default_font().get_string_size(number,HORIZONTAL_ALIGNMENT_LEFT,-1,16).x+14),28)
		var chosen := Rect2()
		var found := false
		for ring in range(24):
			for y in range(-ring,ring+1):
				for x in range(-ring,ring+1):
					if maxi(absi(x),absi(y)) != ring: continue
					var center := anchor + Vector2(x*(extent.x+6),y*34)
					center = center.clamp(extent*0.5+Vector2(3,3),size-extent*0.5-Vector2(3,3))
					var candidate := Rect2(center-extent*0.5,extent)
					var clear := true
					for used in occupied:
						if used.grow(3).intersects(candidate): clear=false; break
					if clear: chosen=candidate; found=true; break
				if found: break
			if found: break
		if not found: continue
		occupied.append(chosen)
		result.append({"index":index,"rect":chosen,"anchor":anchor,"number":number})
	return result

func _exit_at(at: Vector2) -> int:
	for item in _exit_layout():
		if item.rect.has_point(at): return int(item.index)
	return -1

func _get_tooltip(at: Vector2) -> String:
	var index := _exit_at(at)
	if index < 0: return "拖动查看地形 · 滚轮缩放"
	var entry: Dictionary = exit_markers[index]
	var direction := int(entry.get("direction",-1))
	var heading: String = ["北 ↑","东 →","南 ↓","西 ←"][direction] if direction >= 0 and direction < 4 else "场景连接"
	var action := "点击查看目的地区域" if not str(entry.get("target_key","")).is_empty() else "目的地尚未探索"
	return "出口 %s · %s\n%s\n%s" % [str(entry.get("number",index+1)),str(entry.get("title","未探索区域")),heading,action]

func _draw_marker() -> void:
	if not available: return
	var font := get_theme_default_font()
	for item in _exit_layout():
		var entry: Dictionary = exit_markers[item.index]
		var color := Color("9fdbd0")
		var rect: Rect2 = item.rect
		marker.draw_line(item.anchor,rect.get_center(),color,1.5,true)
		marker.draw_circle(item.anchor,3,color)
		marker.draw_style_box(_badge_style(color),rect)
		var width := font.get_string_size(item.number,HORIZONTAL_ALIGNMENT_LEFT,-1,16).x
		marker.draw_string(font,rect.get_center()+Vector2(-width*0.5,6),item.number,HORIZONTAL_ALIGNMENT_LEFT,-1,16,color)

	if show_player:
		var at := offset + player * zoom
		marker.draw_circle(at,15.0,Color("102f33ee"))
		marker.draw_arc(at,18.0,0,TAU,48,Color("eed599"),1.5,true)
		var points := PackedVector2Array()
		for point in [Vector2(0,-12),Vector2(8,9),Vector2(0,5),Vector2(-8,9)]:
			points.append(at + point.rotated(float(facing) * PI * 0.5))
		marker.draw_colored_polygon(points,Color("ffe0a0"))

func _badge_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("102832")
	style.border_color = color
	style.set_border_width_all(2)
	style.set_corner_radius_all(5)
	return style
