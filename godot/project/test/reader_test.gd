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

func test_edge_colours_follow_the_edges():
	var path := fixture("samples/edge-colours.stp")
	if path == "":
		return
	var scene: CadaclysmScene = CadaclysmScene.open(path)
	ok(scene != null)
	var body: CadaclysmNode = null
	for n in scene.walk():
		if n.edges.polyline_count > 0:
			body = n
			break
	ok(body != null, "no edged body in edge-colours.stp")
	var colours: Array = body.edge_colours
	eq(colours.size(), body.edges.polyline_count)
	var styled := colours.filter(func(c): return c != null)
	eq(styled.size(), 1, "exactly one styled entry")
	if styled.size() == 1:
		var c: Color = styled[0]
		near(c.r, 0.1, 1e-6)
		near(c.g, 0.6, 1e-6)
		near(c.b, 0.55, 1e-6)
		near(c.a, 1.0, 1e-6)
	scene.close()

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

# The mechanism facts, identical in every language: two links "base" and "arm", each
# naming one node of the same name; one joint "hinge" from "arm" (index 1) to "base"
# (index 0).
func test_mechanism_links_and_joints():
	var path := fixture("samples/mechanism.stp")
	if path == "":
		return
	var scene := CadaclysmScene.open(path)
	ok(scene != null, Cadaclysm.last_error())
	if scene == null:
		return
	var links := scene.links
	eq(links.size(), 2)
	eq(links[0].name, "base")
	eq(links[1].name, "arm")
	for link in links:
		eq(link.nodes.size(), 1)
		eq(link.nodes[0].name, link.name)
	var joints := scene.joints
	eq(joints.size(), 1)
	var hinge: CadaclysmJoint = joints[0]
	eq(hinge.name, "hinge")
	eq(hinge.start.name, "arm")
	eq(hinge.start.index, 1)
	eq(hinge.end.name, "base")
	eq(hinge.end.index, 0)

func test_cube_has_no_links_or_joints():
	var path := fixture("samples/cube.scad")
	if path == "":
		return
	var scene := CadaclysmScene.open(path)
	ok(scene != null, Cadaclysm.last_error())
	if scene == null:
		return
	eq(scene.links.size(), 0)
	eq(scene.joints.size(), 0)

# ---- the FEM surface mesh -------------------------------------------------------------
#
# `CadaclysmNode.fem_mesh`, both paths: a node with no B-rep (the scene's own triangles)
# and one with a B-rep, read back from STEP the kernel wrote. The kernel's own side is in
# blacksmith_test.gd, which carries the twins of the helpers below -- the two suites
# already duplicate `all_near` and friends the same way, each file running on its own.
#
# Every assertion names the wrong implementation it catches. There are no synthetic
# record tests here, unlike the Python, Node and LuaJIT suites: this wrapper hands an
# edge over as a Dictionary of straight field copies with no `chains()` helper, so there
# is no index arithmetic of its own to test as a pure function. What stands in for them
# is the field-by-field walk below plus the sheet's `faces == [0, NONE]` in the kernel
# suite, which is what catches a sentinel normalised to `0` and a field swap.

const CUBE := "cube(20);"
# The one body in this repository whose FEM censuses are both non-empty. Its own comment
# header says why a `polyhedron` is the only route to one and what the figures are.
const OPEN_SHEET := "samples/open-sheet.scad"
# The ABI's "there is none" sentinel: 2^32 - 1. Every field that can hold it comes over
# as an `int` (`vertices[i].node`) or in a `PackedInt64Array` (`faces`, `ends`, a census
# row), never in a `PackedInt32Array`, where it would read as -1.
const FEM_NONE := 4294967295

# A placement carrying **both a rotation and a translation**: a quarter turn about z,
# then 100 along x, as sixteen column-major doubles.
#
#     [ 0 -1  0 100 ]        so (x, y, z) -> (100 - y, x, z)
#     [ 1  0  0   0 ]
#     [ 0  0  1   0 ]
#     [ 0  0  0   1 ]
#
# A translation alone cannot catch a composition-order bug -- translate-then-rotate and
# rotate-then-translate agree on every pure translation, and the transpose of the
# identity is the identity. With the turn in it they disagree loudly: this sends the
# origin to (100, 0, 0) where the other order sends it to (0, 100, 0), and a transposed
# 3x3 block sends what should be +y to -y.
#
# **A rotation only says something about a body that is not symmetric under it.**
# Transposing the 3x3 block composes this with a 180-degree turn about z through the
# placement's own origin, so a body centred on that axis maps onto itself: same nodes,
# same span, no failure. `cube.scad` spans 0..20 in x and y rather than straddling the
# axis, which is why it needs no care here; the kernel suite's cuboid is moved off the
# axis **in the plane the turn acts in** for exactly this reason (an offset purely along
# z is off the origin but on the axis and buys nothing -- measured in task 4).
const TURNED := [0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 100, 0, 0, 1]

