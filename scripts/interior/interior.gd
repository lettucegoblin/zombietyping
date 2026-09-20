extends Node3D
## The storey the player is currently inside. Builds revealed rooms only (per-floor fog),
## applies room/door state to World, and answers "what can be typed from here".

signal door_kicked(di: int)

var building: BuildingData
var plan: FloorPlan
var current_room := -1
var _room_nodes: Dictionary = {}    # ri -> Node3D
var _revealed: Dictionary = {}      # ri -> true
var _door_nodes: Dictionary = {}    # di -> Node3D (leaf on its hinge)
var _old_floor: Node3D              # previous storey kept alive during a stair climb


func is_inside() -> bool:
	return plan != null


func enter(b: BuildingData, floor: int) -> void:
	unload()
	building = b
	plan = InteriorGen.generate(World.seed, b, floor)
	current_room = -1
	_set_own_collider(false)
	SectorMesher.set_doorway_open(b.id(), true)
	_build_all()


## Every room is built up front so walls (and closed doors) block sightlines everywhere;
## rooms you have not seen yet are simply invisible until revealed.
func _build_all() -> void:
	for ri in plan.rooms.size():
		_rebuild(ri)
		_set_room_visible(ri, _revealed.has(ri))


func _set_room_visible(ri: int, v: bool) -> void:
	var n: Node3D = _room_nodes.get(ri)
	if n == null:
		return
	for c in n.get_children():
		if c is MeshInstance3D:
			c.visible = v


## Start a stair transition: the current storey stays visible (parked under _old_floor)
## while the new one is built; call finish_floor_change() once the player has arrived.
func begin_floor_change(delta: int) -> void:
	_drop_old_floor()
	_old_floor = Node3D.new()
	_old_floor.name = "OldFloor"
	add_child(_old_floor)
	for n in _room_nodes.values():
		var l: Node3D = n.get_node_or_null("Labels")
		if l != null:
			l.visible = false
		n.reparent(_old_floor)
	for n in _door_nodes.values():
		n.reparent(_old_floor)
	_room_nodes.clear()
	_door_nodes.clear()
	_revealed.clear()
	plan = InteriorGen.generate(World.seed, building, plan.floor + delta)
	current_room = -1
	_build_all()
	_reveal(plan.stair_room)


func finish_floor_change() -> void:
	_drop_old_floor()
	set_room(plan.stair_room)


func _drop_old_floor() -> void:
	if _old_floor != null and is_instance_valid(_old_floor):
		_old_floor.queue_free()
	_old_floor = null


## Stair geometry helpers (world space): the foot of the ramp on this storey and the landing
## on the storey above. The ramp runs along +x through the stair cell.
## Foot of this storey's flight (floor level) and its landing on the storey above.
func stair_foot() -> Vector3:
	var c := stair_pos()
	var d := InteriorMesher.stair_dir(plan.floor)
	return c + Vector3(InteriorMesher.STAIR_FOOT * d, 0, 0)


func stair_top() -> Vector3:
	var c := stair_pos()
	var d := InteriorMesher.stair_dir(plan.floor)
	return c + Vector3(InteriorMesher.STAIR_LAND * d, World.FLOOR_M, 0)


## The flight that comes DOWN from this storey (built by the floor below): foot/landing.
func stair_down_top() -> Vector3:
	var c := stair_pos()
	var d := InteriorMesher.stair_dir(plan.floor - 1)
	return c + Vector3(InteriorMesher.STAIR_LAND * d, 0, 0)


func stair_down_foot() -> Vector3:
	var c := stair_pos()
	var d := InteriorMesher.stair_dir(plan.floor - 1)
	return c + Vector3(InteriorMesher.STAIR_FOOT * d, -World.FLOOR_M, 0)


## Keep a point inside room `ri` (world space), `margin` metres off its walls.
func clamp_to_room(ri: int, p: Vector3, margin: float) -> Vector3:
	if plan == null or ri < 0:
		return p
	var r := plan.rooms[ri].rect
	var lo := plan.cell_to_world(Vector2(r.position))
	var hi := plan.cell_to_world(Vector2(r.end))
	return Vector3(clampf(p.x, lo.x + margin, hi.x - margin), p.y, clampf(p.z, lo.z + margin, hi.z - margin))


