extends Node
## Game root. Modes:
##   STREET  — riding the rail between typed map destinations
##   DOOR    — stopped at a queued building; the door shows a word. Type it to enter.
##             With more stops queued you get a short window, then the rail moves on.
##   INSIDE  — in a storey; doors/stairs/exit are typed words.

enum Mode { STREET, DOOR, INSIDE, SAFEZONE }

const DOOR_WORDS := ["breach", "kick", "shove", "pry", "force", "bash", "ram", "smash"]
const DOOR_WINDOW := 4.0

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
const HALT_RANGE := 14.0              # a zombie you can fire at (in sight, in range) stops the rail
const AIM_RANGE := 14.0               # ...and turns you to face it whenever you are not walking
var _rescue_cue: SurvivorCue

@onready var player: Node3D = $View/Viewport/World/Player
@onready var streamer: Node3D = $View/Viewport/World/Streamer
@onready var interior: Node3D = $View/Viewport/World/Interior
@onready var director: Node3D = $View/Viewport/World/Director
@onready var world3d: Node3D = $View/Viewport/World
@onready var flash: ColorRect = $UI/Flash
@onready var game_over: Label = $UI/GameOver
@onready var typist: Node = $Typist
@onready var map: Control = $UI/TabMap
@onready var minimap: Control = $UI/Minimap
@onready var sfx: Node = $Sfx
@onready var ash: GPUParticles3D = $View/Viewport/World/Player/Ash
@onready var sky: Node3D = $View/Viewport/World/SkyLife
@onready var settlement: Settlement = $View/Viewport/World/Settlement
@onready var hud: RichTextLabel = $UI/HUD


func _ready() -> void:
	World.state_changed.connect(_on_world_state_changed)
	streamer.target = player
	streamer.prime(World.sector_of_tile(player.tile))
	map.player = player
	sfx.player = player
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
	typist.dest_labels = func(): return minimap.labels
	typist.destination_typed.connect(_on_hud_destination)
	map.destinations_typed.connect(_on_destinations)
	map.clear_requested.connect(func(): player.clear_queue(); map.queue_redraw())
	map.closed.connect(func(): get_tree().paused = false; typist.enabled = mode != Mode.SAFEZONE)
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
	_refresh_hud()


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
	if Engine.get_process_frames() % 10 == 0:
		_refresh_hud()


@onready var post_mat: ShaderMaterial = $View/Viewport/Post/PaletteQuantize.material


func _unhandled_input(event: InputEvent) -> void:
	if dead and event is InputEventKey and event.pressed and event.keycode == KEY_R:
		Engine.time_scale = 1.0
		get_tree().paused = false
		get_tree().reload_current_scene()
		return
	if mode == Mode.SAFEZONE and event is InputEventKey and event.pressed and not event.echo:
		var msg := ""
		match event.keycode:
			KEY_B: msg = settlement.toggle_build()
			KEY_Q: msg = settlement.cycle_build(-1) if settlement.build_mode else ""
			KEY_E: msg = settlement.cycle_build(1) if settlement.build_mode else ""
			KEY_R: msg = settlement.rotate_preview() if settlement.build_mode else ""
			KEY_F: msg = settlement.place_selected() if settlement.build_mode else ""
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
			KEY_PAGEUP: msg = _safezone_floor(1)
			KEY_PAGEDOWN: msg = _safezone_floor(-1)
		if msg != "":
			minimap.flash(msg)
			_refresh_hud()
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
			typist.enabled = false
			get_tree().paused = true
			map.open()
		get_viewport().set_input_as_handled()


func _toggle_map() -> void:
	if map.visible:
		map.close()
	else:
		typist.enabled = false
		get_tree().paused = true
		map.open()


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
	if id.begins_with("room:"):
		var ri := int(id.substr(5))
		interior.set_room(ri)
		_populate_room(ri)
		_refresh_prompts()
		_face_arrival(ri)
		if interior.is_room_cleared(ri) and not interior.rescue_waiting_here():
			_queue_search(0.35)
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
		if interior.is_room_cleared(ri) and interior.unexplored_doors(ri).is_empty() and not interior.rescue_waiting_here():
			_queue_search(0.35)
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
	mode = Mode.SAFEZONE
	door_building = b
	_search_pending = false
	_searching = false
	_moving_on = false
	_climbing = false
	typist.clear_prompts()
	typist.enabled = false
	_rescue_cue.resolve()
	_hide_door_label()
	interior.enter(b, 0)
	interior.reveal_all()
	# A claim can complete while the survivor is on an upper floor. Free roam currently
	# represents the generated ground floor, so keep the existing X/Z position and land it.
	player.global_position.y = 0.0
	settlement.enter(b.id())
	director.clear_room_zombies()
	director.clear_street_zombies()
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
	_rescue_cue.resolve()
	var b := World.building_by_id(settlement.active_building_id)
	interior.unload()
	settlement.leave()
	mode = Mode.STREET
	typist.enabled = true
	if b != null:
		player.snap_to_road(b.road_tile)


