class_name Zombie
extends Node3D
## A zombie: 8-direction billboard sprite, a word over its head, and a small state
## machine. Every correctly typed letter is a bullet: flinch, knockback, stun. The last
## letter kills. Movement: A* over road tiles outdoors, straight line indoors.

signal died(z: Zombie)
signal hit_player(z: Zombie, damage: int)

enum State { DORMANT, CHASE, WINDUP, STRIKE, RECOVER, STUN, DEAD }

var type: ZombieType
var word := ""
var typed := 0
var state := State.CHASE
var facing := Vector3(0, 0, 1)
var target: Node3D
var room := -1                 ## interior room index, -1 = street
var in_los := false            ## set by the director
var last_seen := -10.0         ## seconds (Time.get_ticks_msec/1000) when last in LOS
var locked := false

var _timer := 0.0
var _flinch_b := false
var _path: Array[Vector2i] = []
var _path_i := 0
var _repath := 0.0
var _lane := Vector3.ZERO
var _flash := 0.0
var _dead_timer := 0.0
var _struck := false
var interior: Node3D           ## set by the director when indoors (for door routing)
var _route: Array = []         ## door indices towards the player's room
var _route_t := 0.0
var _best_dist := 1e9          ## closest we have got to the player (stuck detection)
var _stuck_t := 0.0

var sprite: AnimatedSprite3D
var label: WordLabel


func setup(t: ZombieType, w: String, tgt: Node3D) -> void:
	type = t
	word = w
	target = tgt


func _ready() -> void:
	sprite = AnimatedSprite3D.new()
	sprite.sprite_frames = ZombieFrames.load_for(type)
	sprite.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	sprite.pixel_size = type.pixel_size
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	sprite.shaded = false
	sprite.offset = Vector2(0, 46)   # feet at the node origin
	add_child(sprite)
	label = WordLabel.new(word, 26)
	label.position = Vector3(0, 2.15, 0)
	add_child(label)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(word) + int(global_position.x * 7.0)
	_lane = Vector3(rng.randf_range(-1.4, 1.4), 0, rng.randf_range(-1.4, 1.4))
	_play("run" if state == State.CHASE else "idle")
	_update_label()


func is_alive() -> bool:
	return state != State.DEAD


func next_letter() -> String:
	return word[typed] if typed < word.length() else ""


# ------------------------------------------------------------------ combat

## A correctly typed letter. Returns true if this letter killed it.
func hit() -> bool:
	if state == State.DEAD:
		return false
	typed += 1
	_flash = 0.07
	var away := (global_position - target.global_position)
	away.y = 0.0
	if away.length() > 0.01:
		global_position += away.normalized() * type.knockback
	facing = -away.normalized() if away.length() > 0.01 else facing
	if typed >= word.length():
		_die()
		return true
	state = State.STUN
	_timer = type.stun
	_flinch_b = not _flinch_b
	_play("flinch_b" if _flinch_b else "flinch_a", true)
	_punch()
	_update_label()
	return false


func _die() -> void:
	state = State.DEAD
	# the body stays on the floor (street corpses fade after a while; room corpses go with
	# the storey)
	_dead_timer = 40.0 if room < 0 else 1e9
	label.visible = false
	if ZombieFrames.has_anim(sprite.sprite_frames, "death"):
		_play("death", true)
		_punch(1.35, 0.7)
	else:
		# no death frames yet: collapse (squash flat) and fade
		var tw := create_tween()
		tw.set_parallel(true)
		tw.tween_property(sprite, "scale", Vector3(1.3, 0.08, 1.0), 0.28).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.tween_property(sprite, "modulate:a", 0.0, 0.9).set_delay(0.3)
	died.emit(self)


func set_locked(v: bool) -> void:
	locked = v
	label.set_locked(v)


func wake() -> void:
	if state == State.DORMANT:
		state = State.CHASE
		_play("run")
		_sfx_at("growl1" if randf() < 0.5 else "growl2", -4.0, 0.15)


func _sfx_at(name: String, db: float, pitch_var: float, pitch := 1.0) -> void:
	var sfx := get_tree().get_first_node_in_group("sfx")
	if sfx != null:
		sfx.play_at(name, global_position, db, pitch_var, pitch)


## A door just burst open next to it: hop back, face the noise, take a beat before
## charging. Gives you the first shot instead of a zombie already in your face.
func startle(from: Vector3) -> void:
	if state == State.DEAD or state == State.STUN:
		return
	var away := global_position - from
	away.y = 0.0
	if away.length() < 0.05:
		away = -facing
	away = away.normalized()
	var to := global_position + away * 1.3
	if interior != null and interior.is_inside() and room >= 0:
		to = interior.clamp_to_room(room, to, 0.45)
	facing = -away
	state = State.STUN
	_timer = 0.85
	_play("flinch_b", true)
	_punch(0.78, 1.32)
	_sfx_at("startle", -2.0, 0.2)
	var tw := create_tween()
	tw.tween_property(self, "global_position", to, 0.26).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


