# cadaclysm for C++

A header-only C++17 wrapper over the two C libraries: `cadaclysm.hpp` (the reader) and
`cadaclysm_blacksmith.hpp` (the kernel), with `result.hpp` beside them. The object model
is `cadaclysm.py`'s, in its spelling: `scene.metres_per_unit()`,
`Workplane::xy().extrude(profile, 6).solid()`.

## Install

Header-only means there is no wrapper to compile, not that there is nothing to link:
you link `cadaclysm_capi` (and `cadaclysm_blacksmith` for the kernel), from a release
archive or a build of this repository.

With CMake and an unpacked release archive:

```cmake
find_package(cadaclysm CONFIG REQUIRED)          # -DCMAKE_PREFIX_PATH=<archive>
target_link_libraries(app PRIVATE cadaclysm::blacksmith)   # or cadaclysm::reader
```

Without CMake, add `<archive>/include` to the include path and link
`cadaclysm_capi.lib` / `libcadaclysm_capi.so` / `libcadaclysm_capi.dylib` (and the
blacksmith one). Ship the shared libraries beside your executable. C++17: MSVC 2019+,
GCC 9+, Clang 9+, AppleClang 11+ (macOS 10.15+).

## Errors: `Result<T>`, never exceptions

Every call that can fail returns a `Result<T>` holding a value or an `Error` (the
library's own message and which library said it). Nothing throws, and the headers build
with exceptions off.

```cpp
#include <cadaclysm/cadaclysm_blacksmith.hpp>
#include <cstdio>
using namespace cadaclysm::blacksmith;

cadaclysm::Result<Solid> plate_with_pin() {
    CADACLYSM_TRY(outline, Profile::rect(40, 20));
    CADACLYSM_TRY(plate, Workplane::xy().extrude(outline, 6).solid());
    CADACLYSM_TRY(pin, Solid::cylinder(4, 10));
    CADACLYSM_TRY(moved, pin.translate(0, 0, 6));
    return plate.join(moved);
}

int main() {
    auto part = plate_with_pin();
    if (!part) { std::fprintf(stderr, "%s\n", part.error().message.c_str()); return 1; }
    return part->step("part.stp").ok() ? 0 : 1;
}
```

`CADACLYSM_TRY(var, expr)` declares `var` or returns the error from the enclosing
function (one per line). `CADACLYSM_TRY_VOID(expr)` does the same for a `Result<void>`.
`map` and `and_then` chain without the macro.

The builders (`Path`, `SweepPath`, `Workplane`) keep the first refused step and skip the
rest; `end()`, `end_open()` or `solid()` report it, and `err()` shows it early.

## Drawing SVG

`Scene::svg_text`/`Scene::svg` (and `Node`'s own, in its own frame) draw the library's
own camera, not a viewer, from a `cadaclysm::SvgOptions`:

```cpp
cadaclysm::SvgOptions options;
options.view = cadaclysm::SvgView::front;
options.stroke = 0x000000;
CADACLYSM_TRY(svg, scene.svg_text(options));
CADACLYSM_TRY_VOID(scene.svg("model.svg", options));
```

`view` is one of `SvgView`'s seven (`front`, `back`, `left`, `right`, `top`, `bottom`,
`iso`, the default), which fills `azimuth`/`elevation` in degrees unless they are set
directly (`std::optional<double>`, not `nullopt`); `up` (`"y"` or `"z"`, `nullopt` by
default) falls back to the scene's own convention. `stroke`/`background` are packed
`0xRRGGBB`; `background` left `nullopt` is no `<rect>` at all, the page left
transparent. A refused option (`fov` outside `0..179`, say) is an `Error` naming the
field, worded by the library itself -- test with `if (!result)`, as any other call.

The kernel has its own `cadaclysm::blacksmith::SvgOptions`/`SvgView` (no scene to
default `up` from, so it is always `"z"`): `Solid::svg_text`/`Solid::svg`, and
`write_svg_text`/`write_svg` over several solids at once, mirroring
`write_sat_text`/`write_sat`'s shape.

## Lifetimes

- **Strings are copies.** Names, ids, attribute text, STEP text: `std::string`s that
  outlive anything.
- **Arrays are borrowed.** `Node::mesh()`, `edges()`, `surfaces()` point into the open
  `Scene` and are valid until it is closed or destroyed. `Solid::mesh(tolerance)` and
  `edge_polylines(tolerance)` point into the solid's tessellation cache and are valid
  until the solid is closed or destroyed, or meshed again at a *different* tolerance
  (`mesh`, `mesh64`, `edge_polylines`, `bounds_at` and `bounds64` all fill that cache, so
  a `Mesh64` shares `Mesh`'s cache and invalidation). `Profile::polylines(tolerance)`
  points into the profile's own cache the same way: valid until the profile is destroyed
  or asked again at a different tolerance. `.copy()` gives arrays of your own.
- **`Node::mesh64()` is different: a forget drops it, `mesh()` does not.** The `double`
  members (`mesh64`, `edge_beziers64`, `curve_beziers64`, `isocurve_beziers64`,
  `bounds64`, `bounds_placed64`) are the same values as their `float` twins, unnarrowed
  -- not a second copy. `Bounds64`/`Bounds` (from `bounds64`/`bounds_placed64` and their
  `float` twins) are plain value structs, copied out on every call, never dangling.
  `edge_beziers64` and its two siblings are views into the scene exactly like `edges()`:
  valid until the scene closes. `mesh64()` is not: it lends the document's own mesh
  cache directly, and `Scene::forget_meshes()` frees that cache -- read none of a
  `Mesh64`'s arrays after a forget without asking `mesh64()` again, even though
  `Node::mesh()`'s `float` copy survives the same forget (kept separately, narrowed
  once and cached). `mesh64()`'s liveness check (in `CADACLYSM_CHECKED` mode) is the
  same one `mesh()` makes -- that the scene itself is still open -- because a forget is
  not a close; using a held `Mesh64` after a forget without an intervening close is
  undefined behaviour, exactly as the C ABI documents for `cadaclysm_node_mesh64`.
- **Nodes and placements** are cheap handles, valid while their `Scene` is open.
- Moving a `Scene`, `Solid` or `Profile` keeps every view into it valid.

## Checked mode

`CADACLYSM_CHECKED` defaults to on unless `NDEBUG` is defined. When it is on, every
view, node and placement checks that its owner is alive and unchanged before each read,
and a stale read calls `CADACLYSM_BAD_ACCESS(message)` instead of reading freed memory.
So does `value()` on an error, or any call on a closed or moved-from owner. When it is
off, a view is a pointer and a length.

`CADACLYSM_BAD_ACCESS` prints the message and calls `std::abort()` unless you define it
before the first include. It must not return. A hook that `longjmp`s out instead is
only safe from the plain view, node and placement accessors: other calls
(`Node::visible_now` and `walk`, `Mesh::copy`, `EdgePolylines::rows` and `copy`,
`ProfilePolylines::rows` and `copy`,
`Solid::step_text`, a defaulted `Progress` argument) hold objects with destructors on the
way to the hook, and a `longjmp` skips them.

Every translation unit of a program must agree on `CADACLYSM_CHECKED`, on
`CADACLYSM_BAD_ACCESS` (each bakes its hook into the inline `detail::bad_access`, so two
different hooks break the one-definition rule), and on the language standard: under
C++20 a view is a `std::span`, under C++17 the headers' own `Span`, and `Mesh` and `Face`
are laid out differently. Checked mode and the span choice are both in the headers'
inline-namespace tag, so most mismatches are link errors rather than silent layout
mismatches -- but not all: GCC and Clang do not mangle a variable's type, so an
`extern Scene g;` defined in a translation unit that disagrees can still link.

## windows.h

`Selector::max` and `Selector::min` are declared parenthesised, so windows.h's `max`
and `min` macros cannot break the header. Where your code includes windows.h without
`NOMINMAX`, call them as `(Selector::max)(Axis::z)`.

## The smoke

`smoke.cpp` is the scenario every wrapper's smoke runs. It builds against a cargo build
of the two libraries:

```
cmake -S . -B build -DCADACLYSM_LIBRARY_DIR=<repo>/target/release
cmake --build build && ctest --test-dir build --output-on-failure
```
