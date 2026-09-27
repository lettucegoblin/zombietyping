extends Node
## Autoload "World": the infinite city. Sectors are generated on demand from the seed
## and cached; everything the player changes lives in `state` (sparse, saveable).

signal sector_generated(sd: SectorData)
signal state_changed(building_id: String)
signal materials_changed
signal backpack_changed
signal field_inventory_changed
signal settlement_changed
signal survivor_rescued(survivor: Dictionary)

const S := SectorData.SIZE
const TILE_M := 5.0                 ## metres per tile in 3D
const FLOOR_M := 3.6                ## metres per storey
const WARD_GRID := 2.5              ## one player-built wall edge / enclosed ward cell
const FARM_MIN_AREA_M2 := 30.0      ## one plot plus working room between rows
const WORK_CYCLE_SECONDS := 45.0
const BACKPACK_CAPACITY := 12
const FOLLOWER_CAPACITY := 4
const CART_CAPACITY := 12
const CART_CREW_MAX := 2
const FIELD_CAPACITY := {
	"bandages": 2,
	"packaged_food": 2,
}
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
const RESCUE_ARCHETYPES := ["grandma", "grandpa", "cat", "dog", "adult", "adult", "adult", "adult", "adult", "adult"]
const ARCHETYPE_NAMES := {
	"grandma": ["Evelyn", "Mabel", "Rosa", "Dot", "Loretta", "Nana Jo"],
	"grandpa": ["Arthur", "Walter", "Hector", "Frank", "Lionel", "Grandpa Sol"],
	"cat": ["Miso", "Pickle", "Marmalade", "Juniper", "Beans", "Orbit", "Mochi", "Waffles"],
	"dog": ["Biscuit", "Maple", "Scout", "Pepper", "Rook", "Sunny", "Noodle", "Bear"],
}
const ARCHETYPE_TRAITS := {
	"grandma": ["medic", "grower", "cook", "teacher"],
	"grandpa": ["mechanic", "builder", "teacher", "radio operator"],
	"cat": ["mouser", "scout", "comfort"],
	"dog": ["tracker", "guard", "comfort", "scout"],
}
const ARCHETYPE_DIALOGUE := {
	"adult": ["We'll make this place feel lived in.", "I marked a quiet route through the block.", "Tell me what needs doing."],
	"grandma": ["Sit down before you fall down. I have tea.", "A garden, strong walls, and good neighbors. That's a life.", "I survived worse kitchens than this."],
	"grandpa": ["The hinge is sound. The world around it needs work.", "Give me a toolbox and somewhere to put the kettle.", "I checked the wall twice. Habit."],
	"cat": ["The food arrangement remains unacceptable.", "I found three quiet routes. You may thank me later.", "Yes, I can talk. Keep up."],
	"dog": ["I checked the fence. Still excellent.", "We're safe. This is a very good place.", "I can carry supplies. Also sticks."],
}

var seed: int = 1337
var _sectors: Dictionary = {}       ## Vector2i -> SectorData
var _sector_tasks: Dictionary = {}  ## Vector2i -> {id, seed}; generation runs off the main thread
var _sector_task_results: Dictionary = {} ## request token -> SectorData, guarded below
var _sector_task_mutex := Mutex.new()
var _sector_task_token := 0
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
	"zombie_matter": 0,
}
var backpack: Dictionary = {}        ## carried scavenged items, broken down at safe zones
var field_inventory: Dictionary = {} ## ready-use consumables; overflow remains in backpack
var supply_links: Array[PackedStringArray] = []
var placements: Array[Dictionary] = []
var survivors: Dictionary = {}       ## stable survivor id -> named/traited roster record
var pending_survivors: Array[String] = [] ## rescued before a base exists
## The base whose assigned cart party is currently travelling with the player. Crew
## selection lives on the base; this runtime leg is saved so a mid-expedition reload keeps
## both the companions and the carrying limit.
var expedition_base_id := ""
var settlement_cycle := 0
var settlement_work_seconds := 0.0
var persistence_enabled := true
var _save_queued := false
var _ward_cache: Dictionary = {}    ## building id -> enclosed Vector2i cells


func _ready() -> void:
	_sectors.clear()
	_sector_tasks.clear()
	_sector_task_mutex.lock()
	_sector_task_results.clear()
	_sector_task_mutex.unlock()
	persistence_enabled = DisplayServer.get_name() != "headless"
	state_changed.connect(func(_id): _queue_save())
	materials_changed.connect(_queue_save)
	backpack_changed.connect(_queue_save)
	field_inventory_changed.connect(_queue_save)
	settlement_changed.connect(_queue_save)
	settlement_changed.connect(func(): _ward_cache.clear())
	if persistence_enabled:
		load_now()


