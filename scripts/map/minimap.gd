extends Control
## Always-on minimap (top right): the Tab map's textures around the survivor, north up,
## with the same stable digit-first labels — type one and the rail goes there, no Tab needed.
## The address registry covers the whole rendered neighbourhood, including buildings under
## fog; drawing remains clipped to this small view.

const S := SectorData.SIZE
const PPT := 5.0                  # pixels per tile
const RELABEL_DRIFT := 10.0       # tiles of travel before labels move with you
const COL_ROUTE := Color("#ffd166")
const COL_PLAYER := Color("#ff5a36")
const COL_QUEUED := Color("#ffd166")
const LABEL_NUDGE_STEP := 5.0
const LABEL_NUDGE_RINGS := 8
const LABEL_OVERSCAN := 42.0       # laid out offscreen, then clipped for smooth edge entry
const LABEL_DENSITY_DIVISOR := 4   # full registry stays typeable; the glance map stays calm
const MIN_NEARBY_LABELS := 8

var player: Node3D
var tab_map: Control              # texture cache + fog dirty tracking live there
var labels: Dictionary = {}       # label -> building id (current window)
var _placed: Array = []
var _label_offsets: Dictionary = {} # building id -> persistent nudge from its map anchor
var _label_center := Vector2(INF, INF)
var _was_moving := false
var _font: Font
var typing := ""                  # destination being typed (shown under the map)
var _msg := ""
var _msg_until := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	clip_contents = true
	_font = ThemeDB.fallback_font


func flash(msg: String) -> void:
	_msg = msg
	_msg_until = Time.get_ticks_msec() / 1000.0 + 2.5


func _process(_dt: float) -> void:
	if player == null:
		return
	var moving: bool = player.is_moving() and not player.halt
	var c := Vector2(player.tile) + Vector2(0.5, 0.5)
	var drift := c.distance_to(_label_center) if _label_center.x != INF else INF
	if (_was_moving and not moving) or drift > RELABEL_DRIFT:
		relabel()
	_was_moving = moving
	queue_redraw()


## Typeable labels cover the same broad range as visible streamed buildings. This means a
## first-person reticle label is always a valid destination even when it lies off the small
## minimap or under unrevealed fog.
func relabel() -> void:
	_label_center = Vector2(player.tile) + Vector2(0.5, 0.5)
	var radius := MapLabels.WORLD_LABEL_RANGE_TILES
	var lo := Vector2i(floori(_label_center.x - radius), floori(_label_center.y - radius))
	var hi := Vector2i(ceili(_label_center.x + radius), ceili(_label_center.y + radius))
	var res := MapLabels.assign(Rect2i(lo, hi - lo + Vector2i.ONE), _label_center, radius, true)
	labels = res["labels"]
	_placed = res["placed"]
	# The address registry only forgets a building after it is several complete view ranges
	# away. Keep the visual nudge for exactly as long, so ordinary streaming at the edge of
	# the minimap cannot make labels already on-screen jump.
	for id in _label_offsets.keys():
		if MapLabels.label_for_id(str(id)) == "":
			_label_offsets.erase(id)


func ensure_building_label(b: BuildingData) -> String:
	var label := MapLabels.ensure_label(b)
	labels[label] = b.id()
	var found := false
	for entry in _placed:
		if (entry["b"] as BuildingData).id() == b.id():
			found = true
			break
	if not found:
		_placed.append({ "label": label, "b": b })
	return label


func _window_tiles(center: Vector2) -> Rect2i:
	var half := size / PPT * 0.5
	var t0 := Vector2i(floori(center.x - half.x), floori(center.y - half.y))
	var t1 := Vector2i(ceili(center.x + half.x), ceili(center.y + half.y))
	return Rect2i(t0, t1 - t0)


func has_label_prefix(prefix: String) -> bool:
	for l in labels.keys():
		if (l as String).begins_with(prefix):
			return true
	return false


func _tile_to_screen(t: Vector2, center: Vector2) -> Vector2:
	return (t - center) * PPT + size * 0.5


## Keep addresses legible in dense blocks. The search order is deterministic, so labels
## settle into the same nearby slot instead of vibrating between positions as the map scrolls.
## An address that cannot fit is only hidden visually; it remains in `labels` and typeable.
func _nudged_label_rect(anchor: Vector2, box_size: Vector2,
		occupied: Array[Rect2], bounds: Rect2) -> Rect2:
	return _stable_label_rect("", anchor, box_size, occupied, bounds)


