# A small CAD viewer: the file's tree on the left, the model on the right, what the
# file says about the selected node below the tree. `godot --path project
# res://examples/viewer/viewer.tscn -- model.step`, the Open button, or drop a file.
extends Control

const HIGHLIGHT := Color(1.0, 0.55, 0.1, 0.45)

@onready var tree: Tree = %Tree
@onready var attributes: Tree = %Attributes
@onready var status: Label = %Status
@onready var edges: CheckBox = %Edges
@onready var world: Node3D = %World
@onready var camera: CadaclysmOrbitCamera = %Camera

var scene: CadaclysmScene           # kept open: the tree and attributes read it
var model: Node3D
var drawn := {}                     # file node index -> the MeshInstance3Ds it selects
var highlight := StandardMaterial3D.new()

func _ready() -> void:
	highlight.albedo_color = HIGHLIGHT
	highlight.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	highlight.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	highlight.no_depth_test = true
	%Open.pressed.connect(%Dialog.popup_centered_ratio)
	%Dialog.file_selected.connect(open)
	edges.toggled.connect(func(on): for e in get_tree().get_nodes_in_group("cadaclysm_edges"): e.visible = on)
	tree.item_selected.connect(_on_selected)
	%View.resized.connect(func(): if scene: camera.frame.call_deferred(scene.bounds))   # refit, once the view has its new size
	get_window().files_dropped.connect(func(files): open(files[0]))
	var args := OS.get_cmdline_user_args()
	open(args[0] if args.size() > 0 else "res://examples/models/nut.step")

func open(path: String) -> void:
	var started := Time.get_ticks_msec()
	var opened := CadaclysmScene.open(path)
	if opened == null:
		status.text = Cadaclysm.last_error()
		return
	if model:
		model.queue_free()
	scene = opened
	scene.realize_all()                                  # every body at once, in parallel
	model = scene.instantiate_with({"edges": true})
	world.add_child(model)
	drawn.clear()
	for body in model.find_children("*", "MeshInstance3D", true, false):
		if body.name == "edges":
			body.add_to_group("cadaclysm_edges")
			body.visible = edges.button_pressed
		elif body.has_meta("cadaclysm_node"):
			drawn.get_or_add(body.get_meta("cadaclysm_node"), []).append(body)
	camera.frame(scene.bounds)
	_fill_tree()
	var triangles := 0
	for body in drawn.values():
		for instance in body:
			triangles += (instance.mesh as ArrayMesh).surface_get_array_index_len(0) / 3 if instance.mesh else 0
	status.text = "%s: %d nodes, %d placements, %d triangles, %d ms" % [path.get_file(), scene.node_count,
		scene.placements.size(), triangles, Time.get_ticks_msec() - started]

func _fill_tree() -> void:
	tree.clear()
	attributes.clear()
	var items := {}
	var root := tree.create_item()
	for node in scene.walk():                            # depth first: parents come first
		var parent: TreeItem = items.get(node.parent.index, root) if node.parent else root
		var item := tree.create_item(parent)
		item.set_text(0, node.label)
		item.set_tooltip_text(0, node.kind)
		item.set_metadata(0, node.index)
		item.collapsed = node.depth >= 2
		items[node.index] = item

func _on_selected() -> void:
	for body in drawn.values():
		for instance in body:
			instance.material_overlay = null
	var node := scene.node(tree.get_selected().get_metadata(0))
	for below in node.walk():                            # the node and everything under it
		for instance in drawn.get(below.index, []):
			instance.material_overlay = highlight
	attributes.clear()
	var top := attributes.create_item()
	for row in [["kind", node.kind], ["id", node.id]]:
		var item := attributes.create_item(top)
		item.set_text(0, row[0])
		item.set_text(1, row[1])
	for a in node.attributes:
		var item := attributes.create_item(top)
		item.set_text(0, a["name"])
		item.set_text(1, a["text"])
