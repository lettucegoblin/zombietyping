class_name Settlement
extends Node3D
## Regenerates the visible settlement layer from sparse World state: salvage cars,
## perimeter walls, farms, placed furnishings, and lightweight citizen simulation.

const CAR_TEXTURES := [
	preload("res://assets/sprites/vehicles/car_salvage_0.png"),
	preload("res://assets/sprites/vehicles/car_salvage_1.png"),
	preload("res://assets/sprites/vehicles/car_salvage_2.png"),
	preload("res://assets/sprites/vehicles/car_salvage_3.png"),
	preload("res://assets/sprites/vehicles/car_salvage_4.png"),
]
const PROP_TEXTURES := {
	"crate": preload("res://assets/sprites/props/crate.png"),
	"bed": preload("res://assets/sprites/props/bed.png"),
	"chair": preload("res://assets/sprites/props/chair.png"),
}
const BUILD_KINDS := ["wall", "crate", "bed", "chair", "farm"]
const WALL_COLOR := Color("#623b55")
const WALL_CAP := Color("#f6c177")

var player: Node3D
var active_building_id := ""
var build_mode := false
var build_index := 0
var _root: Node3D
var _dirty := true
var _last_sector := Vector2i(999999, 999999)
var _citizens: Array[Node3D] = []
var _food_clock := 0.0


func _ready() -> void:
	_root = Node3D.new()
	_root.name = "GeneratedSettlement"
	add_child(_root)
	World.state_changed.connect(func(_id): _dirty = true)
	World.settlement_changed.connect(func(): _dirty = true)


func configure(p: Node3D) -> void:
	player = p
	_dirty = true


func enter(id: String) -> void:
	active_building_id = id
	build_mode = false
	var b := World.building_by_id(id)
	if b != null:
		player.set_manual_zone(World.safe_rect_world(b))
	_dirty = true


func leave() -> void:
	active_building_id = ""
	build_mode = false
	if player != null:
		player.clear_manual_zone()


func toggle_build() -> String:
	if active_building_id == "":
		return "enter a claimed safe zone first"
	build_mode = not build_mode
	return "build mode %s — Q/E select, F place" % ("on" if build_mode else "off")


func cycle_build(delta: int) -> String:
	build_index = posmod(build_index + delta, BUILD_KINDS.size())
	return selected_kind()


func selected_kind() -> String:
	return BUILD_KINDS[build_index]


func place_selected() -> String:
	if not build_mode or active_building_id == "" or player == null:
		return "turn on build mode inside a safe zone"
	var p: Vector3 = player.global_position + player.facing * 2.6
	p.y = 0.05
	var msg := World.place_item(active_building_id, selected_kind(), p, atan2(player.facing.x, player.facing.z))
	_dirty = true
	return msg


func _process(dt: float) -> void:
	if player == null:
		return
	var sec := World.sector_of_tile(World.world_to_tile(player.global_position))
	if sec != _last_sector:
		_last_sector = sec
		_dirty = true
	if _dirty:
		_rebuild(sec)
	_move_citizens(dt)
	_food_clock += dt
	if _food_clock >= 45.0:
		_food_clock = 0.0
		var farms := 0
		for item in World.placements:
			if item.get("kind", "") == "farm" and World.building_state(item.get("building", "")).get("claimed", false):
				farms += 1
		if farms > 0:
			World.add_materials({ "food": farms })


func _rebuild(center: Vector2i) -> void:
	_dirty = false
	for c in _root.get_children():
		c.free()
	_citizens.clear()
	# Cars are seed-derived street salvage, not authored encounter props.
	for sy in range(center.y - 1, center.y + 2):
		for sx in range(center.x - 1, center.x + 2):
			for b in World.get_sector(sx, sy).buildings:
				if World.car_exists(b):
					_add_car(b)
	for id in World.state:
		var st: Dictionary = World.state[id]
		if not st.get("fortified", false):
			continue
		var b := World.building_by_id(id)
		if b == null or maxi(absi(b.sector.x - center.x), absi(b.sector.y - center.y)) > 2:
			continue
		_add_perimeter(b)
		if st.get("claimed", false):
			for i in int(st.get("citizens", 0)):
				_add_citizen(b, i)
	for item in World.placements:
		var b := World.building_by_id(item["building"])
		if b != null and maxi(absi(b.sector.x - center.x), absi(b.sector.y - center.y)) <= 2:
			_add_placement(item)


func _add_car(b: BuildingData) -> void:
	var st: Dictionary = World.state.get(b.id(), {})
	var stage: int = clampi(st.get("car_stage", 0), 0, 4)
	var sp := Sprite3D.new()
	sp.name = "SalvageCar_%s" % b.id().replace(",", "_").replace(":", "_")
	sp.texture = CAR_TEXTURES[stage]
	sp.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sp.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	sp.pixel_size = 0.019
	sp.shaded = false
	var out := Vector2(b.door_tile - b.road_tile)
	# Park down the curb, never directly in front of the building's gate/player rail.
	var side := Vector2(-out.y, out.x) * (3.7 if posmod(b.seed_hash, 2) == 0 else -3.7)
	var p := World.tile_to_world(b.road_tile, 1.15)
	sp.position = p + Vector3(side.x, 0.0, side.y)
	_root.add_child(sp)


