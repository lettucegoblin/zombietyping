class_name Palette
## The game palette ("Sunday Comic"): every sprite is quantized onto these colours and the
## 3D world is post-processed onto them too. Source strip: res://assets/palette/palette.png

const COLORS: Array[Color] = [
	Color("#120a1f"),  # ink
	Color("#2d1b4e"),  # plum_dark
	Color("#5b2a86"),  # plum
	Color("#8e44ad"),  # violet
	Color("#c39bd3"),  # lilac
	Color("#fdf6e3"),  # cream
	Color("#0f766e"),  # teal_dark
	Color("#14b8a6"),  # teal
	Color("#99f6e4"),  # mint
	Color("#365314"),  # moss_dark
	Color("#84cc16"),  # lime
	Color("#d9f99d"),  # lime_pale
	Color("#7c2d12"),  # rust_dark
	Color("#ea580c"),  # orange
	Color("#fdba74"),  # peach
	Color("#334155"),  # slate
	Color("#94a3b8"),  # slate_light
	Color("#be123c"),  # crimson
	Color("#ff2d55"),  # hot_pink
	Color("#ff6fb5"),  # pink
	Color("#facc15"),  # yellow
]

const INK := Color("#120a1f")
const PLUM_DARK := Color("#2d1b4e")
const PLUM := Color("#5b2a86")
const VIOLET := Color("#8e44ad")
const LILAC := Color("#c39bd3")
const CREAM := Color("#fdf6e3")
const TEAL_DARK := Color("#0f766e")
const TEAL := Color("#14b8a6")
const MINT := Color("#99f6e4")
const MOSS_DARK := Color("#365314")
const LIME := Color("#84cc16")
const LIME_PALE := Color("#d9f99d")
const RUST_DARK := Color("#7c2d12")
const ORANGE := Color("#ea580c")
const PEACH := Color("#fdba74")
const SLATE := Color("#334155")
const SLATE_LIGHT := Color("#94a3b8")
const CRIMSON := Color("#be123c")
const HOT_PINK := Color("#ff2d55")
const PINK := Color("#ff6fb5")
const YELLOW := Color("#facc15")

const COUNT := 21


## Nearest palette colour (used when re-tinting vertex colours).
static func nearest(c: Color) -> Color:
	var best := COLORS[0]
	var bd := 1e9
	for p in COLORS:
		var d := (p.r - c.r) * (p.r - c.r) + (p.g - c.g) * (p.g - c.g) + (p.b - c.b) * (p.b - c.b)
		if d < bd:
			bd = d
			best = p
	return best
