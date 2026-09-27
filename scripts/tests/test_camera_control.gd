extends Node
## Fast regression for the two gaze priorities: a kicked door owns the camera for its
## animation, and mouse look owns it briefly after the player moves the mouse.

const RailPlayerScript := preload("res://scripts/player/rail_player.gd")
const InteriorScript := preload("res://scripts/interior/interior.gd")


func _ready() -> void:
	var player := RailPlayerScript.new()
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	player.add_child(camera)
	add_child(player)
	await get_tree().process_frame
	player.global_position = Vector3.ZERO

	player.lock_look_toward(Vector3(0, 0, -5))
	var doorway_facing: Vector3 = player.facing
	player.face_toward(Vector3(5, 0, 0))
	_check(player.is_look_locked(), "doorway look is locked")
	_check(player.facing.is_equal_approx(doorway_facing), "auto-aim cannot steal doorway look")

	player.unlock_look()
	player.face_toward(Vector3(5, 0, 0))
	_check(player.facing.is_equal_approx(Vector3.RIGHT), "look unlock restores target facing")

	player.mouse_look(Vector2(120, -30))
	player._update_cam(0.0)
	var mouse_facing: Vector3 = player.facing
	_check(player.is_manual_looking(), "mouse movement starts manual-look priority")
	player.face_toward(Vector3(0, 0, -5))
	_check(player.facing.is_equal_approx(mouse_facing), "auto-aim cannot immediately erase mouse look")
	_check(absf(camera.rotation.x) > 0.01, "mouse movement applies camera pitch")

	player.guide_toward(Vector3(0, 0, -5))
	_check(not player.is_manual_looking(), "arrival guidance consumes the stale mouse-look grace period")
	_check(player.facing.is_equal_approx(Vector3.FORWARD), "arrival guidance gets one decisive doorway heading")

	# Door guidance targets a point through the opening at both close and oblique angles;
	# aiming at the door plane itself used to produce wall-facing headings.
	World.state.clear()
	var building: BuildingData = World.get_sector(0, 0).buildings[0]
	var interior := InteriorScript.new()
	add_child(interior)
	interior.enter(building, 0, true)
	interior.reveal_all()
	var di := -1
	for candidate in interior.plan.doors.size():
		if interior.plan.doors[candidate].b >= 0:
			di = candidate
			break
	_check(di >= 0, "generated test floor has an internal doorway")
	if di >= 0:
		var door: FloorPlan.Door = interior.plan.doors[di]
		interior.current_room = door.a
		var through := Vector3(door.dir.x, 0, door.dir.y)
		var side := Vector3(-through.z, 0, through.x)
		for viewer in [door.pos - through * 0.08 + side * 0.5, door.pos - through * 2.5 + side * 2.0]:
			var target := interior.option_look_pos({ "kind": "door", "door": di }, viewer)
			var flat_target := Vector2(target.x - door.pos.x, target.z - door.pos.z).normalized()
			_check(flat_target.dot(Vector2(through.x, through.z)) > 0.95, "door target stays beyond the doorway plane")
		var hinge: Node3D = interior._door_nodes[di]
		for i in 5:
			interior.update_safezone_doors(hinge.global_position + through * 0.5, 0.1)
		var swing: Node3D = hinge.get_node("Swing")
		_check(absf(swing.rotation.y) > 0.5, "safe-zone door swings open before contact")
		_check(hinge.get_node_or_null("Swing/Leaf") is MeshInstance3D, "safe-zone doorway keeps a full-size visible leaf")
	interior.unload()

	print("CAMERA CONTROL PASS")
	get_tree().quit(0)


func _check(ok: bool, label: String) -> void:
	if ok:
		print("  PASS: ", label)
	else:
		push_error("  FAIL: " + label)
		get_tree().quit(1)
