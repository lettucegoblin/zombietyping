extends Node
## Sound: a pool of players for one-shots (with pitch jitter), distance-faded one-shots for
## things in the world, and two ambient loops (wind outside, drone inside) that crossfade.
## Streams are the procedural placeholders from tools/make_sounds.py.

const DIR := "res://assets/audio/"
const POOL := 10

var player: Node3D
var _streams: Dictionary = {}
var _pool: Array[AudioStreamPlayer] = []
var _wind: AudioStreamPlayer
var _hum: AudioStreamPlayer
var _inside := false
var _step_t := 0.0
var _step_alt := false


func _ready() -> void:
	add_to_group("sfx")
	for i in POOL:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_pool.append(p)
	_wind = _loop("wind", -14.0)
	_hum = _loop("hum", -60.0)


func _loop(name: String, db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	var s := _stream(name)
	if s is AudioStreamWAV:
		var w: AudioStreamWAV = s
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = w.data.size() / 2   # 16-bit mono
	p.stream = s
	p.volume_db = db
	p.autoplay = true
	add_child(p)
	p.play()
	return p


func _stream(name: String) -> AudioStream:
	if _streams.has(name):
		return _streams[name]
	var path := DIR + name + ".wav"
	var s: AudioStream = load(path) if ResourceLoader.exists(path) else null
	_streams[name] = s
	return s


## One-shot, no position. pitch_var = random +-fraction (0.08 = +-8%).
func play(name: String, db := 0.0, pitch_var := 0.0, pitch := 1.0) -> void:
	var s := _stream(name)
	if s == null:
		return
	var p: AudioStreamPlayer = _pool[0]   # all busy: steal the first
	for c in _pool:
		if not c.playing:
			p = c
			break
	p.stream = s
	p.volume_db = db
	p.pitch_scale = pitch * (1.0 + randf_range(-pitch_var, pitch_var))
	p.play()


## One-shot from a world position: fades with distance to the survivor.
func play_at(name: String, pos: Vector3, db := 0.0, pitch_var := 0.0, pitch := 1.0, max_dist := 26.0) -> void:
	if player == null:
		return play(name, db, pitch_var, pitch)
	var d := pos.distance_to(player.global_position)
	if d > max_dist:
		return
	var att := clampf((d - 2.5) / (max_dist - 2.5), 0.0, 1.0)
	play(name, db - att * 26.0, pitch_var, pitch)


func set_inside(v: bool) -> void:
	if v == _inside:
		return
	_inside = v
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_wind, "volume_db", -30.0 if v else -14.0, 0.9)
	tw.tween_property(_hum, "volume_db", -16.0 if v else -60.0, 0.9)


## Footsteps while the rail moves (call every frame with the current speed in m/s).
func footsteps(dt: float, speed: float) -> void:
	if speed <= 0.1:
		_step_t = 0.15
		return
	_step_t -= dt
	if _step_t <= 0.0:
		_step_t = clampf(0.62 - speed * 0.04, 0.3, 0.6)
		_step_alt = not _step_alt
		play("step1" if _step_alt else "step2", -18.0 if _inside else -22.0, 0.12)
