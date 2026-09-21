extends Sprite3D
## Lightweight animated CRT snow. Only the screen pixels are rewritten; the PixelLab
## cabinet art remains untouched. Room visibility pauses this automatically.

var _base: Image
var _frame := 0.0
var _rng := RandomNumberGenerator.new()
const SCREEN := Rect2i(24, 22, 20, 18)
const SNOW := [Color("#fdf6e3"), Color("#9aa7b8"), Color("#6c6c72"), Color("#272338"), Color("#120a1f")]


func _ready() -> void:
	_rng.seed = hash(name)
	if texture != null:
		_base = texture.get_image()


func _process(dt: float) -> void:
	if not is_visible_in_tree() or _base == null:
		return
	_frame -= dt
	if _frame > 0.0:
		return
	_frame = 0.075
	var img := _base.duplicate()
	for y in range(SCREEN.position.y, SCREEN.end.y):
		for x in range(SCREEN.position.x, SCREEN.end.x):
			# Preserve the rounded cabinet mask and dark screen edge.
			if _base.get_pixel(x, y).a > 0.5 and _base.get_pixel(x, y).get_luminance() > 0.10:
				img.set_pixel(x, y, SNOW[_rng.randi_range(0, SNOW.size() - 1)])
	texture = ImageTexture.create_from_image(img)
