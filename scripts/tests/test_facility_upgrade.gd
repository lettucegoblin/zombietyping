extends Node
## Physical facility upgrades: role lock, staffing/cost gates, utility failure, persistence.

var _failed := false


func _ready() -> void:
	World.persistence_enabled = false
	World.state.clear()
	World.placements.clear()
	World.survivors.clear()
	for key in World.materials:
		World.materials[key] = 500
	var b := _ready_candidate()
	if b == null:
		_fail("could not find an upgrade-ready procedural facility")
		return
	World.state[b.id()] = { "cleared": true, "claimed": true, "founders": 1, "citizens": 1, "resident_ids": [] }
	var before := World.materials.duplicate()
	var initial := FacilityProfile.derive(World.seed, b, World.state[b.id()])
	var cost1 := World.facility_upgrade_cost(b.id())
	var result1 := World.upgrade_facility(b.id())
	var st: Dictionary = World.state[b.id()]
	_check(result1.contains("level 1"), "first upgrade failed: " + result1)
	_check(int(st.get("facility_level", 0)) == 1 and st.get("facility_role", "") == initial["role_id"], "upgrade did not lock its procedural role/level")
	for material in cost1:
		_check(int(World.materials[material]) == int(before[material]) - int(cost1[material]), "upgrade charged the wrong %s cost" % material)
	var operational := FacilityProfile.derive(World.seed, b, st)
	_check(operational["upgrade_operational"] and operational["readiness_kind"] == "operational", "intact upgrade did not become operational")

	var staffing_block := World.upgrade_facility(b.id())
	_check(staffing_block.contains("2 residents"), "level-two upgrade ignored staffing: " + staffing_block)
	st["citizens"] = 3
	var result2 := World.upgrade_facility(b.id())
	_check(result2.contains("level 2") and int(st["facility_level"]) == 2, "staffed level-two upgrade failed: " + result2)

	var required_stat := _first_required_stat(str(st["facility_role"]))
	var removed := {}
	for floor in b.floors:
		for prop in InteriorGen.generate(World.seed, b, floor).props:
			if prop.utility == required_stat or (required_stat == "beds" and prop.kind == "bed"):
				removed[prop.id] = true
	st["salvaged_props"] = removed
	var offline := FacilityProfile.derive(World.seed, b, st)
	_check(not offline["upgrade_operational"] and offline["readiness_kind"] == "needs", "dismantled required utilities did not take the upgrade offline")
	var blocked := World.upgrade_facility(b.id())
	_check(blocked.contains("restore intact utilities"), "offline facility accepted another upgrade: " + blocked)

	var snapshot := World.save_snapshot()
	World.state.clear()
	_check(World.restore_snapshot(snapshot) and int(World.state[b.id()].get("facility_level", 0)) == 2 \
			and World.state[b.id()].get("facility_role", "") == initial["role_id"], "save/load lost facility upgrade state")
	var settlement := Settlement.new()
	add_child(settlement)
	settlement._add_facility_upgrade(b, World.state[b.id()])
	var marker: Node3D = settlement._root.get_child(0)
	_check(marker.get_meta("facility_level", 0) == 2 and not marker.get_meta("operational", true) \
			and marker.get_child_count() == 3, "installed/offline upgrade was not represented by its rooftop marker")
	if not _failed:
		print("FACILITY UPGRADE OK  ", initial["role_label"], " level 2 · utility-offline gate")
	get_tree().quit(1 if _failed else 0)


func _ready_candidate() -> BuildingData:
	for sy in range(-1, 2):
		for sx in range(-1, 2):
			for b in World.get_sector(sx, sy).buildings:
				var profile := FacilityProfile.derive(World.seed, b, { "cleared": true, "claimed": true })
				if (profile["missing"] as Array).is_empty():
					return b
	return null


func _first_required_stat(role_id: String) -> String:
	for rule in FacilityProfile.ROLE_RULES:
		if rule["id"] == role_id:
			for stat in rule["requires"]:
				return stat
	return "storage"


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error("FACILITY UPGRADE FAIL: " + message)


func _fail(message: String) -> void:
	push_error("FACILITY UPGRADE FAIL: " + message)
	get_tree().quit(1)
