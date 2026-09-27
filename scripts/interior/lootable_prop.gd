extends Node3D
## Lightweight collectible presentation: the object rises toward alternating sides while
## a few warm motes drift around it. Amplitudes derive from the prop's proportions so a
## broad dresser shifts more and leans less than a tall, narrow refrigerator.

var _rest_position := Vector3.ZERO
var _side_axis := Vector3.RIGHT
var _phase := 0.0
var _side_amplitude := 0.02
var _lift_amplitude := 0.045
var _lean_amplitude := deg_to_rad(1.0)


func configure(prop_id: String, size: Vector3, yaw: float) -> void:
	_rest_position = position
	_side_axis = Basis(Vector3.UP, yaw) * Vector3.RIGHT
	var horizontal := maxf(size.x, size.z)
	var tallness := clampf(size.y / maxf(horizontal, 0.2), 0.25, 2.5)
	var breadth := clampf(horizontal / maxf(size.y, 0.2), 0.4, 3.0)
	_side_amplitude = lerpf(0.012, 0.035, inverse_lerp(0.4, 3.0, breadth))
	_lift_amplitude = lerpf(0.032, 0.058, clampf(horizontal / 1.5, 0.0, 1.0))
	_lean_amplitude = deg_to_rad(lerpf(2.1, 0.7, inverse_lerp(0.4, 3.0, breadth))) * clampf(tallness, 0.7, 1.5)
	_phase = float(absi(prop_id.hash()) % 10000) / 10000.0 * TAU
	set_meta("lootable_animation", true)
	_add_motes(size)


func _process(_delta: float) -> void:
	var t := Time.get_ticks_msec() * 0.0017 + _phase
	var side := sin(t)
	# At either side of the sway the prop is at the top of its tiny hop: up-left, settle,
	# up-right, settle. The power curve keeps the motion alive without looking bouncy.
	var lift := pow(absf(side), 1.55) * _lift_amplitude
	position = _rest_position + _side_axis * (side * _side_amplitude) + Vector3.UP * lift
	rotation.z = -side * _lean_amplitude


func _add_motes(size: Vector3) -> void:
	var particles := GPUParticles3D.new()
	particles.name = "LootMotes"
	particles.amount = 6
	particles.lifetime = 1.7
	particles.randomness = 0.62
	particles.fixed_fps = 12
	particles.local_coords = true
	particles.position.y = maxf(size.y * 0.48, 0.24)
	particles.visibility_aabb = AABB(Vector3(-1.2, -0.4, -1.2), Vector3(2.4, 2.4, 2.4))
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(maxf(size.x, 0.35) * 0.48, maxf(size.y, 0.4) * 0.42, maxf(size.z, 0.3) * 0.48)
	process.direction = Vector3.UP
	process.spread = 48.0
	process.initial_velocity_min = 0.035
	process.initial_velocity_max = 0.12
	process.gravity = Vector3(0, 0.035, 0)
	process.scale_min = 0.65
	process.scale_max = 1.15
	process.color = Color("#facc15")
	particles.process_material = process
	var quad := QuadMesh.new()
	quad.size = Vector2(0.045, 0.045)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.vertex_color_use_as_albedo = true
	material.albedo_color = Color("#fdf6e3")
	material.emission_enabled = true
	material.emission = Color("#facc15")
	material.emission_energy_multiplier = 1.35
	quad.material = material
	particles.draw_pass_1 = quad
	add_child(particles)
