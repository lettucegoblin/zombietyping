extends SceneTree
func _init() -> void:
	var tex: Texture2D = load("res://assets/textures/atlas.png")
	var img := tex.get_image()
	print("loaded atlas ", img.get_size(), " fmt ", img.get_format())
	print("door cell (10,140): ", img.get_pixel(10, 140), "  window (70,140): ", img.get_pixel(70, 140), "  plain (10,10): ", img.get_pixel(10, 10))
	quit()
