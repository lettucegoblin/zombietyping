class_name ZombieType
extends RefCounted
## Tuning per zombie kind. Frames live in assets/sprites/zombie/<frames_dir>/frames.json.

var name := "runner"
var frames_dir := "hoodie"
var speed := 2.0              ## m/s
var word_len := Vector2i(3, 5)
var stun := 0.34              ## seconds frozen per hit
var knockback := 0.18         ## metres per hit
var attack_range := 1.5
var attack_windup := 0.6
var attack_recover := 0.9
var damage := 12
var pixel_size := 0.022
var run_fps := 11.0
## per-frame duration multipliers for the run cycle (weight the foot plants)
var run_weights: Array[float] = [0.9, 1.6, 0.8, 0.9, 0.9, 1.6, 0.8, 0.9]
## flinch frame handling: "skip_first" (animated from a neutral pose: impact is frame 1)
## or "reverse" (animated from an action pose: impact is the last frame)
var flinch_mode := "skip_first"


static func runner() -> ZombieType:
	return ZombieType.new()


static func shambler() -> ZombieType:
	var t := ZombieType.new()
	t.name = "shambler"
	t.frames_dir = "hoodie"     # until the shambler sprite exists
	t.speed = 0.8
	t.word_len = Vector2i(5, 8)
	t.stun = 0.5
	t.knockback = 0.22
	t.attack_windup = 0.7
	t.damage = 16
	t.run_fps = 6.0
	return t
