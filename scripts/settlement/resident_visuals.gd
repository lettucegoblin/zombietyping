extends RefCounted
## Shared resident art sizing. Each source has different transparent padding, so one
## pixel_size made adults look child-sized and left their feet hovering above the ground.

const TEXTURES := {
	"adult": preload("res://assets/sprites/survivor/citizen.png"),
	"grandma": preload("res://assets/sprites/survivor/grandma.png"),
	"grandpa": preload("res://assets/sprites/survivor/grandpa.png"),
	"cat": preload("res://assets/sprites/survivor/cat.png"),
	"dog": preload("res://assets/sprites/survivor/dog.png"),
}

# Human opaque silhouettes normalize to about 1.8 m. Pets remain naturally shorter.
const PIXEL_SIZE := {
	"adult": 0.0205,
	"grandma": 0.0186,
	"grandpa": 0.0190,
	"cat": 0.0120,
	"dog": 0.0130,
}

# Centre height adjusted for each PNG's bottom transparent padding, keeping feet grounded.
const REST_Y := {
	"adult": 0.9635,
	"grandma": 0.9858,
	"grandpa": 0.9690,
	"cat": 0.3840,
	"dog": 0.4420,
}


static func texture(archetype: String) -> Texture2D:
	return TEXTURES.get(archetype, TEXTURES["adult"])


static func pixel_size(archetype: String) -> float:
	return float(PIXEL_SIZE.get(archetype, PIXEL_SIZE["adult"]))


static func rest_y(archetype: String) -> float:
	return float(REST_Y.get(archetype, REST_Y["adult"]))
