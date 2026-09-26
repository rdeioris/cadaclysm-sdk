# The kernel: the LuaJIT suite (luajit/test/blacksmith_test.lua, itself the Node.js
# suite) ported, with the same shapes and the same expected numbers, plus what only
# Godot has -- Transform3D frames, ArrayMeshes, AABB bounds.
extends "res://test/suite.gd"

const XY := [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]
const SCHEMA_AP203 := "schemas/ap203.exp"

func plate_outline() -> CadaclysmProfile:
	return CadaclysmProfile.rect(80, 40).with_hole(CadaclysmProfile.circle(4)).with_hole(CadaclysmProfile.slot([25, 0], 24, 5))

func count_faces(solid: CadaclysmSolid, kind: String) -> Array:
	var out := []
	for i in solid.faces:
		if solid.face_kind(i) == kind:
			out.append(i)
	return out

func all_near(a, b, tolerance := 1e-9) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if absf(a[i] - b[i]) > tolerance:
			return false
	return true

func v3near(a: Vector3, b: Vector3, tolerance := 1e-6) -> bool:
	return all_near([a.x, a.y, a.z], [b.x, b.y, b.z], tolerance)

# `fails`, after a call that works has cleared the last error: a call that should fail
# and does not then cannot pass on an earlier call's message.
func refuses(f: Callable, pattern := "") -> String:
	CadaclysmBlacksmith.version()
	return fails(f, pattern)

func schema() -> String:
	var r := root()
	return r.path_join(SCHEMA_AP203) if r != "" and FileAccess.file_exists(r.path_join(SCHEMA_AP203)) else ""

func test_the_library_loads():
	var path := CadaclysmBlacksmith.library_path()
	ok(FileAccess.file_exists(path), "library_path names a file: " + path)
	ok(path.contains("cadaclysm_blacksmith"), path)
	ok(RegEx.create_from_string("^\\d+\\.\\d+\\.\\d+").search(CadaclysmBlacksmith.version()) != null, CadaclysmBlacksmith.version())
	ok(RegEx.create_from_string("^\\d{4}-\\d{2}-\\d{2}$").search(CadaclysmBlacksmith.build_date()) != null, CadaclysmBlacksmith.build_date())
	ok(CadaclysmBlacksmith.license_info() != "")
	ok(CadaclysmBlacksmith.license_notice_count() >= 0)
	eq(CadaclysmBlacksmith.load(path), true)
	ok(CadaclysmBlacksmith.brep_layout_id() != "")
	eq(CadaclysmBlacksmith.brep_layout_id(), CadaclysmBrep.layout_id(), "one release, one layout")
	eq(CadaclysmBlacksmith.default_tolerance(), 0.05)
	eq(CadaclysmBlacksmith.fillet_tolerance(), 1e-6)
	refuses(func(): return CadaclysmBlacksmith.license("garbage"))
	eq(CadaclysmBlacksmith.license("garbage"), false)
	if schema() != "":
		eq(CadaclysmBlacksmith.default_schema().replace("\\", "/").to_lower(), schema().replace("\\", "/").to_lower())
	eq(CadaclysmBlacksmith.rgb("#ff0000"), Color(1, 0, 0))
	refuses(func(): return CadaclysmBlacksmith.rgb("#ff00"), "a colour is")

func test_an_error_carries_the_library_text():
	eq(CadaclysmProfile.rect(0, 1), null)
	ok(Cadaclysm.last_error().contains("profile_rect: width and height must be positive"), Cadaclysm.last_error())
	ok(CadaclysmProfile.rect(1, 1) != null)
	eq(Cadaclysm.last_error(), "", "a call that works clears it")

func test_profiles_and_paths_build_and_a_bad_one_fails():
	ok(plate_outline() is CadaclysmProfile)
	ok(CadaclysmProfile.polygon([[0, 0], [10, 0], [0, 10]]) is CadaclysmProfile)
	ok(CadaclysmProfile.polygon(PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(0, 10)])) is CadaclysmProfile)
	var rounded := CadaclysmProfile.path([0, 0]).line_to(10, 0).line_to(10, 8).arc_to(8, 10, [8, 8], true) \
		.line_to(0, 10).line_to(0, 0).end()
	ok(rounded is CadaclysmProfile)
	var p := CadaclysmProfile.path(Vector2(0, 0)).line_to(5, 0)
	ok(p.end_open() is CadaclysmProfile)
	refuses(func(): return p.line_to(1, 1), "path: already ended")
	var builder := CadaclysmProfile.path([0, 0]).line_to(10, 0).bezier_to([12, 2], [12, 8], [10, 10]).line_to(0, 10).line_to(0, 0)
	ok(builder.end() is CadaclysmProfile)
	refuses(func(): return builder.end(), "path: already ended")
	ok(CadaclysmProfile.circle(3).translate(5, 5) is CadaclysmProfile)
	ok(CadaclysmPath.begin([0, 0]) is CadaclysmPath)
	refuses(func(): return CadaclysmPath.begin([0, 0, 0]), "path: start: expected 2 numbers, got 3")
	# A NURBS segment: a quadratic arc-like piece, then closed.
	var nurbs := CadaclysmProfile.path([0, 0]).nurbs_to([[5, 5], [10, 0]], [0, 0, 0, 1, 1, 1], 2, PackedFloat64Array([1, 0.7, 1])) \
		.line_to(0, 0).end()
	eq(CadaclysmSolid.extrude(nurbs, XY, 1).faces, 4)
	refuses(func(): return CadaclysmProfile.path([0, 0]).nurbs_to([[5, 5], [10, 0]], [0, 0, 0, 1, 1, 1], 2, PackedFloat64Array([1, 1])), "nurbs_to: 2 weights")

func test_an_abandoned_path_does_not_wedge_the_library():
	CadaclysmProfile.path([0, 0]).line_to(1, 1)   # dropped unfinished: freed with its last reference
	var closed := CadaclysmProfile.path([0, 0]).line_to(1, 0).line_to(1, 1).line_to(0, 1).line_to(0, 0).end()
	ok(closed is CadaclysmProfile)
	var open := CadaclysmProfile.path([0, 0]).line_to(5, 0)
	open.end_open()
	refuses(func(): return open.end(), "path: already ended")
	for i in 500:
		CadaclysmProfile.path([0, 0]).line_to(1, 0).line_to(1, 1).line_to(0, 1).line_to(0, 0).end()
	ok(CadaclysmProfile.rect(1, 1) is CadaclysmProfile)

func test_solids_build_transform_combine_mesh_bound_and_write_step():
	var plate := CadaclysmSolid.extrude(plate_outline(), XY, 6)
	eq(plate.faces, 12)
	eq(plate.face_kind(0), "plane")
	near(plate.bounds.size.x, 80, 1e-4)
	near(plate.bounds.size.z, 6, 1e-4)
	var raw := plate.raw_bounds()
	eq(raw.size(), 6)
	near(raw[3] - raw[0], 80, 1e-9)
	near(raw[5] - raw[2], 6, 1e-9)
	var mesh := plate.mesh(0.05)
	ok(mesh.vertex_count > 0)
	eq(mesh.normals.size(), mesh.vertex_count)
	eq(mesh.index_count % 3, 0)
	ok(mesh.triangle_count > 0)
	var runs := plate.edge_polylines(0.05)
	ok(runs.polyline_count > 0)
	for r in runs.runs():
		ok(r.size() >= 2)
	for s in [CadaclysmSolid.cuboid(1, 2, 3), CadaclysmSolid.cylinder(1, 2), CadaclysmSolid.cone(1, 2), CadaclysmSolid.sphere(1),
			CadaclysmSolid.torus(3, 1), CadaclysmSolid.wedge(2, 2, 2, 1)]:
		ok(s.faces > 0)
		s.close()
	refuses(func(): return CadaclysmSolid.cuboid(-1, 1, 1), "cuboid")
	eq(CadaclysmSolid.cuboid(-1, 1, 1), null)
	var big := CadaclysmSolid.cuboid(1, 2, 3).scaled(2)
	ok(big != null, "scaled")
	var bb: AABB = big.bounds_at(0.05)
	ok(absf(bb.size.x - 2.0) < 1e-5 and absf(bb.size.z - 6.0) < 1e-5, "scaled bounds")
	eq(CadaclysmSolid.cuboid(1, 1, 1).scaled(0), null)
	var pin := CadaclysmSolid.cylinder(4, 10).translate(0, 0, 6).rotate([0, 0, 0], [0, 0, 1], 0.1).place(XY).mirror(XY)
	ok(pin.faces > 0)
	var part := plate.join(CadaclysmSolid.cuboid(6, 6, 20).translate(30, 10, -5), 0.05)
	ok(part.faces > plate.faces)
	ok(plate.join(CadaclysmSolid.cylinder(3, 20).translate(30, 10, -5), 0.05).faces > plate.faces)
	ok(plate.cut(CadaclysmSolid.cylinder(3, 20).translate(30, 10, -5)).faces > 0)
	ok(plate.common(CadaclysmSolid.cuboid(20, 20, 20)).faces > 0)
	var text := part.step_text(schema(), "mm")
	ok(text.begins_with("ISO-10303-21;"), "STEP text")
	refuses(func(): return part.step_text(schema(), "furlong"), "unit must be one of")
	var stp := tmp("part.stp")
	eq(part.step(stp, schema()), true)
	ok(FileAccess.get_file_as_string(stp).begins_with("ISO-10303-21;"))
	var two := tmp("two.stp")
	# The mirrored pin sits on a left-handed frame; the writer bakes the mirror into
	# the geometry instead of refusing it (faec26ef), so it writes like the upright one.
	eq(CadaclysmBlacksmith.write_step(two, [plate, pin], schema()), true)
	ok(FileAccess.get_file_as_string(two).begins_with("ISO-10303-21;"), "a mirrored solid writes STEP")
	var upright := CadaclysmSolid.cylinder(4, 10).translate(0, 0, 6).rotate([0, 0, 0], [0, 0, 1], 0.1).place(XY)
	eq(CadaclysmBlacksmith.write_step(two, [plate, upright], schema()), true)
	ok(FileAccess.get_file_as_string(two).length() > 0)
	refuses(func(): return CadaclysmBlacksmith.write_step(two, [plate, "nope"]), "write_step: expected CadaclysmSolids")
	# SAT, the same two ways.
	var sat := plate.sat_text("mm")
	ok(sat.begins_with("400 0 1 0"), "SAT text")
	ok(sat.contains(" cone-surface $-1 "), "the bore is written exactly")
	refuses(func(): return plate.sat_text("furlong"), "unit must be one of")
	var sat_path := tmp("plate.sat")
	eq(plate.sat(sat_path), true)
	ok(FileAccess.get_file_as_string(sat_path).begins_with("400 0 1 0"))
	eq(CadaclysmBlacksmith.write_sat(tmp("two.sat"), [plate, upright], "in"), true)
	ok(FileAccess.get_file_as_string(tmp("two.sat")).contains("\n25.4 1e-06 1e-10"), "the unit line")
	part.close()
	eq(part.closed, true)
	refuses(func(): return part.faces, "closed")
	refuses(func(): return part.translate(1, 0, 0), "closed")
	part.close()   # idempotent

func test_svg():
	var plate := CadaclysmSolid.extrude(plate_outline(), XY, 6)
	var text := plate.svg_text()
	ok(text.begins_with("<svg"), text.left(40))
	ok(text.contains("<path"), "no <path in the solid's svg text")

	var path := tmp("plate.svg")
	eq(plate.svg(path), true)
	ok(FileAccess.get_file_as_string(path).begins_with("<svg"))

	# No scene over the kernel: `up` left out is always "z", so an explicit y-up
	# still reads differently from the default.
	var z_up: String = plate.svg_text_with({"up": "z"})
	var y_up: String = plate.svg_text_with({"up": "y"})
	ok(z_up != y_up, "z-up and y-up read the same")

	var both := CadaclysmBlacksmith.write_svg_text([plate, CadaclysmSolid.cuboid(1, 1, 1)])
	eq(both.count("<g id=\""), 2)

	refuses(func(): return plate.svg_text_with({"fov": 200}), "fov")
	eq(plate.svg_text_with({"fov": 200}), "")
	refuses(func(): return plate.svg_with(tmp("no/such/dir/plate.svg"), {"fov": 200}), "fov")
	plate.close()

