class_name Stairwell
## Stairwells are rooms you only pass through: no door leaves, no zombies, no stopping.
## Two kinds, chosen per building (same footprint on every storey):
##   CORE — a switchback core (skyscraper style) in a 1x2 strip: entry landing, two
##          half-width flights side by side with a half-height landing between them.
##   WALL — a home staircase: a 1x3 strip along an exterior wall, a straight flight on the
##          outer half, a walkway on the inner half; flights stagger along the strip on
##          alternate storeys so they never stack.
## Everything is described in strip coordinates (t along the strip from the entry end,
## s across it, h up) and mapped to the world with `frame()`.

enum Kind { CORE, WALL }

const STEP_H := 0.225        ## rise per step in the core (8 steps per half flight)
const CORE_STEPS := 8
const WALL_STEPS := 12
const COL := Color("#8c8c90")
const PIT := Color("#2d1b4e")
const CAP := Color("#334155")


## Deterministic placement for a building. Returns {} when it has no stairs (1 storey).
## { kind, rect: Rect2i (cells), along: Vector2i (entry -> far end), side: Vector2i
##   (CORE: flight-1 side; WALL: towards the exterior wall) }
static func layout(b: BuildingData, cells: Vector2i, entrance_cell: Vector2i) -> Dictionary:
	if b.floors <= 1:
		return {}
	var h := b.seed_hash
	var homey := b.district == District.Kind.RESIDENTIAL or b.district == District.Kind.SUBURB or b.district == District.Kind.STRIP
	var cands: Array = []
	if homey:
		cands = _wall_candidates(cells, entrance_cell)
	if cands.is_empty():
		cands = _core_candidates(cells, entrance_cell)
	if cands.is_empty():
		cands = _core_candidates(cells, Vector2i(-9, -9))   # tiny plan: allow the entrance cell
	if cands.is_empty():
		return {}
	return cands[(h >> 4) % cands.size()]


static func _wall_candidates(cells: Vector2i, ec: Vector2i) -> Array:
	var out: Array = []
	if cells.x < 3 or cells.y < 2:
		pass
	else:
		for x0 in range(0, cells.x - 2):
			for y in [0, cells.y - 1]:
				var r := Rect2i(x0, y, 3, 1)
				if r.has_point(ec):
					continue
				var side := Vector2i(0, -1) if y == 0 else Vector2i(0, 1)
				out.append({ "kind": Kind.WALL, "rect": r, "along": Vector2i(1, 0), "side": side })
				out.append({ "kind": Kind.WALL, "rect": r, "along": Vector2i(-1, 0), "side": side })
	if cells.y >= 3 and cells.x >= 2:
		for y0 in range(0, cells.y - 2):
			for x in [0, cells.x - 1]:
				var r := Rect2i(x, y0, 1, 3)
				if r.has_point(ec):
					continue
				var side := Vector2i(-1, 0) if x == 0 else Vector2i(1, 0)
				out.append({ "kind": Kind.WALL, "rect": r, "along": Vector2i(0, 1), "side": side })
				out.append({ "kind": Kind.WALL, "rect": r, "along": Vector2i(0, -1), "side": side })
	return out


static func _core_candidates(cells: Vector2i, ec: Vector2i) -> Array:
	var out: Array = []
	for y in cells.y:
		for x in cells.x:
			for along: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var entry := Vector2i(x, y)
				var far := entry + along
				if far.x < 0 or far.y < 0 or far.x >= cells.x or far.y >= cells.y:
					continue
				var r := Rect2i(Vector2i(mini(entry.x, far.x), mini(entry.y, far.y)), Vector2i(1, 1) + Vector2i(absi(along.x), absi(along.y)))
				if r.has_point(ec):
					continue
				# the entry cell needs at least one neighbour room to open into
				var ok := false
				for d: Vector2i in _entry_dirs(along):
					var n: Vector2i = entry + d
					if n.x >= 0 and n.y >= 0 and n.x < cells.x and n.y < cells.y:
						ok = true
				if not ok:
					continue
				var side := Vector2i(-along.y, along.x)
				out.append({ "kind": Kind.CORE, "rect": r, "along": along, "side": side })
	return out


