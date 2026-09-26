//! Open one file through the Rust binding and check what comes back, then build a part
//! through the kernel, write it as STEP and read it back through the reader. The exit
//! code is the verdict: the release pipeline runs this against every library it ships,
//! as it runs the C#, Go, Java and Node smokes.
//!
//!     cargo run --example smoke -- samples/cube.scad [cadaclysm.lic]

use std::path::Path;
use std::process::ExitCode;

use cadaclysm_sdk::blacksmith::{
    self, Assembly, Axis, Curve, Frame, Intersection, Keep, Path as Outline, Profile, Selector, Solid, SolidHits, SweepPath, Unit, Workplane,
    DEFAULT_TOLERANCE, FILLET_TOLERANCE,
};
use cadaclysm_sdk::{Convention, Link, Node, OpenOptions, Scene, SvgOptions};

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
        check(scene.links().is_empty() && scene.joints().is_empty(), "the cube has links or joints")?;
    }

    // The mechanism facts, from mechanism.stp beside the sample this smoke was given.
    mechanism_checks(&path)?;

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
        let beziers64 = first.edge_beziers64();
        check(
            beziers64.count() == beziers.count() && beziers64.points[0].map(|v| v as f32) == beziers.points[0],
            "edge_beziers64 does not agree with edge_beziers",
        )?;
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
        check(first.surface_edge_beziers().is_empty(), "the cube hands exact edges to the surface path")?;
        check(first.surface_pick([10.0, 10.0, 100.0], [10.0, 10.0, -100.0]).is_none() && first.bounds_placed(None).is_empty(), "the cube picks or bounds through surfaces")?;
        check(first.bounds_placed64(None).is_empty(), "the cube bounds_placed64 through surfaces")?;
        check(first.edge_colours().is_empty() && first.surface_edge_colours().is_empty(), "the unpainted cube has edge colours")?;
    }

    // Edge colours: samples/edge-colours.stp sits beside the given sample and paints one
    // edge teal (0.1, 0.6, 0.55) on the body -- everything else, edge and surface-edge
    // alike, stays unstyled.
    let edge_colours_path = Path::new(&path).with_file_name("edge-colours.stp");
    let edge_colours_scene = cadaclysm_sdk::open(&edge_colours_path).map_err(e)?;
    let body = edge_colours_scene.walk().find(|n| n.edges().polyline_count() > 0).ok_or("no edged body in edge-colours.stp")?;
    for (count, colours) in [
        (body.edges().polyline_count(), body.edge_colours()),
        (body.surface_edges().polyline_count(), body.surface_edge_colours()),
    ] {
        check(colours.len() == count, "edge colours: entry count does not equal polyline count")?;
        let styled: Vec<_> = colours.iter().flatten().collect();
        check(styled.len() == 1, "edge colours: not exactly one styled entry")?;
        let c = styled[0];
        check(
            (c[0] - 0.1).abs() < 1e-6 && (c[1] - 0.6).abs() < 1e-6 && (c[2] - 0.55).abs() < 1e-6 && (c[3] - 1.0).abs() < 1e-6,
            "edge colours: the styled entry is not (0.1, 0.6, 0.55, 1.0)",
        )?;
    }
    drop(edge_colours_scene);

    // f64 twins: mesh64's counts and first position agree with mesh's, and bounds64's
    // max widens to bounds's, on both the node and the scene.
    let mesh64 = first.mesh64().ok_or("no mesh64 for the first meshable node")?;
    check(
        mesh64.vertex_count() == mesh.vertex_count() && mesh64.index_count() == mesh.index_count(),
        "mesh64's vertex/index counts do not equal mesh's",
    )?;
    check(
        mesh64.positions[0].map(|v| v as f32) == mesh.positions[0],
        "mesh64's first position narrowed to float does not equal mesh's first position",
    )?;
    let node_bounds64 = first.bounds64();
    check(node_bounds64.max.map(|v| v as f32) == first.bounds().max, "bounds64's max does not equal bounds's max widened")?;
    let scene_bounds64 = scene.bounds64();
    check(scene_bounds64.max.map(|v| v as f32) == bounds.max, "scene bounds64's max does not equal bounds's max widened")?;
    println!(
        "reader f64 twins: mesh64 {} triangles, bounds64 max {:?}",
        mesh64.triangle_count(),
        scene_bounds64.max
    );
    let fresh = cadaclysm_sdk::open(&path).map_err(e)?;
    let body = fresh.walk().find(|n| n.can_mesh()).ok_or("no meshable node")?;
    check(!body.is_meshed(), "a fresh scene is already meshed")?;
    check(fresh.realize_meshes(false) > 0 && body.is_meshed(), "realize_meshes(false) did not build")?;

    // A Rhino extrusion hands its exact edges to the surface path without meshing, in both
    // conventions: UNREAL goes through the decorator that maps every getter into the caller's
    // space. The fixture is the repository's, not an SDK checkout's, so this runs where found.
    let extrusions = Path::new(&path).parent().and_then(Path::parent).map(|root| root.join("crates/cadaclysm-acis/tests/fixtures/rhino/extrusion-objects.3dm"));
    if let Some(extrusions) = extrusions.filter(|p| p.exists()) {
        for convention in [Convention::Native, Convention::Unreal] {
            let scene = OpenOptions::new().convention(convention).open(&extrusions).map_err(e)?;
            let mut found = 0;
            for node in scene.walk().filter(|n| n.can_mesh() && !n.surface_edges().is_empty()) {
                let exact = node.surface_edge_beziers().count();
                check(exact > 0 && !node.is_meshed(), "an extrusion's exact edges are not free")?;
                check(exact == node.edge_beziers().count(), "surface_edge_beziers is not edge_beziers' segments")?;
                found += 1;
            }
            check(found > 0, "extrusion-objects.3dm has no surfaced extrusion")?;
            println!("surface_edge_beziers ({convention:?}): {found} extrusions, exact and unmeshed");
        }
    }
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
    fem_reader(&scene, is_cube)?;
    if is_cube {
        fem_census_wiring(&Path::new(&path).with_file_name("open-sheet.scad"))?;
    }

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

    // Intersect: two equal pipes crossing at right angles meet on ellipse chains whose points
    // lie on both pipes; apart, nothing; a zero tolerance refused in the kernel's words. Two
    // coaxial pipes overlapping in height share a wall band: an overlap whose rings lie on it.
    let tol = 1e-3;
    let off_a = |p: [f64; 3]| ((p[0] * p[0] + p[1] * p[1]).sqrt() - 1.0).abs();
    let off_b = |p: [f64; 3]| ((p[0] * p[0] + (p[2] - 3.0) * (p[2] - 3.0)).sqrt() - 1.0).abs();
    let pipe_a = Solid::cylinder(1.0, 6.0).map_err(e)?;
    let pipe_b = Solid::cylinder(1.0, 6.0).map_err(e)?.rotate(&[[0.0, 0.0, 3.0], [1.0, 0.0, 0.0]], std::f64::consts::FRAC_PI_2).map_err(e)?;
    let found: Intersection = pipe_a.intersect(&pipe_b, tol).map_err(e)?;
    check(found.chains.len() >= 2 && found.overlaps.is_empty(), &format!("intersect: the crossed pipes read {found:?}"))?;
    let (faces_a, faces_b) = (pipe_a.faces().map_err(e)?, pipe_b.faces().map_err(e)?);
    let mut ellipses = 0;
    for c in &found.chains {
        check(c.faces.0 < faces_a && c.faces.1 < faces_b && c.points.len() >= 2, &format!("intersect: a chain reads {c:?}"))?;
        check(c.points.iter().all(|&p| off_a(p) < 50.0 * tol && off_b(p) < 50.0 * tol), &format!("intersect: a chain leaves the pipes: {c:?}"))?;
        let Some(curve) = &c.curve else { continue };
        check(curve.kind == "ellipse" || curve.kind == "nurbs", &format!("intersect: a chain's curve reads {curve:?}"))?;
        if curve.kind != "ellipse" {
            continue;
        }
        ellipses += 1;
        let t = (curve.t0 + curve.t1) / 2.0;
        let q = std::array::from_fn(|k| curve.origin[k] + curve.x[k] * curve.radius * t.cos() + curve.y[k] * curve.radius2 * t.sin());
        check(off_a(q) < 50.0 * tol && off_b(q) < 50.0 * tol, &format!("intersect: the ellipse leaves the pipes at {curve:?}"))?;
    }
    check(ellipses > 0, "intersect: two equal pipes cross on ellipses")?;
    let apart = pipe_a.intersect(&pipe_b.translate(10.0, 0.0, 0.0).map_err(e)?, DEFAULT_TOLERANCE).map_err(e)?;
    check(apart == Intersection::default(), &format!("intersect: pipes apart read {apart:?}"))?;
    match pipe_a.intersect(&pipe_b, 0.0) {
        Err(err) if err.to_string().contains("intersect: tolerance must be positive and finite") => {}
        other => return Err(format!("intersect: a zero tolerance was accepted or refused in other words: {other:?}")),
    }
    let lower = Solid::cylinder(1.0, 4.0).map_err(e)?;
    let upper = Solid::cylinder(1.0, 4.0).map_err(e)?.translate(0.0, 0.0, 2.0).map_err(e)?;
    let shared = lower.intersect(&upper, tol).map_err(e)?;
    check(!shared.overlaps.is_empty() && !shared.overlaps[0].loops.is_empty(), &format!("intersect: the coaxial pipes read {shared:?}"))?;
    for ring in &shared.overlaps[0].loops {
        check(
            ring.len() >= 3 && ring.iter().all(|&p| off_a(p) < 50.0 * tol && (2.0 - 50.0 * tol..=4.0 + 50.0 * tol).contains(&p[2])),
            &format!("intersect: an overlap ring leaves the shared band: {ring:?}"),
        )?;
    }
    println!(
        "intersect: {} chains ({ellipses} ellipses), {} overlaps; coaxial: faces {:?}, {} rings",
        found.chains.len(),
        found.overlaps.len(),
        shared.overlaps[0].faces,
        shared.overlaps[0].loops.len()
    );

    // Solid x profile hits: a line through a cuboid pierces two faces and is cut into three
    // pieces, outside/inside/outside, the middle one spanning the box and sweeping; a loop no
    // hit cuts is one piece; an open sheet has no pieces; a zero tolerance refused verbatim.
    let xy = Frame::xy([0.0; 3]);
    let cuboid = Solid::cuboid(10.0, 20.0, 30.0).map_err(e)?;
    let line = Outline::begin([-20.0, 0.0]).and_then(|p| p.line_to(20.0, 0.0)).and_then(|p| p.end_open()).map_err(e)?;
    let found: SolidHits = cuboid.hits(&line, &xy, DEFAULT_TOLERANCE).map_err(e)?;
    check(found.hits.len() == 2 && found.pieces.len() == 3, &format!("solid hits: a line through a cuboid reads {:?} and {} pieces", found.hits, found.pieces.len()))?;
    for (h, x) in found.hits.iter().zip([-5.0, 5.0]) {
        check(
            !h.run && !h.touch && (h.start[0] - x).abs() < 0.05 && h.a_start.segment == 0 && h.a_start.face == blacksmith::NONE
                && h.b_start.face != blacksmith::NONE && h.b_start.u.is_finite() && h.b_start.v.is_finite(),
            &format!("solid hits: a hit reads {h:?}"),
        )?;
    }
    let p = &found.pieces;
    let spots: Vec<_> = p.iter().map(|q| (q.inside, q.start, q.end)).collect();
    check(!p[0].inside && p[1].inside && !p[2].inside, &format!("solid hits: the pieces read {spots:?}"))?;
    check(
        p[0].start.t == 0.0 && p[2].end.t == 1.0 && p[0].end.t == p[1].start.t && p[1].end.t == p[2].start.t,
        &format!("solid hits: the pieces do not run head to tail: {spots:?}"),
    )?;
    let (lo, hi) = Solid::extrude_open(&p[1].profile, &xy, 1.0).map_err(e)?.bounds().map_err(e)?;
    check((lo[0] + 5.0).abs() < 0.05 && (hi[0] - 5.0).abs() < 0.05, &format!("solid hits: the middle piece spans x {} .. {}, not the box", lo[0], hi[0]))?;
    SweepPath::along(&p[1].profile, &xy, DEFAULT_TOLERANCE, true).map_err(e)?;
    let far = cuboid.hits(&Profile::circle(1.0).map_err(e)?, &Frame::xy([100.0, 0.0, 0.0]), DEFAULT_TOLERANCE).map_err(e)?;
    check(far.hits.is_empty() && far.pieces.len() == 1 && !far.pieces[0].inside, "solid hits: a circle far off is not one outside piece")?;
    let flat = Solid::face(&Profile::rect(20.0, 20.0).map_err(e)?, &xy).map_err(e)?;
    let upright = Outline::begin([0.0, -20.0]).and_then(|p| p.line_to(0.0, 20.0)).and_then(|p| p.end_open()).map_err(e)?;
    let across = flat.hits(&upright, &Frame::xz([0.0; 3]), DEFAULT_TOLERANCE).map_err(e)?;
    check(!across.hits.is_empty() && across.pieces.is_empty(), &format!("solid hits: a line across a sheet reads {:?}, {} pieces", across.hits, across.pieces.len()))?;
    match cuboid.hits(&line, &xy, 0.0) {
        Err(err) if err.to_string() == "solid_profile_hits: tolerance must be positive and finite" => {}
        other => return Err(format!("solid hits: a zero tolerance was accepted or refused in other words: {:?}", other.map(|f| f.hits))),
    }
    println!("solid hits: {} hits, {} pieces; the middle {:?}", found.hits.len(), found.pieces.len(), spots[1]);

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
    assemblies()?;

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

    // Edge colour: the plate's edges gold, edge 0 blue -- an edge's own colour wins over
    // the all-edges one, and a plain read-back tells "no colour" from "a coloured edge".
    let plate_gold_edges = plate.edges_coloured([0.8, 0.6, 0.4], None).map_err(e)?;
    let mut plate_edges = plate_gold_edges.edges_coloured([0.2, 0.4, 1.0], Some(&[0])).map_err(e)?;
    let edge0 = plate_edges.edge_colour(0).map_err(e)?;
    let edge1 = plate_edges.edge_colour(1).map_err(e)?;
    println!("edge0={edge0:?} edge1={edge1:?}");
    check(edge0 == Some([0.2, 0.4, 1.0]), "edge 0 did not take its own picked colour")?;
    check(edge1 == Some([0.8, 0.6, 0.4]), "edge 1 did not take the all-edges colour")?;
    let edge_polyline_colours = plate_edges.edge_polyline_colours(0.05).map_err(e)?;
    check(!edge_polyline_colours.is_empty(), "edge_polyline_colours was empty on a solid with edge paint")?;
    let profile_colour = Profile::rect(10.0, 4.0).map_err(e)?.coloured([0.8, 0.6, 0.4]).map_err(e)?.colour().map_err(e)?;
    check(profile_colour == Some([0.8, 0.6, 0.4]), "the profile did not keep its own colour")?;
    check(plate.edge_colour(0).map_err(e)?.is_none(), "plate itself should not have gained an edge colour")?;
    // An empty edge list colours no edge -- only a null list (`None`) colours every edge.
    let none_coloured = Solid::cuboid(1.0, 1.0, 1.0).map_err(e)?.edges_coloured([0.8, 0.6, 0.4], Some(&[])).map_err(e)?;
    check(none_coloured.edge_colour(0).map_err(e)?.is_none(), "an empty edge list coloured edge 0")?;

    // A face: the outline as a sheet, which pushed out is the plate again.
    let sheet = Solid::face(&outline, &Frame::xy([0.0; 3])).map_err(e)?;
    let pushed = sheet.extrude_faces(6.0).map_err(e)?;
    check(
        sheet.faces().map_err(e)? == 1
            && pushed.faces().map_err(e)? == plate.faces().map_err(e)?
            && pushed.is_watertight(DEFAULT_TOLERANCE).map_err(e)?,
        "the outline's face did not push out to the plate",
    )?;

    // The kernel's FEM mesh: the closed filleted part, and the sheet whose rim is open.
    fem_kernel(&rounded, &sheet)?;

    // The mesh borrows the solid's cache; meshing again needs the borrow to have ended,
    // which the compiler enforces -- here the two meshes are taken one after the other.
    let coarse = rounded.mesh(0.5).map_err(e)?.triangle_count();
    let mesh = rounded.mesh(0.05).map_err(e)?;
    let fine = mesh.triangle_count();
    check(mesh.normals.is_some_and(|n| n.len() == mesh.positions.len()), "the kernel mesh has no normals")?;
    check(mesh.indices.iter().all(|&i| (i as usize) < mesh.positions.len()), "a kernel index points past the vertices")?;
    check(fine > coarse, "a finer tolerance did not mesh finer")?;

    // f64 twins: mesh64(0.05) shares mesh(0.05)'s counts and first position narrowed;
    // bounds64(0.05) is the same box as bounds(0.05) (both close to the origin here).
    let (mesh_vertex_count, mesh_index_count, mesh_first) = (mesh.vertex_count(), mesh.index_count(), mesh.positions[0]);
    let mesh64 = rounded.mesh64(0.05).map_err(e)?;
    let (mesh64_vertex_count, mesh64_index_count, mesh64_first, mesh64_triangles) =
        (mesh64.vertex_count(), mesh64.index_count(), mesh64.positions[0], mesh64.triangle_count());
    check(
        mesh64_vertex_count == mesh_vertex_count && mesh64_index_count == mesh_index_count,
        "blacksmith mesh64(0.05)'s counts do not equal mesh(0.05)'s",
    )?;
    check(mesh64_first.map(|v| v as f32) == mesh_first, "blacksmith mesh64's first position narrowed does not equal mesh's")?;
    let (lo64, hi64) = rounded.bounds_at64(0.05).map_err(e)?;
    let (lo32, hi32) = rounded.bounds_at(0.05).map_err(e)?;
    check(
        (0..3).all(|i| (lo64[i] - lo32[i]).abs() < 1e-6 && (hi64[i] - hi32[i]).abs() < 1e-6),
        "blacksmith bounds64(0.05) does not equal bounds(0.05)",
    )?;
    println!("blacksmith f64 twins: mesh64 {mesh64_triangles} triangles, bounds64 max {hi64:?}");

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
    fem_brep(&back)?;
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

    // A profile's own plane, top by default -- pinned against an explicit iso call, not
    // just checked non-empty, so a silently-iso default would fail this.
    let profile_svg_top = outline.svg_text(None).map_err(e)?;
    check(profile_svg_top.starts_with("<svg") && profile_svg_top.contains("<path"), "profile SVG text did not look like an SVG wireframe")?;
    let profile_svg_path = std::env::temp_dir().join("cadaclysm-smoke-rust-profile.svg");
    outline.svg(&profile_svg_path, None).map_err(e)?;
    check(std::fs::metadata(&profile_svg_path).is_ok_and(|m| m.len() > 0), "Profile::svg wrote an empty file")?;
    let profile_svg_iso = outline.svg_text(Some(&SvgOptions::default())).map_err(e)?;
    check(profile_svg_top != profile_svg_iso, "Profile::svg_text did not default to the top view")?;
    println!("blacksmith svg: profile text, file written, top default confirmed against iso");

    // The widened pair: a solid and a profile drawn together, one call, both group ids.
    let mixed = blacksmith::svg_text_of(&[&rounded], &[&outline], &SvgOptions::default()).map_err(e)?;
    check(
        mixed.contains("<path") && mixed.contains("id=\"solid-0\"") && mixed.contains("id=\"profile-0\""),
        "the mixed drawing did not contain both group ids",
    )?;
    let mixed_path = std::env::temp_dir().join("cadaclysm-smoke-rust-mixed.svg");
    blacksmith::svg_of(&mixed_path, &[&rounded], &[&outline], &SvgOptions::default()).map_err(e)?;
    check(std::fs::metadata(&mixed_path).is_ok_and(|m| m.len() > 0), "svg_of wrote an empty file")?;
    println!("blacksmith svg: solid and profile drawn together, both group ids present");

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

    // Scaled: every length times factor, exactly; a non-positive or non-finite factor is refused.
    let big = Solid::cuboid(1.0, 2.0, 3.0).map_err(e)?.scaled(2.0).map_err(e)?;
    let (lo, hi) = big.bounds().map_err(e)?;
    check(
        (hi[0] - lo[0] - 2.0).abs() < 1e-9 && (hi[2] - lo[2] - 6.0).abs() < 1e-9,
        "scaled bounds",
    )?;
    check(
        big.scaled(0.0).unwrap_err().to_string().starts_with("scaled:"),
        "scaled(0) not refused",
    )?;

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

    // A five-pointed star: ten walls and two caps.
    let star = Solid::extrude(&Profile::star([0.0, 0.0], 10.0, 4.0, 5, 0.0).map_err(e)?, &xy, 2.0).map_err(e)?;
    check(count(&star)? == 12 && star.is_watertight(DEFAULT_TOLERANCE).map_err(e)?, "star: not twelve watertight faces")?;

    // Text: an `i` is two shapes and an `o` one; the `o` extrudes to a watertight ring with spline edges.
    let word = Profile::text("io", 10.0, "", "left", "baseline", 1.0, "ltr", None).map_err(e)?;
    let text_ring = Solid::extrude(&word[2], &xy, 2.0).map_err(e)?;
    let spline = text_ring.edges().map_err(e)?.iter().any(|edge| edge.kind == "nurbs");
    check(word.len() == 3 && spline && text_ring.is_watertight(DEFAULT_TOLERANCE).map_err(e)?, "text: not three shapes with a spline-edged ring")?;

    // A reflector: the parabola from rim to rim, closed and revolved -- watertight.
    let dish = Outline::parabola([0.0, 0.0], [0.0, 1.0], 20.0, 0.0, 50.0)
        .and_then(|p| p.line_to(0.0, 31.25))
        .and_then(|p| p.line_to(0.0, 0.0))
        .and_then(|p| p.end())
        .map_err(e)?;
    let bowl = Solid::revolve_in_plane(&dish, &xy, [0.0, 0.0], [0.0, 1.0], std::f64::consts::TAU).map_err(e)?;
    check(bowl.is_watertight(DEFAULT_TOLERANCE).map_err(e)?, "parabola: the bowl leaks")?;
    // A conic with a quarter circle's weight; a control point on the chord and a
    // hyperbola's weight not over 1 are refused.
    let quarter = Outline::begin([10.0, 0.0])
        .and_then(|p| p.conic_to(0.0, 10.0, [10.0, 10.0], std::f64::consts::FRAC_PI_4.cos()))
        .and_then(|p| p.line_to(0.0, 0.0))
        .and_then(|p| p.line_to(10.0, 0.0))
        .and_then(|p| p.end())
        .map_err(e)?;
    check(count(&Solid::extrude(&quarter, &xy, 2.0).map_err(e)?)? == 5, "conic_to: a quarter circle's box is not five faces")?;
    // The dish's own arc by vertex, closed by a second parabola through the same rim points
    // with a focus beyond the chord -- the arch over the top, not the dish again (a focus at
    // (0, 20) would rebuild the identical arc and retrace it).
    let arch = Outline::begin([-50.0, 31.25])
        .and_then(|p| p.parabola_by_vertex(50.0, 31.25, [0.0, 0.0]))
        .and_then(|p| p.parabola_by_focus(-50.0, 31.25, [0.0, 40.0]))
        .and_then(|p| p.end())
        .map_err(e)?;
    check(Solid::extrude(&arch, &xy, 2.0).map_err(e)?.is_watertight(DEFAULT_TOLERANCE).map_err(e)?, "parabola_by_vertex/focus: the arch leaks")?;
    // A parabola by its end tangents, and a hyperbola at weight 2: one wall and a floor each.
    let bump = Outline::begin([0.0, 0.0]).and_then(|p| p.parabola_to(10.0, 0.0, [5.0, 5.0])).and_then(|p| p.line_to(0.0, 0.0)).and_then(|p| p.end()).map_err(e)?;
    check(count(&Solid::extrude(&bump, &xy, 2.0).map_err(e)?)? == 4, "parabola_to: a bump is not four faces")?;
    let hump = Outline::begin([0.0, 0.0]).and_then(|p| p.hyperbola_to(10.0, 0.0, [5.0, 5.0], 2.0)).and_then(|p| p.line_to(0.0, 0.0)).and_then(|p| p.end()).map_err(e)?;
    check(count(&Solid::extrude(&hump, &xy, 2.0).map_err(e)?)? == 4, "hyperbola_to: a hump is not four faces")?;
    let refused_path = |r: cadaclysm_sdk::Result<Outline>| r.err().map(|err| err.to_string()).unwrap_or_default();
    let flat = refused_path(Outline::begin([0.0, 0.0]).and_then(|p| p.conic_to(2.0, 0.0, [1.0, 0.0], 1.0)));
    check(flat == "path_conic_to: the control point lies on the chord", &format!("a conic through its chord: {flat:?}"))?;
    let low = refused_path(Outline::begin([0.0, 0.0]).and_then(|p| p.hyperbola_to(2.0, 0.0, [1.0, 1.0], 1.0)));
    check(low == "hyperbola_to: the weight must be over 1 (1 is a parabola, under 1 an ellipse)", &format!("a hyperbola at weight 1: {low:?}"))?;

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