func turned(p: Array) -> Array:
	return [100 - p[1], p[0], p[2]]

# Every node as a triple: `nodes` is flat doubles, three to a node.
func fem_points(nodes: PackedFloat64Array) -> Array:
	var out := []
	for i in range(0, nodes.size() - 2, 3):
		out.append([nodes[i], nodes[i + 1], nodes[i + 2]])
	return out

func fem_near(a: Array, b: Array) -> bool:
	for k in 3:
		if absf(a[k] - b[k]) > 1e-6:
			return false
	return true

func fem_has(nodes: PackedFloat64Array, want: Array) -> bool:
	for p in fem_points(nodes):
		if fem_near(p, want):
			return true
	return false

# The box the nodes fill: `[lo, hi]`.
func fem_span(nodes: PackedFloat64Array) -> Array:
	var points := fem_points(nodes)
	if points.is_empty():
		return [[0, 0, 0], [0, 0, 0]]
	var lo: Array = points[0].duplicate()
	var hi: Array = points[0].duplicate()
	for p in points:
		for k in 3:
			lo[k] = minf(lo[k], p[k])
			hi[k] = maxf(hi[k], p[k])
	return [lo, hi]

func fem_span_is(nodes: PackedFloat64Array, lo: Array, hi: Array, what: String) -> bool:
	var span := fem_span(nodes)
	return ok(fem_near(span[0], lo) and fem_near(span[1], hi),
		"%s: the nodes span %s..%s, expected %s..%s" % [what, span[0], span[1], lo, hi])

# What holds of any FEM mesh, whichever library built it: the five flat arrays agree with
# each other and with the counts, every index is in range, and every `node_entity` is
# bounded by the list its own `node_kind` names -- which is what tells those two arrays
# apart if they were ever filled from one pointer. Returns `[node_count, triangle_count]`.
func fem_arrays(mesh, what: String) -> Array:
	var nodes: PackedFloat64Array = mesh.nodes
	var triangles: PackedInt32Array = mesh.triangles
	ok(nodes.size() > 0 and triangles.size() > 0, "%s: an empty mesh came back as success" % what)
	eq(nodes.size() % 3, 0, "%s: the nodes are not triples" % what)
	eq(triangles.size() % 3, 0, "%s: the triangles are not triples" % what)
	var node_count := nodes.size() / 3
	var triangle_count := triangles.size() / 3
	eq(mesh.triangle_face.size(), triangle_count, "%s: triangle_face is not one per triangle" % what)
	eq(mesh.node_kind.size(), node_count, "%s: node_kind is not one per node" % what)
	eq(mesh.node_entity.size(), node_count, "%s: node_entity is not one per node" % what)
	for i in triangles:
		ok(i < node_count, "%s: a triangle index points past the nodes" % what)
	for f in mesh.triangle_face:
		ok(f < mesh.face_count, "%s: a triangle_face is not one of the %d faces" % [what, mesh.face_count])
	var kinds: PackedInt32Array = mesh.node_kind
	var entities: PackedInt32Array = mesh.node_entity
	var edge_count: int = mesh.edges.size()
	var vertex_count: int = mesh.vertices.size()
	for i in node_count:
		var bound := -1
		match kinds[i]:
			0: bound = vertex_count
			1: bound = edge_count
			2: bound = mesh.face_count
		if not ok(bound != -1, "%s: node %d has kind %d, which is neither vertex, edge nor face" % [what, i, kinds[i]]):
			continue
		ok(entities[i] < bound, "%s: node %d is on entity %d of kind %d, which has only %d" % [what, i, entities[i], kinds[i], bound])
	return [node_count, triangle_count]

