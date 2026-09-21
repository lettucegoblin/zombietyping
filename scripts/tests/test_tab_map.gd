extends Node
## Focused regression checks for TabMap supply caching and opaque-panel input capture.

var _failed := false


func _ready() -> void:
	World.supply_links.clear()
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
	World.supply_links.append(PackedStringArray([a.id(), b.id()]))
	map._sync_supply_route_cache()
	_check(map._supply_route_cache.size() == 1, "connected route was not cached")
	_check(map._supply_route_cache[0]["status"] == "route", "connected route was marked degenerate")
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
	if not _failed:
		print("TAB MAP OK  cached route builds=", builds, "  panel input captured")
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
