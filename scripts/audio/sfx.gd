extends Node
## Layered soundscape: local UI/player one-shots, real 3D world one-shots, and ambience beds
## that crossfade by indoor/outdoor state and semantic room use. Generated televisions own
## their directional static players; this node deliberately keeps interiors free of hiss.

const DIR := "res://assets/audio/"
const POOL := 10

var player: Node3D
var _streams: Dictionary = {}
var _pool: Array[AudioStreamPlayer] = []
var _world_pool: Array[AudioStreamPlayer3D] = []
var _wind: AudioStreamPlayer
var _room: AudioStreamPlayer
var _electric: AudioStreamPlayer
var _pipes: AudioStreamPlayer
var _inside := false
var _room_kind := ""
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
	["creak2", -24.0, 0.12], ["thump", -24.0, 0.08],
	["knock", -28.0, 0.08], ["groan_far", -30.0, 0.16],
]
const ROOM_EVENTS := {
	"bathroom": [["drip", -17.0, 0.16], ["drip", -21.0, 0.22], ["knock", -25.0, 0.08]],
	"kitchen": [["drip", -23.0, 0.16], ["knock", -27.0, 0.08], ["creak2", -25.0, 0.10]],
	"stair": [["creak2", -18.0, 0.10], ["thump", -24.0, 0.08], ["knock", -27.0, 0.08]],
	"hall": [["creak2", -22.0, 0.10], ["thump", -25.0, 0.08], ["groan_far", -31.0, 0.15]],
	"storage": [["clank", -25.0, 0.14], ["thump", -23.0, 0.08], ["creak2", -25.0, 0.10]],
	"workshop": [["clank", -21.0, 0.14], ["thump", -23.0, 0.08], ["knock", -27.0, 0.08]],
}
const POWERED_ROOMS := ["kitchen", "living", "studio", "office", "conference", "sales", "lobby", "workshop"]
const WET_ROOMS := ["bathroom", "kitchen", "studio"]


func _ready() -> void:
	add_to_group("sfx")
	for i in POOL:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_pool.append(p)
	_wind = _loop("wind", -14.0)
	_room = _loop("room", -60.0)
	_electric = _loop("electric", -60.0)
	_pipes = _loop("pipes", -60.0)
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


## Create positional players inside the rendered 3D world. Sfx itself lives above the
## SubViewport, so parenting these to the player's world is required for actual panning.
func _ensure_world_pool() -> bool:
	if not _world_pool.is_empty():
		return true
	if player == null or player.get_parent() == null:
		return false
	for i in POOL:
		var p := AudioStreamPlayer3D.new()
		p.name = "WorldSound%d" % i
		p.bus = "Master"
		p.unit_size = 2.5
		p.max_distance = 32.0
		p.panning_strength = 1.7
		p.attenuation_filter_cutoff_hz = 4200.0
		p.attenuation_filter_db = -10.0
		player.get_parent().add_child(p)
		_world_pool.append(p)
	return true


## One-shot from a world position with real stereo direction and distance filtering.
func play_at(name: String, pos: Vector3, db := 0.0, pitch_var := 0.0, pitch := 1.0, max_dist := 26.0) -> void:
	if player == null or not _ensure_world_pool():
		return play(name, db, pitch_var, pitch)
	var d := pos.distance_to(player.global_position)
	if d > max_dist:
		return
	var s := _stream(name)
	if s == null:
		return
	var p: AudioStreamPlayer3D = _world_pool[0]
	for c in _world_pool:
		if not c.playing:
			p = c
			break
	p.stream = s
	p.global_position = pos
	p.volume_db = db
	p.pitch_scale = pitch * (1.0 + randf_range(-pitch_var, pitch_var))
	p.max_distance = max_dist
	p.play()


## Place an ambience event in a stable-feeling ring around the survivor rather than in the
## centre of their head. Vertical variation helps upstairs/behind-you events read clearly.
func play_near(name: String, db: float, pitch_var: float, near := 5.0, far := 13.0) -> void:
	if player == null:
		return play(name, db, pitch_var)
	var a := _rng.randf_range(-PI, PI)
	var dist := _rng.randf_range(near, far)
	var pos := player.global_position + Vector3(cos(a) * dist, _rng.randf_range(-1.0, 2.2), sin(a) * dist)
	play_at(name, pos, db, pitch_var, 1.0, far + 12.0)


func set_inside(v: bool, room_kind := "") -> void:
	if v == _inside and room_kind == _room_kind:
		return
	_inside = v
	_room_kind = room_kind if v else ""
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_wind, "volume_db", -40.0 if v else -14.0, 1.1)
	tw.tween_property(_room, "volume_db", -25.0 if v else -60.0, 1.1)
	tw.tween_property(_electric, "volume_db", -31.0 if v and _room_kind in POWERED_ROOMS else -60.0, 0.8)
	tw.tween_property(_pipes, "volume_db", -29.0 if v and _room_kind in WET_ROOMS else -60.0, 0.8)
	_next_event = minf(_next_event, 3.0)


## Distant life: crows, a flutter of pigeons, a far groan or clank outside; drips, creaks
## and thumps inside. Call every frame.
func atmosphere(dt: float) -> void:
	_next_event -= dt
	if _next_event <= 0.0:
		var table: Array = ROOM_EVENTS.get(_room_kind, INSIDE_EVENTS) if _inside else OUTSIDE_EVENTS
		var e: Array = table[_rng.randi_range(0, table.size() - 1)]
		if _inside:
			play_near(e[0], e[1], e[2], 3.5, 10.0)
		else:
			play_near(e[0], e[1], e[2], 8.0, 22.0)
		_next_event = _rng.randf_range(7.0, 16.0) if _inside else _rng.randf_range(6.0, 16.0)
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
