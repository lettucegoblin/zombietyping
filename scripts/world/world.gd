extends Node
## Autoload "World": the infinite city. Sectors are generated on demand from the seed
## and cached; everything the player changes lives in `state` (sparse, saveable).

signal sector_generated(sd: SectorData)
signal state_changed(building_id: String)
signal materials_changed
signal backpack_changed
signal settlement_changed
signal survivor_rescued(survivor: Dictionary)

const S := SectorData.SIZE
const TILE_M := 5.0                 ## metres per tile in 3D
const FLOOR_M := 3.6                ## metres per storey
const FARM_MIN_AREA_M2 := 30.0      ## one plot plus working room between rows
const WORK_CYCLE_SECONDS := 45.0
const BACKPACK_CAPACITY := 12
const WorkforceRules = preload("res://scripts/settlement/workforce.gd")
const FacilityUpgradeRules = preload("res://scripts/settlement/facility_upgrade.gd")
const PropLootRules = preload("res://scripts/loot/prop_loot.gd")

const PLACEMENT_SIZE := {
	"wall": Vector2(2.4, 0.3),
	"crate": Vector2(0.9, 0.9),
	"bed": Vector2(1.3, 2.1),
	"chair": Vector2(0.8, 0.8),
	"farm": Vector2(3.6, 2.4),
}
const SURVIVOR_NAMES := ["Mara", "Dante", "June", "Inez", "Cal", "Priya", "Owen", "Rafi", "Tess", "Noor", "Bea", "Sol"]
const SURVIVOR_TRAITS := ["medic", "mechanic", "grower", "scout", "builder", "teacher", "cook", "radio operator"]

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
var backpack: Dictionary = {}        ## carried scavenged items, broken down at safe zones
var supply_links: Array[PackedStringArray] = []
var placements: Array[Dictionary] = []
var survivors: Dictionary = {}       ## stable survivor id -> named/traited roster record
var pending_survivors: Array[String] = [] ## rescued before a base exists
var settlement_cycle := 0
var settlement_work_seconds := 0.0
var persistence_enabled := true
var _save_queued := false


func _ready() -> void:
	_sectors.clear()
	persistence_enabled = DisplayServer.get_name() != "headless"
	state_changed.connect(func(_id): _queue_save())
	materials_changed.connect(_queue_save)
	backpack_changed.connect(_queue_save)
	settlement_changed.connect(_queue_save)
	if persistence_enabled:
		load_now()


func _exit_tree() -> void:
	# The work-cycle clock advances without writing every frame. Always flush on a clean
	# shutdown so partial progress toward the next cycle is not discarded.
	if persistence_enabled:
		save_now()


func save_snapshot() -> Dictionary:
	return {
		"seed": seed,
		"state": state.duplicate(true),
		"explored": explored.duplicate(true),
		"safezone_blocks": safezone_blocks.duplicate(true),
		"materials": materials.duplicate(true),
		"backpack": backpack.duplicate(true),
		"supply_links": supply_links.duplicate(true),
		"placements": placements.duplicate(true),
		"survivors": survivors.duplicate(true),
		"pending_survivors": pending_survivors.duplicate(),
		"settlement_cycle": settlement_cycle,
		"settlement_work_seconds": settlement_work_seconds,
	}


