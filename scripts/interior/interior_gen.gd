class_name InteriorGen
## Deterministic floor plans: BSP rooms on a ~2.5 m cell grid over the building footprint,
## doors as a spanning tree plus a few loops, a stairwell anchored per building so up/down
## line up across storeys, and the street entrance on floor 0 exactly where the facade's
## door quad is. Every door gets a typeable word, unique per floor and prefix-free.

const CELL_M := 2.5
const RESERVED := ["up", "down", "exit"]
const WORDS := [
	"attic","basin","bench","blade","bolt","bucket","cabin","candle","cellar","chain","chalk","chest",
	"cider","clock","cloth","couch","crate","crowbar","curtain","desk","drawer","dust","ember","fence",
	"flask","fridge","garage","glass","grate","hammer","hatch","hinge","hook","iron","jacket","kettle",
	"knife","ladder","lamp","latch","lever","locker","marble","mirror","mop","nail","oven","pantry",
	"pipe","plank","plaster","porch","radio","rail","rope","rug","rust","saw","shelf","shovel","sink",
	"sofa","stool","stove","table","tank","tape","tarp","tile","toolbox","torch","towel","trunk",
	"valve","vent","vase","wire","wrench","yard","anvil","barrel","boiler","broom","carpet","closet",
	"coat","cot","cradle","dial","drill","fan","file","fuse","gear","hose","jar","jug","kiln","lantern",
	"lid","lock","mat","meter","mug","nook","pail","pan","pen","pot","quilt","rack","ramp","ring",
	"rod","sack","seat","sled","sponge","stamp","strap","tin","tray","tub","tube","urn","vault","vial",
	"wick","wheel","zip","axe","bin","cog","cup","dye","fork","gate","hat","ink","key","log","map",
	"net","oar","pad","peg","pin","rib","sod","tag","tap","toy","van","wax","yarn",
]


static func footprint(b: BuildingData) -> Rect2:
	## World-space XZ rect of the walls (the facade is built from this same rect).
	var inset := 0.25 if b.district == District.Kind.DOWNTOWN else (0.7 if b.district == District.Kind.STRIP or b.district == District.Kind.INDUSTRIAL else 1.3)
	if b.kind == "apartments":
		inset = 0.5   # blocks fill their lot: room for a corridor with flats on both sides
	var T := World.TILE_M
	return Rect2(b.rect.position.x * T + inset, b.rect.position.y * T + inset,
		b.rect.size.x * T - 2.0 * inset, b.rect.size.y * T - 2.0 * inset)


static func _room_limits(district: int) -> Vector2i:
	## (min, max) room side in cells
	match district:
		District.Kind.INDUSTRIAL: return Vector2i(3, 7)
		District.Kind.DOWNTOWN, District.Kind.STRIP: return Vector2i(2, 4)
		_: return Vector2i(2, 3)


static func generate(seed: int, b: BuildingData, floor: int) -> FloorPlan:
	var fp := FloorPlan.new()
	fp.building_id = b.id()
	fp.floor = floor
	fp.floors_total = b.floors
	var fpr := footprint(b)
	fp.cells = Vector2i(maxi(2, floori(fpr.size.x / CELL_M)), maxi(2, floori(fpr.size.y / CELL_M)))
	fp.cell_size = Vector2(fpr.size.x / fp.cells.x, fpr.size.y / fp.cells.y)
	fp.origin = Vector3(fpr.position.x, floor * World.FLOOR_M, fpr.position.y)
	fp.cell_room = PackedInt32Array()
	fp.cell_room.resize(fp.cells.x * fp.cells.y)
	fp.cell_room.fill(-1)
	var rng := Det.rng_for(seed, b.seed_hash, floor, 500 + b.index)

	if b.kind == "apartments" and _plan_apartments(fp, b, fpr, rng):
		pass
	else:
		_plan_bsp(fp, b, fpr, rng, floor)

	# --- street entrance on the ground floor, at the facade door position
	if floor == 0:
		_add_entrance(fp, b, fpr)

	# --- words: unique per floor, no prefix of another prompt (typing is prefix-matched)
	var chosen: Array[String] = []
	chosen.append_array(RESERVED)
	for door in fp.doors:
		if door.b < 0:
			continue
		var w := ""
		var tries := 0
		while tries < 40:
			w = WORDS[rng.randi_range(0, WORDS.size() - 1)]
			var ok := true
			for c in chosen:
				if c.begins_with(w) or w.begins_with(c):
					ok = false
					break
			if ok:
				break
			tries += 1
		door.word = w
		chosen.append(w)
	return fp


