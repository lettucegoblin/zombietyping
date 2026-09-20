class_name FloorPlan
extends RefCounted
## One storey of one building: a cell grid, rooms (BSP leaves), doors between them.
## Purely derived data — regenerable from (seed, building, floor). State lives in World.

class Room:
	var index: int
	var rect: Rect2i            ## in cells
	var kind: String            ## "room", "hall", "stair", "entrance"
	var doors: Array[int] = []
	var is_stair := false
	var is_entrance := false
	func center_cell() -> Vector2:
		return Vector2(rect.position) + Vector2(rect.size) * 0.5

class Door:
	var index: int
	var a: int                  ## room index
	var b: int                  ## room index, or -1 for the street (entrance)
	var cell: Vector2i          ## cell on room a's side
	var dir: Vector2i           ## a -> b direction (unit)
	var pos: Vector3            ## world position of the opening centre, on the wall plane, floor height
	var word: String
	var open_always := false    ## a doorless opening (into the stairwell): no leaf, no word
	func key() -> String:
		return "%d,%d:%d,%d" % [cell.x, cell.y, dir.x, dir.y]

var building_id: String
var floor: int
var floors_total: int
var cells: Vector2i
var cell_size: Vector2        ## metres per cell (x, z)
var origin: Vector3           ## world position of cell (0,0)'s min corner, y = floor height
var rooms: Array[Room] = []
var doors: Array[Door] = []
var entrance_door := -1
var stair_room := -1
var stair_cell := Vector2i.ZERO        ## entry cell of the stairwell (see Stairwell.layout)
var stair_layout: Dictionary = {}      ## Stairwell.layout() result, {} for single-storey buildings

## per-cell room index, row-major
var cell_room: PackedInt32Array


func room_at_cell(c: Vector2i) -> int:
	if c.x < 0 or c.y < 0 or c.x >= cells.x or c.y >= cells.y:
		return -1
	return cell_room[c.y * cells.x + c.x]


func cell_to_world(c: Vector2, y_off: float = 0.0) -> Vector3:
	return origin + Vector3(c.x * cell_size.x, y_off, c.y * cell_size.y)


func room_center_world(ri: int) -> Vector3:
	return cell_to_world(rooms[ri].center_cell())


## Where the survivor stands when "in" a room: its centre. (You never stand in the
## stairwell; its entry cell centre is returned for pass-through paths.)
func room_stand_world(ri: int) -> Vector3:
	if ri == stair_room and stair_room >= 0:
		return cell_to_world(Vector2(stair_cell) + Vector2(0.5, 0.5))
	return room_center_world(ri)


## The door from room `ri` into the stairwell (open or not), or -1.
func stair_opening(ri: int) -> int:
	if stair_room < 0 or ri < 0 or ri == stair_room:
		return -1
	for di in rooms[ri].doors:
		var d := doors[di]
		if d.a == stair_room or d.b == stair_room:
			return di
	return -1


## World position of the door opening centre (on the wall plane, floor height).
func door_world(di: int) -> Vector3:
	return doors[di].pos


func other_room(di: int, from_room: int) -> int:
	var d := doors[di]
	return d.b if d.a == from_room else d.a
