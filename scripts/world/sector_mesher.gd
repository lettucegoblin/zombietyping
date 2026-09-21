class_name SectorMesher
## Builds the 3D geometry for one sector as a few batched meshes (ground+roads, buildings).
## Everything is vertex-coloured for now; facade textures from PixelLab come later.

const T := 5.0            # World.TILE_M (kept local: static context)
const FLOOR_H := 3.6      # World.FLOOR_M
const S := SectorData.SIZE

static var _mat: ShaderMaterial
static var _flat: ShaderMaterial
static var _door_leaf_mat: StandardMaterial3D
## building id -> {mmi: MultiMeshInstance3D, idx: int} for the facade door leaves of loaded sectors
static var door_instances: Dictionary = {}
## building id -> {mmi, idx} for the dark vestibule behind each facade door (hidden while
## that building's interior is loaded, so you can see in through the opening)
static var doorway_instances: Dictionary = {}
static var _vestibule_mesh: ArrayMesh
const DOORWAY := Color("#120a1f")
const DOOR_W := 1.2      ## must match InteriorMesher.DOOR_W / DOOR_H (the leaf flies through both holes)
const DOOR_H := 2.2
const VESTIBULE_D := 0.7

## Atlas cells (4x4 grid of 64px, see assets/textures/atlas.png). (0,0) is plain white.
const CELL_PLAIN := Vector2(0, 0)
const CELL_BRICK := Vector2(1, 0)
const CELL_CONCRETE := Vector2(2, 0)
const CELL_SIDING := Vector2(3, 0)
const CELL_ASPHALT := Vector2(0, 1)
const CELL_SIDEWALK := Vector2(1, 1)
const CELL_GRASS := Vector2(2, 1)
const CELL_ROOF := Vector2(3, 1)
const CELL_DOOR := Vector2(0, 2)     ## 32x56 sprite in the cell's top-left
const CELL_WINDOW := Vector2(1, 2)   ## 32x40 sprite in the cell's top-left
const DOOR_UV := Vector2(0.5, 0.875)
const WINDOW_UV := Vector2(0.5, 0.625)
const WIN_LO := 1.2
const WIN_HI := 2.2
const UV_METRES := 1.25    ## one texture repeat = 1.25 m

const GROUND := {
	District.Kind.DOWNTOWN: Color("#6c6c72"), District.Kind.INDUSTRIAL: Color("#7a7268"),
	District.Kind.RESIDENTIAL: Color("#587a41"), District.Kind.SUBURB: Color("#5e8446"),
	District.Kind.STRIP: Color("#6e685c"), District.Kind.PARK: Color("#4d7d3c"),
}
const ROAD_ARTERIAL := Color("#34343a")
const ROAD_LOCAL := Color("#42424a")
const SIDEWALK := Color("#8d8b84")
const LANE := Color("#b9a851")


static func material() -> ShaderMaterial:
	if _mat == null:
		_mat = ShaderMaterial.new()
		_mat.shader = load("res://shaders/cel.gdshader")
		if ResourceLoader.exists("res://assets/textures/atlas.png"):
			_mat.set_shader_parameter("atlas", load("res://assets/textures/atlas.png"))
	return _mat


## Unlit material for interiors (shading baked into vertex colours).
static func flat_material() -> ShaderMaterial:
	if _flat == null:
		_flat = ShaderMaterial.new()
		_flat.shader = load("res://shaders/flat.gdshader")
		if ResourceLoader.exists("res://assets/textures/atlas.png"):
			_flat.set_shader_parameter("atlas", load("res://assets/textures/atlas.png"))
	return _flat


static func wall_cell(district: int) -> Vector2:
	match district:
		District.Kind.DOWNTOWN, District.Kind.INDUSTRIAL: return CELL_CONCRETE
		District.Kind.SUBURB: return CELL_SIDING
		_: return CELL_BRICK


