class_name LootFlyover
extends Control
## Cleared-room rewards travel from their world position into a persistent backpack chip.
## The chip owns a presentation count so each unit advances exactly when its icon lands,
## rather than jumping ahead when the authoritative inventory is updated.

const PropLootRules = preload("res://scripts/loot/prop_loot.gd")

const ITEM_COLORS := {
	"packaged_food": Color("#f59e0b"),
	"bandages": Color("#fdf6e3"),
	"cloth_bundle": Color("#c39bd3"),
	"batteries": Color("#d9f99d"),
	"circuits": Color("#68d5ff"),
	"utensils": Color("#94a3b8"),
	"tool_kit": Color("#fdba74"),
	"fasteners": Color("#a6e3a1"),
	"fuel_can": Color("#ff6f91"),
}
const TRAY_SIZE := Vector2(224, 58)
const TOKEN_DURATION := 0.64
const TOKEN_STAGGER := 0.12

var camera: Camera3D
var view_container: Control
var source_viewport: SubViewport
var sfx: Node
var hud: Control
var _tokens: Array[Dictionary] = []
var _displayed_units := 0
var _displayed_field: Dictionary = {}
var _pulse := 0.0
var _combo := 0


func configure(world_camera: Camera3D, view: Control, viewport: SubViewport, sound: Node,
		hud_control: Control) -> void:
	camera = world_camera
	view_container = view
	source_viewport = viewport
	sfx = sound
	hud = hud_control
	sync_backpack()


func sync_backpack() -> void:
	if _tokens.is_empty():
		_displayed_units = World.backpack_units()
		_displayed_field = World.field_inventory.duplicate(true)
		queue_redraw()


## Queue one icon per carried unit. Returns the complete flight time so room navigation can
## wait for the final arrival beat without coupling game state to this presentation node.
func fly_bundle(world_pos: Vector3, bundle: Dictionary, units_before: int,
		field_before: Dictionary = {}) -> float:
	var item_order: Array = bundle.keys()
	item_order.sort()
	var units: Array[Dictionary] = []
	for item in item_order:
		var field_gain := maxi(0, World.field_count(str(item)) - int(field_before.get(item, 0)))
		for i in int(bundle[item]):
			units.append({ "item": str(item), "destination": "field" if i < field_gain else "pack" })
	if units.is_empty():
		return 0.0
	if _tokens.is_empty():
		_displayed_units = units_before
		_displayed_field = field_before.duplicate(true)
		_combo = 0
	var start := _world_to_ui(world_pos)
	var tray := _tray_rect()
	for i in units.size():
		var item := str(units[i]["item"])
		var destination := str(units[i]["destination"])
		var target := tray.position + Vector2(18, 42 if destination == "field" else 17)
		_tokens.append({
			"item": item,
			"destination": destination,
			"from": start + Vector2((i % 2) * 9 - 4, -float(i) * 3.0),
			"to": target,
			"age": -float(i) * TOKEN_STAGGER,
			"arrived": false,
			"final": i == units.size() - 1,
		})
	set_process(true)
	queue_redraw()
	return TOKEN_DURATION + float(units.size() - 1) * TOKEN_STAGGER + 0.12


func _process(delta: float) -> void:
	_pulse = maxf(_pulse - delta * 3.8, 0.0)
	var any_active := false
	for token in _tokens:
		token["age"] = float(token["age"]) + delta
		if float(token["age"]) < TOKEN_DURATION + 0.18:
			any_active = true
		if not bool(token["arrived"]) and float(token["age"]) >= TOKEN_DURATION:
			token["arrived"] = true
			_arrive(token)
	_tokens = _tokens.filter(func(token): return float(token["age"]) < TOKEN_DURATION + 0.18)
	queue_redraw()
	if not any_active and _tokens.is_empty() and _pulse <= 0.0:
		set_process(false)