func test_svg_profile_and_drawing():
	var outline := plate_outline()
	var top_text := outline.svg_text()
	ok(top_text.begins_with("<svg"), top_text.left(40))
	ok(top_text.contains("<path"), "no <path in the profile's svg text")

	var path := tmp("outline.svg")
	eq(outline.svg(path), true)
	ok(FileAccess.get_file_as_string(path).begins_with("<svg"))

	# Pinned against an explicit iso call, not just checked non-empty -- a silently-iso
	# default would make this equal and the assertion below would fail.
	var iso_text: String = outline.svg_text_with({"view": "iso"})
	ok(top_text != iso_text, "profile svg_text did not default to the top view")

	# The widened pair: any mix of solids and profiles, each its own group id -- a
	# solids-only call (test_svg above) still reads exactly as it always did.
	var plate := CadaclysmSolid.extrude(plate_outline(), XY, 6)
	var mixed: String = CadaclysmBlacksmith.write_drawing_svg_text([plate], [outline])
	ok(mixed.contains("<path"), "no <path in the mixed drawing")
	ok(mixed.contains("id=\"solid-0\""), "no solid-0 group in the mixed drawing")
	ok(mixed.contains("id=\"profile-0\""), "no profile-0 group in the mixed drawing")

	var mixed_path := tmp("mixed.svg")
	eq(CadaclysmBlacksmith.write_drawing_svg(mixed_path, [plate], [outline]), true)
	ok(FileAccess.get_file_as_string(mixed_path).begins_with("<svg"))

	refuses(func(): return outline.svg_text_with({"fov": 200}), "fov")
	plate.close()

func test_step_text_takes_no_schema_a_builtin_name_a_path_or_text():
	var solid := CadaclysmSolid.cuboid(1, 2, 3)
	ok(solid.step_text().contains("CONFIG_CONTROL_DESIGN"), "no schema is the built-in AP203")
	ok(solid.step_text("AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF").begins_with("ISO-10303-21;"))
	refuses(func(): return solid.step_text("NO_SUCH_SCHEMA"), "no built-in schema named")
	if schema() != "":
		ok(solid.step_text(schema()).begins_with("ISO-10303-21;"))
	# A long one-line string names no file: it is sent as EXPRESS text, which parses and
	# is then refused for lacking an entity the writer needs.
	var express := "SCHEMA x; ENTITY a; s : STRING; END_ENTITY; END_SCHEMA; -- " + "x".repeat(300)
	var message := refuses(func(): return solid.step_text(express))
	ok(message.begins_with("step: the schema has no entity "), message)
	eq(CadaclysmBlacksmith.write_step_text([solid]), solid.step_text())
	eq(CadaclysmBlacksmith.write_step_text([solid], "", "in").contains("INCH"), true, "the unit reaches the file")
	solid.close()

func test_faces_and_edges_are_queried_selected_filleted_chamfered_and_shelled():
	var box := CadaclysmSolid.cuboid(20, 20, 10)
	var top := box.select_face(">Z")
	eq(box.face_kind(top), "plane")
	var frame := box.face_frame(top)
	eq(frame.raw.size(), 12)
	near(frame.raw[11], 1, 1e-9)
	eq(box.select_face([0, 0, -1]), box.select_face("<Z"))
	eq(box.select_face(Vector3(0, 0, -1)), box.select_face("<Z"))
	eq(box.select_face(2), 2)
	refuses(func(): return box.select_face(99))
	eq(box.select_face(99), -1)
	refuses(func(): return box.select_face("^Z"), "a selector is")
	var edges := box.edges
	eq(edges.size(), 12)
	var vertical := []
	for e in edges:
		if e.is_line and absf(e.direction.z) > 0.99:
			vertical.append(e)
	eq(vertical.size(), 4)
	var shape := RegEx.create_from_string("^Edge\\(\\d+, 'line', faces=\\(\\d+, \\d+\\)\\)$")
	for e in vertical:
		eq(e.faces.size(), 2)
		ok(e.segments.size() >= 2)
		eq(e.raw_segments.size(), e.segments.size() * 3)
		ok(shape.search(str(e)) != null, str(e))
	eq(edges.filter(func(e): return not e.is_line).size(), 0)
	ok(box.fillet(vertical, 2).faces > box.faces)
	var indices := vertical.map(func(e): return e.index)
	ok(box.chamfer(indices, 1).faces > box.faces)
	ok(box.chamfer(PackedInt32Array(indices), 1).faces > box.faces)
	ok(box.shell(1, [top]).faces > box.faces)
	refuses(func(): return box.fillet(vertical, -1))
	refuses(func(): return box.fillet(["a"], 1), "fillet: edges: expected ints or CadaclysmEdges")

func test_a_profile_becomes_a_sheet_and_the_sheet_a_solid():
	var outline := CadaclysmProfile.rect(80, 40).with_hole(CadaclysmProfile.circle(4))
	var sheet := CadaclysmSolid.face(outline, XY)
	eq(sheet.faces, 1)
	eq(sheet.face_kind(0), "plane")
	eq(sheet.face_frame(0).raw.slice(9), PackedFloat64Array([0, 0, 1]))
	eq(sheet.extrude_faces(6).faces, CadaclysmSolid.extrude(outline, XY, 6).faces)
	eq(CadaclysmWorkplane.xz().face(outline).solid().faces, 1)

func test_push_pull_split_and_rounds_and_bevels_remade():
	var box := CadaclysmSolid.cuboid(40, 20, 10)
	var top := box.select_face(">Z")
	var taller := box.push_pull(top, 6)
	eq(taller.faces, 6)
	ok(taller.is_watertight())
	eq(box.push_pull(top, -4).faces, 6)
	var spring := CadaclysmSolid.coil(CadaclysmProfile.circle(1).translate(10, 0), [0, 0, 0], [0, 0, 1], 4, 2)
	ok(spring.is_watertight())
	var pipe := CadaclysmSolid.pipe(CadaclysmSweepPath.at([0, 0, 0]).line_to([0, 0, 10]), 2, 0.5)
	ok(pipe.is_watertight())
	eq(pipe.faces, 6, "two walls outside, two in the bore, two ends")
	var halves := box.split_by_plane([[10, 0, 0], [0, 1, 0], [0, 0, 1], [1, 0, 0]])
	eq(halves.size(), 2)
	eq(halves[0].faces, 6)
	eq(halves[1].faces, 6)
	eq(box.lumps().size(), 1)
	refuses(func(): return box.split_by_plane([[0, 0, 50], [1, 0, 0], [0, 1, 0], [0, 0, 1]]), "split_by_plane: the plane does not cross")
	eq(box.split_by_plane([[0, 0, 50], [1, 0, 0], [0, 1, 0], [0, 0, 1]]).size(), 0)
	var slab := CadaclysmSolid.cuboid(40, 20, 2)
	var parts := box.split(slab)
	ok(parts.size() >= 2, "a box split by a slab through it is at least two bodies, got %d" % parts.size())
	var can := CadaclysmSolid.cylinder(5, 10)
	var caps := [can.select_face(">Z"), can.select_face("<Z")]
	var wall := -1
	for i in 3:
		if not caps.has(i):
			wall = i
	var fatter := can.push_pull(wall, 2)
	ok(fatter.is_watertight())
	eq(fatter.faces, 3)
	var block := CadaclysmSolid.cuboid(30, 20, 12)
	var edge := -1
	for e in block.edges:
		if edge == -1 and e.is_line and absf(e.direction.x) > 0.99:
			edge = e.index
	var rounded := block.fillet([edge], 2)
	var band: int = count_faces(rounded, "cylinder")[0]
	eq(rounded.refillet(band, 3).faces, 7)
	eq(rounded.unfillet(band).faces, 6)
	var walls := CadaclysmSolid.extrude_open(CadaclysmProfile.rect(20, 10), XY, 8)
	var thick := walls.thicken(1)
	ok(thick.is_watertight())
	eq(thick.faces, 16)
	var message := refuses(func(): return walls.thicken(0))
	ok(message.begins_with("thicken: "), message)
	var bevelled := block.chamfer([edge], 2)
	var bevel := -1
	for i in bevelled.faces:
		var nz := snappedf(bevelled.face_frame(i).raw[11], 1e-6)
		if bevel == -1 and bevelled.face_kind(i) == "plane" and nz != 0 and nz != 1 and nz != -1:
			bevel = i
	ok(bevel != -1, "a bevel face")
	eq(bevelled.rechamfer(bevel, 3).faces, 7)
	eq(bevelled.unchamfer(bevel).faces, 6)
	var joined := box.join(box.face_sheet(top).extrude_faces(6))
	eq(joined.faces, 10)
	eq(joined.merge_flush().faces, 6)
	eq(box.join(box.face_sheet(top).extrude_faces(6), 0.05, true).faces, 6, "merged as it joins")

func test_an_open_profile_closes_with_a_line_back_to_its_start():
	var ell := CadaclysmProfile.path([0, 0]).line_to(10, 0).line_to(10, 5).end_open()
	eq(CadaclysmSolid.extrude_open(ell, XY, 2).faces, 2)
	eq(CadaclysmSolid.extrude_open(ell.close_loop(), XY, 2).faces, 3)

func test_open_profiles_chain_into_one_in_any_order():
	var side := func(a, b): return CadaclysmProfile.path(a).line_to(b[0], b[1]).end_open()
	var rect := CadaclysmProfile.chain([side.call([0, 0], [10, 0]), side.call([10, 5], [0, 5]), side.call([0, 0], [0, 5]),
		side.call([10, 0], [10, 5])])
	eq(CadaclysmSolid.extrude(rect, XY, 2).faces, 6)
	eq(CadaclysmSolid.extrude_open(CadaclysmProfile.chain([side.call([0, 0], [10, 0]), side.call([10, 5], [10, 0])]), XY, 2).faces, 2)
	var message := refuses(func(): return CadaclysmProfile.chain([side.call([0, 0], [1, 0]), side.call([5, 5], [6, 5])]))
	eq(message, "chain: piece 1 does not meet the others")

func test_colours_are_set_read_back_and_inherited():
	var block := CadaclysmSolid.cuboid(10, 10, 10)
	eq(block.colour, null)
	var top := block.select_face(">Z")
	var painted := block.coloured("#cc9966").coloured([0.2, 0.4, 1], top)
	ok(painted.colour.is_equal_approx(Color(0.8, 0.6, 0.4)), str(painted.colour))
	ok(painted.face_colour(top).is_equal_approx(Color(0.2, 0.4, 1)))
	ok(painted.translate(5, 0, 0).face_colour(top).is_equal_approx(Color(0.2, 0.4, 1)))
	eq(block.coloured("#fff").colour, Color(1, 1, 1))
	eq(block.coloured(Color(0, 1, 0)).colour, Color(0, 1, 0))
	var cut := painted.cut(CadaclysmSolid.cylinder(2, 20).translate(0, 0, -10).coloured([1, 0, 0]))
	var bore := count_faces(cut, "cylinder")
	ok(bore.size() > 0)
	for f in bore:
		eq(cut.face_colour(f), Color(1, 0, 0))
	refuses(func(): return block.coloured([1.5, 0, 0]), "coloured: r, g and b must be in 0..1")
	refuses(func(): return block.coloured("#fff", -2), "coloured: face -2 is not one of the solid's 6")
	refuses(func(): return block.coloured("#fff", 6), "face 6")
	refuses(func(): return block.face_colour(6), "colour: face 6 is not one of the solid's 6")
	refuses(func(): return block.coloured("red"), "coloured: a colour is")
	var painted_mesh := painted.array_mesh()
	ok((painted_mesh.surface_get_material(0) as StandardMaterial3D).albedo_color.is_equal_approx(Color(0.8, 0.6, 0.4)), "the mesh is painted the solid's colour")

