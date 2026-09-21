class_name FacilityProfile
extends RefCounted
## Read-only interpretation of a procedural building's room program and still-intact
## furnishings. Profiles never create resources or mutable facility state: dismantling a
## stable prop simply removes its contribution the next time this profile is derived.

const STAT_ORDER := ["beds", "storage", "water", "power", "comfort"]
const STAT_LABEL := {
	"beds": "beds",
	"storage": "storage",
	"water": "water",
	"power": "power",
	"comfort": "comfort",
}
const ROOM_LABEL := {
	"bedroom": "bed",
	"bathroom": "bath",
	"kitchen": "kitchen",
	"storage": "storage",
	"workshop": "workshop",
	"office": "office",
	"conference": "conference",
	"sales": "sales",
	"living": "living",
	"dining": "dining",
	"lobby": "lobby",
}

# Scores choose a deterministic best use from the authored building kind, generated room
# program, and intact utility props. Requirements only explain readiness; they do not spend
# resources or unlock a second economy.
const ROLE_RULES := [
	{
		"id": "shelter", "label": "Shelter",
		"kind": { "apartments": 9.0, "house": 8.0, "office": 1.0 },
		"rooms": { "bedroom": 3.0, "bathroom": 1.0, "living": 1.0 },
		"stats": { "beds": 3.0, "comfort": 0.55, "water": 0.4 },
		"requires": { "beds": 2, "water": 1 }, "room_requires": {},
	},
	{
		"id": "depot", "label": "Supply depot",
		"kind": { "warehouse": 9.0, "shop": 5.0, "office": 1.0 },
		"rooms": { "storage": 3.0, "sales": 1.0, "workshop": 1.0 },
		"stats": { "storage": 2.2, "power": 0.25 },
		"requires": { "storage": 3 }, "room_requires": {},
	},
	{
		"id": "workshop", "label": "Workshop",
		"kind": { "warehouse": 5.0, "shop": 1.0, "office": 1.0 },
		"rooms": { "workshop": 6.0, "storage": 1.5 },
		"stats": { "power": 2.2, "storage": 0.8 },
		"requires": { "power": 1, "storage": 2 }, "room_requires": { "workshop": 1 },
	},
	{
		"id": "kitchen", "label": "Community kitchen",
		"kind": { "house": 2.0, "apartments": 2.0, "shop": 1.0 },
		"rooms": { "kitchen": 6.0, "dining": 3.0, "living": 0.5 },
		"stats": { "power": 1.8, "water": 1.8, "storage": 0.3 },
		"requires": { "power": 1, "water": 1 }, "room_requires": { "kitchen": 1 },
	},
	{
		"id": "operations", "label": "Operations center",
		"kind": { "office": 9.0, "shop": 1.0, "warehouse": 1.0 },
		"rooms": { "office": 3.0, "conference": 3.0, "lobby": 2.0 },
		"stats": { "power": 1.4, "storage": 0.65, "comfort": 0.25 },
		"requires": { "power": 1, "storage": 1 }, "room_requires": { "office": 1 },
	},
]