func _arrive(token: Dictionary) -> void:
	if str(token["destination"]) == "field":
		var item := str(token["item"])
		_displayed_field[item] = int(_displayed_field.get(item, 0)) + 1
	else:
		_displayed_units = mini(World.backpack_capacity(), _displayed_units + 1)
	_combo += 1
	_pulse = 1.0
	if sfx != null:
		var pitch := minf(1.0 + float(_combo - 1) * 0.075, 1.45)
		sfx.play("loot_complete" if bool(token["final"]) else "loot_pickup",
			-4.0 if bool(token["final"]) else -8.0, 0.015, pitch, "UI")


func _world_to_ui(world_pos: Vector3) -> Vector2:
	if camera == null or view_container == null or source_viewport == null \
			or camera.is_position_behind(world_pos):
		return get_viewport_rect().size * Vector2(0.5, 0.58)
	var source := camera.unproject_position(world_pos)
	var source_size := Vector2(source_viewport.size)
	var rect := view_container.get_global_rect()
	if source_size.x <= 0.0 or source_size.y <= 0.0:
		return rect.get_center()
	return rect.position + source * rect.size / source_size


func _draw() -> void:
	var pulse_color := Color("#facc15").lerp(Color("#fdf6e3"), _pulse)
	var grow := _pulse * 3.0
	var base_tray := _tray_rect()
	var tray := base_tray.grow(grow)
	draw_rect(tray, Color(0.055, 0.035, 0.09, 0.92), true)
	draw_rect(tray, pulse_color, false, 2.0 + _pulse * 2.0)
	_draw_token(base_tray.position + Vector2(18, 17), "tool_kit", 0.9 + _pulse * 0.22)
	var text := "PACK  %d/%d" % [_displayed_units, World.backpack_capacity()]
	draw_string(ThemeDB.fallback_font, base_tray.position + Vector2(38, 23), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color("#fdf6e3"))
	_draw_token(base_tray.position + Vector2(18, 42), "bandages", 0.82 + _pulse * 0.18)
	var field_text := "FIELD  B %d/%d  F %d/%d" % [
		int(_displayed_field.get("bandages", 0)), int(World.FIELD_CAPACITY["bandages"]),
		int(_displayed_field.get("packaged_food", 0)), int(World.FIELD_CAPACITY["packaged_food"]),
	]
	draw_string(ThemeDB.fallback_font, base_tray.position + Vector2(38, 48), field_text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("#68d5ff"))
	for token in _tokens:
		var age := float(token["age"])
		if age < 0.0 or age >= TOKEN_DURATION + 0.18:
			continue
		var t := clampf(age / TOKEN_DURATION, 0.0, 1.0)
		var eased := 1.0 - pow(1.0 - t, 3.0)
		var p: Vector2 = (token["from"] as Vector2).lerp(token["to"], eased)
		p.y -= sin(t * PI) * 72.0
		var scale := 1.0 + sin(t * PI) * 0.34
		if t >= 1.0:
			scale *= maxf(0.0, 1.0 - (age - TOKEN_DURATION) / 0.18)
		_draw_token(p, str(token["item"]), scale)


func _tray_rect() -> Rect2:
	var y := 116.0
	if hud != null:
		y = maxf(y, hud.get_global_rect().end.y + 6.0)
	y = minf(y, get_viewport_rect().size.y - TRAY_SIZE.y - 12.0)
	return Rect2(Vector2(12, y), TRAY_SIZE)


func _draw_token(center: Vector2, item: String, scale: float) -> void:
	var color: Color = ITEM_COLORS.get(item, Color("#facc15"))
	var r := 8.0 * scale
	var points := PackedVector2Array([
		center + Vector2(0, -r), center + Vector2(r, 0),
		center + Vector2(0, r), center + Vector2(-r, 0),
	])
	draw_colored_polygon(points, color)
	draw_polyline(PackedVector2Array([points[0], points[1], points[2], points[3], points[0]]),
		Color("#17131f"), maxf(1.0, scale * 2.0))
	var label: String = PropLootRules.ITEM_LABELS.get(item, item).left(1).to_upper()
	draw_string(ThemeDB.fallback_font, center + Vector2(-3.5, 4.5) * scale, label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(9, roundi(10.0 * scale)), Color("#17131f"))
