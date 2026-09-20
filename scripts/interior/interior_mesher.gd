class_name InteriorMesher
## Builds one room of a FloorPlan as inward-facing geometry: floor, ceiling, walls with
## door openings, and — on the building perimeter — real window openings cut from the same
## window_slots() the facade uses. Exterior geometry is back-face culled from inside, so
## through those openings you see the streamed city: one-way windows for free.

const DOOR_W := 1.2
const DOOR_H := 2.2
const WIN_LO := 1.2
const WIN_HI := 2.2

const FLOOR_COL := {
	District.Kind.DOWNTOWN: Color("#94a3b8"), District.Kind.STRIP: Color("#fdba74"),
	District.Kind.INDUSTRIAL: Color("#334155"), District.Kind.RESIDENTIAL: Color("#ea580c"),
	District.Kind.SUBURB: Color("#fdba74"), District.Kind.PARK: Color("#94a3b8"),
}
const WALL_COLS := [Color("#fdf6e3"), Color("#c39bd3"), Color("#99f6e4"), Color("#d9f99d"), Color("#fdba74")]
const CEIL_COL := Color("#fdf6e3")
const DOOR_COL := Color("#5a3d28")
static var _door_mat: StandardMaterial3D


static func wall_color(b: BuildingData, ri: int) -> Color:
	return WALL_COLS[(b.seed_hash >> (ri % 5)) % WALL_COLS.size()]


