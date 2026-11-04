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
    cadaclysm::Result<Solid> part = plate_with_pin();
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

## Drawing

`cadaclysm/view.hpp` draws through a view library opened at run time -- the terminal by
default, the GPU window (`cadaclysm_view`, on wgpu) after `cadaclysm::view::use_wgpu()`, any
other with `cadaclysm::view::use(path)` or `CADACLYSM_VIEW`. Link `cadaclysm::view_loader`
**and** `cadaclysm::blacksmith` (the view library is not linked: `view_loader` compiles in
where to look). `cadaclysm::view` is the linked C library itself, for a host that calls
`cadaclysm_view.h` directly. A missing library is refused with "no view library: ...", naming
where it looked, and the view library must speak ABI 1.18.

```cpp
#include <cadaclysm/view.hpp>
namespace bs = cadaclysm::blacksmith;

cadaclysm::Result<void> draw() {
    CADACLYSM_TRY(solid, bs::Solid::sphere(10));
    CADACLYSM_TRY_VOID(cadaclysm::view::use_wgpu());   // else the terminal prints a still
    CADACLYSM_TRY_VOID(solid.show());                  // blocks until the window is closed
    CADACLYSM_TRY(camera, solid.view());               // a Camera: where it was left, and the last pick

    CADACLYSM_TRY(view, cadaclysm::View::offscreen(800, 600));   // no display needed
    CADACLYSM_TRY(item, view.show(solid));                       // keeps the solid alive while shown
    CADACLYSM_TRY_VOID(item.colour("tomato"));                   // or "#e64d1a", or {0.9f, 0.3f, 0.1f}
    CADACLYSM_TRY_VOID(view.frame());
    return view.save("sphere.png");
}
```

`show()` and `view()` are member templates of `Solid`, `Scene`, `Node` and `Pose`: include
`cadaclysm/view.hpp` to call them. Their options are a `cadaclysm::ShowOptions` (`edges` true
by default; `azimuth`, `elevation` and `up` are `std::optional`; `tolerance` is
`std::optional<double>`, for solids only). Every colour argument is a `Colour`: three or four
floats, or text -- `"#rgb"`, `"#rrggbb"` or a CSS colour name, read by the view library's own
`cadaclysm_view_parse_colour`.

`view.show_text("Bracket", {0, 0, 10}, options)` shows text as one item: a label (the
default; `size` in pixels, facing the viewer, its `align` corner on the point, moved by
`offset` pixels, over an optional `box` colour with `padding`, drawn through geometry when
`on_top`) or `mode = "world"` text lying in the model along `right` and `up` (`size` in model
units). The options are a `cadaclysm::TextOptions` (white, 12 pixels, `"bottom-left"`, no box,
by default). `item.set_text("...")` replaces the string; a pick on text answers its item, the
`face` being the line hit. `cadaclysm::view::load_font(bytes)` (or a path) loads a TTF/OTF font
and returns its id for `options.font` (0 is the bundled Liberation Sans);
`view.layer(CADACLYSM_VIEW_LAYER_TEXT, false)` hides every text item. An unknown `mode` or
`align` and a NUL in the text are refused in Python's words, the rest with the library's
reason.

`pose.show()` draws a posed mechanism (the scene by handle, every node at its posed
transform). `view.lod("smooth")` turns levels of detail on (`wake_ms()` says when a resting
frame is owed), and `item.node_transforms(...)` poses a shown scene by hand.

`View::create` opens a window of its own (`run()` blocks, `cadaclysm::view::pump()` keeps it
live from your loop); `View::in_window` draws in a host's native window, the host forwarding
`input` (a `Result<uint32_t>`), `resize` and `draw` (`needs_draw()` is a `Result<bool>`). A
View belongs to the thread that made it (on macOS the main thread): another thread's call,
`close()` included, is refused. A shown `Node` or `Pose` borrows from its `Scene`, as
everything here does: keep the Scene open. `Scene::close()` first removes the items of this
thread's views that show it, and leaves the scene open when another thread's view still shows
it. `show()` and `view()` draw in a view of their own that `Scene::close()` does not see while
they run: do not close the Scene they draw from another thread meanwhile. A View made in a `static` or at namespace scope is leaked at program exit.

