extends Node
## The typing input. Holds the set of active prompts (word -> callback), matches what the
## player types against them by prefix, fires the callback on a full match. Doors, stairs,
## exits and (later) zombies all go through here. Owns key handling via keycodes so it
## works with any keyboard layout's letter keys and with injected test input.

signal changed          # buffer or prompts changed (HUD redraw)
signal mistyped(ch: String)
signal shot(zombie: Zombie, killed: bool)
signal missed
signal destination_typed(building_id: String)

var enabled := true
var buffer := ""
var director: Node3D            # zombie director; when it has targets, letters are bullets
var locked: Zombie = null
var _prompts: Dictionary = {}   # word -> {id, callback}
## Map labels start with a digit ("3b"), so a digit opens a destination buffer that only
## the minimap's labels can complete. Words and bullets never start with a digit.
var dest_buffer := ""
var dest_labels: Callable        # -> Dictionary label -> building id (set by main)


func set_prompts(list: Array) -> void:
	## list of {id, word, callback}
	_prompts.clear()
	for p in list:
		_prompts[p["word"]] = p
	buffer = ""
	changed.emit()


func clear_prompts() -> void:
	_prompts.clear()
	buffer = ""
	changed.emit()


func prompts() -> Array:
	return _prompts.values()


func has_prompt(word: String) -> bool:
	return _prompts.has(word)


func _lock_alive() -> bool:
	if locked == null or not is_instance_valid(locked) or not locked.is_alive():
		return false
	return locked.in_los or (Time.get_ticks_msec() / 1000.0 - locked.last_seen) < 0.8


func in_combat() -> bool:
	if director == null:
		return false
	return director.has_targets() or _lock_alive()


func _combat_key(ch: String) -> void:
	# drop the lock only if the target died or has been out of sight for a while
	if locked != null:
		var gone := not is_instance_valid(locked) or not locked.is_alive()
		var unseen := is_instance_valid(locked) and not locked.in_los and (Time.get_ticks_msec() / 1000.0 - locked.last_seen) > 0.8
		if gone or unseen:
			if is_instance_valid(locked):
				locked.set_locked(false)
			locked = null
	if locked == null:
		var z: Zombie = director.nearest_matching(ch)
		if z == null:
			missed.emit()
			return
		locked = z
		z.set_locked(true)
	elif locked.next_letter() != ch and locked.typed == 0:
		# nothing typed on the current lock yet: allow switching to another target
		var z2: Zombie = director.nearest_matching(ch)
		if z2 != null:
			locked.set_locked(false)
			locked = z2
			z2.set_locked(true)
	if locked.next_letter() != ch:
		missed.emit()
		return
	var killed: bool = locked.hit()
	shot.emit(locked, killed)
	if killed:
		locked = null
	changed.emit()


func _dest_key(ch: String) -> void:
	var next := dest_buffer + ch
	var labels: Dictionary = dest_labels.call() if dest_labels.is_valid() else {}
	if labels.has(next):
		dest_buffer = ""
		changed.emit()
		destination_typed.emit(labels[next])
		return
	var any := false
	for l in labels.keys():
		if (l as String).begins_with(next):
			any = true
			break
	if not any:
		dest_buffer = ""
		mistyped.emit(ch)
		changed.emit()
		return
	dest_buffer = next
	changed.emit()


func _prompt_prefix(text: String) -> bool:
	for w in _prompts.keys():
		if (w as String).begins_with(text):
			return true
	return false


func _prompt_key(ch: String) -> void:
	buffer += ch
	if _prompts.has(buffer):
		var p: Dictionary = _prompts[buffer]
		buffer = ""
		changed.emit()
		var cb: Callable = p["callback"]
		cb.call()
		return
	changed.emit()


## Where a letter goes. Zombies never take the keyboard away from you: a letter is a
## bullet only when it matches a target, otherwise it types the door/stairs/exit words.
##   1. it continues the word you are already typing
##   2. it is the next letter of the zombie you are locked on
##   3. it is the next letter of some zombie in your sights (zombies first: their first
##      letters are unique, and a door word can always be started with its own)
##   4. it starts one of the prompt words
##   5. otherwise: a miss (in a fight) or a mistype
func _letter(ch: String) -> void:
	if buffer != "" and _prompt_prefix(buffer + ch):
		_prompt_key(ch)
		return
	if _lock_alive() and locked.next_letter() == ch:
		_combat_key(ch)
		return
	if director != null and director.nearest_matching(ch) != null:
		if buffer != "":
			buffer = ""       # abandon the half-typed word for the shot
		_combat_key(ch)
		return
	if buffer == "" and _prompt_prefix(ch):
		_prompt_key(ch)
		return
	if in_combat():
		missed.emit()
	if buffer != "":
		buffer = ""
		mistyped.emit(ch)
	elif not in_combat():
		mistyped.emit(ch)
	changed.emit()


func _input(event: InputEvent) -> void:
	if not enabled:
		return
	if not (event is InputEventKey and event.pressed):
		return
	var k: int = event.keycode
	var digit := ""
	if k >= KEY_0 and k <= KEY_9:
		digit = char(48 + (k - KEY_0))
	elif k >= KEY_KP_0 and k <= KEY_KP_9:
		digit = char(48 + (k - KEY_KP_0))
	if dest_buffer != "" or digit != "":
		if event.echo:
			return
		get_viewport().set_input_as_handled()
		if digit != "":
			_dest_key(digit)
		elif k >= KEY_A and k <= KEY_Z:
			_dest_key(char(97 + (k - KEY_A)))
		elif k == KEY_BACKSPACE:
			dest_buffer = dest_buffer.left(maxi(dest_buffer.length() - 1, 0))
			changed.emit()
		elif k == KEY_ESCAPE:
			dest_buffer = ""
			changed.emit()
		return
	if k >= KEY_A and k <= KEY_Z:
		if event.echo:
			return
		get_viewport().set_input_as_handled()
		_letter(char(97 + (k - KEY_A)))
	elif k == KEY_BACKSPACE:
		if buffer != "":
			buffer = buffer.left(buffer.length() - 1)
			changed.emit()
			get_viewport().set_input_as_handled()
	elif k == KEY_ESCAPE:
		if buffer != "":
			buffer = ""
			changed.emit()
