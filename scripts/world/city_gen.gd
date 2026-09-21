class_name CityGen
## Deterministic per-sector city generation. Neighbouring sectors agree on sparse edge
## ports, then connect those ports through a continuous global tensor field. This keeps
## the world infinite/cacheable while avoiding the old square road around every sector.
##
## Pipeline per sector:
##   density field -> district -> shared boundary ports -> tensor-guided street traces
##   -> local branches and cul-de-sacs
##   -> blocks (flood fill) -> lots (must front a road) -> buildings.
## Tensor-field approach adapted to a discrete tile graph from the Purdue SIGGRAPH 2011
## urban-modelling course notes: https://www.cs.purdue.edu/cgvlab/urban/sg_2011_course/umc_SG11_02_urban_layouts.pdf

const S := SectorData.SIZE

static var _noise: FastNoiseLite
static var _vnoise: FastNoiseLite
static var _tnoise: FastNoiseLite
static var _noise_seed := -0x7FFFFFFF


# ---------------------------------------------------------------- macro layer

static func _noise_for(seed: int) -> FastNoiseLite:
	if _noise == null or _noise_seed != seed:
		_noise = FastNoiseLite.new()
		_noise.seed = seed
		_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
		_noise.fractal_octaves = 3
		_noise.frequency = 0.11
		_vnoise = FastNoiseLite.new()
		_vnoise.seed = seed ^ 0x5bd1e995
		_vnoise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_vnoise.fractal_type = FastNoiseLite.FRACTAL_FBM
		_vnoise.fractal_octaves = 2
		_vnoise.frequency = 0.16
		_tnoise = FastNoiseLite.new()
		_tnoise.seed = seed ^ 0x27d4eb2d
		_tnoise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_tnoise.fractal_type = FastNoiseLite.FRACTAL_FBM
		_tnoise.fractal_octaves = 3
		_tnoise.frequency = 0.006
		_noise_seed = seed
	return _noise


## Slow-varying "flavour" field in [0,1]: decides residential vs suburb, industrial vs park,
## so those kinds form coherent zones instead of per-sector confetti.
static func variation_at(seed: int, sx: int, sy: int) -> float:
	_noise_for(seed)
	return clampf(0.5 + 0.5 * _vnoise.get_noise_2d(float(sx), float(sy)) * 1.6, 0.0, 1.0)


## Urban density in [0,1] at sector coords. Cores (downtown) are density peaks.
static func density_at(seed: int, sx: int, sy: int) -> float:
	var n := _noise_for(seed).get_noise_2d(float(sx), float(sy))   # fbm: mostly within [-0.7, 0.7]
	var d := clampf(0.5 + 0.5 * n * 1.7, 0.0, 1.0)                  # stretch so cores exist naturally
	# guarantee a downtown core a few sectors from the start so the opening has a skyline
	var core := Vector2(4.0, 1.0)
	var dist2 := Vector2(sx, sy).distance_squared_to(core)
	d = d * 0.85 + 0.40 * exp(-dist2 / 5.0)
	# Ease the opening neighbourhood (including the sectors across its borders) toward a
	# residential edge, so the first visible destinations demonstrate homes/apartments.
	d = lerp(d, 0.52, 0.9 * exp(-(sx * sx + sy * sy) / 6.0))
	# Every coarse region contributes a different soft urban centre. The maximum of the
	# nearby centres produces polycentric growth instead of one infinite downtown blob.
	var region_size := 12
	var rx := floori(float(sx) / region_size)
	var ry := floori(float(sy) / region_size)
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			var crx := rx + ox
			var cry := ry + oy
			var cx := crx * region_size + 2.0 + Det.unit(seed, crx, cry, 41) * (region_size - 4.0)
			var cy := cry * region_size + 2.0 + Det.unit(seed, crx, cry, 42) * (region_size - 4.0)
			var strength := 0.18 + Det.unit(seed, crx, cry, 43) * 0.28
			var r2 := Vector2(sx - cx, sy - cy).length_squared()
			d = maxf(d, 0.18 + strength * exp(-r2 / 18.0))
	return clampf(d, 0.0, 1.0)


static func district_at(seed: int, sx: int, sy: int) -> int:
	var d := density_at(seed, sx, sy)
	var u := variation_at(seed, sx, sy)
	if d > 0.80:
		return District.Kind.DOWNTOWN
	if d > 0.64:
		return District.Kind.STRIP if u < 0.40 else District.Kind.RESIDENTIAL
	if d > 0.42:
		return District.Kind.RESIDENTIAL if u < 0.55 else District.Kind.SUBURB
	if d > 0.26:
		if u < 0.45: return District.Kind.SUBURB
		return District.Kind.INDUSTRIAL if u < 0.78 else District.Kind.PARK
	return District.Kind.PARK if u < 0.55 else District.Kind.INDUSTRIAL


