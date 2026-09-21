extends Node
## Autoload "World": the infinite city. Sectors are generated on demand from the seed
## and cached; everything the player changes lives in `state` (sparse, saveable).

signal sector_generated(sd: SectorData)
signal state_changed(building_id: String)
signal materials_changed
signal settlement_changed

const S := SectorData.SIZE
const TILE_M := 5.0                 ## metres per tile in 3D
const FLOOR_M := 3.6                ## metres per storey

var seed: int = 1337
var _sectors: Dictionary = {}       ## Vector2i -> SectorData
var state: Dictionary = {}          ## building id -> Dictionary (cleared floors, barricades, ...)
var explored: Dictionary = {}       ## Vector2i sector -> PackedByteArray (fog of war, 1 = seen)
var safezone_blocks: Dictionary = {} ## "sx,sy:block" -> true
var materials: Dictionary = {
	"building_materials": 0,
	"wood": 0,
	"metal": 0,
	"electronics": 0,
	"textiles": 0,
	"food": 0,
	"medicine": 0,
	"fuel": 0,
	"vehicle_parts": 0,
	"tools": 0,
}
var supply_links: Array[PackedStringArray] = []
var placements: Array[Dictionary] = []


func _ready() -> void:
	_sectors.clear()


# ------------------------------------------------------------- sectors / tiles

func get_sector(sx: int, sy: int) -> SectorData:
	var k := Vector2i(sx, sy)
	var sd: SectorData = _sectors.get(k)
	if sd == null:
		sd = CityGen.generate(seed, sx, sy)
		_sectors[k] = sd
		sector_generated.emit(sd)
	return sd


func sector_of_tile(t: Vector2i) -> Vector2i:
	return Vector2i(floori(float(t.x) / S), floori(float(t.y) / S))


func local_of_tile(t: Vector2i) -> Vector2i:
	return Vector2i(posmod(t.x, S), posmod(t.y, S))


## 0 none, 1 local road, 2 arterial (global tile coords).
func road_at(t: Vector2i) -> int:
	var sc := sector_of_tile(t)
	var l := local_of_tile(t)
	return get_sector(sc.x, sc.y).road[SectorData.idx(l.x, l.y)]


func building_at(t: Vector2i) -> BuildingData:
	var sc := sector_of_tile(t)
	var l := local_of_tile(t)
	var sd := get_sector(sc.x, sc.y)
	var li := sd.lot[SectorData.idx(l.x, l.y)]
	return null if li == 0 else sd.buildings[li - 1]


func building_by_id(id: String) -> BuildingData:
	var parts := id.split(":")
	if parts.size() != 2:
		return null
	var sc := parts[0].split(",")
	var sd := get_sector(int(sc[0]), int(sc[1]))
	var i := int(parts[1])
	return sd.buildings[i] if i >= 0 and i < sd.buildings.size() else null


func tile_to_world(t: Vector2i, y: float = 0.0) -> Vector3:
	return Vector3((t.x + 0.5) * TILE_M, y, (t.y + 0.5) * TILE_M)


func world_to_tile(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / TILE_M), floori(p.z / TILE_M))


# ------------------------------------------------------------- pathfinding

## A* over road tiles between two road tiles. Uses an AStarGrid2D over the bounding
## box (+margin) so it stays cheap and only touches sectors it needs.
func find_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	# Hierarchical streets can require a collector/avenue detour rather than the old direct
	# sector-grid route. Two sectors is still cheap and leaves room for realistic blocks.
	var margin := S * 2
	var lo := Vector2i(mini(from.x, to.x) - margin, mini(from.y, to.y) - margin)
	var hi := Vector2i(maxi(from.x, to.x) + margin, maxi(from.y, to.y) + margin)
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(lo, hi - lo + Vector2i.ONE)
	grid.cell_size = Vector2.ONE
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	grid.update()
	# fill solids sector by sector (fast path: direct array reads)
	var s0 := sector_of_tile(lo)
	var s1 := sector_of_tile(hi)
	for sy in range(s0.y, s1.y + 1):
		for sx in range(s0.x, s1.x + 1):
			var sd := get_sector(sx, sy)
			var org := sd.origin_tile()
			for ly in S:
				var gy := org.y + ly
				if gy < lo.y or gy > hi.y:
					continue
				for lx in S:
					var gx := org.x + lx
					if gx < lo.x or gx > hi.x:
						continue
					if sd.road[ly * S + lx] == 0:
						grid.set_point_solid(Vector2i(gx, gy), true)
					elif sd.road[ly * S + lx] == 1:
						grid.set_point_weight_scale(Vector2i(gx, gy), 1.15)  # prefer arterials slightly
	if grid.is_point_solid(from) or grid.is_point_solid(to):
		return out
	for p in grid.get_id_path(from, to):
		out.append(p)
	return out


# ------------------------------------------------------------- state

func building_state(id: String) -> Dictionary:
	if not state.has(id):
		state[id] = {}
	return state[id]