func restore_snapshot(snapshot: Dictionary) -> bool:
	if snapshot.is_empty():
		return false
	seed = int(snapshot.get("seed", seed))
	state = (snapshot.get("state", {}) as Dictionary).duplicate(true)
	explored = (snapshot.get("explored", {}) as Dictionary).duplicate(true)
	safezone_blocks = (snapshot.get("safezone_blocks", {}) as Dictionary).duplicate(true)
	var loaded_materials: Dictionary = snapshot.get("materials", {})
	for key in materials:
		materials[key] = int(loaded_materials.get(key, 0))
	backpack = (snapshot.get("backpack", {}) as Dictionary).duplicate(true)
	supply_links.clear()
	for link in snapshot.get("supply_links", []):
		supply_links.append(PackedStringArray(link))
	placements = (snapshot.get("placements", []) as Array).duplicate(true)
	survivors = (snapshot.get("survivors", {}) as Dictionary).duplicate(true)
	pending_survivors.clear()
	for survivor_id in snapshot.get("pending_survivors", []):
		pending_survivors.append(str(survivor_id))
	settlement_cycle = int(snapshot.get("settlement_cycle", 0))
	settlement_work_seconds = clampf(float(snapshot.get("settlement_work_seconds", 0.0)), 0.0, WORK_CYCLE_SECONDS)
	_sectors.clear()
	materials_changed.emit()
	backpack_changed.emit()
	settlement_changed.emit()
	return true


func save_now() -> Error:
	_save_queued = false
	if not persistence_enabled:
		return OK
	return SaveStore.write(save_snapshot())


func load_now() -> bool:
	if not persistence_enabled or not SaveStore.exists():
		return false
	return restore_snapshot(SaveStore.read())


func erase_save() -> Error:
	_save_queued = false
	return SaveStore.erase()


func _queue_save() -> void:
	if not persistence_enabled or _save_queued:
		return
	_save_queued = true
	call_deferred("save_now")


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


func backpack_units() -> int:
	return PropLootRules.bundle_units(backpack)


func backpack_summary() -> String:
	var used := backpack_units()
	return "backpack %d/%d%s" % [used, BACKPACK_CAPACITY,
		"" if backpack.is_empty() else " · " + PropLootRules.item_text(backpack)]


func can_carry(bundle: Dictionary) -> bool:
	return backpack_units() + PropLootRules.bundle_units(bundle) <= BACKPACK_CAPACITY


func add_to_backpack(bundle: Dictionary) -> bool:
	if not can_carry(bundle):
		return false
	for item in bundle:
		backpack[item] = int(backpack.get(item, 0)) + int(bundle[item])
	backpack_changed.emit()
	return true


func break_down_backpack() -> String:
	if backpack.is_empty():
		return "backpack is empty"
	var recovered: Dictionary = PropLootRules.breakdown(backpack)
	backpack.clear()
	backpack_changed.emit()
	add_materials(recovered)
	return "sorted backpack into: " + cost_text(recovered)


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
	# This first pass recovers loose stock, rubble and generic fixtures needed to establish
	# a perimeter. Stable generated furniture remains in the world and is dismantled
	# individually through PropSalvage, so its materials are never counted twice.
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
	# Keep loose yields useful without turning generic site rubble into an entire base.
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


# ------------------------------------------------------------- survivor rescue

func rescue_eligible(b: BuildingData) -> bool:
	# Eligibility is seed-derived rather than rolled on entry, so reloading or approaching
	# the same building from another route never changes who is trapped there.
	return posmod(Det.h3(seed, b.seed_hash, b.floors, b.index, 1201), 3) == 0


func _rescue_target(b: BuildingData) -> Dictionary:
	var semantic: Array[Dictionary] = []
	var fallback: Array[Dictionary] = []
	for floor in b.floors:
		var fp := InteriorGen.generate(seed, b, floor)
		for ri in fp.rooms.size():
			var room: FloorPlan.Room = fp.rooms[ri]
			if room.is_stair or room.is_entrance:
				continue
			var target := { "floor": floor, "room": ri, "room_kind": room.kind }
			fallback.append(target)
			if room.kind in ["bedroom", "bathroom", "kitchen", "living", "office", "storage", "workshop", "conference"]:
				semantic.append(target)
	var choices := semantic if not semantic.is_empty() else fallback
	if choices.is_empty():
		return {}
	var index := posmod(Det.h3(seed, b.seed_hash, b.index, choices.size(), 1202), choices.size())
	return choices[index].duplicate()


