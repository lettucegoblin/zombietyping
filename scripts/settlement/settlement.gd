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
const CitizenNav = preload("res://scripts/settlement/citizen_navigation.gd")
const WALL_COLOR := Color("#623b55")
const WALL_CAP := Color("#f6c177")
const GHOST_VALID := Color("#7ee787", 0.58)
const GHOST_INVALID := Color("#ff4f87", 0.62)
const UNDO_WINDOW_MSEC := 10000

var player: Node3D
var active_building_id := ""
var build_mode := false
var build_index := 0
var _root: Node3D
var _dirty := true
var _last_sector := Vector2i(999999, 999999)
var _citizens: Array[Node3D] = []
var _citizen_memory: Dictionary = {}
var _citizen_navigation: Dictionary = {}
var _food_clock := 0.0
var preview_rotation := 0
var _ghost_root: Node3D
var _ghost_kind := ""
var _ghost_materials: Array[StandardMaterial3D] = []
var _ghost_sprites: Array[Sprite3D] = []
var _ghost_valid := false
var _ghost_error := ""
var _last_built: Dictionary = {}
var _undo_until_msec := 0


func _ready() -> void:
	_root = Node3D.new()
	_root.name = "GeneratedSettlement"
	add_child(_root)
	_ghost_root = Node3D.new()
	_ghost_root.name = "PlacementGhost"
	_ghost_root.visible = false
	add_child(_ghost_root)
	World.state_changed.connect(func(_id): _dirty = true)
	World.settlement_changed.connect(func(): _dirty = true)


func configure(p: Node3D) -> void:
	player = p
	_dirty = true


func enter(id: String) -> void:
	active_building_id = id
	build_mode = false
	_ghost_root.visible = false
	var b := World.building_by_id(id)
	if b != null:
		player.set_manual_zone(World.safe_rect_world(b), b.road_tile)
	_dirty = true


func leave() -> void:
	active_building_id = ""
	build_mode = false
	_ghost_root.visible = false
	_last_built.clear()
	_undo_until_msec = 0
	if player != null:
		player.clear_manual_zone()


func toggle_build() -> String:
	if active_building_id == "":
		return "enter a claimed safe zone first"
	build_mode = not build_mode
	if build_mode:
		preview_rotation = 0
		_update_ghost(true)
		return "build mode on — Q/E item, R rotate, F confirm, Esc cancel"
	_ghost_root.visible = false
	return "build mode off"


func cycle_build(delta: int) -> String:
	if not build_mode:
		return "turn on build mode first"
	build_index = posmod(build_index + delta, BUILD_KINDS.size())
	preview_rotation = 0
	_update_ghost(true)
	return "%s selected" % selected_kind()


func selected_kind() -> String:
	return BUILD_KINDS[build_index]


func rotate_preview() -> String:
	if not build_mode:
		return "turn on build mode first"
	preview_rotation = posmod(preview_rotation + 1, 4)
	_update_ghost()
	return "%s rotated to %d°" % [selected_kind(), preview_rotation * 90]


func cancel_build() -> String:
	if not build_mode:
		return "build mode is already off"
	build_mode = false
	_ghost_root.visible = false
	return "placement cancelled — no materials spent"


func _preview_position() -> Vector3:
	var p: Vector3 = player.global_position + player.facing * 2.6
	p.y = player.global_position.y + 0.05
	return p


func _preview_yaw() -> float:
	return atan2(player.facing.x, player.facing.z) + preview_rotation * PI * 0.5


func ghost_is_valid() -> bool:
	return build_mode and _ghost_valid


func ghost_error() -> String:
	return _ghost_error


func undo_seconds_remaining() -> float:
	if _last_built.is_empty():
		return 0.0
	return maxf(0.0, float(_undo_until_msec - Time.get_ticks_msec()) / 1000.0)


