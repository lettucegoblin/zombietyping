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
	var items: Array[Dictionary] = []
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
		var tip := Vector2.ZERO
		var d := Vector2.ZERO
		var s := fs * 0.55
		if arrow != Vector2.ZERO:
			# pinned: the arrow sits against the screen edge, the word just inside it
			var horizontal := absf(arrow.x) >= absf(arrow.y)
			d = Vector2(signf(arrow.x), 0.0) if horizontal else Vector2(0.0, signf(arrow.y))
			if horizontal:
				tip = Vector2(size.x - 6.0 if d.x > 0.0 else 6.0, clampf(sp.y, 40.0, size.y - 40.0))
				x = (tip.x - s * 1.25 - (wt + wr) - 4.0) if d.x > 0.0 else (tip.x + s * 1.25 + 4.0)
				y = tip.y + fs * 0.35
			else:
				tip = Vector2(clampf(sp.x, 60.0, size.x - 60.0), size.y - 6.0 if d.y > 0.0 else 6.0)
				x = tip.x - (wt + wr) * 0.5
				y = (tip.y - s * 1.25 - 6.0) if d.y > 0.0 else (tip.y + s * 1.25 + fs * 0.9)
		var marker_width := 0.0
		if w.recommended and not w.retired:
			marker_width = _font.get_string_size("▶", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 7.0
		var rect := Rect2(Vector2(x - marker_width, y - fs * 0.9), Vector2(wt + wr + marker_width, fs * 1.18)).grow(osz + 2.0)
		items.append({
			"label": w, "typed_text": t, "rest_text": r, "typed_width": wt,
			"rest_width": wr, "x": x, "y": y, "font_size": fs, "outline": osz,
			"outline_color": oc, "tip": tip, "direction": d, "arrow_size": s,
			"base_rect": rect, "offset": Vector2.ZERO,
			"priority": (2000 if w.typed > 0 else 0) + (1000 if w.locked else 0)
				+ (250 if w.recommended else 0) + (0 if w.retired else 100),
			"stable_id": w.get_instance_id(),
		})

	_resolve_nudges(items, Rect2(Vector2(8.0, 8.0), size - Vector2(16.0, 16.0)))
	for item in items:
		if item.get("layout_visible", true):
			_draw_word_item(item)


func _draw_word_item(item: Dictionary) -> void:
	var w: WordLabel = item["label"]
	var offset: Vector2 = item["offset"]
	var x: float = item["x"] + offset.x
	var y: float = item["y"] + offset.y
	var fs: int = item["font_size"]
	var osz: int = item["outline"]
	var t: String = item["typed_text"]
	var r: String = item["rest_text"]
	var wt: float = item["typed_width"]
	var tip: Vector2 = item["tip"] + offset
	var d: Vector2 = item["direction"]
	if d != Vector2.ZERO:
		_draw_arrow(tip, d, float(item["arrow_size"]), w.typed > 0)
	# Gold once again means "these letters have been typed". A recommendation keeps its
	# gold chevron, but no longer paints the untyped suffix gold and masks progress.
	var typed_col := GOLD
	var rest_col := RETIRED if w.retired else CREAM
	if w.recommended and not w.retired:
		var marker := "▶"
		var mw := _font.get_string_size(marker, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string_outline(_font, Vector2(x - mw - 7.0, y), marker, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, osz, INK)
		draw_string(_font, Vector2(x - mw - 7.0, y), marker, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, GOLD)
	if t != "":
		draw_string_outline(_font, Vector2(x, y), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, osz, item["outline_color"])
		draw_string(_font, Vector2(x, y), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, typed_col)
	if r != "":
		draw_string_outline(_font, Vector2(x + wt, y), r, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, osz, item["outline_color"])
		draw_string(_font, Vector2(x + wt, y), r, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, rest_col)
	if w.retired:
		var strike_y := y - fs * 0.28
		var word_width: float = item["typed_width"] + item["rest_width"]
		draw_line(Vector2(x - 2.0, strike_y), Vector2(x + word_width + 2.0, strike_y), INK, 6.0)
		draw_line(Vector2(x - 2.0, strike_y), Vector2(x + word_width + 2.0, strike_y), RETIRED, 2.0)


## Resolve labels in priority order. Active typing and route recommendations keep their
## anchors; other words try increasingly broad vertical/diagonal offsets. Edge hints move
## only along their edge, so their arrows continue pointing in the correct direction.
func _resolve_nudges(items: Array[Dictionary], bounds: Rect2) -> void:
	items.sort_custom(func(a: Dictionary, b: Dictionary):
		if int(a["priority"]) != int(b["priority"]):
			return int(a["priority"]) > int(b["priority"])
		return int(a["stable_id"]) < int(b["stable_id"])
	)
	var placed: Array[Rect2] = []
	for item in items:
		var offsets := _nudge_offsets(item)
		var best_offset := Vector2.ZERO
		var best_rect: Rect2 = item["base_rect"]
		var best_score := INF
		var found_slot := false
		for raw_offset in offsets:
			var offset: Vector2 = raw_offset
			var rect: Rect2 = item["base_rect"]
			rect.position += offset
			offset += _fit_rect(rect, bounds, item["direction"])
			rect = item["base_rect"]
			rect.position += offset
			var overlap := 0.0
			for other in placed:
				if rect.intersects(other, true):
					overlap += rect.intersection(other).get_area()
			var score := overlap * 1000.0 + offset.length_squared() * 0.01
			if score < best_score:
				best_score = score
				best_offset = offset
				best_rect = rect
			if overlap <= 0.001:
				found_slot = true
				break
		item["offset"] = best_offset
		item["layout_visible"] = found_slot
		if found_slot:
			placed.append(best_rect)


func _nudge_offsets(item: Dictionary) -> Array[Vector2]:
	var offsets: Array[Vector2] = [Vector2.ZERO]
	var rect: Rect2 = item["base_rect"]
	var step := maxf(28.0, rect.size.y + 7.0)
	var d: Vector2 = item["direction"]
	for ring in range(1, 11):
		var amount := step * ring
		if absf(d.x) > 0.5: # left/right edge: slide vertically
			offsets.append(Vector2(0, -amount))
			offsets.append(Vector2(0, amount))
		elif absf(d.y) > 0.5: # top/bottom edge: slide horizontally
			offsets.append(Vector2(-amount, 0))
			offsets.append(Vector2(amount, 0))
		else:
			offsets.append(Vector2(0, -amount))
			offsets.append(Vector2(0, amount))
			offsets.append(Vector2(-amount * 0.72, -amount * 0.72))
			offsets.append(Vector2(amount * 0.72, -amount * 0.72))
			offsets.append(Vector2(-amount, 0))
			offsets.append(Vector2(amount, 0))
	return offsets


func _fit_rect(rect: Rect2, bounds: Rect2, edge_direction: Vector2) -> Vector2:
	var correction := Vector2.ZERO
	if absf(edge_direction.x) <= 0.5:
		if rect.position.x < bounds.position.x:
			correction.x += bounds.position.x - rect.position.x
		elif rect.end.x > bounds.end.x:
			correction.x -= rect.end.x - bounds.end.x
	if absf(edge_direction.y) <= 0.5:
		if rect.position.y < bounds.position.y:
			correction.y += bounds.position.y - rect.position.y
		elif rect.end.y > bounds.end.y:
			correction.y -= rect.end.y - bounds.end.y
	return correction


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
