class_name BuildingData
extends RefCounted
## Immutable, regenerable description of one building. Mutable state lives in WorldState.

var sector: Vector2i
var index: int                 ## index within the sector (stable)
var rect: Rect2i               ## footprint in GLOBAL tile coords
var district: int              ## District.Kind
var floors: int
var door_tile: Vector2i        ## footprint tile that holds the entrance
var road_tile: Vector2i        ## road tile in front of the door (graph node)
var block: int                 ## block id within the sector
var seed_hash: int             ## per-building hash for cosmetic variation
var kind := "plain"            ## apartments | house | shop | office | warehouse | legacy plain


func id() -> String:
	return "%d,%d:%d" % [sector.x, sector.y, index]


func center_tile() -> Vector2:
	return Vector2(rect.position) + Vector2(rect.size) * 0.5