func _exit_tree() -> void:
	# Worker callables capture this autoload. Drain them before the object is released so a
	# late sector result can never write into a freed World during shutdown.
	for request in _sector_tasks.values():
		WorkerThreadPool.wait_for_task_completion(int(request["id"]))
	_sector_tasks.clear()
	_sector_task_mutex.lock()
	_sector_task_results.clear()
	_sector_task_mutex.unlock()
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
		"field_inventory": field_inventory.duplicate(true),
		"supply_links": supply_links.duplicate(true),
		"placements": placements.duplicate(true),
		"survivors": survivors.duplicate(true),
		"pending_survivors": pending_survivors.duplicate(),
		"expedition_base_id": expedition_base_id,
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
	field_inventory = (snapshot.get("field_inventory", {}) as Dictionary).duplicate(true)
	supply_links.clear()
	for link in snapshot.get("supply_links", []):
		supply_links.append(PackedStringArray(link))
	placements = (snapshot.get("placements", []) as Array).duplicate(true)
	survivors = (snapshot.get("survivors", {}) as Dictionary).duplicate(true)
	pending_survivors.clear()
	for survivor_id in snapshot.get("pending_survivors", []):
		pending_survivors.append(str(survivor_id))
	expedition_base_id = str(snapshot.get("expedition_base_id", ""))
	if expedition_base_id != "" and not building_state(expedition_base_id).get("claimed", false):
		expedition_base_id = ""
	settlement_cycle = int(snapshot.get("settlement_cycle", 0))
	settlement_work_seconds = clampf(float(snapshot.get("settlement_work_seconds", 0.0)), 0.0, WORK_CYCLE_SECONDS)
	_sectors.clear()
	_sector_tasks.clear()
	_sector_task_mutex.lock()
	_sector_task_results.clear()
	_sector_task_mutex.unlock()
	materials_changed.emit()
	backpack_changed.emit()
	field_inventory_changed.emit()
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
		if _sector_tasks.has(k):
			sd = _finish_sector_task(k)
		if sd == null:
			sd = CityGen.generate(seed, sx, sy)
			_store_sector(k, sd)
	return sd


## Start deterministic sector data generation without blocking the render thread. Scene
## nodes/resources are still constructed on the main thread by Streamer/SectorMesher.
func request_sector(sx: int, sy: int) -> void:
	var k := Vector2i(sx, sy)
	if _sectors.has(k) or _sector_tasks.has(k):
		return
	var requested_seed := seed
	_sector_task_token += 1
	var token := _sector_task_token
	var task_id := WorkerThreadPool.add_task(
		func():
			var generated := CityGen.generate(requested_seed, sx, sy)
			_sector_task_mutex.lock()
			_sector_task_results[token] = generated
			_sector_task_mutex.unlock(),
		false,
		"generate city sector %d,%d" % [sx, sy]
	)
	_sector_tasks[k] = {"id": task_id, "seed": requested_seed, "token": token}


## Non-blocking counterpart to get_sector(), used by the streamer once a worker finishes.
func take_requested_sector(sx: int, sy: int) -> SectorData:
	var k := Vector2i(sx, sy)
	var cached: SectorData = _sectors.get(k)
	if cached != null:
		return cached
	if not _sector_tasks.has(k):
		request_sector(sx, sy)
		return null
	var request: Dictionary = _sector_tasks[k]
	if not WorkerThreadPool.is_task_completed(int(request["id"])):
		return null
	return _finish_sector_task(k)


func _finish_sector_task(k: Vector2i) -> SectorData:
	var request: Dictionary = _sector_tasks.get(k, {})
	if request.is_empty():
		return null
	WorkerThreadPool.wait_for_task_completion(int(request["id"]))
	_sector_tasks.erase(k)
	_sector_task_mutex.lock()
	var generated = _sector_task_results.get(int(request["token"]))
	_sector_task_results.erase(int(request["token"]))
	_sector_task_mutex.unlock()
	if int(request["seed"]) != seed or not generated is SectorData:
		return null
	var sd := generated as SectorData
	_store_sector(k, sd)
	return sd


func _store_sector(k: Vector2i, sd: SectorData) -> void:
	_sectors[k] = sd
	sector_generated.emit(sd)


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
	var order := ["building_materials", "wood", "metal", "electronics", "textiles", "food", "medicine", "fuel", "vehicle_parts", "tools", "zombie_matter"]
	var out: Array[String] = []
	for key in order:
		var n: int = materials.get(key, 0)
		if n > 0 or key in ["building_materials", "wood", "metal"]:
			out.append("%s %d" % [material_name(key), n])
	return "  ·  ".join(out)


func backpack_units() -> int:
	return PropLootRules.bundle_units(backpack)


func cart_crew(id: String) -> Array[String]:
	var out: Array[String] = []
	if id == "":
		return out
	var st := building_state(id)
	for raw_id in st.get("cart_crew", []):
		var survivor_id := str(raw_id)
		var person: Dictionary = survivors.get(survivor_id, {})
		if not person.is_empty() and person.get("base_id", "") == id \
				and str(person.get("species", "human")) == "human":
			out.append(survivor_id)
	return out


func expedition_survivors() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for survivor_id in cart_crew(expedition_base_id):
		out.append((survivors.get(survivor_id, {}) as Dictionary).duplicate(true))
	return out


func backpack_capacity() -> int:
	var crew_count := cart_crew(expedition_base_id).size()
	return BACKPACK_CAPACITY + crew_count * FOLLOWER_CAPACITY + (CART_CAPACITY if crew_count > 0 else 0)


func backpack_summary() -> String:
	var used := backpack_units()
	var crew_count := cart_crew(expedition_base_id).size()
	var cart_text := " · cart +%d" % (crew_count * FOLLOWER_CAPACITY + CART_CAPACITY) if crew_count > 0 else ""
	return "backpack %d/%d%s%s" % [used, backpack_capacity(), cart_text,
		"" if backpack.is_empty() else " · " + PropLootRules.item_text(backpack)]