func _stable_label_rect(id: String, anchor: Vector2, box_size: Vector2,
		occupied: Array[Rect2], bounds: Rect2) -> Rect2:
	if id != "" and _label_offsets.has(id):
		var remembered_offset: Vector2 = _label_offsets[id]
		var remembered := Rect2(anchor + remembered_offset - box_size * 0.5, box_size)
		if not bounds.encloses(remembered):
			return Rect2()
		for used in occupied:
			if used.intersects(remembered.grow(1.0)):
				# Never move a settled label because a newcomer appeared. Hiding the later
				# claimant for this frame is less distracting and both addresses remain typeable.
				return Rect2()
		return remembered
	for ring in range(LABEL_NUDGE_RINGS + 1):
		for gy in range(-ring, ring + 1):
			for gx in range(-ring, ring + 1):
				if ring > 0 and absi(gx) != ring and absi(gy) != ring:
					continue
				var offset := Vector2(gx, gy) * LABEL_NUDGE_STEP
				var rect := Rect2(anchor + offset - box_size * 0.5, box_size)
				if not bounds.encloses(rect):
					continue
				var blocked := false
				for used in occupied:
					if used.intersects(rect.grow(1.0)):
						blocked = true
						break
				if not blocked:
					if id != "":
						_label_offsets[id] = rect.get_center() - anchor
					return rect
	return Rect2()


## Reserve remembered rectangles before considering any newcomer. Candidate order may
## change when typing/queue priority changes, but that must never let a new label steal a
## settled label's slot for one frame.
func _layout_label_candidates(candidates: Array, bounds: Rect2,
		blockers: Array[Rect2]) -> Dictionary:
	var layout := {}
	var occupied: Array[Rect2] = []
	var stable_candidates := candidates.duplicate()
	stable_candidates.sort_custom(func(a, b): return str(a["id"]) < str(b["id"]))
	for candidate in stable_candidates:
		var id := str(candidate["id"])
		if not _label_offsets.has(id):
			continue
		var rect := _stable_label_rect(id, candidate["anchor"], candidate["size"], occupied, bounds)
		if rect.size != Vector2.ZERO:
			layout[id] = rect
			occupied.append(rect)
	occupied.append_array(blockers)
	for candidate in stable_candidates:
		var id := str(candidate["id"])
		if _label_offsets.has(id):
			continue
		var rect := _stable_label_rect(id, candidate["anchor"], candidate["size"], occupied, bounds)
		if rect.size != Vector2.ZERO:
			layout[id] = rect
			occupied.append(rect)
	return layout