## Houses, shops, offices: BSP rooms, a stairwell strip carved out, doors as a spanning
## tree plus a few loops.
static func _plan_bsp(fp: FloorPlan, b: BuildingData, fpr: Rect2, rng: RandomNumberGenerator, floor: int) -> void:
	# --- rooms (BSP)
	var lim := _room_limits(b.district)
	var leaves: Array[Rect2i] = []
	_split(Rect2i(Vector2i.ZERO, fp.cells), rng, lim.x, lim.y, leaves)
	for i in leaves.size():
		var r := FloorPlan.Room.new()
		r.index = i
		r.rect = leaves[i]
		r.kind = "room"
		fp.rooms.append(r)
		for y in range(r.rect.position.y, r.rect.end.y):
			for x in range(r.rect.position.x, r.rect.end.x):
				fp.cell_room[y * fp.cells.x + x] = i

	# --- stairwell: one strip per building (same on every storey), carved out of the BSP
	# rooms it overlaps as its own pass-through room. See Stairwell.
	var ecell := _entrance_cell(b, fp, fpr)
	var lay := Stairwell.layout(b, fp.cells, ecell)
	if not lay.is_empty():
		fp.stair_layout = lay
		fp.stair_cell = Stairwell.entry_cell(lay)
		fp.stair_room = _carve_rect(fp, lay["rect"])
		fp.rooms[fp.stair_room].is_stair = true
		fp.rooms[fp.stair_room].kind = "stair"

	# --- doors: candidates per adjacent pair, spanning tree + loops
	var cands := {}   # "i-j" -> Array of [cell, dir] (from room i side)
	for y in fp.cells.y:
		for x in fp.cells.x:
			var ri := fp.cell_room[y * fp.cells.x + x]
			for d: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
				var n := Vector2i(x, y) + d
				var rj := fp.room_at_cell(n)
				if rj < 0 or rj == ri:
					continue
				var key := "%d-%d" % [mini(ri, rj), maxi(ri, rj)]
				if not cands.has(key):
					cands[key] = []
				# store from the lower-index room's side
				if ri < rj:
					cands[key].append([Vector2i(x, y), d, ri, rj])
				else:
					cands[key].append([n, -d, rj, ri])
	var pairs := cands.keys()
	_shuffle(pairs, rng)
	if fp.stair_room >= 0:
		# stairwell openings only where the layout allows (the entry landing / the walkway
		# side); pairs with a preferred edge come first so the spanning tree uses them
		var tiers: Array = Stairwell.allowed_edges(fp.stair_layout)
		var front: Array = []
		var rest: Array = []
		for key in pairs:
			var opts: Array = cands[key]
			if opts[0][2] != fp.stair_room and opts[0][3] != fp.stair_room:
				rest.append(key)
				continue
			var pref: Array = []
			var okay: Array = []
			for o in opts:
				var cell: Vector2i = o[0] if o[2] == fp.stair_room else o[0] + o[1]
				var d: Vector2i = o[1] if o[2] == fp.stair_room else -o[1]   # from the stair room's side
				if [cell, d] in tiers[0]:
					pref.append(o)
				elif [cell, d] in tiers[1]:
					okay.append(o)
			if not pref.is_empty():
				cands[key] = pref
				front.append(key)
			elif not okay.is_empty():
				cands[key] = okay
				rest.append(key)
			else:
				cands.erase(key)     # not a place an opening may go
		pairs = front + rest
	var parent := PackedInt32Array()
	parent.resize(fp.rooms.size())
	for i in parent.size():
		parent[i] = i
	var used := {}
	for key in pairs:
		var opts: Array = cands[key]
		var pick: Array = opts[rng.randi_range(0, opts.size() - 1)]
		var ra: int = pick[2]
		var rb: int = pick[3]
		if _find(parent, ra) != _find(parent, rb):
			_union(parent, ra, rb)
			_add_door(fp, pick[0], pick[1], ra, rb)
			used[key] = true
	for key in pairs:
		if used.has(key) or rng.randf() > 0.22:
			continue
		var opts: Array = cands[key]
		var pick: Array = opts[rng.randi_range(0, opts.size() - 1)]
		if fp.stair_room >= 0 and (pick[2] == fp.stair_room or pick[3] == fp.stair_room) and fp.rooms[fp.stair_room].doors.size() >= 2:
			continue
		_add_door(fp, pick[0], pick[1], pick[2], pick[3])