func field_count(item: String) -> int:
	return int(field_inventory.get(item, 0))


func field_summary() -> String:
	return "field kit · bandages %d/%d · food %d/%d" % [
		field_count("bandages"), int(FIELD_CAPACITY["bandages"]),
		field_count("packaged_food"), int(FIELD_CAPACITY["packaged_food"]),
	]


func item_summary(bundle: Dictionary) -> String:
	return "nothing" if bundle.is_empty() else PropLootRules.item_text(bundle)


func can_carry(bundle: Dictionary) -> bool:
	return backpack_units() + PropLootRules.bundle_units(bundle) <= backpack_capacity()


func loot_overflow(bundle: Dictionary) -> Dictionary:
	var overflow := {}
	for item in bundle:
		var count := int(bundle[item])
		if FIELD_CAPACITY.has(item):
			count -= mini(count, maxi(0, int(FIELD_CAPACITY[item]) - field_count(item)))
		if count > 0:
			overflow[item] = count
	return overflow


func can_collect_loot(bundle: Dictionary) -> bool:
	return can_carry(loot_overflow(bundle))


## Loot tops up ready-use consumables first. Everything else, including consumable
## overflow, remains in the general backpack for later use or settlement storage.
func collect_loot(bundle: Dictionary) -> bool:
	if not can_collect_loot(bundle):
		return false
	var overflow := {}
	var field_changed := false
	for item in bundle:
		var count := int(bundle[item])
		if FIELD_CAPACITY.has(item):
			var room := maxi(0, int(FIELD_CAPACITY[item]) - field_count(item))
			var field_take := mini(count, room)
			if field_take > 0:
				field_inventory[item] = field_count(item) + field_take
				count -= field_take
				field_changed = true
		if count > 0:
			overflow[item] = count
	if field_changed:
		field_inventory_changed.emit()
	if not overflow.is_empty():
		add_to_backpack(overflow)
	return true


func add_to_backpack(bundle: Dictionary) -> bool:
	if not can_carry(bundle):
		return false
	for item in bundle:
		backpack[item] = int(backpack.get(item, 0)) + int(bundle[item])
	backpack_changed.emit()
	return true


func consume_backpack_item(item: String, count := 1) -> bool:
	if count <= 0 or int(backpack.get(item, 0)) < count:
		return false
	var left := int(backpack[item]) - count
	if left > 0:
		backpack[item] = left
	else:
		backpack.erase(item)
	backpack_changed.emit()
	return true


## Deliberately drain overflow first so the small field reserve survives routine use.
func consume_field_supply(item: String, count := 1) -> bool:
	if count <= 0 or int(backpack.get(item, 0)) + field_count(item) < count:
		return false
	var from_backpack := mini(count, int(backpack.get(item, 0)))
	if from_backpack > 0:
		consume_backpack_item(item, from_backpack)
	var from_field := count - from_backpack
	if from_field > 0:
		var left := field_count(item) - from_field
		if left > 0:
			field_inventory[item] = left
		else:
			field_inventory.erase(item)
		field_inventory_changed.emit()
	return true


## A settlement visit refills empty ready-use slots from that base's stores. It never
## manufactures supplies, and it leaves all unrelated stored items untouched.
func refresh_field_inventory(id: String) -> String:
	var st := building_state(id)
	if not st.get("claimed", false):
		return ""
	var stored: Dictionary = (st.get("stored_items", {}) as Dictionary).duplicate()
	var moved := {}
	for item in FIELD_CAPACITY:
		var need := maxi(0, int(FIELD_CAPACITY[item]) - field_count(item))
		var take := mini(need, int(stored.get(item, 0)))
		if take <= 0:
			continue
		field_inventory[item] = field_count(item) + take
		moved[item] = take
		var left := int(stored[item]) - take
		if left > 0:
			stored[item] = left
		else:
			stored.erase(item)
	if moved.is_empty():
		return ""
	st["stored_items"] = stored
	field_inventory_changed.emit()
	state_changed.emit(id)
	settlement_changed.emit()
	return "field kit restocked: " + PropLootRules.item_text(moved)


func deposit_backpack(id: String) -> String:
	var st := building_state(id)
	if not st.get("claimed", false):
		return "carried supplies can only be stashed at a claimed base"
	if backpack.is_empty():
		return "backpack is empty"
	var deposited := backpack.duplicate()
	var stored: Dictionary = (st.get("stored_items", {}) as Dictionary).duplicate()
	_add_bundle(stored, deposited)
	st["stored_items"] = stored
	backpack.clear()
	backpack_changed.emit()
	state_changed.emit(id)
	settlement_changed.emit()
	var verb := "cart unloaded at this base: " if expedition_base_id != "" else "stashed at this base: "
	return verb + PropLootRules.item_text(deposited)


