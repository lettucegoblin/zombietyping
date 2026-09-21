extends Node
## Autoload "World": the infinite city. Sectors are generated on demand from the seed
## and cached; everything the player changes lives in `state` (sparse, saveable).

signal sector_generated(sd: SectorData)
signal state_changed(building_id: String)

const S := SectorData.SIZE
const TILE_M := 5.0                 ## metres per tile in 3D
const FLOOR_M := 3.6                ## metres per storey

var seed: int = 1337
var _sectors: Dictionary = {}       ## Vector2i -> SectorData
var state: Dictionary = {}          ## building id -> Dictionary (cleared floors, barricades, ...)
var explored: Dictionary = {}       ## Vector2i sector -> PackedByteArray (fog of war, 1 = seen)
var safezone_blocks: Dictionary = {} ## "sx,sy:block" -> true


func _ready() -> void:
	_sectors.clear()


# ------------------------------------------------------------- sectors / tiles

func get_sector(sx: int, sy: int) -> SectorData:
	var k := Vector2i(sx, sy)
	var sd: SectorData = _sectors.get(k)
	if sd == null:
		sd = CityGen.generate(seed, sx, sy)
		_sectors[k] = sd
		sector_generated.emit(sd)
	return sd


func sector_of_tile(t: Vector2i) -> Vector2i:
	return Vector2i(floori(float(t.x) / S), floori(float(t.y) / S))


func local_of_tile(t: Vector2i) -> Vector2i:
	return Vector2i(posmod(t.x, S), posmod(t.y, S))


## 0 none, 1 local road, 2 arterial (global tile coords).
func road_at(t: Vector2i) -> int:
	var sc := sector_of_tile(t)
	var l := local_of_tile(t)
	return get_sector(sc.x, sc.y).road[SectorData.idx(l.x, l.y)]


func building_at(t: Vector2i) -> BuildingData:
	var sc := sector_of_tile(t)
	var l := local_of_tile(t)
	var sd := get_sector(sc.x, sc.y)
	var li := sd.lot[SectorData.idx(l.x, l.y)]
	return null if li == 0 else sd.buildings[li - 1]


func building_by_id(id: String) -> BuildingData:
	var parts := id.split(":")
	if parts.size() != 2:
		return null
	var sc := parts[0].split(",")
	var sd := get_sector(int(sc[0]), int(sc[1]))
	var i := int(parts[1])
	return sd.buildings[i] if i >= 0 and i < sd.buildings.size() else null


func tile_to_world(t: Vector2i, y: float = 0.0) -> Vector3:
	return Vector3((t.x + 0.5) * TILE_M, y, (t.y + 0.5) * TILE_M)


func world_to_tile(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / TILE_M), floori(p.z / TILE_M))


# ------------------------------------------------------------- pathfinding

## A* over road tiles between two road tiles. Uses an AStarGrid2D over the bounding
## box (+margin) so it stays cheap and only touches sectors it needs.
func find_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	# Hierarchical streets can require a collector/avenue detour rather than the old direct
	# sector-grid route. Two sectors is still cheap and leaves room for realistic blocks.
	var margin := S * 2
	var lo := Vector2i(mini(from.x, to.x) - margin, mini(from.y, to.y) - margin)
	var hi := Vector2i(maxi(from.x, to.x) + margin, maxi(from.y, to.y) + margin)
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(lo, hi - lo + Vector2i.ONE)
	grid.cell_size = Vector2.ONE
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	grid.update()
	# fill solids sector by sector (fast path: direct array reads)
	var s0 := sector_of_tile(lo)
	var s1 := sector_of_tile(hi)
	for sy in range(s0.y, s1.y + 1):
		for sx in range(s0.x, s1.x + 1):
			var sd := get_sector(sx, sy)
			var org := sd.origin_tile()
			for ly in S:
				var gy := org.y + ly
				if gy < lo.y or gy > hi.y:
					continue
				for lx in S:
					var gx := org.x + lx
					if gx < lo.x or gx > hi.x:
						continue
					if sd.road[ly * S + lx] == 0:
						grid.set_point_solid(Vector2i(gx, gy), true)
					elif sd.road[ly * S + lx] == 1:
						grid.set_point_weight_scale(Vector2i(gx, gy), 1.15)  # prefer arterials slightly
	if grid.is_point_solid(from) or grid.is_point_solid(to):
		return out
	for p in grid.get_id_path(from, to):
		out.append(p)
	return out


# ------------------------------------------------------------- state

func building_state(id: String) -> Dictionary:
	if not state.has(id):
		state[id] = {}
	return state[id]


func set_building_state(id: String, key: String, value: Variant) -> void:
	building_state(id)[key] = value
	state_changed.emit(id)


func mark_explored(t: Vector2i, radius: int) -> void:
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx * dx + dy * dy > radius * radius:
				continue
			var g := t + Vector2i(dx, dy)
			var sc := sector_of_tile(g)
			var l := local_of_tile(g)
			if not explored.has(sc):
				var fresh := PackedByteArray()
				fresh.resize(S * S)
				explored[sc] = fresh
			explored[sc][SectorData.idx(l.x, l.y)] = 1


func is_explored(t: Vector2i) -> bool:
	var sc := sector_of_tile(t)
	if not explored.has(sc):
		return false
	var l := local_of_tile(t)
	return explored[sc][SectorData.idx(l.x, l.y)] == 1