static func building_wall_cell(b: BuildingData) -> Vector2:
	match b.kind:
		"apartments", "shop": return CELL_BRICK
		"house": return CELL_SIDING
		"office", "warehouse": return CELL_CONCRETE
		_: return wall_cell(b.district)


static func build(sd: SectorData) -> Node3D:
	var root := Node3D.new()
	root.name = "Sector_%d_%d" % [sd.coord.x, sd.coord.y]
	var org := sd.origin_tile()
	var ox := org.x * T
	var oz := org.y * T

	# ---- ground + roads + sidewalks ----
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var gcell := CELL_GRASS if sd.district in [District.Kind.RESIDENTIAL, District.Kind.SUBURB, District.Kind.PARK] else CELL_CONCRETE
	_quad_y(st, ox, oz, ox + S * T, oz + S * T, -0.02, GROUND[sd.district], gcell)
	for ly in S:
		for lx in S:
			var r := sd.road[ly * S + lx]
			var x0 := ox + lx * T
			var z0 := oz + ly * T
			if r != 0:
				_quad_y(st, x0, z0, x0 + T, z0 + T, 0.0, ROAD_ARTERIAL if r == 2 else ROAD_LOCAL, CELL_ASPHALT)
				if r == 2:
					# Centre dashes follow the same continuous tensor as the road trace.
					var flow := CityGen.road_direction_at(World.seed, Vector2(org + Vector2i(lx, ly)) + Vector2(0.5, 0.5))
					var horiz := absf(flow.x) >= absf(flow.y)
					if horiz:
						_quad_y(st, x0 + 1.0, z0 + T * 0.5 - 0.12, x0 + 3.0, z0 + T * 0.5 + 0.12, 0.01, LANE)
					else:
						_quad_y(st, x0 + T * 0.5 - 0.12, z0 + 1.0, x0 + T * 0.5 + 0.12, z0 + 3.0, 0.01, LANE)
			else:
				# sidewalk strip on every edge that touches a road
				var w := 0.9
				if _road_n(sd, lx, ly - 1): _quad_y(st, x0, z0, x0 + T, z0 + w, 0.03, SIDEWALK, CELL_SIDEWALK)
				if _road_n(sd, lx, ly + 1): _quad_y(st, x0, z0 + T - w, x0 + T, z0 + T, 0.03, SIDEWALK, CELL_SIDEWALK)
				if _road_n(sd, lx - 1, ly): _quad_y(st, x0, z0, x0 + w, z0 + T, 0.03, SIDEWALK, CELL_SIDEWALK)
				if _road_n(sd, lx + 1, ly): _quad_y(st, x0 + T - w, z0, x0 + T, z0 + T, 0.03, SIDEWALK, CELL_SIDEWALK)
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	ground.mesh = st.commit()
	ground.material_override = material()
	root.add_child(ground)

	# ---- buildings ----
	if not sd.buildings.is_empty():
		var bt := SurfaceTool.new()
		bt.begin(Mesh.PRIMITIVE_TRIANGLES)
		for b in sd.buildings:
			_building(bt, b)
		var bm := MeshInstance3D.new()
		bm.name = "Buildings"
		bm.mesh = bt.commit()
		bm.material_override = material()
		root.add_child(bm)
		# facade door leaves: one MultiMesh per sector; a kicked door's instance is collapsed
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		var qm := QuadMesh.new()
		qm.size = Vector2(DOOR_W, DOOR_H)
		mm.mesh = qm
		mm.instance_count = sd.buildings.size()
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "DoorLeaves"
		mmi.multimesh = mm
		mmi.material_override = door_leaf_material()
		mmi.custom_aabb = AABB(Vector3(ox - 2.0, -1.0, oz - 2.0), Vector3(S * T + 4.0, 6.0, S * T + 4.0))
		root.add_child(mmi)
		# dark vestibules behind the door openings (the facade wall has a real hole there)
		var vm := MultiMesh.new()
		vm.transform_format = MultiMesh.TRANSFORM_3D
		vm.mesh = vestibule_mesh()
		vm.instance_count = sd.buildings.size()
		var vmi := MultiMeshInstance3D.new()
		vmi.name = "Doorways"
		vmi.multimesh = vm
		vmi.material_override = material()
		vmi.custom_aabb = mmi.custom_aabb
		root.add_child(vmi)
		for i in sd.buildings.size():
			var b := sd.buildings[i]
			door_instances[b.id()] = { "mmi": mmi, "idx": i }
			doorway_instances[b.id()] = { "mmi": vmi, "idx": i }
			var kicked: bool = World.state.get(b.id(), {}).get("door_kicked", false)
			mm.set_instance_transform(i, Transform3D().scaled(Vector3.ZERO) if kicked else door_leaf_transform(b))
			vm.set_instance_transform(i, door_leaf_transform(b, 0.0))
		# one box collider per building: blocks line-of-sight rays (layer 1) around corners
		for b in sd.buildings:
			var body := StaticBody3D.new()
			body.name = "Col_" + b.id().replace(",", "_").replace(":", "_")
			body.set_meta("bid", b.id())
			body.add_to_group("building_colliders")
			var shape := CollisionShape3D.new()
			var box := BoxShape3D.new()
			var fpr := InteriorGen.footprint(b)
			var h := b.floors * FLOOR_H
			box.size = Vector3(fpr.size.x, h, fpr.size.y)
			shape.shape = box
			shape.position = Vector3(fpr.position.x + fpr.size.x * 0.5, h * 0.5, fpr.position.y + fpr.size.y * 0.5)
			body.add_child(shape)
			root.add_child(body)
	return root