## The street door on the ground floor, exactly where the facade's door quad is.
static func _add_entrance(fp: FloorPlan, b: BuildingData, fpr: Rect2) -> void:
	var d := b.road_tile - b.door_tile
	var T := World.TILE_M
	var dc := Vector2((b.door_tile.x + 0.5) * T, (b.door_tile.y + 0.5) * T)
	var cell := _entrance_cell(b, fp, fpr)
	var ra := fp.room_at_cell(cell)
	var door := FloorPlan.Door.new()
	door.index = fp.doors.size()
	door.a = ra
	door.b = -1
	door.cell = cell
	door.dir = d
	door.word = "exit"
	# exact facade position, on the wall plane
	if d.x == 0:
		door.pos = Vector3(dc.x, fp.origin.y, fpr.position.y if d.y < 0 else fpr.end.y)
	else:
		door.pos = Vector3(fpr.position.x if d.x < 0 else fpr.end.x, fp.origin.y, dc.y)
	fp.doors.append(door)
	fp.rooms[ra].doors.append(door.index)
	fp.rooms[ra].is_entrance = true
	fp.rooms[ra].kind = "entrance"
	fp.entrance_door = door.index


## Apartment block: a corridor down the long axis with a switchback core at one end and
## flats off both sides (a front room on the corridor, back rooms behind). Returns false
## when the footprint is too small, so the caller falls back to the BSP plan.
static func _plan_apartments(fp: FloorPlan, b: BuildingData, fpr: Rect2, rng: RandomNumberGenerator) -> bool:
	var along_x := fp.cells.x >= fp.cells.y
	var L := fp.cells.x if along_x else fp.cells.y     # cells along the corridor
	var Wc := fp.cells.y if along_x else fp.cells.x    # cells across
	if L < 4 or Wc < 2 or b.floors < 2:
		return false
	var mid := Wc / 2                                  # corridor row/column
	var rooms: Array = []                              # [Rect2i, kind]
	# stairwell: the last two corridor cells, entered from the corridor
	var stair_end := (b.seed_hash >> 9) % 2 == 0       # which end of the corridor
	var s0 := (L - 2) if stair_end else 0
	var stair_rect := Rect2i(s0, mid, 2, 1) if along_x else Rect2i(mid, s0, 1, 2)
	# `along` runs from the entry cell (next to the corridor) to the far end of the strip
	var along := Vector2i(1, 0) if along_x else Vector2i(0, 1)
	if not stair_end:
		along = -along
	var corr_rect := (Rect2i(0 if stair_end else 2, mid, L - 2, 1)) if along_x else (Rect2i(mid, 0 if stair_end else 2, 1, L - 2))
	rooms.append([corr_rect, "hall"])
	# flats on each side: strips split along the corridor into units 1-3 cells wide
	var sides: Array = []
	if mid > 0:
		sides.append([0, mid])                         # rows [0, mid)
	if mid + 1 < Wc:
		sides.append([mid + 1, Wc])
	var unit_doors: Array = []                         # [front room rect index, corridor-facing dir]
	for side in sides:
		var r0: int = side[0]
		var r1: int = side[1]
		var depth := r1 - r0
		var toward_corr := Vector2i(0, 1) if r0 < mid else Vector2i(0, -1)   # from the front row to the corridor
		if not along_x:
			toward_corr = Vector2i(1, 0) if r0 < mid else Vector2i(-1, 0)
		var t := 0
		while t < L:
			var w := mini(rng.randi_range(1, 3), L - t)
			if L - (t + w) == 1:
				w += 1                                 # no 1-cell leftovers
			if t == 0 and not stair_end and w < 2:
				w = 2                                  # never a flat that only sits over the far stair cell
			var front_row := (mid - 1) if r0 < mid else (mid + 1)
			var front := Rect2i(t, front_row, w, 1) if along_x else Rect2i(front_row, t, 1, w)
			rooms.append([front, "flat"])
			unit_doors.append([rooms.size() - 1, toward_corr])
			var front_idx := rooms.size() - 1
			if depth >= 2:
				# back rooms behind the front room, away from the corridor
				var back_rows := Vector2i(r0, mid - 1) if r0 < mid else Vector2i(mid + 2, r1)   # [a, b)
				var back := Rect2i(t, back_rows.x, w, back_rows.y - back_rows.x) if along_x else Rect2i(back_rows.x, t, back_rows.y - back_rows.x, w)
				if w >= 2 and rng.randf() < 0.55:
					var cut := rng.randi_range(1, w - 1)
					var b1 := Rect2i(t, back.position.y, cut, back.size.y) if along_x else Rect2i(back.position.x, t, back.size.x, cut)
					var b2 := Rect2i(t + cut, back.position.y, w - cut, back.size.y) if along_x else Rect2i(back.position.x, t + cut, back.size.x, w - cut)
					rooms.append([b1, "room"]); _link_back(fp, rooms, front_idx, rooms.size() - 1, along_x)
					rooms.append([b2, "room"]); _link_back(fp, rooms, front_idx, rooms.size() - 1, along_x)
				else:
					rooms.append([back, "room"]); _link_back(fp, rooms, front_idx, rooms.size() - 1, along_x)
			t += w
	# materialise rooms
	for i in rooms.size():
		var r := FloorPlan.Room.new()
		r.index = i
		r.rect = rooms[i][0]
		r.kind = rooms[i][1]
		fp.rooms.append(r)
		for y in range(r.rect.position.y, r.rect.end.y):
			for x in range(r.rect.position.x, r.rect.end.x):
				fp.cell_room[y * fp.cells.x + x] = i
	var stair := FloorPlan.Room.new()
	stair.index = fp.rooms.size()
	stair.rect = stair_rect
	stair.kind = "stair"
	stair.is_stair = true
	fp.rooms.append(stair)
	for y in range(stair_rect.position.y, stair_rect.end.y):
		for x in range(stair_rect.position.x, stair_rect.end.x):
			fp.cell_room[y * fp.cells.x + x] = stair.index
	fp.stair_room = stair.index
	var side_v := Vector2i(-along.y, along.x)
	fp.stair_layout = { "kind": Stairwell.Kind.CORE, "rect": stair_rect, "along": along, "side": side_v }
	fp.stair_cell = Stairwell.entry_cell(fp.stair_layout)
	# doors: every flat's front room onto the corridor, back rooms into the front room
	# (queued by _link_back), the stairwell off the corridor's end
	for ud in unit_doors:
		var fi: int = ud[0]
		var dir: Vector2i = ud[1]
		var fr: Rect2i = fp.rooms[fi].rect
		# the door goes where the corridor is across the wall; a flat sitting over the
		# stairwell opens onto its landing (entry cell) instead
		var onto_corr: Array = []
		var onto_stair: Array = []
		for y in range(fr.position.y, fr.end.y):
			for x in range(fr.position.x, fr.end.x):
				var c := Vector2i(x, y)
				var across := fp.room_at_cell(c + dir)
				if across == 0:
					onto_corr.append(c)
				elif across == stair.index and c + dir == fp.stair_cell:
					onto_stair.append(c)
		if not onto_corr.is_empty():
			_add_door(fp, onto_corr[rng.randi_range(0, onto_corr.size() - 1)], dir, fi, 0)
		elif not onto_stair.is_empty():
			_add_door(fp, onto_stair[0], dir, fi, stair.index)
	for link in _pending_links:
		_add_door(fp, link[0], link[1], link[2], link[3])
	_pending_links.clear()
	var entry := fp.stair_cell
	_add_door(fp, entry, -along, stair.index, 0)
	return true


