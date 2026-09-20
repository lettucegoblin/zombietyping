extends SceneTree
## Parse every script under res://scripts (autoload-dependent ones report "World" errors
## only, which is fine). Godot --headless --path . -s res://scripts/tests/parse_check.gd

func _init():
	var bad := 0
	for p in _walk("res://scripts"):
		var s = load(p)
		if s == null:
			bad += 1
	print("parse check done, unloadable scripts: ", bad)
	quit()

func _walk(dir: String) -> Array:
	var out := []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		var p := dir + "/" + f
		if d.current_is_dir():
			out.append_array(_walk(p))
		elif f.ends_with(".gd"):
			out.append(p)
		f = d.get_next()
	return out
