//! `cargo run --example tree -- MODEL [SCHEMA]` -- the tree and the totals, as
//! `python cadaclysm.py MODEL` prints them, plus what each drawn node carries.

use std::process::ExitCode;

use cadaclysm_sdk::OpenOptions;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(model) = args.first() else {
        eprintln!("usage: tree MODEL [SCHEMA]");
        return ExitCode::from(2);
    };
    let mut options = OpenOptions::new();
    if let Some(schema) = args.get(1) {
        options = options.schema(schema);
    }
    let scene = match options.open(model) {
        Ok(scene) => scene,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let schema = scene.schema();
    println!("cadaclysm {} - {}", scene.version(), scene.path().display());
    println!(
        "  {}, {} m/unit, {} nodes, {} roots, {} placements",
        if schema.is_empty() { "(no schema)" } else { &schema },
        scene.metres_per_unit(),
        scene.len(),
        scene.roots().len(),
        scene.placements().len()
    );
    for node in scene.walk() {
        let indent = "  ".repeat(node.depth() as usize);
        if !node.can_mesh() {
            println!("  {indent}{}  [{}]", node.label(), node.kind());
            continue;
        }
        let mesh = node.mesh();
        let manifold = node.brep().and_then(|brep| brep.manifold().ok());
        println!(
            "  {indent}{}  [{}] * {} triangles, {} faces, {} edge runs, {} attributes{}",
            node.label(),
            node.kind(),
            mesh.triangle_count(),
            node.surfaces().len(),
            node.edges().polyline_count(),
            node.attributes().len(),
            match manifold {
                Some(m) => format!(", brep {} faces closed={}", m.faces, m.is_closed),
                None => String::new(),
            }
        );
    }
    for note in scene.diagnostics() {
        println!("  diagnostic: {note}");
    }
    ExitCode::SUCCESS
}