static func _road_n(sd: SectorData, lx: int, ly: int) -> bool:
	if lx >= 0 and ly >= 0 and lx < S and ly < S:
		return sd.road[ly * S + lx] != 0
	return World.road_at(sd.origin_tile() + Vector2i(lx, ly)) != 0


static func building_color(b: BuildingData) -> Color:
	var base: Color = District.COLOR[b.district]
	var h := b.seed_hash
	var hue_shift := (float(h & 0xFF) / 255.0 - 0.5) * 0.08
	var val := 0.55 + float((h >> 8) & 0xFF) / 255.0 * 0.35
	var sat := 0.25 + float((h >> 16) & 0xFF) / 255.0 * 0.35
	return Color.from_hsv(fmod(base.h + hue_shift + 1.0, 1.0), sat, val)


static func _building(st: SurfaceTool, b: BuildingData) -> void:
	var fpr := InteriorGen.footprint(b)   # one source of truth for the walls' footprint
	var x0 := fpr.position.x
	var z0 := fpr.position.y
	var x1 := fpr.end.x
	var z1 := fpr.end.y
	var h := b.floors * FLOOR_H + (0.4 if b.district == District.Kind.INDUSTRIAL else 0.0)
	var wc := building_wall_cell(b)
	# textured walls: neutral tint (brightness varies per building), texture carries the colour
	var bright := 0.82 + float(b.seed_hash & 0xFF) / 255.0 * 0.18
	var c := Color(bright, bright, bright)
	var c_dark := c.darkened(0.25)
	var roof := Color(0.9, 0.9, 0.9)
	var win := Color("#1d1f2a")
	# door on the face that looks at the road tile; windows skip that slot on the ground floor
	var d := b.road_tile - b.door_tile
	var dc := Vector3((b.door_tile.x + 0.5) * T, 0, (b.door_tile.y + 0.5) * T)
	var dw := DOOR_W * 0.5
	var door_wall := -1          # 0 north(-z) 1 south(+z) 2 east(+x) 3 west(-x)
	var door_along := 0.0        # distance of the door centre along that wall (from its `a` corner)
	if d == Vector2i(0, -1):
		door_wall = 0; door_along = dc.x - x0
	elif d == Vector2i(0, 1):
		door_wall = 1; door_along = x1 - dc.x
	elif d == Vector2i(1, 0):
		door_wall = 2; door_along = dc.z - z0
	else:
		door_wall = 3; door_along = z1 - dc.z
	# walls (outward normals); the door wall gets a real opening (see vestibule_mesh)
	var faces := [
		[Vector3(x0, 0, z0), Vector3(x1, 0, z0), Vector3(0, 0, -1)],   # north (-z)
		[Vector3(x1, 0, z1), Vector3(x0, 0, z1), Vector3(0, 0, 1)],    # south (+z)
		[Vector3(x1, 0, z0), Vector3(x1, 0, z1), Vector3(1, 0, 0)],    # east (+x)
		[Vector3(x0, 0, z1), Vector3(x0, 0, z0), Vector3(-1, 0, 0)],   # west (-x)
	]
	for wi in 4:
		var w: Array = faces[wi]
		if wi == door_wall:
			_wall_door(st, w[0], w[1], h, w[2], c, c_dark, wc, door_along - dw, door_along + dw, DOOR_H)
		else:
			_wall(st, w[0], w[1], h, w[2], c, c_dark, wc)
	_quad_y(st, x0, z0, x1, z1, h, roof, CELL_ROOF)
	# window bands per floor (cheap "pixel skyline" detail). Slot layout comes from
	# window_slots() so the interior builder can cut matching openings later.
	for f in b.floors:
		var y0 := f * FLOOR_H + WIN_LO
		var y1 := f * FLOOR_H + WIN_HI
		var e := 0.04
		var walls := [
			[Vector3(x0, y0, z0 - e), Vector3(x1, y0, z0 - e), Vector3(0, 0, -1)],
			[Vector3(x1, y0, z1 + e), Vector3(x0, y0, z1 + e), Vector3(0, 0, 1)],
			[Vector3(x1 + e, y0, z0), Vector3(x1 + e, y0, z1), Vector3(1, 0, 0)],
			[Vector3(x0 - e, y0, z1), Vector3(x0 - e, y0, z0), Vector3(-1, 0, 0)],
		]
		for wi in 4:
			var w: Array = walls[wi]
			var skip_c := door_along if (f == 0 and wi == door_wall) else -100.0
			_band(st, w[0], w[1], y1 - y0, w[2], Color.WHITE, skip_c, dw + 0.35)