func room_at_world(p: Vector3) -> int:
	if plan == null:
		return -1
	var c := Vector2i(floori((p.x - plan.origin.x) / plan.cell_size.x), floori((p.z - plan.origin.z) / plan.cell_size.y))
	return plan.room_at_cell(c)


func entrance_room() -> int:
	return plan.doors[plan.entrance_door].a if (plan != null and plan.entrance_door >= 0) else -1


func entrance_pos() -> Vector3:
	return plan.doors[plan.entrance_door].pos if (plan != null and plan.entrance_door >= 0) else Vector3.ZERO


## Door indices from room a to room b through OPEN doors only (BFS). Empty if unreachable.
func route(a: int, b: int) -> Array:
	if plan == null or a < 0 or b < 0:
		return []
	if a == b:
		return []
	var prev := {}
	var via := {}
	var q: Array[int] = [a]
	prev[a] = -1
	while not q.is_empty():
		var r: int = q.pop_front()
		if r == b:
			break
		for di in plan.rooms[r].doors:
			var d := plan.doors[di]
			if d.b < 0 or not is_door_open(d):
				continue
			var o := plan.other_room(di, r)
			if prev.has(o):
				continue
			prev[o] = r
			via[o] = di
			q.append(o)
	if not prev.has(b):
		return []
	var out: Array = []
	var cur := b
	while cur != a:
		out.push_front(via[cur])
		cur = prev[cur]
	return out


## The building's exterior box collider would block line of sight to zombies inside it.
func _set_own_collider(enabled: bool) -> void:
	if building == null:
		return
	for body in get_tree().get_nodes_in_group("building_colliders"):
		if body.get_meta("bid", "") == building.id():
			for c in body.get_children():
				if c is CollisionShape3D:
					c.disabled = not enabled


func unload() -> void:
	_set_own_collider(true)
	if building != null:
		SectorMesher.set_doorway_open(building.id(), false)
	_drop_old_floor()
	for n in _room_nodes.values():
		n.queue_free()
	for n in _door_nodes.values():
		n.queue_free()
	_room_nodes.clear()
	_door_nodes.clear()
	_revealed.clear()
	plan = null
	building = null
	current_room = -1


# ------------------------------------------------------------------ state

func floor_state() -> Dictionary:
	var bs := World.building_state(building.id())
	if not bs.has("floors"):
		bs["floors"] = {}
	var key := str(plan.floor)
	if not bs["floors"].has(key):
		bs["floors"][key] = { "rooms": {}, "opened": {} }
	return bs["floors"][key]


func is_door_open(d: FloorPlan.Door) -> bool:
	return d.b < 0 or floor_state()["opened"].has(d.key())


func open_door(di: int) -> void:
	var d := plan.doors[di]
	floor_state()["opened"][d.key()] = true
	World.state_changed.emit(building.id())
	_reveal(d.a)
	if d.b >= 0:
		_reveal(d.b)
	# kick the leaf open (it stays open; the state above makes it open on later visits)
	if _door_nodes.has(di):
		InteriorMesher.kick_in(_door_nodes[di], plan.doors[di], current_room)
	door_kicked.emit(di)


## Rooms cleared / total across all storeys (generates the other plans; cheap).
func progress() -> Vector2i:
	var bs := World.building_state(building.id())
	var cleared := 0
	var total := 0
	for f in building.floors:
		var fp := plan if f == plan.floor else InteriorGen.generate(World.seed, building, f)
		total += fp.rooms.size()
		var fs: Dictionary = bs.get("floors", {}).get(str(f), {})
		cleared += (fs.get("rooms", {}) as Dictionary).size()
	return Vector2i(cleared, total)


func set_room(ri: int) -> void:
	current_room = ri
	_reveal(ri)
	_update_labels()
	# rooms visible through already-open doors
	for di in plan.rooms[ri].doors:
		var d := plan.doors[di]
		if is_door_open(d) and d.b >= 0:
			_reveal(plan.other_room(di, ri))


func is_room_cleared(ri: int) -> bool:
	return floor_state()["rooms"].has(str(ri))


