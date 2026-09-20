extends GPUParticles3D
## Drifting ash / dust around the survivor: a slow box of specks that follows the camera.
## Reads as "the city is burning somewhere" and gives the empty streets some motion.

func _ready() -> void:
	amount = 110
	lifetime = 7.0
	preprocess = 4.0
	visibility_aabb = AABB(Vector3(-14, -3, -14), Vector3(28, 12, 28))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(12, 5, 12)
	pm.direction = Vector3(0.3, -1, 0.1)
	pm.spread = 40.0
	pm.initial_velocity_min = 0.15
	pm.initial_velocity_max = 0.5
	pm.gravity = Vector3(0, -0.12, 0)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.6
	pm.turbulence_noise_scale = 3.0
	pm.scale_min = 0.6
	pm.scale_max = 1.3
	pm.color = Color(0.99, 0.96, 0.89, 0.85)
	process_material = pm
	var qm := QuadMesh.new()
	qm.size = Vector2(0.06, 0.06)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(0.99, 0.96, 0.89, 1.0)
	qm.material = mat
	draw_pass_1 = qm
	# the emitter is parented to the player but should not spin with the camera
	top_level = true


func _process(_dt: float) -> void:
	var p := get_parent() as Node3D
	if p != null:
		global_position = p.global_position + Vector3(0, 2.0, 0)