/// The mechanism facts, identical in every language: two links `base` and `arm`, each
/// naming one node of the same name; one joint `hinge` from `arm` (index 1) to `base`
/// (index 0). `mechanism.stp` sits beside whatever sample this smoke was given.
fn mechanism_checks(sample_path: &str) -> Result<(), String> {
    let e = |e: cadaclysm_sdk::Error| e.to_string();
    let samples = Path::new(sample_path).parent().unwrap_or_else(|| Path::new("."));
    let mechanism = cadaclysm_sdk::open(samples.join("mechanism.stp")).map_err(e)?;

    let links = mechanism.links();
    let names: Vec<String> = links.iter().map(Link::name).collect();
    check(names == ["base", "arm"], &format!("mechanism: link names are {names:?}, not [base, arm]"))?;
    for link in &links {
        let nodes = link.nodes();
        check(nodes.len() == 1 && nodes[0].name() == link.name(), &format!("mechanism: link {} does not name its one node", link.name()))?;
    }

    let joints = mechanism.joints();
    check(joints.len() == 1, &format!("mechanism: {} joints, not 1", joints.len()))?;
    let hinge = &joints[0];
    check(hinge.name() == "hinge", &format!("mechanism: joint name is {}, not hinge", hinge.name()))?;
    let (start, end) = (hinge.start(), hinge.end());
    check(
        start.name() == "arm" && start.index() == 1 && end.name() == "base" && end.index() == 0,
        &format!("mechanism: hinge runs {}({}) -> {}({}), not arm(1) -> base(0)", start.name(), start.index(), end.name(), end.index()),
    )?;
    println!("mechanism: links {names:?}, hinge {}({}) -> {}({})", start.name(), start.index(), end.name(), end.index());
    Ok(())
}