## Recruit rescued human residents into a small expedition party. The cart requires at
## least one person, so the final press clears the roster rather than leaving an invisible
## capacity upgrade behind. Animals remain residents/companions, not freight labor.
func cycle_cart_crew(id: String) -> String:
	var st := building_state(id)
	if not st.get("claimed", false):
		return "cart crews can only be assigned at a claimed base"
	var candidates: Array[String] = []
	for raw_id in st.get("resident_ids", []):
		var survivor_id := str(raw_id)
		var person: Dictionary = survivors.get(survivor_id, {})
		if str(person.get("species", "human")) == "human":
			candidates.append(survivor_id)
	candidates.sort()
	if candidates.is_empty():
		return "rescue a human survivor before assigning the gate cart"
	var crew := cart_crew(id)
	if crew.size() >= mini(CART_CREW_MAX, candidates.size()):
		crew.clear()
	else:
		for survivor_id in candidates:
			if not crew.has(survivor_id):
				crew.append(survivor_id)
				break
	st["cart_crew"] = crew.duplicate()
	if expedition_base_id == id:
		expedition_base_id = id if not crew.is_empty() else ""
	state_changed.emit(id)
	settlement_changed.emit()
	if crew.is_empty():
		return "gate cart parked — expedition crew cleared"
	var names: Array[String] = []
	for survivor_id in crew:
		names.append(str((survivors.get(survivor_id, {}) as Dictionary).get("name", "survivor")))
	var extra := crew.size() * FOLLOWER_CAPACITY + CART_CAPACITY
	return "cart crew: %s — carrying capacity +%d" % [", ".join(names), extra]


func begin_expedition(id: String) -> String:
	var crew := cart_crew(id)
	expedition_base_id = id if not crew.is_empty() else ""
	settlement_changed.emit()
	if crew.is_empty():
		return ""
	return "cart party following — backpack capacity %d" % backpack_capacity()


func end_expedition() -> void:
	if expedition_base_id == "":
		return
	expedition_base_id = ""
	settlement_changed.emit()


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
		"zombie_matter": 3 + b.floors,
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
	st["warded"] = true
	state_changed.emit(id)
	settlement_changed.emit()
	return "perimeter fortified — this still does not claim the site"


# ------------------------------------------------------------- survivor rescue

func _with_survivor_needs(record: Dictionary) -> Dictionary:
	var person := record.duplicate(true)
	var sid := str(person.get("id", "survivor"))
	if not person.has("archetype"):
		person["archetype"] = "adult"
	if not person.has("species"):
		person["species"] = person["archetype"] if person["archetype"] in ["cat", "dog"] else "human"
	var roll := Det.h3(seed, sid.hash(), str(person.get("trait", "")).hash(), 0, 1401)
	if not person.has("health"):
		person["health"] = 48 + posmod(roll, 43)
	if not person.has("hunger"):
		person["hunger"] = 25 + posmod(floori(float(roll) / 43.0), 36)
	if not person.has("morale"):
		person["morale"] = 52 + posmod(floori(float(roll) / 1548.0), 29)
	if not person.has("wellbeing"):
		person["wellbeing"] = 45 + posmod(floori(float(roll) / 44892.0), 26)
	if not person.has("injured"):
		person["injured"] = int(person["health"]) < 64
	var base_id := str(person.get("base_id", ""))
	if base_id != "":
		if not person.has("home_id"):
			person["home_id"] = base_id
		if not person.has("home_slot"):
			person["home_slot"] = 1 + posmod(roll, 12)
		if not person.has("schedule_offset"):
			person["schedule_offset"] = posmod(floori(float(roll) / 97.0), int(WORK_CYCLE_SECONDS))
	return person


func survivor_condition(person: Dictionary) -> String:
	if person.get("injured", false):
		return "recovering"
	if int(person.get("wellbeing", 50)) >= 80:
		return "thriving"
	if int(person.get("morale", 60)) >= 75:
		return "happy"
	return "steady"


func survivor_schedule(person: Dictionary) -> String:
	var phase := fmod(settlement_work_seconds + float(person.get("schedule_offset", 0)), WORK_CYCLE_SECONDS) / WORK_CYCLE_SECONDS
	if phase < 0.22:
		return "home"
	if phase < 0.58:
		return "work"
	if phase < 0.78:
		return "community"
	return "patrol"


func rescue_archetype(identity_hash: int) -> String:
	return RESCUE_ARCHETYPES[posmod(floori(float(identity_hash) / 31.0), RESCUE_ARCHETYPES.size())]


func survivor_archetype_label(person: Dictionary) -> String:
	match str(person.get("archetype", "adult")):
		"grandma": return "grandma"
		"grandpa": return "grandpa"
		"cat": return "cat"
		"dog": return "dog"
	return "survivor"


