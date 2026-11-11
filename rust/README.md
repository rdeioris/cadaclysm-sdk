# cadaclysm-sdk (Rust)

The cadaclysm C ABIs as Rust types: open a CAD file, walk its parts and borrow
their meshes (the reader, `cadaclysm_capi`), and build, combine, fillet and write
exact solids (the kernel, `cadaclysm_blacksmith`, in the `blacksmith` module). The
same object model as the Python, C#, Go, Java and Node wrappers -- `Scene`,
`Node`, `Placement`, `Mesh`; `Profile`, `Solid`, `Frame`, `Workplane` -- over the
same prebuilt libraries.

It carries **no cadaclysm source**. The crate opens the libraries (`.dll`, `.so`,
`.dylib`) when your program runs, the way Python's ctypes does, so building needs
no C toolchain and no import library. Its only dependency is `libloading` (in the
browser, wasm-bindgen and its companions instead: see [In the browser](#in-the-browser)).

```
cargo add cadaclysm-sdk
```

**The libraries come with it.** When the crate builds, it downloads this
platform's libraries for its own version from the
[SDK](https://github.com/rdeioris/cadaclysm-sdk)'s release (Windows x64, macOS 11+,
Linux x64 and arm64), checks them against the release's `SHA256SUMS`, and copies
them beside your binaries in `target/debug` or `target/release` -- so `cargo run`
works as it is, and shipping is copying those two files with your executable.
The download happens once per build directory; `curl` and `tar`, which Windows 10+,
macOS and Linux all carry, do the work.

- **Without it:** `default-features = false`, or `CADACLYSM_NO_DOWNLOAD=1` in the
  build's environment (where the crate is a dependency of a dependency). Then get
  the libraries from the SDK (`python fetch.py` puts them in `lib/`) and the crate
  finds them as below. A download that fails is a build warning, not an error,
  with the same fallback.
- **API reference:** <https://cadaclysm.blitter.studio/docs/rust.html>
- The libraries are proprietary, under the SDK's EULA; this crate's own source is
  Apache-2.0.

```rust
fn main() -> cadaclysm_sdk::Result<()> {
    let scene = cadaclysm_sdk::open("part.stp")?;
    for node in scene.walk().filter(|node| node.can_mesh()) {
        let mesh = node.mesh(); // slices straight into the library's memory
        println!("{}: {} triangles", node.label(), mesh.triangle_count());
    }
    Ok(())
}
```

```rust
use cadaclysm_sdk::blacksmith::{Axis, Profile, Selector, Workplane, DEFAULT_TOLERANCE};

fn main() -> cadaclysm_sdk::Result<()> {
    let outline = Profile::rect(80.0, 40.0)?.with_hole(&Profile::circle(4.0)?)?;
    let plate = Workplane::xy().extrude(&outline, 6.0)?.solid()?;
    let pin = Workplane::from_solid(&plate)
        .faces(&Selector::Max(Axis::Z))?
        .on_face()?
        .cylinder(5.0, 10.0)?
        .solid()?;
    plate.join(&pin, DEFAULT_TOLERANCE)?.step("plate.stp", None, Default::default())
}
```

## Where it finds the libraries

1. the copy your process already holds: a program that embeds Python and has
   imported the `cadaclysm` wheel has its libraries loaded, and the View reads solids
   through that copy, so the crate binds it rather than loading a second beside it
   (`blacksmith::use_loaded()` binds it explicitly, and fails rather than load one);
2. `CADACLYSM_LIBRARY` for the reader, `CADACLYSM_BLACKSMITH_LIBRARY` for the
   kernel -- the library itself, or its directory. Each reads only its own;
3. beside your executable -- where the download puts them;
4. where the build downloaded them;
5. a `lib/` directory in any ancestor of the executable or the working directory
   (the SDK layout -- `python fetch.py` puts the libraries there);
6. `target/release` or `target/debug` in any of those ancestors (this repository).

Or call `cadaclysm_sdk::load(path)` / `cadaclysm_sdk::blacksmith::load(path)`
before anything else. When shipping, put the libraries beside your executable.
Libraries and crate must come from the same release: a library missing an entry
point this crate binds is refused at load, by name. `Solid::from_node` and
`Solid::open` hand the reader's B-rep to the kernel by pointer, so those two need
the reader and the kernel from one build as well (the call checks).

## What Rust adds

Every pointer the libraries hand back points into memory they own. The other
wrappers document that; here the compiler enforces it.

- A `Node<'s>`, `Mesh<'s>` or `Polylines<'s>` borrows its `Scene`, so their
  slices are the library's own memory, never copied, and keeping one past the
  scene does not compile. Dropping a `Scene` closes it.
- `Solid::mesh` and `Solid::edge_polylines` take `&mut self`: meshing a solid at
  another tolerance replaces the cache the slices point into, and the borrow
  rules that out while a mesh is in use. `Mesh::copy` gives arrays of your own.
- `Scene` is `Send + Sync`: run `realize_all` on one thread and read `realized`
  or call `cancel` from another. A `Solid` is `Send` but not `Sync` -- the kernel
  caches its tessellation, and a solid is not for two threads at once.
- A `Sketch` (the 2D constraint sketcher) is `Send` but not `Sync`, and every method
  takes `&self`: the library keeps the state. A refusal's `Error::ids()` names the
  constraints or entities it ran into (empty for any other error); kinds, senses and
  ends are `&'static str`s, and dropping the sketch frees it.
- A `blacksmith::Document` loads the text any wrapper's `Document.save` wrote and
  reads each node back as an ordinary `Solid` or `Profile` (`result_kind`, then
  `result_solid` / `result_profile`), colours and all; `add_solid` and
  `add_profile` put the ones you have in. The crate reads no JSON: ops, statuses,
  errors and values are JSON text, as the C ABI has them. `Send`, not `Sync`.

## Drawing

`show` and `view` draw a `Solid`, `Profile`, `Scene` or `Node` -- by default with the
terminal library the SDK ships (`cadaclysm_terminal`, copied beside your binary by the
build), which draws with sixel, the kitty graphics protocol or half blocks. Solids,
scenes and nodes are drawn by handle, exact, read in place:

```rust
use cadaclysm_sdk::blacksmith::Solid;
use cadaclysm_sdk::view::{self, ViewOptions};

let part = Solid::cuboid(2.0, 1.0, 0.5)?;
part.show(None)?;                              // terminal: one picture, left in the scrollback
let camera = part.view(None)?;                 // orbit; q quits
println!("{camera}");                          // az=-32 el=41
part.show(&ViewOptions::from(camera))?;        // the same picture again
part.show(&ViewOptions { hint: Some("blocks".into()), ..Default::default() })?;

view::use_wgpu()?;                             // cadaclysm_view: windows of its own
part.show(None)?;                              // a window; returns when it is closed
```

`show` and `view` take `None` for the defaults, or `&options` (`Some(&options)` works
too); so do `svg_text` and `svg`.

### `View`

A `View` is one window of the library's own, a host's window, or an offscreen picture,
and what it shows comes back as `Item`s:

```rust
use cadaclysm_sdk::view::{self, Standard, View, ViewOptions};

view::use_wgpu()?;
let cube = Solid::cuboid(1.0, 1.0, 1.0)?;      // shown by handle: must outlive the view
let view = View::offscreen(900, 600)?;         // or View::new(&ViewOptions { .. })
let curve = [[0.0, 0.0, 0.0, 1.0], [1.0, 2.0, 0.0, 1.0], [3.0, -1.0, 0.0, 1.0], [4.0, 1.0, 0.0, 1.0]];
view.show_curves(&[curve], Some([0.9, 0.3, 0.1]))?;
let item = view.show_solid(&cube, 0.05, None)?;
item.colour("steelblue")?;                     // or [0.2, 0.5, 0.9]: text or numbers
view.standard(Standard::Iso)?;
view.frame()?;
view.save("view.png")?;                        // or view.image()? for the pixels; view.run()? for a window
```

- **Showing.** `show_solid(&solid, tolerance, rgb)` (or `show_solid_with(.., &SolidOptions { material,
  opacity, faces })`: a `Material`, an opacity, and only some faces -- a trim's ghost), `show_scene(&scene)`,
  `show_node(node)` by handle; `show_mesh`, `show_lines`, `show_points` (`&[[f32; 3]]`, a
  disc of `size_px` pixels a point), `show_curves` (rational cubic
  Béziers, `[[x, y, z, w]; 4]` each), `show_image` by value -- these need no reader or
  kernel loaded. A solid, scene or node shown by handle is borrowed by the view: dropping
  it first does not compile.
- **Machining.** `show_machining(&programs, [min, max], part, &options)` plays a CAM job on a
  stock: `MachiningProgram { tool: MachiningTool { number, shape: ToolShape, diameter,
  flute_length, angle, corner_radius }, gcode }` in run order, an optional
  `MachiningPart { positions, triangles }` for colouring by deviation, `MachiningOptions { cell,
  tolerance, skin, rapid_rate }` (`Option<f64>`, absent is the library's). It returns a
  `Machining`, an `Item` (through `Deref`) with `seek_move`, `colour_by(ColourBy)`, `overlays`,
  `info` and `heights`. The view's timeline: `play(speed)`, `pause`, `seek`, `set_loop`
  (`loop` is a Rust keyword), `time`, `duration`, `playing`, `status`.
- **Colours.** Every colour takes text -- `"#rgb"`, `"#rrggbb"` or a CSS colour name, read
  by the view library's own parser -- or numbers in 0..1: `colour` and `background` take
  `impl Into<Colour>`, the `show_*` calls' `rgb` an `impl Into<view::Rgb>` (`None`,
  `Some([r, g, b])` or a colour), `node_colour`/`node_highlight`/`face_colours` an
  `impl Into<view::Rgba>` (text and three numbers mean alpha 1).
- **`Item`.** `remove`, `colour`, `placement`, `face_colours`, `clear_face_colours`, `xray`, `frame`,
  `node_visible`, `node_colour`, `node_highlight`, `frame_node`, `node_transforms` (pose a
  shown scene, one matrix per node), `id`.
- **The camera.** `orbit`, `pan`, `zoom`, `look`, `dolly`, `standard`, `frame`,
  `orthographic`, `viewports`.
- **The rest.** `pick(x, y, viewport)`, `last_pick` (the pick a click or double click
  landed, read without waiting), `draw`, `needs_draw`, `run` (blocks; the camera and
  the last pick), `pump(timeout_ms)` (for a loop of your own), `image`, `save` (PNG),
  `input(&Event)`, `resize`, `layer`, `set_surfaces`, `set_lighting`, `background`, `lod(Some(Lod { .. }))`
  (levels of detail) and `wake_ms` (when a resting frame is owed). Dropping the view
  destroys it.
- **Snapping.** `set_snap(kinds, aperture_px, marker)` -- `SnapKind::ALL`, some kinds, or `&[]`
  for off, as a view starts -- then `snap(x, y, viewport)`: the vertex, midpoint, arc centre,
  quadrant, edge, face, grid or plane point under a pixel as a `Snap` (`None` for nothing),
  drawing until it lands like `pick`. `last_snap` reads a hover's or a click's in the view's own
  window without waiting; `clear_snap` hides the marker; `set_work_plane(Some(WorkPlane { .. }))`
  moves grid and plane snaps off the ground grid (`None` puts it back). Since view ABI 1.22.
- **A host's window.** `unsafe { View::in_window(window, &options) }` with a `RawWindow`
  (a kind, a handle and a display); with the `raw-window-handle` feature,
  `RawWindow::of(&winit_window, width, height)`. The host forwards input (`input`), calls
  `resize` on its resize and `draw` when `needs_draw`.
- **Text.** `view.show_text(&Text { .. })` puts words in the picture: a **label** (screen
  pixels, anchored to a point, optionally boxed and offset, on top or hidden with its
  anchor) or **world text** lying in a plane of the model. The `Item` it returns is an
  ordinary one -- `remove`, `colour`, `placement`, `xray`, picked (the pick's `face` is
  the line hit) -- and `item.set_text("..")` replaces the string. `view::load_font(bytes)`
  adds a TTF/OTF font; font 0 is the bundled Liberation Sans. Both view libraries draw
  it (the terminal's labels are real characters); since view ABI 1.6.
- **Offscreen** needs no display, only a GPU adapter (SSH, CI); the terminal refuses it.

### Which library

`view::use_terminal()` (the default), `view::use_wgpu()`, or
`view::use_library("path/to/library")?` for any library implementing `cadaclysm_view.h`;
or set `CADACLYSM_VIEW` to `terminal`, `wgpu` or a path. `CADACLYSM_TERMINAL_LIBRARY` and
`CADACLYSM_VIEW_LIBRARY` point at the two libraries when they are not beside the program.
`cargo run --example view` shows the API in a window; `-- offscreen` writes `view.png`.

## In the browser

Built for `wasm32-unknown-unknown`, the crate runs the kernel in a web page: the same
`blacksmith` API -- `Profile`, `Solid`, `Workplane`, STEP text -- answered by the cadaclysm
web package instead of a native library, and the same `view::View`, drawing through the
package's `View`. Download `cadaclysm-<version>-web-pro.zip` from the
[SDK's releases](https://github.com/rdeioris/cadaclysm-sdk/releases) and serve its `pkg/`
beside your app; nothing is downloaded when the crate builds for the web. Then:

- `web::load` imports the package and binds the kernel to it;
- `View::on_canvas` makes a `View` on a page's canvas or a worker's, with the pointer
  controls wired; the drawing code after it is the desktop's;
- `web::page::spawn` and `web::worker::start` run the kernel and the view in a Web
  Worker, so the page stays responsive while a boolean runs: the page hands its canvas
  over and forwards drag, wheel and pinch to it.

The drawing is shared; only how the `View` is made and how the program waits on it differ:

```rust
use cadaclysm_sdk::blacksmith::{Frame, Profile, Solid};
use cadaclysm_sdk::view::{Rgb, View, ViewOptions};
use cadaclysm_sdk::web::page::{self, App};
use cadaclysm_sdk::web::{worker, LoadOptions};
use wasm_bindgen::prelude::*;

/// Shared with the desktop program.
pub fn present<'a>(view: &View<'a>, hex: &'a Solid) -> cadaclysm_sdk::Result<()> {
    view.show_solid(hex, 0.05, Rgb::from("#c8ccd4"))?;
    view.frame()
}

/// On the page (called from index.html after the glue's init()).
#[wasm_bindgen]
pub fn page_main() -> Result<(), JsValue> {
    let canvas = web_sys::window().unwrap().document().unwrap()
        .get_element_by_id("view").unwrap().dyn_into::<web_sys::HtmlCanvasElement>()?;
    page::spawn(&canvas, App { glue: "./app/my_app.js", entry: "worker_main", package: "./pkg/index.js" })?;
    Ok(())
}

/// In the worker: load the package, take the canvas, draw, and keep drawing.
#[wasm_bindgen]
pub async fn worker_main() -> Result<(), JsValue> {
    let worker = worker::start(LoadOptions::new("./pkg/index.js")).await?;
    let hex = Solid::extrude(&Profile::regular_polygon([0.0, 0.0], 60.0, 6, 0.0)?, &Frame::xy([0.0; 3]), 46.0)?;
    let view = View::on_canvas(worker.canvas(), &ViewOptions::default()).await?;
    present(&view, &hex)?;
    view.run().await?; // resolves when view.close() is called
    Ok(())
}
```

On the desktop the same `present` follows `View::new(&ViewOptions::default())?` and
`view.run()?` blocks until the window closes. In the browser `view.run().await` resolves
when `view.close()` stops the view; awaiting it keeps the view and what it shows alive.
Messages the page posts to the worker (`PageWorker::post`, the forwarded controls) are held
until the entry returns or awaits `run`. `nut.show(None)` draws into the latest canvas view
still open, replacing what an earlier `show()` drew there, and returns; with none open it
says to make one with `View::on_canvas`. That view is shared: `show()` re-aims its camera
and switches its whole Edges layer, your own items on it included, where on the desktop
each `show()` has a window of its own.

What a browser can't do refuses, naming the call: `View::new`, `offscreen`,
`offscreen_with`, `in_window`, `pump`, `image`, `save`, `png`, `pixel`, `input`, `pick`,
`last_pick`, `viewports`, `lod`, the viewport cameras, `show_image`, `show_scene`/`show_node`
and the node calls, `finish`, machining, the timeline and `use_library`.
`snap` is `async` in the browser (await it); `set_snap`, `last_snap`, `clear_snap` and
`set_work_plane` are as on the desktop, and `last_snap` reads only the answers to your own `snap`s.

Call `page_main` from the page yourself rather than marking it
`#[wasm_bindgen(start)]`: the worker runs the same wasm, and a start function would run
there too. For a demo where a short freeze doesn't matter, skip the worker: `web::load`,
then `View::on_canvas` on the page's canvas. Build and serve:

```
cargo build --release --target wasm32-unknown-unknown
wasm-bindgen --target web --out-dir app target/wasm32-unknown-unknown/release/my_app.wasm
```

Serve the folder holding `index.html`, `app/` and the package's `pkg/` over HTTP (a
`file:` page can't start a module worker). The `wasm-bindgen` command-line tool must be the
version of the `wasm-bindgen` crate in your `Cargo.lock`. Your app's wasm is small beside
the package's: an app that builds and draws one part is about 0.4 MB, the package 15.7 MB.

Not in the browser yet: reading files (the reader), `heal`, `health`, a solid's history,
`n_sided_patch` and the FEM mesh, which fail saying so; calls that write a file, such as
`Solid::sat`, fail too -- use their text or bytes form (`sat_text`) and save the result
from the page. Checked with plain `wasm-bindgen --target web` in Chrome; Trunk and bundlers
such as Vite are untested.

## The license

Development, testing and evaluation are free: without a license the libraries run
in full and print a notice on every open and export. When they run in production,
a product, server or website license removes it. Put `cadaclysm.lic` beside your executable, set `CADACLYSM_LICENSE`, or
call `cadaclysm_sdk::license(path_or_text)` -- and
`cadaclysm_sdk::blacksmith::license(...)` for the kernel, which keeps its own
license state.

## Examples

```
cargo run --example tree -- part.stp
cargo run --example smoke -- samples/cube.scad cadaclysm.lic
```

Progress callbacks for the long kernel verbs are not exposed, as in the C#, Go
and Java wrappers.
