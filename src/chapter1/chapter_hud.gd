class_name ChapterHUD
extends Control
## Read-only native HUD. One Control, fixed drawing resources, no scene rebuilding.
## Battle snapshots deliberately omit numeric HP/MP/money presentation values.
const PANEL_WIDTH := 336.0
const FIELD_HEIGHT := 110.0
const BATTLE_HEIGHT := 70.0
const INK := Color("ede8d5")
const MUTED := Color("a8bfb5")
const GOLD := Color("c5aa71")
const HP_COLOR := Color("91b99a")
const MP_COLOR := Color("76aeb7")
var show_currency := true:
	set(value):
		show_currency = value
		queue_redraw()
var _session: WeakRef
var _started := true
var _view: Dictionary = {}
var _battle_identity: Dictionary = {}
var _portrait: Texture2D
var _font := SystemFont.new()
var _panel := StyleBoxFlat.new()

func _init() -> void:
	position = Vector2(24,20)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_font.font_names = PackedStringArray(["PingFang SC","Microsoft YaHei","Noto Sans CJK SC","Heiti SC","Arial"])
	_panel.bg_color = Color(0.035,0.135,0.145,0.94)
	_panel.border_color = Color(0.70,0.61,0.42,0.73)
	_panel.set_border_width_all(1)
	_panel.set_corner_radius_all(4)
	_panel.shadow_color = Color(0.015,0.035,0.035,0.22)
	_panel.shadow_size = 3
	_panel.shadow_offset = Vector2(0,2)
	custom_minimum_size = Vector2(PANEL_WIDTH,FIELD_HEIGHT)
	size = custom_minimum_size
	visible = false

func bind_session(session: ChapterSession, started: bool = true) -> void:
	# Bind once if the owner prefers signals. update_snapshot is the alternative API.
	var previous: ChapterSession = _session.get_ref() if _session != null else null
	if previous != null and previous.changed.is_connected(_on_session_changed):
		previous.changed.disconnect(_on_session_changed)
	_session = weakref(session) if session != null else null
	_started = started
	if session != null:
		session.changed.connect(_on_session_changed)
		_on_session_changed()
	else:
		update_snapshot({},false,false)

func update_snapshot(snapshot: Dictionary, battle_presenting: bool = false, started: bool = true, scene_title: String = "") -> void:
	_started = started
	var party: Array = snapshot.get("party",[])
	var actors: Dictionary = snapshot.get("actors",{})
	var actor: Dictionary = actors.get(str(party[0]),{}) if not party.is_empty() else {}
	if not started or actor.is_empty():
		_view = {}
		_battle_identity = {}
		visible = false
		return
	var runtime: Dictionary = snapshot.get("source_runtime",{})
	var request: Dictionary = runtime.get("request",{})
	var combat: Dictionary = runtime.get("combat",{})
	var in_battle: bool = battle_presenting or not combat.is_empty() or bool(runtime.get("battle_event",false)) or request.get("kind","") in ["battle","battle_result","gameover"]
	var actor_id := str(party[0])
	var level := int(actor.get("level",1))
	if in_battle:
		# The initial request token and RNG seed stay fixed; action tokens/RNG state do not.
		var token := str(runtime.get("battle_request",{}).get("token",""))
		if combat.is_empty() and request.get("kind","") == "battle":
			token = str(request.get("token",""))
		var identity := {"content":str(snapshot.get("content_hash","")), "token":token,
			"seed":str(combat.get("rng_seed",""))}
		var same_battle: bool = _view.get("battle",false) and _view.get("actor_id","") == actor_id and not token.is_empty() and _battle_identity.get("token","") == token and _battle_identity.get("content","") == identity.content
		if same_battle:
			var previous_seed := str(_battle_identity.get("seed",""))
			same_battle = identity.seed.is_empty() or previous_seed.is_empty() or identity.seed == previous_seed
			# Combat may be cleared before the final presentation has finished.
			if identity.seed.is_empty(): identity.seed = previous_seed
		if same_battle:
			# A different loaded battle must display its own level immediately.
			level = int(_view.level)
		_battle_identity = identity
	else:
		_battle_identity = {}
	var view_next := {"scene":scene_title if not scene_title.is_empty() else str(runtime.get("scene_name","")), "actor_id":actor_id,
		"name":str(actor.get("name","")), "level":level, "battle":in_battle}
	if not in_battle:
		view_next.hp = maxi(0,int(actor.get("hp",0)))
		view_next.max_hp = maxi(0,int(actor.get("max_hp",0)))
		view_next.mp = maxi(0,int(actor.get("mp",0)))
		view_next.max_mp = maxi(0,int(actor.get("max_mp",0)))
		view_next.companions = []
		for id in party.slice(1):
			var member: Dictionary = actors.get(str(id),{})
			view_next.companions.append({"name":str(member.get("name","")),"level":int(member.get("level",1)),"hp":int(member.get("hp",0)),"max_hp":int(member.get("max_hp",0)),"mp":int(member.get("mp",0)),"max_mp":int(member.get("max_mp",0))})
		view_next.currency = maxi(0,int(snapshot.get("currency",0)))
	if view_next == _view and visible: return
	_view = view_next
	visible = true
	custom_minimum_size = Vector2(PANEL_WIDTH,BATTLE_HEIGHT if in_battle else FIELD_HEIGHT + 68 * _view.get("companions",[]).size())
	size = custom_minimum_size
	tooltip_text = "%s · %s Lv.%d" % [_view.scene,_view.name,_view.level]
	queue_redraw()

func set_portrait(texture: Texture2D) -> void:
	# Optional existing hero_south_1 texture; no asset is required or loaded implicitly.
	_portrait = texture
	queue_redraw()

