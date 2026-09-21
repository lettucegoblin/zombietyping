class_name InteriorGen
## Deterministic floor plans: BSP rooms on a ~2.0 m cell grid over the building footprint,
## doors as a spanning tree plus a few loops, a stairwell anchored per building so up/down
## line up across storeys, and the street entrance on floor 0 exactly where the facade's
## door quad is. Every door gets a typeable word, unique per floor and prefix-free.

const CELL_M := 2.0
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

	var apartment_plan := b.kind == "apartments" and _plan_apartments(fp, b, fpr, rng)
	if not apartment_plan:
		_plan_bsp(fp, b, fpr, rng, floor)
		_assign_bsp_uses(fp, b, fpr, rng)

	# --- street entrance on the ground floor, at the facade door position
	if floor == 0:
		_add_entrance(fp, b, fpr)

	# Furniture is regenerated from a separate stream so adding a chair never changes
	# doors or room topology for an existing seed.
	_furnish(fp, b, Det.rng_for(seed, b.seed_hash, floor, 900 + b.index))

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
	fp.entrance_door = door.index


## Apartment block: a shared corridor leads from the street to a switchback core. Each
## side is split into complete, seed-driven units whose cells have real uses rather than
## anonymous "flat" rectangles. Returns false for footprints too small to hold a useful
## apartment program, so the caller can fall back to BSP.
static func _plan_apartments(fp: FloorPlan, b: BuildingData, _fpr: Rect2, rng: RandomNumberGenerator) -> bool:
	var outside := b.road_tile - b.door_tile
	var along_x := outside.x != 0
	var L := fp.cells.x if along_x else fp.cells.y
	var Wc := fp.cells.y if along_x else fp.cells.x
	if L < 6 or Wc < 5 or b.floors < 2:
		return false
	var mid := Wc / 2
	var stair_end := outside.x < 0 if along_x else outside.y < 0
	var s0 := L - 2 if stair_end else 0
	var stair_rect := Rect2i(s0, mid, 2, 1) if along_x else Rect2i(mid, s0, 1, 2)
	var along := Vector2i(1, 0) if along_x else Vector2i(0, 1)
	if not stair_end:
		along = -along
	var corr_rect := Rect2i(0 if stair_end else 2, mid, L - 2, 1) if along_x else Rect2i(mid, 0 if stair_end else 2, 1, L - 2)
	var defs: Array = [{ "rect": corr_rect, "kind": "hall", "unit": -1 }]
	var links: Array = []          # room-definition index pairs that receive a door
	var living_rooms: Array[int] = []
	var unit_id := 0
	var sides := [[0, mid], [mid + 1, Wc]]
	for side in sides:
		var r0: int = side[0]
		var r1: int = side[1]
		var depth := r1 - r0
		if depth <= 0:
			continue
		var front_cross := mid - 1 if r0 < mid else mid + 1
		var away := -1 if r0 < mid else 1
		var widths := _unit_widths(L, rng)
		var t := 0
		for width in widths:
			var living_rect := _oriented_rect(along_x, t, front_cross, width, 1)
			var living_idx := defs.size()
			defs.append({ "rect": living_rect, "kind": "living", "unit": unit_id })
			living_rooms.append(living_idx)
			var back_depth := depth - 1
			if back_depth <= 0:
				defs[living_idx]["kind"] = "studio"
			elif back_depth == 1:
				# A compact unit still has all three private/service rooms along its back wall.
				var cuts := [1, 1, width - 2]
				var names := ["bathroom", "kitchen", "bedroom"]
				var off := 0
				for j in 3:
					if cuts[j] <= 0:
						continue
					var rr := _oriented_rect(along_x, t + off, front_cross + away, cuts[j], 1)
					var idx := defs.size()
					defs.append({ "rect": rr, "kind": names[j], "unit": unit_id })
					links.append([living_idx, idx])
					off += cuts[j]
			else:
				# Service band behind the living room; bedrooms occupy the quiet exterior band.
				var bath_rect := _oriented_rect(along_x, t, front_cross + away, 1, 1)
				var kitchen_rect := _oriented_rect(along_x, t + 1, front_cross + away, width - 1, 1)
				var bath_idx := defs.size()
				defs.append({ "rect": bath_rect, "kind": "bathroom", "unit": unit_id })
				var kitchen_idx := defs.size()
				defs.append({ "rect": kitchen_rect, "kind": "kitchen", "unit": unit_id })
				links.append([living_idx, bath_idx])
				links.append([living_idx, kitchen_idx])
				var bedroom_cross := front_cross + 2 if away > 0 else front_cross - back_depth
				var bedroom_rect := _oriented_rect(along_x, t, bedroom_cross, width, back_depth - 1)
				var bedroom_idx := defs.size()
				defs.append({ "rect": bedroom_rect, "kind": "bedroom", "unit": unit_id })
				links.append([kitchen_idx, bedroom_idx])
			t += width
			unit_id += 1

	# Materialise the semantic room program before choosing door positions.
	for i in defs.size():
		var r := FloorPlan.Room.new()
		r.index = i
		r.rect = defs[i]["rect"]
		r.kind = defs[i]["kind"]
		r.unit = defs[i]["unit"]
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
	fp.stair_layout = { "kind": Stairwell.Kind.CORE, "rect": stair_rect, "along": along, "side": Vector2i(-along.y, along.x) }
	fp.stair_cell = Stairwell.entry_cell(fp.stair_layout)

	# Each unit enters through its living room. Units overlapping the core may use its
	# landing, but never create disconnected slivers.
	for living_idx in living_rooms:
		if not _door_between(fp, living_idx, 0, rng):
			_door_between(fp, living_idx, stair.index, rng)
	for link in links:
		_door_between(fp, link[0], link[1], rng)
	_door_between(fp, stair.index, 0, rng)
	return true


