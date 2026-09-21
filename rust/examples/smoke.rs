//! Open one file through the Rust binding and check what comes back, then build a part
//! through the kernel, write it as STEP and read it back through the reader. The exit
//! code is the verdict: the release pipeline runs this against every library it ships,
//! as it runs the C#, Go, Java and Node smokes.
//!
//!     cargo run --example smoke -- samples/cube.scad [cadaclysm.lic]

use std::path::Path;
use std::process::ExitCode;

use cadaclysm_sdk::blacksmith::{
    self, Axis, Curve, Frame, Keep, Path as Outline, Profile, Selector, Solid, SweepPath, Unit, Workplane, DEFAULT_TOLERANCE,
    FILLET_TOLERANCE,
};
use cadaclysm_sdk::{Convention, OpenOptions, Scene, SvgOptions};

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("FAIL: {message}");
            ExitCode::FAILURE
        }
    }
}

fn check(ok: bool, message: &str) -> Result<(), String> {
    if ok {
        Ok(())
    } else {
        Err(message.to_string())
    }
}

fn run() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let path = args.next().unwrap_or_else(|| "samples/cube.scad".to_string());
    let license = args.next();
    if let Some(license) = &license {
        cadaclysm_sdk::license(license).map_err(|e| format!("license: {e}"))?;
    }
    let e = |e: cadaclysm_sdk::Error| e.to_string();
    println!("cadaclysm {} built {}", cadaclysm_sdk::version().map_err(e)?, cadaclysm_sdk::build_date().map_err(e)?);
    println!("license: {}", cadaclysm_sdk::license_info().map_err(e)?);
    println!("library: {}", cadaclysm_sdk::library_path().map_err(e)?.display());

    let mut scene = cadaclysm_sdk::open(&path).map_err(e)?;
    let bounds = scene.bounds();
    println!("bounds min={:?} max={:?}", bounds.min, bounds.max);

    let triangles: usize = scene.walk().filter(|node| node.can_mesh()).map(|node| node.mesh().triangle_count()).sum();
    println!("triangles={triangles}");
    let is_cube = Path::new(&path).file_name().is_some_and(|name| name == "cube.scad");
    // All six bounds values: a bug that only flips Y still passes the X and Z checks.
    if is_cube {
        check(
            bounds.min == [0.0; 3] && bounds.max == [20.0; 3] && triangles == 12,
            "the cube did not come back as a 20-unit cube of 12 triangles",
        )?;
    }

    // The reader's own extras: a query, the diagnostics, the placements.
    let matched = scene.query("class == solid").map_err(e)?;
    println!("query: {} node(s)", matched.len());
    check(scene.query("class ==").is_err(), "a filter that does not parse was accepted")?;
    println!("diagnostics: {}", scene.diagnostics().len());
    let formats = cadaclysm_sdk::formats().map_err(e)?;
    check(formats.iter().any(|f| f.name == "IGES" && f.extensions == ["iges", "igs"]), "formats() lacks IGES iges;igs")?;
    let mesh_formats = cadaclysm_sdk::mesh_formats().map_err(e)?;
    check(mesh_formats.iter().any(|f| f.name == "stl" && f.label == "STL (binary)"), "mesh format label is not the library's")?;
    println!("geometry diagnostics: {}", scene.geometry_diagnostics().len());
    scene.forget_meshes();
    let again: usize = scene.walk().filter(|node| node.can_mesh()).map(|node| node.mesh().triangle_count()).sum();
    check(again == triangles, "forget_meshes did not rebuild")?;
    check(cadaclysm_sdk::lod_levels().map_err(e)? == 3, "lod_levels is not 3")?;
    let first = scene.walk().find(|n| n.can_mesh()).ok_or("no meshable node")?;
    check(first.mesh_lod(0).triangle_count() == first.mesh().triangle_count(), "LOD 0 is not the mesh")?;
    check(first.lod_error(0) == 0.0 && first.mesh_lod(4).is_empty(), "LOD errors or levels are off")?;
    if path.ends_with("cube.scad") {
        let beziers = first.edge_beziers();
        check(first.mesh_lod(1).triangle_count() == 3 && beziers.count() == 12 && beziers.points.len() == 48, "the cube's LOD 1 or Béziers are off")?;
    }
    let fit = first.collision(0).ok_or("no collision body for the first body")?;
    check(fit.error == 0.0 && fit.hull_vertex_count == 8 && !fit.shape_name().is_empty(), "the collision fit is off")?;
    let hull = first.collision_hull(0);
    check(hull.vertex_count() == 8 && hull.index_count() == 36, "the collision hull is off")?;
    let mesh = first.mesh();
    let meshlets = cadaclysm_sdk::Meshlets::build(mesh.positions, mesh.normals, mesh.indices, 124, 64, 0).map_err(e)?;
    check(meshlets.count() >= 1, "no meshlets")?;
    let one = meshlets.meshlet(0);
    check(one.positions.len() == one.vertex_count() && one.indices.len() == one.triangle_count() * 3 && one.level == 0, "meshlet 0 is off")?;
    if path.ends_with("cube.scad") {
        check(meshlets.count() == 1 && one.triangle_count() == 12 && one.vertex_count() == 36, "the cube's meshlets are off")?;
    }
    drop(meshlets);
    check(cadaclysm_sdk::Meshlets::build(mesh.positions, None, mesh.indices, 0, 64, 0).is_err(), "a zero budget was accepted")?;
    let estimate = first.triangle_estimate();
    check(estimate > 0 || estimate == -1, "triangle estimate is neither a count nor -1")?;
    if path.ends_with("cube.scad") {
        check(estimate == 12 && first.surface_edges().is_empty() && first.surface_proxy_mesh(4).is_empty(), "the cube has no surface products")?;
        check(first.surface_pick([10.0, 10.0, 100.0], [10.0, 10.0, -100.0]).is_none() && first.bounds_placed(None).is_empty(), "the cube picks or bounds through surfaces")?;
    }
    let fresh = cadaclysm_sdk::open(&path).map_err(e)?;
    let body = fresh.walk().find(|n| n.can_mesh()).ok_or("no meshable node")?;
    check(!body.is_meshed(), "a fresh scene is already meshed")?;
    check(fresh.realize_meshes(false) > 0 && body.is_meshed(), "realize_meshes(false) did not build")?;
    println!("placements: {}", scene.placements().len());
    if is_cube {
        check(!matched.is_empty(), "class == solid matched nothing in the cube")?;
        let mesh = scene.node(matched[0]).ok_or("the query named a node past the end")?.mesh();
        check(mesh.vertex_count() > 0 && mesh.normals.is_some(), "the cube's mesh has no vertices or no normals")?;
        check(mesh.indices.iter().all(|&i| (i as usize) < mesh.vertex_count()), "an index points past the vertices")?;
    }

    // The same bytes in memory, the format given since the name has no extension.
    let data = std::fs::read(&path).map_err(|err| err.to_string())?;
    let extension = Path::new(&path).extension().map(|x| x.to_string_lossy().into_owned()).unwrap_or_default();
    let again = OpenOptions::new().name("cube-bytes").open_memory(&data, &extension).map_err(e)?;
    check(again.bounds() == bounds, "open_memory disagrees with open")?;
    check(again.path() == Path::new("cube-bytes"), "open_memory's path is not the name it was given")?;
    drop(again);
    check(cadaclysm_sdk::open_memory(&data, "no-such-format").is_err(), "an unknown format opened")?;

    // A convention converts on the way out: a Y-up metres read of the same file.
    let yup = OpenOptions::new().convention(Convention::YUp).open(&path).map_err(e)?;
    check(yup.convention() == Convention::YUp as u32, "the scene forgot its convention")?;
    println!("y-up bounds min={:?} max={:?}", yup.bounds().min, yup.bounds().max);

    // Threads: realize on one, read progress on another.
    let realized = std::thread::scope(|scope| {
        let worker = scope.spawn(|| yup.realize_all());
        let _ = yup.realized();
        worker.join().expect("realize_all panicked")
    });
    println!("realize_all: {realized} of {}", yup.realize_total());
    check(yup.realized() == yup.realize_total(), "realize_all stopped short")?;

    save_checks(&scene)?;

    // SVG: the library's own camera, no viewer -- a scene and a node each write a
    // wireframe.
    let svg_text = scene.svg_text(&SvgOptions::default()).map_err(e)?;
    check(svg_text.starts_with("<svg") && svg_text.contains("<path"), "scene SVG text did not look like an SVG wireframe")?;
    let svg_path = std::env::temp_dir().join("cadaclysm-smoke-rust.svg");
    scene.svg(&svg_path, &SvgOptions::default()).map_err(e)?;
    check(std::fs::metadata(&svg_path).is_ok_and(|m| m.len() > 0), "Scene::svg wrote an empty file")?;
    let node_svg_text = first.svg_text(&SvgOptions::default()).map_err(e)?;
    check(node_svg_text.starts_with("<svg") && node_svg_text.contains("<path"), "node SVG text did not look like an SVG wireframe")?;
    let bad_fov = SvgOptions { fov: 200.0, ..Default::default() };
    check(scene.svg_text(&bad_fov).is_err(), "scene svg: fov=200 was accepted")?;
    println!("svg: scene and node text, file written, fov=200 refused");

    check(cadaclysm_sdk::open("no/such/file.stp").is_err(), "a missing file opened")?;
    kernel(license.as_deref())?;
    println!("OK");
    Ok(())
}

