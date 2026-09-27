extends Node
## Game root. Modes:
##   STREET  — riding the rail between typed map destinations
##   DOOR    — stopped at a queued building; the door shows a word. Type it to enter.
##             With more stops queued you get a short window, then the rail moves on.
##   INSIDE  — in a storey; doors/stairs/exit are typed words.

enum Mode { STREET, DOOR, INSIDE, SAFEZONE }

const DOOR_WORDS := ["breach", "kick", "shove", "pry", "force", "bash", "ram", "smash"]
const DOOR_WINDOW := 4.0
const PropLootRules = preload("res://scripts/loot/prop_loot.gd")

var mode := Mode.STREET
var door_building: BuildingData
var door_word := ""
var door_timer := -1.0
var _last_door := -1      # door index we came through (so the camera looks at the others)
var hp := 100
var kills := 0
var dead := false
var _spawned_rooms: Dictionary = {}   # "floor:room" -> true (zombies already placed this visit)
var _spark_tex: Texture2D
var _invuln := 0.0                    # seconds of immunity after taking a hit
var _resume_beat := 0.0               # countdown before the rail rolls again after a fight
var _climbing := false
var _door_label: WordLabel
var _search_pending := false          # room done: decide where the rail takes us next
var _search_beat := 0.0
var _searching := false               # a "search:" leg is running (walking back to a frontier)
var _moving_on := false               # you typed a door/stairs/exit: zombies in view no longer stop the rail
const ENGAGE_FAR := 40.0              # facing on arrival: anything in your sights at all
const APPROACH_RANGE := 10.0          # closer than this and a zombie's word is live; walk in until then
var _approach_beat := 0.0
var _gameplay_mouse_look := false
const HALT_RANGE := 14.0              # a zombie you can fire at (in sight, in range) stops the rail
const AIM_RANGE := 14.0               # ...and turns you to face it whenever you are not walking
var _rescue_cue: SurvivorCue
var _loot_collecting := false
var _loot_ticket := 0
var _safezone_exiting := false

@onready var player: Node3D = $View/Viewport/World/Player
@onready var settings: GameSettings = $Settings
@onready var streamer: Node3D = $View/Viewport/World/Streamer
@onready var interior: Node3D = $View/Viewport/World/Interior
@onready var director: Node3D = $View/Viewport/World/Director
@onready var world3d: Node3D = $View/Viewport/World
@onready var flash: ColorRect = $UI/Flash
@onready var game_over: Label = $UI/GameOver
@onready var typist: Node = $Typist
@onready var map: Control = $UI/TabMap
@onready var minimap: Control = $UI/Minimap
@onready var building_reticle: BuildingReticle = $UI/BuildingReticle
@onready var sfx: Node = $Sfx
@onready var ash: GPUParticles3D = $View/Viewport/World/Player/Ash
@onready var sky: Node3D = $View/Viewport/World/SkyLife
@onready var settlement: Settlement = $View/Viewport/World/Settlement
@onready var hud: RichTextLabel = $UI/HUD
@onready var words: WordOverlay = $UI/Words
@onready var pause_menu: PauseMenu = $UI/PauseMenu
@onready var loot_flyover: LootFlyover = $UI/LootFlyover


func _ready() -> void:
	pause_menu.configure(settings)
	pause_menu.resume_requested.connect(_on_pause_resumed)
	settings.changed.connect(_on_setting_changed)
	_apply_runtime_settings()
	var startup_base := _startup_base()
	if startup_base != null:
		_position_player_at_base_start(startup_base)
	World.state_changed.connect(_on_world_state_changed)
	streamer.target = player
	streamer.prime(World.sector_of_tile(player.tile))
	map.player = player
	map.health_provider = func(): return hp
	map.healing_requested.connect(_on_map_healing_requested)
	sfx.player = player
	loot_flyover.configure(player.cam, $View, $View/Viewport, sfx, hud)
	sky.player = player
	sky.sfx = sfx
	settlement.configure(player)
	_rescue_cue = SurvivorCue.new()
	_rescue_cue.name = "SurvivorCue"
	world3d.add_child(_rescue_cue)
	_rescue_cue.set_listener(player)
	_rescue_cue.resolve()
	minimap.player = player
	minimap.tab_map = map
	building_reticle.game = self
	building_reticle.player = player
	building_reticle.camera = player.cam
	building_reticle.minimap = minimap
	typist.dest_labels = func(): return minimap.labels
	typist.destination_typed.connect(_on_hud_destination)
	map.destinations_typed.connect(_on_destinations)
	map.clear_requested.connect(func(): player.clear_queue(); map.queue_redraw())
	map.closed.connect(_on_map_closed)
	player.queue_changed.connect(_on_queue_changed)
	player.arrived.connect(_on_arrived)
	player.tile_changed.connect(func(t): map.mark_fog_dirty_around(World.sector_of_tile(t)))
	player.manual_zone_exited.connect(_on_safezone_gate_exit)
	typist.changed.connect(_refresh_hud)
	typist.changed.connect(_on_typing)
	typist.mistyped.connect(func(_c): _refresh_hud())
	director.player = player
	director.interior = interior
	typist.director = director
	typist.shot.connect(_on_shot)
	typist.missed.connect(_on_missed)
	director.zombie_killed.connect(_on_zombie_killed)
	director.zombie_spawned.connect(func(z): z.hit_player.connect(_on_player_hit))
	_spark_tex = _make_spark()
	game_over.visible = false
	if startup_base != null:
		_enter_safezone(startup_base)
	_capture_mouse_look()
	_refresh_hud()


func _startup_base() -> BuildingData:
	var id := World.primary_base_id()
	return World.building_by_id(id) if id != "" else null


## Begin each session in the courtyard of the founding safehouse, looking back toward its
## entrance. This is inside the permanent perimeter but clear of the building and door arc.
func _position_player_at_base_start(b: BuildingData) -> void:
	var entrance := InteriorGen.entrance_position(b, InteriorGen.footprint(b))
	var outward := Vector2(b.road_tile - b.door_tile).normalized()
	if outward == Vector2.ZERO:
		outward = Vector2.RIGHT
	var point := Vector2(entrance.x, entrance.z) + outward * 2.6
	var bounds := World.ward_bounds_world(b.id()).grow(-0.6)
	if bounds.has_area():
		point.x = clampf(point.x, bounds.position.x, bounds.end.x)
		point.y = clampf(point.y, bounds.position.y, bounds.end.y)
	player.global_position = Vector3(point.x, 0.0, point.y)
	player.tile = World.world_to_tile(player.global_position)
	player.facing = (entrance - player.global_position).normalized()
	player.facing.y = 0.0
	World.mark_explored(player.tile, player.reveal_radius)