## Create (once) the deterministic rescue mission for an uncleared building. Buildings
## cleared by older saves do not retroactively acquire survivors, while a mission created
## on entry remains valid even if its room is the final one cleared.
func ensure_rescue_candidate(id: String) -> Dictionary:
	var b := building_by_id(id)
	if b == null:
		return {}
	var st := building_state(id)
	if st.has("rescue"):
		var existing: Dictionary = st["rescue"]
		return existing.duplicate(true) if existing.get("status", "") == "trapped" else {}
	if st.get("cleared", false) or st.get("claimed", false) or not rescue_eligible(b):
		return {}
	var target := _rescue_target(b)
	if target.is_empty():
		return {}
	var identity_hash := Det.h3(seed, b.seed_hash, target["floor"], target["room"], 1203)
	var record := {
		"id": "survivor:%s:%d" % [id, identity_hash],
		"name": SURVIVOR_NAMES[posmod(identity_hash, SURVIVOR_NAMES.size())],
		"trait": SURVIVOR_TRAITS[posmod(floori(float(identity_hash) / 17.0), SURVIVOR_TRAITS.size())],
		"building": id,
		"floor": int(target["floor"]),
		"room": int(target["room"]),
		"room_kind": str(target["room_kind"]),
		"status": "trapped",
		"word": "help",
	}
	st["rescue"] = record.duplicate(true)
	state_changed.emit(id)
	return record.duplicate(true)


func active_rescue(id: String) -> Dictionary:
	var mission: Dictionary = state.get(id, {}).get("rescue", {})
	return mission.duplicate(true) if mission.get("status", "") == "trapped" else {}


func rescue_at(id: String, floor: int, room: int) -> bool:
	var mission := active_rescue(id)
	return not mission.is_empty() and int(mission["floor"]) == floor and int(mission["room"]) == room


func _nearest_claimed_base(from_building: BuildingData) -> String:
	var best := ""
	var best_dist := 0x7FFFFFFF
	for id in claimed_ids():
		var base := building_by_id(id)
		if base == null:
			continue
		var dist: int = (base.road_tile - from_building.road_tile).length_squared()
		if dist < best_dist or (dist == best_dist and (best == "" or id < best)):
			best_dist = dist
			best = id
	return best


func _assign_survivor_to_base(survivor_id: String, base_id: String) -> void:
	if not survivors.has(survivor_id) or not building_state(base_id).get("claimed", false):
		return
	var survivor: Dictionary = survivors[survivor_id]
	if survivor.get("base_id", "") != "":
		return
	survivor["status"] = "assigned"
	survivor["base_id"] = base_id
	survivors[survivor_id] = survivor
	var base_state := building_state(base_id)
	var residents: Array = base_state.get("resident_ids", [])
	if not residents.has(survivor_id):
		residents.append(survivor_id)
		base_state["resident_ids"] = residents
		base_state["citizens"] = int(base_state.get("citizens", 0)) + 1
	if str(survivor.get("job", "")) == "":
		var base: BuildingData = building_by_id(base_id)
		if base != null:
			var profile: Dictionary = FacilityProfile.derive(seed, base, base_state)
			survivor["job"] = WorkforceRules.suggested_job(str(survivor.get("trait", "")), profile, placement_count(base_id, "farm"))
			survivors[survivor_id] = survivor
	pending_survivors.erase(survivor_id)
	state_changed.emit(base_id)
	settlement_changed.emit()


func _assign_pending_to(base_id: String) -> void:
	for survivor_id in pending_survivors.duplicate():
		_assign_survivor_to_base(survivor_id, base_id)