## The three outer directions of the entry cell (everything but towards the far cell).
static func _entry_dirs(along: Vector2i) -> Array:
	return [-along, Vector2i(-along.y, along.x), Vector2i(along.y, -along.x)]


static func entry_cell(lay: Dictionary) -> Vector2i:
	var r: Rect2i = lay["rect"]
	var along: Vector2i = lay["along"]
	return r.position if (along.x > 0 or along.y > 0) else (r.end - Vector2i.ONE)


## Wall edges (cell, outward dir) where an opening into a neighbouring room may go, in
## tiers: [preferred, acceptable].
static func allowed_edges(lay: Dictionary) -> Array:
	var r: Rect2i = lay["rect"]
	var along: Vector2i = lay["along"]
	var side: Vector2i = lay["side"]
	var pref: Array = []
	var ok: Array = []
	if lay["kind"] == Kind.CORE:
		var e := entry_cell(lay)
		for d in _entry_dirs(along):
			pref.append([e, d])
	else:
		# openings on the inner side of every cell; the strip ends are acceptable too
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				pref.append([Vector2i(x, y), -side])
		var e := entry_cell(lay)
		var f := e + along * 2
		ok.append([e, -along])
		ok.append([f, along])
	return [pref, ok]


## Strip frame: origin (world, floor level) at the entry end's centre, unit vectors.
## { o: Vector3, a: Vector3 (along), s: Vector3 (side), L: float, W: float }
static func frame(fp: FloorPlan, lay: Dictionary) -> Dictionary:
	var r: Rect2i = lay["rect"]
	var along: Vector2i = lay["along"]
	var side: Vector2i = lay["side"]
	var cs := fp.cell_size
	var L: float = (r.size.x * cs.x) if along.x != 0 else (r.size.y * cs.y)
	var W: float = cs.y if along.x != 0 else cs.x
	var lo := fp.cell_to_world(Vector2(r.position))
	var hi := fp.cell_to_world(Vector2(r.end))
	var c := (lo + hi) * 0.5
	var a := Vector3(along.x, 0, along.y)
	var s := Vector3(side.x, 0, side.y)
	var o := c - a * (L * 0.5)
	return { "o": o, "a": a, "s": s, "L": L, "W": W }


static func P(f: Dictionary, t: float, s: float, h: float) -> Vector3:
	return f["o"] + f["a"] * t + f["s"] * s + Vector3(0, h, 0)


## Along-strip range [t0, t1] of the flight footprint that pierces the slabs.
static func _core_t0(f: Dictionary) -> float:
	return minf(1.4, f["L"] * 0.28)


static func _wall_range(f: Dictionary, floor: int) -> Vector2:
	var L: float = f["L"]
	var run := minf(3.2, L * 0.44)
	var margin := 0.5
	if floor % 2 == 0:
		return Vector2(margin, margin + run)
	return Vector2(L - margin - run, L - margin)


## World-space XZ rect (as Rect2 x,z) of the opening in a slab: what the flights of `floor`
## rise through (the ceiling of `floor` / the floor of `floor + 1`).
static func shaft_rect(fp: FloorPlan, lay: Dictionary, floor: int) -> Rect2:
	var f := frame(fp, lay)
	var W: float = f["W"]
	var pa: Vector3
	var pb: Vector3
	if lay["kind"] == Kind.CORE:
		pa = P(f, _core_t0(f), -W * 0.5, 0)
		pb = P(f, f["L"], W * 0.5, 0)
	else:
		var tr := _wall_range(f, floor)
		pa = P(f, tr.x - 0.05, 0.0, 0)
		pb = P(f, tr.y + 0.35, W * 0.5, 0)
	var lo := Vector2(minf(pa.x, pb.x), minf(pa.z, pb.z))
	var hi := Vector2(maxf(pa.x, pb.x), maxf(pa.z, pb.z))
	return Rect2(lo, hi - lo)


# ------------------------------------------------------------------ geometry