func _process(dt: float) -> void:
	if dead:
		return
	_invuln = maxf(_invuln - dt, 0.0)
	# the rail stops the moment a zombie is in your sights (close enough to matter) and
	# rolls again a beat after; once you have typed where to go next it keeps going
	var lock_close: bool = typist.locked != null and is_instance_valid(typist.locked) and typist.locked.is_alive() \
		and typist.locked.global_position.distance_to(player.global_position) < HALT_RANGE
	var threat: Zombie = director.threat_within(HALT_RANGE)
	if mode == Mode.SAFEZONE:
		threat = null
		lock_close = false
	if threat != null and _moving_on and threat.room < 0 and mode == Mode.INSIDE:
		threat = null   # a street zombie seen through a window does not stop you indoors
	if threat != null or (lock_close and not _moving_on):
		player.halt = true
		_resume_beat = 0.7
	elif player.halt:
		_resume_beat -= dt
		if _resume_beat <= 0.0:
			player.halt = false
	# a big room: the zombie you are staring at is beyond word range, so walk in on it
	# until its word goes live (the hold-on-sight rule stops you the moment it does)
	if mode == Mode.INSIDE and interior.is_inside() and not player.is_moving() and not typist.in_combat() \
			and interior.current_room >= 0 and not interior.is_room_cleared(interior.current_room):
		_approach_beat += dt
		if _approach_beat > 0.6:
			_approach_beat = 0.0
			var z: Zombie = director.nearest_in_room(interior.current_room)
			if z != null and z.global_position.distance_to(player.global_position) > APPROACH_RANGE:
				var to: Vector3 = z.global_position - player.global_position
				to.y = 0.0
				var goal: Vector3 = z.global_position - to.normalized() * (APPROACH_RANGE - 1.5)
				goal.y = player.global_position.y
				player.push_local(PackedVector3Array([goal]), "approach", 2.2)
	else:
		_approach_beat = 0.0
	if _search_pending and mode == Mode.INSIDE:
		_search_beat -= dt
		if _search_beat <= 0.0 and not typist.in_combat() and not player.is_moving():
			# A kill in the room ahead can queue this while the rail is still crossing its
			# threshold. Do not consume that pulse until the room we actually occupy is
			# marked clear, or the automatic return can be lost between arrival callbacks.
			if interior.current_room >= 0 and interior.is_room_cleared(interior.current_room):
				_search_pending = false
				_search_step()
			else:
				_search_beat = 0.15
	if mode == Mode.DOOR and door_timer > 0.0 and not typist.in_combat():
		door_timer -= dt
		if door_timer <= 0.0:
			_leave_door()
			player.resume()
		_refresh_hud()
	# auto-aim: standing still (or held by a threat) and not mid-word on a door, face the
	# zombie you are shooting, else the closest one you can fire at
	if (not player.is_moving() or player.halt) and typist.buffer == "":
		var z: Zombie = null
		if typist.locked != null and is_instance_valid(typist.locked) and typist.locked.is_alive():
			z = typist.locked
		else:
			z = director.threat_within(AIM_RANGE)
		if z == null:
			z = director.nearest_awake(2.6)
		if z == null and mode == Mode.INSIDE and interior.is_inside() and not player.is_moving():
			# the room has gone quiet but is not clear: sweep to whatever is still standing
			# in it (nothing sees you before you see it, so you have to look)
			z = director.nearest_in_room(interior.current_room)
		if z != null:
			player.face_toward(z.global_position)
	if not director.get_meta("no_street", false):
		director.street_spawning = mode != Mode.INSIDE and mode != Mode.SAFEZONE
	var room_kind := ""
	if mode == Mode.INSIDE and interior.is_inside() and interior.current_room >= 0:
		room_kind = interior.plan.rooms[interior.current_room].kind
	sfx.set_inside(mode == Mode.INSIDE, room_kind)
	sfx.footsteps(dt, player.current_speed())
	sfx.atmosphere(dt)
	ash.emitting = mode != Mode.INSIDE
	if mode == Mode.SAFEZONE and interior.is_inside():
		interior.update_safezone_doors(player.global_position, dt)
	if Engine.get_process_frames() % 10 == 0:
		_refresh_hud()


