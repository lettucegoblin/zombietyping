class_name PropSalvage
## Object-level dismantling for stable generated furniture IDs. The interior generator
## remains pure; only the sparse set of removed prop IDs and recovered materials is saved.


static func material_yield(kind: String) -> Dictionary:
	match kind:
		"bed": return { "wood": 2, "textiles": 2 }
		"sofa": return { "wood": 2, "textiles": 2 }
		"rug": return { "textiles": 2 }
		"painting": return { "wood": 1, "textiles": 1 }
		"dresser", "nightstand", "cabinet", "shelf", "desk", "counter", "bench": return { "wood": 2 }
		"chair": return { "wood": 1, "textiles": 1 }
		"crate": return { "wood": 2, "building_materials": 1 }
		"fridge": return { "metal": 3, "electronics": 1 }
		"tv": return { "electronics": 3, "metal": 1 }
		"stove": return { "metal": 3, "electronics": 1 }
		"sink", "toilet", "tub": return { "metal": 2, "building_materials": 1 }
		_: return { "building_materials": 1 }


static func is_salvaged(building_id: String, prop_id: String) -> bool:
	var st: Dictionary = World.state.get(building_id, {})
	return (st.get("salvaged_props", {}) as Dictionary).has(prop_id)


static func salvage(building_id: String, prop: FloorPlan.Prop) -> String:
	var st := World.building_state(building_id)
	if not st.get("cleared", false):
		return "clear the building before dismantling furniture"
	var removed: Dictionary = st.get("salvaged_props", {})
	if removed.has(prop.id):
		return "%s is already dismantled" % prop.kind
	removed[prop.id] = true
	st["salvaged_props"] = removed
	var recovered := material_yield(prop.kind)
	World.add_materials(recovered)
	World.state_changed.emit(building_id)
	return "dismantled %s: %s" % [prop.kind, World.cost_text(recovered)]


static func hint(prop: FloorPlan.Prop) -> String:
	return "X dismantle %s → %s" % [prop.kind, World.cost_text(material_yield(prop.kind))]
