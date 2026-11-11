//! The View API: a Bézier with no reader or kernel loaded, then a cube by handle.
//!
//!   cargo run --example view                 in a window of its own (cadaclysm_view), until closed
//!   cargo run --example view -- offscreen    no window: writes view.png
//!
//! A window needs a display; `offscreen` needs only a GPU adapter. Native only: in the
//! browser a view is made with `View::on_canvas`.

#[cfg(target_arch = "wasm32")]
fn main() {}

#[cfg(not(target_arch = "wasm32"))]
use cadaclysm_sdk::blacksmith::Solid;
#[cfg(not(target_arch = "wasm32"))]
use cadaclysm_sdk::view::{self, Standard, View, ViewOptions};

#[cfg(not(target_arch = "wasm32"))]
fn main() -> cadaclysm_sdk::Result<()> {
    let offscreen = std::env::args().any(|a| a == "offscreen");
    view::use_wgpu()?;

    // Plain data: no reader, no kernel.
    let curve = [[0.0, 0.0, 0.0, 1.0], [1.0, 2.0, 0.0, 1.0], [3.0, -1.0, 0.0, 1.0], [4.0, 1.0, 0.0, 1.0]];
    // Declared before the view: what a view shows by handle must outlive it.
    let cube = Solid::cuboid(1.0, 1.0, 1.0)?.translate(1.5, -0.5, -1.5)?;

    let view = if offscreen {
        View::offscreen(900, 600)?
    } else {
        View::new(&ViewOptions { title: Some("One Bézier, one cube".into()), width: 900, height: 600, ..ViewOptions::default() })?
    };
    view.show_curves(&[curve], Some([0.9, 0.3, 0.1]))?;
    let item = view.show_solid(&cube, 0.05, None)?;
    item.colour([0.2, 0.5, 0.9])?;
    view.standard(Standard::Iso)?;
    view.frame()?;
    if offscreen {
        view.save("view.png")?;
        println!("wrote view.png");
    } else {
        let camera = view.run()?;
        println!("left at {camera}");
    }
    Ok(())
}
