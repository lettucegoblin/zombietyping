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
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			var before := _screen_to_tile(event.position)
			_ppt = clampf(_ppt * (1.15 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15), MIN_PPT, MAX_PPT)
			var after := _screen_to_tile(event.position)
			_center += before - after
			_invalidate()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
	elif event is InputEventMouseMotion and _dragging:
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
			var bg := Color(0, 0, 0, 0.55) if qi < 0 else COL_ROUTE
			var fg := Color.WHITE if qi < 0 else Color.BLACK
			draw_rect(Rect2(p - Vector2(w * 0.5 + 2, fs * 0.6), Vector2(w + 4, fs * 1.15)), bg)
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
	# messages / status
	var now := Time.get_ticks_msec() / 1000.0
	status.text = _msg if now < _msg_until else ""
	prompt.text = "> " + buffer + ("_" if int(now * 2.0) % 2 == 0 else " ")
	hint.text = "zoom in to label buildings" if _ppt < LABEL_MIN_PPT else "type labels (e.g. 3b 1c) + Enter  ·  x = clear queue  ·  arrows/drag pan  ·  wheel zoom  ·  Tab/Esc close"
	var sec := World.sector_of_tile(Vector2i(_center))
	var sd_here := World.get_sector(sec.x, sec.y)
	draw_string(font, Vector2(12, 24), "%s   sector %d,%d   %d labelled" % [District.NAME[sd_here.district], sec.x, sec.y, _placed.size()], HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("#dddddd"))