func test_edge_colours_are_set_read_back_and_an_empty_list_colours_none():
	var block := CadaclysmSolid.cuboid(10, 10, 10)
	eq(block.edge_colour(0), null)
	var gold_edges := block.edges_coloured("#cc9966")
	ok(gold_edges.edge_colour(0).is_equal_approx(Color(0.8, 0.6, 0.4)), "edges_coloured(colour) should colour every edge")
	eq(gold_edges.edges_coloured_with("#cc9966", null).edge_colour(0), gold_edges.edge_colour(0))
	var picked := gold_edges.edges_coloured_with([0.2, 0.4, 1], [0])
	ok(picked.edge_colour(0).is_equal_approx(Color(0.2, 0.4, 1)), str(picked.edge_colour(0)))
	ok(picked.edge_colour(1).is_equal_approx(Color(0.8, 0.6, 0.4)), str(picked.edge_colour(1)))
	ok(picked.edge_polyline_colours().size() > 0, "edge_polyline_colours was empty on a solid with edge paint")
	var rect_colour: Variant = CadaclysmProfile.rect(10, 4).coloured("#cc9966").colour
	ok(rect_colour.is_equal_approx(Color(0.8, 0.6, 0.4)), str(rect_colour))
	# block is untouched -- edges_coloured returns a new solid, as coloured does.
	eq(block.edge_colour(0), null)
	# An empty edges list colours no edge -- only a null edges list (edges_coloured's own
	# case) colours every edge.
	var none_coloured := block.edges_coloured_with("#cc9966", [])
	eq(none_coloured.edge_colour(0), null)

func test_the_workplane_chain_mirrors_the_rust_one():
	var plate := CadaclysmWorkplane.xy().extrude(plate_outline(), 6).solid()
	var pin := CadaclysmWorkplane.from_solid(plate).faces(">Z").workplane().cylinder(4, 10).solid()
	near(pin.bounds.position.z, 6, 1e-5, "the pin sits on the top face")
	refuses(func(): return CadaclysmWorkplane.xz().solid(), "nothing was built")
	refuses(func(): return CadaclysmWorkplane.yz().translate(1, 0, 0), "holds no solid")
	refuses(func(): return CadaclysmWorkplane.xy().faces(">Z"), "holds no solid")
	eq(CadaclysmWorkplane.on(XY).cuboid(1, 1, 1).translate(1, 2, 3).solid().faces, 6)
	ok(CadaclysmWorkplane.xy().revolve(CadaclysmProfile.rect(2, 2).translate(5, 0), PI * 2).solid().faces > 0)
	eq(CadaclysmWorkplane.xy().workplane().frame.raw[0], 0.0, "workplane() with nothing picked is a no-op")
	ok(CadaclysmWorkplane.on(CadaclysmFrame.xz()) is CadaclysmWorkplane)

func test_a_frame_is_built_checked_and_passed_where_twelve_numbers_go():
	eq(CadaclysmFrame.xy().raw, PackedFloat64Array(XY))
	eq(CadaclysmFrame.xz().raw, CadaclysmWorkplane.xz().frame.raw)
	eq(CadaclysmFrame.yz().raw, CadaclysmWorkplane.yz().frame.raw)
	eq(CadaclysmFrame.xy().raw[11], 1.0)
	ok(CadaclysmFrame.at([1, 2, 3], [0, 0, 7]).is_equal_approx(CadaclysmFrame.xy(Vector3(1, 2, 3))))
	ok(CadaclysmFrame.at([0, 0, 0], [0, -1, 0]).is_equal_approx(CadaclysmFrame.xz()))
	ok(CadaclysmFrame.at([0, 0, 0], [2, 0, 0]).is_equal_approx(CadaclysmFrame.yz()))
	var f := CadaclysmFrame.at([0, 0, 0], [0, 0, -1], Vector3(1, 1, 5))
	var h := sqrt(0.5)
	ok(all_near(f.raw.slice(3, 6), [h, h, 0]) and all_near(f.raw.slice(6, 9), [h, -h, 0]))
	eq(f.raw.slice(9), PackedFloat64Array([0, 0, -1]))
	eq(f.z, Vector3(0, 0, -1))
	ok(CadaclysmFrame.xy().offset(5).is_equal_approx(CadaclysmFrame.xy(Vector3(0, 0, 5))))
	ok(all_near(CadaclysmFrame.xz().offset(2).raw.slice(0, 3), [0, -2, 0]))
	eq(CadaclysmFrame.xy().translate(1, 2, 3).origin, Vector3(1, 2, 3))
	ok(CadaclysmFrame.create([0, 0, 0], [3, 0, 0], [0, 2, 0], [0, 0, 9]).is_equal_approx(CadaclysmFrame.xy()), "normalised")
	refuses(func(): return CadaclysmFrame.create([0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 0, 1]), "not square")
	refuses(func(): return CadaclysmFrame.create([0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, -1]), "left-handed")
	# `Frame.of` is, unlike every other frame-taking call, itself the checked
	# constructor for a raw array (as Python's `Frame.of` builds through the checked
	# `Frame(...)`), so a mirrored array is refused here too -- in this crate's own
	# "left-handed" wording, since `of` never reaches the kernel to say "right-handed
	# and orthonormal" (only `CadaclysmAssembly.place`'s raw, unchecked path does, spec
	# §5 fact 7). Round-trip regression: `frame()`'s raw-array path moved to
	# `bs::Frame::raw_unchecked` for `place`'s sake and silently carried `of` along with
	# it, until `of` re-validated its own result.
	refuses(func(): return CadaclysmFrame.of([0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, -1]), "left-handed")
	# `Workplane.on` shares `frame()` with every other frame-taking call, so a raw array
	# reaches it unchecked too -- it must re-validate through `bs::Frame::of` the same way
	# `Frame.of` does, or a mirrored raw frame would silently become the workplane's frame.
	refuses(func(): return CadaclysmWorkplane.on([0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, -1]), "left-handed")
	refuses(func(): return CadaclysmFrame.at([0, 0, 0], [0, 0, 0]), "no direction")
	refuses(func(): return CadaclysmFrame.at([0, 0, 0], [0, 0, 1], Vector3(0, 0, -2)), "along the normal")
	ok(str(CadaclysmFrame.xy()).begins_with("Frame(origin="), str(CadaclysmFrame.xy()))
	var lid := CadaclysmSolid.extrude(CadaclysmProfile.rect(10, 4), CadaclysmFrame.xy(Vector3(0, 0, 5)), 2)
	ok(all_near(lid.raw_bounds(), [-5, -2, 5, 5, 2, 7]), str(lid.raw_bounds()))
	var wall := CadaclysmWorkplane.on(CadaclysmFrame.xz(Vector3(0, 3, 0))).extrude(CadaclysmProfile.rect(10, 4), 1).solid()
	near(wall.raw_bounds()[1], 2, 1e-9)
	near(wall.raw_bounds()[4], 3, 1e-9)
	var top := CadaclysmFrame.of(lid.face_frame(lid.select_face(">Z")).raw)
	near(top.raw[2], 7, 1e-9)
	ok(all_near(top.raw.slice(9), [0, 0, 1]))
	# Four triples, a Transform3D and a CadaclysmFrame go wherever twelve numbers do.
	eq(CadaclysmSolid.extrude(CadaclysmProfile.rect(1, 1), [[0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1]], 1).faces, 6)
	eq(CadaclysmSolid.extrude(CadaclysmProfile.rect(1, 1), Transform3D.IDENTITY, 1).faces, 6)
	refuses(func(): return CadaclysmSolid.extrude(CadaclysmProfile.rect(1, 1), [0, 0, 0], 1), "frame: expected 12 numbers, got 3")
	refuses(func(): return CadaclysmSolid.extrude(CadaclysmProfile.rect(1, 1), "xy", 1), "expected a CadaclysmFrame, a Transform3D or 12 numbers")
	# A Transform3D both ways: a turn and a move survive; a scale is refused.
	var turned := Transform3D(Basis(Vector3.UP, 0.5), Vector3(1, 2, 3))
	var back := CadaclysmFrame.from_transform(turned).to_transform()
	ok(back.is_equal_approx(turned), str(back))
	ok(CadaclysmFrame.of(turned).is_equal_approx(CadaclysmFrame.from_transform(turned)))
	refuses(func(): return CadaclysmFrame.from_transform(Transform3D.IDENTITY.scaled(Vector3.ONE * 2)), "scales")
	var moved := CadaclysmSolid.cuboid(2, 2, 2).place(Transform3D(Basis.IDENTITY, Vector3(10, 20, 30)))
	ok(all_near(moved.raw_bounds().slice(0, 3), [9, 19, 29], 1e-6), str(moved.raw_bounds()))

func test_sweep_loft_taper_and_open_sheets():
	var sp := CadaclysmSweepPath.at([0, 0, 0]).line_to([0, 0, 20]).arc([10, 0, 20], [0, 1, 0], PI / 2)
	ok(CadaclysmSolid.sweep(CadaclysmProfile.circle(2), XY, sp).faces > 0)
	ok(CadaclysmSolid.sweep_open(CadaclysmProfile.path([-2, 0]).line_to(2, 0).end_open(), XY, sp).faces > 0)
	sp.close()
	sp.close()
	refuses(func(): return sp.line_to([1, 1, 1]), "sweep_path: closed")
	refuses(func(): return CadaclysmSolid.sweep(CadaclysmProfile.circle(2), XY, sp), "sweep_path: closed")
	var up := [0, 0, 10, 1, 0, 0, 0, 1, 0, 0, 0, 1]
	ok(CadaclysmSolid.loft(CadaclysmProfile.rect(10, 10), XY, CadaclysmProfile.polygon([[-2, -3], [3, -2], [2, 3], [-3, 2]]), up).faces > 0)
	ok(CadaclysmSolid.loft_open(CadaclysmProfile.path([0, 0]).line_to(10, 0).end_open(), XY,
		CadaclysmProfile.path([0, 0]).line_to(10, 0).end_open(), up).faces > 0)
	eq(CadaclysmSolid.extrude_tapered(CadaclysmProfile.rect(10, 10), XY, 5, 0.1).faces, 6)
	var sheet := CadaclysmSolid.extrude_open(CadaclysmProfile.path([0, 0]).line_to(10, 0).end_open(), XY, 5)
	ok(sheet.faces >= 1)
	ok(CadaclysmSolid.extrude_open_tapered(CadaclysmProfile.path([0, 0]).line_to(10, 0).end_open(), XY, 5, 0.1).faces >= 1)
	ok(sheet.extrude_faces(2).faces > sheet.faces)
	ok(CadaclysmSolid.revolve_open(CadaclysmProfile.path([5, 0]).line_to(6, 0).end_open(), [0, 0, 0], [0, 1, 0], PI).faces >= 1)
	ok(CadaclysmSolid.revolve(CadaclysmProfile.rect(2, 2).translate(5, 0), Vector3.ZERO, Vector3.UP, PI).faces > 0)
	ok(CadaclysmSweepPath.at(Vector3.ZERO) is CadaclysmSweepPath)

