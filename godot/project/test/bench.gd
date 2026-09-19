# How long a model takes to reach the screen, and how fast it draws there:
#
#     godot --path <project> --script res://test/bench.gd -- MODEL [SECONDS]
#
# Prints the time to open, mesh (realize_all), build the Godot nodes (instantiate),
# and the frames per second over SECONDS (default 5) of a turning view with edges.
# CADACLYSM_BENCH_PLAIN=1 turns the stage's shadows and SSAO off.
extends SceneTree

var camera: CadaclysmOrbitCamera
var seconds := 5.0
var started := 0
var frames := 0

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("usage: -- MODEL [SECONDS]")
		quit(2)
		return
	if args.size() > 1:
		seconds = float(args[1])
	var t0 := Time.get_ticks_usec()
	var scene := CadaclysmScene.open(args[0])
	if scene == null:
		printerr(Cadaclysm.last_error())
		quit(1)
		return
	var t1 := Time.get_ticks_usec()
	scene.realize_all()
	var t2 := Time.get_ticks_usec()
	var model := scene.instantiate_with({"edges": true})
	var t3 := Time.get_ticks_usec()
	var triangles := 0
	var segments := 0
	for body in model.find_children("*", "MeshInstance3D", true, false):
		var mesh: ArrayMesh = body.mesh
		if mesh.surface_get_primitive_type(0) == Mesh.PRIMITIVE_LINES:
			segments += mesh.surface_get_array_len(0) / 2
		else:
			triangles += mesh.surface_get_array_index_len(0) / 3
	print("%s: %d placements, %d triangles, %d edge segments" % [args[0].get_file(), scene.placements.size(), triangles, segments])
	print("open %.2f s, realize_all %.2f s, instantiate %.2f s" % [(t1 - t0) / 1e6, (t2 - t1) / 1e6, (t3 - t2) / 1e6])
	var stage: Node = load("res://examples/stage.tscn").instantiate()
	if OS.has_environment("CADACLYSM_BENCH_PLAIN"):     # no shadows, no SSAO
		stage.get_node("Sun").shadow_enabled = false
		stage.get_node("Environment").environment.ssao_enabled = false
	root.add_child(stage)
	root.add_child(model)
	camera = CadaclysmOrbitCamera.new()
	camera.fov = 40
	camera.turntable_speed = 0.4
	root.add_child(camera)
	camera.frame(scene.bounds)
	scene.close()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

func _process(_delta: float) -> bool:
	frames += 1
	if frames == 10:                 # past the first frames' shader and upload work
		started = Time.get_ticks_usec()
	elif frames > 10 and Time.get_ticks_usec() - started > seconds * 1e6:
		var fps := (frames - 10) / ((Time.get_ticks_usec() - started) / 1e6)
		print("%.1f fps over %.0f s (%s)" % [fps, seconds, RenderingServer.get_video_adapter_name()])
		quit(0)
	return false
