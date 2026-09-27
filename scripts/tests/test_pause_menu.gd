extends Node
## Pause ownership, dynamic audio mixer controls, routing, and live accessibility settings.

var _failed := false


func _ready() -> void:
	World.persistence_enabled = false
	var main: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	main.settings.persistence_enabled = false
	var menu: PauseMenu = main.pause_menu
	_check(not menu.visible, "pause menu started open")
	_check(main.hud.text.split("\n").size() <= 2, "gameplay HUD exceeded its two-line information ceiling")
	_check(main.context_ribbon != null, "contextual control ribbon was not attached")
	_check(menu.audio_slider_count() == GameSettings.AUDIO_BUSES.size(),
		"pause menu did not generate one control per mixer bus")
	for definition in GameSettings.AUDIO_BUSES:
		var bus_name := str(definition["name"])
		_check(AudioServer.get_bus_index(bus_name) >= 0, "missing mixer bus " + bus_name)
		_check(menu.audio_slider(bus_name) != null, "missing dynamic slider for " + bus_name)
	_check(not menu._audio_details_visible and menu._audio_detail_rows.all(func(row): return not row.visible),
		"pause menu did not begin with secondary mixer categories collapsed")
	menu._toggle_audio_details()
	_check(menu._audio_details_visible and menu._audio_detail_rows.all(func(row): return row.visible),
		"pause menu sound-category disclosure did not reveal all mixer controls")
	menu._toggle_audio_details()

	var escape := InputEventKey.new()
	escape.pressed = true
	escape.keycode = KEY_ESCAPE
	main._unhandled_input(escape)
	_check(menu.visible and get_tree().paused, "Escape did not open a paused menu")
	_check(not main.typist.enabled, "typing remained active behind pause menu")
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "pause menu did not release pointer")

	menu.audio_slider("Master").value = 37.0
	_check(absf(main.settings.audio_volume("Master") - 0.37) < 0.015,
		"overall sound slider did not drive Master bus")
	menu.audio_slider("Television").value = 23.0
	_check(absf(main.settings.audio_volume("Television") - 0.23) < 0.015,
		"category sound slider did not drive its mixer bus")
	menu.setting_slider("mouse_sensitivity").value = 150.0
	_check(absf(main.player.mouse_look_sensitivity - 0.00375) < 0.00001,
		"mouse sensitivity did not apply live")
	menu.setting_slider("screen_shake").value = 0.0
	main.player._shake = 0.0
	main.player.shake(1.0)
	_check(main.player._shake == 0.0, "zero screen shake still moved the camera")
	menu.setting_slider("typing_text_scale").value = 125.0
	_check(absf(main.words.text_scale - 1.25) < 0.001, "typing text scale did not apply live")

	main.sfx.play("shot")
	_check((main.sfx._pool[0] as AudioStreamPlayer).bus == "Combat", "gunshot was not routed to Combat")
	main.sfx.play("key")
	var ui_routed := false
	for player in main.sfx._pool:
		if (player as AudioStreamPlayer).bus == "UI" and (player as AudioStreamPlayer).playing:
			ui_routed = true
	_check(ui_routed, "typing sound was not routed to UI")

	menu._input(escape)
	_check(not menu.visible and not get_tree().paused, "Escape did not resume gameplay")
	_check(main.typist.enabled and main._gameplay_mouse_look, "resume did not restore gameplay input")

	main.settings.reset_defaults()
	if not _failed:
		print("PAUSE MENU OK  progressive mixer disclosure + routing + pause ownership + live accessibility settings")
	get_tree().quit(1 if _failed else 0)


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error("PAUSE MENU FAIL: " + message)
