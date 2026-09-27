extends Node3D
## The survivor moves on rails. Two queues: street legs (typed on the map, A* over road
## tiles) and local legs (door -> room, stairs, exit) which always run first. After a street
## leg the player HOLDS at the door until main resumes it (typed door / window timeout).

signal arrived(id: String)
signal queue_changed
signal tile_changed(tile: Vector2i)
signal manual_zone_exited

@export var street_speed := 7.0
@export var turn_speed := 6.0
@export var reveal_radius := 10

var tile: Vector2i = Vector2i(16, 0)
var facing := Vector3(1, 0, 0)
var hold := false
var halt := false      ## combat: stop in place (keeps the current leg for later)
var manual_control := false
var manual_speed := 4.2
var _manual_bounds := Rect2()
var _manual_gate := Vector2.INF
var _manual_shape: SphereShape3D

var _street: Array[Dictionary] = []   # {id, tiles: Array[Vector2i]}
var _local: Array[Dictionary] = []    # {id, points: PackedVector3Array, speed}
var _cur: Dictionary = {}             # {id, points, tiles (or []), speed}
var _seg_i := 0
var _seg_t := 0.0
var _yaw := 0.0
var _pitch := 0.0
var _shake := 0.0
var _look_locked := false
var _manual_look_time := 0.0

const MOUSE_LOOK_HOLD := 1.25
const MAX_LOOK_PITCH := deg_to_rad(38.0)
var mouse_look_sensitivity := 0.0025
var invert_mouse_y := false
var shake_intensity := 1.0

@onready var cam: Camera3D = $Camera3D


func _ready() -> void:
	global_position = World.tile_to_world(tile)
	World.mark_explored(tile, reveal_radius)
	_yaw = atan2(-facing.x, -facing.z)
	_update_cam(1.0)


func is_moving() -> bool:
	return not _cur.is_empty() or not _local.is_empty() or (manual_control and _manual_vector() != Vector2.ZERO)


## Speed of the leg being walked right now (0 when standing, held or halted).
func current_speed() -> float:
	if manual_control:
		return manual_speed if _manual_vector() != Vector2.ZERO else 0.0
	if halt or _cur.is_empty():
		return 0.0
	return _cur["speed"]


func queued_ids() -> Array[String]:
	var out: Array[String] = []
	if not _cur.is_empty() and _cur.has("tiles") and not (_cur["tiles"] as Array).is_empty():
		out.append(_cur["id"])
	for l in _street:
		out.append(l["id"])
	return out


func has_street_queue() -> bool:
	return not _street.is_empty()


func plan_end_tile() -> Vector2i:
	if not _street.is_empty():
		var t: Array = _street[-1]["tiles"]
		return t[-1]
	if not _cur.is_empty() and _cur.has("tiles") and not (_cur["tiles"] as Array).is_empty():
		var t: Array = _cur["tiles"]
		return t[-1]
	return tile


## Street destination. Returns false if no route exists.
func enqueue(building_id: String) -> bool:
	var b := World.building_by_id(building_id)
	if b == null:
		return false
	var path := World.find_path(plan_end_tile(), b.road_tile)
	if path.is_empty():
		return false
	_street.append({ "id": building_id, "tiles": path })
	queue_changed.emit()
	return true


func clear_queue() -> void:
	_street.clear()
	if not _cur.is_empty() and _cur.has("tiles") and not (_cur["tiles"] as Array).is_empty():
		# finish only the current segment, then stop
		var pts: PackedVector3Array = _cur["points"]
		var keep := PackedVector3Array()
		for i in range(_seg_i, mini(_seg_i + 2, pts.size())):
			keep.append(pts[i])
		_cur = { "id": "", "points": keep, "tiles": [], "speed": _cur["speed"] }
		_seg_i = 0
	queue_changed.emit()


## Immediate move (inside buildings, door approach). Runs before any street leg.
func push_local(points: PackedVector3Array, id: String, speed := 3.2) -> void:
	_local.append({ "id": id, "points": points, "speed": speed })


func resume() -> void:
	hold = false


func set_manual_zone(bounds: Rect2, gate_tile: Vector2i = Vector2i(0x7FFFFFFF, 0), gate_world: Vector2 = Vector2.INF) -> void:
	manual_control = true
	_manual_bounds = bounds.grow(-0.45)
	_manual_gate = gate_world if gate_world != Vector2.INF else (Vector2.INF if gate_tile.x == 0x7FFFFFFF else Vector2(World.tile_to_world(gate_tile).x, World.tile_to_world(gate_tile).z))
	_manual_shape = SphereShape3D.new()
	_manual_shape.radius = 0.3
	hold = false
	halt = false
	_cur.clear()
	_local.clear()
	_street.clear()
	queue_changed.emit()


