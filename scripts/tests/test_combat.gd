extends Node
## Headless combat test:  Godot --headless --path . res://scenes/tests/test_combat.tscn
## Spawns a zombie in front of the player, types its word letter by letter (stun lock,
## kill), then lets one attack to verify damage. Exit 0 = pass.

var _main: Node
var _player: Node3D
var _typist: Node
var _director: Node3D
var _step := "spawn"
var _frames := 0
var _z: Zombie
var _z2: Zombie
var _z3: Zombie
var _z4: Zombie
var _door := Vector3.ZERO
var _t0 := 0
var _hp0 := 0


func _ready() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	add_child(_main)
	_player = _main.get_node("View/Viewport/World/Player")
	_typist = _main.get_node("Typist")
	_director = _main.get_node("View/Viewport/World/Director")
	_director.set_meta("no_street", true)
	_director.street_spawning = false


func _fail(msg: String) -> void:
	print("TEST FAIL: " + msg)
	get_tree().quit(1)


func _key(ch: String) -> void:
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.keycode = KEY_A + (ch.unicode_at(0) - 97)
	_typist._input(ev)


func _process(_dt: float) -> void:
	_frames += 1
	if _frames > 4000:
		return _fail("timeout at " + _step)
	match _step:
		"spawn":
			if _frames < 5:
				return
			_director.street_spawning = false
			var f: Vector3 = _player.facing
			var pos: Vector3 = _player.global_position + f * 6.0
			_z = _director._spawn(ZombieType.runner(), pos)
			print("spawned '", _z.word, "' at ", pos, " player facing ", f)
			_step = "los"
		"los":
			if _frames % 3 != 0:
				return
			_director._update_los()
			if _z.in_los:
				print("in LOS after frame ", _frames, "; targetable=", _director.targetable().size())
				if not _typist.in_combat(): return _fail("typist should be in combat")
				_step = "type"
			elif _frames > 200:
				return _fail("zombie never entered line of sight")
		"type":
			var ch: String = _z.word[0]
			_key(ch)
			if _z.typed != 1: return _fail("first letter should register a hit")
			if _z.state != Zombie.State.STUN: return _fail("hit should stun")
			if _typist.locked != _z: return _fail("first letter should lock the target")
			var wrong := "z" if _z.word[1] != "z" else "q"
			var before_typed: int = _z.typed
			_key(wrong)
			if _z.typed != before_typed: return _fail("wrong letter must not advance")
			# drop the lock (as a hit would) and make sure the half-typed word can be picked up again
			_typist.locked.set_locked(false)
			_typist.locked = null
			_key(_z.word[1])
			if _typist.locked != _z or _z.typed != 2: return _fail("a dropped lock must re-lock on the NEXT letter")
			if not _player.halt: return _fail("the rail should halt while a zombie is in sight")
			for i in range(1, _z.word.length()):
				_key(_z.word[i])
			if _z.is_alive(): return _fail("finishing the word should kill")
			if _main.kills != 1: return _fail("kill should be counted")
			print("killed with the full word; kills=", _main.kills)
			_hp0 = _main.hp
			var pos: Vector3 = _player.global_position + _player.facing * 1.0
			_z2 = _director._spawn(ZombieType.runner(), pos)
			_step = "bite"
		"bite":
			# fairness: the word must be on screen (clamped if need be) and readable for a
			# beat before the zombie may land a hit
			var cam: Camera3D = _main.get_node("View/Viewport").get_camera_3d()
			var a: Dictionary = WordOverlay.anchor_for(cam, _z2.label.global_position, Vector2(640, 360), Vector2(1280, 720), true)
			if _z2.label.visible and not a["on_screen"]: return _fail("a zombie in your face must still have its word on screen")
			if _main.hp < _hp0:
				print("took damage: ", _hp0, " -> ", _main.hp, "  zombie state ", _z2.state, "  invuln ", _main._invuln, "  word readable for %.2fs" % _z2._label_time)
				if _main._invuln <= 0.0: return _fail("a hit should grant i-frames")
				if _z2._label_time < Zombie.FAIR_READ: return _fail("hit landed before the word was readable long enough")
				_step = "relock"
			elif _frames > 800:
				return _fail("zombie in range never dealt damage (state %s)" % _z2.state)
		"relock":
			# after the hit the lock dropped; the next letter must re-acquire it
			_director._update_los()
			if not _z2.in_los or _z2.state == Zombie.State.STRIKE:
				return
			var ch: String = _z2.next_letter()
			_key(ch)
			if _typist.locked != _z2: return _fail("could not re-lock after being hit (typed=%d)" % _z2.typed)
			print("re-locked after a hit on '", ch, "'  typed=", _z2.typed)
			# word clamping: a zombie half a metre away has its label far above the view
			var cam: Camera3D = _main.get_node("View/Viewport").get_camera_3d()
			var near_label: Vector3 = _player.global_position + _player.facing * 0.5 + Vector3(0, 2.15, 0)
			var a: Dictionary = WordOverlay.anchor_for(cam, near_label, Vector2(640, 360), Vector2(1280, 720), true)
			var b: Dictionary = WordOverlay.anchor_for(cam, near_label, Vector2(640, 360), Vector2(1280, 720), false)
			if not a["on_screen"] or b["on_screen"]: return _fail("keep_on_screen should clamp an off-screen word (%s / %s)" % [a, b])
			# the throw: a zombie behind a kicked door is flung back and stunned
			_door = _player.global_position + _player.facing * 4.0
			_z3 = _director._spawn(ZombieType.runner(), _door + _player.facing * 1.2)
			_z3.startle(_door)
			_t0 = Time.get_ticks_msec()
			_step = "throw"
		"throw":
			var el := (Time.get_ticks_msec() - _t0) / 1000.0
			if el > 0.6 and el < 0.9:
				if _z3.state != Zombie.State.STUN: return _fail("thrown zombie should be stunned")
				var d := _z3.global_position.distance_to(_door)
				if d < 2.4: return _fail("thrown zombie should land well back (%.2f m)" % d)
			if el > Zombie.THROW_STUN + 0.4:
				if _z3.state != Zombie.State.CHASE: return _fail("thrown zombie should get up and chase (state %s)" % _z3.state)
				print("throw: landed %.2f m from the door, stunned, then up" % _z3.global_position.distance_to(_door))
				# the notice beat: a dormant zombie that spots you stares before it charges
				_z4 = _director._spawn(ZombieType.runner(), _player.global_position + _player.facing * 5.0, -1, true)
				_z4.wake()
				if _z4.state != Zombie.State.STUN: return _fail("waking should start with a beat, not a charge")
				_t0 = Time.get_ticks_msec()
				_step = "notice"
		"notice":
			var el := (Time.get_ticks_msec() - _t0) / 1000.0
			if el < Zombie.NOTICE_BEAT * 0.6 and _z4.state != Zombie.State.STUN:
				return _fail("zombie charged during its notice beat")
			if el > Zombie.NOTICE_BEAT + 0.4:
				if _z4.state != Zombie.State.CHASE: return _fail("zombie should charge after the beat (state %s)" % _z4.state)
				print("notice beat held %.1fs, then charged" % Zombie.NOTICE_BEAT)
				print("COMBAT OK")
				get_tree().quit(0)