func _draw() -> void:
	if player == null or tab_map == null:
		return
	var center := Vector2(player.tile) + Vector2(0.5, 0.5)
	# the survivor's exact position, for smooth scrolling
	var wp: Vector3 = player.global_position
	center = Vector2(wp.x, wp.z) / World.TILE_M
	draw_rect(Rect2(Vector2.ZERO, size), Color("#0b0b10"))
	var vr := _window_tiles(center)
	var s0 := World.sector_of_tile(vr.position)
	var s1 := World.sector_of_tile(vr.end)
	var sec_px := Vector2(S * PPT, S * PPT)
	var visible_sectors: Array[SectorData] = []
	for sy in range(s0.y, s1.y + 1):
		for sx in range(s0.x, s1.x + 1):
			var sd := World.get_sector(sx, sy)
			visible_sectors.append(sd)
			draw_texture_rect(tab_map.base_texture(sd), Rect2(_tile_to_screen(Vector2(sd.origin_tile()), center), sec_px), false)
	for sd in visible_sectors:
		for b in sd.buildings:
			var st: Dictionary = World.state.get(b.id(), {})
			if st.is_empty():
				continue
			var r := Rect2(_tile_to_screen(Vector2(b.rect.position), center), Vector2(b.rect.size) * PPT)
			if st.get("safe", false):
				draw_rect(r, Color("#3fd0ff", 0.55))
			elif st.get("cleared", false):
				draw_rect(r, Color("#5dff7a", 0.45))
	for sd in visible_sectors:
		draw_texture_rect(tab_map.fog_texture(sd.coord), Rect2(_tile_to_screen(Vector2(sd.origin_tile()), center), sec_px), false)
	# routes
	var li := 0
	for path in player.all_paths():
		if path.size() >= 2:
			var pts := PackedVector2Array()
			for t in path:
				pts.append(_tile_to_screen(Vector2(t) + Vector2(0.5, 0.5), center))
			draw_polyline(pts, COL_ROUTE if li == 0 else COL_ROUTE.darkened(0.3), 2.0)
		li += 1
	# Labels: settled slots are reserved first; priority only affects draw styling/order.
	# Every address stays typeable even if this tiny view cannot draw it.
	var queued: Array = player.queued_ids()
	var fs := 11
	var visible_entries: Array = []
	var ordinary_entries: Array = []
	var priority_entries: Array = []
	for e in _placed:
		var b: BuildingData = e["b"]
		var p := _tile_to_screen(b.center_tile(), center)
		if p.x < -LABEL_OVERSCAN or p.y < -LABEL_OVERSCAN \
				or p.x > size.x + LABEL_OVERSCAN or p.y > size.y + LABEL_OVERSCAN:
			continue
		visible_entries.append(e)
		var label: String = e["label"]
		var st: Dictionary = World.state.get(b.id(), {})
		var essential: bool = queued.has(b.id()) or bool(st.get("safe", false)) or bool(st.get("claimed", false)) \
			or (typing != "" and label.begins_with(typing))
		if essential:
			priority_entries.append(e)
		elif (not st.is_empty() and posmod(b.seed_hash, 2) == 0) \
				or posmod(b.seed_hash, LABEL_DENSITY_DIVISOR) == 0:
			ordinary_entries.append(e)
	# Sparse hashing makes the same buildings win every frame. If a very uniform block
	# happens to produce too few, fill from the nearest candidates without changing the
	# complete address registry consumed by typing.
	if priority_entries.size() + ordinary_entries.size() < MIN_NEARBY_LABELS:
		var fillers := visible_entries.duplicate()
		fillers.sort_custom(func(a, b):
			return (a["b"] as BuildingData).center_tile().distance_squared_to(center) \
				< (b["b"] as BuildingData).center_tile().distance_squared_to(center))
		for e in fillers:
			if priority_entries.has(e) or ordinary_entries.has(e):
				continue
			ordinary_entries.append(e)
			if priority_entries.size() + ordinary_entries.size() >= MIN_NEARBY_LABELS:
				break
	var draw_entries := priority_entries.duplicate()
	draw_entries.append_array(ordinary_entries)
	# Layout extends beyond all four sides. `clip_contents` reveals each label progressively
	# as the world scrolls it through the minimap frame instead of popping in fully formed.
	var bounds := Rect2(Vector2.ZERO, size).grow(LABEL_OVERSCAN)
	var candidates: Array = []
	for e in draw_entries:
		var b: BuildingData = e["b"]
		var label: String = e["label"]
		var w := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		candidates.append({"id": b.id(), "anchor": _tile_to_screen(b.center_tile(), center),
			"size": Vector2(w + 6, fs * 1.25)})
	var blockers: Array[Rect2] = [Rect2(size * 0.5 - Vector2(8, 8), Vector2(16, 16))]
	var layout := _layout_label_candidates(candidates, bounds, blockers)
	for e in draw_entries:
		var b: BuildingData = e["b"]
		if not layout.has(b.id()):
			continue
		var p := _tile_to_screen(b.center_tile(), center)
		var label: String = e["label"]
		var qi := queued.find(b.id())
		var typed_match := typing != "" and label.begins_with(typing)
		var lr: Rect2 = layout[b.id()]
		var bg := Color(0, 0, 0, 0.6)
		var fg := Color.WHITE
		if qi >= 0:
			bg = COL_QUEUED; fg = Color.BLACK
		elif typed_match:
			bg = Color("#facc15", 0.85); fg = Color.BLACK
		if lr.get_center().distance_squared_to(p) > 9.0:
			draw_line(p, lr.get_center(), Color(1, 1, 1, 0.28), 1.0)
		draw_rect(lr, bg)
		var baseline := Vector2(lr.position.x + 3.0, lr.position.y + fs)
		draw_string(_font, baseline, label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, fg)
		if building_visited(b.id()):
			draw_line(Vector2(lr.position.x + 2.0, lr.get_center().y),
				Vector2(lr.end.x - 2.0, lr.get_center().y), fg, 1.5)
	# player
	var pp := _tile_to_screen(center, center)
	var f: Vector3 = player.facing
	var dir := Vector2(f.x, f.z).normalized()
	draw_circle(pp, 5.0, Color.BLACK)
	draw_circle(pp, 3.5, COL_PLAYER)
	draw_line(pp, pp + dir * 9.0, COL_PLAYER, 2.0)
	# frame + typed destination
	draw_rect(Rect2(Vector2.ZERO, size), Color("#fdf6e3", 0.55), false, 2.0)
	var now := Time.get_ticks_msec() / 1000.0
	var line := ""
	if typing != "":
		line = "> " + typing + ("_" if int(now * 2.0) % 2 == 0 else " ")
	elif now < _msg_until:
		line = _msg
	if line != "":
		var lw := _font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		draw_rect(Rect2(Vector2(size.x - lw - 10, size.y - 22), Vector2(lw + 8, 20)), Color(0, 0, 0, 0.7))
		draw_string(_font, Vector2(size.x - lw - 6, size.y - 7), line, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("#facc15"))


func building_visited(id: String) -> bool:
	return World.building_state(id).get("visited", false)
