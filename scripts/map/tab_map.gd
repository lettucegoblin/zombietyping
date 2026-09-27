extends Control
## The Tab map. Opening it pauses the game. Generated buildings get stable addresses
## using the same stable addresses as the minimap and first-person reticle; type labels
## separated by spaces and press Enter to queue destinations. Labels remain available under
## fog, out to the rendered city's large selection radius.
## The minimap in the corner uses the same scheme, so labels can also be typed without Tab.

signal destinations_typed(ids: Array[String])
signal clear_requested
signal closed

const S := SectorData.SIZE
const BAND_TILES := 6
const MIN_PPT := 4.0
const MAX_PPT := 28.0
const LABEL_MIN_PPT := 4.0
const FOCUS_EXPLORATION_SITES := 8
const ALL_SITE_DRAW_LIMIT := 96
const FacilityUpgradeRules = preload("res://scripts/settlement/facility_upgrade.gd")

const NAME_ROOTS := [
	"Aster", "Bellweather", "Cinder", "Dovetail", "Elm", "Foxglove",
	"Garnet", "Harbor", "Juniper", "Kingfisher", "Lantern", "Marigold",
	"Northstar", "Orchid", "Palisade", "Quarry", "Rosewood", "Solace",
	"Thistle", "Union", "Vesper", "Willow", "Yarrow", "Zephyr",
]
const NAME_SUFFIXES := {
	"apartments": ["Court", "Heights", "Residences", "Arms"],
	"house": ["House", "Cottage", "Place", "Homestead"],
	"shop": ["Market", "Trading Post", "Supply", "Arcade"],
	"office": ["Center", "Exchange", "Offices", "Tower"],
	"warehouse": ["Works", "Depot", "Foundry", "Yard"],
	"plain": ["Building", "Hall", "Block", "Annex"],
}

var player: Node3D
var _center := Vector2.ZERO          # view centre, tile coords
var _ppt := 10.0                      # pixels per tile
var _base_tex: Dictionary = {}        # Vector2i -> ImageTexture
var _fog_tex: Dictionary = {}         # Vector2i -> ImageTexture
var _fog_dirty: Dictionary = {}       # Vector2i -> true
var _labels: Dictionary = {}          # label -> building id (current view)
var _placed: Array = []               # [{label, b, centre}]
var _label_offsets: Dictionary = {}   # building id -> persistent nudge from its map anchor
var _label_layout_ppt := -1.0
var _dragging := false
var _msg := ""
var _msg_until := 0.0
var _selected_id := ""
var _building_hitboxes: Array[Dictionary] = []
var _action_hitboxes: Array[Dictionary] = []
var _supply_route_cache: Array[Dictionary] = []
var _supply_topology_key := ""
var _supply_route_build_count := 0  # exposed to focused tests; never used by gameplay
var _show_all_buildings := false
var _facility_cache: Dictionary = {} # building id -> {signature, profile}

var buffer := ""                      # what the player has typed (we own key handling: typing game)
var _view_key := ""                   # cache key of the last label recompute

@onready var prompt: Label = $Panel/Prompt
@onready var status: Label = $Status
@onready var hint: Label = $Hint

const COL_ARTERIAL := Color("#e2dccb")
const COL_LOCAL := Color("#9b978f")
const COL_FOG := Color(0.02, 0.02, 0.04, 0.93)
const COL_ROUTE := Color("#ffd166")
const COL_PLAYER := Color("#ff5a36")


func _ready() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	World.sector_generated.connect(func(_sd): _invalidate())
	World.settlement_changed.connect(_sync_supply_route_cache)
	_sync_supply_route_cache()


func _process(_dt: float) -> void:
	if visible:
		queue_redraw()   # caret blink + status timeout; the draw is cheap (texture blits)


func open() -> void:
	# Gameplay owns a captured pointer for always-on mouse look. Menus must explicitly
	# release it before accepting map dragging, wheel zoom, or building-panel clicks.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	visible = true
	if player != null:
		_center = Vector2(player.tile) + Vector2(0.5, 0.5)
	buffer = ""
	_invalidate()


func close() -> void:
	visible = false
	closed.emit()


func mark_fog_dirty_around(sector: Vector2i) -> void:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			_fog_dirty[sector + Vector2i(dx, dy)] = true
	if visible:
		_invalidate()


func flash(msg: String) -> void:
	_msg = msg
	_msg_until = Time.get_ticks_msec() / 1000.0 + 2.5
	queue_redraw()


