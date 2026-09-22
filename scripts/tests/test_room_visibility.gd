extends Node
## Unrevealed rooms retain an opaque structural shell, while their furniture and zombies
## remain hidden. Furniture source sprites must carry real transparent backgrounds.

var _failed := false


func _ready() -> void:
	World.persistence_enabled = false
	World.state.clear()
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

	if not _failed:
		print("ROOM VISIBILITY OK  structural occlusion + hidden encounters + transparent props")
	get_tree().quit(1 if _failed else 0)


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error("ROOM VISIBILITY FAIL: " + message)
