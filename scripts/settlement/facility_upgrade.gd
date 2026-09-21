class_name FacilityUpgrade
extends RefCounted
## Costs and readable effects for upgrades locked to a building's procedural facility role.

const MAX_LEVEL := 3


static func cost(role_id: String, next_level: int) -> Dictionary:
	var level := clampi(next_level, 1, MAX_LEVEL)
	var out := { "building_materials": 6 * level, "tools": level }
	match role_id:
		"shelter":
			out["wood"] = 3 * level
			out["textiles"] = 2 * level
		"depot":
			out["wood"] = 2 * level
			out["metal"] = 2 * level
		"workshop":
			out["metal"] = 4 * level
			out["electronics"] = level
		"kitchen":
			out["wood"] = 2 * level
			out["metal"] = 2 * level
		"operations":
			out["metal"] = 2 * level
			out["electronics"] = 3 * level
	return out


static func effect_text(role_id: String, level: int) -> String:
	if level <= 0:
		return "no facility upgrade installed"
	match role_id:
		"shelter": return "+%d medicine from staffed care" % level
		"depot": return "+%d material per scavenger" % level
		"workshop": return "+%d builder/mechanic output" % level
		"kitchen": return "+%d food per tended plot" % level
		"operations": return "+%d coordinated electronics" % level
	return "level %d facility output" % level
