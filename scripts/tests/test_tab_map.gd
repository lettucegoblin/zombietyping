extends Node
## Focused regression checks for TabMap supply caching and opaque-panel input capture.

var _failed := false


func _ready() -> void:
	World.persistence_enabled = false
	World.state.clear()
	World.explored.clear()
	World.supply_links.clear()
	World.survivors.clear()
	var main: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	var map: Control = main.get_node("UI/TabMap")
	map.size = Vector2(1280, 720)

	var pair := _connected_pair()
	if pair.is_empty():
		_fail("could not find two road-connected buildings")
		return
	var a: BuildingData = pair[0]
	var b: BuildingData = pair[1]
	_check(map.building_name(a) == map.building_name(a), "building name is not deterministic")
	_check(map.building_name(a).contains(" "), "building name is not human-readable")
	World.state[a.id()] = { "cleared": true, "claimed": true }
	var facility: Dictionary = map.facility_profile(a)
	var facility_lines: Array[String] = map.facility_panel_lines(a)
	_check(str(facility["role_label"]) != "", "building panel omitted deterministic facility role")
	_check(facility_lines.size() >= 5, "building panel omitted intact utility details")
	_check(facility_lines[0].contains(str(facility["role_label"])), "panel role disagrees with facility profile")
	_check(facility_lines[-1] == facility["readiness"], "panel omitted upgrade readiness")
	World.state.erase(a.id())

	# Focus mode draws a small actionable subset without changing the complete label map
	# consumed by typed navigation.
	World.mark_explored(Vector2i(a.center_tile()), 72)
	map._center = a.center_tile()
	map._ppt = 10.0
	map._invalidate()
	map.recompute_labels()
	var all_count: int = map._placed.size()
	var all_labels: Dictionary = map._labels.duplicate()
	var crew_label: String = map._label_for_id(a.id())
	var crew_id := "tab:test:resident"
	World.survivors[crew_id] = { "id": crew_id, "name": "Bea", "trait": "medic", "job": "scavenger", "base_id": a.id(), "status": "assigned" }
	World.state[a.id()] = { "cleared": true, "claimed": true, "founders": 0, "citizens": 1, "resident_ids": [crew_id] }
	map._on_submit("job %s medic" % crew_label)
	_check(World.survivors[crew_id]["job"] == "medic", "typed building-menu job command did not assign the resident")
	World.state.erase(a.id())
	World.survivors.clear()
	var focused: Array = map._displayed_placed()
	_check(all_count > map.FOCUS_EXPLORATION_SITES, "test view did not expose enough buildings for focus mode")
	_check(focused.size() <= map.FOCUS_EXPLORATION_SITES, "focus mode did not reduce label overload")
	var focused_ids := {}
	for entry in focused:
		focused_ids[(entry["b"] as BuildingData).id()] = true
	var hidden_label := ""
	var hidden_id := ""
	for label in map._labels:
		if not focused_ids.has(map._labels[label]):
			hidden_label = label
			hidden_id = map._labels[label]
			break
	_check(hidden_label != "", "focus mode left no hidden label to test")
	var capture := { "ids": [] }
	map.destinations_typed.connect(func(ids): capture["ids"] = ids)
	map._on_submit(hidden_label)
	_check((capture["ids"] as Array).has(hidden_id), "focus-hidden label stopped typed navigation")
	_check(map._labels == all_labels, "typing or focus mode mutated label addresses")
	map._show_all_buildings = true
	_check(map._displayed_placed().size() == all_count, "all-sites toggle omitted known buildings")
	map._show_all_buildings = false
	map.visible = true
	var f3 := InputEventKey.new()
	f3.keycode = KEY_F3
	f3.pressed = true
	map._input(f3)
	_check(map._show_all_buildings, "F3 did not enable all-sites detail")
	map._input(f3)
	_check(not map._show_all_buildings, "F3 did not return to focus mode")
	map.visible = false
	World.state[hidden_id] = { "visited": true }
	var priority_ids := {}
	for entry in map._displayed_placed():
		priority_ids[(entry["b"] as BuildingData).id()] = true
	_check(priority_ids.has(hidden_id), "stateful priority site was hidden by focus mode")

	World.supply_links.append(PackedStringArray([a.id(), b.id()]))
	map._sync_supply_route_cache()
	_check(map._supply_route_cache.size() == 1, "connected route was not cached")
	_check(map._supply_route_cache[0]["status"] == "route", "connected route was marked degenerate")
	_check(map._endpoint_text(a.id()).contains(map.building_name(a)), "supply endpoint omitted building name")
	_check(map._new_supply_message(b.id()).contains("→"), "supply message omitted route direction")
	map._selected_id = b.id()
	map.visible = true
	map.queue_redraw()
	await get_tree().process_frame
	map.visible = false
	var builds: int = map._supply_route_build_count
	for i in 12:
		map._sync_supply_route_cache()
	_check(map._supply_route_build_count == builds, "unchanged topology rebuilt A* routes")

	# A same-endpoint link is valid-but-degenerate. It gets a visible point marker and
	# deliberately avoids an unnecessary A* query.
	World.supply_links.append(PackedStringArray([a.id(), a.id()]))
	map._sync_supply_route_cache()
	_check(map._supply_route_cache.size() == 2, "topology change did not invalidate cache")
	_check(map._supply_route_cache[1]["status"] == "point", "zero-length link lacks point state")
	var builds_after_change: int = map._supply_route_build_count
	map._sync_supply_route_cache()
	_check(map._supply_route_build_count == builds_after_change, "degenerate route cache was unstable")

	# Entering the opaque panel cancels an active map drag; wheel input there must not zoom.
	var panel_center: Vector2 = map._panel_rect().get_center()
	var old_center: Vector2 = map._center
	map._dragging = true
	var motion := InputEventMouseMotion.new()
	motion.position = panel_center
	motion.relative = Vector2(90, 30)
	map._gui_input(motion)
	_check(not map._dragging, "panel did not cancel map drag")
	_check(map._center == old_center, "drag moved map through opaque panel")
	var old_zoom: float = map._ppt
	var wheel := InputEventMouseButton.new()
	wheel.position = panel_center
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	map._gui_input(wheel)
	_check(is_equal_approx(map._ppt, old_zoom), "wheel zoom leaked through opaque panel")

	World.supply_links.clear()
	World.state.clear()
	World.explored.clear()
	World.survivors.clear()
	if not _failed:
		print("TAB MAP OK  cached route builds=", builds, "  focus=", focused.size(), "/", all_count, "  names + input captured")
	get_tree().quit(1 if _failed else 0)


func _connected_pair() -> Array[BuildingData]:
	var candidates: Array[BuildingData] = []
	for sy in range(-1, 2):
		for sx in range(-1, 2):
			for b in World.get_sector(sx, sy).buildings:
				candidates.append(b)
	for i in candidates.size():
		for j in range(i + 1, candidates.size()):
			if candidates[i].road_tile == candidates[j].road_tile:
				continue
			if World.find_path(candidates[i].road_tile, candidates[j].road_tile).size() >= 2:
				return [candidates[i], candidates[j]]
	return []


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error("TAB MAP FAIL: " + message)


func _fail(message: String) -> void:
	push_error("TAB MAP FAIL: " + message)
	get_tree().quit(1)
