extends Node3D
## Spawns zombies, tracks line of sight from the camera, hands words out, and serves
## the Typist's targeting queries. Outdoors it spawns ahead of the player on road tiles;
## indoors it seeds rooms deterministically when they are entered.

signal zombie_killed(z: Zombie)
signal zombie_spawned(z: Zombie)

var player: Node3D
var interior: Node3D
var zombies: Array[Zombie] = []
var street_spawning := true
var max_street := 3
const ENGAGE_RANGE := 14.0   ## metres: words only go live inside this
var rng := RandomNumberGenerator.new()
var _spawn_timer := 5.0
var _los_frame := 0


func _ready() -> void:
	rng.seed = World.seed ^ 0xC0FFEE


func alive() -> Array[Zombie]:
	var out: Array[Zombie] = []
	for z in zombies:
		if is_instance_valid(z) and not z.is_queued_for_deletion() and z.is_alive():
			out.append(z)
	return out


func targetable() -> Array[Zombie]:
	var out: Array[Zombie] = []
	for z in alive():
		if z.visible and z.in_los and z.state != Zombie.State.DORMANT:
			out.append(z)
	return out


func has_targets() -> bool:
	return not targetable().is_empty()


## A zombie in your sights close enough to matter (the rail stops for these).
func threat_within(dist: float) -> Zombie:
	var best: Zombie = null
	var bd := dist
	for z in targetable():
		var d := z.global_position.distance_to(player.global_position)
		if d < bd:
			bd = d
			best = z
	return best


## The zombie whose NEXT letter is `ch`: partially typed ones first (so a dropped lock can
## always be picked back up), then fresh words, nearest wins.
func nearest_matching(ch: String) -> Zombie:
	var best: Zombie = null
	var best_key := 1e9
	for z in targetable():
		if z.next_letter() != ch:
			continue
		var d := z.global_position.distance_to(player.global_position)
		var key := d if z.typed > 0 else d + 1000.0
		if key < best_key:
			best_key = key
			best = z
	return best


func nearest_starting_with(ch: String) -> Zombie:
	return nearest_matching(ch)


func used_first_letters() -> Dictionary:
	var d := {}
	for z in alive():
		d[z.word[0]] = true
	return d


## Nearest zombie that is up and about (any state but dormant/dead) within max_dist.
func nearest_awake(max_dist: float) -> Zombie:
	var best: Zombie = null
	var bd := max_dist
	for z in alive():
		if z.state == Zombie.State.DORMANT:
			continue
		var d := z.global_position.distance_to(player.global_position)
		if d < bd:
			bd = d
			best = z
	return best


## Nearest zombie standing in room `ri` (awake or not): the sweep target when the room
## has gone quiet but is not clear yet.
func nearest_in_room(ri: int) -> Zombie:
	var best: Zombie = null
	var bd := 1e9
	for z in alive():
		if z.room != ri:
			continue
		var d := z.global_position.distance_to(player.global_position)
		if d < bd:
			bd = d
			best = z
	return best


func nearest_alive(max_dist: float) -> Zombie:
	var best: Zombie = null
	var bd := max_dist
	for z in alive():
		var d := z.global_position.distance_to(player.global_position)
		if d < bd:
			bd = d
			best = z
	return best


# ------------------------------------------------------------------ spawning

func _spawn(t: ZombieType, pos: Vector3, room := -1, dormant := false) -> Zombie:
	var z := Zombie.new()
	var w := Words.pick(t.word_len.x, t.word_len.y, used_first_letters(), rng)
	z.setup(t, w, player)
	z.room = room
	z.interior = interior
	z.visible = room < 0 or (interior != null and interior.is_inside() and interior.is_room_revealed(room))
	z.state = Zombie.State.DORMANT if dormant else Zombie.State.CHASE
	z.position = pos
	add_child(z)
	z.died.connect(_on_died)
	zombies.append(z)
	zombie_spawned.emit(z)
	return z