static func _unit_widths(length: int, rng: RandomNumberGenerator) -> Array[int]:
	var out: Array[int] = []
	var left := length
	while left > 0:
		if left <= 5:
			out.append(left)
			break
		var width := rng.randi_range(3, 4)
		if left - width < 3:
			width = left - 3
		out.append(width)
		left -= width
	return out


static func _oriented_rect(along_x: bool, along0: int, cross0: int, along_size: int, cross_size: int) -> Rect2i:
	return Rect2i(along0, cross0, along_size, cross_size) if along_x else Rect2i(cross0, along0, cross_size, along_size)


static func _door_between(fp: FloorPlan, ra: int, rb: int, rng: RandomNumberGenerator) -> bool:
	var options: Array = []
	var r := fp.rooms[ra]
	for y in range(r.rect.position.y, r.rect.end.y):
		for x in range(r.rect.position.x, r.rect.end.x):
			var cell := Vector2i(x, y)
			for dir: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				if fp.room_at_cell(cell + dir) == rb:
					options.append([cell, dir])
	if options.is_empty():
		return false
	var pick: Array = options[rng.randi_range(0, options.size() - 1)]
	_add_door(fp, pick[0], pick[1], ra, rb)
	return true


## Give non-apartment BSP rooms a plausible program based on the generated building use.
## This is semantic generation, not decoration: the labels drive each room's furniture set.
static func _assign_bsp_uses(fp: FloorPlan, b: BuildingData, fpr: Rect2, rng: RandomNumberGenerator) -> void:
	var usable: Array[int] = []
	for r in fp.rooms:
		if not r.is_stair:
			usable.append(r.index)
	if usable.is_empty():
		return
	usable.sort_custom(func(a: int, c: int):
		var ar: Rect2i = fp.rooms[a].rect
		var cr: Rect2i = fp.rooms[c].rect
		return ar.size.x * ar.size.y > cr.size.x * cr.size.y)
	var entry := fp.room_at_cell(_entrance_cell(b, fp, fpr))
	if entry < 0 or fp.rooms[entry].is_stair:
		entry = usable[0]
	var use := b.kind
	if use == "plain":
		if b.district in [District.Kind.RESIDENTIAL, District.Kind.SUBURB]:
			use = "house"
		elif b.district == District.Kind.STRIP:
			use = "shop"
		elif b.district == District.Kind.INDUSTRIAL:
			use = "warehouse"
		else:
			use = "office"
	match use:
		"house":
			for ri in usable: fp.rooms[ri].kind = "bedroom"
			fp.rooms[entry].kind = "living"
			var rest := usable.duplicate()
			rest.erase(entry)
			if not rest.is_empty(): fp.rooms[rest[0]].kind = "kitchen"
			if rest.size() > 1: fp.rooms[rest[-1]].kind = "bathroom"
		"shop":
			for ri in usable: fp.rooms[ri].kind = "storage"
			fp.rooms[entry].kind = "sales"
			if usable.size() > 1: fp.rooms[usable[-1]].kind = "bathroom"
			if usable.size() > 2: fp.rooms[usable[1]].kind = "office"
		"warehouse":
			for ri in usable: fp.rooms[ri].kind = "storage"
			fp.rooms[entry].kind = "workshop"
			if usable.size() > 1: fp.rooms[usable[-1]].kind = "bathroom"
			if usable.size() > 2: fp.rooms[usable[1]].kind = "office"
		_:
			for ri in usable: fp.rooms[ri].kind = "office"
			fp.rooms[entry].kind = "lobby"
			if usable.size() > 2: fp.rooms[usable[-1]].kind = "bathroom"
			if usable.size() > 3 and rng.randf() < 0.7: fp.rooms[usable[1]].kind = "conference"


