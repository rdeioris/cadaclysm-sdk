# The reader, against the ACIS crate's Fusion assembly fixture (three coloured bodies
# placed in one assembly) and a Rhino fixture, when the repository has them.
extends "res://test/suite.gd"

const ASSEMBLY := "crates/cadaclysm-acis/tests/fixtures/fusion/assembly.stp"

# The assembly in its own axes and units, as every other wrapper's tests read it.
func native() -> CadaclysmScene:
	var path := fixture(ASSEMBLY)
	return CadaclysmScene.open_with(path, {"convention": "native"}) if path != "" else null

func test_version_and_licence_text():
	ok(Cadaclysm.version().split(".").size() >= 3, Cadaclysm.version())
	ok(RegEx.create_from_string("^\\d{4}-\\d\\d-\\d\\d$").search(Cadaclysm.build_date()) != null, Cadaclysm.build_date())
	ok(Cadaclysm.license_info() != "")
	ok(Cadaclysm.license_notice_count() >= 0)
	ok(Cadaclysm.library_path().contains("cadaclysm_capi"), Cadaclysm.library_path())

func test_mesh_formats_include_stl_and_glb():
	var names := {}
	for f in Cadaclysm.mesh_formats():
		names[f["name"]] = f["extension"]
	eq(names.get("stl"), "stl")
	eq(names.get("glb"), "glb")
	eq(names.get("stl-ascii"), "stl")

func test_conventions_by_name():
	eq(Cadaclysm.convention("native"), 0)
	eq(Cadaclysm.convention("Y-UP"), 3)
	eq(Cadaclysm.convention("unreal+file-units"), 1 | 0x100)
	eq(Cadaclysm.convention("sideways"), -1)
	ok(Cadaclysm.last_error().contains("no convention called"), Cadaclysm.last_error())

func test_open_refuses_what_is_not_there():
	eq(CadaclysmScene.open("no/such/file.stp"), null)
	ok(Cadaclysm.last_error().contains("no such file"), Cadaclysm.last_error())
	eq(CadaclysmScene.open_bytes("not a step file".to_utf8_buffer(), "step", {}), null)
	ok(Cadaclysm.last_error().contains("<memory>"), Cadaclysm.last_error())
	eq(CadaclysmScene.open_bytes("not a step file".to_utf8_buffer(), "step", {"name": "bytes.stp"}), null)
	ok(Cadaclysm.last_error().contains("bytes.stp"), Cadaclysm.last_error())
	eq(CadaclysmScene.open_with("whatever.stp", {"sideways": true}), null)
	ok(Cadaclysm.last_error().contains("no open option called"), Cadaclysm.last_error())

func test_a_call_that_works_clears_the_last_error():
	CadaclysmScene.open("no/such/file.stp")
	ok(Cadaclysm.last_error() != "")
	var scene := native()
	if scene == null:
		return
	eq(Cadaclysm.last_error(), "")

func test_tree_labels_and_depth():
	var scene := native()
	if scene == null:
		return
	eq(scene.node_count, 4)
	eq(scene.nodes.size(), 4)
	eq(scene.roots.size(), 1)
	eq(scene.path, fixture(ASSEMBLY))
	eq(scene.convention, 0)
	ok(scene.schema.contains("AUTOMOTIVE_DESIGN"), scene.schema)
	eq(scene.substituted, false)
	near(scene.metres_per_unit, 0.01, 1e-12)
	var labels := []
	for n in scene.walk():
		labels.append("  ".repeat(n.depth) + n.label)
	eq("|".join(labels), "(Unsaved)|  Bracket body|  Pin body|  Cap body")
	var root: CadaclysmNode = scene.roots[0]
	eq(root.parent, null)
	eq(root.children.size(), 3)
	eq(root.children[0].parent.index, root.index)
	eq(root.can_mesh, false)
	eq(root.children[0].can_mesh, true)
	eq(root.children[0].generator, "brep")
	eq(root.children[0].select_as.index, root.children[0].index)
	eq(root.children[0].instance_of, null)
	eq(root.visible_now, true)
	eq(root.locked, false)
	eq(root.walk().size(), 4)
	eq(scene.node(99), null)
	ok(Cadaclysm.last_error().contains("no node 99"), Cadaclysm.last_error())
	scene.close()