func _on_died(z: Zombie) -> void:
	zombie_killed.emit(z)


func spawn_street() -> Zombie:
	# a road tile 18-40 tiles away, preferably ahead of the player
	var pt: Vector2i = player.tile
	var f: Vector3 = player.facing
	var fwd := Vector2(f.x, f.z)
	for attempt in 30:
		var ang := rng.randf_range(-PI, PI)
		var r := rng.randf_range(7.0, 20.0)
		var off := Vector2(cos(ang), sin(ang)) * r
		if fwd.length() > 0.1 and off.normalized().dot(fwd.normalized()) < -0.2:
			continue   # not behind us
		var t: Vector2i = pt + Vector2i(roundi(off.x), roundi(off.y))
		if World.road_at(t) == 0:
			continue
		if World.is_tile_safe(t):
			continue
		var kind := ZombieType.runner() if rng.randf() < 0.35 else ZombieType.shambler()
		# standing there until you look at it (or fire near it): nothing sees you first
		return _spawn(kind, World.tile_to_world(t) + Vector3(rng.randf_range(-1.5, 1.5), 0, rng.randf_range(-1.5, 1.5)), -1, true)
	return null


## Deterministic zombie count for a room; 0 once the room is recorded as cleared.
func room_count(b: BuildingData, fp: FloorPlan, ri: int) -> int:
	if fp.rooms[ri].is_stair:
		return 0
	var h := Det.h3(World.seed, b.seed_hash, fp.floor, ri, 900)
	var base := 0
	match b.district:
		District.Kind.DOWNTOWN: base = 1 + h % 3
		District.Kind.STRIP, District.Kind.INDUSTRIAL: base = h % 3
		_: base = h % 3 if not fp.rooms[ri].is_entrance else h % 2
	return base


## Zombies stand in the room (dormant), away from its doors so you see them through the
## doorway instead of bumping into them at the threshold.
func spawn_in_room(b: BuildingData, fp: FloorPlan, ri: int) -> Array[Zombie]:
	var out: Array[Zombie] = []
	var n := room_count(b, fp, ri)
	var room := fp.rooms[ri]
	var r2 := Det.rng_for(World.seed, b.seed_hash, ri, 901 + fp.floor)
	var door_pts: Array[Vector3] = []
	for di in room.doors:
		door_pts.append(fp.doors[di].pos)
	for i in n:
		var pos := Vector3.ZERO
		var best_d := -1.0
		for attempt in 12:
			var cx := r2.randf_range(room.rect.position.x + 0.35, room.rect.end.x - 0.35)
			var cy := r2.randf_range(room.rect.position.y + 0.35, room.rect.end.y - 0.35)
			var p := fp.cell_to_world(Vector2(cx, cy))
			var dmin := 99.0
			for dp in door_pts:
				dmin = minf(dmin, p.distance_to(dp))
			if dmin > best_d:
				best_d = dmin
				pos = p
			if dmin > 2.2:
				break
		var kind := ZombieType.runner() if r2.randf() < 0.3 else ZombieType.shambler()
		out.append(_spawn(kind, pos, ri, true))
	return out


## Gunfire wakes dormant zombies that can hear it: same room, or rooms reachable through
## open doors within `hops`, or (street) within `radius`.
func wake_by_noise(interior: Node3D, player_room: int, radius: float, hops: int) -> void:
	for z in alive():
		if z.state != Zombie.State.DORMANT:
			continue
		if z.room < 0:
			if z.global_position.distance_to(player.global_position) < radius:
				z.wake()
			continue
		if interior == null or not interior.is_inside():
			continue
		var route: Array = interior.route(z.room, player_room)
		if not route.is_empty() and route.size() <= hops + 1:
			z.wake()


func clear_all() -> void:
	for z in zombies:
		if is_instance_valid(z):
			z.queue_free()
	zombies.clear()


