extends Node
## Headless progression check for the procedural settlement economy.

func _ready() -> void:
	World.state.clear()
	World.supply_links.clear()
	World.placements.clear()
	for key in World.materials:
		World.materials[key] = 0
	var first: BuildingData
	var second: BuildingData
	for b in World.get_sector(0, 0).buildings:
		if first == null and World.car_exists(b):
			first = b
		elif second == null:
			second = b
	if first == null or second == null:
		_fail("could not find procedural settlement sites")
		return
	World.set_building_state(first.id(), "visited", true)
	World.set_building_state(first.id(), "cleared", true)
	_assert_ok(World.salvage_building(first.id()), "salvage first")
	for i in 4:
		_assert_ok(World.salvage_car(first.id()), "car stage %d" % i)
	_assert_ok(World.fortify_building(first.id()), "fortify first")
	_assert_ok(World.claim_building(first.id()), "claim first")
	if not World.building_state(first.id()).get("claimed", false):
		_fail("first base was not claimed")
		return
	# A second cleared site must be fortified and supplied; clearing alone never claims it.
	World.set_building_state(second.id(), "visited", true)
	World.set_building_state(second.id(), "cleared", true)
	_assert_ok(World.salvage_building(second.id()), "salvage second")
	_assert_ok(World.fortify_building(second.id()), "fortify second")
	var premature := World.claim_building(second.id())
	if not premature.contains("supply"):
		_fail("second claim bypassed supply rule: " + premature)
		return
	_assert_ok(World.link_supply(second.id()), "link supply")
	_assert_ok(World.claim_building(second.id()), "claim second")
	var r := World.safe_rect_world(first)
	_assert_ok(World.place_item(first.id(), "chair", Vector3(r.get_center().x, 0.05, r.get_center().y), 0.0), "place furniture")
	print("SETTLEMENT OK  materials=", World.material_summary(), "  links=", World.supply_links.size(), "  placements=", World.placements.size())
	get_tree().quit(0)


func _assert_ok(msg: String, step: String) -> void:
	if msg.begins_with("need ") or msg.contains("before") or msg.contains("only") or msg.contains("no viable"):
		_fail("%s failed: %s" % [step, msg])


func _fail(msg: String) -> void:
	push_error("SETTLEMENT FAIL: " + msg)
	get_tree().quit(1)