static var _pending_links: Array = []


## Queue a door from a back room into its front room (they share the row edge).
static func _link_back(fp: FloorPlan, rooms: Array, front_idx: int, back_idx: int, along_x: bool) -> void:
	var fr: Rect2i = rooms[front_idx][0]
	var br: Rect2i = rooms[back_idx][0]
	# the back room touches the front room along the axis; pick the middle shared cell
	var cell: Vector2i
	var dir: Vector2i
	if along_x:
		var x := br.position.x + br.size.x / 2
		if br.position.y < fr.position.y:
			cell = Vector2i(x, br.end.y - 1); dir = Vector2i(0, 1)
		else:
			cell = Vector2i(x, br.position.y); dir = Vector2i(0, -1)
	else:
		var y := br.position.y + br.size.y / 2
		if br.position.x < fr.position.x:
			cell = Vector2i(br.end.x - 1, y); dir = Vector2i(1, 0)
		else:
			cell = Vector2i(br.position.x, y); dir = Vector2i(-1, 0)
	_pending_links.append([cell, dir, back_idx, front_idx])


## The footprint cell the street door opens into.
static func _entrance_cell(b: BuildingData, fp: FloorPlan, fpr: Rect2) -> Vector2i:
	var d := b.road_tile - b.door_tile
	var T := World.TILE_M
	var dc := Vector2((b.door_tile.x + 0.5) * T, (b.door_tile.y + 0.5) * T)
	if d == Vector2i(0, -1):
		return Vector2i(clampi(int((dc.x - fpr.position.x) / fp.cell_size.x), 0, fp.cells.x - 1), 0)
	elif d == Vector2i(0, 1):
		return Vector2i(clampi(int((dc.x - fpr.position.x) / fp.cell_size.x), 0, fp.cells.x - 1), fp.cells.y - 1)
	elif d == Vector2i(1, 0):
		return Vector2i(fp.cells.x - 1, clampi(int((dc.y - fpr.position.y) / fp.cell_size.y), 0, fp.cells.y - 1))
	return Vector2i(0, clampi(int((dc.y - fpr.position.y) / fp.cell_size.y), 0, fp.cells.y - 1))


