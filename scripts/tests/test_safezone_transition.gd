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

	print("SAFEZONE TRANSITION OK")
	get_tree().quit(0)


func _fail(msg: String) -> void:
	push_error("SAFEZONE TRANSITION FAIL: " + msg)
	get_tree().quit(1)
