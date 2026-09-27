extends Node
## Regression benchmark for the spikes that used to scale with building height. This is
## intentionally timing-light: correctness counters enforce the optimization, while the
## printed timings make future profiling comparable across machines.

var _failed := false


func _ready() -> void:
	World.persistence_enabled = false
	World.state.clear()
	var tallest := _tallest_nearby_building()
	_check(tallest != null, "could not find a generated building")
	if tallest == null:
		get_tree().quit(1)
		return
	_check(tallest.floors >= 5, "fixture has no tall building to exercise")
	_check(_check_furnishing_variety(), "procedural bedrooms lacked scaled storage, varied rugs, posters, or consoles")

	InteriorGen.clear_cache()
	var cold_start := Time.get_ticks_usec()
	var first_plans: Array[FloorPlan] = []
	for floor in tallest.floors:
		first_plans.append(InteriorGen.generate(World.seed, tallest, floor))
	var cold_us := Time.get_ticks_usec() - cold_start
	var after_cold := InteriorGen.cache_stats()
	_check(int(after_cold["misses"]) == tallest.floors, "cold generation did not miss exactly once per floor")

	var repeats := 60
	var warm_start := Time.get_ticks_usec()
	for repeat in repeats:
		for floor in tallest.floors:
			var reused := InteriorGen.generate(World.seed, tallest, floor)
			_check(reused == first_plans[floor], "cached floor plan was regenerated")
	var warm_us := Time.get_ticks_usec() - warm_start
	var after_warm := InteriorGen.cache_stats()
	_check(int(after_warm["misses"]) == tallest.floors, "warm floor access added generator misses")
	_check(int(after_warm["hits"]) >= repeats * tallest.floors, "warm floor access did not hit the cache")
	_check(warm_us < cold_us, "cached repeated generation was not faster than one cold building")

	var interior = load("res://scripts/interior/interior.gd").new()
	add_child(interior)
	var entry_start := Time.get_ticks_usec()
	interior.enter(tallest, 0)
	var entry_us := Time.get_ticks_usec() - entry_start
	var progress_start := Time.get_ticks_usec()
	for i in 120:
		interior.progress()
	var progress_us := Time.get_ticks_usec() - progress_start
	var after_progress := InteriorGen.cache_stats()
	_check(int(after_progress["misses"]) == tallest.floors, "HUD progress regenerated a cached tall-building floor")
	interior.unload()
	interior.queue_free()

	print("PERFORMANCE OK  tallest=%s floors=%d cold_plans=%.2fms warm_60x=%.2fms entry_mesh=%.2fms progress_120x=%.2fms" % [
		tallest.id(), tallest.floors, cold_us / 1000.0, warm_us / 1000.0,
		entry_us / 1000.0, progress_us / 1000.0,
	])
	get_tree().quit(1 if _failed else 0)


func _tallest_nearby_building() -> BuildingData:
	var tallest: BuildingData
	for sy in range(-2, 3):
		for sx in range(-2, 3):
			for building in World.get_sector(sx, sy).buildings:
				if tallest == null or building.floors > tallest.floors:
					tallest = building
	return tallest


func _check_furnishing_variety() -> bool:
	var large_dresser := false
	var poster := false
	var console := false
	var rug_sizes := {}
	for sy in range(-1, 2):
		for sx in range(-1, 2):
			for building in World.get_sector(sx, sy).buildings:
				var plan := InteriorGen.generate(World.seed, building, 0)
				for prop in plan.props:
					if prop.kind == "dresser" and prop.size.x >= 1.30:
						large_dresser = true
					elif prop.kind in ["poster_space", "poster_band"]:
						poster = true
						if InteriorGen.prop_overlaps_door_clearance(plan, prop):
							return false
					elif prop.kind == "game_console":
						console = true
					elif prop.kind == "rug":
						rug_sizes[Vector2(snappedf(prop.size.x, 0.05), snappedf(prop.size.z, 0.05))] = true
	return large_dresser and poster and console and rug_sizes.size() >= 3


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error("PERFORMANCE FAIL: " + message)
