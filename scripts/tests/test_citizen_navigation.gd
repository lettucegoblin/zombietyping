extends Node
## Focused regression for deterministic yard routing and citizen position preservation.

const CitizenNav = preload("res://scripts/settlement/citizen_navigation.gd")
const ResidentVisuals = preload("res://scripts/settlement/resident_visuals.gd")


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	await get_tree().process_frame
	World.state.clear()
	World.placements.clear()
	if ResidentVisuals.pixel_size("adult") * 88.0 < 1.75 \
			or ResidentVisuals.pixel_size("grandma") * 97.0 < 1.75 \
			or ResidentVisuals.pixel_size("grandpa") * 95.0 < 1.75:
		_fail("human resident art is still shorter than an adult eye-height scale")
		return
	var b: BuildingData = World.get_sector(0, 0).buildings[0]
	var safe := World.safe_rect_world(b)
	var structure := World.building_rect_world(b)
	var placements: Array[Dictionary] = [
		{
			"building": b.id(), "kind": "farm",
			"pos": Vector3(structure.get_center().x, 0.05, (safe.position.y + structure.position.y) * 0.5),
			"yaw": 0.0,
		},
		{
			"building": b.id(), "kind": "wall",
			"pos": Vector3(structure.get_center().x, 0.05, (structure.end.y + safe.end.y) * 0.5),
			"yaw": PI * 0.5,
		},
		{
			"building": b.id(), "kind": "crate",
			"pos": Vector3((safe.position.x + structure.position.x) * 0.5, 0.05, structure.get_center().y),
			"yaw": 0.0,
		},
	]
	World.placements.assign(placements)
	var nav: RefCounted = CitizenNav.new(b, World.placements)
	if nav.is_walkable(structure.get_center()):
		_fail("claimed building was not treated as an obstacle")
		return
	for item in placements:
		var pos: Vector3 = item["pos"]
		if nav.is_walkable(Vector2(pos.x, pos.z)):
			_fail("%s was not treated as an obstacle" % item["kind"])
			return

	var start: Vector2 = nav.nearest_walkable(Vector2(safe.position.x + 1.0, structure.get_center().y))
	var finish: Vector2 = nav.nearest_walkable(Vector2(safe.end.x - 1.0, structure.get_center().y))
	var path: PackedVector2Array = nav.route(start, finish)
	if path.size() < 3:
		_fail("route did not navigate around the building")
		return
	if not _route_is_clear(nav, path):
		return
	var same_path: PackedVector2Array = nav.route(start, finish)
	if path != same_path:
		_fail("identical navigation inputs produced different routes")
		return

	# A settlement rebuild used to respawn every citizen at the building centre. Preserve
	# their exact walkable position across unrelated material/state redraws instead.
	var resident_id := "nav-test-resident"
	World.survivors[resident_id] = {
		"id": resident_id, "name": "Mara", "trait": "builder", "job": "builder",
		"archetype": "cat", "species": "cat",
		"base_id": b.id(), "home_id": b.id(), "home_slot": 3, "schedule_offset": 0,
	}
	World.state[b.id()] = { "fortified": true, "claimed": true, "citizens": 1, "founders": 0, "resident_ids": [resident_id] }
	var settlement := Settlement.new()
	add_child(settlement)
	settlement._rebuild(b.sector)
	if settlement._citizens.size() != 1:
		_fail("test settlement did not generate its citizen")
		return
	var citizen: Node3D = settlement._citizens[0]
	if not (citizen.get_node_or_null("Sprite") is Sprite3D):
		_fail("resident still uses placeholder geometry instead of a pixel person")
		return
	if citizen.get_meta("archetype", "") != "cat" or float(citizen.get_meta("sprite_rest_y", 9.0)) >= 0.5:
		_fail("animal resident did not use quadruped scale and placement")
		return
	if int(citizen.get_meta("home_slot", -1)) != 3 or str(citizen.get_meta("schedule", "")) == "":
		_fail("resident home or schedule metadata was not applied")
		return
	citizen.position = Vector3(start.x, 0.0, start.y)
	var before := citizen.position
	settlement._rebuild(b.sector)
	var rebuilt: Node3D = settlement._citizens[0]
	if rebuilt.position.distance_to(before) > 0.001:
		_fail("unrelated rebuild reset citizen position from %s to %s" % [before, rebuilt.position])
		return
	var pet_response := settlement.pet_nearest(rebuilt.global_position, 0.5)
	if not pet_response.contains("Mara") or not settlement.last_interaction_world \
			or not (rebuilt.get_node_or_null("SpeechBubble") is Label3D):
		_fail("nearby animal could not be petted with character-anchored feedback")
		return
	var live_nav: RefCounted = settlement._citizen_navigation[b.id()]
	for i in 600:
		settlement._move_citizens(0.1)
		var p := Vector2(rebuilt.position.x, rebuilt.position.z)
		if not live_nav.is_walkable(p):
			_fail("citizen entered blocked geometry while walking at step %d" % i)
			return

	print("CITIZEN NAVIGATION OK  corners=", path.size())
	World.survivors.erase(resident_id)
	get_tree().quit(0)


func _route_is_clear(nav: RefCounted, path: PackedVector2Array) -> bool:
	for i in range(path.size() - 1):
		var a := path[i]
		var b := path[i + 1]
		var steps := maxi(1, ceili(a.distance_to(b) / 0.12))
		for step in range(steps + 1):
			var p := a.lerp(b, float(step) / steps)
			if not nav.is_walkable(p):
				_fail("route crossed blocked geometry at %s" % p)
				return false
	return true


func _fail(msg: String) -> void:
	push_error("CITIZEN NAVIGATION FAIL: " + msg)
	get_tree().quit(1)
