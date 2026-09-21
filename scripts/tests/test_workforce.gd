extends Node
## Procedural base work: trait assignment, staffed farms, route-held stock, delivery, save.

var _failed := false


func _ready() -> void:
	World.persistence_enabled = false
	World.state.clear()
	World.supply_links.clear()
	World.placements.clear()
	World.survivors.clear()
	World.pending_survivors.clear()
	World.settlement_cycle = 0
	World.settlement_work_seconds = 0.0
	for key in World.materials:
		World.materials[key] = 0

	var buildings: Array[BuildingData] = []
	for b in World.get_sector(0, 0).buildings:
		buildings.append(b)
	if buildings.size() < 2:
		_fail("not enough procedural bases")
		return
	var home := buildings[0]
	var outpost := buildings[1]
	var grower_id := "test:grower"
	var scout_id := "test:scout"
	World.survivors[grower_id] = { "id": grower_id, "name": "June", "trait": "grower", "base_id": home.id(), "status": "assigned" }
	World.survivors[scout_id] = { "id": scout_id, "name": "Rafi", "trait": "scout", "job": "scavenger", "base_id": outpost.id(), "status": "assigned" }
	World.state[home.id()] = { "claimed": true, "safe": true, "founders": 1, "citizens": 2, "resident_ids": [grower_id] }
	World.state[outpost.id()] = { "claimed": true, "safe": true, "founders": 0, "citizens": 1, "resident_ids": [scout_id] }
	World.placements.append({ "building": home.id(), "kind": "farm", "pos": Vector3.ZERO, "yaw": 0.0 })

	var assigned := World.auto_assign_jobs(home.id())
	_check(assigned.contains("June") and World.survivors[grower_id]["job"] == "farmer", "grower was not assigned to the existing farm")
	_check(World.assign_next_job(home.id(), "invalid").contains("job must be"), "invalid job was accepted")
	_check(World.assign_next_job(home.id(), "builder").contains("June") and World.survivors[grower_id]["job"] == "builder", "manual job assignment missed the resident cursor")
	World.assign_next_job(home.id(), "farmer")

	var cycle1 := World.run_work_cycle()
	var home_report: Dictionary = cycle1["bases"][home.id()]
	_check(int(home_report["tended_farms"]) == 1, "staffed farm was not tended")
	_check(int(home_report["output"].get("food", 0)) >= 2 and int(World.materials["food"]) >= 2, "farm output did not reach shared materials")
	var held: Dictionary = World.building_state(outpost.id()).get("local_stockpile", {})
	_check(not held.is_empty(), "disconnected outpost did not retain local production")
	_check(not World.building_state(outpost.id())["last_production"]["delivered"], "disconnected outpost falsely delivered output")

	var before_delivery := _material_total(World.materials)
	World.supply_links.append(PackedStringArray([home.id(), outpost.id()]))
	World.run_work_cycle()
	_check((World.building_state(outpost.id()).get("local_stockpile", {}) as Dictionary).is_empty(), "restored route did not flush held stock")
	_check(World.building_state(outpost.id())["last_production"]["delivered"], "connected outpost still reports a cut route")
	_check(_material_total(World.materials) > before_delivery, "supply network delivered no production")

	World.settlement_work_seconds = 12.5
	var snapshot := World.save_snapshot()
	World.settlement_cycle = 0
	World.settlement_work_seconds = 0.0
	World.survivors.clear()
	_check(World.restore_snapshot(snapshot), "workforce snapshot did not restore")
	_check(World.settlement_cycle == 2 and is_equal_approx(World.settlement_work_seconds, 12.5), "work-cycle clock was not persisted")
	_check(World.survivors[grower_id].get("job", "") == "farmer", "resident job was not persisted")

	var specialist_base := _specialist_building()
	if specialist_base == null:
		_fail("could not find a procedural workshop with intact utilities")
		return
	var specialist_roster := {
		"test:mechanic": { "job": "mechanic", "trait": "mechanic" },
		"test:medic": { "job": "medic", "trait": "medic" },
	}
	var specialist_state := { "cleared": true, "claimed": true, "resident_ids": ["test:mechanic", "test:medic"] }
	var specialist_result := Workforce.produce(World.seed, specialist_base, specialist_state, specialist_roster, 0, 6)
	var specialist_output: Dictionary = specialist_result["output"]
	_check(int(specialist_output.get("tools", 0)) > 0 and int(specialist_output.get("vehicle_parts", 0)) > 0 and int(specialist_output.get("medicine", 0)) > 0, "intact workshop/water utilities did not enable specialists")
	var removed_power := {}
	for floor in specialist_base.floors:
		for prop in InteriorGen.generate(World.seed, specialist_base, floor).props:
			if prop.utility == "power":
				removed_power[prop.id] = true
	specialist_state["salvaged_props"] = removed_power
	var stripped_result := Workforce.produce(World.seed, specialist_base, specialist_state, specialist_roster, 0, 6)
	var stripped_output: Dictionary = stripped_result["output"]
	_check(int(stripped_output.get("tools", 0)) == 0 and int(stripped_output.get("vehicle_parts", 0)) == 0, "dismantled power props still enabled mechanic output")

	if not _failed:
		print("WORKFORCE OK  staffed farms + held stock + route delivery + persistent jobs")
	get_tree().quit(1 if _failed else 0)


func _material_total(bundle: Dictionary) -> int:
	var total := 0
	for value in bundle.values():
		total += int(value)
	return total


func _specialist_building() -> BuildingData:
	for sy in range(-1, 2):
		for sx in range(-1, 2):
			for b in World.get_sector(sx, sy).buildings:
				var profile := FacilityProfile.derive(World.seed, b, { "cleared": true })
				if int(profile["rooms"].get("workshop", 0)) > 0 and int(profile["stats"].get("power", 0)) > 0 \
						and int(profile["stats"].get("water", 0)) > 0 and int(profile["stats"].get("storage", 0)) > 0:
					return b
	return null


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error("WORKFORCE FAIL: " + message)


func _fail(message: String) -> void:
	push_error("WORKFORCE FAIL: " + message)
	get_tree().quit(1)