/// The smoke's second half: the plate with a hole and a pin, filleted, as STEP -- then
/// read back through the reader and handed back to the kernel. The kernel keeps its own
/// license state, so the same file is loaded into it too.
fn kernel(license: Option<&str>) -> Result<(), String> {
    let e = |e: cadaclysm_sdk::Error| e.to_string();
    if let Some(license) = license {
        blacksmith::license(license).map_err(|e| format!("blacksmith license: {e}"))?;
    }
    println!("blacksmith {} built {}", blacksmith::version().map_err(e)?, blacksmith::build_date().map_err(e)?);
    println!("blacksmith license: {}", blacksmith::license_info().map_err(e)?);
    println!("blacksmith library: {}", blacksmith::library_path().map_err(e)?.display());
    check(
        blacksmith::brep_layout_id().map_err(e)? == cadaclysm_sdk::Brep::layout_id().map_err(e)?,
        "the reader and the kernel are not from one build",
    )?;

    // Hits: two radius-5 circles six apart cross at two points, (3, -4) and (3, 4). At
    // (3, 4) the first circle's upper arc is at t 0.2952 and the moved one's at 0.7048;
    // at (3, -4) the other way round -- which catches the two sides read swapped.
    let crossing = Profile::circle(5.0)
        .map_err(e)?
        .hits(&Profile::circle(5.0).and_then(|c| c.translate(6.0, 0.0)).map_err(e)?, 1e-6)
        .map_err(e)?;
    check(crossing.len() == 2, &format!("hits: two circles hit {} times, not 2", crossing.len()))?;
    let mut ys: Vec<f64> = crossing.iter().map(|h| h.start[1]).collect();
    ys.sort_by(f64::total_cmp);
    check((ys[0] + 4.0).abs() < 1e-9 && (ys[1] - 4.0).abs() < 1e-9, &format!("hits: y {ys:?}, not -4 and 4"))?;
    for h in &crossing {
        let (ta, tb) = if h.start[1] > 0.0 { (0.2952, 0.7048) } else { (0.7048, 0.2952) };
        check(
            !h.run
                && !h.touch
                && h.a_start.loop_index == 0
                && (h.start[0] - 3.0).abs() < 1e-9
                && (h.a_start.t - ta).abs() < 1e-3
                && (h.b_start.t - tb).abs() < 1e-3,
            &format!("hits: {h:?} is not a crossing at (3, +-4) at t {ta} on a and {tb} on b"),
        )?;
    }
    println!("hits: {:?}, {:?}", crossing[0].start, crossing[1].start);
    // Common: the same two circles share one lens, four arcs (each circle's own seam stays
    // a join) between two caps once extruded; moved apart they share nothing.
    let left = Profile::circle(5.0).map_err(e)?;
    let right = Profile::circle(5.0).and_then(|c| c.translate(6.0, 0.0)).map_err(e)?;
    let lenses = left.common(&right, 1e-6).map_err(e)?;
    check(lenses.len() == 1, &format!("common: two circles share {} regions, not 1", lenses.len()))?;
    let lens_faces = Workplane::xy().extrude(&lenses[0], 1.0).and_then(|w| w.solid()).and_then(|s| s.faces()).map_err(e)?;
    check(lens_faces == 6, &format!("common: the lens extrudes to {lens_faces} faces, not 6"))?;
    let far = right.translate(100.0, 0.0).map_err(e)?;
    check(left.common(&far, 1e-6).map_err(e)?.is_empty(), "common: circles 100 apart share a region")?;
    match left.common(&right, 0.0) {
        Err(err) if err.to_string().contains("profile_common: tolerance must be positive and finite") => {}
        other => return Err(format!("common: a zero tolerance was accepted or refused in other words: {other:?}")),
    }
    println!("common: one lens, {lens_faces} faces extruded");
    // Edge curves: a cylinder's rims are circles of its radius about a cap centre in a unit
    // frame, a whole turn each; a cuboid's edges are lines whose origin + x is the far end;
    // an extruded closed spline keeps a nurbs edge with knots = poles + degree + 1.
    let norm = |v: [f64; 3]| (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
    let sub = |a: [f64; 3], b: [f64; 3]| [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
    let cyl = Solid::cylinder(5.0, 3.0).map_err(e)?;
    let rims: Vec<Curve> = cyl.edges().map_err(e)?.into_iter().filter(|edge| edge.kind == "circle").filter_map(|edge| edge.curve).collect();
    check(rims.len() >= 2, "edge_curve: the cylinder's rims have no curve")?;
    for c in &rims {
        let unit = (norm(c.x) - 1.0).abs() < 1e-9
            && (norm(c.y) - 1.0).abs() < 1e-9
            && (c.x[0] * c.y[0] + c.x[1] * c.y[1] + c.x[2] * c.y[2]).abs() < 1e-9;
        let centred = c.origin[0].abs() < 1e-9 && c.origin[1].abs() < 1e-9 && c.origin[2].abs().min((c.origin[2] - 3.0).abs()) < 1e-9;
        check(
            c.kind == "circle"
                && (c.radius - 5.0).abs() < 1e-9
                && unit
                && centred
                && ((c.t1 - c.t0).abs() - 2.0 * std::f64::consts::PI).abs() < 1e-9
                && c.degree == 0
                && c.knots.is_empty()
                && c.weights.is_none(),
            &format!("edge_curve: a rim reads {c:?}"),
        )?;
    }
    let cube = Solid::cuboid(2.0, 4.0, 6.0).map_err(e)?;
    let cube_edges = cube.edges().map_err(e)?;
    for edge in &cube_edges {
        let c = edge.curve.as_ref().ok_or_else(|| format!("edge_curve: cuboid edge {} has no curve", edge.index))?;
        check(c.kind == "line" && c.t0 == 0.0 && c.t1 == 1.0, &format!("edge_curve: a cuboid edge reads {c:?}"))?;
        let far = [c.origin[0] + c.x[0], c.origin[1] + c.x[1], c.origin[2] + c.x[2]];
        let ends: Vec<[f64; 3]> = edge.segments.iter().flat_map(|s| [s[0], s[1]]).collect();
        check(
            ends.iter().any(|p| norm(sub(*p, c.origin)) < 1e-9) && ends.iter().any(|p| norm(sub(*p, far)) < 1e-9),
            &format!("edge_curve: a cuboid line's ends are not its own vertices: {c:?}"),
        )?;
    }
    let square = Profile::spline(&[[0.0, 0.0], [10.0, 0.0], [10.0, 10.0], [0.0, 10.0]], 3, None, true).map_err(e)?;
    let spline_loop = Solid::extrude(&square, &Frame::xy([0.0; 3]), 2.0).map_err(e)?;
    let splines: Vec<Curve> = spline_loop.edges().map_err(e)?.into_iter().filter(|edge| edge.kind == "nurbs").filter_map(|edge| edge.curve).collect();
    check(!splines.is_empty(), "edge_curve: the extruded spline keeps no nurbs edge")?;
    for c in &splines {
        check(
            c.kind == "nurbs" && c.degree == 3 && c.knots.len() == c.poles.len() + c.degree as usize + 1 && c.weights.is_none(),
            &format!("edge_curve: the spline edge reads {c:?}"),
        )?;
    }
    println!(
        "edge_curve: {} r={} t={}..{}; line {:?}+{:?}; nurbs degree {} poles {}",
        rims[0].kind, rims[0].radius, rims[0].t0, rims[0].t1, cube_edges[0].curve.as_ref().unwrap().origin, cube_edges[0].curve.as_ref().unwrap().x,
        splines[0].degree, splines[0].poles.len()
    );

    let outline = Profile::rect(80.0, 40.0).map_err(e)?.with_hole(&Profile::circle(4.0).map_err(e)?).map_err(e)?;
    let plate = Workplane::xy().extrude(&outline, 6.0).map_err(e)?.solid().map_err(e)?;
    // The chain borrows the plate, which stays the caller's to join the pin to.
    let pin = Workplane::from_solid(&plate)
        .faces(&Selector::Max(Axis::Z))
        .and_then(|w| w.on_face())
        .and_then(|w| w.cylinder(5.0, 10.0))
        .and_then(|w| w.solid())
        .map_err(e)?;
    let part = plate.join(&pin, DEFAULT_TOLERANCE).map_err(e)?;

    // The plate's own corners: vertical lines between planes.
    let mut corners = Vec::new();
    for edge in part.edges().map_err(e)? {
        let vertical = edge.direction().is_some_and(|d| d[2].abs() > 0.99);
        let planes = edge.faces.iter().try_fold(true, |all, &f| Ok::<_, cadaclysm_sdk::Error>(all && part.face_kind(f)? == "plane"));
        if vertical && planes.map_err(e)? {
            corners.push(edge.index);
        }
    }
    let mut rounded = part.fillet(&corners, 1.0, FILLET_TOLERANCE).map_err(e)?;
    let faces = rounded.faces().map_err(e)?;
    let watertight = rounded.is_watertight(DEFAULT_TOLERANCE).map_err(e)?;
    let shape = rounded.manifold().map_err(e)?;
    println!("faces={faces} watertight={watertight} manifold={shape:?}");
    check(watertight, "the filleted part is not watertight")?;
    check(shape.is_closed && shape.faces == faces, "the filleted part is not a closed manifold")?;
    // 6 plate faces, 1 hole, the pin's wall and top, and one face per rounded corner.
    check(faces == 15, &format!("the filleted part has {faces} faces, not 15"))?;

    sheet_verbs(&plate)?;
    frames()?;

    // Colour: a gold plate joined with a blue pin -- gold overall, the pin's top blue.
    let gold = plate.coloured([0.8, 0.6, 0.4], None).map_err(e)?;
    let blue = pin.coloured(blacksmith::rgb("#3366ff").map_err(e)?, None).map_err(e)?;
    let coloured = gold.join(&blue, DEFAULT_TOLERANCE).map_err(e)?;
    let top = coloured.select_face(&Selector::Max(Axis::Z)).map_err(e)?;
    let part_colour = coloured.colour().map_err(e)?;
    let top_colour = coloured.face_colour(top).map_err(e)?;
    println!("colour={part_colour:?} pin top={top_colour:?}");
    check(
        part_colour == Some([0.8, 0.6, 0.4]) && top_colour == blacksmith::rgb("#3366ff").ok(),
        "the colours did not carry through the join",
    )?;
    check(Solid::cuboid(1.0, 1.0, 1.0).map_err(e)?.colour().map_err(e)?.is_none(), "an uncoloured solid has a colour")?;

    // A face: the outline as a sheet, which pushed out is the plate again.
    let sheet = Solid::face(&outline, &Frame::xy([0.0; 3])).map_err(e)?;
    let pushed = sheet.extrude_faces(6.0).map_err(e)?;
    check(
        sheet.faces().map_err(e)? == 1
            && pushed.faces().map_err(e)? == plate.faces().map_err(e)?
            && pushed.is_watertight(DEFAULT_TOLERANCE).map_err(e)?,
        "the outline's face did not push out to the plate",
    )?;

    // The mesh borrows the solid's cache; meshing again needs the borrow to have ended,
    // which the compiler enforces -- here the two meshes are taken one after the other.
    let coarse = rounded.mesh(0.5).map_err(e)?.triangle_count();
    let mesh = rounded.mesh(0.05).map_err(e)?;
    let fine = mesh.triangle_count();
    check(mesh.normals.is_some_and(|n| n.len() == mesh.positions.len()), "the kernel mesh has no normals")?;
    check(mesh.indices.iter().all(|&i| (i as usize) < mesh.positions.len()), "a kernel index points past the vertices")?;
    check(fine > coarse, "a finer tolerance did not mesh finer")?;
    let polylines = rounded.edge_polylines(0.05).map_err(e)?;
    check(!polylines.is_empty() && polylines.iter().all(|p| p.len() >= 2), "the edge polylines are empty")?;
    println!("mesh: {coarse} triangles at 0.5, {fine} at 0.05; {} edge polylines", polylines.len());

    // No schema: the kernel writes against its built-in AP203.
    let text = rounded.step_text(None, Unit::Millimetre).map_err(e)?;
    check(text.starts_with("ISO-10303-21;"), "step_text with no schema did not write valid STEP")?;
    check(rounded.step_text(Some("NO_SUCH_SCHEMA"), Unit::Millimetre).is_err(), "an unknown schema name was accepted")?;

    let step = std::env::temp_dir().join("cadaclysm-smoke-rust.stp");
    rounded.step(&step, None, Unit::Millimetre).map_err(e)?;
    let back = cadaclysm_sdk::open(&step).map_err(|err| format!("step read back: {err}"))?;
    let b = back.bounds();
    println!("step read back: bounds max={:?}", b.max);
    // The plate is 80 x 40 x 6, centred on the origin, and the pin adds 10.
    check(
        (b.max[0] - 40.0).abs() < 0.01 && (b.max[1] - 20.0).abs() < 0.01 && (b.max[2] - 16.0).abs() < 0.01,
        "the STEP did not read back as the plate with its pin",
    )?;

    // The same solid as SAT, written by the library itself, read back the same way.
    let sat = std::env::temp_dir().join("cadaclysm-smoke-rust.sat");
    rounded.sat(&sat, Unit::Millimetre).map_err(e)?;
    check(rounded.sat_text(Unit::Millimetre).map_err(e)?.starts_with("400 0 1 0"), "the SAT text does not open with the record version")?;
    let sat_back = cadaclysm_sdk::open(&sat).map_err(|err| format!("sat read back: {err}"))?;
    let sb = sat_back.bounds();
    println!("sat read back: bounds max={:?}", sb.max);
    check(
        (sb.max[0] - 40.0).abs() < 0.01 && (sb.max[1] - 20.0).abs() < 0.01 && (sb.max[2] - 16.0).abs() < 0.01,
        "the SAT did not read back as the plate with its pin",
    )?;

    // The OCCT .brep writer, and its reader.
    let brep = std::env::temp_dir().join("cadaclysm-smoke-rust.brep");
    rounded.brep(&brep).map_err(e)?;
    check(rounded.brep_text().map_err(e)?.starts_with("DBRep_DrawableShape"), "the .brep text does not begin as one")?;
    let back_brep = cadaclysm_sdk::open(&brep).map_err(|err| format!("brep read back: {err}"))?;
    let bb = back_brep.bounds();
    println!("brep read back: bounds max={:?}", bb.max);
    check(
        (bb.max[0] - 40.0).abs() < 0.01 && (bb.max[1] - 20.0).abs() < 0.01 && (bb.max[2] - 16.0).abs() < 0.01,
        "the .brep did not read back as the plate with its pin",
    )?;

    // SVG over the kernel: the solid's own wireframe, no scene involved.
    let solid_svg_text = rounded.svg_text(&SvgOptions::default()).map_err(e)?;
    check(solid_svg_text.starts_with("<svg") && solid_svg_text.contains("<path"), "solid SVG text did not look like an SVG wireframe")?;
    let solid_svg_path = std::env::temp_dir().join("cadaclysm-smoke-rust-solid.svg");
    rounded.svg(&solid_svg_path, &SvgOptions::default()).map_err(e)?;
    check(std::fs::metadata(&solid_svg_path).is_ok_and(|m| m.len() > 0), "Solid::svg wrote an empty file")?;
    let bad_fov = SvgOptions { fov: 200.0, ..Default::default() };
    check(rounded.svg_text(&bad_fov).is_err(), "blacksmith svg: fov=200 was accepted")?;
    println!("blacksmith svg: solid text, file written, fov=200 refused");

    // And back into the kernel: the read body's brep, shared rather than copied, as a
    // solid that outlives the scene it came from.
    let body = back
        .placements()
        .into_iter()
        .map(|p| p.geometry())
        .find(|node| node.brep().is_some())
        .ok_or("no placement of the read-back STEP has a brep")?;
    let read = body.brep().ok_or("the brep went away")?.manifold().map_err(e)?;
    check(read.is_closed && read.faces == 15, &format!("the read body is not the closed manifold written: {read:?}"))?;
    let imported = Solid::from_node(&body, true).map_err(|err| format!("from_node: {err}"))?;
    drop(back);
    check(imported.faces().map_err(e)? == faces, "from_node lost faces")?;
    let opened = Solid::open(&step, None).map_err(|err| format!("open: {err}"))?;
    check(opened.faces().map_err(e)? == faces, "Solid::open lost faces")?;
    check(Solid::open(&step, Some(1)).is_err(), "Solid::open found a second body in a one-body file")?;
    println!("from_node: {faces} faces after the scene closed; open: the same");

    // to_scene is the same round trip in memory.
    let (_, own_max) = rounded.bounds().map_err(e)?;
    let scene = rounded.to_scene(None).map_err(e)?;
    drop(rounded);
    let seen = scene.bounds();
    check(
        (0..3).all(|i| (f64::from(seen.max[i]) - own_max[i]).abs() < 0.05),
        &format!("to_scene's bounds {:?} are not the solid's {own_max:?}", seen.max),
    )?;

    // Split by a plane across the plate's length: two bodies, front first.
    let halves = plate.split_by_plane(&Frame::yz([0.0; 3]), DEFAULT_TOLERANCE).map_err(e)?;
    check(halves.len() == 2, &format!("split_by_plane gave {} bodies, not 2", halves.len()))?;
    println!("kernel: OK");
    Ok(())
}

fn sheet_verbs(plate: &Solid) -> Result<(), String> {
    let e = |e: cadaclysm_sdk::Error| format!("sheet verbs: {e}");
    let count = |s: &Solid| s.faces().map_err(e);
    let xy = Frame::xy([0.0; 3]);
    let square = Profile::rect(20.0, 20.0).map_err(e)?;
    let sheet = Solid::face(&square, &xy).map_err(e)?;
    let peg = Solid::extrude(&Profile::circle(4.0).map_err(e)?, &Frame::xy([0.0, 0.0, -6.0]), 12.0).map_err(e)?;
    let holed = sheet.trim(&peg, Keep::Outside, DEFAULT_TOLERANCE).map_err(e)?;
    let disc = sheet.trim(&peg, Keep::Inside, DEFAULT_TOLERANCE).map_err(e)?;
    let top = plate.select_face(&Selector::Max(Axis::Z)).map_err(e)?;
    let lid = plate.face_sheet(top).map_err(e)?;
    let walls = plate.drop_faces(&[0, 1]).map_err(e)?;
    let slab = Solid::extrude(&square.round(2.0, None, false).map_err(e)?, &xy, 1.0).map_err(e)?;
    let wave = Outline::begin([0.0, 0.0]).and_then(|p| p.bezier_to([20.0, 0.0], [20.0, 20.0], [40.0, 10.0])).and_then(|p| p.end_open()).map_err(e)?;
    let along = SweepPath::along(&wave, &xy, 0.01, true).map_err(e)?;
    let tube = Solid::sweep(&Profile::circle(1.0).map_err(e)?, &Frame::yz([0.0; 3]), &along).map_err(e)?;
    let on_plane = Workplane::xy().face(&square).and_then(|w| w.solid()).map_err(e)?;
    check(
        count(&sheet)? == 1
            && count(&holed)? >= 1
            && count(&disc)? >= 1
            && count(&lid)? == 1
            && count(&walls)? == count(plate)? - 2
            && count(&slab)? == 10
            && tube.is_watertight(DEFAULT_TOLERANCE).map_err(e)?
            && count(&on_plane)? == 1,
        "sheet verbs: a count is wrong",
    )?;
    let away = peg.translate(100.0, 0.0, 0.0).map_err(e)?;
    let refused = sheet.trim(&away, Keep::Inside, DEFAULT_TOLERANCE).err().map(|err| err.to_string()).unwrap_or_default();
    check(refused.contains("trim: nothing of the sheet lies inside the tool"), &format!("a trim with nothing inside: {refused:?}"))?;

    // Chain: an L's two sides, the second drawn back to front -- open, two walls; closed,
    // a triangle's three.
    let side_a = Outline::begin([0.0, 0.0]).and_then(|p| p.line_to(10.0, 0.0)).and_then(|p| p.end_open()).map_err(e)?;
    let side_b = Outline::begin([10.0, 8.0]).and_then(|p| p.line_to(10.0, 0.0)).and_then(|p| p.end_open()).map_err(e)?;
    let ell = Profile::chain(&[&side_a, &side_b], 1e-6).map_err(e)?;
    check(count(&Solid::extrude_open(&ell, &xy, 2.0).map_err(e)?)? == 2, "chain: an L extruded open is not two walls")?;
    check(count(&Solid::extrude_open(&ell.close_loop().map_err(e)?, &xy, 2.0).map_err(e)?)? == 3, "close_loop: not three walls")?;

    // A pipe along a line and a quarter turn: one watertight tube.
    let bend = SweepPath::at([0.0; 3])
        .and_then(|p| p.line_to([0.0, 0.0, 10.0]))
        .and_then(|p| p.arc([5.0, 0.0, 10.0], [0.0, 1.0, 0.0], std::f64::consts::FRAC_PI_2))
        .map_err(e)?;
    check(Solid::pipe(&bend, 1.0, 0.2).map_err(e)?.is_watertight(DEFAULT_TOLERANCE).map_err(e)?, "the pipe leaks")?;

    // The library reads a fixed count of weights: a wrong count is refused, not read past.
    let corners = [[0.0, 0.0], [10.0, 0.0], [10.0, 10.0], [0.0, 10.0]];
    let (control, knots) = ([[5.0, 5.0], [10.0, 0.0]], [0.0, 0.0, 0.0, 1.0, 1.0, 1.0]);
    Profile::spline(&corners, 3, Some(&[1.0, 2.0, 1.0, 1.0][..]), true).map_err(e)?;
    Outline::begin([0.0, 0.0]).and_then(|p| p.nurbs_to(&control, &knots, 2, Some(&[1.0, 0.5, 1.0][..]))).and_then(|p| p.end_open()).map_err(e)?;
    let refused = |r: cadaclysm_sdk::Result<Profile>| r.err().map(|err| err.to_string()).unwrap_or_default();
    let short = refused(Profile::spline(&corners, 3, Some(&[1.0, 1.0][..]), true));
    check(short == "spline: 2 weights for 4 points; give one per point", &format!("a short weight list: {short:?}"))?;
    let short = refused(Outline::begin([0.0, 0.0]).and_then(|p| p.nurbs_to(&control, &knots, 2, Some(&[1.0, 1.0][..]))).and_then(|p| p.end_open()));
    check(short == "nurbs_to: 2 weights for 3 control points (the current point and 2 given); give one per point", &format!("a short weight list: {short:?}"))?;
    Ok(())
}

fn frames() -> Result<(), String> {
    let e = |e: cadaclysm_sdk::Error| format!("frames: {e}");
    let lid = Solid::extrude(&Profile::rect(30.0, 30.0).map_err(e)?, &Frame::xy([0.0, 0.0, 20.0]), 2.0).map_err(e)?;
    let (low, high) = lid.bounds().map_err(e)?;
    check((low[2] - 20.0).abs() < 1e-9 && (high[2] - 22.0).abs() < 1e-9, "Frame::xy did not lift the lid to z = 20")?;
    let boss = Solid::extrude(&Profile::circle(6.0).map_err(e)?, &Frame::at([10.0, 0.0, 0.0], [1.0, 1.0, 0.0], None).map_err(e)?, 4.0)
        .map_err(e)?;
    check(boss.is_watertight(DEFAULT_TOLERANCE).map_err(e)?, "a boss on a slanted frame leaks")?;
    let face = lid.select_face(&Selector::Max(Axis::Z)).map_err(e)?;
    let on_top = lid.face_frame(face).map_err(e)?;
    check(on_top.z() == [0.0, 0.0, 1.0] && (on_top.origin()[2] - 22.0).abs() < 1e-9, "the lid's top frame is wrong")?;
    check(
        Frame::new([0.0; 3], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, -1.0]).is_err(),
        "a left-handed frame was accepted",
    )?;
    Ok(())
}

fn save_checks(scene: &Scene) -> Result<(), String> {
    let e = |e: cadaclysm_sdk::Error| e.to_string();
    let formats = cadaclysm_sdk::mesh_formats().map_err(e)?;
    check(formats.iter().any(|f| f.name == "stl"), "stl is not among the mesh formats")?;

    let stl = std::env::temp_dir().join("cadaclysm-smoke-rust.stl");
    let root = scene.roots().into_iter().next().ok_or("the scene has no root nodes to save a mesh from")?;
    root.save_mesh(&stl, "stl").map_err(e)?;
    let size = std::fs::metadata(&stl).map_err(|err| err.to_string())?.len();
    check(size >= 84, "save_mesh wrote no triangles")?;
    check(root.save_mesh(&stl, "no-such-format").is_err(), "save_mesh accepted an unknown format")?;

    let glb = std::env::temp_dir().join("cadaclysm-smoke-rust.glb");
    scene.save(&glb, "glb").map_err(e)?;
    let head = std::fs::read(&glb).map_err(|err| err.to_string())?;
    check(head.starts_with(b"glTF"), "save wrote something that is not a binary glTF")?;
    Ok(())
}
