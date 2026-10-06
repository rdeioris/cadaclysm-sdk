# Changelog

What changed in each cadaclysm release, for the developers building on the SDK: the
readers, the mesher, the blacksmith kernel, the C API and the wrappers. The newest
release is first; each GitHub release page opens with its own section.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) (0.x: a
minor release may change the API).

## [Unreleased]

## [0.10.0] - 2026-10-05

One view API everywhere: a C view that opens a native window of its own, the terminal drawing through the same view contract, `show()`/`view()` through it in Python, Rust, Node, Java, C# and LuaJIT, and the web viewer's own gesture input and timeline. Mechanisms can be posed from every wrapper, written by the kernel and played through their own motion sequences, moving parts checked for interference, and open edges sewn. Also mass properties, compressed STEP files, a modelling guide for language models, and mesher and kernel fixes on real-world files.

### Added

- CSS colour names everywhere a colour is taken as text: `coloured`/`edges_coloured` and SVG's `stroke=`/`background=` in every wrapper now read `"#rgb"`, `"#rrggbb"` or one of the 148 CSS Color Level 4 names (`"tomato"`, `"RebeccaPurple"`, matched ASCII case-insensitively), through the one parser `cadaclysm_parse_colour`/`cadaclysm_blacksmith_parse_colour` shares with the library's own coloured/edges_coloured entry points. C#/Java gain `Coloured(string)`/`coloured(String)` and `EdgesColoured(string, ...)`/`edgesColoured(String, ...)` overloads and a `Packed(string)`/`packed(String)` helper for the numeric fields that keep their type -- C#'s `Background` (`uint?`; `Stroke` is already a `string`) and Java's `background` (`Integer`); Go gains `blacksmith.RGB(string)` and `...Text` methods; Rust gains a `Colour` enum (`impl Into<Colour>` for `coloured`/`edges_coloured`) and `rgb`/`packed` free functions for the numeric `stroke`/`background`; Swift gains string overloads and `packed(_:)` for the numeric `stroke`/`background`; C++ gains `bs::rgb`/`bs::packed`/`cad::packed` and `string_view` overloads for the numeric `stroke`/`background`; Godot's colour arguments (`coloured`, `edges_coloured`, `SvgOptions`' `stroke`/`background`) and `CadaclysmBlacksmith.rgb` take names; OpenSCAD's `color()` takes every CSS name plus `#rgba`/`#rrggbbaa`.
- Rust SDK: `blacksmith`'s `coloured`/`edges_coloured` methods (`Profile`, `Solid`) now take `impl Into<Colour>` (an `[f64; 3]` array or colour text); `blacksmith::rgb` now needs the kernel library loaded.
- `cadaclysm_blacksmith_mass_properties`: a solid's area, volume, centroid and principal moments of
  inertia per unit density, integrated over its exact surfaces rather than a mesh, each figure beside a
  bound on its own error and a flag saying whether the accuracy asked for was met. Through every
  wrapper as a solid's `mass` (Python, C++, C#, Swift, Java, Go, Node, LuaJIT, Rust and Godot).
