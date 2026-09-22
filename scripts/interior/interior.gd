extends Node3D
## The storey the player is currently inside. Builds revealed rooms only (per-floor fog),
## applies room/door state to World, and answers "what can be typed from here".

signal door_kicked(di: int)

const PropLootRules = preload("res://scripts/loot/prop_loot.gd")

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


## Claimed buildings use the same generated floor plan as clearing, but the whole ground
## floor is visible for free-roam furnishing rather than gated by combat exploration.
func reveal_all() -> void:
	if plan == null:
		return
	for ri in plan.rooms.size():
		_reveal(ri)


func nearest_salvageable_prop(world_pos: Vector3, max_distance: float = 3.4) -> FloorPlan.Prop:
	if plan == null or building == null:
		return null
	var nearest: FloorPlan.Prop
	var best := max_distance * max_distance
	for prop in plan.props:
		if PropSalvage.is_salvaged(building.id(), prop.id):
			continue
		var d := Vector2(prop.pos.x - world_pos.x, prop.pos.z - world_pos.z).length_squared()
		if d < best:
			best = d
			nearest = prop
	return nearest


func salvage_hint(world_pos: Vector3) -> String:
	var prop := nearest_salvageable_prop(world_pos)
	return "" if prop == null else PropSalvage.hint(prop)


func salvage_nearest(world_pos: Vector3) -> String:
	var prop := nearest_salvageable_prop(world_pos)
	if prop == null:
		return "no intact furniture close enough to dismantle"
	var result := PropSalvage.salvage(building.id(), prop)
	if result.begins_with("dismantled"):
		_rebuild(prop.room)
		_set_room_visible(prop.room, true)
	return result


func nearest_lootable_prop(world_pos: Vector3, require_capacity := true) -> FloorPlan.Prop:
	if plan == null or building == null or current_room < 0:
		return null
	var nearest: FloorPlan.Prop
	var best := INF
	for prop in plan.props:
		if prop.room != current_room or prop.loot_table == "" \
				or PropLootRules.is_looted(building.id(), prop.id) \
				or PropSalvage.is_salvaged(building.id(), prop.id):
			continue
		if require_capacity and not World.can_carry(PropLootRules.contents(building.id(), prop)):
			continue
		var d := Vector2(prop.pos.x - world_pos.x, prop.pos.z - world_pos.z).length_squared()
		if d < best:
			best = d
			nearest = prop
	return nearest


func has_loot_here(world_pos: Vector3) -> bool:
	return nearest_lootable_prop(world_pos) != null


func loot_hint(world_pos: Vector3) -> String:
	var prop := nearest_lootable_prop(world_pos)
	return "" if prop == null else "type LOOT to search %s" % prop.kind


func loot_here(world_pos: Vector3) -> String:
	var prop := nearest_lootable_prop(world_pos)
	if prop == null:
		var blocked := nearest_lootable_prop(world_pos, false)
		if blocked != null:
			return "backpack full — return to a safe zone to sort it"
		return "nothing left to loot in this room"
	var result: String = PropLootRules.loot(building.id(), prop)
	if result.begins_with("searched"):
		_rebuild(prop.room)
		_set_room_visible(prop.room, true)
	return result


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
	for c in n.find_children("*", "VisualInstance3D", true, false):
		# Structural shells stay rendered for unrevealed rooms. Hiding those meshes made
		# the one-way exterior facade disappear from an interior camera, exposing the city
		# (and any pre-seeded encounter actors) through a building-shaped hole.
		var structure := bool(c.get_meta("room_structure", false))
		(c as VisualInstance3D).visible = (v or structure) and not c.get_meta("hidden", false)
	for c in n.find_children("*", "AudioStreamPlayer3D", true, false):
		var audio := c as AudioStreamPlayer3D
		if v and not audio.playing:
			audio.play()
		elif not v and audio.playing:
			audio.stop()


func is_room_revealed(ri: int) -> bool:
	return _revealed.has(ri)


## Hide/show one part of a room's build (the stairwell's DownFlights / ShaftCap while the
## storey they stand in for is really there, during a climb).
func _set_part_hidden(node: Node3D, part: String, hidden: bool) -> void:
	if node == null:
		return
	var c: Node3D = node.get_node_or_null(part)
	if c == null:
		return
	c.set_meta("hidden", hidden)
	c.visible = not hidden and c.get_parent().get_node("Mesh").visible


