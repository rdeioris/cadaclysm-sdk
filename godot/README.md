# cadaclysm for Godot

Open CAD files in Godot 4.4 and later, and build exact solids from GDScript: a
GDExtension over the prebuilt cadaclysm libraries. Drop a `.step` into a project and it
imports like a `.glb`; or open files at run time, in the editor or an exported game.

| Where | What it is |
| --- | --- |
| `src/` | The extension, in Rust (godot-rust) over the `cadaclysm-sdk` crate: `CadaclysmScene`, `CadaclysmNode`, `CadaclysmPlacement`, `CadaclysmMesh`, `CadaclysmPolylines`, `CadaclysmBrep`, `CadaclysmFemMesh`, the kernel's `CadaclysmSolid`, `CadaclysmProfile`, `CadaclysmFrame`, `CadaclysmSolidFemMesh`..., and `CadaclysmImporter` |
| `project/addons/cadaclysm/` | The addon to copy into a project: the `.gdextension` file, `CadaclysmOrbitCamera`, and `bin/<platform>/` with the libraries |
| `project/examples/` | `part` (a model turning on a stand), `drawing` (a three-view sheet in 2D), `forge` (a parametric flange built by the kernel), `nut` (the logo's nut, built by the kernel), `viewer` (the file's tree beside the model) |
| `project/test/` | The tests (`run.gd`), and `bench.gd` for timing a big model |
| `build.py` | Builds the extension and puts it and the libraries in `bin/<platform>/`; `--test` runs the tests |

## Installing

Every release carries the addon prebuilt, `cadaclysm-<version>-godot.zip`, on the
[SDK's releases](https://github.com/rdeioris/cadaclysm-sdk/releases): copy its
`addons/cadaclysm/` into a project. It holds the extension and the two libraries for
Windows x64, macOS (universal) and Linux x64 and arm64, in `bin/<platform>/`, where the
`.gdextension` file looks for them. Building it yourself is below.

## Opening a file

```gdscript
var scene := CadaclysmScene.open("res://part.step")  # Y up, in metres: Godot's own space
add_child(scene.instantiate_with({"edges": true}))  # a MeshInstance3D per body
for node in scene.walk():
	print("  ".repeat(node.depth), node.label)
scene.close()
```

- **`instantiate()`** builds a `Node3D` with one `MeshInstance3D` per placement. A body
  drawn several times (a bolt in every hole) shares one `ArrayMesh`. Options: `edges`,
  `edge_color`, `material`, `tree` (nest them as the file's tree), `double_sided`. Each
  instance carries `cadaclysm_node` metadata, the index of the file node it stands for.
- **Lower down**, `node.array_mesh()`, `node.edge_mesh()`, `node.mesh` (positions,
  normals, indices as packed arrays), `placement.transform` (a `Transform3D`),
  `node.bounds` (an `AABB`), `node.colour` (a `Color`, or `null`).
- **2D**: `scene.drawing("front")` flattens every edge onto a page, as segment pairs for
  `draw_multiline`.
- **Errors**: a call that fails returns `null` (or an empty value, or `false`), reports
  with `push_error`, and leaves the reason in `Cadaclysm.last_error()`.
- **`CadaclysmScene.open_with(path, {convention = "native"})`** reads the file's own axes and
  units instead; `"unity"`, `"unreal"`, `"blender"`, `"+file-units"` as elsewhere.

## In the editor

With the addon in a project, `.step`, `.stp`, `.iges`, `.igs`, `.ifc`, `.3dm`, `.sat`,
`.brep` and `.scad` files import as scenes. The Import dock's `cadaclysm/` options add the
edges, nest the file's tree, draw both sides of faces, or add world-scale UVs. The
imported scene is Godot's own: an exported game needs no cadaclysm library to draw it.

Godot loads a new extension only after it has scanned the project once, so CAD files
that were in a project before the addon arrived import on the next launch (or
reimport them from the Import dock).

## Building

```bash
python build.py --libs path/to/sdk/lib
```

Needs Rust 1.94 or later. `--libs` names the directory holding `cadaclysm_capi` and
`cadaclysm_blacksmith` (an SDK's `lib/`); without it, `CADACLYSM_LIBRARY` and
`CADACLYSM_BLACKSMITH_LIBRARY`, then the repository's `target/release`. Then
`GODOT=path/to/godot python build.py --test` runs the tests headless.

The extension finds the two libraries beside itself (`bin/`, or next to an exported
game's executable, where the `.gdextension` file's `[dependencies]` copies them); failing
that, where `CADACLYSM_LIBRARY` and `CADACLYSM_BLACKSMITH_LIBRARY` point.