func clear_manual_zone() -> void:
	manual_control = false
	_manual_bounds = Rect2()
	_manual_gate = Vector2.INF
	_manual_shape = null


func snap_to_road(t: Vector2i) -> void:
	clear_manual_zone()
	global_position = World.tile_to_world(t)
	tile = t
	World.mark_explored(tile, reveal_radius)
	tile_changed.emit(tile)


func _manual_vector() -> Vector2:
	var v := Vector2.ZERO
	if Input.is_key_pressed(KEY_W): v.y -= 1.0
	if Input.is_key_pressed(KEY_S): v.y += 1.0
	if Input.is_key_pressed(KEY_A): v.x -= 1.0
	if Input.is_key_pressed(KEY_D): v.x += 1.0
	return v.normalized()


func _manual_move(dt: float) -> void:
	var v := _manual_vector()
	if v == Vector2.ZERO:
		return
	_manual_move_vector(v, dt)


func _manual_move_vector(v: Vector2, dt: float) -> void:
	# Movement is camera-relative: W follows the survivor's gaze, A/D strafe.
	var forward := Vector2(facing.x, facing.z).normalized()
	var right := Vector2(-forward.y, forward.x)
	var d := (right * v.x + forward * -v.y).normalized()
	var current := Vector2(global_position.x, global_position.z)
	var p := current + d * manual_speed * dt
	if global_position.y < 1.0 and _manual_gate != Vector2.INF \
			and current.distance_to(_manual_gate) < 0.9 and p.distance_to(_manual_gate) < current.distance_to(_manual_gate):
		clear_manual_zone()
		manual_zone_exited.emit()
		return
	if not _manual_bounds.has_point(p) and global_position.y < 1.0 and _manual_gate != Vector2.INF and current.distance_to(_manual_gate) < 3.2:
		clear_manual_zone()
		manual_zone_exited.emit()
		return
	p.x = clampf(p.x, _manual_bounds.position.x, _manual_bounds.end.x)
	p.y = clampf(p.y, _manual_bounds.position.y, _manual_bounds.end.y)
	var next := Vector3(p.x, global_position.y, p.y)
	if _manual_position_clear(next):
		global_position = next
	else:
		# Axis retries make wall contact slide instead of feeling like an invisible snag.
		var slide_x := Vector3(p.x, global_position.y, current.y)
		var slide_z := Vector3(current.x, global_position.y, p.y)
		if _manual_position_clear(slide_x):
			global_position = slide_x
		elif _manual_position_clear(slide_z):
			global_position = slide_z
	if d.length() > 0.01 and not is_manual_looking() and not _look_locked:
		facing = Vector3(d.x, 0, d.y)
	var next_tile := World.world_to_tile(global_position)
	if next_tile != tile:
		tile = next_tile
		World.mark_explored(tile, reveal_radius)
		tile_changed.emit(tile)


func _manual_position_clear(pos: Vector3) -> bool:
	if _manual_shape == null or not is_inside_tree():
		return true
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _manual_shape
	query.transform = Transform3D(Basis.IDENTITY, pos + Vector3(0, 0.85, 0))
	query.collision_mask = 1
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


## Turn (smoothly) to look at a world point. A deliberate mouse glance briefly wins over
## ambient auto-aim, while a scripted look lock wins over both.
func face_toward(p: Vector3) -> void:
	if _look_locked or is_manual_looking():
		return
	_set_facing_toward(p)


## Arrival guidance is an intentional camera cue rather than ambient auto-aim. It gets one
## clean heading even if the mouse moved a moment ago, but never interrupts a door-kick
## cinematic lock. The player can immediately look elsewhere again afterward.
func guide_toward(p: Vector3) -> void:
	if _look_locked:
		return
	_manual_look_time = 0.0
	_pitch = 0.0
	_set_facing_toward(p)


func _set_facing_toward(p: Vector3) -> void:
	var d := p - global_position
	d.y = 0.0
	if d.length() > 0.01:
		facing = d.normalized()


## Cinematic beats such as a kicked-in entrance use this so combat auto-aim cannot pull
## the camera away before the animation has finished.
func lock_look_toward(p: Vector3) -> void:
	_look_locked = true
	_manual_look_time = 0.0
	_pitch = 0.0
	_set_facing_toward(p)


func unlock_look() -> void:
	_look_locked = false


func is_look_locked() -> bool:
	return _look_locked


func is_manual_looking() -> bool:
	return _manual_look_time > 0.0