static func _furnish(fp: FloorPlan, _b: BuildingData, rng: RandomNumberGenerator) -> void:
	for room in fp.rooms:
		if room.is_stair:
			continue
		match room.kind:
			"bedroom":
				_add_prop(fp, room.index, "bed", 0.27, 0.34, 1.35, 1.95, 0.52, Color("#c39bd3"))
				_add_prop(fp, room.index, "nightstand", 0.72, 0.22, 0.48, 0.48, 0.58, Color("#5a3d28"))
				_add_prop(fp, room.index, "dresser", 0.78, 0.78, 1.05, 0.42, 0.95, Color("#fdba74"))
				_add_prop(fp, room.index, "rug", 0.48, 0.58, 1.45, 1.05, 0.03, Color("#b9a4e0"))
				if rng.randf() < 0.72:
					_add_prop(fp, room.index, "painting", 0.20, 0.82, 0.85, 0.08, 0.72, Color("#fdba74"))
			"bathroom":
				_add_prop(fp, room.index, "toilet", 0.26, 0.30, 0.56, 0.72, 0.72, Color("#fdf6e3"))
				_add_prop(fp, room.index, "sink", 0.72, 0.25, 0.66, 0.48, 0.86, Color("#99f6e4"))
				if room.rect.size.x * room.rect.size.y > 1:
					_add_prop(fp, room.index, "tub", 0.70, 0.73, 0.76, 1.45, 0.55, Color("#b9a4e0"))
			"kitchen":
				_add_prop(fp, room.index, "counter", 0.50, 0.18, 1.75, 0.58, 0.92, Color("#fdba74"))
				_add_prop(fp, room.index, "stove", 0.22, 0.22, 0.62, 0.62, 0.92, Color("#6c6c72"))
				_add_prop(fp, room.index, "fridge", 0.82, 0.22, 0.72, 0.68, 1.75, Color("#99f6e4"))
				if room.rect.size.x * room.rect.size.y >= 3:
					_add_prop(fp, room.index, "table", 0.54, 0.66, 1.15, 0.78, 0.74, Color("#5a3d28"))
			"living":
				_add_prop(fp, room.index, "sofa", 0.50, 0.22, 1.75, 0.72, 0.82, Color("#ea580c"))
				_add_prop(fp, room.index, "coffee_table", 0.50, 0.56, 1.05, 0.62, 0.42, Color("#5a3d28"))
				_add_prop(fp, room.index, "shelf", 0.82, 0.78, 0.92, 0.34, 1.45, Color("#b9a4e0"))
				_add_prop(fp, room.index, "rug", 0.50, 0.50, 1.85, 1.30, 0.03, Color("#c39bd3"))
				if rng.randf() < 0.78:
					_add_prop(fp, room.index, "tv", 0.20 if rng.randf() < 0.5 else 0.80, 0.78, 0.92, 0.46, 1.05, Color("#272338"))
				if rng.randf() < 0.60:
					_add_prop(fp, room.index, "painting", 0.18, 0.72, 0.92, 0.08, 0.76, Color("#fdba74"))
			"studio":
				_add_prop(fp, room.index, "bed", 0.25, 0.32, 1.20, 1.80, 0.50, Color("#c39bd3"))
				_add_prop(fp, room.index, "counter", 0.72, 0.20, 1.25, 0.52, 0.90, Color("#fdba74"))
				_add_prop(fp, room.index, "table", 0.66, 0.70, 0.78, 0.78, 0.72, Color("#5a3d28"))
			"office", "conference", "lobby":
				_add_prop(fp, room.index, "desk", 0.48, 0.34, 1.35, 0.68, 0.76, Color("#5a3d28"))
				_add_prop(fp, room.index, "chair", 0.50, 0.62, 0.52, 0.52, 0.92, Color("#6c6c72"))
				_add_prop(fp, room.index, "cabinet", 0.82, 0.78, 0.82, 0.42, 1.35, Color("#b9a4e0"))
				if rng.randf() < 0.55:
					_add_prop(fp, room.index, "painting", 0.18, 0.80, 0.90, 0.08, 0.74, Color("#99f6e4"))
			"sales":
				_add_prop(fp, room.index, "counter", 0.52, 0.28, 1.85, 0.62, 0.92, Color("#fdba74"))
				_add_prop(fp, room.index, "shelf", 0.18, 0.72, 0.75, 1.45, 1.55, Color("#c39bd3"))
				_add_prop(fp, room.index, "shelf", 0.82, 0.72, 0.75, 1.45, 1.55, Color("#99f6e4"))
			"storage", "workshop":
				_add_prop(fp, room.index, "crate", 0.25, 0.25, 0.82, 0.82, 0.82, Color("#5a3d28"))
				_add_prop(fp, room.index, "crate", 0.72, 0.72, 0.68, 0.68, 0.62, Color("#fdba74"))
				_add_prop(fp, room.index, "shelf", 0.80, 0.24, 0.62, 1.42, 1.65, Color("#6c6c72"))
			"hall":
				if rng.randf() < 0.55:
					_add_prop(fp, room.index, "bench", 0.50, 0.18, 1.25, 0.42, 0.48, Color("#5a3d28"))


