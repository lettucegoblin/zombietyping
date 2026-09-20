extends Node3D
## Sky life: big slow clouds far out over the city, and flocks of crows that circle the
## streets, land along rooftop edges, sit a while and take off again when you come close
## or a shot goes off nearby.

const CLOUDS := 7
const FLOCKS := 3
const CLOUD_DIST := Vector2(230.0, 330.0)
const CLOUD_HEIGHT := Vector2(70.0, 115.0)
const BIRD_PIXEL := 0.032

var player: Node3D
var sfx: Node
var _clouds: Array = []          # [{node, off}]
var _flocks: Array = []
var _fly: Array[Texture2D] = []
var _perch: Array[Texture2D] = []
var _rng := RandomNumberGenerator.new()


class Bird:
	var node: MeshInstance3D
	var mat: StandardMaterial3D
	var phase := 0.0
	var radius := 3.0
	var lift := 0.0
	var pos := Vector3.ZERO
	var perch := Vector3.ZERO
	var pose := 0
	var flap := 0.0
	var last := Vector3.ZERO


class Flock:
	enum { FLY, LAND, PERCHED, TAKEOFF }
	var birds: Array = []
	var centre := Vector3.ZERO
	var target := Vector3.ZERO
	var state := FLY
	var timer := 0.0
	var roof := Vector3.ZERO


func _ready() -> void:
	_rng.seed = 4242
	for i in 2:
		_fly.append(load("res://assets/sprites/sky/crow_fly_%d.png" % i))
	for i in 3:
		_perch.append(load("res://assets/sprites/sky/crow_perch_%d.png" % i))
	for i in CLOUDS:
		var tex: Texture2D = load("res://assets/sprites/sky/cloud_%d.png" % (i % 2))
		var m := _quad(tex, 0.6 + _rng.randf() * 0.35, true)
		add_child(m)
		var ang := _rng.randf_range(0.0, TAU)
		var d := _rng.randf_range(CLOUD_DIST.x, CLOUD_DIST.y)
		_clouds.append({ "node": m, "off": Vector3(cos(ang) * d, _rng.randf_range(CLOUD_HEIGHT.x, CLOUD_HEIGHT.y), sin(ang) * d) })
	for i in FLOCKS:
		var f := Flock.new()
		var n := _rng.randi_range(4, 7)
		for k in n:
			var b := Bird.new()
			b.node = _quad(_fly[0], BIRD_PIXEL, false)
			b.mat = b.node.material_override
			b.phase = _rng.randf_range(0.0, TAU)
			b.radius = _rng.randf_range(1.5, 5.0)
			b.lift = _rng.randf_range(-1.5, 1.5)
			b.flap = _rng.randf_range(0.0, 1.0)
			b.pose = _rng.randi_range(0, 2)
			add_child(b.node)
			f.birds.append(b)
		f.centre = Vector3(0, 18, 0)
		f.timer = _rng.randf_range(0.0, 6.0)
		_flocks.append(f)


func _quad(tex: Texture2D, pixel: float, fogless: bool) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(tex.get_width(), tex.get_height()) * pixel
	m.mesh = q
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.5
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.disable_fog = fogless
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.material_override = mat
	return m


func _process(dt: float) -> void:
	if player == null:
		return
	var pp: Vector3 = player.global_position
	# clouds: parked far out, drifting with the wind, wrapping around you
	for c in _clouds:
		var off: Vector3 = c["off"]
		off.x += dt * 1.1
		if off.x > CLOUD_DIST.y:
			off.x = -CLOUD_DIST.y
			off.z = _rng.randf_range(-CLOUD_DIST.y, CLOUD_DIST.y)
		c["off"] = off
		(c["node"] as Node3D).global_position = Vector3(pp.x, 0, pp.z) + off
	for f in _flocks:
		_flock(f, dt, pp)


func _flock(f: Flock, dt: float, pp: Vector3) -> void:
	f.timer -= dt
	match f.state:
		Flock.FLY:
			if f.centre.distance_to(f.target) < 4.0 or f.timer <= 0.0:
				# wander around you; sometimes pick a roof to land on
				var roof := _roof_point(pp) if _rng.randf() < 0.4 else Vector3.INF
				if roof != Vector3.INF:
					f.roof = roof
					f.target = roof + Vector3(0, 2.5, 0)
					f.state = Flock.LAND
				else:
					var ang := _rng.randf_range(0.0, TAU)
					var d := _rng.randf_range(22.0, 70.0)
					f.target = pp + Vector3(cos(ang) * d, _rng.randf_range(12.0, 26.0), sin(ang) * d)
					f.timer = _rng.randf_range(8.0, 16.0)
			_steer(f, dt, 5.5)
			_orbit(f, dt, 1.0)
		Flock.LAND:
			_steer(f, dt, 5.0)
			if f.centre.distance_to(f.target) < 2.0:
				f.state = Flock.PERCHED
				f.timer = _rng.randf_range(9.0, 26.0)
				var i := 0
				for b in f.birds:
					b.perch = _perch_slot(f.roof, i)
					b.pose = _rng.randi_range(0, 2)
					i += 1
			else:
				_orbit(f, dt, 0.6)
		Flock.PERCHED:
			var scared := f.roof.distance_to(pp) < 13.0
			for b in f.birds:
				b.pos = b.pos.lerp(b.perch, minf(dt * 3.0, 1.0))
				_show_perched(b)
			if scared or f.timer <= 0.0:
				_takeoff(f, pp)
		Flock.TAKEOFF:
			_steer(f, dt, 6.0)
			_orbit(f, dt, 1.4)
			if f.timer <= 0.0:
				f.state = Flock.FLY
				f.timer = 0.0


