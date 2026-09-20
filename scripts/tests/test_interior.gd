extends Node
## Headless interior test:  Godot --headless --path . res://scenes/tests/test_interior.tscn
## Drives: map -> queue two buildings -> arrive -> type door word -> enter -> open a door
## -> stairs (if any) -> exit -> rail resumes -> second arrival. Exit code 0 = pass.

var _main: Node
var _player: Node3D
var _map: Control
var _typist: Node
var _interior: Node3D
var _queued: Array = []
var _step := "queue"
var _frames := 0
var _wait := 0
var _opened_doors := 0
var _climbed := false
var _kills := 0
var _auto_returns := 0
var _floor_before := 0
var _expect_landing := false
var _idle := 0


func _ready() -> void:
	Engine.time_scale = 30.0
	_main = load("res://scenes/main.tscn").instantiate()
	add_child(_main)
	_player = _main.get_node("View/Viewport/World/Player")
	_map = _main.get_node("UI/TabMap")
	_typist = _main.get_node("Typist")
	_interior = _main.get_node("View/Viewport/World/Interior")
	_main.get_node("View/Viewport/World/Director").set_meta("no_street", true)
	_main.get_node("View/Viewport/World/Director").street_spawning = false
	call_deferred("_queue")


func _fail(msg: String) -> void:
	print("TEST FAIL: " + msg)
	push_error("TEST FAIL: " + msg)
	get_tree().quit(1)


func _type(word: String) -> void:
	for ch in word:
		var ev := InputEventKey.new()
		ev.pressed = true
		ev.keycode = KEY_A + (ch.unicode_at(0) - 97)
		_typist._input(ev)


func _words() -> Array:
	var out := []
	for p in _typist.prompts():
		out.append(p["word"])
	return out


func _queue() -> void:
	_map.size = Vector2(1280, 720)
	_main._toggle_map()
	_map.recompute_labels()
	var labels: Array = _map._labels.keys()
	labels.sort()
	# pick the tallest visible building first so we can test stairs
	var best := ""
	var best_floors := 0
	for l in labels:
		var b := World.building_by_id(_map._labels[l])
		if b.floors > best_floors:
			best_floors = b.floors
			best = l
	_map._on_submit("%s %s" % [best, labels[0] if labels[0] != best else labels[1]])
	_queued = _player.queued_ids()
	print("queued: ", _queued, "  first has ", best_floors, " floors")
	_main._toggle_map()
	_step = "arrive1"


