class_name Workforce
extends RefCounted
## Pure settlement-work rules. World owns clocks, inventories and persistence; this file
## turns a base's real residents, farms and intact procedural utilities into one cycle's
## output without creating a second economy.

const JOBS := ["farmer", "scavenger", "builder", "mechanic", "medic"]
const SCAVENGE_MATERIALS := ["wood", "metal", "building_materials", "textiles"]


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
	var counts: Dictionary = {}
	for job in JOBS:
		counts[job] = 0
	var skilled_growers: int = 0
	var scavengers: Array[String] = []
	for survivor_id in st.get("resident_ids", []):
		var person: Dictionary = roster.get(str(survivor_id), {})
		var job: String = str(person.get("job", "unassigned"))
		if not JOBS.has(job):
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
		output["food"] = tended_farms * 2 + mini(skilled_growers, tended_farms)
	for i in scavengers.size():
		var roll := Det.h3(world_seed, b.seed_hash, cycle, i, 1301)
		var material: String = SCAVENGE_MATERIALS[posmod(roll, SCAVENGE_MATERIALS.size())]
		output[material] = int(output.get(material, 0)) + 1

	var stats: Dictionary = profile["stats"]
	var rooms: Dictionary = profile["rooms"]
	var builders: int = int(counts["builder"])
	if builders > 0 and (int(rooms.get("workshop", 0)) > 0 or int(stats.get("storage", 0)) > 0):
		output["building_materials"] = int(output.get("building_materials", 0)) + builders
	var mechanics: int = int(counts["mechanic"])
	if mechanics > 0 and int(stats.get("power", 0)) > 0 and int(rooms.get("workshop", 0)) > 0:
		if cycle % 2 == 0:
			output["tools"] = mechanics
		if cycle % 3 == 0:
			output["vehicle_parts"] = mechanics
	var medics: int = int(counts["medic"])
	if medics > 0 and int(stats.get("water", 0)) > 0 and int(stats.get("storage", 0)) > 0 and cycle % 2 == 0:
		output["medicine"] = medics
	return {
		"output": output,
		"jobs": counts,
		"farm_count": farm_count,
		"tended_farms": tended_farms,
		"facility_role": profile["role_label"],
	}
