extends Node
## End-to-end survivor flow: deterministic mission -> route priority -> typed help ->
## pending roster -> save/load -> assignment and named settlement population.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	await get_tree().process_frame
	var main: Node = get_parent()
	World.persistence_enabled = false
	World.state.clear()
	World.supply_links.clear()
	World.placements.clear()
	World.survivors.clear()
	World.pending_survivors.clear()
	for key in World.materials:
		World.materials[key] = 0
	main.director.set_meta("no_street", true)
	main.director.street_spawning = false

	var rescue_building: BuildingData
	var other_buildings: Array[BuildingData] = []
	for sy in range(-1, 2):
		for sx in range(-1, 2):
			for b in World.get_sector(sx, sy).buildings:
				if rescue_building == null and World.rescue_eligible(b):
					rescue_building = b
				else:
					other_buildings.append(b)
	if rescue_building == null or other_buildings.size() < 2:
		_fail("could not find procedural rescue and base sites")
		return
	var mission := World.ensure_rescue_candidate(rescue_building.id())
	var repeated := World.ensure_rescue_candidate(rescue_building.id())
	if mission.is_empty() or mission != repeated:
		_fail("rescue candidate was missing or unstable")
		return
	if mission["name"] == "" or mission["trait"] == "" or mission["room_kind"] in ["", "stair", "hall"]:
		_fail("candidate lacks a stable named, traited semantic target: %s" % mission)
		return

	main.mode = main.Mode.INSIDE
	main.door_building = rescue_building
	main.interior.enter(rescue_building, int(mission["floor"]))
	var fp: FloorPlan = main.interior.plan
	var target_room := int(mission["room"])
	# Mark this storey quiet so route retirement is determined only by the pending rescue.
	for ri in fp.rooms.size():
		main.interior.floor_state()["rooms"][str(ri)] = true
	var start_room := target_room
	for ri in fp.rooms.size():
		if ri != target_room and not main.interior.route_any(ri, target_room).is_empty():
			start_room = ri
			break
	if start_room == target_room:
		_fail("target floor has no route into the rescue room")
		return
	main.interior.set_room(start_room)
	var rescue_path: Array = main.interior.route_any(start_room, target_room)
	var guidance: Dictionary = main.interior.recommended_option()
	if guidance.get("kind", "") != "door" or int(guidance.get("door", -1)) != int(rescue_path[0]):
		_fail("room guidance did not prioritize the survivor: %s" % guidance)
		return
	if main.interior.door_retired(int(rescue_path[0]), start_room):
		_fail("door toward the survivor was retired")
		return
	var retired_side_branch := false
	for ri in fp.rooms.size():
		for di in fp.rooms[ri].doors:
			if fp.doors[di].b >= 0 and main.interior.door_retired(di, ri):
				retired_side_branch = true
				break
		if retired_side_branch:
			break
	if not retired_side_branch:
		_fail("pending rescue prevented every cleared dead end from retiring")
		return

	main.interior.set_room(target_room)
	main._refresh_prompts()
	var prompt_words: Array = main.typist.prompts().map(func(p): return p["word"])
	if not prompt_words.has("help"):
		_fail("cleared rescue room did not expose the help action: %s" % prompt_words)
		return
	_type(main.typist, "help")
	var survivor_id: String = mission["id"]
	if not World.survivors.has(survivor_id) or not World.pending_survivors.has(survivor_id):
		_fail("typed rescue did not create a pending roster member")
		return
	if World.active_rescue(rescue_building.id()).size() != 0:
		_fail("completed rescue remained active")
		return

	var snapshot := World.save_snapshot()
	World.survivors.clear()
	World.pending_survivors.clear()
	World.state.clear()
	if not World.restore_snapshot(snapshot) or not World.survivors.has(survivor_id) \
			or not World.pending_survivors.has(survivor_id):
		_fail("save/load lost survivor roster state")
		return

	var first_base := other_buildings[0]
	World.state[first_base.id()] = { "cleared": true, "salvaged": true, "fortified": true }
	World.add_materials(World.claim_cost(first_base))
	var claim_result := World.claim_building(first_base.id())
	var first_state := World.building_state(first_base.id())
	if not claim_result.contains("claimed") or int(first_state.get("citizens", 0)) != 2 \
			or not (first_state.get("resident_ids", []) as Array).has(survivor_id):
		_fail("pending survivor was not assigned on first claim: %s / %s" % [claim_result, first_state])
		return
	if not World.pending_survivors.is_empty() or World.survivors[survivor_id].get("base_id", "") != first_base.id():
		_fail("assigned survivor retained pending/incorrect base state")
		return

	var later_base := other_buildings[1]
	World.state[later_base.id()] = { "cleared": true, "salvaged": true, "fortified": true, "supplied": true }
	World.add_materials(World.claim_cost(later_base))
	var later_result := World.claim_building(later_base.id())
	if not later_result.contains("claimed") or int(World.building_state(later_base.id()).get("citizens", -1)) != 0:
		_fail("later claim still created free citizens: %s" % World.building_state(later_base.id()))
		return

	main.settlement._rebuild(first_base.sector)
	var named_seen := false
	for citizen in main.settlement._citizens:
		if citizen.get_meta("survivor_id", "") == survivor_id:
			named_seen = citizen.get_meta("survivor_name", "") == mission["name"] \
					and citizen.get_meta("trait", "") == mission["trait"]
	if not named_seen:
		_fail("assigned survivor did not become a stable named settlement citizen")
		return

	print("RESCUE LOOP OK  ", mission["name"], " / ", mission["trait"], " / floor ", int(mission["floor"]) + 1, " ", mission["room_kind"])
	get_tree().quit(0)


func _type(typist: Node, word: String) -> void:
	for ch in word:
		var event := InputEventKey.new()
		event.pressed = true
		event.keycode = KEY_A + (ch.unicode_at(0) - 97)
		typist._input(event)


func _fail(msg: String) -> void:
	push_error("RESCUE LOOP FAIL: " + msg)
	get_tree().quit(1)