func test_watertightness_is_checked_and_a_bad_tolerance_fails():
	var cube := CadaclysmSolid.cuboid(2, 2, 2)
	eq(cube.is_watertight(), true)
	eq(cube.leaked_edges(), 0)
	eq(cube.unpaired_edges(), 0)
	var sheet := CadaclysmSolid.extrude_open(CadaclysmProfile.rect(4, 4), XY, 2)
	eq(sheet.is_watertight(), false)
	ok(sheet.leaked_edges(0.05) > 0)
	ok(sheet.unpaired_edges(0.05) > 0)
	var message := refuses(func(): return cube.leaked_edges(0))
	ok(message.begins_with("leaked_edges: tolerance must be positive and finite"), message)
	eq(cube.leaked_edges(0), -1)
	message = refuses(func(): return cube.unpaired_edges(-1))
	ok(message.begins_with("unpaired_edges: "), message)

func test_manifold_is_read_off_the_topology():
	var m := CadaclysmSolid.cuboid(2, 2, 2).manifold
	eq(m["faces"], 6)
	eq(m["edges"], 12)
	eq(m["vertices"], 8)
	eq(m["boundary_edges"], 0)
	eq(m["non_manifold_edges"], 0)
	eq(m["non_manifold_vertices"], 0)
	eq(m["is_manifold"], true)
	eq(m["is_closed"], true)
	var sheet := CadaclysmSolid.extrude_open(CadaclysmProfile.rect(4, 4), XY, 2).manifold
	eq(sheet["faces"], 4)
	eq(sheet["is_manifold"], true)
	eq(sheet["is_closed"], false)
	eq(sheet["boundary_edges"], 8)

func test_split_sheet_cuts_a_sheet_along_a_solids_boundary():
	var sheet := CadaclysmSolid.extrude_open(CadaclysmProfile.rect(40, 40), XY, 20)
	eq(sheet.faces, 4)
	var tool := CadaclysmSolid.cuboid(10, 10, 10).translate(20, 0, 10)
	ok(sheet.split_sheet(tool).faces > sheet.faces, "the straddled wall comes out in more than one piece")
	var message := refuses(func(): return sheet.split_sheet(tool, 0))
	ok(message.begins_with("split_sheet: "), message)

func test_extrude_between_takes_slants_or_numbers():
	var rect := CadaclysmProfile.rect(80, 40)
	var between := CadaclysmSolid.extrude_between(rect, XY, 0, {"at": 6})
	var plain := CadaclysmSolid.extrude(rect, XY, 6)
	eq(between.faces, plain.faces)
	eq(between.raw_bounds(), plain.raw_bounds())
	var flat := CadaclysmBlacksmith.slant_of_plane(XY, [0, 0, 6], [0, 0, 1])
	near(flat["at"], 6, 1e-9)
	near(flat["grad"][0], 0, 1e-9)
	near(flat["grad"][1], 0, 1e-9)
	var message := refuses(func(): return CadaclysmBlacksmith.slant_of_plane(XY, [0, 0, 6], [1, 0, 0]))
	eq(message, "slant_of_plane: the plane holds the sweep direction")
	eq(CadaclysmBlacksmith.slant_of_plane(XY, [0, 0, 6], [1, 0, 0]), {})
	refuses(func(): return CadaclysmBlacksmith.slant_of_plane(XY, [0, 0], [0, 0, 1]), "point: expected 3 numbers")
	var shifted := rect.translate(40, 0)
	var sloped := CadaclysmSolid.extrude_between(shifted, XY, 0.0, {"at": 6, "grad": [0.25, 0]})
	near(sloped.raw_bounds()[2], 0, 1e-6)
	near(sloped.raw_bounds()[5], 26, 1e-6)
	eq(sloped.is_watertight(), true)
	message = refuses(func(): return CadaclysmSolid.extrude_between(rect, XY, 0, {"at": 6, "grad": Vector2(0.25, 0)}))
	ok(message.begins_with("extrude_between: "), message)
	refuses(func(): return CadaclysmSolid.extrude_between(rect, XY, 0, "six"), "extrude_between: top: expected a number or {at, grad}")
	var walls := CadaclysmSolid.extrude_open_between(shifted, XY, 0, {"at": 6, "grad": [0.25, 0]})
	eq(walls.faces, CadaclysmSolid.extrude_open(shifted, XY, 6).faces)
	eq(walls.is_watertight(), false)
	# What slant_of_plane returns is what extrude_between takes.
	var mitre := CadaclysmBlacksmith.slant_of_plane(XY, [0, 0, 6], [-0.25, 0, 1])
	near(mitre["grad"][0], 0.25, 1e-9)
	near(CadaclysmSolid.extrude_between(shifted, XY, 0, mitre).raw_bounds()[5], 26, 1e-6)

func test_faces_are_made_taken_dropped_and_trimmed_profiles_rounded_and_followed():
	var square := CadaclysmProfile.rect(20, 20)
	var sheet := CadaclysmSolid.face(square, XY)
	eq(sheet.faces, 1)
	eq(CadaclysmWorkplane.xy().face(square).solid().faces, 1)
	var peg := CadaclysmSolid.extrude(CadaclysmProfile.circle(4), [0, 0, -6, 1, 0, 0, 0, 1, 0, 0, 0, 1], 12)
	var holed := sheet.trim(peg)
	var disc := sheet.trim(peg, "inside")
	eq(holed.faces + disc.faces, sheet.faces * 2)
	ok(holed.raw_bounds()[3] > 9.9 and disc.raw_bounds()[3] < 4.1, "outside keeps the square, inside the disc")
	refuses(func(): return sheet.trim(peg.translate(100, 0, 0), "inside"), "trim: nothing of the sheet lies inside the tool")
	refuses(func(): return sheet.trim(peg, "both"), "keep must be 'outside' or 'inside', not 'both'")
	var plate := CadaclysmSolid.extrude(square, XY, 6)
	var top := plate.select_face(">Z")
	eq(plate.face_sheet(top).faces, 1)
	eq(plate.drop_faces([0, 1]).faces, plate.faces - 2)
	refuses(func(): return plate.face_sheet(6), "face_sheet: no face 6 -- the solid has 6 (0 to 5)")
	refuses(func(): return plate.face_sheet(-1), "face_sheet: no face -1")
	eq(CadaclysmSolid.extrude(square.round(2), XY, 1).faces, 10)
	eq(CadaclysmSolid.extrude(square.round(2, [1]), XY, 1).faces, 7)
	refuses(func(): return square.round(30), "round: the radius 30 does not fit corner 0")
	var wave := CadaclysmProfile.path([0, 0]).bezier_to([20, 0], [20, 20], [40, 10]).end_open()
	var along := CadaclysmSweepPath.along(wave, XY, 0.01)
	var tube := CadaclysmSolid.sweep(CadaclysmProfile.circle(1), [0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0], along)
	var hi_x: float = tube.raw_bounds()[3]
	ok(tube.faces > 2 and hi_x > 40 and hi_x < 41, "a tube to the end of the curve")
	along.close()
	refuses(func(): return CadaclysmSweepPath.along(wave, XY, 0), "along: the tolerance must be positive and finite")

func test_a_profile_turns_about_an_axis_beside_it_and_loose_loops_make_a_plate():
	var plate := CadaclysmProfile.polygon([[-8, 0], [-5, 0], [-5, 10], [-8, 10]])
	var quarter := CadaclysmSolid.revolve_in_plane(plate, XY, [0, 0], [0, 1], PI / 2)
	var b := quarter.raw_bounds()
	near(b[0], -8, 1e-6)
	near(b[3], 0, 1e-6)
	near(b[2], 0, 1e-6)
	near(b[5], 8, 1e-6)
	var message := refuses(func(): return CadaclysmSolid.revolve_in_plane(plate, XY, [-6, 0], [-6, 1], 1))
	eq(message, "revolve_in_plane: the profile crosses the axis")
	eq(CadaclysmSolid.revolve_open_in_plane(CadaclysmProfile.path([5, 0]).line_to(5, 10).end_open(), XY, [0, 0], [0, 1], PI).faces, 1)
	eq(CadaclysmSolid.extrude(CadaclysmProfile.from_loops([CadaclysmProfile.circle(4), CadaclysmProfile.rect(30, 30)]), XY, 2).faces, 8)
	message = refuses(func(): return CadaclysmProfile.from_loops([CadaclysmProfile.rect(30, 30), CadaclysmProfile.circle(4).translate(100, 0)]))
	eq(message, "from_loops: loop 1 lies outside loop 0")
	refuses(func(): return CadaclysmProfile.from_loops([CadaclysmProfile.rect(30, 30), 4]), "from_loops: expected CadaclysmProfiles")

func test_a_regular_polygon_and_a_spline_open_and_closed():
	eq(CadaclysmSolid.extrude(CadaclysmProfile.regular_polygon([0, 0], 10, 6), XY, 2).faces, 8)
	var square := [[0, 0], [10, 0], [10, 10], [0, 10]]
	var loop := CadaclysmSolid.extrude(CadaclysmProfile.spline(square, 3, PackedFloat64Array(), true), XY, 2)
	eq(loop.faces, 3)
	ok(loop.is_watertight())
	eq(CadaclysmSolid.extrude_open(CadaclysmProfile.spline(square, 3, PackedFloat64Array([1, 2, 2, 1])), XY, 2).faces, 1)
	var message := refuses(func(): return CadaclysmProfile.regular_polygon([0, 0], 10, 2))
	eq(message, "profile_regular_polygon: a polygon has at least 3 sides, not 2")
	# A five-pointed star: ten walls and two caps.
	var star := CadaclysmSolid.extrude(CadaclysmProfile.star([0, 0], 10, 4, 5), XY, 2)
	eq(star.faces, 12)
	ok(star.is_watertight())
	message = refuses(func(): return CadaclysmProfile.star([0, 0], 10, 10, 5))
	eq(message, "profile_star: the inner radius must be under the outer")

func test_text_is_set_as_profiles_with_curved_walls():
	# An `i` is two shapes and an `o` one; the `o` extrudes to a watertight ring
	# whose walls meet the caps on splines: the font's curves are kept.
	var word := CadaclysmProfile.text("io", 10)
	eq(word.size(), 3)
	var ring := CadaclysmSolid.extrude(word[2], XY, 2)
	ok(ring.is_watertight())
	var spline := false
	for edge in ring.edges:
		if edge.kind == "nurbs":
			spline = true
	ok(spline)
	eq(CadaclysmProfile.text("g", 10, "No Such Family Anywhere").size(), 1)
	eq(CadaclysmProfile.text("", 10).size(), 0)
	var message := refuses(func(): return CadaclysmProfile.text("x", 0))
	eq(message, "profile_text: the size must be positive and finite")

func test_meshes_and_edges_are_copied_out_for_godot():
	var ball := CadaclysmSolid.sphere(5)
	var fine := ball.mesh(0.05)
	var p: Vector3 = fine.positions[0]
	near(p.length(), 5, 0.06, "a vertex on the sphere")
	near(fine.normals[0].length_squared(), 1, 1e-4, "a unit normal")
	var top_index := 0
	for i in fine.indices:
		top_index = maxi(top_index, i)
	ok(top_index < fine.vertex_count, "indices count from zero into the vertices")
	var coarse := ball.mesh(0.5)
	ok(coarse.vertex_count < fine.vertex_count, "coarser is fewer vertices")
	eq(fine.positions[0], p, "a copy outlives a re-mesh")
	var drawn := ball.array_mesh()
	eq(drawn.get_surface_count(), 1)
	eq(drawn.surface_get_primitive_type(0), Mesh.PRIMITIVE_TRIANGLES)
	eq(drawn.surface_get_array_index_len(0), fine.index_count)
	var material := drawn.surface_get_material(0) as StandardMaterial3D
	ok(material != null)
	eq(material.cull_mode, BaseMaterial3D.CULL_BACK, "a closed solid draws one side")
	# Godot winds the other way: each triangle's last two corners trade places.
	var godot_indices: PackedInt32Array = drawn.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	eq([godot_indices[0], godot_indices[1], godot_indices[2]], [fine.indices[0], fine.indices[2], fine.indices[1]])
	var sheet := CadaclysmSolid.extrude_open(CadaclysmProfile.rect(4, 4), XY, 2).array_mesh()
	eq((sheet.surface_get_material(0) as StandardMaterial3D).cull_mode, BaseMaterial3D.CULL_DISABLED, "a sheet draws both sides")
	var box := CadaclysmSolid.cuboid(10, 10, 10)
	var edges := box.edge_polylines(0.05)
	eq(edges.polyline_count, 12)
	for run in edges.runs():
		ok(run.size() >= 2)
		near(absf(run[0].x), 5, 1e-6, "an edge of the box runs along its surface")
	var lines := box.edge_mesh()
	eq(lines.surface_get_primitive_type(0), Mesh.PRIMITIVE_LINES)
	ok(lines.surface_get_material(0) is ShaderMaterial)
	var kept := box.mesh()
	box.close()
	refuses(func(): return box.mesh(), "closed")
	refuses(func(): return box.array_mesh(), "closed")
	refuses(func(): return box.edge_polylines(), "closed")
	ok(kept.triangle_count > 0, "a copy outlives its solid")
	refuses(func(): return ball.mesh(0), "mesh")

