class_name PauseMenu
extends Control
## Always-processing pause/settings overlay. The audio rows are generated from
## GameSettings.AUDIO_BUSES rather than being hard-coded controls.

signal resume_requested

var settings: GameSettings
var _audio_sliders: Dictionary = {}
var _value_controls: Dictionary = {}
var _bool_controls: Dictionary = {}
var _syncing := false
var _resume_button: Button
var _settings_box: VBoxContainer

const INK := Color("#120a1f")
const PANEL := Color("#1d1329")
const CREAM := Color("#fdf6e3")
const GOLD := Color("#facc15")
const MUTED := Color("#9f95ad")


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process_input(true)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build_ui()


func configure(value: GameSettings) -> void:
	settings = value
	_build_settings()
	_refresh_controls()


func open() -> void:
	visible = true
	_refresh_controls()
	if _resume_button != null:
		_resume_button.grab_focus()


func close() -> void:
	if not visible:
		return
	visible = false
	resume_requested.emit()


func audio_slider_count() -> int:
	return _audio_sliders.size()


func audio_slider(bus_name: String) -> HSlider:
	return _audio_sliders.get(bus_name) as HSlider


func setting_slider(key: String) -> HSlider:
	return _value_controls.get(key) as HSlider


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()


func _build_ui() -> void:
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.025, 0.018, 0.035, 0.90)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -400.0
	panel.offset_top = -330.0
	panel.offset_right = 400.0
	panel.offset_bottom = 330.0
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = PANEL
	panel_style.border_color = Color("#6b3f82")
	panel_style.set_border_width_all(3)
	panel_style.corner_radius_top_left = 5
	panel_style.corner_radius_top_right = 5
	panel_style.corner_radius_bottom_left = 5
	panel_style.corner_radius_bottom_right = 5
	panel.add_theme_stylebox_override("panel", panel_style)
	add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_bottom", 22)
	panel.add_child(margin)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	margin.add_child(body)

	var heading := HBoxContainer.new()
	body.add_child(heading)
	var title := Label.new()
	title.text = "PAUSED"
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", GOLD)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(title)
	var esc := Label.new()
	esc.text = "ESC  resume"
	esc.add_theme_font_size_override("font_size", 16)
	esc.add_theme_color_override("font_color", MUTED)
	esc.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	heading.add_child(esc)
	body.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.name = "SettingsScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	_settings_box = VBoxContainer.new()
	_settings_box.name = "Settings"
	_settings_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_settings_box.add_theme_constant_override("separation", 7)
	scroll.add_child(_settings_box)

	body.add_child(HSeparator.new())
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 12)
	body.add_child(footer)
	_resume_button = _button("RESUME", GOLD, INK)
	_resume_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_resume_button.pressed.connect(close)
	footer.add_child(_resume_button)
	var defaults := _button("RESET DEFAULTS", Color("#99f6e4"), INK)
	defaults.pressed.connect(func():
		if settings != null:
			settings.reset_defaults()
			_refresh_controls())
	footer.add_child(defaults)
	var quit := _button("QUIT TO DESKTOP", Color("#ff8aa1"), INK)
	quit.pressed.connect(func(): get_tree().quit())
	footer.add_child(quit)


func _build_settings() -> void:
	if _settings_box == null:
		return
	for child in _settings_box.get_children():
		child.free()
	_audio_sliders.clear()
	_value_controls.clear()
	_bool_controls.clear()
	if settings == null:
		return

	_add_section("AUDIO")
	var audio_definitions := settings.audio_controls()
	if not audio_definitions.is_empty():
		_add_audio_slider(audio_definitions[0])
		var note := Label.new()
		note.text = "Sound categories — generated from the active mixer"
		note.add_theme_font_size_override("font_size", 13)
		note.add_theme_color_override("font_color", MUTED)
		_settings_box.add_child(note)
		for i in range(1, audio_definitions.size()):
			_add_audio_slider(audio_definitions[i])

	_add_section("CONTROLS")
	_add_value_slider("mouse_sensitivity", "Mouse look sensitivity", 25.0, 200.0, 1.0,
		func(v: float): settings.set_float("mouse_sensitivity", v / 100.0), "%")
	_add_check("invert_mouse_y", "Invert vertical mouse look",
		func(v: bool): settings.set_bool("invert_mouse_y", v))

	_add_section("ACCESSIBILITY")
	_add_value_slider("screen_shake", "Screen shake", 0.0, 100.0, 1.0,
		func(v: float): settings.set_float("screen_shake", v / 100.0), "%")
	_add_value_slider("screen_flash", "Hit flashes", 0.0, 100.0, 1.0,
		func(v: float): settings.set_float("screen_flash", v / 100.0), "%")
	_add_value_slider("typing_text_scale", "World typing text", 80.0, 140.0, 1.0,
		func(v: float): settings.set_float("typing_text_scale", v / 100.0), "%")

	_add_section("DISPLAY")
	_add_check("fullscreen", "Fullscreen", func(v: bool): settings.set_bool("fullscreen", v))