# The `.msh` text and the file: the same bytes from the same writer, and two asks giving
# two equal texts. On this side of the ABI the library's text is a slot borrowed from the
# handle -- a wrapper that ported the kernel's owned-string convention across and freed it
# would double-free the library's own memory, and asking twice is what says it did not.
func fem_msh(mesh, file: String, what: String) -> String:
	var text: String = mesh.msh_text()
	ok(text.begins_with("$MeshFormat\n4.1 0 8\n"), "%s: the .msh text does not open as Gmsh 4.1 ASCII: %s" % [what, text.left(40)])
	eq(mesh.msh_text(), text, "%s: two asks for the same mesh's .msh text disagree" % what)
	var out := tmp(file)
	ok(mesh.save_msh(out), "%s: save_msh failed: %s" % [what, Cadaclysm.last_error()])
	ok(FileAccess.get_file_as_bytes(out).size() >= text.length() / 2,
		"%s: save_msh wrote %d bytes against %d of text" % [what, FileAccess.get_file_as_bytes(out).size(), text.length()])
	return text

# The cube in its own axes and units. **Native, not Godot's y-up default**: a `from_mesh`
# body comes back in the scene's convention, so y-up would rotate and scale the very
# nodes the placement test asserts. Every other wrapper reads this cube in its own space.
func cube_scene() -> CadaclysmScene:
	return CadaclysmScene.open_bytes(CUBE.to_utf8_buffer(), "scad", {"convention": "native"})

# A curved, closed B-rep body: the kernel builds it, writes STEP, and the reader reads it
# back -- ten faces, the same body every other wrapper's FEM tests use, and the reader's
# **B-rep path**, where the options are read. The one test here that uses the kernel; its
# own `Solid.fem_mesh` is exercised in blacksmith_test.gd.
func rounded_scene() -> CadaclysmScene:
	var box := CadaclysmSolid.cuboid(20, 20, 10)
	var vertical := box.edges.filter(func(e): return e.is_line and absf(e.direction.z) > 0.99)
	var rounded := box.fillet(vertical, 2)
	if rounded == null:
		return null
	return CadaclysmScene.open_bytes(rounded.step_text().to_utf8_buffer(), "stp", {"convention": "native", "name": "rounded.stp"})

func brep_body(scene: CadaclysmScene) -> CadaclysmNode:
	for p in scene.placements:
		if p.geometry.brep != null:
			return p.geometry
	return null

# Which count feeds which entry point -- the census *wiring*, which nothing else pins. Every
# other FEM test proves a row is extracted correctly; none proves `open_edges` reads
# `open_edge_count` rows through `cadaclysm_fem_mesh_open_edge` rather than the folded count or
# the folded call.
#
# `samples/open-sheet.scad` is the only body in this repository where both censuses are
# non-empty and of different lengths: the B-rep path computes no census unless the topology is
# closed (the documented "not asked" pair) and every closed body has none, while the mesh path
# always computes one -- so a `polyhedron` with a flap over one of its own directed edges is the
# way in. Six cracks, one fold, and the fold is not the first crack.
#
# Catches: `open_edges` wired to the folded count (1 row where 6 belong), to the folded call
# (row 1 of a one-row table cannot be read at all, so the getter comes back empty), or both
# consistently (the contents then disagree).
func test_fem_a_census_reads_its_own_count_through_its_own_entry_point():
	var path := fixture(OPEN_SHEET)
	if path == "":
		return
	var scene := CadaclysmScene.open_with(path, {"convention": "native"})
	if not ok(scene != null, "fem census: " + Cadaclysm.last_error()):
		return
	var mesh: CadaclysmFemMesh = scene.node(0).fem_mesh()
	if not ok(mesh != null, "fem census: " + Cadaclysm.last_error()):
		return
	eq(mesh.nodes.size(), 5 * 3)
	eq(mesh.triangles.size(), 3 * 3)
	eq(mesh.from_mesh, true)
	eq(mesh.watertight, false)
	var cracks := mesh.open_edges
	var folds := mesh.folded_edges
	# The counts are what separate the two lists.
	eq(cracks.size(), 6, "the sheet and its flap leave six boundary edges")
	eq(folds.size(), 1, "the flap shares one directed edge with the sheet")
	# And the contents, which separates a wrapper that swapped both consistently. A census row
	# is a PackedInt64Array so the sentinel is 4294967295 and not -1.
	if folds.size() == 1:
		eq(Array(folds[0]), [2, 0, FEM_NONE], "a mesh-only body's rows name no brep edge")
	if cracks.size() == 6:
		eq(Array(cracks[0]), [1, 2, FEM_NONE])
	mesh.release()
	scene.close()