@onready var post_mat: ShaderMaterial = $View/Viewport/Post/PaletteQuantize.material


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _gameplay_mouse_look and not map.visible and not pause_menu.visible:
		building_reticle.note_mouse_motion(event.relative)
		player.mouse_look(event.relative)
		get_viewport().set_input_as_handled()
		return
	if dead and event is InputEventKey and event.pressed and event.keycode == KEY_R:
		Engine.time_scale = 1.0
		get_tree().paused = false
		get_tree().reload_current_scene()
		return
	if mode == Mode.SAFEZONE and event is InputEventKey and event.pressed and not event.echo:
		var msg := ""
		match event.keycode:
			KEY_B: msg = settlement.toggle_build()
			KEY_T: msg = settlement.talk_nearest(player.global_position) if not settlement.build_mode else ""
			KEY_Q: msg = settlement.cycle_build(-1) if settlement.build_mode else ""
			KEY_E: msg = settlement.cycle_build(1) if settlement.build_mode else ""
			KEY_R: msg = settlement.rotate_preview() if settlement.build_mode else ""
			KEY_F: msg = settlement.place_selected() if settlement.build_mode else ""
			KEY_LEFT: msg = settlement.nudge_preview(Vector2.LEFT) if settlement.build_mode else ""
			KEY_RIGHT: msg = settlement.nudge_preview(Vector2.RIGHT) if settlement.build_mode else ""
			KEY_UP: msg = settlement.nudge_preview(Vector2.UP) if settlement.build_mode else ""
			KEY_DOWN: msg = settlement.nudge_preview(Vector2.DOWN) if settlement.build_mode else ""
			KEY_C: msg = settlement.reset_preview() if settlement.build_mode else ""
			KEY_ESCAPE: msg = settlement.cancel_build() if settlement.build_mode else ""
			KEY_U: msg = settlement.undo_or_dismantle_last()
			KEY_X:
				if not settlement.build_mode:
					msg = interior.salvage_nearest(player.global_position)
					if msg.begins_with("dismantled"):
						sfx.play_at("creak", player.global_position, -7.0, 0.1, 0.9, 12.0)
			KEY_V:
				if not settlement.build_mode:
					msg = World.break_down_backpack()
			KEY_G:
				if not settlement.build_mode:
					msg = World.deposit_backpack(settlement.active_building_id)
			KEY_H:
				if not settlement.build_mode:
					msg = _use_carried_supply("bandages", 30, "bandaged wounds")
			KEY_J:
				if not settlement.build_mode:
					msg = _use_carried_supply("packaged_food", 8, "ate packaged food")
			KEY_PAGEUP: msg = _safezone_floor(1)
			KEY_PAGEDOWN: msg = _safezone_floor(-1)
		if msg != "":
			minimap.flash(msg)
			loot_flyover.sync_backpack()
			_refresh_hud()
			get_viewport().set_input_as_handled()
			return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		if not map.visible and not pause_menu.visible:
			_open_pause_menu()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F1:
		var on: float = post_mat.get_shader_parameter("enabled")
		post_mat.set_shader_parameter("enabled", 0.0 if on > 0.5 else 1.0)
	if OS.is_debug_build() and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F5:
		var f: Vector3 = player.facing
		director._spawn(ZombieType.runner(), player.global_position + f * 7.0 + Vector3(-f.z, 0, f.x) * 0.6)
	if OS.is_debug_build() and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F6:
		player.facing = -player.facing   # look behind (debug)
	if OS.is_debug_build() and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F8:
		print("RAIL moving=%s halt=%s hold=%s leg=%s local=%d pos=%s room=%d mode=%d moving_on=%s pending=%s searching=%s threats=%s" % [
			player.is_moving(), player.halt, player.hold, player._cur.get("id", "-"), player._local.size(), player.global_position,
			interior.current_room, mode, _moving_on, _search_pending, _searching, director.targetable_words()])
		for z in director.alive():
			if z.global_position.distance_to(player.global_position) < 16.0:
				print("  Z %s state=%d room=%d dist=%.2f los=%s fair=%s label_t=%.2f on_cam=%s" % [z.word, z.state, z.room, z.global_position.distance_to(player.global_position), z.in_los, z.fair(), z._label_time, z._on_camera()])
	if OS.is_debug_build() and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F7:
		# debug: dump the minimap labels with storey counts (for scripted playtests)
		var parts: Array[String] = []
		for l in minimap.labels.keys():
			var b := World.building_by_id(minimap.labels[l])
			parts.append("%s=%d(%s,%s)" % [l, b.floors if b else 0, minimap.labels[l], b.kind if b else "?"])
		print("LABELS ", " ".join(parts))
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F2:
		var d: float = post_mat.get_shader_parameter("dither_strength")
		post_mat.set_shader_parameter("dither_strength", 0.0 if d > 0.0 else 0.04)
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB:
		if not map.visible:
			_open_map()
			get_viewport().set_input_as_handled()


func _release_mouse_look() -> void:
	_gameplay_mouse_look = false
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _capture_mouse_look() -> void:
	if not dead and not map.visible and not pause_menu.visible:
		_gameplay_mouse_look = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _open_map() -> void:
	if pause_menu.visible:
		return
	_release_mouse_look()
	typist.enabled = false
	get_tree().paused = true
	map.open()


func _on_map_closed() -> void:
	get_tree().paused = false
	typist.enabled = mode != Mode.SAFEZONE
	_capture_mouse_look()


func _toggle_map() -> void:
	if map.visible:
		map.close()
	else:
		_open_map()


func _open_pause_menu() -> void:
	_release_mouse_look()
	typist.enabled = false
	get_tree().paused = true
	pause_menu.open()


func _on_pause_resumed() -> void:
	get_tree().paused = false
	typist.enabled = not dead and mode != Mode.SAFEZONE
	if not dead:
		_capture_mouse_look()


func _on_setting_changed(_key: String, _value: Variant) -> void:
	_apply_runtime_settings()


func _apply_runtime_settings() -> void:
	player.mouse_look_sensitivity = 0.0025 * settings.mouse_sensitivity
	player.invert_mouse_y = settings.invert_mouse_y
	player.shake_intensity = settings.screen_shake
	words.text_scale = settings.typing_text_scale


# ------------------------------------------------------------------ street

func _on_destinations(ids: Array[String]) -> void:
	if mode == Mode.SAFEZONE:
		_leave_safezone_for_travel()
	var ok := 0
	for id in ids:
		if player.enqueue(id):
			ok += 1
	map.flash("queued %d destination%s" % [ok, "" if ok == 1 else "s"] if ok > 0 else "no route")
	map.queue_redraw()
	_refresh_hud()


## A label typed on the HUD (no Tab): queue it. From inside a building on the ground
## floor the rail walks out first; upstairs the queue waits until you come down and exit.
func _on_hud_destination(id: String) -> void:
	var label := ""
	for l in minimap.labels.keys():
		if minimap.labels[l] == id:
			label = l
	if not player.enqueue(id):
		minimap.flash("no route to " + label)
		return
	minimap.flash("queued " + label)
	minimap.relabel()
	if mode == Mode.INSIDE and interior.is_inside() and interior.plan.floor == 0 and not player.is_moving() and not typist.in_combat():
		var er: int = interior.entrance_room()
		if interior.current_room == er or not interior.route(interior.current_room, er).is_empty():
			_on_option({ "kind": "exit", "door": interior.plan.entrance_door })
	_refresh_hud()


func _on_queue_changed() -> void:
	# new destinations while waiting at a door: abandon the prompt and roll
	if mode == Mode.DOOR and player.has_street_queue():
		_leave_door()
		player.resume()
	_refresh_hud()