/// The eleven assembly facts spec §5 asserts, built as Python's `_shared_assembly()`
/// does: a bolt and a coloured plate, a bracket placing the plate once and the bolt
/// twice, and a top assembly placing the bracket twice (mirrored the second time) and
/// the bolt once more.
fn assemblies() -> Result<(), String> {
    let e = |e: cadaclysm_sdk::Error| format!("assemblies: {e}");
    let origin = |p: [f64; 3]| Frame::xy(p);

    let bolt = Solid::cylinder(1.0, 6.0).and_then(|s| s.named("bolt")).map_err(e)?;
    let plate = Solid::cuboid(20.0, 10.0, 2.0)
        .and_then(|s| s.named("plate"))
        .and_then(|s| s.coloured([1.0, 0.5, 0.0], None))
        .map_err(e)?;

    let bracket = Assembly::new("bracket").map_err(e)?;
    bracket.place_solid(&plate, &Frame::xy([0.0; 3]), None).map_err(e)?;
    let bolt_name_1 = bracket.place_solid(&bolt, &origin([5.0, 5.0, 2.0]), None).map_err(e)?;
    let bolt_name_2 = bracket.place_solid(&bolt, &origin([15.0, 5.0, 2.0]), None).map_err(e)?;
    check((bolt_name_1.as_str(), bolt_name_2.as_str()) == ("bolt", "bolt 2"), &format!("bracket's own bolts named {bolt_name_1:?}, {bolt_name_2:?}"))?;

    let mirrored = Frame::new([100.0, 0.0, 0.0], [0.0, 1.0, 0.0], [-1.0, 0.0, 0.0], [0.0, 0.0, 1.0]).map_err(e)?;
    let frame = Assembly::new("frame").map_err(e)?;
    let left = frame.place_assembly(&bracket, &Frame::xy([0.0; 3]), Some("left")).map_err(e)?;
    let right = frame.place_assembly(&bracket, &mirrored, Some("right")).map_err(e)?;
    let root_bolt = frame.place_solid(&bolt, &origin([50.0, 50.0, 0.0]), None).map_err(e)?;
    // Fact 1: the placement names, in placing order.
    check(
        (left.as_str(), right.as_str(), root_bolt.as_str()) == ("left", "right", "bolt"),
        &format!("placement names read {left:?}, {right:?}, {root_bolt:?}"),
    )?;

    // Fact 2 and 3: the STEP text's counts and the placement names it carries.
    let text = frame.step_text(None, Unit::Millimetre).map_err(e)?;
    let count = |needle: &str| text.matches(needle).count();
    check(
        count("=MANIFOLD_SOLID_BREP(") == 2 && count("=PRODUCT(") == 4 && count("=NEXT_ASSEMBLY_USAGE_OCCURRENCE(") == 6,
        &format!(
            "frame.step_text() has {} breps, {} products, {} NAUOs, not 2/4/6",
            count("=MANIFOLD_SOLID_BREP("),
            count("=PRODUCT("),
            count("=NEXT_ASSEMBLY_USAGE_OCCURRENCE(")
        ),
    )?;
    check(
        text.contains("'left'") && text.contains("'right'") && text.contains("'bolt 2'"),
        "frame.step_text() is missing 'left', 'right' or 'bolt 2'",
    )?;

    // Fact 11: read-back through the reader, at this pre-fact-4 text -- the root named
    // "frame" with three children: two "bracket" containers, each holding plate, bolt,
    // bolt, plus one bolt. Opened from the `text` already captured above (not a fresh
    // `step_text()`), since fact 4 below adds a bolt that would change the count.
    let readback = cadaclysm_sdk::open_memory(text.as_bytes(), "stp").map_err(e)?;
    let root = readback.roots().into_iter().next().ok_or("assemblies: to_scene's read-back has no root node")?;
    check(root.name() == "frame", &format!("the read-back root is named {:?}, not \"frame\"", root.name()))?;
    let children = root.children();
    check(children.len() == 3, &format!("the read-back root has {} children, not 3", children.len()))?;
    let brackets: Vec<_> = children.iter().filter(|c| c.name() == "bracket").collect();
    let root_bolts: Vec<_> = children.iter().filter(|c| c.name() == "bolt").collect();
    check(
        brackets.len() == 2 && root_bolts.len() == 1,
        &format!("the read-back root's children are named {:?}", children.iter().map(Node::name).collect::<Vec<_>>()),
    )?;
    for bracket_node in &brackets {
        let grandchildren = bracket_node.children();
        let names: Vec<String> = grandchildren.iter().map(Node::name).collect();
        let (plates, bolts) = (names.iter().filter(|n| n.as_str() == "plate").count(), names.iter().filter(|n| n.as_str() == "bolt").count());
        check(plates == 1 && bolts == 2, &format!("a read-back bracket holds {names:?}, not one plate and two bolts"))?;
    }
    drop(readback);

    // Fact 4: one more bolt into the bracket, then a fresh count of 7 NAUOs.
    bracket.place_solid(&bolt, &origin([5.0, 15.0, 2.0]), None).map_err(e)?;
    let text2 = frame.step_text(None, Unit::Millimetre).map_err(e)?;
    check(
        text2.matches("=NEXT_ASSEMBLY_USAGE_OCCURRENCE(").count() == 7,
        &format!("after one more bolt, step_text() has {} NAUOs, not 7", text2.matches("=NEXT_ASSEMBLY_USAGE_OCCURRENCE(").count()),
    )?;

    // Fact 5: a cycle is refused, naming it.
    let cycle = bracket.place_assembly(&frame, &Frame::xy([0.0; 3]), None);
    let cycle_message = cycle.err().map(|err| err.to_string()).unwrap_or_default();
    check(
        cycle_message.contains("bracket → frame → bracket"),
        &format!("placing frame into bracket did not name the cycle: {cycle_message:?}"),
    )?;

    // Fact 6: an explicit name already taken is refused.
    check(
        frame.place_assembly(&bracket, &Frame::xy([0.0; 3]), Some("left")).is_err(),
        "placing the bracket again as 'left' was accepted",
    )?;

    // Fact 7: a mirrored raw twelve-number frame is refused on handedness -- in the
    // library's own words, not `Frame::new`'s ("left-handed"). `Frame::of` would hit
    // that same check first, so this goes through `Frame::raw_unchecked` (doc-hidden,
    // for exactly this: handing the library a frame this crate would otherwise refuse
    // before it is ever sent).
    let raw_mirror = Frame::raw_unchecked([0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, -1.0]);
    let raw_message = frame.place_solid(&bolt, &raw_mirror, None).err().map(|err| err.to_string()).unwrap_or_default();
    check(
        raw_message.contains("right-handed and orthonormal"),
        &format!("a mirrored raw frame was not refused for handedness: {raw_message:?}"),
    )?;

    // Fact 8: an assembly that places nothing is refused at step_text().
    let empty = Assembly::new("x").map_err(e)?;
    check(empty.step_text(None, Unit::Millimetre).is_err(), "Assembly(\"x\").step_text() was accepted")?;

    // Fact 9: an outer assembly placing an empty sub-assembly is refused, naming it.
    let hollow = Assembly::new("hollow").map_err(e)?;
    let outer = Assembly::new("outer").map_err(e)?;
    outer.place_assembly(&hollow, &Frame::xy([0.0; 3]), None).map_err(e)?;
    let hollow_message = outer.step_text(None, Unit::Millimetre).err().map(|err| err.to_string()).unwrap_or_default();
    check(hollow_message.contains("hollow"), &format!("placing an empty sub-assembly did not name it: {hollow_message:?}"))?;

    // Fact 10: name rides through a one-source operation, is dropped by a two-source
    // one, and a fresh primitive has none.
    check(bolt.name().as_deref() == Some("bolt"), "bolt.name is not \"bolt\"")?;
    check(bolt.place(&Frame::xy([1.0, 2.0, 3.0])).map_err(e)?.name().as_deref() == Some("bolt"), "bolt.place(...).name did not keep \"bolt\"")?;
    check(bolt.coloured([0.2, 0.2, 0.2], None).map_err(e)?.name().as_deref() == Some("bolt"), "bolt.coloured(...).name did not keep \"bolt\"")?;
    let cube = Solid::cuboid(1.0, 1.0, 1.0).map_err(e)?;
    check(bolt.join(&cube, DEFAULT_TOLERANCE).map_err(e)?.name().is_none(), "bolt.join(cube).name is not None")?;
    check(Solid::cuboid(1.0, 1.0, 1.0).map_err(e)?.name().is_none(), "cuboid(1,1,1).name is not None")?;

    println!("assemblies: 11 facts checked (placement names, STEP counts, cycles, naming, read-back structure)");
    Ok(())
}

