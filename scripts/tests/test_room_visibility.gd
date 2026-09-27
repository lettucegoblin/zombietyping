extends Node
## Unrevealed rooms retain an opaque structural shell, while their furniture and zombies
## remain hidden. Furniture source sprites must carry real transparent backgrounds.

var _failed := false


func _ready() -> void:
	World.persistence_enabled = false
	World.state.clear()
	_check_entrance_lanes()
	_check_ceiling_palette()
	_check_furnishing_clearance_and_wall_art()
	var b: BuildingData = World.get_sector(0, 0).buildings[2]
	var interior = load("res://scripts/interior/interior.gd").new()
	add_child(interior)
	interior.enter(b, 0)
	var entrance: int = interior.entrance_room()
	interior._reveal(entrance)
	var hidden := -1
	for ri in interior.plan.rooms.size():
		if not interior.is_room_revealed(ri):
			hidden = ri
			break
	_check(hidden >= 0, "fixture had no unrevealed room")
	if hidden >= 0:
		var room: Node3D = interior._room_nodes[hidden]
		var shell: MeshInstance3D = room.get_node("Mesh")
		_check(shell.visible, "unrevealed room shell became a see-through hole")
		var furnishings: Node3D = room.get_node_or_null("Furnishings")
		if furnishings != null:
			for visual in furnishings.find_children("*", "VisualInstance3D", true, false):
				_check(not (visual as VisualInstance3D).visible, "unrevealed furniture was visible")

		var player := Node3D.new()
		add_child(player)
		var director = load("res://scripts/zombies/director.gd").new()
		director.player = player
		director.interior = interior
		add_child(director)
		var zombie: Zombie = director._spawn(ZombieType.shambler(), interior.plan.room_stand_world(hidden), hidden, true)
		director._sync_room_visibility()
		_check(not zombie.visible and not zombie.in_los, "zombie in an unrevealed room was rendered or targetable")
		interior._reveal(hidden)
		director._sync_room_visibility()
		_check(zombie.visible, "revealing a room did not reveal its zombie")

	for path in InteriorMesher.PROP_SPRITES.values():
		var image := Image.load_from_file(ProjectSettings.globalize_path(str(path)))
		_check(not image.is_empty() and image.get_pixel(0, 0).a < 0.01, "%s has an opaque background" % path)
	var bed := Image.load_from_file(ProjectSettings.globalize_path("res://assets/sprites/props/bed.png"))
	var bed_bounds := bed.get_used_rect()
	_check(float(bed_bounds.size.x) / maxf(float(bed_bounds.size.y), 1.0) > 1.8,
		"bed art was not a grounded side profile")

	# 0,0:2 is also the fixed TV fixture. Leaving a building must stop its directional
	# static synchronously, before deferred room deletion can leak a tail outdoors.
	interior.reveal_all()
	var tv_audio: Array[Node] = interior.find_children("*", "AudioStreamPlayer3D", true, false)
	_check(not tv_audio.is_empty(), "fixture generated no television audio source")
	for audio in tv_audio:
		_check((audio as AudioStreamPlayer3D).bus == "Television", "TV static bypassed its mixer bus")
	interior.unload()
	for audio in tv_audio:
		_check(not (audio as AudioStreamPlayer3D).playing, "television static survived interior unload")

	if not _failed:
		print("ROOM VISIBILITY OK  clear furnished doorways + continuous opening gradients + fixed wall art + room-tinted ceilings + structural occlusion + hidden encounters + transparent props + TV audio teardown")
	get_tree().quit(1 if _failed else 0)