## Window slot offsets along a wall of length len: [start, end] pairs. Deterministic and
## shared with the interior builder so openings line up with the facade.
static func window_slots(len: float, skip_center: float = -100.0, skip_half: float = 0.0) -> Array:
	var out := []
	var period := 2.2
	var wwidth := 0.8
	var t := 0.5
	while t + wwidth < len - 0.3:
		var c := t + wwidth * 0.5
		if absf(c - skip_center) > skip_half + wwidth * 0.5:
			out.append([t, t + wwidth])
		t += period
	return out


## Wall from ground point a to b, height h, with a bottom->top colour gradient.
static func _wall(st: SurfaceTool, a: Vector3, b: Vector3, h: float, n: Vector3, top: Color, bottom: Color, cell: Vector2 = CELL_PLAIN) -> void:
	var up := Vector3(0, h, 0)
	_quad4(st, a, b, b + up, a + up, n, bottom, bottom, top, top, cell)


## Same wall minus a doorway [t0, t1] along a->b, hh high: left piece, right piece, lintel.
static func _wall_door(st: SurfaceTool, a: Vector3, b: Vector3, h: float, n: Vector3, top: Color, bottom: Color, cell: Vector2, t0: float, t1: float, hh: float) -> void:
	var len := a.distance_to(b)
	var dir := (b - a) / maxf(len, 0.001)
	var up := Vector3(0, h, 0)
	var mid := bottom.lerp(top, hh / h)
	t0 = clampf(t0, 0.0, len)
	t1 = clampf(t1, 0.0, len)
	if t0 > 0.001:
		var p := a + dir * t0
		_quad4(st, a, p, p + up, a + up, n, bottom, bottom, top, top, cell)
	if t1 < len - 0.001:
		var p := a + dir * t1
		_quad4(st, p, b, b + up, p + up, n, bottom, bottom, top, top, cell)
	var l0 := a + dir * t0 + Vector3(0, hh, 0)
	var l1 := a + dir * t1 + Vector3(0, hh, 0)
	_quad4(st, l0, l1, l1 + Vector3(0, h - hh, 0), l0 + Vector3(0, h - hh, 0), n, mid, mid, top, top, cell)