# ------------------------------------------------------------------ input

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed:
		var step := 64.0 / _ppt
		var k: int = event.keycode
		if k == KEY_ESCAPE:
			close()
		elif k == KEY_LEFT:  _center.x -= step; _invalidate()
		elif k == KEY_RIGHT: _center.x += step; _invalidate()
		elif k == KEY_UP:    _center.y -= step; _invalidate()
		elif k == KEY_DOWN:  _center.y += step; _invalidate()
		elif k == KEY_HOME and player != null:
			_center = Vector2(player.tile) + Vector2(0.5, 0.5); _invalidate()
		elif k == KEY_F3:
			_toggle_label_detail()
		elif k == KEY_BACKSPACE:
			buffer = buffer.left(maxi(buffer.length() - 1, 0)); queue_redraw()
		elif k == KEY_ENTER or k == KEY_KP_ENTER:
			_on_submit(buffer); buffer = ""; queue_redraw()
		elif k == KEY_SPACE:
			if not buffer.ends_with(" ") and buffer != "": buffer += " "
			queue_redraw()
		elif k >= KEY_A and k <= KEY_Z:
			buffer += char(97 + (k - KEY_A)); queue_redraw()
		elif k >= KEY_0 and k <= KEY_9:
			buffer += char(48 + (k - KEY_0)); queue_redraw()
		elif k >= KEY_KP_0 and k <= KEY_KP_9:
			buffer += char(48 + (k - KEY_KP_0)); queue_redraw()
		elif k == KEY_TAB:
			if not event.echo:
				close()   # while paused only ALWAYS-mode nodes get input, so the map closes itself
		get_viewport().set_input_as_handled()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		# The building panel is opaque UI, not part of the pannable map. Consume every
		# mouse button over it so hidden building labels, zoom, and drag never leak through.
		if _panel_rect().has_point(event.position):
			_dragging = false
			if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
				for hit in _action_hitboxes:
					if (hit["rect"] as Rect2).has_point(event.position):
						var action: String = hit["action"]
						if action == "toggle_labels":
							_toggle_label_detail()
						else:
							_run_settlement_action(action)
						accept_event()
						return
			accept_event()
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			var before := _screen_to_tile(event.position)
			_ppt = clampf(_ppt * (1.15 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15), MIN_PPT, MAX_PPT)
			var after := _screen_to_tile(event.position)
			_center += before - after
			_invalidate()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				for hit in _building_hitboxes:
					if (hit["rect"] as Rect2).has_point(event.position):
						_selected_id = hit["id"]
						_dragging = false
						queue_redraw()
						accept_event()
						return
				_dragging = true
			else:
				_dragging = false
	elif event is InputEventMouseMotion:
		if _panel_rect().has_point(event.position):
			_dragging = false
			accept_event()
		elif _dragging:
			_center -= event.relative / _ppt
			_invalidate()


func _on_submit(text: String) -> void:
	var tokens := text.strip_edges().to_lower().split(" ", false)
	if tokens.is_empty():
		return
	if tokens[0] in ["x", "clear", "stop"]:
		clear_requested.emit()
		flash("queue cleared")
		return
	if tokens[0] == "job":
		if tokens.size() < 3 or not _labels.has(tokens[1]):
			flash("use job <label> farmer|scavenger|builder|mechanic|medic")
			return
		_selected_id = _labels[tokens[1]]
		flash(World.assign_next_job(_selected_id, tokens[2]))
		_invalidate()
		return
	var commands := { "info": "info", "salvage": "salvage", "car": "car", "fortify": "fortify", "supply": "supply", "claim": "claim", "farm": "farm", "crew": "crew", "upgrade": "upgrade" }
	if commands.has(tokens[0]):
		if tokens.size() < 2 or not _labels.has(tokens[1]):
			flash("use %s <map label>" % tokens[0])
			return
		_selected_id = _labels[tokens[1]]
		if tokens[0] != "info":
			_run_settlement_action(commands[tokens[0]])
		_invalidate()
		return
	var ids: Array[String] = []
	var unknown: Array[String] = []
	for t in tokens:
		if _labels.has(t):
			ids.append(_labels[t])
		else:
			unknown.append(t)
	if not unknown.is_empty():
		flash("unknown: " + " ".join(unknown))
	if not ids.is_empty():
		destinations_typed.emit(ids)
	_invalidate()


func _toggle_label_detail() -> void:
	_show_all_buildings = not _show_all_buildings
	flash("all known buildings" if _show_all_buildings else "priority sites only")
	queue_redraw()


func _run_settlement_action(action: String) -> void:
	var message := World.settlement_action(action, _selected_id)
	if action == "supply" and message.begins_with("supply line established"):
		message = _new_supply_message(_selected_id)
	flash(message)
	_invalidate()


# ------------------------------------------------------------------ mapping

func _tile_to_screen(t: Vector2) -> Vector2:
	return (t - _center) * _ppt + size * 0.5


func _screen_to_tile(p: Vector2) -> Vector2:
	return (p - size * 0.5) / _ppt + _center


func _panel_rect() -> Rect2:
	var panel_w := minf(350.0, size.x * 0.36)
	return Rect2(Vector2(size.x - panel_w - 12.0, 42.0), Vector2(panel_w, size.y - 160.0))


func building_name(b: BuildingData) -> String:
	# Names are cosmetic and regenerable: no mutable state or save entry is required.
	var name_seed := b.seed_hash ^ (b.rect.position.x * 73856093) ^ (b.rect.position.y * 19349663)
	name_seed ^= b.district * 83492791 ^ b.floors * 265443576
	var roots_index := posmod(name_seed, NAME_ROOTS.size())
	var suffixes: Array = NAME_SUFFIXES.get(b.kind, NAME_SUFFIXES["plain"])
	var suffix_index := posmod((name_seed >> 7) ^ b.index ^ b.block, suffixes.size())
	return "%s %s" % [NAME_ROOTS[roots_index], suffixes[suffix_index]]


