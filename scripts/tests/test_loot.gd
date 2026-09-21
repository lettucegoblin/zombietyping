extends Node
## Procedural container, backpack-capacity, breakdown, and persistence regression.

const PropLootRules = preload("res://scripts/loot/prop_loot.gd")

var _failed := false


func _ready() -> void:
	World.persistence_enabled = false
	World.state.clear()
	World.backpack.clear()
	for key in World.materials:
		World.materials[key] = 0
	var candidate := _find_container()
	if candidate.is_empty():
		return _finish("no generated loot container found")
	var b: BuildingData = candidate["building"]
	var prop: FloorPlan.Prop = candidate["prop"]
	var first: Dictionary = PropLootRules.contents(b.id(), prop)
	var repeat: Dictionary = PropLootRules.contents(b.id(), prop)
	_check(not first.is_empty() and first == repeat, "container contents were not deterministic")
	_check(PropLootRules.bundle_units(first) <= 2, "single container exceeded the intended carry unit range")
	World.backpack = { "packaged_food": World.BACKPACK_CAPACITY }
	_check(not World.can_carry(first), "full backpack accepted another container")
	World.backpack.clear()

	var interior = load("res://scripts/interior/interior.gd").new()
	add_child(interior)
	interior.enter(b, 0)
	interior.set_room(prop.room)
	interior.mark_room_cleared(prop.room)
	var words: Array = interior.options().map(func(o): return o["word"])
	_check(words.has("loot"), "cleared room did not expose the typed loot action")
	var message: String = interior.loot_here(prop.pos)
	_check(message.begins_with("searched"), "container could not be searched: " + message)
	_check(PropLootRules.is_looted(b.id(), prop.id), "searched container id was not persisted")
	_check(World.backpack == first, "rolled items did not enter the backpack")
	_check(PropLootRules.loot(b.id(), prop).contains("already"), "container could be looted twice")

	var snapshot := World.save_snapshot()
	World.backpack.clear()
	World.state.clear()
	_check(World.restore_snapshot(snapshot), "loot snapshot could not be restored")
	_check(World.backpack == first and PropLootRules.is_looted(b.id(), prop.id), "snapshot lost carried or searched loot")
	var expected: Dictionary = PropLootRules.breakdown(first)
	var breakdown_message := World.break_down_backpack()
	_check(breakdown_message.begins_with("sorted"), "backpack did not break down at base")
	_check(World.backpack.is_empty(), "breakdown did not empty backpack")
	for material in expected:
		_check(int(World.materials[material]) == int(expected[material]), "wrong breakdown yield for " + material)
	interior.queue_free()
	_finish("")


func _find_container() -> Dictionary:
	for sy in range(-1, 2):
		for sx in range(-1, 2):
			for b in World.get_sector(sx, sy).buildings:
				var fp := InteriorGen.generate(World.seed, b, 0)
				for prop in fp.props:
					if prop.loot_table != "":
						return { "building": b, "prop": prop }
	return {}


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error("LOOT FAIL: " + message)


func _finish(message: String) -> void:
	if message != "":
		_check(false, message)
	if not _failed:
		print("LOOT OK  ", World.backpack_summary(), "  materials ", World.material_summary())
	get_tree().quit(1 if _failed else 0)