## The flights of `floor` rising to `floor + 1`, built at height offset `dh` (0 for this
## storey's own flights, -FLOOR_M for the storey below's, seen down the shaft).
static func build_flights(st: SurfaceTool, fp: FloorPlan, lay: Dictionary, floor: int, dh: float) -> void:
	var f := frame(fp, lay)
	var H := World.FLOOR_M
	var W: float = f["W"]
	if lay["kind"] == Kind.CORE:
		var t0 := _core_t0(f)
		var L: float = f["L"]
		var mid := t0
		var run := (L - t0 - mid) / CORE_STEPS
		var rise := H * 0.5 / CORE_STEPS
		var fw := W * 0.44
		# flight 1: entry landing -> mid landing, on the -s half
		_flight(st, P(f, t0, -W * 0.25, dh), f["a"], f["s"], fw, CORE_STEPS, run, rise)
		# mid landing block
		var t1 := t0 + run * CORE_STEPS
		_box(st, f, t1, L, -W * 0.5, W * 0.5, dh, dh + H * 0.5, COL.darkened(0.2), COL.darkened(0.45))
		# flight 2: mid landing -> next storey, on the +s half, climbing back towards the entry
		_flight(st, P(f, t1, W * 0.25, dh + H * 0.5), -f["a"], f["s"], fw, CORE_STEPS, run, rise)
	else:
		var tr := _wall_range(f, floor)
		var run := (tr.y - tr.x) / WALL_STEPS
		var rise := H / WALL_STEPS
		_flight(st, P(f, tr.x, W * 0.25, dh), f["a"], f["s"], W * 0.46, WALL_STEPS, run, rise)


## A dark slab one storey down, closing the shaft when you look down it.
static func build_pit(st: SurfaceTool, fp: FloorPlan, lay: Dictionary, floor: int) -> void:
	var r := shaft_rect(fp, lay, floor - 1)
	var y := fp.origin.y - World.FLOOR_M + 0.03
	SectorMesher._quad(st, Vector3(r.position.x, y, r.position.y), Vector3(r.end.x, y, r.position.y),
		Vector3(r.end.x, y, r.end.y), Vector3(r.position.x, y, r.end.y), Vector3.UP, PIT)


## A dark slab just above the ceiling hole, for when the storey above is not built.
static func build_cap(st: SurfaceTool, fp: FloorPlan, lay: Dictionary, floor: int) -> void:
	var r := shaft_rect(fp, lay, floor).grow(0.3)
	var y := fp.origin.y + World.FLOOR_M + 0.5
	SectorMesher._quad(st, Vector3(r.position.x, y, r.position.y), Vector3(r.end.x, y, r.position.y),
		Vector3(r.end.x, y, r.end.y), Vector3(r.position.x, y, r.end.y), Vector3.DOWN, CAP)


## Solid stepped block: treads, risers, side panels and a back, climbing along `dir`.
static func _flight(st: SurfaceTool, foot: Vector3, dir: Vector3, side: Vector3, w: float, steps: int, run: float, rise: float) -> void:
	var side_col := COL.darkened(0.45)
	var riser_col := COL.darkened(0.3)
	var hw := side * (w * 0.5)
	for i in steps:
		var a := foot + dir * (i * run)                 # bottom-front of this step's riser
		var top_y := (i + 1) * rise
		var b := a + dir * run
		var yb := Vector3(0, top_y, 0)
		# tread
		SectorMesher._quad(st, a + yb - hw, b + yb - hw, b + yb + hw, a + yb + hw, Vector3.UP, COL)
		# riser
		SectorMesher._quad(st, a + Vector3(0, i * rise, 0) - hw, a + Vector3(0, i * rise, 0) + hw, a + yb + hw, a + yb - hw, -dir, riser_col)
		# side panels down to the foot level
		SectorMesher._quad(st, a - hw, b - hw, b + yb - hw, a + yb - hw, -side, side_col)
		SectorMesher._quad(st, a + hw, b + hw, b + yb + hw, a + yb + hw, side, side_col)
	var e := foot + dir * (steps * run)
	var top := Vector3(0, steps * rise, 0)
	SectorMesher._quad(st, e - hw, e + hw, e + top + hw, e + top - hw, dir, side_col)


