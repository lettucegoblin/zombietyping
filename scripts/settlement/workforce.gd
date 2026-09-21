class_name Workforce
extends RefCounted
## Pure settlement-work rules. World owns clocks, inventories and persistence; this file
## turns a base's real residents, farms and intact procedural utilities into one cycle's
## output without creating a second economy.

const JOBS := ["farmer", "scavenger", "builder", "mechanic", "medic"]
const SCAVENGE_MATERIALS := ["wood", "metal", "building_materials", "textiles"]
const UpgradeRules = preload("res://scripts/settlement/facility_upgrade.gd")


static func suggested_job(survivor_trait: String, profile: Dictionary, farm_count: int) -> String:
	var stats: Dictionary = profile.get("stats", {})
	var rooms: Dictionary = profile.get("rooms", {})
	match survivor_trait:
		"grower", "cook":
			if farm_count > 0:
				return "farmer"
		"mechanic":
			if int(stats.get("power", 0)) > 0 and int(rooms.get("workshop", 0)) > 0:
				return "mechanic"
		"medic":
			if int(stats.get("water", 0)) > 0:
				return "medic"
		"builder":
			return "builder"
		"scout", "radio operator", "teacher":
			return "scavenger"
	if farm_count > 0:
		return "farmer"
	if int(rooms.get("workshop", 0)) > 0:
		return "builder"
	return "scavenger"


static func produce(world_seed: int, b: BuildingData, st: Dictionary, roster: Dictionary,
		farm_count: int, cycle: int) -> Dictionary:
	var profile: Dictionary = FacilityProfile.derive(world_seed, b, st)
	var upgrade_level: int = int(profile.get("upgrade_level", 0)) if profile.get("upgrade_operational", false) else 0
	var role_id: String = str(profile.get("role_id", ""))
	var counts: Dictionary = {}
	for job in JOBS:
		counts[job] = 0
	var skilled_growers: int = 0
	var scavengers: Array[String] = []
	var unavailable := 0
	var resident_index := 0
	for survivor_id in st.get("resident_ids", []):
		var person: Dictionary = roster.get(str(survivor_id), {})
		var job: String = str(person.get("job", "unassigned"))
		if not JOBS.has(job):
			continue
		var unfit := int(person.get("health", 100)) <= 30 or int(person.get("hunger", 0)) >= 90
		var demoralized := int(person.get("morale", 70)) < 35 and (cycle + resident_index) % 2 == 0
		resident_index += 1
		if unfit or demoralized:
			unavailable += 1
			continue
		counts[job] = int(counts[job]) + 1
		if job == "farmer" and str(person.get("trait", "")) in ["grower", "cook"]:
			skilled_growers += 1
		if job == "scavenger":
			scavengers.append(str(survivor_id))
	# The first base's anonymous founder keeps one plot alive or scavenges until named
	# survivors arrive. Expansion bases receive no free labour.
	var founders: int = int(st.get("founders", 0))
	if founders > 0:
		counts["farmer" if farm_count > 0 else "scavenger"] += founders
		if farm_count <= 0:
			for i in founders:
				scavengers.append("founder:%s:%d" % [b.id(), i])

	var output: Dictionary = {}
	var tended_farms: int = mini(farm_count, int(counts["farmer"]) * 2)
	if tended_farms > 0:
		var kitchen_bonus: int = upgrade_level if role_id == "kitchen" else 0
		output["food"] = tended_farms * (2 + kitchen_bonus) + mini(skilled_growers, tended_farms)
	for i in scavengers.size():
		var roll := Det.h3(world_seed, b.seed_hash, cycle, i, 1301)
		var material: String = SCAVENGE_MATERIALS[posmod(roll, SCAVENGE_MATERIALS.size())]
		output[material] = int(output.get(material, 0)) + 1 + (upgrade_level if role_id == "depot" else 0)
	if role_id == "operations" and upgrade_level > 0 and not scavengers.is_empty() and cycle % 2 == 0:
		output["electronics"] = int(output.get("electronics", 0)) + upgrade_level

	var stats: Dictionary = profile["stats"]
	var rooms: Dictionary = profile["rooms"]
	var builders: int = int(counts["builder"])
	if builders > 0 and (int(rooms.get("workshop", 0)) > 0 or int(stats.get("storage", 0)) > 0):
		output["building_materials"] = int(output.get("building_materials", 0)) + builders * (1 + (upgrade_level if role_id == "workshop" else 0))
	var mechanics: int = int(counts["mechanic"])
	if mechanics > 0 and int(stats.get("power", 0)) > 0 and int(rooms.get("workshop", 0)) > 0:
		var mechanic_output: int = mechanics * (1 + (upgrade_level if role_id == "workshop" else 0))
		if cycle % 2 == 0:
			output["tools"] = mechanic_output
		if cycle % 3 == 0:
			output["vehicle_parts"] = mechanic_output
	var medics: int = int(counts["medic"])
	if medics > 0 and int(stats.get("water", 0)) > 0 and int(stats.get("storage", 0)) > 0 and cycle % 2 == 0:
		output["medicine"] = medics * (1 + (upgrade_level if role_id == "shelter" else 0))
	return {
		"output": output,
		"jobs": counts,
		"farm_count": farm_count,
		"tended_farms": tended_farms,
		"facility_role": profile["role_label"],
		"upgrade_level": upgrade_level,
		"unavailable": unavailable,
	}