func display_values() -> Dictionary:
	return _view.duplicate(true)

func _on_session_changed() -> void:
	var session: ChapterSession = _session.get_ref() if _session != null else null
	if session != null: update_snapshot(session.snapshot(),false,_started,session.content.display_scene_name(session.state))

func _exit_tree() -> void:
	var session: ChapterSession = _session.get_ref() if _session != null else null
	if session != null and session.changed.is_connected(_on_session_changed):
		session.changed.disconnect(_on_session_changed)
	_session = null

func _draw() -> void:
	if _view.is_empty(): return
	var battle: bool = _view.battle
	var height: float = BATTLE_HEIGHT if battle else FIELD_HEIGHT + 68 * _view.get("companions",[]).size()
	draw_style_box(_panel,Rect2(0,0,PANEL_WIDTH,height))
	# Restrained inner highlights keep the frame readable over light terrain.
	draw_line(Vector2(8,1),Vector2(PANEL_WIDTH-8,1),Color(0.85,0.75,0.49,0.20),1)
	draw_line(Vector2(16,39),Vector2(PANEL_WIDTH-16,39),Color(0.67,0.61,0.43,0.23),1)
	var money_width := 0.0
	if show_currency and not battle:
		var money := "银两  %d" % int(_view.currency)
		money_width = _font.get_string_size(money,HORIZONTAL_ALIGNMENT_LEFT,-1,12).x + 14
		_text_right(money,PANEL_WIDTH-16,28,12,MUTED)
	_text(str(_view.scene),Vector2(16,29),19,INK,PANEL_WIDTH-32-money_width)
	var body_x := 16.0
	if _portrait != null and not battle:
		draw_rect(Rect2(12,46,35,54),Color(0.025,0.095,0.11,0.7))
		draw_line(Vector2(12,47),Vector2(12,97),Color(0.69,0.60,0.40,0.42),1)
		var dimensions := Vector2(_portrait.get_size())
		var scale_factor := minf(32.0/maxf(1,dimensions.x),48.0/maxf(1,dimensions.y))
		var drawn := (dimensions*scale_factor).floor()
		draw_texture_rect(_portrait,Rect2(Vector2(14,48)+(Vector2(32,48)-drawn)*0.5,drawn),false)
		body_x = 58.0
	var name := _fit(str(_view.name),15,150)
	_text(name,Vector2(body_x,59),15,INK,150)
	var name_width := _font.get_string_size(name,HORIZONTAL_ALIGNMENT_LEFT,-1,15).x
	_text("Lv.%d" % int(_view.level),Vector2(body_x+name_width+12,58),12,GOLD,65)
	if battle: return
	_bar(body_x,79,"生命",int(_view.hp),int(_view.max_hp),HP_COLOR)
	_bar(body_x,97,"真气",int(_view.mp),int(_view.max_mp),MP_COLOR)

	for i in range(_view.get("companions",[]).size()):
		var member: Dictionary = _view.companions[i]
		var y := FIELD_HEIGHT + 68 * i
		draw_line(Vector2(16,y-5),Vector2(PANEL_WIDTH-16,y-5),Color(0.67,0.61,0.43,0.23),1)
		_text("%s  Lv.%d" % [member.name,member.level],Vector2(16,y+13),15,INK,PANEL_WIDTH-32)
		_bar(16,y+33,"生命",member.hp,member.max_hp,HP_COLOR)
		_bar(16,y+51,"真气",member.mp,member.max_mp,MP_COLOR)

func _bar(x: float, baseline: float, label: String, value: int, maximum: int, tint: Color) -> void:
	_text(label,Vector2(x,baseline),11,MUTED,30)
	var bar := Rect2(x+34,baseline-6,202-x,5)
	draw_rect(Rect2(bar.position-Vector2.ONE,bar.size+Vector2(2,2)),Color(0.015,0.06,0.065,0.88))
	draw_rect(bar,Color("224649"))
	var ratio := clampf(float(value)/float(maximum),0,1) if maximum > 0 else 0.0
	var fill := floorf(bar.size.x*ratio)
	var color := Color("cf9475") if label == "生命" and ratio <= 0.25 else tint
	if fill > 0:
		draw_rect(Rect2(bar.position,Vector2(fill,bar.size.y)),color)
		draw_rect(Rect2(bar.position,Vector2(fill,1)),color.lightened(0.18))
	for column in range(12,int(bar.size.x),12):
		draw_line(bar.position+Vector2(column,1),bar.position+Vector2(column,4),Color(0.025,0.11,0.12,0.30),1)
	_text_right("%d / %d" % [value,maximum],PANEL_WIDTH-16,baseline,11,INK)

func _text(value: String, at: Vector2, font_size: int, tint: Color, width: float) -> void:
	draw_string(_font,at,_fit(value,font_size,width),HORIZONTAL_ALIGNMENT_LEFT,-1,font_size,tint)

func _text_right(value: String, right: float, baseline: float, font_size: int, tint: Color) -> void:
	var text_width := _font.get_string_size(value,HORIZONTAL_ALIGNMENT_LEFT,-1,font_size).x
	draw_string(_font,Vector2(right-text_width,baseline),value,HORIZONTAL_ALIGNMENT_LEFT,-1,font_size,tint)

func _fit(value: String, font_size: int, width: float) -> String:
	if _font.get_string_size(value,HORIZONTAL_ALIGNMENT_LEFT,-1,font_size).x <= width: return value
	var shortened := value
	while not shortened.is_empty():
		shortened = shortened.left(shortened.length()-1)
		if _font.get_string_size(shortened+"…",HORIZONTAL_ALIGNMENT_LEFT,-1,font_size).x <= width: return shortened+"…"
	return ""
