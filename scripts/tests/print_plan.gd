extends Node
## Print ASCII floor plans of the first few apartment blocks (debug).
func _ready() -> void:
	World.seed = 1337
	var n := 0
	for sy in range(-1, 2):
		for sx in range(-1, 2):
			for b in World.get_sector(sx, sy).buildings:
				if b.kind != "apartments" or n >= 2:
					continue
				n += 1
				for f in [0, 1]:
					var fp := InteriorGen.generate(World.seed, b, f)
					print("%s floor %d  cells %s  rooms %d  stair %d (%s)" % [b.id(), f, fp.cells, fp.rooms.size(), fp.stair_room, fp.stair_layout.get("along")])
					for y in fp.cells.y:
						var line := ""
						for x in fp.cells.x:
							var ri := fp.room_at_cell(Vector2i(x, y))
							var k: String = fp.rooms[ri].kind
							var glyph: String = { "stair": "S", "hall": "=", "living": "L", "kitchen": "K", "bathroom": "B", "bedroom": "R", "studio": "U" }.get(k, "?")
							line += glyph + ("%d" % (ri % 10))
							line += " "
						print(line)
					var ds := []
					for d in fp.doors:
						ds.append("%d-%d:%s" % [d.a, d.b, d.word])
					print("  doors: ", ", ".join(ds))
					print("  furniture: ", fp.props.size())
	get_tree().quit(0)
