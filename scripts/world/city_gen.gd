class_name CityGen
## Deterministic per-sector city generation from a continuous GLOBAL street-coordinate
## field. Curved avenues, collectors and short local segments are classified in world-tile
## space, so sector edges are merely streaming boundaries rather than city-design rules.
##
## Pipeline per sector:
##   density field -> district -> warped street coordinates -> hierarchical road graph
##   -> blocks (flood fill) -> lots (must front a road) -> buildings.
## Tensor-field approach adapted to a discrete tile graph from the Purdue SIGGRAPH 2011
## urban-modelling course notes: https://www.cs.purdue.edu/cgvlab/urban/sg_2011_course/umc_SG11_02_urban_layouts.pdf

const S := SectorData.SIZE

static var _noise: FastNoiseLite
static var _vnoise: FastNoiseLite
static var _tnoise: FastNoiseLite
static var _warp_x: FastNoiseLite
static var _warp_y: FastNoiseLite
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
		_warp_x = FastNoiseLite.new()
		_warp_x.seed = seed ^ 0x6c8e9cf5
		_warp_x.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_warp_x.fractal_type = FastNoiseLite.FRACTAL_FBM
		_warp_x.fractal_octaves = 2
		_warp_x.frequency = 0.018
		_warp_y = FastNoiseLite.new()
		_warp_y.seed = seed ^ 0x51ed270b
		_warp_y.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_warp_y.fractal_type = FastNoiseLite.FRACTAL_FBM
		_warp_y.fractal_octaves = 2
		_warp_y.frequency = 0.018
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


## A smooth, invertible-enough pair of coordinates over the city. Periodic contours in
## this space become long, gently turning roads in world space. The tensor supplies the
## regional orientation; low-frequency domain warp keeps parallel streets from looking
## drafted with a ruler.
static func street_coordinates(seed: int, tile: Vector2) -> Vector2:
	_noise_for(seed)
	# A coherent regional bearing keeps the rasterized network four-connected. Curvature
	# comes from domain warp; rotating every sample independently can tear contour lines.
	# Sample the seed's blended tensor near the opening region for the city-wide bearing.
	# Raster streets become fragile near 45 degrees, so fold to the nearest orthogonal
	# family and cap the obliqueness; the continuous warp provides the visible curvature.
	var field := tensor_direction_at(seed, Vector2(2.5 * S, 1.5 * S))
	var folded := wrapf(field.angle() + PI * 0.25, 0.0, PI * 0.5) - PI * 0.25
	var a := clampf(folded, -0.17, 0.17)
	var ca := cos(a)
	var sa := sin(a)
	var u := tile.x * ca + tile.y * sa
	var v := -tile.x * sa + tile.y * ca
	u += _warp_x.get_noise_2d(tile.x, tile.y) * 5.5
	v += _warp_y.get_noise_2d(tile.x, tile.y) * 5.5
	return Vector2(u, v)


static func _line_distance(value: float, spacing: float, phase: float) -> float:
	return absf(posmod(value - phase + spacing * 0.5, spacing) - spacing * 0.5)


static func _street_phase(seed: int) -> Vector2:
	# Put the fixed survivor spawn on a seed-specific avenue without fixing the avenue's
	# shape. The perpendicular phase is derived entirely from the world seed.
	var spawn_uv := street_coordinates(seed, Vector2(16.5, 0.5))
	return Vector2(spawn_uv.x, (Det.unit(seed, 0, 0, 301) - 0.5) * 48.0)


## Base road class at a global tile: 2 avenue/collector, 1 local, 0 buildable land.
## Two collector-bounded local segments per superblock are independently retained. That
## creates loops, T-junctions and cul-de-sacs while every retained segment still terminates
## on a higher-order road.
static func road_class_at(seed: int, tile: Vector2i) -> int:
	var p := Vector2(tile) + Vector2(0.5, 0.5)
	var uv := street_coordinates(seed, p)
	var phase := _street_phase(seed)
	const AVENUE := 48.0
	const COLLECTOR := 24.0
	var du_a := _line_distance(uv.x, AVENUE, phase.x)
	var dv_a := _line_distance(uv.y, AVENUE, phase.y)
	if minf(du_a, dv_a) <= 1.45:
		return 2
	var du_c := _line_distance(uv.x, COLLECTOR, phase.x)
	var dv_c := _line_distance(uv.y, COLLECTOR, phase.y)
	if minf(du_c, dv_c) <= 1.15:
		return 2
	var rel := uv - phase
	var cell := Vector2i(floori(rel.x / COLLECTOR), floori(rel.y / COLLECTOR))
	var lu := posmod(rel.x, COLLECTOR)
	var lv := posmod(rel.y, COLLECTOR)
	var density := density_at(seed, floori(float(tile.x) / S), floori(float(tile.y) / S))
	var keep := lerpf(0.42, 0.88, density)
	for lane in 2:
		var off := 8.0 + lane * 8.0
		if absf(lu - off) <= 1.45 and Det.unit(seed, cell.x, cell.y, 320 + lane) < keep:
			return 1
		if absf(lv - off) <= 1.45 and Det.unit(seed, cell.x, cell.y, 330 + lane) < keep:
			return 1
	return 0


## Tangent used for lane paint. It follows the nearest contour family rather than merely
## choosing a world axis, so markings turn with the generated street.
static func road_direction_at(seed: int, tile: Vector2) -> Vector2:
	var phase := _street_phase(seed)
	var uv := street_coordinates(seed, tile)
	var du := _line_distance(uv.x, 8.0, phase.x)
	var dv := _line_distance(uv.y, 8.0, phase.y)
	var ex := street_coordinates(seed, tile + Vector2(0.25, 0.0)) - street_coordinates(seed, tile - Vector2(0.25, 0.0))
	var ey := street_coordinates(seed, tile + Vector2(0.0, 0.25)) - street_coordinates(seed, tile - Vector2(0.0, 0.25))
	var grad := Vector2(ex.x, ey.x) if du <= dv else Vector2(ex.y, ey.y)
	var tangent := Vector2(-grad.y, grad.x)
	return tangent.normalized() if tangent.length_squared() > 0.0001 else Vector2.RIGHT


# ---------------------------------------------------------------- sector

static func generate(seed: int, sx: int, sy: int) -> SectorData:
	var sd := SectorData.new()
	sd.coord = Vector2i(sx, sy)
	sd.density = density_at(seed, sx, sy)
	sd.district = district_at(seed, sx, sy)
	var p := District.params(sd.district)
	var rng := Det.rng_for(seed, sx, sy, 100)
	var org := sd.origin_tile()
	# 1. Classify the global hierarchy. Nothing here depends on the sector boundary.
	for y in S:
		for x in S:
			sd.road[SectorData.idx(x, y)] = road_class_at(seed, org + Vector2i(x, y))

	# 2. blocks
	_flood_blocks(sd)

	# 3. lots + buildings
	if not (p["lots"] as Array).is_empty():
		_place_lots(sd, rng, p, seed)
	return sd

# ---------------------------------------------------------------- helpers

static func _is_road(sd: SectorData, x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= S or y >= S:
		return false
	return sd.road[SectorData.idx(x, y)] != 0


const DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]


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