func set_building_state(id: String, key: String, value: Variant) -> void:
	building_state(id)[key] = value
	state_changed.emit(id)


# ------------------------------------------------------------- settlement economy

func material_name(key: String) -> String:
	return key.replace("_", " ")


func material_summary() -> String:
	var order := ["building_materials", "wood", "metal", "electronics", "textiles", "food", "medicine", "fuel", "vehicle_parts", "tools"]
	var out: Array[String] = []
	for key in order:
		var n: int = materials.get(key, 0)
		if n > 0 or key in ["building_materials", "wood", "metal"]:
			out.append("%s %d" % [material_name(key), n])
	return "  ·  ".join(out)


func add_materials(bundle: Dictionary) -> void:
	for key in bundle:
		materials[key] = int(materials.get(key, 0)) + int(bundle[key])
	materials_changed.emit()
	settlement_changed.emit()


func can_afford(cost: Dictionary) -> bool:
	for key in cost:
		if int(materials.get(key, 0)) < int(cost[key]):
			return false
	return true


func spend(cost: Dictionary) -> bool:
	if not can_afford(cost):
		return false
	for key in cost:
		materials[key] = int(materials.get(key, 0)) - int(cost[key])
	materials_changed.emit()
	settlement_changed.emit()
	return true


func cost_text(cost: Dictionary) -> String:
	var out: Array[String] = []
	for key in cost:
		out.append("%s %d" % [material_name(key), cost[key]])
	return ", ".join(out)


func fortify_cost(b: BuildingData) -> Dictionary:
	return {
		"building_materials": 8 + ceili(float(b.rect.size.x + b.rect.size.y) * 0.5),
		"wood": 4 + b.floors,
		"metal": 3,
	}


func claim_cost(b: BuildingData) -> Dictionary:
	return { "building_materials": 4 + b.floors, "tools": 1 }


func farm_cost() -> Dictionary:
	return { "building_materials": 5, "wood": 4, "tools": 1 }


func supply_cost() -> Dictionary:
	return { "building_materials": 3, "fuel": 1, "tools": 1 }


func car_exists(b: BuildingData) -> bool:
	return posmod(b.seed_hash, 4) != 0


func salvage_preview(b: BuildingData) -> Dictionary:
	var found := {
		"building_materials": 16 + b.floors * 4,
		"wood": 12 + b.floors * 2,
		"metal": 7,
		"electronics": 0,
		"textiles": 0,
		"food": 0,
		"medicine": 0,
		"tools": 3,
	}
	for floor in b.floors:
		var fp := InteriorGen.generate(seed, b, floor)
		for prop in fp.props:
			match prop.kind:
				"bed", "sofa", "rug": found["textiles"] += 1
				"dresser", "shelf", "desk", "chair", "counter": found["wood"] += 1
				"fridge", "stove", "sink", "tub", "toilet": found["metal"] += 1
				"tv": found["electronics"] += 2; found["metal"] += 1
			if prop.loot_table == "kitchen":
				found["food"] += 1
	# Keep large procedural buildings valuable without turning every chair into a wall.
	for key in found:
		if key != "building_materials":
			found[key] = ceili(float(found[key]) * 0.45)
	return found


func salvage_building(id: String) -> String:
	var b := building_by_id(id)
	if b == null:
		return "building no longer exists"
	var st := building_state(id)
	if not st.get("cleared", false):
		return "clear every room before salvaging"
	if st.get("salvaged", false):
		return "contents already salvaged"
	var salvage_bundle := salvage_preview(b)
	st["salvaged"] = true
	st["salvage_yield"] = salvage_bundle.duplicate()
	add_materials(salvage_bundle)
	state_changed.emit(id)
	return "salvaged contents: " + cost_text(salvage_bundle)


func salvage_car(id: String) -> String:
	var b := building_by_id(id)
	if b == null or not car_exists(b):
		return "no salvageable vehicle at this site"
	var st := building_state(id)
	if not st.get("visited", false):
		return "visit this block before salvaging its vehicle"
	var stage: int = st.get("car_stage", 0)
	if stage >= 4:
		return "vehicle is already a bare frame"
	var yields: Array[Dictionary] = [
		{ "metal": 2, "textiles": 1 },
		{ "metal": 4, "electronics": 2 },
		{ "metal": 5, "vehicle_parts": 4, "fuel": 2 },
		{ "metal": 4, "building_materials": 3, "tools": 1 },
	]
	stage += 1
	st["car_stage"] = stage
	add_materials(yields[stage - 1])
	state_changed.emit(id)
	return "vehicle dismantled to stage %d/4: %s" % [stage, cost_text(yields[stage - 1])]