static func _add_prop(fp: FloorPlan, ri: int, kind: String, u: float, v: float,
		sx: float, sz: float, height: float, color: Color, yaw: float = 0.0) -> void:
	var room := fp.rooms[ri]
	var p0 := fp.cell_to_world(Vector2(room.rect.position))
	var p1 := fp.cell_to_world(Vector2(room.rect.end))
	var prop := FloorPlan.Prop.new()
	prop.id = "%d:%d:%s" % [fp.floor, ri, kind + ":" + str(fp.props.size())]
	prop.kind = kind
	prop.room = ri
	prop.size = Vector3(minf(sx, maxf(0.35, (p1.x - p0.x) * 0.42)), height,
		minf(sz, maxf(0.35, (p1.z - p0.z) * 0.42)))
	var mx := prop.size.x * 0.5 + 0.06
	var mz := prop.size.z * 0.5 + 0.06
	prop.pos = Vector3(clampf(lerpf(p0.x, p1.x, u), p0.x + mx, p1.x - mx), fp.origin.y + 0.04,
		clampf(lerpf(p0.z, p1.z, v), p0.z + mz, p1.z - mz))
	prop.yaw = yaw
	prop.color = color
	match kind:
		"dresser", "nightstand", "cabinet", "shelf", "fridge", "crate":
			prop.loot_table = "household"
			prop.utility = "storage"
		"bed", "sofa", "chair", "rug", "painting":
			prop.utility = "comfort"
		"sink", "toilet", "tub":
			prop.utility = "water"
		"tv", "stove":
			prop.loot_table = "electronics" if kind == "tv" else "kitchen"
			prop.utility = "power"
	fp.props.append(prop)


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