// ---- the FEM surface mesh ----------------------------------------------------------

/// A placement carrying **both a rotation and a translation**: a quarter turn about z,
/// then a move of 100 along x, as the sixteen column-major doubles
/// [`cadaclysm_sdk::Node::bounds_placed`] takes. Rows, as the textbooks write them:
///
/// ```text
/// [ 0 -1  0 100 ]
/// [ 1  0  0   0 ]
/// [ 0  0  1   0 ]
/// [ 0  0  0   1 ]
/// ```
///
/// Rust's placement is a **sized type** (`&[f64; 16]` here, `&Frame` on the kernel), so
/// the sixteen-versus-twelve confusion C# and Java check for at run time does not compile
/// and there is no refusal to assert. What replaces it is this: a translation alone catches
/// a placement dropped, doubled or transposed, but **not one composed in the wrong order**
/// -- translate-then-rotate and rotate-then-translate agree on every pure translation. With
/// the turn in it they disagree loudly: this maps the origin to (100, 0, 0) where the other
/// order maps it to (0, 100, 0), and a transposed rotation sends what should be +y to -y.
///
/// **A rotation only tells you something about a body that is not symmetric under it.**
/// Transposing the 3x3 block composes this transform with a 180-degree turn about z through
/// the placement's own origin, so a body whose centre lands on that axis maps onto itself and
/// the check sees nothing -- which every `Solid::cuboid` does, being centred where it is built.
///
/// **What the body needs is a centre off the rotation's axis, in the plane the rotation acts
/// in.** This turn is about z, so it is the centre's **x or y** that must be non-zero; a z
/// offset lies along the axis and buys nothing whatever. Measured: with the transpose applied
/// and the kernel cuboid moved to (0, 0, 5) -- off the literal origin, but purely along the
/// axis -- the smoke still passes at exit 0. So "move the body off the origin" is the wrong
/// rule to copy; "off the rotation's axis, in the plane it turns in" is the right one. See
/// `fem_kernel`, which is where the trap bites.
const TURNED: [f64; 16] = [
    0.0, 1.0, 0.0, 0.0, // column 0: where x goes
    -1.0, 0.0, 0.0, 0.0, // column 1: where y goes
    0.0, 0.0, 1.0, 0.0, // column 2: where z goes
    100.0, 0.0, 0.0, 1.0, // column 3: the translation
];

