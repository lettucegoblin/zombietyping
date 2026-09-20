extends Control
## Always-on minimap (top right): the Tab map's textures around the survivor, north up,
## with the same "1a" labels — type one and the rail goes there, no Tab needed.
## Labels are assigned for a window around where you last STOPPED (or drifted 10+ tiles
## from), so they do not reshuffle under your fingers while the rail is moving.

const S := SectorData.SIZE
const PPT := 5.0                  # pixels per tile
const RELABEL_DRIFT := 10.0       # tiles of travel before labels move with you
const COL_ROUTE := Color("#ffd166")
const COL_PLAYER := Color("#ff5a36")
const COL_QUEUED := Color("#ffd166")

var player: Node3D
var tab_map: Control              # texture cache + fog dirty tracking live there
var labels: Dictionary = {}       # label -> building id (current window)
var _placed: Array = []
var _label_center := Vector2(INF, INF)
var _explored_n := -1
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
	if (_was_moving and not moving) or drift > RELABEL_DRIFT or _explored_n != World.explored.size():
		relabel()
	_was_moving = moving
	queue_redraw()


## Labels for the window around the survivor's current tile.
func relabel() -> void:
	_label_center = Vector2(player.tile) + Vector2(0.5, 0.5)
	_explored_n = World.explored.size()
	var res := MapLabels.assign(_window_tiles(_label_center))
	labels = res["labels"]
	_placed = res["placed"]


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
	# labels
	var queued: Array = player.queued_ids()
	var fs := 11
	for e in _placed:
		var b: BuildingData = e["b"]
		var p := _tile_to_screen(b.center_tile(), center)
		if p.x < -20 or p.y < -10 or p.x > size.x + 20 or p.y > size.y + 10:
			continue
		var label: String = e["label"]
		var w := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var qi := queued.find(b.id())
		var typed_match := typing != "" and label.begins_with(typing)
		var bg := Color(0, 0, 0, 0.6)
		var fg := Color.WHITE
		if qi >= 0:
			bg = COL_QUEUED; fg = Color.BLACK
		elif typed_match:
			bg = Color("#facc15", 0.85); fg = Color.BLACK
		draw_rect(Rect2(p - Vector2(w * 0.5 + 2, fs * 0.6), Vector2(w + 4, fs * 1.1)), bg)
		draw_string(_font, p + Vector2(-w * 0.5, fs * 0.35), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, fg)
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