func _process(_dt: float) -> void:
	_frames += 1
	if _frames > 20000:
		return _fail("timeout at step " + _step)
	if _frames % 1500 == 0:
		var director := _main.get_node("View/Viewport/World/Director")
		print("[diag f%d] step=%s moving=%s halt=%s combat=%s pending=%s searching=%s room=%d targets=%s alive=%d pos=%s" % [_frames, _step, _player.is_moving(), _player.halt, _typist.in_combat(), _main._search_pending, _main._searching, _interior.current_room, director.targetable_words(), director.alive().size(), _player.global_position])
	match _step:
		"arrive1":
			if _main.mode == _main.Mode.DOOR:
				var w: Array = _words()
				print("at door, prompt: ", w, "  window: ", _main.door_timer)
				if w.size() != 1: return _fail("door should offer exactly one word")
				if _main.door_timer <= 0.0: return _fail("with a queue the door should have a time window")
				_type(w[0])
				if _main.mode != _main.Mode.INSIDE: return _fail("typing the door word should enter")
				_step = "inside"
		"inside":
			if _main._searching:
				_auto_returns += 1
			# rooms have zombies now: doors are suspended while any is targetable, so shoot first
			if _typist.in_combat():
				var director := _main.get_node("View/Viewport/World/Director")
				director._update_los()
				for z in director.targetable():
					var rem: String = z.word.substr(z.typed)
					_type(rem)
					_kills += 1
				return
			if (_player.is_moving() and not _player.halt) or _main._search_pending:
				return
			var w: Array = _words()
			if w.is_empty():
				return
			var ri: int = _interior.current_room
			if _expect_landing:
				_expect_landing = false
				if not _interior.plan.rooms[ri].is_stair: return _fail("a climb should end on the stairwell landing")
			print("room ", ri, " (", _interior.plan.rooms[ri].kind, ") floor ", _interior.plan.floor, " options: ", w, "  progress ", _interior.progress(), "  old floor alive: ", _interior._old_floor != null)
			if _interior._old_floor != null: return _fail("old floor should be dropped after arriving")
			if _typist.buffer != "": return _fail("buffer should be empty between prompts")
			if (w.has("up") or w.has("down")) and _interior.plan.stair_opening(ri) < 0 and not _interior.plan.rooms[ri].is_stair:
				return _fail("up/down offered without a door into the stairwell")
			if _interior.plan.rooms[ri].is_stair:
				var director := _main.get_node("View/Viewport/World/Director")
				for z in director.alive():
					if z.room == ri and z.state == z.State.DORMANT:
						return _fail("zombies must not spawn in the stairwell")
			# the search rule: a closed door worth opening is offered here, or we were walked
			# to a room that has one (or the stairwell / exit)
			var unexplored: Array = _interior.unexplored_doors(ri)
			var door_word := ""
			if not unexplored.is_empty():
				door_word = _interior.plan.doors[unexplored[0]].word
				if not w.has(door_word): return _fail("unexplored door word missing from prompts")
			if w.has("up") and not _climbed:
				_climbed = true
				var seen_before: int = _main.get_node("View/Viewport/World/Director").alive().size()
				_floor_before = _interior.plan.floor
				_type("up")
				if not _player.is_moving(): return _fail("up should start the climb")
				if _interior.plan.floor != _floor_before + 1: return _fail("up should build the storey above right away")
				_expect_landing = true
				print("climbing (%s stairwell); old floor kept: %s  zombies seeded before: %d" % ["core" if _interior.plan.stair_layout["kind"] == 0 else "wall", _interior._old_floor != null, seen_before])
				return
			if door_word != "" and (_opened_doors < 12 or _interior.plan.floor >= 1):
				_opened_doors += 1
				_type(door_word)
				if not _player.is_moving(): return _fail("typing a door word should start moving")
				return
			if _climbed and w.has("down"):
				_type("down")
				return
			if w.has("exit"):
				_type("exit")
				_step = "exiting"
				return
			# nothing worth typing here: the rail must bring us somewhere useful by itself
			_idle += 1
			if _idle > 400: return _fail("stuck in room %d with options %s and no auto-return" % [ri, w])
		"exiting":
			# anything in sight on the way out holds the rail until it is shot
			if _typist.in_combat():
				var director := _main.get_node("View/Viewport/World/Director")
				director._update_los()
				for z in director.targetable():
					_type(z.word.substr(z.typed))
					_kills += 1
				return
			if _main.mode == _main.Mode.STREET and not _interior.is_inside():
				if not _climbed: return _fail("never climbed")
				print("auto-return legs seen: ", _auto_returns, "  doors opened: ", _opened_doors)
				if _auto_returns == 0: return _fail("the search never walked us back from a dead end")
				var st: Dictionary = World.state[_queued[0]]
				print("exited; state: ", st.keys(), " progress ", st.get("progress"))
				if not st.has("floors"): return _fail("building state should record floors")
				_step = "arrive2"
		"arrive2":
			if _main.mode == _main.Mode.DOOR:
				print("second door: ", _words(), " window: ", _main.door_timer, "  zombies shot inside: ", _kills, "  main.kills=", _main.kills)
				if _main.door_timer > 0.0: return _fail("last stop should not have a window")
				if _main.door_building.id() != _queued[1]: return _fail("should be at the second building")
				print("INTERIOR OK")
				get_tree().quit(0)
