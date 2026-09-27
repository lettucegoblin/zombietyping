extends Node
## Headless loop test (autoloads live):
##   Godot --headless --path . res://scenes/tests/test_gameloop.tscn
## Boots main.tscn, opens the map, assigns labels, types two destinations, then lets the
## engine run (time_scale 30x) until the player arrives at both. Exit code 0 = pass.

var _main: Node
var _player: Node3D
var _map: Control
var _queued: Array = []
var _arrivals: Array[String] = []
var _explored0 := 0
var _frames := 0


func _ready() -> void:
	Engine.time_scale = 30.0
	_main = load("res://scenes/main.tscn").instantiate()
	add_child(_main)
	# This test exercises routing/map state, not combat. Organic routes can be longer than
	# the old sector grid, so disable random street encounters that would intentionally halt
	# an automated survivor which never types zombie words.
	_main.get_node("View/Viewport/World/Director").process_mode = Node.PROCESS_MODE_DISABLED
	_player = _main.get_node("View/Viewport/World/Player")
	_map = _main.get_node("UI/TabMap")
	_player.arrived.connect(func(id): _arrivals.append(id))
	call_deferred("_drive")


func _fail(msg: String) -> void:
	push_error("TEST FAIL: " + msg)
	print("TEST FAIL: " + msg)
	get_tree().quit(1)


func _drive() -> void:
	_map.size = Vector2(1280, 720)
	_main._toggle_map()
	if not (_map.visible and get_tree().paused):
		return _fail("map should be open and game paused")
	_map.recompute_labels()
	var labels: Array = _map._labels.keys()
	labels.sort()
	print("labels visible: ", labels.size(), " -> ", labels)
	if labels.size() < 4:
		return _fail("expected several labelled buildings around the start")
	var typed := "%s %s" % [labels[labels.size() - 1], labels[0]]
	print("typing: ", typed)
	_map._on_submit(typed)
	_queued = _player.queued_ids()
	print("queued ids: ", _queued)
	if _queued.size() != 2:
		return _fail("two destinations should be queued")
	_map._center += Vector2(40, 0)
	_map.recompute_labels()
	if _player.queued_ids() != _queued:
		return _fail("queue must hold stable ids, not labels")
	_main._toggle_map()
	if get_tree().paused:
		return _fail("closing the map should unpause")
	_explored0 = World.explored.size()


func _process(_dt: float) -> void:
	if _queued.is_empty():
		return
	_frames += 1
	if _arrivals.size() >= 2:
		print("arrivals: ", _arrivals, " after ", _frames, " frames")
		if _arrivals[0] != _queued[0] or _arrivals[1] != _queued[1]:
			return _fail("arrival order must match the queue")
		if World.explored.size() < _explored0:
			return _fail("fog of war should be revealed along the way")
		var st: Dictionary = World.state.get(_queued[0], {}) as Dictionary
		if not st.get("visited", false):
			return _fail("arrival should write sparse building state")
		var streamer := _main.get_node("View/Viewport/World/Streamer")
		print("state entries: ", World.state.size(), "  explored sectors: ", World.explored.size(), "  loaded sectors: ", streamer._loaded.size())
		# HUD-typed destination: a minimap label typed as keys (digit first) queues a trip
		# and moves us on from the door we are standing at
		var minimap := _main.get_node("UI/Minimap")
		minimap.size = Vector2(208, 208)
		minimap.relabel()
		var labels: Array = minimap.labels.keys()
		labels.sort()
		print("minimap labels: ", labels)
		if labels.is_empty(): return _fail("minimap should label buildings around the survivor")
		var target := ""
		for l in labels:
			if minimap.labels[l] != _queued[1]:
				target = l
				break
		if target == "": return _fail("need a second building to type")
		if not target[0].is_valid_int(): return _fail("labels must start with a digit: " + target)
		var typist := _main.get_node("Typist")
		for ch in target:
			var ev := InputEventKey.new()
			ev.pressed = true
			ev.keycode = (KEY_0 + int(ch)) if ch.is_valid_int() else (KEY_A + (ch.unicode_at(0) - 97))
			typist._input(ev)
		print("typed %s on the HUD -> queue %s  mode %s" % [target, _player.queued_ids(), _main.mode])
		if _player.queued_ids() != [minimap.labels[target]]: return _fail("HUD-typed label should queue that building")
		if _main.mode != _main.Mode.STREET: return _fail("a new destination should release the door hold")
		var cue := _main.get_node("UI/OrientationCue")
		if cue._destination_text.to_lower() != target or cue._destination_alpha < 0.9:
			return _fail("HUD-typed label was not mirrored as a centered orientation cue")
		var focus: Vector3 = _main._building_focus_point(minimap.labels[target])
		var expected_facing := (focus - _player.global_position)
		expected_facing.y = 0.0
		if expected_facing.length() > 0.01 and _player.facing.dot(expected_facing.normalized()) < 0.98:
			return _fail("HUD-typed destination did not focus the distant building")
		# Revisited building labels are struck through on the map and at the door, but the
		# door word remains a valid prompt and visibly tracks typing progress.
		if not minimap.building_visited(_queued[0]): return _fail("visited building missing minimap state")
		_player.clear_queue()
		_main._on_arrived(_queued[0])
		if _main._door_label == null or not _main._door_label.retired:
			return _fail("revisited door should be crossed out")
		if not typist.has_prompt(_main.door_word): return _fail("revisited door word should remain typeable")
		_main._door_label.match_buffer(_main.door_word.left(1))
		if _main._door_label.typed != 1: return _fail("crossed-out door should show typing progress")
		print("GAMELOOP OK")
		get_tree().quit(0)
	elif _frames > 6000:
		print("rail debug: halt=", _player.halt, " hold=", _player.hold, " moving=", _player.is_moving(),
			" current=", _player._cur, " queued=", _player._street, " mode=", _main.mode)
		_fail("timed out waiting for arrivals (%s)" % [_arrivals])