/// Where [`TURNED`] puts a point: `(x, y, z)` -> `(100 - y, x, z)`. The kernel's
/// [`turned_frame`] is the same transform written the kernel's way, so both sides of the
/// ABI are checked against this one map -- which is what makes the sixteen-versus-twelve
/// asymmetry a thing the smoke proves rather than a thing it only says.
fn turned(p: [f64; 3]) -> [f64; 3] {
    [100.0 - p[1], p[0], p[2]]
}

/// [`TURNED`] as the kernel's **twelve** numbers: an origin and the three axes x, y and z
/// go to. `Frame::new` checks them, so a left-handed or skewed mistake here never reaches
/// the library.
fn turned_frame() -> Result<Frame, String> {
    Frame::new([100.0, 0.0, 0.0], [0.0, 1.0, 0.0], [-1.0, 0.0, 0.0], [0.0, 0.0, 1.0])
        .map_err(|err| format!("fem: the turned frame: {err}"))
}

fn near(a: [f64; 3], b: [f64; 3]) -> bool {
    (0..3).all(|i| (a[i] - b[i]).abs() < 1e-9)
}

/// The box a set of nodes fills, for comparing a placed mesh against a hand-computed one.
fn span(nodes: &[[f64; 3]]) -> ([f64; 3], [f64; 3]) {
    let mut lo = [f64::INFINITY; 3];
    let mut hi = [f64::NEG_INFINITY; 3];
    for p in nodes {
        for i in 0..3 {
            lo[i] = lo[i].min(p[i]);
            hi[i] = hi[i].max(p[i]);
        }
    }
    (lo, hi)
}

/// The eight corners of a box, for the placement checks: every one of them is a B-rep
/// vertex of a cuboid and so a node of its FEM mesh.
fn corners(lo: [f64; 3], hi: [f64; 3]) -> Vec<[f64; 3]> {
    let mut out = Vec::new();
    for x in [lo[0], hi[0]] {
        for y in [lo[1], hi[1]] {
            for z in [lo[2], hi[2]] {
                out.push([x, y, z]);
            }
        }
    }
    out
}