## Called once the room's zombies are dead (or it had none).
func mark_room_cleared(ri: int) -> void:
	floor_state()["rooms"][str(ri)] = true
	var p := progress()
	World.set_building_state(building.id(), "progress", [p.x, p.y])
	if p.x >= p.y:
		World.set_building_state(building.id(), "cleared", true)


## Light up typed letters on the current room's door/stair words.
func show_typing(buffer: String) -> void:
	if current_room < 0 or not _room_nodes.has(current_room):
		return
	var n: Node3D = _room_nodes[current_room]
	var l: Node3D = n.get_node_or_null("Labels")
	if l == null:
		return
	for c in l.get_children():
		if c is WordLabel:
			c.match_buffer(buffer)


func _update_labels() -> void:
	for k in _room_nodes.keys():
		var n: Node3D = _room_nodes[k]
		var l: Node3D = n.get_node_or_null("Labels")
		if l != null:
			l.visible = (k == current_room)


func _reveal(ri: int) -> void:
	if ri < 0 or _revealed.has(ri):
		return
	_revealed[ri] = true
	if not _room_nodes.has(ri):
		_rebuild(ri)
	_set_room_visible(ri, true)


func _rebuild(ri: int) -> void:
	if not _revealed.has(ri):
		return
	if _room_nodes.has(ri):
		_room_nodes[ri].queue_free()
	var node := InteriorMesher.build_room(plan, ri, building, floor_state()["opened"])
	add_child(node)
	_room_nodes[ri] = node
	var l: Node3D = node.get_node_or_null("Labels")
	if l != null:
		l.visible = (ri == current_room)
	# door leaves are shared between two rooms: build once per floor
	for di in plan.rooms[ri].doors:
		var d := plan.doors[di]
		if d.b < 0 or _door_nodes.has(di):
			continue
		var leaf := InteriorMesher.build_door_leaf(d, is_door_open(d))
		add_child(leaf)
		_door_nodes[di] = leaf


# ------------------------------------------------------------------ typed options

## [{word, kind: "door"|"exit"|"up"|"down", door: di}]
func options() -> Array:
	var out := []
	if current_room < 0:
		return out
	var room := plan.rooms[current_room]
	for di in room.doors:
		var d := plan.doors[di]
		if d.b < 0:
			out.append({ "word": "exit", "kind": "exit", "door": di })
		else:
			out.append({ "word": d.word, "kind": "door", "door": di })
	# on the ground floor "exit" works from any room the front door can be reached from:
	# the rail walks you out through the doors you already opened
	var er := entrance_room()
	if er >= 0 and current_room != er and not route(current_room, er).is_empty():
		out.append({ "word": "exit", "kind": "exit", "door": plan.entrance_door })
	if room.is_stair:
		if plan.floor < plan.floors_total - 1:
			out.append({ "word": "up", "kind": "up", "door": -1 })
		if plan.floor > 0:
			out.append({ "word": "down", "kind": "down", "door": -1 })
	return out


## Step through a door and stop just inside: the room is in front of you, its zombies
## (which spawn away from the doors) have to come at you across it.
func path_through_door(di: int) -> PackedVector3Array:
	var d := plan.doors[di]
	var other := plan.other_room(di, current_room)
	return PackedVector3Array([d.pos, threshold_world(di, other)])


## A point 1.3 m inside room `ri` from door `di` (the stairwell uses its foot instead).
func threshold_world(di: int, ri: int) -> Vector3:
	if ri == plan.stair_room:
		return plan.room_stand_world(ri)
	var d := plan.doors[di]
	var into := Vector3(d.dir.x, 0, d.dir.y) if d.b == ri else Vector3(-d.dir.x, 0, -d.dir.y)
	return d.pos + into * 1.3


## From the current room, through open doors, out of the front door onto the road.
func path_to_street() -> PackedVector3Array:
	var pts := PackedVector3Array()
	var er := entrance_room()
	if current_room != er and current_room >= 0:
		pts.append_array(path_to_room(er))
	var d := plan.doors[plan.entrance_door]
	pts.append(d.pos)
	pts.append(World.tile_to_world(building.road_tile))
	return pts