## Major eigenvector of a continuous, directionless tensor field at a GLOBAL tile point.
## Double-angle vectors let straight and radial/tangential basis fields blend without the
## 180-degree sign ambiguity of ordinary direction vectors.
static func tensor_direction_at(seed: int, tile: Vector2) -> Vector2:
	_noise_for(seed)
	var base_angle := (_tnoise.get_noise_2d(tile.x, tile.y) * 0.5 + 0.5) * PI
	var tx := cos(2.0 * base_angle)
	var ty := sin(2.0 * base_angle)
	var core := Vector2(4.5 * S, 1.5 * S)
	var delta := tile - core
	var influence := exp(-delta.length_squared() / pow(7.0 * S, 2.0)) * 2.6
	if delta.length_squared() > 0.01:
		var tangent := delta.angle() + PI * 0.5
		tx += cos(2.0 * tangent) * influence
		ty += sin(2.0 * tangent) * influence
	# A nearby regional centre adds local curvature and makes distant districts distinct.
	var span := 10 * S
	var rx := floori(tile.x / span)
	var ry := floori(tile.y / span)
	var rc := Vector2((rx + 0.18 + Det.unit(seed, rx, ry, 61) * 0.64) * span,
		(ry + 0.18 + Det.unit(seed, rx, ry, 62) * 0.64) * span)
	var rd := tile - rc
	var rw := exp(-rd.length_squared() / pow(3.5 * S, 2.0)) * 1.7
	if rd.length_squared() > 0.01:
		var radial := rd.angle()
		tx += cos(2.0 * radial) * rw
		ty += sin(2.0 * radial) * rw
	var angle := 0.5 * atan2(ty, tx)
	return Vector2(cos(angle), sin(angle)).normalized()


# ---------------------------------------------------------------- sector

static func generate(seed: int, sx: int, sy: int) -> SectorData:
	var sd := SectorData.new()
	sd.coord = Vector2i(sx, sy)
	sd.density = density_at(seed, sx, sy)
	sd.district = district_at(seed, sx, sy)
	var p := District.params(sd.district)
	var rng := Det.rng_for(seed, sx, sy, 100)

	# 1. Four sparse, shared edge ports. Each boundary's offset/class depends only on that
	# boundary, so the independently generated neighbour creates the matching road tile.
	var ports := [
		[Vector2i(0, _vertical_port(seed, sx, sy)), _edge_class(seed, sx, sy, 0)],
		[Vector2i(S - 1, _vertical_port(seed, sx + 1, sy)), _edge_class(seed, sx + 1, sy, 0)],
		[Vector2i(_horizontal_port(seed, sx, sy), 0), _edge_class(seed, sx, sy, 1)],
		[Vector2i(_horizontal_port(seed, sx, sy + 1), S - 1), _edge_class(seed, sx, sy + 1, 1)],
	]
	var hub := Vector2i(rng.randi_range(S / 2 - 4, S / 2 + 4), rng.randi_range(S / 2 - 4, S / 2 + 4))
	for entry in ports:
		var port: Vector2i = entry[0]
		var cls: int = entry[1]
		_trace_road(sd, seed, port, hub, cls)

	# 2. Secondary tensor streamlines branch from the connected spine. District density
	# controls their count/length; unlike the old grid, they bend with the global field.
	var sp: int = p["spacing"]
	if sp > 0:
		var branch_count := clampi(roundi(float(S) / sp * 1.6), 2, 8)
		for branch in branch_count:
			_grow_branch(sd, seed, rng, 5 + rng.randi_range(0, maxi(3, 15 - sp)), branch % 2)

	# 3. blocks
	_flood_blocks(sd)

	# 4. lots + buildings
	if not (p["lots"] as Array).is_empty():
		_place_lots(sd, rng, p, seed)
	return sd


static func _vertical_port(seed: int, boundary_x: int, sy: int) -> int:
	return 4 + floori(Det.unit(seed, boundary_x, sy, 71) * float(S - 8))


static func _horizontal_port(seed: int, sx: int, boundary_y: int) -> int:
	# The player starts on this shared boundary; keep the opening deterministic and on-road.
	if sx == 0 and boundary_y == 0:
		return S / 2
	return 4 + floori(Det.unit(seed, sx, boundary_y, 72) * float(S - 8))


static func _edge_class(seed: int, a: int, b: int, axis: int) -> int:
	return 2 if Det.unit(seed, a, b, 73 + axis) < 0.58 else 1


