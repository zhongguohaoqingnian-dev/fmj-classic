extends RefCounted
## Presentation only: visited interiors stay separate in the journal and save.
var parent: Dictionary = {}
var children: Dictionary = {}

func _destinations(content: ChapterContent, key: String) -> Array[String]:
	var result: Array[String] = []
	var parts := key.split("|")
	if parts.size()!=2: return result
	var code: Array = content.scripts.get(parts[1],{}).get("instructions",[])
	for index in code.size():
		var a: Dictionary = code[index]
		if a.name == "STARTCHAPTER" and (index==0 or code[index-1].name != "LOADMAP"): return []
		if a.name != "LOADMAP": continue
		# Unknown transition patterns cannot prove a building's ownership.
		if index+1>=code.size() or code[index+1].name != "STARTCHAPTER": return []
		var b: Dictionary = code[index+1]
		var target := "2:%d:%d|1:%d:%d" % [a.args[0],a.args[1],b.args[0],b.args[1]]
		if target not in result: result.append(target)
	return result

func rebuild(content: ChapterContent, regions: Dictionary) -> void:
	parent.clear()
	children.clear()
	var cache: Dictionary = {}
	for key in regions:
		if not str(regions[key].map_id).begins_with("2:2:"): continue
		var frontier: Array[String] = [key]
		var seen: Dictionary = {}
		var outdoors: Dictionary = {}
		var auditable := true
		# Follow indoor floors as one building, including an unvisited upper floor
		# only to establish ownership. Never expose or add it to explored regions.
		while not frontier.is_empty() and auditable:
			var room: String = frontier.pop_front()
			if seen.has(room): continue
			seen[room] = true
			if not cache.has(room): cache[room] = _destinations(content,room)
			if cache[room].is_empty(): auditable=false; break
			for target in cache[room]:
				if str(target).begins_with("2:2:"):
					if not seen.has(target): frontier.append(target)
				else: outdoors[target] = true
		if not auditable or outdoors.size()!=1: continue
		var town: String = outdoors.keys()[0]
		if not regions.has(town): continue
		parent[key] = town
		if not children.has(town): children[town] = []
		children[town].append(key)
	for town in children:
		children[town].sort_custom(func(a,b):
			return int(regions[a].order)<int(regions[b].order) if regions[a].order!=regions[b].order else str(a)<str(b))

func world_key(key: String) -> String:
	return str(parent.get(key,key))

func title_for(key: String, journal: RefCounted) -> String:
	if not parent.has(key): return journal.title_for(key)
	var record: Dictionary = journal.data.regions[key]
	var count := 0
	var ordinal := 1
	for room in children[parent[key]]:
		var other: Dictionary = journal.data.regions[room]
		if other.title==record.title:
			count+=1
			if other.order<record.order: ordinal+=1
	return str(record.title)+(" · %d" % ordinal if count>1 else "")

func label(key: String, journal: RefCounted) -> String:
	var title: String = title_for(key,journal)
	return journal.title_for(parent[key])+" · "+title if parent.has(key) else title