func _on_arrived(id: String) -> void:
	_moving_on = false
	if id == "safezone_exit":
		_finish_safezone_exit()
		return
	if id.begins_with("room:"):
		var ri := int(id.substr(5))
		interior.set_room(ri)
		_populate_room(ri)
		_refresh_prompts()
		_face_arrival(ri)
		if interior.is_room_cleared(ri):
			_schedule_room_rewards(ri, 0.55)
		return
	if id == "approach":
		_refresh_prompts()
		_face_arrival(interior.current_room)
		return
	if id.begins_with("search:"):
		_searching = false
		var ri := int(id.substr(7))
		interior.set_room(ri)
		_populate_room(ri)
		_refresh_prompts()
		_face_arrival(ri)
		# A search target can become complete while we are walking to it (for example a
		# zero-zombie living room reached through several already-open service rooms).
		# Continue the automatic search instead of idling among irrelevant open-door words.
		if interior.is_room_cleared(ri):
			_schedule_room_rewards(ri, 0.55)
		return
	if id == "stairs":
		# standing on the landing of the new storey: look through the archways, shoot,
		# then type the archway of the room you want (or up/down again)
		_climbing = false
		interior.finish_floor_change()
		var ri: int = interior.plan.stair_room
		interior.set_room(ri)
		interior.mark_room_cleared(ri)
		_refresh_prompts()
		_face_arrival(ri)
		_queue_search(0.35)
		return
	if id == "exit":
		_cancel_room_rewards()
		_rescue_cue.resolve()
		director.clear_room_zombies()
		_spawned_rooms.clear()
		interior.unload()
		mode = Mode.STREET
		typist.clear_prompts()
		player.resume()
		_refresh_hud()
		return
	# arrived at a queued building's door
	var b := World.building_by_id(id)
	if b == null:
		player.resume()
		return
	var was_visited: bool = World.building_state(id).get("visited", false)
	World.set_building_state(id, "visited", true)
	if World.building_state(id).get("claimed", false):
		_enter_safezone(b)
		return
	mode = Mode.DOOR
	door_building = b
	door_word = DOOR_WORDS[b.seed_hash % DOOR_WORDS.size()]
	var fp0 := InteriorGen.generate(World.seed, b, 0)
	if fp0.entrance_door >= 0:
		var dpos: Vector3 = fp0.doors[fp0.entrance_door].pos
		player.face_toward(dpos)
		_show_door_label(door_word, dpos + Vector3(fp0.doors[fp0.entrance_door].dir.x, 0, fp0.doors[fp0.entrance_door].dir.y) * 0.4 + Vector3(0, 2.75, 0), was_visited)
	door_timer = DOOR_WINDOW if player.has_street_queue() else -1.0
	typist.set_prompts([{ "id": "door", "word": door_word, "callback": _enter_building }])
	_refresh_hud()


func _leave_door() -> void:
	mode = Mode.STREET
	door_building = null
	door_timer = -1.0
	typist.clear_prompts()
	_hide_door_label()


func _enter_safezone(b: BuildingData) -> void:
	_cancel_room_rewards()
	mode = Mode.SAFEZONE
	door_building = b
	_search_pending = false
	_searching = false
	_moving_on = false
	_climbing = false
	_safezone_exiting = false
	typist.clear_prompts()
	typist.enabled = false
	_rescue_cue.resolve()
	_hide_door_label()
	interior.enter(b, 0, true)
	interior.reveal_all()
	# A claim can complete while the survivor is on an upper floor. Free roam currently
	# represents the generated ground floor, so keep the existing X/Z position and land it.
	player.global_position.y = 0.0
	settlement.enter(b.id())
	director.clear_room_zombies()
	director.clear_street_zombies()
	loot_flyover.sync_backpack()
	minimap.flash("safe zone: WASD move · B build · Tab travel/manage")
	_refresh_hud()


## Settlement actions happen on the paused Tab map. If the player claims the site they
## are standing at, enter its safe-zone mode as part of that same action instead of making
## them leave and route back to it before the claim becomes usable.
func _on_world_state_changed(id: String) -> void:
	if mode == Mode.SAFEZONE or not World.building_state(id).get("claimed", false):
		return
	var here := false
	if mode == Mode.DOOR and door_building != null:
		here = door_building.id() == id
	elif mode == Mode.INSIDE and interior.is_inside() and interior.building != null:
		here = interior.building.id() == id
	if here:
		var b := World.building_by_id(id)
		if b != null:
			_enter_safezone(b)


func _leave_safezone_for_travel() -> void:
	_safezone_exiting = false
	_rescue_cue.resolve()
	var b := World.building_by_id(settlement.active_building_id)
	interior.unload()
	settlement.leave()
	mode = Mode.STREET
	typist.enabled = true
	if b != null:
		player.snap_to_road(b.road_tile)


func _on_safezone_gate_exit() -> void:
	if mode != Mode.SAFEZONE or _safezone_exiting:
		return
	var b := World.building_by_id(settlement.active_building_id)
	if b == null:
		_leave_safezone_for_travel()
		return
	_safezone_exiting = true
	var gate := World.ward_gate_world(b.id())
	var outward := Vector2(b.road_tile - b.door_tile).normalized()
	if outward == Vector2.ZERO:
		outward = Vector2.RIGHT
	var outside_tile := _outside_road_tile(b, gate, outward)
	var road := World.tile_to_world(outside_tile)
	var through := Vector3(gate.x + outward.x * 1.35, 0.0, gate.y + outward.y * 1.35)
	player.guide_toward(through)
	player.push_local(PackedVector3Array([
		player.global_position,
		Vector3(gate.x, 0.0, gate.y),
		through,
		road,
	]), "safezone_exit", 3.4)
	minimap.flash("leaving the safe zone — walking out to the road")
	_refresh_hud()


