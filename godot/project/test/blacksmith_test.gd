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
	ok(RegEx.create_from_string("cadaclysm[a-z_]*\\.(dll|so|dylib)$").search(path) != null, path)
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

func test_tolerances_unset_is_the_effective_one_and_the_defaults_stay():
	# hole2.3dm, a root sample (scripts/link-samples.py), declares an absolute 0.01 and one degree.
	var hole2 := root().path_join("hole2.3dm") if root() != "" else ""
	if hole2 != "" and FileAccess.file_exists(hole2):
		var scene := CadaclysmScene.open_with(hole2, {"convention": "native"})
		eq(scene.tolerances["absolute"], 0.01)
		eq(scene.tolerances["angular"], deg_to_rad(1.0), "one degree")
		scene.close()
	elif hole2 != "" and OS.get_environment("CADACLYSM_SAMPLES_OPTIONAL") == "":
		failures.append("%s: fixture missing: %s (scripts/link-samples.py)" % [_where(), hole2])
	var block := CadaclysmSolid.cuboid(10, 10, 10)
	var pin := CadaclysmSolid.cylinder(3, 20).translate(0, 0, -5)
	ok(is_nan(block.tolerances()["absolute"]) and is_nan(block.tolerances()["angular"]), "a built solid declares nothing")
	var at := CadaclysmBlacksmith.effective_tolerance([block, pin])
	ok(absf(at - 1e-4 * 20) < 1e-3, "effective %s" % at)
	eq(CadaclysmBlacksmith.effective_tolerance([]), 0.0)
	var unset := block.cut(pin, 0.0)
	var explicit := block.cut(pin, at)
	ok(is_nan(unset.tolerances()["absolute"]), "an unset cut declares nothing")
	eq(unset.mass(1e-7)["volume"], explicit.mass(1e-7)["volume"])
	eq(unset.mesh(0.0).index_count, explicit.mesh(CadaclysmBlacksmith.effective_tolerance([explicit])).index_count, "an unset mesh is the explicit-effective one")
	eq(block.cut(pin).mesh().index_count, block.cut(pin, 0.05).mesh(0.05).index_count, "the default is still 0.05")
	var loose := block.with_tolerances(0.1, deg_to_rad(1.0))
	eq(loose.tolerances()["absolute"], 0.1)
	eq(loose.tolerances()["angular"], deg_to_rad(1.0))
	eq(CadaclysmBlacksmith.effective_tolerance([loose, pin]), 0.1)
	eq(loose.cut(pin, 0.0).tolerances()["absolute"], 0.1, "a verb inherits the loosest declaration")
	ok(is_nan(block.vertex_tolerance(Vector3(5, 5, 5))), "a built cuboid records no vertex tolerance")
	refuses(func(): return block.with_tolerances(-1.0), "solid_with_tolerances: ")
	eq(block.with_tolerances(-1.0), null)

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

# ---- transforms (plan A4): CadaclysmTransform, CadaclysmQuaternion, Solid.transform,
# convert_to_nurbs, inexact_trims and the profile maps -- Python's figures, as the Rust
# SDK's `mod transforms` ports them.

const ORIGIN := [0, 0, 0]

# `refuses`, and the message must begin with `prefix`: the call's own name.
func refused(f: Callable, prefix: String) -> void:
	var message := refuses(f, prefix)
	ok(message.begins_with(prefix), "%s does not begin with %s" % [message, prefix])

func fxy() -> CadaclysmFrame:
	return CadaclysmFrame.xy()

func frame_at(x: float, y: float, z: float) -> CadaclysmFrame:
	return CadaclysmFrame.of([x, y, z, 1, 0, 0, 0, 1, 0, 0, 0, 1])

func det3(t: CadaclysmTransform) -> float:
	var r := t.rows
	return r[0] * (r[5] * r[10] - r[6] * r[9]) - r[1] * (r[4] * r[10] - r[6] * r[8]) + r[2] * (r[4] * r[9] - r[5] * r[8])

func kinds(solid: CadaclysmSolid) -> Array:
	var out := []
	for i in solid.faces:
		out.append(solid.face_kind(i))
	return out

func test_a_transform_is_sixteen_numbers_row_major_and_composes_right_to_left():
	var t := CadaclysmTransform.translation([1, 2, 3])
	eq(t.rows, PackedFloat64Array([1, 0, 0, 1, 0, 1, 0, 2, 0, 0, 1, 3, 0, 0, 0, 1]))
	var s := CadaclysmTransform.scale(ORIGIN, 2)
	ok(all_near(t.compose(s).point([1, 1, 1]), [3, 4, 5], 1e-12), "t after s")
	ok(all_near(s.compose(t).point([1, 1, 1]), [4, 6, 8], 1e-12), "s after t")
	var ts := t.compose(s)
	ok(all_near(ts.inverse().compose(ts).point([3, -4, 5]), [3, -4, 5], 1e-12), "inverse")
	eq(CadaclysmTransform.from_rows(t.rows).rows, t.rows)
	var r := t.rows
	var nested := [[r[0], r[1], r[2], r[3]], [r[4], r[5], r[6], r[7]], [r[8], r[9], r[10], r[11]], [r[12], r[13], r[14], r[15]]]
	eq(CadaclysmTransform.from_rows(nested).rows, t.rows, "four rows of four")
	eq(CadaclysmTransform.identity().rows, PackedFloat64Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]))
	refused(func(): return CadaclysmTransform.from_rows([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1]),
		"Transform: the bottom row must be 0 0 0 1 (a projective map is not affine)")
	refused(func(): return CadaclysmTransform.from_rows(range(15)), "Transform: a matrix is 16 numbers, got 15")
	var nan := CadaclysmTransform.identity().rows
	nan[5] = NAN
	refused(func(): return CadaclysmTransform.from_rows(nan), "Transform: not finite")
	refused(func(): return CadaclysmTransform.from_rows("nope"), "Transform: expected 16 numbers")
	eq(CadaclysmTransform.from_rows(nan), null)
	refused(func(): return CadaclysmTransform.scale_xyz(fxy(), 1, 1, 0).inverse(), "transform_inverse: the map is singular")
	eq(CadaclysmTransform.scale_xyz(fxy(), 1, 1, 0).inverse(), null)

func test_the_transform_constructors_match_their_closed_forms():
	var turn := CadaclysmTransform.rotation([1, 0, 0], [0, 0, 1], PI / 2)
	ok(all_near(turn.point([2, 0, 0]), [1, 1, 0], 1e-12), "rotation")
	ok(all_near(CadaclysmTransform.mirror(frame_at(0, 0, 5)).point([1, 2, 3]), [1, 2, 7], 1e-12), "mirror")
	ok(all_near(CadaclysmTransform.scale_xyz(fxy(), 2, 3, 4).point([1, 1, 1]), [2, 3, 4], 1e-12), "scale_xyz")
	var about := CadaclysmTransform.scale([1, 2, 3], 2)
	ok(all_near(about.point([2, 2, 3]), [3, 2, 3], 1e-12), "scale")
	ok(all_near(about.point([1, 2, 3]), [1, 2, 3], 1e-12), "scale fixes its centre")
	ok(all_near(CadaclysmTransform.shear(fxy(), [5, 0, 0], 0.5).point([0, 0, 2]), [1, 0, 2], 1e-12), "shear")
	ok(all_near(CadaclysmTransform.planar_projection(fxy()).point([1, 2, 3]), [1, 2, 0], 1e-12), "planar_projection")
	ok(all_near(CadaclysmTransform.project_along(fxy(), [1, 0, 1]).point([0, 0, 2]), [-2, 0, 0], 1e-12), "project_along")
	ok(all_near(CadaclysmTransform.plane_to_plane(fxy(), frame_at(1, 2, 3)).point(ORIGIN), [1, 2, 3], 1e-12), "plane_to_plane")
	ok(all_near(CadaclysmTransform.change_basis(frame_at(1, 2, 3), fxy()).point(ORIGIN), [1, 2, 3], 1e-12), "change_basis")
	refused(func(): return CadaclysmTransform.shear(fxy(), [0, 0, 1], 0.5), "transform_shear: the shear direction must lie in the plane")
	# Twelve raw numbers go to the library unchecked, so it refuses in its own words.
	refused(func(): return CadaclysmTransform.mirror([0, 0, 0, 1, 1e-3, 0, 0, 1, 0, 0, 0, 1]),
		"transform_mirror: the frame is not right-handed and orthonormal")
	refused(func(): return CadaclysmTransform.identity().point([1, 2]), "point: expected 3 numbers, got 2")

func test_maps_are_told_and_split():
	var turn := CadaclysmTransform.rotation([1, 2, 3], [1, 1, 0], 0.7)
	eq(turn.is_rigid(), true)
	near(turn.is_similarity(), 1.0, 1e-9)
	var big := CadaclysmTransform.scale(ORIGIN, 2.5).compose(turn)
	eq(big.is_rigid(), false)
	near(big.is_similarity(), 2.5, 1e-9)
	var split = big.decompose_similarity()
	near(split["k"], 2.5, 1e-9)
	eq(split["orthogonal"].is_rigid(), true)
	var scaled = CadaclysmTransform.scale([1, 2, 3], 2).decompose_similarity()
	ok(all_near(scaled["translation"], [-1, -2, -3], 1e-12), "similarity translation")
	near(scaled["k"], 2.0, 1e-12)
	eq(scaled["orthogonal"].rows, CadaclysmTransform.identity().rows)
	var rigid = turn.decompose_rigid()
	var r := turn.rows
	ok(all_near(rigid["translation"], [r[3], r[7], r[11]], 1e-12), "rigid translation")
	eq(rigid["orthogonal"].is_rigid(), true)
	eq(rigid.keys(), ["translation", "orthogonal"])
	eq(split.keys(), ["translation", "orthogonal", "k"])
	var stretch := CadaclysmTransform.scale_xyz(fxy(), 1, 2, 3)
	eq(stretch.is_similarity(), null)
	eq(Cadaclysm.last_error(), "", "none is not a refusal")
	eq(stretch.decompose_rigid(), null)
	eq(stretch.decompose_similarity(), null)
	var polar = CadaclysmTransform.mirror(fxy()).compose(stretch).decompose_affine()
	eq(polar.keys(), ["translation", "rotation", "axes", "stretch"])
	ok(all_near(polar["stretch"], [3, 2, 1], 1e-9), "stretch")
	# Only `rotation` carries the mirror; `axes` is a proper rotation -- which pins the order.
	near(det3(polar["rotation"]), -1.0, 1e-9, "det(rotation)")
	near(det3(polar["axes"]), 1.0, 1e-9, "det(axes)")
	eq(CadaclysmTransform.planar_projection(fxy()).decompose_affine(), null)
	eq(Cadaclysm.last_error(), "", "none is not a refusal")
	refused(func(): return turn.is_rigid(-1), "transform_is_rigid: the tolerance must be finite and not negative")
	eq(turn.is_rigid(-1), false)
	refused(func(): return turn.is_similarity(-1), "transform_is_similarity: the tolerance must be finite and not negative")
	eq(turn.is_similarity(-1), null)
	refused(func(): return turn.decompose_rigid(-1), "transform_is_rigid: ")
	refused(func(): return turn.decompose_similarity(-1), "transform_is_similarity: ")

func test_a_quaternion_turns_as_its_transform_does():
	var q := CadaclysmQuaternion.from_axis_angle([0, 0, 2], PI / 2)
	ok(all_near(q.components, [cos(PI / 4), 0, 0, sin(PI / 4)], 1e-12), "from_axis_angle")
	near(q.angle(), PI / 2, 1e-12)
	ok(all_near(q.axis(), [0, 0, 1], 1e-12), "axis")
	ok(all_near(q.to_transform([1, 0, 0]).point([2, 0, 0]), [1, 1, 0], 1e-12), "to_transform about a centre")
	var doubled := CadaclysmQuaternion.create(2 * q.w, 2 * q.x, 2 * q.y, 2 * q.z)
	ok(all_near(doubled.to_transform().point([1, 0, 0]), [0, 1, 0], 1e-12), "a non-unit quaternion is normalised")
	ok(all_near(CadaclysmQuaternion.from_transform(q.to_transform()).components, q.components, 1e-12), "from_transform")
	near(CadaclysmQuaternion.slerp(CadaclysmQuaternion.identity(), q, 0.25).angle(), PI / 8, 1e-12)
	ok(all_near(q.multiply(q.conjugate()).components, [1, 0, 0, 0], 1e-12), "q * conjugate")
	eq(CadaclysmQuaternion.create(0, 0, 0, 2).normalized().components, PackedFloat64Array([0, 0, 0, 1]))
	eq(CadaclysmQuaternion.identity().axis(), null)
	refused(func(): return CadaclysmQuaternion.create(0, 0, 0, 0).to_transform(), "quaternion_to_transform: the quaternion is zero")
	refused(func(): return CadaclysmQuaternion.from_transform(CadaclysmTransform.mirror(fxy())), "quaternion_from_transform: ")
	refused(func(): return CadaclysmQuaternion.create(INF, 0, 0, 0), "Quaternion: not finite")
	# The product's sign pattern, against Python's literal.
	var about_x := CadaclysmQuaternion.from_axis_angle([1, 0, 0], PI / 2)
	var about_y := CadaclysmQuaternion.from_axis_angle([0, 1, 0], PI / 2)
	ok(all_near(about_x.multiply(about_y).components, [0.5, 0.5, 0.5, 0.5], 1e-12), "x then y")
	# Every term of every component non-zero, so any one sign flipped shows.
	eq(CadaclysmQuaternion.create(1, 2, 3, 4).multiply(CadaclysmQuaternion.create(5, 6, 7, 8)).components, PackedFloat64Array([-60, 12, 30, 24]))
	# Two general rotations: the product turns as the composed transforms do.
	var a := CadaclysmQuaternion.from_axis_angle([1, 2, 3], 0.7)
	var b := CadaclysmQuaternion.from_axis_angle([-2, 0.5, 1], 1.9)
	ok(all_near(a.multiply(b).to_transform().rows, a.to_transform().compose(b.to_transform()).rows, 1e-12), "a * b is a after b")

func test_a_quaternion_far_from_unit_length_normalises_like_the_abi():
	var half := sqrt(0.5)
	for k in [1e200, 1e-170]:
		eq(CadaclysmQuaternion.create(k, 0, 0, 0).normalized().components, PackedFloat64Array([1, 0, 0, 0]), str(k))
		eq(CadaclysmQuaternion.create(0, 0, 0, -k).normalized().components, PackedFloat64Array([0, 0, 0, -1]), str(k))
		ok(all_near(CadaclysmQuaternion.create(k, k, 0, 0).normalized().components, [half, half, 0, 0], 1e-12), str(k))
		var length: float = CadaclysmQuaternion.create(k, k, 0, 0).length()
		ok(absf((length - k * sqrt(2.0)) / (k * sqrt(2.0))) <= 1e-15, "%s: length %s" % [k, length])
		near(CadaclysmQuaternion.create(k, k, 0, 0).angle(), PI / 2, 1e-12, str(k))
		ok(all_near(CadaclysmQuaternion.create(0, k, k, 0).axis(), [half, half, 0], 1e-12), str(k))
	refused(func(): return CadaclysmQuaternion.create(0, 0, 0, 0).normalized(), "Quaternion.normalized: the quaternion is zero")

func test_a_solid_takes_any_affine_map():
	var block := CadaclysmSolid.cuboid(1, 2, 3)
	eq(block.inexact_trims, 0, "a solid no map made has lost nothing")
	var stretched := block.transform(CadaclysmTransform.scale_xyz(fxy(), 2, 3, 0.5))
	var bb := stretched.raw_bounds(0.05)
	ok(all_near([bb[3] - bb[0], bb[4] - bb[1], bb[5] - bb[2]], [2, 6, 1.5], 1e-9), "extents %s" % [bb])
	eq(stretched.inexact_trims, 0)
	var moved := block.transform(CadaclysmTransform.translation([1, 0, 0]).rows)
	ok(moved != null, "16 numbers")
	eq(moved.inexact_trims, 0)
	var sheared := CadaclysmSolid.cylinder(1, 2).transform(CadaclysmTransform.shear(fxy(), [1, 0, 0], 0.5))
	var volume: float = sheared.mass(1e-7)["volume"]
	ok(absf((volume - TAU) / TAU) < 1e-6, "volume %s" % volume)
	ok("nurbs" in kinds(sheared), str(kinds(sheared)))
	refused(func(): return block.transform(CadaclysmTransform.scale_xyz(fxy(), 1, 1, 0)), "solid_transform: a singular map flattens the solid")
	refused(func(): return block.transform(range(15)), "Transform: a matrix is 16 numbers, got 15")
	refused(func(): return block.transform("nope"), "transform: expected a CadaclysmTransform or 16 numbers")

func test_a_mapped_solid_keeps_its_colours_and_name():
	var can := CadaclysmSolid.cylinder(1, 2).coloured("#808080").named("can")
	var side: int = count_faces(can, "cylinder")[0]
	can = can.coloured([0.2, 0.4, 1.0], side)
	var shear := CadaclysmTransform.shear(fxy(), [1, 0, 0], 0.5)
	for out in [can.transform(shear), can.convert_to_nurbs()]:
		eq(out.faces, can.faces)
		eq(out.face_colour(side), Color(0.2, 0.4, 1.0))
		for i in out.faces:
			if i != side:
				eq(out.face_colour(i), can.colour, "face %d" % i)
		eq(out.name, "can")

func test_a_solid_converts_to_nurbs_at_each_level():
	var can := CadaclysmSolid.cylinder(1, 2)
	var every := can.convert_to_nurbs()
	ok(kinds(every).all(func(k): return k == "nurbs"), str(kinds(every)))
	eq(every.inexact_trims, 0)
	var analytic := kinds(can.convert_to_nurbs("analytic"))
	ok("plane" in analytic and "nurbs" in analytic, str(analytic))
	var procedural := kinds(can.convert_to_nurbs("procedural"))
	ok("plane" in procedural and "cylinder" in procedural, str(procedural))
	refused(func(): return can.convert_to_nurbs("x"), "convert_to_nurbs: level 'x' is not \"procedural\", \"analytic\" or \"all\"")
	eq(can.convert_to_nurbs("x"), null)

# ---- value geometry (plan B3): CadaclysmInterval, the frame verbs, the nine values --------
# Python's TestInterval ... TestCuboidValue, same figures. Doubles that cross as doubles
# compare to EXACT; a Vector3 holds floats, so a point that crosses as one compares to FLOATS.
# The Rhino records are the file B1's rhino_values.rs reads.

#: Right-handed and exact: x = world y, y = world z, z = world x, off the origin.
const YZX := [1, 2, 3, 0, 1, 0, 0, 0, 1, 1, 0, 0]
const EXACT := 1e-12
const FLOATS := 1e-5
const NURBS_FOOT := 1e-7
const VALUE_VECTORS := "crates/cadaclysm/tests/fixtures/rhino/value_vectors.txt"

# The repository checkout holding the project: the ancestor with crates/cadaclysm/Cargo.toml.
static func kernel_root() -> String:
	var dir := ProjectSettings.globalize_path("res://").trim_suffix("/")
	while dir != "" and dir.get_base_dir() != dir:
		if FileAccess.file_exists(dir.path_join("crates/cadaclysm/Cargo.toml")):
			return dir
		dir = dir.get_base_dir()
	return ""

# The Rhino records, "case what" -> its words; null outside a checkout (skipped, with the
# reason printed). In a checkout a missing file fails.
func vectors():
	var r := kernel_root()
	if r == "":
		print("      skipped: no repository checkout above the project, so no ", VALUE_VECTORS)
		return null
	var path := r.path_join(VALUE_VECTORS)
	if not ok(FileAccess.file_exists(path), "the Rhino vectors are missing: " + path):
		return null
	var records := {}
	for raw in FileAccess.get_file_as_string(path).split("\n"):
		var line := raw.strip_edges()
		if line == "" or line.begins_with("#"):
			ok(not line.contains("ERROR"), line)
			continue
		ok(not line.contains("ERROR"), line)
		var words := line.split(" ", false)
		var key := words[0] + " " + words[1]
		ok(not records.has(key), "a record twice: " + key)
		records[key] = words.slice(2)
	ok(records.size() > 100, "records read: %d" % records.size())
	return records

func nums(r: Dictionary, case: String, what: String) -> Array:
	var out := []
	for w in r[case + " " + what]:
		out.append(String(w).to_float())
	return out

func xyz(p: Vector3) -> Array:
	return [p.x, p.y, p.z]

func iv(t0: float, t1: float) -> CadaclysmInterval:
	return CadaclysmInterval.create(t0, t1)

# `got` is an interval holding exactly `want`.
func is_iv(got, want: Array, message := "") -> bool:
	if got == null:
		return ok(false, "%s: null, not %s" % [message, want])
	return eq([got.t0, got.t1], [float(want[0]), float(want[1])], message)

# `refuses`, and the message is exactly `message`.
func refused_as(f: Callable, message: String) -> void:
	eq(refuses(f, message), message)

func queries(r: Dictionary, shape: String) -> Array:
	var out := []
	for i in 12:
		var case := "%s_%02d" % [shape, i]
		out.append([case, nums(r, case, "query")])
	return out

func dist(a: Array, b: Array) -> float:
	return sqrt((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2)

# A foot Rhino found by iteration on a NURBS form: the distance to 1e-12, never beaten by
# Rhino's, the point to 1e-7 -- as B1's `nurbs_foot`.
func nurbs_foot(label: String, q: Array, ours: Array, rhino: Array) -> void:
	var d := dist(q, ours)
	var dr := dist(q, rhino)
	ok(d <= dr + EXACT and absf(d - dr) <= EXACT, "%s: %s against %s" % [label, d, dr])
	ok(all_near(ours, rhino, NURBS_FOOT), "%s: %s against %s" % [label, ours, rhino])

func test_an_interval_measures_keeping_its_orientation():
	var up := iv(2, 6)
	var down := iv(6, 2)
	eq([up.length(), down.length()], [4.0, -4.0])
	eq([up.mid(), down.mid()], [4.0, 4.0])
	eq([up.min(), up.max(), down.min(), down.max()], [2.0, 6.0, 2.0, 6.0])
	ok(up.is_increasing() and not down.is_increasing() and not iv(3, 3).is_increasing())
	ok(iv(3, 3).is_singleton() and not up.is_singleton())
	ok(up.swapped().equals(down) and down.swapped().equals(up))
	eq(down.values, PackedFloat64Array([6, 2]))
	eq([down.t0, down.t1], [6.0, 2.0])

func test_an_intervals_set_operations_answer_increasing_and_touching_is_a_singleton():
	var up := iv(2, 6)
	var down := iv(6, 2)
	is_iv(up.grown(9), [2, 9], "grown")
	is_iv(down.grown(-1), [-1, 6], "grown down")
	ok(down.grown(3).equals(up), "grown inside")
	is_iv(up.union(iv(8, 7)), [2, 8], "union")
	is_iv(down.union([1, 3]), [1, 6], "union of a pair")
	is_iv(down.intersect(iv(9, 4)), [4, 6], "intersect")
	is_iv(up.intersect(iv(3, 5)), [3, 5], "intersect inside")
	eq(up.intersect(iv(7, 9)), null)
	eq(down.intersect(iv(1, 1.5)), null)
	is_iv(iv(0, 1).intersect(iv(1, 2)), [1, 1], "touching")
	is_iv(iv(2, 1).intersect(iv(0, 1)), [1, 1], "touching down")
	for x in [up, down]:
		ok(x.contains(2) and x.contains(6) and x.contains(4.5))
		ok(not x.contains(1.999) and not x.contains(6.001))
	refused_as(func(): return up.grown(INF), "Interval: not finite")

func test_an_intervals_parameters_round_trip():
	eq(iv(2, 6).parameter_at(0.25), 3.0)
	eq(iv(6, 2).parameter_at(0.25), 5.0)
	for x in [iv(2, 6), iv(6, 2), iv(-1.5, 0.7)]:
		for s in [-0.5, 0.0, 0.3, 1.0, 2.0]:
			near(x.normalized_parameter_at(x.parameter_at(s)), s, 1e-15)
	eq(iv(3, 3).normalized_parameter_at(3), null)

func test_an_interval_is_a_value():
	var a := iv(1, 2)
	ok(a.equals(iv(1.0, 2.0)) and not a.equals(iv(2, 1)) and not a.equals([1.0, 2.0]))
	eq(str(a), "Interval(1.0, 2.0)")
	ok(CadaclysmInterval.of([1, 2]).equals(a) and CadaclysmInterval.of(a).equals(a))
	ok(CadaclysmInterval.of(Vector2(1, 2)).equals(a))
	refused_as(func(): return CadaclysmInterval.create(NAN, 1), "Interval: not finite")
	eq(CadaclysmInterval.create(NAN, 1), null)
	refused_as(func(): return CadaclysmInterval.of([1, 2, 3]), "Interval: an interval is 2 numbers, got 3")

func test_intervals_match_rhino():
	var r = vectors()
	if r == null:
		return
	for name in ["apart", "dec_dec", "inc_dec", "inc_inc", "touch"]:
		var case: String = "interval_" + name
		var args := nums(r, case, "args")
		var a := iv(args[0], args[1])
		var b := iv(args[2], args[3])
		is_iv(a.union(b), nums(r, case, "union"), case)
		if r[case + " intersection"] == PackedStringArray(["none"]):
			eq(a.intersect(b), null, case)
		else:
			is_iv(a.intersect(b), nums(r, case, "intersection"), case)
	for name in ["inc_inside", "inc_out", "dec_low", "dec_inside"]:
		var args := nums(r, "grow_" + name, "args")
		is_iv(iv(args[0], args[1]).grown(args[2]), nums(r, "grow_" + name, "grown"), name)
	for name in ["inc", "dec"]:
		for k in 4:
			var case := "param_%s_%d" % [name, k]
			var args := nums(r, case, "args")
			var x := iv(args[0], args[1])
			var t: float = args[2]
			near(x.parameter_at(t), nums(r, case, "parameter_at")[0], EXACT, case)
			near(x.normalized_parameter_at(2.5 + t), nums(r, case, "normalized_at")[0], EXACT, case)

func test_the_frame_verbs_match_rhino():
	var r = vectors()
	if r == null:
		return
	var p := CadaclysmFrame.of(nums(r, "plane", "frame"))
	ok(p.flipped() is CadaclysmFrame)
	ok(all_near(p.flipped().raw, nums(r, "plane", "flip"), EXACT), "flip")
	ok(all_near(p.rotated(0.6, [1, -1, 0.5]).raw, nums(r, "plane", "rotate"), EXACT), "rotate")
	for item in queries(r, "plane"):
		var case: String = item[0]
		var q: Array = item[1]
		ok(all_near(xyz(p.to_local(q)), nums(r, case, "remap"), FLOATS), case)
		ok(all_near(xyz(p.closest_point(q)), nums(r, case, "closest"), FLOATS), case)
		near(p.distance_to(q), nums(r, case, "distance")[0], EXACT, case)
	refused_as(func(): return p.rotated(0.6, [0, 0, 0]), "transform_rotation: the axis has no direction")
	refused_as(func(): return p.to_local([1, 2]), "to_local: a point is 3 numbers, got 2")

func test_frame_fit_matches_rhino_and_refuses_in_the_librarys_words():
	var r = vectors()
	if r == null:
		return
	var flat := nums(r, "fit", "points")
	var pts := []
	for k in range(0, flat.size(), 3):
		pts.append(flat.slice(k, k + 3))
	var fit = CadaclysmFrame.fit(pts)
	var got: CadaclysmFrame = fit["frame"]
	var want := CadaclysmFrame.of(nums(r, "fit", "frame"))
	var gz := got.raw.slice(9)
	var wz := want.raw.slice(9)
	var sign := -1.0 if gz[0] * wz[0] + gz[1] * wz[1] + gz[2] * wz[2] < 0 else 1.0
	ok(all_near([sign * gz[0], sign * gz[1], sign * gz[2]], wz, EXACT), "normal")
	near(want.distance_to(got.raw.slice(0, 3)), 0, EXACT, "origins")
	near(got.distance_to(want.raw.slice(0, 3)), 0, EXACT, "origins")
	near(fit["deviation"], nums(r, "fit", "deviation")[0], EXACT, "deviation")
	ok(CadaclysmFrame.fit(PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)])) is Dictionary)
	refused_as(func(): return CadaclysmFrame.fit(pts.slice(0, 2)), "frame_fit: needs three points")
	eq(CadaclysmFrame.fit(pts.slice(0, 2)), null)
	refused_as(func(): return CadaclysmFrame.fit([[0, 0, 0], [1, 1, 1], [2, 2, 2]]), "frame_fit: the points lie on one line")

func test_a_bad_curve_value_is_refused_by_value_check():
	refused_as(func(): return CadaclysmCircle.create(XY, 0), "value_check: the radius must be positive")
	refused_as(func(): return CadaclysmLine.create([1, 1, 1], [1, 1, 1]), "value_check: the line has no length")
	refused_as(func(): return CadaclysmArc.create(XY, 1, [0, 7]), "value_check: the angle must increase by at most a full turn")
	refused_as(func(): return CadaclysmArc.create(XY, 1, iv(1, 0)), "value_check: the angle must increase by at most a full turn")
	refused_as(func(): return CadaclysmEllipse.create(XY, 3, -1), "value_check: the second radius must be positive")
	refused_as(func(): return CadaclysmCircle.create([0, 0, 0, 1, 1e-3, 0, 0, 1, 0, 0, 0, 1], 1),
		"value_check: the frame is not right-handed and orthonormal")
	eq(CadaclysmCircle.create(XY, 0), null)
	# The raw array's count is checked first, in the library's own sentence.
	refused_as(func(): return CadaclysmCircle.from_values(range(12)), "value_check: a circle is 13 numbers, got 12")
	ok(CadaclysmCircle.from_values(XY + [2]).equals(CadaclysmCircle.create(XY, 2)))
	# 1e-7 off square is squared up, not refused.
	var near_square := CadaclysmCircle.create([0, 0, 0, 1, 1e-7, 0, 0, 1, 0, 0, 0, 1], 1)
	var f := near_square.frame.raw
	ok(absf(f[3] * f[6] + f[4] * f[7] + f[5] * f[8]) < 1e-15 and f[4] != 0, str(f))

func test_curve_values_answer_b1s_figures():
	var unit := CadaclysmCircle.create(XY, 1)
	ok(v3near(unit.point_at(PI / 2), Vector3(0, 1, 0)))
	ok(v3near(unit.tangent_at(0), Vector3(0, 1, 0)))
	var line := CadaclysmLine.create([0, 0, 0], [1, 2, 3])
	eq(line.point_at(0.5), Vector3(0.5, 1, 1.5))
	eq(line.length(), sqrt(14))
	eq([line.start, line.end], [Vector3(0, 0, 0), Vector3(1, 2, 3)])
	ok(v3near(line.tangent_at(0), Vector3(1, 2, 3) / sqrt(14)))
	var quarter := CadaclysmArc.create(XY, 2, [0, PI / 2])
	eq(quarter.length(), PI)
	is_iv(quarter.angle, [0, PI / 2], "angle")
	ok(v3near(quarter.start, Vector3(2, 0, 0)) and v3near(quarter.end, Vector3(0, 2, 0)))
	ok(v3near(quarter.mid, Vector3(sqrt(2), sqrt(2), 0)))
	# On the axis the foot is a pick: t = 0, not unique.
	var off := unit.closest_point([2, 0, 5])
	eq([off.t, off.raw_point, off.unique], [0.0, PackedFloat64Array([1, 0, 0]), true])
	var axis := unit.closest_point([0, 0, 5])
	eq([axis.t, axis.raw_point, axis.unique], [0.0, PackedFloat64Array([1, 0, 0]), false])
	eq(axis.point, Vector3(1, 0, 0))
	near(unit.distance_to([2, 0, 5]), sqrt(26), 1e-12)
	eq(CadaclysmLine.create([1, 5, 0], [0, 2, 3]).bounds(), AABB(Vector3(0, 2, 0), Vector3(1, 3, 3)))
	near(CadaclysmEllipse.create(XY, 3, 1).length(), 13.364893220555258, 13.364893220555258 * 1e-12)
	refused_as(func(): return unit.closest_point([1, 2]), "curve_value_closest_point: a point is 3 numbers, got 2")
	ok(is_nan(unit.distance_to("x")))

func test_curve_value_constructors_and_transforms():
	var a := [1, 0, 0]
	var b := [0, 1, 0]
	var c := [-1, 0, 0]
	var circle := CadaclysmCircle.through(a, b, c)
	ok(circle is CadaclysmCircle and all_near(circle.values, XY + [1], 1e-15), str(circle))
	ok(all_near(CadaclysmArc.through(a, b, c).values, XY + [1, 0, PI], 1e-15))
	var arc := CadaclysmArc.from_start_tangent_end(a, [0, 1, 0], c)
	ok(arc is CadaclysmArc and all_near(arc.values, XY + [1, 0, PI], 1e-15), str(arc))
	refused_as(func(): return CadaclysmCircle.through(a, a, c), "circle_through: the points are coincident or collinear")
	refused_as(func(): return CadaclysmArc.from_start_tangent_end(a, [0, 0, 0], c),
		"arc_from_start_tangent_end: the tangent is zero or the end lies on the tangent line")
	ok(CadaclysmEllipse.from_circle(CadaclysmCircle.create(XY, 2)).equals(CadaclysmEllipse.create(XY, 2, 2)))
	ok(CadaclysmCircle.create(XY, 1).transform(CadaclysmTransform.scale(ORIGIN, 2)).equals(CadaclysmCircle.create(XY, 2)))
	var stretch := CadaclysmTransform.scale_xyz(fxy(), 1, 3, 1)
	refused_as(func(): return CadaclysmCircle.create(XY, 1).transform(stretch),
		"value_transform: a circle takes only a similarity (use ellipse_from_circle)")
	var e := CadaclysmEllipse.from_circle(CadaclysmCircle.create(XY, 1)).transform(stretch.rows)
	ok(e is CadaclysmEllipse and all_near([e.r1, e.r2], [3, 1], 1e-15), str(e))
	var moved := CadaclysmLine.create([0, 0, 0], [1, 0, 0]).transform(CadaclysmTransform.translation([0, 0, 2]))
	ok(moved.equals(CadaclysmLine.create([0, 0, 2], [1, 0, 2])), str(moved))

func test_values_compare_by_kind_and_array():
	var c := CadaclysmCircle.create(YZX, 2)
	eq(c.values, PackedFloat64Array(YZX + [2]))
	eq(c.radius, 2.0)
	eq(c.frame.raw, CadaclysmFrame.of(YZX).raw)
	ok(c.equals(CadaclysmCircle.create(CadaclysmFrame.of(YZX), 2.0)))
	ok(not c.equals(CadaclysmSphere.create(YZX, 2)), "a circle never equals a sphere of the same numbers")
	ok(not c.equals(CadaclysmCircle.create(YZX, 3)) and not c.equals(null) and not c.equals(c.values))
	ok(str(c).begins_with("Circle["), str(c))

func test_lines_circles_and_arcs_match_rhino():
	var r = vectors()
	if r == null:
		return
	var ends := nums(r, "line", "ends")
	var line := CadaclysmLine.create(ends.slice(0, 3), ends.slice(3, 6))
	near(line.length(), nums(r, "line", "length")[0], EXACT, "line length")
	ok(all_near(xyz(line.tangent_at(0.5)), nums(r, "line", "tangent"), FLOATS), "line tangent")
	for k in 5:
		var n := nums(r, "line_at_%d" % k, "point")
		ok(all_near(xyz(line.point_at(n[0])), n.slice(1), FLOATS), "line_at_%d" % k)
	for item in queries(r, "line"):
		ok(all_near(line.closest_point(item[1]).raw_point, nums(r, item[0], "closest"), EXACT), item[0])

	var circle := CadaclysmCircle.create(nums(r, "circle", "frame"), nums(r, "circle", "radius")[0])
	near(circle.length(), nums(r, "circle", "length")[0], EXACT, "circle length")
	for k in 5:
		var n := nums(r, "circle_at_%d" % k, "point")
		ok(all_near(xyz(circle.point_at(n[0])), n.slice(1, 4), FLOATS), "circle_at_%d" % k)
		ok(all_near(xyz(circle.tangent_at(n[0])), n.slice(4, 7), FLOATS), "circle_at_%d tangent" % k)
	for item in queries(r, "circle"):
		var want := nums(r, item[0], "closest")
		var foot := circle.closest_point(item[1])
		ok(foot.unique, item[0])
		near(foot.t, fposmod(want[0], TAU), EXACT, item[0])
		ok(all_near(foot.raw_point, want.slice(1), EXACT), item[0])

	var arc := CadaclysmArc.create(nums(r, "arc", "frame"), nums(r, "arc", "radius")[0], nums(r, "arc", "angle"))
	near(arc.length(), nums(r, "arc", "length")[0], EXACT, "arc length")
	for k in 4:
		var n := nums(r, "arc_at_%d" % k, "point")
		ok(all_near(xyz(arc.point_at(n[0])), n.slice(1, 4), FLOATS), "arc_at_%d" % k)
		ok(all_near(xyz(arc.tangent_at(n[0])), n.slice(4, 7), FLOATS), "arc_at_%d tangent" % k)
	for item in queries(r, "arc"):
		var want := nums(r, item[0], "closest")
		var foot := arc.closest_point(item[1])
		near(foot.t, want[0], EXACT, item[0])
		ok(all_near(foot.raw_point, want.slice(1), EXACT), item[0])

func test_an_edges_curve_is_its_value():
	for rim in CadaclysmSolid.cylinder(5, 3).edges.filter(func(e): return e.kind == "circle"):
		var v = rim.curve.value()
		ok(v is CadaclysmCircle, str(v))
		near(v.radius, 5, 1e-9)
		var z: float = v.frame.raw[2]
		ok(absf(z) < 1e-9 or absf(z - 3) < 1e-9, str(z))
	for e in CadaclysmSolid.cuboid(2, 4, 6).edges:
		var v = e.curve.value()
		ok(v is CadaclysmLine, str(v))
		var s: PackedFloat64Array = e.raw_segments
		var raw: PackedFloat64Array = v.values
		for end in [raw.slice(0, 3), raw.slice(3, 6)]:
			var found := false
			for k in range(0, s.size(), 3):
				found = found or all_near(s.slice(k, k + 3), end)
			ok(found, "%s ends on its edge" % v)
	var cube := CadaclysmSolid.cuboid(10, 10, 10)
	var upright := cube.edges.filter(func(e): return e.direction != null and absf(absf(e.direction.z) - 1) < 1e-6)
	var rounded := cube.fillet([upright[0]], 2.0)
	var arcs := rounded.edges.filter(func(e): return e.kind == "circle")
	eq(arcs.size(), 2)
	for e in arcs:
		var v = e.curve.value()
		ok(v is CadaclysmArc, str(v))
		near(v.radius, 2, 1e-9)
		near(v.angle.length(), PI / 2, 1e-9)
		var segments: PackedVector3Array = e.segments
		var vertices := [segments[0], segments[segments.size() - 1]]
		ok(vertices.any(func(p): return v3near(v.start, p, FLOATS)), "%s starts on a vertex" % v)
		ok(vertices.any(func(p): return v3near(v.end, p, FLOATS)), "%s ends on a vertex" % v)
	var square := [[0, 0], [10, 0], [10, 10], [0, 10]]
	var spline := CadaclysmSolid.extrude(CadaclysmProfile.spline(square, 3, PackedFloat64Array(), true), XY, 2)
	var nurbs := spline.edges.filter(func(e): return e.kind == "nurbs")
	ok(nurbs.size() > 0)
	for e in nurbs:
		eq(e.curve.value(), null)

func test_a_bad_surface_value_is_refused_by_value_check():
	refused_as(func(): return CadaclysmCylinder.create(XY, 1, [2, 1]), "value_check: the height must increase")
	refused_as(func(): return CadaclysmTorus.create(XY, 1, 1), "value_check: the minor radius must be less than the major")
	refused_as(func(): return CadaclysmCone.create(XY, 1, 0), "value_check: the height must be positive")
	refused_as(func(): return CadaclysmSphere.create(XY, NAN), "value_check: not finite")

func test_surface_values_answer_b1s_figures():
	var sphere := CadaclysmSphere.create(XY, 2)
	ok(v3near(sphere.point_at(0, PI / 2), Vector3(0, 0, 2)))
	var cyl := CadaclysmCylinder.create(XY, 1, [-1, 2])
	is_iv(cyl.height, [-1, 2], "height")
	ok(v3near(cyl.normal_at(PI / 2, 0), Vector3(0, 1, 0)))
	ok(v3near(CadaclysmTorus.create(XY, 3, 1).point_at(0, 0), Vector3(4, 0, 0)))
	var foot := sphere.closest_point([0, 0, 5])
	ok(foot is CadaclysmSurfaceFoot and foot.unique)
	ok(all_near([foot.u, foot.v] + Array(foot.raw_point), [0, PI / 2, 0, 0, 2], 1e-15), str(foot))
	ok(not sphere.closest_point([0, 0, 0]).unique, "the centre is a pick")
	near(sphere.distance_to([0, 0, 5]), 3, 1e-12)
	var d := cyl.domain()
	eq(d.size(), 2)
	is_iv(d[0], [0, TAU], "u")
	is_iv(d[1], [-1, 2], "v")
	var cone := CadaclysmCone.create(XY, 1, 2).domain()
	is_iv(cone[0], [0, TAU], "cone u")
	is_iv(cone[1], [0, 2], "cone v")
	near(sphere.volume(), 32 * PI / 3, 1e-13)
	near(sphere.area(), 16 * PI, 1e-13)
	ok(CadaclysmTorus.create(XY, 3, 1).contains([3, 0, 0.5]) and not sphere.contains([0, 0, 2.5]))
	ok(sphere.contains([0, 0, 2.5], 0.5))
	refused_as(func(): return sphere.contains([0, 0, 0], -1), "solid_value_contains: the tolerance must be finite and not negative")
	eq(sphere.contains([0, 0, 0], -1), false)
	eq(sphere.bounds(), AABB(Vector3(-2, -2, -2), Vector3(4, 4, 4)))
	refused_as(func(): return sphere.transform(CadaclysmTransform.scale_xyz(fxy(), 1, 3, 1)), "value_transform: a sphere takes only a similarity")
	ok(sphere.transform(CadaclysmTransform.translation([1, 0, 0])).equals(CadaclysmSphere.create(CadaclysmFrame.xy(Vector3(1, 0, 0)), 2)))
	var sheet := cyl.to_nurbs_sheet()
	ok(sheet is CadaclysmSolid)
	eq(sheet.faces, 1)

func test_each_shape_becomes_a_solid_of_its_volume():
	var shapes := [[CadaclysmSphere.create(XY, 2), 32 * PI / 3], [CadaclysmCylinder.create(XY, 1, [-1, 2]), 3 * PI],
		[CadaclysmCone.create(XY, 1, 2), 2 * PI / 3], [CadaclysmTorus.create(XY, 3, 1), 6 * PI * PI],
		[CadaclysmCuboid.create(YZX, [0, 1], [0, 2], [0, 3]), 6.0]]
	for item in shapes:
		var shape = item[0]
		var volume: float = item[1]
		var solid = shape.to_solid()
		ok(solid is CadaclysmSolid, str(shape))
		near(solid.mass(1e-9)["volume"], volume, volume * 1e-6, str(shape))
		near(shape.volume(), volume, volume * 1e-12, str(shape))

func test_spheres_tori_cylinders_and_cones_match_rhino():
	var r = vectors()
	if r == null:
		return
	var sphere := CadaclysmSphere.create(nums(r, "sphere", "frame"), nums(r, "sphere", "radius")[0])
	for item in queries(r, "sphere"):
		var want := nums(r, item[0], "closest")
		var foot := sphere.closest_point(item[1])
		ok(all_near([foot.u, foot.v], [fposmod(want[0], TAU), want[1]], EXACT), item[0])
		ok(all_near(foot.raw_point, want.slice(2), EXACT), item[0])
	var radii := nums(r, "torus", "radii")
	var torus := CadaclysmTorus.create(nums(r, "torus", "frame"), radii[0], radii[1])
	for item in queries(r, "torus"):
		var foot := torus.closest_point(item[1])
		ok(foot.unique, item[0])
		nurbs_foot(item[0], item[1], Array(foot.raw_point), nums(r, item[0], "closest"))
	var cyl := CadaclysmCylinder.create(nums(r, "cylinder", "frame"), nums(r, "cylinder", "radius")[0], nums(r, "cylinder", "height"))
	for item in queries(r, "cylinder"):
		nurbs_foot(item[0], item[1], Array(cyl.closest_point(item[1]).raw_point), nums(r, item[0], "closest"))
	var size := nums(r, "cone", "size")
	var cone := CadaclysmCone.create(nums(r, "cone", "frame"), size[0], size[1])
	for item in queries(r, "cone"):
		nurbs_foot(item[0], item[1], Array(cone.closest_point(item[1]).raw_point), nums(r, item[0], "closest"))

func test_a_cuboid_is_built_bounded_and_fitted_around_points():
	var box := CadaclysmCuboid.create(YZX, [0, 1], [0, 2], iv(0, 3))
	is_iv(box.x, [0, 1], "x")
	is_iv(box.y, [0, 2], "y")
	is_iv(box.z, [0, 3], "z")
	# x along world y (0..1), y along world z (0..2), z along world x (0..3), from (1, 2, 3).
	eq(box.bounds(), AABB(Vector3(1, 2, 3), Vector3(3, 1, 2)))
	ok(CadaclysmCuboid.from_bounds([0, 0, 0], [1, 2, 3]).equals(CadaclysmCuboid.create(XY, [0, 1], [0, 2], [0, 3])))
	refused_as(func(): return CadaclysmCuboid.from_bounds([0, 0, 0], [1, 0, 3]), "cuboid_from_bounds: the bounds must increase along every axis")
	refused_as(func(): return CadaclysmCuboid.create(XY, [0, 1], [2, 2], [0, 1]), "value_check: the y range must increase")
	var pts := [[0, 0, 0], [1, 2, 3], [0.5, -1, 0.25]]
	ok(CadaclysmCuboid.around(fxy(), pts).equals(CadaclysmCuboid.create(XY, [0, 1], [-1, 2], [0, 3])))
	ok(CadaclysmCuboid.around(XY, PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 2, 3)])).equals(CadaclysmCuboid.create(XY, [0, 1], [0, 2], [0, 3])))
	refused_as(func(): return CadaclysmCuboid.around(XY, [[0, 0, 0], [1, 1, 0]]), "cuboid_around: the points are flat along an axis of the frame")
	refused_as(func(): return CadaclysmCuboid.around(XY, []), "cuboid_around: no points")
	refused_as(func(): return CadaclysmCuboid.around(XY, [[0, 0, 0], [1, 1]]), "cuboid_around: a point is 3 numbers, got 2")

func test_a_cuboid_answers_b1s_figures():
	var box := CadaclysmCuboid.create(XY, [0, 1], [0, 2], [0, 3])
	eq([box.area(), box.volume()], [22.0, 6.0])
	ok(box.contains([0.5, 0.5, 0.5]) and not box.contains([1.5, 0.5, 0.5], 0.4) and box.contains([1.5, 0.5, 0.5], 0.5))
	var tilted := CadaclysmCuboid.create(YZX, [0, 1], [0, 2], [0, 3])
	eq(tilted.closest_point([9, 9, 9]), Vector3(4, 3, 5))
	ok(v3near(tilted.point_at(0.5, 0.5, 0.5), Vector3(2.5, 2.5, 4)))
	var corners := box.corners()
	eq(corners.size(), 8)
	eq([corners[0], corners[2], corners[6]], [Vector3(0, 0, 0), Vector3(1, 2, 0), Vector3(1, 2, 3)])
	var moved := box.transform(CadaclysmTransform.translation([0, 0, 1]))
	ok(moved is CadaclysmCuboid)
	eq(moved.bounds(), AABB(Vector3(0, 0, 1), Vector3(1, 2, 3)))
	ok(is_nan(box.closest_point([1, 2]).x))

func test_boxes_match_rhino():
	var r = vectors()
	if r == null:
		return
	var ranges := nums(r, "box", "ranges")
	var box := CadaclysmCuboid.create(nums(r, "box", "frame"), ranges.slice(0, 2), ranges.slice(2, 4), ranges.slice(4, 6))
	var corners := nums(r, "box", "corners")
	var got := box.corners()
	eq(got.size(), 8)
	for k in got.size():
		ok(all_near(xyz(got[k]), corners.slice(3 * k, 3 * k + 3), FLOATS), "corner %d" % k)
	for k in 4:
		var n := nums(r, "box_at_%d" % k, "point")
		ok(all_near(xyz(box.point_at(n[0], n[1], n[2])), n.slice(3, 6), FLOATS), "box_at_%d" % k)
	for item in queries(r, "box"):
		ok(all_near(xyz(box.closest_point(item[1])), nums(r, item[0], "closest"), FLOATS), item[0])

# ---- the rectangle, the triangle and the ray (plan B4): Python's TestPlanarValues ----------

const SHEAR := [1, 0.5, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

func test_a_rectangle_is_a_curve_with_calls_of_its_own():
	var r := CadaclysmRectangle.create(XY, [1, 4], iv(0, 4))
	is_iv(r.x, [1, 4], "x")
	is_iv(r.y, [0, 4], "y")
	eq(r.frame.origin, Vector3(0, 0, 0))
	eq([r.point_at(2.25), r.point_at(9)], [Vector3(3.25, 4, 0), Vector3(1, 0, 0)], "clamped to 4")
	eq(r.tangent_at(1.5), Vector3(0, 1, 0))
	eq(r.length(), 14.0)
	var foot := r.closest_point([2, -1, 7])
	ok(near(foot.t, 1.0 / 3.0, 1e-15) and foot.point == Vector3(2, 0, 0) and foot.unique, str(foot))
	eq(CadaclysmRectangle.create(XY, [0, 2], [0, 2]).closest_point([1, 1, 0]).unique, false, "the centre is a pick")
	eq(r.corners(), PackedVector3Array([Vector3(1, 0, 0), Vector3(4, 0, 0), Vector3(4, 4, 0), Vector3(1, 4, 0)]))
	eq(r.area(), 12.0)
	eq([r.closest_point_in([2, 1, 5]), r.closest_point_in([2, 1, 5], false)], [Vector3(2, 1, 0), Vector3(1, 1, 0)])
	eq(r.bounds(), AABB(Vector3(1, 0, 0), Vector3(3, 4, 0)))
	refused_as(func(): return CadaclysmRectangle.create(XY, [1, 1], [0, 4]), "value_check: the x range must increase")
	refused_as(func(): return CadaclysmRectangle.from_values(XY + [1, 4, 0]), "value_check: a rectangle is 16 numbers, got 15")
	refused_as(func(): return r.transform(SHEAR), "value_transform: a rectangle takes only a map that keeps its sides square (no shear in its plane)")
	ok(r.transform(CadaclysmTransform.scale_xyz(XY, 2, 3, 1)).equals(CadaclysmRectangle.create(XY, [2, 8], [0, 12])), "scaled")
	var sheet := r.to_sheet()
	eq(sheet.faces, 1)
	near(sheet.mass(1e-9)["area"], 12.0, 12e-9, "the sheet's area")
	var ring := r.to_nurbs()
	ok(ring.degree == 1 and ring.is_closed and not ring.is_rational, "the boundary's curve")
	eq([ring.domain[0], ring.domain[1]], [0.0, 4.0])
	ok(pdist(ring.point(2.25), [3.25, 4, 0]) <= 1e-12, "its parameter is t: " + str(ring.point(2.25)))

func test_a_rectangles_contains_takes_nan_as_its_effective_tolerance_and_zero_as_exact():
	var r := CadaclysmRectangle.create(XY, [1, 4], [0, 4])   # diagonal 5: effective 5e-4
	eq([r.contains([2, 2, 9], 0), r.contains([0, 2, 0], 0), r.contains([1, 2, 0], 0)], ["inside", "outside", "on"])
	var near_edge := [1 - 4e-4, 2, 0]
	eq([r.contains(near_edge, 0), r.contains(near_edge, 1e-3)], ["outside", "on"])
	eq([r.contains(near_edge), r.contains(near_edge, NAN)], ["on", "on"])
	eq(r.contains([1 - 6e-4, 2, 0]), "outside")
	refused_as(func(): return r.contains([0, 0, 0], -1), "rectangle_contains: the tolerance must be finite and not negative")
	var eff := 1e-4 * 4 * sqrt(3)
	var ball := CadaclysmSphere.create(XY, 2)
	ok(ball.contains([2 + 0.9 * eff, 0, 0], NAN) and not ball.contains([2 + 0.9 * eff, 0, 0]) and not ball.contains([2 + 1.1 * eff, 0, 0], NAN),
		"a sphere's contains takes NAN as unset")

func test_a_triangle_answers_its_closed_forms():
	var t := CadaclysmTriangle.create([0, 0, 0], [4, 0, 0], [0, 3, 0])
	eq([t.a, t.b, t.c], [Vector3(0, 0, 0), Vector3(4, 0, 0), Vector3(0, 3, 0)])
	eq([t.area(), t.perimeter()], [6.0, 12.0])
	ok(v3near(t.centroid(), Vector3(4.0 / 3.0, 1, 0), FLOATS), "centroid")
	var cc := t.circumcircle()
	ok(cc is CadaclysmCircle and v3near(cc.frame.origin, Vector3(2, 1.5, 0), FLOATS) and near(cc.radius, 2.5, 1e-15), str(cc))
	eq(t.point_at(0.5, 0.25, 0.25), Vector3(1, 0.75, 0))
	ok(all_near(Array(t.barycentric([1, 0.75, 5])), [0.5, 0.25, 0.25], 1e-15), "barycentric")
	eq([t.closest_point([2, -1, 0]), t.closest_point([1, 1, 3])], [Vector3(2, 0, 0), Vector3(1, 1, 0)])
	eq(t.distance_to([1, 1, 3]), 3.0)
	ok(t.edge(1).equals(CadaclysmLine.create([4, 0, 0], [0, 3, 0])), str(t.edge(1)))
	refused_as(func(): return t.edge(3), "triangle_edge: edge 3 is not 0, 1 or 2")
	refused_as(func(): return CadaclysmTriangle.create([0, 0, 0], [1, 1, 1], [2, 2, 2]), "value_check: the triangle is degenerate (its points are collinear or coincident)")
	refused_as(func(): return CadaclysmTriangle.from_values([0, 0, 0, 4, 0, 0, 0, 3]), "value_check: a triangle is 9 numbers, got 8")
	ok(t.transform(SHEAR).equals(CadaclysmTriangle.create([0, 0, 0], [4, 0, 0], [1.5, 3, 0])), "any affine map")
	near(t.to_sheet().mass(1e-9)["area"], 6.0, 6e-9, "the sheet's area")
	ok(not t.equals(CadaclysmTriangle.create([0, 0, 0], [0, 3, 0], [4, 0, 0])), "a reordered triangle differs")

func test_a_ray_holds_to_its_half_line_only_in_closest_point():
	var ray := CadaclysmRay.create([1, 2, 3], [0, 0, 2])
	eq(Array(ray.values), [1.0, 2.0, 3.0, 0.0, 0.0, 2.0])
	eq([ray.position, ray.direction], [Vector3(1, 2, 3), Vector3(0, 0, 2)], "kept as given")
	eq([ray.point_at(1.5), ray.point_at(-1)], [Vector3(1, 2, 6), Vector3(1, 2, 1)])
	var ahead := ray.closest_point([5, 2, 7])
	var behind := ray.closest_point([5, 2, -7])
	ok(ahead.t == 2.0 and ahead.point == Vector3(1, 2, 7) and ahead.unique, str(ahead))
	ok(behind.t == 0.0 and behind.point == Vector3(1, 2, 3) and behind.unique, "behind: the start " + str(behind))
	near(ray.distance_to([5, 2, -7]), sqrt(116.0), 1e-12)
	refused_as(func(): return ray.bounds(), "value_bounds: a ray has no box (it is unbounded)")
	refused_as(func(): return CadaclysmRay.create([0, 0, 0], [0, 0, 0]), "value_check: the ray's direction is zero")
	refused_as(func(): return CadaclysmRay.from_values([0, 0, 0, 1, 0, 0, 0]), "value_check: a ray is 6 numbers, got 7")
	ok(ray.transform(CadaclysmTransform.scale_xyz(XY, 1, 1, 3)).equals(CadaclysmRay.create([1, 2, 9], [0, 0, 6])), "scaled")

func test_rectangles_triangles_and_rays_match_rhino():
	var r = vectors()
	if r == null:
		return
	var ranges := nums(r, "rectangle", "ranges")
	var rect := CadaclysmRectangle.create(nums(r, "rectangle", "frame"), ranges.slice(0, 2), ranges.slice(2, 4))
	var corners := nums(r, "rectangle", "corners")
	var got := rect.corners()
	eq(got.size(), 4)
	for k in got.size():
		ok(all_near(xyz(got[k]), corners.slice(3 * k, 3 * k + 3), FLOATS), "corner %d" % k)
	ok(all_near([rect.area(), rect.length()], nums(r, "rectangle", "area") + nums(r, "rectangle", "circumference"), EXACT), "area")
	for k in 9:
		var n := nums(r, "rectangle_at_%d" % k, "point")
		ok(all_near(xyz(rect.point_at(n[0])), n.slice(1, 4), FLOATS), "rectangle_at_%d" % k)
	var said := {"Inside": "inside", "Outside": "outside", "Coincident": "on"}
	for item in queries(r, "rectangle") + queries(r, "rectangle_in"):
		ok(all_near(Array(rect.closest_point(item[1]).raw_point), nums(r, item[0], "boundary"), EXACT), item[0])
		ok(all_near(xyz(rect.closest_point_in(item[1], true)), nums(r, item[0], "filled"), FLOATS), item[0])
		eq(rect.contains(item[1], 0), said[r[item[0] + " contains"][0]], item[0])
	var p := nums(r, "triangle", "points")
	var tri := CadaclysmTriangle.create(p.slice(0, 3), p.slice(3, 6), p.slice(6, 9))
	ok(all_near([tri.area(), tri.perimeter()], nums(r, "triangle", "area") + nums(r, "triangle", "perimeter"), EXACT), "triangle")
	ok(all_near(xyz(tri.centroid()), nums(r, "triangle", "centroid"), FLOATS), "centroid")
	ok(all_near(Array(tri.circumcircle().values), nums(r, "triangle", "circumcircle"), EXACT), "circumcircle")
	for item in queries(r, "triangle") + queries(r, "triangle_in"):
		var w := Array(tri.barycentric(item[1]))
		ok(all_near(w.slice(1, 3), nums(r, item[0], "barycentric").slice(0, 2), EXACT), item[0])
		ok(all_near(xyz(tri.point_at(w[0], w[1], w[2])), nums(r, item[0], "projected"), FLOATS), item[0])
		if min(w[0], w[1], w[2]) < 0:
			ok(all_near(xyz(tri.closest_point(item[1])), nums(r, item[0], "boundary"), FLOATS), item[0])
	var rn := nums(r, "ray", "ray")
	var ray := CadaclysmRay.create(rn.slice(0, 3), rn.slice(3, 6))
	for k in 4:
		var n := nums(r, "ray_at_%d" % k, "point")
		ok(all_near(xyz(ray.point_at(n[0])), n.slice(1, 4), FLOATS), "ray_at_%d" % k)

# A profile's (x span, y span, x centre, y centre), off the sheet it bounds.
func measure(p: CadaclysmProfile) -> Array:
	var b := CadaclysmSolid.face(p, XY).raw_bounds(0.01)
	return [b[3] - b[0], b[4] - b[1], (b[3] + b[0]) / 2, (b[4] + b[1]) / 2]

func test_a_profile_turns_scales_mirrors_and_maps():
	var rect := CadaclysmProfile.rect(80, 40)
	var m := measure(rect)
	var rx: float = m[2]
	var ry: float = m[3]
	ok(all_near(measure(rect.rotate([0, 0], PI / 2)).slice(0, 2), [40, 80], 1e-3), "rotate spans")
	ok(all_near(measure(rect.scale([0, 0], 0.5, 2)).slice(0, 2), [40, 80], 1e-3), "scale spans")
	# Off the origin, so the argument order shows.
	ok(all_near(measure(rect.rotate([10, 20], PI / 2)).slice(2, 4), [10 - (ry - 20), 20 + (rx - 10)], 1e-3), "rotate centre")
	ok(all_near(measure(rect.scale([10, 0], 0.5, 2)).slice(2, 4), [10 + 0.5 * (rx - 10), 2 * ry], 1e-3), "scale centre")
	ok(all_near(measure(rect.mirror([100, 0], [0, 1])).slice(2, 3), [200], 1e-3), "mirror")
	ok(all_near(measure(rect.transform2d([1, 0.5, 0, 0, 1, 0])).slice(0, 1), [100], 1e-3), "transform2d")
	refused(func(): return rect.transform2d([1, 2, 0, 2, 4, 0]), "profile_transform2d: the 2D map is singular")
	refused(func(): return rect.transform2d([1, 0, 0, 0, 1]), "transform2d: expected 6 numbers, got 5")

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
	# Two bodies' line groups plus the plate's silhouette group (on by default since fc978acfc).
	eq(both.count("<g id=\""), 3)

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
	# A rectangle drawn above a sphere cores it: the ball with a square hole, then the core.
	var ball := CadaclysmSolid.sphere(10)
	var cored := ball.split_by_profile(CadaclysmProfile.rect(6, 6), [[0, 0, 40], [1, 0, 0], [0, 1, 0], [0, 0, 1]])
	eq(cored.size(), 2)
	var outside: float = cored[0].mass()["volume"]
	var inside: float = cored[1].mass()["volume"]
	var whole: float = ball.mass()["volume"]
	ok(inside > 0 and inside < outside, "the core is the smaller body: %f %f" % [outside, inside])
	ok(absf(outside + inside - whole) < 0.01 * whole, "the hole and the core add up to the ball")
	refuses(func(): return ball.split_by_profile(CadaclysmProfile.rect(6, 6), [[30, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1]]), "split_by_profile: ")
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
	eq(block.coloured("red").colour, Color(1, 0, 0))
	refuses(func(): return block.coloured("notacolour"), "coloured: a colour is")
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
	var message := refuses(func(): return cube.leaked_edges(-1))
	ok(message.begins_with("leaked_edges: tolerance must be positive and finite"), message)
	eq(cube.leaked_edges(-1), -1)
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

# ---- the health report and healing (healing in the other wrappers, 2026-10-29) --------
# Python's figures (test_health_* / test_healed_* in test_cadaclysm_blacksmith.py).

func rel(actual: float, expected: float, tolerance: float, message := "") -> bool:
	return ok(absf(actual - expected) <= tolerance * absf(expected), "%s expected %s (rel %s), got %s" % [message, expected, tolerance, actual])

func test_health_of_a_closed_cuboid_finds_nothing():
	var box := CadaclysmSolid.cuboid(10, 10, 10)
	var h := box.health()
	eq(h["free_edges"].size(), 0)
	eq(h["wires"].size(), 0)
	eq(h["small"].size(), 0)
	eq(h["cracks"], null)
	rel(h["extent"], 10 * sqrt(3.0), 1e-12, "extent")
	rel(h["rounding"], 1e-7 * h["extent"], 1e-12, "rounding")
	rel(h["tolerance"], 1e-4 * h["extent"], 1e-12, "tolerance")
	eq([h["loose_edges"], h["worst_loose"], h["sew_pairs"], h["sew_refused"], h["sew_worst_gap"], h["worst_gap"]], [0, 0.0, 0, 0, 0.0, 0.0])
	var c: Dictionary = box.health(0.0, true)["cracks"]
	eq([c["watertight"], c["open"], c["folded"], c["crossings"]], [true, 0, 0, 0])
	eq(c["edges"], PackedInt64Array())
	eq(box.health(0.5)["tolerance"], 0.5)
	eq(box.health(-1)["tolerance"], h["tolerance"])
	eq(box.health(NAN)["tolerance"], h["tolerance"])

func test_health_of_an_open_rim_lists_its_four_free_edges():
	var open := CadaclysmSolid.cuboid(10, 10, 10).drop_faces([0])
	var h := open.health()
	eq(h["free_edges"].size(), 4)
	eq(h["wires"].size(), 1)
	var w: Dictionary = h["wires"][0]
	eq([w["first"], w["count"], w["closed"]], [0, 4, true])
	near(w["length"], 40, 1e-9, "wire length")
	var rows := []
	for e in h["free_edges"]:
		rows.append([e["trim"], e["edge"], e["face"], e["partner"]])
		eq([e["wire"], e["shared_ends"]], [0, 0])
		near(e["length"], 10, 1e-9, "length")
		near(e["gap"], 10, 1e-9, "gap")
	eq(rows, [[4, 3, 1, 2], [16, 2, 4, 3], [11, 1, 2, 0], [15, 0, 3, 1]])
	near(h["worst_gap"], 10, 1e-9, "worst_gap")
	var c: Dictionary = open.health(0.0, true)["cracks"]
	eq([c["watertight"], c["open"], c["folded"], c["crossings"], c["edges"]], [false, 0, 0, 0, PackedInt64Array()])
	# A triangle sheet's three free edges are each other's neighbours on the wire, so none has
	# a partner: -1, the gap infinite.
	var tri := CadaclysmSolid.face(CadaclysmProfile.regular_polygon([0, 0], 5, 3), XY).health()
	eq(tri["free_edges"].size(), 3)
	ok(tri["free_edges"].all(func(e): return e["partner"] == -1 and is_inf(e["gap"])), "no partner: %s" % [tri["free_edges"]])

func test_health_of_a_thin_plate_lists_short_edges_then_slivers():
	var small: Array = CadaclysmSolid.cuboid(10, 10, 0.001).health(0.01)["small"]
	var rows := []
	for s in small:
		rows.append([s["kind"], s["index"]])
	eq(rows, [["short_edge", 8], ["short_edge", 9], ["short_edge", 10], ["short_edge", 11],
		["sliver_face", 2], ["sliver_face", 3], ["sliver_face", 4], ["sliver_face", 5]])
	for i in 4:
		rel(small[i]["size"], 0.001, 1e-9, "short edge size")
		rel(small[4 + i]["size"], 0.0009999, 1e-3, "sliver size")

func test_health_of_a_tiny_body_lists_edges_faces_and_the_body():
	var small: Array = CadaclysmSolid.cuboid(0.0005, 0.0005, 0.0005).health(0.01)["small"]
	var kinds := {}
	for s in small:
		kinds[s["kind"]] = kinds.get(s["kind"], 0) + 1
	eq(kinds, {"short_edge": 12, "tiny_face": 6, "tiny_body": 1})
	var faces := []
	for s in small:
		if s["kind"] == "tiny_face":
			faces.append(s["index"])
			rel(s["size"], 2.5e-7, 1e-9, "tiny face size")
	eq(faces, [0, 1, 2, 3, 4, 5])
	var body: Dictionary = small[small.size() - 1]
	eq([body["kind"], body["index"]], ["tiny_body", 0])
	rel(body["size"], 0.0005 * sqrt(3.0), 1e-9, "tiny body size")

func test_healed_cuboid_is_a_new_solid_with_nothing_done():
	var box := CadaclysmSolid.cuboid(10, 10, 10)
	var pair := box.healed()
	var healed: CadaclysmSolid = pair["body"]
	var r: Dictionary = pair["report"]
	ok(healed != box and healed.closed == false)
	eq([r["fixes"].size(), r["refused"].size(), r["guarded"]], [0, 0, false])
	eq([r["small_before"], r["small_after"], r["free_before"], r["free_after"]], [0, 0, 0, 0])
	eq([r["closed_before"], r["closed_after"], r["nonmanifold_before"], r["nonmanifold_after"]], [true, true, 0, 0])
	eq(r["tolerance"], box.health()["tolerance"])
	eq(r["moved"], 0.0)
	eq(healed.faces, 6)
	near(healed.mass(0)["volume"], 1000, 1e-6, "volume")
	eq(box.healed(0.5)["report"]["tolerance"], 0.5)
	for e in 12:
		eq(healed.edge_tolerance(e), 0.0, "edge %d" % e)
	ok(is_nan(healed.edge_tolerance(0xFFFFFFF0)), "no such edge is NAN")
	refuses(func(): return healed.edge_tolerance(-1), "edge_tolerance: no edge -1")
	ok(is_nan(healed.edge_tolerance(0x100000000)))

func test_healed_with_every_kind_off_refuses_them_as_toggled():
	var plate := CadaclysmSolid.cuboid(10, 10, 0.001)
	var r: Dictionary = plate.healed(0.01, false, false, false)["report"]
	eq(r["fixes"].size(), 0)
	eq([r["small_before"], r["small_after"]], [8, 8])
	var rows := []
	for x in r["refused"]:
		rows.append([x["kind"], x["index"], x["why"], x["figure"]])
	eq(rows, [["short_edge", 8, "toggled", 0.0], ["short_edge", 9, "toggled", 0.0], ["short_edge", 10, "toggled", 0.0], ["short_edge", 11, "toggled", 0.0],
		["sliver_face", 2, "toggled", 0.0], ["sliver_face", 3, "toggled", 0.0], ["sliver_face", 4, "toggled", 0.0], ["sliver_face", 5, "toggled", 0.0]])
	# One kind off at a time: only that kind is toggled, so each switch reaches the library.
	var edges_off: Dictionary = plate.healed(0.01, false, true, true)["report"]
	ok(edges_off["refused"].any(func(x): return x["kind"] == "short_edge" and x["why"] == "toggled"), "edges off")
	ok(not edges_off["refused"].any(func(x): return x["kind"] == "sliver_face" and x["why"] == "toggled"), "edges off toggles faces")
	var faces_off: Dictionary = plate.healed(0.01, true, false, true)["report"]
	ok(faces_off["refused"].any(func(x): return x["kind"] == "sliver_face" and x["why"] == "toggled"), "faces off")
	var on: Dictionary = plate.healed(0.01)["report"]
	eq(on["small_before"], 8)
	ok(not on["refused"].any(func(x): return x["why"] == "toggled"), "nothing toggled with every kind on")
	if on["guarded"]:
		ok(on["refused"].all(func(x): return x["why"] == "body_guard"), "a guarded refusal is body_guard")

func test_healed_holes_switch_reaches_a_pinhole():
	var sheet := CadaclysmSolid.face(CadaclysmProfile.rect(10, 10).with_hole(CadaclysmProfile.circle(0.002)), XY)
	var small: Array = sheet.health(0.01)["small"]
	ok(small.any(func(s): return s["kind"] == "small_hole"), "a pinhole is a small hole: %s" % [small])
	var off: Dictionary = sheet.healed(0.01, true, true, false)["report"]
	ok(off["refused"].any(func(x): return x["kind"] == "small_hole" and x["why"] == "toggled"), "holes off: %s" % [off])
	var on: Dictionary = sheet.healed(0.01)["report"]
	ok(on["fixes"].any(func(x): return x["kind"] == "small_hole"), "holes on: %s" % [on])

func test_health_and_healing_refuse_a_closed_solid():
	var box := CadaclysmSolid.cuboid(1, 1, 1)
	box.close()
	eq(box.health(), {})
	refuses(func(): return box.health(), "closed")
	refuses(func(): return box.healed(), "closed")
	refuses(func(): return box.edge_tolerance(0), "closed")
	ok(is_nan(box.edge_tolerance(0)))

func test_the_collider_finds_overlapping_parts_and_rebuilds_the_overlap():
	# Two cuboids overlapping by 2 along x, plus one far away -> one hit (0, 1), depth 2.
	var a := CadaclysmSolid.cuboid(4, 4, 4)
	var b := CadaclysmSolid.cuboid(4, 4, 4).translate(2, 0, 0)
	var c := CadaclysmSolid.cuboid(4, 4, 4).translate(100, 0, 0)
	ok(a.bounds_box().overlaps(b.bounds_box()), "the two overlapping cuboids' bounds boxes do not overlap")
	var collider := CadaclysmCollider.create([a, b, c])
	eq(collider.group_count, 3)
	var stats0 := collider.stats()
	eq(stats0.considered, 0, "no check yet")
	var hits: Array = collider.check([XY, XY, XY])
	eq(hits.size(), 1)
	var hit: CadaclysmCollisionHit = hits[0]
	eq(hit.a, 0)
	eq(hit.b, 1)
	ok(hit.overlap and hit.kind == "overlap" and hit.text == "", "the hit is not a clean overlap")
	near(hit.depth, 2.0, 1e-9)
	var overlap := hit.solid()
	ok(overlap != null and overlap.faces > 0, "the hit's rebuilt solid has no faces")
	var stats1 := collider.stats()
	eq(stats1.considered, 3)
	ok(stats1.confirmed + stats1.closed_form + stats1.meshed >= 1, "no pair was answered")
	collider.close()
	ok(collider.closed, "close() did not close the collider")

func test_a_collision_hits_solid_survives_the_collider_closing():
	# solid() keeps the collisions handle (not the collider) alive: closing the
	# collider itself must not take the hit's own rebuild with it.
	var a := CadaclysmSolid.cuboid(2, 2, 2)
	var b := CadaclysmSolid.cuboid(2, 2, 2).translate(1, 0, 0)
	var collider := CadaclysmCollider.create([a, b])
	var hits: Array = collider.check([XY, XY])
	collider.close()
	eq(hits.size(), 1)
	var overlap: CadaclysmSolid = hits[0].solid()
	ok(overlap != null and overlap.faces > 0)

func test_a_refused_check_is_null_never_an_empty_clear_array():
	# check() returns [] only when every pair is proved clear; a refusal is null with
	# the reason in last_error() -- the two must never read alike. (Called directly, not
	# through refuses(): a lambda captures `hits` by value, so it could not hand it back.)
	var a := CadaclysmSolid.cuboid(2, 2, 2)
	var b := CadaclysmSolid.cuboid(2, 2, 2).translate(1, 0, 0)
	var collider := CadaclysmCollider.create([a, b])
	var hits = collider.check([XY])
	ok(typeof(hits) == TYPE_NIL, "a check with one frame for two groups returned %s, not null" % [hits])
	ok(Cadaclysm.last_error().contains("1 frames for 2 groups"), Cadaclysm.last_error())
	hits = collider.check([XY, XY], -1, 2)
	ok(typeof(hits) == TYPE_NIL, "a negative share_k returned %s, not null" % [hits])
	ok(Cadaclysm.last_error().contains("share (-1, 2)"), Cadaclysm.last_error())
	hits = collider.check([XY, XY], 2, 2)
	ok(typeof(hits) == TYPE_NIL, "share_k == share_n returned %s, not null" % [hits])
	ok(Cadaclysm.last_error().contains("share (2, 2)"), Cadaclysm.last_error())
	hits = collider.check([XY, [0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 1]])
	ok(typeof(hits) == TYPE_NIL, "a scaled frame returned %s, not null" % [hits])
	ok(Cadaclysm.last_error() != "", "a scaled frame left no error")
	hits = collider.check([XY, XY])
	ok(hits is Array and hits.size() == 1, "the same collider no longer checks a good pose: %s" % [hits])
	collider.close()
	hits = collider.check([XY, XY])
	ok(typeof(hits) == TYPE_NIL, "a closed collider's check returned %s, not null" % [hits])
	ok(Cadaclysm.last_error().contains("closed"), Cadaclysm.last_error())

func test_the_collider_refuses_odd_allowed_and_negative_indices():
	var a := CadaclysmSolid.cuboid(2, 2, 2)
	var b := CadaclysmSolid.cuboid(2, 2, 2).translate(1, 0, 0)
	var message := refuses(func(): return CadaclysmCollider.create([a, b], 0.05, PackedInt32Array(), PackedInt32Array([0, 1, 1])))
	ok(message.contains("allowed is 3 numbers"), message)
	message = refuses(func(): return CadaclysmCollider.create([a, b], 0.05, PackedInt32Array([0, -1])))
	ok(message.contains("negative"), message)
	message = refuses(func(): return CadaclysmCollider.create([a, b], 0.05, PackedInt32Array(), PackedInt32Array([0, -1])))
	ok(message.contains("negative"), message)

func test_a_float_transform3d_pose_is_squared_up_not_refused():
	# A Transform3D's basis is float32: a turned one is off square by ~1e-8, past the
	# kernel's 1e-9 -- the wrapper squares it up, so the pose is checked, not refused.
	var a := CadaclysmSolid.cuboid(2, 2, 2)
	var b := CadaclysmSolid.cuboid(2, 2, 2)
	var collider := CadaclysmCollider.create([a, b])
	var turned := Transform3D(Basis(Vector3(0.3, 0.4, 0.866).normalized(), deg_to_rad(37.0)), Vector3(1, 0, 0))
	var hits = collider.check([Transform3D.IDENTITY, turned])
	ok(hits is Array, "a turned Transform3D pose was refused: " + Cadaclysm.last_error())
	if hits is Array:
		eq(hits.size(), 1)

func test_the_collider_refuses_a_part_that_is_not_a_closed_solid():
	var sheet := CadaclysmSolid.cuboid(2, 2, 2).face_sheet(0)
	var message := refuses(func(): return CadaclysmCollider.create([sheet]))
	ok(message.contains("collider_new: part 0 is not a closed solid"), message)

func test_the_collider_refuses_a_short_groups_list():
	var a := CadaclysmSolid.cuboid(2, 2, 2)
	var b := CadaclysmSolid.cuboid(2, 2, 2).translate(1, 0, 0)
	var groups := PackedInt32Array([0])
	var message := refuses(func(): return CadaclysmCollider.create([a, b], 0.05, groups))
	ok(message.contains("groups must have one entry per solid (2 solids, 1 groups)"), message)

# ---- clash (clash plan 3) ------------------------------------------------------------

# The frame at (x, y, z) with the world's axes: origin, x, y, z.
func at(x: float, y := 0.0, z := 0.0) -> Array:
	return [x, y, z, 1, 0, 0, 0, 1, 0, 0, 0, 1]

func clash_pairs(rows: Array) -> Array:
	return rows.map(func(r): return [r.a, r.b, r.kind])

func test_clash_balls_within_the_clearance_are_too_close():
	var a := CadaclysmSolid.sphere(1)
	var b := CadaclysmSolid.sphere(1)
	var collider := CadaclysmCollider.create([a, b], 1e-3)
	var rows = collider.clash([at(0), at(2.5)], 1.0)
	ok(rows is Array, "refused: " + Cadaclysm.last_error())
	eq(clash_pairs(rows), [[0, 1, "too_close"]])
	var r: CadaclysmClash = rows[0]
	near(r.distance, 0.5, 1e-3, "distance")
	eq([r.kind_a, r.kind_b], ["face", "face"])
	ok(r.index_a >= 0 and r.index_b >= 0, str(r))
	eq([r.edge_a, r.edge_b], [-1, -1])
	near(r.on_a.x, 1.0, 2e-3, "on_a.x")
	near(r.on_b.x, 1.5, 2e-3, "on_b.x")
	near(r.raw_on_a[0], 1.0, 2e-3, "raw_on_a[0]")
	near(r.raw_on_b[0], 1.5, 2e-3, "raw_on_b[0]")
	eq(r.raw_on_a.size(), 3)
	eq(r.text, "")
	eq(r.depth, 0.0)
	eq(typeof(r.refined), TYPE_BOOL)
	ok(str(r).begins_with("Clash(a=0, b=1, kind=too_close"), str(r))
	var none = collider.clash([at(0), at(2.5)], 0.25)
	ok(none is Array and none.is_empty(), "clearance 0.25: %s" % [none])

func test_clash_boxes_face_to_face_touch_and_intersect_on_the_shared_face():
	var a := CadaclysmSolid.cuboid(2, 2, 2)
	var b := CadaclysmSolid.cuboid(2, 2, 2)
	var collider := CadaclysmCollider.create([a, b], 1e-3)
	var rows = collider.clash([at(0), at(2)])
	collider.close()
	eq(clash_pairs(rows), [[0, 1, "touching"]])
	var r: CadaclysmClash = rows[0]
	ok(r.distance <= 1e-3, str(r.distance))
	var message := refuses(func(): return r.solid())
	ok(message.begins_with("clashes_solid: pair (0, 1) is not penetrating"), message)
	var x := r.intersect()
	ok(x != null, "intersect refused: " + Cadaclysm.last_error())
	eq(x.overlaps.size(), 1)
	var ring: PackedFloat64Array = x.overlaps[0].raw_loops[0]
	ok(ring.size() >= 9, "a ring is at least a triangle")
	var area := 0.0
	for k in range(0, ring.size(), 3):
		var m := (k + 3) % ring.size()
		ok(absf(ring[k] - 1.0) <= 1e-3, "off the shared face: %s" % ring[k])
		area += ring[k + 1] * ring[m + 2] - ring[m + 1] * ring[k + 2]
	near(absf(area) / 2.0, 4.0, 1e-6, "shared face area")

func test_clash_boxes_interpenetrating_report_depth_and_rebuild_the_overlap():
	var a := CadaclysmSolid.cuboid(2, 2, 2)
	var b := CadaclysmSolid.cuboid(2, 2, 2)
	var collider := CadaclysmCollider.create([a, b], 1e-3)
	var rows = collider.clash([at(0), at(1.75)])
	collider.close()
	collider = null
	eq(clash_pairs(rows), [[0, 1, "penetrating"]])
	# One row kept, the list and the collider gone: the row keeps the answer alive.
	var r: CadaclysmClash = rows[0]
	rows = null
	ok(absf(r.depth - 0.25) < 1e-9, str(r.depth))
	eq(r.distance, 0.0)
	eq([r.kind_a, r.index_a, r.edge_a], ["none", -1, -1])
	eq([r.kind_b, r.index_b, r.edge_b], ["none", -1, -1])
	var shared := r.solid()
	ok(shared != null, "solid refused: " + Cadaclysm.last_error())
	if shared != null:
		near(shared.mass(1e-6)["volume"], 1.0, 1e-6, "shared volume")
	ok(r.intersect() != null, "intersect refused: " + Cadaclysm.last_error())

func test_clash_one_shot_indexes_the_second_set_and_takes_allowed_pairs():
	var a0 := CadaclysmSolid.sphere(1)
	var a1 := CadaclysmSolid.sphere(1).translate(2.05, 0, 0)
	var b0 := CadaclysmSolid.sphere(1).translate(0, 2.5, 0)
	var b1 := CadaclysmSolid.sphere(1).translate(10, 0, 0)
	var two = CadaclysmBlacksmith.clash([a0, a1], [b0, b1], 1.0, 1e-3)
	eq(clash_pairs(two), [[0, 0, "too_close"]])
	near(two[0].distance, 0.5, 1e-3, "distance")
	var one = CadaclysmBlacksmith.clash([a0, a1], null, 1.0, 1e-3)
	eq(clash_pairs(one).map(func(p): return [p[0], p[1]]), [[0, 1]])
	var spared = CadaclysmBlacksmith.clash([a0, a1], null, 1.0, 1e-3, PackedInt32Array([0, 1]))
	ok(spared is Array and spared.is_empty(), "allowed (0, 1): %s" % [spared])

func test_clash_refusals_carry_the_calls_prefix():
	var a := CadaclysmSolid.cuboid(2, 2, 2)
	var b := CadaclysmSolid.cuboid(2, 2, 2)
	var collider := CadaclysmCollider.create([a, b])
	var pose := [at(0), at(1.75)]
	# A refusal is null, never an empty clear array.
	var rows = collider.clash(pose, -1.0)
	ok(typeof(rows) == TYPE_NIL, "clearance -1 returned %s, not null" % [rows])
	var message := Cadaclysm.last_error()
	ok(message.begins_with("collider_clash: clearance -1"), message)
	message = refuses(func(): return collider.clash([at(0)]))
	ok(message.begins_with("collider_clash: 1 frames for 2 groups"), message)
	message = refuses(func(): return collider.clash(pose, 0.0, 2, 2))
	ok(message.begins_with("collider_clash: share (2, 2)"), message)
	message = refuses(func(): return collider.clash(pose, 0.0, -1, 2))
	ok(message.begins_with("collider_clash: share (-1, 2)"), message)
	eq(clash_pairs(collider.clash(pose)), [[0, 1, "penetrating"]])
	message = refuses(func(): return CadaclysmBlacksmith.clash([a, b], null, -1.0))
	ok(message.begins_with("clash: clearance -1"), message)
	message = refuses(func(): return CadaclysmBlacksmith.clash([a, b], null, 0.0, 0.05, PackedInt32Array([5, 0])))
	ok(message.begins_with("clash: allowed pair (5, 0) names a part out of range"), message)
	rows = CadaclysmBlacksmith.clash([a, b], [])
	ok(typeof(rows) == TYPE_NIL, "an empty others returned %s, not null" % [rows])
	message = Cadaclysm.last_error()
	ok(message.begins_with("clash: an empty set"), message)
	message = refuses(func(): return CadaclysmBlacksmith.clash([a, b], null, 0.0, 0.05, PackedInt32Array([0, 1, 1])))
	ok(message.begins_with("clash: allowed is 3 numbers, not pairs"), message)
	message = refuses(func(): return CadaclysmBlacksmith.clash([a, b], null, 0.0, 0.05, PackedInt32Array([0, -1])))
	ok(message.begins_with("clash: allowed pair (0, -1) is not two indices"), message)
	message = refuses(func(): return CadaclysmBlacksmith.clash([a, b], 5))
	ok(message.begins_with("clash: others is null or an array"), message)
	collider.close()
	message = refuses(func(): return collider.clash(pose))
	ok(message.contains("closed"), message)

func test_clash_names_the_edges_of_two_boxes_edge_to_edge():
	var a := CadaclysmSolid.cuboid(2, 2, 2)
	var b := CadaclysmSolid.cuboid(2, 2, 2)
	var collider := CadaclysmCollider.create([a, b], 1e-3)
	var c := sqrt(0.5)
	var s := 0.1 * c
	var turned := [2 + s, 2 + s, 0, c, -c, 0, 0.5, 0.5, c, -0.5, -0.5, c]
	var rows = collider.clash([at(0), turned], 0.5)
	eq(clash_pairs(rows), [[0, 1, "too_close"]])
	var r: CadaclysmClash = rows[0]
	near(r.distance, 0.1, 1e-3, "distance")
	ok(all_near(r.raw_on_a, [1.0, 1.0, 0.0], 2e-3), "on_a: %s" % [r.raw_on_a])
	eq([r.kind_a, r.kind_b], ["edge", "edge"])
	ok(r.edge_a >= 0 and r.edge_a < a.edges.size(), "edge_a %d" % r.edge_a)
	if r.edge_a >= 0 and r.edge_a < a.edges.size():
		var seg: PackedFloat64Array = a.edges[r.edge_a].raw_segments
		ok(seg.size() >= 6)
		for k in range(0, seg.size(), 3):
			ok(absf(seg[k] - 1.0) <= 2e-3 and absf(seg[k + 1] - 1.0) <= 2e-3, "a's edge leaves x = 1, y = 1: %s" % [[seg[k], seg[k + 1]]])
	ok(r.edge_b >= 0 and r.edge_b < b.edges.size(), "edge_b %d of %d" % [r.edge_b, b.edges.size()])

func test_clash_keeps_each_sides_feature_apart():
	# CadaclysmSolid.closest's pose: the cuboid's edge against the ball's face, the sides told apart.
	var cuboid := CadaclysmSolid.cuboid(2, 3, 4)
	var ball := CadaclysmSolid.sphere(1).translate(3, 0, 4)
	var rows = CadaclysmBlacksmith.clash([cuboid], [ball], 2.0, 1e-3)
	eq(clash_pairs(rows), [[0, 0, "too_close"]])
	var r: CadaclysmClash = rows[0]
	near(r.distance, 2.0 * sqrt(2.0) - 1.0, 2e-3, "distance")
	eq([r.kind_a, r.kind_b], ["edge", "face"])
	ok(r.edge_a >= 0 and r.edge_b == -1, str([r.edge_a, r.edge_b]))
	var closest := cuboid.closest(ball, 1e-3)
	eq([r.index_a, r.edge_a, r.index_b], [closest.index_a, closest.edge_a, closest.index_b])

# ---- swept clash (swept clash plan 2b) ----------------------------------------------------
# The closed forms of crates/cadaclysm-blacksmith-capi/tests/swept_abi.rs: a 2-cube moving
# along x from -5 to 5 through a 2-cube at the origin meets it at t = 0.3 and leaves at 0.7,
# at a relative speed of 10 a segment.

const SWEPT_TOL := 1e-3
const SWEPT_RES := 1e-3

func through() -> Array:
	return [[at(-5), at(0)], [at(5), at(0)]]

func swept_collider() -> CadaclysmCollider:
	return CadaclysmCollider.create([CadaclysmSolid.cuboid(2, 2, 2), CadaclysmSolid.cuboid(2, 2, 2)], SWEPT_TOL)

func swept_pairs(rows: Array) -> Array:
	return rows.map(func(r): return [r.a, r.b])

# Each row as [a, b, first_time, intervals as plain arrays].
func swept_rows(rows: Array, b_offset := 0) -> Array:
	return rows.map(func(r): return [r.a, r.b - b_offset, r.first_time, r.intervals.map(func(s): return Array(s))])

func test_swept_clash_a_cube_through_a_cube():
	var collider := swept_collider()
	var rows = collider.swept_clash(through())
	collider.close()
	collider = null
	ok(rows is Array, "refused: " + Cadaclysm.last_error())
	eq(rows.size(), 1)
	var r: CadaclysmSweptClash = rows[0]
	rows = null
	eq([r.a, r.b], [0, 1])
	ok(absf(r.first_time - 0.3) <= SWEPT_TOL / 10 + 1e-9, "first_time %s" % r.first_time)
	eq(r.intervals.size(), 1)
	var span: PackedFloat64Array = r.intervals[0]
	eq(span.size(), 2)
	eq(span[0], r.first_time, "an interval starts at first_time")
	ok(absf(span[1] - 0.7) <= SWEPT_RES + SWEPT_TOL / 10, "end %s" % span[1])
	ok(str(r).begins_with("SweptClash(a=0, b=1, first_time="), str(r))
	var first: CadaclysmClash = r.first
	eq([first.a, first.b, first.kind], [0, 1, "touching"])
	# The first row keeps its own answer: the collider and the swept row are gone, the
	# contact still rebuilds.
	r = null
	refused(func(): return first.solid(), "clashes_solid: pair (0, 1) is not penetrating")
	var x := first.intersect()
	ok(x != null, "intersect refused: " + Cadaclysm.last_error())
	if x != null:
		eq(x.overlaps.size(), 1)
		for ring in x.overlaps[0].raw_loops:
			for k in range(0, ring.size(), 3):
				ok(absf(ring[k] + 1.0) <= 2 * SWEPT_TOL, "off the shared face: %s" % ring[k])

func test_swept_clash_there_and_back_is_two_intervals():
	var collider := swept_collider()
	var rows = collider.swept_clash(through() + [[at(-5), at(0)]])
	ok(rows is Array, "refused: " + Cadaclysm.last_error())
	eq(rows.size(), 1)
	var r: CadaclysmSweptClash = rows[0]
	eq(r.intervals.size(), 2)
	var want := [[0.3, 0.7], [1.3, 1.7]]
	for i in mini(r.intervals.size(), 2):
		var span: PackedFloat64Array = r.intervals[i]
		ok(absf(span[0] - want[i][0]) <= SWEPT_TOL / 10 + 1e-9, "interval %d %s" % [i, span])
		ok(absf(span[1] - want[i][1]) <= SWEPT_RES + SWEPT_TOL / 10, "interval %d %s" % [i, span])

func test_swept_clash_a_miss_is_seen_only_within_the_clearance():
	var collider := swept_collider()
	var passing := [[at(-5, 2.5), at(0)], [at(5, 2.5), at(0)]]
	var none = collider.swept_clash(passing, 0.4)
	ok(none is Array and none.is_empty(), "clearance 0.4: %s %s" % [none, Cadaclysm.last_error()])
	var rows = collider.swept_clash(passing, 0.6)
	ok(rows is Array, "refused: " + Cadaclysm.last_error())
	eq(rows.size(), 1)
	var r: CadaclysmSweptClash = rows[0]
	eq(r.first.kind, "too_close")
	ok(r.first.distance >= 0.5 - SWEPT_TOL and r.first.distance <= 0.6, "distance %s" % r.first.distance)
	eq(r.intervals.size(), 1)

func test_swept_clash_a_pair_starting_inside_rebuilds_the_overlap_at_its_first_time():
	# The cubes share a 0.25 slab at t = 0, then a moves clear.
	var collider := swept_collider()
	var rows = collider.swept_clash([[at(1.75), at(0)], [at(5), at(0)]])
	collider.close()
	ok(rows is Array, "refused: " + Cadaclysm.last_error())
	eq(rows.size(), 1)
	var r: CadaclysmSweptClash = rows[0]
	eq(r.first_time, 0.0)
	eq(r.first.kind, "penetrating")
	var shared: CadaclysmSolid = r.first.solid()
	ok(shared != null, "solid refused: " + Cadaclysm.last_error())
	if shared != null:
		near(shared.mass(1e-6)["volume"], 1.0, 1e-6, "shared volume")

func test_swept_clash_one_shot_indexes_the_second_set_and_agrees_with_the_collider():
	# Set a still at the origin and at y = 20; set b carried along x through them.
	var a0 := CadaclysmSolid.cuboid(2, 2, 2)
	var a1 := CadaclysmSolid.cuboid(2, 2, 2).translate(0, 20, 0)
	var b0 := CadaclysmSolid.cuboid(2, 2, 2)
	var b1 := CadaclysmSolid.cuboid(2, 2, 2)
	var still := [[at(0), at(0)], [at(0), at(0)]]
	var moving := [[at(-5), at(-5, 20)], [at(5), at(5, 20)]]
	var two = CadaclysmBlacksmith.swept_clash([a0, a1], still, [b0, b1], moving, 0.0, SWEPT_TOL)
	ok(two is Array, "refused: " + Cadaclysm.last_error())
	eq(swept_pairs(two), [[0, 0], [1, 1]])
	eq(two.map(func(r): return [r.first.a, r.first.b]), [[0, 0], [1, 1]])
	var collider := CadaclysmCollider.create([a0, a1, b0, b1], SWEPT_TOL)
	var via = collider.swept_clash([still[0] + moving[0], still[1] + moving[1]])
	ok(via is Array, "refused: " + Cadaclysm.last_error())
	eq(swept_rows(via, 2), swept_rows(two))
	var one = CadaclysmBlacksmith.swept_clash([a0, b0], [[at(0), at(-5)], [at(0), at(5)]], null, null, 0.0, SWEPT_TOL)
	ok(one is Array, "refused: " + Cadaclysm.last_error())
	eq(swept_pairs(one), [[0, 1]])
	var spared = CadaclysmBlacksmith.swept_clash([a0, b0], [[at(0), at(-5)], [at(0), at(5)]], null, null, 0.0, SWEPT_TOL, SWEPT_RES, 100000, PackedInt32Array([0, 1]))
	ok(spared is Array and spared.is_empty(), "allowed (0, 1): %s" % [spared])

func test_swept_clash_refusals_carry_the_calls_prefix():
	var a := CadaclysmSolid.cuboid(2, 2, 2)
	var b := CadaclysmSolid.cuboid(2, 2, 2)
	var collider := CadaclysmCollider.create([a, b], SWEPT_TOL)
	# A refusal is null, never an empty clear array.
	var rows = collider.swept_clash(through().slice(0, 1))
	ok(typeof(rows) == TYPE_NIL, "one pose returned %s, not null" % [rows])
	var message := Cadaclysm.last_error()
	ok(message.begins_with("collider_swept_clash: 1 poses, at least 2 are needed"), message)
	refused(func(): return collider.swept_clash([[at(0)], [at(0)]]), "collider_swept_clash: 1 frames for 2 groups")
	refused(func(): return collider.swept_clash([[at(0), at(0)], [at(0)]]), "collider_swept_clash: 1 frames for 2 groups")
	refused(func(): return collider.swept_clash(through(), 0.0, 0.0), "collider_swept_clash: resolution 0")
	refused(func(): return collider.swept_clash(through(), 0.0, SWEPT_RES, 0), "collider_swept_clash: max_steps must be at least 1")
	refused(func(): return collider.swept_clash(through(), 0.0, SWEPT_RES, -1), "collider_swept_clash: max_steps -1")
	refused(func(): return collider.swept_clash(through(), -1.0), "collider_swept_clash: clearance -1")
	refused(func(): return collider.swept_clash(through(), 0.0, SWEPT_RES, 100000, 2, 2), "collider_swept_clash: share (2, 2)")
	refused(func(): return collider.swept_clash(through(), 0.0, SWEPT_RES, 100000, -1, 2), "collider_swept_clash: share (-1, 2)")
	refused(func(): return collider.swept_clash([5, 6]), "collider_swept_clash: pose 0 is an array of frames")
	refused(func(): return collider.swept_clash([[at(0), at(0)], [at(0), 7]]), "collider_swept_clash: frame 1 of pose 1")
	eq(swept_pairs(collider.swept_clash(through())), [[0, 1]])
	collider.close()
	message = refuses(func(): return collider.swept_clash(through()))
	ok(message.contains("closed"), message)
	var still := [[at(0)], [at(0)]]
	refused(func(): return CadaclysmBlacksmith.swept_clash([a], still, [b], null), "swept_clash: others and other_poses go together")
	refused(func(): return CadaclysmBlacksmith.swept_clash([a], still, null, still), "swept_clash: others and other_poses go together")
	refused(func(): return CadaclysmBlacksmith.swept_clash([a], still, [b], still.slice(0, 1)), "swept_clash: 2 poses for set a, 1 for set b")
	refused(func(): return CadaclysmBlacksmith.swept_clash([a], [[at(0), at(0)], [at(0)]], null, null), "swept_clash: pose 0 of set a has 2 frames for 1 parts")
	refused(func(): return CadaclysmBlacksmith.swept_clash([a], still, [b], [[at(0)], [at(0), at(0)]]), "swept_clash: pose 1 of set b has 2 frames for 1 parts")
	rows = CadaclysmBlacksmith.swept_clash([a], still, [], [[], []])
	ok(typeof(rows) == TYPE_NIL, "an empty others returned %s, not null" % [rows])
	message = Cadaclysm.last_error()
	ok(message.begins_with("swept_clash: an empty set"), message)
	refused(func(): return CadaclysmBlacksmith.swept_clash([a, b], through(), null, null, 0.0, 0.05, SWEPT_RES, 100000, PackedInt32Array([5, 0])), "swept_clash: allowed pair (5, 0) names a part out of range")
	refused(func(): return CadaclysmBlacksmith.swept_clash([a, b], through(), null, null, 0.0, 0.05, SWEPT_RES, 100000, PackedInt32Array([0, 1, 1])), "swept_clash: allowed is 3 numbers, not pairs")
	refused(func(): return CadaclysmBlacksmith.swept_clash([a, b], through(), null, null, 0.0, 0.05, SWEPT_RES, 100000, PackedInt32Array([0, -1])), "swept_clash: allowed pair (0, -1) is not two indices")
	refused(func(): return CadaclysmBlacksmith.swept_clash([a, b], through(), null, null, 0.0, 0.05, SWEPT_RES, 0), "swept_clash: max_steps must be at least 1")
	refused(func(): return CadaclysmBlacksmith.swept_clash([a, b], through().slice(0, 1), null, null), "swept_clash: 1 poses, at least 2 are needed")
	refused(func(): return CadaclysmBlacksmith.swept_clash([a, b], through(), 5, still), "swept_clash: others is null or an array")
	refused(func(): return CadaclysmBlacksmith.swept_clash([a], still, [b], 5), "swept_clash: other_poses is null or an array")
	refused(func(): return CadaclysmBlacksmith.swept_clash([a, 5], through(), null, null), "swept_clash: parts")

func rot_z(degrees: float, origin: Array) -> Array:
	var r := deg_to_rad(degrees)
	return [origin[0], origin[1], origin[2], cos(r), sin(r), 0, -sin(r), cos(r), 0, 0, 0, 1]

func test_boxes_apart_on_the_45_degree_case():
	# Two unit boxes, the second turned 45 degrees about z: corner to face apart along x
	# by more than sqrt(2) + 1 -> apart; closer -> not apart, even though their world
	# AABBs already overlap there. Frames as raw twelve-number arrays, as every other
	# frame-taking call here accepts.
	var unit := CadaclysmBox.create(Vector3(-1, -1, -1), Vector3(1, 1, 1))
	var identity := XY
	ok(CadaclysmBox.boxes_apart(unit, identity, unit, rot_z(45.0, [2.5, 0, 0])))
	ok(not CadaclysmBox.boxes_apart(unit, identity, unit, rot_z(45.0, [2.3, 0, 0])))
	ok(unit.moved(identity).overlaps(unit.moved(rot_z(45.0, [2.3, 0, 0]))))
	var touching := [2, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]
	ok(not CadaclysmBox.boxes_apart(unit, identity, unit, touching))

func test_split_sheet_cuts_a_sheet_along_a_solids_boundary():
	var sheet := CadaclysmSolid.extrude_open(CadaclysmProfile.rect(40, 40), XY, 20)
	eq(sheet.faces, 4)
	var tool := CadaclysmSolid.cuboid(10, 10, 10).translate(20, 0, 10)
	ok(sheet.split_sheet(tool).faces > sheet.faces, "the straddled wall comes out in more than one piece")
	var message := refuses(func(): return sheet.split_sheet(tool, -1))
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
	refuses(func(): return CadaclysmSweepPath.along(wave, XY, -1), "along: the tolerance must be positive and finite")

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
	# A count a u32 cannot hold is refused before the call, not read as 0.
	for n in [-1, 4294967302]:
		message = refuses(func(): return CadaclysmProfile.regular_polygon([0, 0], 10, n))
		eq(message, "profile_regular_polygon: sides is out of range: %d" % n)
		message = refuses(func(): return CadaclysmProfile.star([0, 0], 10, 4, n))
		eq(message, "profile_star: points is out of range: %d" % n)

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
	refuses(func(): return ball.mesh(-1), "mesh")

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
	var mesh := CadaclysmScene.open_bytes("square(10);".to_utf8_buffer(), "scad", {})
	var cube: CadaclysmNode = null
	for n in mesh.nodes:
		if cube == null and n.brep == null:
			cube = n
	ok(cube != null, "a node with no brep")
	message = refuses(func(): return CadaclysmSolid.from_node(cube))
	ok(message.begins_with("from_node: node ") and message.contains("has no brep"), message)
	mesh.close()
	# A flat OpenSCAD sheet draws no solid; a cube is one exact solid of volume 1000.
	var sheet := tmp("sheet.scad")
	var g := FileAccess.open(sheet, FileAccess.WRITE)
	g.store_string("square(10);\n")
	g.close()
	refuses(func(): return CadaclysmSolid.open(sheet), "open: the .scad file draws no B-rep body")
	# A cube is a B-rep only where the reader library was built with the kernel
	# (`cadaclysm-capi`'s `openscad-brep`); in the Reader flavour OpenSCAD is a mesh.
	var probe := CadaclysmScene.open_bytes("cube(10);".to_utf8_buffer(), "scad", {})
	var exact: bool = probe.nodes[0].brep != null
	probe.close()
	if exact:
		var scad := tmp("cube.scad")
		var f := FileAccess.open(scad, FileAccess.WRITE)
		f.store_string("cube(10);\n")
		f.close()
		eq(CadaclysmSolid.open_all(scad).size(), 1)
		near(CadaclysmSolid.open(scad).mass(1e-7)["volume"], 1000, 1e-6)

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
	refuses(func(): return a.hits(a, -1.0), "profile_hits: tolerance must be positive and finite")
	eq(a.hits(a, -1.0).size(), 0, "empty on failure")

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
	refuses(func(): return box.hits(line, XY, -1.0), "solid_profile_hits: tolerance must be positive and finite")

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
	refuses(func(): return a.intersect(b, -1.0), "intersect: tolerance must be positive and finite")
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

func test_a_tube_swept_through_itself_reports_its_crossing_and_a_cube_nothing():
	var tol := 1e-3
	# A thin rectangle swept open along a path that comes back across its own start: a line to
	# (10, 0, 0), a 270-degree turn about (10, 3, 0), a line down to (7, -5, 0) -- through the
	# first leg at (7, 0). The profile's x along world y, its y along world z.
	var back := CadaclysmSweepPath.at([0, 0, 0]).line_to([10, 0, 0]).arc([10, 3, 0], [0, 0, 1], 1.5 * PI).line_to([7, -5, 0])
	var tube := CadaclysmSolid.sweep_open(CadaclysmProfile.rect(0.2, 5), [0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0], back)
	var found = tube.self_intersections(tol)
	ok(found is CadaclysmIntersection, "self_intersections refused: " + Cadaclysm.last_error())
	ok(found.chains.size() > 0, "the tube passes through itself at (7, 0)")
	for c in found.chains:
		ok(c.face_a != c.face_b and c.face_a < tube.faces and c.face_b < tube.faces, "two walls, not a fold: " + str(c))
		ok(c.curve != null and c.curve.kind == "line", "two planar walls cross in a line: " + str(c))
		var s: PackedFloat64Array = c.raw_points
		for k in range(0, s.size(), 3):
			ok(absf(s[k] - 7) <= 0.1 + tol and absf(s[k + 1]) <= 0.1 + tol and absf(s[k + 2]) <= 2.5 + tol, "off the crossing: " + str(c))
	var clean = CadaclysmSolid.cuboid(4, 6, 8).self_intersections(tol)
	eq([clean.chains.size(), clean.overlaps.size()], [0, 0])
	refuses(func(): return tube.self_intersections(-1.0), "self_intersect: tolerance must be positive and finite")

func test_check_finds_a_tube_through_itself_its_free_edges_for_a_cut_and_nothing_wrong_with_two_cubes():
	var tol := 1e-3
	# The tube of the test above: a thin rectangle swept open back across its own start at (7, 0).
	var back := CadaclysmSweepPath.at([0, 0, 0]).line_to([10, 0, 0]).arc([10, 3, 0], [0, 0, 1], 1.5 * PI).line_to([7, -5, 0])
	var tube := CadaclysmSolid.sweep_open(CadaclysmProfile.rect(0.2, 5), [0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0], back)
	var cube := CadaclysmSolid.cuboid(1, 1, 1)
	var fine = cube.check(null)
	ok(fine is Array and fine.is_empty(), "a cube reads " + str(fine) + " " + Cadaclysm.last_error())
	fine = cube.check(CadaclysmSolid.sphere(2), "join", tol)
	ok(fine is Array and fine.is_empty(), "a cube and a sphere to join read " + str(fine))
	var alone = tube.check(null, "", tol)
	ok(alone is Array and alone.size() > 0, "the tube passes through itself at (7, 0): " + Cadaclysm.last_error())
	for f in alone:
		ok(f is CadaclysmFinding, "a finding: " + str(f))
		eq(f.kind, "self_intersection", "an open sheet is no fault alone")
		eq(f.argument, 0)
		ok(f.index >= 0 and f.other >= 0 and f.index != f.other and f.size > 0.1, str(f))
	var as_cut = tube.check(cube, "cut", tol)
	var open := (as_cut as Array).filter(func(f): return f.kind == "open")
	ok(open.size() > 0 and open.all(func(f): return f.argument == 0 and f.other >= 0 and f.size > 0), str(open))
	ok((as_cut as Array).all(func(f): return f.argument == 0), "the cube is fine: " + str(as_cut))
	var as_trim = cube.check(tube, "trim", tol)
	ok((as_trim as Array).any(func(f): return f.kind == "open" and f.argument == 1), "a trim's tool must be closed: " + str(as_trim))
	var small = CadaclysmSolid.cuboid(4, 4, 0.01).check(null, "", 0.05)
	ok((small as Array).any(func(f): return f.kind == "short_edge" and f.index >= 0 and f.other == -1 and f.size < 0.05), str(small))
	eq(cube.check(cube, "union"), null)
	refuses(func(): return cube.check(cube, "union"), 'check: unknown operation "union" (join, cut, common, split_sheet, trim, merge or intersect)')
	refuses(func(): return cube.check(null, "", -1.0), "check: tolerance must be positive and finite")

func test_two_circles_share_one_lens_of_arcs():
	var a := CadaclysmProfile.circle(5)
	var b := CadaclysmProfile.circle(5).translate(6, 0)
	var lenses := a.common(b)
	eq(lenses.size(), 1)
	ok(lenses[0] is CadaclysmProfile)
	# Four arcs (each circle's own seam stays a join) between two caps.
	eq(CadaclysmSolid.extrude(lenses[0], XY, 1).faces, 6)
	eq(a.common(b.translate(100, 0)).size(), 0)
	refuses(func(): return a.common(b, -1.0), "profile_common: tolerance must be positive and finite")
	eq(a.common(b, -1.0).size(), 0, "empty on failure")

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
	eq(mesh.crossings.size(), 0, "kernel fem: the rounded box does not cross itself")
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
	# Unlike the two censuses above, `crossings` is computed for every solid, open or
	# closed -- a flat sheet with no self-intersection still reads an empty list, not "not asked".
	eq(mesh.crossings.size(), 0, "kernel fem: a flat sheet does not cross itself")
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

# Crossings through the kernel's own open of a file: `samples/dented-box.stp` is a closed
# B-rep box whose top dips through its own floor, 296 pairs measured 2026-09-26 -- the same
# number reader_test.gd's census-wiring test reads through the reader over the same file,
# which must agree with it.
func test_fem_the_kernel_reports_the_same_crossings_opening_a_file_directly():
	var path := fixture("samples/dented-box.stp")
	if path == "":
		return
	var solid := CadaclysmSolid.open(path)
	if not ok(solid != null, "kernel fem: " + Cadaclysm.last_error()):
		return
	var mesh: CadaclysmSolidFemMesh = solid.fem_mesh()
	if not ok(mesh != null, "kernel fem: " + Cadaclysm.last_error()):
		return
	eq(mesh.watertight, true)
	var crossings := mesh.crossings
	eq(crossings.size(), 296)
	if crossings.size() > 0:
		ok(crossings[0][0] < crossings[0][1], "the first pair is not a < b")
	mesh.release()
	solid.close()

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

func test_a_material_and_an_outside_style_ride_operations_and_reach_step():
	var cube := CadaclysmSolid.cuboid(1, 1, 1)
	eq(cube.material, "", "a fresh cuboid has no material")
	var steel := cube.with_material("Steel").styled("materials/steel.mtlx", "BrushedSteel")
	eq(steel.material, "Steel")
	eq(steel.style_location, "materials/steel.mtlx")
	eq(steel.style_identification, "BrushedSteel")
	var tool := cube.with_material("Oak").translate(0.5, 0.5, 0.5)
	var cut := steel.cut(tool)
	eq(cut.material, "Steel", "a cut is made of its target's material")
	eq(cut.style_identification, "BrushedSteel")
	eq(cube.styled("", "BrushedSteel").style_location, "", "an empty location is left out")
	var text := steel.step_text()
	ok(text.contains("MATERIAL_DESIGNATION('Steel'"), "the material reaches STEP")
	ok(text.contains("EXTERNALLY_DEFINED_STYLE(IDENTIFIER('BrushedSteel')"), "the style reaches STEP")
	refuses(func(): return cube.with_material(" "), "blank")
	refuses(func(): return cube.styled("", ""), "location or an identification")

func test_assembly_create_close_and_get_name():
	refuses(func(): return CadaclysmAssembly.create(""), "name")
	var top := CadaclysmAssembly.create("top")
	eq(top.name, "top")
	top.close()
	eq(top.name, "", "a closed assembly reads its name as \"\"")
	refuses(func(): return top.place(CadaclysmSolid.cuboid(1, 1, 1), XY), "closed")

# `CadaclysmAssembly.link`/`joint`, at parity with the Python reference's
# `_mechanism()` and its two mechanism tests -- see the Rust suite's `mechanisms()`
# for the same facts worked out, and this crate's own `blacksmith::tests` for the
# same build in test form.
func _mechanism_arm() -> Array:
	# Spec 2026-09-25 section 6's fixture. The plate is left unpainted, so the AP242
	# default fact 1 checks comes from the mechanism, not from paint.
	var bolt := CadaclysmSolid.cylinder(1, 6).named("bolt")
	var plate := CadaclysmSolid.cuboid(20, 10, 2).named("plate")
	var bracket := CadaclysmAssembly.create("bracket")
	bracket.place(plate, XY)
	bracket.place(bolt, CadaclysmFrame.xy(Vector3(5, 5, 2)))
	bracket.place(bolt, CadaclysmFrame.xy(Vector3(15, 5, 2)))
	ok(bracket.link("fixed", ["plate"]), "bracket.link fixed")
	ok(bracket.link("bolts", ["bolt", "bolt 2"]), "bracket.link bolts")
	ok(bracket.joint("screw", "fixed", "bolts"), "bracket.joint screw")
	var arm := CadaclysmAssembly.create("arm")
	arm.place(plate, XY, "base")
	arm.place(bracket, CadaclysmFrame.xy(Vector3(0, 0, 10)), "upper")
	arm.place(bolt, CadaclysmFrame.xy(Vector3(5, 5, 2)), "pin")
	ok(arm.link("ground", ["base"]), "arm.link ground")
	ok(arm.link("upper arm", ["upper", "pin"]), "arm.link upper arm")
	ok(arm.joint("shoulder", "ground", "upper arm"), "arm.joint shoulder")
	return [bracket, arm]

func test_a_mechanism_is_written_as_ap242_kinematic_topology():
	var shared := _mechanism_arm()
	var arm: CadaclysmAssembly = shared[1]
	# Fact 1: the default schema (no explicit schema) carries the kinematic entities.
	var text := arm.step_text()
	ok(text.contains("AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF"), "arm.step_text() is not AP242")
	eq(text.count("=KINEMATIC_LINK("), 4)
	eq(text.count("=RIGID_LINK_REPRESENTATION("), 6)
	eq(text.count("=CONTEXT_DEPENDENT_KINEMATIC_LINK_REPRESENTATION("), 6)
	eq(text.count("=KINEMATIC_JOINT("), 2)
	eq(text.count("=KINEMATIC_TOPOLOGY_STRUCTURE("), 2)
	# Fact 2: an explicit schema without kinematic entities is refused.
	refuses(func(): return arm.step_text("config_control_design"), "no kinematic entities")

func test_every_bad_link_or_joint_is_refused_and_changes_nothing():
	var shared := _mechanism_arm()
	var arm: CadaclysmAssembly = shared[1]
	var no_stamp := func(text: String) -> String:
		var lines := []
		for line in text.split("\n"):
			if not line.begins_with("FILE_NAME("):
				lines.append(line)
		return "\n".join(lines)
	# Fact 3: each of the eleven refusals raises with exactly its message, and
	# afterwards the STEP text (with `FILE_NAME(` lines stripped) is unchanged.
	var before: String = no_stamp.call(arm.step_text())
	var refusals := [
		[func(): return arm.link("", ["base"]), "link: a name cannot be empty"],
		[func(): return arm.link("ground", ["base"]), "link: assembly 'arm' already has a link named 'ground'"],
		[func(): return arm.link("free", []), "link: link 'free' names no placements"],
		[func(): return arm.link("free", ["base", "base"]), "link: link 'free' names placement 'base' twice"],
		[func(): return arm.link("free", ["bolt"]), "link: assembly 'arm' has no placement named 'bolt'"],
		[func(): return arm.link("free", ["pin"]), "link: placement 'pin' of assembly 'arm' is already in link 'upper arm'"],
		[func(): return arm.joint("", "ground", "upper arm"), "joint: a name cannot be empty"],
		[func(): return arm.joint("shoulder", "upper arm", "ground"), "joint: assembly 'arm' already has a joint named 'shoulder'"],
		[func(): return arm.joint("wrist", "ground", "hand"), "joint: assembly 'arm' has no link named 'hand'"],
		[func(): return arm.joint("wrist", "ground", "ground"), "joint: joint 'wrist' joins link 'ground' to itself"],
		[func(): return arm.joint("wrist", "ground", "upper arm"), "joint: assembly 'arm' already joins 'ground' to 'upper arm'"],
	]
	for pair in refusals:
		var message: String = refuses(pair[0])
		eq(message, pair[1], "refusal message")
	eq(no_stamp.call(arm.step_text()), before, "arm.step_text() changed across the eleven refused calls")
	# Fact 4: the reverse pair is a new joint.
	ok(arm.joint("back", "upper arm", "ground"), "the reverse pair should be accepted: " + Cadaclysm.last_error())

# Fact 5: read-back through the reader's links and joints, which come with the
# reader's kinematics ABI, branch claude/kinematic-abi (merged into this checkout).
func test_a_mechanism_reads_back_through_to_scene():
	var shared := _mechanism_arm()
	var arm: CadaclysmAssembly = shared[1]
	var scene := arm.to_scene()
	if not ok(scene != null, "to_scene: " + Cadaclysm.last_error()):
		return
	eq(scene.links.map(func(l): return l.name), ["fixed", "bolts", "ground", "upper arm"])
	eq(scene.links.map(func(l): return l.nodes.size()), [1, 2, 1, 2])
	eq(scene.joints.map(func(j): return [j.name, j.start.index, j.end.index]), [["screw", 0, 1], ["shoulder", 2, 3]])
	var kinematics_diagnostics := 0
	for d in scene.diagnostics:
		if String(d).begins_with("kinematics:"):
			kinematics_diagnostics += 1
	eq(kinematics_diagnostics, 0, "no kinematics: diagnostic")
	scene.close()

# `CadaclysmAssembly.pair`/`state`/`base`, at parity with the Python reference's
# `_paired()` and its tests -- see the Rust SDK's `blacksmith::tests::paired` for the
# same facts worked out, and the LuaJIT/Node suites for the same build in their own
# forms. Godot compares frames as `Transform3D` (single precision), so facts 2 and 3
# check origins and axes within 1e-4, not the Rust SDK's 1e-9.
func _paired_arm() -> Array:
	var shared := _mechanism_arm()
	var bracket: CadaclysmAssembly = shared[0]
	var arm: CadaclysmAssembly = shared[1]
	ok(bracket.pair("screw", "prismatic", CadaclysmFrame.xy(Vector3(1, 2, 3)), CadaclysmFrame.xy(Vector3(4, 2, 3)), [], NAN),
		"bracket.pair screw: " + Cadaclysm.last_error())
	ok(arm.pair("shoulder", "revolute", CadaclysmFrame.xy(Vector3(0, 0, 10)), null, [[-1.5, 1.5]], NAN),
		"arm.pair shoulder: " + Cadaclysm.last_error())
	ok(arm.state("reach", [["shoulder", PackedFloat64Array([0.5])]]), "arm.state reach: " + Cadaclysm.last_error())
	ok(arm.base("ground"), "arm.base ground: " + Cadaclysm.last_error())
	return shared

# Fact 1: `arm.step_text()` carries exactly the pair/state entity counts the Python
# reference's `_paired()` fixture gives.
func test_a_paired_mechanism_is_written_as_ap242_kinematic_pairs_and_states():
	var shared := _paired_arm()
	var arm: CadaclysmAssembly = shared[1]
	var text := arm.step_text()
	eq(text.count("=MECHANISM_REPRESENTATION("), 2)
	eq(text.count("=PAIR_REPRESENTATION_RELATIONSHIP("), 2)
	eq(text.count("REVOLUTE_PAIR_WITH_RANGE"), 1)
	eq(text.count("PRISMATIC_PAIR"), 1)
	eq(text.count("=KINEMATIC_PROPERTY_MECHANISM_REPRESENTATION("), 1)
	eq(text.count("=MECHANISM_STATE_REPRESENTATION("), 1)

# Facts 2, 3, 4, 5, 6 and 9: read back through `to_scene`.
func test_a_paired_mechanism_reads_back_through_to_scene():
	var shared := _paired_arm()
	var arm: CadaclysmAssembly = shared[1]
	var scene := arm.to_scene()
	if not ok(scene != null, "to_scene: " + Cadaclysm.last_error()):
		return

	# Fact 2: shoulder's pair is revolute, both world frames at (0, 0, 10) with z
	# (0, 0, 1), one freedom about z ranged [-1.5, 1.5].
	var shoulder: CadaclysmJoint
	for j in scene.joints:
		if j.name == "shoulder":
			shoulder = j
	ok(shoulder != null, "shoulder joint not found")
	var s_pair: CadaclysmPair = shoulder.pair
	eq(s_pair.kind, "revolute")
	for t in [s_pair.frame_start, s_pair.frame_end]:
		ok(v3near(t.origin, Vector3(0, 0, 10), 1e-4), "shoulder frame origin: " + str(t.origin))
		ok(v3near(t.basis.z, Vector3(0, 0, 1), 1e-4), "shoulder frame z: " + str(t.basis.z))
	var freedoms := s_pair.freedoms
	eq(freedoms.size(), 1)
	eq(freedoms[0].motion, "rotation")
	eq(freedoms[0].axis, "z")
	ok(absf(freedoms[0].lower - (-1.5)) < 1e-4, "shoulder lower")
	ok(absf(freedoms[0].upper - 1.5) < 1e-4, "shoulder upper")

	# Fact 3: screw's pair is prismatic with no ranges; world start (1, 2, 13), end
	# (4, 2, 13).
	var screw: CadaclysmJoint
	for j in scene.joints:
		if j.name == "screw":
			screw = j
	ok(screw != null, "screw joint not found")
	var sc_pair: CadaclysmPair = screw.pair
	eq(sc_pair.kind, "prismatic")
	for f in sc_pair.freedoms:
		ok(is_nan(f.lower) and is_nan(f.upper), "screw: expected an unbounded freedom")
	ok(v3near(sc_pair.frame_start.origin, Vector3(1, 2, 13), 1e-4), "screw frame_start origin")
	ok(v3near(sc_pair.frame_end.origin, Vector3(4, 2, 13), 1e-4), "screw frame_end origin")

	# Fact 4: the base is 'ground'; one state 'reach' with one row (shoulder, [0.5]).
	eq(scene.base.name, "ground")
	eq(scene.states.map(func(s): return s.name), ["reach"])
	var reach: CadaclysmState = scene.states[0]
	eq(reach.values.size(), 1)
	eq(reach.values[0].joint.name, "shoulder")
	ok(absf(reach.values[0].values[0] - 0.5) < 1e-9, "reach value")

	# Fact 5: pose_state(reach) carries the pin node's origin (5, 5, 2) to
	# (5cos0.5 - 5sin0.5, 5sin0.5 + 5cos0.5, 2) within 1e-4.
	var pose := scene.pose_state(reach, null)
	var upper_arm: CadaclysmLink
	for l in scene.links:
		if l.name == "upper arm":
			upper_arm = l
	var pin_node: CadaclysmNode
	for n in upper_arm.nodes:
		if v3near(n.transform.origin, Vector3(5, 5, 2), 1e-4):
			pin_node = n
	ok(pin_node != null, "pin node at (5, 5, 2) not found")
	var want := Vector3(5 * cos(0.5) - 5 * sin(0.5), 5 * sin(0.5) + 5 * cos(0.5), 2)
	var posed := pose.transform(pin_node)
	ok(v3near(posed.origin, want, 1e-4), "posed pin node: " + str(posed.origin))

	# Fact 6: pose([(screw, [3.0])]) leaves every node at rest (drawn at 3); pose at
	# 5.0 moves each 'bolts' node by (2, 0, 0).
	var pose3 := scene.pose([CadaclysmStateValue.create(screw, PackedFloat64Array([3.0]))], null)
	var pose5 := scene.pose([CadaclysmStateValue.create(screw, PackedFloat64Array([5.0]))], null)
	var bolts: CadaclysmLink
	for l in scene.links:
		if l.name == "bolts":
			bolts = l
	for n in bolts.nodes:
		var rest: Transform3D = n.transform
		var t3: Transform3D = pose3.transform(n)
		var t5: Transform3D = pose5.transform(n)
		ok(v3near(t3.origin, rest.origin, 1e-4), "pose at the rest value moved a node")
		ok(v3near(t5.origin, rest.origin + Vector3(2, 0, 0), 1e-4), "pose at 5.0")

	# Fact 9: no diagnostic names kinematics.
	var kinematics_diagnostics := 0
	for d in scene.diagnostics:
		if String(d).begins_with("kinematics:"):
			kinematics_diagnostics += 1
	eq(kinematics_diagnostics, 0, "no kinematics: diagnostic")
	scene.close()

# `CadaclysmAssembly.sequence`: written, read back, and one exact refusal.
func test_a_written_sequence_reads_back_and_a_bad_state_is_refused():
	var shared := _paired_arm()
	var arm: CadaclysmAssembly = shared[1]
	ok(arm.state("rest", [["shoulder", PackedFloat64Array([0.0])]]), "arm.state rest: " + Cadaclysm.last_error())
	ok(arm.sequence("swing", [["rest", 0.0, "linear"], ["reach", 1.0, "linear"]], true), "arm.sequence: " + Cadaclysm.last_error())
	refuses(func(): return arm.sequence("bad", [["rest", 0.0, "linear"], ["nowhere", 1.0, "linear"]]),
		"sequence: assembly 'arm' has no state named 'nowhere'")
	var scene := arm.to_scene()
	if not ok(scene != null, "to_scene: " + Cadaclysm.last_error()):
		return
	var sequences: Array = scene.sequences
	eq(sequences.size(), 1)
	var swing: CadaclysmSequence = sequences[0]
	eq(swing.name, "swing")
	eq(swing.closed, true)
	eq(swing.seconds_per_unit, 1.0)
	eq(swing.segments.map(func(s): return [s.state.name, s.t, s.interpolation]),
		[["rest", 0.0, "linear"], ["reach", 1.0, "linear"]])
	scene.close()

# Fact 7: each of the eight refusals fails with exactly its message, and afterwards the
# STEP text (with `FILE_NAME(` lines stripped) is unchanged -- the unpaired-"back" trick.
func test_every_bad_pair_state_or_base_call_is_refused_and_changes_nothing():
	var shared := _paired_arm()
	var arm: CadaclysmAssembly = shared[1]
	ok(arm.joint("back", "upper arm", "ground"), "joint back: " + Cadaclysm.last_error())
	var no_stamp := func(text: String) -> String:
		var lines := []
		for line in text.split("\n"):
			if not line.begins_with("FILE_NAME("):
				lines.append(line)
		return "\n".join(lines)
	var before: String = no_stamp.call(arm.step_text())
	var xy0 := CadaclysmFrame.xy(Vector3(0, 0, 0))
	var turned := CadaclysmFrame.at(Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0))
	var refusals := [
		[func(): return arm.pair("shoulder", "revolute", CadaclysmFrame.xy(Vector3(0, 0, 10)), null, [], NAN),
			"pair: joint 'shoulder' already has a pair"],
		[func(): return arm.pair("back", "orbital", xy0, null, [], NAN),
			"pair: 'orbital' is not a pair kind (revolute, prismatic, cylindrical, screw, gear, rack_and_pinion, spherical, " + \
			"spherical_with_pin, planar, universal, homokinetic, fully_constrained, unconstrained)"],
		[func(): return arm.pair("back", "screw", xy0, null, [], NAN), "pair: a screw needs a non-zero pitch"],
		[func(): return arm.pair("back", "revolute", xy0, null, [[-1.0, 1.0], [-1.0, 1.0]], NAN),
			"pair: 'revolute' has 1 freedoms, but 2 ranges were given"],
		[func(): return arm.pair("back", "revolute", xy0, null, [[1.0, -1.0]], NAN),
			"pair: range 0 of joint 'back' has lower >= upper"],
		[func(): return arm.pair("back", "prismatic", turned, xy0, [], NAN),
			"pair: joint 'back' is prismatic, but its end frame is turned 90° about -z, which prismatic (does not turn) cannot make"],
		[func(): return arm.state("overreach", [["shoulder", PackedFloat64Array([5.0])]]),
			"state: value 0 of joint 'shoulder' is outside its range"],
		[func(): return arm.base("upper arm"), "base: assembly 'arm' already has base 'ground'"],
	]
	for pair in refusals:
		var message: String = refuses(pair[0])
		eq(message, pair[1], "refusal message")
	eq(no_stamp.call(arm.step_text()), before, "arm.step_text() changed across the eight refused calls")

# Fact 8: a joint with no pair is refused only when `step_text()` is written, with
# exactly this message.
func test_a_joint_without_a_pair_is_refused_at_write_time():
	var shared := _paired_arm()
	var arm: CadaclysmAssembly = shared[1]
	ok(arm.joint("back", "upper arm", "ground"), "joint back: " + Cadaclysm.last_error())
	refuses(func(): return arm.step_text(),
		"assembly_step: assembly 'arm': joint 'back' has no pair; a mechanism with pairs needs one on every joint (AP242)")

# Fact 9's `pair_freedom_count` half.
func test_pair_freedom_count_reports_known_and_unknown_kinds():
	eq(CadaclysmBlacksmith.pair_freedom_count("spherical"), 3)
	eq(CadaclysmBlacksmith.pair_freedom_count("revolute"), 1)
	eq(CadaclysmBlacksmith.pair_freedom_count("fully_constrained"), 0)
	eq(CadaclysmBlacksmith.pair_freedom_count("not_a_kind"), 0)

# Controller ruling, fact 10: a one-sided range survives the round trip. An
# implementation that always sent has_lower/has_upper as true would pass every other
# fact but fail this one.
func test_a_one_sided_pair_range_survives_the_round_trip():
	var plate := CadaclysmSolid.cuboid(20, 10, 2)
	var bolt := CadaclysmSolid.cylinder(1, 6)
	var hinge := CadaclysmAssembly.create("hinge")
	hinge.place(plate, CadaclysmFrame.xy(Vector3(0, 0, 0)), "base")
	hinge.place(bolt, CadaclysmFrame.xy(Vector3(0, 0, 2)), "arm")
	ok(hinge.link("base", ["base"]), "hinge.link base: " + Cadaclysm.last_error())
	ok(hinge.link("arm", ["arm"]), "hinge.link arm: " + Cadaclysm.last_error())
	ok(hinge.joint("j", "base", "arm"), "hinge.joint j: " + Cadaclysm.last_error())
	ok(hinge.pair("j", "revolute", CadaclysmFrame.xy(Vector3(0, 0, 0)), null, [[null, 1.0]], NAN),
		"hinge.pair j: " + Cadaclysm.last_error())
	var scene := hinge.to_scene()
	if not ok(scene != null, "to_scene: " + Cadaclysm.last_error()):
		return
	var j: CadaclysmJoint
	for joint in scene.joints:
		if joint.name == "j":
			j = joint
	ok(j != null, "joint j not found")
	var freedoms := j.pair.freedoms
	eq(freedoms.size(), 1)
	ok(is_nan(freedoms[0].lower), "freedom 0 should have no lower limit")
	ok(absf(freedoms[0].upper - 1.0) < 1e-9, "freedom 0 upper")
	scene.close()
# Drives plan 4's round trip, at parity with the Python reference's `_geared()`: a pinion
# turning on `drive` meshes, by the gear pair `mesh` (radii 10 and 20, ratio -0.5, bevel
# 0.25, helical 0.125), with a wheel turning on `driven` about (30, 0); the wheel's part
# sits 5 off its axis, at (35, 0, 2). The two are different parts: AP242 refuses a pair
# between two placements of one.
func _geared(mesh := true) -> CadaclysmAssembly:
	var gears := CadaclysmAssembly.create("gears")
	gears.place(CadaclysmSolid.cuboid(40, 10, 2).named("plate"), CadaclysmFrame.xy(Vector3(0, 0, 0)), "frame")
	gears.place(CadaclysmSolid.cylinder(1, 6).named("pin"), CadaclysmFrame.xy(Vector3(0, 0, 2)), "pinion")
	gears.place(CadaclysmSolid.cylinder(2, 4).named("hub"), CadaclysmFrame.xy(Vector3(35, 0, 2)), "wheel")
	ok(gears.link("base", ["frame"]), Cadaclysm.last_error())
	ok(gears.link("driver", ["pinion"]), Cadaclysm.last_error())
	ok(gears.link("follower", ["wheel"]), Cadaclysm.last_error())
	ok(gears.joint("drive", "base", "driver"), Cadaclysm.last_error())
	ok(gears.joint("driven", "base", "follower"), Cadaclysm.last_error())
	ok(gears.joint("mesh", "driver", "follower"), Cadaclysm.last_error())
	ok(gears.pair("drive", "revolute", CadaclysmFrame.xy(Vector3(0, 0, 2)), null, [], NAN), Cadaclysm.last_error())
	ok(gears.pair("driven", "revolute", CadaclysmFrame.xy(Vector3(30, 0, 2)), null, [], NAN), Cadaclysm.last_error())
	if mesh:
		ok(gears.pair_with("mesh", "gear", CadaclysmFrame.xy(Vector3(0, 0, 2)), null, [],
			PackedFloat64Array([10, 20, -0.5, 0.25, 0.125])), Cadaclysm.last_error())
	return gears

func test_a_gear_pair_round_trips_and_poses_from_its_driver():
	var scene := _geared().to_scene()
	if not ok(scene != null, "to_scene: " + Cadaclysm.last_error()):
		return
	var joints := {}
	for j in scene.joints:
		joints[j.name] = j
	var mesh: CadaclysmPair = joints["mesh"].pair
	eq([mesh.kind, mesh.kind_name], ["other", "gear"])
	ok(all_near(mesh.parameters, PackedFloat64Array([10, 20, -0.5, 0.25, 0.125])), "mesh parameters: " + str(mesh.parameters))
	var drive_pair: CadaclysmPair = joints["drive"].pair
	eq(drive_pair.kind_name, "revolute")
	eq(drive_pair.parameters.size(), 0)

	# the driver alone turns the wheel by ratio x 0.4 about (30, 0): nothing to report
	var pose := scene.pose([CadaclysmStateValue.create(joints["drive"], PackedFloat64Array([0.4]))], null)
	eq(pose.diagnostics.size(), 0)
	eq(pose.unsolved.size(), 0)
	var wheel: CadaclysmNode = scene.links[2].nodes[0]
	ok(v3near(pose.transform(wheel).origin, Vector3(30 + 5 * cos(-0.2), 5 * sin(-0.2), 2), 1e-9),
		"wheel origin: " + str(pose.transform(wheel).origin))

	# both sides given, against the law: one diagnostic, in the kernel's words
	pose = scene.pose([
		CadaclysmStateValue.create(joints["drive"], PackedFloat64Array([0.4])),
		CadaclysmStateValue.create(joints["driven"], PackedFloat64Array([0.4])),
	], null)
	eq(pose.diagnostics.size(), 1)
	ok(pose.diagnostics[0].begins_with("coupling 'mesh': both 'drive' and 'driven' are given and disagree by"),
		str(pose.diagnostics))
	scene.close()

func test_pair_with_refuses_a_wrong_parameter_count():
	var gears := _geared(false)
	var message := refuses(func(): return gears.pair_with("mesh", "gear", CadaclysmFrame.xy(Vector3(0, 0, 0)), null, [],
		PackedFloat64Array([10, 20])), "pair: a gear takes 3 or 5 parameters, not 2")
	eq(message, "pair: a gear takes 3 or 5 parameters, not 2")
	# unchanged: it takes one now
	ok(gears.pair_with("mesh", "gear", CadaclysmFrame.xy(Vector3(0, 0, 0)), null, [],
		PackedFloat64Array([10, 20, -0.5])), Cadaclysm.last_error())

# `CadaclysmAssembly.posed`, at parity with the Python reference's posed tests and the
# Rust SDK's `posed_*` tests, compared by STEP text (stamp stripped). NOT RUN locally:
# there is no Godot binary on the authoring machine.
func _posed_no_stamp(a: CadaclysmAssembly) -> String:
	var lines := []
	for line in a.step_text().split("\n"):
		if not line.begins_with("FILE_NAME("):
			lines.append(line)
	return "\n".join(lines)

# Python's `_posed_frame()`: two copies of a bracket whose bolt turns on `turn` (revolute
# about z through (10, 5, 2)), placed as `left` and `right/rear`.
func _posed_frame() -> CadaclysmAssembly:
	var bracket := CadaclysmAssembly.create("bracket")
	bracket.place(CadaclysmSolid.cuboid(20, 10, 2).named("plate"), XY)
	bracket.place(CadaclysmSolid.cuboid(1, 1, 6).named("bolt"), CadaclysmFrame.xy(Vector3(5, 5, 2)))
	ok(bracket.link("fixed", ["plate"]), Cadaclysm.last_error())
	ok(bracket.link("bolts", ["bolt"]), Cadaclysm.last_error())
	ok(bracket.joint("turn", "fixed", "bolts"), Cadaclysm.last_error())
	ok(bracket.pair("turn", "revolute", CadaclysmFrame.xy(Vector3(10, 5, 2)), null, [], NAN), Cadaclysm.last_error())
	var frame := CadaclysmAssembly.create("frame")
	frame.place(bracket, XY, "left")
	frame.place(bracket, CadaclysmFrame.xy(Vector3(100, 0, 0)), "right/rear")
	return frame

func test_posed_moves_the_shoulder():
	var arm: CadaclysmAssembly = _paired_arm()[1]
	var before := _posed_no_stamp(arm)
	var posed: CadaclysmAssembly = arm.posed({"shoulder": 0.5})
	if not ok(posed != null, "posed: " + Cadaclysm.last_error()):
		return
	eq(posed.name, "arm")
	ok(_posed_no_stamp(posed) != before, "the posed copy differs from the rest")
	eq(_posed_no_stamp(arm), before, "the original is unchanged")
	# rows as an array of pairs, a list value, and no rows at all
	eq(_posed_no_stamp(arm.posed([["shoulder", [0.5]]])), _posed_no_stamp(posed))
	eq(_posed_no_stamp(arm.posed({})), before)

func test_posed_refuses_an_ambiguous_name_and_takes_a_path_with_a_slash():
	var frame := _posed_frame()
	var before := _posed_no_stamp(frame)
	refuses(func(): return frame.posed({"turn": 0.3}),
		"posed: 'turn' names 2 joints: left/turn, right\\/rear/turn; give one by its path")
	var posed: CadaclysmAssembly = frame.posed({"right\\/rear/turn": 0.3})
	if not ok(posed != null, "posed: " + Cadaclysm.last_error()):
		return
	eq(posed.name, "frame")
	ok(_posed_no_stamp(posed) != before, "posed by path differs from the rest")
	# an array of names is escaped and joined
	eq(_posed_no_stamp(frame.posed({["right/rear", "turn"]: 0.3})), _posed_no_stamp(posed))
	eq(_posed_no_stamp(frame.posed({"right\\/rear/turn": 0.0})), before)
	eq(_posed_no_stamp(frame), before)

func test_posed_takes_a_state_and_a_ground_and_refuses_with_the_kernels_words():
	var arm: CadaclysmAssembly = _paired_arm()[1]
	var before := _posed_no_stamp(arm)
	eq(_posed_no_stamp(arm.posed({}, "reach")), _posed_no_stamp(arm.posed({"shoulder": [0.5]})))
	var held: CadaclysmAssembly = arm.posed({"shoulder": 0.5}, "", "upper arm")
	ok(_posed_no_stamp(held) != _posed_no_stamp(arm.posed({"shoulder": 0.5})), "the ground link changes the pose")
	eq(refuses(func(): return arm.posed({"shoulder": 2.0})), "posed: value 0 of joint 'shoulder' is 2, outside its range")
	eq(refuses(func(): return arm.posed({}, "fold")), "posed: assembly 'arm' has no state named 'fold'")
	eq(_posed_no_stamp(arm), before)

func test_posed_refuses_a_disagreeing_coupling():
	var gears := _geared()
	var before := _posed_no_stamp(gears)
	var posed: CadaclysmAssembly = gears.posed({"drive": 0.4})
	if ok(posed != null, "posed drive alone: " + Cadaclysm.last_error()):
		eq(posed.name, "gears")
	refuses(func(): return gears.posed({"drive": 0.4, "driven": 0.4}),
		"posed: assembly 'gears': coupling 'mesh': both 'drive' and 'driven' are given and disagree by")
	eq(_posed_no_stamp(gears), before)

# ---- an assembly's swept clash (swept clash plan 3c) --------------------------------------
# Python's `_rig` (test_cadaclysm_blacksmith.py): a `base` plate on link `ground`; an `arm`,
# cuboid(3, 0.2, 0.2) from the hinge out along x, on link `arm`, turning on `hinge`
# (revolute about z through the origin); a `carriage` far out on `slide` (cylindrical, two
# values); and two cubes in no link, held fixed: `chord` below the hinge, which the chord
# between the arm's end poses crosses and its arc never does, and `circle` on the arm's
# circle at 90 degrees.

func _rig(hand: CadaclysmAssembly = null) -> CadaclysmAssembly:
	var rig := CadaclysmAssembly.create("rig")
	rig.place(CadaclysmSolid.cuboid(1, 1, 0.4), at(0, 0, -1), "base")
	if hand == null:
		rig.place(CadaclysmSolid.cuboid(3, 0.2, 0.2), at(1.5), "arm")
	else:
		rig.place(hand, at(1.5), "hand")
	rig.place(CadaclysmSolid.cuboid(0.4, 0.4, 0.4), at(0, -1.2), "chord")
	rig.place(CadaclysmSolid.cuboid(0.4, 0.4, 0.4), at(0, 1.5), "circle")
	rig.place(CadaclysmSolid.cuboid(0.4, 0.4, 0.4), at(20), "carriage")
	ok(rig.link("ground", ["base"]), Cadaclysm.last_error())
	ok(rig.link("arm", ["arm" if hand == null else "hand"]), Cadaclysm.last_error())
	ok(rig.link("carriage", ["carriage"]), Cadaclysm.last_error())
	for spec in [["hinge", "arm", "revolute"], ["slide", "carriage", "cylindrical"]]:
		ok(rig.joint(spec[0], "ground", spec[1]), Cadaclysm.last_error())
		ok(rig.pair(spec[0], spec[2], at(0), null, [], NAN), Cadaclysm.last_error())
	ok(rig.base("ground"), Cadaclysm.last_error())
	return rig

# A `tip` cube on link `body`, and a `nub` well above it on `nubs`, turning on `turn`.
func _hand() -> CadaclysmAssembly:
	var hand := CadaclysmAssembly.create("hand")
	hand.place(CadaclysmSolid.cuboid(0.4, 0.4, 0.4), at(0), "tip")
	hand.place(CadaclysmSolid.cuboid(0.2, 0.2, 0.2), at(0, 0, 2), "nub")
	ok(hand.link("body", ["tip"]), Cadaclysm.last_error())
	ok(hand.link("nubs", ["nub"]), Cadaclysm.last_error())
	ok(hand.joint("turn", "body", "nubs"), Cadaclysm.last_error())
	ok(hand.pair("turn", "revolute", at(0), null, [], NAN), Cadaclysm.last_error())
	return hand

# The hinge at 0, 90 and 180 degrees, the carriage sliding 0, 0.5, 1 unturned.
func _swing() -> Array:
	return [{"hinge": 0.0, "slide": [0.0, 0.0]}, {"hinge": PI / 2, "slide": [0.5, 0.0]}, {"hinge": PI, "slide": [1.0, 0.0]}]

# The time the arm's leading face (y = 0.1 in its own frame) is `gap` from the circle
# cube's corner (0.2, 1.3), the first point it meets, in the first segment.
func _circle_time(gap: float) -> float:
	var r := sqrt(1.3 * 1.3 + 0.2 * 0.2)
	var phi := atan2(0.2, 1.3)
	return (acos((0.1 + gap) / r) - phi) / (PI / 2)

# A sweep's rows as [a, b, first_time], or the refusal's text.
func _swept_triples(rows) -> Variant:
	if not rows is Array:
		return "refused: " + Cadaclysm.last_error()
	return rows.map(func(r): return [r.a, r.b, r.first_time])

# A sweep's rows as [name of a, name of b], by `parts()`, or the refusal's text.
func _swept_names(names: PackedStringArray, rows) -> Variant:
	if not rows is Array:
		return "refused: " + Cadaclysm.last_error()
	return rows.map(func(r): return [names[r.a], names[r.b]])

func test_assembly_parts_are_listed_depth_first_and_escaped():
	var sub := CadaclysmAssembly.create("pair")
	sub.place(CadaclysmSolid.cuboid(1, 1, 1), at(0), "x")
	sub.place(CadaclysmSolid.cuboid(1, 1, 1), at(2), "y")
	var top := CadaclysmAssembly.create("top")
	top.place(CadaclysmSolid.cuboid(1, 1, 1), at(0, 5), "p")
	top.place(sub, at(0), "a/b")
	top.place(CadaclysmSolid.cuboid(1, 1, 1), at(0, 9), "q")
	eq(top.parts(), PackedStringArray(["p", "a\\/b/x", "a\\/b/y", "q"]))
	eq(CadaclysmAssembly.create("empty").parts(), PackedStringArray())
	top.close()
	eq(refuses(func(): return top.parts()), "assembly: closed")

# Catches the values flattened joint-major (the hinge would read the carriage's values and
# never reach the circle cube), the chord swept, and rows that do not index `parts()`.
func test_assembly_swept_clash_sweeps_the_arc_not_the_chord():
	var rig := _rig()
	var names := rig.parts()
	eq(names, PackedStringArray(["base", "arm", "chord", "circle", "carriage"]))
	var rows = rig.swept_clash(_swing(), 0.0, SWEPT_TOL)
	if not eq(_swept_names(names, rows), [["arm", "circle"]]):
		return
	var r: CadaclysmSweptClash = rows[0]
	var first: CadaclysmClash = r.first
	eq([first.a, first.b], [r.a, r.b])
	var within := _circle_time(SWEPT_TOL)
	var meets := _circle_time(0.0)
	ok(within - 1e-9 <= r.first_time and r.first_time <= meets + 1e-9, "%s not in [%s, %s]" % [r.first_time, within, meets])
	# rows as [joint, values] arrays, a joint key as an array of names and a number as a
	# one-value array read the same
	var as_rows := _swing().map(func(k): return [[["hinge"], [k["hinge"]]], ["slide", k["slide"]]])
	eq(_swept_triples(rig.swept_clash(as_rows, 0.0, SWEPT_TOL)), [[r.a, r.b, r.first_time]])

# The arm starts at 1.5 rad, already through the circle cube: penetrating at time 0, and the
# overlap rebuilt from the first row lies inside the arm's box turned 1.5 about z.
func test_assembly_swept_clash_first_is_at_the_posed_frames():
	var rig := _rig()
	var rows = rig.swept_clash([{"hinge": 1.5, "slide": [0.0, 0.0]}, {"hinge": PI, "slide": [0.0, 0.0]}], 0.0, SWEPT_TOL)
	if not eq(_swept_triples(rows), [[1, 3, 0.0]]):
		return
	var shared: CadaclysmSolid = rows[0].first.solid()
	if not ok(shared != null, "solid refused: " + Cadaclysm.last_error()):
		return
	var got := shared.bounds_box(SWEPT_TOL)
	var co := cos(1.5)
	var si := sin(1.5)
	var want := CadaclysmSolid.cuboid(3, 0.2, 0.2).translate(1.5, 0, 0).bounds_box(SWEPT_TOL).moved([0, 0, 0, co, si, 0, -si, co, 0, 0, 0, 1])
	for k in 3:
		ok(want.lo[k] - 1e-6 <= got.lo[k] and got.hi[k] <= want.hi[k] + 1e-6, "%s not inside %s" % [got, want])
	ok(got.lo.y >= 1.3 - 4 * SWEPT_TOL and got.hi.y <= 1.7 + 4 * SWEPT_TOL and got.hi.x > got.lo.x, str(got))

# A pin on the arm's link inside a bore on the ground link, the hinge joining them; catches
# `joined` dropped on its way to the SDK.
func test_assembly_swept_clash_tests_joined_links_only_when_asked():
	var pinned := CadaclysmAssembly.create("pinned")
	pinned.place(CadaclysmSolid.cuboid(0.6, 0.6, 0.6), at(0), "bore")
	pinned.place(CadaclysmSolid.cuboid(0.2, 0.2, 0.2), at(0), "pin")
	ok(pinned.link("ground", ["bore"]), Cadaclysm.last_error())
	ok(pinned.link("arm", ["pin"]), Cadaclysm.last_error())
	ok(pinned.joint("hinge", "ground", "arm"), Cadaclysm.last_error())
	ok(pinned.pair("hinge", "revolute", at(0), null, [], NAN), Cadaclysm.last_error())
	var keys := [{"hinge": 0.0}, {"hinge": 1.0}]
	eq(_swept_triples(pinned.swept_clash(keys, 0.0, SWEPT_TOL)), [])
	eq(_swept_triples(pinned.swept_clash(keys, 0.0, SWEPT_TOL, 1e-3, 100000, PackedInt32Array(), "", true)), [[0, 1, 0.0]])
	eq(_swept_triples(pinned.swept_clash(keys, 0.0, SWEPT_TOL, 1e-3, 100000, PackedInt32Array([0, 1]), "", true)), [])

func test_assembly_swept_clash_a_sub_assembly_rides_its_placements_link():
	var rig := _rig(_hand())
	var names := rig.parts()
	eq(names, PackedStringArray(["base", "hand/tip", "hand/nub", "chord", "circle", "carriage"]))
	eq(_swept_names(names, rig.swept_clash(_swing(), 0.0, SWEPT_TOL)), [["hand/tip", "circle"]])

# The SDK's own refusals (keyframes naming other joints, a joint given twice, a value count
# that changes), Godot's (a keyframe not in `posed`'s shape, a malformed `allowed`, a
# negative `max_steps`, a closed assembly), then the kernel's, passed on.
func test_assembly_swept_clash_refuses_in_the_kernels_words():
	var rig := _rig(_hand())
	var two := [{"hinge": 0.0}, {"hinge": 1.0}]
	var sweep := func(keyframes: Array): return rig.swept_clash(keyframes, 0.0, SWEPT_TOL)
	eq(refuses(sweep.bind([{"hinge": 0.0, "slide": [0, 0]}, {"hinge": 1.0, "slide": [0, 0]}, {"hinge": 2.0}])),
		"swept_clash: joint 'slide' is in keyframe 0 and not in keyframe 2")
	eq(refuses(sweep.bind([{"hinge": 0.0}, {"hinge": 1.0, "slide": [0, 0]}])),
		"swept_clash: joint 'slide' is in keyframe 1 and not in keyframe 0")
	eq(refuses(sweep.bind([{"hinge": 0.0}, [["hinge", 1.0], ["hinge", 2.0]]])), "swept_clash: joint 'hinge' is given twice")
	eq(refuses(sweep.bind([{"slide": [0, 0]}, {"slide": [1]}])),
		"swept_clash: joint 'slide' has 2 values in keyframe 0 and 1 in keyframe 1")
	# Godot's own
	eq(refuses(sweep.bind([{"hinge": 0.0}, 5])),
		"swept_clash: keyframe 1: expected a Dictionary or an array of [joint, values] rows, not 5")
	eq(refuses(func(): return rig.swept_clash(two, 0.0, SWEPT_TOL, 1e-3, 100000, PackedInt32Array([0, 1, 2]))),
		"swept_clash: allowed is 3 numbers, not pairs")
	eq(refuses(func(): return rig.swept_clash(two, 0.0, SWEPT_TOL, 1e-3, 100000, PackedInt32Array([0, -1]))),
		"swept_clash: allowed pair (0, -1) is not two indices")
	eq(refuses(func(): return rig.swept_clash(two, 0.0, SWEPT_TOL, 1e-3, -1)), "swept_clash: max_steps -1 is not a count")
	# the kernel's own
	eq(refuses(sweep.bind([{["hand", "turn"]: 0.0}, {["hand", "turn"]: 1.0}])),
		"swept_clash: joint 'hand/turn' is in a sub-assembly; a sweep moves this assembly's own joints")
	eq(refuses(sweep.bind([{"elbow": 0.0}, {"elbow": 1.0}])), "swept_clash: no joint named 'elbow' in assembly 'rig' or under it")
	eq(refuses(sweep.bind([{"hinge": [0.0, 0.0]}, {"hinge": [1.0, 1.0]}])), "swept_clash: joint 'hinge' takes 1 values, but 2 were given")
	var once = rig.swept_clash(two.slice(0, 1), 0.0, SWEPT_TOL)
	ok(typeof(once) == TYPE_NIL, "one keyframe returned %s, not null" % [once])
	eq(Cadaclysm.last_error(), "swept_clash: 1 poses, at least 2 are needed")
	refused(func(): return rig.swept_clash(two, 0.0, SWEPT_TOL, 0.0), "swept_clash: resolution 0")
	eq(refuses(func(): return rig.swept_clash(two, 0.0, SWEPT_TOL, 1e-3, 0)), "swept_clash: max_steps must be at least 1")
	eq(refuses(func(): return rig.swept_clash(two, 0.0, SWEPT_TOL, 1e-3, 100000, PackedInt32Array([9, 0]))),
		"swept_clash: allowed pair (9, 0) names a part out of range")
	eq(refuses(func(): return rig.swept_clash(two, 0.0, SWEPT_TOL, 1e-3, 100000, PackedInt32Array(), "wheel")),
		"swept_clash: assembly 'rig' has no link named 'wheel'")
	eq(_swept_triples(rig.swept_clash(two, 0.0, SWEPT_TOL)), [])
	rig.close()
	eq(refuses(sweep.bind(two)), "assembly: closed")

# ---- CAM: to_arcs, offset, section, Tool, Stock, Job ------------------------------------
# The Rust wrapper's own suite (crates/cadaclysm-capi/examples/rust/src/blacksmith.rs,
# `mod tests`, from `profile_offset_grows_and_shrinks_a_rectangle` on -- itself the shared
# recipe the CAM plan gives every wrapper) ported to GDScript with the same numbers, plus
# the spec's own hand-driven four verbs fixture (Go's `74b9553ec`, Rust's
# `the_four_verbs_by_hand_gives_two_programs_with_the_specs_own_numbers`).

# `p` extruded by 1 and read back through `bounds`: `[xmin, xmax, ymin, ymax]`, as the
# other wrappers' own smoke fixtures measure a profile's footprint.
func cam_footprint(p: CadaclysmProfile) -> Array:
	var solid := CadaclysmSolid.extrude(p, XY, 1)
	var b: AABB = solid.bounds
	return [b.position.x, b.position.x + b.size.x, b.position.y, b.position.y + b.size.y]

func assert_cam_footprint(p: CadaclysmProfile, expected: Array, tolerance: float, message := ""):
	var got := cam_footprint(p)
	for i in 4:
		near(got[i], expected[i], tolerance, "%s footprint[%d]" % [message, i])

# A 40x30x10 block on z=0 with a 20x10 pocket 8 deep: four corners a 6 mm end mill misses.
func cam_pocketed_block() -> CadaclysmSolid:
	var block := CadaclysmSolid.cuboid(40, 30, 10).translate(0, 0, 5)
	var pocket := CadaclysmSolid.cuboid(20, 10, 8).translate(0, 0, 6)
	return block.cut(pocket)

func test_profile_offset_grows_and_shrinks_a_rectangle():
	var rect := CadaclysmProfile.rect(20, 10)
	var grown := rect.offset(2, 0.01)
	eq(grown.size(), 1)
	assert_cam_footprint(grown[0], [-12, 12, -7, 7], 1e-3, "grown")
	var shrunk := rect.offset(-2, 0.01)
	eq(shrunk.size(), 1)
	assert_cam_footprint(shrunk[0], [-8, 8, -3, 3], 1e-3, "shrunk")
	var eaten := rect.offset(-6, 0.01)
	eq(eaten.size(), 0)
	refuses(func(): return rect.offset(NAN, 0.01), "profile_offset: distance must be finite")

func test_profile_to_arcs_fits_a_spline_within_tolerance():
	var spline := CadaclysmProfile.spline([[0, 0], [10, 0], [10, 10], [0, 10]], 3, PackedFloat64Array(), true)
	var fitted := spline.to_arcs(0.01)
	assert_cam_footprint(fitted, cam_footprint(spline), 0.011, "fitted")
	refuses(func(): return spline.to_arcs(-1.0), "profile_to_arcs: tolerance must be positive and finite")

func test_solid_section_cuts_a_cuboid():
	var cuboid := CadaclysmSolid.cuboid(20, 10, 5)
	var middle := cuboid.section(0, 0.05)
	eq(middle.size(), 1)
	assert_cam_footprint(middle[0], [-10, 10, -5, 5], 1e-3, "middle")
	var miss := cuboid.section(50, 0.05)
	eq(miss.size(), 0)
	refuses(func(): return cuboid.section(2.5, 0.05),
		"solid_section: a face lies in the plane -- section a little above or below it")

func test_a_pocketed_block_reports_four_corners_a_six_mm_end_mill_misses():
	var block := cam_pocketed_block()
	var end_mill := CadaclysmTool.flat(1, 6, 20, 800, 200, 12000)
	var stock := CadaclysmStock.around(block, 2)
	var job := CadaclysmJob.create(stock, 30)
	var report := job.machine(block, end_mill)
	if not ok(report != null, "machine: " + Cadaclysm.last_error()):
		return
	eq(report.items.size(), 4)
	eq(report.text.split("\n").size(), 4)
	eq(str(report), report.text)
	for item in report.items:
		eq(item.kind, "corner")
		ok(item.size > 0)
		ok(item.region.size() > 0)
		ok(item.reason != "")
	var ops := job.operations()
	ok(ops.size() > 0)
	for op in ops:
		ok(op.kind != "")
		eq(op.tool, 1)
		ok(op.params.size() > 0)

	# A drill as the end mill is refused, and leaves the job as it was.
	var drill := CadaclysmTool.drill(2, 5, 30, 150, 3000)
	var fresh_stock := CadaclysmStock.around(block, 2)
	var fresh := CadaclysmJob.create(fresh_stock, 30)
	var message := refuses(func(): return fresh.machine(block, drill))
	ok(message.contains("end mill must not be a drill"), message)
	eq(fresh.operations().size(), 0)

func test_a_report_item_carries_its_z_range():
	var block := cam_pocketed_block()
	var end_mill := CadaclysmTool.flat(1, 6, 20, 800, 200, 12000)
	var job := CadaclysmJob.create(CadaclysmStock.around(block, 2), 30)
	var report := job.machine(block, end_mill)
	if not ok(report != null, "machine: " + Cadaclysm.last_error()):
		return
	eq(report.items.size(), 4)
	for item in report.items:
		near(item.top, 10.0, 1e-6, "top")
		near(item.bottom, 2.0, 1e-6, "bottom")

func test_two_end_mills_leave_the_corners_to_the_smaller_one():
	var block := cam_pocketed_block()
	var t1 := CadaclysmTool.flat(1, 6, 20, 800, 200, 12000)
	var t2 := CadaclysmTool.flat(2, 2.0, 20.0, 800.0, 200.0, 12000.0)
	var job := CadaclysmJob.create(CadaclysmStock.around(block, 2), 30)
	var report := job.machine_with_end_mills(block, [t1, t2], [])
	if not ok(report != null, "machine_with_end_mills: " + Cadaclysm.last_error()):
		return
	eq(report.items.size(), 4)
	for item in report.items:
		ok(item.reason.contains("T2 (2 mm)"), item.reason)
		near(item.top, 10.0, 1e-6, "top")
		near(item.bottom, 2.0, 1e-6, "bottom")
	var pocketed_with_t2 := false
	for op in job.operations():
		if op.kind == "pocket" and op.tool == 2:
			pocketed_with_t2 = true
	ok(pocketed_with_t2, "a pocket with tool 2")

func test_corner_relief_notches_the_corners_the_small_end_mill_cannot_reach():
	var block := cam_pocketed_block()
	var t1 := CadaclysmTool.flat(1, 6.0, 20.0, 800.0, 200.0, 12000.0)
	var t2 := CadaclysmTool.flat(2, 2.0, 20.0, 800.0, 200.0, 12000.0)
	var job := CadaclysmJob.create(CadaclysmStock.around(block, 2), 30)
	var report := job.machine_with_end_mills(block, [t1, t2], [], NAN, NAN, 0.3, NAN, true)
	if not ok(report != null, "machine_with_end_mills: " + Cadaclysm.last_error()):
		return
	eq(report.items.size(), 4)
	for item in report.items:
		eq(item.kind, "relief")
		ok(item.reason.begins_with("corner relieved by T2 (2 mm): a notch 0.293 mm into the walls"), item.reason)
	near(report.items[0].size, 1.0 - sqrt(0.5), 1e-6, "size")

func test_corner_relief_off_leaves_the_corners_reported_as_corners():
	var block := cam_pocketed_block()
	var t1 := CadaclysmTool.flat(1, 6.0, 20.0, 800.0, 200.0, 12000.0)
	var t2 := CadaclysmTool.flat(2, 2.0, 20.0, 800.0, 200.0, 12000.0)
	var job := CadaclysmJob.create(CadaclysmStock.around(block, 2), 30)
	var report := job.machine_with_end_mills(block, [t1, t2], [], NAN, NAN, 0.3, NAN, false)
	if not ok(report != null, "machine_with_end_mills: " + Cadaclysm.last_error()):
		return
	eq(report.items.size(), 4)
	for item in report.items:
		eq(item.kind, "corner")

func test_an_empty_end_mill_list_is_refused():
	var block := cam_pocketed_block()
	var job := CadaclysmJob.create(CadaclysmStock.around(block, 2), 30)
	var before := job.operations().size()
	refuses(func(): return job.machine_with_end_mills(block, [], []),
		"machine: at least one end mill is needed")
	eq(job.operations().size(), before)

func test_the_plate_is_machined_cleanly_by_one_end_mill_and_one_drill():
	var plate_outline := CadaclysmProfile.rect(80, 50).round(6)
	var part := CadaclysmSolid.extrude(plate_outline, XY, 12)
	var pocket_outline := CadaclysmProfile.rect(40, 24).round(4).with_hole(CadaclysmProfile.circle(5))
	var pocket_solid := CadaclysmSolid.extrude(pocket_outline, CadaclysmFrame.xy(Vector3(0, 0, 7)), 5)
	part = part.cut(pocket_solid)
	for xy in [[-32, -17], [-32, 17], [32, -17], [32, 17]]:
		var bore := CadaclysmSolid.cylinder(3, 12).translate(xy[0], xy[1], 0)
		part = part.cut(bore)

	var end_mill := CadaclysmTool.flat(1, 6, 20, 800, 200, 12000)
	var drill := CadaclysmTool.drill(2, 6, 30, 150, 3000)
	var stock := CadaclysmStock.around(part, 3)
	var job := CadaclysmJob.create(stock, 25, 1.0, 0.01, "plate")
	var report := job.machine_with_drills(part, end_mill, [drill])
	if not ok(report != null, "machine_with_drills: " + Cadaclysm.last_error()):
		return
	eq(report.is_empty, true)
	eq(report.text, "nothing left uncut")

	var ops := job.operations()
	ok(ops.size() > 0)
	eq(ops[0].kind, "face")
	var has_pocket := false
	for op in ops:
		if op.kind == "pocket":
			has_pocket = true
	ok(has_pocket, "a pocket operation")
	var last: CadaclysmOperation = ops[ops.size() - 1]
	eq(last.kind, "drill")
	eq(last.params.get("points"), 4.0)
	ok(last.params.has("peck") and last.params["peck"] == null, "no peck")

	var programs := job.gcode()
	eq(programs.size(), 2)
	for p in programs:
		ok(p.tool >= 1)
		ok(p.name != "")
		ok(p.text != "")

	var dir := tmp("plate-camotics")
	DirAccess.make_dir_recursive_absolute(dir)
	var written := job.write_camotics(dir.path_join("plate.camotics"))
	ok(written.size() > 0)
	ok(String(written[written.size() - 1]).ends_with("plate.camotics"))
	for w in written:
		ok(FileAccess.file_exists(w), "%s was not written" % w)

func test_the_four_verbs_by_hand_give_two_programs_with_the_specs_own_numbers():
	var outline := CadaclysmProfile.rect(60, 40).round(5)
	var part := CadaclysmSolid.extrude(outline, XY, 20)
	var end := CadaclysmTool.flat(1, 6, 20, 800, 200, 12000)
	var drill := CadaclysmTool.drill(2, 5, 30, 150, 3000)
	var stock := CadaclysmStock.around(part, 2)
	var job := CadaclysmJob.create(stock, 30)

	ok(job.face(end, 20, 3, 1), "face: " + Cadaclysm.last_error())
	ok(job.contour(end, outline, 20, 0, "outside", 2, true, false), "contour: " + Cadaclysm.last_error())
	var levels := part.section(15, 0.05)
	if not ok(levels.size() > 0, "job: section(15) is empty"):
		return
	ok(job.pocket(end, levels[0], 20, 10, 2.4, 2), "pocket: " + Cadaclysm.last_error())
	ok(job.drill(drill, [[10, 10], [40, 10]], 20, -1, 3), "drill: " + Cadaclysm.last_error())

	var programs := job.gcode()
	eq(programs.size(), 2)
	eq(programs[0].tool, 1)
	eq(programs[0].name, "job-T1")
	ok(programs[0].text.begins_with("(cadaclysm: job-T1, T1 flat D6)\n"), programs[0].text)
	eq(programs[1].tool, 2)
	eq(programs[1].name, "job-T2")
	ok(programs[1].text.begins_with("(cadaclysm: job-T2, T2 drill D5)\n"), programs[1].text)

	var ops := job.operations()
	var kinds := ops.map(func(o): return o.kind)
	eq(kinds, ["face", "contour", "pocket", "drill"])
	# `job_side`'s mapping: "outside" is the library's own 0.
	eq(ops[1].params.get("side"), 0.0)
	var drill_op: CadaclysmOperation = ops[3]
	eq(drill_op.params.get("peck"), 3.0)
	eq(drill_op.params.get("points"), 2.0)

	# A bad `side` is refused before the library is asked, and leaves the job unchanged.
	var before := job.operations().size()
	var bad_side := refuses(func(): return job.contour(end, outline, 20, 0, "left", 2, true, false))
	eq(bad_side, "side must be 'outside', 'inside' or 'on'")
	eq(job.operations().size(), before)

	# A peck-less drill reads back as no peck at all through `drill` directly, not only
	# through `machine` (the plate fixture above covers that path).
	var no_peck_job := CadaclysmJob.create(stock, 30)
	ok(no_peck_job.drill(drill, [[0, 0]], 20, -1, NAN), "no-peck drill: " + Cadaclysm.last_error())
	var no_peck_ops := no_peck_job.operations()
	ok(no_peck_ops[0].params.has("peck") and no_peck_ops[0].params["peck"] == null, "no peck")

# A negative tool number is clamped to 0, as every other wrapper does, and refused in the
# library's own words: the ones it gives 0 (not "flat: number: -1 is not an index" from here).
func test_a_negative_tool_number_is_refused_in_the_librarys_words():
	var at_zero := refuses(func(): return CadaclysmTool.flat(0, 6, 20, 800, 200, 12000), "number must be at least 1")
	eq(at_zero, "tool: number must be at least 1")
	eq(refuses(func(): return CadaclysmTool.flat(-1, 6, 20, 800, 200, 12000)), at_zero)
	eq(refuses(func(): return CadaclysmTool.ball(-1, 6, 20, 800, 200, 12000)), at_zero)
	eq(refuses(func(): return CadaclysmTool.drill(-1, 6, 30, 150, 3000)), at_zero)

func test_a_closed_job_refuses_every_later_call():
	var part := CadaclysmSolid.cuboid(20, 10, 5)
	var end_mill := CadaclysmTool.flat(1, 6, 20, 800, 200, 12000)
	var stock := CadaclysmStock.around(part, 2)
	var job := CadaclysmJob.create(stock, 30)
	eq(job.closed, false)
	job.close()
	eq(job.closed, true)
	refuses(func(): return job.face(end_mill, 0, 3, 1), "job: closed")
	refuses(func(): return job.contour(end_mill, CadaclysmProfile.rect(10, 10), 0, -5, "outside", 1, true, false), "job: closed")
	refuses(func(): return job.pocket(end_mill, CadaclysmProfile.rect(10, 10), 0, -5, 2, 1), "job: closed")
	refuses(func(): return job.drill(CadaclysmTool.drill(2, 5, 30, 150, 3000), [[0, 0]], 0, -5), "job: closed")
	refuses(func(): return job.machine(part, end_mill), "job: closed")
	refuses(func(): return job.operations(), "job: closed")
	refuses(func(): return job.gcode(), "job: closed")
	refuses(func(): return job.write_camotics(tmp("closed.camotics")), "job: closed")
	job.close()   # idempotent

# Oriented box, lengths, containment and closest: the Python suite's section of that name,
# trimmed to what proves the marshalling.
func test_the_oriented_box_of_a_turned_cuboid():
	var turned := CadaclysmSolid.cuboid(2, 3, 4).rotate([0, 0, 0], [0, 0, 1], deg_to_rad(30))
	var box := turned.oriented_box(1e-9)
	ok(box != null, Cadaclysm.last_error())
	var half := Array(box.raw_half)
	half.sort()
	for i in 3:
		var want: float = [1.0, 1.5, 2.0][i]
		ok(half[i] >= want - 1e-9 and half[i] <= want + 1e-3, "half[%d] = %s" % [i, half[i]])
	for c in box.raw_centre:
		near(c, 0.0, 1e-3, "centre")
	var raw := box.raw_axes
	eq(raw.size(), 9)
	for i in 3:
		for j in 3:
			var dot := 0.0
			for k in 3:
				dot += raw[i * 3 + k] * raw[j * 3 + k]
			near(dot, 1.0 if i == j else 0.0, 1e-9, "axes[%d].axes[%d]" % [i, j])
	# the Vector3 spellings are the same numbers, as floats
	eq(box.axes.size(), 3)
	for i in 3:
		ok(v3near(box.axes[i], Vector3(raw[i * 3], raw[i * 3 + 1], raw[i * 3 + 2]), 1e-5), "axes[%d]" % i)
	ok(v3near(box.half, Vector3(box.raw_half[0], box.raw_half[1], box.raw_half[2]), 1e-5), "half")
	ok(v3near(box.centre, Vector3(box.raw_centre[0], box.raw_centre[1], box.raw_centre[2]), 1e-5), "centre")

func test_the_oriented_box_defaults_and_refusals():
	var cyl := CadaclysmSolid.cylinder(1, 2)
	var by_default := cyl.oriented_box(0)
	var negative := cyl.oriented_box(-1)
	var explicit := cyl.oriented_box(1e-5)
	ok(by_default != null and negative != null and explicit != null, Cadaclysm.last_error())
	eq(by_default.raw_centre, explicit.raw_centre)
	eq(by_default.raw_axes, explicit.raw_axes)
	eq(by_default.raw_half, explicit.raw_half)
	eq(negative.raw_centre, explicit.raw_centre)
	eq(negative.raw_axes, explicit.raw_axes)
	eq(negative.raw_half, explicit.raw_half)
	eq(cyl.oriented_box().raw_half, explicit.raw_half, "the default argument")
	for h in explicit.raw_half:
		near(h, 1.0 + 3.125e-5 * sqrt(12.0), 1e-12, "half")
	var nan := refuses(func(): return cyl.oriented_box(NAN), "oriented_box: ")
	ok(nan.contains("is not an accuracy"), nan)
	refuses(func(): return CadaclysmSolid.cuboid(1, 2, 3).face_sheet(0).oriented_box(), "oriented_box: ")

func test_a_circle_edge_measures_five_pi():
	var cyl := CadaclysmSolid.cylinder(2.5, 4)
	var circles := cyl.edges.filter(func(e): return e.kind == "circle")
	ok(circles.size() >= 1, "no circle edge")
	for e in circles:
		var measured := cyl.edge_length(e.index, 1e-9)
		ok(measured != null, Cadaclysm.last_error())
		near(measured.length, 5.0 * PI, maxf(measured.error, 1e-9), "edge %d" % e.index)
		ok(measured.error <= 1e-6 * measured.length, "error %s" % measured.error)
		eq(measured.accuracy_met, true)
		eq(measured.from_polyline, false)
	var cube := CadaclysmSolid.cuboid(1, 1, 1)
	refuses(func(): return cube.edge_length(cube.edges.size()), "edge_length: ")
	refuses(func(): return cube.edge_length(-1), "edge_length: ")
	near(cube.edge_length(0).length, 1.0, 1e-9, "a cube's edge")

func test_a_slot_profile_measures_its_perimeter():
	var slot := CadaclysmProfile.slot([0, 0], 8, 1)
	var measured := slot.length(1e-9)
	ok(measured != null, Cadaclysm.last_error())
	near(measured.length, 12.0 + 2.0 * PI, maxf(measured.error, 1e-9), "slot perimeter")
	ok(measured.error <= 1e-6 * measured.length, "error %s" % measured.error)
	eq(measured.accuracy_met, true)
	refuses(func(): return slot.length(NAN), "profile_length: ")
	near(slot.length().length, 12.0 + 2.0 * PI, 1e-3, "the default accuracy")

func test_a_rim_a_quarter_of_the_way_round_is_a_quarter_turn():
	var cyl := CadaclysmSolid.cylinder(2.5, 4)
	var circles := cyl.edges.filter(func(e): return e.kind == "circle")
	ok(circles.size() >= 2, "circle edges")
	for e in circles:
		var t0: float = e.curve.t0
		var start := cyl.edge_point_at_length(e.index, 0)
		ok(start != null, Cadaclysm.last_error())
		near(start.parameter, t0, 1e-9, "start parameter")
		var quarter := cyl.edge_point_at_length(e.index, 2.5 * PI / 2.0)
		ok(quarter != null, Cadaclysm.last_error())
		near(quarter.parameter, t0 + PI / 2.0, 1e-9, "quarter parameter")
		near(quarter.point.distance_to(e.curve.origin), 2.5, 1e-5, "radius")
		near(quarter.tangent.length(), 1.0, 1e-5, "unit tangent")
		eq(quarter.segment, -1)
		eq(quarter.from_polyline, false)
		ok(is_finite(quarter.error) and quarter.error >= 0.0, "error %s" % quarter.error)
		var four := cyl.edge_divide_by_count(e.index, 4)
		eq(four.size(), 4)
		for i in four.size():
			near(four[i].point.distance_to(four[(i + 1) % 4].point), 2.5 * sqrt(2.0), 1e-5, "chord %d" % i)
		ok(v3near(four[0].point, start.point, 1e-5), "the first sample is the start")
		eq(cyl.edge_divide_by_length(e.index, 2.5 * PI / 2.0).size(), 4)

func test_an_open_edge_divides_into_n_plus_one():
	var box := CadaclysmSolid.cuboid(2, 3, 4)
	var line := -1
	for e in box.edges:
		if e.kind == "line" and absf(box.edge_length(e.index).length - 4.0) < 1e-9:
			line = e.index
			break
	ok(line >= 0, "no edge of length 4")
	var five := box.edge_divide_by_count(line, 4)
	eq(five.size(), 5)
	for i in five.size():
		near(five[i].point.distance_to(five[0].point), float(i), 1e-5, "sample %d" % i)
	var curve: CadaclysmCurve = box.edges.filter(func(e): return e.index == line)[0].curve
	near(five[0].parameter, curve.t0, 1e-9, "first parameter")
	near(five[4].parameter, curve.t1, 1e-9, "last parameter")
	var by_length := box.edge_divide_by_length(line, 1.5)
	eq(by_length.size(), 3)
	for i in 3:
		near(by_length[i].point.distance_to(by_length[0].point), 1.5 * i, 1e-5, "step %d" % i)

func test_a_slot_profile_has_points_at_length():
	var slot := CadaclysmProfile.slot([0, 0], 8, 1)
	var at := slot.point_at_length(6.0 + PI / 2.0)
	ok(at != null, Cadaclysm.last_error())
	ok(v3near(at.point, Vector3(4, 0, 0), 1e-5), str(at.point))
	eq(at.segment, 1)
	var eight := slot.divide_by_count(8)
	eq(eight.size(), 8)
	for a in eight:
		ok(a.segment >= 0 and a.segment < 4, "segment %d" % a.segment)
	var step := slot.divide_by_length(3)
	eq(step.size(), int(floor((12.0 + 2.0 * PI) / 3.0)) + 1)
	for k in step.size():
		var same := slot.point_at_length(3.0 * k)
		ok(v3near(step[k].point, same.point, 1e-5), "sample %d" % k)
		eq(step[k].segment, same.segment)
	ok(step[step.size() - 1].point.distance_to(step[0].point) > 0.1, "the last is not the first")

func test_arc_length_refusals():
	var cyl := CadaclysmSolid.cylinder(2.5, 4)
	var rim: int = cyl.edges.filter(func(e): return e.kind == "circle")[0].index
	refuses(func(): return cyl.edge_point_at_length(rim, -1), "edge_point_at_length: ")
	refuses(func(): return cyl.edge_point_at_length(rim, 100), "edge_point_at_length: ")
	refuses(func(): return cyl.edge_point_at_length(cyl.edges.size(), 1), "edge_point_at_length: ")
	refuses(func(): return cyl.edge_point_at_length(-1, 1), "edge_point_at_length: ")
	refuses(func(): return cyl.edge_divide_by_count(rim, 0), "edge_divide_by_count: ")
	var few := refuses(func(): return cyl.edge_divide_by_count(rim, 0), "edge_divide_by_count: ")
	ok(few.contains("not at least 1"), few)
	var many := refuses(func(): return cyl.edge_divide_by_count(rim, 1000001), "edge_divide_by_count: ")
	ok(many.contains("not at most 1000000"), many)
	eq(refuses(func(): return cyl.edge_divide_by_count(rim, -1), "edge_divide_by_count: n is out of range: -1"), "edge_divide_by_count: n is out of range: -1")
	var huge := (1 << 32) + 4
	eq(refuses(func(): return cyl.edge_divide_by_count(rim, huge), "n is out of range"), "edge_divide_by_count: n is out of range: %d" % huge)
	eq(cyl.edge_divide_by_count(rim, huge).size(), 0)
	refuses(func(): return cyl.edge_divide_by_length(rim, 0), "edge_divide_by_length: ")
	var nan := refuses(func(): return cyl.edge_point_at_length(rim, 1, NAN), "edge_point_at_length: ")
	ok(nan.contains("is not an accuracy"), nan)
	var slot := CadaclysmProfile.slot([0, 0], 8, 1)
	refuses(func(): return slot.point_at_length(-1), "profile_point_at_length: ")
	refuses(func(): return slot.divide_by_count(0), "profile_divide_by_count: ")
	eq(refuses(func(): return slot.divide_by_count(-1), "profile_divide_by_count: "), "profile_divide_by_count: n is out of range: -1")
	refuses(func(): return slot.divide_by_length(-1), "profile_divide_by_length: ")

func test_the_default_accuracy_of_a_point_at_length():
	var slot := CadaclysmProfile.slot([0, 0], 8, 1)
	var plain := slot.point_at_length(5)
	for accuracy in [0.0, -1.0]:
		var at := slot.point_at_length(5, accuracy)
		ok(at != null, Cadaclysm.last_error())
		eq(at.point, plain.point)
		eq(at.tangent, plain.tangent)
		eq(at.parameter, plain.parameter)
		eq(at.segment, plain.segment)
		eq(at.error, plain.error)
		eq(at.from_polyline, plain.from_polyline)

func test_containment_one_shot_and_classified():
	var box := CadaclysmSolid.cuboid(2, 3, 4)
	eq(box.contains(Vector3(0, 0, 0)), "inside")
	eq(box.contains(Vector3(5, 0, 0)), "outside")
	eq(box.contains(Vector3(0, 0, 2)), "on")
	eq(box.contains([0.0, 0.0, 2.0]), "on", "an array is a point too")
	var classifier := box.classifier()
	ok(classifier != null, Cadaclysm.last_error())
	for p in [Vector3(0, 0, 0), Vector3(0.99, 0, 0), Vector3(1, 0, 0), Vector3(1.2, 0, 0), Vector3(0, 1.6, 0), Vector3(0, 0, -2)]:
		eq(classifier.contains(p), box.contains(p), str(p))
	eq(classifier.contains(Vector3(1.2, 0, 0)), "outside")
	eq(classifier.contains(Vector3(1, 0, 0)), "on")
	var sphere := CadaclysmSolid.sphere(1.5).classifier(1e-3)
	var want := ["outside", "inside", "inside", "inside", "inside", "inside", "outside"]
	var xs := [-2.0, -1.4, -0.5, 0.0, 0.5, 1.4, 2.0]
	for i in xs.size():
		eq(sphere.contains(Vector3(xs[i], 0, 0)), want[i], "x = %s" % xs[i])
	eq(sphere.contains(Vector3(1.5, 0, 0)), "on")
	eq(sphere.contains(Vector3(0, 0, -1.5)), "on")

func test_a_classifier_outlives_its_solid():
	var solid := CadaclysmSolid.sphere(1.0)
	var classifier := solid.classifier(1e-3)
	solid.close()
	eq(solid.closed, true)
	eq(classifier.contains(Vector3(0, 0, 0)), "inside")
	eq(classifier.contains(Vector3(2, 0, 0)), "outside")
	eq(classifier.contains(Vector3(1, 0, 0)), "on")

func test_containment_refusals():
	var box := CadaclysmSolid.cuboid(2, 3, 4)
	var nan := refuses(func(): return box.contains(Vector3(NAN, 0, 0)), "contains: ")
	ok(nan.contains("not finite"), nan)
	eq(box.contains(Vector3(NAN, 0, 0)), "", "a refusal is not a containment")
	var classifier := box.classifier()
	var classified := refuses(func(): return classifier.contains(Vector3(NAN, 0, 0)), "classifier_contains: ")
	ok(classified.contains("not finite"), classified)
	eq(classifier.contains(Vector3(NAN, 0, 0)), "", "a refusal is not a containment")
	var one_shot := refuses(func(): return box.contains(Vector3(0, 0, 0), -1.0), "contains: ")
	ok(one_shot.contains("positive and finite"), one_shot)
	var made := refuses(func(): return box.classifier(-1.0), "classifier_new: ")
	ok(made.contains("positive and finite"), made)
	eq(box.classifier(-1.0), null)
	eq(classifier.closed, false)
	classifier.close()
	eq(classifier.closed, true)
	refuses(func(): return classifier.contains(Vector3(0, 0, 0)), "classifier: closed")
	classifier.close()   # idempotent
	eq(classifier.closed, true)

func test_the_closest_points_of_two_spheres():
	var a := CadaclysmSolid.sphere(1)
	var b := CadaclysmSolid.sphere(1).translate(5, 0, 0)
	var found := a.closest(b, 1e-3)
	ok(found != null, Cadaclysm.last_error())
	near(found.distance, 3.0, 6e-9, "distance")
	eq(found.refined, true)
	eq(found.kind_a, "face")
	eq(found.kind_b, "face")
	eq(found.edge_a, -1)
	eq(found.edge_b, -1)
	ok(v3near(found.on_a, Vector3(1, 0, 0), 1e-5), str(found.on_a))
	ok(v3near(found.on_b, Vector3(4, 0, 0), 1e-5), str(found.on_b))
	ok(all_near(found.raw_on_a, [1, 0, 0], 1e-6), str(found.raw_on_a))
	ok(all_near(found.raw_on_b, [4, 0, 0], 1e-6), str(found.raw_on_b))
	var swapped := b.closest(a, 1e-3)
	near(swapped.distance, found.distance, 1e-12, "distance, swapped")
	ok(all_near(swapped.raw_on_a, found.raw_on_b, 1e-9), "on_a, swapped")
	ok(all_near(swapped.raw_on_b, found.raw_on_a, 1e-9), "on_b, swapped")

func test_the_closest_point_can_name_a_filletable_edge():
	var box := CadaclysmSolid.cuboid(2, 3, 4)
	var ball := CadaclysmSolid.sphere(1).translate(3, 0, 4)
	var found := box.closest(ball, 1e-3)
	ok(found != null, Cadaclysm.last_error())
	near(found.distance, 2.0 * sqrt(2.0) - 1.0, 2e-3, "distance")
	eq(found.kind_a, "edge")
	ok(found.edge_a >= 0, "edge_a = %d" % found.edge_a)
	eq(found.kind_b, "face")
	eq(found.edge_b, -1)
	var rounded := box.fillet([found.edge_a], 0.2)
	ok(rounded != null, Cadaclysm.last_error())
	eq(rounded.faces, box.faces + 1)

func test_closest_refuses_a_negative_tolerance():
	var a := CadaclysmSolid.sphere(1)
	var b := CadaclysmSolid.sphere(1).translate(5, 0, 0)
	var message := refuses(func(): return a.closest(b, -1.0), "closest: ")
	ok(message.contains("positive and finite"), message)
	eq(a.closest(b, -1.0), null)

# ---- CadaclysmSketch: the 2D constraint sketcher (Python's sketch tests, ported) -----
# Points come back as Vector2 (single precision), so positions are checked to 1e-4.

func sk_rect(s: CadaclysmSketch) -> Dictionary:
	var rect := s.add_rect(Vector2(0, 0), Vector2(40, 30))
	ok(rect.has("corners") and rect.has("sides"), Cadaclysm.last_error())
	return rect

func sorted_ids(ids) -> PackedInt64Array:
	var out := PackedInt64Array(ids)
	out.sort()
	return out

func test_a_sketch_dimensions_a_plate_and_extrudes_it():
	var s := CadaclysmSketch.create()
	ok(s != null, Cadaclysm.last_error())
	var rect := sk_rect(s)
	var corners: PackedInt64Array = rect["corners"]
	var sides: PackedInt64Array = rect["sides"]
	eq(corners.size(), 4, "corners")
	eq(sides.size(), 4, "sides")
	ok(s.fix(corners[0]) >= 0, Cadaclysm.last_error())
	var width := s.length(sides[0], 60)
	ok(width >= 0, Cadaclysm.last_error())
	ok(s.length(sides[1], 30) >= 0, Cadaclysm.last_error())
	var hole := s.add_circle(s.add_point(30, 15), 5)
	ok(s.radius_of(hole, 5) >= 0, Cadaclysm.last_error())
	var report := s.solve()
	ok(report != null, Cadaclysm.last_error())
	eq(report.converged, true, "converged")
	eq(report.status, "converged")
	eq(report.ids, PackedInt64Array(), "a converged solve names no ids")
	ok(report.iterations >= 0 and report.max_residual >= 0, str(report))
	var p: Vector2 = s.point(corners[1])
	near(p.x, 60, 1e-4, "corner 1 x")
	near(p.y, 0, 1e-4, "corner 1 y")
	eq(s.constraint_kind(width), "length")
	eq(s.constraint_value(width), 60.0)
	var dof := s.diagnose()
	ok(dof != null, Cadaclysm.last_error())
	eq(dof.free, 2, "free")
	eq(dof.state, "under")
	ok(dof.parts.size() > 0, "parts")
	for part in dof.parts:
		ok(part.free <= part.params, str(part))
	var profiles := s.profiles(1e-9)
	eq(profiles.size(), 1, "profiles")
	var body := CadaclysmSolid.extrude(profiles[0], XY, 10)
	ok(body != null, Cadaclysm.last_error())
	ok(body.mass()["volume"] > 0, "volume")

func test_a_sketch_refuses_a_conflict_and_the_refusal_carries_the_ids():
	var s := CadaclysmSketch.create()
	var rect := sk_rect(s)
	var corners: PackedInt64Array = rect["corners"]
	var sides: PackedInt64Array = rect["sides"]
	s.fix(corners[0])
	s.length(sides[0], 40)
	s.length(sides[1], 30)
	var conflict := refuses(func(): return s.distance(corners[0], corners[2], 10))
	ok(conflict.begins_with("sketch_constrain: over-constrained"), conflict)
	eq(s.last_ids(), PackedInt64Array([0, 1, 5, 6]), "the conflict's ids")
	eq(s.distance(corners[0], corners[2], 10), -1, "a refused constraint is -1")
	eq(s.constraints().size(), 7, "the refused constraint was not kept")
	eq(s.last_ids(), PackedInt64Array(), "a call that works clears them")
	var in_use := refuses(func(): return s.remove_entity(corners[0]))
	ok(in_use.begins_with("sketch_remove_entity: point"), in_use)
	eq(sorted_ids(s.last_ids()), sorted_ids([sides[0], sides[3]]), "the entities using the point")
	refuses(func(): return s.kind(9999), "sketch_kind")
	eq(s.last_ids(), PackedInt64Array(), "a refusal that names no ids carries none")
	eq(s.kind(9999), "", "a refused kind is empty")
	s.close()
	eq(s.closed, true)
	refuses(func(): return s.solve(), "sketch: closed")
	eq(s.solve(), null, "a closed sketch does not solve")
	s.close()   # idempotent
	eq(s.closed, true)

func test_a_sketch_drag_moves_the_point_it_holds():
	var s := CadaclysmSketch.create()
	var corners: PackedInt64Array = sk_rect(s)["corners"]
	var report := s.drag({corners[0]: Vector2(5, 5)})
	ok(report != null, Cadaclysm.last_error())
	eq(report.converged, true, str(report))
	eq(report.ids, PackedInt64Array())
	var p: Vector2 = s.point(corners[0])
	near(p.x, 5, 1e-4, "dragged x")
	near(p.y, 5, 1e-4, "dragged y")
	near(s.point(corners[1]).y, 5, 1e-4, "the side stays level")
	var array_target := s.drag({corners[0]: [6, 6]})
	ok(array_target != null and array_target.converged, Cadaclysm.last_error())
	refuses(func(): return s.drag({corners[0]: [1, 2, 3]}), "sketch_drag")
	refuses(func(): return s.drag({"a": Vector2(1, 2)}), "sketch_drag")
	var start := s.add_point(0, 0)
	refuses(func(): return s.add_nurbs(start, [[1], [3, 2], [4, 0]], [0, 0, 0, 0.5, 1, 1, 1], 2), "sketch_add_nurbs")

func test_a_sketch_reference_follows_its_source():
	var plate := CadaclysmSketch.create()
	var rect := sk_rect(plate)
	var corners: PackedInt64Array = rect["corners"]
	var sides: PackedInt64Array = rect["sides"]
	var boss := CadaclysmSketch.create()
	plate.fix(corners[0])
	var width := plate.length(sides[0], 40)
	plate.length(sides[1], 30)
	var edge := boss.reference(plate, sides[1])
	ok(edge >= 0, Cadaclysm.last_error())
	ok(boss.is_reference(edge) and boss.is_construction(edge), "a reference is construction")
	var o := boss.add_point(130, 15)
	var hole := boss.add_circle(o, 12)
	boss.radius_of(hole, 12)
	ok(boss.point_line_distance(o, edge, 100) >= 0, Cadaclysm.last_error())
	near(boss.point(o).x, 140, 1e-4, "o.x")
	eq(boss.profiles(1e-9).size(), 1, "boss profiles")
	eq(plate.set_value(width, 60).converged, true, "set_value")
	var report := boss.update_reference(edge, plate)
	ok(report != null, Cadaclysm.last_error())
	eq(report.converged, true)
	eq(report.ids, PackedInt64Array())
	near(boss.point(o).x, 160, 1e-4, "o.x follows")
	var not_a_reference := refuses(func(): return boss.update_reference(o, plate))
	ok(not_a_reference.begins_with("sketch_update_reference: entity"), not_a_reference)
	eq(boss.last_ids(), PackedInt64Array())
	eq(boss.update_reference(o, plate), null, "a refused update is null")
	refuses(func(): return boss.reference(boss, o), "cannot reference itself")
	eq(boss.reference(boss, o), -1)

func test_a_sketch_comes_from_a_profile_and_keeps_its_tangents():
	var s := CadaclysmSketch.from_profile(CadaclysmProfile.slot([0, 0], 60, 8), true, 1e-9)
	ok(s != null, Cadaclysm.last_error())
	var tangents := 0
	for c in s.constraints():
		if s.constraint_kind(c) == "tangent":
			tangents += 1
			ok(s.is_joint_tangent(c), "tangent %d is a joint tangent" % c)
	eq(tangents, 4, "tangents")
	eq(s.diagnose().free, 4, "free")
	ok(CadaclysmSketch.from_profile(CadaclysmProfile.slot([0, 0], 60, 8)) != null, "the defaults")

func test_a_sketch_reads_back_what_it_holds():
	var s := CadaclysmSketch.create()
	var a := s.add_point(0, 0)
	var b := s.add_point(10, 0)
	var line := s.add_line(a, b)
	eq(s.kind(a), "point")
	eq(s.kind(line), "line")
	eq(s.entities(), sorted_ids([a, b, line]))
	eq(s.ends(line), PackedInt64Array([a, b]))
	var c := s.add_circle(s.add_point(0, 20), 3)
	eq(s.kind(c), "circle")
	eq(s.radius(c), 3.0)
	eq(s.kind(s.centre(c)), "point")
	eq(s.set_radius(c, 4), true)
	eq(s.radius(c), 4.0)
	eq(s.set_point(b, 12, 0), true)
	eq(s.point(b), Vector2(12, 0))
	eq(s.set_construction(c), true)
	ok(s.is_construction(c) and not s.is_reference(c), "construction, not reference")
	var h := s.horizontal(a, b)
	eq(s.constraint_kind(h), "horizontal")
	eq(s.constraint_refs(h), PackedInt64Array([a, b]))
	eq(s.constraint_value(h), null, "a horizontal has no value")
	eq(Cadaclysm.last_error(), "", "no value is not an error")
	eq(s.constraint_driving(h), false)
	eq(s.constraint_sense(h), "auto")
	var d := s.distance(a, b, 15, false)
	eq(s.constraint_value(d), 15.0)
	eq(s.constraint_driving(d), false)
	near(s.measure(d), 12, 1e-12, "measure")
	var report := s.set_driving(d, true)
	eq(report.converged, true, "set_driving")
	eq(s.constraint_driving(d), true)
	eq(s.constraint_value(d), 12.0)
	report = s.set_value(d, 20)
	eq(report.converged, true, "set_value")
	near(s.measure(d), 20, 1e-9, "measure after set_value")
	report = s.drag({b: Vector2(25, 5)})
	ok(report.status in ["converged", "conflicting", "diverged"], str(report))
	ok(report.ids is PackedInt64Array, "ids")
	eq(s.constraints(), sorted_ids([h, d]))
	eq(s.remove(h), true)
	eq(s.constraints(), PackedInt64Array([d]))
	eq(s.remove_entity(line), PackedInt64Array([d]))
	ok(not (a in s.entities()), "a went with its line")
	eq(s.constraints(), PackedInt64Array())
	var bez := s.add_bezier(s.add_point(0, 0), Vector2(1, 1), [2, 1], Vector2(3, 0))
	eq(s.kind(bez), "free_curve")
	eq(s.ends(bez).size(), 4)
	eq(s.open_chains(1e-9).size(), 1, "open chains")
	refuses(func(): return s.kind(9999), "sketch_kind")
	var sideways := refuses(func(): return s.tangent(bez, c, "sideways"))
	ok(sideways.begins_with("tangent: sense must be one of ") and sideways.ends_with(", not 'sideways'"), sideways)
	eq(s.tangent(bez, c, "sideways"), -1)
	var negative := refuses(func(): return s.kind(-1), "sketch_kind")
	ok(negative.contains("-1"), negative)

func test_a_sketch_tangent_at_end_reads_its_end_back():
	var s := CadaclysmSketch.create()
	var a := s.add_point(0, 0)
	var b := s.add_point(4, 0)
	var line := s.add_line(a, b)
	var bez := s.add_bezier(b, Vector2(5, 0), Vector2(6, 1), Vector2(7, 1))
	eq(s.constraint_end(s.tangent_at_end(bez, line, "end")), "end")
	eq(s.constraint_end(s.tangent_at_end(bez, line)), "start")
	eq(s.constraint_end(s.length(line, 4)), "start")
	refuses(func(): return s.constraint_end(999), "sketch_constraint_end: no constraint 999")
	eq(s.constraint_end(999), "")
	refuses(func(): return s.tangent_at_end(bez, line, "middle"), "tangent_at_end: end must be one of 'start', 'end', not 'middle'")

func test_a_sketch_checks_nurbs_weights_and_finite_points():
	var s := CadaclysmSketch.create()
	var start := s.add_point(0, 0)
	var points := [[1, 2], [3, 2], [4, 0]]
	var knots := [0, 0, 0, 0.5, 1, 1, 1]
	var short := refuses(func(): return s.add_nurbs(start, points, knots, 2, PackedFloat64Array([1, 1, 1])))
	eq(short, "sketch_add_nurbs: 3 weights for 4 control points (the start and 3 given); give one per point")
	var curve := s.add_nurbs(start, points, knots, 2, PackedFloat64Array([1, 0.5, 0.5, 1]))
	ok(curve >= 0, Cadaclysm.last_error())
	eq(s.kind(curve), "free_curve")
	var ends := s.ends(curve)
	eq(ends.size(), 4)
	eq(ends[0], start, "the curve starts on its start point")
	var plain := s.add_nurbs(start, PackedVector2Array([Vector2(1, 2), Vector2(3, 2), Vector2(4, 0)]), knots, 2)
	eq(s.kind(plain), "free_curve")
	refuses(func(): return s.add_nurbs(start, points, knots, -1), "sketch_add_nurbs: degree must not be negative")
	var fresh := CadaclysmSketch.create()
	var nan := refuses(func(): return fresh.add_point(NAN, 0))
	ok(nan.begins_with("sketch_add_point: the coordinates must be finite"), nan)
	eq(fresh.add_point(0, INF), -1)
	eq(fresh.entities(), PackedInt64Array(), "a refused point was not kept")

func test_a_sketch_reader_whose_failure_is_ambiguous_refuses_an_unknown_id():
	var s := CadaclysmSketch.create()
	var h := s.horizontal(s.add_point(0, 0), s.add_point(10, 0))
	eq(s.constraint_value(h), null)
	eq(s.constraint_driving(h), false)
	refuses(func(): return s.constraint_value(999), "sketch_constraint_value")
	eq(s.last_ids(), PackedInt64Array())
	refuses(func(): return s.constraint_driving(999), "sketch_constraint_driving")
	eq(s.last_ids(), PackedInt64Array())

func test_a_sketch_distance_sense_puts_the_point_on_its_own_side():
	for row in [["positive", 3.0], ["negative", -3.0]]:
		var sense: String = row[0]
		var s := CadaclysmSketch.create()
		var la := s.add_point(0, 0)
		var lb := s.add_point(10, 0)
		var line := s.add_line(la, lb)
		s.fix(la)
		s.fix(lb)
		var pt := s.add_point(5, 1)
		var dc := s.point_line_distance(pt, line, 3, true, sense)
		eq(s.constraint_sense(dc), sense)
		eq(s.solve().converged, true, "the %s distance converged" % sense)
		near(s.point(pt).y, row[1], 1e-4, "the %s sense's side" % sense)

func test_a_sketch_diagnosis_names_the_redundant_constraint():
	var s := CadaclysmSketch.create()
	var rect := sk_rect(s)
	var corners: PackedInt64Array = rect["corners"]
	var sides: PackedInt64Array = rect["sides"]
	s.fix(corners[0])
	s.length(sides[0], 40)
	s.length(sides[1], 30)
	var h := s.horizontal(corners[3], corners[2])
	eq(h, 7, "the redundant horizontal's id")
	var dof := s.diagnose()
	ok(dof != null, Cadaclysm.last_error())
	eq(dof.free, 0, "free")
	eq(dof.state, "full")
	eq(dof.redundant, PackedInt64Array([7]), "redundant")
	eq(dof.conflicting, PackedInt64Array(), "conflicting")
	eq(dof.parts.size(), 1, "one part")
	var part: CadaclysmPartDof = dof.parts[0]
	eq(part.free, 0, "part free")
	eq(part.state, "full")
	eq(part.redundant, PackedInt64Array([7]), "part redundant")
	eq(part.conflicting, PackedInt64Array(), "part conflicting")
	eq(part.constraints, PackedInt64Array([0, 1, 2, 3, 5, 6, 7]), "part constraints")

func test_a_sketch_refuses_an_edit_the_solve_cannot_reach_and_names_its_constraints():
	var s := CadaclysmSketch.create()
	var a := s.add_point(0, 0)
	var b := s.add_point(1, 0)
	var c := s.add_point(0, 1)
	s.distance(a, b, 1)
	s.distance(b, c, 1)
	var d3 := s.distance(a, c, 1)
	var diverged := refuses(func(): return s.set_value(d3, 10))
	ok(diverged.begins_with("sketch_set_value: the solve did not converge"), diverged)
	eq(s.last_ids(), PackedInt64Array([2, 0, 1]), "the diverged edit's ids")
	var report := s.solve()
	ok(report != null and report.converged, "the sketch was left solvable: %s" % Cadaclysm.last_error())

func test_a_sketch_raw_point_reads_back_in_double_precision():
	var s := CadaclysmSketch.create()
	var p := s.add_point(0.1, 123456789.123)
	eq(s.raw_point(p), PackedFloat64Array([0.1, 123456789.123]), "the doubles as given")
	ok(float(s.point(p).y) != 123456789.123, "point() is single precision, raw_point() is not")
	refuses(func(): return s.raw_point(9999), "sketch_point")
	eq(s.raw_point(9999), PackedFloat64Array(), "a refused raw_point is empty")
	refuses(func(): return s.raw_point(-1), "sketch_point: id -1 is not a sketch id")

func test_a_sketch_refuses_an_id_past_a_u32():
	var s := CadaclysmSketch.create()
	var a := s.add_point(0, 0)
	var big := 4294967296   # u32::MAX + 1: no sketch id, refused before the kernel sees it
	var why := refuses(func(): return s.point(big), "sketch_point: id 4294967296 is not a sketch id")
	ok(why.contains("4294967295"), why)
	eq(s.point(big), null)
	eq(s.add_line(a, big), -1, "a line to an id past a u32")
	refuses(func(): return s.add_line(a, big), "4294967296")
	refuses(func(): return s.kind(big), "4294967296")
	refuses(func(): return s.constraint_kind(big), "4294967296")
	eq(s.ends(big), PackedInt64Array())
	eq(s.entities(), PackedInt64Array([a]), "nothing was added")

func test_a_sketch_close_clears_last_ids():
	var s := CadaclysmSketch.create()
	var rect := sk_rect(s)
	var corners: PackedInt64Array = rect["corners"]
	var sides: PackedInt64Array = rect["sides"]
	s.fix(corners[0])
	s.length(sides[0], 40)
	s.length(sides[1], 30)
	refuses(func(): return s.distance(corners[0], corners[2], 10), "sketch_constrain: over-constrained")
	eq(s.last_ids(), PackedInt64Array([0, 1, 5, 6]), "the conflict's ids, before close")
	s.close()
	eq(s.last_ids(), PackedInt64Array(), "close() empties last_ids")

func test_a_sketch_is_readers_answer_false_without_refusing():
	var s := CadaclysmSketch.create()
	var a := s.add_point(0, 0)
	s.set_construction(a)
	ok(s.is_construction(a), "a construction point")
	for id in [9999, -1, 4294967296]:
		eq(s.is_construction(id), false, "is_construction(%d)" % id)
		eq(Cadaclysm.last_error(), "", "is_construction(%d) is no error" % id)
		eq(s.is_reference(id), false, "is_reference(%d)" % id)
		eq(Cadaclysm.last_error(), "", "is_reference(%d) is no error" % id)
		eq(s.is_joint_tangent(id), false, "is_joint_tangent(%d)" % id)
		eq(Cadaclysm.last_error(), "", "is_joint_tangent(%d) is no error" % id)
	s.close()
	eq(s.is_construction(a), false, "a closed sketch's is_construction")
	refuses(func(): return s.is_construction(a), "sketch: closed")
	refuses(func(): return s.is_reference(a), "sketch: closed")
	refuses(func(): return s.is_joint_tangent(0), "sketch: closed")

# ---- every constraint method: kind, refs in order, value, and the geometry it leaves (so a
# kind sent under another kind's code is caught although it reads back as sent). Read in
# double precision through raw_point.

func sk_every() -> Dictionary:
	var s := CadaclysmSketch.create()
	var x := {"s": s}
	x.a = s.add_point(0, 0)
	x.b = s.add_point(10, 0)
	x.l1 = s.add_line(x.a, x.b)
	x.c = s.add_point(0, 5)
	x.d = s.add_point(10, 6)
	x.l2 = s.add_line(x.c, x.d)
	x.e = s.add_point(30, 0)
	x.c1 = s.add_circle(x.e, 5)
	x.f = s.add_point(30, 20)
	x.c2 = s.add_circle(x.f, 3)
	x.g = s.add_point(50, 0)
	x.bz = s.add_bezier(x.g, Vector2(51, 1), Vector2(52, 1), Vector2(53, 0))
	return x

func sk_p(x: Dictionary, id: int) -> Array:
	var r: PackedFloat64Array = x.s.raw_point(id)
	return [r[0], r[1]]

func sk_sub(u: Array, v: Array) -> Array:
	return [u[0] - v[0], u[1] - v[1]]

func sk_cross(u: Array, v: Array) -> float:
	return u[0] * v[1] - u[1] * v[0]

func sk_dot(u: Array, v: Array) -> float:
	return u[0] * v[0] + u[1] * v[1]

func sk_norm(u: Array) -> float:
	return sqrt(u[0] * u[0] + u[1] * u[1])

func sk_near(u: float, v: float) -> bool:
	return absf(u - v) <= 1e-6

func sk_gap(x: Dictionary, p: int, q: int) -> float:
	return sk_norm(sk_sub(sk_p(x, q), sk_p(x, p)))

func sk_dir(x: Dictionary, line: int) -> Array:
	var ends: PackedInt64Array = x.s.ends(line)
	return sk_sub(sk_p(x, ends[1]), sk_p(x, ends[0]))

func sk_off(x: Dictionary, p: Array, line: int) -> float:   # how far p is from the line
	var ends: PackedInt64Array = x.s.ends(line)
	var u := sk_dir(x, line)
	return absf(sk_cross(u, sk_sub(p, sk_p(x, ends[0])))) / sk_norm(u)

func sk_sine(u: Array, v: Array) -> float:
	return sk_cross(u, v) / (sk_norm(u) * sk_norm(v))

func sk_cosine(u: Array, v: Array) -> float:
	return sk_dot(u, v) / (sk_norm(u) * sk_norm(v))

func sk_r(x: Dictionary, circle: int) -> float:
	return x.s.radius(circle)

func sk_mid(u: Array, v: Array) -> Array:
	return [(u[0] + v[0]) / 2.0, (u[1] + v[1]) / 2.0]

func sk_end_tangent(x: Dictionary, curve: int) -> Array:
	var poles: PackedInt64Array = x.s.ends(curve)
	return sk_sub(sk_p(x, poles[3]), sk_p(x, poles[2]))

func sk_stays_fixed(x: Dictionary) -> bool:
	x.s.drag({x.a: Vector2(3, 3)})
	return sk_norm(sk_p(x, x.a)) <= 1e-9

func test_a_sketch_holds_every_constraint_method_with_its_kind_refs_and_value():
	# kind, value (null: a geometric kind), the call, its refs in order, what the geometry shows
	var rows := [
		["coincident", null, func(x): return x.s.coincident(x.a, x.c), func(x): return [x.a, x.c],
			func(x): return sk_gap(x, x.a, x.c) <= 1e-6],
		["point_on_line", null, func(x): return x.s.point_on_line(x.c, x.l1), func(x): return [x.c, x.l1],
			func(x): return sk_near(sk_off(x, sk_p(x, x.c), x.l1), 0)],
		["point_on_circle", null, func(x): return x.s.point_on_circle(x.a, x.c1), func(x): return [x.a, x.c1],
			func(x): return sk_near(sk_gap(x, x.a, x.e), sk_r(x, x.c1))],
		["horizontal", null, func(x): return x.s.horizontal(x.c, x.d), func(x): return [x.c, x.d],
			func(x): return sk_near(sk_p(x, x.c)[1], sk_p(x, x.d)[1]) and sk_gap(x, x.c, x.d) > 1],
		["vertical", null, func(x): return x.s.vertical(x.a, x.c), func(x): return [x.a, x.c],
			func(x): return sk_near(sk_p(x, x.a)[0], sk_p(x, x.c)[0]) and sk_gap(x, x.a, x.c) > 1],
		["parallel", null, func(x): return x.s.parallel(x.l1, x.l2), func(x): return [x.l1, x.l2],
			func(x): return sk_near(sk_sine(sk_dir(x, x.l1), sk_dir(x, x.l2)), 0)],
		["perpendicular", null, func(x): return x.s.perpendicular(x.l1, x.l2), func(x): return [x.l1, x.l2],
			func(x): return sk_near(sk_cosine(sk_dir(x, x.l1), sk_dir(x, x.l2)), 0)],
		["collinear", null, func(x): return x.s.collinear(x.l1, x.l2), func(x): return [x.l1, x.l2],
			func(x): return sk_near(sk_off(x, sk_p(x, x.c), x.l1), 0) and sk_near(sk_off(x, sk_p(x, x.d), x.l1), 0)],
		["tangent", null, func(x): return x.s.tangent(x.l2, x.c1, "auto"), func(x): return [x.l2, x.c1],
			func(x): return sk_near(sk_off(x, sk_p(x, x.e), x.l2), sk_r(x, x.c1))],
		["tangent_at_end", null, func(x): return x.s.tangent_at_end(x.bz, x.l1, "end"), func(x): return [x.bz, x.l1],
			func(x): return sk_near(sk_sine(sk_end_tangent(x, x.bz), sk_dir(x, x.l1)), 0)],
		["concentric", null, func(x): return x.s.concentric(x.c1, x.c2), func(x): return [x.c1, x.c2],
			func(x): return sk_gap(x, x.e, x.f) <= 1e-6],
		["equal_length", null, func(x): return x.s.equal_length(x.l1, x.l2), func(x): return [x.l1, x.l2],
			func(x): return sk_near(sk_norm(sk_dir(x, x.l1)), sk_norm(sk_dir(x, x.l2)))],
		["equal_radius", null, func(x): return x.s.equal_radius(x.c1, x.c2), func(x): return [x.c1, x.c2],
			func(x): return sk_near(sk_r(x, x.c1), sk_r(x, x.c2))],
		["midpoint", null, func(x): return x.s.midpoint(x.c, x.l1), func(x): return [x.c, x.l1],
			func(x): return sk_norm(sk_sub(sk_p(x, x.c), sk_mid(sk_p(x, x.a), sk_p(x, x.b)))) <= 1e-6],
		["symmetric", null, func(x): return x.s.symmetric(x.c, x.d, x.l1), func(x): return [x.c, x.d, x.l1],
			func(x): return sk_near(sk_off(x, sk_mid(sk_p(x, x.c), sk_p(x, x.d)), x.l1), 0) and sk_near(sk_cosine(sk_sub(sk_p(x, x.d), sk_p(x, x.c)), sk_dir(x, x.l1)), 0)],
		["fix", null, func(x): return x.s.fix(x.a), func(x): return [x.a],
			func(x): return sk_stays_fixed(x)],
		["distance", 12.0, func(x): return x.s.distance(x.a, x.d, 12), func(x): return [x.a, x.d],
			func(x): return sk_near(sk_gap(x, x.a, x.d), 12)],
		["point_line_distance", 4.0, func(x): return x.s.point_line_distance(x.c, x.l1, 4), func(x): return [x.c, x.l1],
			func(x): return sk_near(sk_off(x, sk_p(x, x.c), x.l1), 4)],
		# measured from b's start
		["line_distance", 4.0, func(x): return x.s.line_distance(x.l1, x.l2, 4), func(x): return [x.l1, x.l2],
			func(x): return sk_near(sk_off(x, sk_p(x, x.c), x.l1), 4)],
		["circle_line_distance", 7.0, func(x): return x.s.circle_line_distance(x.c1, x.l1, 7), func(x): return [x.c1, x.l1],
			func(x): return sk_near(sk_off(x, sk_p(x, x.e), x.l1) - sk_r(x, x.c1), 7)],
		["circle_distance", 9.0, func(x): return x.s.circle_distance(x.c1, x.c2, 9), func(x): return [x.c1, x.c2],
			func(x): return sk_near(sk_gap(x, x.e, x.f) - sk_r(x, x.c1) - sk_r(x, x.c2), 9)],
		["horizontal_distance", 8.0, func(x): return x.s.horizontal_distance(x.a, x.d, 8), func(x): return [x.a, x.d],
			func(x): return sk_near(absf(sk_p(x, x.d)[0] - sk_p(x, x.a)[0]), 8)],
		["vertical_distance", 4.0, func(x): return x.s.vertical_distance(x.a, x.d, 4), func(x): return [x.a, x.d],
			func(x): return sk_near(absf(sk_p(x, x.d)[1] - sk_p(x, x.a)[1]), 4)],
		["length", 12.0, func(x): return x.s.length(x.l1, 12), func(x): return [x.l1],
			func(x): return sk_near(sk_norm(sk_dir(x, x.l1)), 12)],
		["angle", 0.5, func(x): return x.s.angle(x.l1, x.l2, 0.5), func(x): return [x.l1, x.l2],
			func(x): return sk_near(absf(atan2(sk_cross(sk_dir(x, x.l1), sk_dir(x, x.l2)), sk_dot(sk_dir(x, x.l1), sk_dir(x, x.l2)))), 0.5)],
		["radius", 6.0, func(x): return x.s.radius_of(x.c1, 6), func(x): return [x.c1],
			func(x): return sk_near(sk_r(x, x.c1), 6)],
		["diameter", 8.0, func(x): return x.s.diameter(x.c1, 8), func(x): return [x.c1],
			func(x): return sk_near(sk_r(x, x.c1), 4)],
	]
	eq(rows.size(), 27, "every constraint method")
	for row in rows:
		var kind: String = row[0]
		var x := sk_every()
		var id: int = row[2].call(x)
		if not ok(id >= 0, "the %s was refused: %s" % [kind, Cadaclysm.last_error()]):
			continue
		eq(x.s.constraint_kind(id), kind, "the %s's kind" % kind)
		eq(x.s.constraint_refs(id), PackedInt64Array(row[3].call(x)), "the %s's refs" % kind)
		eq(x.s.constraint_value(id), row[1], "the %s's value" % kind)
		ok(row[4].call(x), "the %s holds in the geometry" % kind)
	var x := sk_every()
	var h: int = x.s.add_point(70, 0)
	var i: int = x.s.add_point(75, 0)
	var j: int = x.s.add_point(70, 5)
	var arc: int = x.s.add_arc(h, i, j)
	eq(x.s.kind(arc), "arc")
	eq(x.s.centre(arc), h, "the arc's centre")
	eq(x.s.ends(arc), PackedInt64Array([i, j]), "the arc's ends")
	var k: int = x.s.add_point(90, 0)
	var conic: int = x.s.add_conic(k, Vector2(91, 1), Vector2(92, 0), 0.7)
	eq(x.s.kind(conic), "free_curve")
	var ends: PackedInt64Array = x.s.ends(conic)
	eq(ends.size(), 3, "the conic's poles")
	eq(ends[0], k, "the conic starts on its start point")

# ---- the R-tree (r-tree plan 3), at parity with the Python reference's test_rtree_*,
# test_closest_points_and_k_neighbors_match_brute_force and
# test_k_neighbors_reports_a_bad_point_before_a_bad_k, trimmed to what proves the marshalling:
# every field read, every refusal's prefix, the lists' length and order, the handle's lifetime.
# Integer grid coordinates throughout: a Vector3 holds floats.

# The 10 x 10 x 10 grid of unit boxes as [id, [min, max]], id 100 i + 10 j + k, ascending.
func rtree_grid() -> Array:
	var cells := []
	for i in 10:
		for j in 10:
			for k in 10:
				cells.append([100 * i + 10 * j + k, [Vector3(i, j, k), Vector3(i + 1, j + 1, k + 1)]])
	return cells

func rtree_hit_rows(hits: Array) -> Array:
	return hits.map(func(h): return [h.id, h.distance])

func rtree_pair_rows(pairs: Array) -> Array:
	return pairs.map(func(p): return [p.a, p.b])

func rtree_ascending(rows: Array) -> bool:
	for n in range(1, rows.size()):
		var p: Array = rows[n - 1]
		var q: Array = rows[n]
		if not (p[0] < q[0] or (p[0] == q[0] and p[1] <= q[1])):
			return false
	return true

func test_rtree_a_grid_packed_or_grown_answers_alike():
	var cells := rtree_grid()
	var packed := CadaclysmRTree.from_boxes(cells)
	ok(packed != null, Cadaclysm.last_error())
	var grown := CadaclysmRTree.create()
	# grown backwards, each box shape in turn: [min, max], a CadaclysmBox, 6 numbers
	for n in range(cells.size() - 1, -1, -1):
		var id: int = cells[n][0]
		var lo: Vector3 = cells[n][1][0]
		var hi: Vector3 = cells[n][1][1]
		var shapes := [[lo, hi], CadaclysmBox.create(lo, hi), [lo.x, lo.y, lo.z, hi.x, hi.y, hi.z]]
		ok(grown.insert(id, shapes[n % 3]), Cadaclysm.last_error())
	var corner := PackedInt64Array()
	for c in cells:
		var id: int = c[0]
		if id / 100 <= 2 and (id / 10) % 10 <= 2 and id % 10 <= 2:
			corner.append(id)
	eq(corner.size(), 27)
	var answers := []
	for named in [["from_boxes", packed], ["insert", grown]]:
		var name: String = named[0]
		var tree: CadaclysmRTree = named[1]
		eq(tree.count(), 1000, name)
		var b: CadaclysmBox = tree.bounds
		ok(b != null and b.lo == Vector3(0, 0, 0) and b.hi == Vector3(10, 10, 10), name + ": bounds")
		eq(tree.search([Vector3(0, 0, 0), Vector3(2, 2, 2)]), corner, name + ": search")
		var near_hits := tree.nearest(Vector3(-1, -1, -1), 1)
		eq(near_hits.size(), 1, name)
		eq(near_hits[0].id, 0, name)
		near(near_hits[0].distance, sqrt(3.0), 1e-12, name)
		eq(rtree_hit_rows(tree.within(Vector3(0, 0, 0), 0)), [[0, 0.0]], name + ": within 0")
		eq(tree.within([-1, -1, -1], 2.5).map(func(h): return h.id), [0, 1, 10, 100], name + ": by distance then id")
		var pairs := rtree_pair_rows(tree.self_overlaps())
		eq(pairs.size(), (28 * 28 * 28 - 1000) / 2, name)
		ok(pairs.all(func(p): return p[0] < p[1]), name + ": the smaller id first")
		ok(rtree_ascending(pairs), name + ": pairs ascending")
		eq(rtree_pair_rows(tree.self_overlaps(0.5)), pairs, name + ": unit gaps paired at slack 0.5")
		answers.append(pairs)
	eq(answers[0], answers[1], "both trees answer alike")

func test_rtree_two_trees_and_one_tree_against_itself():
	var grid := CadaclysmRTree.from_boxes(rtree_grid())
	var one := CadaclysmRTree.from_boxes([[7, [[4.5, 4.5, 4.5], [5.5, 5.5, 5.5]]]])
	var ids := [444, 445, 454, 455, 544, 545, 554, 555]
	eq(rtree_pair_rows(grid.overlaps(one)), ids.map(func(id): return [id, 7]), "grid against one")
	eq(rtree_pair_rows(one.overlaps(grid, 0)), ids.map(func(id): return [7, id]), "one against grid")
	var twice := rtree_pair_rows(grid.overlaps(grid))
	eq(twice.size(), 1000 + 2 * 10476)
	ok(rtree_ascending(twice), "pairs ascending")

func test_rtree_points_insert_and_remove():
	var points := CadaclysmRTree.from_points([[0, 0, 0], [5, 0, 0], [1, 0, 0], [0, 3, 0]])
	eq(points.count(), 4)
	eq(points.search([[0.9, -0.1, -0.1], [1.1, 0.1, 0.1]]), PackedInt64Array([2]))
	eq(rtree_hit_rows(points.nearest([4, 0, 0], 2)), [[1, 1.0], [2, 3.0]])
	eq(CadaclysmRTree.from_points(PackedVector3Array([Vector3(1, 2, 3)])).count(), 1, "a PackedVector3Array")

	var tree := CadaclysmRTree.create()
	var unit := [Vector3(3, 3, 3), Vector3(4, 4, 4)]
	ok(tree.insert(7, unit))
	ok(tree.insert(7, unit))
	eq(tree.search(unit), PackedInt64Array([7, 7]))
	eq([tree.remove(7, unit), tree.remove(7, unit), tree.remove(7, unit)], [true, true, false])
	eq(Cadaclysm.last_error(), "", "an absent entry is no error")
	ok(tree.insert(7, unit))
	eq(tree.remove(8, unit), false, "another id")
	eq(tree.remove(7, [[3, 3, 3], [4, 4, 4.5]]), false, "another box")
	ok(tree.insert_point(9, Vector3(1, 2, 3)))
	eq(tree.count(), 2)
	var b: CadaclysmBox = tree.bounds
	ok(b.lo == Vector3(1, 2, 3) and b.hi == Vector3(4, 4, 4), "bounds")
	eq(tree.remove_point(9, [1, 2, 3]), true, "a point is removed by the same point")
	eq(tree.remove(7, CadaclysmBox.create(unit[0], unit[1])), true)
	eq(tree.count(), 0)
	eq(tree.bounds, null)
	var largest := (1 << 32) - 1
	ok(tree.insert_point(largest, [1, 2, 3]))
	eq(tree.search([0, 0, 0, 5, 5, 5]), PackedInt64Array([largest]))
	eq(tree.nearest([0, 0, 0], 1)[0].id, largest, "the largest id reads back")
	eq(tree.remove_point(largest, [1, 2, 3]), true)

func test_rtree_closest_points_and_k_neighbors_match_a_brute_force():
	var state := [5]
	var next := func() -> float:
		state[0] = (state[0] * 1664525 + 1013904223) % 4294967296
		return state[0] / 4294967296.0
	var points_of := func(n: int) -> Array:
		var out := []
		for i in n:
			out.append([10.0 * next.call(), 10.0 * next.call(), 10.0 * next.call()])
		return out
	var hay: Array = points_of.call(30)
	var needles: Array = points_of.call(5)
	var distance := func(a: Array, b: Array) -> float:
		return sqrt(pow(a[0] - b[0], 2) + pow(a[1] - b[1], 2) + pow(a[2] - b[2], 2))
	var by_distance := func(q: Array) -> Array:
		var order := range(hay.size())
		var nearer := func(x: int, y: int) -> bool:
			var dx: float = distance.call(hay[x], q)
			var dy: float = distance.call(hay[y], q)
			return dx < dy if dx != dy else x < y
		order.sort_custom(nearer)
		return order
	var closest := CadaclysmBlacksmith.closest_points(hay, needles, 3)
	var knn := CadaclysmBlacksmith.k_neighbors(hay, needles, 4)
	eq(closest.size(), 5)
	eq(knn.size(), 5)
	var some := false
	var all := true
	for n in needles.size():
		var q: Array = needles[n]
		var order: Array = by_distance.call(q)
		var in_limit := order.filter(func(i): return distance.call(hay[i], q) <= 3.0)
		eq(Array(closest[n]), in_limit, "closest points, needle %d" % n)
		eq(Array(knn[n]), order.slice(0, 4), "k neighbors, needle %d" % n)
		some = some or in_limit.size() > 0
		all = all and in_limit.size() == hay.size()
	ok(some and not all, "the limit chose nothing or everything")
	eq(Array(CadaclysmBlacksmith.k_neighbors(hay, needles.slice(0, 2), 500)[1]), by_distance.call(needles[1]), "k over the hay count is every point")
	var empty := CadaclysmBlacksmith.k_neighbors([], needles.slice(0, 2), 3)
	eq(empty.size(), 2, "an empty hay")
	eq(empty[0].size() + empty[1].size(), 0)

func test_rtree_refusals_name_their_call_and_ids_and_k_are_checked_before_the_call():
	var tree := CadaclysmRTree.create()
	var not_a_box := refuses(func(): return tree.insert(1, [[0, 0, 0], [NAN, 1, 1]]), "rtree_insert: ")
	ok(not_a_box.ends_with("is not a box"), not_a_box)
	not_a_box = refuses(func(): return tree.insert(1, [[1, 0, 0], [0, 1, 1]]), "rtree_insert: ")
	ok(not_a_box.ends_with("is not a box"), not_a_box)
	var not_finite := refuses(func(): return tree.insert_point(1, [INF, 0, 0]), "rtree_insert_point: ")
	ok(not_finite.ends_with("is not finite"), not_finite)
	eq(tree.count(), 0, "a refused insert changed the tree")
	refuses(func(): return tree.remove(1, [[1, 0, 0], [0, 1, 1]]), "rtree_remove: ")
	eq(tree.remove(1, [[0, 0, 0], [1, 1, 1]]), false, "absent right after a refusal")
	eq(Cadaclysm.last_error(), "", "an absent entry clears the refusal before it")
	refuses(func(): return tree.search([[0, 0, 0], [NAN, 1, 1]]), "rtree_search: ")
	not_finite = refuses(func(): return tree.within([NAN, 0, 0], 1), "rtree_within: ")
	ok(not_finite.ends_with("is not finite"), not_finite)
	not_finite = refuses(func(): return tree.nearest([NAN, 0, 0], 1), "rtree_nearest: ")
	ok(not_finite.ends_with("is not finite"), not_finite)
	eq(refuses(func(): return tree.within([0, 0, 0], -1), "rtree_within: "), "rtree_within: radius -1 is not a distance")
	eq(refuses(func(): return tree.self_overlaps(NAN), "rtree_self_overlaps: "), "rtree_self_overlaps: slack NaN is not a distance")
	refuses(func(): return tree.overlaps(tree, -0.5), "rtree_overlaps: ")
	eq(refuses(func(): return tree.nearest([0, 0, 0], 1000001), "rtree_nearest: "), "rtree_nearest: k 1000001 is not at most 1000000")
	not_a_box = refuses(func(): return CadaclysmRTree.from_boxes([[1, [[0, 0, 0], [1, 1, 1]]], [2, [[2, 0, 0], [1, 1, 1]]]]), "rtree_from_boxes: entry 1")
	ok(not_a_box.ends_with("is not a box"), not_a_box)
	eq(refuses(func(): return CadaclysmRTree.from_points([[0, 0, 0], [0, NAN, 0]]), "rtree_from_points: "), "rtree_from_points: point 1 is not finite")
	eq(CadaclysmRTree.from_points([[0, 0, 0], [0, NAN, 0]]), null, "a refused tree is null")
	# the shapes, refused here
	refuses(func(): return tree.insert(1, "box"), "rtree_insert: a box is ")
	refuses(func(): return tree.insert(1, [0, 0]), "rtree_insert: a box is ")
	refuses(func(): return tree.within([0, 0], 1), "rtree_within: point: expected 3 numbers")
	refuses(func(): return CadaclysmRTree.from_boxes([7]), "rtree_from_boxes: entry 0 is not an [id, box] pair")

	var origin := [[0, 0, 0]]
	eq(refuses(func(): return CadaclysmBlacksmith.closest_points(origin, origin, -1), "closest_points: "), "closest_points: limit -1 is not a distance")
	eq(refuses(func(): return CadaclysmBlacksmith.closest_points([[0, 0, 0], [NAN, 0, 0]], [[INF, 0, 0]], -1), "closest_points: "), "closest_points: limit -1 is not a distance")
	eq(refuses(func(): return CadaclysmBlacksmith.closest_points(origin, [[NAN, 0, 0]], 1), "closest_points: "), "closest_points: needle point 0 is not finite")
	eq(refuses(func(): return CadaclysmBlacksmith.closest_points([[0, 0, 0], [0, 0, NAN]], [[NAN, 0, 0]], 1), "closest_points: "), "closest_points: hay point 1 is not finite")
	eq(refuses(func(): return CadaclysmBlacksmith.k_neighbors([[0, 0, 0], [INF, 0, 0]], origin, 1000001), "k_neighbors: "), "k_neighbors: hay point 1 is not finite")
	eq(refuses(func(): return CadaclysmBlacksmith.k_neighbors([[0, 0, 0], [INF, 0, 0]], origin, -1), "k_neighbors: "), "k_neighbors: hay point 1 is not finite")
	eq(refuses(func(): return CadaclysmBlacksmith.k_neighbors(origin, origin, 1000001), "k_neighbors: "), "k_neighbors: k 1000001 is not at most 1000000")

	# an int is not a uint32_t: refused before the kernel could wrap it
	for id in [-1, 1 << 32]:
		eq(refuses(func(): return tree.insert(id, [[0, 0, 0], [1, 1, 1]]), "rtree_insert: "), "rtree_insert: id is out of range: %d" % id)
		eq(refuses(func(): return tree.insert_point(id, [0, 0, 0]), "rtree_insert_point: "), "rtree_insert_point: id is out of range: %d" % id)
		eq(refuses(func(): return tree.remove(id, [[0, 0, 0], [1, 1, 1]]), "rtree_remove: "), "rtree_remove: id is out of range: %d" % id)
		eq(refuses(func(): return tree.remove_point(id, [0, 0, 0]), "rtree_remove: "), "rtree_remove: id is out of range: %d" % id)
		eq(refuses(func(): return CadaclysmRTree.from_boxes([[id, [[0, 0, 0], [1, 1, 1]]]]), "rtree_from_boxes: "), "rtree_from_boxes: entry 0: id is out of range: %d" % id)
		eq(refuses(func(): return tree.nearest([0, 0, 0], id), "rtree_nearest: "), "rtree_nearest: k is out of range: %d" % id)
		eq(refuses(func(): return CadaclysmBlacksmith.k_neighbors(origin, origin, id), "k_neighbors: "), "k_neighbors: k is out of range: %d" % id)
	eq(tree.count(), 0, "an id out of range reached the tree")

func test_rtree_an_empty_tree_answers_nothing_and_a_closed_one_refuses():
	var other := CadaclysmRTree.from_boxes(rtree_grid())
	var empty := CadaclysmRTree.create()
	eq(empty.count(), 0)
	eq(empty.bounds, null)
	eq(empty.search([[0, 0, 0], [1, 1, 1]]).size(), 0)
	eq(empty.within([0, 0, 0], 10).size(), 0)
	eq(empty.nearest([0, 0, 0], 3).size(), 0)
	eq(empty.self_overlaps().size(), 0)
	eq(empty.overlaps(other).size(), 0)
	eq(other.overlaps(empty).size(), 0)
	eq(other.nearest([0, 0, 0], 0).size(), 0)
	eq(CadaclysmRTree.from_boxes([]).count(), 0)
	eq(CadaclysmRTree.from_points([]).count(), 0)
	eq(empty.closed, false)
	empty.close()
	empty.close()
	eq(empty.closed, true)
	eq(refuses(func(): return empty.count()), "rtree: closed")
	eq(refuses(func(): return empty.bounds), "rtree: closed")
	eq(refuses(func(): return empty.insert(1, [[0, 0, 0], [1, 1, 1]])), "rtree: closed")
	eq(refuses(func(): return empty.insert_point(1, [0, 0, 0])), "rtree: closed")
	eq(refuses(func(): return empty.remove(1, [[0, 0, 0], [1, 1, 1]])), "rtree: closed")
	eq(refuses(func(): return empty.remove_point(1, [0, 0, 0])), "rtree: closed")
	eq(refuses(func(): return empty.search([0, 0, 0, 1, 1, 1])), "rtree: closed")
	eq(refuses(func(): return empty.within([0, 0, 0], 1)), "rtree: closed")
	eq(refuses(func(): return empty.nearest([0, 0, 0], 1)), "rtree: closed")
	eq(refuses(func(): return empty.self_overlaps()), "rtree: closed")
	eq(refuses(func(): return other.overlaps(empty)), "rtree: closed")
	eq(refuses(func(): return empty.overlaps(other)), "rtree: closed")
	other.close()
	eq(other.closed, true)

# ---- the interpolator, the circumscribed polygon and the merge (wrappers plan, 2026-10-27), at
# parity with the Python reference's test_interpolator_*, test_circumscribed_polygon_touches_its_circle,
# test_merge_* and test_a_merged_body_is_refused_*, trimmed to what proves the marshalling: every
# field read, every refusal's prefix, the lists' length and order, the handle's lifetime.

const INTERP_SQUARES := [0.0, 1.0, 4.0, 9.0, 16.0]
const MERGE_TOLERANCE := 1e-6

# A dimension-1 value's one number.
func interp_one(v: PackedFloat64Array) -> float:
	ok(v.size() == 1, "a dimension-1 value: %s" % v)
	return v[0] if v.size() == 1 else NAN

func test_interpolator_closed_forms_on_the_squares():
	eq([CadaclysmInterpolator.MODE_NEAREST, CadaclysmInterpolator.MODE_LINEAR, CadaclysmInterpolator.MODE_COSINE,
		CadaclysmInterpolator.MODE_CUBIC, CadaclysmInterpolator.MODE_CATMULL_ROM], [0, 1, 2, 3, 4], "the C constants")
	var sq := CadaclysmInterpolator.create(PackedFloat64Array(INTERP_SQUARES))
	ok(sq != null, Cadaclysm.last_error())
	eq(sq.count(), 5)
	eq(sq.dimension, 1)
	eq(sq.cyclic, false)
	for mode in 5:
		for k in 5:
			near(interp_one(sq.at(k, mode)), INTERP_SQUARES[k], 1e-12, "mode %d at %d" % [mode, k])
		near(interp_one(sq.at(-2, mode)), 0.0, 1e-12, "mode %d clamped low" % mode)
		near(interp_one(sq.at(7, mode)), 16.0, 1e-12, "mode %d clamped high" % mode)
	eq(interp_one(sq.nearest(1.5)), 4.0)
	eq(interp_one(sq.nearest(1.49)), 1.0)
	near(interp_one(sq.linear(1.5)), 2.5, 1e-12, "linear")
	near(interp_one(sq.cosine(1.5)), 2.5, 1e-12, "cosine")
	near(interp_one(sq.cosine(1.25)), 1.0 + 3.0 * (1.0 - cos(PI / 4.0)) / 2.0, 1e-12, "cosine at a quarter")
	near(interp_one(sq.cubic(1.5)), 2.0, 1e-12, "cubic")
	near(interp_one(sq.catmull_rom(1.5)), 2.25, 1e-12, "catmull-rom")
	eq(sq.at(1.5), sq.linear(1.5), "linear by default")
	var ring := CadaclysmInterpolator.create(INTERP_SQUARES, 1, true)
	eq(ring.cyclic, true)
	near(interp_one(ring.catmull_rom(5)), interp_one(ring.catmull_rom(0)), 1e-12, "wrapped")
	near(interp_one(ring.linear(-0.5)), 8.0, 1e-12, "halfway from the last sample back to the first")

func test_interpolator_points_and_sample_is_a_loop_of_at():
	var helix := []
	var flat := PackedFloat64Array()
	for k in 9:
		var p := [cos(0.7 * k), sin(0.7 * k), 0.3 * k]
		helix.append(p)
		flat.append_array(PackedFloat64Array(p))
	var h := CadaclysmInterpolator.create(flat, 3)
	ok(h != null, Cadaclysm.last_error())
	eq(h.count(), 9)
	eq(h.dimension, 3)
	ok(all_near(h.at(2), helix[2], 1e-12), "sample 2: %s" % h.at(2))
	eq(h.catmull_rom(2.5).size(), 3)
	var ts := PackedFloat64Array()
	for k in 50:
		ts.append(-1.0 + 10.0 * k / 49.0)
	for mode in 5:
		var looped: Array[PackedFloat64Array] = []
		for t in ts:
			looped.append(h.at(t, mode))
		var sampled := h.sample(ts, mode)
		eq(sampled.size(), 50, "mode %d" % mode)
		eq(sampled, looped, "mode %d: sample is a loop of at" % mode)
	eq(h.sample(PackedFloat64Array()).size(), 0, "no ts")
	var square := CadaclysmInterpolator.create([0, 0, 1, 0, 1, 1, 0, 1], 2, true)
	eq(square.count(), 4)
	eq(square.dimension, 2)
	ok(all_near(square.linear(-0.5), [0.0, 0.5], 1e-12), "back round the corner: %s" % square.linear(-0.5))
	var both := square.sample([0.5, 1.5])
	eq(both.size(), 2)
	ok(both.size() == 2 and all_near(both[0], [0.5, 0.0], 1e-12) and all_near(both[1], [1.0, 0.5], 1e-12), "%s" % [both])

func test_interpolator_refusals_name_their_call_and_a_closed_one_refuses():
	refuses(func(): return CadaclysmInterpolator.create(PackedFloat64Array()), "interpolator_new: no samples")
	eq(CadaclysmInterpolator.create(PackedFloat64Array()), null, "a refused interpolator is null")
	refuses(func(): return CadaclysmInterpolator.create([0, 1, NAN]), "interpolator_new: sample 2 is not finite")
	refuses(func(): return CadaclysmInterpolator.create([0, 1, 2, 3, 4], 2), "interpolator: samples differ in length")
	refuses(func(): return CadaclysmInterpolator.create([0, 1], 0), "interpolator_new: the dimension must be at least 1")
	for d in [-1, 1 << 32]:
		eq(refuses(func(): return CadaclysmInterpolator.create([0, 1], d), "interpolator_new: "), "interpolator_new: dimension is out of range: %d" % d)
	var sq := CadaclysmInterpolator.create(INTERP_SQUARES)
	refuses(func(): return sq.linear(NAN), "interpolator_at: t NaN is not finite")
	eq(sq.linear(NAN).size(), 0, "a refused value is empty")
	refuses(func(): return sq.sample([0, INF]), "interpolator_sample: t 1 (inf) is not finite")
	eq(sq.sample([0, INF]).size(), 0)
	for mode in [5, -1]:
		eq(refuses(func(): return sq.at(1, mode), "interpolator_at: "), "interpolator_at: mode %d is not a mode" % mode)
		eq(refuses(func(): return sq.sample([1], mode), "interpolator_sample: "), "interpolator_sample: mode %d is not a mode" % mode)
		eq(refuses(func(): return sq.sample(PackedFloat64Array(), mode), "interpolator_sample: "), "interpolator_sample: mode %d is not a mode" % mode)
	sq.close()
	sq.close()
	eq(refuses(func(): return sq.count()), "interpolator: closed")
	eq(refuses(func(): return sq.dimension), "interpolator: closed")
	eq(refuses(func(): return sq.cyclic), "interpolator: closed")
	eq(refuses(func(): return sq.at(1)), "interpolator: closed")
	eq(refuses(func(): return sq.linear(1)), "interpolator: closed")
	eq(refuses(func(): return sq.catmull_rom(1)), "interpolator: closed")
	eq(refuses(func(): return sq.sample([1])), "interpolator: closed")

func test_circumscribed_polygon_touches_its_circle():
	var centre := Vector3(2, -1, 0)
	var r := 5.0
	var n := 6
	var hex := CadaclysmProfile.circumscribed_polygon([2, -1], r, n, 0.3)
	ok(hex != null, Cadaclysm.last_error())
	var step := PI / n
	var side := 2.0 * r * tan(step)
	var perimeter := n * side
	near(hex.length(1e-9).length, perimeter, 1e-9 * perimeter, "perimeter")
	for k in n:
		var corner: Vector3 = hex.point_at_length(k * side).point
		near(corner.distance_to(centre), r / cos(step), 1e-5, "corner %d" % k)
		var middle: Vector3 = hex.point_at_length((k + 0.5) * side).point
		near(middle.distance_to(centre), r, 1e-5, "side %d's midpoint" % k)
	var first: Vector3 = hex.point_at_length(0).point
	near(atan2(first.y - centre.y, first.x - centre.x), 0.3, 1e-5, "the first corner at angle")
	eq(refuses(func(): return CadaclysmProfile.circumscribed_polygon([0, 0], 10, 2)),
		"profile_circumscribed_polygon: a polygon has at least 3 sides, not 2")
	# an int is not a uint32_t: refused before the call (a huge count would abort it)
	for sides in [-1, 1 << 32]:
		eq(refuses(func(): return CadaclysmProfile.circumscribed_polygon([0, 0], 10, sides), "profile_circumscribed_polygon: "),
			"profile_circumscribed_polygon: sides is out of range: %d" % sides)

# [cube, the cube merged with itself moved by (1/2, 1/2, 1/2)].
func merge_cube_and_corner() -> Array:
	var a := CadaclysmSolid.cuboid(1, 1, 1)
	return [a, a.merge(a.translate(0.5, 0.5, 0.5), MERGE_TOLERANCE)]

# A region as plain values: index, finite, box corners, [face, sense] rows, shells.
func region_row(r: CadaclysmRegion) -> Array:
	return [r.index, r.finite, r.box.lo, r.box.hi, r.sides.map(func(s): return [s.face, s.sense]), r.shells]

func test_merge_of_two_cubes_at_a_corner_is_the_outside_and_three_cells():
	var m: CadaclysmSolid = merge_cube_and_corner()[1]
	ok(m != null, Cadaclysm.last_error())
	eq(m.faces, 18)
	var regions := m.regions()
	eq(regions.map(func(r): return r.index), [0, 1, 2, 3])
	eq(regions.map(func(r): return r.finite), [false, true, true, true])
	ok(regions.all(func(r): return r.shells == 1), "one shell each")
	var total := 0
	var covered := {}
	for r in regions:
		var rows: Array = r.sides.map(func(s): return [s.face, s.sense])
		total += rows.size()
		ok(rows.all(func(x): return x[1] == 1 or x[1] == -1), "region %d: a sense neither +1 nor -1: %s" % [r.index, rows])
		for k in range(1, rows.size()):
			var p: Array = rows[k - 1]
			var q: Array = rows[k]
			ok(p[0] < q[0] or (p[0] == q[0] and p[1] < q[1]), "region %d's sides out of order: %s" % [r.index, rows])
		if r.finite:
			for x in rows:
				covered[x[0]] = true
	eq(total, 2 * 18, "each face's two sides")
	var faces := covered.keys()
	faces.sort()
	eq(faces, range(18), "the cells' faces")
	var volumes := []
	var small := -1
	for i in [1, 2, 3]:
		var cell := m.region_solid(i)
		ok(cell != null, Cadaclysm.last_error())
		var v: float = cell.mass()["volume"]
		volumes.append(v)
		if absf(v - 0.125) < 1e-6:
			small = i
	volumes.sort()
	ok(all_near(volumes, [0.125, 0.875, 0.875], 1e-6), "the cells' volumes: %s" % [volumes])
	ok(small > 0, "no 1/8 cell")
	if small > 0:
		var overlap: CadaclysmRegion = regions[small]
		eq(overlap.sides.size(), 6)
		ok(overlap.sides.all(func(s): return s.sense == -1), "inside both, behind its walls")
		ok(v3near(overlap.box.lo, Vector3(0, 0, 0)), "the overlap's low corner: %s" % overlap.box.lo)
		ok(v3near(overlap.box.hi, Vector3(0.5, 0.5, 0.5)), "the overlap's high corner: %s" % overlap.box.hi)
	eq(m.regions().map(region_row), regions.map(region_row), "regions twice")

func test_merge_of_a_ball_in_a_box_is_a_box_cell_with_a_void():
	var m := CadaclysmSolid.cuboid(1, 1, 1).merge(CadaclysmSolid.sphere(0.3), MERGE_TOLERANCE)
	ok(m != null, Cadaclysm.last_error())
	var regions := m.regions()
	eq(regions.size(), 3)
	var ball := 4.0 / 3.0 * PI * pow(0.3, 3)
	var volumes := [m.region_solid(1).mass()["volume"], m.region_solid(2).mass()["volume"]]
	var boxed := 1 if volumes[0] > volumes[1] else 2
	near(volumes[boxed - 1], 1.0 - ball, 1e-6, "the box less the ball")
	near(volumes[2 - boxed], ball, 1e-6, "the ball")
	eq([regions[boxed].shells, regions[3 - boxed].shells], [2, 1])

func test_a_merged_body_is_refused_by_the_manifold_verbs_and_its_cells_are_not():
	var both := merge_cube_and_corner()
	var a: CadaclysmSolid = both[0]
	var m: CadaclysmSolid = both[1]
	refuses(func(): return m.join(a, MERGE_TOLERANCE), "join: the join needs a manifold solid, and this one has edges of three or more faces")
	eq(m.join(a, MERGE_TOLERANCE), null)
	refuses(func(): return m.mass(), "mass_properties: the mass needs a manifold solid")
	eq(refuses(func(): return m.region_solid(0)), "region_solid: region 0 is the infinite region")
	eq(refuses(func(): return m.region_solid(4)), "region_solid: region 4 is not below 4")
	eq(m.region_solid(4), null)
	refuses(func(): return a.merge(a, -1.0), "merge: tolerance must be positive and finite")
	eq(a.merge(a, -1.0), null)
	# an int is not a uint32_t: refused before the call
	for region in [-1, 1 << 32]:
		eq(refuses(func(): return m.region_solid(region), "region_solid: "), "region_solid: region is out of range: %d" % region)
	var cell := m.region_solid(1)
	ok(cell.join(a, MERGE_TOLERANCE).faces > 0, "a cell is an ordinary solid again")
	var ordinary := a.regions()
	eq(ordinary.size(), 2)
	eq(ordinary[0].sides.size(), 6)
	ok(ordinary[0].sides.all(func(s): return s.sense == 1), "the outside is in front of every face")
	ok(ordinary[1].sides.all(func(s): return s.sense == -1), "the inside is behind them")
	eq(ordinary[1].box.hi, Vector3(0.5, 0.5, 0.5))
	eq(ordinary[0].finite, false)
	var closed := CadaclysmSolid.cuboid(1, 1, 1)
	closed.close()
	eq(refuses(func(): return closed.regions()), "the solid is closed")
	eq(closed.regions().size(), 0)

# ---- rays, triangle trees and a solid's face tree (r-tree plan 6): Python's test_rtree_ray_*,
# test_rtree_from_triangles_* and test_solid_face_tree_*, trimmed. Points as arrays of numbers,
# which keep a double's precision.

func test_rtree_a_ray_through_a_row():
	var cells := []
	for i in 10:
		cells.append([i, [[i, 0, 0], [i + 1, 1, 1]]])
	var row := CadaclysmRTree.from_boxes(cells)
	var start := [-1, 0.5, 0.5]
	var along := []
	for i in 10:
		along.append([i, float(i + 1)])
	eq(rtree_hit_rows(row.ray(start, [1, 0, 0])), along, "entry t per box")
	eq(rtree_hit_rows(row.ray(start, [2, 0, 0], 1)), [[0, 0.5], [1, 1.0]], "t in units of the direction")
	eq(rtree_hit_rows(row.ray(start, [1, 0, 0], 3)), [[0, 1.0], [1, 2.0], [2, 3.0]], "max_t cuts the row")
	eq(rtree_hit_rows(row.ray([2.5, 0.5, 0.5], [1, 0, 0], 1)), [[2, 0.0], [3, 0.5]], "from inside: 0")
	eq(rtree_hit_rows(row.ray([11, 0.5, 0.5], [-1, 0, 0], 2)), [[9, 1.0], [8, 2.0]], "backwards")
	eq(rtree_hit_rows(row.ray(Vector3(11, 0.5, 0.5), Vector3(-1, 0, 0), 2)), [[9, 1.0], [8, 2.0]], "Vector3s")
	eq(row.ray([-1, 1, 0.5], [1, 0, 0]).size(), 10, "grazing the top face counts")
	eq(row.ray([-1, 1 + 1e-12, 0.5], [1, 0, 0]).size(), 0)
	eq(row.ray(start, [1, 0, 0], INF).size(), 10)
	eq(CadaclysmRTree.create().ray(start, [1, 0, 0]).size(), 0, "an empty tree")
	eq(refuses(func(): return row.ray([0, 0, 0], [0, 0, 0]), "rtree_ray: "), "rtree_ray: direction (0, 0, 0) is not a direction")
	eq(refuses(func(): return row.ray([0, 0, 0], [1, 0, 0], -1), "rtree_ray: "), "rtree_ray: max_t -1 is not a distance")
	eq(refuses(func(): return row.ray([0, 0, 0], [1, 0, 0], NAN), "rtree_ray: "), "rtree_ray: max_t NaN is not a distance")
	eq(refuses(func(): return row.ray([NAN, 0, 0], [1, 0, 0]), "rtree_ray: "), "rtree_ray: origin (NaN, 0, 0) is not finite")
	eq(refuses(func(): return row.ray([0, 0, 0], [INF, 0, 0]), "rtree_ray: "), "rtree_ray: direction (inf, 0, 0) is not finite")
	# the shapes, refused here
	refuses(func(): return row.ray([0, 0], [1, 0, 0]), "rtree_ray: origin: expected 3 numbers")
	refuses(func(): return row.ray([0, 0, 0], "x"), "rtree_ray: direction: expected 3 numbers")
	row.close()
	eq(refuses(func(): return row.ray(start, [1, 0, 0])), "rtree: closed")

func test_rtree_from_triangles_boxes_each_triangle():
	var positions := [[0, 0, 0], [2, 0, 0], [0, 3, 0], [NAN, 0, 0], [5, 1, 4]]
	var tree := CadaclysmRTree.from_triangles(positions, [[0, 1, 2], [1, 4, 1]])
	eq(tree.count(), 2)
	var b: CadaclysmBox = tree.bounds
	eq([b.lo, b.hi], [Vector3(0, 0, 0), Vector3(5, 3, 4)], "point 3 is used by no triangle")
	eq(tree.search([1, 1, 0, 1, 1, 0]), PackedInt64Array([0]), "ids are the triangle indices")
	eq(tree.search([4, 0.5, 2, 4, 0.5, 2]), PackedInt64Array([1]))
	eq(rtree_hit_rows(tree.ray([-1, 0.5, 0], [1, 0, 0])), [[0, 1.0], [1, 3.0]])
	var flat := CadaclysmRTree.from_triangles(PackedVector3Array([Vector3(0, 0, 0), Vector3(2, 0, 0), Vector3(0, 3, 0)]), PackedInt32Array([0, 1, 2, 2, 1, 0]))
	eq(flat.count(), 2, "packed positions and flat packed indices")
	eq(flat.search([1, 1, 0, 1, 1, 0]), PackedInt64Array([0, 1]))
	eq(CadaclysmRTree.from_triangles([], []).count(), 0)
	var four := [[0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0]]
	eq(refuses(func(): return CadaclysmRTree.from_triangles(four, [[0, 1, 2], [0, 4, 1]]), "rtree_from_triangles: "), "rtree_from_triangles: triangle 1 names point 4 of 4")
	eq(refuses(func(): return CadaclysmRTree.from_triangles([[0, 0, 0], [0, INF, 0]], [[0, 1, 0]]), "rtree_from_triangles: "), "rtree_from_triangles: triangle 0 point 1 is not finite")
	eq(CadaclysmRTree.from_triangles(four, [[0, 1, 2], [0, 4, 1]]), null, "a refused tree is null")
	# the shapes and the index range, refused here
	refuses(func(): return CadaclysmRTree.from_triangles([[0, 0, 0], [1, 1]], [[0, 0, 0]]), "rtree_from_triangles: point 1")
	refuses(func(): return CadaclysmRTree.from_triangles(four, [[0, 1, 2], [0, 1]]), "rtree_from_triangles: triangle 1 is not 3 indices")
	refuses(func(): return CadaclysmRTree.from_triangles(four, PackedInt32Array([0, 1, 2, 0])), "rtree_from_triangles: 4 indices are not whole triangles")
	refuses(func(): return CadaclysmRTree.from_triangles(four, "x"), "rtree_from_triangles: expected an array of triangles")
	for k in [-1, 1 << 32]:
		eq(refuses(func(): return CadaclysmRTree.from_triangles(four, [[0, 1, 2], [0, k, 1]]), "rtree_from_triangles: "), "rtree_from_triangles: triangle 1's index is out of range: %d" % k)
	eq(refuses(func(): return CadaclysmRTree.from_triangles(four, PackedInt64Array([0, 1, -1])), "rtree_from_triangles: "), "rtree_from_triangles: triangle 0's index is out of range: -1")
	refuses(func(): return CadaclysmRTree.from_triangles(four, [[0, 1.5, 2]]), "rtree_from_triangles: triangle 0 is not 3 indices")

func test_rtree_a_cuboids_face_tree():
	var cuboid := CadaclysmSolid.cuboid(3, 4, 5)
	var faces := cuboid.face_tree()
	ok(faces is CadaclysmRTree)
	eq(faces.count(), 6)
	var grow := 5 * 1e-3
	var b: CadaclysmBox = faces.bounds
	ok(b.lo.is_equal_approx(Vector3(-1.5 - grow, -2 - grow, -2.5 - grow)) and b.hi.is_equal_approx(Vector3(1.5 + grow, 2 + grow, 2.5 + grow)), "bounds grown by a thousandth of the extent: %s %s" % [b.lo, b.hi])
	eq(faces.search([[1.4, 1.9, 2.4], [1.6, 2.1, 2.6]]).size(), 3, "three faces at a corner")
	var shot := faces.ray([10, 0, 0], [-1, 0, 0])
	eq(shot.size(), 2)
	near(shot[0].distance, 8.5 - grow, 1e-9)
	near(shot[1].distance, 11.5 - grow, 1e-9)
	# The +x face is the one the ray met first: a face call by that index agrees.
	ok(cuboid.face_frame(shot[0].id).z.is_equal_approx(Vector3(1, 0, 0)), "the +x face first")
	# The tree is its own: it outlives the solid.
	cuboid.close()
	eq(faces.count(), 6)
	eq(refuses(func(): return cuboid.face_tree()), "the solid is closed")
	faces.close()

# ---- wall thickness (wall-thickness plan 2b) ------------------------------------------
# Python's closed forms: a 10 x 10 x 2 plate reads 2, a right wedge's rule 5/sqrt 2 under its
# inscribed ball of 4.1421, two triangles 1 apart read 1. Points come back as Vector3s (floats),
# so positions compare to 1e-5; the figures (thickness, exact_thickness, sphere) are doubles.

const THICK_EPS := 1e-5

func thick_near(a: Vector3, b: Vector3, message := "") -> bool:
	return ok((a - b).length() <= THICK_EPS, "%s %s is not %s" % [message, a, b])

func thick_refuses(f: Callable, prefix: String) -> void:
	var rows = f.call()
	ok(rows == null, "%s returned %s, not null" % [prefix, rows])
	var message := Cadaclysm.last_error()
	ok(message.begins_with(prefix), "expected %s, got %s" % [prefix, message])

# The face of body `body` whose reading at `p` lies at `p`.
func thickness_face_holding(gauge: CadaclysmThicknessGauge, solid: CadaclysmSolid, body: int, p: Vector3) -> int:
	for f in range(solid.faces):
		var r = gauge.thickness_at(body, f, p, 100.0, 0.5)
		if r != null and (r.point - p).length() < THICK_EPS:
			return f
	ok(false, "no face holds %s" % [p])
	return -1

func thickness_tube() -> CadaclysmSolid:
	var ring := CadaclysmProfile.circle(5.0).with_hole(CadaclysmProfile.circle(4.0))
	return CadaclysmSolid.extrude(ring, at(0), 10.0)

func test_thickness_a_plate_reads_two_at_every_cap_vertex():
	var plate := CadaclysmSolid.cuboid(10, 10, 2)
	var gauge := CadaclysmThicknessGauge.create([plate])
	eq(gauge.body_count, 1)
	near(gauge.tolerance, 0.01, 1e-12)
	eq(gauge.closed, false)
	var rows = gauge.thickness(10.0, 0.5)
	var mesh: CadaclysmThicknessMesh = gauge.mesh(0)
	var caps := 0
	for r in rows:
		ok(r is CadaclysmThickness)
		eq(r.body, 0)
		ok(r.vertex >= 0 and r.vertex < mesh.positions.size(), "vertex %d" % r.vertex)
		eq(mesh.positions[r.vertex], r.point, "the row's vertex is its point")
		if r.has_sphere:
			ok(not is_nan(r.sphere))
		else:
			ok(is_nan(r.sphere))
		if absf(absf(r.point.z) - 1.0) < THICK_EPS and absf(r.opposite.z + r.point.z) < THICK_EPS:
			caps += 1
			near(r.thickness, 2.0, 1e-9, "cap thickness")
			near(r.exact_thickness, 2.0, 1e-9, "cap exact thickness")
			near(r.exact_opposite.z, -r.point.z, THICK_EPS)
			eq(r.knife, false)
			eq(r.opposite_body, 0)
			near(r.raw_point[2], float(r.point.z), 1e-9)
			near(r.raw_opposite[2], -r.raw_point[2], 1e-9)
	ok(caps >= 8, "%d cap rows of %d" % [caps, rows.size()])
	# below the wall nothing reads; the sharp angle defaults to 0
	var none = gauge.thickness(1.0)
	ok(none is Array)
	eq(none.size(), 0)
	eq(gauge.thickness(10.0).size(), rows.size())
	ok(str(rows[0]).begins_with("Thickness("))
	ok(str(gauge).begins_with("ThicknessGauge("))

func test_thickness_gauge_mesh_is_a_copy_that_matches_the_readings():
	var plate := CadaclysmSolid.cuboid(10, 10, 2)
	var gauge := CadaclysmThicknessGauge.create([plate])
	var m: CadaclysmThicknessMesh = gauge.mesh(0)
	var tris := m.faces.size()
	ok(tris >= 12, "triangles %d" % tris)
	eq(m.triangles.size(), 3 * tris)
	ok(m.positions.size() > 0)
	eq(m.normals.size(), m.positions.size())
	for f in m.faces:
		ok(f >= 0 and f < plate.faces, "face %d" % f)
	for k in m.triangles:
		ok(k >= 0 and k < m.positions.size(), "index %d" % k)
	for n in m.normals:
		near(n.length(), 1.0, THICK_EPS, "unit normal")
	var rows = gauge.thickness(100.0, 0.5)
	eq(rows.size(), m.positions.size())
	for r in rows:
		var t := -1
		for i in range(tris):
			if m.triangles[3 * i] == r.vertex or m.triangles[3 * i + 1] == r.vertex or m.triangles[3 * i + 2] == r.vertex:
				t = i
				break
		ok(t >= 0, "a triangle holds vertex %d" % r.vertex)
		if t >= 0:
			eq(m.faces[t], r.face, "the triangle's face is the row's")
	var message := refuses(func(): return gauge.mesh(1))
	eq(message, "thickness_gauge_mesh: no body 1 -- there are 1")
	gauge.close()
	# copied out: the mesh outlives the gauge, which refuses once closed
	eq(m.positions.size(), rows.size())
	thick_refuses(func(): return gauge.mesh(0), "thickness_gauge: closed")

func test_thickness_at_a_point_reads_one_row_with_no_vertex():
	var plate := CadaclysmSolid.cuboid(10, 10, 2)
	var probe := Vector3(1, 2, 1)
	var gauge := CadaclysmThicknessGauge.create([plate])
	var top := thickness_face_holding(gauge, plate, 0, probe)
	var r = gauge.thickness_at(0, top, probe, 100.0, 0.5)
	ok(r is CadaclysmThickness)
	eq(r.vertex, -1)
	eq([r.body, r.face, r.opposite_body], [0, top, 0])
	eq(r.point, probe)
	near(r.thickness, 2.0, 1e-9)
	near(r.exact_thickness, 2.0, 1e-9)
	near(r.opposite.z, -1.0, THICK_EPS)
	near(r.exact_opposite.z, -1.0, THICK_EPS)
	ok(r.has_sphere)
	near(r.sphere, 2.0, 2 * 0.01)
	# the point as an array of doubles reads the same row
	eq(gauge.thickness_at(0, top, [1.0, 2.0, 1.0], 100.0).thickness, r.thickness)
	# thicker than the maximum: null, and no error
	eq(gauge.thickness_at(0, top, probe, 1.0, 0.5), null)
	eq(Cadaclysm.last_error(), "")
	# the sharp angle defaults to 0
	eq(gauge.thickness_at(0, top, probe, 100.0).thickness, r.thickness)

func test_thickness_at_face_reads_the_plate_and_none_where_nothing_is_found():
	var plate := CadaclysmSolid.cuboid(10, 10, 2)
	var gauge := CadaclysmThicknessGauge.create([plate])
	var top := thickness_face_holding(gauge, plate, 0, Vector3(1, 2, 1))
	var f = gauge.thickness_at_face(0, top, null, 100.0)
	ok(f is CadaclysmFaceThickness)
	near(f.thickness, 2.0, 1e-9)
	eq(f.uniform, true)
	near(f.min, 2.0, 1e-9)
	near(f.max, 2.0, 1e-9)
	ok(str(f).begins_with("FaceThickness("))
	var a = gauge.thickness_at_face(0, top, Vector3(1, 2, 5), 100.0)
	near(a.thickness, 2.0, 1e-9)
	eq(a.min, a.max)
	eq(a.uniform, true)
	eq(gauge.thickness_at_face(0, top, [1.0, 2.0, 5.0], 100.0).thickness, a.thickness)
	# not found: under the maximum, and off the face -- null with no error
	eq(gauge.thickness_at_face(0, top, null, 1.0), null)
	eq(Cadaclysm.last_error(), "")
	eq(gauge.thickness_at_face(0, top, Vector3(50, 2, 5), 100.0), null)
	eq(Cadaclysm.last_error(), "")
	# the one-body convenience: a gauge of its own
	var s = plate.thickness_at_face(top, null, 100.0)
	ok(s is CadaclysmFaceThickness)
	near(s.thickness, 2.0, 1e-9)
	eq(s.uniform, true)
	near(plate.thickness_at_face(top, Vector3(1, 2, 5), 100.0, 0.05).thickness, 2.0, 1e-9)
	eq(plate.thickness_at_face(top, null, 1.0), null)
	eq(Cadaclysm.last_error(), "")

func test_thickness_a_ball_past_the_maximum_is_none():
	var wedge := CadaclysmSolid.extrude(CadaclysmProfile.polygon([[0, 0], [10, 0], [0, 10]]), at(0), 20.0)
	var probe := Vector3(5, 0, 10)
	var gauge := CadaclysmThicknessGauge.create([wedge])
	var f := thickness_face_holding(gauge, wedge, 0, probe)
	var wide = gauge.thickness_at(0, f, probe, 100.0, 0.5)
	ok(wide.has_sphere)
	near(wide.sphere, 2.0 * 5.0 / (1.0 + sqrt(2.0)), 0.01)
	var narrow = gauge.thickness_at(0, f, probe, 4.0, 0.5)
	near(narrow.thickness, 5.0 / sqrt(2.0), 1e-9)
	eq(narrow.has_sphere, false)
	ok(is_nan(narrow.sphere), "no ball is NaN")

func thickness_key(rows: Array) -> Array:
	return rows.map(func(r): return [r.body, r.vertex, r.face, r.thickness, r.opposite_body])

func test_thickness_two_bodies_read_each_other_and_the_one_shot_agrees():
	var slab := CadaclysmSolid.extrude(CadaclysmProfile.polygon([[0, 0], [10, 0], [10, 3], [0, 1]]), at(0), 4.0)
	var tube := thickness_tube()
	var gauge := CadaclysmThicknessGauge.create([slab, tube])
	eq(gauge.body_count, 2)
	var via = gauge.thickness(100.0, 0.5)
	var one = CadaclysmBlacksmith.thickness([slab, tube], 100.0, 0.5)
	ok(one.size() > 0)
	eq(thickness_key(one), thickness_key(via))
	ok(one.any(func(r): return r.body == 0 and r.opposite_body == 1), "the slab reads the tube somewhere")
	ok(one.any(func(r): return r.body == 1 and r.opposite_body == 0), "the tube reads the slab somewhere")
	var none = CadaclysmBlacksmith.thickness([slab], 0.001)
	ok(none is Array)
	eq(none.size(), 0)
	ok(CadaclysmBlacksmith.thickness([slab], 100.0, 0.0, 0.05).size() > 0)

func test_mesh_thickness_two_triangles_one_apart_read_one_across():
	var lower := [[[0, 0, 0], [0, 1, 0], [1, 0, 0]], PackedInt32Array([0, 1, 2])]
	var upper := [[[0, 0, 1], [1, 0, 1], [0, 1, 1]], PackedInt32Array([0, 1, 2])]
	var rows = CadaclysmBlacksmith.mesh_thickness([lower, upper], 10.0, 0.5)
	eq(rows.size(), 6)
	var order := []
	for r in rows:
		ok(r is CadaclysmMeshThickness)
		near(r.thickness, 1.0, 1e-12)
		eq(r.knife, false)
		eq([r.opposite_mesh, r.opposite_triangle], [1 - r.mesh, 0])
		var source: Array = [lower, upper][r.mesh][0][r.vertex]
		thick_near(r.point, Vector3(source[0], source[1], source[2]), "point")
		near(r.raw_point[2], float(source[2]), 1e-12)
		near(r.opposite.z, 1.0 - r.point.z, THICK_EPS)
		near(r.raw_opposite[2], 1.0 - r.raw_point[2], 1e-12)
		near(r.opposite.x, r.point.x, THICK_EPS)
		near(r.opposite.y, r.point.y, THICK_EPS)
		order.append([r.mesh, r.vertex])
	eq(order, [[0, 0], [0, 1], [0, 2], [1, 0], [1, 1], [1, 2]])
	ok(str(rows[0]).begins_with("MeshThickness("))
	# under the gap nothing; no meshes at all, nothing
	var none = CadaclysmBlacksmith.mesh_thickness([lower, upper], 0.5, 0.5)
	ok(none is Array)
	eq(none.size(), 0)
	eq(CadaclysmBlacksmith.mesh_thickness([], 1.0).size(), 0)
	# the other input shapes: packed points, triangles as an array of triples
	var packed := [PackedVector3Array([Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 0, 0)]), [Vector3i(0, 1, 2)]]
	var rows2 = CadaclysmBlacksmith.mesh_thickness([packed, upper], 10.0)
	eq(rows2.size(), 6)
	var rows3 = CadaclysmBlacksmith.mesh_thickness([[[[0, 0, 0], [0, 1, 0], [1, 0, 0]], [[0, 1, 2]]], upper], 10.0)
	eq(rows3.size(), 6)

func test_thickness_refusals_carry_the_calls_prefix():
	var plate := CadaclysmSolid.cuboid(10, 10, 2)
	thick_refuses(func(): return CadaclysmThicknessGauge.create([plate], -1.0), "thickness_gauge_new: the tolerance must be positive and finite")
	var gauge := CadaclysmThicknessGauge.create([plate])
	thick_refuses(func(): return gauge.thickness(0.0), "thickness_gauge_measure: the maximum must be positive and finite")
	thick_refuses(func(): return gauge.thickness(10.0, -0.1), "thickness_gauge_measure: the sharp angle must be zero or positive and finite")
	eq(refuses(func(): return gauge.thickness_at(3, 0, Vector3(1, 2, 1), 10.0)), "thickness_gauge_at: no body 3 -- there are 1")
	eq(refuses(func(): return gauge.thickness_at(0, 99, Vector3(1, 2, 1), 10.0)), "thickness_gauge_at: no face 99 -- the solid has 6 (0 to 5)")
	refuses(func(): return gauge.thickness_at(0, 0, Vector3(1, NAN, 1), 10.0), "thickness_gauge_at: the point must be finite")
	eq(refuses(func(): return gauge.thickness_at(0, 0, [1.0, 2.0], 10.0)), "thickness_gauge_at: a point is 3 numbers, got 2")
	refuses(func(): return gauge.thickness_at(0, 0, "x", 10.0), "thickness_gauge_at: a point is 3 numbers, not")
	eq(refuses(func(): return gauge.thickness_at(-1, 0, Vector3(1, 2, 1), 10.0)), "thickness_gauge_at: body is out of range: -1")
	eq(refuses(func(): return gauge.thickness_at(0, 1 << 32, Vector3(1, 2, 1), 10.0)), "thickness_gauge_at: face is out of range: %d" % (1 << 32))
	eq(refuses(func(): return gauge.thickness_at_face(2, 0, null, 10.0)), "thickness_gauge_face: no body 2 -- there are 1")
	eq(refuses(func(): return gauge.thickness_at_face(0, 99, null, 10.0)), "thickness_gauge_face: no face 99 -- the solid has 6 (0 to 5)")
	refuses(func(): return gauge.thickness_at_face(0, 0, Vector3(INF, 0, 1), 10.0), "thickness_gauge_face: the point must be finite")
	refuses(func(): return gauge.thickness_at_face(0, 0, [1.0], 10.0), "thickness_gauge_face: a point is 3 numbers, got 1")
	refuses(func(): return gauge.thickness_at_face(0, 0, null, 0.0), "thickness_gauge_face: the maximum must be positive and finite")
	eq(refuses(func(): return gauge.thickness_at_face(0, -1, null, 10.0)), "thickness_gauge_face: face is out of range: -1")
	eq(refuses(func(): return gauge.mesh(-1)), "thickness_gauge_mesh: body is out of range: -1")
	gauge.close()
	gauge.close()   # twice is a no-op
	eq(gauge.closed, true)
	eq(gauge.body_count, 0)
	thick_refuses(func(): return gauge.thickness(10.0), "thickness_gauge: closed")
	thick_refuses(func(): return gauge.thickness_at(0, 0, Vector3(1, 2, 1), 10.0), "thickness_gauge: closed")
	thick_refuses(func(): return gauge.thickness_at_face(0, 0, null, 10.0), "thickness_gauge: closed")
	# the conveniences refuse with the gauge call's own prefix
	thick_refuses(func(): return CadaclysmBlacksmith.thickness([plate], -1.0), "thickness_gauge_measure: the maximum must be positive and finite")
	thick_refuses(func(): return CadaclysmBlacksmith.thickness([plate], 10.0, 0.0, INF), "thickness_gauge_new: the tolerance must be positive and finite")
	thick_refuses(func(): return CadaclysmBlacksmith.thickness(["x"], 10.0), "thickness: solids: expected CadaclysmSolids")
	thick_refuses(func(): return plate.thickness_at_face(99, null, 10.0), "thickness_gauge_face: no face 99")
	thick_refuses(func(): return plate.thickness_at_face(0, [1.0, 2.0], 10.0), "thickness_gauge_face: a point is 3 numbers, got 2")
	# mesh_thickness: the kernel's refusals and the wrapper's own
	var lower := [[[0, 0, 0], [0, 1, 0], [1, 0, 0]], PackedInt32Array([0, 1, 2])]
	var upper := [[[0, 0, 1], [1, 0, 1], [0, 1, 1]], PackedInt32Array([0, 1, 2])]
	var meshes := [lower, upper]
	thick_refuses(func(): return CadaclysmBlacksmith.mesh_thickness(meshes, 0.0), "mesh_thickness: the maximum must be positive and finite")
	thick_refuses(func(): return CadaclysmBlacksmith.mesh_thickness(meshes, 10.0, -0.5), "mesh_thickness: the sharp angle must be zero or positive and finite")
	thick_refuses(func(): return CadaclysmBlacksmith.mesh_thickness([[[[0, 0, 0], [1, 0, 0]], PackedInt32Array([0, 1, 2])]], 10.0), "mesh_thickness: a triangle names a position past the mesh")
	thick_refuses(func(): return CadaclysmBlacksmith.mesh_thickness([[[[0, 0, 0], [1, NAN, 0], [0, 1, 0]], PackedInt32Array([0, 1, 2])]], 10.0), "mesh_thickness: a mesh position is not finite")
	thick_refuses(func(): return CadaclysmBlacksmith.mesh_thickness([lower, 5], 10.0), "mesh_thickness: mesh 1 is not a [positions, triangles] pair")
	thick_refuses(func(): return CadaclysmBlacksmith.mesh_thickness([[lower[0]]], 10.0), "mesh_thickness: mesh 0 is not a [positions, triangles] pair")
	thick_refuses(func(): return CadaclysmBlacksmith.mesh_thickness([[[[0, 0, 0], [1, 0]], PackedInt32Array([0, 1, 2])]], 10.0), "mesh_thickness: mesh 0 position 1 is not three numbers")
	thick_refuses(func(): return CadaclysmBlacksmith.mesh_thickness([[lower[0], PackedInt32Array([0, 1])]], 10.0), "mesh_thickness: mesh 0 triangle 0 is not three indices")
	thick_refuses(func(): return CadaclysmBlacksmith.mesh_thickness([[lower[0], PackedInt32Array([0, 1, -2])]], 10.0), "mesh_thickness: mesh 0 triangle 0 is not three indices")
	thick_refuses(func(): return CadaclysmBlacksmith.mesh_thickness([[lower[0], [[0, 1]]]], 10.0), "mesh_thickness: mesh 0 triangle 0 is not three indices")
	thick_refuses(func(): return CadaclysmBlacksmith.mesh_thickness([[lower[0], [[0, 1, 4294967296]]]], 10.0), "mesh_thickness: mesh 0 triangle 0 is not three indices")
	thick_refuses(func(): return CadaclysmBlacksmith.mesh_thickness([[lower[0], [[0, 1, 1.5]]]], 10.0), "mesh_thickness: mesh 0 triangle 0 is not three indices")

# ---- identity: ids, origins, history, attributes, edge and vertex references --------
# Python's TestIdentity, ported. Ids are ints, -1 for none (Godot has no null int);
# origins are [operand, id] Arrays; attribute reads are `null` where there is none.

# A 10-cube centred on the origin and a pin through it (radius 2, along z, z -10..10),
# both tracked.
func block_and_pin() -> Array:
	return [CadaclysmSolid.cuboid(10, 10, 10).tracked(), CadaclysmSolid.cylinder(2, 20).translate(0, 0, -10).tracked()]

# Face `f`'s outward normal's z, off its reference.
func nz(solid: CadaclysmSolid, f: int) -> float:
	return solid.face_ref(f)[6]

func test_tracking_numbers_faces_and_edges_and_an_untracked_solid_has_no_ids():
	var plain := CadaclysmSolid.cuboid(1, 2, 3)
	eq(plain.is_tracked, false)
	eq(plain.face_id(0), -1, "untracked: none")
	eq(plain.edge_id(0), -1)
	eq(plain.face_origins(0), [])
	var t := plain.tracked()
	eq(t.is_tracked, true)
	eq(t.tracked().face_id(5), 6, "a tracked solid comes back as it is")
	eq(range(6).map(func(f): return t.face_id(f)), [1, 2, 3, 4, 5, 6])
	eq(range(12).map(func(e): return t.edge_id(e)), range(1, 13))
	eq([t.face_with_id(4), t.face_with_id(7), t.face_with_id(0)], [3, -1, -1])
	eq([t.edge_with_id(12), t.edge_with_id(13)], [11, -1])
	eq(t.face_origins(2), [[0, 3]])
	eq(t.edge_origins(11), [[0, 12]])
	eq(refuses(func(): return t.face_id(6)), "face_id: face 6 of 6")
	eq(t.face_id(6), -1)
	eq(refuses(func(): return t.face_origins(6)), "face_origin_count: face 6 of 6")
	eq(refuses(func(): return t.edge_id(12)), "edge_id: edge 12 of 12")

func test_a_cuts_origins_and_history():
	var bp := block_and_pin()
	var block: CadaclysmSolid = bp[0]
	var pin: CadaclysmSolid = bp[1]
	var wall: int = count_faces(pin, "cylinder")[0]
	var wall_id := pin.face_id(wall)
	var caps := []
	for f in pin.faces:
		if f != wall:
			caps.append([1, pin.face_id(f)])
	var cut := block.cut(pin)
	var bore: int = count_faces(cut, "cylinder")[0]
	eq(cut.face_origins(bore), [[1, wall_id]], "the bore came from the pin's wall")
	eq(cut.face_id(bore), 7, "renumbered: the wall's id is the box's")
	for f in cut.faces:
		if f != bore:
			eq(cut.face_origins(f), [[0, cut.face_id(f)]], "the box's own")
	var h := cut.history([block, pin])
	ok(h is CadaclysmHistory)
	eq(h.kept, range(1, 7).map(func(k): return [[0, k], k]), "the box's six kept")
	eq(h.modified, [[[1, wall_id], [7]]], "the bore modified")
	eq(h.generated, [])
	eq(h.deleted, caps, "the pin's two caps deleted")
	eq(str(h), "History(kept=6, modified=1, generated=0, deleted=2)")
	var e := cut.edge_history([block, pin])
	eq([e.kept.size(), e.deleted, e.generated.size(), e.modified], [12, [[1, 1], [1, 2], [1, 3]], 3, []])
	eq(refuses(func(): return cut.history([block, CadaclysmSolid.cuboid(1, 1, 1)])), "history: input 1 is not tracked")
	eq(cut.history([block, CadaclysmSolid.cuboid(1, 1, 1)]), null)
	ok(refuses(func(): return cut.history([block])).begins_with("history: face "), Cadaclysm.last_error())
	ok(Cadaclysm.last_error().contains(" names operand 1"), Cadaclysm.last_error())
	eq(refuses(func(): return CadaclysmSolid.cuboid(1, 1, 1).edge_history([block])), "edge_history: the result is not tracked")

func test_a_union_renumbers_the_second_operands_clashing_ids():
	var a := CadaclysmSolid.cuboid(10, 10, 10).tracked()
	var b := CadaclysmSolid.cuboid(10, 10, 10).translate(5, 5, 5).tracked()
	var joined := a.join(b)
	eq(joined.faces, 12)
	var firsts := []
	var seconds := []
	var theirs := []
	for f in joined.faces:
		var o: Array = joined.face_origins(f)[0]
		if o[0] == 0:
			eq(joined.face_id(f), o[1])
			firsts.append(o[1])
		else:
			seconds.append(joined.face_id(f))
			theirs.append(o[1])
	firsts.sort()
	theirs.sort()
	eq(firsts, [1, 2, 3, 4, 5, 6])
	eq(seconds, [7, 8, 9, 10, 11, 12], "renumbered in face order")
	eq(theirs, [1, 2, 3, 4, 5, 6], "their origins name operand 1's own ids")

func test_a_split_halves_the_sides_and_its_bodies_keep_the_splits_origins():
	var block := CadaclysmSolid.cuboid(2, 4, 6).tracked()
	var pieces := block.split_by_plane(XY)
	eq(pieces.size(), 2)
	var halves := {}
	for f in 6:
		if absf(nz(block, f)) < 0.5:
			halves[block.face_id(f)] = []
	eq(halves.size(), 4)
	var cut_faces := 0
	var caps := 0
	for piece in pieces:
		for f in piece.faces:
			var o: Array = piece.face_origins(f)
			var id := piece.face_id(f)
			if o.is_empty():
				ok(id > 6, "a cut face is generated, with a fresh id")
				cut_faces += 1
			elif halves.has(o[0][1]):
				eq(o, [[0, o[0][1]]])
				halves[o[0][1]].append(id)
			else:
				eq(o, [[0, id]], "a cap is kept")
				caps += 1
	eq([cut_faces, caps], [2, 2])
	for s in halves:
		var ids: Array = halves[s]
		ok(ids.size() == 2 and ids.count(s) == 1, "side %d in two, one half keeping its id: %s" % [s, ids])
	for piece in pieces:
		var h := piece.history([block])
		eq([h.generated.size(), h.deleted.size()], [1, 1], "its cut face generated, the other body's cap deleted")

func test_a_fillets_round_is_generated():
	var block := CadaclysmSolid.cuboid(10, 10, 10).tracked()
	var rounded := block.fillet([0], 1.0)
	eq(rounded.faces, 7)
	var round_: int = range(rounded.faces).filter(func(f): return rounded.face_kind(f) != "plane")[0]
	eq(rounded.face_origins(round_), [])
	eq(rounded.face_id(round_), 7)
	var h := rounded.history([block])
	eq(h.generated, [7])
	eq(h.kept.size(), 6)
	eq(rounded.edge_with_id(1), -1, "the rounded edge is gone")

func test_a_flush_join_merged_names_one_origin_per_input():
	var a := CadaclysmSolid.cuboid(10, 10, 10).tracked()
	var b := CadaclysmSolid.cuboid(4, 10, 10).translate(7, 0, 0).tracked()
	var merged := a.join(b, 0.05, true)
	eq(merged.faces, 6)
	var two := 0
	for f in merged.faces:
		var o: Array = merged.face_origins(f)
		if absf(merged.face_ref(f)[4]) < 0.5:
			# The four faces along x: one origin in each box, [0, id] and [1, id].
			eq(o.map(func(p): return p[0]), [0, 1], "face %d: %s" % [f, o])
			if o.size() == 2:
				ok(a.face_with_id(o[0][1]) != -1 and b.face_with_id(o[1][1]) != -1, str(o))
			two += 1
		else:
			eq(o.size(), 1, "face %d: %s" % [f, o])
	eq(two, 4)
	var h := merged.history([a, b])
	eq(h.generated, [])
	eq(h.deleted.size(), 2, "the two flush faces")
	eq(h.modified.filter(func(m): return m[1].size() == 1 and m[0][0] == 1).size(), 4)

func test_the_same_chain_twice_numbers_the_same():
	var run := func() -> Array:
		var bp := block_and_pin()
		var cut: CadaclysmSolid = bp[0].cut(bp[1])
		var line: int = cut.edges.filter(func(e): return e.kind == "line")[0].index
		var r := cut.fillet([line], 1.0)
		return [range(r.faces).map(func(f): return r.face_id(f)), range(r.edges.size()).map(func(e): return r.edge_id(e))]
	var first: Array = run.call()
	ok(not first[0].has(-1) and not first[1].has(-1), "every face and edge has an id")
	eq(run.call(), first)

func test_attributes_are_set_read_listed_and_refused():
	var s := CadaclysmSolid.cuboid(1, 2, 3).with_attribute("material", "steel")
	eq(s.is_tracked, true, "an attribute rides with the ids")
	eq(s.attribute("material"), "steel")
	eq(s.attribute("absent"), null)
	eq(s.attributes, {"material": "steel"})
	ok(s.attributes.is_read_only(), "read-only")
	var both := s.with_attributes({"zeta": "1", "alpha": "2"})
	eq(both.attributes.keys(), ["alpha", "material", "zeta"], "in key order")
	eq(both.attributes.values(), ["2", "steel", "1"])
	var text := "acciaio inossidabile è ☃ 🔧"
	eq(s.with_attribute("m", text).attribute("m"), text)
	eq(s.with_attribute("empty", "").attribute("empty"), "")
	eq(refuses(func(): return s.with_attribute("", "x")), "with_attribute: the key is empty")
	eq(s.with_attribute("", "x"), null)
	eq(s.without_attribute("absent").attributes, {"material": "steel"})
	eq(s.without_attribute("material").attributes, {})
	eq(CadaclysmSolid.cuboid(1, 1, 1).attributes, {})
	eq(s.with_attributes({}).attributes, {"material": "steel"}, "no attributes: an equal solid")
	refuses(func(): return s.with_attributes({"a": 1}), "with_attributes: keys and values are Strings")

func test_face_attributes_survive_a_translate_and_a_split():
	var block := CadaclysmSolid.cuboid(10, 10, 10)
	var side: int = range(6).filter(func(f): return absf(nz(block, f)) < 0.5)[0]
	var s := block.with_face_attribute(side, "finish", "ground")
	eq(s.face_attribute(side, "finish"), "ground")
	var other := (side + 1) % 6
	eq(s.face_attribute(other, "finish"), null)
	eq(s.face_attributes(other), {})
	eq(s.face_attributes(side), {"finish": "ground"})
	ok(s.face_attributes(side).is_read_only(), "read-only")
	var two := s.with_face_attributes(side, {"b": "1", "a": "2"})
	eq(two.face_attributes(side).keys(), ["a", "b", "finish"])
	eq(s.without_face_attribute(side, "finish").face_attributes(side), {})
	eq(s.translate(5, 0, 0).face_attribute(side, "finish"), "ground")
	eq(refuses(func(): return s.face_attribute(6, "finish")), "face_attribute: face 6 is not one of the solid's 6")
	eq(refuses(func(): return s.with_face_attribute(side, "", "x")), "with_face_attribute: the key is empty")
	# A split face's pieces keep their parent's attributes.
	var side_id := s.face_id(side)
	var found := []
	for p in s.split_by_plane(XY):
		for f in p.faces:
			if p.face_origins(f).has([0, side_id]):
				found.append(p.face_attribute(f, "finish"))
	eq(found, ["ground", "ground"])

func test_a_solids_attributes_reach_step():
	var text := CadaclysmSolid.cuboid(1, 2, 3).with_attribute("material", "steel").step_text()
	eq(text.count("PROPERTY_DEFINITION('material','user defined attribute',"), 1)
	ok(text.contains("DESCRIPTIVE_REPRESENTATION_ITEM('material','steel')"), "the value written")
	ok(text.split("ENDSEC;")[0].contains("AP242"), "the header names the AP242 schema")

func test_edges_are_found_again_after_a_stretch_and_vertices_after_a_move():
	var box := CadaclysmSolid.cuboid(10, 10, 10)
	var long := CadaclysmSolid.cuboid(11, 10, 10)
	var n := box.edges.size()
	var refs := range(n).map(func(e): return box.edge_ref(e))
	ok(refs.all(func(r): return r is PackedFloat64Array and r.size() == 15), "fifteen doubles each")
	var found := refs.map(func(r): return long.find_edge(r))
	var sorted := found.duplicate()
	sorted.sort()
	eq(sorted, range(n), "a permutation of all twelve: %s" % [found])
	for i in n:
		var r: PackedFloat64Array = refs[i]
		var tangent := long.edge_ref(found[i]).slice(4, 7)
		ok(absf(r[4] * tangent[0] + r[5] * tangent[1] + r[6] * tangent[2]) > 0.99, "tangents parallel")
	var bad: PackedFloat64Array = refs[0].duplicate()
	bad[1] = NAN
	eq(refuses(func(): return box.find_edge(bad)), "find_edge: an edge reference is fifteen finite numbers")
	eq(box.find_edge(bad), -1)
	eq(refuses(func(): return box.find_edge(refs[0].slice(0, 14))), "find_edge: an edge reference is fifteen finite numbers")
	eq(refuses(func(): return box.edge_ref(12)), "edge_ref: edge 12 of 12")
	eq(box.edge_ref(12), PackedFloat64Array())
	eq(box.vertex_count, 8)
	var moved := box.translate(1e-4, 0, 0)
	for v in 8:
		var p := box.vertex_ref(v)
		eq(p.size(), 3)
		eq(moved.find_vertex(p), v)
	eq(box.find_vertex([100.0, 0.0, 0.0]), -1, "none that near")
	eq(Cadaclysm.last_error(), "", "none is not an error")
	ok(refuses(func(): return box.find_vertex([0.0, 0.0, NAN])).begins_with("find_vertex: "), Cadaclysm.last_error())

# ---- CadaclysmNurbsCurve: curves in space (Python's NurbsCurve tests, ported) -------------
# The curve keeps the kernel's doubles (a point is three in a PackedFloat64Array), so these
# compare at Python's tolerances; a CadaclysmAt's point is a Vector3, so floats: 1e-5.

func pdist(a, b) -> float:
	return sqrt(pow(a[0] - b[0], 2) + pow(a[1] - b[1], 2) + pow(a[2] - b[2], 2))

func hypot(p) -> float:
	return sqrt(p[0] * p[0] + p[1] * p[1])

# `fails`, and the message starts with `prefix`: the call's own name, as Python's `^name: `.
func refuses_as(f: Callable, prefix: String) -> String:
	var message := refuses(f, prefix)
	ok(message.begins_with(prefix), "expected an error starting %s, got %s" % [prefix, message])
	return message

func quarter_circle(r := 2.0) -> CadaclysmNurbsCurve:
	return CadaclysmNurbsCurve.create([[r, 0, 0], [r, r, 0], [0, r, 0]], 2, PackedFloat64Array([1, sqrt(0.5), 1]))

# The whole circle of radius `r` about `centre`, in its z plane: nine rational quadratic points.
func exact_circle(centre: Array, r: float) -> CadaclysmNurbsCurve:
	var pts := []
	for ab in [[1, 0], [1, 1], [0, 1], [-1, 1], [-1, 0], [-1, -1], [0, -1], [1, -1], [1, 0]]:
		pts.append([centre[0] + r * ab[0], centre[1] + r * ab[1], centre[2]])
	var h := sqrt(0.5)
	return CadaclysmNurbsCurve.create(pts, 2, PackedFloat64Array([1, h, 1, h, 1, h, 1, h, 1]),
		PackedFloat64Array([0, 0, 0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1, 1, 1]))

func segment(a, b) -> CadaclysmNurbsCurve:
	return CadaclysmNurbsCurve.create([a, b], 1)

func mix(p, q, f: float) -> Array:
	return [p[0] + f * (q[0] - p[0]), p[1] + f * (q[1] - p[1]), p[2] + f * (q[2] - p[2])]

# Each tween's ends are `a`'s and `b`'s blended at `(i + 1) / (tweens.size() + 1)`.
func ends_blended(a: CadaclysmNurbsCurve, b: CadaclysmNurbsCurve, tweens: Array, tolerance: float) -> void:
	var a0 := a.point(a.domain[0])
	var a1 := a.point(a.domain[1])
	var b0 := b.point(b.domain[0])
	var b1 := b.point(b.domain[1])
	for i in tweens.size():
		var f := (i + 1.0) / (tweens.size() + 1)
		var t: CadaclysmNurbsCurve = tweens[i]
		ok(pdist(t.point(t.domain[0]), mix(a0, b0, f)) < tolerance, "tween %d starts on the blend" % i)
		ok(pdist(t.point(t.domain[1]), mix(a1, b1, f)) < tolerance, "tween %d ends on the blend" % i)

func test_a_nurbs_curve_reads_back_what_it_was_built_from():
	var c := quarter_circle()
	eq(c.degree, 2)
	ok(c.is_rational)
	ok(not c.is_closed)
	eq(c.control_points, PackedFloat64Array([2, 0, 0, 2, 2, 0, 0, 2, 0]))
	ok(all_near(c.weights, [1, sqrt(0.5), 1], 1e-15), str(c.weights))
	eq(c.knots, PackedFloat64Array([0, 0, 0, 1, 1, 1]))
	eq(c.domain, PackedFloat64Array([0, 1]))
	eq(c.fit_error, null)
	near(pdist(c.point(0.37), [0, 0, 0]), 2, 1e-12)
	var k := c.curvature(0.5)
	near(k.kappa, 0.5, 1e-12)
	ok(pdist(k.centre, [0, 0, 0]) < 1e-12, str(k.centre))
	eq(k.tangent.size(), 3)
	near(c.length().length, PI, 1e-9)
	var at := c.point_at_length(PI / 2)
	ok(v3near(at.point, Vector3(sqrt(2), sqrt(2), 0), 1e-5), str(at.point))
	eq(at.segment, -1)
	eq(c.divide_by_count(4).size(), 5)
	eq(c.divide_by_length(1.0).size(), 4)
	var d := c.derivatives(0.0, 2)
	eq(d.size(), 3)
	eq(d[0], PackedFloat64Array([2, 0, 0]))
	ok(absf(d[1][0]) < 1e-12 and d[1][1] > 0, str(d[1]))
	ok(str(c).begins_with("NurbsCurve(degree=2"), str(c))
	var straight := CadaclysmNurbsCurve.create([[0, 0, 0], [1, 0, 0]], 1)
	var s := straight.curvature(0.5)
	eq(s.centre, null)
	near(s.kappa, 0, 0)
	ok(not straight.is_rational)

func test_a_curve_through_points_and_its_edits():
	var ring := []
	for i in 10:
		var a := TAU * i / 10
		ring.append([cos(a), sin(a), 0.2 * sin(3 * a)])
	var closed := CadaclysmNurbsCurve.through(ring, 3, true)
	ok(closed.is_closed)
	eq(closed.divide_by_count(6).size(), 6)
	var c := CadaclysmNurbsCurve.through([[0, 0, 0], [1, 2, 0.5], [3, 1, -0.5], [4, 3, 1], [6, 2, 0]], 3, false, PackedFloat64Array([0, 0, 5]))
	var lo: float = c.domain[0]
	var hi: float = c.domain[1]
	var d: PackedFloat64Array = c.derivatives(lo, 1)[1]
	ok(absf(d[0]) < 1e-9 and absf(d[1]) < 1e-9 and d[2] > 0, str(d))
	var samples := []
	for t in 200:
		samples.append([t / 50.0, sin(t / 50.0), 0])
	var fit := CadaclysmNurbsCurve.fit(samples, 3, 1e-4)
	ok(fit.fit_error != null and fit.fit_error >= 0 and fit.fit_error <= 1e-4, str(fit.fit_error))
	ok(pdist(c.reversed().point(lo), c.point(hi)) < 1e-12)
	var mid := 0.5 * (lo + hi)
	eq(c.trimmed(lo, mid).domain, PackedFloat64Array([lo, mid]))
	var longer := c.extended(0.5)
	ok(longer.domain[1] > hi and pdist(longer.point(hi), c.point(hi)) < 1e-9, str(longer.domain))
	var earlier := c.extended(0.5, true)
	ok(earlier.domain[0] < lo and earlier.domain[1] == hi, str(earlier.domain))
	eq(c.elevated(2).degree, 5)
	eq(c.elevated().degree, 4)

func test_curves_join_end_to_end():
	# A line to (2, 0, 0), the quarter circle from there given backwards, and a quintic on.
	var lead := segment([2, -3, 0], [2, 0, 0])
	var arc := quarter_circle()
	var tail := CadaclysmNurbsCurve.create([[0, 2, 0], [-1, 2.5, 0], [-2, 2, 1], [-3, 3, 0], [-4, 2, 0], [-5, 2, 2]], 5)
	var j := CadaclysmNurbsCurve.joined([lead, arc.reversed(), tail])
	eq(j.degree, 5)
	eq(j.domain, PackedFloat64Array([0, 3]))
	for row in [[0, [2, -3, 0]], [1, [2, 0, 0]], [2, [0, 2, 0]], [3, [-5, 2, 2]]]:
		ok(pdist(j.point(row[0]), row[1]) < 1e-12, str(row))
	for i in 21:
		near(pdist(j.point(1 + i / 20.0), [0, 0, 0]), 2, 1e-12)
		ok(pdist(j.point(2 + i / 20.0), tail.point(i / 20.0)) < 1e-12)
	eq(CadaclysmNurbsCurve.joined([arc]).control_points, arc.control_points)
	var message := refuses_as(func(): return CadaclysmNurbsCurve.joined([lead, tail]), "nurbs_curve_joined: curve 1")
	ok(message.contains("curve 0"), message)
	refuses_as(func(): return CadaclysmNurbsCurve.joined([]), "nurbs_curve_joined: ")
	refuses_as(func(): return CadaclysmNurbsCurve.joined([lead, 7]), "nurbs_curve_joined: curves")

func test_tweens_blend_from_one_curve_to_another():
	var a := CadaclysmNurbsCurve.create([[0, 0, 0], [3, 2, 0], [6, -1, 0], [10, 0, 0]], 3)
	var b := CadaclysmNurbsCurve.create([[0, 1, 5], [4, 4, 5], [7, -3, 6], [10, 1, 5]], 3)
	var plain := a.tween(b, 3, "plain")
	eq(plain.size(), 3)
	ends_blended(a, b, plain, 1e-12)
	ok(pdist(plain[1].control_points.slice(3, 6), [3.5, 3, 2.5]) < 1e-12, str(plain[1].control_points))
	var matching := a.tween(b, 2)
	eq(matching.size(), 2)
	ends_blended(a, b, matching, 1e-12)
	var sampled := a.tween(b, 4, "sampling", 20)
	eq(sampled.size(), 4)
	for t in sampled:
		eq(t.degree, 3)
	ends_blended(a, b, sampled, 1e-9)
	eq(a.tween(b, 1, "matching", 0, true, 0.0).size(), 1)
	# A quadratic against the cubic: plain refuses in the library's words; matching makes one.
	var q := CadaclysmNurbsCurve.create([[0, 1, 5], [5, 4, 5], [10, 1, 5]], 2)
	var message := refuses_as(func(): return a.tween(q, 2, "plain"), "nurbs_curve_tween: ")
	ok(message.contains("compatible"), message)
	var mixed := a.tween(q, 2)
	eq(mixed[0].degree, 3)
	ends_blended(a, q, mixed, 1e-12)
	refuses_as(func(): return a.tween(b, 0), "nurbs_curve_tween: ")

func test_tween_samples_and_method_are_checked():
	var a := CadaclysmNurbsCurve.create([[0, 0, 0], [3, 2, 0], [6, -1, 0], [10, 0, 0]], 3)
	var b := CadaclysmNurbsCurve.create([[0, 1, 5], [4, 4, 5], [7, -3, 6], [10, 1, 5]], 3)
	refuses_as(func(): return a.tween(b, 2, "sampling"), "nurbs_curve_tween: sampling needs samples")
	refuses_as(func(): return a.tween(b, 2, "matching", 10), "nurbs_curve_tween: samples is read only by sampling, not matching")
	refuses_as(func(): return a.tween(b, 2, "loft"), "nurbs_curve_tween: method must be one of plain, matching, sampling, not 'loft'")
	refuses_as(func(): return a.tween(b, 2, "sampling", 1), "nurbs_curve_tween: sampling needs at least")
	refuses_as(func(): return a.tween(b, -1), "nurbs_curve_tween: count")
	refuses_as(func(): return a.tween(b, 2, "sampling", -4), "nurbs_curve_tween: samples")

func test_tweens_of_two_circles_are_closed_circles():
	var small := exact_circle([0, 0, 0], 2)
	var big := exact_circle([0, 0, 6], 4)
	for row in [["plain", 0, 1e-12], ["matching", 0, 1e-12], ["sampling", 40, 1e-4]]:
		var tweens := small.tween(big, 3, row[0], row[1])
		eq(tweens.size(), 3, row[0])
		for i in tweens.size():
			var f := (i + 1) / 4.0
			var t: CadaclysmNurbsCurve = tweens[i]
			ok(t.is_closed, "%s %d is closed" % [row[0], i])
			var lo: float = t.domain[0]
			var hi: float = t.domain[1]
			for k in 24:
				var p := t.point(lo + (hi - lo) * k / 24.0)
				ok(absf(hypot(p) - (2 + 2 * f)) < row[2] and absf(p[2] - 6 * f) < row[2], "%s %d %d: %s" % [row[0], i, k, p])

func test_a_curve_from_an_edge_a_plane_and_a_sphere():
	var cyl := CadaclysmSolid.cylinder(2.5, 4)
	var rims := []
	for e in cyl.edges:
		if e.kind == "circle":
			rims.append(CadaclysmNurbsCurve.from_edge(cyl, e))
			rims.append(CadaclysmNurbsCurve.from_edge(cyl, e.index))
	ok(rims.size() >= 4, str(rims.size()))
	for rim in rims:
		var lo: float = rim.domain[0]
		var hi: float = rim.domain[1]
		for t in [lo, 0.5 * (lo + hi), hi]:
			near(hypot(rim.point(t)), 2.5, 1e-12)
	var sphere := CadaclysmSolid.sphere(3)
	var line := segment([-2, 0.5, 10], [2, -0.5, 10])
	var on := line.projected_to_face(sphere, 0, [0, 0, -1], 1e-4)
	ok(on.fit_error != null and on.fit_error <= 1e-4, str(on.fit_error))
	near(pdist(on.point(0.5 * (on.domain[0] + on.domain[1])), [0, 0, 0]), 3, 1e-4)
	var pulled := line.pulled_to_face(sphere, 0, 1e-4)
	near(pdist(pulled.point(pulled.domain[0]), [0, 0, 0]), 3, 1e-4)
	ok(pulled.fit_error != null)
	var through := segment([-5, 1, 1], [5, 1, 1])
	var hits := through.face_hits(sphere, 0, 1e-6)
	eq(hits.size(), 2)
	near(hits[0].point.x, -sqrt(7), 1e-5)
	var crossing := through.plane_hits([0, 0, 0], [1, 0, 0])
	eq(crossing.size(), 1)
	ok(v3near(crossing[0].point, Vector3(0, 1, 1), 1e-6), str(crossing[0].point))
	var flat := line.projected_to_plane([0, 0, 1], [0, 0, 1])
	eq(flat.point(0), PackedFloat64Array([-2, 0.5, 1]))
	eq(flat.fit_error, null)
	var slanted := line.projected_to_plane([0, 0, 1], [0, 0, 1], PackedFloat64Array([1, 0, -1]))
	ok(pdist(slanted.point(0), [7, 0.5, 1]) < 1e-12, str(slanted.point(0)))
	var blend := CadaclysmNurbsCurve.blend(quarter_circle(), true, through, false, 2)
	eq(blend.degree, 5)
	near(blend.curvature(0).kappa, 0.5, 1e-9)
	var teeth := quarter_circle().comb(8)
	eq(teeth.size(), 18)
	for i in 9:
		near(teeth[2 * i].distance_to(teeth[2 * i + 1]), 0.5, 1e-5)

func test_nurbs_curve_refusals_name_the_call():
	var q := quarter_circle()
	var cube := CadaclysmSolid.cuboid(1, 1, 1)
	var two := [[0, 0, 0], [1, 0, 0]]
	for row in [
		[func(): return CadaclysmNurbsCurve.create(two, 9), "nurbs_curve_new: "],
		[func(): return CadaclysmNurbsCurve.create(two, 1, PackedFloat64Array([1, -1])), "nurbs_curve_new: "],
		[func(): return CadaclysmNurbsCurve.create(two, 1, PackedFloat64Array([1])), "nurbs_curve_new: 1 weights for 2 points; give one per point"],
		[func(): return CadaclysmNurbsCurve.create([[0, 0], [1, 0]], 1), "nurbs_curve_new: a point is 3 numbers"],
		[func(): return CadaclysmNurbsCurve.through(two, 3), "nurbs_curve_through: "],
		[func(): return CadaclysmNurbsCurve.through(two, 1, false, PackedFloat64Array([1, 0])), "nurbs_curve_through: start_tangent"],
		[func(): return CadaclysmNurbsCurve.fit(two, 1, -1), "nurbs_curve_fit: "],
		[func(): return CadaclysmNurbsCurve.from_edge(cube, 999), "nurbs_curve_from_edge: "],
		[func(): return CadaclysmNurbsCurve.from_edge(cube, -1), "nurbs_curve_from_edge: "],
		[func(): return CadaclysmNurbsCurve.isocurve(cube, 0, true, 0.5), "nurbs_curve_from_face_isocurve: "],
		[func(): return CadaclysmNurbsCurve.blend(q, true, q, true, 3), "nurbs_curve_blend: "],
		[func(): return q.projected_to_plane([0, 0, 0], [0, 0, 1], PackedFloat64Array([1, 0, 0])), "nurbs_curve_projected_to_plane: "],
		[func(): return q.trimmed(0.5, 0.2), "nurbs_curve_trimmed: "],
		[func(): return q.extended(0), "nurbs_curve_extended: "],
		[func(): return q.point(2), "nurbs_curve_point: "],
		[func(): return q.derivatives(0.5, 9), "nurbs_curve_derivatives: "],
		[func(): return q.divide_by_count(0), "nurbs_curve_divide_by_count: "],
		[func(): return q.plane_hits([0, 0, 0], [0, 0, 1]), "nurbs_curve_plane_hits: "],
		[func(): return q.transformed([1, 2, 3]), "Transform: a matrix is 16 numbers"],
	]:
		refuses_as(row[0], row[1])
	eq(q.point(2), PackedFloat64Array())
	eq(q.trimmed(0.5, 0.2), null)

func test_a_curve_maps_by_its_control_points_and_values_turn_into_curves():
	var c := CadaclysmNurbsCurve.create([[0, 0, 0], [1, 1, 1], [2, 0, 0]], 2, PackedFloat64Array([1, 0.5, 1]))
	var p := c.point(0.5)
	for t in [CadaclysmTransform.translation([1, 2, 3]), [1, 0, 0, 1, 0, 1, 0, 2, 0, 0, 1, 3, 0, 0, 0, 1]]:
		var moved := c.transformed(t)
		ok(pdist(moved.point(0.5), [p[0] + 1, p[1] + 2, p[2] + 3]) < 1e-12, str(moved.point(0.5)))
		ok(all_near(moved.weights, c.weights, 1e-15))
	var line := CadaclysmLine.create([0, 0, 0], [2, 0, 0]).to_nurbs()
	eq(line.degree, 1)
	ok(pdist(line.point(0.5 * (line.domain[0] + line.domain[1])), [1, 0, 0]) < 1e-12)
	var ring := CadaclysmCircle.create(XY, 3).to_nurbs()
	ok(ring.is_rational and ring.is_closed)
	var lo: float = ring.domain[0]
	var hi: float = ring.domain[1]
	for i in 16:
		near(pdist(ring.point(lo + (hi - lo) * i / 16.0), [0, 0, 0]), 3, 1e-12)
	var arc := CadaclysmArc.create(XY, 2, [0, PI / 2]).to_nurbs()
	ok(arc.is_rational and not arc.is_closed)
	ok(pdist(arc.point(arc.domain[1]), [0, 2, 0]) < 1e-12, str(arc.point(arc.domain[1])))
	var oval := CadaclysmEllipse.create(XY, 3, 1).to_nurbs()
	ok(oval.is_closed)
	near(oval.length().length, CadaclysmEllipse.create(XY, 3, 1).length(), 1e-6)

func test_curves_outlive_what_they_came_from():
	var cyl := CadaclysmSolid.cylinder(2, 3)
	var index := -1
	for e in cyl.edges:
		if e.kind == "circle":
			index = e.index
	var rim := CadaclysmNurbsCurve.from_edge(cyl, index)
	cyl = null
	near(rim.length().length, 4 * PI, 1e-9)
	var a := CadaclysmNurbsCurve.create([[0, 0, 0], [3, 2, 0], [6, -1, 0], [10, 0, 0]], 3)
	var b := CadaclysmNurbsCurve.create([[0, 1, 5], [4, 4, 5], [7, -3, 6], [10, 1, 5]], 3)
	var tweens := a.tween(b, 2)
	a = null
	b = null
	eq(tweens.size(), 2)
	ok(pdist(tweens[1].point(tweens[1].domain[0]), [0, 2.0 / 3, 10.0 / 3]) < 1e-12, str(tweens[1].point(0)))

# ---- sheets from curves (Python's tests, ported) ----------------------------------------

# A `w` by `h` rectangle centred at `origin` in the plane of `x`, `y`, facing `x × y`.
func rect_sheet(origin: Array, x: Array, y: Array, w: float, h: float) -> CadaclysmSolid:
	var z := [x[1] * y[2] - x[2] * y[1], x[2] * y[0] - x[0] * y[2], x[0] * y[1] - x[1] * y[0]]
	return CadaclysmSolid.face(CadaclysmProfile.rect(w, h), [origin, x, y, z])

func area(solid: CadaclysmSolid) -> float:
	return solid.mass(1e-6)["area"]

func test_surfaces_from_curves_are_sheets():
	var c := [[-1, -1, 1], [1, -1, -1], [1, 1, 1], [-1, 1, -1]]
	var coons := CadaclysmSolid.edge_surface([segment(c[0], c[1]), segment(c[1], c[2]), segment(c[2], c[3]), segment(c[3], c[0])], 1e-9)
	eq(coons.faces, 1)
	eq(coons.sheet_error, 0.0)
	var loft := CadaclysmSolid.loft_curves([segment([0, 0, 0], [2, 0, 0]), segment([0, 1, 1], [2, 1, -1])])
	eq(loft.faces, 1)
	eq(loft.sheet_error, null)
	eq(loft.patch_report, null)
	eq(CadaclysmSolid.cuboid(1, 1, 1).sheet_error, null)
	var ring := []
	for i in 8:
		ring.append([cos(TAU * i / 8), sin(TAU * i / 8), 0])
	var circle := CadaclysmNurbsCurve.through(ring, 3, true)
	var tube := CadaclysmSolid.sweep_rail(segment([0, 0, 0], [0, 0, 4]), [circle], "rmf", PackedFloat64Array(), 1e-5)
	eq(tube.faces, 1)
	ok(tube.sheet_error != null and tube.sheet_error >= 0 and tube.sheet_error <= 1e-5, str(tube.sheet_error))
	var upright := CadaclysmSolid.sweep_rail(segment([0, 0, 0], [0, 0, 4]), [circle], "fixed", PackedFloat64Array([0, 1, 0]), 1e-5)
	eq(upright.faces, 1)
	var band := CadaclysmSolid.sweep_two_rails(segment([-1, 0, 0], [-1, 5, 0]), segment([1, 0, 0], [1, 5, 0]), [segment([-1, 0, 0], [1, 0, 0])], 1e-6)
	eq(band.faces, 1)
	ok(band.sheet_error != null, "sweep_two_rails sets sheet_error")
	var us := []
	for y in [-1, 0.2, 1]:
		us.append(segment([-1, y, -y], [1, y, y]))
	var vs := []
	for x in [-1, 0.3, 1]:
		vs.append(segment([x, -1, -x], [x, 1, x]))
	var net := CadaclysmSolid.network_surface(us, vs, 1e-9)
	eq(net.faces, 1)
	ok(net.sheet_error != null and net.sheet_error <= 1e-9, str(net.sheet_error))
	refuses_as(func(): return CadaclysmSolid.loft_curves([circle]), "loft_curves: ")
	refuses_as(func(): return CadaclysmSolid.edge_surface([segment([0, 0, 0], [1, 0, 0])]), "edge_surface: ")
	refuses_as(func(): return CadaclysmSolid.network_surface([segment([0, 0, 0], [1, 0, 0])], [segment([0, 0, 0], [0, 1, 0])]), "network_surface: ")
	refuses_as(func(): return CadaclysmSolid.sweep_rail(segment([0, 0, 0], [0, 0, 4]), [circle], "twisty"), "sweep_rail: frame is 'rmf' or 'fixed', not 'twisty'")
	refuses_as(func(): return CadaclysmSolid.loft_curves([circle, CadaclysmSolid.cuboid(1, 1, 1)]), "loft_curves: sections")

func test_the_rmf_and_fixed_frames_sweep_differently():
	# A section swept along a rail that twists in space: rotation-minimising turns it with the
	# rail, fixed keeps `up` upright -- two different sheets.
	var rail := CadaclysmNurbsCurve.through([[0, 0, 0], [2, 0, 2], [0, 2, 4], [-2, 0, 6]], 3)
	var section := segment([-0.5, 0, 0], [0.5, 0, 0])
	var rmf := CadaclysmSolid.sweep_rail(rail, [section], "rmf", PackedFloat64Array(), 1e-5)
	var fixed := CadaclysmSolid.sweep_rail(rail, [section], "fixed", PackedFloat64Array([0, 0, 1]), 1e-5)
	ok(rmf != null and fixed != null)
	ok(absf(area(rmf) - area(fixed)) > 1e-6 or not rmf.bounds.is_equal_approx(fixed.bounds), "the two frames sweep the same sheet")

func test_a_curve_trims_a_hole_and_an_island_and_they_join_back():
	var sheet := rect_sheet([0, 0, 0], [1, 0, 0], [0, 1, 0], 20, 20)
	var ring := exact_circle([1, -2, 0], 5)
	var holed := sheet.trim_by_curve(ring, "outside", PackedFloat64Array([0, 0, -1]), 0.01)
	var island := sheet.trim_by_curve(ring, "inside", PackedFloat64Array(), 0.01)
	near(area(island), 25 * PI, 1e-6)
	near(area(holed), 400 - 25 * PI, 1e-6)
	near(area(sheet.trim_by_curve(ring)), 400 - 25 * PI, 1e-6)
	var split := sheet.split_by_curve(ring, PackedFloat64Array(), 0.01)
	eq(split.faces, 2)
	var joined = CadaclysmSolid.join_sheets([holed, island])
	var back: CadaclysmSolid = joined[0]
	var report: CadaclysmJoinReport = joined[1]
	ok(report.sewn >= 1, str(report))
	eq(report.naked_after, report.naked_before - 2 * report.sewn)
	ok(not report.closed)
	eq(back.faces, 2)
	ok(str(report).begins_with("JoinReport(sewn="), str(report))

func test_an_open_curve_keeps_its_left_or_right():
	var sheet := rect_sheet([0, 0, 0], [1, 0, 0], [0, 1, 0], 20, 20)
	var line := CadaclysmNurbsCurve.through([[-5, 1, 0], [5, 1, 0]], 1)
	var up := PackedFloat64Array([0, 0, 1])
	near(area(sheet.trim_by_curve(line, "left", up, 0.01)), 180, 1e-9)
	near(area(sheet.trim_by_curve(line, "right", up, 0.01)), 220, 1e-9)
	near(area(sheet.trim_by_curve(line, "inside", PackedFloat64Array([0, 0, -1]), 0.01)), 220, 1e-9)

func test_six_sheets_join_into_a_box_the_kernel_measures_cuts_and_writes():
	var x := [1, 0, 0]
	var y := [0, 1, 0]
	var z := [0, 0, 1]
	var faces := [rect_sheet([5, 10, 0], x, y, 10, 20), rect_sheet([5, 10, 30], x, y, 10, 20),
		rect_sheet([0, 10, 15], y, z, 20, 30), rect_sheet([10, 10, 15], y, z, 20, 30),
		rect_sheet([5, 0, 15], z, x, 30, 10), rect_sheet([5, 20, 15], x, z, 10, 30)]
	var joined = CadaclysmSolid.join_sheets(faces)
	var box: CadaclysmSolid = joined[0]
	var report: CadaclysmJoinReport = joined[1]
	eq([report.sewn, report.naked_before, report.naked_after, report.turned, report.closed], [12, 24, 0, 4, true])
	near(report.refused, 0, 0)
	var m := box.mass(1e-6)
	ok(m["closed"])
	near(m["volume"], 6000, 1e-6)
	var bored := box.cut(CadaclysmSolid.cylinder(2, 50).translate(5, 10, -10), 0.01)
	near(bored.mass(1e-6)["volume"], 6000 - PI * 4 * 30, 0.05)
	ok(box.step_text().contains("CLOSED_SHELL"))
	# Two of the faces, one moved a thousandth away: sewn only at a tolerance that covers it.
	var moved: CadaclysmSolid = faces[3].translate(0, 0, 1e-3)
	var apart: CadaclysmJoinReport = CadaclysmSolid.join_sheets([faces[1], moved])[1]
	var loose: CadaclysmJoinReport = CadaclysmSolid.join_sheets([faces[1], moved], 2e-3)[1]
	eq(apart.sewn, 0)
	eq(loose.sewn, 1)
	near(loose.worst_gap, 1e-3, 1e-9)

func test_mirror_join_squares_a_half_roof_to_its_mirror():
	# Half a roof domed both ways, lofted out from the centre plane y = 0, leaning as it leaves
	# the plane: mirrored as it is, the seam is a crease; squared first, it is smooth.
	var sections := []
	for y in [0.0, 10.0, 20.0, 30.0]:
		var row := []
		for i in range(9):
			var x := 10.0 * i
			row.append([x, y, 20 * sin(PI * x / 80) - 0.01 * y * y + 0.05 * y + 0.002 * x * y])
		sections.append(CadaclysmNurbsCurve.through(row))
	var half := CadaclysmSolid.loft_curves(sections)
	var plane := [0, 0, 0, 1, 0, 0, 0, 0, -1, 0, 1, 0]
	var creased = half.mirror_join(plane, 0, 0.01)
	var r: CadaclysmSymmetryReport = creased[1]
	eq([creased[0].faces, r.seams, r.squared], [2, 1, 0])
	near(r.moved, 0, 0)
	ok(r.gap < 1e-9 and r.angle > deg_to_rad(5) and r.curvature > 1e-4, str(r))
	var smooth = half.mirror_join(plane, 0.5, 0.01)
	var s: CadaclysmSymmetryReport = smooth[1]
	eq([smooth[0].faces, s.seams, s.squared, s.naked], [2, 1, 1, 6])
	ok(s.moved > 0 and s.gap < 1e-9 and s.angle < 1e-9 and s.curvature < 1e-9, str(s))
	# Only the first two rows moved: the body is near twice the half.
	var one: float = half.mass()["area"]
	near(smooth[0].mass()["area"], 2 * one, 0.01 * one)
	eq(smooth[0].mirror_join(plane), null)
	ok(Cadaclysm.last_error().begins_with("mirror_join: the half lies on both sides of the plane"), Cadaclysm.last_error())

func test_a_hole_drills_through_a_block():
	var blk := CadaclysmSolid.cuboid(40, 30, 20).translate(20, 15, 10)
	var drilled = blk.hole([10, 15, 20], 4)
	var r: CadaclysmHoleReport = drilled[1]
	var want := 24000 - 80 * PI
	near(drilled[0].mass()["volume"], want, 1e-6 * want)
	eq([drilled[0].faces, r.holes, r.faces_added, r.bottoms.size()], [7, 1, 1, 1], str(r))
	near(r.bottoms[0], 20, 1e-9)
	var tool := blk.hole_tool([10, 15, 20], 4)
	ok(tool.mass()["volume"] > 80 * PI, str(tool.mass()["volume"]))
	eq(blk.hole([10, 15, 20], 0), null)
	ok(Cadaclysm.last_error().begins_with("hole: diameter 0 is not positive and finite"), Cadaclysm.last_error())

func test_a_pattern_of_holes_cuts_a_plate_in_one_boolean():
	var plate := CadaclysmSolid.cuboid(100, 60, 10).translate(50, 30, 5)
	var tool := CadaclysmSolid.cylinder(3, 30).translate(10, 10, -10)
	var grid := CadaclysmPattern.rectangular([1, 0, 0], 4, 20, PackedFloat64Array([0, 1, 0]), 3, 20)
	eq(grid.size(), 12)
	var cut = plate.pattern_feature(tool, "cut", grid)
	var r: CadaclysmPatternReport = cut[1]
	var want := 60000 - 1080 * PI
	near(cut[0].mass()["volume"], want, 1e-6 * want)
	eq([r.instances, r.booleans, r.missed], [12, 1, 0], str(r))
	var row := CadaclysmPattern.rectangular([1, 0, 0], 3, 10)
	eq(row.size(), 3)
	eq(row[0].rows, PackedFloat64Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]))
	eq(row[1].rows, PackedFloat64Array([1, 0, 0, 10, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]))
	var blk := CadaclysmSolid.cuboid(40, 30, 20).translate(20, 15, 10)
	var bodies = blk.pattern(CadaclysmPattern.rectangular([1, 0, 0], 2, 8).slice(0, 2))
	var b: CadaclysmPatternReport = bodies[1]
	eq([b.instances, b.booleans], [2, 1], str(b))
	near(bodies[0].mass()["volume"], 28800, 1e-6 * 28800)
	var ring := CadaclysmPattern.circular([0, 0, 0], [0, 0, 1], 6)
	eq(ring.size(), 6)
	near(ring[1].rows[0], 0.5, 1e-12)
	var along := CadaclysmPattern.along(segment([0, 0, 0], [30, 0, 0]), 4)
	eq(along.size(), 4)
	near(along[3].rows[3], 30, 1e-9)
	eq(CadaclysmPattern.rectangular([1, 0, 0], 0, 10).size(), 0)
	ok(Cadaclysm.last_error().begins_with("pattern_rectangular: count1 is 0"), Cadaclysm.last_error())

func test_a_rib_braces_an_l_and_a_web_divides_a_tray():
	var l := CadaclysmSolid.cuboid(40, 30, 5).translate(20, 15, 2.5).join(CadaclysmSolid.cuboid(5, 30, 40).translate(2.5, 15, 20))
	near(l.mass()["volume"], 11250, 1e-6 * 11250)
	var diag := CadaclysmNurbsCurve.through([[30, 15, 5], [5, 15, 30]], 1)
	var plane := [0, 15, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0]
	near(l.rib(diag, plane, 4).mass()["volume"], 12500, 1e-6 * 12500)
	near(l.rib_tool(diag, plane, 4, "front").mass()["volume"], 1250, 1e-6 * 1250)
	var tray := CadaclysmSolid.cuboid(60, 40, 20).translate(30, 20, 10).cut(CadaclysmSolid.cuboid(56, 36, 18).translate(30, 20, 11))
	var down := [0, 0, 10, 1, 0, 0, 0, -1, 0, 0, 0, -1]
	var line := segment([10, 20, 10], [50, 20, 10])
	var walls: float = tray.web([line], down, 3).mass()["volume"] - tray.mass()["volume"]
	near(walls, 1344, 1e-6 * 1344)
	ok(tray.web_tool(line, down, 3, "both", 6).mass()["volume"] > 0)
	eq(l.rib(diag, plane, 4, "sideways"), null)
	ok(Cadaclysm.last_error().begins_with("rib: side must be 'both', 'front' or 'back', not 'sideways'"), Cadaclysm.last_error())

func flat_rect(x0: float, y0: float, x1: float, y1: float) -> CadaclysmSolid:
	var c := [[x0, y0, 0], [x1, y0, 0], [x1, y1, 0], [x0, y1, 0]]
	return CadaclysmSolid.edge_surface([segment(c[0], c[1]), segment(c[1], c[2]), segment(c[2], c[3]), segment(c[3], c[0])])

func test_join_sheets_sews_a_t_junction():
	# Two unit squares on a 2 x 1 rectangle's long edge: it is cut where they meet on it.
	var big := flat_rect(0, 0, 2, 1)
	var a := flat_rect(0, 1, 1, 2)
	var b := flat_rect(1, 1, 2, 2)
	var exact: CadaclysmJoinReport = CadaclysmSolid.join_sheets([big, a, b])[1]
	eq(exact.sewn, 1)
	var joined = CadaclysmSolid.join_sheets([big, a, b], 1e-3)
	var report: CadaclysmJoinReport = joined[1]
	eq([report.sewn, report.naked_before, report.naked_after, report.closed], [3, 13, 7, false])
	eq(joined[0].faces, 3)

func test_trim_by_curve_and_join_refuse_by_name():
	var sheet := rect_sheet([0, 0, 0], [1, 0, 0], [0, 1, 0], 20, 20)
	var ring := exact_circle([0, 0, 0], 5)
	refuses_as(func(): return sheet.trim_by_curve(ring, "middle"), "trim_by_curve: keep must be 'outside', 'inside', 'left' or 'right', not 'middle'")
	var message := refuses_as(func(): return sheet.trim_by_curve(exact_circle([100, 0, 0], 5), "inside"), "trim_by_curve: ")
	ok(message.contains("nothing of the sheet lies inside"), message)
	message = refuses_as(func(): return sheet.split_by_curve(ring, PackedFloat64Array([0, 0, 0])), "split_by_curve: ")
	ok(message.contains("direction is zero"), message)
	refuses_as(func(): return sheet.split_by_curve(ring, PackedFloat64Array([0, 1])), "split_by_curve: direction")
	refuses_as(func(): return CadaclysmSolid.join_sheets([]), "join_sheets: no sheets")
	message = refuses_as(func(): return CadaclysmSolid.join_sheets([sheet], -1), "join_sheets: ")
	ok(message.contains("tolerance"), message)
	eq(CadaclysmSolid.join_sheets([]), null)
	refuses_as(func(): return CadaclysmSolid.join_sheets([sheet, ring]), "join_sheets: sheets")

# Every segment of `e` starts on the circle of radius 5 about (1, -2) within `tol` (and in
# z = 0 within `ztol`), read as doubles.
func on_hole(e: CadaclysmEdge, tol: float, ztol := INF) -> bool:
	var raw: PackedFloat64Array = e.raw_segments
	for i in range(0, raw.size(), 6):
		if absf(hypot([raw[i] - 1, raw[i + 1] + 2]) - 5) >= tol or absf(raw[i + 2]) >= ztol:
			return false
	return true

# The 20 x 20 square in z = 0 facing +z with a round hole of radius 5 about (1, -2), and the
# hole's rim edges: `[holed, rim]`.
func holed_sheet() -> Array:
	var sheet := rect_sheet([0, 0, 0], [1, 0, 0], [0, 1, 0], 20, 20)
	var holed := sheet.trim_by_curve(exact_circle([1, -2, 0], 5), "outside", PackedFloat64Array([0, 0, -1]), 0.01)
	var rim := holed.edges.filter(func(e): return e.faces.size() == 1 and on_hole(e, 1e-6))
	ok(rim.size() > 0, "the hole has a rim")
	return [holed, rim]

func test_a_flange_turns_a_hole_under_and_carries_it_inward():
	var made := holed_sheet()
	var holed: CadaclysmSolid = made[0]
	var rim: Array = made[1]
	var under := segment([0, 0, 0], [0, -3, 0])
	# Turned under 3 along the face's normal (+z): the hole's own cylinder, 3 deep, below the sheet.
	var wall := holed.flange(rim, under, 1e-3, false)
	eq(wall.faces, rim.size())
	ok(wall.sheet_error != null and wall.sheet_error <= 1e-3, str(wall.sheet_error))
	near(area(wall), 2 * PI * 5 * 3, 0.05)
	var box := wall.bounds
	near(box.position.z, -3, 1e-3)
	near(box.end.z, 0, 1e-3)
	near(box.position.x, 1 - 5, 1e-2)
	near(box.end.x, 1 + 5, 1e-2)
	# Carried on outward from the face 2: into the hole, an annulus from radius 5 in to 3.
	var indices := PackedInt32Array(rim.map(func(e): return e.index))
	var ring := holed.flange(indices, segment([0, 0, 0], [2, 0, 0]), 1e-3, false)
	near(area(ring), PI * (25 - 9), 0.05)
	# Joined, the sheet's faces come first and the flange is sewn on.
	var joined := holed.flange(rim, under)
	eq(joined.faces, holed.faces + rim.size())
	near(area(joined), area(holed) + 2 * PI * 5 * 3, 0.05)
	# The rim is sewn all the way round: every edge on the hole's circle borders the sheet and the flange.
	var on_rim := joined.edges.filter(func(e): return on_hole(e, 1e-3, 1e-6))
	ok(on_rim.size() > 0, "edges on the rim")
	for e in on_rim:
		var faces: Array = Array(e.faces)
		faces.sort()
		eq(faces, [0, 1], str(e))

func test_a_liner_runs_a_hole_down_to_a_tilted_floor():
	var made := holed_sheet()
	var holed: CadaclysmSolid = made[0]
	var rim: Array = made[1]
	# The floor z = -7 + 0.1 x, wide enough to catch every point: the wall is 7 - 0.1 x deep,
	# 6.9 on average round a hole centred at x = 1.
	var floor_sheet := CadaclysmSolid.edge_surface([segment([-20, -20, -9], [20, -20, -5]), segment([20, -20, -5], [20, 20, -5]),
		segment([20, 20, -5], [-20, 20, -9]), segment([-20, 20, -9], [-20, -20, -9])])
	var wall := holed.extrude_to(rim, [0, 0, -1], floor_sheet, 1e-3, false)
	eq(wall.faces, rim.size())
	ok(wall.sheet_error != null and wall.sheet_error <= 1e-3, str(wall.sheet_error))
	near(area(wall), 2 * PI * 5 * 6.9, 0.05)
	var box := wall.bounds
	near(box.position.z, -7 + 0.1 * (1 - 5), 1e-2)
	near(box.end.z, 0, 1e-5)
	var joined := holed.extrude_to(rim, Vector3(0, 0, -1), floor_sheet)
	eq(joined.faces, holed.faces + rim.size())
	ok(joined.step_text().contains("SURFACE_OF_LINEAR_EXTRUSION"))

func test_flange_and_extrude_to_refuse_by_name():
	var made := holed_sheet()
	var holed: CadaclysmSolid = made[0]
	var rim: Array = made[1]
	var under := segment([0, 0, 0], [0, -3, 0])
	refuses_as(func(): return holed.flange(rim, segment([1, 0, 0], [1, -3, 0])), "flange: the section starts at")
	refuses_as(func(): return holed.flange([], under), "flange: no edges given")
	refuses_as(func(): return holed.flange([999], under), "flange: no edge 999")
	refuses_as(func(): return holed.flange(rim[0], under), "flange: edges: expected an array")
	refuses_as(func(): return holed.flange([-1], under), "flange: edges: -1 is not an index")
	refuses_as(func(): return CadaclysmSolid.cuboid(10, 10, 10).flange([0], under), "flange: edge 0 borders 2 faces")
	var floor_sheet := rect_sheet([0, 0, -7], [1, 0, 0], [0, 1, 0], 40, 40)
	var message := refuses_as(func(): return holed.extrude_to(rim, [0, 0, 1], floor_sheet), "extrude_to: edge ")
	ok(message.contains("misses the target"), message)
	refuses_as(func(): return holed.extrude_to(rim, [0, 0, 0], floor_sheet), "extrude_to: the direction has no length")
	refuses_as(func(): return holed.extrude_to(rim, null, floor_sheet), "extrude_to: direction")
	refuses_as(func(): return holed.extrude_to(rim, [0, 1], floor_sheet), "extrude_to: direction")

func test_continuity_match_and_blend():
	var a := CadaclysmSolid.loft_curves([segment([-1, 0, 0], [0, 0, 0]), segment([-1, 1, 0], [0, 1, 0])], 1)
	var b := CadaclysmSolid.loft_curves([segment([0, 0, 0], [0, 0, 1]), segment([0, 1, 0], [0, 1, 1])], 1)
	var r := a.continuity("u1", b, "u0", 0, 0, 32)
	ok(r.gap <= 1e-12 and absf(r.angle - PI / 2) <= 1e-9 and r.samples >= 33, str(r))
	var m := a.matched("u1", b, "u0", 1)
	r = m.continuity("u1", b, "u0")
	ok(r.gap <= 1e-10 and r.angle <= 1e-8, str(r))
	var blend := CadaclysmSolid.blend_sides(a, "u0", b, "u1", 2)
	r = blend.continuity("v0", a, "u0")
	ok(r.gap <= 1e-10 and r.angle <= 1e-8 and r.curvature <= 1e-6, str(r))
	refuses_as(func(): return a.continuity("w2", b, "u0"), "a side is 'u0', 'u1', 'v0' or 'v1', not 'w2'")
	refuses_as(func(): return a.matched("u1", b, "u0", 3), "match_side: ")
	refuses_as(func(): return CadaclysmSolid.blend_sides(a, "u0", b, "x", 2), "a side is 'u0', 'u1', 'v0' or 'v1', not 'x'")

func test_continuity_positions_belong_to_their_figures():
	# The gap opens to a fifth by the far end; the right angle is first found at the near one, so
	# a binding reading `gap_at` and `angle_at` swapped fails here.
	var a := CadaclysmSolid.loft_curves([segment([-1, 0, 0], [0, 0, 0]), segment([-1, 1, 0], [0, 1, 0])], 1)
	var b := CadaclysmSolid.loft_curves([segment([0, 0, 0], [0, 0, 1]), segment([0, 1, 0.2], [0, 1, 1.2])], 1)
	var r := a.continuity("u1", b, "u0", 0, 0, 32)
	ok(r.gap > 0.19 and r.gap <= 0.2 + 1e-9 and r.gap_at[1] > 0.99 and r.angle_at[1] < 0.01, str(r))
	ok(absf(r.angle - PI / 2) < 1e-9 and r.curvature < 1e-9 and r.samples == 33, str(r))
	eq(r.curvature_at.size(), 3)

# A roof line traced off a drawing: rising to a header at point 4, then a long gentle arch.
const ROOF := [[1717, 1110], [1848, 1191], [1979, 1262], [2110, 1330], [2242, 1356], [2504, 1367], [2767, 1369], [3029, 1364],
	[3160, 1354], [3423, 1304], [3554, 1251], [3686, 1207], [3817, 1165], [3948, 1123], [4079, 1078]]

# The parameter of `curve` nearest `p`, among 400 even arc-length steps.
func roof_parameter_near(curve: CadaclysmNurbsCurve, p: Array) -> float:
	var best := INF
	var t := 0.0
	for a in curve.divide_by_count(400):
		var d := pdist(a.raw_point(), p)
		if d < best:
			best = d
			t = a.parameter
	return t

func test_a_traced_roof_faired_has_no_inflection_past_the_header():
	var pts := []
	for xz in ROOF:
		pts.append([float(xz[0]), 0.0, float(xz[1])])
	var through := CadaclysmNurbsCurve.through(pts)
	var t_header := roof_parameter_near(through, pts[4])
	var wobbles := []
	for a in through.inflections():
		if a.parameter > t_header:
			wobbles.append(a)
	ok(wobbles.size() >= 3, str(wobbles))
	for a in wobbles:
		ok(pdist(through.point(a.parameter), a.raw_point()) < 1e-9 and a.error == 0.0, str(a))
	var tolerance := 5.25   # two pixels of the drawing
	var roof := CadaclysmNurbsCurve.fair(pts, 5, tolerance, PackedFloat64Array([4, NAN]))
	ok(roof.degree == 5 and roof.fit_error != null and roof.fit_error >= 0 and roof.fit_error <= tolerance, str(roof.fit_error))
	t_header = roof_parameter_near(roof, pts[4])
	var past := []
	for a in roof.inflections():
		if a.parameter > t_header + 1e-6:
			past.append(a)
	eq(past.size(), 0, str(past))
	var k := roof.knot_continuity()
	ok(k != null and k.angle < 1e-6 and k.curvature < 1e-9, str(k))
	eq(k.angle_at.size(), 3)
	eq(k.curvature_at.size(), 3)
	# Too tight to hold: refused in the library's words, not a curve that turns over.
	var message := refuses_as(func(): return CadaclysmNurbsCurve.fair(pts, 5, 0.05, PackedFloat64Array([NAN, NAN])), "nurbs_curve_fair: ")
	ok(message.contains("no curve free of inflections"), message)
	message = refuses_as(func(): return CadaclysmNurbsCurve.fair(pts, 2, tolerance), "nurbs_curve_fair: ")
	ok(message.contains("degree 2"), message)
	refuses_as(func(): return CadaclysmNurbsCurve.fair(pts, 5, tolerance, PackedFloat64Array([4])), "nurbs_curve_fair: no_inflection takes two numbers")
	# Faired from the wobbly curve itself, its own parameters naming the span.
	var faired := through.faired(5, 1.5 * tolerance, through.domain)
	eq(faired.inflections().size(), 0, str(faired.inflections()))
	ok(faired.fit_error != null and faired.fit_error <= 1.6 * tolerance, str(faired.fit_error))

func test_edge_continuity_reads_a_crease_and_a_fillet_seam():
	var block := CadaclysmSolid.cuboid(40, 30, 20)
	var r := block.edge_continuity(0, 16)
	ok(absf(r.angle - PI / 2) < 1e-9 and r.gap < 1e-9 and r.curvature < 1e-9 and r.samples == 17, str(r))
	var rounded := block.fillet([0], 4.0)
	var seams := []
	for e in rounded.edges:
		var c := rounded.edge_continuity(e)
		if c != null and c.angle < 1e-6:   # null: an edge of one face
			seams.append(c)
	# The fillet's two tangent seams, its curvature a quarter where the flat faces' is zero.
	ok(seams.size() == 2, str(seams))
	for c in seams:
		near(c.curvature, 0.25, 1e-4)
	refuses_as(func(): return block.edge_continuity(999), "edge_continuity: ")
	refuses_as(func(): return block.edge_continuity(-1), "edge_continuity: edge: -1 is not an index")

func test_a_wobbly_loft_faired_turns_no_curvature_over():
	# Eleven lines across a shallow arch, each lifted or dropped by 0.4 in turn: a loft through
	# them ripples between every pair.
	var lines := []
	for k in 11:
		var x := 10.0 * k
		var z := -0.01 * (x - 50.0) * (x - 50.0) + (0.4 if k % 2 == 0 else -0.4)
		lines.append(segment([x, 0.0, z], [x, 40.0, z]))
	var loft := CadaclysmSolid.loft_curves(lines, 3)
	var t := loft.curvature_turns(0, 32)
	ok(t != null and t.samples == 32, str(t))
	ok(t.mean_turns.size() > 0 and t.mean_positive + t.mean_negative > 1, str(t))
	for a in t.mean_turns:
		var p: PackedFloat64Array = a.raw_point()
		ok(absf(a.tangent.length() - 1.0) < 1e-6 and p[0] >= 0.0 and p[0] <= 100.0 and p[2] > -26.0 and p[2] < 1.0, str(a))
	# The lines run along u, the loft's v across them: the end lines kept, held along v.
	var keep := PackedInt64Array([-1, -1, 0, 0])
	var faired := loft.faired(1.0, 3, PackedInt64Array(), keep, "v")
	ok(faired != null and faired.sheet_error != null and faired.sheet_error >= 0.0 and faired.sheet_error <= 1.05, str(faired.sheet_error))
	var f := faired.curvature_turns()
	ok(f.mean_turns.size() == 0 and f.mean_positive + f.mean_negative == 1, str(f))
	var coarse := loft.faired(1.0, 3, PackedInt64Array([6, 8]), keep, "v")
	ok(coarse.sheet_error <= 1.05 and coarse.curvature_turns().mean_turns.size() == 0, str(coarse.sheet_error))
	var message := refuses_as(func(): return loft.faired(1.0, 2), "surface_faired: ")
	ok(message.contains("degree 2"), message)
	message = refuses_as(func(): return loft.faired(0.01, 3, PackedInt64Array(), keep, "v"), "surface_faired: ")
	ok(message.contains("no fair free of inflections"), message)
	refuses_as(func(): return loft.faired(1e-3, 3, PackedInt64Array(), PackedInt64Array([0, 0])), "surface_faired: keep takes 4 levels")
	refuses_as(func(): return loft.faired(1e-3, 3, PackedInt64Array(), PackedInt64Array(), "w"), "no_inflection is 'u', 'v', 'uv'")
	refuses_as(func(): return loft.curvature_turns(7), "curvature_turns: ")

func test_highlight_kink_runs_straight_across_planes_and_kinks_at_a_fillet_seam():
	var block := CadaclysmSolid.cuboid(2, 2, 2)
	var k := block.highlight_kink(0, 16)
	ok(k != null and k.angle < 1e-9 and k.samples == 17, str(k))
	eq(k.at.size(), 3)
	var rounded := block.fillet([0], 0.5)
	var worst: CadaclysmHighlightKink = null
	for e in rounded.edges:
		var h := rounded.highlight_kink(e)
		if h != null and (worst == null or h.angle > worst.angle):   # null: an edge of one face
			worst = h
	# Where the fillet's curvature meets a flat face's, the highlight lines break.
	ok(worst != null and worst.angle > deg_to_rad(45), str(worst))
	var d := worst.light_direction
	near(sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]), 1.0, 1e-9)
	refuses_as(func(): return block.highlight_kink(999), "highlight_kink: ")
	refuses_as(func(): return block.highlight_kink(-1), "highlight_kink: edge: -1 is not an index")

func pentagon_strips() -> Array:
	var corners := []
	for k in 5:
		var a := TAU * k / 5 + 0.1 * sin(3 * k)
		corners.append([cos(a), sin(a), 0.0])
	var strips := []
	for i in 5:
		var p: Array = corners[i]
		var q: Array = corners[(i + 1) % 5]
		strips.append(CadaclysmSolid.loft_curves([segment(p, q), segment([1.6 * p[0], 1.6 * p[1], 0], [1.6 * q[0], 1.6 * q[1], 0])], 1))
	return [corners, strips]

func test_n_sided_patch_fills_a_pentagon_of_strips():
	# Five flat strips round a pentagon in z = 0, each lofted from a side outward: the hole's
	# side is each loft's "v0". Given every way the wrapper takes a boundary.
	var made := pentagon_strips()
	var corners: Array = made[0]
	var strips: Array = made[1]
	var edge := segment(corners[3], corners[4])
	var boundaries := [[strips[0], "v0"], [strips[1], "v0", 1], {"sheet": strips[2], "side": "v0", "range": [1.0, 0.0]},
		edge, {"sheet": strips[4], "side": "v0", "level": 2, "face": 0}]
	var fill := CadaclysmSolid.n_sided_patch(boundaries, 1.0, 1e-6)
	var r: CadaclysmPatchReport = fill.patch_report
	eq(fill.faces, 5)
	eq(r.faces, 5)
	ok(r.boundary.gap <= 1e-9 and r.boundary.angle <= 1e-6 and r.internal.angle <= 1e-6 and r.corner_angle <= 1e-9, str(r))
	ok(r.boundary.samples > 0 and r.internal.samples > 0 and r.boundary.gap_at.size() == 3, str(r))
	eq(fill.sheet_error, null)
	# Face 0 meets strip 0's second half along its v0 side, face 4 the first half along u1.
	for row in [[0, "v0"], [4, "u1"]]:
		var k := fill.continuity(row[1], strips[0], "v0", row[0])
		ok(k.gap <= 1e-9 and k.angle <= 1e-6, "%s %s" % [row, k])
	# Into the ring: watertight round the hole but where the curve stood in for strip 3.
	var report: CadaclysmJoinReport = CadaclysmSolid.join_sheets([strips[0], strips[1], strips[2], strips[4], fill], 1e-6)[1]
	# Naked: the four strips' outer sides, the two radial sides beside the gap, the curve's two halves.
	ok(report.refused == 0 and report.naked_after == 4 + 2 + 2, str(report))
	# Every boundary a sheet's side: the curve's place taken by strip 3, the same five faces.
	var sides := []
	for s in strips:
		sides.append([s, "v0"])
	var whole := CadaclysmSolid.n_sided_patch(sides, 1.0, 1e-6)
	ok(whole.faces == 5 and whole.patch_report.boundary.angle <= 1e-6, str(whole.patch_report))
	refuses_as(func(): return CadaclysmSolid.n_sided_patch(boundaries.slice(0, 2)), "n_sided_patch: ")
	refuses_as(func(): return CadaclysmSolid.n_sided_patch([{"sheet": strips[0], "side": "v0", "bulge": 2}, sides[1], sides[2]]), "n_sided_patch: boundary 0: unknown keys ['bulge']")
	refuses_as(func(): return CadaclysmSolid.n_sided_patch([[strips[0]], sides[1], sides[2]]), "n_sided_patch: boundary 0 is [sheet, side] or [sheet, side, level]")
	refuses_as(func(): return CadaclysmSolid.n_sided_patch([7, sides[1], sides[2]]), "n_sided_patch: boundary 0 is a CadaclysmNurbsCurve")
	refuses_as(func(): return CadaclysmSolid.n_sided_patch([[strips[0], "w1"], sides[1], sides[2]]), "a side is 'u0', 'u1', 'v0' or 'v1', not 'w1'")
	# A level of 3 on one side of an otherwise good ring is the level's refusal, not the ring's
	# (a binding that sends every side at G2 passes everything above).
	var bad := []
	for i in 5:
		bad.append([strips[i], "v0", 3 if i == 1 else 2])
	refuses_as(func(): return CadaclysmSolid.n_sided_patch(bad, 1.0, 1e-6), "n_sided_patch: ")

func test_fillet_surfaces_rolls_a_ball_between_two_sheets():
	var floor_ := CadaclysmSolid.loft_curves([segment([0, 0, 0], [4, 0, 0]), segment([0, 3, 0], [4, 3, 0])], 1)
	var wall := CadaclysmSolid.loft_curves([segment([0, 0, 0], [0, 3, 0]), segment([0, 0, 4], [0, 3, 4])], 1)
	var found = null
	for flips in [[false, false], [true, false], [false, true], [true, true]]:
		var got = CadaclysmSolid.fillet_surfaces(floor_, wall, 1.0, NAN, flips[0], flips[1], 1e-4)
		if got == null:
			continue
		var p: PackedFloat64Array = got[1].point(got[1].domain[0])
		if p[0] > 0 and absf(p[2]) <= 1e-9:
			found = got
			break
	ok(found != null, "a flip pair puts the ball between the two sheets")
	if found == null:
		return
	var sheet: CadaclysmSolid = found[0]
	var ra: CadaclysmNurbsCurve = found[1]
	var rb: CadaclysmNurbsCurve = found[2]
	# The rails are the caller's: they outlive the two sheets and the fillet.
	floor_ = null
	wall = null
	found = null
	eq(sheet.faces, 1)
	ok(sheet.sheet_error != null and sheet.sheet_error >= 0 and sheet.sheet_error <= 1e-4, str(sheet.sheet_error))
	near(ra.point(ra.domain[0])[0], 1.0, 1e-4)
	near(rb.point(rb.domain[0])[2], 1.0, 1e-4)
	var a := CadaclysmSolid.loft_curves([segment([0, 0, 0], [4, 0, 0]), segment([0, 3, 0], [4, 3, 0])], 1)
	var b := CadaclysmSolid.loft_curves([segment([0, 0, 0], [0, 3, 0]), segment([0, 0, 4], [0, 3, 4])], 1)
	refuses_as(func(): return CadaclysmSolid.fillet_surfaces(a, b, 0.0), "fillet_surfaces: ")
	eq(CadaclysmSolid.fillet_surfaces(a, b, 0.0), null)

# Two bicubic patches -- a fender's top and a door's side -- sharing the crease row, joined.
func fender_and_door() -> CadaclysmSolid:
	var length := 400.0
	var a_rows := []
	var b_rows := []
	for y in [0.0, length / 3, 2 * length / 3, length]:
		var s := sin(PI * y / length)
		var c := [150.0 + 8.0 * s, y, 6.0 * s]
		a_rows.append(CadaclysmNurbsCurve.create([[0.0, y, 10.0], [50.0, y, 14.0], [100.0, y, 12.0], c], 3))
		b_rows.append(CadaclysmNurbsCurve.create([c, [c[0] + 14, y, c[2] - 60], [c[0] + 10, y, c[2] - 130], [c[0] - 4, y, c[2] - 200]], 3))
	var a := CadaclysmSolid.loft_curves(a_rows, 3, true)
	var b := CadaclysmSolid.loft_curves(b_rows, 3, true)
	var joined = CadaclysmSolid.join_sheets([a, b], 1e-6)
	eq(joined[1].sewn, 1)
	return joined[0]

func test_fillet_rounds_a_spline_edge_at_a_constant_and_a_varying_radius():
	var shell := fender_and_door()
	var crease := []
	for e in shell.edges:
		if e.faces.size() == 2:
			crease.append(e)
	eq(crease.size(), 1)
	eq(crease[0].kind, "nurbs")
	var constant := shell.fillet(crease, 12.0, 1e-3)
	var varying := shell.fillet(crease, 8.0, 1e-3, 20.0)
	var same := shell.fillet(crease, 12.0, 1e-3, 12.0)
	eq(constant.faces, 3)
	eq(varying.faces, 3)
	# The fillet cuts the corner off: less area than the sharp shell, and more taken by the
	# larger ball on average (8 to 20 against 12 all along).
	ok(area(varying) < area(constant) and area(constant) < area(shell), "%s %s %s" % [area(varying), area(constant), area(shell)])
	near(area(same), area(constant), 1e-9)
	var message := refuses_as(func(): return CadaclysmSolid.cuboid(10, 10, 10).fillet([0], 1.0, 1e-6, 2.0), "fillet: ")
	ok(message.contains("a varying radius rounds only spline edges"), message)

func test_fillet_law_with_stations_at_the_ends_is_the_varying_fillet():
	var shell := fender_and_door()
	var crease := []
	for e in shell.edges:
		if e.faces.size() == 2:
			crease.append(e)
	var varying := shell.fillet(crease, 8.0, 1e-3, 20.0)
	var lawed := shell.fillet_law(crease, [[0.0, 8.0], [1.0, 20.0]], 1e-3)
	eq(lawed.faces, 3)
	near(area(lawed), area(varying), 1e-3)
	# A swell in the middle takes more than 8 all along and less than 20 all along.
	var swell := area(shell.fillet_law([crease[0].index], [[0.0, 8.0], [0.5, 20.0], [1.0, 8.0]], 1e-3))
	ok(swell < area(shell.fillet(crease, 8.0, 1e-3)) and swell > area(shell.fillet(crease, 20.0, 1e-3)), "the swell takes %s" % swell)
	var none := refuses_as(func(): return shell.fillet_law(crease, [], 1e-3), "fillet: ")
	ok(none.contains("at least one station"), none)
	var message := refuses_as(func(): return CadaclysmSolid.cuboid(10, 10, 10).fillet_law([0], [[0.0, 1.0], [1.0, 2.0]]), "fillet: ")
	ok(message.contains("a radius law rounds only spline edges"), message)

# ---- closest point from a point: the cube's face, edge and vertex feet and the sphere's pinned to
# their closed forms (literals, not read back through the wrapper; the doubles through raw_point
# and raw_normal), max_distance on both sides, the projector equal to the one-shot (uv included)
# after its solid is closed, and the refusals (null, the reason in last_error).

const CP_SQRT_HALF := 0.7071067811865476
const CP_INV_SQRT3 := 0.5773502691896258
# query, point, distance, kind, uv (empty off a face), normal
const CP_CUBE_FEET := [
	[[20, 0, 0], [5, 0, 0], 15.0, "face", [5, 5], [1, 0, 0]],
	[[8, 8, 0], [5, 5, 0], 4.242640687119285, "edge", [], [CP_SQRT_HALF, CP_SQRT_HALF, 0]],
	[[8, 8, 8], [5, 5, 5], 5.196152422706632, "vertex", [], [CP_INV_SQRT3, CP_INV_SQRT3, CP_INV_SQRT3]],
	[[1, 0, 0], [5, 0, 0], 4.0, "face", [5, 5], [1, 0, 0]],
	[[0, -7, 2], [0, -5, 2], 2.0, "face", [5, 7], [0, -1, 0]],
	[[5, 1, 2], [5, 1, 2], 0.0, "face", [6, 7], [1, 0, 0]],
]

func cp_foot_is(foot, row: Array) -> void:
	if not ok(foot != null, "no foot for %s: %s" % [str(row[0]), Cadaclysm.last_error()]):
		return
	var what := str(foot)
	ok(foot is CadaclysmPointFoot, what)
	ok(all_near(foot.raw_point, row[1]) and absf(foot.distance - row[2]) <= 1e-9, what)
	ok(v3near(foot.point, Vector3(row[1][0], row[1][1], row[1][2]), 1e-5), what)
	ok(foot.kind == row[3] and foot.refined and all_near(foot.raw_normal, row[5]), what)
	ok(all_near(foot.uv, row[4]), what)
	if row[3] == "edge":
		ok(foot.edge >= 0 and foot.edge < 12, what)
	else:
		eq(foot.edge, -1, what)

func test_closest_point_names_a_cubes_face_edge_and_vertex_in_closed_form():
	var cube := CadaclysmSolid.cuboid(10, 10, 10)
	for row in CP_CUBE_FEET:
		cp_foot_is(cube.closest_point(row[0]), row)
	var p: Array = CP_CUBE_FEET[0][0]
	ok(cube.closest_point(Vector3(20, 0, 0), INF, 0.0).equals(cube.closest_point(p)), "INF and 0 are no limit and unset")
	var sphere := CadaclysmSolid.sphere(2)
	var foot := sphere.closest_point([0, 3, 4])
	near(foot.distance, 3.0, 1e-9)
	ok(all_near(foot.raw_point, [0, 1.2, 1.6]) and all_near(foot.raw_normal, [0, 0.6, 0.8]), str(foot))
	eq(foot.kind, "face")
	var inside := sphere.closest_point([0, 0, 0.5])
	near(inside.distance, 1.5, 1e-9)
	ok(all_near(inside.raw_point, [0, 0, 2]), str(inside))

func test_closest_point_edge_is_the_public_edge_number():
	var cube := CadaclysmSolid.cuboid(10, 10, 10)
	var p := [8, 8, 1]
	var edge: int = cube.closest_point(p).edge
	var foot = cube.edge_closest_point(edge, p)
	ok(foot is Dictionary, Cadaclysm.last_error())
	ok(all_near(foot["raw_point"], [5, 5, 1]), str(foot))
	ok(v3near(foot["point"], Vector3(5, 5, 1), 1e-5), str(foot))
	near(foot["distance"], 4.242640687119285, 1e-9)
	# A straight edge: the arc length to the foot is the chord from the edge's start.
	var start := cube.edge_point_at_length(edge, 0)
	var s: float = start.point.distance_to(foot["point"])
	var at := cube.edge_point_at_length(edge, s)
	ok(v3near(at.point, foot["point"], 1e-5), "the point at that arc length")
	near(at.parameter, foot["t"], 1e-5)
	eq(refuses(func(): return cube.edge_closest_point(99, p), "edge_closest_point: "), "edge_closest_point: edge 99 of 12")
	eq(cube.edge_closest_point(99, p), null)
	refuses(func(): return cube.edge_closest_point(-1, p), "edge_closest_point: no edge -1")

func test_closest_point_max_distance_on_both_sides():
	var cube := CadaclysmSolid.cuboid(10, 10, 10)
	var far := Vector3(20, 0, 0)
	eq(cube.closest_point(far, 14.9), null)
	eq(Cadaclysm.last_error(), "", "beyond the limit is not a refusal")
	near(cube.closest_point(far, 15.1).distance, 15.0, 1e-9)
	ok(cube.closest_point(far, INF) != null, "INF is no limit")
	ok(cube.closest_point([5, 1, 2], 0.0) != null, "0 keeps a point on the body")
	eq(cube.closest_point([5.5, 1, 2], 0.0), null)
	eq(refuses(func(): return cube.closest_point(Vector3.ZERO, -1.0), "closest_point: "),
		"closest_point: the max distance must not be negative")
	eq(cube.closest_point(Vector3.ZERO, -1.0), null)
	refused(func(): return cube.closest_point(Vector3.ZERO, NAN, -1.0), "closest_point: ")
	refused(func(): return cube.closest_point(Vector3.ZERO, NAN, INF), "closest_point: ")
	refused(func(): return cube.closest_point([NAN, 0, 0]), "closest_point: ")
	refused(func(): return cube.closest_point([0, 0]), "closest_point: ")

func test_a_projector_answers_as_the_one_shot_and_outlives_its_solid():
	var cube := CadaclysmSolid.cuboid(10, 10, 10)
	var want := []
	for row in CP_CUBE_FEET:
		want.append(cube.closest_point(row[0]))
	var projector := cube.projector()
	ok(projector != null, Cadaclysm.last_error())
	cube.close()
	for i in CP_CUBE_FEET.size():
		var got := projector.closest_point(CP_CUBE_FEET[i][0])
		ok(got != null and got.equals(want[i]), "%s != %s" % [str(got), str(want[i])])
		cp_foot_is(got, CP_CUBE_FEET[i])
	eq(projector.closest_point(CP_CUBE_FEET[0][0], 14.9), null)
	eq(Cadaclysm.last_error(), "", "beyond the limit is not a refusal")
	ok(projector.closest_point(CP_CUBE_FEET[0][0], 15.1).equals(want[0]), "within 15.1")
	eq(refuses(func(): return projector.closest_point(Vector3.ZERO, -1.0), "projector_closest_point: "),
		"projector_closest_point: the max distance must not be negative")
	refused(func(): return CadaclysmSolid.sphere(1).projector(-1.0), "projector_new: ")
	eq(CadaclysmSolid.sphere(1).projector(-1.0), null)
	eq(projector.closed, false)
	projector.close()
	eq(projector.closed, true)
	eq(refuses(func(): return projector.closest_point(Vector3.ZERO), "projector: closed"), "projector: closed")
	eq(projector.closest_point(Vector3.ZERO), null)
	projector.close()   # idempotent
	eq(projector.closed, true)

func test_face_closest_point_stays_on_its_face():
	var cube := CadaclysmSolid.cuboid(10, 10, 10)
	var top := -1
	for f in cube.faces:
		if cube.face_ref(f)[6] > 0.5:
			top = f
	var foot := cube.face_closest_point(top, [20, 0, 0])
	ok(all_near(foot.raw_point, [5, 0, 5]), str(foot))
	near(foot.distance, 15.811388300841896, 1e-9)
	ok(foot.kind == "edge" and foot.refined, str(foot))
	var inner := cube.face_closest_point(top, [1, 2, 9])
	ok(all_near(inner.raw_point, [1, 2, 5]) and all_near(inner.raw_normal, [0, 0, 1]), str(inner))
	ok(inner.kind == "face" and inner.index == top and inner.edge == -1 and inner.uv.size() == 2, str(inner))
	eq(refuses(func(): return cube.face_closest_point(99, Vector3.ZERO), "face_closest_point: "),
		"face_closest_point: face 99 of 6")
	eq(cube.face_closest_point(99, Vector3.ZERO), null)

func test_a_nurbs_curves_closest_point_and_its_axis():
	var circle := CadaclysmCircle.create(XY, 2).to_nurbs()
	var foot := circle.closest_point([0, 5, 0])
	ok(foot != null, Cadaclysm.last_error())
	ok(all_near(foot.raw_point, [0, 2, 0]) and foot.unique, str(foot))
	ok(all_near(circle.point(foot.t), foot.raw_point, 1e-12), "the foot's parameter")
	var axis := circle.closest_point(Vector3(0, 0, 3))
	eq(axis.unique, false, str(axis))
	near(Vector3(axis.raw_point[0], axis.raw_point[1], axis.raw_point[2]).length(), 2.0, 1e-6)
	refused(func(): return circle.closest_point([INF, 0, 0]), "nurbs_curve_closest_point: ")
	eq(circle.closest_point([INF, 0, 0]), null)

# ---- closest points from a curve: a point within reach of a line, two skew lines and a line
# through or past the 2-cube pinned to their closed forms (literals, not read back through the
# wrapper; the doubles through the raw_ properties), max_distance on both sides, the projector
# equal to the one-shot, the nearest object naming its item with a curve's and a point's answer,
# and the refusals (null, the reason in last_error).

const CC_SHIFTS := [[0.0, 0.0, 0.0], [1e4, -1e4, 5e3], [1e6, -1e6, 5e5]]

func cc_plus(s: Array, p: Array) -> Array:
	return [s[0] + p[0], s[1] + p[1], s[2] + p[2]]

func cc_segment(a: Array, b: Array) -> CadaclysmNurbsCurve:
	return CadaclysmNurbsCurve.create([a, b], 1)

# 1e-12 (or `base`) relative to the shift's largest coordinate, as the other wrappers' tests take it.
func cc_scaled(s: Array, base := 1e-12) -> float:
	return base * (1.0 + maxf(absf(s[0]), maxf(absf(s[1]), absf(s[2]))))

func test_curve_closest_points_a_point_within_reach_of_a_line():
	for s in CC_SHIFTS:
		var line := cc_segment(s, cc_plus(s, [10, 0, 0]))
		var p := cc_plus(s, [3, 4, 0])
		var foot := line.closest_point(p, 4.1)
		if not ok(foot != null, Cadaclysm.last_error()):
			return
		near(foot.t, 0.3, 1e-12)
		ok(all_near(foot.raw_point, cc_plus(s, [3, 0, 0]), cc_scaled(s)) and foot.unique, str(foot))
		eq(line.closest_point(p, 3.9), null)
		eq(Cadaclysm.last_error(), "", "beyond the limit is not a refusal")
		var unlimited := line.closest_point(p)
		for limit in [NAN, INF]:
			var same := line.closest_point(p, limit)
			ok(same.t == unlimited.t and same.raw_point == unlimited.raw_point and same.unique == unlimited.unique,
				"%s is no limit" % str(limit))
	var line := cc_segment([0, 0, 0], [10, 0, 0])
	eq(refuses(func(): return line.closest_point([3, 4, 0], -1.0), "nurbs_curve_closest_point_within: "),
		"nurbs_curve_closest_point_within: the max distance must not be negative")
	eq(line.closest_point([3, 4, 0], -1.0), null)

func test_curve_closest_points_two_skew_lines_meet_at_their_closed_form():
	for s in CC_SHIFTS:
		var a := cc_segment(s, cc_plus(s, [10, 0, 0]))
		var b := cc_segment(cc_plus(s, [3, -5, 2]), cc_plus(s, [3, 5, 2]))
		for limit in [2.1, NAN, INF]:
			var pair := a.closest_points(b, limit)
			if not ok(pair is CadaclysmCurvePair, "limit %s: %s" % [str(limit), Cadaclysm.last_error()]):
				return
			near(pair.distance, 2.0, 1e-9)
			near(pair.t_a, 0.3, 1e-12)
			near(pair.t_b, 0.5, 1e-12)
			ok(all_near(pair.raw_point_a, cc_plus(s, [3, 0, 0]), cc_scaled(s)), str(pair))
			ok(all_near(pair.raw_point_b, cc_plus(s, [3, 0, 2]), cc_scaled(s)), str(pair))
		var swapped := b.closest_points(a)
		near(swapped.t_a, 0.5, 1e-12)
		near(swapped.t_b, 0.3, 1e-12)
		ok(all_near(swapped.raw_point_a, cc_plus(s, [3, 0, 2]), cc_scaled(s)), str(swapped))
		ok(a.closest_points(b).equals(a.closest_points(b, INF)), "the default is no limit")
		eq(a.closest_points(b, 1.9), null)
		eq(Cadaclysm.last_error(), "", "beyond the limit is not a refusal")
		eq(refuses(func(): return a.closest_points(b, -1.0), "nurbs_curve_closest_points: "),
			"nurbs_curve_closest_points: the max distance must not be negative")
		eq(a.closest_points(b, -1.0), null)

func test_curve_closest_points_a_line_through_the_cube_crosses_its_first_face():
	var cube := CadaclysmSolid.cuboid(2, 2, 2)
	var through := cc_segment([-3, 0.1, 0.2], [3, 0.1, 0.2])
	var foot := cube.curve_closest_points(through)
	if not ok(foot is CadaclysmCurveBodyFoot, Cadaclysm.last_error()):
		return
	ok(foot.crossing and foot.distance == 0.0, str(foot))
	near(foot.t, 1.0 / 3.0, 1e-9)
	ok(all_near(foot.raw_point_on_curve, [-1, 0.1, 0.2]) and all_near(foot.raw_point_on_body, [-1, 0.1, 0.2]), str(foot))
	ok(v3near(foot.point_on_body, Vector3(-1, 0.1, 0.2), 1e-5), str(foot))
	ok(foot.kind == "face" and foot.edge == -1 and foot.uv.size() == 2 and all_near(foot.raw_normal, [-1, 0, 0]), str(foot))
	var projector := cube.projector()
	ok(projector.curve_closest_points(through).equals(foot), "the projector answers as the one-shot")
	for bad in [-1.0, INF]:
		eq(refuses(func(): return cube.curve_closest_points(through, NAN, bad), "curve_closest_points: "),
			"curve_closest_points: tolerance must be positive and finite")
	ok(cube.curve_closest_points(through, NAN, 0.0) != null, "0 is an unset tolerance")
	eq(refuses(func(): return cube.curve_closest_points(through, -1.0), "curve_closest_points: "),
		"curve_closest_points: the max distance must not be negative")
	eq(cube.curve_closest_points(through, -1.0), null)
	eq(refuses(func(): return projector.curve_closest_points(through, -1.0), "projector_curve_closest_points: "),
		"projector_curve_closest_points: the max distance must not be negative")
	projector.close()
	eq(refuses(func(): return projector.curve_closest_points(through), "projector: closed"), "projector: closed")

func test_curve_closest_points_a_line_past_an_edge_and_a_projector_answering_as_the_one_shot():
	for s in CC_SHIFTS:
		var tol := cc_scaled(s, 1e-9)
		var cube := CadaclysmSolid.cuboid(2, 2, 2).translate(s[0], s[1], s[2])
		var line := cc_segment(cc_plus(s, [2, -0.5, 2]), cc_plus(s, [2.5, 0.5, 2.5]))
		var projector := cube.projector()
		var foot := cube.curve_closest_points(line, 1.5)
		if not ok(foot != null, Cadaclysm.last_error()):
			return
		ok(not foot.crossing and foot.kind == "edge" and foot.uv.is_empty(), str(foot))
		near(foot.distance, sqrt(2.0), tol)
		near(foot.t, 0.0, 1e-9)
		ok(all_near(foot.raw_point_on_curve, cc_plus(s, [2, -0.5, 2]), tol), str(foot))
		ok(all_near(foot.raw_point_on_body, cc_plus(s, [1, -0.5, 1]), tol), str(foot))
		ok(foot.edge >= 0, str(foot))
		var at = cube.edge_closest_point(foot.edge, foot.raw_point_on_curve)
		ok(all_near(at["raw_point"], foot.raw_point_on_body, tol), "the public edge's foot")
		near(at["distance"], foot.distance, tol)
		eq(cube.curve_closest_points(line, 1.4), null)
		eq(projector.curve_closest_points(line, 1.4), null)
		eq(Cadaclysm.last_error(), "", "beyond the limit is not a refusal")
		ok(projector.curve_closest_points(line, 1.5).equals(foot), "within 1.5")
		ok(projector.curve_closest_points(line).equals(cube.curve_closest_points(line)), "no limit")
		ok(cube.curve_closest_points(line, NAN).equals(cube.curve_closest_points(line, INF)), "NaN and INF")

func test_curve_closest_points_the_nearest_object_names_its_item():
	var cube := CadaclysmSolid.cuboid(2, 2, 2)
	var line := cc_segment([2, -0.5, 2], [2.5, 0.5, 2.5])
	var other := cc_segment([2, -0.5, 2.3], [2, 5, 2.3])   # sqrt(0.045) off `line`, at t 0.3
	var projector := cube.projector()

	# A curve wins (answer kind 1): its pair.
	var nearest := line.closest_object([Vector3(0, 0, 10), cube, other, projector, [9, 9, 9]])
	if not ok(nearest is CadaclysmNearestObject, Cadaclysm.last_error()):
		return
	var pair := line.closest_points(other)
	eq(nearest.which, 2)
	ok(nearest.answer is CadaclysmCurvePair and nearest.answer.equals(pair), str(nearest))
	near(nearest.distance, sqrt(0.045), 1e-9)
	near(nearest.t, 0.3, 1e-9)
	ok(nearest.distance == pair.distance and nearest.t == pair.t_a, str(nearest))
	ok(nearest.raw_point_on_curve == pair.raw_point_a and nearest.raw_point_on_item == pair.raw_point_b, str(nearest))

	# A point wins (answer kind 2): no answer of its own.
	var point := line.closest_object([cube, [2.5, 0.6, 2.5]])
	eq(point.which, 1)
	eq(point.answer, null)
	near(point.distance, 0.1, 1e-9)
	near(point.t, 1.0, 1e-9)
	ok(all_near(point.raw_point_on_item, [2.5, 0.6, 2.5], 0.0) and all_near(point.raw_point_on_curve, [2.5, 0.5, 2.5]), str(point))

	# A solid or a projector alone: the body's answer.
	var solid := line.closest_object([cube])
	eq(solid.which, 0)
	ok(solid.answer is CadaclysmCurveBodyFoot and solid.answer.equals(cube.curve_closest_points(line)), str(solid))
	var prepared := line.closest_object([projector], NAN, NAN)
	ok(prepared.answer.equals(projector.curve_closest_points(line)), str(prepared))
	ok(prepared.equals(line.closest_object([projector])), "equals compares every field")

	eq(line.closest_object([cube, other], 0.2), null)
	eq(Cadaclysm.last_error(), "", "beyond the limit is not a refusal")
	eq(line.closest_object([cube, other], 0.25).which, 1)
	eq(line.closest_object([]), null)
	eq(refuses(func(): return line.closest_object([cube], -1.0), "nurbs_curve_closest_object: "),
		"nurbs_curve_closest_object: the max distance must not be negative")
	refused(func(): return line.closest_object([cube, "hello"]), "nurbs_curve_closest_object: item 1: ")
	refused(func(): return line.closest_object([[NAN, 0, 0]]), "nurbs_curve_closest_object: ")
	eq(line.closest_object([cube, "hello"]), null)

# ---- closest points against a triangle mesh: a unit square's face, shared edge, outer edge and
# corner, and a line through a tetrahedron, pinned to their closed forms (literals, not read back
# through the wrapper; the doubles through the raw_ properties, the mesh's points given as arrays
# so they keep a double's precision) at the origin and shifted far out; max_distance on both
# sides, packed arrays, a solid's own mesh, the nearest object naming a mesh item, and the
# refusals (null, the reason in last_error).

const MC_SQUARE := [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [1.0, 1.0, 0.0], [0.0, 1.0, 0.0]]
const MC_SQUARE_TRIANGLES := [[0, 1, 2], [0, 2, 3]]   # sharing the diagonal 0-2
const MC_TETRA := [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
const MC_TETRA_TRIANGLES := [[0, 2, 1], [0, 1, 3], [0, 3, 2], [1, 2, 3]]   # 0 the z = 0 floor

func mc_mesh(points: Array, triangles: Array, s: Array) -> CadaclysmTriangleMesh:
	var moved := []
	for p in points:
		moved.append(cc_plus(s, p))
	return CadaclysmTriangleMesh.create(moved, triangles)

func test_mesh_closest_points_face_edge_and_vertex_feet():
	for s in CC_SHIFTS:
		var tol := cc_scaled(s)
		var mesh := mc_mesh(MC_SQUARE, MC_SQUARE_TRIANGLES, s)
		if not ok(mesh is CadaclysmTriangleMesh, Cadaclysm.last_error()):
			return
		eq(mesh.vertex_count(), 4)
		eq(mesh.triangle_count(), 2)
		ok(all_near(mesh.raw_bounds(), [s[0], s[1], s[2], s[0] + 1.0, s[1] + 1.0, s[2]], 0.0), str(mesh.raw_bounds()))
		var face := mesh.closest_point(cc_plus(s, [0.75, 0.25, 2]))
		if not ok(face is CadaclysmMeshPoint, Cadaclysm.last_error()):
			return
		ok(face.triangle == 0 and face.kind == "face" and face.vertices.is_empty(), str(face))
		ok(all_near(face.raw_point, cc_plus(s, [0.75, 0.25, 0]), tol), str(face))
		near(face.distance, 2.0, 1e-9)
		ok(all_near(face.barycentric, [0.25, 0.5, 0.25]), str(face))
		var diagonal := mesh.closest_point(cc_plus(s, [0.5, 0.5, 1]))
		ok(diagonal.triangle == 0 and diagonal.kind == "edge" and diagonal.vertices == PackedInt64Array([0, 2]), str(diagonal))
		near(diagonal.distance, 1.0, 1e-9)
		ok(all_near(diagonal.barycentric, [0.5, 0.0, 0.5]), str(diagonal))
		var outer := mesh.closest_point(cc_plus(s, [0.5, -1, 0]))
		ok(outer.triangle == 0 and outer.kind == "edge" and outer.vertices == PackedInt64Array([0, 1]), str(outer))
		ok(all_near(outer.barycentric, [0.5, 0.5, 0.0]), str(outer))
		var corner := mesh.closest_point(cc_plus(s, [2, 2, 0]))
		ok(corner.triangle == 0 and corner.kind == "vertex" and corner.vertices == PackedInt64Array([2]), str(corner))
		ok(all_near(corner.raw_point, cc_plus(s, [1, 1, 0]), tol), str(corner))
		near(corner.distance, sqrt(2.0), 1e-9)
		ok(all_near(corner.barycentric, [0.0, 0.0, 1.0]), str(corner))
	# Godot's own packed arrays build the same mesh.
	var packed := CadaclysmTriangleMesh.create(
		PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(0, 1, 0)]),
		PackedInt32Array([0, 1, 2, 0, 2, 3]))
	var listed := mc_mesh(MC_SQUARE, MC_SQUARE_TRIANGLES, [0.0, 0.0, 0.0])
	ok(packed.closest_point(Vector3(0.5, 0.5, 1)).equals(listed.closest_point([0.5, 0.5, 1])), "packed arrays build the same mesh")
	ok(v3near(packed.bounds().end, Vector3(1, 1, 0)), str(packed.bounds()))

func test_mesh_closest_points_a_point_max_distance_on_both_sides():
	for s in CC_SHIFTS:
		var mesh := mc_mesh(MC_SQUARE, MC_SQUARE_TRIANGLES, s)
		var p := cc_plus(s, [0.75, 0.25, 2])
		var unlimited := mesh.closest_point(p)
		if not ok(unlimited != null, Cadaclysm.last_error()):
			return
		ok(mesh.closest_point(p, 2.1).equals(unlimited), "within 2.1")
		eq(mesh.closest_point(p, 1.9), null)
		eq(Cadaclysm.last_error(), "", "beyond the limit is not a refusal")
		ok(mesh.closest_point(p, NAN).equals(unlimited) and mesh.closest_point(p, INF).equals(unlimited), "NaN and INF")
	var mesh := mc_mesh(MC_SQUARE, MC_SQUARE_TRIANGLES, [0.0, 0.0, 0.0])
	ok(mesh.closest_point([0.5, 0.5, 0], 0.0) != null, "a point on the mesh is within 0")
	eq(refuses(func(): return mesh.closest_point([0.5, 0.5, 1], -1.0), "triangle_mesh_closest_point: "),
		"triangle_mesh_closest_point: the max distance must not be negative")
	eq(mesh.closest_point([0.5, 0.5, 1], -1.0), null)

func test_mesh_closest_points_a_line_through_a_tetrahedron_crosses_its_floor_first():
	for s in CC_SHIFTS:
		var tol := cc_scaled(s, 1e-9)
		var mesh := mc_mesh(MC_TETRA, MC_TETRA_TRIANGLES, s)
		var line := cc_segment(cc_plus(s, [0.2, 0.2, -1]), cc_plus(s, [0.2, 0.2, 2]))
		var foot := mesh.curve_closest_points(line)
		if not ok(foot is CadaclysmCurveMeshFoot, Cadaclysm.last_error()):
			return
		ok(foot.crossing and foot.distance == 0.0, str(foot))
		ok(foot.triangle == 0 and foot.kind == "face" and foot.vertices.is_empty(), str(foot))
		near(foot.t, 1.0 / 3.0, 1e-9)
		ok(all_near(foot.raw_point_on_curve, cc_plus(s, [0.2, 0.2, 0]), tol), str(foot))
		ok(all_near(foot.raw_point_on_mesh, cc_plus(s, [0.2, 0.2, 0]), tol), str(foot))
		ok(all_near(foot.barycentric, [0.6, 0.2, 0.2]), str(foot))
		var beside := cc_segment(cc_plus(s, [2, 0, 0]), cc_plus(s, [3, 0, 0]))
		var near_ := mesh.curve_closest_points(beside, 1.1)
		if not ok(near_ != null, Cadaclysm.last_error()):
			return
		ok(not near_.crossing and near_.triangle == 0 and near_.kind == "vertex" and near_.vertices == PackedInt64Array([1]), str(near_))
		near(near_.distance, 1.0, tol)
		near(near_.t, 0.0, 1e-9)
		ok(all_near(near_.raw_point_on_mesh, cc_plus(s, [1, 0, 0]), tol), str(near_))
		eq(mesh.curve_closest_points(beside, 0.9), null)
		eq(Cadaclysm.last_error(), "", "beyond the limit is not a refusal")
		ok(mesh.curve_closest_points(beside).equals(near_), "the default is no limit")
		ok(mesh.curve_closest_points(beside, NAN).equals(near_) and mesh.curve_closest_points(beside, INF).equals(near_), "NaN and INF")
		eq(refuses(func(): return mesh.curve_closest_points(beside, -1.0), "triangle_mesh_curve_closest_points: "),
			"triangle_mesh_curve_closest_points: the max distance must not be negative")

func test_mesh_closest_points_a_bad_index_and_a_closed_mesh_are_refused():
	eq(refuses(func(): return CadaclysmTriangleMesh.create(MC_SQUARE, [[0, 1, 4]]), "triangle_mesh_new: "),
		"triangle_mesh_new: triangle 0 names vertex 4, past the vertex count")
	eq(CadaclysmTriangleMesh.create(MC_SQUARE, [[0, 1, 4]]), null)
	var mesh := mc_mesh(MC_SQUARE, MC_SQUARE_TRIANGLES, [0.0, 0.0, 0.0])
	ok(not mesh.closed, "open")
	mesh.close()
	mesh.close()
	ok(mesh.closed, "closed")
	eq(refuses(func(): return mesh.closest_point([0, 0, 1]), "triangle_mesh: closed"), "triangle_mesh: closed")
	var line := cc_segment([0, 0, 1], [1, 0, 1])
	eq(refuses(func(): return line.closest_object([mesh]), "nurbs_curve_closest_object: "),
		"nurbs_curve_closest_object: item 0: triangle_mesh: closed")

func test_mesh_closest_points_a_solids_triangle_mesh_is_its_measuring_tessellation():
	var cube := CadaclysmSolid.cuboid(2, 2, 2)
	var mesh := cube.triangle_mesh()
	if not ok(mesh is CadaclysmTriangleMesh, Cadaclysm.last_error()):
		return
	ok(mesh.triangle_count() >= 12 and mesh.vertex_count() >= 8, str(mesh))
	ok(all_near(mesh.raw_bounds(), [-1, -1, -1, 1, 1, 1]), str(mesh.raw_bounds()))
	eq(cube.triangle_mesh(0.0).triangle_count(), mesh.triangle_count(), "0 is an unset tolerance")
	for bad in [-1.0, INF]:
		eq(refuses(func(): return cube.triangle_mesh(bad), "solid_triangle_mesh: "),
			"solid_triangle_mesh: tolerance must be positive and finite")
	cube.close()
	var foot := mesh.closest_point([5, 0.1, 0.2])
	if not ok(foot != null, Cadaclysm.last_error()):
		return
	near(foot.distance, 4.0, 1e-9)
	ok(all_near(foot.raw_point, [1, 0.1, 0.2]), str(foot))

func test_mesh_closest_points_the_nearest_object_takes_a_triangle_mesh():
	var mesh := mc_mesh(MC_TETRA, MC_TETRA_TRIANGLES, [0.0, 0.0, 0.0])
	var line := cc_segment([0.2, 0.2, -1], [0.2, 0.2, 2])
	var nearest := line.closest_object([[9, 9, 9], mesh])
	if not ok(nearest is CadaclysmNearestObject, Cadaclysm.last_error()):
		return
	var own := mesh.curve_closest_points(line)
	eq(nearest.which, 1)
	ok(nearest.answer is CadaclysmCurveMeshFoot and nearest.answer.equals(own), str(nearest))
	ok(nearest.distance == own.distance and nearest.t == own.t, str(nearest))
	ok(nearest.raw_point_on_curve == own.raw_point_on_curve and nearest.raw_point_on_item == own.raw_point_on_mesh, str(nearest))
	var beside := cc_segment([2, 0, 0], [3, 0, 0])
	var after := beside.closest_object([mesh, [2.5, 0.5, 0]])
	eq(after.which, 1)
	eq(after.answer, null)
	near(after.distance, 0.5, 1e-9)
	# 1 from vertex 0 and from the point (0, 0, 0) alike: the earlier item answers.
	var short := cc_segment([-2, 0, 0], [-1, 0, 0])
	var tie := short.closest_object([mesh, [0, 0, 0]])
	ok(tie.which == 0 and tie.distance == 1.0, str(tie))
	ok(tie.answer is CadaclysmCurveMeshFoot and tie.answer.vertices == PackedInt64Array([0]), str(tie))
	var second := short.closest_object([[0, 0, 0], mesh])
	ok(second.which == 0 and second.answer == null, str(second))
	eq(beside.closest_object([mesh], 0.9), null)
	eq(Cadaclysm.last_error(), "", "beyond the limit is not a refusal")

func _hlr_sum(lines: Array) -> float:
	var total := 0.0
	for l in lines:
		total += l.length3d
	return total

func test_a_cube_on_its_diagonal_shows_nine_lines_and_hides_three():
	var cube := CadaclysmSolid.cuboid(10, 10, 10)
	var view = CadaclysmBlacksmith.hlr([cube], {"direction": Vector3(-1, -1, -1)})
	ok(view is CadaclysmHlr, Cadaclysm.last_error())
	eq([view.visible().size(), view.hidden().size()], [9, 3])
	for l in view.lines():
		eq([l.kind, l.source_kind, l.solid, l.source2], ["sharp", "edge", 0, -1], str(l))
		var b2: PackedFloat64Array = l.beziers2d
		eq(b2.size() % 16, 0)
		ok(b2.size() >= 16 and b2.size() == l.beziers3d.size(), str(l))
		for k in range(2, b2.size(), 4):
			eq(b2[k], 0.0, "a view-plane Bézier lies at z 0")
	ok(absf(_hlr_sum(view.visible()) - 90.0) < 1e-6, str(_hlr_sum(view.visible())))
	ok(absf(_hlr_sum(view.hidden()) - 30.0) < 1e-6, str(_hlr_sum(view.hidden())))
	for l in view.hidden():
		var p: PackedFloat64Array = l.beziers3d
		var n := p.size()
		var first := Vector3(p[0], p[1], p[2])
		var last := Vector3(p[n - 4], p[n - 3], p[n - 2])
		ok(first.is_equal_approx(Vector3(-5, -5, -5)) or last.is_equal_approx(Vector3(-5, -5, -5)), str(l))
	eq(view.report()["unsettled"], 0)
	ok(absf(view.tolerance - CadaclysmBlacksmith.effective_tolerance([cube])) < 1e-15, str(view.tolerance))
	var persp = CadaclysmBlacksmith.hlr([cube], {"eye": [30, 25, 20], "target": Vector3.ZERO})
	eq([persp.visible().size(), persp.hidden().size()], [9, 3])
	var corners := [[-5, -5, -5], [5, -5, -5], [5, 5, -5], [-5, 5, -5], [-5, -5, 5], [5, -5, 5], [5, 5, 5], [-5, 5, 5]]
	var triangles := [[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7], [0, 1, 5], [0, 5, 4], [3, 7, 6], [3, 6, 2], [0, 4, 7], [0, 7, 3], [1, 2, 6], [1, 6, 5]]
	var meshed = CadaclysmBlacksmith.hlr_mesh([CadaclysmTriangleMesh.create(corners, triangles)], {"direction": [-1, -1, -1]})
	eq([meshed.visible().size(), meshed.hidden().size()], [9, 3])
	ok(meshed.lines().all(func(l): return l.source_kind == "mesh_edge" and l.source2 >= 0), str(meshed.lines()))
	refuses(func(): return CadaclysmBlacksmith.hlr([cube], {"direction": [0, 0, -1]}), "hlr: up is along the view -- give one across it")
	refuses(func(): return CadaclysmBlacksmith.hlr([], {}), "hlr: no solids")
	refuses(func(): return CadaclysmBlacksmith.hlr([cube], {"direction": [1, 0, 0], "eye": [5, 5, 5]}), "hlr: give direction (parallel) or eye (perspective), not both")
	view.close()
	ok(view.closed and view.lines().is_empty())

func test_a_plate_outlines_as_one_profile_with_its_hole():
	var plate := CadaclysmSolid.cuboid(40, 30, 5).cut(CadaclysmSolid.cylinder(5, 20).translate(0, 0, -10), NAN)
	var outline := CadaclysmBlacksmith.projected_outline([plate], {"direction": [0, 0, -1], "up": [0, 1, 0]})
	eq(outline.size(), 1, Cadaclysm.last_error())
	var b: PackedFloat64Array = outline[0].beziers()
	var max_x := 0.0
	for k in range(0, b.size(), 4):
		max_x = maxf(max_x, absf(b[k]))
	ok(absf(max_x - 20.0) < 1e-6, str(max_x))

func test_svg_draws_hidden_lines_removed_or_dashed():
	var cube := CadaclysmSolid.cuboid(10, 10, 10)
	var el := rad_to_deg(atan(1.0 / sqrt(2.0)))
	var removed := cube.svg_text_with({"az": 45, "el": el, "hidden": "removed"})
	ok(removed.contains("<g id=\"solid-0\"") and not removed.contains("solid-0-hidden"), Cadaclysm.last_error())
	var dashed := cube.svg_text_with({"az": 45, "el": el, "hidden": "dashed"})
	var group := dashed.substr(dashed.find("<g id=\"solid-0-hidden\""))
	group = group.substr(0, group.find("</g>"))
	ok(group.contains("stroke-dasharray"), group)
	eq(group.count("M"), 3)
	eq(cube.svg_text_with({"hidden": "faint"}), "")

func test_a_page_writes_r2000_dxf_that_reads_back_as_its_profiles():
	var cube := CadaclysmSolid.cuboid(10, 10, 10)
	var rect := CadaclysmProfile.rect(40, 20)
	var page = CadaclysmPage.create("mm")
	ok(page.add_view(CadaclysmBlacksmith.hlr([cube], {"direction": [-1, -1, -1]}), Vector2(50, 50), 2.0), Cadaclysm.last_error())
	eq(page.entity_count, 12)
	ok(page.add_profile(rect, [150, 50], "parts"))
	ok(page.add_hatch(rect, [150, 50], "ANSI31"))
	ok(page.add_text("PLATE", [150, 30], 3.5, 0.0, "center"))
	eq(page.entity_count, 15)
	var dxf: String = page.dxf()
	ok(dxf.begins_with("  0\nSECTION\n  2\nHEADER\n  9\n$ACADVER\n  1\nAC1015\n"), dxf.substr(0, 60))
	eq(dxf, page.dxf())
	for layer in ["visible", "hidden", "parts", "hatch", "text"]:
		ok(dxf.contains("\n  8\n" + layer + "\n"), layer)
	ok(page.svg().contains("PLATE"))
	var alone = CadaclysmPage.create()
	ok(alone.add_profile(rect, Vector2(150, 50)))
	var back := CadaclysmBlacksmith.dxf_profiles(alone.dxf())
	eq(back.size(), 1, Cadaclysm.last_error())
	var b: PackedFloat64Array = back[0].beziers()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for k in range(0, b.size(), 4):
		lo = Vector2(minf(lo.x, b[k]), minf(lo.y, b[k + 1]))
		hi = Vector2(maxf(hi.x, b[k]), maxf(hi.y, b[k + 1]))
	ok(lo.is_equal_approx(Vector2(130, 40)) and hi.is_equal_approx(Vector2(170, 60)), str([lo, hi]))
	eq(CadaclysmBlacksmith.dxf_profiles("not a DXF file").size(), 0)
	ok(Cadaclysm.last_error().begins_with("dxf_profiles: line "), Cadaclysm.last_error())
	ok(not page.add_hatch(rect, [0, 0], "BRICK"))
	ok(Cadaclysm.last_error().begins_with("page_add_hatch: pattern"), Cadaclysm.last_error())
	eq(CadaclysmPage.create("furlongs"), null)
	page.close()
	ok(page.closed and not page.add_profile(rect, [0, 0]))