static func _box(st: SurfaceTool, f: Dictionary, t0: float, t1: float, s0: float, s1: float, h0: float, h1: float, top: Color, sides: Color) -> void:
	var a := P(f, t0, s0, h1)
	var b := P(f, t1, s0, h1)
	var c := P(f, t1, s1, h1)
	var d := P(f, t0, s1, h1)
	SectorMesher._quad(st, a, b, c, d, Vector3.UP, top)
	var dn := Vector3(0, h0 - h1, 0)
	SectorMesher._quad(st, a + dn, d + dn, d, a, -f["a"], sides)     # front (towards the entry)
	SectorMesher._quad(st, a + dn, b + dn, b, a, -f["s"], sides)
	SectorMesher._quad(st, d + dn, c + dn, c, d, f["s"], sides)


# ------------------------------------------------------------------ the rail

## Points of the climb from this storey's entry to the landing one storey up (up=true) or
## down (using the flights of the storey below). Starts/ends inside the stairwell.
static func climb_points(fp: FloorPlan, lay: Dictionary, up: bool) -> PackedVector3Array:
	var f := frame(fp, lay)
	var H := World.FLOOR_M
	var W: float = f["W"]
	var pts := PackedVector3Array()
	if lay["kind"] == Kind.CORE:
		var t0 := _core_t0(f)
		var L: float = f["L"]
		var t1 := L - t0
		var mid := L - t0 * 0.5
		if up:
			pts.append(P(f, t0 * 0.5, 0, 0))
			pts.append(P(f, t0, -W * 0.25, 0))
			pts.append(P(f, t1, -W * 0.25, H * 0.5))
			pts.append(P(f, mid, -W * 0.25, H * 0.5))
			pts.append(P(f, mid, W * 0.25, H * 0.5))
			pts.append(P(f, t1, W * 0.25, H * 0.5))
			pts.append(P(f, t0, W * 0.25, H))
			pts.append(P(f, t0 * 0.5, 0, H))
		else:
			pts.append(P(f, t0 * 0.5, 0, 0))
			pts.append(P(f, t0, W * 0.25, 0))
			pts.append(P(f, t1, W * 0.25, -H * 0.5))
			pts.append(P(f, mid, W * 0.25, -H * 0.5))
			pts.append(P(f, mid, -W * 0.25, -H * 0.5))
			pts.append(P(f, t1, -W * 0.25, -H * 0.5))
			pts.append(P(f, t0, -W * 0.25, -H))
			pts.append(P(f, t0 * 0.5, 0, -H))
	else:
		if up:
			var tr := _wall_range(f, fp.floor)
			pts.append(P(f, tr.x - 0.5, -W * 0.25, 0))
			pts.append(P(f, tr.x - 0.4, W * 0.25, 0))
			pts.append(P(f, tr.x, W * 0.25, 0))
			pts.append(P(f, tr.y, W * 0.25, H))
			pts.append(P(f, tr.y + 0.3, W * 0.25, H))
			pts.append(P(f, tr.y + 0.3, -W * 0.25, H))
		else:
			var tr := _wall_range(f, fp.floor - 1)
			pts.append(P(f, tr.y + 0.3, -W * 0.25, 0))
			pts.append(P(f, tr.y + 0.3, W * 0.25, 0))
			pts.append(P(f, tr.y, W * 0.25, 0))
			pts.append(P(f, tr.x, W * 0.25, -H))
			pts.append(P(f, tr.x - 0.4, W * 0.25, -H))
			pts.append(P(f, tr.x - 0.5, -W * 0.25, -H))
	return pts


## Where a walk from an opening joins the climb: a point just inside the stairwell, on
## the walkway side, at the given height.
static func inside_point(fp: FloorPlan, lay: Dictionary, d: FloorPlan.Door, h: float) -> Vector3:
	var f := frame(fp, lay)
	var into := Vector3(d.dir.x, 0, d.dir.y) if d.b == fp.stair_room else Vector3(-d.dir.x, 0, -d.dir.y)
	var p := d.pos + into * 0.7
	if lay["kind"] == Kind.WALL:
		# keep to the inner (walkway) half
		var rel: Vector3 = p - f["o"]
		var t: float = rel.dot(f["a"])
		p = P(f, clampf(t, 0.4, f["L"] - 0.4), -f["W"] * 0.25, 0)
	return Vector3(p.x, fp.origin.y + h, p.z)