func _outside_road_tile(b: BuildingData, gate: Vector2, outward: Vector2) -> Vector2i:
	var probe := Vector3(gate.x + outward.x * (World.TILE_M * 0.75), 0.0,
		gate.y + outward.y * (World.TILE_M * 0.75))
	var center := World.world_to_tile(probe)
	var best := b.road_tile
	var best_score := INF
	for radius in range(0, 13):
		for y in range(center.y - radius, center.y + radius + 1):
			for x in range(center.x - radius, center.x + radius + 1):
				if radius > 0 and x > center.x - radius and x < center.x + radius \
						and y > center.y - radius and y < center.y + radius:
					continue
				var tile := Vector2i(x, y)
				var world := World.tile_to_world(tile)
				if World.road_at(tile) <= 0 or World.ward_contains_point(b.id(), Vector2(world.x, world.z)):
					continue
				var delta := Vector2(world.x - gate.x, world.z - gate.y)
				var score := delta.length_squared() - maxf(0.0, delta.dot(outward)) * 2.0
				if score < best_score:
					best_score = score
					best = tile
		if best_score < INF:
			break
	return best


func _finish_safezone_exit() -> void:
	var b := World.building_by_id(settlement.active_building_id)
	var final_tile := World.world_to_tile(player.global_position)
	_rescue_cue.resolve()
	interior.unload()
	settlement.leave()
	mode = Mode.STREET
	typist.enabled = true
	_safezone_exiting = false
	player.snap_to_road(final_tile if World.road_at(final_tile) > 0 else (b.road_tile if b != null else final_tile))
	minimap.flash("on the road — typed travel restored")
	_refresh_hud()


func _safezone_floor(delta: int) -> String:
	if mode != Mode.SAFEZONE or not interior.is_inside() or door_building == null:
		return "enter a claimed building first"
	var next_floor: int = interior.plan.floor + delta
	if next_floor < 0 or next_floor >= door_building.floors:
		return "no storey in that direction"
	interior.enter(door_building, next_floor, true)
	interior.reveal_all()
	if interior.plan.stair_room >= 0:
		player.global_position = interior.plan.room_stand_world(interior.plan.stair_room) + Vector3(0, 0.05, 0)
	else:
		player.global_position.y = next_floor * World.FLOOR_M + 0.05
	if settlement.build_mode:
		settlement.reset_preview()
	return "safe-zone floor %d/%d" % [next_floor + 1, door_building.floors]


func _use_carried_supply(item: String, healing: int, success_text: String) -> String:
	if hp >= 100:
		return "health is already full"
	if not World.consume_backpack_item(item):
		return "no " + item.replace("_", " ") + " in the backpack"
	hp = mini(100, hp + healing)
	sfx.play("hit", -14.0, 0.04, 1.35)
	return "%s — health %d" % [success_text, hp]


func _on_map_healing_requested(source: String, base_id: String) -> void:
	var result := ""
	if source == "carried":
		result = _use_carried_supply("bandages", 30, "bandaged wounds")
	elif source == "base":
		if hp >= 100:
			result = "health is already full"
		elif mode != Mode.SAFEZONE or settlement.active_building_id != base_id:
			result = "safehouse treatment requires being inside this base"
		elif not World.consume_base_medicine(base_id):
			result = "this safehouse has no bandages or medicine"
		else:
			hp = mini(100, hp + 60)
			sfx.play("hit", -14.0, 0.04, 1.35)
			result = "treated at the safehouse — health %d" % hp
	map.flash(result)
	loot_flyover.sync_backpack()
	_refresh_hud()


func _show_door_label(word: String, pos: Vector3, visited := false) -> void:
	_hide_door_label()
	_door_label = WordLabel.new(word, 34)
	_door_label.position = pos
	_door_label.edge_hint = true
	_door_label.retired = visited
	world3d.add_child(_door_label)


func _hide_door_label() -> void:
	if _door_label != null and is_instance_valid(_door_label):
		_door_label.queue_free()
	_door_label = null


# ------------------------------------------------------------------ inside

func _enter_building() -> void:
	_cancel_room_rewards()
	var b := door_building
	var rescue := World.ensure_rescue_candidate(b.id())
	_moving_on = true
	mode = Mode.INSIDE
	door_timer = -1.0
	typist.clear_prompts()
	interior.enter(b, 0)
	_sync_rescue_cue()
	var fp: FloorPlan = interior.plan
	var d: FloorPlan.Door = fp.doors[fp.entrance_door]
	var ri: int = d.a
	_last_door = fp.entrance_door
	interior._reveal(ri)
	_hide_door_label()
	SectorMesher.kick_facade_door(b.id())
	interior.add_child(InteriorMesher.kicked_leaf(d))
	sfx.play_at("door", d.pos, 0.0, 0.08, 1.0, 24.0)
	player.shake(0.25)
	player.lock_look_toward(d.pos)
	_seed_floor()
	_startle_near(d.pos, ri)
	if not rescue.is_empty():
		minimap.flash("rescue lead: %s · %s · floor %d %s" % [rescue["name"], rescue["trait"], int(rescue["floor"]) + 1, rescue["room_kind"]])
	_refresh_hud()
	# a beat to watch the door tumble in (and see what is standing behind it), then walk
	await get_tree().create_timer(0.55).timeout
	player.unlock_look()
	if mode != Mode.INSIDE or interior.building != b:
		return
	player.push_local(PackedVector3Array([d.pos, interior.threshold_world(fp.entrance_door, ri)]), "room:%d" % ri, 2.6)


## Every uncleared room of the current storey gets its zombies now (dormant, standing in
## place) so you can see them through doorways and shoot before you step in.
func _seed_floor() -> void:
	director.clear_room_zombies()
	_spawned_rooms.clear()
	var fp: FloorPlan = interior.plan
	for ri in fp.rooms.size():
		if interior.is_room_cleared(ri):
			continue
		_spawned_rooms["%d:%d" % [fp.floor, ri]] = true
		director.spawn_in_room(interior.building, fp, ri)


## On arrival: the nearest zombie in this room (awake or not) if it is close, else the
## most useful thing in the room. In the stairwell: the archway of the room to clear next.
func _face_arrival(ri: int) -> void:
	# whatever you can fire at first; else any zombie standing in this room, however far
	var z: Zombie = null
	if typist.locked != null and is_instance_valid(typist.locked) and typist.locked.is_alive():
		z = typist.locked
	else:
		z = director.threat_within(ENGAGE_FAR)
	if z == null:
		var bd := 1e9
		for c in director.alive():
			var d: float = c.global_position.distance_to(player.global_position)
			if c.room != ri and d > 3.0:
				continue
			if d < bd:
				bd = d
				z = c
	if z != null:
		player.face_toward(z.global_position)
		return
	if ri == interior.plan.stair_room:
		var target: int = interior.stair_exit_room()
		var fp: FloorPlan = interior.plan
		for di in fp.rooms[ri].doors:
			var d: FloorPlan.Door = fp.doors[di]
			if d.b >= 0 and fp.other_room(di, ri) == target:
				player.guide_toward(interior.option_look_pos({ "kind": "door", "door": di }, player.global_position))
				return
	_face_room()


