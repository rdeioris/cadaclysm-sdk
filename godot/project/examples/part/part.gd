# A CAD part turning on its stand: `godot --path project res://examples/part/part.tscn
# -- part.step`, or drop a STEP, IGES, IFC, SAT, 3DM or BREP file on the window.
extends Node3D

var model: Node3D

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	open(args[0] if args.size() > 0 else "res://examples/models/nut.step")
	get_window().files_dropped.connect(func(files): open(files[0]))

func open(path: String) -> void:
	var scene := CadaclysmScene.open(path)              # metres, Y up: Godot's own space
	if scene == null:
		push_error(Cadaclysm.last_error())
		return
	if model:
		model.queue_free()
	model = scene.instantiate_with({"edges": true})     # a MeshInstance3D per body
	add_child(model)
	$Camera.frame(scene.bounds)
	scene.close()                                       # the meshes are Godot's now