## Carve `S` out of the BSP rooms it overlaps and make it a room of its own (returned
## index). Each overlapped room is split into up to four rectangles around S; 1-wide
## leftovers read as halls. Rooms are re-indexed (this runs before doors exist).
static func _carve_rect(fp: FloorPlan, S: Rect2i) -> int:
	var kept: Array[Rect2i] = []
	var kinds: Array[String] = []
	for r in fp.rooms:
		var R: Rect2i = r.rect
		if not R.intersects(S):
			kept.append(R)
			kinds.append(r.kind)
			continue
		var I := R.intersection(S)
		var pieces: Array[Rect2i] = []
		if I.position.x > R.position.x:
			pieces.append(Rect2i(R.position.x, R.position.y, I.position.x - R.position.x, R.size.y))
		if I.end.x < R.end.x:
			pieces.append(Rect2i(I.end.x, R.position.y, R.end.x - I.end.x, R.size.y))
		if I.position.y > R.position.y:
			pieces.append(Rect2i(I.position.x, R.position.y, I.size.x, I.position.y - R.position.y))
		if I.end.y < R.end.y:
			pieces.append(Rect2i(I.position.x, I.end.y, I.size.x, R.end.y - I.end.y))
		for pr in pieces:
			kept.append(pr)
			kinds.append("hall" if (pr.size.x == 1 or pr.size.y == 1) else "room")
	fp.rooms.clear()
	for i in kept.size():
		var r := FloorPlan.Room.new()
		r.index = i
		r.rect = kept[i]
		r.kind = kinds[i]
		fp.rooms.append(r)
	var stair := FloorPlan.Room.new()
	stair.index = fp.rooms.size()
	stair.rect = S
	stair.kind = "stair"
	stair.is_stair = true
	fp.rooms.append(stair)
	fp.cell_room.fill(-1)
	for r in fp.rooms:
		for y in range(r.rect.position.y, r.rect.end.y):
			for x in range(r.rect.position.x, r.rect.end.x):
				fp.cell_room[y * fp.cells.x + x] = r.index
	return stair.index


