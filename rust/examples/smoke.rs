//! Open one file through the Rust binding and check what comes back, then build a part
//! through the kernel, write it as STEP and read it back through the reader. The exit
//! code is the verdict: the release pipeline runs this against every library it ships,
//! as it runs the C#, Go, Java and Node smokes.
//!
//!     cargo run --example smoke -- samples/cube.scad [cadaclysm.lic]

use std::path::Path;
use std::process::ExitCode;

use cadaclysm_sdk::blacksmith::{
    self, Axis, Frame, Keep, Path as Outline, Profile, Selector, Solid, SweepPath, Unit, Workplane, DEFAULT_TOLERANCE,
    FILLET_TOLERANCE,
};
use cadaclysm_sdk::{Convention, OpenOptions, Scene};

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

    let scene = cadaclysm_sdk::open(&path).map_err(e)?;
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