func test_fem_a_node_with_no_brep_meshes_from_its_own_triangles():
	var scene := cube_scene()
	var mesh: CadaclysmFemMesh = scene.node(0).fem_mesh()
	if not ok(mesh != null, "fem: " + Cadaclysm.last_error()):
		return
	var counts := fem_arrays(mesh, "fem")
	# A mesh-only body: one face, every node on it, no topology at all -- and its census
	# does run over the welded triangles, so an empty one here means "nothing found"
	# rather than "not asked".
	eq(mesh.from_mesh, true, "fem: a node with no brep did not report from_mesh")
	eq(mesh.face_count, 1)
	eq(mesh.edges.size(), 0)
	eq(mesh.vertices.size(), 0)
	for k in mesh.node_kind:
		eq(k, 2, "fem: a from_mesh body has a node off a face")
	eq(mesh.open_edges.size(), 0)
	eq(mesh.folded_edges.size(), 0)
	eq(mesh.watertight, true, "fem: the cube's own mesh is not watertight")
	eq(counts[0], 8)
	eq(counts[1], 12)
	fem_span_is(mesh.nodes, [0, 0, 0], [20, 20, 20], "fem")
	ok(mesh.min_angle > 0 and mesh.min_angle <= 60, "fem: min_angle reads %s" % mesh.min_angle)
	ok(mesh.worst_triangle < counts[1], "fem: worst_triangle is not a triangle")
	ok(mesh.longest_edge > 0, "fem: longest_edge is not positive")
	fem_msh(mesh, "reader.msh", "fem")
	ok(str(mesh).begins_with("FemMesh(nodes=8, triangles=12"), str(mesh))
	mesh.release()
	scene.close()

func test_fem_the_reader_placement_is_sixteen_numbers_column_major():
	var scene := cube_scene()
	var node := scene.node(0)
	var placed: CadaclysmFemMesh = node.fem_mesh_placed(0.01, 0.0, TURNED)
	var plain: CadaclysmFemMesh = node.fem_mesh()
	if not ok(placed != null and plain != null, "fem: " + Cadaclysm.last_error()):
		return
	eq(placed.nodes.size(), plain.nodes.size(), "fem: the placement changed the node count")
	# Every node, not one convenient point: a transposed 3x3 block leaves the corner at
	# the origin where it was. Catches a placement dropped (the nodes stay where the body
	# is), applied twice, transposed (+y for -y), or composed the other way round (the
	# origin at (0, 100, 0), not (100, 0, 0)).
	for p in fem_points(plain.nodes):
		ok(fem_has(placed.nodes, turned(p)), "fem: the placement did not send %s to %s -- the placed nodes span %s" % [p, turned(p), fem_span(placed.nodes)])
	fem_span_is(placed.nodes, [80, 0, 0], [100, 20, 20], "fem placed")
	# The same transform as a `Transform3D`, whose basis columns are the first three
	# columns of those sixteen numbers: this is what a transposed conversion gets wrong,
	# and a `Transform3D` is how a Godot caller has a placement to hand.
	var by_transform: CadaclysmFemMesh = node.fem_mesh_placed(0.01, 0.0,
		Transform3D(Basis(Vector3(0, 1, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1)), Vector3(100, 0, 0)))
	fem_span_is(by_transform.nodes, [80, 0, 0], [100, 20, 20], "fem placed by a Transform3D")
	# A `PackedFloat64Array` is the other spelling of the sixteen, and the one that keeps
	# a double: a `Transform3D` holds floats.
	fem_span_is(node.fem_mesh_placed(0.01, 0.0, PackedFloat64Array(TURNED)).nodes, [80, 0, 0], [100, 20, 20], "fem placed by doubles")
	# The wrapper checks the length, because the ABI receives only a pointer and cannot:
	# sixteen here, twelve on the kernel's side.
	eq(node.fem_mesh_placed(0.01, 0.0, [1, 0, 0]), null)
	ok(Cadaclysm.last_error().contains("expected 16 numbers, got 3"), Cadaclysm.last_error())
	eq(node.fem_mesh_placed(0.01, 0.0, [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]), null)
	ok(Cadaclysm.last_error().contains("got 12"), Cadaclysm.last_error())
	eq(node.fem_mesh_placed(0.01, 0.0, "sideways"), null)
	ok(Cadaclysm.last_error().contains("expected a Transform3D or 16 numbers"), Cadaclysm.last_error())
	# Sixteen numbers the library itself refuses.
	var zeros := PackedFloat64Array()
	zeros.resize(16)
	eq(node.fem_mesh_placed(0.01, 0.0, zeros), null)
	ok(Cadaclysm.last_error() != "", "fem: a singular placement was not refused")
	scene.close()

