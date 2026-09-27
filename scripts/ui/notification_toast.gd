class_name NotificationToast
extends Control
## Short, non-modal feedback that is independent from navigation surfaces. Interaction
## results replace one another instead of forming a queue, so repeated looting/building
## actions never turn into a second HUD.

const INK := Color("#120a1f", 0.94)
const CREAM := Color("#fdf6e3")
const GOLD := Color("#facc15")
const GREEN := Color("#7ee787")
const PINK := Color("#ff6f91")

var _panel: PanelContainer
var _label: Label
var _tween: Tween
var _message := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_panel.offset_left = -360.0
	_panel.offset_top = -166.0
	_panel.offset_right = 360.0
	_panel.offset_bottom = -102.0
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = INK
	style.border_color = Color("#8067a8", 0.95)
	style.set_border_width_all(2)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 18.0
	style.content_margin_right = 18.0
	style.content_margin_top = 10.0
	style.content_margin_bottom = 10.0
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)
	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.add_theme_font_size_override("font_size", 16)
	_label.add_theme_color_override("font_color", CREAM)
	_label.add_theme_constant_override("outline_size", 4)
	_label.add_theme_color_override("font_outline_color", Color("#120a1f"))
	_panel.add_child(_label)


func show_notice(message: String, tone := "auto", seconds := -1.0) -> void:
	if message.strip_edges() == "":
		return
	_message = message
	_label.text = message
	_label.add_theme_color_override("font_color", _tone_color(tone, message))
	if _tween != null and _tween.is_valid():
		_tween.kill()
	visible = true
	modulate.a = 0.0
	var hold := seconds if seconds > 0.0 else clampf(1.8 + message.length() * 0.025, 2.2, 4.2)
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 1.0, 0.12)
	_tween.tween_interval(hold)
	_tween.tween_property(self, "modulate:a", 0.0, 0.35)
	_tween.tween_callback(func(): visible = false)


func current_message() -> String:
	return _message


func _tone_color(tone: String, message: String) -> Color:
	if tone == "warning":
		return PINK
	if tone == "success":
		return GREEN
	if tone == "accent":
		return GOLD
	var lower := message.to_lower()
	if lower.contains("no route") or lower.contains("cannot") or lower.contains("can't") \
			or lower.contains("full") or lower.begins_with("move closer") \
			or lower.contains("not enough") or lower.contains("need "):
		return PINK
	if lower.contains("collected") or lower.contains("placed") or lower.contains("rescued") \
			or lower.contains("restocked") or lower.contains("unloaded") \
			or lower.contains("dismantled") or lower.contains("bandaged"):
		return GREEN
	return GOLD
