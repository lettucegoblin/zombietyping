class_name MapLabels
## Short typeable labels for the buildings inside a map window. Number = left-to-right
## order, letter = row band from the top of the window (6 tiles per band): "1a", "2a", "1b"…
## Digit-first so they can be typed straight from the HUD: no door or zombie word starts
## with a digit, so the first key tells the Typist it is a destination.
## Only buildings you have SEEN (explored footprint or door tile) get a label.

const BAND_TILES := 6


## -> { "labels": {label: building_id}, "placed": [{label, b}] }
static func assign(r: Rect2i) -> Dictionary:
	var labels := {}
	var placed: Array = []
	var s0 := World.sector_of_tile(r.position)
	var s1 := World.sector_of_tile(r.end)
	var bands: Dictionary = {}
	for sy in range(s0.y, s1.y + 1):
		for sx in range(s0.x, s1.x + 1):
			for b in World.get_sector(sx, sy).buildings:
				var c := b.center_tile()
				if c.x < r.position.x or c.x > r.end.x or c.y < r.position.y or c.y > r.end.y:
					continue
				if not seen(b):
					continue
				var band := floori((c.y - float(r.position.y)) / BAND_TILES)
				if not bands.has(band):
					bands[band] = []
				bands[band].append(b)
	var band_keys := bands.keys()
	band_keys.sort()
	var letter := 0
	for bk in band_keys:
		if letter >= 26:
			break
		var arr: Array = bands[bk]
		arr.sort_custom(func(a, b): return a.center_tile().x < b.center_tile().x)
		var n := 1
		for b in arr:
			var label := "%d%s" % [n, char(97 + letter)]
			labels[label] = b.id()
			placed.append({ "label": label, "b": b })
			n += 1
		letter += 1
	return { "labels": labels, "placed": placed }


static func seen(b: BuildingData) -> bool:
	# a building is known once any tile of its footprint (or its door road tile) is explored
	if World.is_explored(b.road_tile):
		return true
	for y in range(b.rect.position.y, b.rect.end.y):
		for x in range(b.rect.position.x, b.rect.end.x):
			if World.is_explored(Vector2i(x, y)):
				return true
	return false