static func build_room(fp: FloorPlan, ri: int, b: BuildingData, opened: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "Room_%d" % ri
	var room := fp.rooms[ri]
	var H := World.FLOOR_M
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var wall_col: Color = wall_color(b, ri)

	# floor + ceiling (with a hole over the stairwell so the climb doesn't clip)
	var p00 := fp.cell_to_world(Vector2(room.rect.position))
	var p11 := fp.cell_to_world(Vector2(room.rect.end))
	var slab := Rect2(p00.x, p00.z, p11.x - p00.x, p11.z - p00.z)
	var floor_hole := Rect2()
	var ceil_hole := Rect2()
	if room.is_stair:
		# the storey below's flights come up through this floor; ours go through the ceiling
		if fp.floor > 0:
			floor_hole = Stairwell.shaft_rect(fp, fp.stair_layout, fp.floor - 1)
		if fp.floor < fp.floors_total - 1:
			ceil_hole = Stairwell.shaft_rect(fp, fp.stair_layout, fp.floor)
	_slab(st, slab, p00.y + 0.02, Vector3.UP, FLOOR_COL[b.district], floor_hole)
	_slab(st, slab, p00.y + H - 0.06, Vector3.DOWN, CEIL_COL, ceil_hole)

	# walls, cell edge by cell edge
	var fpr := InteriorGen.footprint(b)
	var x0 := fpr.position.x
	var z0 := fpr.position.y
	var x1 := fpr.end.x
	var z1 := fpr.end.y
	var T := World.TILE_M
	var dvec := b.road_tile - b.door_tile
	var dc := Vector2((b.door_tile.x + 0.5) * T, (b.door_tile.y + 0.5) * T)
	var door_wall := 0
	var door_along := 0.0
	if dvec == Vector2i(0, -1): door_wall = 0; door_along = dc.x - x0
	elif dvec == Vector2i(0, 1): door_wall = 1; door_along = x1 - dc.x
	elif dvec == Vector2i(1, 0): door_wall = 2; door_along = dc.y - z0
	else: door_wall = 3; door_along = z1 - dc.y
	var win_lo := WIN_LO

	for y in range(room.rect.position.y, room.rect.end.y):
		for x in range(room.rect.position.x, room.rect.end.x):
			var cell := Vector2i(x, y)
			for dir: Vector2i in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(1, 0), Vector2i(-1, 0)]:
				var n := cell + dir
				var nr := fp.room_at_cell(n)
				if nr == ri:
					continue
				var p0: Vector3
				var p1: Vector3
				var normal: Vector3
				if dir == Vector2i(0, -1):
					p0 = fp.cell_to_world(Vector2(x, y)); p1 = fp.cell_to_world(Vector2(x + 1, y)); normal = Vector3(0, 0, 1)
				elif dir == Vector2i(0, 1):
					p0 = fp.cell_to_world(Vector2(x, y + 1)); p1 = fp.cell_to_world(Vector2(x + 1, y + 1)); normal = Vector3(0, 0, -1)
				elif dir == Vector2i(1, 0):
					p0 = fp.cell_to_world(Vector2(x + 1, y)); p1 = fp.cell_to_world(Vector2(x + 1, y + 1)); normal = Vector3(-1, 0, 0)
				else:
					p0 = fp.cell_to_world(Vector2(x, y)); p1 = fp.cell_to_world(Vector2(x, y + 1)); normal = Vector3(1, 0, 0)
				var holes: Array = []
				var seg_len := p0.distance_to(p1)
				var seg_dir := (p1 - p0) / maxf(seg_len, 0.001)
				# doors on this edge
				for di in room.doors:
					var d := fp.doors[di]
					var here := (d.a == ri and d.cell == cell and d.dir == dir) or (d.b == ri and d.cell + d.dir == cell and d.dir == -dir)
					if not here:
						continue
					var t := (d.pos - p0).dot(seg_dir)
					holes.append([t - DOOR_W * 0.5, t + DOOR_W * 0.5, 0.0, DOOR_H])
				# windows on the building perimeter
				if nr < 0:
					var wall := -1
					var a0 := 0.0
					var a1 := 0.0
					var wlen := 0.0
					if dir == Vector2i(0, -1) and y == 0:
						wall = 0; wlen = x1 - x0; a0 = p0.x - x0; a1 = p1.x - x0
					elif dir == Vector2i(0, 1) and y == fp.cells.y - 1:
						wall = 1; wlen = x1 - x0; a0 = x1 - p0.x; a1 = x1 - p1.x
					elif dir == Vector2i(1, 0) and x == fp.cells.x - 1:
						wall = 2; wlen = z1 - z0; a0 = p0.z - z0; a1 = p1.z - z0
					elif dir == Vector2i(-1, 0) and x == 0:
						wall = 3; wlen = z1 - z0; a0 = z1 - p0.z; a1 = z1 - p1.z
					if wall >= 0:
						var skip_c := door_along if (fp.floor == 0 and wall == door_wall) else -100.0
						for slot in SectorMesher.window_slots(wlen, skip_c, 1.05):
							# map "along" coords to this segment's t coords (a0 -> t=0, a1 -> t=len)
							var ta: float
							var tb: float
							if a1 > a0:
								ta = slot[0] - a0; tb = slot[1] - a0
							else:
								ta = a0 - slot[1]; tb = a0 - slot[0]
							if tb <= 0.0 or ta >= seg_len:
								continue
							holes.append([maxf(ta, 0.0), minf(tb, seg_len), win_lo, WIN_HI])
				_wall_with_holes(st, p0, p1, normal, H, holes, wall_col)

	# this storey's flights (up to the next storey)
	if room.is_stair and fp.floor < fp.floors_total - 1:
		Stairwell.build_flights(st, fp, fp.stair_layout, fp.floor, 0.0)

	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = st.commit()
	mi.material_override = SectorMesher.flat_material()
	root.add_child(mi)
	mi.create_trimesh_collision()   # walls block line-of-sight rays
	for c in mi.get_children():
		if c is StaticBody3D:
			for cs in c.get_children():
				if cs is CollisionShape3D and cs.shape is ConcavePolygonShape3D:
					cs.shape.backface_collision = true   # rays from the street must hit the outside of the walls too
	if room.is_stair:
		# the storey below's flights + a pit slab, seen down the shaft (hidden while that
		# storey is actually built, during a climb), and a cap over the ceiling hole for
		# when the storey above is not built
		if fp.floor > 0:
			var ds := SurfaceTool.new()
			ds.begin(Mesh.PRIMITIVE_TRIANGLES)
			Stairwell.build_flights(ds, fp, fp.stair_layout, fp.floor - 1, -H)
			Stairwell.build_pit(ds, fp, fp.stair_layout, fp.floor)
			var dm := MeshInstance3D.new()
			dm.name = "DownFlights"
			dm.mesh = ds.commit()
			dm.material_override = SectorMesher.flat_material()
			root.add_child(dm)
		if fp.floor < fp.floors_total - 1:
			var cs2 := SurfaceTool.new()
			cs2.begin(Mesh.PRIMITIVE_TRIANGLES)
			Stairwell.build_cap(cs2, fp, fp.stair_layout, fp.floor)
			var cm := MeshInstance3D.new()
			cm.name = "ShaftCap"
			cm.mesh = cs2.commit()
			cm.material_override = SectorMesher.flat_material()
			root.add_child(cm)

	# door words as 3D labels on this room's side of each door (shown only while you're in
	# this room — see Interior.set_room)
	var labels := Node3D.new()
	labels.name = "Labels"
	labels.visible = false
	for di in room.doors:
		var d := fp.doors[di]
		var into := Vector2(-d.dir) if d.a == ri else Vector2(d.dir)
		var lp := d.pos + Vector3(into.x, 0, into.y) * 0.3
		var to_stair := not room.is_stair and fp.stair_room >= 0 and (d.a == fp.stair_room or d.b == fp.stair_room)
		if to_stair:
			# the stairwell door: its word, and the storeys behind it
			labels.add_child(_label(d.word, lp + Vector3(0, DOOR_H * 0.55, 0)))
			if fp.floor < fp.floors_total - 1:
				labels.add_child(_label("up", lp + Vector3(0, DOOR_H * 0.95, 0)))
			if fp.floor > 0:
				labels.add_child(_label("down", lp + Vector3(0, DOOR_H * 0.2, 0)))
			continue
		# on the upper half of the leaf, so it is in view even when you stand right at it
		labels.add_child(_label(d.word, lp + Vector3(0, DOOR_H * 0.7, 0)))
	if room.is_stair:
		var lps := Stairwell.label_points(fp, fp.stair_layout)
		if fp.floor < fp.floors_total - 1 and lps.has("up"):
			labels.add_child(_label("up", lps["up"]))
		if fp.floor > 0 and lps.has("down"):
			labels.add_child(_label("down", lps["down"]))
	root.add_child(labels)
	return root