## Look at the generator/state-aware next action. The same option receives the gold route
## chevron; cleared branches remain visibly crossed out but can still be revisited.
func _face_room() -> void:
	var opt: Dictionary = interior.recommended_option()
	if opt.is_empty():
		return
	var p: Vector3 = interior.option_look_pos(opt, player.global_position)
	if p != Vector3.INF:
		player.guide_toward(p)


## The room is done. If it still has a closed door worth opening we wait here for you to
## type it; otherwise the rail walks you back to the nearest room that does (or to the
## stairwell / the exit) and waits there. No retyping your way back out.
func _queue_search(beat: float) -> void:
	_search_pending = true
	_search_beat = beat


func _cancel_room_rewards() -> void:
	_loot_ticket += 1
	_loot_collecting = false


## A cleared room gets a short victory beat while its still-bouncing supplies remain in
## the world, then each carried unit flies into the HUD. Door prompts are held until the
## last icon and sound land so the reward cannot be skipped by immediately typing onward.
func _schedule_room_rewards(ri: int, beat := 0.85) -> void:
	if mode != Mode.INSIDE or not interior.is_inside() or ri != interior.current_room \
			or not interior.is_room_cleared(ri):
		return
	if _loot_collecting:
		return
	var props: Array = interior.lootable_props_in_room(ri, true)
	if props.is_empty():
		if interior.has_uncollected_loot(ri):
			minimap.flash("room clear — backpack full, supplies left in place")
		_refresh_prompts()
		_face_room()
		if not interior.rescue_waiting_here():
			_queue_search(0.35)
		return
	_loot_ticket += 1
	var ticket := _loot_ticket
	_loot_collecting = true
	_search_pending = false
	_searching = false
	typist.clear_prompts()
	var first: FloorPlan.Prop = props[0]
	player.guide_toward(first.pos + Vector3(0, maxf(first.size.y, 0.7), 0))
	minimap.flash("room clear — supplies incoming")
	_collect_room_rewards(ri, ticket, beat)
	_refresh_hud()


func _collect_room_rewards(ri: int, ticket: int, beat: float) -> void:
	await get_tree().create_timer(beat, false).timeout
	while ticket == _loot_ticket and mode == Mode.INSIDE and interior.is_inside() \
			and interior.current_room == ri:
		var props: Array = interior.lootable_props_in_room(ri, true)
		if props.is_empty():
			break
		var prop: FloorPlan.Prop = props[0]
		var bundle: Dictionary = PropLootRules.contents(interior.building.id(), prop)
		var units_before := World.backpack_units()
		var origin := prop.pos + Vector3(0, maxf(prop.size.y * 0.72, 0.62), 0)
		var result: String = interior.loot_prop(prop)
		if not result.begins_with("searched"):
			break
		var flight := loot_flyover.fly_bundle(origin, bundle, units_before)
		minimap.flash("collected " + PropLootRules.item_text(bundle))
		_refresh_hud()
		if flight > 0.0:
			await get_tree().create_timer(flight, false).timeout
	if ticket != _loot_ticket:
		return
	_loot_collecting = false
	_refresh_prompts()
	_face_room()
	if interior.has_uncollected_loot(ri):
		minimap.flash("backpack full — remaining supplies stay here")
	if not interior.rescue_waiting_here():
		_queue_search(0.35)
	_refresh_hud()


func _search_step() -> void:
	if mode != Mode.INSIDE or not interior.is_inside() or player.is_moving() or _loot_collecting:
		return
	var here: int = interior.current_room
	if here < 0 or not interior.is_room_cleared(here):
		return
	if interior.rescue_waiting_here():
		return
	var target: int = interior.search_target(here)
	if OS.is_debug_build():
		print("search: room %d -> %d (unexplored here: %s, options %s)" % [here, target, interior.unexplored_doors(here), interior.options().map(func(o): return o["word"])])
	if target == here or target < 0:
		return
	var pts: PackedVector3Array = interior.path_to_room(target)
	if pts.is_empty():
		return
	_last_door = -1
	_searching = true
	typist.clear_prompts()
	player.push_local(pts, "search:%d" % target, 3.0)
	_refresh_hud()


func _refresh_prompts() -> void:
	if _loot_collecting:
		typist.clear_prompts()
		_refresh_hud()
		return
	var list := []
	for o in interior.options():
		var opt: Dictionary = o
		list.append({ "id": opt["kind"], "word": opt["word"], "callback": _on_option.bind(opt) })
	typist.set_prompts(list)
	_refresh_hud()


func _on_option(opt: Dictionary) -> void:
	typist.clear_prompts()
	_moving_on = true
	match opt["kind"]:
		"door":
			var di: int = opt["door"]
			_last_door = di
			interior.open_door(di)
			sfx.play_at("door", interior.plan.doors[di].pos, -2.0, 0.1, 1.0, 24.0)
			player.shake(0.18)
			var other: int = interior.plan.other_room(di, interior.current_room)
			_startle_near(interior.plan.doors[di].pos, other)
			player.push_local(interior.path_through_door(di), "room:%d" % other, 2.6)
		"exit":
			_searching = false
			player.push_local(interior.path_to_street(), "exit", 2.6)
		"up", "down":
			# through the archway, up/down the flights, out into a room on the next storey
			_last_door = -1
			director.clear_room_zombies()
			_spawned_rooms.clear()
			var up: bool = opt["kind"] == "up"
			# from a room: the stairwell door has to come down first
			var sd: int = opt["door"]
			if sd >= 0 and not interior.is_door_open(interior.plan.doors[sd]):
				interior.open_door(sd)
				sfx.play_at("door", interior.plan.doors[sd].pos, -2.0, 0.1, 1.0, 24.0)
				player.shake(0.18)
			var pts: PackedVector3Array = interior.climb_path(up)
			interior.begin_floor_change(1 if up else -1)
			_sync_rescue_cue()
			_seed_floor()
			pts.append(interior.landing(up))
			sfx.play_at("creak", player.global_position, -8.0, 0.15, 1.0, 16.0)
			_climbing = true
			player.push_local(pts, "stairs", 2.2)
		"rescue":
			_moving_on = false
			var result := World.complete_rescue(interior.building.id())
			_rescue_cue.resolve()
			interior.clear_rescue_visual()
			minimap.flash(result)
			interior._update_labels()
			_refresh_prompts()
			_face_room()
			if interior.is_room_cleared(interior.current_room):
				_queue_search(0.7)
		"loot":
			_moving_on = false
			var result: String = interior.loot_here(player.global_position)
			minimap.flash(result)
			sfx.play_at("clank", player.global_position, -15.0, 0.12, 1.1, 10.0)
			interior._update_labels()
			_refresh_prompts()
			_face_room()
			if not interior.has_loot_here(player.global_position):
				_queue_search(0.7)
	_refresh_hud()


