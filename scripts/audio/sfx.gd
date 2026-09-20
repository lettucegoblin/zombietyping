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
var _next_event := 6.0
var _siren_t := 40.0
var _rng := RandomNumberGenerator.new()
## Random ambience events: [name, min gap, max gap, db, pitch var]
const OUTSIDE_EVENTS := [
	["crow1", -16.0, 0.12], ["crow2", -18.0, 0.12], ["flutter", -20.0, 0.15],
	["groan_far", -22.0, 0.2], ["clank", -24.0, 0.2], ["crow1", -20.0, 0.1],
]
const INSIDE_EVENTS := [
	["drip", -18.0, 0.25], ["drip", -22.0, 0.3], ["creak2", -20.0, 0.15],
	["thump", -20.0, 0.1], ["knock", -24.0, 0.1], ["groan_far", -26.0, 0.2],
]


func _ready() -> void:
	add_to_group("sfx")
	for i in POOL:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_pool.append(p)
	_wind = _loop("wind", -14.0)
	_hum = _loop("room", -60.0)
	_next_event = 4.0


func _loop(name: String, db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	var s := _stream(name)
	if s is AudioStreamWAV:
		var w: AudioStreamWAV = s
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		# in samples; the imported data is QOA-compressed, so never derive this from data.size()
		w.loop_end = int(round(w.get_length() * w.mix_rate))
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
	tw.tween_property(_wind, "volume_db", -34.0 if v else -14.0, 0.9)
	tw.tween_property(_hum, "volume_db", -13.0 if v else -60.0, 0.9)


## Distant life: crows, a flutter of pigeons, a far groan or clank outside; drips, creaks
## and thumps inside. Call every frame.
func atmosphere(dt: float) -> void:
	_next_event -= dt
	if _next_event <= 0.0:
		var table: Array = INSIDE_EVENTS if _inside else OUTSIDE_EVENTS
		var e: Array = table[_rng.randi_range(0, table.size() - 1)]
		play(e[0], e[1], e[2])
		_next_event = _rng.randf_range(4.0, 11.0) if _inside else _rng.randf_range(5.0, 14.0)
	_siren_t -= dt
	if _siren_t <= 0.0:
		_siren_t = _rng.randf_range(70.0, 160.0)
		if not _inside:
			play("siren", -30.0, 0.05)


## Birds flapping off a roof nearby (called by the sky life when a flock takes off).
func flock_takeoff(pos: Vector3) -> void:
	play_at("flutter", pos, -8.0, 0.15, 1.0, 40.0)
	if _rng.randf() < 0.6:
		play_at("crow1" if _rng.randf() < 0.5 else "crow2", pos, -8.0, 0.12, 1.0, 45.0)


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
