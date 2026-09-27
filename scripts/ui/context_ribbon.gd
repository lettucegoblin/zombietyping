class_name ContextRibbon
extends Control
## Short-lived, state-aware guidance. This keeps control instructions out of the permanent
## HUD and only introduces them when the player enters a new interaction state.

const INK := Color("#120a1f", 0.93)
const PURPLE := Color("#8067a8", 0.95)
const GOLD := Color("#facc15")
const CREAM := Color("#fdf6e3")
const MUTED := Color("#b8adca")

var context_key := ""
var title := ""
var detail := ""
var _time_left := 0.0
var _fade_seconds := 0.35
var _font: Font


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	process_mode = Node.PROCESS_MODE_ALWAYS
	_font = ThemeDB.fallback_font
	visible = false


## Repeated HUD refreshes do not restart the timer. A changed key means the interaction
## state changed, so its guidance gets one fresh, readable beat.
func show_context(key: String, heading: String, description := "", seconds := 4.5) -> void:
	if key == "":
		hide_context()
		return
	if key == context_key:
		return
	context_key = key
	title = heading
	detail = description
	_time_left = maxf(seconds, _fade_seconds)
	modulate.a = 1.0
	visible = true
	queue_redraw()


func hide_context() -> void:
	context_key = ""
	title = ""
	detail = ""
	_time_left = 0.0
	visible = false


func _process(dt: float) -> void:
	if not visible:
		return
	_time_left = maxf(0.0, _time_left - dt)
	modulate.a = minf(1.0, _time_left / _fade_seconds)
	if _time_left <= 0.0:
		visible = false


func _draw() -> void:
	if title == "":
		return
	var title_size := 17
	var detail_size := 13
	var title_width := _font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, title_size).x
	var detail_width := _font.get_string_size(detail, HORIZONTAL_ALIGNMENT_LEFT, -1, detail_size).x if detail != "" else 0.0
	var panel_width := clampf(maxf(title_width, detail_width) + 46.0, 260.0, 620.0)
	var panel_height := 58.0 if detail != "" else 40.0
	var panel := Rect2(Vector2((size.x - panel_width) * 0.5, size.y - panel_height - 24.0),
		Vector2(panel_width, panel_height))
	draw_rect(panel, INK, true)
	draw_rect(panel, PURPLE, false, 2.0)
	draw_rect(Rect2(panel.position, Vector2(5.0, panel.size.y)), GOLD, true)
	var title_pos := Vector2(panel.get_center().x - title_width * 0.5 + 2.5,
		panel.position.y + (23.0 if detail != "" else 26.0))
	draw_string(_font, title_pos, title, HORIZONTAL_ALIGNMENT_LEFT, -1, title_size, GOLD)
	if detail != "":
		var detail_pos := Vector2(panel.get_center().x - detail_width * 0.5 + 2.5, panel.end.y - 10.0)
		draw_string(_font, detail_pos, detail, HORIZONTAL_ALIGNMENT_LEFT, -1, detail_size, CREAM if _time_left > 0.8 else MUTED)
