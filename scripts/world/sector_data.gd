class_name SectorData
extends RefCounted
## One generated sector: 32x32 tiles. Row 0 / col 0 are the framing arterials.

const SIZE := 32

var coord: Vector2i
var district: int
var density: float
var road: PackedByteArray      ## 0 none, 1 local, 2 arterial  (SIZE*SIZE, row-major)
var block: PackedInt32Array    ## block id per tile, -1 for road
var lot: PackedInt32Array      ## building index + 1 per tile, 0 = none
var buildings: Array[BuildingData] = []
var block_count: int = 0


func _init() -> void:
	road.resize(SIZE * SIZE)
	block.resize(SIZE * SIZE)
	lot.resize(SIZE * SIZE)
	block.fill(-1)


static func idx(x: int, y: int) -> int:
	return y * SIZE + x


func road_at(x: int, y: int) -> int:
	return road[y * SIZE + x]


func origin_tile() -> Vector2i:
	return coord * SIZE
