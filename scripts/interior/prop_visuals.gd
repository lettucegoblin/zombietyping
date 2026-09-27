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
	# These compact storage pieces deliberately reuse the dresser sheet at a smaller
	# procedural size. Falling back to the mesh builder made them read as mystery cubes.
	"nightstand": "res://assets/sprites/props/dresser.png",
	"cabinet": "res://assets/sprites/props/dresser.png",
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
const CANVAS_SIZE := Vector2i(67, 67)
## Opaque extents measured from the source PNG alpha once at authoring time. Scanning
## texture pixels the first time each kind spawned caused avoidable room-entry stalls.
const OPAQUE_BOUNDS := {
	"bed": Rect2i(3, 41, 61, 26),
	"cabinet": Rect2i(13, 8, 44, 46),
	"chair": Rect2i(22, 15, 29, 49),
	"counter": Rect2i(5, 20, 61, 33),
	"crate": Rect2i(14, 16, 52, 49),
	"desk": Rect2i(2, 25, 62, 34),
	"dresser": Rect2i(13, 8, 44, 46),
	"fridge": Rect2i(20, 0, 33, 52),
	"nightstand": Rect2i(13, 8, 44, 46),
	"painting": Rect2i(6, 6, 51, 41),
	"rug": Rect2i(0, 12, 57, 29),
	"shelf": Rect2i(7, 14, 38, 53),
	"sink": Rect2i(12, 10, 31, 52),
	"sofa": Rect2i(2, 12, 59, 39),
	"stove": Rect2i(22, 11, 36, 48),
	"toilet": Rect2i(20, 8, 35, 52),
	"tub": Rect2i(0, 26, 60, 32),
	"tv": Rect2i(18, 1, 44, 47),
}


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


## World-space height for the centre of a billboard whose opaque bottom sits exactly on
## the floor. This avoids treating transparent padding as part of the furniture's legs.
static func grounded_center_y(kind: String, size: Vector3) -> float:
	var metric := _metric(kind)
	return (float(metric.bounds.end.y) - float(metric.canvas.y) * 0.5) * pixel_size(size)


static func _metric(kind: String) -> Dictionary:
	var bounds: Rect2i = OPAQUE_BOUNDS.get(kind, Rect2i(Vector2i.ZERO, CANVAS_SIZE))
	return {"canvas": CANVAS_SIZE, "bounds": bounds}
