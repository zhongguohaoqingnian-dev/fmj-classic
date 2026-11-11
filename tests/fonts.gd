extends SceneTree
## Runs against source or as an external script with the exported application's PCK.
var failures: Array[String] = []
var app: Control
var screenshot_dir := ""
func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--font-screenshots="): screenshot_dir = arg.trim_prefix("--font-screenshots=")
	call_deferred("run")
func check(value: bool, message: String) -> void:
	if not value: failures.append(message)
func capture(name_: String) -> void:
	if screenshot_dir.is_empty(): return
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(screenshot_dir.path_join(name_ + ".png")) == OK,"Capture " + name_)
func run() -> void:
	ProjectSettings.set_setting("application/config/custom_user_dir_name", "FMJClassic-font-validation")
	DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir())
	var body: FontFile = load("res://assets/fonts/NotoSansCJKsc-Regular.otf")
	var title: FontFile = load("res://assets/fonts/NotoSerifCJKsc-Regular.otf")
	for font in [body, title]:
		check(font != null and not font.data.is_empty(), "Bundled font data")
		check(not font.allow_system_fallback, "Font must work without system fallback")
		check(font.get_string_size("伏魔记 初入江湖 ABC 0123",HORIZONTAL_ALIGNMENT_LEFT,-1,20).x > 100,"Nonzero glyph advances")
		for character in "伏魔记初入江湖继续前缘体力法力银两百草地完ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789，。？！：·…—":
			check(font.has_char(character.unicode_at(0)), "Missing UI glyph: " + character)
	var text := FileAccess.get_file_as_string("res://data/game/classic.json")
	var checked := {}
	for i in range(text.length()):
		var code := text.unicode_at(i)
		if code < 32 or checked.has(code): continue
		checked[code] = true
		check(body.has_char(code), "Missing game data glyph U+%04X" % code)
	print("FONT_DATA_CODEPOINTS=",checked.size())
	app = load("res://scenes/chapter1.tscn").instantiate()
	root.add_child(app)
	await process_frame
	check(app.session != null,"Production scene loads bundled data")
	check(app.get_theme_default_font() == body,"Controls use bundled body font")
	check(app.field_hud._font == body and app.world._font == body,"Custom drawing uses bundled body font")
	await capture("title")
	app._new_game()
	await process_frame
	await capture("prologue")
	for step in range(60):
		if not app.session.snapshot().world.map_id.is_empty(): break
		var request: Dictionary = app.session.request()
		if request.is_empty(): app.session.pump()
		elif request.kind in ["prologue","dialogue","pose","scene_name","screen","movie","movement"]: app._respond()
		else: break
		await process_frame
	await capture("dialogue-hud")
	check(not app.session.snapshot().world.map_id.is_empty(),"Normal new game reaches map")
	check(app.session.runtime().error.is_empty(),"No opening event error")
	app._save_menu(false)
	await capture("save-menu")
	if failures.is_empty(): print("CLASSIC_FONTS_PASS")
	else:
		for failure in failures: push_error(failure)
	app.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