/// Checks that hold of any FEM mesh, whichever side of the ABI built it: the five flat
/// arrays agree with each other and with the counts, every index is in range, and every
/// `node_entity` is bounded by the list its own `node_kind` names -- which is what tells
/// the two arrays apart if they were ever read from one pointer.
fn fem_arrays(
    nodes: &[[f64; 3]],
    triangles: &[[u32; 3]],
    triangle_face: &[u32],
    node_kind: &[u32],
    node_entity: &[u32],
    face_count: u32,
    edge_count: usize,
    vertex_count: usize,
    what: &str,
) -> Result<(), String> {
    check(!nodes.is_empty() && !triangles.is_empty(), &format!("{what}: an empty mesh came back as success"))?;
    check(
        triangle_face.len() == triangles.len() && node_kind.len() == nodes.len() && node_entity.len() == nodes.len(),
        &format!(
            "{what}: the arrays disagree -- {} nodes, {} triangles, {} triangle_face, {} node_kind, {} node_entity",
            nodes.len(),
            triangles.len(),
            triangle_face.len(),
            node_kind.len(),
            node_entity.len()
        ),
    )?;
    check(
        triangles.iter().flatten().all(|&i| (i as usize) < nodes.len()),
        &format!("{what}: a triangle index points past the nodes"),
    )?;
    check(
        triangle_face.iter().all(|&f| f < face_count),
        &format!("{what}: a triangle_face is not one of the body's {face_count} faces"),
    )?;
    for (i, (&kind, &entity)) in node_kind.iter().zip(node_entity).enumerate() {
        let bound = match kind {
            0 => vertex_count,
            1 => edge_count,
            2 => face_count as usize,
            other => return Err(format!("{what}: node {i} has kind {other}, which is neither vertex, edge nor face")),
        };
        check(
            (entity as usize) < bound,
            &format!("{what}: node {i} is on entity {entity} of kind {kind}, which has only {bound}"),
        )?;
    }
    Ok(())
}

/// **Which count feeds which entry point** -- the census *wiring*, which nothing else here
/// pins. Every other FEM check proves a row is extracted correctly; none proves
/// [`FemMesh::open_edges`] reads `open_edge_count` rows through `cadaclysm_fem_mesh_open_edge`
/// rather than the folded count or the folded call.
///
/// `samples/open-sheet.scad` is the only body in this repository where both censuses are
/// non-empty and of different lengths: the B-rep path computes no census unless the topology is
/// closed (the documented "not asked" pair) and every closed body has none, while the mesh path
/// always computes one -- so a `polyhedron` with a flap over one of its own directed edges is the
/// way in. Six cracks, one fold, and the fold is not the first crack.
fn fem_census_wiring(sheet: &Path) -> Result<(), String> {
    let e = |err: cadaclysm_sdk::Error| format!("fem census: {err}");
    let scene = cadaclysm_sdk::open(sheet).map_err(e)?;
    let node = scene.walk().find(|n| n.can_mesh()).ok_or("fem census: no meshable node")?;
    let mesh = node.fem_mesh(0.01, 0.0, None).map_err(e)?;
    check(
        mesh.nodes().len() == 5 && mesh.triangles().len() == 3 && mesh.from_mesh() && !mesh.watertight(),
        &format!("fem census: open-sheet.scad read {} nodes, {} triangles, watertight={}", mesh.nodes().len(), mesh.triangles().len(), mesh.watertight()),
    )?;
    let (cracks, folds) = (mesh.open_edges().map_err(e)?, mesh.folded_edges().map_err(e)?);
    // The counts are what separate the two lists: a swapped count reads 1 where 6 belongs, and a
    // swapped call cannot read row 1 of a one-row table at all.
    check(
        cracks.len() == 6 && folds.len() == 1,
        &format!("fem census: {} cracks and {} folds, not 6 and 1", cracks.len(), folds.len()),
    )?;
    // And the contents, which separates a wrapper that swapped both consistently.
    check(folds[0] == (2, 0, cadaclysm_sdk::NONE), &format!("fem census: the fold reads {:?}, not (2, 0, NONE)", folds[0]))?;
    check((cracks[0].0, cracks[0].1) == (1, 2), &format!("fem census: the first crack reads {:?}, not (1, 2, NONE)", cracks[0]))?;
    println!("fem census: open-sheet.scad reads {} cracks and {} fold at ({}, {})", cracks.len(), folds.len(), folds[0].0, folds[0].1);
    Ok(())
}

/// The reader's FEM mesh over a node with no B-rep: the **mesh-only** path, where
/// `from_mesh` is true, there are no edges and no vertices, and -- the trap the plan
/// names -- `fem_mesh_of_mesh` reads no options at all, so a tolerance or a size the
/// B-rep path refuses still comes back as a mesh.
fn fem_reader(scene: &Scene, is_cube: bool) -> Result<(), String> {
    let e = |err: cadaclysm_sdk::Error| format!("fem: {err}");
    let node = scene.walk().find(|n| n.can_mesh()).ok_or("fem: no meshable node")?;
    let mesh = node.fem_mesh(0.01, 0.0, None).map_err(e)?;

    let (nodes, triangles) = (mesh.nodes(), mesh.triangles());
    let edges = mesh.edges().map_err(e)?;
    let vertices = mesh.vertices().map_err(e)?;
    fem_arrays(
        nodes,
        triangles,
        mesh.triangle_face(),
        mesh.node_kind(),
        mesh.node_entity(),
        mesh.face_count(),
        edges.len(),
        vertices.len(),
        "fem reader",
    )?;
    // A mesh-only body: one face, every node on it, no topology at all -- and the census
    // does run over the welded triangles, so an empty one here means "nothing found".
    check(mesh.from_mesh(), "fem: a node with no brep did not report from_mesh")?;
    check(
        mesh.face_count() == 1 && edges.is_empty() && vertices.is_empty() && mesh.node_kind().iter().all(|&k| k == 2),
        "fem: a from_mesh body has edges, vertices or a node off face 0",
    )?;
    check(
        mesh.watertight() && mesh.open_edges().map_err(e)?.is_empty() && mesh.folded_edges().map_err(e)?.is_empty(),
        "fem: the cube's own mesh is not watertight with both censuses empty",
    )?;
    check(
        mesh.min_angle() > 0.0 && mesh.min_angle() <= 60.0 && (mesh.worst_triangle() as usize) < triangles.len() && mesh.longest_edge() > 0.0,
        &format!("fem: the quality figures read {} deg, triangle {}, longest {}", mesh.min_angle(), mesh.worst_triangle(), mesh.longest_edge()),
    )?;
    if is_cube {
        check(nodes.len() == 8 && triangles.len() == 12, &format!("fem: the cube meshed to {} nodes, {} triangles", nodes.len(), triangles.len()))?;
    }

    // The `.msh` text: on this side of the ABI it is borrowed from the handle, and the
    // wrapper copies it into a `String` on the way out -- so asking twice gives two
    // strings of the caller's own, and the second ask does not free the first.
    let text = mesh.msh_text().map_err(e)?;
    let again = mesh.msh_text().map_err(e)?;
    check(text.starts_with("$MeshFormat\n4.1 0 8\n"), &format!("fem: the .msh text does not open as Gmsh 4.1 ASCII: {:?}", &text[..text.len().min(40)]))?;
    check(again == text, "fem: two asks for the same mesh's .msh text disagree")?;
    let msh = std::env::temp_dir().join("cadaclysm-smoke-rust-fem.msh");
    mesh.save_msh(&msh).map_err(e)?;
    let written = std::fs::metadata(&msh).map_err(|err| format!("fem: {err}"))?.len();
    check(written as usize >= text.len() / 2, &format!("fem: save_msh wrote {written} bytes against {} of text", text.len()))?;
    println!("fem reader: {} nodes, {} triangles, from_mesh={}, {} bytes of .msh", nodes.len(), triangles.len(), mesh.from_mesh(), written);
    // Dropped by name, not left to the end of the block: a `Vec<FemEdge<'_>>` borrows the
    // mesh until it is dropped, so `free()` -- which takes the mesh by value -- does not
    // compile while one is still in scope. That refusal is this language's whole guard.
    drop(edges);
    drop(vertices);
    mesh.free();

    // The placement reaches the library, and in the right order. Catches: a placement
    // dropped (the nodes stay where the body is), applied twice, transposed (+y for -y),
    // or composed the other way round (the origin at (0, 100, 0), not (100, 0, 0)).
    //
    // This half needs no care about where the body sits: `cube.scad` spans 0..20 in x and y
    // rather than straddling the z axis the turn is about, so its corner set is not invariant
    // under the 180-degree turn a transposed 3x3 block composes in (see `TURNED`). The kernel
    // half has to move its cuboid for exactly that reason.
    //
    // Every node is checked rather than one convenient point, which is defence in depth
    // rather than what earns the catch: at either half's offset the two image spans are
    // already disjoint, so one point -- or the span check by itself -- catches a transpose
    // too. It is the offset that does the work, and a later reader keeping the loop while
    // centring the body would be blind again.
    let placed = node.fem_mesh(0.01, 0.0, Some(&TURNED)).map_err(e)?;
    let plain = node.fem_mesh(0.01, 0.0, None).map_err(e)?;
    check(placed.nodes().len() == plain.nodes().len(), "fem: the placement changed the node count")?;
    for p in plain.nodes() {
        let want = turned(*p);
        check(
            placed.nodes().iter().any(|q| near(*q, want)),
            &format!("fem: the placement did not send {p:?} to {want:?} -- the placed nodes span {:?}", span(placed.nodes())),
        )?;
    }
    let (lo, hi) = span(placed.nodes());
    let (plain_lo, plain_hi) = span(plain.nodes());
    check(
        near(lo, turned([plain_lo[0], plain_hi[1], plain_lo[2]])) && near(hi, turned([plain_hi[0], plain_lo[1], plain_hi[2]])),
        &format!("fem: the placed nodes span {lo:?}..{hi:?}, not the turn of {plain_lo:?}..{plain_hi:?}"),
    )?;
    println!("fem reader: the placement turns and moves {plain_lo:?}..{plain_hi:?} into {lo:?}..{hi:?}");
    placed.free();
    plain.free();

    // **Neither `tolerance` nor `max_size` is checked by this wrapper**, and the mesh-only
    // path reads neither: `fem_mesh_of_mesh` takes no options at all. Catches a wrapper
    // that validated either field itself -- which passes every Python-shaped test and is
    // wrong. The B-rep half of this contract is in `fem_brep`, where each of these *is*
    // refused, in the library's own words.
    for (tolerance, max_size) in [(0.0, 0.0), (-1.0, 0.0), (f64::NAN, 0.0), (0.01, -1.0), (0.01, f64::NAN), (0.01, f64::INFINITY)] {
        match node.fem_mesh(tolerance, max_size, None) {
            Ok(mesh) => check(
                !mesh.nodes().is_empty(),
                &format!("fem: tolerance {tolerance} max_size {max_size} came back as an empty mesh"),
            )?,
            Err(err) => return Err(format!("fem: tolerance {tolerance} max_size {max_size} was refused on the mesh-only path: {err}")),
        }
    }
    println!("fem reader: tolerance 0/-1/NaN and max_size -1/NaN/+Inf all mesh on the mesh-only path");
    Ok(())
}

