class_name PropLoot
## Deterministic, container-by-container loot. Contents are regenerated from the world seed
## and stable prop id; persistence only needs to remember which containers were searched.

const ITEM_LABELS := {
	"packaged_food": "packaged food",
	"bandages": "bandages",
	"cloth_bundle": "cloth bundle",
	"batteries": "batteries",
	"circuits": "circuits",
	"utensils": "utensils",
	"tool_kit": "tool kit",
	"fasteners": "fasteners",
	"fuel_can": "fuel can",
}

const TABLES := {
	"household": ["packaged_food", "bandages", "cloth_bundle", "batteries"],
	"electronics": ["circuits", "batteries", "circuits"],
	"kitchen": ["packaged_food", "packaged_food", "utensils", "bandages"],
	"tools": ["tool_kit", "fasteners", "fuel_can", "fasteners"],
}

const BREAKDOWN := {
	"packaged_food": { "food": 1 },
	"bandages": { "medicine": 1, "textiles": 1 },
	"cloth_bundle": { "textiles": 2 },
	"batteries": { "electronics": 1 },
	"circuits": { "electronics": 2 },
	"utensils": { "metal": 1 },
	"tool_kit": { "tools": 1, "metal": 1 },
	"fasteners": { "building_materials": 1, "metal": 1 },
	"fuel_can": { "fuel": 2, "metal": 1 },
}


static func contents(building_id: String, prop: FloorPlan.Prop) -> Dictionary:
	var pool: Array = TABLES.get(prop.loot_table, [])
	if pool.is_empty():
		return {}
	var rng := Det.rng_for(World.seed, building_id.hash(), prop.id.hash(), prop.loot_table.hash())
	var result := {}
	var rolls := 1 + rng.randi_range(0, 1)
	for _i in rolls:
		var item: String = pool[rng.randi_range(0, pool.size() - 1)]
		result[item] = int(result.get(item, 0)) + 1
	return result


static func is_looted(building_id: String, prop_id: String) -> bool:
	var st: Dictionary = World.state.get(building_id, {})
	return (st.get("looted_props", {}) as Dictionary).has(prop_id)


static func can_loot(building_id: String, prop: FloorPlan.Prop) -> bool:
	return prop.loot_table != "" and not is_looted(building_id, prop.id) \
		and not PropSalvage.is_salvaged(building_id, prop.id) \
		and World.can_collect_loot(contents(building_id, prop))


static func loot(building_id: String, prop: FloorPlan.Prop) -> String:
	if prop.loot_table == "":
		return "%s has nothing searchable" % prop.kind
	if is_looted(building_id, prop.id):
		return "%s already searched" % prop.kind
	var found := contents(building_id, prop)
	if not World.can_collect_loot(found):
		return "field kit and backpack full — need %d carried slots" % bundle_units(World.loot_overflow(found))
	World.collect_loot(found)
	var st := World.building_state(building_id)
	var searched: Dictionary = st.get("looted_props", {})
	searched[prop.id] = true
	st["looted_props"] = searched
	World.state_changed.emit(building_id)
	return "searched %s: %s" % [prop.kind, item_text(found)]


static func breakdown(bundle: Dictionary) -> Dictionary:
	var recovered := {}
	for item in bundle:
		var count := int(bundle[item])
		for material in (BREAKDOWN.get(item, {}) as Dictionary):
			recovered[material] = int(recovered.get(material, 0)) \
				+ int(BREAKDOWN[item][material]) * count
	return recovered


static func bundle_units(bundle: Dictionary) -> int:
	var total := 0
	for item in bundle:
		total += int(bundle[item])
	return total


static func item_text(bundle: Dictionary) -> String:
	var parts: Array[String] = []
	var keys := bundle.keys()
	keys.sort()
	for item in keys:
		parts.append("%s %d" % [ITEM_LABELS.get(item, str(item).replace("_", " ")), int(bundle[item])])
	return ", ".join(parts)
