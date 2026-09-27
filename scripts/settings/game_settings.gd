class_name GameSettings
extends Node
## Runtime-owned, version-tolerant preferences. Audio controls are described here and the
## pause menu builds itself from this list, so adding a future sound class is one data row.

signal changed(key: String, value: Variant)

const CONFIG_PATH := "user://settings.cfg"
const AUDIO_BUSES := [
	{"name": "Master", "label": "Overall sound", "default": 1.0},
	{"name": "Combat", "label": "Combat", "default": 1.0},
	{"name": "Interaction", "label": "Doors & interactions", "default": 1.0},
	{"name": "Footsteps", "label": "Footsteps", "default": 1.0},
	{"name": "Ambience", "label": "World ambience", "default": 1.0},
	{"name": "Television", "label": "Television static", "default": 1.0},
	{"name": "Survivor", "label": "Survivor cues", "default": 1.0},
	{"name": "UI", "label": "Typing & UI", "default": 1.0},
]

const COMBAT_SOUNDS := ["shot", "hit", "kill", "miss", "growl1", "growl2", "startle"]
const INTERACTION_SOUNDS := ["door", "creak", "clank"]
const FOOTSTEP_SOUNDS := ["step1", "step2"]
const AMBIENCE_SOUNDS := ["wind", "room", "electric", "pipes", "crow1", "crow2",
	"flutter", "groan_far", "drip", "creak2", "thump", "knock", "hum", "siren"]
const UI_SOUNDS := ["key", "loot_pickup", "loot_complete"]

var persistence_enabled := DisplayServer.get_name() != "headless"
var mouse_sensitivity := 1.0
var invert_mouse_y := false
var screen_shake := 1.0
var screen_flash := 1.0
var typing_text_scale := 1.0
var fullscreen := false


func _ready() -> void:
	ensure_audio_buses()
	load_settings()
	apply_audio()
	apply_display()


func audio_controls() -> Array:
	return AUDIO_BUSES


func ensure_audio_buses() -> void:
	ensure_buses()


static func ensure_buses() -> void:
	for definition in AUDIO_BUSES:
		var bus_name := str(definition["name"])
		if bus_name == "Master" or AudioServer.get_bus_index(bus_name) >= 0:
			continue
		AudioServer.add_bus()
		var index := AudioServer.bus_count - 1
		AudioServer.set_bus_name(index, bus_name)
		AudioServer.set_bus_send(index, "Master")


func audio_volume(bus_name: String) -> float:
	var index := AudioServer.get_bus_index(bus_name)
	if index < 0 or AudioServer.is_bus_mute(index):
		return 0.0
	return clampf(db_to_linear(AudioServer.get_bus_volume_db(index)), 0.0, 1.0)


func set_audio_volume(bus_name: String, linear: float, save_now := true) -> void:
	ensure_audio_buses()
	var index := AudioServer.get_bus_index(bus_name)
	if index < 0:
		return
	linear = clampf(linear, 0.0, 1.0)
	AudioServer.set_bus_mute(index, linear <= 0.0001)
	AudioServer.set_bus_volume_db(index, linear_to_db(maxf(linear, 0.0001)))
	changed.emit("audio/" + bus_name, linear)
	if save_now:
		save_settings()


func set_float(key: String, value: float, save_now := true) -> void:
	match key:
		"mouse_sensitivity": mouse_sensitivity = clampf(value, 0.25, 2.0)
		"screen_shake": screen_shake = clampf(value, 0.0, 1.0)
		"screen_flash": screen_flash = clampf(value, 0.0, 1.0)
		"typing_text_scale": typing_text_scale = clampf(value, 0.8, 1.4)
		_: return
	changed.emit(key, get(key))
	if save_now:
		save_settings()


func set_bool(key: String, value: bool, save_now := true) -> void:
	match key:
		"invert_mouse_y": invert_mouse_y = value
		"fullscreen":
			fullscreen = value
			apply_display()
		_: return
	changed.emit(key, get(key))
	if save_now:
		save_settings()


func reset_defaults() -> void:
	for definition in AUDIO_BUSES:
		set_audio_volume(str(definition["name"]), float(definition["default"]), false)
	mouse_sensitivity = 1.0
	invert_mouse_y = false
	screen_shake = 1.0
	screen_flash = 1.0
	typing_text_scale = 1.0
	fullscreen = false
	apply_display()
	changed.emit("reset", true)
	save_settings()


func load_settings() -> void:
	var config := ConfigFile.new()
	if not persistence_enabled or config.load(CONFIG_PATH) != OK:
		for definition in AUDIO_BUSES:
			set_audio_volume(str(definition["name"]), float(definition["default"]), false)
		return
	for definition in AUDIO_BUSES:
		var bus_name := str(definition["name"])
		set_audio_volume(bus_name,
			float(config.get_value("audio", bus_name, definition["default"])), false)
	mouse_sensitivity = clampf(float(config.get_value("controls", "mouse_sensitivity", 1.0)), 0.25, 2.0)
	invert_mouse_y = bool(config.get_value("controls", "invert_mouse_y", false))
	screen_shake = clampf(float(config.get_value("accessibility", "screen_shake", 1.0)), 0.0, 1.0)
	screen_flash = clampf(float(config.get_value("accessibility", "screen_flash", 1.0)), 0.0, 1.0)
	typing_text_scale = clampf(float(config.get_value("accessibility", "typing_text_scale", 1.0)), 0.8, 1.4)
	fullscreen = bool(config.get_value("display", "fullscreen", false))


func save_settings() -> void:
	if not persistence_enabled:
		return
	var config := ConfigFile.new()
	for definition in AUDIO_BUSES:
		var bus_name := str(definition["name"])
		config.set_value("audio", bus_name, audio_volume(bus_name))
	config.set_value("controls", "mouse_sensitivity", mouse_sensitivity)
	config.set_value("controls", "invert_mouse_y", invert_mouse_y)
	config.set_value("accessibility", "screen_shake", screen_shake)
	config.set_value("accessibility", "screen_flash", screen_flash)
	config.set_value("accessibility", "typing_text_scale", typing_text_scale)
	config.set_value("display", "fullscreen", fullscreen)
	config.save(CONFIG_PATH)


func apply_audio() -> void:
	ensure_audio_buses()
	# Values are already installed while loading. This method remains a single public hook
	# for tests and future device/bus rebuilds.
	for definition in AUDIO_BUSES:
		var bus_name := str(definition["name"])
		var index := AudioServer.get_bus_index(bus_name)
		if index >= 0 and not AudioServer.is_bus_mute(index):
			AudioServer.set_bus_volume_db(index, linear_to_db(maxf(audio_volume(bus_name), 0.0001)))


func apply_display() -> void:
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen \
		else DisplayServer.WINDOW_MODE_WINDOWED)


static func bus_for_sound(sound_name: String) -> String:
	if sound_name in COMBAT_SOUNDS:
		return "Combat"
	if sound_name in INTERACTION_SOUNDS:
		return "Interaction"
	if sound_name in FOOTSTEP_SOUNDS:
		return "Footsteps"
	if sound_name in AMBIENCE_SOUNDS:
		return "Ambience"
	if sound_name in UI_SOUNDS:
		return "UI"
	return "Interaction"