func test_to_scene_hands_a_solid_to_the_reader():
	var scene := CadaclysmSolid.cuboid(10, 20, 30).to_scene()
	var meshed: CadaclysmNode = null
	for n in scene.nodes:
		if meshed == null and n.can_mesh:
			meshed = n
	ok(meshed != null, "a node that meshes")
	ok(v3near(meshed.bounds.size, Vector3(10, 20, 30), 1e-3), "size " + str(meshed.bounds.size))
	scene.close()
	if schema() != "":
		var again := CadaclysmSolid.cuboid(1, 1, 1).to_scene(schema())
		ok(again.node_count >= 1)
		again.close()

func test_a_read_body_is_a_solid_sharing_the_reader_brep():
	var plate := CadaclysmSolid.extrude(plate_outline(), XY, 6)
	var file := tmp("plate.stp")
	ok(plate.step(file, schema()))
	var scene := CadaclysmScene.open_with(file, {"convention": "native"})
	var node: CadaclysmNode = null
	for p in scene.placements:
		var g: CadaclysmNode = p.geometry
		var b := g.brep
		if b != null:
			b.release()
			if node == null:
				node = g
	ok(node != null, "a placement with a brep")
	var part := CadaclysmSolid.from_node(node)
	var again := CadaclysmSolid.from_node(node, false)
	scene.close()
	eq(part.faces, plate.faces)
	eq(again.faces, plate.faces, "the scene can close first")
	ok(part.cut(CadaclysmSolid.cylinder(2, 20).translate(-30, 0, -5)).faces > part.faces)
	refuses(func(): return CadaclysmSolid.from_node(node), "closed")
	eq(CadaclysmSolid.open(file).faces, plate.faces)
	var all := CadaclysmSolid.open_all(file)
	eq(all.size(), 1)
	eq(all[0].faces, plate.faces)
	var message := refuses(func(): return CadaclysmSolid.open(tmp("missing.stp")))
	ok(message.begins_with("open: "), message)
	# Two bodies: body picks one, from zero.
	var two := tmp("two-bodies.stp")
	ok(CadaclysmBlacksmith.write_step(two, [CadaclysmSolid.cuboid(1, 1, 1), CadaclysmSolid.cylinder(1, 3).translate(10, 0, 0)]))
	eq(CadaclysmSolid.open_all(two).size(), 2)
	refuses(func(): return CadaclysmSolid.open(two), "holds 2 bodies: pass a body (0 to 1)")
	var picked := [CadaclysmSolid.open(two, 0).faces, CadaclysmSolid.open(two, 1).faces]
	picked.sort()
	eq(picked, [3, 6])
	refuses(func(): return CadaclysmSolid.open(two, 5), "has no body 5: it holds 2")
	# A mesh-only document: no brep to hand across.
	var mesh := CadaclysmScene.open_bytes("cube(10);".to_utf8_buffer(), "scad", {})
	var cube: CadaclysmNode = null
	for n in mesh.nodes:
		if cube == null and n.brep == null:
			cube = n
	ok(cube != null, "a node with no brep")
	message = refuses(func(): return CadaclysmSolid.from_node(cube))
	ok(message.begins_with("from_node: node ") and message.contains("has no brep"), message)
	mesh.close()
	var scad := tmp("cube.scad")
	var f := FileAccess.open(scad, FileAccess.WRITE)
	f.store_string("cube(10);\n")
	f.close()
	refuses(func(): return CadaclysmSolid.open(scad), "open: the .scad file draws no B-rep body")

func test_push_pull_on_several_faces_at_once():
	# The box's top and +x side pushed together: 5 taller and 5 longer, each face found
	# again after the other's push; a can's top and wall, taller and fatter.
	var box := CadaclysmSolid.cuboid(40, 20, 10)
	var top := box.select_face(">Z")
	var side := box.select_face(">X")
	var grown := box.push_pull([top, side], 5)
	ok(grown.is_watertight())
	eq(grown.faces, 6)
	var b := grown.raw_bounds()
	near(b[3] - b[0], 45, 1e-6)
	near(b[4] - b[1], 20, 1e-6)
	near(b[5] - b[2], 15, 1e-6)
	eq(box.push_pull(PackedInt32Array([top, side]), 5).faces, 6)
	var can := CadaclysmSolid.cylinder(5, 10)
	var cap := can.select_face(">Z")
	var base := can.select_face("<Z")
	var wall := -1
	for i in can.faces:
		if i != cap and i != base:
			wall = i
	var both := can.push_pull([cap, wall], 2)
	ok(both.is_watertight())
	eq(both.faces, 3)
	b = both.raw_bounds()
	near(b[5] - b[2], 12, 1e-6)
	near(b[3] - b[0], 14, 0.05)
	eq(refuses(func(): return box.push_pull([], 2)), "push_pull: no faces to push")
	refuses(func(): return box.push_pull(-1, 2), "push_pull: no face -1")

func test_weights_one_per_point_refused_otherwise():
	var square := [[0, 0], [10, 0], [10, 10], [0, 10]]
	eq(refuses(func(): return CadaclysmProfile.spline(square, 3, PackedFloat64Array([1, 1]), true)),
		"spline: 2 weights for 4 points; give one per point")
	ok(CadaclysmProfile.spline(square, 3, PackedFloat64Array([1, 1, 1, 1]), true) != null)
	eq(refuses(func(): return CadaclysmProfile.path([0, 0]).nurbs_to([[5, 5], [10, 0]], [0, 0, 0, 1, 1, 1], 2, PackedFloat64Array([1, 1]))),
		"nurbs_to: 2 weights for 3 control points (the current point and 2 given); give one per point")

func test_a_reflector_is_drawn_and_revolved_from_a_parabola():
	# A dish 100 wide, focal length 20, opening up: from rim to rim on the parabola,
	# closed by the rim line, revolved about the axis -- one NURBS wall, watertight.
	var dish := CadaclysmProfile.parabola([0, 0], [0, 1], 20, 0, 50).line_to(0, 31.25).line_to(0, 0).end()
	var bowl := CadaclysmSolid.revolve_in_plane(dish, XY, [0, 0], [0, 1], 2 * PI)
	ok(bowl.is_watertight())
	ok(count_faces(bowl, "revolution").size() > 0)
	# The dish's own arc by vertex, closed by a second parabola through the same rim
	# points with a focus beyond the chord -- the arch over the top, not the dish again
	# (a focus at (0, 20) would rebuild the identical arc and retrace it, per
	# parabola_by_focus's own doc comment on this reflector).
	var arch := CadaclysmProfile.path([-50, 31.25]).parabola_by_vertex(50, 31.25, [0, 0]).parabola_by_focus(-50, 31.25, [0, 40]).end()
	ok(CadaclysmSolid.extrude(arch, XY, 2).is_watertight())
	# A conic with a quarter circle's weight; a parabola by its end tangents.
	var quarter := CadaclysmProfile.path([10, 0]).conic_to(0, 10, [10, 10], cos(PI / 4)).line_to(0, 0).line_to(10, 0).end()
	eq(CadaclysmSolid.extrude(quarter, XY, 2).faces, 5)
	var bump := CadaclysmProfile.path([0, 0]).parabola_to(10, 0, [5, 5]).line_to(0, 0).end()
	eq(CadaclysmSolid.extrude(bump, XY, 2).faces, 4)
	ok(CadaclysmProfile.path([0, 0]).hyperbola_to(10, 0, [5, 5], 2).line_to(0, 0).end() != null)
	eq(refuses(func(): return CadaclysmProfile.path([0, 0]).conic_to(2, 0, [1, 0], 1)),
		"path_conic_to: the control point lies on the chord")
	eq(refuses(func(): return CadaclysmProfile.path([0, 0]).hyperbola_to(2, 0, [1, 1], 1)),
		"hyperbola_to: the weight must be over 1 (1 is a parabola, under 1 an ellipse)")
	eq(refuses(func(): return CadaclysmProfile.parabola([0, 0], [0, 0], 1, -1, 1)),
		"path_parabola: the axis direction is zero")
	refuses(func(): return CadaclysmProfile.path([0, 0]).conic_to(2, 0, [1, 1, 1], 1), "conic_to: control: expected 2 numbers, got 3")

# A closed mesh's volume, by the divergence theorem over its triangles.
func volume(solid: CadaclysmSolid) -> float:
	var m := solid.mesh(0.01)
	var p := m.positions
	var ix := m.indices
	var v := 0.0
	for t in range(0, ix.size(), 3):
		v += p[ix[t]].dot(p[ix[t + 1]].cross(p[ix[t + 2]])) / 6.0
	return absf(v)

func test_loft_through_several_sections():
	# Wide, narrow, wide: a waist, round at every height, and the sheet through the same
	# curves, open.
	var sections := []
	for rz in [[10, 0], [6, 10], [10, 20]]:
		sections.append([CadaclysmProfile.circle(rz[0]), CadaclysmFrame.xy(Vector3(0, 0, rz[1]))])
	var waist := CadaclysmSolid.loft_through(sections)
	ok(waist.is_watertight())
	var drum := volume(CadaclysmSolid.extrude(CadaclysmProfile.circle(10), CadaclysmFrame.xy(), 20))
	var inside := volume(waist)
	ok(inside > 0 and inside < drum, "waist %f of the drum's %f" % [inside, drum])
	var sheet := CadaclysmSolid.loft_through_open(sections)
	eq(sheet.is_watertight(), false)
	eq(CadaclysmSolid.loft_through(sections.slice(0, 1)), null)
	ok(Cadaclysm.last_error().begins_with("loft_through: "), Cadaclysm.last_error())
	eq(CadaclysmSolid.loft_through([sections[0], "nope"]), null)
	ok(Cadaclysm.last_error().contains("section 1 is not a [profile, frame] pair"), Cadaclysm.last_error())

func test_two_circles_hit_twice_a_tangent_touches_and_an_overlap_runs():
	var a := CadaclysmProfile.circle(5)
	var hits := a.hits(CadaclysmProfile.circle(5).translate(6, 0))
	eq(hits.size(), 2)
	var ys := []
	for h in hits:
		ok(not h.run and not h.touch)
		near(h.raw_start[0], 3.0, 1e-12)
		eq(h.raw_start, h.raw_end)
		eq(h.a_start.face, 4294967295)
		eq(h.a_start.loop_index, 0)
		ok(h.a_start.t >= 0.0 and h.a_start.t <= 1.0, str(h.a_start.t))
		ys.append(h.raw_start[1])
	ys.sort()
	near(ys[0], -4.0, 1e-12)
	near(ys[1], 4.0, 1e-12)
	var tangent := CadaclysmProfile.path([-10, 5]).line_to(10, 5).end_open()
	var touching := a.hits(tangent)
	eq(touching.size(), 1)
	ok(touching[0].touch and not touching[0].run)
	var runs := CadaclysmProfile.rect(10, 10).hits(CadaclysmProfile.rect(10, 10).translate(5, 0)).filter(func(h): return h.run)
	eq(runs.size(), 2)
	eq(a.hits(CadaclysmProfile.circle(2).translate(10, 0)).size(), 0)
	refuses(func(): return a.hits(a, 0.0), "profile_hits: tolerance must be positive and finite")
	eq(a.hits(a, 0.0).size(), 0, "empty on failure")

