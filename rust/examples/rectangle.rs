//! A rectangle with the View API alone -- no reader, no kernel: a filled one (a mesh of two
//! triangles, its outline as the mesh's edges) and an outline-only one (four line segments).
//!
//!   cargo run --example rectangle                 in a window of its own, until closed;
//!                                                 click the filled one to toggle its colour
//!   cargo run --example rectangle -- offscreen    no window: writes rectangle.png

use cadaclysm_sdk::view::{self, Layer, Standard, View, ViewOptions};

/// The four corners of a `w` x `h` rectangle at (`x`, `y`), on the plane z = `z`,
/// counter-clockwise seen from above.
fn corners(x: f32, y: f32, w: f32, h: f32, z: f32) -> [[f32; 3]; 4] {
    [[x, y, z], [x + w, y, z], [x + w, y + h, z], [x, y + h, z]]
}

/// The rectangle's outline: one segment from each corner to the next.
fn outline(c: &[[f32; 3]; 4]) -> [[[f32; 3]; 2]; 4] {
    [[c[0], c[1]], [c[1], c[2]], [c[2], c[3]], [c[3], c[0]]]
}

fn main() -> cadaclysm_sdk::Result<()> {
    let offscreen = std::env::args().any(|a| a == "offscreen");
    view::use_wgpu()?;

    let view = if offscreen {
        View::offscreen(900, 600)?
    } else {
        View::new(&ViewOptions { title: Some("A rectangle".into()), width: 900, height: 600, ..ViewOptions::default() })?
    };

    // Filled: two triangles over the four corners, every normal up, the outline as edges.
    let filled = corners(0.0, 0.0, 40.0, 25.0, 0.0);
    let up = [[0.0, 0.0, 1.0]; 4];
    let rectangle = view.show_mesh(&filled, &[0, 1, 2, 0, 2, 3], Some(&up), Some(&outline(&filled)), "steelblue")?;

    // Outline only, beside it.
    let frame = corners(50.0, 0.0, 30.0, 25.0, 0.0);
    view.show_lines(&outline(&frame), "#e4572e")?;

    // A flat drawing: no grid (it draws over everything), a white page, looked at from above.
    view.layer(Layer::Grid, false)?;
    view.background("white")?;
    view.standard(Standard::Top)?;
    view.frame()?;
    if offscreen {
        view.save("rectangle.png")?;
        println!("wrote rectangle.png");
    } else {
        // The program's own loop: `pump` keeps the window live (orbit, pan, zoom, Escape),
        // and `last_pick` reads each click the window answered. Lines never pick; the
        // filled rectangle, a mesh, does.
        let mut lit = false;
        while view.pump(8)? {
            match view.last_pick()? {
                Some(Some(pick)) if pick.item == rectangle.id() => {
                    lit = !lit;
                    rectangle.colour(if lit { "gold" } else { "steelblue" })?;
                    println!("clicked the rectangle (face {})", pick.face);
                }
                Some(Some(pick)) => println!("clicked item {}", pick.item),
                Some(None) => println!("clicked nothing"),
                None => {} // no click since the last look
            }
        }
    }
    Ok(())
}