## Keep the audible survivor at the same seed-derived room position on every storey.
## The cue itself owns cadence, range filtering and stereo panning; mission state stays
## authoritative in World so save/load and typed completion cannot diverge from sound.
func _sync_rescue_cue() -> void:
	if mode != Mode.INSIDE or not interior.is_inside():
		_rescue_cue.resolve()
		return
	var mission: Dictionary = interior.active_rescue()
	var target: Vector3 = interior.rescue_world_pos()
	if mission.is_empty() or target == Vector3.INF:
		_rescue_cue.resolve()
		return
	if _rescue_cue.target_id != str(mission["id"]):
		_rescue_cue.configure(str(mission["id"]), target, player, true)
	else:
		_rescue_cue.set_target_position(target)
		_rescue_cue.set_unresolved(true)


## Zombies standing right behind a door we just kicked jump back in surprise.
func _startle_near(door_pos: Vector3, ri: int) -> void:
	for z in director.alive():
		if z.room == ri and z.global_position.distance_to(door_pos) < 3.6:
			z.startle(door_pos)


func _populate_room(ri: int) -> void:
	if interior.is_room_cleared(ri):
		return
	# zombies were seeded on entry, dormant: nothing sees you before you see it. The
	# director wakes the ones in your sight; gunfire wakes the rest within earshot.
	# A room with none left counts as cleared on arrival.
	if director.alive_in_room(ri) == 0:
		interior.mark_room_cleared(ri)


var _last_typed_len := 0


func _on_typing() -> void:
	minimap.typing = typist.dest_buffer
	var n: int = typist.buffer.length() + typist.dest_buffer.length()
	if n > _last_typed_len:
		sfx.play("key", -10.0, 0.1)
	_last_typed_len = n
	if _door_label != null and is_instance_valid(_door_label):
		_door_label.match_buffer(typist.buffer)
	if interior.is_inside():
		interior.show_typing(typist.buffer)
		# start typing an option and the survivor turns to face it
		if typist.buffer != "" and not player.is_moving():
			for o in interior.options():
				var opt: Dictionary = o
				if (opt["word"] as String).begins_with(typist.buffer):
					var p: Vector3 = interior.option_look_pos(opt, player.global_position)
					if p != Vector3.INF:
						player.guide_toward(p)
					break


# ------------------------------------------------------------------ combat feedback

func _on_shot(z: Zombie, killed: bool) -> void:
	director.wake_by_noise(interior, interior.room_at_world(player.global_position) if interior.is_inside() else -1, 12.0, 1)
	sfx.play("shot", -3.0, 0.1)
	sfx.play_at("kill" if killed else "hit", z.global_position, 0.0 if killed else -6.0, 0.12)
	if mode != Mode.INSIDE:
		sky.startle(player.global_position, 30.0)
	player.shake(0.32 if killed else 0.11)
	_flash(Color(1, 1, 1, 0.16 if killed else 0.07), 0.07)
	_spark(z.global_position + Vector3(0, 1.05, 0), 1.6 if killed else 1.0)
	if killed:
		z.burst_letters(world3d)
		_slowmo(0.22, 0.10)
	_refresh_hud()


func _on_missed() -> void:
	sfx.play("miss", -6.0, 0.1)
	player.shake(0.05)
	_flash(Color(1, 0.2, 0.3, 0.08), 0.06)


func _on_zombie_killed(z: Zombie) -> void:
	kills += 1
	World.add_materials({ "zombie_matter": 1 })
	if z.room >= 0 and interior.is_inside() and director.alive_in_room(z.room) == 0:
		interior.mark_room_cleared(z.room)
		if z.room == interior.current_room:
			_schedule_room_rewards(z.room, 0.85)
		else:
			_refresh_prompts()
	_refresh_hud()


func _on_player_hit(z: Zombie, damage: int) -> void:
	if dead or _invuln > 0.0:
		return
	_invuln = 0.8
	hp = maxi(hp - damage, 0)
	sfx.play("hit", 2.0, 0.05, 0.65)
	player.shake(0.45)
	_flash(Color(0.9, 0.05, 0.15, 0.35), 0.18)
	if typist.locked != null and is_instance_valid(typist.locked):
		typist.locked.set_locked(false)
	typist.locked = null
	if hp <= 0:
		_die()
	_refresh_hud()


func _die() -> void:
	dead = true
	typist.enabled = false
	_release_mouse_look()
	game_over.visible = true
	Engine.time_scale = 0.35


func _flash(col: Color, dur: float) -> void:
	col.a *= settings.screen_flash
	flash.color = col
	var tw := create_tween()
	tw.tween_property(flash, "color:a", 0.0, dur)


func _slowmo(scale: float, real_seconds: float) -> void:
	Engine.time_scale = scale
	await get_tree().create_timer(real_seconds, true, false, true).timeout
	if not dead:
		Engine.time_scale = 1.0


