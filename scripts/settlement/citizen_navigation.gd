extends RefCounted
## Small deterministic occupancy grid for one claimed rectangle. Settlement yards are
## only a few dozen metres across, so a sub-metre grid is cheaper and more predictable
## than maintaining navigation meshes for streamed procedural geometry.

const CELL_M := 0.75
const BODY_RADIUS := 0.48

var bounds := Rect2()
var _building := Rect2()
var _obstacles: Array[Dictionary] = []
var _grid := AStarGrid2D.new()
var _size := Vector2i.ZERO
var _walkable: Array[Vector2i] = []


func _init(b: BuildingData, placements: Array) -> void:
	bounds = World.safe_rect_world(b).grow(-BODY_RADIUS - 0.2)
	_building = World.building_rect_world(b).grow(BODY_RADIUS)
	for item in placements:
		if item.get("building", "") != b.id():
			continue
		var pos: Vector3 = item.get("pos", Vector3.ZERO)
		if absf(pos.y) > 1.0:
			continue # outdoor citizens only occupy the ground-level yard
		var kind: String = item.get("kind", "")
		if not World.PLACEMENT_SIZE.has(kind):
			continue
		var yaw := float(item.get("yaw", 0.0))
		_obstacles.append({
			"center": Vector2(pos.x, pos.z),
			"axis_x": Vector2(cos(yaw), -sin(yaw)),
			"axis_z": Vector2(sin(yaw), cos(yaw)),
			"half": (World.PLACEMENT_SIZE[kind] as Vector2) * 0.5 + Vector2.ONE * BODY_RADIUS,
		})
	_build_grid()


func _build_grid() -> void:
	_size = Vector2i(
		maxi(1, floori(bounds.size.x / CELL_M)),
		maxi(1, floori(bounds.size.y / CELL_M))
	)
	_grid.region = Rect2i(Vector2i.ZERO, _size)
	_grid.cell_size = Vector2.ONE
	_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	_grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	_grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	_grid.update()
	for y in _size.y:
		for x in _size.x:
			var cell := Vector2i(x, y)
			if _point_blocked(_cell_point(cell)):
				_grid.set_point_solid(cell, true)
			else:
				_walkable.append(cell)


func _cell_point(cell: Vector2i) -> Vector2:
	return bounds.position + (Vector2(cell) + Vector2(0.5, 0.5)) * CELL_M


func _point_blocked(p: Vector2) -> bool:
	if not bounds.has_point(p) or _building.has_point(p):
		return true
	for obstacle in _obstacles:
		var delta: Vector2 = p - obstacle["center"]
		var half: Vector2 = obstacle["half"]
		if absf(delta.dot(obstacle["axis_x"])) <= half.x \
				and absf(delta.dot(obstacle["axis_z"])) <= half.y:
			return true
	return false


func is_walkable(p: Vector2) -> bool:
	if _walkable.is_empty() or _point_blocked(p):
		return false
	var cell := _nearest_cell(p)
	return not _grid.is_point_solid(cell)


func _nearest_cell(p: Vector2) -> Vector2i:
	var direct := Vector2i(floori((p.x - bounds.position.x) / CELL_M), floori((p.y - bounds.position.y) / CELL_M))
	direct.x = clampi(direct.x, 0, _size.x - 1)
	direct.y = clampi(direct.y, 0, _size.y - 1)
	if not _grid.is_point_solid(direct):
		return direct
	var best := _walkable[0]
	var best_dist := INF
	for cell in _walkable:
		var d := _cell_point(cell).distance_squared_to(p)
		if d < best_dist:
			best_dist = d
			best = cell
	return best


func nearest_walkable(p: Vector2) -> Vector2:
	if _walkable.is_empty():
		return bounds.get_center()
	return _cell_point(_nearest_cell(p))


func deterministic_point(seed_value: int, leg: int) -> Vector2:
	if _walkable.is_empty():
		return bounds.get_center()
	var i := posmod(Det.h3(World.seed, seed_value, leg, 0, 707), _walkable.size())
	return _cell_point(_walkable[i])


func route(from: Vector2, to: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	if _walkable.is_empty():
		return out
	var start := _nearest_cell(from)
	var finish := _nearest_cell(to)
	var cells := _grid.get_id_path(start, finish)
	if cells.is_empty():
		return out
	# AStarGrid returns a Manhattan staircase. Keep only corners so citizen metadata and
	# movement work stay small without permitting corner-cutting through rectangles.
	var previous_dir := Vector2i.ZERO
	for i in cells.size():
		var cell: Vector2i = cells[i]
		var next_dir := Vector2i.ZERO if i == cells.size() - 1 else (cells[i + 1] as Vector2i) - cell
		if i == 0 or i == cells.size() - 1 or next_dir != previous_dir:
			out.append(_cell_point(cell))
		previous_dir = next_dir
	return out