static func _label(text: String, pos: Vector3) -> WordLabel:
	var l := WordLabel.new(text, 30)
	l.position = pos
	l.name = "Word_" + text
	l.edge_hint = true
	return l


## Horizontal slab (floor or ceiling) as up to four quads around an optional hole.
static func _slab(st: SurfaceTool, r: Rect2, y: float, n: Vector3, col: Color, hole: Rect2) -> void:
	var parts: Array[Rect2] = []
	if hole.size == Vector2.ZERO or not r.intersects(hole):
		parts.append(r)
	else:
		var h := r.intersection(hole)
		parts.append(Rect2(r.position.x, r.position.y, r.size.x, h.position.y - r.position.y))            # north strip
		parts.append(Rect2(r.position.x, h.end.y, r.size.x, r.end.y - h.end.y))                             # south strip
		parts.append(Rect2(r.position.x, h.position.y, h.position.x - r.position.x, h.size.y))            # west
		parts.append(Rect2(h.end.x, h.position.y, r.end.x - h.end.x, h.size.y))                             # east
	for p in parts:
		if p.size.x <= 0.001 or p.size.y <= 0.001:
			continue
		SectorMesher._quad(st, Vector3(p.position.x, y, p.position.y), Vector3(p.end.x, y, p.position.y),
			Vector3(p.end.x, y, p.end.y), Vector3(p.position.x, y, p.end.y), n, col)