## Walk from the current room to `target` through open doors: door, room, door, room...
func path_to_room(target: int) -> PackedVector3Array:
	var pts := PackedVector3Array()
	var r := current_room
	for di in route(current_room, target):
		var d: FloorPlan.Door = plan.doors[di]
		pts.append(d.pos)
		r = plan.other_room(di, r)
		pts.append(plan.room_stand_world(r))
	return pts


## World point an option refers to (for turning towards it as you type).
func option_pos(opt: Dictionary) -> Vector3:
	match opt["kind"]:
		"door", "exit":
			return plan.doors[opt["door"]].pos
		"up":
			return stair_pos() + Vector3(0, 1.4, 0)
		"down":
			return stair_down_top()
	return Vector3.INF


# ------------------------------------------------------------------ search

## Doors out of `ri` still worth opening: closed, with an uncleared room somewhere behind
## them that you cannot already reach through open doors.
func unexplored_doors(ri: int) -> Array[int]:
	var out: Array[int] = []
	var known := reachable_rooms(ri)
	for di in plan.rooms[ri].doors:
		var d := plan.doors[di]
		if d.b < 0 or is_door_open(d):
			continue
		if _uncleared_beyond(plan.other_room(di, ri), known):
			out.append(di)
	return out


## Rooms reachable from `ri` through open doors (including `ri`).
func reachable_rooms(ri: int) -> Dictionary:
	var seen := { ri: true }
	var q: Array[int] = [ri]
	while not q.is_empty():
		var r: int = q.pop_front()
		for di in plan.rooms[r].doors:
			var d := plan.doors[di]
			if d.b < 0 or not is_door_open(d):
				continue
			var o := plan.other_room(di, r)
			if not seen.has(o):
				seen[o] = true
				q.append(o)
	return seen


## Is there an uncleared room in the part of the floor behind `start` (walking through any
## door, open or closed, but never back into `known` territory)?
func _uncleared_beyond(start: int, known: Dictionary) -> bool:
	var seen := { start: true }
	var q: Array[int] = [start]
	while not q.is_empty():
		var r: int = q.pop_front()
		if not is_room_cleared(r):
			return true
		for di in plan.rooms[r].doors:
			var d := plan.doors[di]
			if d.b < 0:
				continue
			var o := plan.other_room(di, r)
			if not seen.has(o) and not known.has(o):
				seen[o] = true
				q.append(o)
	return false


## Any storey other than this one with rooms left to clear?
func other_floors_uncleared() -> bool:
	var bs := World.building_state(building.id())
	for f in building.floors:
		if f == plan.floor:
			continue
		var fp := InteriorGen.generate(World.seed, building, f)
		var fs: Dictionary = bs.get("floors", {}).get(str(f), {})
		if (fs.get("rooms", {}) as Dictionary).size() < fp.rooms.size():
			return true
	return false


## The manual search: from `from`, the nearest room (through open doors) that still has a
## closed door worth opening. When this storey is done: the stairwell if other storeys are
## not, else the entrance (to exit), else the stairwell. Returns `from` if nothing better.
func search_target(from: int) -> int:
	if plan == null or from < 0:
		return from
	var order: Array[int] = [from]
	var seen := { from: true }
	var i := 0
	while i < order.size():
		var r := order[i]
		i += 1
		if not unexplored_doors(r).is_empty():
			return r
		for di in plan.rooms[r].doors:
			var d := plan.doors[di]
			if d.b < 0 or not is_door_open(d):
				continue
			var o := plan.other_room(di, r)
			if not seen.has(o):
				seen[o] = true
				order.append(o)
	var stair_ok := plan.stair_room >= 0 and seen.has(plan.stair_room)
	if stair_ok and other_floors_uncleared():
		return plan.stair_room
	var er := entrance_room()
	if er >= 0 and seen.has(er):
		return er
	if stair_ok:
		return plan.stair_room
	return from


func stair_pos() -> Vector3:
	return plan.cell_to_world(Vector2(plan.stair_cell) + Vector2(0.5, 0.5))


## Switch storey in place. Returns the stair position on the new floor.
func change_floor(delta: int) -> Vector3:
	var b := building
	var f := plan.floor + delta
	enter(b, f)
	var sp := stair_pos()
	set_room(plan.stair_room)
	return sp
