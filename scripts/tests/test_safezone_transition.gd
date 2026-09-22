extends Node
## Regression: claiming the site under the player enters SAFEZONE immediately and removes
## retained street threats before typing combat is disabled.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	await get_tree().process_frame
	var main: Node = get_parent()
	World.state.clear()
	World.supply_links.clear()
	World.placements.clear()
	World.safezone_blocks.clear()
	World.backpack.clear()
	for key in World.materials:
		World.materials[key] = 0

	var b: BuildingData = World.get_sector(0, 0).buildings[0]
	main.player.snap_to_road(b.road_tile)
	main._on_arrived(b.id())
	if main.mode != 1: # Main.Mode.DOOR
		_fail("arrival did not stop at the unclaimed building")
		return

	World.set_building_state(b.id(), "cleared", true)
	World.set_building_state(b.id(), "salvaged", true)
	World.set_building_state(b.id(), "fortified", true)
	World.add_materials(World.claim_cost(b))
	var street: Zombie = main.director._spawn(
		ZombieType.shambler(), main.player.global_position + Vector3(1.5, 0.0, 0.0)
	)
	if street.room >= 0:
		_fail("test threat was not a street zombie")
		return

	var result: String = World.claim_building(b.id())
	if not result.contains("claimed"):
		_fail("claim failed: " + result)
		return
	if main.mode != 3: # Main.Mode.SAFEZONE
		_fail("claiming the current building did not enter SAFEZONE")
		return
	if main.typist.enabled:
		_fail("typing combat remained enabled in SAFEZONE")
		return
	if not main.director.alive().is_empty():
		_fail("a hostile survived SAFEZONE entry")
		return
	if not street.is_queued_for_deletion():
		_fail("the retained street zombie was not removed")
		return
	World.add_materials({ "wood": 10 })
	main.settlement.build_index = Settlement.BUILD_KINDS.find("crate")
	_press(main, KEY_B)
	var cursor_start: Vector3 = main.settlement._ghost_root.position
	_press(main, KEY_RIGHT)
	if not is_equal_approx(main.settlement._ghost_root.position.distance_to(cursor_start), Settlement.NUDGE_STEP):
		_fail("safe-zone arrow input did not nudge the build cursor")
		return
	_press(main, KEY_C)
	if not main.settlement._ghost_root.position.is_equal_approx(cursor_start):
		_fail("safe-zone C input did not recenter the build cursor")
		return
	_press(main, KEY_ESCAPE)
	var gate_dir := Vector2(b.road_tile - b.door_tile).normalized()
	var gate_world := World.tile_to_world(b.road_tile)
	main.player.global_position = gate_world + Vector3(gate_dir.x, 0, gate_dir.y) * 1.9
	main.player.facing = Vector3(gate_dir.x, 0, gate_dir.y)
	main.player._manual_move_vector(Vector2(0, -1), 0.25)
	if main.mode != 0 or main.player.manual_control: # Main.Mode.STREET
		_fail("walking through the visible gate did not leave SAFEZONE")
		return
	var tower: BuildingData
	for candidate in World.get_sector(0, 0).buildings:
		if candidate.floors > 1:
			tower = candidate
			break
	if tower == null:
		_fail("test sector had no multi-storey claimed building")
		return
	World.set_building_state(tower.id(), "claimed", true)
	World.set_building_state(tower.id(), "safe", true)
	main.player.snap_to_road(tower.road_tile)
	main._enter_safezone(tower)
	var floor_result: String = main._safezone_floor(1)
	if main.interior.plan.floor != 1 or main.player.global_position.y < World.FLOOR_M or not floor_result.contains("2/"):
		_fail("claimed multi-storey navigation did not reach floor 2: " + floor_result)
		return
	main.hp = 60
	World.backpack = { "bandages": 1 }
	var heal_key := InputEventKey.new()
	heal_key.pressed = true
	heal_key.keycode = KEY_H
	main._unhandled_input(heal_key)
	if main.hp != 90 or not World.backpack.is_empty():
		_fail("safe-zone bandage control did not consume carried medicine")
		return
	World.backpack = { "circuits": 1 }
	var stash_key := InputEventKey.new()
	stash_key.pressed = true
	stash_key.keycode = KEY_G
	main._unhandled_input(stash_key)
	if not World.backpack.is_empty() or int(World.building_state(tower.id()).get("stored_items", {}).get("circuits", 0)) != 1:
		_fail("safe-zone stash control did not deposit carried loot")
		return

	print("SAFEZONE TRANSITION OK  build cursor input + gate exit + multi-storey free roam + backpack controls")
	get_tree().quit(0)


func _press(main: Node, keycode: Key) -> void:
	var event := InputEventKey.new()
	event.pressed = true
	event.keycode = keycode
	main._unhandled_input(event)


func _fail(msg: String) -> void:
	push_error("SAFEZONE TRANSITION FAIL: " + msg)
	get_tree().quit(1)
