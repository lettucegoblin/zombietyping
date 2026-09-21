extends Node

func _ready() -> void:
	call_deferred("_setup")


func _setup() -> void:
	await get_tree().process_frame
	var main: Node = get_parent()
	var player: Node3D = main.player
	var sd := World.get_sector(0, 0)
	var b: BuildingData = sd.buildings[0]
	var best := 999999.0
	for candidate in sd.buildings:
		if not World.car_exists(candidate):
			continue
		var d: float = Vector2(candidate.road_tile - player.tile).length_squared()
		if d < best:
			best = d
			b = candidate
	World.mark_explored(b.road_tile, 42)
	World.set_building_state(b.id(), "visited", true)
	World.set_building_state(b.id(), "cleared", true)
	World.salvage_building(b.id())
	World.salvage_car(b.id())
	World.salvage_car(b.id())
	World.fortify_building(b.id())
	World.claim_building(b.id())
	World.add_materials({ "building_materials": 40, "wood": 30, "metal": 20, "tools": 8, "textiles": 10 })
	World.build_farm(b.id())
	var r := World.safe_rect_world(b)
	World.place_item(b.id(), "crate", Vector3(r.get_center().x - 2, 0.05, r.get_center().y + 2), 0.0)
	World.place_item(b.id(), "chair", Vector3(r.get_center().x + 2, 0.05, r.get_center().y + 2), 0.0)
	player.snap_to_road(b.road_tile)
	main._enter_safezone(b)
	player.global_position = Vector3(r.position.x + 2.0, 0.0, r.end.y - 2.0)
	player.facing = Vector3(1, 0, 0)
	await get_tree().create_timer(0.5).timeout
	main.typist.enabled = false
	main.map.open()
	main.map._selected_id = b.id()
	DirAccess.make_dir_absolute("res://artifacts")
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://artifacts/settlement_map.png")
	main.map.close()
	await get_tree().create_timer(0.4).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://artifacts/settlement_safezone.png")
	print("PREVIEW CAPTURED")
	get_tree().quit()
