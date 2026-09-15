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
