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

## The license

Without a license the libraries run in full and print a notice on every open and
export. Put `cadaclysm.lic` beside your executable, set `CADACLYSM_LICENSE`, or
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
