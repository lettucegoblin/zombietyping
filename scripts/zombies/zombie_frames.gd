class_name ZombieFrames
## Builds SpriteFrames from a frames.json manifest (see tools/import_character.py).
## Animation names are "<anim>_<direction>", e.g. "run_south-west". Cached per type.

const DIRS := ["south", "south-west", "west", "north-west", "north", "north-east", "east", "south-east"]
static var _cache: Dictionary = {}


static func load_for(t: ZombieType) -> SpriteFrames:
	if _cache.has(t.frames_dir):
		return _cache[t.frames_dir]
	var base := "res://assets/sprites/zombie/%s/" % t.frames_dir
	var sf := SpriteFrames.new()
	var manifest: Dictionary = {}
	if FileAccess.file_exists(base + "frames.json"):
		manifest = JSON.parse_string(FileAccess.get_file_as_string(base + "frames.json"))
	var anims: Dictionary = manifest.get("anims", {})
	for anim in anims.keys():
		var dirs: Dictionary = anims[anim]
		for d in DIRS:
			var frames: Array = dirs.get(d, [])
			if frames.is_empty():
				continue
			var key := "%s_%s" % [anim, d]
			sf.add_animation(key)
			sf.set_animation_loop(key, anim == "run" or anim.begins_with("idle") or anim == "walk")
			var fps := 10.0
			if anim == "run": fps = t.run_fps
			elif anim.begins_with("flinch"): fps = 14.0
			elif anim == "attack": fps = 9.0
			elif anim == "death": fps = 11.0
			elif anim == "idle_breathe": fps = 6.0
			sf.set_animation_speed(key, fps)
			var order: Array = range(frames.size())
			if anim.begins_with("flinch"):
				if t.flinch_mode == "reverse":
					order.reverse()      # build-up -> impact: play backwards so the hit lands on frame 0
				elif frames.size() > 2:
					order.pop_front()    # neutral -> impact -> recover: drop the neutral lead-in
			for i in order:
				var tex: Texture2D = load(base + frames[i])
				var dur := 1.0
				if anim == "run" and i < t.run_weights.size():
					dur = t.run_weights[i]
				sf.add_frame(key, tex, dur)
	if sf.get_animation_names().is_empty():
		# no art yet: a 1-frame magenta box so the game still runs
		var img := Image.create_empty(32, 64, false, Image.FORMAT_RGBA8)
		img.fill(Color.MAGENTA)
		for d in DIRS:
			sf.add_animation("idle_" + d)
			sf.add_frame("idle_" + d, ImageTexture.create_from_image(img))
	_cache[t.frames_dir] = sf
	return sf


static func has_anim(sf: SpriteFrames, anim: String) -> bool:
	return sf.has_animation(anim + "_south")