func fortify_building(id: String) -> String:
	var b := building_by_id(id)
	if b == null:
		return "building no longer exists"
	var st := building_state(id)
	if not st.get("cleared", false):
		return "clearing is tactical only; finish every room first"
	if not st.get("salvaged", false):
		return "salvage the building before construction"
	if st.get("fortified", false):
		return "perimeter is already fortified"
	var cost := fortify_cost(b)
	if not spend(cost):
		return "need " + cost_text(cost)
	st["fortified"] = true
	state_changed.emit(id)
	settlement_changed.emit()
	return "perimeter fortified — this still does not claim the site"


func claimed_ids() -> Array[String]:
	var out: Array[String] = []
	for id in state:
		if (state[id] as Dictionary).get("claimed", false):
			out.append(id)
	return out


func has_supply_link(id: String) -> bool:
	for link in supply_links:
		if id in link:
			return true
	return false


func link_supply(id: String) -> String:
	var b := building_by_id(id)
	if b == null:
		return "building no longer exists"
	var homes := claimed_ids()
	if homes.is_empty():
		return "the first base does not need a supply link"
	if not building_state(id).get("fortified", false):
		return "fortify the destination before linking it"
	if has_supply_link(id):
		return "site is already supplied"
	var source := homes[0]
	var sb := building_by_id(source)
	if sb == null or find_path(sb.road_tile, b.road_tile).is_empty():
		return "no viable road supply route"
	var cost := supply_cost()
	if not spend(cost):
		return "need " + cost_text(cost)
	supply_links.append(PackedStringArray([source, id]))
	building_state(id)["supplied"] = true
	state_changed.emit(id)
	settlement_changed.emit()
	return "supply line established from %s" % source


func claim_building(id: String) -> String:
	var b := building_by_id(id)
	if b == null:
		return "building no longer exists"
	var st := building_state(id)
	if st.get("claimed", false):
		return "building already belongs to the settlement"
	if not st.get("fortified", false):
		return "cleared is not claimable — build the perimeter first"
	if not claimed_ids().is_empty() and not st.get("supplied", false):
		return "connect a supply line before claiming this outpost"
	var cost := claim_cost(b)
	if not spend(cost):
		return "need " + cost_text(cost)
	st["claimed"] = true
	st["safe"] = true
	st["citizens"] = 2
	safezone_blocks["%d,%d:%d" % [b.sector.x, b.sector.y, b.block]] = true
	state_changed.emit(id)
	settlement_changed.emit()
	return "building claimed — survivors can now live and build here"


func build_farm(id: String) -> String:
	var b := building_by_id(id)
	if b == null or not building_state(id).get("claimed", false):
		return "farms can only be built inside a claimed perimeter"
	var cost := farm_cost()
	if not spend(cost):
		return "need " + cost_text(cost)
	var st := building_state(id)
	st["farms"] = int(st.get("farms", 0)) + 1
	state_changed.emit(id)
	settlement_changed.emit()
	return "farm plot established; it will produce food"


func build_cost(kind: String) -> Dictionary:
	match kind:
		"wall": return { "building_materials": 2 }
		"crate": return { "wood": 2 }
		"bed": return { "wood": 2, "textiles": 2 }
		"chair": return { "wood": 1 }
		"farm": return farm_cost()
	return {}


func place_item(id: String, kind: String, pos: Vector3, yaw: float) -> String:
	if not building_state(id).get("claimed", false):
		return "placement is restricted to claimed safe zones"
	var b := building_by_id(id)
	if b == null or not safe_rect_world(b).has_point(Vector2(pos.x, pos.z)):
		return "placement must stay inside the walls"
	var cost := build_cost(kind)
	if not spend(cost):
		return "need " + cost_text(cost)
	placements.append({ "building": id, "kind": kind, "pos": pos, "yaw": yaw })
	if kind == "farm":
		var st := building_state(id)
		st["farms"] = int(st.get("farms", 0)) + 1
	settlement_changed.emit()
	return "%s placed" % kind


func safe_rect_world(b: BuildingData) -> Rect2:
	var grown := b.rect.grow(1)
	return Rect2(Vector2(grown.position) * TILE_M, Vector2(grown.size) * TILE_M)


func settlement_action(action: String, id: String) -> String:
	match action:
		"salvage": return salvage_building(id)
		"car": return salvage_car(id)
		"fortify": return fortify_building(id)
		"supply": return link_supply(id)
		"claim": return claim_building(id)
		"farm": return build_farm(id)
	return "unknown building action"


func mark_explored(t: Vector2i, radius: int) -> void:
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx * dx + dy * dy > radius * radius:
				continue
			var g := t + Vector2i(dx, dy)
			var sc := sector_of_tile(g)
			var l := local_of_tile(g)
			if not explored.has(sc):
				var fresh := PackedByteArray()
				fresh.resize(S * S)
				explored[sc] = fresh
			explored[sc][SectorData.idx(l.x, l.y)] = 1


func is_explored(t: Vector2i) -> bool:
	var sc := sector_of_tile(t)
	if not explored.has(sc):
		return false
	var l := local_of_tile(t)
	return explored[sc][SectorData.idx(l.x, l.y)] == 1