# ------------------------------------------------------------------ update

func _process(dt: float) -> void:
	if target == null:
		return
	_flash = maxf(_flash - dt, 0.0)
	if state != State.DEAD:
		sprite.modulate = Color(3, 3, 3) if _flash > 0.0 else Color.WHITE
	# the word exists only while you have a sightline (or a fresh lock on it)
	var show := state != State.DEAD and state != State.DORMANT and (in_los or (locked and Time.get_ticks_msec() / 1000.0 - last_seen < 0.8))
	label.visible = show
	var to_player := target.global_position - global_position
	to_player.y = 0.0
	var dist := to_player.length()
	match state:
		State.DORMANT:
			pass
		State.CHASE:
			# a zombie that cannot get any closer for a long while (outside a window,
			# wrong side of a wall) gives up and wanders off once you are not looking
			if dist < _best_dist - 0.4:
				_best_dist = dist
				_stuck_t = 0.0
			else:
				_stuck_t += dt
				if _stuck_t > 12.0 and not in_los and dist > 3.0:
					queue_free()
					return
			if dist <= type.attack_range and _on_camera():
				state = State.WINDUP
				_timer = type.attack_windup
				_struck = false
				facing = to_player.normalized()
				_play("attack", true)
			elif dist <= type.attack_range:
				facing = to_player.normalized()   # in reach but off camera: lurk, never swing
			else:
				_move(dt, to_player, dist)
		State.WINDUP:
			facing = to_player.normalized() if dist > 0.01 else facing
			_timer -= dt
			if _timer <= 0.0:
				state = State.STRIKE
				_timer = 0.12
		State.STRIKE:
			if not _struck:
				_struck = true
				if dist <= type.attack_range + 0.4:
					hit_player.emit(self, type.damage)
			_timer -= dt
			if _timer <= 0.0:
				state = State.RECOVER
				_timer = type.attack_recover
		State.RECOVER:
			# back off half a metre after a swing so there is a window to answer
			if dist > 0.01 and _timer > type.attack_recover * 0.5:
				global_position -= to_player.normalized() * dt * 1.2
			_timer -= dt
			if _timer <= 0.0:
				state = State.CHASE
				_play("run")
		State.STUN:
			_timer -= dt
			if _timer <= 0.0:
				state = State.CHASE
				_play("run")
		State.DEAD:
			_dead_timer -= dt
			if _dead_timer <= 1.0 and _dead_timer > 0.0 and sprite.modulate.a >= 1.0:
				var tw := create_tween()
				tw.tween_property(sprite, "modulate:a", 0.0, 0.9)
			if _dead_timer <= 0.0:
				queue_free()
	_update_direction()


const CONE_DEG := 28.0     ## half-angle of the camera's "front": zombies approach only inside it


## Is this zombie inside the camera's front cone (so its whole word is on screen)?
func _on_camera() -> bool:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return true
	var fwd := -cam.global_transform.basis.z
	fwd.y = 0.0
	var to_me := global_position - target.global_position
	to_me.y = 0.0
	if fwd.length() < 0.01 or to_me.length() < 0.01:
		return true
	return rad_to_deg(fwd.normalized().angle_to(to_me.normalized())) <= CONE_DEG


## Action-movie rule: come at the player from the front. Off camera, the goal is the edge
## of the front cone on this side at the current distance — sidestep into view, then close.
func _approach_goal(dist: float) -> Vector3:
	var cam := get_viewport().get_camera_3d()
	var pp := target.global_position
	if cam == null:
		return pp
	var fwd := -cam.global_transform.basis.z
	fwd.y = 0.0
	var to_me := global_position - pp
	to_me.y = 0.0
	if fwd.length() < 0.01 or to_me.length() < 0.01:
		return pp
	fwd = fwd.normalized()
	if rad_to_deg(fwd.angle_to(to_me.normalized())) <= CONE_DEG:
		return pp
	var side := signf(fwd.cross(to_me).y)
	var edge := fwd.rotated(Vector3.UP, side * deg_to_rad(CONE_DEG - 4.0))
	return pp + edge * maxf(dist, 4.0)