func test_placements_transforms_and_meshes():
	var scene := native()
	if scene == null:
		return
	var placements := scene.placements
	eq(placements.size(), 3)
	var triangles := 0
	for p in placements:
		var m: CadaclysmMesh = p.geometry.mesh
		ok(not m.is_empty)
		eq(m.normals.size(), m.vertex_count)
		triangles += m.triangle_count
		var top := 0
		for i in m.indices:
			top = maxi(top, i)
		ok(top < m.vertex_count, "indices in range")
		var raw: PackedFloat64Array = p.raw_transform
		eq(raw.size(), 16)
		eq(raw[15], 1.0)
		var t: Transform3D = p.transform
		eq(t.origin, Vector3(raw[12], raw[13], raw[14]), "the origin is the fourth column")
		eq(t.basis.x, Vector3(raw[0], raw[1], raw[2]), "column-major basis")
		eq(p.select.index, p.geometry.index)
	eq(triangles, 542)
	# The second body sits 8 along x, the third 8 along y.
	eq(placements[1].raw_transform[12], 8.0)
	eq(placements[1].transform.origin.x, 8.0)
	eq(placements[2].transform.origin.y, 8.0)
	var b: AABB = scene.bounds
	ok(b.has_volume())
	near(b.size.x, 9.366, 1e-3)
	near(b.size.z, 5, 1e-6)
	scene.close()

func test_colour_attributes_and_their_text():
	var scene := native()
	if scene == null:
		return
	var bracket: CadaclysmNode = scene.roots[0].children[0]
	ok(bracket.colour is Color, "the bracket is painted")
	eq(scene.roots[0].colour, null)
	var total := 0
	for n in scene.nodes:
		for a in n.attributes:
			total += 1
			ok(a["name"] is String)
			ok(a["kind"] in ["none", "text", "integer", "real", "boolean", "list", "reference"], str(a["kind"]))
			ok(a["text"] is String)
	eq(total, 8)
	scene.close()

func test_edges_segments_and_copies():
	var scene := native()
	if scene == null:
		return
	var pin: CadaclysmNode = scene.roots[0].children[1]
	var edges: CadaclysmPolylines = pin.edges
	ok(not edges.is_empty)
	var idx := edges.segment_indices()
	var expected := 0
	for run in edges.runs():
		expected += 2 * (run.size() - 1)
	eq(idx.size(), expected)
	eq(edges.runs().size(), edges.polyline_count)
	var counted := 0
	for c in edges.counts:
		counted += c
	eq(counted, edges.vertex_count)
	var pts := edges.segments()
	eq(pts.size(), idx.size())
	eq(pts[0], edges.positions[idx[0]])
	var copy: CadaclysmMesh = pin.mesh
	scene.close()
	# The copy is the caller's own memory: still readable after the scene is gone.
	ok(copy.triangle_count > 0)
	eq(copy.positions.size(), copy.vertex_count)

func test_surfaces_and_the_brep():
	var scene := native()
	if scene == null:
		return
	var bracket: CadaclysmNode = scene.roots[0].children[0]
	var faces := bracket.surfaces
	ok(faces.size() >= 6, str(faces.size()))
	var planes := 0
	for f in faces:
		if f["kind"] == 0:
			planes += 1
			eq(f["kind_name"], "plane")
		ok(f["loops"].size() >= 1)
		ok(f["loops"][0].size() >= 3)
	ok(planes >= 6)
	var brep: CadaclysmBrep = bracket.brep
	ok(brep != null)
	ok(CadaclysmBrep.layout_id() != "")
	var man := brep.manifold()
	eq(man["is_manifold"], true)
	eq(man["is_closed"], true)
	eq(man["boundary_edges"], 0)
	scene.close()
	# The brep outlives the scene; releasing is idempotent and then refused.
	eq(brep.manifold()["faces"], man["faces"])
	brep.release()
	brep.release()
	eq(brep.pointer(), 0)
	ok(Cadaclysm.last_error().contains("released"), Cadaclysm.last_error())

func test_query():
	var scene := native()
	if scene == null:
		return
	eq(scene.query('name != "" or name == ""').size(), 4)
	eq(scene.query('name == "Pin body"').size(), 1)
	eq(scene.query('name == "Pin body"')[0].label, "Pin body")
	eq(scene.query('name == "nothing"').size(), 0)
	eq(scene.query("name ==").size(), 0)
	ok(Cadaclysm.last_error() != "")
	scene.close()

func test_conventions_change_the_space():
	var path := fixture(ASSEMBLY)
	if path == "":
		return
	var native := CadaclysmScene.open_with(path, {"convention": "native"})
	var yup := CadaclysmScene.open(path)   # Godot's own space is the default
	eq(yup.convention, 3)
	# Metres and Y up: the assembly's 5-unit (cm) height becomes 0.05 along y.
	near(yup.bounds.size.y, native.bounds.size.z * 0.01, 1e-6)
	var kept := CadaclysmScene.open_with(path, {"convention": "y-up+file-units"})
	near(kept.bounds.size.y, native.bounds.size.z, 1e-4)
	var numbered := CadaclysmScene.open_with(path, {"convention": 4})
	eq(numbered.convention, 4)