## A facade door must lead through the middle of one interior cell. If its along-wall
## coordinate lands on a cell boundary, the entry rail runs coplanar with a partition and
## an infinitely thin wall can divide the camera while exposing both adjacent rooms.
func _check_entrance_lanes() -> void:
	var checked := 0
	for sy in range(-1, 2):
		for sx in range(-1, 2):
			for b in World.get_sector(sx, sy).buildings:
				var fp := InteriorGen.generate(World.seed, b, 0)
				if fp.entrance_door < 0:
					continue
				var door: FloorPlan.Door = fp.doors[fp.entrance_door]
				var centre := fp.cell_to_world(Vector2(door.cell) + Vector2(0.5, 0.5))
				var along_delta := absf(door.pos.z - centre.z) if door.dir.x != 0 else absf(door.pos.x - centre.x)
				_check(along_delta < 0.001, "%s entrance was not centred in its facade cell" % b.id())
				var inward := Vector3(-door.dir.x, 0, -door.dir.y)
				_check(fp.room_at_cell(door.cell) == door.a, "%s entrance cell belongs to another room" % b.id())
				var inside := door.pos + inward * 1.3
				_check(_room_at(fp, inside) == door.a, "%s entry rail crossed a partition before its stopping point" % b.id())
				var leaf := SectorMesher.door_leaf_transform(b, 0.0).origin
				var leaf_delta := absf(leaf.z - door.pos.z) if door.dir.x != 0 else absf(leaf.x - door.pos.x)
				_check(leaf_delta < 0.001, "%s facade leaf and interior opening disagree" % b.id())
				checked += 1
				if checked >= 96:
					return


func _room_at(fp: FloorPlan, p: Vector3) -> int:
	var c := Vector2i(floori((p.x - fp.origin.x) / fp.cell_size.x), floori((p.z - fp.origin.z) / fp.cell_size.y))
	return fp.room_at_cell(c)


func _check_ceiling_palette() -> void:
	for wall_col in InteriorMesher.WALL_COLS:
		var ceiling := InteriorMesher.ceiling_color(wall_col)
		_check(ceiling.is_equal_approx(wall_col), "ceiling lost its room wall swatch")
		var wall_height := World.FLOOR_M + 0.08
		var lintel_height := InteriorMesher.DOOR_H + 0.08
		var expected: Color = wall_col.darkened(0.35).lerp(wall_col, lintel_height / wall_height)
		var lintel: Color = InteriorMesher.wall_tint_at_height(wall_col, lintel_height, wall_height)
		_check(lintel.is_equal_approx(expected), "door/window cap sampled a different wall gradient")
		_check(not lintel.is_equal_approx(wall_col), "opening cap reverted to a flat full-strength swatch")


func _check_furnishing_clearance_and_wall_art() -> void:
	var paintings := 0
	var target := InteriorGen.generate(World.seed, World.get_sector(0, 0).buildings[2], 0)
	var target_kinds: Dictionary = {}
	for target_prop in target.props:
		target_kinds[target_prop.kind] = true
	var target_has_art := target_kinds.has("painting") or target_kinds.has("poster_space") or target_kinds.has("poster_band")
	_check(target_kinds.has("tv") and target_kinds.has("shelf") and target_has_art,
		"0,0:2 fixed its doorway by deleting the reported furnishings")
	for sy in range(-1, 2):
		for sx in range(-1, 2):
			for b in World.get_sector(sx, sy).buildings:
				for floor in b.floors:
					var fp := InteriorGen.generate(World.seed, b, floor)
					for prop in fp.props:
						_check(not InteriorGen.prop_overlaps_door_clearance(fp, prop),
							"%s floor %d %s occupied a door/window opening" % [b.id(), floor, prop.kind])
						if InteriorMesher.PropVisuals.is_billboard(prop.kind):
							var visible_width := InteriorMesher.PropVisuals.visible_size(prop.kind, prop.size).x
							var footprint := InteriorGen._rotated_footprint_size(prop)
							_check(footprint.x + 0.001 >= visible_width and footprint.y + 0.001 >= visible_width,
								"%s placement ignored its %.2fm rendered width" % [prop.kind, visible_width])
						if prop.kind not in ["painting", "poster_space", "poster_band"]:
							continue
						paintings += 1
						var visual := InteriorMesher._sprite_prop(prop)
						_check(visual is MeshInstance3D and not visual is Sprite3D,
							"wall art was not rendered as a fixed wall plane")
						_check(bool(visual.get_meta("wall_art", false)), "wall art lost its marker")
						visual.free()
	_check(paintings > 0, "fixture generated no paintings or posters")


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error("ROOM VISIBILITY FAIL: " + message)
