extends Node3D
## Headless physics check: a kicked door leaf must actually fly, on a floor, out of a
## door-sized hole. Godot --headless --path . res://scenes/tests/check_fling.tscn

var _body: RigidBody3D
var _start: Vector3
var _frames := 0


func _ready() -> void:
	var floor_body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40, 0.1, 40)
	cs.shape = box
	cs.position = Vector3(0, -0.05, 0)
	floor_body.add_child(cs)
	add_child(floor_body)
	# a wall with a door-sized hole around the leaf (like a real doorway)
	for side in [-1.0, 1.0]:
		var w := StaticBody3D.new()
		var wc := CollisionShape3D.new()
		var wb := BoxShape3D.new()
		wb.size = Vector3(3.0, 3.6, 0.1)
		wc.shape = wb
		wc.position = Vector3(side * (1.5 + InteriorMesher.DOOR_W * 0.5), 1.8, 0)
		w.add_child(wc)
		add_child(w)
	var xf := Transform3D(Basis.looking_at(Vector3(0, 0, 1), Vector3.UP), Vector3(0, InteriorMesher.DOOR_H * 0.5, 0))
	InteriorMesher._fling(self, xf, Vector3(0, 0, 1), InteriorMesher.DOOR_W, InteriorMesher.DOOR_H)
	_body = get_node("FlyingDoor")
	_start = _body.global_position


func _physics_process(_dt: float) -> void:
	_frames += 1
	if _frames == 40:
		var moved := _body.global_position.distance_to(_start)
		print("door moved %.2f m in 40 physics frames, pos %s, vel %s" % [moved, _body.global_position, _body.linear_velocity])
		if moved < 1.0:
			push_error("FLING FAIL: door did not fly")
			get_tree().quit(1)
		else:
			print("FLING OK")
			get_tree().quit(0)