func test_realize_all_and_its_counters():
	var scene := native()
	if scene == null:
		return
	eq(scene.realize_total, 0)
	var built := scene.realize_all()
	ok(built >= 3, "built %d" % built)
	eq(scene.realized, scene.realize_total)
	scene.cancel()
	eq(scene.realize_all(), 0)
	scene.close()

func test_save_mesh_and_save():
	var scene := native()
	if scene == null:
		return
	var stl := tmp("pin.stl")
	var glb := tmp("assembly.glb")
	ok(scene.roots[0].children[1].save_mesh(stl, "stl"))
	ok(scene.save(glb, "glb"))
	for p in [stl, glb]:
		ok(FileAccess.get_file_as_bytes(p).size() > 100, p)
	eq(scene.roots[0].save_mesh(tmp("root.stl"), "stl"), false)
	ok(Cadaclysm.last_error() != "")
	scene.close()

func test_svg():
	var scene := native()
	if scene == null:
		return
	var text := scene.svg_text()
	ok(text.begins_with("<svg"), text.left(40))
	ok(text.contains("<path"), "no <path in the scene's svg text")

	var path := tmp("assembly.svg")
	eq(scene.svg(path), true)
	var written := FileAccess.get_file_as_string(path)
	ok(written.length() > 0, "svg wrote an empty file")
	ok(written.begins_with("<svg"))

	var bracket: CadaclysmNode = scene.roots[0].children[0]
	var node_text: String = bracket.svg_text()
	ok(node_text.begins_with("<svg") and node_text.contains("<path"), "node svg_text")

	# The root itself has no geometry: refused, not a blank drawing.
	eq(scene.roots[0].svg_text(), "")
	ok(Cadaclysm.last_error().contains("no node"), Cadaclysm.last_error())

	# A view, an explicit up and a coloured background all reach the camera and page.
	var front: String = scene.svg_text_with({"view": "front"})
	var top: String = scene.svg_text_with({"view": "top"})
	ok(front != top, "front and top read the same")
	var z_up: String = scene.svg_text_with({"up": "z"})
	var y_up: String = scene.svg_text_with({"up": "y"})
	ok(z_up != y_up, "z-up and y-up read the same")
	var painted: String = scene.svg_text_with({"background": "#ff0000"})
	ok(painted.contains('fill="#ff0000"'), painted.left(300))

	eq(scene.svg_text_with({"fov": 200}), "")
	ok(Cadaclysm.last_error().contains("fov"), Cadaclysm.last_error())
	eq(scene.roots[0].svg_text_with({"fov": 200}), "")
	eq(scene.svg_text_with({"nope": 1}), "")
	ok(Cadaclysm.last_error().begins_with("no svg option called"), Cadaclysm.last_error())
	scene.close()

func test_open_bytes_reads_the_same_tree():
	var path := fixture(ASSEMBLY)
	if path == "":
		return
	var scene := CadaclysmScene.open_bytes(FileAccess.get_file_as_bytes(path), ".stp", {"name": "assembly.stp"})
	eq(scene.path, "assembly.stp")
	eq(scene.node_count, 4)
	scene.close()

func test_declared_schema():
	var path := fixture(ASSEMBLY)
	if path == "":
		return
	ok(Cadaclysm.declared_schema(path).begins_with("AUTOMOTIVE_DESIGN"), Cadaclysm.declared_schema(path))
	eq(Cadaclysm.declared_schema("no/such/file"), "")

func test_a_closed_scene_refuses():
	var scene := native()
	if scene == null:
		return
	var keep: CadaclysmNode = scene.nodes[0]
	eq(scene.closed, false)
	scene.close()
	scene.close()
	eq(scene.closed, true)
	eq(keep.name, "")
	ok(Cadaclysm.last_error().contains("closed"), Cadaclysm.last_error())
	eq(scene.placements.size(), 0)

func test_a_rhino_block_one_geometry_several_placements():
	var path := fixture("crates/cadaclysm-acis/tests/fixtures/rhino/block-instances.3dm")
	if path == "":
		return
	var scene := CadaclysmScene.open(path)
	var shared := {}
	for p in scene.placements:
		var g: int = p.geometry.index
		shared[g] = shared.get(g, 0) + 1
	ok(shared.values().max() >= 2, "a block drawn more than once: %d placements" % scene.placements.size())
	# instantiate shares one ArrayMesh between the placements of one geometry.
	var root := scene.instantiate()
	var meshes := {}
	for child in root.get_children():
		meshes[(child as MeshInstance3D).mesh.get_instance_id()] = true
	eq(root.get_child_count(), scene.placements.size())
	ok(meshes.size() < root.get_child_count(), "%d meshes for %d instances" % [meshes.size(), root.get_child_count()])
	root.free()

