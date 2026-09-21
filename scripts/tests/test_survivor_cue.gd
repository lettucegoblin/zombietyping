extends Node
## Standalone contract test for directional rescue audio.

const SurvivorCueScript = preload("res://scripts/audio/survivor_cue.gd")

var _failed := false


func _ready() -> void:
	var listener := Node3D.new()
	listener.position = Vector3(1.0, 1.6, 2.0)
	add_child(listener)
	var pos := Vector3(14.0, 2.0, -6.0)
	var cue: Node3D = SurvivorCueScript.new()
	add_child(cue)
	cue.configure("survivor:0,0:12:room4", pos, listener, true)

	_check(cue.is_unresolved(), "configured rescue was not active")
	_check(cue.is_processing(), "active rescue cue was not processing")
	_check(cue.global_position.is_equal_approx(pos), "cue did not keep target world position")
	var audio: AudioStreamPlayer3D = cue.audio_player()
	_check(audio is AudioStreamPlayer3D, "cue did not create a 3D audio player")
	_check(is_equal_approx(audio.max_distance, cue.max_distance), "3D attenuation range was not configured")
	_check(audio.panning_strength > 1.0, "directional stereo panning was not configured")
	_check(audio.attenuation_filter_db < 0.0, "distance filtering was not configured")

	var emitted := { "count": 0, "id": "", "pos": Vector3.ZERO }
	cue.cue_emitted.connect(func(id, world_position):
		emitted["count"] += 1
		emitted["id"] = id
		emitted["pos"] = world_position
	)
	_check(cue.trigger_now(), "nearby unresolved rescue refused an immediate cue")
	_check(cue.emitted_count == 1 and emitted["count"] == 1, "cue emission was not observable")
	_check(emitted["id"] == cue.target_id and (emitted["pos"] as Vector3).is_equal_approx(pos), "cue emitted unstable target data")

	# A stable id and position produce the same initial cadence in another component.
	var twin: Node3D = SurvivorCueScript.new()
	add_child(twin)
	twin.configure(cue.target_id, pos, listener, true)
	var reference: Node3D = SurvivorCueScript.new()
	add_child(reference)
	reference.configure(cue.target_id, pos, listener, true)
	_check(is_equal_approx(twin.seconds_until_cue(), reference.seconds_until_cue()), "procedural cadence was not deterministic")

	listener.global_position = pos + Vector3(cue.max_distance + 2.0, 0.0, 0.0)
	var before: int = cue.emitted_count
	_check(not cue.trigger_now(), "out-of-range cue played despite max distance")
	_check(cue.emitted_count == before, "inaudible cue changed emission count")

	cue.resolve()
	_check(not cue.is_unresolved(), "resolve did not clear rescue state")
	_check(not cue.is_processing(), "resolved rescue kept processing")
	_check(not cue.trigger_now(), "resolved rescue emitted another cue")
	_check(not audio.playing, "resolved rescue did not stop current audio")

	var moved := Vector3(-9.0, 0.8, 21.0)
	cue.set_target_position(moved)
	_check(cue.target_position().is_equal_approx(moved), "target position API did not update")
	_check(cue.global_position.is_equal_approx(moved), "3D emitter did not follow target position")

	if not _failed:
		print("SURVIVOR CUE OK  positional attenuation + deterministic unresolved gating")
	get_tree().quit(1 if _failed else 0)


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error("SURVIVOR CUE FAIL: " + message)