static func door_material() -> StandardMaterial3D:
	if _door_mat == null:
		_door_mat = StandardMaterial3D.new()
		_door_mat.albedo_texture = load("res://assets/textures/door.png")
		_door_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		_door_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_door_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		_door_mat.alpha_scissor_threshold = 0.5
		_door_mat.roughness = 1.0
		_door_mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return _door_mat


## A closed door leaf standing in its frame (a quad on the wall plane + a collider so it
## blocks sightlines). Kicking it turns it into a loose physics body (see kick_in).
## `col_a` / `col_b` are the wall colours of rooms a and b: a fill behind the leaf, one
## side each, so the door sprite's transparent edges never show the (unbuilt) room beyond.
static func build_door_leaf(d: FloorPlan.Door, is_open: bool, col_a := Color.WHITE, col_b := Color.WHITE) -> Node3D:
	var root := Node3D.new()
	root.name = "Door_%d" % d.index
	root.position = d.pos
	# looking_at points local -z along a->b: local +z faces room a, local -z faces room b
	root.basis = Basis.looking_at(Vector3(d.dir.x, 0, d.dir.y), Vector3.UP)
	root.set_meta("open", is_open)
	if is_open:
		return root    # an already-kicked door is simply gone
	var fill := MeshInstance3D.new()
	fill.name = "Fill"
	var fst := SurfaceTool.new()
	fst.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hw := DOOR_W * 0.5 + 0.03
	var hh := DOOR_H + 0.03
	# each backing sits just BEHIND the leaf as seen from its own room (room a looks
	# along -z at the door, so its backing is at -z, facing +z)
	SectorMesher._quad(fst, Vector3(-hw, -0.05, -0.012), Vector3(hw, -0.05, -0.012), Vector3(hw, hh, -0.012), Vector3(-hw, hh, -0.012), Vector3(0, 0, 1), col_a.darkened(0.12))
	SectorMesher._quad(fst, Vector3(-hw, -0.05, 0.012), Vector3(hw, -0.05, 0.012), Vector3(hw, hh, 0.012), Vector3(-hw, hh, 0.012), Vector3(0, 0, -1), col_b.darkened(0.12))
	fill.mesh = fst.commit()
	fill.material_override = SectorMesher.flat_material()
	root.add_child(fill)
	var leaf := MeshInstance3D.new()
	leaf.name = "Leaf"
	var qm := QuadMesh.new()
	qm.size = Vector2(DOOR_W, DOOR_H)
	leaf.mesh = qm
	leaf.material_override = door_material()
	leaf.position = Vector3(0, DOOR_H * 0.5, 0)
	root.add_child(leaf)
	var body := StaticBody3D.new()
	body.name = "Block"
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(DOOR_W, DOOR_H, 0.08)
	cs.shape = box
	cs.position = Vector3(0, DOOR_H * 0.5, 0)
	body.add_child(cs)
	root.add_child(body)
	return root


## Kick the door in: the leaf becomes a rigid body flung away from the kicker, tumbles,
## bounces off the floor and fades out. Sightlines open immediately (the body is on layer 2,
## which the LOS ray ignores).
static func kick_in(hinge: Node3D, d: FloorPlan.Door, from_room: int) -> void:
	if hinge.get_meta("open", false):
		return
	hinge.set_meta("open", true)
	var block := hinge.get_node_or_null("Block")
	if block != null:
		block.queue_free()
	var fill := hinge.get_node_or_null("Fill")
	if fill != null:
		fill.queue_free()
	var leaf: MeshInstance3D = hinge.get_node_or_null("Leaf")
	if leaf == null:
		return
	# fly AWAY from the kicker: local +z faces room a, so from room a the leaf goes -z
	var away_local := Vector3(0, 0, -1) if d.a == from_room else Vector3(0, 0, 1)
	var away := hinge.global_transform.basis * away_local
	var start := leaf.global_transform
	leaf.queue_free()
	_fling(hinge.get_parent(), start, away, DOOR_W, DOOR_H)