## Monotone Manhattan trace between two points. Both candidate steps get closer, while
## the tensor alignment and a turn penalty decide which one wins. This is the discrete
## hyperstreamline equivalent appropriate for the game's tile navigation graph.
static func _trace_road(sd: SectorData, seed: int, start: Vector2i, target: Vector2i, cls: int) -> void:
	var cur := start
	var last := Vector2i.ZERO
	var org := sd.origin_tile()
	var family := 0
	var first_delta := target - start
	var at_start := tensor_direction_at(seed, Vector2(org + start))
	if absf(at_start.dot(Vector2(first_delta).normalized())) < absf(Vector2(-at_start.y, at_start.x).dot(Vector2(first_delta).normalized())):
		family = 1
	while cur != target:
		sd.road[SectorData.idx(cur.x, cur.y)] = maxi(sd.road[SectorData.idx(cur.x, cur.y)], cls)
		# Leave a shared edge immediately. Otherwise a trace may run along the seam and
		# create tiles its independently generated neighbour cannot mirror.
		if cur == start and (cur.x == 0 or cur.x == S - 1 or cur.y == 0 or cur.y == S - 1):
			var inward := Vector2i(signi(target.x - cur.x), 0) if cur.x in [0, S - 1] else Vector2i(0, signi(target.y - cur.y))
			cur += inward
			last = inward
			continue
		var options: Array[Vector2i] = []
		if cur.x != target.x:
			options.append(Vector2i(signi(target.x - cur.x), 0))
		if cur.y != target.y:
			options.append(Vector2i(0, signi(target.y - cur.y)))
		var field := tensor_direction_at(seed, Vector2(org + cur))
		if family == 1:
			field = Vector2(-field.y, field.x)
		var best := options[0]
		var best_score := -INF
		for dir in options:
			var align := absf(field.dot(Vector2(dir)))
			var keep := 0.22 if dir == last else 0.0
			var jitter := Det.unit(seed, org.x + cur.x, org.y + cur.y, 80 + dir.x * 3 + dir.y) * 0.08
			var score := align + keep + jitter
			if score > best_score:
				best_score = score
				best = dir
		cur += best
		last = best
	sd.road[SectorData.idx(target.x, target.y)] = maxi(sd.road[SectorData.idx(target.x, target.y)], cls)


static func _road_tiles(sd: SectorData) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in range(1, S - 1):
		for x in range(1, S - 1):
			if sd.road[SectorData.idx(x, y)] != 0:
				out.append(Vector2i(x, y))
	return out


static func _grow_branch(sd: SectorData, seed: int, rng: RandomNumberGenerator, length: int, family: int) -> void:
	var roads := _road_tiles(sd)
	if roads.is_empty():
		return
	var cur: Vector2i = roads[rng.randi_range(0, roads.size() - 1)]
	var org := sd.origin_tile()
	var heading := tensor_direction_at(seed, Vector2(org + cur))
	if family == 1:
		heading = Vector2(-heading.y, heading.x)
	if rng.randf() < 0.5:
		heading = -heading
	for step in length:
		var field := tensor_direction_at(seed, Vector2(org + cur))
		if family == 1:
			field = Vector2(-field.y, field.x)
		if heading.dot(field) < 0.0:
			field = -field
		heading = heading.lerp(field, 0.35).normalized()
		var primary := Vector2i(signi(roundi(heading.x)), 0) if absf(heading.x) >= absf(heading.y) else Vector2i(0, signi(roundi(heading.y)))
		var secondary := Vector2i(0, signi(roundi(heading.y))) if primary.x != 0 else Vector2i(signi(roundi(heading.x)), 0)
		var dir := primary if step % 3 != 2 or secondary == Vector2i.ZERO else secondary
		if dir == Vector2i.ZERO:
			break
		var nxt := cur + dir
		if nxt.x < 2 or nxt.y < 2 or nxt.x >= S - 2 or nxt.y >= S - 2:
			break
		if sd.road[SectorData.idx(nxt.x, nxt.y)] != 0 and step > 2:
			break
		cur = nxt
		sd.road[SectorData.idx(cur.x, cur.y)] = 1


# ---------------------------------------------------------------- helpers

static func _is_road(sd: SectorData, x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= S or y >= S:
		return false
	return sd.road[SectorData.idx(x, y)] != 0


const DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]


## Verify that every generated road tile reaches one of the sector's shared edge ports.
## Kept public-to-the-script so the generator invariant test can exercise it directly.
static func _connected(sd: SectorData) -> bool:
	var seen := PackedByteArray()
	seen.resize(S * S)
	var q: Array[Vector2i] = []
	var total := 0
	for y in S:
		for x in S:
			if sd.road[SectorData.idx(x, y)] == 0:
				continue
			total += 1
			if x == 0 or y == 0 or x == S - 1 or y == S - 1:
				seen[SectorData.idx(x, y)] = 1
				q.append(Vector2i(x, y))
	var reached := q.size()
	while not q.is_empty():
		var c: Vector2i = q.pop_back()
		for d in DIRS:
			var n: Vector2i = c + d
			if n.x < 0 or n.y < 0 or n.x >= S or n.y >= S:
				continue
			var i := SectorData.idx(n.x, n.y)
			if sd.road[i] != 0 and seen[i] == 0:
				seen[i] = 1
				reached += 1
				q.append(n)
	return reached == total