func test_fem_neither_tolerance_nor_max_size_is_pre_validated():
	# `fem_mesh_of_mesh` takes no options at all, so a tolerance or a size the B-rep path
	# refuses still comes back as a mesh here. Catches a wrapper that validated either
	# field itself -- which passes every Python-shaped test and is wrong.
	var scene := cube_scene()
	var node := scene.node(0)
	for pair in [[0.0, 0.0], [-1.0, 0.0], [NAN, 0.0], [0.01, -1.0], [0.01, NAN], [0.01, INF]]:
		var mesh: CadaclysmFemMesh = node.fem_mesh(pair[0], pair[1])
		ok(mesh != null and mesh.nodes.size() == 24,
			"fem: tolerance %s max_size %s did not mesh on the mesh-only path: %s" % [pair[0], pair[1], Cadaclysm.last_error()])
	scene.close()

func test_fem_the_mesh_outlives_the_scene_and_hands_back_copies():
	var scene := cube_scene()
	var mesh: CadaclysmFemMesh = scene.node(0).fem_mesh()
	if not ok(mesh != null, "fem: " + Cadaclysm.last_error()):
		return
	var nodes: PackedFloat64Array = mesh.nodes
	scene.close()
	# Catches a wrapper that hung the mesh off the scene -- which every other view in this
	# module does, and which would make this read a freed block.
	eq(mesh.released, false, "fem: closing the scene released the FEM mesh")
	eq(mesh.nodes.size(), 24, "fem: the nodes do not read after CadaclysmScene.close")
	ok(mesh.msh_text().length() > 0, "fem: the .msh text is empty after CadaclysmScene.close")
	# **Every array this wrapper hands back is a copy**, so one already in hand survives
	# the release. This is the assertion the docs' claim about Godot rests on, and it
	# would fail -- or crash -- for a wrapper handing back a view into the library's
	# memory, where the values would be whatever the freed block holds.
	var before := nodes.duplicate()
	mesh.release()
	eq(mesh.released, true)
	eq(nodes, before, "fem: an array taken before release() changed after it -- Godot hands back copies")
	mesh.release()   # idempotent
	# Every call then fails in the wrapper's own words rather than reading freed memory.
	eq(mesh.nodes.size(), 0)
	ok(Cadaclysm.last_error().contains("released"), Cadaclysm.last_error())
	eq(mesh.face_count, 0)
	eq(mesh.edges.size(), 0)
	eq(mesh.msh_text(), "")
	eq(mesh.save_msh(tmp("gone.msh")), false)
	eq(str(mesh), "FemMesh(released)")

