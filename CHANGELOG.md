# Changelog

What changed in each cadaclysm release, for the developers building on the SDK: the
readers, the mesher, the blacksmith kernel, the C API and the wrappers. The newest
release is first; each GitHub release page opens with its own section.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) (0.x: a
minor release may change the API).

## [Unreleased]

A modelling guide for language models, and mesher and kernel fixes on real-world files.

### Added

- A modelling guide for language models (`cadaclysm-llm-guide.md`, also shipped in the SDK as `LLM-GUIDE.md` and on the website) that teaches an assistant to write blacksmith scripts: conventions, common mistakes and worked examples.

### Changed

- Booleans on bodies placed extremely far from the origin, where coordinate precision is coarser than the weld tolerance, are now refused with a clear error instead of running without end.

### Fixed

- Meshing of faces that wrap all the way round a closed surface (bands on revolutions, cylinders and tori) with holes drilled through them: the holes are no longer drawn as material, and no strip is meshed twice. Applies to both the CPU mesher and the GPU path.
- Shelling bodies whose walls are several pieces of the same cylinder (for example arcs stored as separate segments) no longer produces approximate junction curves, creases in the mesh or a STEP export refusal.
- SAT: edges on fitted intersection curves keep the tolerance the file states for the fit, so such edges (for example window rims cut into a cylinder) no longer split or drift off their faces when meshed finely.
- Booleans between bodies far from the origin no longer leak through slightly tilted cap faces.
- Documentation for polyline results in the C ABI and the Python, C#, Go and Java wrappers: `counts` is the number of points in each run, not a cumulative end index.

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
