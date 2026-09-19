# The editor's importer: a CAD file inside the project imports as a scene (run.gd
# imports the project first, the way opening it in the editor does).
extends "res://test/suite.gd"

func test_a_step_file_loads_as_a_packed_scene():
	var packed = load("res://examples/models/nut.step")
	if not ok(packed is PackedScene, "imported as a PackedScene"):
		return
	var root: Node = packed.instantiate()
	var bodies := root.find_children("*", "MeshInstance3D", true, false)
	ok(bodies.size() >= 1, "%d bodies" % bodies.size())
	var mesh: Mesh = bodies[0].mesh
	ok(mesh.get_faces().size() > 0, "it has triangles")
	var direct := CadaclysmScene.open("res://examples/models/nut.step")
	near(mesh.get_aabb().size.length(), direct.placements[0].geometry.bounds.size.length(), 1e-4, "the same body, Y up in metres")
	root.free()

func test_the_import_options_are_the_extension_s():
	var config := ConfigFile.new()
	eq(config.load("res://examples/models/nut.step.import"), OK)
	eq(config.get_value("remap", "importer"), "scene")
	for option in ["cadaclysm/edges", "cadaclysm/tree", "cadaclysm/double_sided", "cadaclysm/uv_world"]:
		ok(config.has_section_key("params", option), option)
