extends Node
## Base provisions are positive bonuses: recovery, morale, productivity, deposit, and save.

var _failed := false


func _ready() -> void:
	World.persistence_enabled = false
	World.state.clear()
	World.supply_links.clear()
	World.placements.clear()
	World.survivors.clear()
	World.pending_survivors.clear()
	World.backpack.clear()
	World.settlement_cycle = 0
	for key in World.materials:
		World.materials[key] = 0
	var b: BuildingData = World.get_sector(0, 0).buildings[0]
	var sid := "needs:test"
	World.survivors[sid] = {
		"id": sid, "name": "Mara", "trait": "grower", "job": "farmer",
		"base_id": b.id(), "status": "assigned", "health": 50, "hunger": 50,
		"morale": 50, "injured": true,
	}
	World.state[b.id()] = {
		"claimed": true, "safe": true, "founders": 0, "citizens": 1,
		"resident_ids": [sid],
	}
	World.backpack = { "packaged_food": 2, "bandages": 1, "circuits": 1 }
	var deposit := World.deposit_backpack(b.id())
	_check(deposit.begins_with("stashed") and World.backpack.is_empty(), "backpack did not deposit into the active base")
	var stored: Dictionary = World.building_state(b.id()).get("stored_items", {})
	_check(int(stored.get("packaged_food", 0)) == 2 and int(stored.get("bandages", 0)) == 1, "deposited provisions were lost")

	var first := World.run_work_cycle()
	var report: Dictionary = first["bases"][b.id()]["needs"]
	var person: Dictionary = World.survivors[sid]
	_check(int(report["food_used"]) == 1 and int(report["medicine_used"]) == 1, "cycle did not consume stored food and bandages")
	_check(int(person["hunger"]) < 50 and int(person["health"]) > 50 and not person["injured"], "provisions did not feed and treat the resident")
	stored = World.building_state(b.id()).get("stored_items", {})
	_check(int(stored.get("packaged_food", 0)) == 1 and not stored.has("bandages") and int(stored.get("circuits", 0)) == 1, "cycle consumed the wrong stored items")

	stored.erase("packaged_food")
	World.building_state(b.id())["stored_items"] = stored
	person["hunger"] = 75
	person["morale"] = 38
	World.survivors[sid] = person
	var hungry_cycle := World.run_work_cycle()
	var hungry_report: Dictionary = hungry_cycle["bases"][b.id()]["needs"]
	_check(int(hungry_report["food_used"]) == 0 and hungry_report["status"] == "steady", "an optional meal shortage became punitive")
	_check(int(hungry_cycle["bases"][b.id()].get("unavailable", 0)) == 0, "a resident was blocked from contributing labour")
	_check(World.survivor_condition(World.survivors[sid]) == "steady", "roster condition framed a missing bonus as punishment")
	_check(int(World.survivors[sid]["hunger"]) == 75 and int(World.survivors[sid]["morale"]) > 38, "a cycle without provisions reduced resident welfare")

	var outpost: BuildingData = World.get_sector(0, 0).buildings[1]
	var isolated_id := "needs:isolated"
	World.survivors[isolated_id] = {
		"id": isolated_id, "name": "Sol", "trait": "builder", "job": "builder",
		"base_id": outpost.id(), "health": 100, "hunger": 40, "morale": 70, "injured": false,
	}
	World.state[outpost.id()] = { "claimed": true, "citizens": 1, "resident_ids": [isolated_id] }
	World.materials["food"] = 5
	var isolated_report := World._process_base_needs(outpost.id(), World.building_state(outpost.id()), false)
	_check(int(isolated_report["food_used"]) == 0 and int(World.materials["food"]) == 5, "cut-off outpost consumed network food")
	World.building_state(outpost.id())["local_stockpile"] = { "food": 1 }
	isolated_report = World._process_base_needs(outpost.id(), World.building_state(outpost.id()), false)
	_check(int(isolated_report["food_used"]) == 1 and int(World.materials["food"]) == 5, "cut-off outpost did not use its local food")

	var snapshot := World.save_snapshot()
	World.state.clear()
	World.survivors.clear()
	_check(World.restore_snapshot(snapshot), "needs snapshot could not be restored")
	_check(int(World.survivors[sid].get("hunger", 0)) == 75 and World.building_state(b.id()).has("needs"), "save lost resident or base wellbeing")
	if not _failed:
		print("SURVIVOR NEEDS OK  ", World.building_state(b.id())["needs"])
	get_tree().quit(1 if _failed else 0)


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error("SURVIVOR NEEDS FAIL: " + message)
