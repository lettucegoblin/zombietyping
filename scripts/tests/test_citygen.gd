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
	# connectivity: every road tile reachable from the frame
	var bad := 0
	for sy in range(-3, 4):
		for sx in range(-3, 4):
			var sd := CityGen.generate(seed, sx, sy)
			if not CityGen._connected(sd):
				bad += 1
	print("disconnected sectors in 7x7: ", bad)
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