func test_a_line_through_a_cuboid_hits_twice_and_cuts_three_pieces():
	var box := CadaclysmSolid.cuboid(10, 20, 30)
	var line := CadaclysmProfile.path([-20, 0]).line_to(20, 0).end_open()
	var found = box.hits(line, XY)
	ok(found is CadaclysmSolidHits)
	eq(str(found), "SolidHits(hits=2, pieces=3)")
	eq(found.hits.size(), 2)
	var xs := [-5.0, 5.0]
	for k in found.hits.size():
		var h = found.hits[k]
		ok(not h.run and not h.touch)
		near(h.raw_start[0], xs[k], 0.05)
		eq(h.a_start.segment, 0)
		eq(h.a_start.face, 4294967295)
		ok(h.b_start.face != 4294967295 and is_finite(h.b_start.u) and is_finite(h.b_start.v))
	var p: Array = found.pieces
	eq(p.size(), 3)
	ok(p[1] is CadaclysmPiece and p[1].profile is CadaclysmProfile and p[1].start is CadaclysmSpot)
	eq([p[0].inside, p[1].inside, p[2].inside], [false, true, false])
	eq([p[0].start.t, p[2].end.t], [0.0, 1.0])
	eq([p[0].end.t, p[1].end.t], [p[1].start.t, p[2].start.t], "the pieces run head to tail")
	var span: AABB = CadaclysmSolid.extrude_open(p[1].profile, XY, 1).bounds
	near(span.position.x, -5, 0.05, "the middle piece starts on the box")
	near(span.end.x, 5, 0.05, "the middle piece ends on the box")
	ok(CadaclysmSweepPath.along(p[1].profile, XY, 0.05, true) is CadaclysmSweepPath)
	# A loop no hit cuts is one piece, outside here; an open sheet has no pieces.
	var far = box.hits(CadaclysmProfile.circle(1), [100, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1])
	eq(far.hits.size(), 0)
	eq(far.pieces.size(), 1)
	eq(far.pieces[0].inside, false)
	var sheet := CadaclysmSolid.face(CadaclysmProfile.rect(20, 20), XY)
	var across = sheet.hits(CadaclysmProfile.path([0, -20]).line_to(0, 20).end_open(), [0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0])
	ok(across.hits.size() >= 1)
	eq(across.pieces.size(), 0)
	refuses(func(): return box.hits(line, XY, 0.0), "solid_profile_hits: tolerance must be positive and finite")

func test_every_edge_carries_its_exact_curve():
	# A cylinder's rims are circles of its radius about a cap centre, in a unit frame, a whole turn each.
	var cyl := CadaclysmSolid.cylinder(5, 3)
	var rims := cyl.edges.filter(func(e): return e.kind == "circle").map(func(e): return e.curve)
	ok(rims.size() >= 2)
	for c in rims:
		ok(c is CadaclysmCurve)
		eq(c.kind, "circle")
		near(c.radius, 5.0, 1e-9)
		near(c.radius2, 5.0, 1e-9)
		var f: PackedFloat64Array = c.raw_frame
		near(f[0], 0.0, 1e-9)
		near(f[1], 0.0, 1e-9)
		ok(minf(absf(f[2]), absf(f[2] - 3.0)) < 1e-9, str(f[2]))
		near(sqrt(f[3] * f[3] + f[4] * f[4] + f[5] * f[5]), 1.0, 1e-9)
		near(sqrt(f[6] * f[6] + f[7] * f[7] + f[8] * f[8]), 1.0, 1e-9)
		near(f[3] * f[6] + f[4] * f[7] + f[5] * f[8], 0.0, 1e-9)
		ok(v3near(c.origin, Vector3(0, 0, f[2])))
		near(absf(c.t1 - c.t0), TAU, 1e-9)
		eq(c.degree, 0)
		eq(c.knots.size(), 0)
		eq(c.poles.size(), 0)
		eq(c.weights.size(), 0)
		ok(not c.is_rational)
		ok(str(c).begins_with("Curve('circle', origin="), str(c))
	# A cuboid's edges are lines: `origin + x` is the far end, both ends its own vertices.
	for e in CadaclysmSolid.cuboid(2, 4, 6).edges:
		var c = e.curve
		eq(c.kind, "line")
		eq([c.t0, c.t1], [0.0, 1.0])
		var f: PackedFloat64Array = c.raw_frame
		var origin := [f[0], f[1], f[2]]
		var far := [f[0] + f[3], f[1] + f[4], f[2] + f[5]]
		var at_origin := false
		var at_far := false
		var s: PackedFloat64Array = e.raw_segments
		for k in range(0, s.size(), 3):
			var p := [s[k], s[k + 1], s[k + 2]]
			at_origin = at_origin or all_near(p, origin)
			at_far = at_far or all_near(p, far)
		ok(at_origin and at_far, str(c))
		ok(all_near(f.slice(6), [0, 0, 0, 0, 0, 0]))
		eq(c.radius, 0.0)
	# A closed spline extruded: its wall's seam edge is the NURBS itself.
	var square := [[0, 0], [10, 0], [10, 10], [0, 10]]
	var loop := CadaclysmSolid.extrude(CadaclysmProfile.spline(square, 3, PackedFloat64Array(), true), XY, 2)
	var splines := loop.edges.filter(func(e): return e.kind == "nurbs").map(func(e): return e.curve)
	ok(splines.size() > 0, "the extruded spline keeps a nurbs edge")
	for c in splines:
		eq(c.kind, "nurbs")
		eq(c.degree, 3)
		eq(c.knots.size(), c.poles.size() / 3 + c.degree + 1)
		eq(c.weights.size(), 0)
		ok(not c.is_rational)
		ok(c.knots[c.degree] <= c.t0 and c.t0 < c.t1 and c.t1 <= c.knots[c.poles.size() / 3])
	# A kernel shape's edges all have an exact curve.
	for solid in [cyl, loop, CadaclysmSolid.sphere(2)]:
		for e in solid.edges:
			ok(e.curve != null)

func test_two_crossed_pipes_intersect_on_ellipse_chains_and_coaxial_pipes_overlap():
	var tol := 1e-3
	var off_a := func(p: Array) -> float: return absf(sqrt(p[0] * p[0] + p[1] * p[1]) - 1.0)
	var off_b := func(p: Array) -> float: return absf(sqrt(p[0] * p[0] + (p[2] - 3.0) * (p[2] - 3.0)) - 1.0)
	# Two equal pipes crossing at right angles: `a` up z, `b` along y through a's middle.
	var a := CadaclysmSolid.cylinder(1, 6)
	var b := CadaclysmSolid.cylinder(1, 6).rotate([0, 0, 3], [1, 0, 0], PI / 2)
	var found = a.intersect(b, tol)
	ok(found is CadaclysmIntersection)
	ok(found.chains.size() >= 2, "the saddle splits into chains")
	eq(found.overlaps.size(), 0, "a transversal crossing has no coincident face pair")
	var ellipses := 0
	for c in found.chains:
		ok(c is CadaclysmChain)
		ok(c.face_a >= 0 and c.face_a < a.faces and c.face_b >= 0 and c.face_b < b.faces)
		var s: PackedFloat64Array = c.raw_points
		ok(s.size() >= 6 and s.size() == 3 * c.points.size())
		for k in range(0, s.size(), 3):
			var p := [s[k], s[k + 1], s[k + 2]]
			ok(off_a.call(p) < 50 * tol and off_b.call(p) < 50 * tol, "off a surface: " + str(p))
		if c.curve == null:
			continue
		ok(c.curve is CadaclysmCurve and c.curve.kind in ["ellipse", "nurbs"], str(c.curve))
		if c.curve.kind == "ellipse":
			ellipses += 1
			var f: PackedFloat64Array = c.curve.raw_frame
			var t: float = (c.curve.t0 + c.curve.t1) / 2   # the curve's own point, mid-chain
			var q := []
			for k in 3:
				q.append(f[k] + f[3 + k] * c.curve.radius * cos(t) + f[6 + k] * c.curve.radius2 * sin(t))
			ok(off_a.call(q) < 50 * tol and off_b.call(q) < 50 * tol, "the ellipse leaves the pipes: " + str(q))
		ok(str(c).begins_with("Chain(points="), str(c))
	ok(ellipses > 0, "two equal pipes cross on ellipses")
	# Apart: nothing, and not an error. A bad tolerance is refused in the kernel's words.
	var apart = a.intersect(b.translate(10, 0, 0))
	eq([apart.chains.size(), apart.overlaps.size()], [0, 0])
	refuses(func(): return a.intersect(b, 0.0), "intersect: tolerance must be positive and finite")
	# Two coaxial pipes overlapping in height share a wall band: rings on that wall.
	var lower := CadaclysmSolid.cylinder(1, 4)
	var upper := CadaclysmSolid.cylinder(1, 4).translate(0, 0, 2)
	var shared = lower.intersect(upper, tol)
	ok(shared.overlaps.size() >= 1, "the overlapping wall band is an overlap")
	var o = shared.overlaps[0]
	ok(o is CadaclysmOverlap and o.face_a >= 0 and o.face_a < lower.faces and o.face_b >= 0 and o.face_b < upper.faces)
	ok(o.loops.size() >= 1, "a coaxial wall band closes into rings")
	eq(o.raw_loops.size(), o.loops.size())
	for r in o.raw_loops.size():
		var ring: PackedFloat64Array = o.raw_loops[r]
		ok(ring.size() >= 9 and ring.size() == 3 * o.loops[r].size(), "a ring is at least a triangle")
		for k in range(0, ring.size(), 3):
			var p := [ring[k], ring[k + 1], ring[k + 2]]
			ok(off_a.call(p) < 50 * tol and p[2] >= 2 - 50 * tol and p[2] <= 4 + 50 * tol, "off the shared band: " + str(p))
	eq(str(o), "Overlap(faces=(%d, %d), loops=%d)" % [o.face_a, o.face_b, o.loops.size()])

func test_two_circles_share_one_lens_of_arcs():
	var a := CadaclysmProfile.circle(5)
	var b := CadaclysmProfile.circle(5).translate(6, 0)
	var lenses := a.common(b)
	eq(lenses.size(), 1)
	ok(lenses[0] is CadaclysmProfile)
	# Four arcs (each circle's own seam stays a join) between two caps.
	eq(CadaclysmSolid.extrude(lenses[0], XY, 1).faces, 6)
	eq(a.common(b.translate(100, 0)).size(), 0)
	refuses(func(): return a.common(b, 0.0), "profile_common: tolerance must be positive and finite")
	eq(a.common(b, 0.0).size(), 0, "empty on failure")

# ---- the FEM surface mesh -------------------------------------------------------------
#
# `CadaclysmSolid.fem_mesh`, and the three places the two ABIs deliberately disagree: an
# owned `.msh` string here against a borrowed slot on the reader, **twelve** placement
# numbers against sixteen, and which call prints the unlicensed notice. The reader's side
# is in reader_test.gd, which carries the twins of the helpers below -- as the two suites
# already do for `all_near`, each file running on its own.
#
# There are no synthetic record tests, unlike the Python, Node and LuaJIT suites: an edge
# comes over as a Dictionary of straight field copies with no `chains()` helper, so this
# wrapper has no index arithmetic of its own to test as a pure function. The sheet's
# `faces == [0, NONE]` below, the cylinder's seam and rims, and the field-by-field walk in
# reader_test.gd are what stand in for them -- between them they catch a sentinel
# normalised to `0`, the two flags swapped, and `ends` filled from `faces`.

