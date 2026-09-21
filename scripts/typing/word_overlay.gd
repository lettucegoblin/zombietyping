class_name WordOverlay
extends Control
## Draws every visible WordLabel in the 3D world onto the UI layer at screen resolution.
## Words flagged edge_hint that fall outside the view are pinned to the nearest screen edge
## with an arrow, so a door 45 degrees to your right shows up on the right edge pointing right.

@export var view_container: SubViewportContainer
@export var viewport: SubViewport

const GOLD := Color("#facc15")
const CREAM := Color("#fdf6e3")
const INK := Color("#120a1f")
const LOCK := Color("#be123c")
const RETIRED := Color("#6c6c72")
const EDGE_MARGIN := Vector2(56.0, 46.0)

var _font: Font


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font


func _process(_dt: float) -> void:
	queue_redraw()


func _draw() -> void:
	if viewport == null:
		return
	var cam := viewport.get_camera_3d()
	if cam == null:
		return
	var vp_size := Vector2(viewport.size)
	var scale := size / vp_size if vp_size.x > 0.0 else Vector2.ONE
	var inner := Rect2(EDGE_MARGIN, size - EDGE_MARGIN * 2.0)
	for n in get_tree().get_nodes_in_group("words"):
		var w: WordLabel = n
		if not w.is_visible_in_tree() or w.word == "":
			continue
		var p := w.global_position
		var behind := cam.is_position_behind(p)
		var sp := Vector2.ZERO
		var arrow := Vector2.ZERO      # unit direction of the edge arrow (zero = none)
		if not behind:
			sp = cam.unproject_position(p) * scale
		if behind or not inner.has_point(sp):
			if w.keep_on_screen and not behind:
				sp = sp.clamp(inner.position, inner.end)
			elif not w.edge_hint:
				if behind or sp.x < -200 or sp.y < -100 or sp.x > size.x + 200 or sp.y > size.y + 100:
					continue
			else:
				# direction from the view centre, in camera space; things behind you pin to
				# the bottom edge ("turn around"), things beside you to the sides
				var lp := cam.global_transform.affine_inverse() * p
				var dir := Vector2(lp.x, -lp.y * 0.35)
				if behind:
					dir = Vector2(lp.x * 0.25, 1.0)
				if dir.length() < 0.001:
					dir = Vector2.RIGHT
				dir = dir.normalized()
				sp = _edge_point(inner, dir)
				arrow = dir
		var dist := cam.global_position.distance_to(p)
		var fs := w.font_px
		if w.scale_with_distance:
			fs = int(clampf(w.font_px * 1.45 - dist * 1.1, w.font_px * 0.7, w.font_px * 1.45))
		if w.locked:
			fs = int(fs * 1.15)
		elif w.recommended:
			fs = int(fs * 1.12)
		var t := w.word.substr(0, w.typed)
		var r := w.word.substr(w.typed)
		var wt := _font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x if t != "" else 0.0
		var wr := _font.get_string_size(r, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x if r != "" else 0.0
		var x := sp.x - (wt + wr) * 0.5
		var y := sp.y + fs * 0.35
		var oc := LOCK if w.locked else INK
		var osz := maxi(3, int(fs * 0.14))
		if arrow != Vector2.ZERO:
			# pinned: the arrow sits against the screen edge, the word just inside it
			var s := fs * 0.55
			var horizontal := absf(arrow.x) >= absf(arrow.y)
			var d := Vector2(signf(arrow.x), 0.0) if horizontal else Vector2(0.0, signf(arrow.y))
			var tip: Vector2
			if horizontal:
				tip = Vector2(size.x - 6.0 if d.x > 0.0 else 6.0, clampf(sp.y, 40.0, size.y - 40.0))
				x = (tip.x - s * 1.25 - (wt + wr) - 4.0) if d.x > 0.0 else (tip.x + s * 1.25 + 4.0)
				y = tip.y + fs * 0.35
			else:
				tip = Vector2(clampf(sp.x, 60.0, size.x - 60.0), size.y - 6.0 if d.y > 0.0 else 6.0)
				x = tip.x - (wt + wr) * 0.5
				y = (tip.y - s * 1.25 - 6.0) if d.y > 0.0 else (tip.y + s * 1.25 + fs * 0.9)
			_draw_arrow(tip, d, s, w.typed > 0)
		var typed_col := RETIRED if w.retired else GOLD
		var rest_col := RETIRED if w.retired else (GOLD if w.recommended else CREAM)
		if w.recommended and not w.retired:
			var marker := "▶"
			var mw := _font.get_string_size(marker, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			draw_string_outline(_font, Vector2(x - mw - 7.0, y), marker, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, osz, INK)
			draw_string(_font, Vector2(x - mw - 7.0, y), marker, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, GOLD)
		if t != "":
			draw_string_outline(_font, Vector2(x, y), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, osz, oc)
			draw_string(_font, Vector2(x, y), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, typed_col)
		if r != "":
			draw_string_outline(_font, Vector2(x + wt, y), r, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, osz, oc)
			draw_string(_font, Vector2(x + wt, y), r, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, rest_col)
		if w.retired:
			var strike_y := y - fs * 0.28
			draw_line(Vector2(x - 2.0, strike_y), Vector2(x + wt + wr + 2.0, strike_y), INK, 6.0)
			draw_line(Vector2(x - 2.0, strike_y), Vector2(x + wt + wr + 2.0, strike_y), RETIRED, 2.0)


## Screen anchor of a world point for a label with `keep`: {pos, on_screen}. Shared with
## the tests so "the word is readable" can be checked headless.
static func anchor_for(cam: Camera3D, p: Vector3, vp_size: Vector2, ui_size: Vector2, keep: bool) -> Dictionary:
	if cam.is_position_behind(p):
		return { "pos": Vector2.ZERO, "on_screen": false }
	var scale := ui_size / vp_size
	var sp := cam.unproject_position(p) * scale
	var inner := Rect2(EDGE_MARGIN, ui_size - EDGE_MARGIN * 2.0)
	if inner.has_point(sp):
		return { "pos": sp, "on_screen": true }
	if keep:
		return { "pos": sp.clamp(inner.position, inner.end), "on_screen": true }
	return { "pos": sp, "on_screen": false }


## Where a ray from the centre of `r` along `dir` leaves it.
func _edge_point(r: Rect2, dir: Vector2) -> Vector2:
	var c := r.get_center()
	var half := r.size * 0.5
	var tx := half.x / absf(dir.x) if absf(dir.x) > 0.0001 else 1e9
	var ty := half.y / absf(dir.y) if absf(dir.y) > 0.0001 else 1e9
	return c + dir * minf(tx, ty)


## A chunky triangle with its tip at `tip`, pointing along the axis direction `d`.
func _draw_arrow(tip: Vector2, d: Vector2, s: float, active: bool) -> void:
	var base := tip - d * s
	var side := Vector2(-d.y, d.x) * s * 0.6
	var pts := PackedVector2Array([tip, base + side, base - side])
	var col := GOLD if active else CREAM
	draw_colored_polygon(pts, INK)
	var inner := PackedVector2Array([tip - d * 2.5, base + side * 0.62 - d * 0.5, base - side * 0.62 - d * 0.5])
	draw_colored_polygon(inner, col)
