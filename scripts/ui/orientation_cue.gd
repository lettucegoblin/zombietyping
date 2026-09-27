class_name OrientationCue
extends Control
## One calm centre-screen language for typed destinations and proximity-held stairs.

var _destination_text := ""
var _destination_alpha := 0.0
var _destination_linger := 0.0
var _stair_progress := 0.0
var _stair_direction := ""


func set_destination_buffer(text: String) -> void:
	if text != "":
		_destination_text = text
		_destination_alpha = 1.0
		_destination_linger = 0.0
	elif _destination_linger <= 0.0:
		_destination_alpha = 0.0
	queue_redraw()


func commit_destination(text: String) -> void:
	_destination_text = text
	_destination_alpha = 1.0
	_destination_linger = 1.15
	queue_redraw()


func set_stair(progress: float, direction := "") -> void:
	_stair_progress = clampf(progress, 0.0, 1.0)
	_stair_direction = direction
	queue_redraw()


func _process(dt: float) -> void:
	if _destination_linger > 0.0:
		_destination_linger = maxf(0.0, _destination_linger - dt)
		if _destination_linger < 0.45:
			_destination_alpha = _destination_linger / 0.45
		queue_redraw()


func _draw() -> void:
	var font := ThemeDB.fallback_font
	if _destination_alpha > 0.01 and _destination_text != "":
		var shown := _destination_text.to_upper()
		var size := 42
		var width := font.get_string_size(shown, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var pos := Vector2((get_viewport_rect().size.x - width) * 0.5, get_viewport_rect().size.y * 0.52)
		draw_string(font, pos + Vector2(3, 3), shown, HORIZONTAL_ALIGNMENT_LEFT, -1, size,
			Color(0.04, 0.02, 0.08, 0.90 * _destination_alpha))
		draw_string(font, pos, shown, HORIZONTAL_ALIGNMENT_LEFT, -1, size,
			Color(0.98, 0.80, 0.08, _destination_alpha))
	if _stair_progress > 0.0:
		var centre := Vector2(get_viewport_rect().size.x * 0.5, get_viewport_rect().size.y * 0.64)
		draw_circle(centre, 31.0, Color(0.04, 0.02, 0.08, 0.72), false, 7.0)
		draw_arc(centre, 31.0, -PI * 0.5, -PI * 0.5 + TAU * _stair_progress,
			48, Color("#facc15"), 7.0, true)
		var label := "STAIRS " + _stair_direction.to_upper()
		var label_size := 17
		var label_width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, label_size).x
		draw_string(font, centre + Vector2(-label_width * 0.5, 58), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, label_size, Color("#fdf6e3"))