func test_fem_a_brep_body_carries_topology_and_the_default_tolerance_is_the_librarys():
	var scene := rounded_scene()
	if not ok(scene != null, "fem brep: " + Cadaclysm.last_error()):
		return
	var body := brep_body(scene)
	if not ok(body != null, "fem brep: no placement of the read-back STEP has a brep"):
		return
	var mesh: CadaclysmFemMesh = body.fem_mesh(0.05)
	if not ok(mesh != null, "fem brep: " + Cadaclysm.last_error()):
		return
	fem_arrays(mesh, "fem brep")
	eq(mesh.from_mesh, false, "fem brep: a body with a brep reported from_mesh")
	eq(mesh.face_count, 10, "fem brep: the rounded box read back as %d faces, not 10" % mesh.face_count)
	eq(mesh.face_count, body.surfaces.size(), "fem brep: face_count is not the faces Node.surfaces hands over")
	var edges := mesh.edges
	var vertices := mesh.vertices
	ok(edges.size() > 0 and vertices.size() > 0, "fem brep: a brep body has no edges or no vertices")
	var kinds := {}
	for k in mesh.node_kind:
		kinds[k] = true
	for k in [0, 1, 2]:
		ok(kinds.has(k), "fem brep: no node lies on an entity of kind %d" % k)
	# `id` is the **body's own** edge id, not the index: the ids ascend, and at least one
	# is not its own index -- which catches an id filled from the loop counter, the one
	# mistake no other assertion here would see.
	var renumbered := false
	for i in edges.size():
		if i > 0:
			ok(edges[i - 1]["id"] < edges[i]["id"], "fem brep: the edge ids do not ascend")
		if edges[i]["id"] != i:
			renumbered = true
	ok(renumbered, "fem brep: every edge id equals its own index -- id is the index, not the body's id")
	var node_count := mesh.nodes.size() / 3
	for i in edges.size():
		var e: Dictionary = edges[i]
		var which := "fem brep: edge %d" % i
		eq(e["runs"][0], 0, which + "'s first run does not start at 0")
		for r in e["runs"].size():
			ok(e["runs"][r] < e["nodes"].size(), "%s's run %d starts past its %d nodes" % [which, r, e["nodes"].size()])
			if r > 0:
				ok(e["runs"][r - 1] < e["runs"][r], which + "'s runs do not ascend")
		for n in e["nodes"]:
			ok(n < node_count, which + " names a node past the mesh")
		# A closed body: every edge has two real faces, and neither is a sentinel.
		ok(e["faces"][0] < mesh.face_count and e["faces"][1] < mesh.face_count,
			"%s bounds faces %s of %d" % [which, e["faces"], mesh.face_count])
		if e["closed"]:
			eq(e["runs"].size(), 1, "%s is closed with %d runs" % [which, e["runs"].size()])
		if e["seam"]:
			eq(e["faces"][0], e["faces"][1], which + " is a seam but bounds two different faces")
		# The ends resolve through `vertices` to the chain's own first or last node, which
		# is what tells `ends` from `faces` -- both a pair of numbers a swap leaves in
		# range.
		for v in e["ends"]:
			if v == FEM_NONE:
				continue
			if not ok(v < vertices.size(), "%s ends at vertex %d of %d" % [which, v, vertices.size()]):
				continue
			var at: int = vertices[v]["node"]
			if at == FEM_NONE:
				continue
			ok(at == e["nodes"][0] or at == e["nodes"][e["nodes"].size() - 1],
				"%s's end vertex %d is node %d, which is neither end of its chain" % [which, v, at])
	var positioned := false
	for v in vertices:
		eq(v["point"].size(), 3, "fem brep: a vertex point is not three doubles")
		if v["has_position"]:
			positioned = true
		else:
			eq(v["point"], PackedFloat64Array([0, 0, 0]), "fem brep: a vertex with no position carries a point that is not zeroed")
	ok(positioned, "fem brep: no vertex has a position")
	eq(mesh.watertight, true)
	eq(mesh.open_edges.size(), 0)
	eq(mesh.folded_edges.size(), 0)
	# **The default tolerance is the library's own 0.01, not the 0.05 that `mesh` and its
	# neighbours default to.** Pinned on this body because it is curved: `cube.scad`
	# meshes to 8 nodes at either figure, which is how one wrapper's wrong default
	# survived seventy-five other tests. Both assertions are needed -- the default must
	# equal 0.01's node count and must *not* equal 0.05's.
	var defaulted: CadaclysmFemMesh = body.fem_mesh()
	var hundredth: CadaclysmFemMesh = body.fem_mesh(0.01)
	eq(defaulted.nodes.size(), hundredth.nodes.size(),
		"fem brep: fem_mesh() is not fem_mesh(0.01) -- the default tolerance is not FemOptions::default()'s 0.01")
	ok(defaulted.nodes.size() != mesh.nodes.size(),
		"fem brep: fem_mesh() and fem_mesh(0.05) agree on a curved body, so the default may be the neighbours' 0.05")
	# The B-rep path **does** read the options, and refuses in the library's own words --
	# which is what proves the wrapper surfaces the library's message and not one of its
	# own.
	eq(body.fem_mesh(0), null)
	ok(Cadaclysm.last_error().contains("tolerance must be finite and > 0"), Cadaclysm.last_error())
	eq(body.fem_mesh(0.05, -1), null)
	ok(Cadaclysm.last_error().contains("max_size"), Cadaclysm.last_error())
	mesh.release()
	scene.close()