func facility_profile(b: BuildingData) -> Dictionary:
	var st: Dictionary = World.state.get(b.id(), {})
	var removed: Dictionary = st.get("salvaged_props", {})
	var removed_ids: Array[String] = []
	for id in removed:
		removed_ids.append(str(id))
	removed_ids.sort()
	var signature := "%d|%s|%s|%s" % [World.seed, str(st.get("cleared", false)), str(st.get("claimed", false)), ",".join(removed_ids)]
	var cached: Dictionary = _facility_cache.get(b.id(), {})
	if cached.get("signature", "") != signature:
		cached = { "signature": signature, "profile": FacilityProfile.derive(World.seed, b, st) }
		_facility_cache[b.id()] = cached
	return cached["profile"]


func facility_panel_lines(b: BuildingData) -> Array[String]:
	var profile := facility_profile(b)
	var lines: Array[String] = ["FACILITY · " + str(profile["role_label"])]
	if not profile["cleared"]:
		lines.append(str(profile["readiness"]))
		return lines
	lines.append("program  " + FacilityProfile.program_text(profile))
	lines.append_array(FacilityProfile.utility_lines(profile))
	lines.append(str(profile["readiness"]))
	return lines


func _label_for_id(id: String) -> String:
	return MapLabels.label_for_id(id)


func _endpoint_text(id: String) -> String:
	var b := World.building_by_id(id)
	if b == null:
		return "unknown site"
	var label := _label_for_id(id)
	return ((label + "  ") if label != "" else "") + building_name(b)


func _new_supply_message(target_id: String) -> String:
	for route in _supply_route_cache:
		if route["target_id"] == target_id:
			return "supply: %s → %s" % [_endpoint_text(route["source_id"]), _endpoint_text(target_id)]
	return "supply line established"


func _supply_lines_for(id: String) -> Array[String]:
	var lines: Array[String] = []
	for route in _supply_route_cache:
		if route["target_id"] == id:
			lines.append("IN  ← " + _endpoint_text(route["source_id"]))
		elif route["source_id"] == id:
			lines.append("OUT → " + _endpoint_text(route["target_id"]))
	return lines


func _displayed_placed() -> Array:
	if _show_all_buildings:
		# The complete `_labels` dictionary remains typeable. Drawing is intentionally bounded:
		# a low-zoom 508-site view cannot be made legible, and trying hundreds of nudge slots
		# every caret frame would turn the management map into a performance spike. Panning
		# changes the nearest slice, so the broad layer is still inspectable spatially.
		var nearby := _placed.duplicate()
		var focus := _center
		nearby.sort_custom(func(a, b):
			var ab: BuildingData = a["b"]
			var bb: BuildingData = b["b"]
			var ad := ab.center_tile().distance_squared_to(focus)
			var bd := bb.center_tile().distance_squared_to(focus)
			return ab.id() < bb.id() if is_equal_approx(ad, bd) else ad < bd
		)
		return nearby.slice(0, mini(ALL_SITE_DRAW_LIMIT, nearby.size()))
	var required := {}
	if _selected_id != "":
		required[_selected_id] = true
	if player != null:
		for id in player.queued_ids():
			required[id] = true
	for link in World.supply_links:
		for id in link:
			required[id] = true
	var candidates: Array = []
	for entry in _placed:
		var b: BuildingData = entry["b"]
		if not (World.state.get(b.id(), {}) as Dictionary).is_empty():
			required[b.id()] = true
		else:
			candidates.append(entry)
	var focus := _center
	candidates.sort_custom(func(a, b):
		var ab: BuildingData = a["b"]
		var bb: BuildingData = b["b"]
		var ad := ab.center_tile().distance_squared_to(focus)
		var bd := bb.center_tile().distance_squared_to(focus)
		return ab.id() < bb.id() if is_equal_approx(ad, bd) else ad < bd
	)
	for i in mini(FOCUS_EXPLORATION_SITES, candidates.size()):
		required[(candidates[i]["b"] as BuildingData).id()] = true
	# Preserve MapLabels' spatial order so focus mode never visually reshuffles addresses.
	var displayed: Array = []
	for entry in _placed:
		if required.has((entry["b"] as BuildingData).id()):
			displayed.append(entry)
	return displayed


# ------------------------------------------------------------------ supply route cache

func _supply_topology_signature() -> String:
	var links: Array[String] = []
	for link in World.supply_links:
		var ids: Array[String] = []
		for id in link:
			ids.append(str(id))
		links.append("\u001f".join(ids))
	return "%d|%s" % [World.seed, "\u001e".join(links)]


## Route finding is intentionally excluded from _draw: the map redraws continuously while
## open for its blinking caret. Rebuild only when the ordered supply topology changes.
func _sync_supply_route_cache() -> void:
	var topology := _supply_topology_signature()
	if topology == _supply_topology_key:
		return
	_supply_topology_key = topology
	_supply_route_cache.clear()
	for i in World.supply_links.size():
		var link: PackedStringArray = World.supply_links[i]
		if link.size() < 2:
			continue
		var a := World.building_by_id(link[0])
		var b := World.building_by_id(link[1])
		if a == null or b == null:
			continue
		var points := PackedVector2Array()
		if a.road_tile == b.road_tile:
			points.append(Vector2(a.road_tile) + Vector2(0.5, 0.5))
		else:
			_supply_route_build_count += 1
			points = _simplify_supply_path(World.find_path(a.road_tile, b.road_tile))
		var status := "route" if points.size() >= 2 else ("point" if points.size() == 1 else "broken")
		_supply_route_cache.append({
			"index": i,
			"source_id": link[0],
			"target_id": link[1],
			"points": points,
			"source": Vector2(a.road_tile) + Vector2(0.5, 0.5),
			"target": Vector2(b.road_tile) + Vector2(0.5, 0.5),
			"status": status,
		})
	queue_redraw()


func _simplify_supply_path(path: Array[Vector2i]) -> PackedVector2Array:
	var points := PackedVector2Array()
	if path.is_empty():
		return points
	points.append(Vector2(path[0]) + Vector2(0.5, 0.5))
	for i in range(1, path.size() - 1):
		var before := path[i] - path[i - 1]
		var after := path[i + 1] - path[i]
		if before != after:
			points.append(Vector2(path[i]) + Vector2(0.5, 0.5))
	if path.size() > 1:
		points.append(Vector2(path[path.size() - 1]) + Vector2(0.5, 0.5))
	return points


func _draw_supply_routes() -> void:
	_sync_supply_route_cache()
	var color := Color("#68d5ff", 0.9)
	var width := maxf(2.0, _ppt * 0.18)
	for route in _supply_route_cache:
		var tile_points: PackedVector2Array = route["points"]
		var points := PackedVector2Array()
		for p in tile_points:
			points.append(_tile_to_screen(p))
		match route["status"]:
			"route":
				draw_polyline(points, color, width)
				_draw_supply_endpoints(points, color, width)
				if _selected_id in [route["source_id"], route["target_id"]]:
					_draw_supply_caption(points[0], route["source_id"], color, -1.0)
					_draw_supply_caption(points[points.size() - 1], route["target_id"], color, 1.0)
			"point":
				# A zero-length valid link still needs a readable map mark.
				var p := points[0]
				draw_circle(p, maxf(4.0, width * 1.8), Color("#17131f"))
				draw_circle(p, maxf(2.5, width), color)
			"broken":
				# Corrupt/stale links should be conspicuous rather than silently disappearing.
				_draw_broken_supply(_tile_to_screen(route["source"]), _tile_to_screen(route["target"]), width)


func _draw_supply_caption(anchor: Vector2, id: String, color: Color, side: float) -> void:
	var font := get_theme_default_font()
	var text := _endpoint_text(id)
	var fs := 11
	var text_w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var x := anchor.x + 7.0 if side > 0.0 else anchor.x - text_w - 11.0
	var rect := Rect2(Vector2(x, anchor.y - 10.0), Vector2(text_w + 6.0, 17.0))
	draw_rect(rect, Color("#17131f", 0.9))
	draw_rect(rect, color, false, 1.0)
	draw_string(font, rect.position + Vector2(3.0, 12.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)


func _draw_supply_endpoints(points: PackedVector2Array, color: Color, width: float) -> void:
	var start := points[0]
	var finish := points[points.size() - 1]
	draw_circle(start, maxf(2.5, width * 1.15), color)
	var direction := (finish - points[points.size() - 2]).normalized()
	if direction.is_zero_approx():
		draw_circle(finish, maxf(2.5, width * 1.15), color, false, maxf(1.0, width * 0.6))
		return
	var side := Vector2(-direction.y, direction.x)
	var length := maxf(7.0, width * 3.2)
	var arrow := PackedVector2Array([
		finish,
		finish - direction * length + side * length * 0.48,
		finish - direction * length - side * length * 0.48,
	])
	draw_colored_polygon(arrow, color)


func _draw_broken_supply(a: Vector2, b: Vector2, width: float) -> void:
	var color := Color("#ff6f91", 0.9)
	var delta := b - a
	var distance := delta.length()
	if distance < 0.5:
		draw_circle(a, maxf(4.0, width * 1.8), color, false, maxf(1.5, width))
		return
	var direction := delta / distance
	var dash := 9.0
	# Bound work for a stale link whose endpoints are far outside the current view.
	var stride := maxf(dash * 2.0, distance / 128.0)
	var cursor := 0.0
	while cursor < distance:
		var end := minf(cursor + minf(dash, stride * 0.5), distance)
		draw_line(a + direction * cursor, a + direction * end, color, width)
		cursor += stride
	var mid := (a + b) * 0.5
	var mark := maxf(4.0, width * 1.5)
	draw_line(mid - Vector2(mark, mark), mid + Vector2(mark, mark), color, width)
	draw_line(mid + Vector2(mark, -mark), mid + Vector2(-mark, mark), color, width)


# ------------------------------------------------------------------ textures

func base_texture(sd: SectorData) -> ImageTexture:
	var tex: ImageTexture = _base_tex.get(sd.coord)
	if tex != null:
		return tex
	var img := Image.create_empty(S, S, false, Image.FORMAT_RGBA8)
	var ground: Color = District.COLOR[sd.district].darkened(0.55)
	var lotc: Color = District.COLOR[sd.district]
	for y in S:
		for x in S:
			var i := y * S + x
			var c: Color
			if sd.road[i] == 2: c = COL_ARTERIAL
			elif sd.road[i] == 1: c = COL_LOCAL
			elif sd.lot[i] != 0:
				var b := sd.buildings[sd.lot[i] - 1]
				c = lotc.darkened(0.12 if b.floors < 4 else 0.0).lightened(0.15 if b.floors >= 6 else 0.0)
			else: c = ground
			img.set_pixel(x, y, c)
	tex = ImageTexture.create_from_image(img)
	_base_tex[sd.coord] = tex
	return tex


func fog_texture(k: Vector2i) -> ImageTexture:
	var tex: ImageTexture = _fog_tex.get(k)
	if tex != null and not _fog_dirty.has(k):
		return tex
	_fog_dirty.erase(k)
	var img := Image.create_empty(S, S, false, Image.FORMAT_RGBA8)
	if not World.explored.has(k):
		img.fill(COL_FOG)
	else:
		var arr: PackedByteArray = World.explored[k]
		for y in S:
			for x in S:
				img.set_pixel(x, y, Color(0, 0, 0, 0) if arr[y * S + x] == 1 else COL_FOG)
	if tex == null:
		tex = ImageTexture.create_from_image(img)
		_fog_tex[k] = tex
	else:
		tex.update(img)
	return tex


# ------------------------------------------------------------------ labels

func _invalidate() -> void:
	_view_key = ""
	queue_redraw()


func _visible_tiles() -> Rect2i:
	var half := size / _ppt * 0.5
	var t0 := Vector2i(floori(_center.x - half.x), floori(_center.y - half.y))
	var t1 := Vector2i(ceili(_center.x + half.x), ceili(_center.y + half.y))
	return Rect2i(t0, t1 - t0)


## Register the complete selection radius, not merely the current screen. Panning only
## changes which addresses are drawn; it never makes an off-screen destination untypeable.
## Fog deliberately does not participate.
func recompute_labels() -> void:
	var player_center := Vector2(player.tile) + Vector2(0.5, 0.5) if player != null else _center
	var key := "%.2f|%s" % [_ppt, player_center]
	if key == _view_key:
		return
	_view_key = key
	if not is_equal_approx(_label_layout_ppt, _ppt):
		# Pixel offsets only have meaning at one zoom scale. Panning and movement retain
		# them; an explicit zoom starts a fresh collision layout.
		_label_offsets.clear()
		_label_layout_ppt = _ppt
	_labels.clear()
	_placed.clear()
	if _ppt < LABEL_MIN_PPT:
		return
	var radius := MapLabels.WORLD_LABEL_RANGE_TILES
	var lo := Vector2i(floori(player_center.x - radius), floori(player_center.y - radius))
	var hi := Vector2i(ceili(player_center.x + radius), ceili(player_center.y + radius))
	var res := MapLabels.assign(Rect2i(lo, hi - lo + Vector2i.ONE), player_center, radius)
	_labels = res["labels"]
	_placed = res["placed"]


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
				return Rect2()
		return remembered
	for ring in range(9):
		for gy in range(-ring, ring + 1):
			for gx in range(-ring, ring + 1):
				if ring > 0 and absi(gx) != ring and absi(gy) != ring:
					continue
				var rect := Rect2(anchor + Vector2(gx, gy) * 6.0 - box_size * 0.5, box_size)
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


func _layout_label_candidates(candidates: Array, bounds: Rect2) -> Dictionary:
	var layout := {}
	var occupied: Array[Rect2] = []
	var stable_candidates := candidates.duplicate()
	stable_candidates.sort_custom(func(a, b): return str(a["id"]) < str(b["id"]))
	# Cached placements are authoritative, regardless of selection/queue draw priority.
	for candidate in stable_candidates:
		var id := str(candidate["id"])
		if not _label_offsets.has(id):
			continue
		var rect := _stable_label_rect(id, candidate["anchor"], candidate["size"], occupied, bounds)
		if rect.size != Vector2.ZERO:
			layout[id] = rect
			occupied.append(rect)
	for candidate in stable_candidates:
		var id := str(candidate["id"])
		if _label_offsets.has(id):
			continue
		var rect := _stable_label_rect(id, candidate["anchor"], candidate["size"], occupied, bounds)
		if rect.size != Vector2.ZERO:
			layout[id] = rect
			occupied.append(rect)
	return layout


# ------------------------------------------------------------------ drawing

func _draw() -> void:
	recompute_labels()
	var displayed := _displayed_placed()
	_building_hitboxes.clear()
	_action_hitboxes.clear()
	draw_rect(Rect2(Vector2.ZERO, size), Color("#0b0b10"))
	var vr := _visible_tiles()
	var s0 := World.sector_of_tile(vr.position)
	var s1 := World.sector_of_tile(vr.end)
	var sec_px := Vector2(S * _ppt, S * _ppt)
	var font := get_theme_default_font()
	var fs := int(clampf(_ppt * 1.15, 8.0, 18.0))

	# sectors
	var visible_sectors: Array[SectorData] = []
	for sy in range(s0.y, s1.y + 1):
		for sx in range(s0.x, s1.x + 1):
			var sd := World.get_sector(sx, sy)
			visible_sectors.append(sd)
			var pos := _tile_to_screen(Vector2(sd.origin_tile()))
			draw_texture_rect(base_texture(sd), Rect2(pos, sec_px), false)
	# cleared / safe state overlay (sparse)
	for sd in visible_sectors:
		for b in sd.buildings:
			var st: Dictionary = World.state.get(b.id(), {})
			if st.is_empty():
				continue
			var r := Rect2(_tile_to_screen(Vector2(b.rect.position)), Vector2(b.rect.size) * _ppt)
			if st.get("safe", false):
				draw_rect(r, Color("#3fd0ff", 0.55))
			elif st.get("cleared", false):
				draw_rect(r, Color("#5dff7a", 0.45))
	# fog
	for sd in visible_sectors:
		var pos := _tile_to_screen(Vector2(sd.origin_tile()))
		draw_texture_rect(fog_texture(sd.coord), Rect2(pos, sec_px), false)
	# routes
	_draw_supply_routes()
	if player != null:
		var li := 0
		for path in player.all_paths():
			if path.size() >= 2:
				var pts := PackedVector2Array()
				for t in path:
					pts.append(_tile_to_screen(Vector2(t) + Vector2(0.5, 0.5)))
				draw_polyline(pts, COL_ROUTE if li == 0 else COL_ROUTE.darkened(0.3), maxf(2.0, _ppt * 0.25))
			li += 1
	# labels
	if _ppt >= LABEL_MIN_PPT:
		var queued: Array = player.queued_ids() if player != null else []
		var important: Array = []
		var ordinary: Array = []
		for e in displayed:
			var eb: BuildingData = e["b"]
			if eb.id() == _selected_id or queued.has(eb.id()):
				important.append(e)
			else:
				ordinary.append(e)
		important.append_array(ordinary)
		var panel_left := _panel_rect().position.x - 6.0
		var label_bounds := Rect2(Vector2(5.0, 66.0), Vector2(panel_left - 10.0, size.y - 134.0))
		var candidates: Array = []
		for e in displayed:
			var b: BuildingData = e["b"]
			var p := _tile_to_screen(b.center_tile())
			if not label_bounds.grow(36.0).has_point(p):
				continue
			var label: String = e["label"]
			var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			candidates.append({"id": b.id(), "anchor": p, "size": Vector2(w + 8, fs * 1.35)})
		var layout := _layout_label_candidates(candidates, label_bounds)
		for e in important:
			var b: BuildingData = e["b"]
			if not layout.has(b.id()):
				continue
			var p := _tile_to_screen(b.center_tile())
			var label: String = e["label"]
			var qi := queued.find(b.id())
			var selected: bool = b.id() == _selected_id
			var bg := Color("#5b3f8c") if selected else (Color(0, 0, 0, 0.55) if qi < 0 else COL_ROUTE)
			var fg := Color.WHITE if qi < 0 else Color.BLACK
			var lr: Rect2 = layout[b.id()]
			if lr.get_center().distance_squared_to(p) > 16.0:
				draw_line(p, lr.get_center(), Color(1, 1, 1, 0.30), 1.0)
			draw_rect(lr, bg)
			_building_hitboxes.append({ "rect": lr, "id": b.id() })
			var baseline := Vector2(lr.position.x + 4.0, lr.position.y + fs)
			draw_string(font, baseline, label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, fg)
			if World.building_state(b.id()).get("visited", false):
				draw_line(Vector2(lr.position.x + 3.0, lr.get_center().y),
					Vector2(lr.end.x - 3.0, lr.get_center().y), fg, 1.5)
			if qi >= 0:
				draw_string(font, Vector2(lr.end.x + 4.0, baseline.y), str(qi + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, COL_ROUTE)
	# player
	if player != null:
		var pp := _tile_to_screen(Vector2(player.tile) + Vector2(0.5, 0.5))
		var f: Vector3 = player.facing
		var dir := Vector2(f.x, f.z).normalized()
		var r := maxf(5.0, _ppt * 0.5)
		draw_circle(pp, r + 2, Color.BLACK)
		draw_circle(pp, r, COL_PLAYER)
		draw_line(pp, pp + dir * r * 2.2, COL_PLAYER, 3.0)
	_draw_legend(font)
	_draw_building_panel(font)
	# messages / status
	var now := Time.get_ticks_msec() / 1000.0
	status.text = _msg if now < _msg_until else ""
	prompt.text = "> " + buffer + ("_" if int(now * 2.0) % 2 == 0 else " ")
	hint.text = "zoom in to label buildings" if _ppt < LABEL_MIN_PPT else "F3 focus/all  ·  click to manage  ·  type labels + Enter to travel  ·  info/action <label>  ·  Tab close"
	var sec := World.sector_of_tile(Vector2i(_center))
	var sd_here := World.get_sector(sec.x, sec.y)
	var count_text := "%d/%d priority labels" % [displayed.size(), _placed.size()] if not _show_all_buildings else "%d addressable buildings" % _placed.size()
	draw_string(font, Vector2(12, 24), "%s   sector %d,%d   %s" % [District.NAME[sd_here.district], sec.x, sec.y, count_text], HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("#dddddd"))


func _draw_legend(font: Font) -> void:
	var pos := Vector2(12.0, 39.0)
	var bg := Rect2(pos, Vector2(384.0, 23.0))
	draw_rect(bg, Color("#17131f", 0.84))
	var x := pos.x + 7.0
	var y := pos.y + 15.0
	for item in [
		[Color("#3fd0ff"), "safe"],
		[Color("#5dff7a"), "cleared"],
		[Color("#68d5ff"), "supply"],
		[COL_ROUTE, "queued"],
	]:
		draw_rect(Rect2(Vector2(x, pos.y + 7.0), Vector2(8.0, 8.0)), item[0])
		x += 12.0
		draw_string(font, Vector2(x, y), item[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("#ded8e8"))
		x += font.get_string_size(item[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x + 13.0
	draw_string(font, Vector2(x, y), "F3: %s" % ("all" if not _show_all_buildings else "focus"), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("#f6c177"))


func _draw_building_panel(font: Font) -> void:
	var pr := _panel_rect()
	draw_rect(pr, Color("#17131f", 0.96))
	draw_rect(pr, Color("#8067a8"), false, 2.0)
	var x := pr.position.x + 16.0
	var y := pr.position.y + 25.0
	draw_string(font, Vector2(x, y), "SETTLEMENT", HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color("#f6c177"))
	var toggle_text := "F3  FOCUS" if _show_all_buildings else "F3  ALL SITES"
	var toggle_rect := Rect2(Vector2(pr.end.x - 119.0, pr.position.y + 8.0), Vector2(106.0, 24.0))
	draw_rect(toggle_rect, Color("#30263f"))
	draw_rect(toggle_rect, Color("#8067a8"), false, 1.0)
	draw_string(font, toggle_rect.position + Vector2(8.0, 17.0), toggle_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("#f6c177"))
	_action_hitboxes.append({ "rect": toggle_rect, "action": "toggle_labels" })
	y += 25.0
	var material_lines := _wrap_text(World.material_summary(), 42)
	for line in material_lines:
		draw_string(font, Vector2(x, y), line, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("#a6e3a1"))
		y += 17.0
	for line in _wrap_text(World.backpack_summary(), 42):
		draw_string(font, Vector2(x, y), line, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("#ffb86c"))
		y += 15.0
	if _selected_id == "":
		y += 18.0
		draw_string(font, Vector2(x, y), "Click a priority label to inspect it.", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color("#dddddd"))
		draw_string(font, Vector2(x, y + 20), "F3 reveals the broad address layer.", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color("#dddddd"))
		return
	var b := World.building_by_id(_selected_id)
	if b == null:
		_selected_id = ""
		return
	var st: Dictionary = World.state.get(_selected_id, {})
	y += 12.0
	var current_label := _label_for_id(_selected_id)
	var address := current_label if current_label != "" else "off-map"
	draw_string(font, Vector2(x, y), "%s  %s" % [address, building_name(b)], HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color.WHITE)
	y += 22.0
	draw_string(font, Vector2(x, y), "%s  ·  %d floor%s  ·  %s" % [b.kind.capitalize(), b.floors, "" if b.floors == 1 else "s", District.NAME[b.district]], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("#b8adca"))
	y += 20.0
	var status_parts: Array[String] = []
	for pair in [["visited", "visited"], ["cleared", "cleared"], ["salvaged", "salvaged"], ["fortified", "fortified"], ["supplied", "supplied"], ["claimed", "claimed"]]:
		if st.get(pair[0], false):
			status_parts.append(pair[1])
	if status_parts.is_empty():
		status_parts.append("unsecured")
	draw_string(font, Vector2(x, y), " → ".join(status_parts), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("#68d5ff") if st.get("claimed", false) else Color("#ff9f68"))
	y += 24.0
	var profile := facility_profile(b)
	draw_string(font, Vector2(x, y), "FACILITY  ·  %s" % profile["role_label"], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("#f6c177"))
	y += 18.0
	if not profile["cleared"]:
		draw_string(font, Vector2(x, y), profile["readiness"], HORIZONTAL_ALIGNMENT_LEFT, pr.size.x - 32.0, 12, Color("#9f95ad"))
		y += 20.0
	else:
		draw_string(font, Vector2(x, y), "program  " + FacilityProfile.program_text(profile), HORIZONTAL_ALIGNMENT_LEFT, pr.size.x - 32.0, 11, Color("#b8adca"))
		y += 16.0
		for utility_line in FacilityProfile.utility_lines(profile):
			draw_string(font, Vector2(x, y), utility_line, HORIZONTAL_ALIGNMENT_LEFT, pr.size.x - 32.0, 11, Color("#ded8e8"))
			y += 16.0
		var readiness_color := Color("#a6e3a1") if profile["readiness_kind"] in ["ready", "operational"] else (Color("#ff6f91") if profile["readiness_kind"] == "needs" else Color("#f6c177"))
		draw_string(font, Vector2(x, y), str(profile["readiness"]), HORIZONTAL_ALIGNMENT_LEFT, pr.size.x - 32.0, 11, readiness_color)
		y += 20.0
		if int(profile.get("upgrade_level", 0)) > 0:
			draw_string(font, Vector2(x, y), FacilityUpgradeRules.effect_text(str(profile["role_id"]), int(profile["upgrade_level"])), HORIZONTAL_ALIGNMENT_LEFT, pr.size.x - 32.0, 10, Color("#a6e3a1") if profile.get("upgrade_operational", false) else Color("#ff6f91"))
			y += 16.0
	if st.get("claimed", false):
		var residents := World.resident_records(_selected_id)
		draw_string(font, Vector2(x, y), "CREW %d  ·  next work cycle %ds" % [int(st.get("citizens", 0)), World.seconds_until_work_cycle()], HORIZONTAL_ALIGNMENT_LEFT, pr.size.x - 32.0, 11, Color("#f6c177"))
		y += 16.0
		if residents.is_empty():
			draw_string(font, Vector2(x, y), "founder caretaker · rescue people to specialize", HORIZONTAL_ALIGNMENT_LEFT, pr.size.x - 32.0, 10, Color("#9f95ad"))
			y += 15.0
		else:
			for i in mini(2, residents.size()):
				var person: Dictionary = residents[i]
				var condition := World.survivor_condition(person)
				var condition_color := Color("#a6e3a1") if condition in ["happy", "thriving"] else (Color("#f6c177") if condition == "recovering" else Color("#ded8e8"))
				draw_string(font, Vector2(x, y), "%s · %s → %s · %s" % [person.get("name", "survivor"), person.get("trait", ""), person.get("job", "unassigned"), condition], HORIZONTAL_ALIGNMENT_LEFT, pr.size.x - 32.0, 10, condition_color)
				y += 15.0
		var needs: Dictionary = st.get("needs", {})
		if not needs.is_empty():
			var needs_color := Color("#a6e3a1") if needs.get("status", "") in ["thriving", "comfortable"] else (Color("#f6c177") if needs.get("status", "") == "recovering" else Color("#ded8e8"))
			draw_string(font, Vector2(x, y), "WELLBEING %s · meals %d/%d · recovery %d · morale %d" % [needs.get("status", ""), int(needs.get("food_used", 0)), int(needs.get("food_needed", 0)), int(needs.get("injured", 0)), int(needs.get("morale", 0))], HORIZONTAL_ALIGNMENT_LEFT, pr.size.x - 32.0, 10, needs_color)
			y += 15.0
		var stored_items: Dictionary = st.get("stored_items", {})
		if not stored_items.is_empty():
			draw_string(font, Vector2(x, y), "stores: " + World.item_summary(stored_items), HORIZONTAL_ALIGNMENT_LEFT, pr.size.x - 32.0, 10, Color("#68d5ff"))
			y += 15.0
		var last: Dictionary = st.get("last_production", {})
		if not last.is_empty():
			var output: Dictionary = last.get("output", {})
			var work_text := "idle" if output.is_empty() else World.cost_text(output)
			if int(last.get("unavailable", 0)) > 0:
				work_text += " · %d unavailable" % int(last["unavailable"])
			var delivery := "delivered" if last.get("delivered", false) else "held locally — route cut"
			draw_string(font, Vector2(x, y), "last: %s · %s" % [work_text, delivery], HORIZONTAL_ALIGNMENT_LEFT, pr.size.x - 32.0, 10, Color("#a6e3a1") if last.get("delivered", false) else Color("#ff6f91"))
			y += 16.0
	var supply_lines := _supply_lines_for(_selected_id)
	for i in mini(2, supply_lines.size()):
		draw_string(font, Vector2(x, y), supply_lines[i], HORIZONTAL_ALIGNMENT_LEFT, pr.size.x - 32.0, 12, Color("#68d5ff"))
		y += 18.0
	if st.get("cleared", false) and not st.get("fortified", false):
		draw_string(font, Vector2(x, y), "Cleared ≠ claimable. Build the perimeter.", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("#ff6f91"))
		y += 21.0
	var rows: Array[Dictionary] = []
	if not st.get("salvaged", false):
		rows.append({ "action": "salvage", "label": "Salvage contents", "cost": "yields material classes" })
	if World.car_exists(b) and int(st.get("car_stage", 0)) < 4:
		rows.append({ "action": "car", "label": "Dismantle parked car", "cost": "stage %d/4" % int(st.get("car_stage", 0)) })
	if not st.get("fortified", false):
		rows.append({ "action": "fortify", "label": "Build perimeter", "cost": World.cost_text(World.fortify_cost(b)) })
	elif not st.get("claimed", false) and not World.claimed_ids().is_empty() and not st.get("supplied", false):
		rows.append({ "action": "supply", "label": "Establish supply line", "cost": World.cost_text(World.supply_cost()) })
	if not st.get("claimed", false):
		rows.append({ "action": "claim", "label": "Claim building", "cost": World.cost_text(World.claim_cost(b)) })
	else:
		if int(profile.get("upgrade_level", 0)) < FacilityUpgradeRules.MAX_LEVEL:
			rows.append({ "action": "upgrade", "label": "Upgrade %s to level %d" % [profile["role_label"], int(profile.get("upgrade_level", 0)) + 1], "cost": World.cost_text(World.facility_upgrade_cost(_selected_id)) })
		if not (st.get("resident_ids", []) as Array).is_empty():
			rows.append({ "action": "crew", "label": "Auto-assign crew", "cost": "or type job <label> <role>" })
		rows.append({ "action": "farm", "label": "Build farm plot", "cost": World.cost_text(World.farm_cost()) })
	for row in rows:
		if y + 45.0 > pr.end.y - 16.0:
			break
		var br := Rect2(Vector2(x, y), Vector2(pr.size.x - 32.0, 39.0))
		draw_rect(br, Color("#30263f"))
		draw_rect(br, Color("#8067a8"), false, 1.0)
		draw_string(font, br.position + Vector2(10, 16), row["label"], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)
		draw_string(font, br.position + Vector2(10, 32), row["cost"], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("#b8adca"))
		_action_hitboxes.append({ "rect": br, "action": row["action"] })
		y += 47.0


func _wrap_text(text: String, width: int) -> Array[String]:
	var out: Array[String] = []
	var line := ""
	for word in text.split(" "):
		if line.length() + word.length() + 1 > width and line != "":
			out.append(line)
			line = word
		else:
			line += ("" if line == "" else " ") + word
	if line != "":
		out.append(line)
	return out