## Start a stair transition: the current storey stays visible (parked under _old_floor)
## while the new one is built; call finish_floor_change() once the player has arrived.
func begin_floor_change(delta: int) -> void:
	_drop_old_floor()
	_old_floor = Node3D.new()
	_old_floor.name = "OldFloor"
	add_child(_old_floor)
	var old_stair: Node3D = _room_nodes.get(plan.stair_room)
	# the two storeys overlap in the stairwell: the old one's stand-ins for the storey we
	# are moving to go away, and the new one's stand-ins for the old storey stay hidden
	_set_part_hidden(old_stair, "ShaftCap" if delta > 0 else "DownFlights", true)
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
	_set_part_hidden(_room_nodes.get(plan.stair_room), "DownFlights" if delta > 0 else "ShaftCap", true)
	_pending_part = "DownFlights" if delta > 0 else "ShaftCap"
	_reveal(plan.stair_room)


var _pending_part := ""


func finish_floor_change() -> void:
	_drop_old_floor()
	if _pending_part != "":
		_set_part_hidden(_room_nodes.get(plan.stair_room), _pending_part, false)
		_pending_part = ""


func _drop_old_floor() -> void:
	if _old_floor != null and is_instance_valid(_old_floor):
		_old_floor.queue_free()
	_old_floor = null


# ------------------------------------------------------------------ stairwell

## The rail through the stairwell from the opening of the current room to the opening
## of `out_room` on the storey above/below. Call BEFORE begin_floor_change (this storey's
## plan), then append exit_path() from the new plan.
func climb_path(up: bool) -> PackedVector3Array:
	var pts := PackedVector3Array()
	if plan.stair_layout.is_empty():
		return pts
	if current_room != plan.stair_room:
		var di := plan.stair_opening(current_room)
		if di < 0:
			return pts
		var d := plan.doors[di]
		pts.append(d.pos)
		pts.append(Stairwell.inside_point(plan, plan.stair_layout, d, 0.0))
	pts.append_array(Stairwell.climb_points(plan, plan.stair_layout, up))
	return pts


## Where the climb ends on the new storey: the landing inside the stairwell.
func landing(from_below: bool) -> Vector3:
	return Stairwell.landing_point(plan, plan.stair_layout, from_below)


## Which room to step into from the stairwell on this (new) storey: one with zombies or
## closed doors left, else any. -1 if the stairwell has no opening (should not happen).
func stair_exit_room() -> int:
	var best := -1
	var best_score := -1
	for di in plan.rooms[plan.stair_room].doors:
		var d := plan.doors[di]
		if d.b < 0:
			continue
		var o := plan.other_room(di, plan.stair_room)
		var score := 0
		if not is_room_cleared(o): score += 2
		if not unexplored_doors(o).is_empty(): score += 1
		if is_door_open(d): score += 1
		if score > best_score:
			best_score = score
			best = o
	return best


## World point of the stairwell opening from room `ri` (label/facing anchor), or INF.
func stair_opening_pos(ri: int) -> Vector3:
	var di := plan.stair_opening(ri)
	return plan.doors[di].pos if di >= 0 else Vector3.INF


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
	return d.b < 0 or d.open_always or floor_state()["opened"].has(d.key())


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
	_update_labels()
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
	if ri == current_room:
		_update_labels()


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
			(c as WordLabel).match_buffer(buffer)


func _update_labels() -> void:
	var rec := recommended_option() if current_room >= 0 else {}
	for k in _room_nodes.keys():
		var n: Node3D = _room_nodes[k]
		var l: Node3D = n.get_node_or_null("Labels")
		if l != null:
			l.visible = (k == current_room)
			if k == current_room:
				for c in l.get_children():
					if not c is WordLabel:
						continue
					var w := c as WordLabel
					w.retired = option_retired(w.option_kind, w.option_door)
					w.recommended = not w.retired and not rec.is_empty() \
						and w.option_kind == rec.get("kind", "") and w.option_door == rec.get("door", -2)
					w.edge_hint = true


func _reveal(ri: int, hop := true) -> void:
	if ri < 0:
		return
	if not _revealed.has(ri):
		_revealed[ri] = true
		if not _room_nodes.has(ri):
			_rebuild(ri)
		_set_room_visible(ri, true)
	if hop:
		# whatever you can see through this room's open doors and archways
		for di in plan.rooms[ri].doors:
			var d := plan.doors[di]
			if d.b >= 0 and is_door_open(d):
				_reveal(plan.other_room(di, ri), false)


