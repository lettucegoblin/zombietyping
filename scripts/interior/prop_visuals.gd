extends RefCounted
## Shared sprite measurement for generation and rendering. PixelLab assets use equal-size
## transparent canvases, but the opaque furniture inside those canvases varies widely.

const SPRITES := {
	"rug": "res://assets/sprites/props/rug.png",
	"painting": "res://assets/sprites/props/painting.png",
	"fridge": "res://assets/sprites/props/fridge.png",
	"tv": "res://assets/sprites/props/tv.png",
	"bed": "res://assets/sprites/props/bed.png",
	"sofa": "res://assets/sprites/props/sofa.png",
	"dresser": "res://assets/sprites/props/dresser.png",
	"toilet": "res://assets/sprites/props/toilet.png",
	"sink": "res://assets/sprites/props/sink.png",
	"tub": "res://assets/sprites/props/tub.png",
	"counter": "res://assets/sprites/props/counter.png",
	"stove": "res://assets/sprites/props/stove.png",
	"shelf": "res://assets/sprites/props/shelf.png",
	"desk": "res://assets/sprites/props/desk.png",
	"workbench": "res://assets/sprites/props/desk.png",
	"chair": "res://assets/sprites/props/chair.png",
	"crate": "res://assets/sprites/props/crate.png",
}

const DESIGN_WIDTH_PX := 52.0
const DESIGN_HEIGHT_PX := 42.0
const ALPHA_THRESHOLD := 0.03

static var _metrics: Dictionary = {}


static func has_sprite(kind: String) -> bool:
	return SPRITES.has(kind)


static func is_billboard(kind: String) -> bool:
	return has_sprite(kind) and kind not in ["rug", "painting"]


## Matches InteriorMesher's display scale exactly. Keeping this here prevents placement
## from measuring one apparent object while the renderer draws another.
static func pixel_size(size: Vector3) -> float:
	return maxf(size.x / DESIGN_WIDTH_PX, size.y / DESIGN_HEIGHT_PX)


static func visible_size(kind: String, size: Vector3) -> Vector2:
	var metric := _metric(kind)
	return Vector2(metric.bounds.size) * pixel_size(size)


## Sprite3D centres the whole transparent canvas. Shift horizontally so the opaque pixels,
## rather than unused padding, are centred on the procedural prop position.
static func horizontal_offset(kind: String) -> float:
	var metric := _metric(kind)
	return float(metric.canvas.x) * 0.5 - (float(metric.bounds.position.x) + float(metric.bounds.size.x) * 0.5)


static func _metric(kind: String) -> Dictionary:
	if _metrics.has(kind):
		return _metrics[kind]
	var texture := load(str(SPRITES.get(kind, ""))) as Texture2D
	if texture == null:
		var fallback := {"canvas": Vector2i(1, 1), "bounds": Rect2i(0, 0, 1, 1)}
		_metrics[kind] = fallback
		return fallback
	var image := texture.get_image()
	var canvas := image.get_size()
	var min_x := canvas.x
	var min_y := canvas.y
	var max_x := -1
	var max_y := -1
	for y in canvas.y:
		for x in canvas.x:
			if image.get_pixel(x, y).a <= ALPHA_THRESHOLD:
				continue
			min_x = mini(min_x, x)
			min_y = mini(min_y, y)
			max_x = maxi(max_x, x)
			max_y = maxi(max_y, y)
	var bounds := Rect2i(0, 0, canvas.x, canvas.y) if max_x < 0 else Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)
	var metric := {"canvas": canvas, "bounds": bounds}
	_metrics[kind] = metric
	return metric