static func _flood_blocks(sd: SectorData) -> void:
	var next_id := 0
	for y in range(1, S):
		for x in range(1, S):
			var i := SectorData.idx(x, y)
			if sd.road[i] != 0 or sd.block[i] >= 0:
				continue
			var q: Array[Vector2i] = [Vector2i(x, y)]
			sd.block[i] = next_id
			while not q.is_empty():
				var c: Vector2i = q.pop_back()
				for d in DIRS:
					var n: Vector2i = c + d
					if n.x < 1 or n.y < 1 or n.x >= S or n.y >= S:
						continue
					var j := SectorData.idx(n.x, n.y)
					if sd.road[j] == 0 and sd.block[j] < 0:
						sd.block[j] = next_id
						q.append(n)
			next_id += 1
	sd.block_count = next_id


static func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	# Array.shuffle() uses the global RNG; we need the sector's stream for determinism.
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


static func _place_lots(sd: SectorData, rng: RandomNumberGenerator, p: Dictionary, seed: int) -> void:
	var taken := PackedByteArray()
	taken.resize(S * S)
	var sizes: Array = (p["lots"] as Array).duplicate()
	var floors_range: Array = p["floors"]
	var vacancy: float = p["vacancy"]
	var origin := sd.origin_tile()
	for y in range(1, S):
		for x in range(1, S):
			var i0 := SectorData.idx(x, y)
			if sd.road[i0] != 0 or taken[i0] != 0:
				continue
			_shuffle(sizes, rng)
			for sz in sizes:
				var w: int = sz.x
				var h: int = sz.y
				if x + w > S or y + h > S:
					continue
				var ok := true
				var fronts := false
				var best_door := Vector2i(-1, -1)
				var best_road := Vector2i(-1, -1)
				var best_class := 0
				var best_score := -INF
				var blk := sd.block[i0]
				var lot_center := Vector2(x + w * 0.5, y + h * 0.5)
				for yy in range(y, y + h):
					for xx in range(x, x + w):
						var i := SectorData.idx(xx, yy)
						if sd.road[i] != 0 or taken[i] != 0 or sd.block[i] != blk:
							ok = false
							break
						for d in DIRS:
							var nx: int = xx + d.x
							var ny: int = yy + d.y
							if _is_road(sd, nx, ny):
								fronts = true
								var cls := sd.road[SectorData.idx(nx, ny)]
								# Prefer arterials, then the middle of a facade. Centred doors make
								# the apartment lobby/corridor relationship legible.
								var score := cls * 20.0 - Vector2(xx + 0.5, yy + 0.5).distance_to(lot_center)
								if score > best_score:
									best_score = score
									best_class = cls
									best_door = Vector2i(xx, yy)
									best_road = Vector2i(nx, ny)
					if not ok:
						break
				if not ok:
					continue
				for yy in range(y, y + h):
					for xx in range(x, x + w):
						taken[SectorData.idx(xx, yy)] = 1
				if fronts and rng.randf() >= vacancy:
					var b := BuildingData.new()
					b.sector = sd.coord
					b.index = sd.buildings.size()
					b.rect = Rect2i(origin + Vector2i(x, y), Vector2i(w, h))
					b.district = sd.district
					b.block = blk
					b.seed_hash = Det.h3(seed, sd.coord.x, sd.coord.y, b.index, 3)
					var fmin: int = floors_range[0]
					var fmax: int = floors_range[1]
					# skew low so towers are the exception, not the rule
					var t := rng.randf()
					b.floors = fmin + int(round((fmax - fmin) * t * t))
					# Building use is procedural data, not inferred later from facade colour.
					var roll := (b.seed_hash >> 12) % 100
					match sd.district:
						District.Kind.DOWNTOWN:
							b.kind = "apartments" if w >= 3 and h >= 3 and roll < 52 else "office"
						District.Kind.RESIDENTIAL:
							b.kind = "apartments" if w >= 3 and h >= 3 and roll < 48 else "house"
						District.Kind.SUBURB:
							b.kind = "house"
						District.Kind.STRIP:
							b.kind = "shop"
						District.Kind.INDUSTRIAL:
							b.kind = "warehouse"
					if b.kind == "apartments":
						b.floors = 3 + (b.seed_hash >> 20) % 4
					b.door_tile = origin + best_door
					b.road_tile = origin + best_road
					sd.buildings.append(b)
					for yy in range(y, y + h):
						for xx in range(x, x + w):
							sd.lot[SectorData.idx(xx, yy)] = b.index + 1
				break