func _move(dt: float, to_player: Vector3, dist: float) -> void:
	var step := type.speed * dt
	if room >= 0:
		_move_indoors(dt, to_player, dist, step)
		return
	if interior != null and interior.is_inside() and interior.room_at_world(target.global_position) >= 0:
		_enter_building(dt, step)
		return
	if dist < 7.0:
		var goal := _approach_goal(dist)
		var d := goal - global_position
		d.y = 0.0
		if d.length() < 0.15:
			return
		d = d.normalized()
		facing = d
		var allowed := minf(step, maxf(dist - type.attack_range * 0.8, 0.0)) if goal == target.global_position else step
		global_position += d * allowed
		return
	# street: follow road tiles towards the player
	_repath -= dt
	if _repath <= 0.0 or _path.is_empty():
		_repath = 0.9
		var from := World.world_to_tile(global_position)
		var to := World.world_to_tile(target.global_position)
		if World.road_at(from) == 0:
			from = _nearest_road(from)
		_path = World.find_path(from, to)
		_path_i = 1 if _path.size() > 1 else 0
	if _path.is_empty():
		var d := to_player.normalized()
		facing = d
		global_position += d * step
		return
	var goal := World.tile_to_world(_path[mini(_path_i, _path.size() - 1)]) + _lane
	var d := goal - global_position
	d.y = 0.0
	if d.length() < 0.5:
		_path_i += 1
		if _path_i >= _path.size():
			_path.clear()
		return
	d = d.normalized()
	facing = facing.lerp(d, 0.2).normalized()
	global_position += d * step


## The player is inside a building: walk the roads to its door tile, step through the
## doorway, and become a room zombie (from then on doors are the only way through walls).
func _enter_building(dt: float, step: float) -> void:
	var b: BuildingData = interior.building
	var ep: Vector3 = interior.entrance_pos()
	var road_pt := World.tile_to_world(b.road_tile)
	var to_road := road_pt - global_position
	to_road.y = 0.0
	if to_road.length() > 1.6:
		# roads first (A* over road tiles), straight line for the last stretch
		_repath -= dt
		if _repath <= 0.0 or _path.is_empty():
			_repath = 0.9
			var from := World.world_to_tile(global_position)
			if World.road_at(from) == 0:
				from = _nearest_road(from)
			_path = World.find_path(from, b.road_tile)
			_path_i = 1 if _path.size() > 1 else 0
		var goal := road_pt
		if not _path.is_empty() and _path_i < _path.size():
			goal = World.tile_to_world(_path[_path_i]) + _lane * 0.5
			if (goal - global_position).length() < 0.5:
				_path_i += 1
				return
		var d := goal - global_position
		d.y = 0.0
		if d.length() > 0.01:
			d = d.normalized()
			facing = facing.lerp(d, 0.2).normalized()
			global_position += d * step
		return
	# doorway
	var to_door := ep - global_position
	to_door.y = 0.0
	if to_door.length() < 0.35:
		room = interior.entrance_room()
		_path.clear()
		return
	var d := to_door.normalized()
	facing = d
	global_position += d * step


## Rooms are convex: straight line inside the player's room, otherwise head for the next
## door on a route through OPEN doors (closed doors hold zombies back).
func _move_indoors(dt: float, to_player: Vector3, dist: float, step: float) -> void:
	if interior == null or not interior.is_inside():
		return
	var player_room: int = interior.room_at_world(target.global_position)
	if player_room == room:
		var goal := _approach_goal(dist)
		goal = _clamp_to_room(goal)
		var d := goal - global_position
		d.y = 0.0
		if d.length() < 0.15:
			return
		d = d.normalized()
		facing = d
		var allowed := minf(step, maxf(dist - type.attack_range * 0.8, 0.0)) if goal == target.global_position else step
		global_position += d * allowed
		return
	# player outside the building: head for the entrance doorway
	var goal_room: int = player_room if player_room >= 0 else interior.entrance_room()
	if goal_room == room and player_room < 0:
		# the player is outside: step into the doorway's line of sight (2.5 m inside the
		# entrance, facing out), then the front-cone rule takes over like anywhere else
		var fp: FloorPlan = interior.plan
		var ed: FloorPlan.Door = fp.doors[fp.entrance_door]
		var inward := Vector3(-ed.dir.x, 0, -ed.dir.y)
		var stage := _clamp_to_room(ed.pos + inward * 2.5)
		var goal := stage
		if _on_camera():
			goal = target.global_position
		var d := goal - global_position
		d.y = 0.0
		if d.length() < 0.2:
			facing = -inward
			return
		d = d.normalized()
		facing = d
		var allowed := minf(step, maxf(dist - type.attack_range * 0.8, 0.0)) if goal == target.global_position else step
		global_position += d * allowed
		return
	_route_t -= dt
	if _route_t <= 0.0:
		_route_t = 0.6
		_route = interior.route(room, goal_room)
	if _route.is_empty():
		return   # no open path: wait
	var di: int = _route[0]
	var dp: Vector3 = interior.plan.doors[di].pos
	var to_door := dp - global_position
	to_door.y = 0.0
	if to_door.length() < 0.35:
		room = interior.plan.other_room(di, room)
		_route.clear()
		_route_t = 0.0
		return
	var d := to_door.normalized()
	facing = d
	global_position += d * step


