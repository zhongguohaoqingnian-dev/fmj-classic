extends RefCounted
static func region_mask(map: Dictionary, at: Vector2i) -> Dictionary:
	var width := int(map.width)
	var height := int(map.height)
	var floor_cells := PackedByteArray()
	floor_cells.resize(width * height)
	var frontier: Array[Vector2i] = [at]
	floor_cells[at.y * width + at.x] = 1
	var cursor := 0
	while cursor < frontier.size():
		var p := frontier[cursor]
		cursor += 1
		for step in [Vector2i.UP,Vector2i.RIGHT,Vector2i.DOWN,Vector2i.LEFT]:
			var next: Vector2i = p + step
			if next.x < 0 or next.y < 0 or next.x >= width or next.y >= height: continue
			var index := next.y * width + next.x
			if floor_cells[index] == 0 and bool(map.cells[index].walkable):
				floor_cells[index] = 1
				frontier.append(next)
	# Keep solid scenery intact. Only disconnected floor regions are concealed.
	var visible := floor_cells.duplicate()
	for index in visible.size():
		if not bool(map.cells[index].walkable): visible[index] = 1
	var left := width
	var right := 0
	var top := height
	var bottom := 0
	for index in visible.size():
		if visible[index] == 0: continue
		left = mini(left,index % width)
		right = maxi(right,index % width)
		top = mini(top,index / width)
		bottom = maxi(bottom,index / width)
	return {"cells":visible,"bounds":Rect2(left * 32,top * 32,(right-left+1)*32,(bottom-top+1)*32)}
