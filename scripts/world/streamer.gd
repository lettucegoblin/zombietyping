extends Node3D
## Streams sector meshes around `target`. New sectors are assembled in bounded ground-row
## and building batches so crossing a sector boundary does not monopolize a frame.

@export var target: Node3D
@export var radius := 2

var _loaded: Dictionary = {}   # Vector2i -> Node3D
var _pending: Array[Vector2i] = []
var _last_center := Vector2i(0x7FFFFFFF, 0)
var _build_job: Dictionary = {}
var last_build_step_usec := 0
var max_build_step_usec := 0
const BUILDINGS_PER_FRAME := 6


func _process(_dt: float) -> void:
	if target == null:
		return
	var center := World.sector_of_tile(World.world_to_tile(target.global_position))
	if center != _last_center:
		_last_center = center
		_refresh(center)
	if not _build_job.is_empty():
		var root: Node3D = _build_job["root"]
		if not is_instance_valid(root):
			_build_job.clear()
		else:
			var started := Time.get_ticks_usec()
			var finished := SectorMesher.continue_build(_build_job, BUILDINGS_PER_FRAME)
			last_build_step_usec = Time.get_ticks_usec() - started
			max_build_step_usec = maxi(max_build_step_usec, last_build_step_usec)
			if finished:
				_build_job.clear()
		return
	if not _pending.is_empty():
		var k: Vector2i = _pending.pop_front()
		if not _loaded.has(k):
			if not _start_load(k):
				_pending.append(k)


func _refresh(center: Vector2i) -> void:
	# unload far sectors
	for k in _loaded.keys():
		if maxi(absi(k.x - center.x), absi(k.y - center.y)) > radius + 1:
			if not _build_job.is_empty() and _build_job.get("coord", Vector2i.ZERO) == k:
				_build_job.clear()
			for b in World.get_sector(k.x, k.y).buildings:
				SectorMesher.door_instances.erase(b.id())
				SectorMesher.doorway_instances.erase(b.id())
			_loaded[k].queue_free()
			_loaded.erase(k)
	# queue near sectors, nearest first
	_pending.clear()
	var ring: Array[Vector2i] = []
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var k := center + Vector2i(dx, dy)
			if not _loaded.has(k):
				ring.append(k)
	ring.sort_custom(func(a, b): return (a - center).length_squared() < (b - center).length_squared())
	_pending = ring
	for k in ring:
		World.request_sector(k.x, k.y)


func _load(k: Vector2i) -> void:
	var sd := World.get_sector(k.x, k.y)
	var node := SectorMesher.build(sd)
	add_child(node)
	_loaded[k] = node


func _start_load(k: Vector2i) -> bool:
	var sd := World.take_requested_sector(k.x, k.y)
	if sd == null:
		return false
	var started := Time.get_ticks_usec()
	_build_job = SectorMesher.begin_build(sd)
	_build_job["coord"] = k
	var node: Node3D = _build_job["root"]
	add_child(node)
	_loaded[k] = node
	last_build_step_usec = Time.get_ticks_usec() - started
	max_build_step_usec = maxi(max_build_step_usec, last_build_step_usec)
	return true


func prime(center: Vector2i) -> void:
	## Synchronously build the sectors around a start point (first frame only).
	_last_center = center
	_refresh(center)
	while not _pending.is_empty():
		var k: Vector2i = _pending.pop_front()
		if not _loaded.has(k):
			_load(k)