## Dark box behind a door opening (open towards local +z = the street): back wall, two
## jambs and a lintel, so the opening reads as a doorway with depth even when the building
## behind it is not loaded.
static func vestibule_mesh() -> ArrayMesh:
	if _vestibule_mesh != null:
		return _vestibule_mesh
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hw := DOOR_W * 0.5
	var h := DOOR_H
	var dd := VESTIBULE_D
	var jamb := DOORWAY.lightened(0.18)
	_quad(st, Vector3(-hw, 0, -dd), Vector3(hw, 0, -dd), Vector3(hw, h, -dd), Vector3(-hw, h, -dd), Vector3(0, 0, 1), DOORWAY)
	_quad(st, Vector3(-hw, 0, -dd), Vector3(-hw, 0, 0), Vector3(-hw, h, 0), Vector3(-hw, h, -dd), Vector3(1, 0, 0), jamb)
	_quad(st, Vector3(hw, 0, -dd), Vector3(hw, 0, 0), Vector3(hw, h, 0), Vector3(hw, h, -dd), Vector3(-1, 0, 0), jamb)
	_quad(st, Vector3(-hw, h, -dd), Vector3(hw, h, -dd), Vector3(hw, h, 0), Vector3(-hw, h, 0), Vector3(0, -1, 0), jamb)
	_vestibule_mesh = st.commit()
	return _vestibule_mesh


## Show/hide the dark vestibule behind a building's door (hidden while its interior exists).
static func set_doorway_open(bid: String, open: bool) -> void:
	var e: Dictionary = doorway_instances.get(bid, {})
	if e.is_empty():
		return
	var mmi: MultiMeshInstance3D = e["mmi"]
	if not is_instance_valid(mmi):
		return
	var b := World.building_by_id(bid)
	if b == null:
		return
	mmi.multimesh.set_instance_transform(e["idx"], Transform3D().scaled(Vector3.ZERO) if open else door_leaf_transform(b, 0.0))


## Horizontal window band: a->b along the wall, band height bh, skipping the door slot.
static func _band(st: SurfaceTool, a: Vector3, b: Vector3, bh: float, n: Vector3, c: Color, skip_center: float, skip_half: float) -> void:
	var len := a.distance_to(b)
	var dir := (b - a) / maxf(len, 0.001)
	for slot in window_slots(len, skip_center, skip_half):
		var p0: Vector3 = a + dir * slot[0]
		var p1: Vector3 = a + dir * slot[1]
		_sprite_quad(st, p0, p1, p1 + Vector3(0, bh, 0), p0 + Vector3(0, bh, 0), n, CELL_WINDOW, WINDOW_UV)


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, col: Color, cell: Vector2 = CELL_PLAIN) -> void:
	_quad4(st, a, b, c, d, n, col, col, col, col, cell)


## World-space planar UV for a point on a face with normal n (tiles every UV_METRES).
static func _planar_uv(p: Vector3, n: Vector3) -> Vector2:
	if absf(n.y) > 0.5:
		return Vector2(p.x, p.z) / UV_METRES
	if absf(n.x) > 0.5:
		return Vector2(p.z, p.y) / UV_METRES
	return Vector2(p.x, p.y) / UV_METRES


