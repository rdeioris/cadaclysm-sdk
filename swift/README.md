# cadaclysm for Swift

The two cadaclysm C ABIs -- the CAD readers (`cadaclysm_*`) and the blacksmith B-rep
kernel (`cadaclysm_blacksmith_*`), one library, `cadaclysm` -- as a Swift package with two modules, `Cadaclysm` and
`Blacksmith` (and a third, `CadaclysmView`, for drawing), class for class with the Python,
C#, Go, Java and Node.js wrappers. The C headers are imported as Clang modules exactly as
published: no generated bindings and no hand-copied structs. Swift 5.9 or later, on macOS
13+, Linux or Windows.

## Use it

From your own package, depend on this one by path:

```swift
// Package.swift
dependencies: [.package(path: "path/to/cadaclysm-sdk/swift")],
targets: [
    .executableTarget(name: "App", dependencies: [
        .product(name: "Cadaclysm", package: "swift"),
        .product(name: "Blacksmith", package: "swift"),
    ]),
]
```

```swift
import Blacksmith
import Cadaclysm

// Build a part and write it as STEP.
let plate = try Workplane.xy().extrude(Profile.rect(80, 40).withHole(Profile.circle(4)), 6).solid()
let pin = try Workplane.fromSolid(plate).faces(.max(.z)).workplane().cylinder(5, 10).solid()
try plate.join(pin).step("part.stp")

// Read it back: the tree, and what to draw.
let scene = try Cadaclysm.open("part.stp")
for placement in scene.placements {
    print(placement.geometry.label, placement.geometry.mesh.triangleCount, "triangles")
}
```

Module functions are spelled with the module's name: `Cadaclysm.open`,
`Cadaclysm.license`, `Blacksmith.writeStep`. Selectors and axes read best with a leading
dot, `.faces(.max(.z))`: on Apple platforms Foundation has a `Selector` of its own, so a
file importing both spells ours `Blacksmith.Selector`.

The API reference is at https://cadaclysm.blitter.studio/docs/swift.html.

## Drawing

The `CadaclysmView` product draws through a view library opened at run time -- the terminal
by default, the GPU window after `ViewLibrary.useWgpu()`, any other with
`ViewLibrary.use(path)` or `CADACLYSM_VIEW`. `Cadaclysm` and `Blacksmith` depend on it, so a
package that imports either already links it; add the product when you use `View` yourself.
A missing library throws "no view library: ...", and the view library must speak ABI 1.25.

```swift
import Blacksmith
import CadaclysmView

let solid = try Solid.sphere(10)
try ViewLibrary.useWgpu()           // else the terminal prints a still
try solid.show()                    // blocks until the window is closed
let camera = try solid.view()       // a Camera: where it was left, and the last pick

let view = try CadaclysmView.View.offscreen(width: 800, height: 600)   // no display needed
let item = try view.showSolid(solid)                                  // the view keeps the solid alive
try item.colour("tomato")                                             // or "#e64d1a", or SIMD3<Float>(0.9, 0.3, 0.1)
try view.frame()
try view.save("sphere.png")
```

`show()` and `view()` are on `Solid`, `Scene`, `Node` and `Pose`, and take a
`ShowOptions(view:azimuth:elevation:zoom:up:edges:width:height:hint:title:tolerance:)`, every
argument optional (`edges:` is true by default, `tolerance:` is a `Double?` for solids only).
Every colour argument is a `Colour`: a `String` -- `"#rgb"`, `"#rrggbb"` or a CSS colour name,
read by the view library's own parser -- or three or four floats (`SIMD3<Float>`,
`SIMD4<Float>`, `[Float]`).

`view.showText("Bracket", at: SIMD3<Float>(0, 0, 10))` shows text as one item: a label (the
default; `size:` in pixels, facing the viewer, its `align:` corner on the point, moved by
`offset:` pixels, over an optional `box:` colour with `padding:`, drawn through geometry when
`onTop:`) or `mode: "world"` text lying in the model along `right:` and `up:` (`size:` in model
units). `item.setText("...")` replaces the string; a pick on text answers its item, the face
being the line hit. `loadFont(bytes)` (or `loadFont(path:)`) loads a TTF/OTF font and returns
its id for `font:` (0 is the bundled Liberation Sans); `view.layer(CADACLYSM_VIEW_LAYER_TEXT,
false)` hides every text item. An unknown `mode` or `align` and a NUL in the text are refused
in Python's words, the rest with the library's reason.

