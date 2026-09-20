extends Node
func _ready() -> void:
	var sd := World.get_sector(0, -1)
	var node := SectorMesher.build(sd)
	add_child(node)
	var mmi: MultiMeshInstance3D = node.get_node("DoorLeaves")
	var mm := mmi.multimesh
	print("instances: ", mm.instance_count, "  visible: ", mm.visible_instance_count, "  aabb: ", mm.get_aabb(), "  mesh: ", mm.mesh)
	var b := sd.buildings[19]
	print("building ", b.id(), " door_tile ", b.door_tile, " road_tile ", b.road_tile, " rect ", b.rect)
	print("leaf xform: ", mm.get_instance_transform(19))
	var fp := InteriorGen.generate(World.seed, b, 0)
	print("entrance pos: ", fp.doors[fp.entrance_door].pos, " dir ", fp.doors[fp.entrance_door].dir)
	print("mmi visible ", mmi.visible, " global aabb ", mmi.get_aabb())
	get_tree().quit()