func place_selected() -> String:
	if not build_mode or active_building_id == "" or player == null:
		return "turn on build mode inside a safe zone"
	_update_ghost()
	if not _ghost_valid:
		return _ghost_error
	var msg := World.place_item(active_building_id, selected_kind(), _preview_position(), _preview_yaw())
	if msg.ends_with(" placed"):
		_last_built = World.last_placement_for(active_building_id)
		_undo_until_msec = Time.get_ticks_msec() + UNDO_WINDOW_MSEC
	_dirty = true
	_update_ghost()
	return msg


func undo_or_dismantle_last() -> String:
	if active_building_id == "":
		return "enter a claimed safe zone first"
	var full_refund := not _last_built.is_empty() and Time.get_ticks_msec() <= _undo_until_msec
	var target := _last_built if full_refund else World.last_placement_for(active_building_id)
	if target.is_empty():
		return "nothing built here to dismantle"
	var msg := World.remove_placement(target, 1.0 if full_refund else 0.5)
	if msg.begins_with("undid") or msg.begins_with("dismantled"):
		_last_built.clear()
		_undo_until_msec = 0
		_dirty = true
		_update_ghost()
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
	_update_ghost()
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
	_remember_citizens()
	for c in _root.get_children():
		c.free()
	_citizens.clear()
	_citizen_navigation.clear()
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
	var citizen_key := "%s:%d" % [b.id(), index]
	n.name = "Citizen_%s_%d" % [b.id(), index]
	var base_state: Dictionary = World.state.get(b.id(), {})
	var resident_ids: Array = base_state.get("resident_ids", [])
	var resident_index := index - int(base_state.get("founders", 0))
	if resident_index >= 0 and resident_index < resident_ids.size():
		var survivor_id: String = resident_ids[resident_index]
		var survivor: Dictionary = World.survivors.get(survivor_id, {})
		if not survivor.is_empty():
			citizen_key = survivor_id
			n.name = "Survivor_%s" % str(survivor.get("name", "resident")).validate_node_name()
			n.set_meta("survivor_id", survivor_id)
			n.set_meta("survivor_name", survivor.get("name", ""))
			n.set_meta("trait", survivor.get("trait", ""))
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
	var nav := _navigation_for(b)
	var seed_value := b.seed_hash + index * 97
	var remembered: Dictionary = _citizen_memory.get(citizen_key, {})
	var p2: Vector2 = nav.deterministic_point(seed_value, -1)
	var leg := 0
	if not remembered.is_empty():
		var old: Vector3 = remembered.get("position", Vector3(p2.x, 0.0, p2.y))
		p2 = Vector2(old.x, old.z) if nav.is_walkable(Vector2(old.x, old.z)) else nav.nearest_walkable(Vector2(old.x, old.z))
		leg = int(remembered.get("leg", 0))
		n.rotation.y = float(remembered.get("yaw", 0.0))
	n.position = Vector3(p2.x, 0.0, p2.y)
	n.set_meta("citizen_key", citizen_key)
	n.set_meta("building_id", b.id())
	n.set_meta("home_seed", seed_value)
	n.set_meta("leg", leg)
	_root.add_child(n)
	_citizens.append(n)
	_assign_citizen_route(n)


func _navigation_for(b: BuildingData) -> RefCounted:
	var nav: RefCounted = _citizen_navigation.get(b.id())
	if nav == null:
		nav = CitizenNav.new(b, World.placements)
		_citizen_navigation[b.id()] = nav
	return nav


func _remember_citizens() -> void:
	for n in _citizens:
		if not is_instance_valid(n):
			continue
		var key: String = n.get_meta("citizen_key", "")
		if key != "":
			_citizen_memory[key] = {
				"position": n.position,
				"yaw": n.rotation.y,
				"leg": int(n.get_meta("leg", 0)),
			}