## Keep an indoor goal inside this zombie's room (rooms are convex rectangles).
func _clamp_to_room(p: Vector3) -> Vector3:
	if interior == null or not interior.is_inside() or room < 0:
		return p
	var fp: FloorPlan = interior.plan
	var r: Rect2i = fp.rooms[room].rect
	var lo := fp.cell_to_world(Vector2(r.position)) + Vector3(0.4, 0, 0.4)
	var hi := fp.cell_to_world(Vector2(r.end)) - Vector3(0.4, 0, 0.4)
	return Vector3(clampf(p.x, lo.x, hi.x), p.y, clampf(p.z, lo.z, hi.z))


func _nearest_road(t: Vector2i) -> Vector2i:
	for r in range(1, 4):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var c := t + Vector2i(dx, dy)
				if World.road_at(c) != 0:
					return c
	return t


# ------------------------------------------------------------------ presentation

func _play(anim: String, restart := false) -> void:
	var sf := sprite.sprite_frames
	if state == State.DEAD and anim != "death":
		return
	var a := anim
	if a == "idle" and ZombieFrames.has_anim(sf, "idle_breathe"):
		a = "idle_breathe"
	if not ZombieFrames.has_anim(sf, a):
		a = "run" if ZombieFrames.has_anim(sf, "run") else "idle"
	var key := "%s_%s" % [a, _dir_name()]
	if sprite.animation != key or restart:
		sprite.play(key)
		if restart:
			sprite.frame = 0
	sprite.set_meta("anim", a)


func _dir_name() -> String:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return "south"
	var right := cam.global_transform.basis.x
	var fwd := -cam.global_transform.basis.z
	right.y = 0.0
	fwd.y = 0.0
	var f := facing
	f.y = 0.0
	if f.length() < 0.01 or right.length() < 0.01:
		return "south"
	var x := f.normalized().dot(right.normalized())
	var y := f.normalized().dot(-fwd.normalized())   # +1 = facing the camera
	var ang := rad_to_deg(atan2(x, y))                 # 0 = south, 90 = east, 180 = north
	var idx := int(round(fposmod(ang, 360.0) / 45.0)) % 8
	return ["south", "south-east", "east", "north-east", "north", "north-west", "west", "south-west"][idx]


func _update_direction() -> void:
	var a: String = sprite.get_meta("anim", "run")
	var key := "%s_%s" % [a, _dir_name()]
	if sprite.animation != key and sprite.sprite_frames.has_animation(key):
		var f := sprite.frame
		var prog := sprite.frame_progress
		sprite.play(key)
		sprite.set_frame_and_progress(mini(f, sprite.sprite_frames.get_frame_count(key) - 1), prog)


func _punch(sx := 1.18, sy := 0.84) -> void:
	sprite.scale = Vector3(sx, sy, 1.0)
	var tw := create_tween()
	tw.tween_property(sprite, "scale", Vector3.ONE, 0.14).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _update_label() -> void:
	label.set_progress(typed)


## Letters fly off when the word is finished (called by the director on kill).
func burst_letters(parent: Node3D) -> void:
	var rng := RandomNumberGenerator.new()
	for i in word.length():
		var l := Label3D.new()
		l.text = word[i]
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.font_size = 56
		l.pixel_size = 0.0075
		l.outline_size = 14
		l.outline_modulate = Color("#120a1f")
		l.modulate = Color("#facc15")
		l.no_depth_test = true
		l.position = global_position + Vector3(0, 2.15, 0) + Vector3((i - word.length() * 0.5) * 0.28, 0, 0)
		parent.add_child(l)
		var vel := Vector3(rng.randf_range(-2.5, 2.5), rng.randf_range(2.0, 4.5), rng.randf_range(-1.5, 1.5))
		var tw := create_tween()
		tw.set_parallel(true)
		tw.tween_property(l, "position", l.position + vel * 0.6 + Vector3(0, -2.2, 0), 0.6).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.tween_property(l, "modulate:a", 0.0, 0.6)
		tw.chain().tween_callback(l.queue_free)
