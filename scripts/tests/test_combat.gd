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
	if _frames > 3000:
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
			if _main.hp < _hp0:
				print("took damage: ", _hp0, " -> ", _main.hp, "  zombie state ", _z2.state, "  invuln ", _main._invuln)
				if _main._invuln <= 0.0: return _fail("a hit should grant i-frames")
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
			print("COMBAT OK")
			get_tree().quit(0)
