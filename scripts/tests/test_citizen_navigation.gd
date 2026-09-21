extends Node
## Focused regression for deterministic yard routing and citizen position preservation.

const CitizenNav = preload("res://scripts/settlement/citizen_navigation.gd")


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	await get_tree().process_frame
	World.state.clear()
	World.placements.clear()
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
	World.state[b.id()] = { "fortified": true, "claimed": true, "citizens": 1 }
	var settlement := Settlement.new()
	add_child(settlement)
	settlement._rebuild(b.sector)
	if settlement._citizens.size() != 1:
		_fail("test settlement did not generate its citizen")
		return
	var citizen: Node3D = settlement._citizens[0]
	citizen.position = Vector3(start.x, 0.0, start.y)
	var before := citizen.position
	settlement._rebuild(b.sector)
	var rebuilt: Node3D = settlement._citizens[0]
	if rebuilt.position.distance_to(before) > 0.001:
		_fail("unrelated rebuild reset citizen position from %s to %s" % [before, rebuilt.position])
		return
	var live_nav: RefCounted = settlement._citizen_navigation[b.id()]
	for i in 600:
		settlement._move_citizens(0.1)
		var p := Vector2(rebuilt.position.x, rebuilt.position.z)
		if not live_nav.is_walkable(p):
			_fail("citizen entered blocked geometry while walking at step %d" % i)
			return

	print("CITIZEN NAVIGATION OK  corners=", path.size())
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
