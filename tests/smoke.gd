extends SceneTree
var app: Control
var failures: Array[String] = []
func _initialize() -> void:
	call_deferred("run")
func check(value: bool, message: String) -> void:
	if not value: failures.append(message)
func run() -> void:
	ProjectSettings.set_setting("application/config/custom_user_dir_name", "FMJClassic-validation")
	DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir())
	app = load("res://scenes/chapter1.tscn").instantiate()
	root.add_child(app)
	await process_frame
	check(app.session != null, "Bundled data must load without external files")
	if app.session == null:
		finish()
		return
	check(app.content.maps.size() == 83, "Classic maps")
	check(app.content.scripts.size() == 186, "Classic event resources")
	check(app.content.goods.size() == 216, "Classic goods")
	check(app.world.atlas.size() > 300, "Remake art catalog")
	app._new_game()
	await process_frame
	check(app.started, "Normal new-game entry")
	check(app.session.runtime().error.is_empty(), "Opening event error")
	check(not app.session.request().is_empty(), "Opening presentation request")
	for step in range(60):
		if not app.session.snapshot().world.map_id.is_empty(): break
		var request: Dictionary = app.session.request()
		if request.is_empty(): app.session.pump()
		elif request.kind in ["prologue", "dialogue", "pose", "scene_name", "screen", "movie", "movement"]: app._respond()
		else: break
		await process_frame
	check(not app.session.snapshot().world.map_id.is_empty(), "Normal opening reaches a map")
	check(app.session.runtime().error.is_empty(), "Opening progression error")
	for catalog_path in ["res://assets/chapter1/atlas.json", "res://assets/chapter2/atlas.json", "res://assets/chapter2/npc-atlas.json", "res://assets/chapter2/terrain-atlas.json", "res://assets/chapter3/atlas.json", "res://assets/chapter3/character-atlas.json", "res://assets/chapter45/atlas.json", "res://assets/chapter45/character-atlas.json", "res://assets/chapter67/atlas.json", "res://assets/chapter67/character-atlas.json"]:
		if not FileAccess.file_exists(catalog_path): continue
		var catalog: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(catalog_path))
		for key in catalog:
			check(ResourceLoader.exists(str(catalog[key].path)), "Missing artwork: " + str(key))
	finish()
func finish() -> void:
	if failures.is_empty(): print("CLASSIC_SMOKE_PASS")
	else:
		for failure in failures: push_error(failure)
	if app != null:
		app.queue_free()
		await process_frame
	quit(0 if failures.is_empty() else 1)