const FEM_NONE := 4294967295

# A placement carrying both a rotation and a translation -- a quarter turn about z, then
# 100 along x -- as the kernel's **twelve** numbers: an origin, then where x, y and z go.
# reader_test.gd's `TURNED` is the same transform as the reader's sixteen column-major
# doubles, and both suites assert it against the one map `turned` below, which is what
# makes the twelve-against-sixteen asymmetry something these tests prove rather than
# merely state. See `TURNED` there for why a translation alone would prove nothing.
const TURNED_FRAME := [100, 0, 0, 0, 1, 0, -1, 0, 0, 0, 0, 1]

func turned(p: Array) -> Array:
	return [100 - p[1], p[0], p[2]]

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

# The eight corners of a box -- every one a B-rep vertex of a cuboid, and so a node.
func fem_corners(lo: Array, hi: Array) -> Array:
	var out := []
	for x in [lo[0], hi[0]]:
		for y in [lo[1], hi[1]]:
			for z in [lo[2], hi[2]]:
				out.append([x, y, z])
	return out

# The twin of reader_test.gd's: the five flat arrays agree with each other and with the
# counts, every index is in range, and every `node_entity` is bounded by the list its own
# `node_kind` names -- which is what tells those two arrays apart if they were ever filled
# from one pointer.
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

# **This library's `.msh` text is an owned string** -- `cadaclysm_blacksmith_string_free`
# at the ABI -- where the reader's is a slot borrowed from the handle. Two asks is what
# separates the two conventions at run time: a missed free leaks silently and no test in
# this repository would see it, while a doubled one takes the process down before the
# first ask returns, which turns a whole test file into a crash.
func fem_msh(mesh, file: String, what: String) -> String:
	var text: String = mesh.msh_text()
	ok(text.begins_with("$MeshFormat\n4.1 0 8\n"), "%s: the .msh text does not open as Gmsh 4.1 ASCII: %s" % [what, text.left(40)])
	eq(mesh.msh_text(), text, "%s: two asks for the same mesh's .msh text disagree" % what)
	var out := tmp(file)
	ok(mesh.save_msh(out), "%s: save_msh failed: %s" % [what, Cadaclysm.last_error()])
	ok(FileAccess.get_file_as_bytes(out).size() >= text.length() / 2,
		"%s: save_msh wrote %d bytes against %d of text" % [what, FileAccess.get_file_as_bytes(out).size(), text.length()])
	return text

# A curved, closed solid: the same body the reader's B-rep test reads back from STEP, and
# the one every other wrapper's FEM tests use. Ten faces.
func rounded_box() -> CadaclysmSolid:
	var box := CadaclysmSolid.cuboid(20, 20, 10)
	var vertical := box.edges.filter(func(e): return e.is_line and absf(e.direction.z) > 0.99)
	return box.fillet(vertical, 2)

func test_fem_the_kernel_meshes_a_solid_and_survives_a_re_mesh():
	var rounded := rounded_box()
	if not ok(rounded != null, "kernel fem: " + Cadaclysm.last_error()):
		return
	var mesh: CadaclysmSolidFemMesh = rounded.fem_mesh(0.05)
	if not ok(mesh != null, "kernel fem: " + Cadaclysm.last_error()):
		return
	var counts := fem_arrays(mesh, "kernel fem")
	eq(mesh.from_mesh, false, "kernel fem: a solid reported from_mesh -- the kernel has no mesh path")
	eq(mesh.face_count, 10, "kernel fem: the rounded box has %d faces, not 10" % mesh.face_count)
	eq(mesh.face_count, rounded.faces, "kernel fem: face_count is not the solid's own face count")
	eq(mesh.watertight, true)
	eq(mesh.open_edges.size(), 0)
	eq(mesh.folded_edges.size(), 0)
	var edges := mesh.edges
	var vertices := mesh.vertices
	ok(edges.size() > 0 and vertices.size() > 0, "kernel fem: a closed solid has no edges or no vertices")
	for i in edges.size():
		var e: Dictionary = edges[i]
		var which := "kernel fem: edge %d" % i
		if i > 0:
			ok(edges[i - 1]["id"] < e["id"], "kernel fem: the edge ids do not ascend")
		eq(e["runs"][0], 0, which + "'s first run does not start at 0")
		for n in e["nodes"]:
			ok(n < counts[0], which + " names a node past the mesh")
		ok(e["faces"][0] < mesh.face_count and e["faces"][1] < mesh.face_count,
			"%s bounds faces %s of %d -- a closed solid's every edge has two real ones" % [which, e["faces"], mesh.face_count])
		# The ends resolve through `vertices` to the chain's own first or last node, which
		# is what tells `ends` from `faces`: both a pair of numbers a swap leaves in range.
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
		eq(v["point"].size(), 3, "kernel fem: a vertex point is not three doubles")
		if v["has_position"]:
			positioned = true
	ok(positioned, "kernel fem: no vertex has a position")
	fem_msh(mesh, "kernel.msh", "kernel fem")
	ok(str(mesh).begins_with("FemMesh(nodes=%d, triangles=%d" % [counts[0], counts[1]]), str(mesh))
	var longest: float = mesh.longest_edge

	# **The default is 0.01, `FemOptions::default()`'s -- not the kernel's own
	# `default_tolerance` of 0.05 that every neighbouring method takes.**
	var defaulted: CadaclysmSolidFemMesh = rounded.fem_mesh()
	var hundredth: CadaclysmSolidFemMesh = rounded.fem_mesh(0.01)
	eq(defaulted.nodes.size(), hundredth.nodes.size(),
		"kernel fem: fem_mesh() is not fem_mesh(0.01) -- the default is not FemOptions::default()'s 0.01")
	ok(defaulted.nodes.size() != mesh.nodes.size(),
		"kernel fem: fem_mesh() and fem_mesh(0.05) agree, so the default may be the neighbours' 0.05")

	# **A FEM mesh is not in the solid's tessellation cache**, so meshing the solid again
	# at another tolerance must not stale it: it is the one array product here whose
	# arrays carry no generation check. Catches that guard wired in by reflex from `mesh`,
	# where it belongs. 2.0 against 0.01, not 0.5 against 0.05: measured in task 8, this
	# body's render mesh is the same 1172 triangles anywhere from 2.0 down to 0.05 (the
	# mesher's own division floor), so a narrower pair would leave the re-mesh unproven.
	var coarse: int = rounded.mesh(2).index_count
	var kept: CadaclysmSolidFemMesh = rounded.fem_mesh(0.05)
	ok(rounded.mesh(0.01).index_count != coarse, "kernel fem: the two tolerances meshed the same -- the re-mesh did not happen")
	eq(kept.nodes.size() / 3, counts[0],
		"kernel fem: a FEM mesh read after the solid was meshed again gives another node count -- a FEM mesh is its own handle, not a product of the tessellation cache")
	eq(kept.edges.size(), edges.size(), "kernel fem: a FEM mesh's edges do not read after the solid was meshed again")
	ok(kept.msh_text().length() > 0, "kernel fem: the .msh text does not read after the solid was meshed again")

	# `max_size` adds nodes and shortens the longest edge -- but it **bounds the boundary
	# and only targets the interior**, so the ceiling is checked loosely on purpose: a
	# tighter pin would assert what the ABI does not promise (measured at 1.03x).
	var finer: CadaclysmSolidFemMesh = rounded.fem_mesh(0.05, 3)
	ok(finer.nodes.size() > mesh.nodes.size(), "kernel fem: max_size 3 gave %d nodes, was %d" % [finer.nodes.size() / 3, counts[0]])
	ok(finer.longest_edge < longest, "kernel fem: max_size 3 left the longest edge at %s, was %s" % [finer.longest_edge, longest])
	ok(finer.longest_edge <= 3 * 1.05, "kernel fem: max_size 3 left a %s edge, past even the 1.03x the spec measured" % finer.longest_edge)

	# A tolerance the mesher refuses, in its own words: the kernel has no mesh-only path,
	# so unlike the reader every solid goes through the options.
	refuses(func(): return rounded.fem_mesh(0), "tolerance must be finite and > 0")
	refuses(func(): return rounded.fem_mesh(0.05, NAN), "max_size")

	# Released by hand; every call then fails, and a second release is a no-op.
	mesh.release()
	eq(mesh.released, true)
	mesh.release()
	eq(mesh.nodes.size(), 0)
	ok(Cadaclysm.last_error().contains("released"), Cadaclysm.last_error())
	eq(mesh.msh_text(), "")
	# The FEM mesh is not the solid's: closing the solid neither frees nor stales one.
	var own: CadaclysmSolidFemMesh = rounded.fem_mesh(0.05)
	rounded.close()
	eq(own.nodes.size() / 3, counts[0], "kernel fem: closing the solid changed the FEM mesh")
	own.release()

func test_fem_the_kernel_placement_is_twelve_numbers():
	# A cuboid, because all eight of its corners are B-rep vertices and so certainly
	# nodes, and **moved off the rotation's axis in the plane the turn acts in**: centred
	# on that axis the check is mathematically blind (see reader_test.gd's TURNED).
	var size := [20.0, 10.0, 4.0]
	var off := [30.0, 7.0, 5.0]
	var lo := []
	var hi := []
	for k in 3:
		lo.append(off[k] - size[k] / 2)
		hi.append(off[k] + size[k] / 2)
	var cuboid := CadaclysmSolid.cuboid(size[0], size[1], size[2]).translate(off[0], off[1], off[2])
	var placed: CadaclysmSolidFemMesh = cuboid.fem_mesh_placed(0.05, 0, TURNED_FRAME)
	if not ok(placed != null, "kernel fem: " + Cadaclysm.last_error()):
		return
	for corner in fem_corners(lo, hi):
		ok(fem_has(placed.nodes, turned(corner)),
			"kernel fem: the frame did not send the corner %s to %s -- the nodes span %s" % [corner, turned(corner), fem_span(placed.nodes)])
	fem_span_is(placed.nodes, [88, 20, 3], [98, 40, 7], "kernel fem placed")
	# Twelve numbers here where the reader takes sixteen, and every other frame form this
	# library takes: four triples, a `CadaclysmFrame`, or a `Transform3D`.
	fem_span_is(cuboid.fem_mesh_placed(0.05, 0, [[100, 0, 0], [0, 1, 0], [-1, 0, 0], [0, 0, 1]]).nodes, [88, 20, 3], [98, 40, 7], "kernel fem placed by triples")
	fem_span_is(cuboid.fem_mesh_placed(0.05, 0, CadaclysmFrame.of(TURNED_FRAME)).nodes, [88, 20, 3], [98, 40, 7], "kernel fem placed by a CadaclysmFrame")
	fem_span_is(cuboid.fem_mesh_placed(0.05, 0, Transform3D(Basis(Vector3(0, 1, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1)), Vector3(100, 0, 0))).nodes,
		[88, 20, 3], [98, 40, 7], "kernel fem placed by a Transform3D")
	# The identity, spelled out: the solid meshed in its own coordinates, as no placement
	# at all does.
	fem_span_is(cuboid.fem_mesh_placed(0.05, 0, CadaclysmFrame.xy()).nodes, lo, hi, "kernel fem placed by the world frame")
	fem_span_is(cuboid.fem_mesh(0.05).nodes, lo, hi, "kernel fem unplaced")
	# The reader's sixteen are refused here, by length, before the library sees them.
	refuses(func(): return cuboid.fem_mesh_placed(0.05, 0, [0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 100, 0, 0, 1]), "expected 12 numbers, got 16")
	cuboid.close()

