# cadaclysm-sdk (Rust)

The cadaclysm C ABIs as Rust types: open a CAD file, walk its parts and borrow
their meshes (the reader, `cadaclysm_capi`), and build, combine, fillet and write
exact solids (the kernel, `cadaclysm_blacksmith`, in the `blacksmith` module). The
same object model as the Python, C#, Go, Java and Node wrappers -- `Scene`,
`Node`, `Placement`, `Mesh`; `Profile`, `Solid`, `Frame`, `Workplane` -- over the
same prebuilt libraries.

It carries **no cadaclysm source**. The crate opens the libraries (`.dll`, `.so`,
`.dylib`) when your program runs, the way Python's ctypes does, so building needs
no C toolchain and no import library. Its only dependency is `libloading`.

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

1. `CADACLYSM_LIBRARY` for the reader, `CADACLYSM_BLACKSMITH_LIBRARY` for the
   kernel -- the library itself, or its directory. Each reads only its own;
2. beside your executable -- where the download puts them;
3. where the build downloaded them;
4. a `lib/` directory in any ancestor of the executable or the working directory
   (the SDK layout -- `python fetch.py` puts the libraries there);
5. `target/release` or `target/debug` in any of those ancestors (this repository).

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
item.colour([0.2, 0.5, 0.9])?;
view.standard(Standard::Iso)?;
view.frame()?;
view.save("view.png")?;                        // or view.image()? for the pixels; view.run()? for a window
```

- **Showing.** `show_solid(&solid, tolerance, rgb)`, `show_scene(&scene)`,
  `show_node(node)` by handle; `show_mesh`, `show_lines`, `show_curves` (rational cubic
  Béziers, `[[x, y, z, w]; 4]` each), `show_image` by value -- these need no reader or
  kernel loaded. A solid, scene or node shown by handle is borrowed by the view: dropping
  it first does not compile.
- **`Item`.** `remove`, `colour`, `placement`, `face_colours`, `xray`, `frame`,
  `node_visible`, `node_colour`, `node_highlight`, `frame_node`, `node_transforms` (pose a
  shown scene, one matrix per node), `id`.
- **The camera.** `orbit`, `pan`, `zoom`, `look`, `dolly`, `standard`, `frame`,
  `orthographic`, `viewports`.
- **The rest.** `pick(x, y, viewport)`, `draw`, `needs_draw`, `run` (blocks; the camera and
  the last pick), `pump(timeout_ms)` (for a loop of your own), `image`, `save` (PNG),
  `input(&Event)`, `resize`, `layer`, `set_surfaces`, `background`, `lod(Some(Lod { .. }))`
  (levels of detail) and `wake_ms` (when a resting frame is owed). Dropping the view
  destroys it.
- **A host's window.** `unsafe { View::in_window(window, &options) }` with a `RawWindow`
  (a kind, a handle and a display); with the `raw-window-handle` feature,
  `RawWindow::of(&winit_window, width, height)`. The host forwards input (`input`), calls
  `resize` on its resize and `draw` when `needs_draw`.
- **Offscreen** needs no display, only a GPU adapter (SSH, CI); the terminal refuses it.

### Which library

`view::use_terminal()` (the default), `view::use_wgpu()`, or
`view::use_library("path/to/library")?` for any library implementing `cadaclysm_view.h`;
or set `CADACLYSM_VIEW` to `terminal`, `wgpu` or a path. `CADACLYSM_TERMINAL_LIBRARY` and
`CADACLYSM_VIEW_LIBRARY` point at the two libraries when they are not beside the program.
`cargo run --example view` shows the API in a window; `-- offscreen` writes `view.png`.

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