## Lifetimes

- **Strings are copies.** Names, ids, attribute text, STEP text: `std::string`s that
  outlive anything.
- **Arrays are borrowed.** `Node::mesh()`, `edges()`, `surfaces()` point into the open
  `Scene` and are valid until it is closed or destroyed. `Solid::mesh(tolerance)`,
  `mesh64(tolerance)`, `edge_polylines(tolerance)` and `face_triangles(tolerance)` each
  return a view that owns a tessellation of its own: it outlives their solid being meshed
  again at another tolerance *and* the solid's own `close()` -- nothing about it goes
  stale. `.copy()` is still there for a caller that would rather own the arrays outright
  than keep the view around. `Profile::polylines(tolerance)` points into the profile's own
  cache the same way it always has: valid until the profile is destroyed or asked again at
  a different tolerance.
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
  once and cached). In `CADACLYSM_CHECKED` mode a `Mesh64` carries the scene's forget
  count as well as the liveness check `mesh()` makes, so reading one after a forget
  reports a stale view rather than reading freed memory. An unchecked build carries
  neither: there it is undefined behaviour, exactly as the C ABI documents for
  `cadaclysm_node_mesh64`.
- **`FemMesh` owns its arrays, and the scene does not.** `Node::fem_mesh()` and
  `Solid::fem_mesh()` hand back a handle of your own, move-only and freed when destroyed or
  on `free()`. Its `Span`s belong to *it*: `Scene::close()` neither frees nor stales one,
  meshing the body again does not either, and there is no generation check because a FEM
  view's pointers are built with the handle and never move. Every accessor on it refuses a
  freed handle **in both modes** -- the check guards a pointer handed to C, as `Meshlets`'
  does, not a borrowed view's owner -- but a `Span` already in hand is a pointer and a
  length from then on, so hold the `FemMesh` while you read one and copy anything that must
  outlive it. A `FemEdge`'s `nodes` and `runs` borrow it the same way.
- **`Mesh`, `Mesh64`, `EdgePolylines` and `FaceTriangles` carry no generation check either,
  for the same reason as `FemMesh`**: each owns a tessellation of its own (built with the
  view and never replaced under it), rather than borrowing the solid's. A `Span` from one
  is a pointer and a length from then on, so hold the view while you read it and `.copy()`
  anything that must outlive the view itself.
- **Nodes and placements** are cheap handles, valid while their `Scene` is open.
- Moving a `Scene`, `Solid` or `Profile` keeps every view into it valid.

## Checked mode

`CADACLYSM_CHECKED` defaults to on unless `NDEBUG` is defined. When it is on, a node or
placement checks that its owning `Scene` is alive and unchanged before each read, and a
stale read calls `CADACLYSM_BAD_ACCESS(message)` instead of reading freed memory. So does
`value()` on an error, or any call on a closed or moved-from owner. `Mesh`, `Mesh64`,
`EdgePolylines` and `FaceTriangles` each own a tessellation of their own now (see above),
so there is no owner left to go stale under them -- checked mode traps only a read
through one of these after it has been moved from, `CADACLYSM_BAD_ACCESS` where an
unchecked build would read through the null pointer the move left behind. When
`CADACLYSM_CHECKED` is off, a view is a pointer and a length.

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

`cadaclysm/view.hpp` includes windows.h itself, through `view_loader.h`, with
`WIN32_LEAN_AND_MEAN` and `NOMINMAX` defined for the include (and left as it found them).
windows.h's other macros, wingdi's `ERROR` among them, remain: where one clashes with a
name of yours, `#undef` it after the include.

## The smoke

`smoke.cpp` is the scenario every wrapper's smoke runs. It builds against a cargo build
of the two libraries:

```
cmake -S . -B build -DCADACLYSM_LIBRARY_DIR=<repo>/target/release
cmake --build build && ctest --test-dir build --output-on-failure
```
