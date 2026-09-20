class_name CityGen
## Deterministic per-sector city generation. A sector is framed by arterial roads on
## its top row and left column (the lattice), so its interior can be generated with
## no knowledge of neighbours: infinite, cacheable, regenerable from (seed, sx, sy).
##
## Pipeline per sector:
##   density field -> district -> frame arterials (some hash-demoted to local streets)
##   -> district-local grid -> prune segments (connectivity-checked) -> cul-de-sacs
##   -> blocks (flood fill) -> lots (must front a road) -> buildings.

const S := SectorData.SIZE

static var _noise: FastNoiseLite
static var _vnoise: FastNoiseLite
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
	# ease the start sector towards mid density (residential edge), never a park
	d = lerp(d, 0.48, 0.7 * exp(-(sx * sx + sy * sy) / 2.0))
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


## Lattice line classes. Vertical line on col 0 of sector (sx, sy); horizontal on row 0.
## ~30% of segments are demoted to local streets so the lattice reads irregular.
static func arterial_v(seed: int, sx: int, sy: int) -> int:
	return 1 if Det.unit(seed, sx, sy, 7) < 0.30 else 2


static func arterial_h(seed: int, sx: int, sy: int) -> int:
	return 1 if Det.unit(seed, sx, sy, 8) < 0.30 else 2


# ---------------------------------------------------------------- sector

static func generate(seed: int, sx: int, sy: int) -> SectorData:
	var sd := SectorData.new()
	sd.coord = Vector2i(sx, sy)
	sd.density = density_at(seed, sx, sy)
	sd.district = district_at(seed, sx, sy)
	var p := District.params(sd.district)
	var rng := Det.rng_for(seed, sx, sy, 100)

	# 1. frame arterials
	var cv := arterial_v(seed, sx, sy)
	var ch := arterial_h(seed, sx, sy)
	for i in S:
		sd.road[SectorData.idx(0, i)] = cv
		sd.road[SectorData.idx(i, 0)] = ch
	sd.road[0] = maxi(cv, ch)

	# 2. district-local grid (lines never hug the frame: keeps 2-tile lots off arterials)
	var sp: int = p["spacing"]
	if sp > 0:
		var ox := rng.randi_range(0, sp - 1)
		var oy := rng.randi_range(0, sp - 1)
		for y in range(1, S):
			for x in range(1, S):
				var on_col := posmod(x - ox, sp) == 0 and x >= 3 and x <= S - 3
				var on_row := posmod(y - oy, sp) == 0 and y >= 3 and y <= S - 3
				if on_col or on_row:
					sd.road[SectorData.idx(x, y)] = 1
		# 3. prune segments -> bigger, irregular blocks (kept only if network stays connected)
		_prune_segments(sd, rng, p["drop"])
		# 4. dead ends: remove, or keep as cul-de-sacs
		_trim_dead_ends(sd, rng, p["culdesac"])

	# 5. blocks
	_flood_blocks(sd)

	# 6. lots + buildings
	if not (p["lots"] as Array).is_empty():
		_place_lots(sd, rng, p, seed)
	return sd


# ---------------------------------------------------------------- helpers

static func _is_road(sd: SectorData, x: int, y: int) -> bool:
	# Tiles at x == S or y == S are the next sector's framing arterial: always road.
	if x == S or y == S:
		return true
	if x < 0 or y < 0:
		return false
	return sd.road[SectorData.idx(x, y)] != 0


static func _degree(sd: SectorData, x: int, y: int) -> int:
	var d := 0
	if _is_road(sd, x + 1, y): d += 1
	if _is_road(sd, x - 1, y): d += 1
	if _is_road(sd, x, y + 1): d += 1
	if _is_road(sd, x, y - 1): d += 1
	return d


static func _is_node(sd: SectorData, x: int, y: int) -> bool:
	return _is_road(sd, x, y) and _degree(sd, x, y) != 2


const DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]


## Local-road segments (runs of degree-2 tiles between two nodes), interior only.
static func _segments(sd: SectorData) -> Array:
	var segs := []
	var seen := {}
	for y in range(1, S):
		for x in range(1, S):
			if not _is_node(sd, x, y):
				continue
			for d in DIRS:
				var cx: int = x + d.x
				var cy: int = y + d.y
				var px := x
				var py := y
				var path: Array[Vector2i] = []
				while cx >= 1 and cy >= 1 and cx < S and cy < S and _is_road(sd, cx, cy) and not _is_node(sd, cx, cy):
					path.append(Vector2i(cx, cy))
					var nxt := Vector2i(-1, -1)
					for d2 in DIRS:
						var ax: int = cx + d2.x
						var ay: int = cy + d2.y
						if Vector2i(ax, ay) == Vector2i(px, py):
							continue
						if _is_road(sd, ax, ay):
							nxt = Vector2i(ax, ay)
							break
					if nxt.x < 0:
						break
					px = cx
					py = cy
					cx = nxt.x
					cy = nxt.y
				if path.is_empty():
					continue
				var k := path[0] if path[0] < path[-1] else path[-1]
				var k2 := path[-1] if path[0] < path[-1] else path[0]
				var key := "%d,%d-%d,%d" % [k.x, k.y, k2.x, k2.y]
				if seen.has(key):
					continue
				seen[key] = true
				segs.append(path)
	return segs


## Every road tile must reach the arterial frame (own frame, or the neighbours' via x/y == S).
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


static func _prune_segments(sd: SectorData, rng: RandomNumberGenerator, drop: float) -> void:
	for path in _segments(sd):
		var all_local := true
		for t in path:
			if sd.road[SectorData.idx(t.x, t.y)] != 1:
				all_local = false
				break
		if not all_local or rng.randf() >= drop:
			continue
		for t in path:
			sd.road[SectorData.idx(t.x, t.y)] = 0
		if not _connected(sd):
			for t in path:
				sd.road[SectorData.idx(t.x, t.y)] = 1


static func _trim_dead_ends(sd: SectorData, rng: RandomNumberGenerator, keep_p: float) -> void:
	var keep := {}
	var changed := true
	while changed:
		changed = false
		for y in range(1, S):
			for x in range(1, S):
				var i := SectorData.idx(x, y)
				if sd.road[i] != 1 or keep.has(i) or _degree(sd, x, y) > 1:
					continue
				if keep_p > 0.0 and rng.randf() < keep_p:
					keep[i] = true
					continue
				sd.road[i] = 0
				changed = true


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
				var blk := sd.block[i0]
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
								var cls := 2 if (nx == S or ny == S) else sd.road[SectorData.idx(nx, ny)]
								if cls > best_class:
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
					# some residential / downtown lots are apartment blocks (3-5 storeys of flats
					# off a corridor); decided from the hash so the rng stream stays put
					if (sd.district == District.Kind.RESIDENTIAL or sd.district == District.Kind.DOWNTOWN) and w * h >= 6 and (b.seed_hash >> 12) % 100 < 35:
						b.kind = "apartments"
						b.floors = 3 + (b.seed_hash >> 20) % 3
					b.door_tile = origin + best_door
					b.road_tile = origin + best_road
					sd.buildings.append(b)
					for yy in range(y, y + h):
						for xx in range(x, x + w):
							sd.lot[SectorData.idx(xx, yy)] = b.index + 1
				break