func _rebuild(ri: int) -> void:
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
		if d.b < 0 or d.open_always or _door_nodes.has(di):
			continue
		var leaf := InteriorMesher.build_door_leaf(d, is_door_open(d), InteriorMesher.wall_color(building, d.a), InteriorMesher.wall_color(building, d.b))
		add_child(leaf)
		_door_nodes[di] = leaf


# ------------------------------------------------------------------ typed options

## Every reachable typed choice. Fully explored branches stay crossed out so they no longer
## compete for the recommendation, but remain typeable for deliberate backtracking.
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
	# the stairwell archway in this room (or the flights, standing in the stairwell): the
	# storeys they lead to
	var so := plan.stair_opening(current_room)
	if so >= 0 or room.is_stair:
		if plan.floor < plan.floors_total - 1 and floors_above_uncleared():
			out.append({ "word": "up", "kind": "up", "door": so })
		if plan.floor > 0:
			out.append({ "word": "down", "kind": "down", "door": so })
	if rescue_waiting_here() and is_room_cleared(current_room):
		var mission := active_rescue()
		out.append({ "word": mission.get("word", "help"), "kind": "rescue", "door": -1, "survivor": mission.get("id", "") })
	if is_room_cleared(current_room) and has_loot_here(plan.room_stand_world(current_room)):
		out.append({ "word": "loot", "kind": "loot", "door": -1 })
	return out


## A door is a retired dead end once every room in the branch on its far side is clear.
## We deliberately traverse closed doors too: a cleared room with an unopened door leading
## to danger is not a dead end. The current room is treated as the branch boundary.
func door_retired(di: int, from: int) -> bool:
	if plan == null or di < 0 or from < 0:
		return false
	var d := plan.doors[di]
	if d.b < 0:
		return false
	var mission := active_rescue()
	if not mission.is_empty() and int(mission["floor"]) == plan.floor:
		var rescue_path := route_any(from, int(mission["room"]))
		if not rescue_path.is_empty() and rescue_path[0] == di:
			return false
	var start := plan.other_room(di, from)
	# An already-open route into a cleared room is useful only when it is the first leg of
	# the shortest route to the next frontier. Alternate loops and cleared side branches
	# stay visible as spatial memory, but no longer compete for typing input.
	if is_door_open(d) and is_room_cleared(start) and unexplored_doors(start).is_empty():
		var target := search_target(from)
		var path := route(from, target) if target != from else []
		if path.is_empty() or path[0] != di:
			return true
	var seen := { from: true, start: true }
	var q: Array[int] = [start]
	while not q.is_empty():
		var r: int = q.pop_front()
		if not is_room_cleared(r):
			return false
		if r == plan.stair_room and other_floors_uncleared():
			return false
		for dj in plan.rooms[r].doors:
			var edge := plan.doors[dj]
			if edge.b < 0:
				continue
			var o := plan.other_room(dj, r)
			if not seen.has(o):
				seen[o] = true
				q.append(o)
	return true


func floor_uncleared(floor: int) -> bool:
	if floor_has_pending_rescue(floor):
		return true
	var bs := World.building_state(building.id())
	var fp := plan if floor == plan.floor else InteriorGen.generate(World.seed, building, floor)
	var fs: Dictionary = bs.get("floors", {}).get(str(floor), {})
	return (fs.get("rooms", {}) as Dictionary).size() < fp.rooms.size()


func floors_above_uncleared() -> bool:
	for f in range(plan.floor + 1, building.floors):
		if floor_uncleared(f):
			return true
	return false


func option_retired(kind: String, door: int) -> bool:
	match kind:
		"door": return door_retired(door, current_room)
		"up": return not floors_above_uncleared()
		"rescue": return false
	return false