static func _add_door(fp: FloorPlan, cell: Vector2i, dir: Vector2i, ra: int, rb: int) -> void:
	var door := FloorPlan.Door.new()
	door.index = fp.doors.size()
	door.a = ra
	door.b = rb
	door.cell = cell
	door.dir = dir
	var c := Vector2(cell) + Vector2(0.5, 0.5) + Vector2(dir) * 0.5
	door.pos = fp.cell_to_world(c)
	fp.doors.append(door)
	fp.rooms[ra].doors.append(door.index)
	fp.rooms[rb].doors.append(door.index)


static func _split(rect: Rect2i, rng: RandomNumberGenerator, min_s: int, max_s: int, out: Array[Rect2i]) -> void:
	var can_v := rect.size.x >= 2 * min_s
	var can_h := rect.size.y >= 2 * min_s
	var must := rect.size.x > max_s or rect.size.y > max_s
	if not (can_v or can_h) or (not must and rng.randf() > 0.55):
		out.append(rect)
		return
	var vertical: bool
	if can_v and can_h:
		vertical = rect.size.x > rect.size.y or (rect.size.x == rect.size.y and rng.randf() < 0.5)
		if rect.size.x > max_s and rect.size.y <= max_s: vertical = true
		if rect.size.y > max_s and rect.size.x <= max_s: vertical = false
	else:
		vertical = can_v
	if vertical:
		var cut := rng.randi_range(min_s, rect.size.x - min_s)
		_split(Rect2i(rect.position, Vector2i(cut, rect.size.y)), rng, min_s, max_s, out)
		_split(Rect2i(rect.position + Vector2i(cut, 0), Vector2i(rect.size.x - cut, rect.size.y)), rng, min_s, max_s, out)
	else:
		var cut := rng.randi_range(min_s, rect.size.y - min_s)
		_split(Rect2i(rect.position, Vector2i(rect.size.x, cut)), rng, min_s, max_s, out)
		_split(Rect2i(rect.position + Vector2i(0, cut), Vector2i(rect.size.x, rect.size.y - cut)), rng, min_s, max_s, out)


static func _find(p: PackedInt32Array, i: int) -> int:
	while p[i] != i:
		p[i] = p[p[i]]
		i = p[i]
	return i


static func _union(p: PackedInt32Array, a: int, b: int) -> void:
	p[_find(p, a)] = _find(p, b)


static func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp
