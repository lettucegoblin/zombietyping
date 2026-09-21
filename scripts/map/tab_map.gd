extends Control
## The Tab map. Opening it pauses the game. Buildings you have SEEN get short labels
## relative to the current view (left-to-right = number, row band = letter, see MapLabels);
## type labels separated by spaces and press Enter to queue destinations. Labels are a view
## concern: the queue stores stable building ids, so scrolling never changes what you asked for.
## The minimap in the corner uses the same scheme, so labels can also be typed without Tab.

signal destinations_typed(ids: Array[String])
signal clear_requested
signal closed

const S := SectorData.SIZE
const BAND_TILES := 6
const MIN_PPT := 4.0
const MAX_PPT := 28.0
const LABEL_MIN_PPT := 6.0

var player: Node3D
var _center := Vector2.ZERO          # view centre, tile coords
var _ppt := 10.0                      # pixels per tile
var _base_tex: Dictionary = {}        # Vector2i -> ImageTexture
var _fog_tex: Dictionary = {}         # Vector2i -> ImageTexture
var _fog_dirty: Dictionary = {}       # Vector2i -> true
var _labels: Dictionary = {}          # label -> building id (current view)
var _placed: Array = []               # [{label, b, centre}]
var _dragging := false
var _msg := ""
var _msg_until := 0.0
var _selected_id := ""
var _building_hitboxes: Array[Dictionary] = []
var _action_hitboxes: Array[Dictionary] = []
var _supply_route_cache: Array[Dictionary] = []
var _supply_topology_key := ""
var _supply_route_build_count := 0  # exposed to focused tests; never used by gameplay

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
						flash(World.settlement_action(hit["action"], _selected_id))
						_invalidate()
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
	var commands := { "info": "info", "salvage": "salvage", "car": "car", "fortify": "fortify", "supply": "supply", "claim": "claim", "farm": "farm" }
	if commands.has(tokens[0]):
		if tokens.size() < 2 or not _labels.has(tokens[1]):
			flash("use %s <map label>" % tokens[0])
			return
		_selected_id = _labels[tokens[1]]
		if tokens[0] != "info":
			flash(World.settlement_action(commands[tokens[0]], _selected_id))
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


# ------------------------------------------------------------------ mapping

func _tile_to_screen(t: Vector2) -> Vector2:
	return (t - _center) * _ppt + size * 0.5


func _screen_to_tile(p: Vector2) -> Vector2:
	return (p - size * 0.5) / _ppt + _center


func _panel_rect() -> Rect2:
	var panel_w := minf(350.0, size.x * 0.36)
	return Rect2(Vector2(size.x - panel_w - 12.0, 42.0), Vector2(panel_w, size.y - 160.0))


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
			"point":
				# A zero-length valid link still needs a readable map mark.
				var p := points[0]
				draw_circle(p, maxf(4.0, width * 1.8), Color("#17131f"))
				draw_circle(p, maxf(2.5, width), color)
			"broken":
				# Corrupt/stale links should be conspicuous rather than silently disappearing.
				_draw_broken_supply(_tile_to_screen(route["source"]), _tile_to_screen(route["target"]), width)


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


## Labels for the buildings visible in the current view (see MapLabels). Only recomputed
## when the view or the explored area changes.
func recompute_labels() -> void:
	var r := _visible_tiles()
	var key := "%s|%.2f|%d" % [r, _ppt, World.explored.size()]
	if key == _view_key:
		return
	_view_key = key
	_labels.clear()
	_placed.clear()
	if _ppt < LABEL_MIN_PPT:
		return
	var res := MapLabels.assign(r)
	_labels = res["labels"]
	_placed = res["placed"]


# ------------------------------------------------------------------ drawing

