class_name MapLabels
## Stable, digit-first building addresses shared by the minimap, Tab map, HUD typing, and
## first-person reticle. Addresses stay attached to a building while it remains in the
## survivor's broad neighbourhood. They are only recycled after travelling far enough that
## the building is well outside both the rendered city and map selection range.

const WORLD_LABEL_RANGE_TILES := 80.0       # 400 m: matches the first-person camera far plane
const RETAIN_RANGE_MULTIPLIER := 3.0         # only recycle after the player is ~1.2 km away

static var _id_to_label: Dictionary = {}
static var _label_to_id: Dictionary = {}
static var _id_to_center: Dictionary = {}
static var _id_to_slot: Dictionary = {}
static var _free_slots: Array[int] = []
static var _next_slot := 0


## -> { "labels": {label: building_id}, "placed": [{label, b}] }
## `r` is the map region currently being presented. `origin` and `max_range` keep even a
## zoomed-out Tab map bounded to the same useful distance as the rendered city.
static func assign(r: Rect2i, origin := Vector2.INF,
		max_range := WORLD_LABEL_RANGE_TILES, prune_far := false) -> Dictionary:
	var scan := r
	if origin != Vector2.INF and is_finite(max_range):
		var lo := Vector2i(floori(origin.x - max_range), floori(origin.y - max_range))
		var hi := Vector2i(ceili(origin.x + max_range), ceili(origin.y + max_range))
		scan = scan.intersection(Rect2i(lo, hi - lo + Vector2i.ONE))
	if scan.size.x <= 0 or scan.size.y <= 0:
		return { "labels": {}, "placed": [] }
	if prune_far and origin != Vector2.INF:
		prune(origin, max_range * RETAIN_RANGE_MULTIPLIER)

	var buildings: Array[BuildingData] = []
	var s0 := World.sector_of_tile(scan.position)
	var s1 := World.sector_of_tile(scan.end - Vector2i.ONE)
	for sy in range(s0.y, s1.y + 1):
		for sx in range(s0.x, s1.x + 1):
			for b in World.get_sector(sx, sy).buildings:
				var c := b.center_tile()
				if not scan.has_point(Vector2i(floori(c.x), floori(c.y))):
					continue
				if origin != Vector2.INF and c.distance_to(origin) > max_range:
					continue
				buildings.append(b)
	buildings.sort_custom(func(a: BuildingData, b: BuildingData):
		var ac := a.center_tile()
		var bc := b.center_tile()
		if not is_equal_approx(ac.y, bc.y):
			return ac.y < bc.y
		if not is_equal_approx(ac.x, bc.x):
			return ac.x < bc.x
		return a.id() < b.id()
	)

	var labels := {}
	var placed: Array = []
	for b in buildings:
		var label := ensure_label(b)
		labels[label] = b.id()
		placed.append({ "label": label, "b": b })
	return { "labels": labels, "placed": placed }


static func ensure_label(b: BuildingData) -> String:
	var id := b.id()
	if _id_to_label.has(id):
		_id_to_center[id] = b.center_tile()
		return _id_to_label[id]
	var slot: int
	if not _free_slots.is_empty():
		_free_slots.sort()
		slot = _free_slots.pop_front()
	else:
		slot = _next_slot
		_next_slot += 1
	var label := _slot_label(slot)
	_id_to_label[id] = label
	_label_to_id[label] = id
	_id_to_center[id] = b.center_tile()
	_id_to_slot[id] = slot
	return label


static func label_for_id(id: String) -> String:
	return str(_id_to_label.get(id, ""))


static func seen(b: BuildingData) -> bool:
	if World.is_explored(b.road_tile):
		return true
	for y in range(b.rect.position.y, b.rect.end.y):
		for x in range(b.rect.position.x, b.rect.end.x):
			if World.is_explored(Vector2i(x, y)):
				return true
	return false


## Recycling is deliberately conservative. A building keeps its address through ordinary
## travel and map panning; only a journey several complete render ranges away releases it.
static func prune(origin: Vector2, retain_range: float) -> void:
	for id in _id_to_label.keys().duplicate():
		var c: Vector2 = _id_to_center.get(id, Vector2.INF)
		if c != Vector2.INF and c.distance_to(origin) <= retain_range:
			continue
		var label: String = _id_to_label[id]
		_label_to_id.erase(label)
		_id_to_label.erase(id)
		_id_to_center.erase(id)
		_free_slots.append(int(_id_to_slot.get(id, 0)))
		_id_to_slot.erase(id)


static func reset_cache() -> void:
	_id_to_label.clear()
	_label_to_id.clear()
	_id_to_center.clear()
	_id_to_slot.clear()
	_free_slots.clear()
	_next_slot = 0


## Nine numeric prefixes times a fixed two-letter suffix: 1aa..9zz. Fixed width matters:
## HUD destinations commit as soon as an exact address is typed, so `1a` and `1aa` must
## never coexist as an ambiguous prefix pair. 6,084 live addresses is comfortably above
## the bounded retention neighbourhood and naturally permits addresses such as `5de`.
static func _slot_label(slot: int) -> String:
	var letters := floori(float(slot) / 9.0)
	if letters >= 26 * 26:
		push_error("stable building address pool exhausted; prune range is too large")
		letters = posmod(letters, 26 * 26)
	return "%d%s%s" % [posmod(slot, 9) + 1,
		char(97 + floori(float(letters) / 26.0)), char(97 + posmod(letters, 26))]