## Facade door: same fling, inward off the street.
static func kicked_leaf(d: FloorPlan.Door) -> Node3D:
	var inward := Vector3(-d.dir.x, 0, -d.dir.y)
	var xf := Transform3D(Basis.looking_at(inward, Vector3.UP), d.pos + Vector3(0, DOOR_H * 0.5, 0))
	var holder := Node3D.new()
	holder.name = "KickedDoor"
	holder.ready.connect(func(): _fling(holder, xf, inward, DOOR_W, DOOR_H))
	return holder


static func _fling(parent: Node, start: Transform3D, away: Vector3, w: float, h: float) -> void:
	var body := RigidBody3D.new()
	body.name = "FlyingDoor"
	body.collision_layer = 2
	body.collision_mask = 1
	body.mass = 12.0
	body.continuous_cd = true
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	# a touch smaller than the opening so it never starts wedged in the frame or the floor
	box.size = Vector3(w - 0.2, h - 0.2, 0.06)
	cs.shape = box
	body.add_child(cs)
	var mesh := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(w, h)
	mesh.mesh = qm
	var mat: StandardMaterial3D = door_material().duplicate()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material_override = mat
	body.add_child(mesh)
	# start a hair off the floor and past the wall plane, on the side it flies to
	body.global_transform = Transform3D(start.basis, start.origin + Vector3(0, 0.06, 0) + away * 0.12)
	# initial state is set as velocities (impulses applied before the body enters the
	# physics space can be dropped)
	body.linear_velocity = away * 5.5 + Vector3(0, 2.4, 0)
	body.angular_velocity = Vector3(away.z, 0.35, -away.x) * 7.0
	parent.add_child(body)
	var tw := body.create_tween()
	tw.tween_interval(2.2)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.8)
	tw.tween_callback(body.queue_free)


## Wall from p0 to p1, height H, minus holes [[t0, t1, y_lo, y_hi], ...] in metres along p0->p1.
static func _wall_with_holes(st: SurfaceTool, p0: Vector3, p1: Vector3, n: Vector3, H: float, holes: Array, col: Color) -> void:
	p0 = p0 + Vector3(0, -0.08, 0)
	p1 = p1 + Vector3(0, -0.08, 0)
	H += 0.08
	for h in holes:
		if h[2] > 0.0: h[2] += 0.08
		h[3] += 0.08
	var len := p0.distance_to(p1)
	var dir := (p1 - p0) / maxf(len, 0.001)
	holes.sort_custom(func(a, b): return a[0] < b[0])
	var cursor := 0.0
	for h in holes:
		var t0: float = clampf(h[0], 0.0, len)
		var t1: float = clampf(h[1], 0.0, len)
		if t1 <= t0:
			continue
		if t0 > cursor:
			_wq(st, p0, dir, cursor, t0, 0.0, H, n, col)
		if h[2] > 0.0:
			_wq(st, p0, dir, t0, t1, 0.0, h[2], n, col)
		if h[3] < H:
			_wq(st, p0, dir, t0, t1, h[3], H, n, col)
		cursor = maxf(cursor, t1)
	if cursor < len - 0.001:
		_wq(st, p0, dir, cursor, len, 0.0, H, n, col)


static func _wq(st: SurfaceTool, p0: Vector3, dir: Vector3, ta: float, tb: float, ya: float, yb: float, n: Vector3, col: Color) -> void:
	var a := p0 + dir * ta + Vector3(0, ya, 0)
	var b := p0 + dir * tb + Vector3(0, ya, 0)
	var c := p0 + dir * tb + Vector3(0, yb, 0)
	var d := p0 + dir * ta + Vector3(0, yb, 0)
	# baked shading: a darker band low on the wall (skirting/shadow), full colour above
	var lo := col.darkened(0.35) if ya < 0.5 else col
	var hi := col.darkened(0.35) if yb < 0.5 else col
	SectorMesher._quad4(st, a, b, c, d, n, lo, lo, hi, hi)