## Single best next action for camera facing and the gold route chevron. Combat still wins
## over navigation in Main; this answers only the quiet-room case.
func recommended_option() -> Dictionary:
	if plan == null or current_room < 0:
		return {}
	var rescue_option := recommended_rescue_option()
	if not rescue_option.is_empty():
		return rescue_option
	if is_room_cleared(current_room) and has_loot_here(plan.room_stand_world(current_room)):
		return { "word": "loot", "kind": "loot", "door": -1 }
	var useful := unexplored_doors(current_room)
	if not useful.is_empty():
		var di: int = useful[0]
		return { "word": plan.doors[di].word, "kind": "door", "door": di }
	var target := search_target(current_room)
	if target != current_room:
		var path := route(current_room, target)
		if not path.is_empty():
			var di: int = path[0]
			return { "word": plan.doors[di].word, "kind": "door", "door": di }
	var so := plan.stair_opening(current_room)
	if (so >= 0 or plan.rooms[current_room].is_stair) and floors_above_uncleared():
		return { "word": "up", "kind": "up", "door": so }
	if (so >= 0 or plan.rooms[current_room].is_stair) and plan.floor > 0:
		return { "word": "down", "kind": "down", "door": so }
	for opt in options():
		if opt["kind"] == "exit":
			return opt
	for opt in options():
		if not option_retired(opt["kind"], opt.get("door", -1)):
			return opt
	return options()[0] if not options().is_empty() else {}


## Step through a door and stop just inside: the room is in front of you, its zombies
## (which spawn away from the doors) have to come at you across it.
func path_through_door(di: int) -> PackedVector3Array:
	var d := plan.doors[di]
	var other := plan.other_room(di, current_room)
	return PackedVector3Array([d.pos, threshold_world(di, other)])


## A point 1.3 m inside room `ri` from door `di` (inside the stairwell: on its walkway).
func threshold_world(di: int, ri: int) -> Vector3:
	if ri == plan.stair_room:
		return Stairwell.inside_point(plan, plan.stair_layout, plan.doors[di], 0.0)
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
		# through the stairwell: keep to its walkway, never across the flights
		pts.append(threshold_world(di, r) if r == plan.stair_room else plan.room_stand_world(r))
	return pts


## World point an option refers to (for turning towards it as you type).
func option_pos(opt: Dictionary) -> Vector3:
	match opt["kind"]:
		"door", "exit":
			return plan.doors[opt["door"]].pos
		"up", "down":
			if opt["door"] >= 0:
				return plan.doors[opt["door"]].pos + Vector3(0, 1.4, 0)
			var lps := Stairwell.label_points(plan, plan.stair_layout)
			return lps.get(opt["kind"], Vector3.INF)
		"rescue":
			return rescue_world_pos()
		"loot":
			var prop := nearest_lootable_prop(plan.room_stand_world(current_room))
			return prop.pos + Vector3(0, prop.size.y * 0.5, 0) if prop != null else Vector3.INF
	return Vector3.INF


# ------------------------------------------------------------------ survivor rescue

func active_rescue() -> Dictionary:
	return World.active_rescue(building.id()) if building != null else {}


func floor_has_pending_rescue(floor: int) -> bool:
	var mission := active_rescue()
	return not mission.is_empty() and int(mission["floor"]) == floor


func rescue_waiting_here() -> bool:
	return plan != null and current_room >= 0 and World.rescue_at(building.id(), plan.floor, current_room)


func rescue_world_pos() -> Vector3:
	var mission := active_rescue()
	if mission.is_empty() or plan == null:
		return Vector3.INF
	var target_plan: FloorPlan = plan
	if int(mission["floor"]) != plan.floor:
		target_plan = InteriorGen.generate(World.seed, building, int(mission["floor"]))
	var ri := int(mission["room"])
	if ri < 0 or ri >= target_plan.rooms.size():
		return Vector3.INF
	var centre := target_plan.room_stand_world(ri)
	var offset_seed := Det.h(World.seed, building.seed_hash, ri, 1204)
	var offset_bit := floori(float(offset_seed) / 2.0) % 2
	var offset := Vector3(0.45 if offset_seed % 2 == 0 else -0.45, 0.85, 0.25 if offset_bit == 0 else -0.25)
	var room_rect := target_plan.rooms[ri].rect
	var lo := target_plan.cell_to_world(Vector2(room_rect.position))
	var hi := target_plan.cell_to_world(Vector2(room_rect.end))
	var p := centre + offset
	return Vector3(clampf(p.x, lo.x + 0.7, hi.x - 0.7), p.y, clampf(p.z, lo.z + 0.7, hi.z - 0.7))


