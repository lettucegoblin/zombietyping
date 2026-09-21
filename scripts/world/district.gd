class_name District
## Per-district generation parameters. A sector has exactly one district.

enum Kind { DOWNTOWN, RESIDENTIAL, SUBURB, STRIP, INDUSTRIAL, PARK }

const LETTER := { Kind.DOWNTOWN: "a", Kind.RESIDENTIAL: "b", Kind.SUBURB: "c",
	Kind.STRIP: "e", Kind.INDUSTRIAL: "d", Kind.PARK: "f" }

const NAME := { Kind.DOWNTOWN: "Downtown", Kind.RESIDENTIAL: "Residential", Kind.SUBURB: "Suburb",
	Kind.STRIP: "Commercial strip", Kind.INDUSTRIAL: "Industrial", Kind.PARK: "Park" }

const COLOR := {
	Kind.DOWNTOWN: Color("#b9a4e0"), Kind.RESIDENTIAL: Color("#b6dcb8"), Kind.SUBURB: Color("#c3e6d3"),
	Kind.STRIP: Color("#efc4c4"), Kind.INDUSTRIAL: Color("#e3cfa8"), Kind.PARK: Color("#93c97a"),
}

## spacing: inverse density of secondary tensor streamlines (0 = no local roads)
## drop: retained for save/parameter compatibility; organic traces no longer prune a grid
## lots: candidate lot sizes (w,h) in tiles
## vacancy: chance a lot stays empty
## floors: [min, max]
## culdesac: keep-probability for dead-end stubs
const PARAMS := {
	Kind.DOWNTOWN:    { "spacing": 4,  "drop": 0.05, "lots": [Vector2i(4, 4), Vector2i(3, 4), Vector2i(4, 3), Vector2i(3, 3), Vector2i(2, 3)], "vacancy": 0.06, "floors": [3, 10], "culdesac": 0.0 },
	Kind.RESIDENTIAL: { "spacing": 7,  "drop": 0.30, "lots": [Vector2i(4, 4), Vector2i(3, 4), Vector2i(4, 3), Vector2i(3, 3), Vector2i(2, 3)], "vacancy": 0.15, "floors": [1, 4],  "culdesac": 0.5 },
	Kind.SUBURB:      { "spacing": 8,  "drop": 0.40, "lots": [Vector2i(4, 3), Vector2i(3, 4), Vector2i(3, 3), Vector2i(3, 2)],                  "vacancy": 0.25, "floors": [1, 2],  "culdesac": 0.7 },
	Kind.STRIP:       { "spacing": 6,  "drop": 0.20, "lots": [Vector2i(4, 3), Vector2i(3, 3), Vector2i(3, 2), Vector2i(2, 3)],                  "vacancy": 0.20, "floors": [1, 3],  "culdesac": 0.0 },
	Kind.INDUSTRIAL:  { "spacing": 10, "drop": 0.30, "lots": [Vector2i(5, 5), Vector2i(6, 4), Vector2i(4, 6), Vector2i(4, 4)], "vacancy": 0.30, "floors": [1, 2],  "culdesac": 0.0 },
	Kind.PARK:        { "spacing": 0,  "drop": 0.0,  "lots": [],                                                               "vacancy": 1.0,  "floors": [1, 1],  "culdesac": 0.0 },
}


static func params(kind: int) -> Dictionary:
	return PARAMS[kind]
