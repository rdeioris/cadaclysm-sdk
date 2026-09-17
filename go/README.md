# Go

`cadaclysm/` is a cgo package over `include/cadaclysm.h`; it links against
`../lib` (this checkout) or a `target/release` in an ancestor (the library's
own repository). A C compiler is needed for cgo (MinGW-w64 on Windows). At
run time the loader must find the library: `PATH` on Windows,
`LD_LIBRARY_PATH` on Linux, `DYLD_LIBRARY_PATH` on macOS -- or ship it beside
your binary.

    export CGO_LDFLAGS="-L$PWD/lib"; export LD_LIBRARY_PATH="$PWD/lib"   # Linux
    go run -C go ./cmd/smoke "$PWD/samples/cube.scad" path/to/cadaclysm.lic



Coverage: see the release notes; the header is the reference.

## The kernel

`blacksmith/` is a second cgo package, over
`include/cadaclysm_blacksmith.h`, built and found the same way. It keeps its
own license state, so a program using both packages licenses each one:

    rect, _ := blacksmith.Rect(80, 40)
    hole, _ := blacksmith.Circle(4)
    outline, _ := rect.WithHole(hole)
    plate, _ := blacksmith.XY().Extrude(outline, 6).Solid()
    pin, _ := blacksmith.FromSolid(plate).Faces(blacksmith.Max(blacksmith.AxisZ)).OnFace().Cylinder(5, 10).Solid()
    part, _ := plate.Join(pin, blacksmith.DefaultTolerance)
    rounded, _ := part.Fillet(corners, 1.0, blacksmith.FilletTolerance)
    rounded.Step("part.stp", "", "mm")

A mesh or a polyline is a view onto the solid's own cache, not a copy: it
dies when the solid is closed, and it goes stale in place too -- meshing the
solid again at a different tolerance frees the memory an earlier view still
points at, so reading that view returns `blacksmith.ErrStaleView` even after
re-meshing back at the tolerance it was taken at.

Coverage: see the release notes; `include/cadaclysm_blacksmith.h` is the
reference.