func test_fem_an_open_sheet_is_the_not_asked_trio():
	# One face with a hole, so its rim is both the outer and the inner loop.
	var sheet := CadaclysmSolid.face(CadaclysmProfile.rect(80, 40).with_hole(CadaclysmProfile.circle(4)), XY)
	var mesh: CadaclysmSolidFemMesh = sheet.fem_mesh(0.05)
	if not ok(mesh != null, "kernel fem: " + Cadaclysm.last_error()):
		return
	# `watertight` false with **both censuses empty** is the "not asked" trio: all three
	# together, which is why the two censuses are as prominent here as the flag.
	eq(mesh.watertight, false)
	eq(mesh.open_edges.size(), 0, "kernel fem: an open sheet is not asked about, so its rim is not a crack")
	eq(mesh.folded_edges.size(), 0)
	eq(mesh.face_count, 1)
	var edges := mesh.edges
	ok(edges.size() > 0, "kernel fem: the sheet has no edges")
	for i in edges.size():
		# Catches a wrapper that filled `face_b` with 0 where the ABI said NONE: 0 is a
		# real face, and the sheet's only one. This is also the one assertion that would
		# catch the sentinel narrowed into a PackedInt32Array, where it reads as -1.
		eq(edges[i]["faces"], PackedInt64Array([0, FEM_NONE]),
			"kernel fem: the sheet's rim edge %d reads faces %s, not [0, %d]" % [i, edges[i]["faces"], FEM_NONE])
	mesh.release()
	sheet.close()

func test_fem_a_cylinder_has_a_seam_edge_and_no_closed_one():
	# A cylinder is the shape that tells `closed` from `seam`, and **measured, not assumed**:
	# the manifold analysis gives this solid's 3 edges as 5 -- each rim circle split in two
	# at its two vertices, ends (0, 1) and (1, 0), plus the seam up the side with 2 nodes,
	# `faces` (0, 0) and `seam` true. So **no edge here is `closed`**: a rim is two open
	# halves, not one loop. `closed == true` is one of the three branches no fixture in this
	# repository reaches (the plan records the other two), so it is pinned at zero rather
	# than asserted to exist.
	#
	# The pair of counts is what catches the two flags read from each other's field: swap
	# them and this body reports one closed edge and no seam, so both `eq`s below fail. A
	# closed box would show nothing -- every edge of one is neither.
	var cyl := CadaclysmSolid.cylinder(5, 10)
	var mesh: CadaclysmSolidFemMesh = cyl.fem_mesh(0.05)
	if not ok(mesh != null, "kernel fem: " + Cadaclysm.last_error()):
		return
	var seams := 0
	var loops := 0
	for e in mesh.edges:
		if e["seam"]:
			seams += 1
			eq(e["faces"][0], e["faces"][1], "kernel fem: a seam edge bounds two different faces")
			eq(e["closed"], false, "kernel fem: the cylinder's seam is a closed loop")
		if e["closed"]:
			loops += 1
			eq(e["runs"].size(), 1, "kernel fem: a closed edge has more than one run")
			eq(e["ends"][1], FEM_NONE, "kernel fem: a closed edge's second end is not NONE")
	eq(seams, 1, "kernel fem: the cylinder has %d seam edges, not its one -- `seam` may be reading another field" % seams)
	eq(loops, 0, "kernel fem: %d edges of the cylinder report `closed`, where the analysis splits each rim in two -- `closed` may be reading another field" % loops)
	eq(mesh.edges.size(), 5, "kernel fem: the cylinder's 3 edges came back as %d, not the 5 the analysis splits them into" % mesh.edges.size())
	mesh.release()
	cyl.close()

# The assembly facts (spec §5), ported from the Node/LuaJIT/Rust suites and
# test_cadaclysm_blacksmith.py's `_shared_assembly()`: a named bolt and a coloured named
# plate, a bracket placing the plate once and the bolt twice, and a top assembly placing
# the bracket twice (mirrored the second time) and the bolt once more. Returns
# [bolt, plate, bracket, frame]; fact 1 (the placement names) is asserted here, since
# every other fact starts from this same tree.
func _shared_assembly() -> Array:
	var bolt := CadaclysmSolid.cylinder(1, 6).named("bolt")
	var plate := CadaclysmSolid.cuboid(20, 10, 2).named("plate").coloured([1.0, 0.5, 0.0])
	var bracket := CadaclysmAssembly.create("bracket")
	bracket.place(plate, XY)
	var bolt_name_1 := bracket.place(bolt, CadaclysmFrame.xy(Vector3(5, 5, 2)))
	var bolt_name_2 := bracket.place(bolt, CadaclysmFrame.xy(Vector3(15, 5, 2)))
	eq(bolt_name_1, "bolt", "bracket's own first bolt")
	eq(bolt_name_2, "bolt 2", "bracket's own second bolt")
	var frame := CadaclysmAssembly.create("frame")
	var mirrored := CadaclysmFrame.create([100, 0, 0], [0, 1, 0], [-1, 0, 0], [0, 0, 1])
	var left := frame.place(bracket, CadaclysmFrame.xy(Vector3.ZERO), "left")
	var right := frame.place(bracket, mirrored, "right")
	var root_bolt := frame.place(bolt, CadaclysmFrame.xy(Vector3(50, 50, 0)))
	eq(left, "left", "fact 1: left")
	eq(right, "right", "fact 1: right")
	eq(root_bolt, "bolt", "fact 1: the root bolt")
	return [bolt, plate, bracket, frame]

func test_an_assembly_writes_each_part_and_sub_assembly_once():
	var shared := _shared_assembly()
	var frame: CadaclysmAssembly = shared[3]
	var text := frame.step_text()
	# Fact 2: two breps (bolt, plate), four products (bracket, frame, bolt, plate), six
	# occurrences (left, its bolt, its bolt 2, right, its bolt, its bolt 2 -- the root
	# bolt is placed directly under frame, so it is the frame product's own NAUO too,
	# already counted among the six alongside frame's two bracket placements... spec §5
	# counts frame -> {left, right, bolt} and each bracket -> {plate, bolt, bolt 2}: 3 + 3).
	eq(text.count("=MANIFOLD_SOLID_BREP("), 2, "step_text() breps")
	eq(text.count("=PRODUCT("), 4, "step_text() products")
	eq(text.count("=NEXT_ASSEMBLY_USAGE_OCCURRENCE("), 6, "step_text() NAUOs")
	# Fact 3.
	ok(text.contains("'left'"), "step_text() is missing 'left'")
	ok(text.contains("'right'"), "step_text() is missing 'right'")
	ok(text.contains("'bolt 2'"), "step_text() is missing 'bolt 2'")

func test_an_assembly_reads_back_as_its_tree_at_its_frames():
	# Fact 11, structure only (world origins are Python's to check): the root named
	# "frame" with three children -- two "bracket" containers (the reader keys a
	# container by its placement, not by the product it shares, so "left" and "right"
	# come back as two distinct nodes) each holding one "plate" and two "bolt"s, plus one
	# more "bolt" directly under the root.
	var shared := _shared_assembly()
	var frame: CadaclysmAssembly = shared[3]
	var scene := frame.to_scene()
	if not ok(scene != null, "to_scene: " + Cadaclysm.last_error()):
		return
	var roots := scene.roots
	eq(roots.size(), 1)
	var root: CadaclysmNode = roots[0]
	eq(root.name, "frame")
	var children := root.children
	eq(children.size(), 3, "two bracket placements and the root bolt")
	var containers := []
	var root_bolts := []
	for c in children:
		if c.name == "bracket":
			containers.append(c)
		elif c.name == "bolt":
			root_bolts.append(c)
	eq(containers.size(), 2)
	eq(root_bolts.size(), 1)
	for container in containers:
		var names := []
		for c in container.children:
			names.append(c.name)
		names.sort()
		eq(names, ["bolt", "bolt", "plate"], "a read-back bracket holds one plate and two bolts")
	scene.close()

func test_a_late_placement_shows_wherever_the_assembly_is_placed():
	# Fact 4: one more bolt into the bracket, then a fresh count of 7 NAUOs -- placing
	# shares, not copies, so the bracket's growth shows up through both of `frame`'s
	# placements of it.
	var shared := _shared_assembly()
	var bolt: CadaclysmSolid = shared[0]
	var bracket: CadaclysmAssembly = shared[2]
	var frame: CadaclysmAssembly = shared[3]
	bracket.place(bolt, CadaclysmFrame.xy(Vector3(5, 15, 2)))
	eq(frame.step_text().count("=NEXT_ASSEMBLY_USAGE_OCCURRENCE("), 7)

func test_an_assembly_refuses_a_cycle_a_duplicate_a_mirror_and_emptiness():
	var shared := _shared_assembly()
	var bolt: CadaclysmSolid = shared[0]
	var bracket: CadaclysmAssembly = shared[2]
	var frame: CadaclysmAssembly = shared[3]
	# Fact 5: placing "frame" (which already places "bracket" as "left" and "right")
	# into "bracket" closes a cycle: bracket -> frame -> bracket.
	refuses(func(): return bracket.place(frame, XY), "bracket → frame → bracket")
	# Fact 6: an explicit name already taken is refused.
	refuses(func(): return frame.place(bracket, XY, "left"), "left")
	# Fact 7: a mirrored **raw** twelve-number frame -- not a CadaclysmFrame, which
	# refuses a left-handed triple itself, before `place` is ever called. A plain array
	# of numbers goes through `place`'s own `frame()` reader unchecked, so this is the
	# one way to drive a mirrored frame past GDScript and into the library's own
	# "right-handed and orthonormal" refusal.
	refuses(func(): return frame.place(bracket, [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, -1]), "right-handed and orthonormal")
	# Fact 8: an assembly that places nothing is refused at step_text().
	refuses(func(): return CadaclysmAssembly.create("x").step_text())
	# Fact 9: an outer assembly placing an empty sub-assembly is refused, naming it, even
	# though the empty one is not the root itself.
	var hollow := CadaclysmAssembly.create("hollow")
	var outer := CadaclysmAssembly.create("outer")
	outer.place(hollow, XY)
	refuses(func(): return outer.step_text(), "hollow")

func test_place_refuses_a_thing_that_is_neither_a_solid_nor_an_assembly():
	var top := CadaclysmAssembly.create("top")
	refuses(func(): return top.place("not a solid", XY), "expected a CadaclysmSolid or a CadaclysmAssembly")

func test_a_solids_name_rides_through_a_one_source_step_and_drops_at_two():
	# Fact 10: name rides through an operation with one source solid, is dropped by one
	# with two or more, and a fresh primitive has none -- Godot's `""` standing in for
	# Python's `None` (`CadaclysmSolid.closed` tells "no name" from "closed" apart).
	var bolt := CadaclysmSolid.cylinder(1, 6).named("bolt")
	eq(bolt.name, "bolt")
	eq(bolt.place(CadaclysmFrame.xy(Vector3(1, 2, 3))).name, "bolt", "place(...) keeps the name")
	eq(bolt.coloured([0.2, 0.2, 0.2]).name, "bolt", "coloured(...) keeps the name")
	var cube := CadaclysmSolid.cuboid(1, 1, 1)
	eq(bolt.join(cube).name, "", "join(...) has two sources, so the name is dropped")
	eq(cube.name, "", "a fresh cuboid has no name")
	refuses(func(): return cube.named(""), "name")

func test_assembly_create_close_and_get_name():
	refuses(func(): return CadaclysmAssembly.create(""), "name")
	var top := CadaclysmAssembly.create("top")
	eq(top.name, "top")
	top.close()
	eq(top.name, "", "a closed assembly reads its name as \"\"")
	refuses(func(): return top.place(CadaclysmSolid.cuboid(1, 1, 1), XY), "closed")