func complete_rescue(id: String) -> String:
	var mission := active_rescue(id)
	if mission.is_empty():
		return "no survivor is waiting here"
	var survivor_id: String = mission["id"]
	mission["status"] = "rescued"
	building_state(id)["rescue"] = mission.duplicate(true)
	var survivor := mission.duplicate(true)
	survivor["status"] = "pending"
	survivor["base_id"] = ""
	survivors[survivor_id] = survivor
	var source := building_by_id(id)
	var base_id := _nearest_claimed_base(source) if source != null else ""
	if base_id == "":
		if not pending_survivors.has(survivor_id):
			pending_survivors.append(survivor_id)
	else:
		_assign_survivor_to_base(survivor_id, base_id)
	state_changed.emit(id)
	settlement_changed.emit()
	survivor_rescued.emit(survivors[survivor_id].duplicate(true))
	return "%s rescued (%s)%s" % [mission["name"], mission["trait"], " — waiting for a claimed base" if base_id == "" else " — assigned to " + base_id]


func claimed_ids() -> Array[String]:
	var out: Array[String] = []
	for id in state:
		if (state[id] as Dictionary).get("claimed", false):
			out.append(id)
	return out


func resident_records(id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for survivor_id in building_state(id).get("resident_ids", []):
		var person: Dictionary = survivors.get(str(survivor_id), {})
		if not person.is_empty():
			out.append(person.duplicate(true))
	return out


func auto_assign_jobs(id: String) -> String:
	var b := building_by_id(id)
	var st := building_state(id)
	if b == null or not st.get("claimed", false):
		return "crew can only be assigned at a claimed base"
	var residents: Array = st.get("resident_ids", [])
	if residents.is_empty():
		return "no rescued survivors live at this base yet"
	var profile: Dictionary = FacilityProfile.derive(seed, b, st)
	var farms: int = placement_count(id, "farm")
	var assigned: Array[String] = []
	for survivor_id in residents:
		var sid := str(survivor_id)
		var person: Dictionary = survivors.get(sid, {})
		if person.is_empty():
			continue
		var job: String = WorkforceRules.suggested_job(str(person.get("trait", "")), profile, farms)
		person["job"] = job
		survivors[sid] = person
		assigned.append("%s → %s" % [person.get("name", "survivor"), job])
	state_changed.emit(id)
	settlement_changed.emit()
	return "crew assigned: " + ", ".join(assigned)


func assign_next_job(id: String, job: String) -> String:
	job = job.to_lower()
	if not WorkforceRules.JOBS.has(job):
		return "job must be " + "|".join(WorkforceRules.JOBS)
	var st := building_state(id)
	if not st.get("claimed", false):
		return "jobs can only be assigned at a claimed base"
	var residents: Array = st.get("resident_ids", [])
	if residents.is_empty():
		return "no rescued survivors live at this base yet"
	var cursor := posmod(int(st.get("job_cursor", 0)), residents.size())
	var survivor_id := str(residents[cursor])
	var person: Dictionary = survivors.get(survivor_id, {})
	if person.is_empty():
		return "resident roster is unavailable"
	person["job"] = job
	survivors[survivor_id] = person
	st["job_cursor"] = (cursor + 1) % residents.size()
	state_changed.emit(id)
	settlement_changed.emit()
	return "%s assigned %s (%d/%d)" % [person.get("name", "survivor"), job, cursor + 1, residents.size()]


func facility_upgrade_cost(id: String) -> Dictionary:
	var b := building_by_id(id)
	if b == null:
		return {}
	var st := building_state(id)
	var profile: Dictionary = FacilityProfile.derive(seed, b, st)
	var next_level := int(profile.get("upgrade_level", 0)) + 1
	if next_level > FacilityUpgradeRules.MAX_LEVEL:
		return {}
	return FacilityUpgradeRules.cost(str(profile.get("role_id", "")), next_level)


func upgrade_facility(id: String) -> String:
	var b := building_by_id(id)
	var st := building_state(id)
	if b == null or not st.get("claimed", false):
		return "facility upgrades require a claimed base"
	var profile: Dictionary = FacilityProfile.derive(seed, b, st)
	var level := int(profile.get("upgrade_level", 0))
	if level >= FacilityUpgradeRules.MAX_LEVEL:
		return "%s is already level %d" % [profile["role_label"], level]
	if not (profile.get("missing", []) as Array).is_empty():
		return "restore intact utilities before upgrading: " + " · ".join(profile["missing"])
	var next_level := level + 1
	var citizens := int(st.get("citizens", 0))
	if citizens < next_level:
		return "level %d needs %d resident%s" % [next_level, next_level, "" if next_level == 1 else "s"]
	var cost: Dictionary = FacilityUpgradeRules.cost(str(profile["role_id"]), next_level)
	if not spend(cost):
		return "need " + cost_text(cost)
	st["facility_role"] = profile["role_id"]
	st["facility_level"] = next_level
	state_changed.emit(id)
	settlement_changed.emit()
	return "%s upgraded to level %d — %s" % [profile["role_label"], next_level, FacilityUpgradeRules.effect_text(str(profile["role_id"]), next_level)]


func has_supply_link(id: String) -> bool:
	for link in supply_links:
		if id in link:
			return true
	return false


func seconds_until_work_cycle() -> int:
	return maxi(0, ceili(WORK_CYCLE_SECONDS - settlement_work_seconds))


func advance_settlement(dt: float) -> void:
	if dt <= 0.0 or claimed_ids().is_empty():
		return
	settlement_work_seconds += dt
	while settlement_work_seconds >= WORK_CYCLE_SECONDS:
		settlement_work_seconds -= WORK_CYCLE_SECONDS
		run_work_cycle()


## A base is on the shared inventory network only when it connects through the persisted
## road links to the founding base. Disconnected production remains visible in that site's
## local stockpile and is delivered automatically after the route is restored.
func networked_base_ids() -> Dictionary:
	var claims: Array[String] = claimed_ids()
	claims.sort()
	if claims.is_empty():
		return {}
	var roots: Array[String] = []
	for id in claims:
		if int(building_state(id).get("founders", 0)) > 0:
			roots.append(id)
	if roots.is_empty():
		roots.append(claims[0]) # compatibility with saves made before founder state existed
	var connected := {}
	var queue: Array[String] = []
	for root in roots:
		connected[root] = true
		queue.append(root)
	while not queue.is_empty():
		var here: String = queue.pop_front()
		for link in supply_links:
			if link.size() < 2:
				continue
			var other := ""
			if link[0] == here:
				other = link[1]
			elif link[1] == here:
				other = link[0]
			if other != "" and not connected.has(other) and claims.has(other):
				connected[other] = true
				queue.append(other)
	return connected


func _add_bundle(target: Dictionary, bundle: Dictionary) -> void:
	for key in bundle:
		target[key] = int(target.get(key, 0)) + int(bundle[key])


func run_work_cycle() -> Dictionary:
	settlement_cycle += 1
	var connected: Dictionary = networked_base_ids()
	var delivered := {}
	var reports := {}
	var claims: Array[String] = claimed_ids()
	claims.sort()
	for id in claims:
		var b: BuildingData = building_by_id(id)
		if b == null:
			continue
		var st: Dictionary = building_state(id)
		var result: Dictionary = WorkforceRules.produce(seed, b, st, survivors, placement_count(id, "farm"), settlement_cycle)
		var output: Dictionary = result["output"]
		var stockpile: Dictionary = (st.get("local_stockpile", {}) as Dictionary).duplicate()
		_add_bundle(stockpile, output)
		var is_connected := connected.has(id)
		if is_connected:
			_add_bundle(delivered, stockpile)
			stockpile.clear()
		st["local_stockpile"] = stockpile
		st["last_production"] = {
			"cycle": settlement_cycle,
			"output": output.duplicate(),
			"delivered": is_connected,
			"jobs": (result["jobs"] as Dictionary).duplicate(),
			"tended_farms": result["tended_farms"],
			"farm_count": result["farm_count"],
		}
		reports[id] = st["last_production"].duplicate(true)
		state_changed.emit(id)
	if not delivered.is_empty():
		add_materials(delivered)
	else:
		settlement_changed.emit()
	return { "cycle": settlement_cycle, "delivered": delivered, "bases": reports }


func link_supply(id: String) -> String:
	var b := building_by_id(id)
	if b == null:
		return "building no longer exists"
	if building_state(id).get("claimed", false):
		return "claimed buildings cannot be linked to themselves"
	var homes := claimed_ids()
	if homes.is_empty():
		return "the first base does not need a supply link"
	if not building_state(id).get("fortified", false):
		return "fortify the destination before linking it"
	if has_supply_link(id):
		return "site is already supplied"
	var source := ""
	var best_path: Array[Vector2i] = []
	for candidate in homes:
		if candidate == id:
			continue
		var sb := building_by_id(candidate)
		if sb == null:
			continue
		var route := find_path(sb.road_tile, b.road_tile)
		if not route.is_empty() and (best_path.is_empty() or route.size() < best_path.size()):
			source = candidate
			best_path = route
	if source == "":
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
	var first_base := claimed_ids().is_empty()
	st["claimed"] = true
	st["safe"] = true
	# The first shelter has one founding caretaker. Expansion sites start empty; named
	# rescued survivors are the population source rather than two free citizens per claim.
	st["founders"] = 1 if first_base else 0
	st["citizens"] = int(st["founders"])
	st["resident_ids"] = []
	safezone_blocks["%d,%d:%d" % [b.sector.x, b.sector.y, b.block]] = true
	state_changed.emit(id)
	_assign_pending_to(id)
	settlement_changed.emit()
	return "building claimed — survivors can now live and build here"


func build_farm(id: String) -> String:
	var b := building_by_id(id)
	if b == null or not building_state(id).get("claimed", false):
		return "farms can only be built inside a claimed perimeter"
	if placement_count(id, "farm") >= farm_capacity(b):
		return "farm capacity reached (%d plots)" % farm_capacity(b)
	var site := find_farm_site(id)
	if site.is_empty():
		return "no open farm plot remains inside this perimeter"
	var result := place_item(id, "farm", site["pos"], site["yaw"])
	if result == "farm placed":
		return "farm plot established; assign a farmer to produce food"
	return result


func build_cost(kind: String) -> Dictionary:
	match kind:
		"wall": return { "building_materials": 2 }
		"crate": return { "wood": 2 }
		"bed": return { "wood": 2, "textiles": 2 }
		"chair": return { "wood": 1 }
		"farm": return farm_cost()
	return {}


func placement_count(id: String, kind: String = "") -> int:
	var count := 0
	for item in placements:
		if item.get("building", "") == id and (kind == "" or item.get("kind", "") == kind):
			count += 1
	return count


## The cap represents room to tend and walk around plots, not merely their mesh area.
## Spatial validation below can still exhaust a site before this theoretical maximum.
func farm_capacity(b: BuildingData) -> int:
	var safe := safe_rect_world(b)
	var structure := building_rect_world(b)
	var outdoor_area := maxf(0.0, safe.get_area() - structure.get_area())
	return clampi(floori(outdoor_area / FARM_MIN_AREA_M2), 1, 12)


func building_rect_world(b: BuildingData) -> Rect2:
	return Rect2(Vector2(b.rect.position) * TILE_M, Vector2(b.rect.size) * TILE_M)


func _placement_footprint(kind: String, pos: Vector3, yaw: float) -> Dictionary:
	var size: Vector2 = PLACEMENT_SIZE[kind]
	var axis_x := Vector2(cos(yaw), -sin(yaw))
	var axis_z := Vector2(sin(yaw), cos(yaw))
	return {
		"kind": kind,
		"center": Vector2(pos.x, pos.z),
		"axis_x": axis_x,
		"axis_z": axis_z,
		"half": size * 0.5,
	}


func _rect_footprint(r: Rect2, kind: String = "structure") -> Dictionary:
	return {
		"kind": kind,
		"center": r.get_center(),
		"axis_x": Vector2.RIGHT,
		"axis_z": Vector2.DOWN,
		"half": r.size * 0.5,
	}


func _footprint_bounds(fp: Dictionary) -> Rect2:
	var ax: Vector2 = fp["axis_x"]
	var az: Vector2 = fp["axis_z"]
	var half: Vector2 = fp["half"]
	var extent := Vector2(
		absf(ax.x) * half.x + absf(az.x) * half.y,
		absf(ax.y) * half.x + absf(az.y) * half.y
	)
	return Rect2(fp["center"] - extent, extent * 2.0)


func _footprints_overlap(a: Dictionary, b: Dictionary) -> bool:
	var delta: Vector2 = b["center"] - a["center"]
	var axes: Array[Vector2] = [a["axis_x"], a["axis_z"], b["axis_x"], b["axis_z"]]
	for axis in axes:
		var ah: Vector2 = a["half"]
		var bh: Vector2 = b["half"]
		var ar := ah.x * absf(axis.dot(a["axis_x"])) + ah.y * absf(axis.dot(a["axis_z"]))
		var br := bh.x * absf(axis.dot(b["axis_x"])) + bh.y * absf(axis.dot(b["axis_z"]))
		# Touching edges are intentional for wall runs and do not count as overlap.
		if absf(delta.dot(axis)) >= ar + br - 0.01:
			return false
	return true


func _entry_clearance(b: BuildingData) -> Dictionary:
	var door := Vector2((b.door_tile.x + 0.5) * TILE_M, (b.door_tile.y + 0.5) * TILE_M)
	var road := Vector2((b.road_tile.x + 0.5) * TILE_M, (b.road_tile.y + 0.5) * TILE_M)
	var lo := Vector2(minf(door.x, road.x), minf(door.y, road.y)) - Vector2(1.15, 1.15)
	var hi := Vector2(maxf(door.x, road.x), maxf(door.y, road.y)) + Vector2(1.15, 1.15)
	return _rect_footprint(Rect2(lo, hi - lo), "entrance lane")


## Empty means valid; otherwise the text is suitable for immediate HUD feedback.
func placement_error(id: String, kind: String, pos: Vector3, yaw: float) -> String:
	if not PLACEMENT_SIZE.has(kind):
		return "unknown build item: " + kind
	if not building_state(id).get("claimed", false):
		return "placement is restricted to claimed safe zones"
	var b := building_by_id(id)
	if b == null:
		return "building no longer exists"
	if kind == "farm" and placement_count(id, "farm") >= farm_capacity(b):
		return "farm capacity reached (%d plots)" % farm_capacity(b)
	if kind == "farm" and pos.y > 0.5:
		return "farm plots need open ground on the ground floor"
	var fp := _placement_footprint(kind, pos, yaw)
	var bounds := _footprint_bounds(fp)
	var safe := safe_rect_world(b)
	if bounds.position.x < safe.position.x or bounds.position.y < safe.position.y \
			or bounds.end.x > safe.end.x or bounds.end.y > safe.end.y:
		return "%s must fit fully inside the perimeter" % kind
	if kind == "farm" and _footprints_overlap(fp, _rect_footprint(building_rect_world(b))):
		return "farm plots need open ground outside the building"
	if kind in ["farm", "wall"] and _footprints_overlap(fp, _entry_clearance(b)):
		return "%s would block the entrance lane" % kind
	for item in placements:
		if item.get("building", "") != id:
			continue
		var other_pos: Vector3 = item.get("pos", Vector3.ZERO)
		if absf(other_pos.y - pos.y) > 1.0:
			continue # identical XZ is valid on a different storey
		var other_kind: String = item.get("kind", "")
		if not PLACEMENT_SIZE.has(other_kind):
			continue
		var other := _placement_footprint(other_kind, item["pos"], float(item.get("yaw", 0.0)))
		if _footprints_overlap(fp, other):
			return "%s overlaps an existing %s" % [kind, other_kind]
	return ""


## Deterministically finds free outdoor ground for construction from the Tab panel.
func find_farm_site(id: String) -> Dictionary:
	var b := building_by_id(id)
	if b == null or not building_state(id).get("claimed", false):
		return {}
	if placement_count(id, "farm") >= farm_capacity(b):
		return {}
	var safe := safe_rect_world(b)
	for yaw in [0.0, PI * 0.5]:
		var probe := _placement_footprint("farm", Vector3.ZERO, yaw)
		var ext := _footprint_bounds(probe).size * 0.5
		var z := safe.position.y + ext.y + 0.25
		while z <= safe.end.y - ext.y - 0.25:
			var x := safe.position.x + ext.x + 0.25
			while x <= safe.end.x - ext.x - 0.25:
				var pos := Vector3(x, 0.05, z)
				if placement_error(id, "farm", pos, yaw) == "":
					return { "pos": pos, "yaw": yaw }
				x += 0.75
			z += 0.75
	return {}


func place_item(id: String, kind: String, pos: Vector3, yaw: float) -> String:
	var error := placement_error(id, kind, pos, yaw)
	if error != "":
		return error
	var cost := build_cost(kind)
	if not spend(cost):
		return "need " + cost_text(cost)
	placements.append({ "building": id, "kind": kind, "pos": pos, "yaw": yaw })
	settlement_changed.emit()
	return "%s placed" % kind


func last_placement_for(id: String) -> Dictionary:
	for i in range(placements.size() - 1, -1, -1):
		if placements[i].get("building", "") == id:
			return (placements[i] as Dictionary).duplicate(true)
	return {}


func _same_placement(a: Dictionary, b: Dictionary) -> bool:
	return a.get("building", "") == b.get("building", "") \
			and a.get("kind", "") == b.get("kind", "") \
			and a.get("pos", Vector3.INF) == b.get("pos", Vector3.INF) \
			and is_equal_approx(float(a.get("yaw", 0.0)), float(b.get("yaw", 0.0)))


## Removes a specific placed object. A just-built undo uses 1.0; later dismantling uses
## 0.5, rounded up so even a one-unit chair returns something useful.
func remove_placement(target: Dictionary, refund_fraction: float) -> String:
	var index := -1
	for i in range(placements.size() - 1, -1, -1):
		if _same_placement(placements[i], target):
			index = i
			break
	if index < 0:
		return "that construction is no longer available to dismantle"
	var item: Dictionary = placements[index]
	var kind: String = item.get("kind", "")
	placements.remove_at(index)
	var refund: Dictionary = {}
	var original_cost := build_cost(kind)
	for material in original_cost:
		var amount := ceili(float(original_cost[material]) * clampf(refund_fraction, 0.0, 1.0))
		if amount > 0:
			refund[material] = amount
	if not refund.is_empty():
		add_materials(refund)
	else:
		settlement_changed.emit()
	var action := "undid" if refund_fraction >= 0.999 else "dismantled"
	var rule := "full refund" if refund_fraction >= 0.999 else "50% rounded-up materials"
	return "%s %s — %s: %s" % [action, kind, rule, cost_text(refund)]


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
		"crew": return auto_assign_jobs(id)
		"upgrade": return upgrade_facility(id)
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
	_queue_save()


func is_explored(t: Vector2i) -> bool:
	var sc := sector_of_tile(t)
	if not explored.has(sc):
		return false
	var l := local_of_tile(t)
	return explored[sc][SectorData.idx(l.x, l.y)] == 1