func _steer(f: Flock, dt: float, speed: float) -> void:
	var to := f.target - f.centre
	var d := to.length()
	if d > 0.01:
		f.centre += to / d * minf(speed * dt, d)


## Birds wheel around the flock centre; the sprite flips to face the way it moves and
## squashes with the wingbeat so the flap reads at a distance.
func _orbit(f: Flock, dt: float, rate: float) -> void:
	var cam := get_viewport().get_camera_3d()
	var right: Vector3 = cam.global_transform.basis.x if cam != null else Vector3.RIGHT
	for b in f.birds:
		b.phase += dt * rate * (0.9 + 0.2 * b.radius / 5.0)
		var goal := f.centre + Vector3(cos(b.phase) * b.radius, b.lift + sin(b.phase * 1.7) * 0.9, sin(b.phase) * b.radius)
		b.last = b.pos
		b.pos = b.pos.lerp(goal, minf(dt * 4.0, 1.0)) if b.pos != Vector3.ZERO else goal
		b.flap += dt * 9.0
		var frame := int(b.flap) % 2
		b.mat.albedo_texture = _fly[frame]
		var vel: Vector3 = b.pos - b.last
		var facing_right: bool = vel.dot(right) >= 0.0
		b.mat.uv1_scale = Vector3(1.0 if facing_right else -1.0, 1.0, 1.0)
		b.mat.uv1_offset = Vector3(0.0 if facing_right else 1.0, 0.0, 0.0)
		b.node.scale = Vector3(1.0, 0.7 + 0.3 * absf(sin(b.flap * PI)), 1.0)
		b.node.global_position = b.pos


func _show_perched(b: Bird) -> void:
	b.mat.albedo_texture = _perch[b.pose]
	b.node.scale = Vector3.ONE
	b.node.global_position = b.pos


func _takeoff(f: Flock, pp: Vector3) -> void:
	f.state = Flock.TAKEOFF
	f.timer = 2.5
	var ang := _rng.randf_range(0.0, TAU)
	f.target = f.roof + Vector3(cos(ang) * 14.0, 12.0, sin(ang) * 14.0)
	f.centre = f.roof + Vector3(0, 1.5, 0)
	if sfx != null:
		sfx.flock_takeoff(f.roof)


## A shot / loud noise: perched flocks within `radius` take off.
func startle(pos: Vector3, radius: float) -> void:
	for f in _flocks:
		if f.state == Flock.PERCHED and f.roof.distance_to(pos) < radius:
			_takeoff(f, pos)


## The middle of a rooftop edge of some building near you (world space), or INF.
func _roof_point(pp: Vector3) -> Vector3:
	var sec := World.sector_of_tile(World.world_to_tile(pp))
	var best := Vector3.INF
	var tries := 0
	while tries < 12:
		tries += 1
		var sd := World.get_sector(sec.x + _rng.randi_range(-1, 1), sec.y + _rng.randi_range(-1, 1))
		if sd.buildings.is_empty():
			continue
		var b: BuildingData = sd.buildings[_rng.randi_range(0, sd.buildings.size() - 1)]
		var fpr := InteriorGen.footprint(b)
		var c := Vector3(fpr.get_center().x, 0, fpr.get_center().y)
		if c.distance_to(pp) > 75.0 or c.distance_to(pp) < 10.0:
			continue
		var h := b.floors * World.FLOOR_M + 0.15
		# one of the four edges
		var side := _rng.randi_range(0, 3)
		var edge_dir := Vector3.ZERO
		var mid := Vector3.ZERO
		match side:
			0: mid = Vector3(c.x, h, fpr.position.y + 0.15); edge_dir = Vector3.RIGHT
			1: mid = Vector3(c.x, h, fpr.end.y - 0.15); edge_dir = Vector3.RIGHT
			2: mid = Vector3(fpr.position.x + 0.15, h, c.z); edge_dir = Vector3.BACK
			_: mid = Vector3(fpr.end.x - 0.15, h, c.z); edge_dir = Vector3.BACK
		_roof_edge = edge_dir
		best = mid
		break
	return best


var _roof_edge := Vector3.RIGHT


func _perch_slot(roof: Vector3, i: int) -> Vector3:
	var k := (i + 1) / 2 * (1 if i % 2 == 0 else -1)
	return roof + _roof_edge * (k * 0.75) + Vector3(0, 0.25, 0)