func _add_perimeter(b: BuildingData) -> void:
	var r := World.safe_rect_world(b)
	var gate_dir := b.road_tile - b.door_tile
	var step := 2.5
	var xs := int(r.size.x / step)
	var zs := int(r.size.y / step)
	for i in range(xs + 1):
		var x := r.position.x + minf(i * step, r.size.x)
		var at_gate := absf(x - (b.door_tile.x + 0.5) * World.TILE_M) < 2.1
		if not (gate_dir.y < 0 and at_gate):
			_add_wall(Vector3(x, 0.8, r.position.y), Vector3(2.55, 1.6, 0.35))
		if not (gate_dir.y > 0 and at_gate):
			_add_wall(Vector3(x, 0.8, r.end.y), Vector3(2.55, 1.6, 0.35))
	for i in range(zs + 1):
		var z := r.position.y + minf(i * step, r.size.y)
		var at_gate := absf(z - (b.door_tile.y + 0.5) * World.TILE_M) < 2.1
		if not (gate_dir.x < 0 and at_gate):
			_add_wall(Vector3(r.position.x, 0.8, z), Vector3(0.35, 1.6, 2.55))
		if not (gate_dir.x > 0 and at_gate):
			_add_wall(Vector3(r.end.x, 0.8, z), Vector3(0.35, 1.6, 2.55))


func _add_wall(pos: Vector3, size: Vector3, yaw: float = 0.0) -> void:
	var wall := Node3D.new()
	wall.name = "Wall"
	wall.position = pos
	wall.rotation.y = yaw
	_root.add_child(wall)
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = WALL_COLOR
	mat.roughness = 0.9
	mesh.material = mat
	mi.mesh = mesh
	wall.add_child(mi)
	var cap := MeshInstance3D.new()
	var cap_mesh := BoxMesh.new()
	cap_mesh.size = Vector3(size.x + 0.04, 0.12, size.z + 0.04)
	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = WALL_CAP
	cap_mesh.material = cap_mat
	cap.mesh = cap_mesh
	cap.position = Vector3(0, size.y * 0.5, 0)
	wall.add_child(cap)


func _add_farm(pos: Vector3, yaw: float) -> void:
	var plot := Node3D.new()
	plot.name = "FarmPlot"
	plot.position = pos
	plot.rotation.y = yaw
	_root.add_child(plot)
	var soil := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(3.6, 0.12, 2.4)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("#65435a")
	mesh.material = mat
	soil.mesh = mesh
	soil.position = Vector3(0, 0.08, 0)
	plot.add_child(soil)
	for row in 3:
		var crop := MeshInstance3D.new()
		var cm := BoxMesh.new()
		cm.size = Vector3(3.1, 0.28, 0.18)
		var cmat := StandardMaterial3D.new()
		cmat.albedo_color = Color("#7ee787")
		cm.material = cmat
		crop.mesh = cm
		crop.position = Vector3(0, 0.25, -0.72 + row * 0.72)
		plot.add_child(crop)


func _add_citizen(b: BuildingData, index: int) -> void:
	var n := Node3D.new()
	n.name = "Citizen_%s_%d" % [b.id(), index]
	var body := MeshInstance3D.new()
	var bm := CapsuleMesh.new()
	bm.radius = 0.27
	bm.height = 1.05
	var mat := StandardMaterial3D.new()
	var cols := [Color("#ff6fb5"), Color("#68d5ff"), Color("#f6c177"), Color("#a6e3a1")]
	mat.albedo_color = cols[posmod(b.seed_hash + index, cols.size())]
	bm.material = mat
	body.mesh = bm
	body.position.y = 0.72
	n.add_child(body)
	var r := World.safe_rect_world(b).grow(-1.2)
	n.position = Vector3(r.get_center().x + index * 0.6, 0.0, r.get_center().y)
	n.set_meta("bounds", r)
	n.set_meta("home_seed", b.seed_hash + index * 97)
	n.set_meta("leg", 0)
	n.set_meta("target", _citizen_target(n))
	_root.add_child(n)
	_citizens.append(n)


func _citizen_target(n: Node3D) -> Vector3:
	var r: Rect2 = n.get_meta("bounds")
	var leg: int = n.get_meta("leg")
	var seed_value: int = n.get_meta("home_seed")
	var rx := Det.unit(World.seed, seed_value, leg, 701)
	var rz := Det.unit(World.seed, seed_value, leg, 702)
	return Vector3(lerpf(r.position.x, r.end.x, rx), 0.0, lerpf(r.position.y, r.end.y, rz))


func _move_citizens(dt: float) -> void:
	for n in _citizens:
		if not is_instance_valid(n):
			continue
		var target: Vector3 = n.get_meta("target")
		var delta := target - n.position
		if delta.length() < 0.18:
			n.set_meta("leg", int(n.get_meta("leg")) + 1)
			n.set_meta("target", _citizen_target(n))
		else:
			n.position += delta.normalized() * minf(delta.length(), dt * 0.75)
			n.rotation.y = atan2(delta.x, delta.z)


func _add_placement(item: Dictionary) -> void:
	var kind: String = item["kind"]
	if kind == "farm":
		_add_farm(item["pos"], float(item.get("yaw", 0.0)))
		return
	if kind == "wall":
		_add_wall(item["pos"] + Vector3(0, 0.75, 0), Vector3(2.4, 1.5, 0.3), float(item.get("yaw", 0.0)))
		return
	if not PROP_TEXTURES.has(kind):
		return
	var sp := Sprite3D.new()
	sp.texture = PROP_TEXTURES[kind]
	sp.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sp.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	sp.pixel_size = 0.028
	sp.position = item["pos"] + Vector3(0, 0.75, 0)
	sp.shaded = false
	_root.add_child(sp)
