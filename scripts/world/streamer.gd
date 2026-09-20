extends Node3D
## Streams sector meshes around `target`. Builds at most one sector per frame so
## crossing a sector boundary never hitches; frees sectors beyond radius + 1.

@export var target: Node3D
@export var radius := 2

var _loaded: Dictionary = {}   # Vector2i -> Node3D
var _pending: Array[Vector2i] = []
var _last_center := Vector2i(0x7FFFFFFF, 0)


func _process(_dt: float) -> void:
	if target == null:
		return
	var center := World.sector_of_tile(World.world_to_tile(target.global_position))
	if center != _last_center:
		_last_center = center
		_refresh(center)
	if not _pending.is_empty():
		var k: Vector2i = _pending.pop_front()
		if not _loaded.has(k):
			_load(k)


func _refresh(center: Vector2i) -> void:
	# unload far sectors
	for k in _loaded.keys():
		if maxi(absi(k.x - center.x), absi(k.y - center.y)) > radius + 1:
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


func _load(k: Vector2i) -> void:
	var sd := World.get_sector(k.x, k.y)
	var node := SectorMesher.build(sd)
	add_child(node)
	_loaded[k] = node


func prime(center: Vector2i) -> void:
	## Synchronously build the sectors around a start point (first frame only).
	_last_center = center
	_refresh(center)
	while not _pending.is_empty():
		var k: Vector2i = _pending.pop_front()
		if not _loaded.has(k):
			_load(k)
