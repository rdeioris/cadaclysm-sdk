//! A square pyramid -- two ridges crossed -- drawn with the viewer in use.
//!
//!   cargo run --example show                      one picture into the scrollback
//!   cargo run --example show -- view              orbit it; prints where it was left
//!   cargo run --example show -- blocks            force the terminal protocol (or sixel, kitty)
//!
//! The viewer is the bundled terminal one unless CADACLYSM_VIEWER names another.

use cadaclysm_sdk::blacksmith::Solid;
use cadaclysm_sdk::viewer::{self, ViewOptions};

fn main() -> cadaclysm_sdk::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();

    // A wedge with no top is a ridge along Y; what it shares with itself turned a quarter
    // about Z is a square pyramid.
    let ridge = Solid::wedge(2.0, 2.0, 1.5, 0.0)?;
    let crossed = ridge.rotate(&[[0.0; 3], [0.0, 0.0, 1.0]], std::f64::consts::FRAC_PI_2)?;
    let mut pyramid = ridge.common(&crossed, 1e-6)?;

    let hint = ["sixel", "kitty", "blocks"].iter().find(|h| args.iter().any(|a| a == *h)).map(|h| h.to_string());
    let options = ViewOptions { hint, ..ViewOptions::default() };
    println!("drawing with {}", viewer::current()?.name());
    if args.iter().any(|a| a == "view") {
        let camera = pyramid.view(&options)?;
        println!("left at {camera}");
    } else {
        pyramid.show(&options)?;
    }
    Ok(())
}