## Mouse look. Horizontal motion changes the actual gaze direction, so targeting,
## the minimap arrow, and safe-zone WASD all agree with what the camera shows.
func mouse_look(relative: Vector2) -> void:
	if _look_locked:
		return
	_manual_look_time = MOUSE_LOOK_HOLD
	var yaw := atan2(-facing.x, -facing.z) - relative.x * mouse_look_sensitivity
	facing = Vector3(-sin(yaw), 0.0, -cos(yaw))
	_yaw = yaw
	var vertical_sign := 1.0 if invert_mouse_y else -1.0
	_pitch = clampf(_pitch + relative.y * mouse_look_sensitivity * vertical_sign, -MAX_LOOK_PITCH, MAX_LOOK_PITCH)


func all_paths() -> Array:
	var out := []
	if not _cur.is_empty() and _cur.has("tiles") and not (_cur["tiles"] as Array).is_empty():
		out.append(_cur["tiles"])
	for l in _street:
		out.append(l["tiles"])
	return out


func _start_next() -> bool:
	if not _local.is_empty():
		var l: Dictionary = _local.pop_front()
		var pts := PackedVector3Array([global_position])
		pts.append_array(l["points"])
		_cur = { "id": l["id"], "points": pts, "tiles": [], "speed": l["speed"] }
	elif not hold and not _street.is_empty():
		var s: Dictionary = _street.pop_front()
		var tiles: Array = s["tiles"]
		var pts := PackedVector3Array()
		for t in tiles:
			pts.append(World.tile_to_world(t))
		_cur = { "id": s["id"], "points": pts, "tiles": tiles, "speed": street_speed }
		queue_changed.emit()
	else:
		return false
	_seg_i = 0
	_seg_t = 0.0
	return true


func _process(dt: float) -> void:
	_manual_look_time = maxf(_manual_look_time - dt, 0.0)
	if manual_control:
		_manual_move(dt)
		_update_cam(dt)
		return
	if halt:
		_update_cam(dt)
		return
	if _cur.is_empty() and not _start_next():
		_update_cam(dt)
		return
	var pts: PackedVector3Array = _cur["points"]
	if pts.size() < 2:
		_finish()
		_update_cam(dt)
		return
	var speed: float = _cur["speed"]
	var remaining := dt * speed
	while remaining > 0.0:
		var a := pts[_seg_i]
		var b := pts[_seg_i + 1]
		var seg_len := a.distance_to(b)
		if seg_len > 0.001 and not is_manual_looking() and not _look_locked:
			facing = (b - a) / seg_len
		var left := (1.0 - _seg_t) * seg_len
		if remaining < left:
			_seg_t += remaining / seg_len
			remaining = 0.0
		else:
			remaining -= left
			_seg_i += 1
			_seg_t = 0.0
			_on_point(_seg_i)
			if _seg_i >= pts.size() - 1:
				global_position = pts[-1]
				_finish()
				_update_cam(dt)
				return
	global_position = pts[_seg_i].lerp(pts[_seg_i + 1], _seg_t)
	_update_cam(dt)


func _on_point(i: int) -> void:
	var tiles: Array = _cur["tiles"]
	if tiles.is_empty() or i >= tiles.size():
		return
	var t: Vector2i = tiles[i]
	if t != tile:
		tile = t
		World.mark_explored(tile, reveal_radius)
		tile_changed.emit(tile)


func _finish() -> void:
	var leg := _cur
	_cur = {}
	_seg_i = 0
	_seg_t = 0.0
	var is_street: bool = not (leg["tiles"] as Array).is_empty()
	if is_street:
		hold = true
	queue_changed.emit()
	if leg["id"] != "":
		arrived.emit(leg["id"])


func shake(amount: float) -> void:
	_shake = maxf(_shake, amount * shake_intensity)


func _update_cam(dt: float) -> void:
	var target_yaw := atan2(-facing.x, -facing.z)
	_yaw = lerp_angle(_yaw, target_yaw, clampf(dt * turn_speed, 0.0, 1.0))
	if not is_manual_looking():
		_pitch = lerpf(_pitch, 0.0, clampf(dt * 4.0, 0.0, 1.0))
	_shake = maxf(_shake - dt * 2.2, 0.0)
	var jx := randf_range(-1.0, 1.0) * _shake * 0.14
	var jy := randf_range(-1.0, 1.0) * _shake * 0.09
	cam.rotation = Vector3(_pitch, _yaw, randf_range(-1.0, 1.0) * _shake * 0.03)
	cam.position = Vector3(jx, 1.65 + jy, 0)
