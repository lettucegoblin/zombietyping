extends Node
## Screen-space word labels must separate deterministically without displacing the active
## target, and edge hints may slide only along their edge.

var _failed := false


func _ready() -> void:
	var overlay := WordOverlay.new()
	var shared := Rect2(220, 170, 150, 48)
	var items: Array[Dictionary] = [
		_item(shared, Vector2.ZERO, 900, 1),
		_item(shared, Vector2.ZERO, 300, 2),
		_item(shared, Vector2.ZERO, 100, 3),
	]
	overlay._resolve_nudges(items, Rect2(8, 8, 624, 344))
	var rects: Array[Rect2] = []
	for item in items:
		var rect: Rect2 = item["base_rect"]
		rect.position += item["offset"]
		for other in rects:
			_check(not rect.intersects(other, true), "free labels still overlap after nudging")
		rects.append(rect)
	var active: Dictionary = _with_id(items, 1)
	_check(active["offset"] == Vector2.ZERO, "active label lost its anchor to a lower-priority word")

	var edge_items: Array[Dictionary] = [
		_item(Rect2(500, 120, 120, 44), Vector2.RIGHT, 500, 10),
		_item(Rect2(500, 120, 120, 44), Vector2.RIGHT, 100, 11),
	]
	overlay._resolve_nudges(edge_items, Rect2(8, 8, 624, 344))
	var moved: Dictionary = _with_id(edge_items, 11)
	_check(is_zero_approx((moved["offset"] as Vector2).x) and not is_zero_approx((moved["offset"] as Vector2).y),
		"side-edge hint did not nudge strictly along the edge")

	# On an impossibly crowded screen, lower-priority words must be withheld instead of
	# falling back to an overlap. This is what makes the no-overlap guarantee absolute.
	var crowded: Array[Dictionary] = []
	for i in range(30):
		crowded.append(_item(Rect2(20, 20, 80, 40), Vector2.ZERO, 1000 - i, 100 + i))
	overlay._resolve_nudges(crowded, Rect2(8, 8, 112, 72))
	var visible_rects: Array[Rect2] = []
	for item in crowded:
		if not item.get("layout_visible", true):
			continue
		var rect: Rect2 = item["base_rect"]
		rect.position += item["offset"]
		for other in visible_rects:
			_check(not rect.intersects(other, true), "crowded fallback allowed a text overlap")
		visible_rects.append(rect)
	_check(not visible_rects.is_empty(), "crowded fallback hid every label")
	_check(_with_id(crowded, 100).get("layout_visible", false), "crowded fallback hid the highest-priority label")
	_check(visible_rects.size() < crowded.size(), "crowded fixture did not exercise label withholding")

	if not _failed:
		print("WORD OVERLAY LAYOUT OK  priority anchor + collision-free nudging + edge sliding + crowded fallback")
	get_tree().quit(1 if _failed else 0)


func _item(rect: Rect2, direction: Vector2, priority: int, stable_id: int) -> Dictionary:
	return {
		"base_rect": rect, "direction": direction, "priority": priority,
		"stable_id": stable_id, "offset": Vector2.ZERO,
	}


func _with_id(items: Array[Dictionary], stable_id: int) -> Dictionary:
	for item in items:
		if int(item["stable_id"]) == stable_id:
			return item
	return {}


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error("WORD OVERLAY LAYOUT FAIL: " + message)
