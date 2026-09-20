extends Node
func _ready() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	var map: Control = main.get_node("UI/TabMap")
	map.size = Vector2(1280, 720)
	main._toggle_map()
	map.recompute_labels()
	var keys: Array = map._labels.keys()
	keys.sort()
	for l in keys:
		var b := World.building_by_id(map._labels[l])
		print("%s -> %s  floors=%d  %s" % [l, b.id(), b.floors, District.NAME[b.district]])
	get_tree().quit()
