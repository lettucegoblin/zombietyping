extends Node
## Headless progression check for the procedural settlement economy.

func _ready() -> void:
	World.persistence_enabled = false
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
	var first_plan := InteriorGen.generate(World.seed, first, 0)
	if first_plan.props.is_empty():
		_fail("claimed building had no stable props to dismantle")
		return
	var salvage_prop: FloorPlan.Prop = first_plan.props[0]
	var prop_yield := PropSalvage.material_yield(salvage_prop.kind)
	var prop_before: Dictionary = World.materials.duplicate()
	var prop_result := PropSalvage.salvage(first.id(), salvage_prop)
	if not prop_result.begins_with("dismantled") or not PropSalvage.is_salvaged(first.id(), salvage_prop.id):
		_fail("stable prop did not dismantle: " + prop_result)
		return
	for key in prop_yield:
		if int(World.materials[key]) != int(prop_before.get(key, 0)) + int(prop_yield[key]):
			_fail("prop yielded the wrong %s amount" % key)
			return
	var duplicate_prop := PropSalvage.salvage(first.id(), salvage_prop)
	if not duplicate_prop.contains("already"):
		_fail("prop could be dismantled twice: " + duplicate_prop)
		return
	var self_link := World.link_supply(first.id())
	if not self_link.contains("themselves"):
		_fail("claimed base accepted a self supply link: " + self_link)
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
	World.add_materials({ "building_materials": 200, "wood": 200, "textiles": 200, "tools": 40 })
	var chair_pos := Vector3(r.get_center().x, 0.05, r.get_center().y)
	_assert_ok(World.place_item(first.id(), "chair", chair_pos, 0.0), "place furniture")
	var before_overlap: int = World.materials["wood"]
	var overlap := World.place_item(first.id(), "crate", chair_pos, 0.0)
	if not overlap.contains("overlaps") or int(World.materials["wood"]) != before_overlap:
		_fail("overlap was accepted or charged materials: " + overlap)
		return
	var edge_pos := Vector3(r.position.x + 0.05, 0.05, r.position.y + 0.05)
	var outside := World.place_item(first.id(), "bed", edge_pos, 0.0)
	if not outside.contains("fit fully"):
		_fail("full-footprint bounds were not enforced: " + outside)
		return
	var farm_site := World.find_farm_site(first.id())
	if farm_site.is_empty():
		_fail("claimed site had no valid procedural farm position")
		return
	var farm_pos: Vector3 = farm_site["pos"]
	var farm_yaw: float = farm_site["yaw"]
	_assert_ok(World.build_farm(first.id()), "place farm")
	var farm_item: Dictionary = World.placements[-1]
	if farm_item["pos"] != farm_pos or not is_equal_approx(float(farm_item["yaw"]), farm_yaw):
		_fail("farm transform was not persisted")
		return
	var building_fp := World.building_rect_world(first)
	if building_fp.has_point(Vector2(farm_pos.x, farm_pos.z)):
		_fail("farm site was placed inside the building")
		return
	var second_farm := World.place_item(first.id(), "farm", farm_pos, farm_yaw)
	if not second_farm.contains("overlaps"):
		_fail("duplicate farm footprint was accepted: " + second_farm)
		return
	var wall_site := _find_wall_site(first, r)
	if wall_site == Vector3.INF:
		_fail("could not find a valid wall site")
		return
	var wall_yaw := PI * 0.5
	_assert_ok(World.place_item(first.id(), "wall", wall_site, wall_yaw), "place rotated wall")
	var wall_item: Dictionary = World.placements[-1]
	if not is_equal_approx(float(wall_item["yaw"]), wall_yaw):
		_fail("wall yaw was not persisted")
		return
	var settlement := Settlement.new()
	add_child(settlement)
	settlement._add_placement(farm_item)
	settlement._add_placement(wall_item)
	var farm_node: Node3D = settlement._root.get_child(0)
	var wall_node: Node3D = settlement._root.get_child(1)
	if farm_node.name != "FarmPlot" or farm_node.position != farm_pos or not is_equal_approx(farm_node.rotation.y, farm_yaw):
		_fail("farm renderer ignored its persisted transform")
		return
	if wall_node.name != "Wall" or not is_equal_approx(wall_node.rotation.y, wall_yaw):
		_fail("wall renderer ignored its persisted yaw")
		return
	var cap := World.farm_capacity(first)
	while World.placement_count(first.id(), "farm") < cap:
		var farm_result := World.build_farm(first.id())
		if farm_result.contains("no open"):
			break
		_assert_ok(farm_result, "fill farm capacity")
	var farm_count := World.placement_count(first.id(), "farm")
	if farm_count > cap:
		_fail("farm capacity was exceeded")
		return
	var materials_before_limit: Dictionary = World.materials.duplicate()
	var full_result := World.build_farm(first.id())
	if not (full_result.contains("capacity") or full_result.contains("no open")):
		_fail("full farm site accepted another plot: " + full_result)
		return
	if World.materials != materials_before_limit:
		_fail("rejected farm charged materials")
		return
	var save_path := "user://settlement_test.save"
	SaveStore.erase(save_path)
	var snapshot := World.save_snapshot()
	if SaveStore.write(snapshot, save_path) != OK:
		_fail("could not write settlement snapshot")
		return
	var loaded := SaveStore.read(save_path)
	World.state.clear()
	World.supply_links.clear()
	World.placements.clear()
	for key in World.materials:
		World.materials[key] = 0
	if not World.restore_snapshot(loaded):
		_fail("could not restore settlement snapshot")
		return
	if not World.building_state(first.id()).get("claimed", false) or World.supply_links.size() != 1 \
			or World.placements.size() != snapshot["placements"].size() \
			or World.placements[0]["pos"] != snapshot["placements"][0]["pos"] \
			or not PropSalvage.is_salvaged(first.id(), salvage_prop.id):
		_fail("restored snapshot lost typed settlement state")
		return
	SaveStore.erase(save_path)
	print("SETTLEMENT OK  materials=", World.material_summary(), "  links=", World.supply_links.size(), "  placements=", World.placements.size())
	get_tree().quit(0)


func _find_wall_site(b: BuildingData, r: Rect2) -> Vector3:
	var z := r.position.y + 1.0
	while z < r.end.y - 1.0:
		var x := r.position.x + 1.0
		while x < r.end.x - 1.0:
			var p := Vector3(x, 0.05, z)
			if World.placement_error(b.id(), "wall", p, PI * 0.5) == "":
				return p
			x += 1.0
		z += 1.0
	return Vector3.INF


func _assert_ok(msg: String, step: String) -> void:
	if msg.begins_with("need ") or msg.contains("before") or msg.contains("only") or msg.contains("no viable"):
		_fail("%s failed: %s" % [step, msg])


func _fail(msg: String) -> void:
	push_error("SETTLEMENT FAIL: " + msg)
	get_tree().quit(1)
