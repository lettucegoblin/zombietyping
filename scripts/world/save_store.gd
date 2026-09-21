class_name SaveStore
## Small binary save wrapper. Variant encoding preserves Vector2i dictionary keys,
## PackedByteArray fog masks, and Vector3 placement transforms without lossy JSON glue.

const PATH := "user://settlement.save"
const MAGIC := "zombietyping-settlement"
const VERSION := 1


static func write(payload: Dictionary, path: String = PATH) -> Error:
	var temp_path := path + ".tmp"
	var backup_path := path + ".bak"
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_var({
		"magic": MAGIC,
		"version": VERSION,
		"saved_at": Time.get_unix_time_from_system(),
		"payload": payload,
	}, false)
	file.flush()
	file.close()
	var temp := ProjectSettings.globalize_path(temp_path)
	var target := ProjectSettings.globalize_path(path)
	var backup := ProjectSettings.globalize_path(backup_path)
	if FileAccess.file_exists(backup_path):
		DirAccess.remove_absolute(backup)
	if FileAccess.file_exists(path):
		var backup_err := DirAccess.rename_absolute(target, backup)
		if backup_err != OK:
			return backup_err
	var err := DirAccess.rename_absolute(temp, target)
	if err != OK and FileAccess.file_exists(backup_path):
		DirAccess.rename_absolute(backup, target)
	return err


static func read(path: String = PATH) -> Dictionary:
	var payload := _read_one(path)
	if not payload.is_empty():
		return payload
	return _read_one(path + ".bak")


static func _read_one(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var data: Variant = file.get_var(false)
	file.close()
	if not data is Dictionary:
		return {}
	var envelope: Dictionary = data
	if envelope.get("magic", "") != MAGIC or int(envelope.get("version", -1)) != VERSION:
		return {}
	var payload: Variant = envelope.get("payload", {})
	return payload if payload is Dictionary else {}


static func exists(path: String = PATH) -> bool:
	return FileAccess.file_exists(path) or FileAccess.file_exists(path + ".bak")


static func erase(path: String = PATH) -> Error:
	var err := OK
	for candidate in [path, path + ".tmp", path + ".bak"]:
		if FileAccess.file_exists(candidate):
			var next := DirAccess.remove_absolute(ProjectSettings.globalize_path(candidate))
			if next != OK:
				err = next
	return err
