class_name SaveStore
extends RefCounted
## Synchronous, single-writer JSON storage. GameSession owns state semantics.

const FORMAT_VERSION := 1
const SCHEMA_VERSION := 1
const SLOT_COUNT := 3
const MAX_FILE_BYTES := 4 * 1024 * 1024
const MAX_PAYLOAD_BYTES := 1024 * 1024
const MAX_DEPTH := 64
const MAX_SAFE_INTEGER := 9007199254740991
const RECOVERABLE_ERRORS := [
	"not_found", "invalid_json", "invalid_envelope", "checksum_mismatch",
	"invalid_payload", "invalid_snapshot", "file_too_large", "invalid_utf8",
]

var _root_dir: String
var _root_error := ""


func _init(root_dir: String = "user://saves") -> void:
	# The root is developer configuration, never taken from a save file.
	if root_dir.is_empty() or root_dir.contains("\\") or root_dir.to_utf8_buffer().has(0):
		_root_error = "invalid_root"
	elif ".." in root_dir.split("/") or root_dir.begins_with("res://"):
		_root_error = "invalid_root"
	elif not root_dir.begins_with("user://") and not root_dir.is_absolute_path():
		_root_error = "invalid_root"
	_root_dir = ProjectSettings.globalize_path(root_dir).simplify_path()


func save_slot(slot: int, snapshot: Dictionary) -> Dictionary:
	if not _valid_slot(slot):
		return _failure("invalid_slot")
	var snapshot_error := _validate_snapshot(snapshot)
	if not snapshot_error.is_empty():
		return _failure(snapshot_error)
	var payload_json := JSON.stringify(snapshot, "", true, true)
	if payload_json.to_utf8_buffer().size() > MAX_PAYLOAD_BYTES:
		return _failure("payload_too_large")
	var envelope_json := JSON.stringify({
		"format_version": FORMAT_VERSION,
		"payload_json": payload_json,
		"sha256": payload_json.sha256_text(),
	}, "", true, true)
	if envelope_json.to_utf8_buffer().size() > MAX_FILE_BYTES:
		return _failure("file_too_large")
	var root_error := _prepare_root(true)
	if not root_error.is_empty():
		return _failure(root_error)
	var paths_error := _check_slot_paths(slot)
	if not paths_error.is_empty():
		return _failure(paths_error)

	var primary := _slot_path(slot)
	var backup := primary + ".bak"
	var content_id: String = snapshot["content_id"]
	var content_hash: String = snapshot["content_hash"]
	var old := _read_file(primary, content_id, content_hash)
	if not old["ok"] and old["error"] != "not_found":
		# A future/incompatible/damaged save must not be destroyed by this build.
		return _failure("existing_save_" + old["error"])
	if not old["ok"] and FileAccess.file_exists(backup):
		var orphan_backup := _read_file(backup, content_id, content_hash)
		if not orphan_backup["ok"]:
			return _failure("existing_backup_" + orphan_backup["error"])

	var written := _write_verified(primary + ".tmp", envelope_json, content_id, content_hash)
	if not written["ok"]:
		return written
	if old["ok"]:
		# Copy the validated old primary; never move it away before replacement.
		var backup_written := _write_verified(
			backup + ".tmp", old["raw_json"], content_id, content_hash
		)
		if not backup_written["ok"]:
			return backup_written
		if DirAccess.rename_absolute(backup + ".tmp", backup) != OK:
			return _failure("backup_replace_failed")
	# Same-directory rename, with no remove-before-rename gap.
	if DirAccess.rename_absolute(primary + ".tmp", primary) != OK:
		return _failure("primary_replace_failed")
	return _success(written["value"])


func load_slot(slot: int, expected_content_id: String, expected_content_hash: String) -> Dictionary:
	if not _valid_slot(slot):
		return _failure("invalid_slot")
	if expected_content_id.is_empty() or expected_content_hash.is_empty():
		return _failure("missing_content_identity")
	var root_error := _prepare_root(false)
	if not root_error.is_empty():
		return _failure(root_error)
	var paths_error := _check_slot_paths(slot)
	if not paths_error.is_empty():
		return _failure(paths_error)
	return _load_with_backup(slot, expected_content_id, expected_content_hash)


func list_slots() -> Array[Dictionary]:
	var slots: Array[Dictionary] = []
	var root_error := _prepare_root(false)
	for slot in range(1, SLOT_COUNT + 1):
		var result: Dictionary
		if not root_error.is_empty():
			result = _failure(root_error)
		else:
			var paths_error := _check_slot_paths(slot)
			if not paths_error.is_empty():
				result = _failure(paths_error)
			else:
				# Listing validates storage but cannot authorize a content pack.
				result = _load_with_backup(slot, "", "")
		if result["ok"]:
			var snapshot: Dictionary = result["value"]
			result["value"] = {
				"schema_version": snapshot["schema_version"],
				"content_id": snapshot["content_id"],
				"content_hash": snapshot["content_hash"],
			}
		result["slot"] = slot
		slots.append(result)
	return slots


func _load_with_backup(slot: int, content_id: String, content_hash: String) -> Dictionary:
	var primary := _read_file(_slot_path(slot), content_id, content_hash)
	if primary["ok"]:
		primary.erase("raw_json")
		primary["recovered"] = false
		return primary
	if primary["error"] not in RECOVERABLE_ERRORS:
		return primary
	var backup := _read_file(_slot_path(slot) + ".bak", content_id, content_hash)
	if backup["ok"]:
		backup.erase("raw_json")
		backup["recovered"] = true
		backup["primary_error"] = primary["error"]
		return backup
	# Surface incompatible backups instead of disguising them as generic damage.
	if backup["error"] not in RECOVERABLE_ERRORS:
		backup["primary_error"] = primary["error"]
		return backup
	primary["backup_error"] = backup["error"]
	return primary


