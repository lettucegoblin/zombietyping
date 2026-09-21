class_name WordLabel
extends Node3D
## A typeable word anchored to a point in the 3D world. Pure data: the UI-layer WordOverlay
## draws every visible one at screen resolution (so distant words stay readable).

var word := ""
var typed := 0
var font_px := 28
var locked := false
var scale_with_distance := true
## Option words (doors, stairs, exit): when off-screen they are pinned to the screen edge
## with an arrow pointing the way, so every choice in a room is always readable.
var edge_hint := false
## Zombie words: when the anchor is in front of the camera but off the screen (a zombie
## right against you), the word is clamped onto the screen instead of dropped.
var keep_on_screen := false
## Interior navigation state. Retired words remain visible but crossed out and cannot be
## typed; recommended words get the route chevron and are where the camera points.
var retired := false
var recommended := false
var option_kind := ""
var option_door := -1


func _init(w := "", size := 28) -> void:
	word = w
	font_px = size


func _ready() -> void:
	add_to_group("words")


func set_progress(n: int) -> void:
	typed = clampi(n, 0, word.length())


func match_buffer(buffer: String) -> void:
	set_progress(buffer.length() if (not retired and buffer != "" and word.begins_with(buffer)) else 0)


func set_locked(v: bool) -> void:
	locked = v
