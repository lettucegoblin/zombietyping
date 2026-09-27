extends Node
## Focused regression checks for TabMap supply caching and opaque-panel input capture.

var _failed := false


func _ready() -> void:
	MapLabels.reset_cache()
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
	var player: Node3D = main.get_node("View/Viewport/World/Player")
	var minimap: Control = main.get_node("UI/Minimap")
	var reticle: Control = main.get_node("UI/BuildingReticle")
	_check(main._gameplay_mouse_look, "gameplay did not enable always-on mouse look")
	var gameplay_facing: Vector3 = player.facing
	var look_motion := InputEventMouseMotion.new()
	look_motion.relative = Vector2(80, 0)
	main._unhandled_input(look_motion)
	_check(not player.facing.is_equal_approx(gameplay_facing), "unclicked gameplay mouse motion did not look")
	main._toggle_map()
	_check(map.visible and get_tree().paused, "Tab map did not open paused")
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "Tab map did not release its pointer")
	var menu_facing: Vector3 = player.facing
	main._unhandled_input(look_motion)
	_check(player.facing.is_equal_approx(menu_facing), "menu mouse motion leaked into camera look")
	map.close()
	_check(not get_tree().paused, "closing Tab map left gameplay paused")
	_check(main._gameplay_mouse_look, "closing Tab map did not restore mouse look")

	var pair := _connected_pair()
	if pair.is_empty():
		_fail("could not find two road-connected buildings")
		return
	var a: BuildingData = pair[0]
	var b: BuildingData = pair[1]
	# The first-person centre ray names the nearest visible building collider and registers
	# the same stable address with HUD typing. A close probe isolates the ray contract from
	# whichever procedural facades happen to be facing the spawn in this seed.
	var probe := StaticBody3D.new()
	probe.collision_layer = 1
	probe.collision_mask = 0
	probe.set_meta("bid", a.id())
	var probe_shape := CollisionShape3D.new()
	var probe_box := BoxShape3D.new()
	probe_box.size = Vector3(1.0, 1.0, 0.2)
	probe_shape.shape = probe_box
	probe.add_child(probe_shape)
	main.get_node("View/Viewport/World").add_child(probe)
	probe.global_position = player.cam.global_position - player.cam.global_transform.basis.z * 2.0
	await get_tree().physics_frame
	reticle._physics_process(0.0)
	var aimed_id := str(reticle.get("target_id"))
	_check(aimed_id != "" and World.building_by_id(aimed_id) != null, "centre reticle did not resolve building collision metadata")
	var reticle_label := str(reticle.get("target_label"))
	_check(reticle_label != "" and minimap.labels.get(reticle_label, "") == aimed_id, "reticle address was not registered for HUD typing")
	probe.queue_free()
	await get_tree().physics_frame

	# Dense map labels nudge into non-overlapping slots instead of painting over one another.
	var bounds := Rect2(Vector2.ZERO, Vector2(160, 100))
	var none: Array[Rect2] = []
	var occupied: Array[Rect2] = []
	var first: Rect2 = minimap._nudged_label_rect(Vector2(80, 50), Vector2(28, 14), none, bounds)
	occupied.append(first)
	var second: Rect2 = minimap._nudged_label_rect(Vector2(80, 50), Vector2(28, 14), occupied, bounds)
	_check(first.size != Vector2.ZERO and second.size != Vector2.ZERO and not first.intersects(second), "minimap label nudging allowed overlap")
	# Once two labels have claimed offsets, their result is independent of which one is
	# visited first on later frames. This prevents newly visible edge labels from cascading
	# all existing addresses into different nudge slots.
	minimap._label_offsets.clear()
	var anchor := Vector2(80, 50)
	var stable_none: Array[Rect2] = []
	var stable_a: Rect2 = minimap._stable_label_rect("stable-a", anchor, Vector2(28, 14), stable_none, bounds)
	var stable_occupied: Array[Rect2] = [stable_a]
	var stable_b: Rect2 = minimap._stable_label_rect("stable-b", anchor, Vector2(28, 14), stable_occupied, bounds)
	var offset_a: Vector2 = minimap._label_offsets["stable-a"]
	var reverse_occupied: Array[Rect2] = []
	var reverse_b: Rect2 = minimap._stable_label_rect("stable-b", anchor, Vector2(28, 14), reverse_occupied, bounds)
	reverse_occupied.append(reverse_b)
	var reverse_a: Rect2 = minimap._stable_label_rect("stable-a", anchor, Vector2(28, 14), reverse_occupied, bounds)
	_check(reverse_a.size != Vector2.ZERO and reverse_b.size != Vector2.ZERO and not reverse_a.intersects(reverse_b),
		"remembered minimap label slots became order-dependent")
	_check((reverse_a.get_center() - anchor).is_equal_approx(offset_a),
		"an existing minimap label shifted when another label became visible")
	# A newcomer can arrive earlier in the draw list (for example after becoming queued).
	# The two-pass layout must still reserve the existing label before placing it.
	minimap._label_offsets.clear()
	var first_candidates := [{"id": "settled", "anchor": anchor, "size": Vector2(28, 14)}]
	var no_blockers: Array[Rect2] = []
	var first_layout: Dictionary = minimap._layout_label_candidates(first_candidates, bounds, no_blockers)
	var settled_rect: Rect2 = first_layout["settled"]
	var newcomer_first := [
		{"id": "new", "anchor": anchor, "size": Vector2(28, 14)},
		{"id": "settled", "anchor": anchor, "size": Vector2(28, 14)},
	]
	var retained_layout: Dictionary = minimap._layout_label_candidates(newcomer_first, bounds, no_blockers)
	var retained_settled: Rect2 = retained_layout["settled"]
	var retained_new: Rect2 = retained_layout["new"]
	_check(retained_settled.is_equal_approx(settled_rect),
		"newly visible priority label stole a settled minimap slot")
	_check(not retained_new.intersects(retained_settled),
		"newcomer was not nudged around the settled minimap label")
	# The actual minimap clips drawing; its layout should accept a partially offscreen label
	# so movement reveals it continuously through the edge instead of popping it in.
	minimap._label_offsets.clear()
	var screen_bounds := Rect2(Vector2.ZERO, Vector2(160, 100))
	var overscan_bounds := screen_bounds.grow(minimap.LABEL_OVERSCAN)
	var edge_none: Array[Rect2] = []
	var edge_rect: Rect2 = minimap._stable_label_rect("edge", Vector2(-5, 50),
		Vector2(28, 14), edge_none, overscan_bounds)
	_check(edge_rect.size != Vector2.ZERO and edge_rect.intersects(screen_bounds)
		and not screen_bounds.encloses(edge_rect), "minimap rejected a partially visible overscan label")
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
	_check(all_count > 0, "large-range map produced no building addresses")
	var explored_snapshot: Dictionary = World.explored.duplicate(true)
	World.explored.clear()
	map._invalidate()
	map.recompute_labels()
	_check(not map._labels.is_empty(), "fogged buildings were not addressable")
	World.explored.merge(explored_snapshot, true)
	map._invalidate()
	map.recompute_labels()
	var stable_id: String = map._labels[map._labels.keys()[0]]
	var stable_label: String = map._label_for_id(stable_id)
	map._center += Vector2(3.0, 2.0)
	map._invalidate()
	map.recompute_labels()
	_check(map._label_for_id(stable_id) == stable_label, "small view movement changed a building address")
	map._center = a.center_tile()
	map._invalidate()
	map.recompute_labels()
	all_labels = map._labels.duplicate()
	all_count = map._placed.size()
	var crew_label: String = map._label_for_id(a.id())
	var crew_id := "tab:test:resident"
	World.survivors[crew_id] = { "id": crew_id, "name": "Bea", "trait": "medic", "job": "scavenger", "base_id": a.id(), "status": "assigned" }
	World.state[a.id()] = { "cleared": true, "claimed": true, "founders": 0, "citizens": 1, "resident_ids": [crew_id] }
	map._on_submit("job %s medic" % crew_label)
	_check(World.survivors[crew_id]["job"] == "medic", "typed building-menu job command did not assign the resident")
	World.state.erase(a.id())
	World.survivors.clear()
	map._show_all_buildings = false
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
	_check(map._displayed_placed().size() == mini(map.ALL_SITE_DRAW_LIMIT, all_count), "all-sites draw budget was not applied")
	_check(map._labels.size() == all_count, "all-sites draw budget removed typeable addresses")
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
