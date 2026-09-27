extends Node
## End-to-end room reward regression: a clear room suspends route typing, persists every
## carryable prop, and advances the presentation counter only as its tokens arrive.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	await get_tree().process_frame
	var main: Node = get_parent()
	World.persistence_enabled = false
	main._cancel_room_rewards()
	main.interior.unload()
	main.settlement.leave()
	World.state.clear()
	World.backpack.clear()
	var candidate := _find_room_with_loot()
	if candidate.is_empty():
		return _fail("no generated room with loot found")
	var b: BuildingData = candidate["building"]
	var ri: int = candidate["room"]
	var prop: FloorPlan.Prop = candidate["prop"]
	main.mode = 2 # Main.Mode.INSIDE
	main.interior.enter(b, 0)
	main.interior.set_room(ri)
	main.interior.mark_room_cleared(ri)
	main._schedule_room_rewards(ri, 0.01)
	if not main._loot_collecting:
		return _fail("clear room did not begin its automatic reward beat")
	if main.typist.prompts().map(func(p): return p["word"]).has("loot"):
		return _fail("automatic reward still exposed a typed LOOT prompt")
	var frames := 0
	while main._loot_collecting and frames < 600:
		frames += 1
		await get_tree().process_frame
	if main._loot_collecting:
		return _fail("automatic reward sequence never completed")
	if not PropLoot.is_looted(b.id(), prop.id):
		return _fail("room reward did not persist the searched prop")
	if World.backpack_units() <= 0:
		return _fail("room reward did not add supplies to the backpack")
	if main.loot_flyover._displayed_units != World.backpack_units():
		return _fail("HUD backpack count did not land in step with the final icon")
	print("AUTO LOOT OK  bouncing room supplies -> world-to-HUD flight -> %s" % World.backpack_summary())
	get_tree().quit(0)


func _find_room_with_loot() -> Dictionary:
	for sy in range(-1, 2):
		for sx in range(-1, 2):
			for b in World.get_sector(sx, sy).buildings:
				var fp := InteriorGen.generate(World.seed, b, 0)
				for prop in fp.props:
					if prop.loot_table != "":
						return {"building": b, "room": prop.room, "prop": prop}
	return {}


func _fail(message: String) -> void:
	push_error("AUTO LOOT FAIL: " + message)
	get_tree().quit(1)
