class_name SurvivorCue
extends Node3D
## Drop-in positional rescue cue. Add it to the rendered 3D world, call configure(), and
## resolve() when the survivor is safe. Cadence and pitch are stable for a given id/position.

signal cue_emitted(target_id: String, world_position: Vector3)

const DEFAULT_STREAM: AudioStream = preload("res://assets/audio/knock.wav")

@export var cue_stream: AudioStream = DEFAULT_STREAM
@export_range(-60.0, 6.0, 0.5) var volume_db := -16.0
@export_range(2.0, 80.0, 0.5) var max_distance := 30.0
@export_range(0.5, 30.0, 0.1) var interval_min := 5.5
@export_range(0.5, 30.0, 0.1) var interval_max := 9.0
@export_range(0.05, 1.0, 0.01) var knock_gap := 0.28

var target_id := ""
var listener: Node3D
var unresolved := false
var emitted_count := 0  # useful to mission controllers and deterministic tests

var _target_position := Vector3.ZERO
var _player: AudioStreamPlayer3D
var _rng := RandomNumberGenerator.new()
var _cue_timer := 0.0
var _burst_timer := 0.0
var _burst_remaining := 0


func _ready() -> void:
	_ensure_player()
	_apply_target_position()
	set_process(unresolved)


## stable_id should be the survivor/object's persistent procedural id. listener_node is
## optional; when supplied, inaudible cues are not played outside max_distance.
func configure(stable_id: String, world_position: Vector3, listener_node: Node3D = null, starts_unresolved := true) -> SurvivorCue:
	target_id = stable_id
	listener = listener_node
	_target_position = world_position
	_seed_rng()
	_schedule_next(true)
	_apply_target_position()
	set_unresolved(starts_unresolved)
	return self


func set_target_position(world_position: Vector3) -> void:
	_target_position = world_position
	_apply_target_position()


func target_position() -> Vector3:
	return _target_position


func set_listener(listener_node: Node3D) -> void:
	listener = listener_node


func set_unresolved(value: bool) -> void:
	if unresolved == value:
		set_process(value)
		if not value:
			_stop_audio()
		return
	unresolved = value
	set_process(value)
	if value:
		if _cue_timer <= 0.0:
			_schedule_next(true)
	else:
		_stop_audio()


func resolve() -> void:
	set_unresolved(false)


func is_unresolved() -> bool:
	return unresolved


func seconds_until_cue() -> float:
	return _cue_timer


## Immediate mission-script hook. Returns false when resolved or out of audible range.
func trigger_now() -> bool:
	if not unresolved or not _listener_in_range():
		return false
	_start_burst()
	_schedule_next(false)
	return true


func audio_player() -> AudioStreamPlayer3D:
	_ensure_player()
	return _player


func _process(dt: float) -> void:
	if not unresolved:
		return
	if _burst_remaining > 0:
		_burst_timer -= dt
		if _burst_timer <= 0.0:
			_play_pulse()
			_burst_remaining -= 1
			_burst_timer = knock_gap
		return
	_cue_timer -= dt
	if _cue_timer > 0.0:
		return
	if _listener_in_range():
		_start_burst()
	_schedule_next(false)


func _ensure_player() -> void:
	if is_instance_valid(_player):
		return
	_player = AudioStreamPlayer3D.new()
	_player.name = "DirectionalRescueCue"
	_player.bus = "Master"
	_player.stream = cue_stream
	_player.volume_db = volume_db
	_player.unit_size = 2.5
	_player.max_distance = max_distance
	_player.panning_strength = 1.8
	_player.attenuation_filter_cutoff_hz = 3600.0
	_player.attenuation_filter_db = -12.0
	add_child(_player)


func _apply_target_position() -> void:
	if is_inside_tree():
		global_position = _target_position
	else:
		position = _target_position


func _seed_rng() -> void:
	var seed_value := _stable_string_hash(target_id)
	seed_value ^= int(round(_target_position.x * 10.0)) * 73856093
	seed_value ^= int(round(_target_position.y * 10.0)) * 19349663
	seed_value ^= int(round(_target_position.z * 10.0)) * 83492791
	_rng.seed = seed_value


func _schedule_next(initial: bool) -> void:
	var lo := minf(interval_min, interval_max)
	var hi := maxf(interval_min, interval_max)
	var scale := 0.55 if initial else 1.0
	_cue_timer = _rng.randf_range(lo * scale, hi * scale)


func _listener_in_range() -> bool:
	if listener == null:
		return true  # AudioStreamPlayer3D still performs its own listener attenuation.
	if not is_instance_valid(listener):
		return false
	return listener.global_position.distance_to(_target_position) <= max_distance


func _start_burst() -> void:
	_play_pulse()
	_burst_remaining = 1 + _rng.randi_range(0, 1)  # two or three restrained knocks total
	_burst_timer = knock_gap


func _play_pulse() -> void:
	if not unresolved:
		return
	_ensure_player()
	_player.stream = cue_stream
	_player.volume_db = volume_db
	_player.max_distance = max_distance
	_player.pitch_scale = _rng.randf_range(0.94, 1.04)
	_player.play()
	emitted_count += 1
	cue_emitted.emit(target_id, _target_position)


func _stop_audio() -> void:
	_burst_remaining = 0
	_burst_timer = 0.0
	if is_instance_valid(_player):
		_player.stop()


static func _stable_string_hash(text: String) -> int:
	# FNV-1a avoids relying on runtime hash randomization for procedural cadence.
	var value := 2166136261
	for byte in text.to_utf8_buffer():
		value = (value ^ int(byte)) * 16777619
	return value
