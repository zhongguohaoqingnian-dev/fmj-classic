class_name ChapterMapJournal
extends RefCounted
## Exploration is saved per slot; source topology supplies directions, never visits.
const Atlas = preload("res://src/chapter1/chapter_road_atlas.gd")
const MAX_REGIONS := 2048
const MAX_EDGES := 8192
var data: Dictionary = {"version":2,"regions":{},"edges":[]}
var current_key := ""
# Ephemeral current-state knowledge; never grants a visit or rewrites history.
var current_flags: Dictionary = {}
var migrated_uncertain := 0

func clear() -> void:
	data = {"version":2,"regions":{},"edges":[]}
	current_key = ""
	current_flags.clear()
	migrated_uncertain = 0

func snapshot() -> Dictionary:
	return data.duplicate(true)

func title_for(key: String) -> String:
	if not data.regions.has(key): return "未探索区域"
	var title: String = data.regions[key].title
	var count := 0
	var ordinal := 1
	for candidate in data.regions:
		if data.regions[candidate].title==title:
			count+=1
			if int(data.regions[candidate].order)<int(data.regions[key].order): ordinal+=1
	return title+(" · %d" % ordinal if count>1 else "")

func observe(content: ChapterContent, state: Dictionary, connect_previous: bool = true, departure: Dictionary = {}) -> bool:
	var key := Atlas.resolve(content,state)
	if key.is_empty() or not _at_valid(content.maps[state.world.map_id],[state.world.get("x"),state.world.get("y")]): return false
	if not _integer(state.world.get("facing"),0,3): return false
	var added: bool = not data.regions.has(key)
	if added:
		if data.regions.size()>=MAX_REGIONS: return false
		var order := 1
		for known in data.regions.values(): order=maxi(order,int(known.order)+1)
		data.regions[key]={"key":key,"map_id":state.world.map_id,"script":state.source_runtime.script,
			"title":content.display_scene_name(state),"at":[int(state.world.x),int(state.world.y)],"facing":int(state.world.facing),"order":order}
	else:
		data.regions[key].at=[int(state.world.x),int(state.world.y)]
		data.regions[key].facing=int(state.world.facing)
		data.regions[key].title=content.display_scene_name(state)
	if connect_previous and not departure.is_empty() and departure.get("from","")!=key and data.regions.has(departure.get("from","")):
		var edge := {"from":str(departure.from),"to":key,"direction":int(departure.get("direction",-1)),
			"event":int(departure.get("event",0)),"trigger":departure.get("trigger",[]).duplicate(),
			"landing":[int(state.world.x),int(state.world.y)],"special":true,"observed":true}
		for source in Atlas.exits_from(edge.from):
			if source.to==key and source.direction==edge.direction and source.event==edge.event: edge.special=source.special; break
		_add_edge(edge)
	current_key=key
	current_flags=state.get("flags",{}).duplicate(true)
	if added: _known_source_links()
	return added

func exits_from(key: String, include_unknown: bool = false) -> Array:
	var result: Array=[]
	var seen: Dictionary={}
	var choices: Array=data.edges.duplicate(true)
	var source_exits := Atlas.exits_from(key)
	choices.append_array(source_exits)
	for edge in choices:
		if edge.from!=key or (not include_unknown and not data.regions.has(edge.to)): continue
		var guard: Dictionary = edge
		for source in source_exits:
			if source.get("current_origin_only",false) and source.to==edge.to and source.event==edge.event and source.direction==edge.direction:
				guard=source; break
		if bool(guard.get("current_origin_only",false)):
			if key != current_key: continue
			var blocked := false
			for flag in guard.get("requires_clear_flags",[]):
				if bool(current_flags.get(str(int(flag)),false)): blocked=true; break
			if blocked: continue
		if bool(edge.get("requires_observation", false)) and not bool(edge.get("observed", false)): continue
		var identity := "%s:%d:%d" % [edge.to,int(edge.direction),int(edge.get("event",0))]
		if seen.has(identity): continue
		seen[identity]=true
		result.append(edge.duplicate(true))
	result.sort_custom(func(a:Dictionary,b:Dictionary): return int(a.direction)<int(b.direction))
	return result

func route_to(target: String) -> Array:
	if not data.regions.has(current_key) or not data.regions.has(target): return []
	var frontier: Array[String]=[current_key]
	var previous: Dictionary={current_key:{}}
	var cursor:=0
	while cursor<frontier.size():
		var key:=frontier[cursor]; cursor+=1
		if key==target: break
		for edge in exits_from(key):
			if previous.has(edge.to): continue
			previous[edge.to]=edge
			frontier.append(str(edge.to))
	if not previous.has(target): return []
	var result:Array=[]
	var key:=target
	while key!=current_key:
		var edge:Dictionary=previous[key]
		result.push_front(edge.duplicate(true))
		key=edge.from
	return result