# ---- Godot's side ---------------------------------------------------------------------

func test_array_mesh_turns_the_winding_round():
	var scene := native()
	if scene == null:
		return
	var pin: CadaclysmNode = scene.roots[0].children[1]
	var m: CadaclysmMesh = pin.mesh
	var am := pin.array_mesh()
	eq(am.get_surface_count(), 1)
	var arrays := am.surface_get_arrays(0)
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	eq(indices.size(), m.index_count)
	eq(indices[0], m.indices[0])
	eq(indices[1], m.indices[2], "Godot winds clockwise: the last two trade places")
	eq(indices[2], m.indices[1])
	eq((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), m.vertex_count)
	var material := am.surface_get_material(0) as StandardMaterial3D
	eq(material.albedo_color, pin.colour, "painted the file's colour")
	var em := pin.edge_mesh()
	eq(em.surface_get_primitive_type(0), Mesh.PRIMITIVE_LINES)
	eq((em.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), pin.edges.segments().size() + pin.curves.segments().size())
	eq(scene.roots[0].array_mesh(), null, "an assembly node has no triangles")
	var copied := m.to_array_mesh()
	eq(copied.get_surface_count(), 1)
	var lines := pin.edges.to_array_mesh(Color.RED)
	eq((lines.surface_get_material(0) as ShaderMaterial).get_shader_parameter("colour"), Color.RED)

func test_instantiate_builds_mesh_instances():
	var scene := native()
	if scene == null:
		return
	var root := scene.instantiate_with({"edges": true})
	eq(root.name, &"assembly")
	eq(root.get_child_count(), 3)
	var names := []
	for child in root.get_children():
		names.append(String(child.name))
		ok(child is MeshInstance3D)
		eq(child.owner, root, "owned by the root, so it saves as a PackedScene")
		eq(child.get_child_count(), 1, "its edges")
		eq((child.get_child(0) as MeshInstance3D).mesh.surface_get_primitive_type(0), Mesh.PRIMITIVE_LINES)
		eq(child.get_child(0).owner, root, "the edges too")
		eq(child.get_meta("cadaclysm_node"), child.get_meta("cadaclysm_geometry"))
		eq(scene.node(child.get_meta("cadaclysm_node")).label, String(child.name))
	eq(",".join(names), "Bracket body,Pin body,Cap body")
	eq(root.get_child(1).transform, scene.placements[1].transform)
	root.free()
	var tree := scene.instantiate_with({"tree": true})
	eq(tree.get_child_count(), 1, "the file's root as a Node3D")
	eq(String(tree.get_child(0).name), "(Unsaved)")
	eq(tree.get_child(0).get_child_count(), 3)
	tree.free()
	eq(scene.instantiate_with({"edge": true}), null)
	ok(Cadaclysm.last_error().contains("no instantiate option called"), Cadaclysm.last_error())
	var packed := PackedScene.new()
	var again := scene.instantiate()
	eq(packed.pack(again), OK)
	var restored := packed.instantiate()
	eq(restored.get_child_count(), 3)
	restored.free()
	again.free()

func test_drawing_flattens_the_edges():
	var scene := native()
	if scene == null:
		return
	var front := scene.drawing("front")
	var segments: PackedVector2Array = front["segments"]
	ok(segments.size() > 0 and segments.size() % 2 == 0)
	var lo: Vector2 = front["lo"]
	var hi: Vector2 = front["hi"]
	# From the front: x across the page and y down it. The edges stay inside the
	# bodies' box, and nearly fill it (a round body's side has no edge on it).
	var size := scene.bounds.size
	ok(hi.x - lo.x <= size.x + 1e-3 and hi.x - lo.x > 0.9 * size.x, "width %s of %s" % [hi.x - lo.x, size.x])
	ok(hi.y - lo.y <= size.y + 1e-3 and hi.y - lo.y > 0.9 * size.y, "height %s of %s" % [hi.y - lo.y, size.y])
	near(lo.y, -scene.bounds.end.y, 0.05 * size.y, "y runs down the page")
	var top := scene.drawing("top")
	ok(top["hi"].y - top["lo"].y <= size.z + 1e-3 and top["hi"].y - top["lo"].y > 0.9 * size.z)
	eq(scene.drawing("isometric"), {})
	ok(Cadaclysm.last_error().contains("no view called"), Cadaclysm.last_error())

func test_res_paths_open():
	var scene := CadaclysmScene.open("res://examples/models/nut.step")
	ok(scene != null, Cadaclysm.last_error())
	if scene:
		ok(scene.placements.size() >= 1)