/// The reader's FEM mesh over a node **with** a B-rep: the path that carries topology, and
/// the one that refuses a bad tolerance.
fn fem_brep(scene: &Scene) -> Result<(), String> {
    let e = |err: cadaclysm_sdk::Error| format!("fem brep: {err}");
    let node = scene
        .placements()
        .into_iter()
        .map(|p| p.geometry())
        .find(|node| node.brep().is_some())
        .ok_or("fem brep: no placement of the read-back STEP has a brep")?;
    let mesh = node.fem_mesh(0.05, 0.0, None).map_err(e)?;
    let edges = mesh.edges().map_err(e)?;
    let vertices = mesh.vertices().map_err(e)?;
    fem_arrays(
        mesh.nodes(),
        mesh.triangles(),
        mesh.triangle_face(),
        mesh.node_kind(),
        mesh.node_entity(),
        mesh.face_count(),
        edges.len(),
        vertices.len(),
        "fem brep",
    )?;
    // The other half of the `from_mesh` proof: this body has a brep, and `watertight` is
    // true for both bodies, so it is `from_mesh` that tells them apart rather than luck.
    check(!mesh.from_mesh(), "fem brep: a body with a brep reported from_mesh")?;
    check(mesh.face_count() == 15, &format!("fem brep: the filleted part read back as {} faces, not 15", mesh.face_count()))?;
    check(!edges.is_empty() && !vertices.is_empty(), "fem brep: a brep body has no edges or no vertices")?;
    check(
        (0..3).all(|k| mesh.node_kind().contains(&k)),
        &format!("fem brep: the nodes do not cover all three kinds: {:?}", mesh.node_kind().iter().take(8).collect::<Vec<_>>()),
    )?;

    // `id` is the **body's own** edge id, not the index. The ids ascend, and at least one
    // is not its own index -- which is what catches an `id` filled from the loop counter.
    check(edges.windows(2).all(|w| w[0].id < w[1].id), "fem brep: the edge ids do not ascend")?;
    check(
        edges.iter().enumerate().any(|(i, edge)| edge.id != i as u32),
        "fem brep: every edge id equals its own index -- id is the index, not the body's id",
    )?;
    for (i, edge) in edges.iter().enumerate() {
        check(edge.runs.first() == Some(&0), &format!("fem brep: edge {i}'s first run does not start at 0: {:?}", edge.runs))?;
        check(
            edge.runs.windows(2).all(|w| w[0] < w[1]) && edge.runs.iter().all(|&r| (r as usize) < edge.nodes.len()),
            &format!("fem brep: edge {i}'s runs {:?} do not ascend inside its {} nodes", edge.runs, edge.nodes.len()),
        )?;
        check(
            edge.nodes.iter().all(|&n| (n as usize) < mesh.nodes().len()),
            &format!("fem brep: edge {i} names a node past the mesh"),
        )?;
        // A closed body: every edge has two real faces, and neither is a sentinel.
        check(
            edge.faces.0 < mesh.face_count() && edge.faces.1 < mesh.face_count(),
            &format!("fem brep: edge {i} bounds faces {:?} of {}", edge.faces, mesh.face_count()),
        )?;
        check(!edge.closed || edge.runs.len() == 1, &format!("fem brep: edge {i} is closed with {} runs", edge.runs.len()))?;
        if edge.seam {
            check(edge.faces.0 == edge.faces.1, &format!("fem brep: edge {i} is a seam but bounds {:?}", edge.faces))?;
        }
        // The ends resolve through `vertices` to the chain's own first and last node --
        // which is what tells `ends` from `faces`, both a pair of u32 a swap leaves in range.
        let ends = [edge.ends.0, edge.ends.1].into_iter().filter(|&v| v != cadaclysm_sdk::NONE);
        for v in ends {
            let at = vertices.get(v as usize).ok_or_else(|| format!("fem brep: edge {i} ends at vertex {v} of {}", vertices.len()))?;
            if at.node != cadaclysm_sdk::NONE {
                check(
                    Some(&at.node) == edge.nodes.first() || Some(&at.node) == edge.nodes.last(),
                    &format!("fem brep: edge {i}'s end vertex {v} is node {} , which is neither end of its chain", at.node),
                )?;
            }
        }
    }
    check(vertices.iter().any(|v| v.has_position), "fem brep: no vertex has a position")?;
    check(
        vertices.iter().all(|v| v.has_position || v.point == [0.0; 3]),
        "fem brep: a vertex with no position carries a point that is not zeroed",
    )?;
    check(
        mesh.watertight() && mesh.open_edges().map_err(e)?.is_empty() && mesh.folded_edges().map_err(e)?.is_empty(),
        "fem brep: the closed filleted part is not watertight with both censuses empty",
    )?;
    println!(
        "fem brep: {} nodes, {} edges (edge 0 id={}), {} vertices, {} faces",
        mesh.nodes().len(),
        edges.len(),
        edges[0].id,
        vertices.len(),
        mesh.face_count()
    );
    drop(edges);
    drop(vertices);
    mesh.free();

    // The B-rep path **does** read the options, and refuses a bad tolerance in the
    // library's own words -- which is what proves the wrapper surfaces the library's
    // message rather than one of its own.
    match node.fem_mesh(0.0, 0.0, None) {
        Err(err) if err.to_string().contains("tolerance must be finite and > 0") => {}
        other => return Err(format!("fem brep: tolerance 0 was accepted or refused in other words: {:?}", other.map(|m| m.nodes().len()))),
    }
    Ok(())
}

