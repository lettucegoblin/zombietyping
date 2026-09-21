extends Node
## Generator invariants for stairwells across many buildings/storeys.
## Godot --headless --path . res://scenes/tests/check_stairs.tscn

func _ready() -> void:
	World.seed = 1337
	var checked := 0
	var kinds := { 0: 0, 1: 0 }
	var apartments := 0
	var furnished := 0
	var bad := 0
	for sy in range(-2, 3):
		for sx in range(-2, 3):
			for b in World.get_sector(sx, sy).buildings:
				if b.floors < 2:
					continue
				var lay0 := {}
				for f in b.floors:
					var fp := InteriorGen.generate(World.seed, b, f)
					if fp.stair_room < 0:
						print("no stairwell: ", b.id(), " cells ", fp.cells); bad += 1; continue
					if f == 0:
						lay0 = fp.stair_layout
						kinds[int(lay0["kind"])] += 1
						if b.kind == "apartments":
							apartments += 1
					if b.kind == "apartments" and fp.rooms[0].kind == "hall":
						# Every procedural unit has a complete room program and enters through
						# its living room onto the corridor or stair landing.
						var units := {}
						for r in fp.rooms:
							if r.unit >= 0:
								if not units.has(r.unit): units[r.unit] = {}
								units[r.unit][r.kind] = true
						for uid in units:
							for required in ["living", "bedroom", "bathroom", "kitchen"]:
								if not units[uid].has(required):
									print("unit missing ", required, ": ", b.id(), " floor ", f, " unit ", uid); bad += 1
							for r in fp.rooms:
								if r.unit != uid or r.kind != "living": continue
								var onto := false
								for di in r.doors:
									var o := fp.other_room(di, r.index)
									if o == 0 or o == fp.stair_room: onto = true
								if not onto:
									print("unit without corridor/landing door: ", b.id(), " floor ", f, " unit ", uid); bad += 1
						var stair_ok := false
						for di in fp.rooms[fp.stair_room].doors:
							if fp.other_room(di, fp.stair_room) == 0:
								stair_ok = true
						if not stair_ok:
							print("apartment stairwell not on the corridor: ", b.id()); bad += 1
					elif fp.stair_layout["rect"] != lay0["rect"] or fp.stair_layout["along"] != lay0["along"]:
						print("stairwell moves between storeys: ", b.id()); bad += 1
					# every cell belongs to a room
					for i in fp.cell_room.size():
						if fp.cell_room[i] < 0:
							print("uncovered cell in ", b.id(), " floor ", f); bad += 1; break
					# doors: at least one, each with a word
					var openings := 0
					for di in fp.rooms[fp.stair_room].doors:
						var d := fp.doors[di]
						if d.word == "":
							print("stair door without a word: ", b.id()); bad += 1
						openings += 1
					if openings == 0:
						print("stairwell has no door: ", b.id(), " floor ", f, " kind ", lay0["kind"]); bad += 1
					# connectivity through all doors
					var seen := { 0: true }
					var q := [0]
					while not q.is_empty():
						var r: int = q.pop_front()
						for di in fp.rooms[r].doors:
							var o := fp.other_room(di, r)
							if o >= 0 and not seen.has(o):
								seen[o] = true
								q.append(o)
					if seen.size() != fp.rooms.size():
						print("disconnected plan: ", b.id(), " floor ", f, " ", seen.size(), "/", fp.rooms.size()); bad += 1
					# climb path is finite and ends one storey up
					if f < b.floors - 1:
						var pts := Stairwell.climb_points(fp, fp.stair_layout, true)
						if pts.is_empty() or absf(pts[-1].y - (fp.origin.y + World.FLOOR_M)) > 0.01:
							print("bad climb path: ", b.id()); bad += 1
					if not fp.props.is_empty():
						furnished += 1
					checked += 1
	if furnished < checked * 0.8:
		print("too few furnished storeys: ", furnished, "/", checked); bad += 1
	print("checked %d storeys; core %d, wall %d buildings (%d apartment blocks); furnished %d; problems %d" % [checked, kinds[0], kinds[1], apartments, furnished, bad])
	if bad > 0:
		push_error("STAIRS FAIL")
		get_tree().quit(1)
	else:
		print("STAIRS OK")
		get_tree().quit(0)
