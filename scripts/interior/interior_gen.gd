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
	## World-space XZ rect of the walls; must match SectorMesher's inset.
	var inset := 0.25 if b.district == District.Kind.DOWNTOWN else (0.7 if b.district == District.Kind.STRIP or b.district == District.Kind.INDUSTRIAL else 1.3)
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

	# --- street entrance on the ground floor, at the facade door position
	if floor == 0:
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