## Route through the generated room graph regardless of door state. Used only for rescue
## guidance; actual movement still requires opening doors and `route()` still means open.
func route_any(a: int, b: int) -> Array[int]:
	if plan == null or a < 0 or b < 0 or a == b:
		return []
	var prev := { a: -1 }
	var via := {}
	var q: Array[int] = [a]
	while not q.is_empty():
		var r: int = q.pop_front()
		if r == b:
			break
		for di in plan.rooms[r].doors:
			var d := plan.doors[di]
			if d.b < 0:
				continue
			var other := plan.other_room(di, r)
			if prev.has(other):
				continue
			prev[other] = r
			via[other] = di
			q.append(other)
	if not prev.has(b):
		return []
	var out: Array[int] = []
	var cur := b
	while cur != a:
		out.push_front(via[cur])
		cur = prev[cur]
	return out


func recommended_rescue_option() -> Dictionary:
	var mission := active_rescue()
	if mission.is_empty():
		return {}
	var target_floor := int(mission["floor"])
	if target_floor == plan.floor:
		var target_room := int(mission["room"])
		if current_room == target_room:
			if is_room_cleared(current_room):
				return { "word": mission.get("word", "help"), "kind": "rescue", "door": -1, "survivor": mission["id"] }
			return {}
		var rescue_path := route_any(current_room, target_room)
		if not rescue_path.is_empty():
			var di: int = rescue_path[0]
			return { "word": plan.doors[di].word, "kind": "door", "door": di }
		return {}
	var direction := "up" if target_floor > plan.floor else "down"
	var so := plan.stair_opening(current_room)
	if so >= 0 or plan.rooms[current_room].is_stair:
		return { "word": direction, "kind": direction, "door": so }
	if plan.stair_room >= 0:
		var stair_path := route_any(current_room, plan.stair_room)
		if not stair_path.is_empty():
			var di: int = stair_path[0]
			return { "word": plan.doors[di].word, "kind": "door", "door": di }
	return {}


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
		var mission := active_rescue()
		if not mission.is_empty() and int(mission["floor"]) == plan.floor and int(mission["room"]) == r:
			return true
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
		if floor_has_pending_rescue(f):
			return true
		var fp := InteriorGen.generate(World.seed, building, f)
		var fs: Dictionary = bs.get("floors", {}).get(str(f), {})
		if (fs.get("rooms", {}) as Dictionary).size() < fp.rooms.size():
			return true
	return false


## The manual search: from `from`, the nearest room (through open doors) that still has a
## closed door worth opening. When this storey is done: the nearest room with a stairwell
## archway if other storeys are not, else the entrance (to exit), else a stairwell room.
## Never the stairwell itself. Returns `from` if nothing better.
func search_target(from: int) -> int:
	if plan == null or from < 0:
		return from
	var mission := active_rescue()
	if not mission.is_empty():
		var target_floor := int(mission["floor"])
		if target_floor == plan.floor:
			var target_room := int(mission["room"])
			if target_room == from:
				return from
			if not route(from, target_room).is_empty():
				return target_room
	var order: Array[int] = [from]
	var seen := { from: true }
	var i := 0
	while i < order.size():
		var r := order[i]
		i += 1
		if r != from and (not is_room_cleared(r) or not unexplored_doors(r).is_empty()):
			return r
		if r == from and not unexplored_doors(r).is_empty():
			return r
		for di in plan.rooms[r].doors:
			var d := plan.doors[di]
			if d.b < 0 or not is_door_open(d):
				continue
			var o := plan.other_room(di, r)
			if not seen.has(o):
				seen[o] = true
				order.append(o)
	# A survivor on another storey makes the nearest reachable stair the primary search
	# destination even if every room on this floor has already been cleared.
	if not mission.is_empty() and int(mission["floor"]) != plan.floor:
		for r in order:
			if r == plan.stair_room or plan.stair_opening(r) >= 0:
				return r
	# this storey is done: the stairwell (or the nearest room with a door to it) when other
	# storeys are not, else the entrance to leave
	var stair_near := -1
	for r in order:
		if r == plan.stair_room or plan.stair_opening(r) >= 0:
			stair_near = r
			break
	if stair_near >= 0 and other_floors_uncleared():
		return stair_near
	var er := entrance_room()
	if er >= 0 and seen.has(er):
		return er
	if stair_near >= 0:
		return stair_near
	return from
