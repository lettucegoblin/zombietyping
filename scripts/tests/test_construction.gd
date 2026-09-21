extends Node
## Focused UX regression for build previews, confirmation, cancellation, and refunds.

class FakeBuilder extends Node3D:
	var facing := Vector3(1, 0, 0)


func _ready() -> void:
	World.persistence_enabled = false
	World.state.clear()
	World.placements.clear()
	for key in World.materials:
		World.materials[key] = 0
	var b: BuildingData = World.get_sector(0, 0).buildings[0]
	World.set_building_state(b.id(), "claimed", true)
	World.set_building_state(b.id(), "fortified", true)
	World.set_building_state(b.id(), "warded", true)
	World.add_materials({ "wood": 10, "building_materials": 20, "tools": 4, "zombie_matter": 20 })
	var safe := World.safe_rect_world(b)
	var target := Vector3(safe.get_center().x, 0.05, safe.get_center().y)
	var builder := FakeBuilder.new()
	add_child(builder)
	builder.global_position = target - builder.facing * 2.6
	var settlement := Settlement.new()
	add_child(settlement)
	settlement.configure(builder)
	settlement.active_building_id = b.id()
	settlement.build_index = Settlement.BUILD_KINDS.find("crate")
	var toggle_msg := settlement.toggle_build()
	settlement._update_ghost()
	if not toggle_msg.contains("build mode on") or not settlement._ghost_root.visible or not settlement.ghost_is_valid():
		_fail("valid placement ghost did not appear: " + settlement.ghost_error())
		return
	var yaw_before := settlement._ghost_root.rotation.y
	settlement.rotate_preview()
	if not is_equal_approx(absf(settlement._ghost_root.rotation.y - yaw_before), PI * 0.5):
		_fail("preview rotation did not advance 90 degrees")
		return
	var wood_before := int(World.materials["wood"])
	var place_msg := settlement.place_selected()
	if not place_msg.contains("placed") or World.placements.size() != 1 \
			or int(World.materials["wood"]) != wood_before - 2:
		_fail("confirmed preview did not spend and place exactly once: " + place_msg)
		return
	if settlement.ghost_is_valid() or not settlement.ghost_error().contains("overlaps"):
		_fail("ghost did not turn invalid over the newly placed object")
		return
	var undo_msg := settlement.undo_or_dismantle_last()
	if not undo_msg.contains("full refund") or not World.placements.is_empty() \
			or int(World.materials["wood"]) != wood_before:
		_fail("short undo did not restore the full cost: " + undo_msg)
		return
	settlement._update_ghost()
	if not settlement.ghost_is_valid():
		_fail("ghost remained invalid after undo: " + settlement.ghost_error())
		return
	_assert_placed(settlement.place_selected(), "second crate")
	settlement._undo_until_msec = 0
	var dismantle_msg := settlement.undo_or_dismantle_last()
	if not dismantle_msg.contains("50% rounded-up") or int(World.materials["wood"]) != wood_before - 1:
		_fail("late dismantle did not return the documented partial refund: " + dismantle_msg)
		return
	var cancel_wood := int(World.materials["wood"])
	var cancel_msg := settlement.cancel_build()
	if not cancel_msg.contains("no materials spent") or settlement._ghost_root.visible \
			or int(World.materials["wood"]) != cancel_wood:
		_fail("cancel did not hide the preview without spending")
		return
	var upstairs_farm := World.placement_error(b.id(), "farm", Vector3(target.x, World.FLOOR_M + 0.05, target.z), 0.0)
	if not upstairs_farm.contains("ground floor"):
		_fail("an upstairs farm preview was accepted: " + upstairs_farm)
		return
	var initial_cells := World.ward_cell_count(b.id())
	var r := World.safe_rect_world(b)
	var x := r.position.x + World.WARD_GRID * 0.5
	var y := r.position.y
	var extension := [
		{ "building": b.id(), "kind": "wall", "pos": Vector3(r.position.x, 0.05, y - World.WARD_GRID * 0.5), "yaw": PI * 0.5 },
		{ "building": b.id(), "kind": "wall", "pos": Vector3(r.position.x + World.WARD_GRID, 0.05, y - World.WARD_GRID * 0.5), "yaw": PI * 0.5 },
		{ "building": b.id(), "kind": "wall", "pos": Vector3(x, 0.05, y - World.WARD_GRID), "yaw": 0.0 },
	]
	World.placements.append(extension[0])
	World.placements.append(extension[1])
	World.settlement_changed.emit()
	if World.ward_cell_count(b.id()) != initial_cells:
		_fail("an open wall run incorrectly created safe territory")
		return
	World.placements.append(extension[2])
	World.settlement_changed.emit()
	var extension_center := Vector2(x, y - World.WARD_GRID * 0.5)
	if World.ward_cell_count(b.id()) != initial_cells + 1 or not World.ward_contains_point(b.id(), extension_center):
		_fail("closing wall segment did not procedurally expand the ward")
		return
	print("CONSTRUCTION OK  ghost/rotate/confirm/cancel/refunds/permanent-ward-expansion")
	get_tree().quit(0)


func _assert_placed(msg: String, step: String) -> void:
	if not msg.contains("placed"):
		_fail("%s failed: %s" % [step, msg])


func _fail(msg: String) -> void:
	push_error("CONSTRUCTION FAIL: " + msg)
	get_tree().quit(1)