func _on_safezone_gate_exit() -> void:
	if mode != Mode.SAFEZONE:
		return
	_rescue_cue.resolve()
	var b := World.building_by_id(settlement.active_building_id)
	interior.unload()
	settlement.leave()
	mode = Mode.STREET
	typist.enabled = true
	if b != null:
		player.snap_to_road(b.road_tile)
	minimap.flash("left the safe zone — typed travel restored")
	_refresh_hud()


func _safezone_floor(delta: int) -> String:
	if mode != Mode.SAFEZONE or not interior.is_inside() or door_building == null:
		return "enter a claimed building first"
	var next_floor: int = interior.plan.floor + delta
	if next_floor < 0 or next_floor >= door_building.floors:
		return "no storey in that direction"
	interior.enter(door_building, next_floor)
	interior.reveal_all()
	if interior.plan.stair_room >= 0:
		player.global_position = interior.plan.room_stand_world(interior.plan.stair_room) + Vector3(0, 0.05, 0)
	else:
		player.global_position.y = next_floor * World.FLOOR_M + 0.05
	return "safe-zone floor %d/%d" % [next_floor + 1, door_building.floors]


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
	player.face_toward(d.pos)
	_seed_floor()
	_startle_near(d.pos, ri)
	if not rescue.is_empty():
		minimap.flash("rescue lead: %s · %s · floor %d %s" % [rescue["name"], rescue["trait"], int(rescue["floor"]) + 1, rescue["room_kind"]])
	_refresh_hud()
	# a beat to watch the door tumble in (and see what is standing behind it), then walk
	await get_tree().create_timer(0.55).timeout
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
				player.face_toward(d.pos)
				return
	_face_room()


## Look at the generator/state-aware next action. The same option receives the gold route
## chevron; cleared branches remain visibly crossed out but can still be revisited.
func _face_room() -> void:
	var opt: Dictionary = interior.recommended_option()
	if opt.is_empty():
		return
	var p: Vector3 = interior.option_pos(opt)
	if p != Vector3.INF:
		player.face_toward(p)


## The room is done. If it still has a closed door worth opening we wait here for you to
## type it; otherwise the rail walks you back to the nearest room that does (or to the
## stairwell / the exit) and waits there. No retyping your way back out.
func _queue_search(beat: float) -> void:
	_search_pending = true
	_search_beat = beat


func _search_step() -> void:
	if mode != Mode.INSIDE or not interior.is_inside() or player.is_moving():
		return
	var here: int = interior.current_room
	if here < 0 or not interior.is_room_cleared(here):
		return
	if interior.rescue_waiting_here():
		return
	if interior.has_loot_here(player.global_position):
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
					var p: Vector3 = interior.option_pos(opt)
					if p != Vector3.INF:
						player.face_toward(p)
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
	if z.room >= 0 and interior.is_inside() and director.alive_in_room(z.room) == 0:
		interior.mark_room_cleared(z.room)
		_refresh_prompts()
	if interior.is_inside() and not interior.rescue_waiting_here():
		_queue_search(1.0)   # runs only once the room we stand in is clear and the fight is over
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
	game_over.visible = true
	Engine.time_scale = 0.35


func _flash(col: Color, dur: float) -> void:
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
				lines.append("[color=#9aa]Idle — Tab: map, type a destination[/color]")
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
				lines.append("[color=#f6c177]RESCUE [b]%s[/b] · %s · %s[/color]" % [rescue["name"], rescue["trait"], location])
			var loot_text: String = interior.loot_hint(player.global_position) if interior.is_inside() else ""
			if loot_text != "":
				lines.append("[color=#ffb86c]%s[/color]" % loot_text)
			lines.append("[color=#a6e3a1]%s[/color]" % World.backpack_summary())
		Mode.SAFEZONE:
			var build := "B: build mode  ·  V: sort backpack  ·  U: dismantle last (50%, rounded up)"
			if settlement.build_mode:
				var preview_state := "[color=#7ee787]VALID[/color]" if settlement.ghost_is_valid() \
						else "[color=#ff6f91]%s[/color]" % settlement.ghost_error()
				build = "[color=#ffd166]BUILD %s %d°[/color]  %s  ·  Q/E item · R rotate · F confirm · Esc cancel" % [
					settlement.selected_kind(), settlement.preview_rotation * 90, preview_state]
			var undo_left := settlement.undo_seconds_remaining()
			if undo_left > 0.0:
				build += "  ·  U undo %.1fs (full refund)" % undo_left
			var floor_text := "floor %d/%d  ·  PgUp/PgDn floors" % [interior.plan.floor + 1, door_building.floors] if interior.is_inside() and door_building != null else ""
			lines.append("[color=#68d5ff][b]SAFE ZONE[/b][/color]  WASD move  ·  %s  ·  %s  ·  Tab manage/travel" % [build, floor_text])
			if not settlement.build_mode:
				var salvage_text: String = interior.salvage_hint(player.global_position)
				if salvage_text != "":
					lines.append("[color=#ffb86c]%s[/color]" % salvage_text)
			lines.append("[color=#a6e3a1]%s[/color]" % World.material_summary())
			lines.append("[color=#a6e3a1]%s[/color]" % World.backpack_summary())
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