func _draw() -> void:
	recompute_labels()
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
		for e in _placed:
			var b: BuildingData = e["b"]
			var p := _tile_to_screen(b.center_tile())
			var label: String = e["label"]
			var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var qi := queued.find(b.id())
			var selected: bool = b.id() == _selected_id
			var bg := Color("#5b3f8c") if selected else (Color(0, 0, 0, 0.55) if qi < 0 else COL_ROUTE)
			var fg := Color.WHITE if qi < 0 else Color.BLACK
			var lr := Rect2(p - Vector2(w * 0.5 + 4, fs * 0.7), Vector2(w + 8, fs * 1.35))
			draw_rect(lr, bg)
			_building_hitboxes.append({ "rect": lr, "id": b.id() })
			draw_string(font, p + Vector2(-w * 0.5, fs * 0.38), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, fg)
			if qi >= 0:
				draw_string(font, p + Vector2(w * 0.5 + 4, fs * 0.38), str(qi + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, COL_ROUTE)
	# player
	if player != null:
		var pp := _tile_to_screen(Vector2(player.tile) + Vector2(0.5, 0.5))
		var f: Vector3 = player.facing
		var dir := Vector2(f.x, f.z).normalized()
		var r := maxf(5.0, _ppt * 0.5)
		draw_circle(pp, r + 2, Color.BLACK)
		draw_circle(pp, r, COL_PLAYER)
		draw_line(pp, pp + dir * r * 2.2, COL_PLAYER, 3.0)
	_draw_building_panel(font)
	# messages / status
	var now := Time.get_ticks_msec() / 1000.0
	status.text = _msg if now < _msg_until else ""
	prompt.text = "> " + buffer + ("_" if int(now * 2.0) % 2 == 0 else " ")
	hint.text = "zoom in to label buildings" if _ppt < LABEL_MIN_PPT else "click a building to manage it  ·  type labels + Enter to travel  ·  info/salvage/fortify/supply/claim/farm <label>  ·  Tab close"
	var sec := World.sector_of_tile(Vector2i(_center))
	var sd_here := World.get_sector(sec.x, sec.y)
	draw_string(font, Vector2(12, 24), "%s   sector %d,%d   %d labelled" % [District.NAME[sd_here.district], sec.x, sec.y, _placed.size()], HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("#dddddd"))


func _draw_building_panel(font: Font) -> void:
	var pr := _panel_rect()
	draw_rect(pr, Color("#17131f", 0.96))
	draw_rect(pr, Color("#8067a8"), false, 2.0)
	var x := pr.position.x + 16.0
	var y := pr.position.y + 25.0
	draw_string(font, Vector2(x, y), "SETTLEMENT / BUILDINGS", HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color("#f6c177"))
	y += 25.0
	var material_lines := _wrap_text(World.material_summary(), 42)
	for line in material_lines:
		draw_string(font, Vector2(x, y), line, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("#a6e3a1"))
		y += 17.0
	if _selected_id == "":
		y += 18.0
		draw_string(font, Vector2(x, y), "Click any visible map label", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color("#dddddd"))
		draw_string(font, Vector2(x, y + 20), "to inspect and develop that site.", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color("#dddddd"))
		return
	var b := World.building_by_id(_selected_id)
	if b == null:
		_selected_id = ""
		return
	var st: Dictionary = World.state.get(_selected_id, {})
	y += 12.0
	draw_string(font, Vector2(x, y), "%s  ·  %s  ·  %d floor%s" % [_selected_id, b.kind, b.floors, "" if b.floors == 1 else "s"], HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color.WHITE)
	y += 22.0
	var status_parts: Array[String] = []
	for pair in [["visited", "visited"], ["cleared", "cleared"], ["salvaged", "salvaged"], ["fortified", "fortified"], ["supplied", "supplied"], ["claimed", "claimed"]]:
		if st.get(pair[0], false):
			status_parts.append(pair[1])
	if status_parts.is_empty():
		status_parts.append("unsecured")
	draw_string(font, Vector2(x, y), " → ".join(status_parts), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("#68d5ff") if st.get("claimed", false) else Color("#ff9f68"))
	y += 24.0
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