func _add_section(text: String) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size.y = 8.0
	_settings_box.add_child(spacer)
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", GOLD)
	_settings_box.add_child(label)


func _add_audio_slider(definition: Dictionary) -> void:
	var bus_name := str(definition["name"])
	var slider := _slider_row(str(definition["label"]), 0.0, 100.0, 1.0, "%")
	_audio_sliders[bus_name] = slider
	slider.value_changed.connect(func(value: float):
		_update_value_label(slider, value, "%")
		if not _syncing and settings != null:
			settings.set_audio_volume(bus_name, value / 100.0))


func _add_value_slider(key: String, label: String, minimum: float, maximum: float,
		step: float, callback: Callable, suffix: String) -> void:
	var slider := _slider_row(label, minimum, maximum, step, suffix)
	_value_controls[key] = slider
	slider.value_changed.connect(func(value: float):
		_update_value_label(slider, value, suffix)
		if not _syncing:
			callback.call(value))


func _add_check(key: String, label: String, callback: Callable) -> void:
	var check := CheckButton.new()
	check.text = label
	check.add_theme_font_size_override("font_size", 16)
	check.add_theme_color_override("font_color", CREAM)
	check.toggled.connect(func(value: bool):
		if not _syncing:
			callback.call(value))
	_bool_controls[key] = check
	_settings_box.add_child(check)


func _slider_row(label_text: String, minimum: float, maximum: float, step: float, suffix: String) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_settings_box.add_child(row)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 220.0
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", CREAM)
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size.x = 330.0
	row.add_child(slider)
	var value_label := Label.new()
	value_label.custom_minimum_size.x = 58.0
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.add_theme_font_size_override("font_size", 15)
	value_label.add_theme_color_override("font_color", MUTED)
	row.add_child(value_label)
	slider.set_meta("value_label", value_label)
	_update_value_label(slider, minimum, suffix)
	return slider


func _update_value_label(slider: HSlider, value: float, suffix: String) -> void:
	var label: Label = slider.get_meta("value_label") as Label
	if label != null:
		label.text = "%d%s" % [roundi(value), suffix]


func _refresh_controls() -> void:
	if settings == null:
		return
	_syncing = true
	for bus_name in _audio_sliders:
		var slider: HSlider = _audio_sliders[bus_name]
		slider.value = settings.audio_volume(str(bus_name)) * 100.0
		_update_value_label(slider, slider.value, "%")
	_set_slider("mouse_sensitivity", settings.mouse_sensitivity * 100.0)
	_set_slider("screen_shake", settings.screen_shake * 100.0)
	_set_slider("screen_flash", settings.screen_flash * 100.0)
	_set_slider("typing_text_scale", settings.typing_text_scale * 100.0)
	_set_check("invert_mouse_y", settings.invert_mouse_y)
	_set_check("fullscreen", settings.fullscreen)
	_syncing = false


func _set_slider(key: String, value: float) -> void:
	var slider: HSlider = _value_controls.get(key) as HSlider
	if slider != null:
		slider.value = value
		_update_value_label(slider, value, "%")


func _set_check(key: String, value: bool) -> void:
	var check: CheckButton = _bool_controls.get(key) as CheckButton
	if check != null:
		check.button_pressed = value


func _button(text: String, color: Color, text_color: Color) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, 42)
	button.add_theme_font_size_override("font_size", 15)
	button.add_theme_color_override("font_color", text_color)
	button.add_theme_color_override("font_hover_color", text_color)
	button.add_theme_color_override("font_pressed_color", text_color)
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = 3
	style.corner_radius_top_right = 3
	style.corner_radius_bottom_left = 3
	style.corner_radius_bottom_right = 3
	button.add_theme_stylebox_override("normal", style)
	button.add_theme_stylebox_override("hover", style.duplicate())
	button.add_theme_stylebox_override("pressed", style.duplicate())
	return button