static func derive(world_seed: int, b: BuildingData, st: Dictionary = {}) -> Dictionary:
	var stats := { "beds": 0, "storage": 0, "water": 0, "power": 0, "comfort": 0 }
	var rooms: Dictionary = {}
	var prop_kinds: Dictionary = {}
	var removed: Dictionary = st.get("salvaged_props", {})
	var generated := 0
	var dismantled := 0
	for floor in b.floors:
		var fp := InteriorGen.generate(world_seed, b, floor)
		for room in fp.rooms:
			if room.is_stair:
				continue
			rooms[room.kind] = int(rooms.get(room.kind, 0)) + 1
		for prop in fp.props:
			generated += 1
			if removed.has(prop.id):
				dismantled += 1
				continue
			prop_kinds[prop.kind] = int(prop_kinds.get(prop.kind, 0)) + 1
			if prop.kind == "bed":
				stats["beds"] += 1
			if stats.has(prop.utility):
				stats[prop.utility] += 1
	var roles: Array[Dictionary] = []
	for rule in ROLE_RULES:
		var score := float((rule["kind"] as Dictionary).get(b.kind, 0.0))
		for room_kind in rule["rooms"]:
			score += int(rooms.get(room_kind, 0)) * float(rule["rooms"][room_kind])
		for stat in rule["stats"]:
			score += int(stats.get(stat, 0)) * float(rule["stats"][stat])
		roles.append({ "id": rule["id"], "label": rule["label"], "score": score, "rule": rule })
	roles.sort_custom(func(a, c):
		return a["id"] < c["id"] if is_equal_approx(a["score"], c["score"]) else a["score"] > c["score"]
	)
	var primary: Dictionary = roles[0]
	var locked_role := str(st.get("facility_role", ""))
	if locked_role != "":
		for candidate in roles:
			if candidate["id"] == locked_role:
				primary = candidate
				break
	var missing := _missing_requirements(primary["rule"], stats, rooms)
	var cleared := bool(st.get("cleared", false))
	var claimed := bool(st.get("claimed", false))
	var upgrade_level := clampi(int(st.get("facility_level", 0)), 0, 3)
	var readiness := "clear to survey intact utilities"
	var readiness_kind := "unknown"
	if cleared and not missing.is_empty():
		readiness = ("upgrade offline · " if upgrade_level > 0 else "needs ") + " · ".join(missing)
		readiness_kind = "needs"
	elif cleared and claimed and upgrade_level > 0:
		readiness = "level %d operational" % upgrade_level
		readiness_kind = "operational"
	elif cleared and claimed:
		readiness = "upgrade-ready from intact utilities"
		readiness_kind = "ready"
	elif cleared:
		readiness = "role-ready · claim to activate"
		readiness_kind = "available"
	return {
		"building_id": b.id(),
		"role_id": primary["id"],
		"role_label": primary["label"],
		"role_score": primary["score"],
		"alternative_label": roles[1]["label"],
		"stats": stats,
		"rooms": rooms,
		"prop_kinds": prop_kinds,
		"generated_props": generated,
		"intact_props": generated - dismantled,
		"dismantled_props": dismantled,
		"missing": missing,
		"cleared": cleared,
		"claimed": claimed,
		"upgrade_ready": cleared and claimed and missing.is_empty(),
		"upgrade_level": upgrade_level,
		"upgrade_operational": cleared and claimed and upgrade_level > 0 and missing.is_empty(),
		"readiness": readiness,
		"readiness_kind": readiness_kind,
	}


static func _missing_requirements(rule: Dictionary, stats: Dictionary, rooms: Dictionary) -> Array[String]:
	var missing: Array[String] = []
	for stat in rule["requires"]:
		var need: int = rule["requires"][stat]
		var have: int = stats.get(stat, 0)
		if have < need:
			missing.append("%d %s" % [need - have, STAT_LABEL.get(stat, stat)])
	for room in rule["room_requires"]:
		var need: int = rule["room_requires"][room]
		var have: int = rooms.get(room, 0)
		if have < need:
			missing.append("%d %s room" % [need - have, ROOM_LABEL.get(room, room)])
	return missing


static func program_text(profile: Dictionary, max_items: int = 4) -> String:
	var parts: Array[String] = []
	for room in ["bedroom", "bathroom", "kitchen", "storage", "workshop", "office", "conference", "sales", "living", "dining", "lobby"]:
		var count: int = profile["rooms"].get(room, 0)
		if count > 0:
			parts.append("%d %s" % [count, ROOM_LABEL.get(room, room)])
			if parts.size() >= max_items:
				break
	return " · ".join(parts) if not parts.is_empty() else "open floor plan"


static func utility_lines(profile: Dictionary) -> Array[String]:
	var stats: Dictionary = profile["stats"]
	return [
		"beds %d  ·  storage %d  ·  water %d" % [stats["beds"], stats["storage"], stats["water"]],
		"power %d  ·  comfort %d  ·  intact %d/%d" % [stats["power"], stats["comfort"], profile["intact_props"], profile["generated_props"]],
	]