/// The kernel's FEM mesh: the same surface over the kernel's own ABI, with the three
/// deliberate asymmetries -- an **owned** `.msh` string, a **twelve**-number placement,
/// and the licence notice on the writers rather than the builder.
fn fem_kernel(rounded: &Solid, sheet: &Solid) -> Result<(), String> {
    let e = |err: cadaclysm_sdk::Error| format!("kernel fem: {err}");
    let mesh = rounded.fem_mesh(0.05, 0.0, None).map_err(e)?;
    let edges = mesh.edges().map_err(e)?;
    let vertices = mesh.vertices().map_err(e)?;
    fem_arrays(
        mesh.nodes(),
        mesh.triangles(),
        mesh.triangle_face(),
        mesh.node_kind(),
        mesh.node_entity(),
        mesh.face_count(),
        edges.len(),
        vertices.len(),
        "kernel fem",
    )?;
    check(!mesh.from_mesh(), "kernel fem: a solid reported from_mesh -- the kernel has no mesh path")?;
    check(mesh.face_count() == 15, &format!("kernel fem: the filleted part has {} faces, not 15", mesh.face_count()))?;
    check(
        mesh.watertight() && mesh.open_edges().map_err(e)?.is_empty() && mesh.folded_edges().map_err(e)?.is_empty(),
        "kernel fem: the filleted part is not watertight with both censuses empty",
    )?;
    let (node_count, longest) = (mesh.nodes().len(), mesh.longest_edge());
    drop(edges);
    drop(vertices);
    mesh.free();

    // `max_size` adds nodes and shortens the longest edge -- but it **bounds the boundary
    // and only targets the interior**, so the check is loose on purpose: a tighter pin
    // would assert what the ABI does not promise (measured at 1.03x on an unevenly
    // parameterised face).
    let finer = rounded.fem_mesh(0.05, 3.0, None).map_err(e)?;
    check(
        finer.nodes().len() > node_count && finer.longest_edge() < longest,
        &format!("kernel fem: max_size 3 gave {} nodes (was {node_count}) and a longest edge of {} (was {longest})", finer.nodes().len(), finer.longest_edge()),
    )?;
    check(
        finer.longest_edge() <= 3.0 * 1.05,
        &format!("kernel fem: max_size 3 left a {} edge, past even the 1.03x the spec measured", finer.longest_edge()),
    )?;
    println!("kernel fem: {node_count} nodes at max_size 0, {} at 3.0 (longest {} -> {})", finer.nodes().len(), longest, finer.longest_edge());
    finer.free();

    // The **owned** `.msh` text: the kernel hands over a string the wrapper frees, where
    // the reader's is borrowed from the handle. Two asks are two independent strings, and
    // a reader porting one side's reasoning onto the other leaks or double-frees.
    let mesh = rounded.fem_mesh(0.05, 0.0, None).map_err(e)?;
    let text = mesh.msh_text().map_err(e)?;
    check(mesh.msh_text().map_err(e)? == text, "kernel fem: two asks for the .msh text disagree")?;
    check(text.starts_with("$MeshFormat\n4.1 0 8\n"), "kernel fem: the .msh text does not open as Gmsh 4.1 ASCII")?;
    let msh = std::env::temp_dir().join("cadaclysm-smoke-rust-kernel-fem.msh");
    mesh.save_msh(&msh).map_err(e)?;
    check(
        std::fs::metadata(&msh).map_err(|err| format!("kernel fem: {err}"))?.len() as usize >= text.len() / 2,
        "kernel fem: save_msh wrote much less than the text",
    )?;
    mesh.free();

    // The open sheet -- one face with a hole, so its rim is both the outer and the inner
    // loop. `watertight` false with **both censuses empty** is the "not asked" trio, and
    // every rim edge has a real face and the NONE sentinel for its second. Catches a
    // wrapper that filled `face_b` with 0 where the ABI said NONE: 0 is a real face.
    let rim = sheet.fem_mesh(0.05, 0.0, None).map_err(e)?;
    check(
        !rim.watertight() && rim.open_edges().map_err(e)?.is_empty() && rim.folded_edges().map_err(e)?.is_empty(),
        &format!(
            "kernel fem: the open sheet reads watertight={} with {} open and {} folded rows -- the 'not asked' trio is all three",
            rim.watertight(),
            rim.open_edges().map_err(e)?.len(),
            rim.folded_edges().map_err(e)?.len()
        ),
    )?;
    let rim_edges = rim.edges().map_err(e)?;
    check(!rim_edges.is_empty(), "kernel fem: the sheet has no edges")?;
    for (i, edge) in rim_edges.iter().enumerate() {
        check(
            edge.faces == (0, blacksmith::NONE),
            &format!("kernel fem: the sheet's rim edge {i} reads faces {:?}, not (0, NONE)", edge.faces),
        )?;
    }
    println!("kernel fem: the sheet's {} rim edges each bound face 0 and nothing else", rim_edges.len());
    drop(rim_edges);
    rim.free();

    // The placement: **twelve** numbers as a `Frame`, where the reader takes sixteen
    // column-major. The same transform as `TURNED`, so `turned` is the one expected map
    // for both sides. A cuboid, because all eight of its corners are B-rep vertices and
    // so certainly nodes.
    //
    // **The body is moved off the rotation's axis, and the test is worthless without that.**
    // `Solid::cuboid` is centred where it is built, and a rotation carries no information
    // about a body symmetric under it: transposing the frame's 3x3 axes block composes this
    // transform with a 180-degree turn about z **through the frame's own origin**, and a box
    // whose centre lands on that axis maps onto itself -- the same eight corners, the same
    // span, the same printed line. That is not a weak assertion, it is a mathematically
    // blind one.
    //
    // **The condition is on x and y alone.** The turn acts in the xy-plane, so it is blind
    // exactly when the body's centre lands on the axis -- when its x and y map to the frame
    // origin's -- and its z never enters the question. Measured, with the transpose applied:
    // an offset of (0, 0, 5) is off the literal origin, purely along the axis, and the smoke
    // passes at exit 0; (30, 7, 5) catches it. **So a non-zero x or y is what is required,
    // and a z offset buys nothing.** With this one the right answer spans x 88..98, y 20..40
    // and the transposed one x 102..112, y -40..-20 -- boxes already disjoint in x, which is
    // what earns the catch. `fem_reader`'s cube needs no such care because `cube.scad` spans
    // 0..20 in x and y rather than straddling the axis.
    let (x, y, z) = (20.0, 10.0, 4.0);
    let off = [30.0, 7.0, 5.0];
    let box_lo = [off[0] - x / 2.0, off[1] - y / 2.0, off[2] - z / 2.0];
    let box_hi = [off[0] + x / 2.0, off[1] + y / 2.0, off[2] + z / 2.0];
    let cuboid = Solid::cuboid(x, y, z).and_then(|s| s.translate(off[0], off[1], off[2])).map_err(e)?;
    let placed = cuboid.fem_mesh(0.05, 0.0, Some(&turned_frame()?)).map_err(e)?;
    for corner in corners(box_lo, box_hi) {
        let want = turned(corner);
        check(
            placed.nodes().iter().any(|q| near(*q, want)),
            &format!("kernel fem: the frame did not send the corner {corner:?} to {want:?} -- the nodes span {:?}", span(placed.nodes())),
        )?;
    }
    let (lo, hi) = span(placed.nodes());
    check(
        near(lo, turned([box_lo[0], box_hi[1], box_lo[2]])) && near(hi, turned([box_hi[0], box_lo[1], box_hi[2]])),
        &format!("kernel fem: the placed cuboid spans {lo:?}..{hi:?}, not the turn of {box_lo:?}..{box_hi:?}"),
    )?;
    println!("kernel fem: the frame turns and moves the cuboid into {lo:?}..{hi:?}");
    placed.free();

    // A tolerance the mesher refuses, in its own words -- the kernel has no mesh-only
    // path, so unlike the reader every solid goes through the options.
    match rounded.fem_mesh(0.0, 0.0, None) {
        Err(err) if err.to_string().contains("tolerance must be finite and > 0") => {}
        other => return Err(format!("kernel fem: tolerance 0 was accepted or refused in other words: {:?}", other.map(|m| m.nodes().len()))),
    }
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