`pose.show()` draws a posed mechanism. `view.lod("smooth")` turns levels of detail on
(`wakeMs()` says when a resting frame is owed), and `item.nodeTransforms(...)` poses a shown
scene by hand.

`View(title:width:height:)` opens a window of its own (`run()` blocks, `View.pump(timeout:)`
keeps it live from your loop); `View.inWindow` draws in a host's window (an `NSView`, an
HWND), the host forwarding `input(kind:...)`, `resize(width:height:)` and `draw()`
(`needsDraw()` throws and answers a `Bool`). A View belongs to the thread that made it (on
macOS the main thread): another thread's call is refused, and it is destroyed in `deinit` or
by `close()`. A shown `Node` or `Pose` borrows from its `Scene`, as everything in `Cadaclysm`
does: keep the Scene open. `Scene.close()` first removes the items of this thread's views that
show it, and leaves the scene open when another thread's view still shows it. `show()` and
`view()` draw in a view of their own that `Scene.close()` does not see while they run: do not
close the Scene they draw from another thread meanwhile. Where SwiftUI is imported too, `View`
is ambiguous: write `CadaclysmView.View`.

## The libraries

The libraries are linked when the package is built, as the Go wrapper's are, so
`Package.swift` has to find them. It takes the first of these that holds the reader
library:

1. `CADACLYSM_LIB_DIR`, when it is set (and then nothing else);
2. `../lib` beside this package -- an SDK checkout after `python fetch.py`;
3. `target/release` of the cadaclysm repository -- after
   `cargo build --release -p cadaclysm-lib-full` (`CADACLYSM_FLAVOUR=reader`:
   `-p cadaclysm-lib-reader`; `separate`: `-p cadaclysm-capi -p cadaclysm-blacksmith-capi`).

On macOS and Linux that directory is written into the executables' rpath, so they run
without `DYLD_LIBRARY_PATH` or `LD_LIBRARY_PATH`. On Windows it has to be on `PATH` when a
program runs, or the DLLs ship beside the executable. Keep the package and the libraries
from the same release: the package carries its own copies of the two headers
(`Sources/CCadaclysm/`, `Sources/CCadaclysmBlacksmith/`), and a library of another release
may have a different ABI.

Check it all works:

```bash
swift run cadaclysm-smoke          # opens samples/cube.scad, builds a part, reads it back
swift test
```

On Windows SwiftPM puts executables in `.build/out/Products/<config>-windows-x86_64/`, so
`swift run` is the easy way to start them. A shell opened before Swift was installed does
not have `SDKROOT` or the toolchain on `PATH` yet.

## Lifetimes

`Scene`, `Solid`, `Profile`, `Path` and `SweepPath` are classes that own their handle and
free it when the last reference goes; `close()` frees one at once. A `Node`, a `Placement`
or a `Mesh` keeps its scene alive, so borrowed memory under it stays valid while you hold
it.

Strings are copied. Mesh and polyline arrays are `NativeArray` views -- random-access
collections over the library's own memory, because a large assembly is tens of millions of
triangles. A view read after its scene is closed traps rather than read freed memory. A
kernel mesh view owns a held tessellation, so it stays valid across any re-mesh and the
solid's own close (`mesh.isStale` always reports `false`). `copy()` gives memory of your
own; so does `Array(view)`.

Every call that can fail `throws` a `CadaclysmError` (the reader) or a `BuildError` (the
kernel), carrying the library's own reason. A property read on a closed scene traps.

## The license

No license is needed to try it: without one the library runs in full, with a notice on
stderr for every file opened or written. Put `cadaclysm.lic` where the library looks --
`CADACLYSM_LICENSE`, beside the executable or in the working directory -- or load it from
code. Either call covers the whole library; the two separate libraries of earlier
releases need both:

```swift
try Cadaclysm.license("cadaclysm.lic")
try Blacksmith.license("cadaclysm.lic")
```
