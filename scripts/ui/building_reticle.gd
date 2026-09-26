class_name BuildingReticle
extends Control
## A quiet first-person aiming reference outdoors. The centre ray only names an actually
## visible building collider, so occlusion and the streamed world naturally define what can
## be inspected. Its address is registered with the minimap and is immediately typeable.

var game: Node
var player: Node3D
var camera: Camera3D
var minimap: Control
var target_id := ""
var target_label := ""

var _font: Font


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font


func _physics_process(_dt: float) -> void:
	var outdoors: bool = game != null and int(game.mode) in [0, 1]
	visible = outdoors and camera != null and player != null
	if not visible or not is_inside_tree():
		_set_target("", "")
		return
	var vp_size := camera.get_viewport().get_visible_rect().size
	var screen_center := vp_size * 0.5
	var origin := camera.project_ray_origin(screen_center)
	var direction := camera.project_ray_normal(screen_center)
	var max_distance := MapLabels.WORLD_LABEL_RANGE_TILES * World.TILE_M
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * max_distance, 1)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	# The camera starts inside the survivor's CharacterBody capsule. Without this exclusion
	# the centre ray resolves the player at distance zero and never reaches the facade.
	if player is CollisionObject3D:
		query.exclude = [(player as CollisionObject3D).get_rid()]
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		_set_target("", "")
		return
	var collider: Object = hit.get("collider")
	if collider == null or not collider.has_meta("bid"):
		_set_target("", "")
		return
	var id := str(collider.get_meta("bid"))
	var b := World.building_by_id(id)
	if b == null:
		_set_target("", "")
		return
	var label: String = minimap.ensure_building_label(b) if minimap != null else MapLabels.ensure_label(b)
	_set_target(id, label)


func _set_target(id: String, label: String) -> void:
	if target_id == id and target_label == label:
		return
	target_id = id
	target_label = label
	queue_redraw()


func _draw() -> void:
	var centre := size * 0.5
	draw_circle(centre, 3.0, Color(0.03, 0.02, 0.06, 0.38))
	draw_circle(centre, 1.7, Color(0.99, 0.96, 0.89, 0.58))
	if target_label == "":
		return
	var fs := 18
	var text_size := _font.get_string_size(target_label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var box := Rect2(centre + Vector2(10.0, -text_size.y - 7.0), text_size + Vector2(10.0, 7.0))
	draw_rect(box, Color(0.04, 0.02, 0.08, 0.72))
	draw_rect(box, Color(0.99, 0.82, 0.40, 0.72), false, 1.0)
	var baseline := box.position + Vector2(5.0, text_size.y)
	draw_string(_font, baseline, target_label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color("#ffd166"))
	if World.building_state(target_id).get("visited", false):
		draw_line(Vector2(box.position.x + 4.0, centre.y - 6.0),
			Vector2(box.end.x - 4.0, centre.y - 6.0), Color("#ffd166"), 1.5)