func clear_room_zombies() -> void:
	for z in zombies:
		if is_instance_valid(z) and z.room >= 0:
			z.queue_free()
	zombies = zombies.filter(func(z): return is_instance_valid(z) and z.room < 0)


## A claimed safe zone turns combat input off, so street threats cannot be allowed to
## follow the player through its gate. Remove the small streamed street encounter set
## immediately on entry; new street spawns stay disabled for the duration of SAFEZONE.
func clear_street_zombies() -> void:
	for z in zombies:
		if is_instance_valid(z) and z.room < 0:
			z.queue_free()
	zombies = zombies.filter(func(z): return is_instance_valid(z) and z.room >= 0)


func alive_in_room(ri: int) -> int:
	var n := 0
	for z in alive():
		if z.room == ri:
			n += 1
	return n


# ------------------------------------------------------------------ update

func _process(dt: float) -> void:
	# Warded ground is a lasting achievement, not a defence chore. Zombie matter
	# disperses any street zombie that crosses a completed perimeter and prevents new
	# spawns there; indoor encounters still obey their room-clearing rules.
	for z in zombies:
		if is_instance_valid(z) and z.room < 0 and World.is_world_safe(z.global_position):
			z.queue_free()
	zombies = zombies.filter(func(z): return is_instance_valid(z) and not z.is_queued_for_deletion())
	_sync_room_visibility()
	if street_spawning and player != null:
		_spawn_timer -= dt
		if _spawn_timer <= 0.0:
			_spawn_timer = rng.randf_range(4.0, 8.0)
			var street_alive := 0
			for z in alive():
				if z.room < 0:
					street_alive += 1
			if street_alive < max_street:
				spawn_street()
	_los_frame += 1
	if _los_frame % 3 == 0:
		_update_los()
	_separate(dt)


## Keep zombies from stacking on one spot (and their words from overlapping).
func _separate(dt: float) -> void:
	var az := alive()
	for i in az.size():
		var a := az[i]
		if a.state == Zombie.State.DORMANT:
			continue
		var push := Vector3.ZERO
		for j in az.size():
			if i == j:
				continue
			var d := a.global_position - az[j].global_position
			d.y = 0.0
			var l := d.length()
			if l < 1.1 and l > 0.001:
				push += d / l * (1.1 - l)
		if push.length() > 0.001:
			a.global_position += push * minf(dt * 6.0, 1.0)


func targetable_words() -> Array[String]:
	var out: Array[String] = []
	for z in targetable():
		out.append(z.word.substr(z.typed))
	return out


func _update_los() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var space := get_world_3d().direct_space_state
	var from := cam.global_position
	for z in alive():
		if not z.visible:
			z.in_los = false
			continue
		var to := z.global_position + Vector3(0, 1.0, 0)
		var visible_now := false
		# A zombie almost touching the survivor can put its head below the camera frustum,
		# especially on an interior threshold. In the same semantic room it is necessarily
		# visible enough to fight; its word overlay already clamps onto the screen.
		var same_room: bool = z.room >= 0 and interior != null and interior.is_inside() \
			and interior.room_at_world(player.global_position) == z.room
		var point_blank: bool = same_room and Vector2(from.x - to.x, from.z - to.z).length() < 1.5
		if point_blank:
			visible_now = true
		elif cam.is_position_in_frustum(to) and from.distance_to(to) < ENGAGE_RANGE:
			var q := PhysicsRayQueryParameters3D.create(from, to, 1)
			var hit := space.intersect_ray(q)
			visible_now = hit.is_empty()
		z.in_los = visible_now
		if visible_now:
			z.last_seen = Time.get_ticks_msec() / 1000.0
		if visible_now and z.state == Zombie.State.DORMANT:
			z.wake()


func _sync_room_visibility() -> void:
	for z in alive():
		if z.room < 0:
			z.visible = true
			continue
		var revealed: bool = interior != null and interior.is_inside() and interior.is_room_revealed(z.room)
		z.visible = revealed
		if not revealed:
			z.in_los = false
