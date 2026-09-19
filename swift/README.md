# cadaclysm for Swift

The two cadaclysm C ABIs -- the CAD readers (`cadaclysm_capi`) and the blacksmith B-rep
kernel (`cadaclysm_blacksmith`) -- as a Swift package with two modules, `Cadaclysm` and
`Blacksmith`, class for class with the Python, C#, Go, Java and Node.js wrappers. The C
headers are imported as Clang modules exactly as published: no generated bindings and no
hand-copied structs. Swift 5.9 or later, on macOS 13+, Linux or Windows.

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

## The libraries

The libraries are linked when the package is built, as the Go wrapper's are, so
`Package.swift` has to find them. It takes the first of these that holds the reader
library:

1. `CADACLYSM_LIB_DIR`, when it is set (and then nothing else);
2. `../lib` beside this package -- an SDK checkout after `python fetch.py`;
3. `target/release` of the cadaclysm repository -- after
   `cargo build --release -p cadaclysm-capi -p cadaclysm-blacksmith-capi`.

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
triangles. A view read after its scene is closed traps rather than read freed memory, as
does a kernel mesh view read after its solid was meshed again at another tolerance
(`mesh.isStale` says so first). `copy()` gives memory of your own; so does `Array(view)`.

Every call that can fail `throws` a `CadaclysmError` (the reader) or a `BuildError` (the
kernel), carrying the library's own reason. A property read on a closed scene traps.

## The license

No license is needed to try it: without one the libraries run in full, with a notice on
stderr for every file opened or written. Put `cadaclysm.lic` where the libraries look --
`CADACLYSM_LICENSE`, beside the executable or in the working directory -- or load it from
code, once per library:

```swift
try Cadaclysm.license("cadaclysm.lic")
try Blacksmith.license("cadaclysm.lic")
```