func _assign_citizen_route(n: Node3D) -> void:
	var nav: RefCounted = _citizen_navigation.get(n.get_meta("building_id", ""))
	if nav == null:
		n.set_meta("path", PackedVector2Array())
		return
	var leg: int = n.get_meta("leg", 0)
	var seed_value: int = n.get_meta("home_seed", 0)
	var from := Vector2(n.position.x, n.position.z)
	# A target can hash to the citizen's current cell. Advance deterministically until
	# there is an actual walking leg, with a small bound for pathological one-cell yards.
	for attempt in 8:
		var target: Vector2 = nav.deterministic_point(seed_value, leg)
		var path: PackedVector2Array = nav.route(from, target)
		if path.size() > 1 or (path.size() == 1 and path[0].distance_to(from) > 0.15):
			n.set_meta("leg", leg)
			n.set_meta("path", path)
			n.set_meta("path_index", 0)
			return
		leg += 1
	n.set_meta("leg", leg)
	n.set_meta("path", PackedVector2Array())
	n.set_meta("path_index", 0)


func _move_citizens(dt: float) -> void:
	for n in _citizens:
		if not is_instance_valid(n):
			continue
		var path: PackedVector2Array = n.get_meta("path", PackedVector2Array())
		var path_index: int = n.get_meta("path_index", 0)
		if path.is_empty() or path_index >= path.size():
			n.set_meta("leg", int(n.get_meta("leg", 0)) + 1)
			_assign_citizen_route(n)
			continue
		var target2 := path[path_index]
		var target := Vector3(target2.x, 0.0, target2.y)
		var delta := target - n.position
		if delta.length() < 0.08:
			n.position = target
			n.set_meta("path_index", path_index + 1)
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


# ------------------------------------------------------------------ construction preview

func _update_ghost(force_rebuild: bool = false) -> void:
	if _ghost_root == null:
		return
	if not build_mode or active_building_id == "" or player == null:
		_ghost_root.visible = false
		_ghost_valid = false
		_ghost_error = ""
		return
	var kind := selected_kind()
	if force_rebuild or kind != _ghost_kind:
		_build_ghost(kind)
	_ghost_root.visible = true
	_ghost_root.position = _preview_position()
	_ghost_root.rotation.y = _preview_yaw()
	_ghost_error = World.placement_error(active_building_id, kind, _ghost_root.position, _ghost_root.rotation.y)
	if _ghost_error == "" and not World.can_afford(World.build_cost(kind)):
		_ghost_error = "need " + World.cost_text(World.build_cost(kind))
	_ghost_valid = _ghost_error == ""
	_set_ghost_feedback(_ghost_valid)


func _build_ghost(kind: String) -> void:
	for child in _ghost_root.get_children():
		child.free()
	_ghost_materials.clear()
	_ghost_sprites.clear()
	_ghost_kind = kind
	var footprint: Vector2 = World.PLACEMENT_SIZE[kind]
	_add_ghost_box(Vector3(footprint.x, 0.035, footprint.y), Vector3(0, 0.035, 0))
	match kind:
		"wall":
			_add_ghost_box(Vector3(2.4, 1.5, 0.3), Vector3(0, 0.75, 0))
		"farm":
			for row in 3:
				_add_ghost_box(Vector3(3.1, 0.16, 0.18), Vector3(0, 0.18, -0.72 + row * 0.72))
		_:
			if PROP_TEXTURES.has(kind):
				var sp := Sprite3D.new()
				sp.texture = PROP_TEXTURES[kind]
				sp.billboard = BaseMaterial3D.BILLBOARD_ENABLED
				sp.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
				sp.pixel_size = 0.028
				sp.position = Vector3(0, 0.75, 0)
				sp.shaded = false
				sp.no_depth_test = true
				_ghost_root.add_child(sp)
				_ghost_sprites.append(sp)


func _add_ghost_box(size: Vector3, pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = GHOST_VALID
	mesh.material = mat
	mi.mesh = mesh
	mi.position = pos
	_ghost_root.add_child(mi)
	_ghost_materials.append(mat)


func _set_ghost_feedback(valid: bool) -> void:
	var color := GHOST_VALID if valid else GHOST_INVALID
	for mat in _ghost_materials:
		mat.albedo_color = color
	for sp in _ghost_sprites:
		sp.modulate = color
