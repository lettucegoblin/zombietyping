extends SceneTree
## Headless smoke test:  Godot --headless --path . -s res://scripts/tests/test_citygen.gd
## Prints an ASCII map of a 3x3 sector window around the origin plus stats.

func _init() -> void:
	var seed := 1337
	var t0 := Time.get_ticks_usec()
	var stats := {}
	var total_b := 0
	var lines: Array[String] = []
	var S := SectorData.SIZE
	var W := 3
	for row in range(S * W):
		lines.append("")
	for sy in range(0, W):
		for sx in range(0, W):
			var sd := CityGen.generate(seed, sx, sy)
			var dname: String = District.NAME[sd.district]
			stats[dname] = stats.get(dname, 0) + 1
			total_b += sd.buildings.size()
			for ly in S:
				var s := ""
				for lx in S:
					var r := sd.road[ly * S + lx]
					var l := sd.lot[ly * S + lx]
					if r == 2: s += "#"
					elif r == 1: s += "+"
					elif l != 0:
						var b := sd.buildings[l - 1]
						s += "D" if b.door_tile == sd.origin_tile() + Vector2i(lx, ly) else ("B" if b.floors < 4 else "T")
					elif sd.district == District.Kind.PARK: s += ","
					else: s += "."
				lines[sy * S + ly] += s
	var dt := (Time.get_ticks_usec() - t0) / 1000.0
	for l in lines:
		print(l)
	print("sectors=%d  buildings=%d  gen_ms=%.1f  (%.2f ms/sector)" % [W * W, total_b, dt, dt / (W * W)])
	print("districts: ", stats)
	# determinism check
	var a := CityGen.generate(seed, 1, 1)
	var b := CityGen.generate(seed, 1, 1)
	var same := a.road == b.road and a.lot == b.lot and a.buildings.size() == b.buildings.size()
	for i in a.buildings.size():
		if a.buildings[i].rect != b.buildings[i].rect or a.buildings[i].floors != b.buildings[i].floors:
			same = false
	print("deterministic: ", same)
	# Connectivity is a global invariant now: sectors are streaming chunks, not blocks
	# framed by roads. Assemble a 7x7 window and count graph components across its seams.
	var roads := {}
	var higher_roads := {}
	var class_bad := 0
	for sy in range(-3, 4):
		for sx in range(-3, 4):
			var sd := CityGen.generate(seed, sx, sy)
			var org := sd.origin_tile()
			for ly in S:
				for lx in S:
					var t := org + Vector2i(lx, ly)
					var cls := sd.road[SectorData.idx(lx, ly)]
					if cls != CityGen.road_class_at(seed, t): class_bad += 1
					if cls != 0: roads[t] = true
					if cls == 2: higher_roads[t] = true
	var seen := {}
	var components := 0
	var component_sizes: Array[int] = []
	var spawn_component_size := 0
	for start in roads:
		if seen.has(start): continue
		components += 1
		var q: Array[Vector2i] = [start]
		seen[start] = true
		var component_size := 0
		var has_spawn := false
		while not q.is_empty():
			var cur: Vector2i = q.pop_back()
			component_size += 1
			if cur == Vector2i(16, 0): has_spawn = true
			for dir: Vector2i in CityGen.DIRS:
				var n := cur + dir
				if roads.has(n) and not seen.has(n):
					seen[n] = true
					q.append(n)
		component_sizes.append(component_size)
		if has_spawn: spawn_component_size = component_size
	component_sizes.sort()
	print("road components in 7x7: ", components, " ", component_sizes, "  class mismatches: ", class_bad)
	var higher_seen := {}
	var higher_components := 0
	for start in higher_roads:
		if higher_seen.has(start): continue
		higher_components += 1
		var q: Array[Vector2i] = [start]
		higher_seen[start] = true
		while not q.is_empty():
			var cur: Vector2i = q.pop_back()
			for dir: Vector2i in CityGen.DIRS:
				var n := cur + dir
				if higher_roads.has(n) and not higher_seen.has(n):
					higher_seen[n] = true
					q.append(n)
	print("higher-road components in 7x7: ", higher_components)
	# A contour clipped by the OUTER test-window edge may appear as a tiny component even
	# though it reconnects outside the sample. The spawn/main network must contain all but
	# at most that short edge fragment.
	if class_bad > 0 or not roads.has(Vector2i(16, 0)) or roads.size() - spawn_component_size > 16:
		push_error("CITYGEN FAIL")
		quit(1)
	# macro district map (letters), 40x20 sectors around the start
	var hist := {}
	print("--- district map: a=downtown b=residential c=suburb e=strip d=industrial f=park  (start at col 12,row 8 marked *) ---")
	for my in range(-8, 12):
		var row := ""
		for mx in range(-12, 28):
			var k := CityGen.district_at(seed, mx, my)
			var ch: String = District.LETTER[k]
			hist[ch] = hist.get(ch, 0) + 1
			row += "*" if (mx == 0 and my == 0) else ch
		print(row)
	print("district histogram (800 sectors): ", hist)
	quit()
