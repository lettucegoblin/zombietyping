class_name ModeHint
extends Control
## A short, centered handoff between the two movement grammars. The controls are sprites,
## so the instruction remains recognizable in browser builds without font glyph support.

const WASD_TEXTURE := preload("res://assets/sprites/ui/control_wasd.png")
const KEYBOARD_TEXTURE := preload("res://assets/sprites/ui/control_keyboard.png")
const PANEL_SIZE := Vector2(390, 188)
const INK := Color("#120a1f", 0.94)
const GOLD := Color("#facc15")
const CREAM := Color("#fdf6e3")

var last_mode := ""
var _tween: Tween
var _font: Font


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_font = ThemeDB.fallback_font
	visible = false


func show_safezone() -> void:
	_show_mode("safezone")


func show_street() -> void:
	_show_mode("street")


func _show_mode(next_mode: String) -> void:
	last_mode = next_mode
	if _tween != null and _tween.is_valid():
		_tween.kill()
	visible = true
	modulate.a = 0.0
	queue_redraw()
	_tween = create_tween()
	_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_tween.tween_property(self, "modulate:a", 1.0, 0.2)
	_tween.tween_interval(1.65)
	_tween.tween_property(self, "modulate:a", 0.0, 0.55)
	_tween.tween_callback(func(): visible = false)


func _draw() -> void:
	if last_mode == "":
		return
	var panel := Rect2((size - PANEL_SIZE) * 0.5, PANEL_SIZE)
	draw_rect(panel, INK, true)
	draw_rect(panel, GOLD, false, 3.0)
	var texture: Texture2D = WASD_TEXTURE if last_mode == "safezone" else KEYBOARD_TEXTURE
	var target_size := Vector2(108, 96) if last_mode == "safezone" else Vector2(190, 104)
	var texture_rect := Rect2(panel.get_center() - target_size * 0.5 + Vector2(0, -18), target_size)
	draw_texture_rect(texture, texture_rect, false)
	var title := "FREE ROAM" if last_mode == "safezone" else "TYPED TRAVEL"
	var subtitle := "move with WASD" if last_mode == "safezone" else "type a building address"
	_draw_centered(title, panel.position.y + 25.0, 20, GOLD)
	_draw_centered(subtitle, panel.end.y - 17.0, 16, CREAM)


func _draw_centered(text: String, baseline_y: float, font_size: int, color: Color) -> void:
	var width := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var baseline := Vector2((size.x - width) * 0.5, baseline_y)
	draw_string_outline(_font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		font_size, 5, Color("#120a1f"))
	draw_string(_font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