- A modelling guide for language models (`cadaclysm-llm-guide.md`, also shipped in the SDK as `LLM-GUIDE.md` and on the website) that teaches an assistant to write blacksmith scripts: conventions, common mistakes and worked examples.
- `cadaclysm_view.h` 1.2: a view created with no window (`cadaclysm_view_create(NULL, options)`) opens a native window of its own, titled and sized by the options' new `title`, `width` and `height`. `cadaclysm_view_run` blocks until the user closes it and hands back the camera it ended on (`CadaclysmViewCamera`) and the last pick; `cadaclysm_view_pump` handles pending events for every open own window and draws what they owe, waiting at most `timeout_ms`, and returns `CADACLYSM_VIEW_CLOSED` once this view's window is closed.
- `cadaclysm_view.h` 1.3: `cadaclysm_view_set_xray(view, item, on)` draws an item's triangles after everything else, depth-tested but without writing depth, so an overlay shows through whatever is in front of it; exact surfaces and pick still treat the item as ordinary geometry.
- `cadaclysm_view.h` 1.3: `cadaclysm_view_name()` says which library implements the view (`cadaclysm-view <version>` or `cadaclysm-terminal <version>`).
- The terminal library, `cadaclysm_terminal`, now implements `cadaclysm_view.h`: `cadaclysm_view_create(NULL, ..)` draws in the terminal, `cadaclysm_view_draw` prints a still, `cadaclysm_view_pump` keeps a live picture, and `cadaclysm_view_run` orbits full-screen. Items, placement, colours, framing and picks work as in `cadaclysm_view`; reference images and several viewports do not.
- Web viewer: `Viewer.input(event)`, the viewer's own gesture handler (orbit, pan, zoom, pinch, tap to pick, double tap to frame, view and fly keys); the `Viewer.flying` and `Viewer.needsDraw` getters, for a host that draws on demand; `Gestures`, the same handler for a camera of your own; `normalise` and `listen` in `view.js`; `node` in `pick`'s answer.
- `cadaclysm_view.h` 1.4: offscreen views (`CadaclysmViewOptions.offscreen`; no display needed, a GPU adapter is), and `cadaclysm_view_size` and `cadaclysm_view_image`, one frame read back from any view as RGBA8; `cadaclysm_view_draw` on an offscreen view renders without presenting and lands picks; the terminal library reads its picture through `image` too and refuses offscreen views. `cadaclysm_view_set_node_transforms(view, item, transforms, count)` poses a shown scene (a reader or a plain mesh), one world transform per node in place of its rest transform; NULL restores the rest pose. Levels of detail on the host's policy: `cadaclysm_view_set_lod(view, &lod)` (`CadaclysmViewLod`: a triangle threshold, default 2,048, and `CADACLYSM_VIEW_LOD_DETAILED` or `CADACLYSM_VIEW_LOD_SMOOTH`, which holds the frame rate while moving and refines once the camera rests) builds coarser levels in the background after each show, off by default; `cadaclysm_view_wake_ms` says when a host drawing on demand next owes a frame. Implemented by both `cadaclysm_view` and `cadaclysm_terminal` (which accepts a level policy and draws every part whole).
- Python: the `cadaclysm.view` package -- `import cadaclysm.view.wgpu` (or `cadaclysm.view.use("wgpu")`) draws in a GPU window; `View` (a window of its own, a host's window by raw handle, or `View.offscreen`) with `Item`s by handle, camera, pick, `image()` and `save()` (PNG, no Pillow); `cadaclysm.view.pump()`; windows stay live at the REPL, in IPython and in Jupyter, and a script waits for them at exit. PySide6 and Tk embedding examples.
- Python and Rust: `Pose.show()`/`Pose.view()` (Rust `Pose::show`/`Pose::view`) draw a mechanism's scene at a pose, as `Scene.show`/`Scene.view` do; Python hands the view each node's posed transform (`cadaclysm_view_set_node_transforms`), and its `Item.node_transforms`, `View.lod` and `View.wake_ms` bind 1.4's other new calls.
- Python: `View.closed` (the view's own window was closed, or the view destroyed) and `View.last_pick()` (a tap or click answered in the window, read without waiting) -- what an outer loop around `cadaclysm.view.pump(0)`, an asyncio task for one, needs to do what `run()` does without giving up the loop.
- The wheel ships `cadaclysm_view`.
- Rust SDK: `cadaclysm_sdk::view::View`, a view of the library in use as one window of its own (`View::new`), a host's window (`View::in_window`, with a `RawWindow`; the `raw-window-handle` feature converts a winit or egui host's) or an offscreen picture (`View::offscreen`, no display needed). Solids, scenes and nodes are shown by handle (`show_solid`, `show_scene`, `show_node` -- the borrow keeps them alive, checked at compile time); meshes, lines, rational Bézier curves and images by value, with no reader or kernel loaded. Each comes back as an `Item` (`remove`, `colour`, `placement`, `face_colours`, `xray`, `node_transforms`, node visibility, colour, highlight and framing). The camera calls, `pick`, `input`, `draw`, `pump`, `run`, `image`, `save` (PNG), `lod` (levels of detail) and `wake_ms` complete it. `view::use_wgpu()` draws with `cadaclysm_view`, which the build now copies beside your binaries; `CADACLYSM_VIEW_LIBRARY` points at it, and `CADACLYSM_VIEW` also takes `terminal` or `wgpu`.
- Posing a mechanism in the C ABI (`cadaclysm_pose`, `cadaclysm_pose_state`, `cadaclysm_kinematics_base`): from pair values or a named state to one world transform per node, with the pairs left out of range or unsolved reported, and through every reader wrapper as `Scene.pose`, `pose_state` and `base` (Python, C++, C#, Swift, Java, Go, Node, LuaJIT, Rust and Godot). Every mechanism in a file poses, each from its own base, and a mechanism nested in a link rides with it.
- Writing mechanisms with the kernel: `Assembly.pair` (a joint's kinematic pair -- kind, contact frames and ranges), `Assembly.state` (a named state) and `Assembly.base`, written to STEP as kinematic pairs and mechanism representations, in the C ABI, WebAssembly and every kernel wrapper.
- Interference of moving parts: a `Collider` over a set of solids answers, for each set of placements, which pairs touch or overlap; each part is meshed only when it is first needed and curved pairs are often cleared without a mesh at all. Parts can be grouped to move together, and designed contacts listed so they are never reported. With box helpers (`bounds_box`, a box moved by a placement, the oriented-box overlap test). In the C ABI, WebAssembly and every kernel wrapper.
- Sewing: `cadaclysm_brep_sew` and `Brep.sewed` (with a `SewReport`) in every reader wrapper join a body's free edges that are one edge written twice, within a tolerance, and report the widest gap sewn.
- Compressed files: a `.gz` file (`part.step.gz`) and STEP-Z (`.stpZ`) open everywhere a CAD file does, in the browser too.
- `cadaclysm_view.h` 1.1: show plain data with no reader or kernel loaded (`cadaclysm_view_show_mesh`, `show_lines`, `show_curves`, `show_image`), a kernel solid by handle (`cadaclysm_view_show_solid`), several viewports (`cadaclysm_view_set_viewports`, `cadaclysm_view_request_pick_in`; a pick answers its face), item colour, per-face colours and placement in place (`set_colour`, `set_face_colours`, `set_placement`), `frame_node`, `look` and `dolly`, and `cadaclysm_view_input`, one gesture handler shared by every view (orbit, pan, zoom, pick, standard views and held fly keys).
- A body's silhouette curves as rational cubic Béziers for a camera: `cadaclysm_node_silhouette_beziers` in the reader and `cadaclysm_blacksmith_silhouette_beziers` in the kernel, exact on planes, spheres, cylinders, cones, extrusions and revolutions and trimmed to their faces.
- Web viewer: a timeline, with a machining track (`showMachining`: the stock cut on the GPU by each tool in turn, coloured by tool or by deviation from the part, seekable, with its toolpath and tool at the playhead) and a mechanism track (`showMotion`, `showPose`: keyframes, states and rates), and timeline controls; a `Viewer` in a page's worker driven by messages (`viewer-host.js`, `viewer-client.js`); `Viewer.setLod`; fly mode; `showLines`, `showSegments` and `setPlacement`; `showSolid`'s painted edges and fill colour; `frame` of one node and `setNodeHighlights`.
- WebAssembly: `Job.machine` (automatic machining), `Solid.mass` and assembly pairs in the browser.
- Node: `Profile.polylines` (the outline, then each hole).
- `cadaclysm_blacksmith_gpu_surfaces`: a kernel solid's exact faces and edges packed for the GPU, the same record the reader packs for a part.
- Node, Java, C# and LuaJIT draw through `cadaclysm_view.h`: a `view` module in each -- `require('cadaclysm/view')`, `View.java`, `Cadaclysm.Viewing` (`View.cs`), `cadaclysm_view.lua` -- with the library choice (`useTerminal`/`useWgpu`/`use(path)` in each language's casing; the terminal stays the default and `CADACLYSM_VIEW` picks one without code), `View` (a window of its own, a host's window, or offscreen), `Item`, `pump`, `image` and `save` (PNG). Solids, scenes, nodes and poses gain `show()` and `view()`, drawn by handle (a pose through `cadaclysm_view_set_node_transforms`, as Python's): in Node `show()` replaces what one shared window shows and returns, a 16 ms timer keeping it live until it is closed; in Java, C# and LuaJIT it blocks until the window is closed. On the terminal `show()` prints a still. As in Python: `Item.nodeTransforms`, `View.lod`/`wakeMs` (levels of detail), `View.size`, `pick()` on a view not yet drawn, Escape closing an own window, and closing a scene first removing the items that show it. Java and C# now compile `View.java`/`View.cs` with the reader and kernel files.
- Motion sequences: a STEP file's own motion -- named sequences of mechanism states over time, with their time unit and whether they loop -- read as `Scene.sequences`, and `Sequence.pose(t)` poses the mechanism at any parameter along one (C: `cadaclysm_sequence_*`, `cadaclysm_pose_sequence`), in every reader wrapper. The kernel writes them too: `Assembly.sequence`, in the C ABI, WebAssembly and every kernel wrapper. The web viewer plays one on its mechanism track with `showMotion({ sequence })`, and `scene.mechanismJson` lists them.
- Kernel fillets and chamfers: a rim between a plane and a sphere or a torus about the rim's axis now rounds and chamfers, as one against a cylinder or a cone did (a ball's rim chamfers to a cone); a seam in a fillet's or chamfer's pick is skipped rather than refused.

### Changed

- Python and Rust: `view()` returns the camera it was left at (`eye`, `target`, `up`, `orthographic`, `azimuth`, `elevation`) and the last pick, in place of `(azimuth, elevation, zoom)`; the variable choosing another library is `CADACLYSM_VIEW` (was `CADACLYSM_VIEWER`). The terminal's keys follow the view's `t`/`f`/`r`/`i` standard views and Space to frame all, in place of the old `1`-`7` (gone) and `f` for refit: pressing `f` now shows the front view, not a refit. `q`, Ctrl-C and Escape all close the terminal's view, and there are no fly keys (a terminal sends no key-up). On the terminal, `e` (and `cadaclysm_view_set_layer(view, CADACLYSM_VIEW_LAYER_EDGES, on)` through the C API) also hides items shown with `show_curves`, not only edges.
- Booleans on bodies placed extremely far from the origin, where coordinate precision is coarser than the weld tolerance, are now refused with a clear error instead of running without end.
- An SVG drawing now includes each body's silhouette by default, in every wrapper: `cadaclysm_blacksmith_svg_options_init` and `cadaclysm_svg_options_init` fill `flags` with `EDGES | SILHOUETTES` (was `EDGES`), and the silhouette line set is now a word every wrapper takes, defaulting to on — Python's and Node's `silhouettes=`/`silhouettes:`, C++'s `silhouettes`, C#'s `Silhouettes`, Java's `silhouettes()` record component, Go's `Silhouettes`, Swift's `silhouettes:`, LuaJIT's `silhouettes =`, the Rust SDK's `silhouettes`, Godot's `"silhouettes"` dictionary key and the loom's `silhouettes` port — on both the reader and the kernel. A line set alone cannot draw every body: a sphere's and a torus's only curves are the seams where their one face meets itself, which are not edges of the body and have not been drawn since seams were hidden, so those two came back as a **blank page**. Every drawing of a curved body therefore gains a `<g id="...-silhouettes">` group and refits its page around it; a planar body (a cuboid) gains nothing, having no silhouette curves. Pass `silhouettes` false, or clear the bit, for the old lines-only drawing.
- Breaking, Java only: `Cad.SvgOptions` and `Blacksmith.SvgOptions` are records, so each gained a seventeenth component, `boolean silhouettes`, at the end. Code using `SvgOptions.defaults()` is unaffected; code constructing one positionally passes one more argument.
- Fixed: a drawing that asked for lines **and** silhouettes of a body with no drawable lines came back empty — the kernel's writer grew its camera box from the line curves alone, so a sphere or a torus framed an empty box and the silhouette group was dropped with it. It now falls back to the bodies' own box, as the reader's `scene_with_silhouettes` always has.
- Go: the reader's `Mesh64` hands out its arrays through methods, `Positions()`, `Normals()`, `Uvs()`, `Colours()` and `Indices()`, each returning `(slice, error)`, in place of the exported fields; it also gains `VertexCount()`, `IndexCount()` and `Copy()` (a `MeshData64` of your own). Breaking: read `m.Positions()` where you read `m.Positions`. The methods exist so a `Mesh64` held across `Scene.ForgetMeshes()` can answer an error wrapping the new `cadaclysm.ErrStaleView` instead of a slice over freed memory.
- Web viewer: `attachControls` and `forwardControls` now also take keys while the canvas has focus (a key with Ctrl, Meta or Alt stays the browser's; a held key is let go when focus or the page leaves) and pick on a tap, and the wheel zooms in proportion to how far it turns. Breaking: an object of your own passed to them (`ControllableViewer`) now needs `input` (and, for keys, `clearKeys`) rather than `orbit`, `pan` and `zoom`. `forwardControls` and `receiveControls` now exchange `"input"` and `"clearKeys"` messages; both halves ship in the same `view.js`, so load them from the same package.
- Python: `show()`/`view()` on a solid, scene or node draw it by handle on every view library (a profile as lines): with the GPU library `show()` replaces what one shared window shows; with the terminal it prints one still, as before. `node.show()` hides the siblings along the path from its root to the node (its ancestors' own geometry stays) and frames it. The Python module needs a 1.4 view library.
- Python: on the terminal library, `show(edges=False)` on a scene or node also hides its free curves -- the terminal draws edges and curves as one layer; they used to be drawn either way.
- Rust SDK, breaking: the `viewer` module is now `view` and its `Viewer` is `Library`, with no alias (`use cadaclysm_sdk::view::{self, ViewOptions}`; `view::use_terminal()`, `view::current()`). `show()` and `view()` draw solids, scenes and nodes by handle -- exact, in their own paint -- instead of handing triangles over; on the wgpu library `show()` opens a window and returns when it is closed, on the terminal it still prints one picture. `Pose::show`/`Pose::view` draw the scene by handle posed through `cadaclysm_view_set_node_transforms`; a singular rest transform is now the view library's refusal. `Solid::show`/`Solid::view` take `&self` (was `&mut self`). The SDK needs a view library of `cadaclysm_view.h` 1.4 or later.
- Seams are never drawn: an edge whose every use lies on one face is a seam, hidden in every drawing mode and for every reader; a same-face edge the surface turns across is a crease and still draws. Each edge shared by two faces is drawn once.
- Extrusions: a wall is one face per smooth run of the profile rather than one per profile segment, so walls meet only at corners.
- Faster line drawing in the GPU viewers on large models (edges drawn without instancing, each evaluated once).
- Linux: the C API libraries carry a SONAME, so a library loaded by path is found by name in the process.
- Booleans between two large curved solids that cross over a thin band are several times faster (two crossing spheres of 65,000 facets each: 119 s to 13 s).
- Java and C#: `Cad.java`/`Cad.cs` and `Blacksmith.java`/`Blacksmith.cs` now refer to the new `View.java`/`View.cs` (for `show()`/`view()`), so the three files compile together; add `View.java`/`View.cs` to an existing build. C#'s view library is fixed at the first view of a process (the runtime binds a native library name once): choose it with `ViewLibrary` before then.
- The GPU libraries (`cadaclysm_view` and the web viewer) are built on wgpu 30.
- Unreal plugin: the native library and its header now sit under `Source/ThirdParty/cadaclysm/{include,lib}`, and the plugin no longer carries a licence file.

### Removed

- `cadaclysm_viewer.h`; Python's `cadaclysm.viewer` module and its `cadaclysm_viewer.py` (use `cadaclysm.view` / `cadaclysm_view.py`); no alias.
- Python: `cadaclysm.view.draw` (the tessellating loader behind `show()`), no replacement -- use `View`.
- `viewer.py`, the moderngl example viewer in the repository (not shipped); `compare_rhino.py` draws through `cadaclysm_view`.
- Rust SDK: `cadaclysm_sdk::viewer` (use `cadaclysm_sdk::view`); no alias.

### Fixed

- Python, C#, Java, LuaJIT, Swift and Go: a `Mesh64` (Python's `node.mesh64`) read after `forget_meshes()` freed the mesh it lends is refused as a stale view -- `CadaclysmError`/`CadaclysmException` naming the forget, a Swift trap (`isValid` false beforehand), Go's `ErrStaleView` -- rather than read from freed memory, as C++'s checked build already did. The float `mesh`, the line views and the Béziers survive a forget as before.
- LuaJIT: `cadaclysm_blacksmith.lua`'s `__version__` says the release (it had said 0.4.4 since 0.4.4); `scripts/release/version.py` now bumps and checks it with every other version site.
- Meshing of faces that wrap all the way round a closed surface (bands on revolutions, cylinders and tori) with holes drilled through them: the holes are no longer drawn as material, and no strip is meshed twice. Applies to both the CPU mesher and the GPU path.
- Shelling bodies whose walls are several pieces of the same cylinder (for example arcs stored as separate segments) no longer produces approximate junction curves, creases in the mesh or a STEP export refusal.
- SAT: edges on fitted intersection curves keep the tolerance the file states for the fit, so such edges (for example window rims cut into a cylinder) no longer split or drift off their faces when meshed finely.
- Booleans between bodies far from the origin no longer leak through slightly tilted cap faces.
- Booleans that meet along a coincident rim: two solids whose faces touch exactly -- a cylinder stood on
  a block, a cut whose wall lands on an existing one -- now decide coincidence at the same tolerance the
  geometry was welded at, instead of one a thousand times looser. A face pair the kernel called
  coincident when it was merely close could leave the wall of a cut behind as a loose band.
- Web viewer: a viewer running in a worker with `controls: true` now lets its held fly keys go when the canvas loses focus to something else on the page, so a key released there no longer leaves the camera flying.
- Viewers: a mesh shown without normals whose triangles share corners (a box with eight vertices, for example) is now shaded flat, face by face, instead of with dark diagonal bands across its faces.
- Documentation for polyline results in the C ABI and the Python, C#, Go and Java wrappers: `counts` is the number of points in each run, not a cumulative end index.
- STEP: a face-based surface model is read as a body (a ship hull no longer reads as nothing); a short-form file's units are read, so an inch part is not read as metres; `parts` lists the representations the reader places.
- 3DM: a brep's edge table is read field by field, so a curved rim on a planar face meshes on its exact curve instead of staying a polygon at every tolerance, and each edge keeps its own tolerance.
- IFC: a zero or non-finite transformation scale reads as one.
- OCCT .brep: every kernel shape now writes a file OpenCASCADE finds valid.
- Kernel: a boolean result that the next boolean refused as not closed; a sphere band's seam laid along its curve rather than as one chord from pole to pole; shelling two faces on one surface no longer crosses their offsets; `leaked_edges`/`unpaired_edges` count the mesh `mesh` hands out.
- Edge polylines stay within their tolerance between the points kept, not only at them.
- Kernel: joining or cutting two crossing spheres at a fine tolerance no longer keeps part of the smaller sphere inside the larger (up to 16% too much volume and a face turned inward).
- Node: `Tool`, `Stock` and `Job` free their handles, and `Job` takes Python's positional arguments.
- LuaJIT: a solid's `bounds_box` no longer fails calling a method that does not exist.
- Kernel fillets: a rounded rim's band seam no longer starts one ring step past the seam (up to 0.7 mm off on a ball's rim); a rim whose edge leaves it off the rim's meridian, or a ball across the axis, is refused instead of built wrong.
- Silhouettes: a ruling lying on a face's seam is drawn once from either side -- a cylinder or cone seen from behind drew it twice, and a torus most of its curves.
- IFC: the GPU trim tolerance of each solid follows its size rather than its distance from the origin.
- Cadaclysm Lite: the open dialog starts on every supported file type, instead of only ACIS SAT.

## [0.9.0] - 2026-09-28

CNC machining (CAM) arrives in the kernel, STEP mechanisms can be read and posed, and a new embeddable 3D view ships in every archive.

### Added

- CAM in the kernel: tools, stock and a machining `Job` with facing, contours, pockets (helix entry) and drilling, written as Grbl G-code (one program per tool) plus a CAMotics project for simulation. `Job.machine` works out the operations automatically from a solid by Z-level sectioning and returns a report of anything it could not machine (undercuts, too-deep faces and holes, leftovers). Available in the C ABI, Python and WebAssembly (automatic `machine` not yet in the web build).
- Kernel profile and section tools: `Profile.to_arcs` (free-form curves as lines and arcs within a tolerance), `Profile.offset` (exact line/arc offsets), `Solid.section` (a solid cut by a horizontal plane into nested profiles), `Solid.pyramid`, and a solid bounding box computed at a tolerance relative to its size.
- STEP kinematics: kinematic pairs (kind, contact frames, freedoms and ranges), named mechanism states and the declared base are read, and a mechanism can be posed from pair values to get node transforms. Exposed in the C ABI and every wrapper (`Joint.pair`, `Freedom`, `Scene.states`).
- `Assembly.link` and `Assembly.joint` in every kernel wrapper.
- `cadaclysm_view`: an embeddable GPU view in the C API and every archive (and `cadaclysm::view` in the CMake package), with camera, layers, background, grid, per-node visibility, colour and highlight, picking, and automatic recovery from a lost GPU device. A Qt example widget is built on it.
- Held tessellations: mesh arrays in every wrapper are now views owned by a held tessellation, so a re-mesh or close no longer invalidates them.
- FEM meshes report triangles that pass through each other (self-crossings), in the C ABI and all wrappers.
- SAT, STEP and OCCT .brep writers export sum surfaces as exact NURBS, including rational profiles.
- New C API entry points: per-part GPU surface packing, surfaces and meshes packed about a part's own centre (for documents far from the origin), a node's own colour, and double-precision edges, curves and isocurves.
- Rust SDK: `show()`/`view()` for solids, profiles, scenes and nodes, plus a bundled terminal viewer.
- Web viewer: `Viewer.onError` reports a lost device or GPU error; `Viewer.setGrid` for grid axes, step and extent; `setColour` updates an item in place.

### Changed

- Kernel booleans are much faster on simple cases (e.g. a common of two boxes from about 110 ms to under 1 ms).
- Wrapper `bounds` now uses the kernel's own box instead of a coarse mesh-based estimate.
- Mesher produces about half the triangles for display on filled face interiors, with better quality.
- Blacksmith solids are safe to read from multiple threads.

### Fixed

- Cracks, missing refinement and folded shading on some spline surfaces and closed spline edges (including edges written against their curve in SAT files) and on faces creased inside themselves.
- Extrusions: hole walls and concave fillets facing the wrong way, cap rims and S-shaped segments not following the profile.
- 3DM sum surfaces now use their spline profile rather than a polyline approximation.
- STEP faceted shells: adjacent faces now share their common side.
- Kernel robustness: thicken keeping rim curves at folds, offset on fine or far-from-origin polylines, sections of closed runs, and booleans of spline solids sunk into or placed beside one another.
- Mass properties no longer panic in WebAssembly; wasm bounds no longer read zero.
- Documents far from the origin keep their lines, boxes and surfaces in place in Unreal and the C API; moved bodies draw correct isocurves.
- Cadaclysm Lite picks a GPU adapter that can present to the window and recovers from a lost device.
- Python kernel mesh arrays could read freed memory.

## [0.8.1] - 2026-09-26

A small follow-up to 0.8.0 for the viewers and the Cadaclysm Lite installer.

### Fixed

- Anti-aliasing now also smooths one-pixel wireframe edges and the ground grid, not only the shaded mesh.
- The Cadaclysm Lite Windows setup and its uninstaller are both code-signed.

## [0.8.0] - 2026-09-26

The first release of Cadaclysm Lite, the free desktop viewer for Windows and Linux, together with a WebAssembly `Viewer`, assembly and kinematics support, and edge colours throughout.

### Added

- Cadaclysm Lite desktop viewer for Windows (x64, arm64) and Linux (x64, arm64): signed Windows installers and zips, .deb, .rpm, AppImage and tarball packages. It registers itself for STEP, SAT, IGES, 3DM and IFC files, with OCCT .brep and OpenSCAD under Open With.
- WebAssembly `Viewer` class (WebGPU, falling back to WebGL2): shows read documents, kernel solids and meshes, with multiple viewports, per-face colours without re-upload, face picking under the cursor, curve items, reference images and pointer input in one call. Parts can optionally be drawn as exact GPU-evaluated trimmed surfaces instead of triangles.
- The web packages now ship as five WebAssembly builds (reader or kernel, with or without the viewer), with `hasReader`/`hasViewer` to tell them apart.
- STEP kinematics: mechanisms are read as links (the nodes each one moves) and joints, exposed as `Scene.links`/`Scene.joints` (and the equivalents) in the C ABI and every wrapper.
- Kernel assemblies: named solids and a new `Assembly` type (named, nested, shared placements, links and joints) in the C ABI, WebAssembly and every wrapper. Assemblies are written to STEP as nested products, and mechanisms as AP242 kinematic structure.
- Edge colours: styled STEP edge curves carry their colour to the edge polylines, exposed as `edge_colours`/`surface_edge_colours` on nodes in the C ABI and every wrapper; the STEP writer also writes solid, face and edge colours as STEP styling.
- 3DM object and layer colours keep their alpha (transparency).
- Bodies read from 3DM files can now be written out as SAT, STEP and OCCT .brep. The writers complete missing 3D edge curves before writing, and repair what they can or refuse the body with a reason.
- `scaled`: a uniform exact scale of a kernel solid, in the C ABI and every wrapper.
- FEM surface meshing of nodes and solids is now available in every wrapper (C#, Java, Go, Rust, Swift, C++, Node, LuaJIT, Godot).
- Unreal plugin: runs on Linux and Android, loads the library at run time, accepts the license from Blueprint (text or file), and draws trimmed surfaces in packaged builds; the sample opens any file and draws edges and curves.
- Python `show()`/`view()` draw edge and profile colours.
- New examples: an L-bracket taken from CAD to a stress plot, and flow around a cylinder from CAD to drag.

### Changed

- The web zips' old `viewer/` folder (`render.js`, `camera.js`) is replaced by the `Viewer` class and `view.js`; see the bundled example.
- Wrappers (Python, Node, LuaJIT) now refuse a malformed list argument (a single edge/face instead of a list, holes, wrong item types) with an error naming the problem, instead of silently truncating it.
- Mesh feature edges and isocurves are returned in a stable order.

### Fixed

- Booleans: exact computation of points where three surfaces meet, closing gaps in results such as a cube bored slightly off-axis; more robust welding of boolean results.
- Mesher: closed several crease crossings and self-intersections on trimmed spline faces, and faces whose outline loop stopped short now close properly.
- SAT writing: loops running against their face, loops around poles and seams, and unclamped spline surfaces and curves are now written correctly.
- OCCT .brep writing: faces of doubly covered surfaces of revolution and trims past a pole keep their correct side.
- STEP: a sub-assembly placed twice in the same parent now reads as two separate nodes.
- 3DM extrusion objects are read as exact surfaces instead of falling back.
- Viewer: correct lighting in linear colour space, WebGL2 line and hidden-edge drawing, and anti-aliasing on OpenGL.

## [0.7.1] - 2026-09-24

Sketch and edge colours reach every language, and STEP files now carry colours.

### Added

- Profile and edge colours in all wrappers (Python, C#, Go, Java, Node.js, Rust, Swift, LuaJIT, C++, Godot) and in the browser: `Profile.coloured`/`colour`, `Solid.edges_coloured`, `edge_colour` and `edge_polyline_colours`. Edge colours survive moves, booleans, fillets, chamfers and shells.
- The STEP writer writes solid and face colours as STEP styling.
- A coloured profile now draws in its own colour in SVG drawings.
- Unreal and Unity store plugins load the project's license file.

### Changed

- License scopes are now product, server, web and education, with a count and a plan in place of seats.
- Sketch segments are turned into curves in one place, shared by drawings and lofts; a spline too broken to evaluate now draws and lofts as its chord instead of dropping a loft side.

### Fixed

- Node.js: `Profile.round` with an empty corner list rounded the first corner on the WebAssembly route; it now rounds none.
- Booleans where a cone's wall passes through a cylinder's rim circle now cut cleanly.

## [0.7.0] - 2026-09-23

SVG drawings of sketches, body/body intersection curves, FEM-ready meshes, STEP assembly writing, parabolas and hyperbolas, and double-precision outputs.

### Added

- SVG drawings take profiles beside solids on one page (`Profile.svg`, and the module-level `svg()` over any mix), with each group stroked in its own colour. C API `cadaclysm_blacksmith_drawing_svg` / `_svg_text`; in every wrapper and in the browser.
- Body/body intersection (`Solid.intersect`): the crossing of two solids as chains of points with exact curves, plus coincident face overlaps. In the C API, every wrapper and the browser.
- Solid/profile hits (`Solid.hits`): where a sketch crosses a solid, with the profile split into inside and outside pieces. In the C API, every wrapper and the browser.
- FEM meshing: a conforming surface mesh of a read node or kernel solid, sized by a maximum element size, tagged by face, edge and vertex, with cracks and folds reported, and saved as Gmsh `.msh`. In the C API, Python and the browser.
- STEP assembly writing (`write_step_assembly`): each part written once, every placement as an assembly occurrence, for much smaller files. In the C API, Python and the browser.
- Parabolas and hyperbolas as exact curves: read and written in STEP, read from IGES conic arcs and OCCT .brep; new sketch verbs `conic_to`, `parabola`, `parabola_by_vertex` and `parabola_by_focus` in the C API, every wrapper and the browser.
- Text and star profiles (`Profile.text`, `Profile.star`) in the C API and every wrapper.
- Double-precision twins of the mesh, Bezier and bounds outputs (`mesh64`, `beziers64`, `bounds64`) for the reader and the kernel, in the C API and every wrapper, for models placed far from the origin.
- The STEP writer writes NURBS surfaces, including rational ones, so lofts and coils round-trip through STEP.
- Unreal: surface-drawn parts take a colour, an opacity and a transform.

### Changed

- Unreal: triangles versus surfaces is now chosen by component class, `UCadaclysmSurfaceComponent` and `ACadaclysmSurfaceActor`.
- `solid.svg()` now strokes a coloured solid in its own colour; pass `stroke=` for the previous single pen.
- Python: the module-level `svg()` names its first argument `things` instead of `solids`; positional calls are unaffected.

### Fixed

- Booleans: many cases of a block cut by several crossing bores now close, including near-equal diameters and sequential cuts.
- Booleans: a cone cut through a box no longer hangs; a tilted cone cut through a top writes to STEP; a sphere crossing another solid keeps the correct part.
- Booleans: fixes for a torus cut across a spline block's wall, a hex-trimmed shell cut by a sphere, and stray faces left inside an earlier bore.
- A revolved closed spline no longer comes out non-manifold, and a rounded or bevelled rim on a drafted block now closes.
- Sketch arcs reach the kernel as single arcs, so a trimmed circle extrudes to one cylinder.
- Mesher: open sheets are oriented more reliably, and sphere facets no longer stray from the surface beyond tolerance.
- GPU surface rendering: a seam fix applied to all renderers; Unreal no longer shows a hole where two trimmed faces meet.

## [0.6.0] - 2026-09-21

SVG drawings of models and solids, SAT and OCCT .brep writers for the kernel, a new C++ wrapper, and full API parity across every language binding.

### Added

- SVG wireframe drawings: `svg()` / `svg_text()` on scenes, nodes and kernel solids, using the same camera options as the viewer (named views, azimuth/elevation, perspective). Lines and arcs stay exact curves on the page. Available in the C API (`cadaclysm_scene_svg`, `cadaclysm_blacksmith_svg`) and every wrapper.
- OCCT .brep writer: kernel solids export with `brep()` / `brep_text()`, and a read scene can be saved with `scene.save(path, "brep")`, keeping exact surfaces.
- SAT writer for kernel solids (`sat()` / `sat_text()`): analytic surfaces as native records, splines and swept surfaces as exact spline surfaces.
- C++ wrapper: header-only, C++17, covering both the reader and the kernel, with a `Result<T>` error type and a CMake package shipped in the archives.
- Every wrapper (Python, C#, Go, Java, Node.js, Rust, Swift, LuaJIT, C++, Godot) now exposes the full reader API, including LOD meshes, meshlets, collision bodies and hulls, the surface rendering path, format queries, geometry diagnostics and `pick_save`.
- Kernel sketch tools: `Profile.hits` reports where profiles cross or overlap; `Profile.pieces` / `Profile.trim` cut a curve where others cross it; exact 2D booleans on profiles (`Profile.common`).
- Persistent face references: `Solid.face_ref` and `Solid.find_face` let a feature built on a face find it again after the solid is rebuilt.
- `Edge.curve` returns an edge's exact curve as a plain curve value, in every wrapper.
- Kernel: coincident faces are detected and merged onto one surface; a free-form wall can be sectioned by a quadric (plane, cylinder, cone, sphere, torus).
- Profile and edge colours in the kernel C API, carried through modelling operations to the result's edges.
- The Web Pro package now includes the Node.js kernel wrapper running on WebAssembly, with a loader.

### Changed

- The Python wheel now depends on numpy.

### Fixed

- Solids exported for Unity now arrive with the correct winding instead of back-facing.
- OCCT .brep files: fillets are meshed smoothly instead of as two facets, frame handedness is honoured, and whole tori no longer produce millions of triangles.
- Mesher: curved faces are split along the diagonal closer to the surface, several cracks between faces on SAT and OCCT .brep models are closed, tubes and half-tube bands mesh correctly, and a model placed far from the origin meshes the same as at the origin.
- STEP: mapped bodies place their exact edge curves correctly; a loop that retraces itself is read as a slit.
- 3DM: polycurve edges stay one exact spline; extrusions draw their seams, open ends and rims as curves.
- IFC: walls cut by openings no longer show shading smears.
- SAT: closed sampled curves no longer repeat their start point.
- Text in the kernel now renders on Android and iOS (fonts were not found).
- Lofted pegs in lofted bores, and faces extruded off spline solids, now produce clean booleans.
- Android viewer: files opened from a `file:` URI keep their name and extension.

## [0.5.1] - 2026-09-19

Faces keep their own colours when drawn, and mirrored solids export to STEP.

### Added

- `Solid.face_triangles()` (`cadaclysm_blacksmith_mesh_face_triangles` in the C API, declared in every wrapper): how many of a mesh's triangles each face owns, so any renderer can paint faces in their own colours.

### Changed

- `Solid.show()` and `view()` draw each face in its own colour: a coloured tool joined or cut into a solid now shows in its colour.

### Fixed

- Mirrored solids are written to STEP instead of being refused.
- A plane meeting a cone gives an exact circle or ellipse in booleans.
- Fillets and blends that would run off their face are refused cleanly instead of producing a broken solid.
- Mesher: fewer cracks along straight, circular and merged edges on real-world models, and correct meshing of spindle tori and cusped edges.
- The mobile viewer draws scenes far from the world origin as sharply as scenes at it.

## [0.5.0] - 2026-09-19

See a model right in your terminal, loft through any number of profiles, and a new Godot addon.

### Added

- Terminal viewer: `show()` and `view()` on `Solid`, `Profile`, `Scene` and `Node` in Python draw a model in the terminal (sixel, kitty graphics or coloured half blocks, over ssh too). `view()` orbits it full screen. Ships in the wheels and archives as `cadaclysm_terminal`, needs no license; `cadaclysm_viewer.h` is the contract a viewer library implements.
- Godot addon (Godot 4.4+), prebuilt for every platform in each release: CAD files import as scenes, and the reader and kernel are scriptable from GDScript, with examples.
- `loft_through`: a smooth loft through any number of profiles, in every wrapper.
- `Profile.polylines()` (`cadaclysm_blacksmith_profile_polylines`): a profile's outline and holes as polylines within a tolerance.
- Construction planes: midplane and the plane through three points.
- Rounds and chamfers whose band runs into a curved face can be taken back off.

### Fixed

- Chamfers on a hole's mouth faced inward; a chamfer ending on a curved wall now ends on its section.
- Revolve and shell no longer produce faces turned inside out; a revolved straight side becomes the exact plane, cylinder or cone.
- Booleans keep every vertex of the solids they cut, fixing missing edges where faces touch tangentially.
- Faces written with the wrong orientation in a file are turned to agree with their neighbours when a closed body is meshed.
- Mesher: steep cone apexes and bands with overlapping rims mesh correctly.
- GPU surface drawing: trims follow the edge's exact curve, and sphere poles stay closed on bodies far from the origin.

## [0.4.5] - 2026-09-19

A LuaJIT wrapper, multi-face press-pull, and shell/thicken on free-form faces.

### Added

- LuaJIT wrapper, plus documentation pages for using the SDK from Godot, LÖVE/LÖVR, Unity and Unreal.
- `push_pull` on several faces at once, in every wrapper; it also follows a slanted plane beside a cylinder or a cone.
- Shell and thicken work on NURBS faces (lofts, coils, spline sweeps).
- A curve split into several edges is merged back into one edge per piece of curve.
- Viewers: a floating origin, so a scene far from the world origin draws as sharply as one at it.

### Changed

- The `LICENSE` in each archive is now the definitive End User License Agreement.
- Every wrapper refuses a weight list of the wrong length.

### Fixed

- IFC and STEP bodies mesh the same when placed far from the origin.
- Loosely joined 3DM files: trims now end on their vertices, closing bodies that used to crack.
- Several SAT corners that did not close at shared vertices.
- A shelled coil no longer cracks after being moved.

## [0.4.4] - 2026-09-19

A Swift package, thicken, and removable chamfers.

### Added

- Swift package over both libraries, at parity with Python (Swift 5.9+).
- `thicken`: turn a sheet into a solid of uniform thickness, through the C API, WebAssembly and every wrapper.
- `rechamfer` and `unchamfer`: change a chamfer's size or remove it.

### Changed

- Spline edges mesh much faster on models with long spline profiles.

### Fixed

- NURBS spheres no longer show dark caps at their poles.
- Sphere caps crossing a pole keep their trims when drawn on the GPU.
- Some SAT bodies with self-touching seams now mesh closed.
- NURBS faces above degree 7 draw correctly.

## [0.4.3] - 2026-09-19

### Added

- `refillet` and `unfillet`: redo a fillet at another radius or remove it, in every wrapper.
- Rust crate `cadaclysm-sdk` on crates.io downloads its libraries by default (feature `download`).

### Fixed

- A brep made only of planes reported a one-unit bounding box.
- NURBS sphere caps drawn dark on the CPU mesh; sphere caps crossing a pole on the GPU.
- Some SAT bodies with a seam that touches itself now mesh closed.

## [0.4.2] - 2026-09-19

### Added

- Rust wrapper (`cadaclysm-sdk` crate) over the reader and the kernel, loading the libraries at run time.
- Swift example package over both C APIs.
- `push_pull` on sphere and torus faces.

### Changed

- Extruded, revolved, lofted, swept and coiled walls build much faster (a coil about 8x faster to build).
- Bodies far from the origin keep their shape when drawn on the GPU.

### Fixed

- Node: a long one-line custom schema is passed as EXPRESS text instead of failing a file-system check (Linux, macOS).
- Booleans keep planar faces' mesh vertices exactly in their plane, and crossings on a solid's own edges are shared by every face along them.
- A sphere's bore rim no longer cracks; small bores close.
- Viewer: moving a part with the gizmo moves its GPU surfaces too.

## [0.4.1] - 2026-09-19

STEP export needs no schema file, and Python 3.8 is supported.

### Added

- STEP export has every EXPRESS schema built in: leave `schema` out for AP203, name a built-in schema (for example AP242), or pass a custom `.exp` path or EXPRESS text, in the C API and all wrappers.
- Python 3.8 support.
- `coil`, `pipe` and `split` in the kernel and every binding.
- Fillets round concave corners.
- `push_pull` on a cone's face.

### Changed

- Writing STEP no longer reads `CADACLYSM_SCHEMAS`; pass a customised schema as `schema=` instead. The pip wheel no longer ships `ap203.exp`.
- Outlining a plate around a small hole in a boolean is much faster.

### Fixed

- 3DM bodies moved anywhere no longer crack at their corners, and read bodies mesh identically far from the origin.
- Some NURBS caps passing through a pole did not draw.
- Pulling in a cylinder's top leaves a clean shorter cylinder.
- Viewer: colour edits and glass materials apply to GPU-drawn surfaces; no dark spots at poles; whole spheres tessellate round.

## [0.4.0] - 2026-09-18

`pip install cadaclysm`, imported bodies as kernel solids, press-pull and manifold checks.

### Added

- `pip install cadaclysm`: one wheel per platform with the reader, the kernel and their libraries.
- Imported B-rep bodies (STEP, SAT, 3DM and others) are kernel solids you can model on.
- `push_pull` and `merge_flush`: extrude a face of a solid (planar or cylindrical), joining or cutting as it goes, and merge flush faces (planes, cylinders, cones, spheres, tori) into one. `join`, `cut` and `common` take an optional `merge`.
- Manifold checks: a brep says whether it is a closed manifold and where it is not (`manifold`, `manifold_flaws`), in both C APIs and every wrapper; a boolean refusing an operand says why.
- Profile helpers: `Profile.chain`, `close_loop`, `from_loops`, `regular_polygon`, `spline`, `chain_ordered`, and `revolve_in_plane`, in every binding.
- Round and chamfer a cone's base rim.
- A `Frame` helper in all kernel wrappers; Python kernel members declare their return types.

### Changed

- A profile whose loops cross is refused by every operation that builds a face or a closed solid.
- A face's frame keeps the world axes (the top of a box is the XY plane).

### Fixed

- STEP writer states each loop's direction, so a filleted box's corners no longer read back inside out.
- SAT sum surfaces with reversed profiles no longer face into the solid.
- Booleans: chained booleans through crossing sections, crossing bores of one size, and a torus bored several times stay closed.
- Mesher: many cracks fixed around sphere poles, cone apexes, closed-spline seams and faces with many holes; small parts far from the origin mesh correctly.
- Signed volume of a small solid far from the origin no longer comes out negative.
- Python, C# and Java find the kernel library and schema files in the SDK layout.

## [0.3.1] - 2026-09-18

A small follow-up to 0.3.0: planar faces from profiles in every wrapper, and a more forgiving web license check.

### Added

- `Solid.face` / `Workplane.face` in the C#, Go, Java and Node.js wrappers: turn a 2D profile into the planar sheet it bounds, holes included, with exact line, arc and spline edges.

### Changed

- In the WebAssembly packages, `load()` now warns and runs unlicensed when it cannot fetch or verify the license, instead of failing, so a mistyped license URL cannot take a site down. `useLicense()` still throws.

## [0.3.0] - 2026-09-18

WebAssembly builds ship as release packages, and the kernel gains faces, trimming, colours and new path and profile tools.

### Added

- WebAssembly release packages: `web-reader` (readers and mesher) and `web-pro` (adds the modelling kernel), each with an ES module, TypeScript typings, license glue, a WebGL2 viewer and an example page. They run under a web license bound to the domains it names.
- New modelling verbs across the C API, Python, C#, Go, Java, Node.js and WebAssembly: `face` (a profile as a planar sheet), `face_sheet` and `drop_faces` (keep selected faces of a solid), `trim` (split a sheet by a tool and keep one side), `SweepPath.along` (a 2D chain as a sweep path) and `Profile.round` (round line-line corners with tangent arcs).
- Colours on solids and faces: `Solid.coloured(colour, face=None)` sets them, `colour` / `face_colour(i)` read them back, and they are inherited through moves, booleans, splits, fillets, chamfers, shells and extrusions.
- The Python kernel wrapper also runs under Pyodide against the WebAssembly build.
- Node.js: `Slant`, `extrudeBetween`, `splitSheet`, open-edge checks, `Scene.save` and `sourceName`; the Node wrapper now covers the whole kernel API.

### Fixed

- SAT: spheres with a negative radius are now oriented towards their centre.
- `cadaclysm_scene_save` prints the license notice like the other export calls.
- The kernel refuses a slant, point or normal array of the wrong length instead of reading past it.
- WebAssembly: a re-entrant progress callback raises an error instead of aborting the module.
- Mesher: twisted edges are subdivided finely enough to meet the requested tolerance.

## [0.2.0] - 2026-09-17

Node.js, C#, Go and Java get full reader and kernel bindings, OBJ and glTF export arrive, and the library no longer needs a license to be evaluated.

### Added

- Node.js wrapper for both the reader and the kernel: open files or bytes, walk the tree, query, placements, meshes, LOD, edges, curves, surfaces, collision and meshlets, plus profiles, solids, booleans, fillet/chamfer/shell and STEP export. Async versions of the heavy calls run on a worker thread with progress callbacks. TypeScript typings included.
- C#, Go and Java reader bindings on the same object model as Python (`Scene`, `Node`, `Placement`, `Mesh`), and kernel bindings (`Workplane`, `Profile`, `Selector`, `Solid`) with full parity with the Python kernel API.
- glTF / GLB export of a mesh, a document or a gathered scene, with materials.
- Wavefront OBJ export, with an MTL file where the model has colours.
- Kernel: tapered extrusions of spline profiles (walls drafted as ruled surfaces); a draft that folds at a tight bend is creased instead of refused.
- Kernel: intersection curves between quadric surfaces are now traced, improving booleans between them.
- A license notice counter available through the C API.

### Changed

- Licensing: there is no trial or evaluation window any more. Without a license the library runs in full and prints a notice on every open and export. `license_info` never returns null.
- Server licenses report servers rather than seats.

### Fixed

- Booleans between coincident spheres and cones, and between coincident faces whose meshes share no facet planes.
- Booleans: two joint vertices closer than half the tolerance along an edge are merged.
- SAT and OCCT .brep: untrimmed spheres and tori (bodies with no loops) are sized and drawn correctly.
- C#: operands are held by SafeHandles, so they stay alive for the whole call.
- Go: a call and the read of its error message stay on one OS thread; open options with schemas no longer trip cgo's pointer checks; `Close` is nil-safe.
- Java and Go: `openMemory` takes a format; views of a closed scene throw; the Java loader looks next to the jar.

## [0.1.0] - 2026-09-15

The first public release: CAD file readers, the B-rep mesher and the blacksmith modelling kernel behind one C ABI, with Python, C#, Go and Java wrappers, for Windows, macOS and Linux.

### Added

- STEP reader (AP203, AP214, AP242) driven by the EXPRESS schema, with the schemas built in: exact B-rep geometry (analytic surfaces, NURBS, surfaces of revolution and extrusion, trimmed curves), open shells, wireframes, colours, and the assembly graph read as a placed, instanced tree. Files in legacy encodings and UTF-16 read with their names intact.
- IFC reader (IFC2X3, IFC4, IFC4X3): products with unit scaling, faceted and advanced B-reps, extrusions and swept solids as exact surfaces, CSG and half-space clipping, openings cut from walls, parametric steel sections, the spatial hierarchy, colours and transparency, and shared shapes read once and instanced.
- SAT reader: bodies and lumps with exact trimmed faces, analytic and spline surfaces, tolerant edges, wire bodies as free curves, named attributes as node properties, and per-face names and colours.
- 3DM reader: B-reps, extrusions, SubD objects, curves, text, block instances, layers, visibility and object colours.
- IGES reader (trimmed and bounded surfaces, surfaces of revolution, space curves, colours) and OCCT .brep reader.
- OpenSCAD: the full language (functions, modules, include/use), 2D shapes and extrusions, CSG, `hull()`, `offset()`, `text()` and per-object colours; zip archives open with a member picker.
- One B-rep mesher for every format: constrained Delaunay triangulation of trimmed faces, crack-free shared edges, a quality setting, triangle caps per face and body, progress, and a report of faces that could not be meshed.
- Edges, curves and surface isocurves for every format, as polylines or as exact rational Bezier segments; faces can also be handed over as trimmed Bezier patches for drawing on the GPU without meshing.
- Levels of detail, meshlets with a crack-free simplification hierarchy, oriented boxes, primitive fitting, convex hulls, collision bodies and signed distance fields.
- A query language (`cadaclysm_query`) that selects nodes by name, property and containment.
- The C ABI: open from file or memory with one options struct, an assembly tree with typed attributes, lazy per-part meshing, placements and instancing, diagnostics, cancellation, format lists for file dialogs, mesh export, and axis conventions (Y-up, Z-up, custom).
- The blacksmith modelling kernel (`cadaclysm_blacksmith`): exact primitives, sketches with lines, arcs and splines, extrude, revolve, sweep and loft, drafted extrusions, exact booleans (join, cut, common), fillets, chamfers and shells, face and edge selectors, sheet operations, meshing and STEP export (AP203).
- Wrappers: Python (reader and kernel), C#, Go and Java (JDK 22+, FFM API).
- Licensing: license file lookup and offline verification, with license info and build date calls in the C API and the wrappers.