func _make_spark() -> Texture2D:
	var img := Image.create_empty(9, 9, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var pts := [[4,0],[4,8],[0,4],[8,4],[2,2],[6,6],[2,6],[6,2],[3,4],[5,4],[4,3],[4,5],[4,4],[3,3],[5,5],[3,5],[5,3]]
	for p in pts:
		img.set_pixel(p[0], p[1], Color("#ff2d55") if (p[0] + p[1]) % 2 == 0 else Color("#fdf6e3"))
	return ImageTexture.create_from_image(img)


func _spark(pos: Vector3, size: float) -> void:
	var sp := Sprite3D.new()
	sp.texture = _spark_tex
	sp.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sp.pixel_size = 0.032 * size
	sp.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	sp.shaded = false
	sp.no_depth_test = true
	sp.position = pos
	world3d.add_child(sp)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(sp, "pixel_size", 0.07 * size, 0.14)
	tw.tween_property(sp, "modulate:a", 0.0, 0.14)
	tw.chain().tween_callback(sp.queue_free)


# ------------------------------------------------------------------ hud

func _refresh_hud() -> void:
	var lines: Array[String] = []
	var q: Array[String] = player.queued_ids()
	match mode:
		Mode.STREET:
			if q.is_empty():
				lines.append("[color=#9aa]Idle — Tab: map, type a destination · move mouse: look[/color]")
			else:
				lines.append("Heading to [b]%s[/b]   (%d queued)" % [q[0], q.size()])
		Mode.DOOR:
			var t := "" if door_timer < 0.0 else "   [color=#ff8866]%.1fs[/color]" % door_timer
			lines.append("At the door of [b]%s[/b]%s" % [door_building.id() if door_building else "?", t])
		Mode.INSIDE:
			var p: Vector2i = interior.progress() if interior.is_inside() else Vector2i.ZERO
			var fl: int = interior.plan.floor + 1 if interior.is_inside() else 0
			lines.append("Inside [b]%s[/b]  floor %d/%d   rooms cleared %d/%d%s" % [interior.building.id() if interior.building else "?", fl, interior.building.floors if interior.building else 0, p.x, p.y, "   [color=#9aa]nothing left here — moving on[/color]" if _searching else ""])
			var rescue: Dictionary = interior.active_rescue() if interior.is_inside() else {}
			if not rescue.is_empty():
				var location: String = "HERE — type %s" % rescue.get("word", "help") if interior.rescue_waiting_here() and interior.is_room_cleared(interior.current_room) else "floor %d · %s" % [int(rescue["floor"]) + 1, rescue["room_kind"]]
				lines.append("[color=#f6c177]RESCUE %s [b]%s[/b] · %s · %s[/color]" % [World.survivor_archetype_label(rescue).to_upper(), rescue["name"], rescue["trait"], location])
			var loot_text: String = interior.loot_hint(player.global_position) if interior.is_inside() else ""
			if loot_text != "":
				lines.append("[color=#ffb86c]%s[/color]" % loot_text)
			lines.append("[color=#a6e3a1]%s[/color]" % World.backpack_summary())
		Mode.SAFEZONE:
			_append_safezone_hud(lines)
	var parts: Array[String] = []
	for p in typist.prompts():
		var w: String = p["word"]
		var typed: String = typist.buffer if w.begins_with(typist.buffer) else ""
		parts.append("[color=#ffd166][b]%s[/b][/color]%s" % [typed, w.substr(typed.length())])
	if typist.in_combat():
		var n: int = director.targetable().size()
		parts.append("[color=#ff6fb5]%d zombie%s in sight[/color]" % [n, "" if n == 1 else "s"])
		if OS.is_debug_build():
			parts.append("[color=#94a3b8]" + " ".join(director.targetable_words()) + "[/color]")
	if not parts.is_empty():
		lines.append("[font_size=24]" + "   ".join(parts) + "[/font_size]")
	var bar := ""
	for i in 10:
		bar += "█" if hp > i * 10 else "░"
	lines.append("[color=#ff2d55]HP %s[/color]  %d   [color=#facc15]kills %d[/color]" % [bar, hp, kills])
	hud.text = "\n".join(lines)
	loot_flyover.queue_redraw()


func _append_safezone_hud(lines: Array[String]) -> void:
	if _safezone_exiting:
		lines.append("[color=#68d5ff][b]LEAVING SAFE ZONE[/b][/color]  crossing the gate → road")
		lines.append("[color=#9aa]typed travel resumes when you reach the road[/color]")
		return
	var floor_text := "floor %d/%d · PgUp/PgDn floors" % [interior.plan.floor + 1, door_building.floors] if interior.is_inside() and door_building != null else ""
	lines.append("[color=#68d5ff][b]SAFE ZONE[/b][/color]  WASD move  ·  mouse look  ·  T talk  ·  %s  ·  Tab manage/travel" % floor_text)
	if settlement.build_mode:
		var preview_state := "[color=#7ee787]VALID[/color]" if settlement.ghost_is_valid() \
				else "[color=#ff6f91]%s[/color]" % settlement.ghost_error()
		var cost := World.cost_text(World.build_cost(settlement.selected_kind()))
		lines.append("[color=#ffd166][b]BUILD %s %d°[/b][/color]  cost %s  ·  %s" % [
			settlement.selected_kind(), settlement.preview_rotation * 90, cost, preview_state])
		lines.append("arrows nudge · C recenter · Q/E item · R rotate · F place · Esc cancel")
	else:
		lines.append("B build · G store supplies · V break down loot · H bandage · J eat")
	var undo_left := settlement.undo_seconds_remaining()
	if undo_left > 0.0:
		lines.append("[color=#ffd166]U undo %.1fs · full refund[/color]" % undo_left)
	if not settlement.build_mode:
		var salvage_text: String = interior.salvage_hint(player.global_position)
		if salvage_text != "":
			lines.append("[color=#ffb86c]%s[/color]" % salvage_text)
		var dismantle_text := settlement.dismantle_hint()
		if dismantle_text != "":
			lines.append("[color=#ffb86c]%s[/color]" % dismantle_text)
	lines.append("[color=#a6e3a1]%s[/color]" % World.material_summary())
	lines.append("[color=#a6e3a1]%s[/color]" % World.backpack_summary())
	var stored_items: Dictionary = World.building_state(settlement.active_building_id).get("stored_items", {})
	if not stored_items.is_empty():
		lines.append("[color=#68d5ff]base stores · %s[/color]" % World.item_summary(stored_items))