func restore(content: ChapterContent, value: Dictionary) -> void:
	clear()
	if value.get("version")==1:
		_restore_legacy(content,value)
	elif value.get("version")==2 and value.get("regions") is Dictionary and value.get("edges") is Array:
		for key in value.regions:
			var row:Variant=value.regions[key]
			if row is Dictionary and Atlas.ambiguous_merged_base(str(row.get("map_id", "")), str(row.get("script", "")), str(key)):
				migrated_uncertain += 1
				continue
			if _valid_record(content,key,row): _put_record(row)
		var restored_edges: Array = value.edges.duplicate(true)
		restored_edges.append_array(_recover_v2_merged(content,value))
		for edge in restored_edges.slice(0,MAX_EDGES):
			if not edge is Dictionary or not data.regions.has(edge.get("from")) or not data.regions.has(edge.get("to")): continue
			if not _integer(edge.get("direction"),-1,3) or not _integer(edge.get("event"),0,255): continue
			if not _at_valid(content.maps[data.regions[edge.from].map_id],edge.get("trigger")): continue
			if not _at_valid(content.maps[data.regions[edge.to].map_id],edge.get("landing")): continue
			_add_edge({"from":str(edge.from),"to":str(edge.to),"direction":int(edge.direction),"event":int(edge.event),
				"trigger":edge.trigger.duplicate(),"landing":edge.landing.duplicate(),"special":bool(edge.get("special",true)),"observed":bool(edge.get("observed",false))})
	_known_source_links()

func _recover_v2_merged(content: ChapterContent, value: Dictionary) -> Array:
	# A directed observed edge may identify one former merged road uniquely.
	# Consider every source-compatible residual-flag destination, never just a
	# clean single-flag sample. Ambiguous matches grant no candidate visits.
	var candidates: Dictionary = {}
	var uncertain: Dictionary = {}
	for key in value.regions:
		var row: Variant = value.regions[key]
		if not row is Dictionary: continue
		if Atlas.ambiguous_merged_base(str(row.get("map_id", "")),str(row.get("script", "")),str(key)):
			candidates[key] = Atlas.legacy_candidates(content,row)
			uncertain[key] = true
		elif data.regions.has(key): candidates[key] = [key]
	var recovered: Dictionary = {}
	var result: Array = []
	for edge in value.edges.slice(0,MAX_EDGES):
		if not edge is Dictionary or not edge.get("observed") is bool or not edge.observed: continue
		if not candidates.has(edge.get("from")) or not candidates.has(edge.get("to")): continue
		if not uncertain.has(edge.from) and not uncertain.has(edge.to): continue
		if not _integer(edge.get("direction"),-1,3) or not _integer(edge.get("event"),0,255): continue
		# Validate both original records and physical edge coordinates before they
		# can serve as evidence. Later edge filtering cannot revoke granted visits.
		var original_from: Dictionary = value.regions[edge.from]
		var original_to: Dictionary = value.regions[edge.to]
		if not _valid_record(content,edge.from,original_from) or not _valid_record(content,edge.to,original_to): continue
		if not _at_valid(content.maps[original_from.map_id],edge.get("trigger")): continue
		if not _at_valid(content.maps[original_to.map_id],edge.get("landing")): continue
		if int(content.cell(original_from.map_id,int(edge.trigger[0]),int(edge.trigger[1])).get("event",0))+40 != int(edge.event): continue
		var matches: Dictionary = {}
		for candidate in candidates[edge.from]:
			for source in Atlas.exits_from(candidate):
				if source.to in candidates[edge.to] and source.direction == edge.get("direction") and source.event == edge.get("event"):
					matches[source.from+"~"+source.to] = [source.from,source.to]
		if matches.size()!=1: continue
		var pair: Array = matches.values()[0]
		var valid := true
		for i in range(2):
			var oldkey: String = edge.from if i==0 else edge.to
			var row: Dictionary = value.regions[oldkey].duplicate(true)
			row.key = pair[i]
			if not _valid_record(content,pair[i],row): valid=false; break
		if not valid: continue
		for i in range(2):
			var oldkey: String = edge.from if i==0 else edge.to
			if not data.regions.has(pair[i]):
				var row: Dictionary = value.regions[oldkey].duplicate(true)
				row.key=pair[i]
				var order:=1
				for known in data.regions.values():order=maxi(order,int(known.order)+1)
				row.order=order
				_put_record(row)
			if uncertain.has(oldkey):recovered[oldkey]=true
		var copy: Dictionary=edge.duplicate(true)
		copy.from=pair[0];copy.to=pair[1]
		result.append(copy)
	migrated_uncertain -= recovered.size()
	return result

