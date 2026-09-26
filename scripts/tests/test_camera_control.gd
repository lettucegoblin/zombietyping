extends Node
## Fast regression for the two gaze priorities: a kicked door owns the camera for its
## animation, and mouse look owns it briefly after the player drags.

const RailPlayerScript := preload("res://scripts/player/rail_player.gd")


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
	_check(player.is_manual_looking(), "mouse drag starts manual-look priority")
	player.face_toward(Vector3(0, 0, -5))
	_check(player.facing.is_equal_approx(mouse_facing), "auto-aim cannot immediately erase mouse look")
	_check(absf(camera.rotation.x) > 0.01, "mouse drag applies camera pitch")

	print("CAMERA CONTROL PASS")
	get_tree().quit(0)


func _check(ok: bool, label: String) -> void:
	if ok:
		print("  PASS: ", label)
	else:
		push_error("  FAIL: " + label)
		get_tree().quit(1)
