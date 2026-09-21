extends Node
## Determinism and depletion regression for read-only procedural facility profiles.


func _ready() -> void:
	World.persistence_enabled = false
	World.state.clear()
	var b := _profile_candidate()
	if b == null:
		_fail("could not find a furnished procedural building")
		return
	var surveyed := { "cleared": true }
	var baseline := FacilityProfile.derive(World.seed, b, surveyed)
	var repeat := FacilityProfile.derive(World.seed, b, surveyed)
	_check(baseline == repeat, "same seed/building produced a different profile")
	_check(str(baseline["role_label"]) != "", "profile omitted facility role")
	_check(int(baseline["generated_props"]) > 0, "profile omitted generated props")
	_check(FacilityProfile.utility_lines(baseline).size() == 2, "profile utility summary is incomplete")

	var removed: Dictionary = {}
	var expected_stats: Dictionary = (baseline["stats"] as Dictionary).duplicate()
	var removed_count := 0
	for floor in b.floors:
		var fp := InteriorGen.generate(World.seed, b, floor)
		for prop in fp.props:
			if removed_count >= 5:
				break
			if prop.utility == "" and prop.kind != "bed":
				continue
			removed[prop.id] = true
			removed_count += 1
			if prop.kind == "bed":
				expected_stats["beds"] -= 1
			if expected_stats.has(prop.utility):
				expected_stats[prop.utility] -= 1
		if removed_count >= 5:
			break
	_check(removed_count > 0, "candidate had no stable utility prop IDs")
	var stripped_state := { "cleared": true, "salvaged_props": removed }
	var stripped := FacilityProfile.derive(World.seed, b, stripped_state)
	_check(stripped["stats"] == expected_stats, "dismantled props still contribute utilities")
	_check(int(stripped["dismantled_props"]) == removed_count, "dismantled count ignored known prop IDs")
	_check(int(stripped["intact_props"]) == int(baseline["intact_props"]) - removed_count, "intact count did not decrease exactly")

	var claimed_state := stripped_state.duplicate(true)
	claimed_state["claimed"] = true
	var claimed := FacilityProfile.derive(World.seed, b, claimed_state)
	_check(claimed["stats"] == stripped["stats"], "claiming changed the intact utility profile")
	_check(claimed["role_id"] == stripped["role_id"], "claiming created a parallel facility role")
	var expected_ready: bool = (stripped["missing"] as Array).is_empty()
	_check(bool(claimed["upgrade_ready"]) == expected_ready, "claimed readiness ignored role requirements")
	_check(str(claimed["readiness"]).contains("upgrade-ready") == expected_ready, "readiness copy does not explain upgrade state")
	if not _failed:
		print("FACILITY PROFILE OK  ", b.kind, " → ", baseline["role_label"], "  intact=", stripped["intact_props"], "/", stripped["generated_props"])
	get_tree().quit(1 if _failed else 0)


var _failed := false


func _profile_candidate() -> BuildingData:
	for sy in range(-1, 2):
		for sx in range(-1, 2):
			for b in World.get_sector(sx, sy).buildings:
				var profile := FacilityProfile.derive(World.seed, b, { "cleared": true })
				if int(profile["generated_props"]) >= 8 and int(profile["stats"]["storage"]) > 0:
					return b
	return null


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error("FACILITY PROFILE FAIL: " + message)


func _fail(message: String) -> void:
	push_error("FACILITY PROFILE FAIL: " + message)
	get_tree().quit(1)
