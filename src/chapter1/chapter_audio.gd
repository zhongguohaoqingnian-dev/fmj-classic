extends Node
## Original remake audio; settings are local presentation preferences.
var music_players: Array[AudioStreamPlayer] = []
var effects: Array[AudioStreamPlayer] = []
var current_track := ""
var active := 0
var _music_fades_db: Array[float] = [-60.0, -60.0]
var master := 0.75
var music_level := 0.7
var effects_level := 0.65
var muted := false
var transition: Tween
var config := ConfigFile.new()

func _ready() -> void:
	if config.load("user://chapter1-settings.cfg") == OK:
		master = clampf(float(config.get_value("audio", "master", master)),0,1)
		music_level = clampf(float(config.get_value("audio", "music", music_level)),0,1)
		effects_level = clampf(float(config.get_value("audio", "effects", effects_level)),0,1)
		muted = bool(config.get_value("audio", "muted", false))
	for i in range(2):
		var player := AudioStreamPlayer.new()
		add_child(player)
		music_players.append(player)
	for i in range(8):
		var player := AudioStreamPlayer.new()
		add_child(player)
		effects.append(player)

func set_levels(master_value: float, music_value: float, effects_value: float) -> void:
	master = clampf(master_value,0,1)
	music_level = clampf(music_value,0,1)
	effects_level = clampf(effects_value,0,1)
	config.set_value("audio", "master", master)
	config.set_value("audio", "music", music_level)
	config.set_value("audio", "effects", effects_level)
	config.set_value("audio", "muted", muted)
	config.save("user://chapter1-settings.cfg")
	for index in music_players.size():
		_set_music_fade(_music_fades_db[index], index)
	for player in effects: player.volume_db = _volume(effects_level)

func _volume(level: float) -> float:
	return linear_to_db(maxf(0.0001,level*master)) if not muted else -80.0

func _set_music_fade(value: float, index: int) -> void:
	_music_fades_db[index] = value
	# A transition owns only attenuation; user gain remains live for both tracks.
	music_players[index].volume_db = maxf(-80.0, _volume(music_level) + value)

func ambience(cave: bool, battle: bool) -> void:
	var name := "guardians_of_the_lamps" if battle else ("breath_below_the_mountain" if cave else "wind_over_sanqing")
	if name == current_track: return
	current_track = name
	var old := music_players[active]
	active = 1-active
	var player := music_players[active]
	var path := "res://assets/chapter1/audio/%s.ogg" % name
	if not ResourceLoader.exists(path): return
	var stream: AudioStreamOggVorbis = load(path)
	stream.loop = true
	player.stream = stream
	_set_music_fade(-60.0, active)
	player.play()
	if transition != null and transition.is_running(): transition.kill()
	transition = create_tween().set_parallel(true)
	transition.tween_method(_set_music_fade.bind(active), -60.0, 0.0, 1.1)
	transition.tween_method(_set_music_fade.bind(1-active), _music_fades_db[1-active], -60.0, 1.1)
	transition.chain().tween_callback(old.stop)

func play_effect(name: String) -> void:
	var path := "res://assets/chapter1/audio/%s.wav" % name
	if not ResourceLoader.exists(path): return
	for player in effects:
		if not player.playing:
			player.stream = load(path)
			player.volume_db = _volume(effects_level)
			player.play()
			return

func on_record(record: Dictionary) -> void:
	var command: Dictionary = record.command
	match str(command.get("kind","")):
		"move":
			if bool(command.get("moved",false)): play_effect("step")
		"shop_buy", "equip": play_effect("confirm")
		"opcode":
			if command.get("opcode") == "GAINGOODS": play_effect("reward")
		"field_magic": play_effect("spell")

func visual_event(event: Dictionary) -> void:
	if event.get("type") == "action":
		match str(event.get("command","")):
			"attack", "throw": play_effect("swing")
			"magic": play_effect("spell")
	elif event.get("type") == "vitals" and int(event.get("hp_delta",0)) < 0: play_effect("hit")

func _exit_tree() -> void:
	if transition != null:
		transition.kill()
		transition = null
	for player in music_players + effects:
		player.stop()
		player.stream = null