## Godot front faces are CLOCKWISE seen from outside: fix the winding so the face points along n.
static func _quad4(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3,
		ca: Color, cb: Color, cc: Color, cd: Color, cell: Vector2 = CELL_PLAIN) -> void:
	if (b - a).cross(c - a).dot(n) > 0.0:
		var tv := b; b = d; d = tv
		var tc := cb; cb = cd; cd = tc
	st.set_normal(n)
	st.set_uv2(cell)
	st.set_color(ca); st.set_uv(_planar_uv(a, n)); st.add_vertex(a)
	st.set_color(cb); st.set_uv(_planar_uv(b, n)); st.add_vertex(b)
	st.set_color(cc); st.set_uv(_planar_uv(c, n)); st.add_vertex(c)
	st.set_color(ca); st.set_uv(_planar_uv(a, n)); st.add_vertex(a)
	st.set_color(cc); st.set_uv(_planar_uv(c, n)); st.add_vertex(c)
	st.set_color(cd); st.set_uv(_planar_uv(d, n)); st.add_vertex(d)


static func door_leaf_material() -> StandardMaterial3D:
	if _door_leaf_mat == null:
		_door_leaf_mat = StandardMaterial3D.new()
		_door_leaf_mat.albedo_texture = load("res://assets/textures/door.png")
		_door_leaf_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		_door_leaf_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_door_leaf_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		_door_leaf_mat.alpha_scissor_threshold = 0.5
		_door_leaf_mat.roughness = 1.0
		_door_leaf_mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return _door_leaf_mat


## World transform of a building's facade door leaf: a quad in the opening, facing the
## street (local +z = out). `y` is the quad centre height; pass 0.0 for ground-anchored meshes.
static func door_leaf_transform(b: BuildingData, y: float = DOOR_H * 0.5) -> Transform3D:
	var d := b.road_tile - b.door_tile
	var out := Vector3(d.x, 0, d.y)                          # facade normal (towards the street)
	var fpr := InteriorGen.footprint(b)
	var dc := Vector3((b.door_tile.x + 0.5) * T, 0, (b.door_tile.y + 0.5) * T)
	var pos: Vector3
	if d.x == 0:
		pos = Vector3(dc.x, y, fpr.position.y if d.y < 0 else fpr.end.y)
	else:
		pos = Vector3(fpr.position.x if d.x < 0 else fpr.end.x, y, dc.z)
	pos += out * 0.03
	return Transform3D(Basis.looking_at(-out, Vector3.UP), pos)


## Collapse a building's facade leaf (it has been kicked in). Persisted in World.state.
static func kick_facade_door(bid: String) -> void:
	World.set_building_state(bid, "door_kicked", true)
	var e: Dictionary = door_instances.get(bid, {})
	if e.is_empty():
		return
	var mmi: MultiMeshInstance3D = e["mmi"]
	if is_instance_valid(mmi):
		mmi.multimesh.set_instance_transform(e["idx"], Transform3D().scaled(Vector3.ZERO))


## Quad mapped to a sprite stored in an atlas cell (uv 0..uv_max within the cell).
## a,b are the bottom edge, c,d the top edge, in the same left->right order as the wall.
static func _sprite_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, cell: Vector2, uv_max: Vector2) -> void:
	var flip := (b - a).cross(c - a).dot(n) > 0.0
	var uva := Vector2(0, uv_max.y)
	var uvb := Vector2(uv_max.x, uv_max.y)
	var uvc := Vector2(uv_max.x, 0)
	var uvd := Vector2(0, 0)
	if flip:
		var tv := b; b = d; d = tv
		var tu := uvb; uvb = uvd; uvd = tu
	st.set_normal(n)
	st.set_uv2(cell)
	st.set_color(Color.WHITE)
	st.set_uv(uva); st.add_vertex(a)
	st.set_uv(uvb); st.add_vertex(b)
	st.set_uv(uvc); st.add_vertex(c)
	st.set_uv(uva); st.add_vertex(a)
	st.set_uv(uvc); st.add_vertex(c)
	st.set_uv(uvd); st.add_vertex(d)


static func _quad_y(st: SurfaceTool, x0: float, z0: float, x1: float, z1: float, y: float, col: Color, cell: Vector2 = CELL_PLAIN) -> void:
	_quad(st, Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1), Vector3.UP, col, cell)