func _valid_record(content: ChapterContent, key: Variant, row: Variant) -> bool:
	if not key is String or not row is Dictionary or row.get("key")!=key: return false
	if not row.get("map_id") is String or not row.get("script") is String: return false
	if not content.maps.has(row.map_id) or not content.scripts.has(row.script): return false
	if not row.get("title") is String or row.title.length()>120: return false
	if not _at_valid(content.maps[row.map_id],row.get("at")) or not _integer(row.get("facing"),0,3): return false
	if not _integer(row.get("order"),1,2147483646): return false
	var source:=Atlas.region(key)
	return (not source.is_empty() and source.map_id==row.map_id and source.script==row.script) or key==row.map_id+"|"+row.script

func _put_record(row: Dictionary) -> void:
	if data.regions.size()>=MAX_REGIONS or data.regions.has(row.key): return
	data.regions[str(row.key)]={"key":str(row.key),"map_id":str(row.map_id),"script":str(row.script),
		"title":str(row.title).replace("\n"," ").replace("\r"," ").left(120),"at":[int(row.at[0]),int(row.at[1])],
		"facing":int(row.facing),"order":int(row.order)}

func _restore_legacy(content: ChapterContent, value: Dictionary) -> void:
	if not value.get("regions") is Dictionary or not value.get("edges") is Array: return
	var candidates:Dictionary={}
	var proven:Dictionary={}
	for oldkey in value.regions:
		var row:Variant=value.regions[oldkey]
		if not row is Dictionary or row.get("key")!=oldkey: continue
		if not content.maps.has(row.get("map_id")) or not _at_valid(content.maps[row.map_id],row.get("at")): continue
		if not row.get("title") is String or not _integer(row.get("order"),1,1000000) or not _integer(row.get("facing"),0,3): continue
		var choices:=Atlas.legacy_candidates(content,row)
		candidates[oldkey]=choices
		if choices.size()==1: proven[choices[0]]=row
	# Each old edge proves its endpoints were visited. A merged key can prove
	# different nodes on different edges; never force it to one guessed region.
	var source_edges:Array=Atlas.catalog().get("exits",[])
	for pair in value.edges.slice(0,MAX_EDGES):
		if not pair is Array or pair.size()!=2 or not candidates.has(pair[0]) or not candidates.has(pair[1]): continue
		var matches:Dictionary={}
		for edge in source_edges:
			if edge.from in candidates[pair[0]] and edge.to in candidates[pair[1]]:
				matches[edge.from+"~"+edge.to]=[edge.from,edge.to]
			elif edge.to in candidates[pair[0]] and edge.from in candidates[pair[1]]:
				matches[edge.to+"~"+edge.from]=[edge.to,edge.from]
		if matches.size()==1:
			var match_:Array=matches.values()[0]
			proven[match_[0]]=value.regions[pair[0]]
			proven[match_[1]]=value.regions[pair[1]]
	var sorted:Array=proven.keys()
	sorted.sort_custom(func(a:String,b:String):
		return int(proven[a].order)<int(proven[b].order) if proven[a].order!=proven[b].order else a<b)
	for key in sorted:
		var row:Dictionary=proven[key].duplicate(true)
		row.key=key
		row.order=data.regions.size()+1
		if _valid_record(content,key,row): _put_record(row)
	for oldkey in candidates:
		var recovered:=false
		for key in candidates[oldkey]: if proven.has(key): recovered=true
		if not recovered: migrated_uncertain+=1
	# Ordinary-map old edges lack departure directions. Preserve the visited
	# maps, and relearn their directions from movement instead of inventing them.

func _known_source_links() -> void:
	for source in Atlas.catalog().get("exits",[]):
		if bool(source.get("current_origin_only",false)): continue
		if bool(source.get("requires_observation", false)): continue
		if data.regions.has(source.from) and data.regions.has(source.to):
			var edge:Dictionary=source.duplicate(true)
			edge["observed"]=false
			_add_edge(edge)

func _add_edge(edge: Dictionary) -> void:
	if edge.from==edge.to or data.edges.size()>=MAX_EDGES: return
	for existing in data.edges:
		if existing.from==edge.from and existing.to==edge.to and existing.direction==edge.direction and existing.event==edge.event:
			if bool(edge.get("observed",false)):
				existing.observed=true
				existing.trigger=edge.trigger.duplicate()
				existing.landing=edge.landing.duplicate()
			return
	data.edges.append({"from":str(edge.from),"to":str(edge.to),"direction":int(edge.direction),"event":int(edge.event),
		"trigger":edge.get("trigger",[]).duplicate(),"landing":edge.get("landing",[]).duplicate(),"special":bool(edge.get("special",false)),"observed":bool(edge.get("observed",false))})

func _at_valid(map: Dictionary, value: Variant) -> bool:
	return value is Array and value.size()==2 and _integer(value[0],0,int(map.get("width",0))-1) and _integer(value[1],0,int(map.get("height",0))-1)

func _integer(value: Variant, low: int, high: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value)==floor(float(value)) and value>=low and value<=high