func survivor_dialogue(person: Dictionary) -> String:
	var archetype := str(person.get("archetype", "adult"))
	var lines: Array = ARCHETYPE_DIALOGUE.get(archetype, ARCHETYPE_DIALOGUE["adult"])
	var sid := str(person.get("id", person.get("name", "resident")))
	var roll := Det.h3(seed, sid.hash(), settlement_cycle, survivor_schedule(person).hash(), 1441)
	return str(lines[posmod(roll, lines.size())])

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
	var archetype := rescue_archetype(identity_hash)
	var names: Array = ARCHETYPE_NAMES.get(archetype, SURVIVOR_NAMES)
	var traits: Array = ARCHETYPE_TRAITS.get(archetype, SURVIVOR_TRAITS)
	var record := {
		"id": "survivor:%s:%d" % [id, identity_hash],
		"name": names[posmod(identity_hash, names.size())],
		"trait": traits[posmod(floori(float(identity_hash) / 17.0), traits.size())],
		"archetype": archetype,
		"species": archetype if archetype in ["cat", "dog"] else "human",
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
	var survivor: Dictionary = _with_survivor_needs(survivors[survivor_id])
	if survivor.get("base_id", "") != "":
		return
	survivor["status"] = "assigned"
	survivor["base_id"] = base_id
	survivor["home_id"] = base_id
	survivors[survivor_id] = survivor
	var base_state := building_state(base_id)
	var residents: Array = base_state.get("resident_ids", [])
	if not residents.has(survivor_id):
		residents.append(survivor_id)
		base_state["resident_ids"] = residents
		base_state["citizens"] = int(base_state.get("citizens", 0)) + 1
	survivor["home_slot"] = residents.find(survivor_id) + int(base_state.get("founders", 0)) + 1
	if not survivor.has("schedule_offset"):
		var home_roll := Det.h3(seed, survivor_id.hash(), base_id.hash(), int(survivor["home_slot"]), 1402)
		survivor["schedule_offset"] = posmod(home_roll, int(WORK_CYCLE_SECONDS))
	survivors[survivor_id] = survivor
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
	var survivor := _with_survivor_needs(mission)
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
	return "%s the %s rescued — \"%s\"%s" % [mission["name"], survivor_archetype_label(mission), survivor_dialogue(mission), " — waiting for a claimed base" if base_id == "" else " — assigned to " + base_id]


func claimed_ids() -> Array[String]:
	var out: Array[String] = []
	for id in state:
		if (state[id] as Dictionary).get("claimed", false):
			out.append(id)
	return out


## The first claimed shelter remains the player's home spawn. Older saves identify it by
## its founding caretaker; the lexical fallback is deterministic for expansion-only saves.
func primary_base_id() -> String:
	var claims := claimed_ids()
	claims.sort()
	for id in claims:
		if int(building_state(id).get("founders", 0)) > 0:
			return id
	return claims[0] if not claims.is_empty() else ""


func resident_records(id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for survivor_id in building_state(id).get("resident_ids", []):
		var person: Dictionary = survivors.get(str(survivor_id), {})
		if not person.is_empty():
			person = _with_survivor_needs(person)
			survivors[str(survivor_id)] = person
			out.append(person.duplicate(true))
	return out


## Spend one treatment from the selected base. Stored bandages are used first, then the
## connected settlement medicine pool (or the base's isolated local stockpile).
func consume_base_medicine(id: String) -> bool:
	var st := building_state(id)
	if not st.get("claimed", false):
		return false
	var stored: Dictionary = (st.get("stored_items", {}) as Dictionary).duplicate()
	if _take_units(stored, "bandages", 1) > 0:
		st["stored_items"] = stored
		state_changed.emit(id)
		settlement_changed.emit()
		return true
	var connected := networked_base_ids().has(id)
	var pool: Dictionary = materials if connected else (st.get("local_stockpile", {}) as Dictionary).duplicate()
	if _take_units(pool, "medicine", 1) <= 0:
		return false
	if connected:
		materials_changed.emit()
	else:
		st["local_stockpile"] = pool
		state_changed.emit(id)
	settlement_changed.emit()
	return true


func base_medicine_count(id: String) -> int:
	var st := building_state(id)
	if not st.get("claimed", false):
		return 0
	var stored: Dictionary = st.get("stored_items", {})
	var count := int(stored.get("bandages", 0))
	if networked_base_ids().has(id):
		count += int(materials.get("medicine", 0))
	else:
		count += int((st.get("local_stockpile", {}) as Dictionary).get("medicine", 0))
	return count


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


## A base joins shared inventory through a road link or through physically joined warded
## ground. The latter lets a mature settlement retire its temporary caravan connection.
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
		for candidate in claims:
			if not connected.has(candidate) and _wards_touch(here, candidate):
				connected[candidate] = true
				queue.append(candidate)
	return connected


func _wards_touch(a_id: String, b_id: String) -> bool:
	var a := ward_cells(a_id)
	var b := ward_cells(b_id)
	if a.is_empty() or b.is_empty():
		return false
	var small: Dictionary = a if a.size() <= b.size() else b
	var large: Dictionary = b if a.size() <= b.size() else a
	for cell in small:
		for offset in [Vector2i.ZERO, Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]:
			if large.has(cell + offset):
				return true
	return false


func _add_bundle(target: Dictionary, bundle: Dictionary) -> void:
	for key in bundle:
		target[key] = int(target.get(key, 0)) + int(bundle[key])


func _take_units(bundle: Dictionary, key: String, wanted: int) -> int:
	var taken := mini(maxi(wanted, 0), int(bundle.get(key, 0)))
	if taken <= 0:
		return 0
	var left := int(bundle[key]) - taken
	if left > 0:
		bundle[key] = left
	else:
		bundle.erase(key)
	return taken


func _process_base_needs(id: String, st: Dictionary, connected: bool) -> Dictionary:
	var resident_ids: Array = (st.get("resident_ids", []) as Array).duplicate()
	resident_ids.sort()
	var citizens := maxi(int(st.get("citizens", 0)), resident_ids.size() + int(st.get("founders", 0)))
	if citizens <= 0:
		var empty := { "status": "empty", "food_needed": 0, "food_used": 0, "medicine_used": 0,
			"hungry": 0, "starving": 0, "injured": 0, "morale": 0, "wellbeing": 0,
			"productivity_bonus": false, "incidents": [] }
		st["needs"] = empty
		return empty

	var stored: Dictionary = (st.get("stored_items", {}) as Dictionary).duplicate()
	var local: Dictionary = (st.get("local_stockpile", {}) as Dictionary).duplicate()
	var food_needed := ceili(float(citizens) / 2.0)
	var food_used := _take_units(stored, "packaged_food", food_needed)
	var food_remaining := food_needed - food_used
	var material_food := 0
	if connected:
		material_food = _take_units(materials, "food", food_remaining)
	else:
		material_food = _take_units(local, "food", food_remaining)
	food_used += material_food

	var injured_before := 0
	for survivor_id in resident_ids:
		var sid := str(survivor_id)
		var person: Dictionary = _with_survivor_needs(survivors.get(sid, { "id": sid }))
		survivors[sid] = person
		if person.get("injured", false):
			injured_before += 1
	var medicine_used := _take_units(stored, "bandages", injured_before)
	var medicine_remaining := injured_before - medicine_used
	var material_medicine := 0
	if connected:
		material_medicine = _take_units(materials, "medicine", medicine_remaining)
	else:
		material_medicine = _take_units(local, "medicine", medicine_remaining)
	medicine_used += material_medicine
	if (connected and (material_food > 0 or material_medicine > 0)):
		materials_changed.emit()

	var fed_slots := mini(citizens, food_used * 2)
	var treatments_left := medicine_used
	var injured := 0
	var morale_total := 0
	var wellbeing_total := 0
	for i in resident_ids.size():
		var sid := str(resident_ids[i])
		var person: Dictionary = _with_survivor_needs(survivors.get(sid, { "id": sid }))
		var fed := i < fed_slots
		if fed:
			person["hunger"] = maxi(0, int(person.get("hunger", 0)) - 12)
		person["wellbeing"] = clampi(int(person["wellbeing"]) + (8 if fed else 1), 0, 100)
		person["morale"] = clampi(int(person["morale"]) + (3 if fed else 1), 0, 100)
		if person.get("injured", false):
			person["health"] = clampi(int(person["health"]) + 4, 0, 100)
			if treatments_left > 0:
				treatments_left -= 1
				person["health"] = clampi(int(person["health"]) + 18, 0, 100)
				person["morale"] = clampi(int(person["morale"]) + 4, 0, 100)
			person["injured"] = int(person["health"]) < 72
		if person.get("injured", false):
			injured += 1
		morale_total += int(person["morale"])
		wellbeing_total += int(person["wellbeing"])
		survivors[sid] = person

	st["stored_items"] = stored
	st["local_stockpile"] = local
	var avg_morale := 70 if resident_ids.is_empty() else roundi(float(morale_total) / resident_ids.size())
	var avg_wellbeing := 60 if resident_ids.is_empty() else roundi(float(wellbeing_total) / resident_ids.size())
	var full_meals := food_used >= food_needed
	var productivity_bonus := full_meals and injured == 0 and avg_morale >= 60
	var status := "recovering" if injured > 0 else ("thriving" if productivity_bonus and avg_wellbeing >= 65 else ("comfortable" if full_meals else "steady"))
	var report := {
		"status": status,
		"food_needed": food_needed,
		"food_used": food_used,
		"medicine_used": medicine_used,
		"hungry": 0,
		"starving": 0,
		"injured": injured,
		"morale": avg_morale,
		"wellbeing": avg_wellbeing,
		"productivity_bonus": productivity_bonus,
		"incidents": [],
	}
	st["needs"] = report
	return report


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
		var is_connected := connected.has(id)
		var needs: Dictionary = _process_base_needs(id, st, is_connected)
		var result: Dictionary = WorkforceRules.produce(seed, b, st, survivors, placement_count(id, "farm"), settlement_cycle)
		var output: Dictionary = result["output"]
		var stockpile: Dictionary = (st.get("local_stockpile", {}) as Dictionary).duplicate()
		_add_bundle(stockpile, output)
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
			"unavailable": result.get("unavailable", 0),
			"needs": needs.duplicate(true),
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
	var existing_claims := claimed_ids()
	if not existing_claims.is_empty() and not st.get("supplied", false):
		var joined_to_safe_ground := false
		for home_id in networked_base_ids():
			if _wards_touch(home_id, id):
				joined_to_safe_ground = true
				break
		if not joined_to_safe_ground:
			return "connect a supply line or extend warded ground to this outpost before claiming it"
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
		"wall": return { "building_materials": 2, "zombie_matter": 1 }
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
	var entrance := InteriorGen.entrance_position(b, InteriorGen.footprint(b))
	var door := Vector2(entrance.x, entrance.z)
	var road := Vector2((b.road_tile.x + 0.5) * TILE_M, (b.road_tile.y + 0.5) * TILE_M)
	var lo := Vector2(minf(door.x, road.x), minf(door.y, road.y)) - Vector2(1.15, 1.15)
	var hi := Vector2(maxf(door.x, road.x), maxf(door.y, road.y)) + Vector2(1.15, 1.15)
	return _rect_footprint(Rect2(lo, hi - lo), "entrance lane")


func snap_wall_position(pos: Vector3, yaw: float) -> Vector3:
	var cardinal := snappedf(yaw, PI * 0.5)
	if absf(cos(cardinal)) >= absf(sin(cardinal)):
		pos.x = (roundf(pos.x / WARD_GRID - 0.5) + 0.5) * WARD_GRID
		pos.z = roundf(pos.z / WARD_GRID) * WARD_GRID
	else:
		pos.x = roundf(pos.x / WARD_GRID) * WARD_GRID
		pos.z = (roundf(pos.z / WARD_GRID - 0.5) + 0.5) * WARD_GRID
	return pos


func _ward_edge_key(a: Vector2i, b: Vector2i) -> String:
	if a.x > b.x or (a.x == b.x and a.y > b.y):
		var swap := a
		a = b
		b = swap
	return "%d,%d:%d,%d" % [a.x, a.y, b.x, b.y]


func _add_ward_edge(edges: Dictionary, a: Vector2i, b: Vector2i) -> void:
	edges[_ward_edge_key(a, b)] = true


func _ward_barriers(id: String, b: BuildingData) -> Dictionary:
	var edges := {}
	var safe := safe_rect_world(b)
	var lo := Vector2i(roundi(safe.position.x / WARD_GRID), roundi(safe.position.y / WARD_GRID))
	var hi := Vector2i(roundi(safe.end.x / WARD_GRID), roundi(safe.end.y / WARD_GRID))
	# Zombie matter closes the entrance energetically even though the physical gate stays
	# open for the player. Once built, this original perimeter is permanent safe ground.
	for x in range(lo.x, hi.x):
		_add_ward_edge(edges, Vector2i(x, lo.y), Vector2i(x + 1, lo.y))
		_add_ward_edge(edges, Vector2i(x, hi.y), Vector2i(x + 1, hi.y))
	for y in range(lo.y, hi.y):
		_add_ward_edge(edges, Vector2i(lo.x, y), Vector2i(lo.x, y + 1))
		_add_ward_edge(edges, Vector2i(hi.x, y), Vector2i(hi.x, y + 1))
	for item in placements:
		if item.get("building", "") != id or item.get("kind", "") != "wall":
			continue
		var pos: Vector3 = item.get("pos", Vector3.ZERO)
		var yaw := snappedf(float(item.get("yaw", 0.0)), PI * 0.5)
		var axis := Vector2(cos(yaw), -sin(yaw))
		var center := Vector2(pos.x, pos.z)
		var a := Vector2i(roundi((center.x - axis.x * WARD_GRID * 0.5) / WARD_GRID),
			roundi((center.y - axis.y * WARD_GRID * 0.5) / WARD_GRID))
		var c := Vector2i(roundi((center.x + axis.x * WARD_GRID * 0.5) / WARD_GRID),
			roundi((center.y + axis.y * WARD_GRID * 0.5) / WARD_GRID))
		if a != c and absi(a.x - c.x) + absi(a.y - c.y) == 1:
			_add_ward_edge(edges, a, c)
	return edges


func ward_cells(id: String) -> Dictionary:
	if _ward_cache.has(id):
		return _ward_cache[id]
	var b := building_by_id(id)
	var st: Dictionary = state.get(id, {})
	if b == null or not (st.get("warded", false) or st.get("fortified", false)):
		return {}
	var barriers := _ward_barriers(id, b)
	var safe := safe_rect_world(b)
	var node_lo := Vector2i(roundi(safe.position.x / WARD_GRID), roundi(safe.position.y / WARD_GRID))
	var node_hi := Vector2i(roundi(safe.end.x / WARD_GRID), roundi(safe.end.y / WARD_GRID))
	for item in placements:
		if item.get("building", "") != id or item.get("kind", "") != "wall":
			continue
		var p: Vector3 = item.get("pos", Vector3.ZERO)
		var n := Vector2i(roundi(p.x / WARD_GRID), roundi(p.z / WARD_GRID))
		node_lo.x = mini(node_lo.x, n.x - 1)
		node_lo.y = mini(node_lo.y, n.y - 1)
		node_hi.x = maxi(node_hi.x, n.x + 1)
		node_hi.y = maxi(node_hi.y, n.y + 1)
	var cell_lo := node_lo - Vector2i(2, 2)
	var cell_hi := node_hi + Vector2i(1, 1)
	var outside := {}
	var queue: Array[Vector2i] = [cell_lo]
	outside[cell_lo] = true
	var cursor := 0
	var directions: Array[Vector2i] = [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]
	while cursor < queue.size():
		var cell := queue[cursor]
		cursor += 1
		for direction in directions:
			var next := cell + direction
			if next.x < cell_lo.x or next.y < cell_lo.y or next.x > cell_hi.x or next.y > cell_hi.y or outside.has(next):
				continue
			var edge_a := Vector2i.ZERO
			var edge_b := Vector2i.ZERO
			if direction == Vector2i.RIGHT:
				edge_a = Vector2i(cell.x + 1, cell.y)
				edge_b = Vector2i(cell.x + 1, cell.y + 1)
			elif direction == Vector2i.LEFT:
				edge_a = Vector2i(cell.x, cell.y)
				edge_b = Vector2i(cell.x, cell.y + 1)
			elif direction == Vector2i.DOWN:
				edge_a = Vector2i(cell.x, cell.y + 1)
				edge_b = Vector2i(cell.x + 1, cell.y + 1)
			else:
				edge_a = Vector2i(cell.x, cell.y)
				edge_b = Vector2i(cell.x + 1, cell.y)
			if barriers.has(_ward_edge_key(edge_a, edge_b)):
				continue
			outside[next] = true
			queue.append(next)
	var enclosed := {}
	for y in range(cell_lo.y, cell_hi.y + 1):
		for x in range(cell_lo.x, cell_hi.x + 1):
			var cell := Vector2i(x, y)
			if not outside.has(cell):
				enclosed[cell] = true
	_ward_cache[id] = enclosed
	return enclosed


func ward_bounds_world(id: String) -> Rect2:
	var cells := ward_cells(id)
	if cells.is_empty():
		var b := building_by_id(id)
		return safe_rect_world(b) if b != null else Rect2()
	var lo := Vector2i(2147483647, 2147483647)
	var hi := Vector2i(-2147483648, -2147483648)
	for cell in cells:
		lo.x = mini(lo.x, cell.x)
		lo.y = mini(lo.y, cell.y)
		hi.x = maxi(hi.x, cell.x + 1)
		hi.y = maxi(hi.y, cell.y + 1)
	return Rect2(Vector2(lo) * WARD_GRID, Vector2(hi - lo) * WARD_GRID)


func ward_contains_point(id: String, point: Vector2) -> bool:
	var cell := Vector2i(floori(point.x / WARD_GRID), floori(point.y / WARD_GRID))
	return ward_cells(id).has(cell)


func ward_contains_rect(id: String, rect: Rect2) -> bool:
	var inset := Vector2(0.03, 0.03)
	for point in [rect.position + inset, Vector2(rect.end.x, rect.position.y) + Vector2(-inset.x, inset.y),
			rect.end - inset, Vector2(rect.position.x, rect.end.y) + Vector2(inset.x, -inset.y), rect.get_center()]:
		if not ward_contains_point(id, point):
			return false
	return true


func ward_cell_count(id: String) -> int:
	return ward_cells(id).size()


func ward_gate_world(id: String) -> Vector2:
	var b := building_by_id(id)
	if b == null:
		return Vector2.INF
	var direction_i := b.road_tile - b.door_tile
	var direction := Vector2(signi(direction_i.x), signi(direction_i.y))
	var point := Vector2((b.road_tile.x + 0.5) * TILE_M, (b.road_tile.y + 0.5) * TILE_M)
	if direction == Vector2.ZERO:
		return point
	# Follow the entrance ray through any newly enclosed cells. The returned point is
	# the actual ward boundary, even when a lopsided expansion enlarged its AABB elsewhere.
	for step in 512:
		var probe := point + direction * (WARD_GRID * 0.75)
		if not ward_contains_point(id, probe):
			break
		point += direction * WARD_GRID
	var cell := Vector2i(floori(point.x / WARD_GRID), floori(point.y / WARD_GRID))
	if direction.x < 0:
		point.x = cell.x * WARD_GRID
	elif direction.x > 0:
		point.x = (cell.x + 1) * WARD_GRID
	elif direction.y < 0:
		point.y = cell.y * WARD_GRID
	else:
		point.y = (cell.y + 1) * WARD_GRID
	return point


func is_world_safe(pos: Vector3) -> bool:
	var point := Vector2(pos.x, pos.z)
	for id in state:
		var st: Dictionary = state[id]
		if (st.get("warded", false) or st.get("fortified", false)) and ward_contains_point(id, point):
			return true
	return false


func is_tile_safe(tile: Vector2i) -> bool:
	return is_world_safe(tile_to_world(tile))


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
	if kind == "wall":
		var construction_band := ward_bounds_world(id).grow(WARD_GRID + 0.35)
		if bounds.position.x < construction_band.position.x or bounds.position.y < construction_band.position.y \
				or bounds.end.x > construction_band.end.x or bounds.end.y > construction_band.end.y:
			return "walls must connect near the current warded perimeter"
	elif not ward_contains_rect(id, bounds):
		return "%s must fit fully inside warded ground" % kind
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
	var safe := ward_bounds_world(id)
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


## The placed object the survivor is actually standing beside. Late dismantling must be
## spatially intentional; silently removing the newest object elsewhere in the base is a
## nasty failure mode once players have furnished more than one room.
func nearest_placement_for(id: String, world_pos: Vector3, max_distance: float = 3.4) -> Dictionary:
	var nearest: Dictionary = {}
	var best := max_distance * max_distance
	for i in range(placements.size() - 1, -1, -1):
		var item: Dictionary = placements[i]
		if item.get("building", "") != id:
			continue
		var pos: Vector3 = item.get("pos", Vector3.INF)
		if pos == Vector3.INF or absf(pos.y - world_pos.y) > 1.0:
			continue
		var distance := Vector2(pos.x - world_pos.x, pos.z - world_pos.z).length_squared()
		if distance < best:
			best = distance
			nearest = item.duplicate(true)
	return nearest


func _same_placement(a: Dictionary, b: Dictionary) -> bool:
	return a.get("building", "") == b.get("building", "") \
			and a.get("kind", "") == b.get("kind", "") \
			and a.get("pos", Vector3.INF) == b.get("pos", Vector3.INF) \
			and is_equal_approx(float(a.get("yaw", 0.0)), float(b.get("yaw", 0.0)))


func placement_refund(kind: String, refund_fraction: float) -> Dictionary:
	var refund: Dictionary = {}
	var cost := build_cost(kind)
	for material in cost:
		var amount := ceili(float(cost[material]) * clampf(refund_fraction, 0.0, 1.0))
		if amount > 0:
			refund[material] = amount
	return refund


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
	var refund := placement_refund(kind, refund_fraction)
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