func _read_file(path: String, content_id: String, content_hash: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _failure("not_found")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _failure("read_failed")
	var length := file.get_length()
	if length > MAX_FILE_BYTES:
		file.close()
		return _failure("file_too_large")
	var bytes := file.get_buffer(length)
	var read_error := file.get_error()
	file.close()
	if bytes.size() != length or (read_error != OK and read_error != ERR_FILE_EOF):
		return _failure("read_failed")
	var raw_json := bytes.get_string_from_utf8()
	if raw_json.to_utf8_buffer() != bytes:
		return _failure("invalid_utf8")
	var parser := JSON.new()
	if parser.parse(raw_json) != OK:
		return _failure("invalid_json")
	if not parser.data is Dictionary:
		return _failure("invalid_envelope")
	var envelope: Dictionary = parser.data
	if not _is_integer_number(envelope.get("format_version")):
		return _failure("invalid_envelope")
	if envelope["format_version"] != FORMAT_VERSION:
		return _failure("unsupported_format_version")
	if not envelope.get("payload_json") is String or not envelope.get("sha256") is String:
		return _failure("invalid_envelope")
	var payload_json: String = envelope["payload_json"]
	if payload_json.to_utf8_buffer().size() > MAX_PAYLOAD_BYTES:
		return _failure("file_too_large")
	if payload_json.sha256_text() != envelope["sha256"]:
		return _failure("checksum_mismatch")
	if parser.parse(payload_json) != OK or not parser.data is Dictionary:
		return _failure("invalid_payload")
	var snapshot: Dictionary = parser.data
	var snapshot_error := _validate_snapshot(snapshot)
	if not snapshot_error.is_empty():
		return _failure(snapshot_error)
	if not content_id.is_empty() and snapshot["content_id"] != content_id:
		return _failure("content_id_mismatch")
	if not content_hash.is_empty() and snapshot["content_hash"] != content_hash:
		return _failure("content_hash_mismatch")
	var result := _success(snapshot)
	result["raw_json"] = raw_json
	return result


func _write_verified(path: String, text: String, content_id: String, content_hash: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _failure("write_failed")
	var stored := file.store_string(text)
	file.flush()
	var write_error := file.get_error()
	file.close()
	if not stored or write_error != OK:
		return _failure("write_failed")
	var verified := _read_file(path, content_id, content_hash)
	if not verified["ok"]:
		return _failure("write_verification_failed")
	if verified["raw_json"] != text:
		return _failure("write_verification_failed")
	verified.erase("raw_json")
	return verified


func _validate_snapshot(snapshot: Dictionary) -> String:
	if not _is_integer_number(snapshot.get("schema_version")):
		return "invalid_snapshot"
	if snapshot["schema_version"] != SCHEMA_VERSION:
		return "unsupported_schema_version"
	for key in ["content_id", "content_hash"]:
		if not snapshot.get(key) is String or snapshot[key].is_empty():
			return "invalid_snapshot"
	if not _is_json_value(snapshot):
		return "invalid_snapshot"
	return ""


func _is_json_value(value: Variant, depth: int = 0) -> bool:
	if depth > MAX_DEPTH:
		return false
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_STRING:
			return true
		TYPE_INT:
			return value >= -MAX_SAFE_INTEGER and value <= MAX_SAFE_INTEGER
		TYPE_FLOAT:
			return is_finite(value) and absf(value) <= float(MAX_SAFE_INTEGER)
		TYPE_ARRAY:
			for item in value:
				if not _is_json_value(item, depth + 1):
					return false
			return true
		TYPE_DICTIONARY:
			for key in value:
				if not key is String or not _is_json_value(value[key], depth + 1):
					return false
			return true
	return false


func _is_integer_number(value: Variant) -> bool:
	if value is int:
		return true
	return value is float and is_finite(value) and value == floor(value)


func _prepare_root(create: bool) -> String:
	if not _root_error.is_empty():
		return _root_error
	# Reject the configured root when it is itself a symlink. The host controls ancestors.
	var parent := DirAccess.open(_root_dir.get_base_dir())
	if parent != null and parent.is_link(_root_dir.get_file()):
		return "unsafe_path"
	if FileAccess.file_exists(_root_dir):
		return "root_unavailable"
	if not DirAccess.dir_exists_absolute(_root_dir):
		if not create:
			return "not_found"
		if DirAccess.make_dir_recursive_absolute(_root_dir) != OK:
			return "root_unavailable"
	if DirAccess.open(_root_dir) == null:
		return "root_unavailable"
	return ""


func _check_slot_paths(slot: int) -> String:
	var directory := DirAccess.open(_root_dir)
	if directory == null:
		return "root_unavailable"
	for suffix in ["", ".bak", ".tmp", ".bak.tmp"]:
		var name := "slot_%02d.json%s" % [slot, suffix]
		if directory.is_link(name):
			return "unsafe_path"
		if directory.dir_exists(name):
			return "slot_path_unavailable"
	return ""


func _slot_path(slot: int) -> String:
	return _root_dir.path_join("slot_%02d.json" % slot)


func _valid_slot(slot: int) -> bool:
	return slot >= 1 and slot <= SLOT_COUNT


func _success(value: Variant) -> Dictionary:
	return {"ok": true, "value": value, "error": ""}


func _failure(error: String) -> Dictionary:
	return {"ok": false, "value": null, "error": error}
