"""The cadaclysm C ABI, as Python objects: this file is the whole binding.

    import cadaclysm

    with cadaclysm.open("part.stp") as scene:
        print(scene.version, scene.schema, scene.metres_per_unit)
        for node in scene.roots:
            walk(node)

    def walk(node, depth=0):
        print("  " * depth, node.name, node.kind)
        for child in node.children:
            walk(child, depth + 1)

It uses `ctypes` and the published header, the way any Python program would —
no generated bindings, no Rust, no build system. Drop it beside your own
script and point `CADACLYSM_LIBRARY` at the shared library if it is not in the
place this looks by default.

`numpy` is imported only when triangles, polylines or a FEM mesh's arrays are
actually asked for. A script that walks the tree and reads attributes needs
nothing but the standard library.

## Everything borrows from the scene

Every pointer this ABI hands back — names, ids, attribute text, vertex and
index arrays — points into the open document and dies with it. Nothing here
copies by default, so nothing here is safe after `Scene.close()`, which is
what leaving a `with` block does.

Strings are the easy half: `ctypes` decodes `char *` into a Python `str` on the
way out, so `node.name` is already a copy and outlives anything.

Arrays are the sharp half, and **`node.mesh` and `node.fem_mesh(...)` hand back
read-only numpy views into the library's own memory** rather than copies. That is the deliberate
choice: `ufi.stp` is 90.5M triangles, and copying every mesh to be safe would
cost gigabytes and seconds to hand back arrays most callers upload to the GPU
and drop. Two things make the unsafe use hard to reach by accident:

* The arrays are read-only, so a stray write cannot corrupt the document.
* Each array keeps the `Scene` alive through its `.base`, so a view cannot
  outlive the scene by having merely dropped the last reference to it.

That leaves exactly one way to dangle: keeping a view past an explicit
`close()`. Call `mesh.copy()` for arrays that must outlive the scene, or
finish with them inside the `with`.

A `FemMesh` is a caller-owned handle, as `Meshlets` is -- but it is the one whose
**borrowed arrays** have an owner that is not the scene: they keep the `FemMesh`
alive through their `.base`, and `free()` (or leaving its own `with` block) is
what invalidates them, not `Scene.close()`.
"""

import ctypes
import decimal
import enum
import os
import platform
import re
import sys
from ctypes import POINTER, c_bool, c_char_p, c_double, c_float, c_size_t, c_uint32, c_uint64, c_void_p
from pathlib import Path

__all__ = [
    "Attribute",
    "Beziers",
    "Bounds",
    "Brep",
    "CadaclysmError",
    "Collision",
    "CollisionHull",
    "Convention",
    "FILE_UNITS",
    "FemEdge",
    "FemMesh",
    "FemVertex",
    "Joint",
    "Link",
    "Manifold",
    "Mesh",
    "Meshlet",
    "Meshlets",
    "NONE",
    "Node",
    "Placement",
    "Polylines",
    "Scene",
    "UV_WORLD",
    "ValueKind",
    "build_date",
    "declared_schema",
    "formats",
    "library_path",
    "license",
    "license_info",
    "license_notice_count",
    "lod_levels",
    "mesh_formats",
    "open",
    "open_memory",
    "pick_file",
    "pick_save",
    "resolve_schema",
    "version",
]

#: What the ABI returns for "no such node": a parent that is a root, an
#: `instance_of` that is not an instance, an index past the end. Spelled
#: `CADACLYSM_NONE` in the header, and `UINT32_MAX` underneath.
NONE = 0xFFFFFFFF


class CadaclysmError(Exception):
    """A call into the library failed, carrying what it said about it."""


class Convention(enum.IntEnum):
    """The coordinate space to open a file into — `CadaclysmConvention`.

    The library converts on the way out, so nothing here rotates anything: a
    caller names the space it draws in and reads geometry already in it.
    `NATIVE` keeps the file's own axes and units, which is what every caller
    got before the parameter existed and what this module still defaults to.
    """

    #: The file's own axes and its own units.
    NATIVE = 0
    #: Z up, left-handed, centimetres.
    UNREAL = 1
    #: Y up, left-handed, metres.
    UNITY = 2
    #: Y up, right-handed, metres — glTF, three.js, Bevy, wgpu.
    Y_UP = 3
    #: Z up, right-handed, metres. `NATIVE`'s axes at Blender's unit, which is
    #: the only difference between the two.
    BLENDER = 4

    @classmethod
    def parse(cls, text: str) -> int:
        """A packed `uint32` from a name a user typed, as `viewer.py` takes it.

        `"unreal"`, or `"unreal+file-units"` to keep the file's own units under
        the preset's axes. Raises `ValueError` naming what was accepted, since
        an unrecognised name silently read as `NATIVE` is the one outcome that
        looks like success and draws the wrong space.
        """
        preset, _, rest = text.strip().lower().partition("+")
        packed = {
            "native": cls.NATIVE, "unreal": cls.UNREAL, "unity": cls.UNITY,
            "y-up": cls.Y_UP, "blender": cls.BLENDER,
        }.get(preset)
        if packed is None:
            raise ValueError(f"no convention called {preset!r}: "
                             "native, unreal, unity, y-up or blender")
        packed = int(packed)
        for flag in filter(None, rest.split("+")):
            if flag != "file-units":
                raise ValueError(f"no convention flag called {flag!r}: file-units")
            packed |= FILE_UNITS
        return packed


#: OR into a convention: keep the preset's axes but the file's own units.
#:
#: **A packing of this module's own now, not the ABI's.** The library takes
#: `file_units` as a field of `CadaclysmOpenOptions`, and `open` unpacks this
#: bit into it. The bit survives here because `Convention.parse` returns one
#: integer and every caller passing `unreal+file-units` expects that to keep
#: working.
FILE_UNITS = 0x100

#: OR into a convention: ask for `Mesh.uvs`, at one world unit per unit of `u`.
#: `CADACLYSM_UV_WORLD`. Off by default in the library and so here — a `(u, v)`
#: is eight bytes a vertex, which is not a cost to impose on a caller who never
#: asked. Even with it, `Mesh.uvs` is None for a node whose reader produces
#: none.
#:
#: What it turns on is *generating* coordinates from a surface's own parameters.
#: A format that stores them is a separate matter and is not gated by it:
#: `PartDesignExample-Body.step` yields UVs on 0 nodes without this flag and 1
#: with it, while `extrusion.3dm` yields them on the same 1 node either way,
#: its meshes carrying coordinates the file itself wrote.
#: **Also this module's own packing**, unpacked into the struct's `uvs` field.
UV_WORLD = 0x200


def _options(convention, schema=None, colors=False, source_meters_per_unit=0.0):
    """A `CadaclysmOpenOptions` built from this module's arguments.

    Returns the struct *and the objects it points into*: ctypes will happily let
    the schema array be collected while the struct still holds its address, so a
    caller has to keep the second value alive across the call.
    """
    options = _OpenOptions()
    _lib().cadaclysm_open_options_init(ctypes.byref(options))
    packed = int(convention)
    options.convention = packed & ~(FILE_UNITS | UV_WORLD)
    options.file_units = bool(packed & FILE_UNITS)
    options.uvs = 1 if packed & UV_WORLD else 0
    options.colors = 1 if colors else 0
    options.source_meters_per_unit = float(source_meters_per_unit)
    held = []
    if schema is not None:
        encoded = str(schema).encode()
        array = (c_char_p * 1)(encoded)
        options.schemas = array
        options.schema_count = 1
        held = [encoded, array]
    return options, held


class ValueKind(enum.IntEnum):
    """Which field of an attribute holds its value.

    **One-based, with zero meaning the attribute was not there** — see
    `include/cadaclysm.h`. A zero-based reading of this enum is off by one for
    every kind, which shows up as every text attribute printing an integer.
    """

    NONE = 0
    TEXT = 1
    INTEGER = 2
    REAL = 3
    BOOLEAN = 4
    #: The flat C struct cannot hold a list's elements, so `text` carries a
    #: `[a, b, c]` rendering of them.
    LIST = 5
    #: Another entity, with the id the file gave (`#4`) in `text`. Its own kind
    #: rather than TEXT so a consumer can follow it instead of showing it as
    #: prose.
    REFERENCE = 6


# ---- the structs the ABI returns by value ---------------------------------


class _Bounds(ctypes.Structure):
    _fields_ = [("min", c_float * 3), ("max", c_float * 3)]


class _Bounds64(ctypes.Structure):
    _fields_ = [("min", c_double * 3), ("max", c_double * 3)]


class _Attribute(ctypes.Structure):
    _fields_ = [
        ("name", c_char_p),
        ("kind", ctypes.c_int),
        ("text", c_char_p),
        ("integer", ctypes.c_int64),
        ("real", c_double),
        ("boolean", c_bool),
    ]


class _Mesh(ctypes.Structure):
    #: Field order must match `CadaclysmMesh` in `include/cadaclysm.h` exactly.
    #: `uvs` sits between `normals` and `indices`, which is where the header
    #: puts it; a copy that leaves it out still loads and still runs, and reads
    #: `uvs` as `indices` and the two halves of the real `indices` pointer as
    #: `vertex_count` and `index_count`. Measured on `extrusion.3dm` before this
    #: field was added: every drawn node came back with a null `indices`, a
    #: `vertex_count` of 995677168 and an `index_count` of 430 — the low and
    #: high words of a heap address — so the viewer drew nothing at all and
    #: raised nothing.
    #:
    #: `cadaclysm-capi/tests/bindings.rs` now pins this against the header, by
    #: field order and by whether each field is a pointer. It does not pin the
    #: exact ctypes type, so `c_float` becoming `c_double` is still yours to get
    #: right.
    _fields_ = [
        ("positions", POINTER(c_float)),
        ("normals", POINTER(c_float)),
        ("uvs", POINTER(c_float)),
        ("colors", POINTER(c_float)),
        ("indices", POINTER(c_uint32)),
        ("vertex_count", c_uint32),
        ("index_count", c_uint32),
    ]


class _Mesh64(ctypes.Structure):
    #: `CadaclysmMesh64`: `_Mesh` in `double`, save `colors` which stays float32.
    #: Same field-order contract as `_Mesh`; pinned by `tests/bindings.rs`.
    _fields_ = [
        ("positions", POINTER(c_double)),
        ("normals", POINTER(c_double)),
        ("uvs", POINTER(c_double)),
        ("colors", POINTER(c_float)),
        ("indices", POINTER(c_uint32)),
        ("vertex_count", c_uint32),
        ("index_count", c_uint32),
    ]


class _OpenOptions(ctypes.Structure):
    #: `CadaclysmOpenOptions`. Field order and `size` are the whole contract:
    #: `cadaclysm_open_options_init` fills the library's whole struct, so this
    #: list must match the header field for field -- `tests/bindings.rs` pins
    #: it -- and it may never reorder.
    _fields_ = [
        ("size", c_size_t),
        ("convention", c_uint32),
        ("spec", c_void_p),
        ("file_units", ctypes.c_bool),
        ("uvs", c_uint32),
        ("colors", c_uint32),
        ("source_meters_per_unit", c_double),
        ("schemas", POINTER(c_char_p)),
        ("schema_count", c_size_t),
        ("schema_text", POINTER(ctypes.c_uint8)),
        ("schema_length", c_size_t),
        # The pick hook is not exposed here -- passing null takes the
        # default (shallowest member, ties to archive order). `init` fills
        # the whole struct, so this list must match the header's field
        # order and length.
        ("pick", c_void_p),
        ("pick_user", c_void_p),
    ]


class _SvgOptions(ctypes.Structure):
    #: `CadaclysmSvgOptions`. Field order and `size` are the whole contract, as
    #: `_OpenOptions` above: `cadaclysm_svg_options_init` fills the library's
    #: whole struct, so this list must match the header field for field --
    #: `tests/bindings.rs` pins it -- and it may never reorder.
    _fields_ = [
        ("size", c_uint32),
        ("up", c_uint32),
        ("azimuth", c_double),
        ("elevation", c_double),
        ("fov", c_double),
        ("width", c_double),
        ("height", c_double),
        ("margin", c_double),
        ("tolerance", c_double),
        ("stroke_width", c_double),
        ("stroke", c_uint32),
        ("background", c_uint32),
        ("flags", c_uint32),
    ]


class _Polylines(ctypes.Structure):
    _fields_ = [
        ("positions", POINTER(c_float)),
        ("counts", POINTER(c_uint32)),
        ("polyline_count", c_uint32),
        ("vertex_count", c_uint32),
    ]


class _EdgeColors(ctypes.Structure):
    #: `CadaclysmEdgeColors`: four floats per polyline of the matching `_Polylines`.
    #: Pinned against the header by `tests/bindings.rs`; `Node.edge_colours` /
    #: `surface_edge_colours` read it.
    _fields_ = [
        ("rgba", POINTER(c_float)),
        ("count", c_uint32),
    ]


class _Beziers(ctypes.Structure):
    #: `CadaclysmBeziers`: four control points a curve (`count * 12` floats) and four
    #: weights a curve (`count * 4`). Pinned against the header by `tests/bindings.rs`.
    _fields_ = [
        ("points", POINTER(c_float)),
        ("weights", POINTER(c_float)),
        ("count", c_uint32),
    ]


class _Beziers64(ctypes.Structure):
    #: `CadaclysmBeziers64`: `_Beziers` in `double`. Pinned by `tests/bindings.rs`.
    _fields_ = [
        ("points", POINTER(c_double)),
        ("weights", POINTER(c_double)),
        ("count", c_uint32),
    ]


class _Collision(ctypes.Structure):
    #: `CadaclysmCollision`; `size` first, which the caller fills. Pinned by `tests/bindings.rs`.
    _fields_ = [
        ("size", c_uint32),
        ("shape", c_uint32),
        ("confidence", c_uint32),
        ("axis", c_uint32),
        ("frame", c_double * 16),
        ("half_extent", c_double * 3),
        ("radius", c_double),
        ("height", c_double),
        ("error", c_double),
        ("hull_vertex_count", c_uint32),
        ("hull_index_count", c_uint32),
    ]


class _CollisionHull(ctypes.Structure):
    _fields_ = [
        ("positions", POINTER(c_float)),
        ("indices", POINTER(c_uint32)),
        ("vertex_count", c_uint32),
        ("index_count", c_uint32),
    ]



class _Face(ctypes.Structure):
    #: `CadaclysmFace`. Field order and the fixed array widths are the contract; a
    #: mismatch here reads one face's frame as the next one's domain. Pinned against the
    #: header by `cadaclysm-capi/tests/bindings.rs`.
    _fields_ = [
        ("kind", c_uint32),
        ("reversed", c_uint32),
        ("transposed", c_uint32),
        ("reserved", c_uint32),
        ("origin", c_float * 4),
        ("ax", c_float * 4),
        ("ay", c_float * 4),
        ("az", c_float * 4),
        ("domain", c_float * 4),
        ("scalars", c_float * 4),
        ("loop_start", c_uint32),
        ("loop_count", c_uint32),
        ("profile_start", c_uint32),
        ("profile_count", c_uint32),
        ("profile2_start", c_uint32),
        ("profile2_count", c_uint32),
        ("nurbs_start", c_uint32),
        ("nurbs_count", c_uint32),
    ]


class _Surfaces(ctypes.Structure):
    #: `CadaclysmSurfaces`. The counts are in elements, not floats: `point_count` counts
    #: (u, v) pairs and `profile_count` counts four-float samples, so each array is that
    #: many times its stride.
    _fields_ = [
        ("faces", POINTER(_Face)),
        ("face_count", c_uint32),
        ("loops", POINTER(c_uint32)),
        ("loop_count", c_uint32),
        ("points", POINTER(c_float)),
        ("point_count", c_uint32),
        ("profiles", POINTER(c_float)),
        ("profile_count", c_uint32),
        ("nurbs", POINTER(c_float)),
        ("nurbs_count", c_uint32),
        ("shared", POINTER(c_uint32)),
        ("shared_count", c_uint32),
    ]


class _FemOptions(ctypes.Structure):
    #: `CadaclysmFemOptions`. Field order and `size` are the whole contract, as
    #: `_OpenOptions` above: `cadaclysm_fem_options_init` fills the library's whole
    #: struct, so this list must match the header field for field --
    #: `tests/bindings.rs` pins it -- and it may never reorder. A field the library
    #: has and this list does not is written **past** what `Node.fem_mesh`
    #: allocated, which is the `CadaclysmOpenOptions` overrun that pin exists for.
    _fields_ = [
        ("size", c_size_t),
        ("tolerance", c_double),
        ("max_size", c_double),
    ]


class _FemMeshView(ctypes.Structure):
    #: `CadaclysmFemMeshView`. Every pointer here is borrowed from the FEM handle
    #: and dies with it; the counts are in elements, so `nodes` holds
    #: `node_count * 3` doubles and `triangles` `triangle_count * 3` indices.
    #: Pinned against the header by `tests/bindings.rs`, which is the only thing
    #: standing between a missing field here and reading `min_angle` out of
    #: `watertight`.
    _fields_ = [
        ("nodes", POINTER(c_double)),
        ("node_count", c_uint32),
        ("triangles", POINTER(c_uint32)),
        ("triangle_count", c_uint32),
        ("triangle_face", POINTER(c_uint32)),
        ("node_kind", POINTER(c_uint32)),
        ("node_entity", POINTER(c_uint32)),
        ("face_count", c_uint32),
        ("edge_count", c_uint32),
        ("vertex_count", c_uint32),
        ("open_edge_count", c_uint32),
        ("folded_edge_count", c_uint32),
        ("watertight", c_bool),
        ("from_mesh", c_bool),
        ("min_angle", c_double),
        ("worst_triangle", c_uint32),
        ("longest_edge", c_double),
    ]


class _FemEdge(ctypes.Structure):
    #: `CadaclysmFemEdge`: one B-rep edge's node chain. Pinned by `tests/bindings.rs`.
    _fields_ = [
        ("id", c_uint32),
        ("nodes", POINTER(c_uint32)),
        ("node_count", c_uint32),
        ("runs", POINTER(c_uint32)),
        ("run_count", c_uint32),
        ("face_a", c_uint32),
        ("face_b", c_uint32),
        ("end_a", c_uint32),
        ("end_b", c_uint32),
        ("closed", c_bool),
        ("seam", c_bool),
    ]


class _FemVertex(ctypes.Structure):
    #: `CadaclysmFemVertex`. `point` is a fixed array of three doubles, not a
    #: pointer: it is the vertex's own position, copied into the struct.
    #: Pinned by `tests/bindings.rs`.
    _fields_ = [
        ("node", c_uint32),
        ("point", c_double * 3),
        ("has_position", c_bool),
    ]


# ---- loading the library --------------------------------------------------

#: Every entry point in `include/cadaclysm.h`, as `(name, restype, argtypes)`.
#:
#: Declared in full, and all of them rather than the few any one caller uses:
#: without a `restype` ctypes assumes `int`, which truncates every pointer
#: these return on a 64-bit build, and a handle truncated to 32 bits is a
#: crash somewhere else entirely.
_ENTRY_POINTS = [
    ("cadaclysm_last_error", c_char_p, []),
    ("cadaclysm_version", c_char_p, []),
    ("cadaclysm_license_set", ctypes.c_bool, [c_char_p]),
    ("cadaclysm_license_info", c_char_p, []),
    ("cadaclysm_license_notice_count", c_uint64, []),
    ("cadaclysm_build_date", c_char_p, []),
    ("cadaclysm_open", c_void_p, [c_char_p, POINTER(_OpenOptions)]),
    ("cadaclysm_open_memory", c_void_p,
     [POINTER(ctypes.c_uint8), c_size_t, c_char_p, POINTER(_OpenOptions)]),
    ("cadaclysm_open_options_init", None, [POINTER(_OpenOptions)]),
    ("cadaclysm_close", None, [c_void_p]),
    ("cadaclysm_source_name", c_char_p, [c_void_p]),
    ("cadaclysm_node_count", c_uint32, [c_void_p]),
    ("cadaclysm_root_count", c_uint32, [c_void_p]),
    ("cadaclysm_root", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_schema", c_char_p, [c_void_p]),
    ("cadaclysm_schema_read", c_char_p, [c_void_p]),
    ("cadaclysm_metres_per_unit", c_double, [c_void_p]),
    ("cadaclysm_bounds", _Bounds, [c_void_p]),
    ("cadaclysm_bounds64", _Bounds64, [c_void_p]),
    ("cadaclysm_node_parent", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_node_child_count", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_node_child", c_uint32, [c_void_p, c_uint32, c_uint32]),
    ("cadaclysm_node_depth", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_node_name", c_char_p, [c_void_p, c_uint32]),
    ("cadaclysm_node_kind", c_char_p, [c_void_p, c_uint32]),
    ("cadaclysm_node_visible", c_bool, [c_void_p, c_uint32]),
    ("cadaclysm_node_save_mesh", c_bool, [c_void_p, c_uint32, c_char_p, c_char_p]),
    ("cadaclysm_scene_save", c_bool, [c_void_p, c_char_p, c_char_p]),
    ("cadaclysm_svg_options_init", None, [POINTER(_SvgOptions)]),
    ("cadaclysm_scene_svg_text", c_char_p, [c_void_p, POINTER(_SvgOptions)]),
    ("cadaclysm_scene_svg", c_bool, [c_void_p, c_char_p, POINTER(_SvgOptions)]),
    ("cadaclysm_node_svg_text", c_char_p, [c_void_p, c_uint32, POINTER(_SvgOptions)]),
    ("cadaclysm_node_svg", c_bool, [c_void_p, c_uint32, c_char_p, POINTER(_SvgOptions)]),
    ("cadaclysm_mesh_format_count", c_uint32, []),
    ("cadaclysm_mesh_format", c_char_p, [c_uint32]),
    ("cadaclysm_mesh_format_extension", c_char_p, [c_uint32]),
    ("cadaclysm_mesh_format_label", c_char_p, [c_uint32]),
    ("cadaclysm_format_count", c_uint32, []),
    ("cadaclysm_format_name", c_char_p, [c_uint32]),
    ("cadaclysm_format_extensions", c_char_p, [c_uint32]),
    ("cadaclysm_query", c_uint32,
     [c_void_p, c_char_p, POINTER(c_uint32), c_uint32]),
    # `NULL` for the parent, which is a `const CadaclysmWindow *`. A viewer with
    # a window of its own should pass one; this binding does not, because pyglet
    # hands out a window handle only through platform-specific attributes and a
    # wrong pointer here reaches a platform API.
    ("cadaclysm_pick_file", c_char_p, [c_void_p]),
    ("cadaclysm_pick_save", c_char_p, [c_void_p, c_char_p]),
    ("cadaclysm_node_id", c_char_p, [c_void_p, c_uint32]),
    ("cadaclysm_node_color", c_bool, [c_void_p, c_uint32, POINTER(c_float)]),
    ("cadaclysm_node_transform", None, [c_void_p, c_uint32, POINTER(c_double)]),
    ("cadaclysm_node_attribute_count", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_node_attribute", _Attribute, [c_void_p, c_uint32, c_uint32]),
    ("cadaclysm_placement_count", c_uint32, [c_void_p]),
    ("cadaclysm_placement_geometry", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_placement_select", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_placement_transform", None, [c_void_p, c_uint32, POINTER(c_double)]),
    ("cadaclysm_node_can_mesh", c_bool, [c_void_p, c_uint32]),
    ("cadaclysm_node_mesh", _Mesh, [c_void_p, c_uint32]),
    ("cadaclysm_node_mesh64", _Mesh64, [c_void_p, c_uint32]),
    ("cadaclysm_lod_levels", c_uint32, []),
    ("cadaclysm_node_mesh_lod", _Mesh, [c_void_p, c_uint32, c_uint32]),
    ("cadaclysm_node_lod_error", c_float, [c_void_p, c_uint32, c_uint32]),
    ("cadaclysm_node_collision", c_bool, [c_void_p, c_uint32, c_uint32, POINTER(_Collision)]),
    ("cadaclysm_node_collision_hull", _CollisionHull, [c_void_p, c_uint32, c_uint32]),
    ("cadaclysm_node_bounds_placed", _Bounds, [c_void_p, c_uint32, POINTER(c_double)]),
    ("cadaclysm_node_bounds_placed64", _Bounds64, [c_void_p, c_uint32, POINTER(c_double)]),
    ("cadaclysm_node_is_meshed", c_bool, [c_void_p, c_uint32]),
    ("cadaclysm_node_surface_edges", _Polylines, [c_void_p, c_uint32]),
    ("cadaclysm_node_surface_edge_beziers", _Beziers, [c_void_p, c_uint32]),
    ("cadaclysm_node_surface_edge_colors", _EdgeColors, [c_void_p, c_uint32]),
    ("cadaclysm_node_surface_isocurves", _Polylines, [c_void_p, c_uint32]),
    ("cadaclysm_node_surface_pick", c_bool,
     [c_void_p, c_uint32, POINTER(c_double), POINTER(c_double), POINTER(c_double)]),
    ("cadaclysm_node_surface_proxy_mesh", _Mesh, [c_void_p, c_uint32, c_uint32]),
    ("cadaclysm_node_triangle_estimate", ctypes.c_int64, [c_void_p, c_uint32]),
    ("cadaclysm_node_surfaces", _Surfaces, [c_void_p, c_uint32]),
    ("cadaclysm_node_brep", c_void_p, [c_void_p, c_uint32]),
    ("cadaclysm_brep_release", None, [c_void_p]),
    ("cadaclysm_brep_manifold", c_bool, [c_void_p, POINTER(c_uint32)]),
    ("cadaclysm_brep_layout_id", c_char_p, []),
    ("cadaclysm_surface_matrix", None, [c_void_p, POINTER(c_float)]),
    ("cadaclysm_node_bounds", _Bounds, [c_void_p, c_uint32]),
    ("cadaclysm_node_bounds64", _Bounds64, [c_void_p, c_uint32]),
    ("cadaclysm_node_instance_of", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_node_select_as", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_node_generator", c_char_p, [c_void_p, c_uint32]),
    ("cadaclysm_diagnostic_count", c_uint32, [c_void_p]),
    ("cadaclysm_diagnostic", c_char_p, [c_void_p, c_uint32]),
    ("cadaclysm_geometry_diagnostic_count", c_uint32, [c_void_p]),
    ("cadaclysm_geometry_diagnostic", c_char_p, [c_void_p, c_uint32]),
    ("cadaclysm_link_count", c_uint32, [c_void_p]),
    ("cadaclysm_link_name", c_char_p, [c_void_p, c_uint32]),
    ("cadaclysm_link_node_count", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_link_node", c_uint32, [c_void_p, c_uint32, c_uint32]),
    ("cadaclysm_joint_count", c_uint32, [c_void_p]),
    ("cadaclysm_joint_name", c_char_p, [c_void_p, c_uint32]),
    ("cadaclysm_joint_start", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_joint_end", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_node_edges", _Polylines, [c_void_p, c_uint32]),
    ("cadaclysm_node_edge_colors", _EdgeColors, [c_void_p, c_uint32]),
    ("cadaclysm_node_curves", _Polylines, [c_void_p, c_uint32]),
    ("cadaclysm_node_isocurves", _Polylines, [c_void_p, c_uint32]),
    ("cadaclysm_node_edge_beziers", _Beziers, [c_void_p, c_uint32]),
    ("cadaclysm_node_curve_beziers", _Beziers, [c_void_p, c_uint32]),
    ("cadaclysm_node_isocurve_beziers", _Beziers, [c_void_p, c_uint32]),
    ("cadaclysm_node_edge_beziers64", _Beziers64, [c_void_p, c_uint32]),
    ("cadaclysm_node_curve_beziers64", _Beziers64, [c_void_p, c_uint32]),
    ("cadaclysm_node_isocurve_beziers64", _Beziers64, [c_void_p, c_uint32]),
    ("cadaclysm_realize_all", c_uint32, [c_void_p]),
    ("cadaclysm_realize_meshes", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_realized", c_uint32, [c_void_p]),
    ("cadaclysm_realize_total", c_uint32, [c_void_p]),
    ("cadaclysm_cancel", None, [c_void_p]),
    ("cadaclysm_forget_meshes", None, [c_void_p]),
    ("cadaclysm_meshlets_build", c_void_p,
     [POINTER(c_float), POINTER(c_float), c_size_t, POINTER(c_uint32), c_size_t, c_uint32, c_uint32, ctypes.c_int32]),
    ("cadaclysm_meshlets_count", c_uint32, [c_void_p]),
    ("cadaclysm_meshlets_free", None, [c_void_p]),
    ("cadaclysm_meshlet_triangle_count", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_meshlet_vertex_count", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_meshlet_level", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_meshlet_group", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_meshlet_error", c_float, [c_void_p, c_uint32]),
    ("cadaclysm_meshlet_child_count", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_meshlet_positions", None, [c_void_p, c_uint32, POINTER(c_float)]),
    ("cadaclysm_meshlet_normals", None, [c_void_p, c_uint32, POINTER(c_float)]),
    ("cadaclysm_meshlet_indices", None, [c_void_p, c_uint32, POINTER(c_uint32)]),
    ("cadaclysm_meshlet_children", None, [c_void_p, c_uint32, POINTER(c_uint32)]),
    # The FEM surface mesh: one handle per meshed body, freed by the caller. The
    # `.msh` text comes back as `c_char_p` and so as a Python `bytes` copy, which
    # is what makes the borrowed-slot lifetime `cadaclysm_fem_mesh_msh_text`
    # documents a non-issue here -- see `FemMesh.msh_text`.
    ("cadaclysm_fem_options_init", None, [POINTER(_FemOptions)]),
    ("cadaclysm_node_fem_mesh", c_void_p,
     [c_void_p, c_uint32, POINTER(c_double), POINTER(_FemOptions)]),
    ("cadaclysm_fem_mesh_free", None, [c_void_p]),
    ("cadaclysm_fem_mesh_view", c_bool, [c_void_p, POINTER(_FemMeshView)]),
    ("cadaclysm_fem_mesh_edge", c_bool, [c_void_p, c_uint32, POINTER(_FemEdge)]),
    ("cadaclysm_fem_mesh_vertex", c_bool, [c_void_p, c_uint32, POINTER(_FemVertex)]),
    ("cadaclysm_fem_mesh_open_edge", c_bool,
     [c_void_p, c_uint32, POINTER(c_uint32), POINTER(c_uint32), POINTER(c_uint32)]),
    ("cadaclysm_fem_mesh_folded_edge", c_bool,
     [c_void_p, c_uint32, POINTER(c_uint32), POINTER(c_uint32), POINTER(c_uint32)]),
    ("cadaclysm_fem_mesh_msh_text", c_char_p, [c_void_p]),
    ("cadaclysm_fem_mesh_save_msh", c_bool, [c_void_p, c_char_p]),
]


def _library_name() -> str:
    suffix = {"Windows": ".dll", "Darwin": ".dylib"}.get(platform.system(), ".so")
    return "cadaclysm_capi.dll" if suffix == ".dll" else "libcadaclysm_capi" + suffix


def library_path() -> Path:
    """Where the shared library is, preferring a release build over a debug one.

    `CADACLYSM_LIBRARY` first, so this file works dropped beside a script
    anywhere; then next to this file; then a `lib/` directory in any ancestor
    (the SDK layout); then a `target/release` (or `target/debug`) in any ancestor
    (this repository's layout).
    """
    name = _library_name()
    override = os.environ.get("CADACLYSM_LIBRARY")
    if override:
        candidate = Path(override)
        # A directory or the library itself, since both are things to point at.
        candidate = candidate / name if candidate.is_dir() else candidate
        if candidate.exists():
            return candidate
        raise CadaclysmError(f"CADACLYSM_LIBRARY={override} names nothing that exists")

    here = Path(__file__).resolve().parent
    searched = [here / name]
    # Walking up from this file: an SDK checkout keeps the library in `lib/` beside
    # the wrappers; the repository this example ships in keeps it in `target/release`
    # (or `target/debug`, a fallback for a machine that only built that).
    for ancestor in [here, *here.parents]:
        searched.append(ancestor / "lib" / name)
    for ancestor in [here, *here.parents]:
        searched += [ancestor / "target" / profile / name for profile in ("release", "debug")]
    for candidate in searched:
        if candidate.exists():
            return candidate
    raise CadaclysmError(
        f"{name} not found. Looked in:\n"
        + "".join(f"    {c}\n" for c in searched)
        + "Build it with:\n    cargo build --release -p cadaclysm-capi\n"
        "or run fetch.py in an SDK checkout, or point CADACLYSM_LIBRARY at it."
    )


_library = None


def _lib() -> ctypes.CDLL:
    """The loaded library, declared and cached.

    Cached because `CDLL` on an already-loaded library is cheap but the
    `argtypes` assignment below is not free, and because two `CDLL` objects
    over one library would each re-declare the same function objects.
    """
    global _library
    if _library is None:
        path = library_path()
        library = ctypes.CDLL(str(path))
        for name, restype, argtypes in _ENTRY_POINTS:
            # A library older than this file is the likeliest reason a symbol is
            # missing, and `getattr` on a CDLL reports it as a bare AttributeError
            # naming only the symbol -- which reads as a bug in this module rather
            # than as a stale build. Measured: a library built before
            # `cadaclysm_node_isocurves` was added dies here on the *first* ABI
            # call of any kind, because every entry point is bound up front.
            try:
                function = getattr(library, name)
            except AttributeError:
                raise CadaclysmError(
                    f"{path} has no {name}: the library is older than this copy of "
                    f"cadaclysm.py, which declares {len(_ENTRY_POINTS)} entry points. "
                    "Rebuild it with `cargo build --release -p cadaclysm-capi`."
                ) from None
            function.restype, function.argtypes = restype, argtypes
        _library = library
    return _library


_numpy_module = None


def _numpy():
    """`numpy`, imported on first use.

    Deferred so that reading a file's tree, ids and attributes — which is most
    of what an evaluation does — needs nothing outside the standard library.
    Only `Mesh` and `Polylines` reach this.
    """
    global _numpy_module
    if _numpy_module is None:
        import numpy

        _numpy_module = numpy
    return _numpy_module


def _text(raw) -> str:
    """A borrowed `char *` as a `str`. Null and empty both come back as `""`."""
    return raw.decode("utf-8", "replace") if raw else ""


def _last_error() -> str:
    return _text(_lib().cadaclysm_last_error())


def _packed(colour) -> int:
    """A colour as the ABI's packed `0xRRGGBB`: `'#rrggbb'` or an `(r, g, b)` triple."""
    if isinstance(colour, str):
        h = colour.lstrip("#")
        if len(h) != 6:
            raise ValueError(f"colour {colour!r}: '#rrggbb' or (r, g, b)")
        return int(h, 16)
    r, g, b = colour
    return (int(r) << 16) | (int(g) << 8) | int(b)


def _svg_options(default_up, *, view="iso", az=None, el=None, up=None, fov=0.0, size=(1000, 1000), margin=0.05,
                 tolerance=0.1, stroke="#000000", width=1.0, background=None, edges=True, curves=False,
                 isocurves=False, polylines=False) -> _SvgOptions:
    """`Scene.svg`/`Node.svg`'s keywords, packed into `CadaclysmSvgOptions`: `view`
    through the viewer's own table (`cadaclysm_viewer.VIEWS`, the one `show` reads
    too), `az`/`el` over it, `up` from the scene's convention unless given, colours
    as `'#rrggbb'` or an `(r, g, b)` triple."""
    VIEWS = _viewer().VIEWS   # the one table both show() and svg() read, found the way show() finds it

    if view not in VIEWS:
        raise ValueError(f"view {view!r}: one of {', '.join(VIEWS)}")
    base_az, base_el = VIEWS[view]
    o = _SvgOptions()
    _lib().cadaclysm_svg_options_init(ctypes.byref(o))
    o.up = 1 if (up or default_up).lower() == "y" else 0
    o.azimuth = float(base_az if az is None else az)
    o.elevation = float(base_el if el is None else el)
    o.fov = float(fov)
    o.width, o.height = float(size[0]), float(size[1])
    o.margin, o.tolerance, o.stroke_width = float(margin), float(tolerance), float(width)
    o.stroke = _packed(stroke)
    o.background = NONE if background is None else _packed(background)
    o.flags = (1 if edges else 0) | (2 if curves else 0) | (4 if isocurves else 0) | (8 if polylines else 0)
    return o


def version() -> str:
    """The version of the library actually loaded, which is the one worth reporting."""
    return _text(_lib().cadaclysm_version())


def license(text_or_path) -> None:
    """Load a license: the certificate text, or the path of a file holding it.

    Without this the library looks in ``CADACLYSM_LICENSE``, then for
    ``cadaclysm.lic`` beside the running executable and in the working
    directory. Raises with the library's reason when the text does not verify;
    the previous license, if any, stays in use.
    """
    text = os.fspath(text_or_path) if not isinstance(text_or_path, str) else text_or_path
    if not _lib().cadaclysm_license_set(text.encode("utf-8")):
        raise CadaclysmError(_last_error() or "license refused")


def license_info() -> str:
    """One line about the license the library is running under.

    Never null: the license line, e.g. ``"customer=Acme Ltd
    expiry=2027-09-15 entitlements=import,kernel"``, or, without one,
    ``"unlicensed"`` (``"unlicensed -- <reason>"`` when a license was found
    but did not verify).
    """
    return _text(_lib().cadaclysm_license_info())


def license_notice_count() -> int:
    """How many unlicensed notices this library has printed to stderr in this
    process. An application without a stderr to watch (a GUI, a game) can
    show its own banner by polling this instead."""
    return int(_lib().cadaclysm_license_notice_count())


def build_date() -> str:
    """When the loaded library was built, ``YYYY-MM-DD``; a paid license covers every build dated on or before its expiry."""
    return _text(_lib().cadaclysm_build_date())


def mesh_formats() -> "list[tuple[str, str, str]]":
    """Every format `Node.save_mesh` writes, as `(name, extension, label)`.

    Ask rather than hard-code: a format added to the library turns up in a menu
    built from this without the client being touched, which is the whole reason
    the ABI enumerates them. The extension is carried because it is not
    derivable -- `stl-ascii` writes a `.stl` -- and the label is what to show
    in that menu: `STL (binary)`, `Gmsh`.
    """
    library = _lib()
    return [
        (_text(library.cadaclysm_mesh_format(i)),
         _text(library.cadaclysm_mesh_format_extension(i)),
         _text(library.cadaclysm_mesh_format_label(i)))
        for i in range(library.cadaclysm_mesh_format_count())
    ]


def lod_levels() -> int:
    """How many coarser levels `Node.mesh_lod` offers above the mesh itself (level 0)."""
    return _lib().cadaclysm_lod_levels()


def formats() -> "list[tuple[str, list[str]]]":
    """Every format this build reads, as `(name, extensions)`: `("IGES", ["iges", "igs"])`.

    What an open dialog's filter is built from, the same way `mesh_formats` feeds
    a save menu. The ABI hands the extensions over semicolon-separated, the way
    dialogs want them; here they are split.
    """
    library = _lib()
    return [
        (_text(library.cadaclysm_format_name(i)),
         [e for e in _text(library.cadaclysm_format_extensions(i)).split(";") if e])
        for i in range(library.cadaclysm_format_count())
    ]


def pick_file() -> "Path | None":
    """Ask the user for a file to open, through the library's own dialog.

    `None` if they cancelled — or if no dialog was available, which on Linux
    means neither an XDG portal nor `zenity`. The ABI cannot tell those two
    apart and neither can this, so a caller treats both as "no file", which is
    the right answer either way.

    The filters come from what this build can read, so a reader added to the
    library turns up in the dialog without anything here being touched. That is
    the same reason `mesh_formats` exists.

    Blocks until the user acts. On macOS it must be called from the main thread.
    """
    raw = _lib().cadaclysm_pick_file(None)
    if not raw:
        return None
    # Borrowed, and only until the next picker call on this thread — so it is
    # copied into a `Path` here rather than held.
    return Path(_text(raw))


def pick_save(suggested_name=None) -> "Path | None":
    """Ask the user where to save, through the library's own dialog.

    `suggested_name` prefills the file name. `None` if they cancelled or no
    dialog was available, as `pick_file`. Blocks until the user acts; on macOS
    it must be called from the main thread.
    """
    raw = _lib().cadaclysm_pick_save(None, None if suggested_name is None else str(suggested_name).encode())
    if not raw:
        return None
    return Path(_text(raw))


# ---- borrowed memory, seen as numpy ---------------------------------------


class _Borrowed:
    """One block of borrowed memory, exposed through the array interface.

    Two properties come out of building views this way rather than with
    `numpy.ctypeslib.as_array`, and both are load-bearing:

    * `data` carries the read-only flag, so `numpy` marks the array
      unwriteable and a stray assignment raises instead of scribbling on the
      document's own vertex buffer.
    * The array `numpy` builds holds this object as its `.base`, and this
      object holds the owner — so no view can outlive what it borrows from by
      having merely dropped the last reference to it. An explicit release still
      invalidates every view, which is the documented sharp edge.

    **The owner is whatever the memory belongs to, not always the `Scene`.** A
    mesh, a polyline set and a collision hull borrow from the open document, so
    the owner is the scene and `Scene.close()` is what invalidates them; a
    `FemMesh`'s arrays borrow from that handle, so the owner is the `FemMesh`
    and its own `free()` is. Passing the scene for a FEM array would let the
    handle die under a live view.
    """

    __slots__ = ("_owner", "__array_interface__")

    def __init__(self, owner, pointer, shape, typestr):
        self._owner = owner
        self.__array_interface__ = {
            "version": 3,
            "data": (ctypes.cast(pointer, c_void_p).value, True),
            "shape": shape,
            "typestr": typestr,
        }


def _view(owner, pointer, shape, dtype):
    """A read-only numpy view of `shape` over memory borrowed from `owner`
    (a `Scene`, or a `FemMesh`), or None if null."""
    if not pointer:
        return None
    numpy = _numpy()
    return numpy.asarray(_Borrowed(owner, pointer, shape, numpy.dtype(dtype).str))


# ---- the values the ABI hands over ----------------------------------------


class Bounds:
    """An axis-aligned box, or all zeros where there was nothing to bound."""

    __slots__ = ("min", "max")

    def __init__(self, low, high):
        self.min = tuple(float(v) for v in low)
        self.max = tuple(float(v) for v in high)

    @property
    def is_empty(self) -> bool:
        """Whether this is the all-zero box the ABI uses for "nothing here"."""
        return not any(self.min) and not any(self.max)

    @property
    def size(self):
        return tuple(b - a for a, b in zip(self.min, self.max))

    @property
    def centre(self):
        return tuple((a + b) / 2.0 for a, b in zip(self.min, self.max))

    def __iter__(self):
        """Unpacks as `low, high`, so `low, high = node.bounds` works."""
        return iter((self.min, self.max))

    def __repr__(self):
        return f"Bounds(min={self.min}, max={self.max})"


def _decimal_text(value: float) -> str:
    """A float written out the way cadaclysm's own Rust `Display` writes it.

    Rust's `Display for f64` never switches to exponent notation, and prints
    the shortest decimal that round-trips. Python's `repr` gives the same
    digits but does switch — `1e16` and `1e-05` — so the digits are taken from
    `repr` and spelled out through `Decimal`, which for a finite value is
    exactly what the Go client's `strconv.FormatFloat(v, 'f', -1, 64)` does.
    Without this a thickness of 1e-05 metres prints in a form no other client
    shows. The infinities are where Go and Rust part company; this follows
    Rust.
    """
    if value != value or value in (float("inf"), float("-inf")):
        # Decimal("inf") formats as "Infinity"; Rust prints "inf" and "NaN".
        return "NaN" if value != value else ("inf" if value > 0 else "-inf")
    return format(decimal.Decimal(repr(value)).normalize(), "f")


class Attribute:
    """One thing the file said about a node.

    `value` is already the Python type the kind names: `str` for TEXT, LIST and
    REFERENCE, `int` for INTEGER, `float` for REAL, `bool` for BOOLEAN, and
    `None` for NONE. `kind` says which, for a caller that wants to tell a
    reference from prose or total the numbers rather than print them.
    """

    __slots__ = ("name", "kind", "value")

    def __init__(self, name, kind, value):
        self.name = name
        self.kind = kind
        self.value = value

    @property
    def text(self) -> str:
        """The value rendered for display, as cadaclysm's own Rust `Display` does.

        Agrees exactly with what the Go, C# and Java clients print for every
        finite value. The one divergence is the infinities: this prints `inf`
        and `-inf`, which is what Rust writes, where Go's `FormatFloat` writes
        `+Inf` and `-Inf`. Rust is the library's own rendering, so it wins.
        """
        if self.value is None:
            return ""
        if self.kind is ValueKind.REAL:
            return _decimal_text(self.value)
        if self.kind is ValueKind.BOOLEAN:
            # Go's "%t" and C#'s bool.ToString() lowercased: "true"/"false",
            # not Python's "True"/"False".
            return "true" if self.value else "false"
        return str(self.value)

    def __repr__(self):
        return f"Attribute(name={self.name!r}, kind={self.kind.name}, value={self.value!r})"


def _attribute(raw) -> "Attribute | None":
    """A `CadaclysmAttribute` as an `Attribute`, or None for one past the end.

    **The kind picks exactly one field to read.** The others are zero, so
    reading the wrong one is silent: a text attribute read as `integer` gives
    0 for every node in the file and looks like data.
    """
    # Null specifically, as the Go client's `a.name == nil` tests. The header
    # promises only "an all-zero one past the end", so an attribute the file
    # genuinely named `""` is a real attribute and is kept — `not raw.name`
    # would have thrown it away with the terminator.
    if raw.name is None:
        return None
    kind = ValueKind(raw.kind) if raw.kind in _KINDS else ValueKind.NONE
    if kind in (ValueKind.TEXT, ValueKind.LIST, ValueKind.REFERENCE):
        value = _text(raw.text)
    elif kind is ValueKind.INTEGER:
        value = int(raw.integer)
    elif kind is ValueKind.REAL:
        value = float(raw.real)
    elif kind is ValueKind.BOOLEAN:
        value = bool(raw.boolean)
    else:
        value = None
    return Attribute(_text(raw.name), kind, value)


_KINDS = frozenset(int(k) for k in ValueKind)


class Mesh:
    """A node's triangles, in the node's own frame.

    `positions` and `normals` are `(vertex_count, 3)` float32, `uvs` is
    `(vertex_count, 2)` float32 and `indices` is `(index_count,)` uint32, three
    to a triangle. All four are read-only views into the scene — see the module
    docstring — and `normals` is None for a mesh that carries none. From
    `Node.mesh64`, `positions`, `normals` and `uvs` are float64 instead — the
    document's own mesh, unnarrowed — while `colors` stays float32 either way.

    `uvs` is None for a node whose reader produced none — which is most of
    them unless the scene was opened with `UV_WORLD`; see that constant for the
    one case that does not need it. One unit of `u` or `v` is one world unit,
    so faces do not share an origin and their charts overlap: a tiling
    material, not a lightmap.
    """

    __slots__ = ("positions", "normals", "uvs", "colors", "indices",
                 "vertex_count", "index_count")

    def __init__(self, positions, normals, uvs, colors, indices, vertex_count, index_count):
        self.positions = positions
        self.normals = normals
        self.uvs = uvs
        #: `(vertex_count, 4)` float32 RGBA, or None -- which is the common
        #: case. Only a body the file painted in more than one colour, opened
        #: with `colors=True`, carries them; otherwise the node's own colour
        #: says everything there is to say.
        self.colors = colors
        self.indices = indices
        self.vertex_count = vertex_count
        self.index_count = index_count

    @property
    def triangle_count(self) -> int:
        return self.index_count // 3

    def __bool__(self) -> bool:
        """False for a node with no triangles, so `if node.mesh:` reads right.

        A node drawn as a *curve* answers `can_mesh` and has an empty mesh,
        having no surface to triangulate.
        """
        return self.index_count > 0 and self.positions is not None

    def copy(self) -> "Mesh":
        """The same triangles in memory of our own, safe to outlive the scene.

        Expensive on purpose to be visible: this is where the gigabytes go on a
        large assembly, and it should be a line a reader can point at.
        """
        return Mesh(
            None if self.positions is None else self.positions.copy(),
            None if self.normals is None else self.normals.copy(),
            None if self.uvs is None else self.uvs.copy(),
            None if self.colors is None else self.colors.copy(),
            None if self.indices is None else self.indices.copy(),
            self.vertex_count,
            self.index_count,
        )

    def __repr__(self):
        return f"Mesh(vertices={self.vertex_count}, triangles={self.triangle_count})"


class Polylines:
    """A node's feature edges or free curves, already flattened to points.

    `positions` is `(vertex_count, 3)` float32 with the runs end to end, and
    `counts` is `(polyline_count,)` uint32 saying where each run stops. Both
    are read-only views into the scene.
    """

    __slots__ = ("positions", "counts", "polyline_count", "vertex_count")

    def __init__(self, positions, counts, polyline_count, vertex_count):
        self.positions = positions
        self.counts = counts
        self.polyline_count = polyline_count
        self.vertex_count = vertex_count

    def __bool__(self) -> bool:
        return self.polyline_count > 0 and self.positions is not None

    def segment_indices(self):
        """Indices into `positions` making line-segment endpoint pairs.

        `GL_LINES` and every other pair-taking API want two endpoints per
        segment, while the ABI hands over runs: a polyline of n points is n - 1
        segments, so each interior point is named twice. Handing back indices
        rather than points lets a caller transform the `vertex_count` positions
        once and expand afterwards, instead of transforming the roughly twice
        as many expanded endpoints.

        Vectorised, because a real assembly has millions of these: `ufi.stp`
        alone carries 4.7M segments, and a Python loop over them costs more
        than reading the 224 MB file did.
        """
        numpy = _numpy()
        empty = numpy.empty(0, numpy.int64)
        if not self:
            return empty
        counts = self.counts
        # Where each run starts, and which runs are long enough to have a
        # segment at all: a one-point run is a point, not a line.
        starts = numpy.concatenate(([0], numpy.cumsum(counts[:-1], dtype=numpy.int64)))
        keep = counts >= 2
        if not keep.any():
            return empty
        lengths = counts[keep].astype(numpy.int64) - 1
        # Within each kept run emit 0,1 1,2 2,3 ...: `first` repeats the run's
        # start once per segment and `step` counts 0..n-2 within the run,
        # built for the whole set at once rather than per polyline.
        first = numpy.repeat(starts[keep], lengths)
        step = numpy.arange(len(first)) - numpy.repeat(
            numpy.concatenate(([0], numpy.cumsum(lengths[:-1]))), lengths
        )
        a = first + step
        pairs = numpy.empty(len(a) * 2, numpy.int64)
        pairs[0::2], pairs[1::2] = a, a + 1
        return pairs

    def segments(self):
        """The endpoint pairs themselves, `(2 * segment_count, 3)` in the node's own frame."""
        return self.positions[self.segment_indices()]

    def __repr__(self):
        return f"Polylines(polylines={self.polyline_count}, vertices={self.vertex_count})"


class Beziers:
    """A node's edges, free curves or isocurves as cubic Bézier curves, exact where
    the file's curves were.

    `points` is `(count, 4, 3)` float32 -- four control points a curve -- and
    `weights` is `(count, 4)` float32, all ones for a polynomial curve; a rational
    one (a circle's arc) carries the weights that make it exact. Read-only views
    into the scene, like `Polylines`; `copy()` makes arrays of your own. From
    `Node.edge_beziers64` and its `curve_beziers64`/`isocurve_beziers64` twins,
    both arrays are float64 instead.
    """

    __slots__ = ("points", "weights", "count")

    def __init__(self, points, weights, count):
        self.points = points
        self.weights = weights
        self.count = count

    def __bool__(self) -> bool:
        return self.count > 0 and self.points is not None

    def copy(self) -> "Beziers":
        return Beziers(
            None if self.points is None else self.points.copy(),
            None if self.weights is None else self.weights.copy(),
            self.count,
        )

    def __repr__(self):
        return f"Beziers(count={self.count})"


class Collision:
    """What a node turned out to be for a physics engine: a box, sphere, capsule or
    cylinder where one fits within `error`, else a convex hull. `frame` (16 numbers,
    column-major) and `half_extent` are always the true oriented box; `radius`,
    `height` and `axis` mean what the shape needs. Plain data, copied out."""

    __slots__ = ("shape", "confidence", "axis", "frame", "half_extent", "radius", "height",
                 "error", "hull_vertex_count", "hull_index_count")
    _NAMES = ("none", "box", "sphere", "capsule", "cylinder", "hull")

    def __init__(self, raw):
        self.shape = raw.shape
        self.confidence = raw.confidence
        self.axis = raw.axis
        self.frame = tuple(raw.frame)
        self.half_extent = tuple(raw.half_extent)
        self.radius = raw.radius
        self.height = raw.height
        self.error = raw.error
        self.hull_vertex_count = raw.hull_vertex_count
        self.hull_index_count = raw.hull_index_count

    @property
    def shape_name(self) -> str:
        """`none`, `box`, `sphere`, `capsule`, `cylinder` or `hull`."""
        return self._NAMES[self.shape] if self.shape < len(self._NAMES) else str(self.shape)

    def __repr__(self):
        return f"Collision({self.shape_name}, error={self.error})"


class CollisionHull:
    """A node's convex hull for a physics engine: `positions` `(vertex_count, 3)`
    float32 and `indices` `(index_count,)` uint32, three a triangle. Views into the
    scene, like `Mesh`."""

    __slots__ = ("positions", "indices", "vertex_count", "index_count")

    def __init__(self, positions, indices, vertex_count, index_count):
        self.positions = positions
        self.indices = indices
        self.vertex_count = vertex_count
        self.index_count = index_count

    def __bool__(self) -> bool:
        return self.vertex_count > 0 and self.positions is not None

    def __repr__(self):
        return f"CollisionHull(vertices={self.vertex_count}, triangles={self.index_count // 3})"


# ---- placements -----------------------------------------------------------




class Face:
    """One trimmed face: the surface itself, plus the loops that cut it.

    `kind` is 0 plane, 1 cylinder, 2 cone, 3 sphere, 4 torus, 5 revolution, 6 extrusion,
    7 NURBS, 8 sum. `origin`, `ax`, `ay`, `az` are the frame; `scalars` is kind-dependent;
    `domain` is `(u_min, v_min, u_max, v_max)`. `loops` is a list of `(N, 2)` arrays of
    `(u, v)`, each closing implicitly, and `profile` and `nurbs` carry what a swept or
    NURBS surface needs. See `CadaclysmFace` in the header for the whole story.
    """

    __slots__ = ("kind", "reversed", "transposed", "origin", "ax", "ay", "az",
                 "domain", "scalars", "loops", "profile", "profile2", "nurbs")

    def __init__(self, **fields):
        for name, value in fields.items():
            setattr(self, name, value)

    def __repr__(self):
        names = ("plane", "cylinder", "cone", "sphere", "torus", "revolution",
                 "extrusion", "nurbs", "sum")
        kind = names[self.kind] if self.kind < len(names) else self.kind
        return f"Face({kind}, {len(self.loops)} loops)"


class Surfaces:
    """A part's faces as surfaces and trims, and the arrays they share.

    Iterate it for `Face` objects. Everything here is **in the file's own frame**, unlike
    every other product this module hands back -- see `Scene.surface_matrix`.
    """

    __slots__ = ("faces",)

    def __init__(self, faces):
        self.faces = faces

    def __bool__(self) -> bool:
        return bool(self.faces)

    def __len__(self) -> int:
        return len(self.faces)

    def __iter__(self):
        return iter(self.faces)

    def __repr__(self):
        return f"Surfaces({len(self.faces)} faces)"


class Placement:
    """One drawing of one node's geometry, at one place.

    **A node is not a drawing, and the difference is a bug this library shipped.**
    Most nodes are structure and draw nothing; a node that places a block draws
    everything inside that block; and a block's members draw once per placement of
    it rather than once on their own account. A viewer that walks nodes and asks
    each for a mesh draws a Rhino block's contents once, at the definition's own
    frame, and every placement of it not at all -- which is what `instances.3dm`
    looked like here: one tube where the file has six.

    So iterate `scene.placements` to draw, and nodes to build a tree. A handle
    rather than a snapshot, like `Node`, so nothing here goes stale.
    """

    __slots__ = ("scene", "index")

    def __init__(self, scene: "Scene", index: int):
        self.scene = scene
        self.index = index

    @property
    def geometry(self) -> "Node":
        """The node whose mesh, edges and curves this draws.

        Two drawings of one shape name the same node and so hand back the same
        arrays -- which is what lets a caller upload it once and draw it twice.
        """
        return Node(self.scene,
                    _lib().cadaclysm_placement_geometry(self.scene._handle, self.index))

    @property
    def select(self) -> "Node":
        """What a click on this drawing should select.

        The placement rather than the shape it draws: the shape is somewhere else
        and is shared with every sibling copy, so selecting it would light them
        all up.
        """
        return Node(self.scene,
                    _lib().cadaclysm_placement_select(self.scene._handle, self.index))

    @property
    def transform(self):
        """Where to draw it, as a 4x4 float64 numpy array.

        Already composed through every frame between the document's root and this
        drawing, so nothing is multiplied here. Transposed into numpy's row-major
        convention for the reason `Node.transform` gives, and `raw_transform`
        keeps the ABI's own order.
        """
        numpy = _numpy()
        return numpy.array(self.raw_transform, numpy.float64).reshape(4, 4).T

    @property
    def raw_transform(self):
        """The same matrix in the ABI's own column-major order, as 16 floats."""
        out = (c_double * 16)()
        _lib().cadaclysm_placement_transform(self.scene._handle, self.index, out)
        return tuple(out)

    def __repr__(self):
        return f"Placement(index={self.index}, geometry={self.geometry.index})"


class Link:
    """A rigid body of the file's mechanism: the nodes that move together when a joint
    moves it. From `Scene.links`; borrows from the scene like `Node`."""

    __slots__ = ("scene", "index")

    def __init__(self, scene: "Scene", index: int):
        self.scene = scene
        self.index = index

    def __eq__(self, other):
        return (
            isinstance(other, Link)
            and other.index == self.index
            and other.scene is self.scene
        )

    def __hash__(self):
        return hash((id(self.scene), self.index))

    def __repr__(self):
        return f"<Link {self.index} {self.name}>"

    @property
    def name(self) -> str:
        """The link's name as the file gives it."""
        return _text(_lib().cadaclysm_link_name(self.scene._handle, self.index))

    @property
    def nodes(self) -> "list[Node]":
        """The topmost node of each subtree this link moves, in node order: moving these
        moves everything under them."""
        library, handle = _lib(), self.scene._handle
        return [
            Node(self.scene, library.cadaclysm_link_node(handle, self.index, i))
            for i in range(library.cadaclysm_link_node_count(handle, self.index))
        ]


class Joint:
    """A connection between two links of the file's mechanism. Topology only: how it
    moves is not read yet. From `Scene.joints`."""

    __slots__ = ("scene", "index")

    def __init__(self, scene: "Scene", index: int):
        self.scene = scene
        self.index = index

    def __eq__(self, other):
        return (
            isinstance(other, Joint)
            and other.index == self.index
            and other.scene is self.scene
        )

    def __hash__(self):
        return hash((id(self.scene), self.index))

    def __repr__(self):
        return f"<Joint {self.index} {self.name}>"

    @property
    def name(self) -> str:
        """The joint's name as the file gives it."""
        return _text(_lib().cadaclysm_joint_name(self.scene._handle, self.index))

    @property
    def start(self) -> Link:
        """The link this joint starts at, in the file's order -- not a parent: a
        mechanism may be a network with loops."""
        return Link(self.scene, _lib().cadaclysm_joint_start(self.scene._handle, self.index))

    @property
    def end(self) -> Link:
        """The link this joint ends at."""
        return Link(self.scene, _lib().cadaclysm_joint_end(self.scene._handle, self.index))


# ---- drawing ----------------------------------------------------------------


def _viewer():
    """The viewer loader: `cadaclysm.viewer` in the wheel, `cadaclysm_viewer` beside this
    module in a checkout. Imported only when something is drawn."""
    try:
        from cadaclysm import viewer
        return viewer
    except ImportError:
        pass
    try:
        import cadaclysm_viewer
        return cadaclysm_viewer
    except ImportError:
        here = Path(__file__).resolve().parent
        sys.path.insert(0, str(here))
        import cadaclysm_viewer
        return cadaclysm_viewer


_Y_UP = {int(Convention.UNITY), int(Convention.Y_UP)}


def _drawn_placements(placements, edges):
    """(meshes, polylines) for the loader, one entry per drawing -- see `Placement`.

    Each placement draws its geometry's mesh (or, for a node drawn as a curve, its
    curves) through the placement's own transform, in the colour of what a click on it
    selects -- else the shape's -- and only while that selected node is visible. With
    `edges`, a meshed placement brings its B-rep edges too, through the same matrix.
    """
    meshes, lines = [], []
    for place in placements:
        select = place.select
        if not select.visible_now:
            continue
        node = place.geometry
        if not node.can_mesh:
            continue
        colour = select.colour or node.colour
        rgb = None if colour is None else colour[:3]
        matrix = place.raw_transform
        mesh = node.mesh
        if mesh:
            meshes.append((mesh.positions, mesh.normals, mesh.indices, matrix, rgb))
            if edges:
                outline = node.edges
                if outline:
                    lines.append((outline.positions, outline.counts, matrix, None))
        else:
            curves = node.curves
            if curves:
                lines.append((curves.positions, curves.counts, matrix, rgb))
    return meshes, lines


# ---- nodes ----------------------------------------------------------------


class Brep:
    """A body's exact B-rep -- the trimmed surfaces its mesh is cut from --
    shared with the scene rather than copied: a reference of this object's own,
    given back by `release()` (or leaving a `with` block, or the collector).

    It is for the blacksmith library, which operates on it without a copy
    (`cadaclysm_blacksmith.Solid.from_node`) -- `pointer` and `layout_id` are
    what that hands across -- and for asking whether it is a manifold
    (`manifold`). The brep outlives the scene it came from for as long as
    anything holds it.

    In the node's own frame and **the file's own units and axes**, whatever
    convention the scene was opened with. The blacksmith library must come
    from the same release as this one; it checks `layout_id` and refuses
    otherwise.
    """

    __slots__ = ("_pointer", "__weakref__")

    def __init__(self, pointer: int):
        self._pointer = pointer

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.release()

    def __del__(self):
        self.release()

    @property
    def pointer(self) -> int:
        if not self._pointer:
            raise CadaclysmError("brep: released")
        return self._pointer

    @staticmethod
    def layout_id() -> str:
        """How this library lays a brep out in memory: its compiler, target and
        source. The blacksmith library shares a brep only with a library whose
        id equals its own."""
        return _text(_lib().cadaclysm_brep_layout_id())

    @property
    def manifold(self) -> "Manifold":
        """Whether its faces make a manifold -- every edge bordered by one face
        or two, the faces round every vertex one fan -- and whether it is
        closed, as a `Manifold` record. Read off the topology the file wrote,
        not a mesh: faces that name no shared edge (IGES, each surface its own
        sheet; an IFC face written as one polygon) read as open however well
        they meet in space."""
        out = (c_uint32 * 8)()
        if not _lib().cadaclysm_brep_manifold(self.pointer, out):
            raise CadaclysmError(_text(_lib().cadaclysm_last_error()) or "manifold")
        return Manifold(tuple(out))

    def release(self) -> None:
        pointer, self._pointer = getattr(self, "_pointer", None), None
        if pointer and _library is not None:
            _library.cadaclysm_brep_release(pointer)


class Manifold:
    """Whether a brep's faces make a manifold, as plain data (`Brep.manifold`):
    its faces, edges and vertices; the edges one face borders (a sheet's rim),
    the edges three or more do, and the vertices whose faces make more than one
    fan (two solids touching at a corner); `is_manifold` where there are none of
    the last two, and `is_closed` where there is no boundary edge either -- it
    encloses a solid."""

    __slots__ = ("faces", "edges", "vertices", "boundary_edges", "non_manifold_edges", "non_manifold_vertices",
                 "is_manifold", "is_closed")

    def __init__(self, row):
        (self.faces, self.edges, self.vertices, self.boundary_edges, self.non_manifold_edges,
         self.non_manifold_vertices) = (int(v) for v in row[:6])
        self.is_manifold, self.is_closed = bool(row[6]), bool(row[7])

    def __repr__(self):
        return (f"Manifold(faces={self.faces}, edges={self.edges}, vertices={self.vertices}, "
                f"boundary_edges={self.boundary_edges}, non_manifold_edges={self.non_manifold_edges}, "
                f"non_manifold_vertices={self.non_manifold_vertices}, is_manifold={self.is_manifold}, "
                f"is_closed={self.is_closed})")


class Meshlet:
    """One meshlet, copied out: its arrays are yours."""

    __slots__ = ("index", "level", "group", "error", "vertex_count", "triangle_count",
                 "positions", "normals", "indices", "children")

    def __init__(self, index, level, group, error, vertex_count, triangle_count,
                 positions, normals, indices, children):
        self.index = index
        self.level = level
        self.group = group
        self.error = error
        self.vertex_count = vertex_count
        self.triangle_count = triangle_count
        #: `(vertex_count, 3)` float32.
        self.positions = positions
        #: `(vertex_count, 3)` float32 (zeros where the mesh had none).
        self.normals = normals
        #: `(triangle_count * 3,)` uint32, into this meshlet's own vertices.
        self.indices = indices
        #: `(child_count,)` uint32: the finer meshlets below this one, for a levelled build.
        self.children = children

    def __repr__(self):
        return f"Meshlet(index={self.index}, level={self.level}, vertices={self.vertex_count}, triangles={self.triangle_count})"


class Meshlets:
    """A mesh split into meshlets, optionally with coarser levels above them, for a
    mesh-shader or meshlet-based renderer. Built from any mesh -- a `Node.mesh` or
    arrays of your own -- and owned by you: `free()` it, or use it as a context
    manager."""

    __slots__ = ("_pointer", "__weakref__")

    def __init__(self, pointer: int):
        self._pointer = pointer

    @staticmethod
    def build(positions, normals, indices, max_triangles: int, max_vertices: int, levels: int = 0) -> "Meshlets":
        """Split `positions` (three floats a vertex), `normals` (the same, or None) and
        `indices` (three a triangle) into meshlets of at most `max_triangles` and
        `max_vertices` each -- the consumer's own limits, with no default: Nanite
        takes 128/256, a mesh-shader pipeline 124/64. `levels` above 0 groups and
        simplifies each level into the next until one meshlet is left; `level(i)`
        and `meshlet(i).children` say which is which."""
        numpy = _numpy()
        if not (max_triangles > 0 and max_vertices > 0):
            raise CadaclysmError("meshlets: max_triangles and max_vertices are required")
        p = numpy.ascontiguousarray(positions, dtype=numpy.float32).reshape(-1)
        i = numpy.ascontiguousarray(indices, dtype=numpy.uint32).reshape(-1)
        n = None if normals is None else numpy.ascontiguousarray(normals, dtype=numpy.float32).reshape(-1)
        if p.size % 3 or i.size % 3:
            raise CadaclysmError("meshlets: positions must hold three floats a vertex and indices three a triangle")
        if n is not None and n.size != p.size:
            raise CadaclysmError("meshlets: normals must hold one per vertex, three floats each")
        pointer = _lib().cadaclysm_meshlets_build(
            p.ctypes.data_as(POINTER(c_float)),
            None if n is None else n.ctypes.data_as(POINTER(c_float)),
            p.size // 3,
            i.ctypes.data_as(POINTER(c_uint32)),
            i.size,
            max_triangles, max_vertices, levels,
        )
        if not pointer:
            raise CadaclysmError(_last_error() or "meshlets: build failed")
        return Meshlets(pointer)

    @property
    def _handle(self) -> int:
        if not self._pointer:
            raise CadaclysmError("meshlets: freed")
        return self._pointer

    @property
    def freed(self) -> bool:
        return not self._pointer

    def free(self) -> None:
        """Give the meshlets back. Idempotent."""
        pointer, self._pointer = self._pointer, None
        if pointer:
            _lib().cadaclysm_meshlets_free(pointer)

    def __enter__(self) -> "Meshlets":
        return self

    def __exit__(self, *_):
        self.free()

    def __del__(self):
        try:
            self.free()
        except Exception:  # noqa: BLE001 - the interpreter may be going down
            pass

    @property
    def count(self) -> int:
        """How many meshlets, every level counted."""
        return _lib().cadaclysm_meshlets_count(self._handle)

    def __len__(self) -> int:
        return self.count

    def triangle_count(self, i: int) -> int:
        return _lib().cadaclysm_meshlet_triangle_count(self._handle, i)

    def vertex_count(self, i: int) -> int:
        return _lib().cadaclysm_meshlet_vertex_count(self._handle, i)

    def level(self, i: int) -> int:
        """0 for a leaf over the mesh itself, higher for a simplified level above it."""
        return _lib().cadaclysm_meshlet_level(self._handle, i)

    def group(self, i: int) -> int:
        return _lib().cadaclysm_meshlet_group(self._handle, i)

    def error(self, i: int) -> float:
        """How far this meshlet's level moved the surface; zero at level 0."""
        return _lib().cadaclysm_meshlet_error(self._handle, i)

    def child_count(self, i: int) -> int:
        return _lib().cadaclysm_meshlet_child_count(self._handle, i)

    def meshlet(self, i: int) -> Meshlet:
        """One meshlet's arrays and numbers, copied out."""
        numpy = _numpy()
        library, handle = _lib(), self._handle
        vertex_count = library.cadaclysm_meshlet_vertex_count(handle, i)
        triangle_count = library.cadaclysm_meshlet_triangle_count(handle, i)
        child_count = library.cadaclysm_meshlet_child_count(handle, i)
        positions = numpy.zeros(vertex_count * 3, numpy.float32)
        normals = numpy.zeros(vertex_count * 3, numpy.float32)
        indices = numpy.zeros(triangle_count * 3, numpy.uint32)
        children = numpy.zeros(child_count, numpy.uint32)
        library.cadaclysm_meshlet_positions(handle, i, positions.ctypes.data_as(POINTER(c_float)))
        library.cadaclysm_meshlet_normals(handle, i, normals.ctypes.data_as(POINTER(c_float)))
        library.cadaclysm_meshlet_indices(handle, i, indices.ctypes.data_as(POINTER(c_uint32)))
        library.cadaclysm_meshlet_children(handle, i, children.ctypes.data_as(POINTER(c_uint32)))
        return Meshlet(
            i, library.cadaclysm_meshlet_level(handle, i), library.cadaclysm_meshlet_group(handle, i),
            library.cadaclysm_meshlet_error(handle, i), vertex_count, triangle_count,
            positions.reshape(vertex_count, 3), normals.reshape(vertex_count, 3), indices, children,
        )

    def __repr__(self):
        return "Meshlets(freed)" if self.freed else f"Meshlets(count={self.count})"


class FemEdge:
    """One B-rep edge of a FEM mesh: the chain of nodes along it, and where that
    chain breaks. Plain data, copied out of the handle.

    `nodes` are this mesh's node indices in order along the edge, its end
    vertices included; a closed edge repeats no node. **`runs` says where the
    chain breaks**: read `nodes[runs[i]:runs[i + 1]]` (the last run to the end)
    as one polyline and join nothing across a run boundary. The two ends either
    side of one are two points of the edge with no mesh edge between them -- a
    crack along the edge, or a stretch of it the mesher sampled on one face
    only. `(0,)` is the ordinary answer, and a caller reading `nodes` as one
    polyline without looking here silently jumps the gap.

    `faces` is `(face_a, face_b)` and `ends` is `(end_a, end_b)`, the second of
    each being `NONE` where there is none -- an open body's rim, or both ends at
    one vertex (a closed edge, a circle's rim, a full-turn seam). **`0` is a
    real face and a real vertex, not a sentinel.** Which end comes first is the
    first trim's direction and means nothing else: the pair bounds the edge, it
    does not orient it.

    `closed` where the nodes make one loop -- never where there is more than one
    run. `seam` where one face bounds the edge twice, a closed surface's seam
    rather than a real boundary; both `faces` are then that same face.

    `id` is **the body's own edge id**, not this mesh's edge index: `FemMesh.edges`
    is a densely renumbered subset of the body's edges, ascending by id, with every
    edge collapsed to a point left out, so edge 0 of a STEP body's mesh routinely
    has an `id` in the hundreds. Everything else that names an edge here means the
    index -- a `node_kind` of 1 read through `node_entity`, the third number of an
    `open_edges` or `folded_edges` row, and the `edge_<i>` physical group of
    `msh_text` -- and this is the one way back from any of them to the topology the
    file wrote.
    """

    __slots__ = ("id", "nodes", "runs", "faces", "ends", "closed", "seam")

    def __init__(self, id, nodes, runs, faces, ends, closed, seam):
        #: The body's own B-rep edge id -- not this mesh's edge index.
        self.id = id
        #: This mesh's node indices, in order along the edge.
        self.nodes = nodes
        #: Where each connected run of `nodes` begins; `(0,)` for one chain.
        self.runs = runs
        #: `(face_a, face_b)`, the second `NONE` on a rim.
        self.faces = faces
        #: `(end_a, end_b)`, the second `NONE` where both ends are one vertex.
        self.ends = ends
        self.closed = closed
        self.seam = seam

    def __repr__(self):
        return (f"FemEdge(id={self.id}, nodes={len(self.nodes)}, runs={len(self.runs)}, "
                f"faces={self.faces}, ends={self.ends}, closed={self.closed}, seam={self.seam})")


class FemVertex:
    """One B-rep vertex of a FEM mesh: the node the mesh put there, if any, and
    where the topology says it is, if that is known. Plain data.

    `node` is the mesh node at this vertex, or `NONE` where the mesh has none
    there. **A sentinel here is ordinary, not a fault**: the analysis rebuilds a
    vertex wherever two trims meet, and a pole's polyline runs give a sphere 48
    of them where the mesh has 2 points, so a caller walking these skips the
    sentinel rather than treating it as a gap.

    `point` is where the vertex is, in the same space and under the same
    placement as `FemMesh.nodes` -- the file's own vertex rather than a mesh
    node, so the two can differ by the reader's rounding. **Meaningless unless
    `has_position`**: it is `(0.0, 0.0, 0.0)` then, which is a point no geometry
    has and which a solver would take for a node at the origin.
    """

    __slots__ = ("node", "point", "has_position")

    def __init__(self, node, point, has_position):
        self.node = node
        self.point = point
        self.has_position = has_position

    def __repr__(self):
        return f"FemVertex(node={self.node}, point={self.point}, has_position={self.has_position})"


class FemMesh:
    """One body meshed for a solver: nodes welded by bits, triangles wound
    outward, every node tagged with the lowest-dimension B-rep entity it lies on,
    and every crack reported rather than closed. Built by `Node.fem_mesh`, and
    **owned by you**: `free()` it, or use it as a context manager.

    A handle rather than a snapshot, and its big arrays are **read-only numpy
    views into the library's own memory**, exactly as `Node.mesh`'s are and for
    the same reason: a solver mesh is megabytes, and copying it to hand it over
    would cost that twice. Each array keeps *this object* alive through its
    `.base` -- not the scene, which does not own it and whose `close()` does not
    free it -- so a view cannot outlive the mesh by having merely dropped the
    last reference to it. What still dangles is a view kept past an explicit
    `free()`, or past the end of a `with` block; call `.copy()` on anything that
    must outlive the handle.

    numpy is imported the first time one of those arrays is asked for, as for
    `Node.mesh`. The flags, the counts, the quality figures, the edge and vertex
    records, the crack censuses and the `.msh` text need nothing outside the
    standard library.
    """

    __slots__ = ("_pointer", "_raw", "__weakref__")

    def __init__(self, pointer: int):
        self._pointer = pointer
        # Read once, here. Every pointer in the view is built with the handle and
        # good until it is freed (nothing in this ABI is built lazily), so asking
        # again per property would be one C call per array for the same answer.
        raw = _FemMeshView()
        if not _lib().cadaclysm_fem_mesh_view(pointer, ctypes.byref(raw)):
            why = _last_error() or "fem mesh view"
            self.free()
            raise CadaclysmError(why)
        self._raw = raw

    @property
    def _handle(self) -> int:
        if not self._pointer:
            raise CadaclysmError("fem mesh: freed")
        return self._pointer

    @property
    def _live(self) -> "_FemMeshView":
        """The view, the handle checked first: every pointer in it is the
        handle's, and a freed handle's point at nothing."""
        if not self._pointer:
            raise CadaclysmError("fem mesh: freed")
        return self._raw

    @property
    def freed(self) -> bool:
        return not self._pointer

    def free(self) -> None:
        """Give the mesh back, and with it every view taken from it. Idempotent."""
        pointer, self._pointer = getattr(self, "_pointer", None), None
        if pointer and _library is not None:
            _library.cadaclysm_fem_mesh_free(pointer)

    def __enter__(self) -> "FemMesh":
        return self

    def __exit__(self, *_):
        self.free()

    def __del__(self):
        try:
            self.free()
        except Exception:  # noqa: BLE001 - the interpreter may be going down
            pass

    # -- the flat arrays, borrowed

    @property
    def nodes(self):
        """Every node's position, a read-only float64 `(node_count, 3)` view --
        placed, and in the space `Node.fem_mesh` and `from_mesh` describe."""
        raw = self._live
        return _view(self, raw.nodes, (raw.node_count, 3), "float64")

    @property
    def triangles(self):
        """Three node indices a triangle, wound outward: a read-only uint32
        `(triangle_count, 3)` view."""
        raw = self._live
        return _view(self, raw.triangles, (raw.triangle_count, 3), "uint32")

    @property
    def triangle_face(self):
        """The brep face each triangle lies on, one per triangle: a read-only
        uint32 `(triangle_count,)` view into `range(face_count)`."""
        raw = self._live
        return _view(self, raw.triangle_face, (raw.triangle_count,), "uint32")

    @property
    def node_kind(self):
        """What each node lies on -- `0` a vertex, `1` an edge, `2` a face -- one
        per node, as a read-only uint32 view. Gmsh's own classification rule: the
        lowest-dimension entity the node lies on. `node_entity` says which one."""
        raw = self._live
        return _view(self, raw.node_kind, (raw.node_count,), "uint32")

    @property
    def node_entity(self):
        """Which vertex, edge or face each node lies on, by the matching
        `node_kind`: an index into `vertices`, into `edges`, or into the body's
        faces. One per node, a read-only uint32 view."""
        raw = self._live
        return _view(self, raw.node_entity, (raw.node_count,), "uint32")

    # -- the topology, copied out

    @property
    def face_count(self) -> int:
        """The body's faces; `triangle_face` and a `node_kind` of 2 index them."""
        return self._live.face_count

    @property
    def edges(self) -> "list[FemEdge]":
        """One `FemEdge` per B-rep edge, in the order a `node_kind` of 1 indexes
        them. Empty for a `from_mesh` body, which has no B-rep edges at all.

        **This list's own numbering, not the body's**: each `FemEdge.id` carries the
        body's own edge id."""
        library, handle, raw = _lib(), self._handle, _FemEdge()
        out = []
        for i in range(self._raw.edge_count):
            if not library.cadaclysm_fem_mesh_edge(handle, i, ctypes.byref(raw)):
                raise CadaclysmError(_last_error() or f"fem mesh edge {i}")
            out.append(FemEdge(
                raw.id,
                tuple(raw.nodes[j] for j in range(raw.node_count)),
                tuple(raw.runs[j] for j in range(raw.run_count)),
                (raw.face_a, raw.face_b),
                (raw.end_a, raw.end_b),
                bool(raw.closed),
                bool(raw.seam),
            ))
        return out

    @property
    def vertices(self) -> "list[FemVertex]":
        """One `FemVertex` per B-rep vertex, in the order a `node_kind` of 0
        indexes them. Empty for a `from_mesh` body."""
        library, handle, raw = _lib(), self._handle, _FemVertex()
        out = []
        for i in range(self._raw.vertex_count):
            if not library.cadaclysm_fem_mesh_vertex(handle, i, ctypes.byref(raw)):
                raise CadaclysmError(_last_error() or f"fem mesh vertex {i}")
            out.append(FemVertex(raw.node, tuple(raw.point), bool(raw.has_position)))
        return out

    # -- the crack census

    @property
    def open_edges(self) -> "list[tuple[int, int, int]]":
        """Every crack, as `(a, b, brep_edge)`: a directed mesh edge `(a, b)`
        with no `(b, a)`, and the B-rep edge both nodes lie on or `NONE` where
        they share none.

        **Empty unless the body's topology is closed -- for a B-rep body**, whose
        mesh is otherwise not asked about at all: such a body reports `watertight`
        False with this and `folded_edges` both empty, and *that trio together*
        says "not asked", not "nothing found".

        **A `from_mesh` body is the other case, and the opposite one.** A bare mesh
        carries no topology to say whether it ought to close, so its census always
        runs over the welded triangles: an open render mesh reports its cracks here
        with `watertight` False, a closed one reports `watertight` True, and an
        empty census there really does mean "nothing found"."""
        return self._census(_lib().cadaclysm_fem_mesh_open_edge,
                            self._live.open_edge_count, "open edge")

    @property
    def folded_edges(self) -> "list[tuple[int, int, int]]":
        """Every fold, as `open_edges` reports a crack: a directed mesh edge used
        by more than one triangle.

        **A body can be folded without being open**, and the closure census's own
        pinned rows are folds rather than open cracks -- a solid no thicker than a
        line leaves no hole for an open edge to find. A caller that checks only
        `open_edges` calls such a body sound."""
        return self._census(_lib().cadaclysm_fem_mesh_folded_edge,
                            self._live.folded_edge_count, "folded edge")

    def _census(self, call, count: int, what: str) -> "list[tuple[int, int, int]]":
        """One flattened census, row by row: the shape `open_edges` and
        `folded_edges` share, so the two cannot drift."""
        handle = self._handle
        a, b, edge = c_uint32(), c_uint32(), c_uint32()
        out = []
        for i in range(count):
            if not call(handle, i, ctypes.byref(a), ctypes.byref(b), ctypes.byref(edge)):
                raise CadaclysmError(_last_error() or f"fem mesh {what} {i}")
            out.append((a.value, b.value, edge.value))
        return out

    # -- the summary

    @property
    def watertight(self) -> bool:
        """The welded mesh closes -- and, for a B-rep body, so does the topology
        behind it. **False for every B-rep body whose topology is not closed**,
        whose mesh is then not asked about at all.

        A `from_mesh` body has no topology to ask of, so this says only that its
        triangles close: a closed render mesh reports True with no topology behind
        it at all. `from_mesh` is which of the two you are holding, and `open_edges`
        says what an empty census beside each does and does not mean."""
        return bool(self._live.watertight)

    @property
    def from_mesh(self) -> bool:
        """This came from the scene's own mesh rather than from a brep: one face,
        every node on face 0, no edges and no vertices.

        **It is also which space the mesh is in.** A B-rep body's FEM mesh is in
        the **file's own units and axes**, whatever `Convention` the scene was
        opened with, because it is taken off the brep -- and a brep is in the
        file's own space for the reason `Brep` gives: a convention converts what
        is drawn, and converting a brep would mean rebuilding it. A node with no
        brep falls back to the scene's mesh, which *is* converted, so it comes
        back **in the scene's convention**, wound counter-clockwise about the
        outward normal even where the convention winds the other way.

        Under a non-NATIVE convention those are two different spaces, so a caller
        mixing these nodes with `Node.transform` on a Y-up scene gets a rotated
        part unless it reads this flag.

        **It is also which contract `watertight`, `open_edges` and `folded_edges`
        are reporting under.** A bare mesh has no topology to ask of, so its census
        always runs and speaks from the triangles alone, where a B-rep body's runs
        only if its topology claims to close. Read `open_edges`."""
        return bool(self._live.from_mesh)

    @property
    def min_angle(self) -> float:
        """The smallest interior angle of any triangle, in degrees."""
        return self._live.min_angle

    @property
    def worst_triangle(self) -> int:
        """The triangle with that angle: an index into `triangles`."""
        return self._live.worst_triangle

    @property
    def longest_edge(self) -> float:
        """The longest triangle edge, placed.

        **The figure to check against `Node.fem_mesh`'s `max_size`, and the only
        one that says what the mesh actually is**: `max_size` bounds the boundary
        segments and merely targets the interior, and one small enough to hit the
        mesher's own piece and station ceilings is not honoured at all."""
        return self._live.longest_edge

    # -- out

    def msh_text(self) -> str:
        """The mesh as Gmsh 4.1 ASCII `.msh` text: an entity per B-rep vertex,
        edge and face, a volume where the body closes, and a physical group
        naming each.

        **The library's text is borrowed from this handle** and replaced by the
        next call on it -- this ABI's convention, and the opposite of the kernel
        library's, where `cadaclysm_blacksmith_fem_mesh_msh_text` hands over an
        owned string to free. Nothing here has to free anything either way:
        ctypes copies a `char *` into Python on the way out, so what comes back
        is a `str` of your own that outlives the handle.

        **No unlicensed notice is printed here.** `Node.fem_mesh` gave it once
        when the mesh was built, and this ABI deliberately does not repeat it on
        either `.msh` call -- where the kernel library notices on both of its
        writers and *not* on its constructor. Each matches its own siblings, so
        moving the call to look like the other side would break a convention.

        Raises `CadaclysmError` for a mesh the writer refuses, naming the field
        it cannot honour, and for a freed handle."""
        raw = _lib().cadaclysm_fem_mesh_msh_text(self._handle)
        if not raw:
            raise CadaclysmError(_last_error() or "msh text")
        return _text(raw)

    def save_msh(self, path) -> None:
        """`msh_text()` written to `path` by the library itself: the same bytes
        from the same writer, straight to the file rather than through the
        borrowed slot, so a `msh_text()` call on this handle from another thread
        cannot free the text under the write.

        Raises `CadaclysmError` for a mesh the writer refuses or a file it cannot
        write, naming the path. No notice here either; see `msh_text`."""
        if not _lib().cadaclysm_fem_mesh_save_msh(self._handle, str(path).encode()):
            raise CadaclysmError(_last_error() or f"could not write {path}")

    def __repr__(self):
        if self.freed:
            return "FemMesh(freed)"
        raw = self._raw
        return (f"FemMesh(nodes={raw.node_count}, triangles={raw.triangle_count}, "
                f"watertight={bool(raw.watertight)}, from_mesh={bool(raw.from_mesh)})")


class Node:
    """One node of the document: an assembly, a shape, a placement.

    A handle rather than a snapshot — every property below asks the scene when
    you ask it, so nothing here goes stale and nothing is read that a caller
    never looks at. That matters: `bounds` and `mesh` *build* the geometry, and
    a tree of ten thousand nodes should cost ten thousand names, not ten
    thousand tessellations.
    """

    __slots__ = ("scene", "index")

    def __init__(self, scene: "Scene", index: int):
        self.scene = scene
        self.index = index

    # Identity is the pair, so a node from one lookup equals the same node from
    # another and can key a dict of, say, what the viewer has uploaded.
    def __eq__(self, other):
        return (
            isinstance(other, Node)
            and other.index == self.index
            and other.scene is self.scene
        )

    def __hash__(self):
        return hash((id(self.scene), self.index))

    def __repr__(self):
        return f"<Node {self.index} {self.name or self.kind or '?'}>"

    @property
    def name(self) -> str:
        return _text(_lib().cadaclysm_node_name(self.scene._handle, self.index))

    @property
    def id(self) -> str:
        """What the file calls it — a STEP `#N`, an IFC GlobalId, a Rhino UUID.

        Text rather than a number because that is what the formats carry: a
        22-character GlobalId does not fit in an integer.
        """
        return _text(_lib().cadaclysm_node_id(self.scene._handle, self.index))

    @property
    def kind(self) -> str:
        """What the file calls it — an IFC type, an openNURBS class, a shape kind."""
        return _text(_lib().cadaclysm_node_kind(self.scene._handle, self.index))

    @property
    def visible(self) -> bool:
        """Whether the file says to show this when it is opened.

        **The file's opening state, and not inherited.** A Rhino layer is a node of
        its own carrying its own switch, and its members carry theirs; hiding a
        subtree means walking it. `visible_now` does that walk.

        `True` where the format says nothing, which is most of them -- so a `False`
        is always something the file actually said.
        """
        return bool(_lib().cadaclysm_node_visible(self.scene._handle, self.index))

    @property
    def visible_now(self) -> bool:
        """`visible`, but with every ancestor consulted.

        A layer switched off hides what hangs under it however the members' own
        switches are set, which is what Rhino shows and what `visible` alone does
        not say.
        """
        node = self
        while node is not None:
            if not node.visible:
                return False
            node = node.parent
        return True

    @property
    def locked(self) -> bool:
        """Whether the file says this cannot be selected or edited.

        Rhino's idea, so it rides as a property rather than a field: an object is
        locked by its own flag or by its layer's, and the reader has already
        combined the two. Formats without the concept answer `False`.

        Locking is not hiding. A locked thing is drawn exactly as any other and only
        refuses to be picked.
        """
        for attribute in self.attributes:
            if attribute.name == "Locked":
                return bool(attribute.value)
        return False

    @property
    def label(self) -> str:
        """Something to put in a tree row: the name, else the kind, else `#index`."""
        return self.name or self.kind or f"#{self.index}"

    @property
    def depth(self) -> int:
        """How far down the tree it sits, a root being zero. For indenting."""
        return _lib().cadaclysm_node_depth(self.scene._handle, self.index)

    @property
    def generator(self) -> str:
        """What its geometry was before it was triangles — `brep`, `mesh`, `csg`.

        Empty for a node that draws nothing, there being no geometry to have
        come from anything.
        """
        return _text(_lib().cadaclysm_node_generator(self.scene._handle, self.index))

    @property
    def parent(self) -> "Node | None":
        """The node containing this one, or None for a root."""
        return self.scene._node_or_none(
            _lib().cadaclysm_node_parent(self.scene._handle, self.index)
        )

    @property
    def children(self) -> "list[Node]":
        library, handle = _lib(), self.scene._handle
        count = library.cadaclysm_node_child_count(handle, self.index)
        return [
            Node(self.scene, library.cadaclysm_node_child(handle, self.index, i))
            for i in range(count)
        ]

    @property
    def instance_of(self) -> "Node | None":
        """The node whose geometry this one is a placement of, or None.

        The point of meshes coming over in their own frame: a shell placed
        seventy-four times is one mesh and seventy-four transforms, and this is
        how a caller knows to upload the buffer once.
        """
        return self.scene._node_or_none(
            _lib().cadaclysm_node_instance_of(self.scene._handle, self.index)
        )

    @property
    def select_as(self) -> "Node":
        """What a click on this node's geometry should select — itself, usually.

        A format that hangs geometry on a child of the object it belongs to
        (IFC: a representation item under its product) points the child back at
        the object.
        """
        chosen = _lib().cadaclysm_node_select_as(self.scene._handle, self.index)
        return self if chosen == NONE else Node(self.scene, chosen)

    @property
    def attributes(self) -> "list[Attribute]":
        """Everything the file said about this node."""
        library, handle = _lib(), self.scene._handle
        count = library.cadaclysm_node_attribute_count(handle, self.index)
        out = []
        for i in range(count):
            attribute = _attribute(library.cadaclysm_node_attribute(handle, self.index, i))
            if attribute is not None:
                out.append(attribute)
        return out

    @property
    def can_mesh(self) -> bool:
        """Whether this node is drawn — whether it has geometry of its own to show.

        Asks for nothing to be built. Most nodes of a model are structure — an
        assembly, a storey, a layer — and answer False.
        """
        return _lib().cadaclysm_node_can_mesh(self.scene._handle, self.index)

    def save_mesh(self, path, fmt: str = "stl") -> None:
        """Write this node's mesh to `path` in `fmt`.

        `fmt` is one of `mesh_formats()`. Raises `CadaclysmError` if the node
        draws nothing, which most of them do -- an assembly, a storey, a layer
        -- or if the format is not one the library writes. Ask `can_mesh` first
        if a menu should grey the row out rather than let the click fail.

        The mesh written is this node's own, where it is defined and without its
        placement, so a node instanced six times writes one file wherever it is
        asked from.
        """
        ok = _lib().cadaclysm_node_save_mesh(
            self.scene._handle, self.index, str(path).encode(), fmt.encode()
        )
        if not ok:
            raise CadaclysmError(_last_error() or f"could not write {path}")

    @property
    def colour(self):
        """`(r, g, b, a)` if the file gave one, else None.

        None rather than a default: most STEP files carry no colour at all, and
        the honest answer lets the caller use its own.
        """
        rgba = (c_float * 4)()
        if not _lib().cadaclysm_node_color(self.scene._handle, self.index, rgba):
            return None
        return tuple(float(v) for v in rgba)

    @property
    def transform(self):
        """Where this node's geometry sits, as a 4x4 float64 numpy array.

        The ABI writes it column-major, as OpenGL and every engine do; this
        transposes it into the row-major convention numpy and the textbooks
        use, so `M[:3, :3]` is the rotation and scale block and `M[:3, 3]` is
        the offset. Feeding it back to a GL uniform therefore wants
        `M.T.astype("f4")` — or the ABI's own order, which `raw_transform`
        keeps.

        Doubles, while the mesh is floats, on purpose: a building at UTM
        coordinates baked into f32 world positions loses millimetres, where an
        f32 mesh about its own origin under an f64 transform does not.
        """
        numpy = _numpy()
        return numpy.array(self.raw_transform, numpy.float64).reshape(4, 4).T

    @property
    def raw_transform(self):
        """The same matrix in the ABI's own column-major order, as 16 floats."""
        out = (c_double * 16)()
        _lib().cadaclysm_node_transform(self.scene._handle, self.index, out)
        return tuple(out)

    @property
    def bounds(self) -> Bounds:
        """The extent of the geometry this node draws, **in that geometry's own frame**.

        Builds the geometry if it has not been built. Carry it through
        `transform` for world coordinates, exactly as with the mesh it bounds.
        """
        raw = _lib().cadaclysm_node_bounds(self.scene._handle, self.index)
        return Bounds(raw.min, raw.max)

    @property
    def bounds64(self) -> Bounds:
        """`bounds` in float64: exact far from the origin, where float32 is not."""
        raw = _lib().cadaclysm_node_bounds64(self.scene._handle, self.index)
        return Bounds(raw.min, raw.max)

    @property
    def mesh(self) -> Mesh:
        """Its triangles, in their own frame, built now if they have not been.

        Where the node instances another these are the instanced node's
        triangles in the instanced node's frame, so two occurrences of one
        shape hand back the *same* arrays and two different transforms. Read
        the module docstring on what these views may not outlive.
        """
        return self._mesh_of(_lib().cadaclysm_node_mesh(self.scene._handle, self.index))

    @property
    def mesh64(self) -> Mesh:
        """`mesh` in float64: the document's own mesh, lent (the float32 one is this
        narrowed) -- the same indices, for a caller using the mesh as geometry. **A
        `Scene.forget_meshes()` invalidates these views**; ask again after one."""
        return self._mesh_of(_lib().cadaclysm_node_mesh64(self.scene._handle, self.index), "float64")

    def _mesh_of(self, raw, real="float32") -> Mesh:
        n = raw.vertex_count
        return Mesh(
            _view(self.scene, raw.positions, (n, 3), real),
            _view(self.scene, raw.normals, (n, 3), real),
            # Two floats a vertex, not three: `uvs` holds `vertex_count * 2`.
            _view(self.scene, raw.uvs, (n, 2), real),
            # Four floats a vertex: `colors` holds `vertex_count * 4`, RGBA -- always float32.
            _view(self.scene, raw.colors, (n, 4), "float32"),
            _view(self.scene, raw.indices, (raw.index_count,), "uint32"),
            n,
            raw.index_count,
        )

    def mesh_lod(self, level: int) -> Mesh:
        """Its triangles at a coarser level of detail: 0 is `mesh` itself, 1 up to
        `lod_levels()` are each about a quarter of the triangles of the one before,
        and past that is empty. **Every level shares the level-0 vertices** -- the
        same `positions` and `vertex_count`, only `indices` differs -- so a caller
        uploads the vertices once and switches level by drawing a different index
        range. Simplifying costs about what meshing did, once per node."""
        return self._mesh_of(_lib().cadaclysm_node_mesh_lod(self.scene._handle, self.index, level))

    def lod_error(self, level: int) -> float:
        """How far `mesh_lod(level)` moved the surface, in the scene's units --
        what to pick a level by against the pixel size on screen. Zero at level 0."""
        return _lib().cadaclysm_node_lod_error(self.scene._handle, self.index, level)

    def fem_mesh(self, tolerance: float = 0.01, max_size: float = 0.0, placement=None) -> FemMesh:
        """This node's body meshed for a solver, as a `FemMesh`: nodes welded by
        bits, triangles wound outward, each node tagged with the lowest-dimension
        B-rep entity it lies on, and every crack reported rather than closed.

        `tolerance` is the chordal tolerance in model units, finite and above
        zero, and **it alone governs how closely the mesh follows the geometry**.
        `max_size` is a size ceiling, finite and zero or more, `0` being no ceiling
        (curvature alone): **it bounds the boundary and targets the interior**,
        which is not a longest-element-edge guarantee. It adds boundary nodes
        without refining boundary geometry, and `FemMesh.longest_edge` is what the
        mesh actually came to -- the figure to check against it.

        Those two defaults are `FemOptions::default()`'s own, restated here so
        that the signature says what a caller gets. The library's struct is still
        filled by `cadaclysm_fem_options_init` first, so a field added to it later
        defaults without this line being touched; only these two are overwritten.
        `cadaclysm_blacksmith.py`'s `Solid.fem_mesh` restates the same pair, and
        has to -- the wasm kernel has no options-init export to ask.

        `placement` is 16 numbers, column-major, as `bounds_placed` takes them
        (None for the identity), applied in float64 throughout. The kernel
        library's `Solid.fem_mesh` takes **twelve** instead -- origin, x, y, z --
        so a caller moving between the two reformats the placement.

        **The space is the body's, not the scene's, for a B-rep -- and the scene's
        for a mesh**, which `FemMesh.from_mesh` is the flag for; read it there,
        because under a non-NATIVE convention the two are different spaces.

        Meshed in the part's own frame and following the hop from an instance to
        the shape it draws that `mesh` follows, so a node instanced six times
        meshes once, where it is defined.

        **A cracked body is not a failure**: it comes back with `watertight`
        False and its cracks in `open_edges` / `folded_edges`, and nothing is
        welded shut to make it look sound. Raises `CadaclysmError` for a tolerance
        or size the mesher refuses, a placement that is not 16 numbers or is not
        finite and invertible, a node with neither a brep nor a mesh (an assembly,
        a storey, a layer, an empty definition, a curve), and a body that meshes
        to no triangles at all.

        Prints the unlicensed notice once, here, and not again on either of
        `FemMesh`'s `.msh` calls."""
        values = None if placement is None else [float(v) for v in placement]
        if values is not None and len(values) != 16:
            raise CadaclysmError(f"fem_mesh: a placement is 16 numbers, not {len(values)}")
        matrix = None if values is None else (c_double * 16)(*values)
        options = _FemOptions()
        # `init` writes `sizeof(CadaclysmFemOptions)` bytes as the *library* knows
        # that type, into the struct `_FemOptions` declares -- which is why
        # `tests/bindings.rs` pins the two field for field. `size` is then set to
        # this header's own sizeof, which is what the growth rule asks of a caller.
        _lib().cadaclysm_fem_options_init(ctypes.byref(options))
        options.size = ctypes.sizeof(_FemOptions)
        options.tolerance, options.max_size = float(tolerance), float(max_size)
        pointer = _lib().cadaclysm_node_fem_mesh(
            self.scene._handle, self.index, matrix, ctypes.byref(options)
        )
        if not pointer:
            raise CadaclysmError(_last_error() or "fem_mesh")
        return FemMesh(pointer)

    @property
    def surfaces(self) -> Surfaces:
        """Its faces as surfaces and trim loops, where the reader built them.

        The parametric product: each face is the surface it sits on plus the loops that
        cut it, both in that surface's own (u, v). Nothing here was meshed, and nothing
        here costs `Node.mesh` anything -- a body carries both descriptions and builds
        whichever is asked for, so a document can be looked at either way, or both, with
        no decision taken when it was opened. Empty where the reader has no parametric
        read of this body (a tessellated face set, a boolean) or of this format.
        """
        import numpy as np

        raw = _lib().cadaclysm_node_surfaces(self.scene._handle, self.index)
        if not raw.face_count:
            return Surfaces([])
        loops = _view(self.scene, raw.loops, (raw.loop_count, 2), "uint32")
        points = _view(self.scene, raw.points, (raw.point_count, 2), "float32")
        profiles = _view(self.scene, raw.profiles, (raw.profile_count, 4), "float32")
        nurbs = _view(self.scene, raw.nurbs, (raw.nurbs_count,), "float32")

        out = []
        for i in range(raw.face_count):
            f = raw.faces[i]
            rings = []
            for k in range(f.loop_count):
                start, length = loops[f.loop_start + k]
                rings.append(points[start:start + length])
            out.append(Face(
                kind=f.kind,
                reversed=bool(f.reversed),
                transposed=bool(f.transposed),
                origin=np.array(f.origin[:3]),
                ax=np.array(f.ax[:3]),
                ay=np.array(f.ay[:3]),
                az=np.array(f.az[:3]),
                domain=np.array(f.domain[:]),
                scalars=np.array(f.scalars[:]),
                loops=rings,
                profile=profiles[f.profile_start:f.profile_start + f.profile_count],
                profile2=profiles[f.profile2_start:f.profile2_start + f.profile2_count],
                nurbs=nurbs[f.nurbs_start:f.nurbs_start + f.nurbs_count],
            ))
        return Surfaces(out)

    @property
    def brep(self) -> "Brep | None":
        """Its exact B-rep, for `cadaclysm_blacksmith.Solid.from_node` to operate on,
        or `None` where it has none (a mesh, a curve, a CSG body, a JT or OpenSCAD
        part). Shared with the scene, not copied; see `Brep`."""
        pointer = _lib().cadaclysm_node_brep(self.scene._handle, self.index)
        return Brep(pointer) if pointer else None

    @property
    def edges(self) -> Polylines:
        """Its feature edges, as polylines to draw an overlay from."""
        return self._polylines(_lib().cadaclysm_node_edges)

    @property
    def edge_colours(self) -> "list":
        """One RGBA per polyline of `edges`, `None` for an edge the file does not style;
        empty when nothing is styled."""
        return self._edge_colours(_lib().cadaclysm_node_edge_colors)

    @property
    def surface_edge_colours(self) -> "list":
        """`edge_colours` for `surface_edges`."""
        return self._edge_colours(_lib().cadaclysm_node_surface_edge_colors)

    def _edge_colours(self, fn) -> "list":
        raw = fn(self.scene._handle, self.index)
        if not raw.rgba or not raw.count:
            return []
        flat = raw.rgba[: raw.count * 4]
        return [None if flat[4 * i + 3] < 0 else tuple(flat[4 * i: 4 * i + 4]) for i in range(raw.count)]

    @property
    def curves(self) -> Polylines:
        """Its free curves, as polylines. A 2D drawing is all of these."""
        return self._polylines(_lib().cadaclysm_node_curves)

    @property
    def isocurves(self) -> Polylines:
        """Its interior surface lines, as polylines.

        Distinct from `edges`: those bound the faces, these rule across them, so
        a curved face reads as curved rather than as a flat patch. A flat face
        still yields its outline here rather than nothing, which is why the two
        can overlap.
        """
        return self._polylines(_lib().cadaclysm_node_isocurves)

    def _polylines(self, function) -> Polylines:
        raw = function(self.scene._handle, self.index)
        return Polylines(
            _view(self.scene, raw.positions, (raw.vertex_count, 3), "float32"),
            _view(self.scene, raw.counts, (raw.polyline_count,), "uint32"),
            raw.polyline_count,
            raw.vertex_count,
        )

    @property
    def edge_beziers(self) -> Beziers:
        """Its feature edges as cubic Bézier curves -- exact where the file's curves
        were, where `edges` is their chords. Builds the geometry if needed."""
        return self._beziers(_lib().cadaclysm_node_edge_beziers)

    @property
    def curve_beziers(self) -> Beziers:
        """Its free curves as cubic Béziers; see `edge_beziers`."""
        return self._beziers(_lib().cadaclysm_node_curve_beziers)

    @property
    def isocurve_beziers(self) -> Beziers:
        """Its isocurves as cubic Béziers; see `edge_beziers`."""
        return self._beziers(_lib().cadaclysm_node_isocurve_beziers)

    @property
    def edge_beziers64(self) -> Beziers:
        """`edge_beziers` in float64, kept beside the float Béziers: a forget leaves it valid, unlike `mesh64`."""
        return self._beziers(_lib().cadaclysm_node_edge_beziers64, "float64")

    @property
    def curve_beziers64(self) -> Beziers:
        """`curve_beziers` in float64; see `edge_beziers64`."""
        return self._beziers(_lib().cadaclysm_node_curve_beziers64, "float64")

    @property
    def isocurve_beziers64(self) -> Beziers:
        """`isocurve_beziers` in float64; see `edge_beziers64`."""
        return self._beziers(_lib().cadaclysm_node_isocurve_beziers64, "float64")

    def _beziers(self, function, real="float32") -> Beziers:
        raw = function(self.scene._handle, self.index)
        return Beziers(
            _view(self.scene, raw.points, (raw.count, 4, 3), real),
            _view(self.scene, raw.weights, (raw.count, 4), real),
            raw.count,
        )

    def collision(self, hull_budget: int = 0) -> "Collision | None":
        """The collision body for what this node draws, building its mesh if it is
        not built. `hull_budget` is the most triangles a hull may have; 0 asks for
        the Unity limit (255) and is not clamped to it. `None` for a node that draws
        nothing. Cached per node and budget, so asking twice costs one fit."""
        out = _Collision()
        out.size = ctypes.sizeof(_Collision)
        if not _lib().cadaclysm_node_collision(self.scene._handle, self.index, hull_budget, ctypes.byref(out)):
            return None
        return Collision(out)

    def collision_hull(self, hull_budget: int = 0) -> CollisionHull:
        """The convex hull `collision` counted, as triangles for the physics engine.
        Empty for a node that draws nothing. Views into the scene, good until it closes or
        this node is asked for a different `hull_budget`, which refits and frees them."""
        raw = _lib().cadaclysm_node_collision_hull(self.scene._handle, self.index, hull_budget)
        return CollisionHull(
            _view(self.scene, raw.positions, (raw.vertex_count, 3), "float32"),
            _view(self.scene, raw.indices, (raw.index_count,), "uint32"),
            raw.vertex_count,
            raw.index_count,
        )

    # -- the surface path: for a renderer drawing exact surfaces, never triangles --

    def bounds_placed(self, placement=None) -> Bounds:
        """The box of what this node draws **under a placement**, for a part drawn
        from its surfaces: every sample is carried through the document's convention
        and then `placement` (16 numbers, column-major, as `Placement.raw_transform`;
        None for the identity) before it is boxed. Tighter than placing the corners of
        `bounds`: the box of a rotated box is bigger than the box of the rotated
        points. All zeros for a part with no surfaces."""
        values = None if placement is None else [float(v) for v in placement]
        if values is not None and len(values) != 16:
            raise CadaclysmError(f"bounds_placed: a placement is 16 numbers, not {len(values)}")
        matrix = None if values is None else (c_double * 16)(*values)
        raw = _lib().cadaclysm_node_bounds_placed(self.scene._handle, self.index, matrix)
        return Bounds(raw.min, raw.max)

    def bounds_placed64(self, placement=None) -> Bounds:
        """`bounds_placed` in float64; see `bounds64`."""
        values = None if placement is None else [float(v) for v in placement]
        if values is not None and len(values) != 16:
            raise CadaclysmError(f"bounds_placed64: a placement is 16 numbers, not {len(values)}")
        matrix = None if values is None else (c_double * 16)(*values)
        raw = _lib().cadaclysm_node_bounds_placed64(self.scene._handle, self.index, matrix)
        return Bounds(raw.min, raw.max)

    @property
    def is_meshed(self) -> bool:
        """Whether its mesh has been built and is held -- by `Scene.realize_all`, by an
        ask for it, or by anything else that needed it. A renderer drawing the part
        from its surfaces checks it never paid for the triangles."""
        return _lib().cadaclysm_node_is_meshed(self.scene._handle, self.index)

    @property
    def surface_edges(self) -> Polylines:
        """Its face boundaries taken from its trimmed surfaces -- the outline that
        costs no tessellation, where `edges` meshes the part. In the surfaces' own
        frame (see `Scene.surface_matrix`); empty without surfaces. A shared edge
        appears once from each face."""
        return self._polylines(_lib().cadaclysm_node_surface_edges)

    @property
    def surface_edge_beziers(self) -> Beziers:
        """Its edges as the exact curves, where the reader has them without meshing
        -- a Rhino extrusion's rims are its profile -- and empty everywhere else, so
        a caller drawing from surfaces tries this before `surface_edges`, whose trims
        are thinned to the mesh tolerance. The same segments as `edge_beziers`, in
        the same space: not the surfaces' frame, so no `Scene.surface_matrix`."""
        return self._beziers(_lib().cadaclysm_node_surface_edge_beziers)

    @property
    def surface_isocurves(self) -> Polylines:
        """Its isocurves taken from its trimmed surfaces and clipped to the trims,
        without meshing: lines at a surface's bend lines and an even spread where it
        has none; a flat face gets none. In the surfaces' frame; empty without
        surfaces."""
        return self._polylines(_lib().cadaclysm_node_surface_isocurves)

    def surface_pick(self, from_, to):
        """Where the segment `from_`..`to` first meets this part's surfaces, as
        `(x, y, z)`, or None where it meets none (or the part has no surfaces).
        Exact: answers from the surface and tests the trims at the hit's own (u, v).
        **In the surfaces' own frame**: carry a ray from the scene's space through
        the inverse of `Scene.surface_matrix` first."""
        start, end = [float(v) for v in from_], [float(v) for v in to]
        if len(start) != 3 or len(end) != 3:
            raise CadaclysmError("surface_pick: from_ and to are three numbers each")
        a = (c_double * 3)(*start)
        b = (c_double * 3)(*end)
        out = (c_double * 3)()
        if not _lib().cadaclysm_node_surface_pick(self.scene._handle, self.index, a, b, out):
            return None
        return tuple(out)

    def surface_proxy_mesh(self, cells: int) -> Mesh:
        """A coarse mesh over its surfaces for the things that need triangles and not
        a picture -- ray tracing, distance fields: each face gridded `cells` by `cells`
        over its trim window, two triangles a cell whose centre lies inside the trims,
        never welded. Built once per part at the first `cells` asked for. In the
        scene's space, like `mesh`. Empty without surfaces or for `cells` of 0."""
        return self._mesh_of(_lib().cadaclysm_node_surface_proxy_mesh(self.scene._handle, self.index, cells))

    @property
    def triangle_estimate(self) -> int:
        """About how many triangles `mesh` would give, **without building it** -- for
        sizing a budget before meshing. Exact for a stored mesh, within a few tens of
        percent for a B-rep; `-1` where the reader cannot say without doing the work,
        and for a node that draws nothing. Treat `-1` as unknown, never as zero."""
        return _lib().cadaclysm_node_triangle_estimate(self.scene._handle, self.index)

    def walk(self):
        """This node and every node under it, parents before children."""
        stack = [self]
        while stack:
            node = stack.pop()
            yield node
            stack.extend(reversed(node.children))

    def show(self, **options) -> None:
        """Draw what this node and everything under it places -- the placements whose
        selected node is this one or in its subtree -- with the viewer in use. Keywords
        as `Scene.show`."""
        self.scene._draw("show", self._placements(), options, "Node")

    def view(self, **options):
        """Orbit what this node and everything under it places; returns (azimuth,
        elevation, zoom)."""
        return self.scene._draw("view", self._placements(), options, "Node")

    def svg(self, path=None, **words) -> "str | None":
        """This node's own wireframe as SVG, in its own frame -- `Scene.svg`'s
        words, read from just this node rather than every placement.

        With `path`, writes the file and returns `None`; without, returns the
        SVG text. Raises `CadaclysmError` on a refused option (naming the
        field) or a failed write."""
        o = _svg_options(self.scene._default_up(), **words)
        if path is not None:
            ok = _lib().cadaclysm_node_svg(
                self.scene._handle, self.index, str(path).encode(), ctypes.byref(o)
            )
            if not ok:
                raise CadaclysmError(_last_error() or f"could not write {path}")
            return None
        p = _lib().cadaclysm_node_svg_text(self.scene._handle, self.index, ctypes.byref(o))
        if p is None:
            raise CadaclysmError(_last_error() or "svg")
        return p.decode("utf-8")

    def _placements(self) -> "list[Placement]":
        mine = {node.index for node in self.walk()}
        return [p for p in self.scene.placements if p.select.index in mine]


# ---- the scene ------------------------------------------------------------


class Scene:
    """An open document. Close it when done, or use it as a context manager.

    Everything it hands back borrows from it — see the module docstring.
    """

    __slots__ = ("_pointer", "path", "schema_path", "convention", "__weakref__")

    def __init__(self, pointer: int, path: Path, schema_path, convention=0):
        self._pointer = pointer
        #: The file this was read from.
        self.path = path
        #: The `.exp` actually used, or None. Worth reporting when `open` was
        #: given a directory and chose from it.
        self.schema_path = schema_path
        #: The packed `uint32` this was opened with — a `Convention` OR'd with
        #: `FILE_UNITS` and `UV_WORLD`. Kept because nothing the ABI hands back
        #: says what space it is in, and every array out of this scene is in
        #: this one.
        self.convention = convention

    # -- lifetime --

    @property
    def _handle(self) -> int:
        """The raw handle, refusing to hand over a closed one.

        Every call in this module goes through here rather than touching
        `_pointer`, so a use-after-close raises a Python exception at the call
        site instead of passing a dangling pointer into the library.
        """
        if self._pointer is None:
            raise CadaclysmError(f"{self.path.name}: the scene is closed")
        return self._pointer

    @property
    def surface_matrix(self):
        """The 4x4 that puts `Node.surfaces` in the space everything else is already in.

        Only the surfaces need it. Meshes, polylines and Bezier curves arrive in the
        convention the document was opened with; a surface does not, because converting
        one means converting its parameter space too -- a cylinder's `v` is a length and
        scales, a sphere's is an angle and does not -- and getting that wrong slides the
        trim loops off the face they trim. For a document opened NATIVE at the file's own
        units this is the identity.
        """
        import numpy as np

        out = (c_float * 16)()
        _lib().cadaclysm_surface_matrix(self._handle, out)
        # Column-major from the library, as OpenGL and the header both say.
        return np.array(out, dtype="f8").reshape(4, 4, order="F")

    @property
    def closed(self) -> bool:
        return self._pointer is None

    def close(self) -> None:
        """Give the scene back. Idempotent.

        Every borrowed array — every `Mesh` and `Polylines` view still in
        Python's hands — is reading freed memory afterwards.
        """
        if self._pointer is not None:
            pointer, self._pointer = self._pointer, None
            _lib().cadaclysm_close(pointer)

    def __enter__(self) -> "Scene":
        return self

    def __exit__(self, *exception) -> None:
        self.close()

    def __del__(self):
        # Only reached once nothing refers to the scene, and a borrowed view
        # refers to it through its `.base` — so this cannot pull memory out
        # from under an array that is still alive.
        try:
            self.close()
        except Exception:
            pass

    def __repr__(self):
        state = "closed" if self.closed else f"{len(self)} nodes"
        return f"<Scene {self.path.name} ({state})>"

    # -- the file --

    @property
    def version(self) -> str:
        """The version of the library that read it."""
        return version()

    @property
    def schema(self) -> str:
        """The schema the file named, or `""` for a format that names none."""
        return _text(_lib().cadaclysm_schema(self._handle))

    @property
    def schema_read(self) -> str:
        """The schema that actually read it, which is not always the one it named.

        A file declaring `IFC4X3_RC2` reads under `IFC4X3_ADD2` where that is what is
        registered -- a release candidate and the finished schema of the same version
        are the same schema. A file whose declared schema nobody registered reads
        under whichever registered one defines the entity types it contains.

        `schema` keeps saying what the file said, so the two differ exactly when a
        substitution happened -- see `substituted`.
        """
        return _text(_lib().cadaclysm_schema_read(self._handle))

    @property
    def substituted(self) -> bool:
        """Whether something other than the file's own schema read it.

        Compared on the *bare* names. A `FILE_SCHEMA` entry may carry a formal
        identifier -- `AUTOMOTIVE_DESIGN { 1 2 10303 214 0 1 1 1 }` -- and the library
        matches on the text before the braces, so comparing the whole entry calls
        every AP214 file substituted when nothing was substituted at all.
        """
        read = self.schema_read
        if not read:
            return False
        bare = lambda entry: entry.split("{")[0].strip().strip(".").casefold()
        return bare(read) not in (bare(part) for part in self.schema.split(","))

    @property
    def metres_per_unit(self) -> float:
        """What one length in the file is worth in metres, or 1 where it did not say."""
        return _lib().cadaclysm_metres_per_unit(self._handle)

    @property
    def bounds(self) -> Bounds:
        """Everything the model covers, **in world coordinates**.

        The one figure here not in a node's own frame. **This meshes all of
        it**, being the only way to know how far it reaches; a caller that has
        not the time should frame from the nodes it has built.
        """
        raw = _lib().cadaclysm_bounds(self._handle)
        return Bounds(raw.min, raw.max)

    @property
    def bounds64(self) -> Bounds:
        """`bounds` in float64, **in world coordinates**: exact far from the origin,
        where float32 is not. This meshes all of it, as `bounds` does."""
        raw = _lib().cadaclysm_bounds64(self._handle)
        return Bounds(raw.min, raw.max)

    @property
    def diagnostics(self) -> "list[str]":
        """What this file held that the reader could not build."""
        library, handle = _lib(), self._handle
        return [
            _text(library.cadaclysm_diagnostic(handle, i))
            for i in range(library.cadaclysm_diagnostic_count(handle))
        ]

    @property
    def links(self) -> "list[Link]":
        """The rigid bodies of the file's mechanism, in the file's order; empty for a file
        that records none."""
        return [Link(self, i) for i in range(_lib().cadaclysm_link_count(self._handle))]

    @property
    def joints(self) -> "list[Joint]":
        """The connections between the links, in the file's order; empty for a file that
        records none."""
        return [Joint(self, i) for i in range(_lib().cadaclysm_joint_count(self._handle))]

    @property
    def geometry_diagnostics(self) -> "list[str]":
        """What the reader built but the geometry stage could not finish: a face
        that would not trim, a surface that would not mesh. `diagnostics` is what
        the *file* held that could not be read; this is what the geometry did."""
        library, handle = _lib(), self._handle
        return [
            _text(library.cadaclysm_geometry_diagnostic(handle, i))
            for i in range(library.cadaclysm_geometry_diagnostic_count(handle))
        ]

    @property
    def source_name(self) -> "str | None":
        """The archive member this was read from, or None for a plain file.

        `open` on a `.zip` chose one member -- the shallowest it could read --
        and this is the only way to learn which.
        """
        raw = _lib().cadaclysm_source_name(self._handle)
        return _text(raw) if raw else None

    # -- nodes --

    def __len__(self) -> int:
        """How many nodes it has, geometry or not."""
        return _lib().cadaclysm_node_count(self._handle)

    def __getitem__(self, index: int) -> Node:
        count = len(self)
        if index < 0:
            index += count
        if not 0 <= index < count:
            raise IndexError(f"node {index} of {count}")
        return Node(self, index)

    def __iter__(self):
        """Every node in index order, without building a list of them."""
        return (Node(self, i) for i in range(len(self)))

    @property
    def nodes(self) -> "list[Node]":
        """Every node, in index order.

        A list, so it can be indexed and measured; iterate the scene itself to
        avoid materialising one object per node on a very large file.
        """
        return list(self)

    def query(self, filter: str) -> "list[int]":  # noqa: A002 - the ABI's own word
        """The indices of the nodes a filter matches, in document order.

        The filter is one boolean expression over a node --
        `class == ON_Brep and within(class == ON_Layer and name == Walls)`.

        Indices rather than `Node`s because that is what the ABI hands back and
        what a caller filtering a tree wants: a set to test membership against,
        not a thousand freshly built objects.

        Raises [`CadaclysmError`] carrying the parser's own message and byte
        offset if the filter will not parse. An empty result is not an error --
        a filter that matches nothing is a perfectly good answer, and the ABI
        distinguishes the two by whether it left a reason behind.
        """
        library, handle = _lib(), self._handle
        encoded = filter.encode()
        # Sized first, then filled: the ABI cannot hand back an allocation this
        # side would have to free, so it counts on request and writes on demand.
        total = library.cadaclysm_query(handle, encoded, None, 0)
        if total == 0:
            reason = _last_error()
            if reason:
                raise CadaclysmError(f"{self.path.name}: {reason}")
            return []
        out = (c_uint32 * total)()
        written = library.cadaclysm_query(handle, encoded, out, total)
        # A second call could in principle see a different document; it cannot
        # here, since nothing between the two calls can mutate the scene.
        return list(out[:min(written, total)])

    @property
    def placements(self) -> "list[Placement]":
        """What this document draws and where -- see [`Placement`].

        **Not the nodes, and the difference is the point.** A node walk draws a
        Rhino block once at its definition's frame and every placement of it not
        at all. This is the list to iterate to draw.
        """
        return [Placement(self, i)
                for i in range(_lib().cadaclysm_placement_count(self._handle))]

    @property
    def roots(self) -> "list[Node]":
        """The nodes nothing else contains."""
        library, handle = _lib(), self._handle
        found = []
        for i in range(library.cadaclysm_root_count(handle)):
            index = library.cadaclysm_root(handle, i)
            if index != NONE:
                found.append(Node(self, index))
        return found

    def _node_or_none(self, index: int) -> "Node | None":
        """A node index as a `Node`, or None for `CADACLYSM_NONE`."""
        return None if index == NONE else Node(self, index)

    def walk(self):
        """Every node reachable from the roots, parents before children."""
        for root in self.roots:
            yield from root.walk()

    # -- building geometry --

    def realize_all(self) -> int:
        """Build every mesh now, across threads, and say how many were built.

        Reading is lazy so a caller can put the tree on screen while the shapes
        are still to come. Asking node by node instead meshes them one at a
        time on one core; this does the same work over every core. On a large
        STEP file that is the difference between a demo and a wait.

        Watch it from another thread with `realized` and `realize_total`, or
        stop it with `cancel`.
        """
        return _lib().cadaclysm_realize_all(self._handle)

    def realize_meshes(self, skip_surfaced: bool = True) -> int:
        """`realize_all`, leaving alone every node that carries surfaces when
        `skip_surfaced` is true: a renderer drawing those parts from their surfaces
        never pays for their triangles, and takes their bounds from `bounds` (which
        falls back to the surfaces). Nodes without surfaces are built as usual."""
        return _lib().cadaclysm_realize_meshes(self._handle, 1 if skip_surfaced else 0)

    @property
    def realized(self) -> int:
        """How many nodes `realize_all` has finished with. Safe to read from another thread."""
        return _lib().cadaclysm_realized(self._handle)

    @property
    def realize_total(self) -> int:
        """How many there will be in all — zero until `realize_all` starts."""
        return _lib().cadaclysm_realize_total(self._handle)

    def cancel(self) -> None:
        """Ask a running `realize_all` to stop.

        **One-way, and for the life of the scene.** Nothing clears the flag, so
        every later `realize_all` on this scene returns 0 at once; a UI that
        offers "Cancel" and then "Load anyway" must reopen the file. Meshes
        stay available one node at a time either way.
        """
        _lib().cadaclysm_cancel(self._handle)

    def forget_meshes(self) -> None:
        """Drop every mesh the scene has built; the next ask rebuilds. For a
        viewer that has uploaded them and wants the memory back. Every `Mesh`
        and `Polylines` view handed out before this is over freed memory."""
        _lib().cadaclysm_forget_meshes(self._handle)

    # -- writing --

    def save(self, path, fmt: str = "glb") -> None:
        """Write the whole scene to `path`: `"glb"` (binary glTF), `"gltf"`
        (text glTF, one file either way) or `"obj"` (Wavefront, every
        placement baked to its own named object, a `.mtl` beside it under the
        same stem when anything has a colour).

        Every placement of every shape, named and placed as the tree is, with a
        material per colour -- where `Node.save_mesh` writes one node's mesh
        on its own (the same names in `mesh_formats()` are those one-mesh forms).
        Coordinates are the scene's own, in the convention it was opened with
        (`Y_UP` for the Y-up metres glTF specifies); the winding is turned for
        a clockwise convention so the file reads right-side out everywhere.
        Raises `CadaclysmError` on any other format or a failed write.
        """
        ok = _lib().cadaclysm_scene_save(self._handle, str(path).encode(), fmt.encode())
        if not ok:
            raise CadaclysmError(_last_error() or f"could not write {path}")

    # -- drawing --

    def show(self, **options) -> None:
        """Draw every visible placement with the viewer in use. Keywords: view= (front
        back left right top bottom iso), az=, el=, zoom=, up= (default from the convention
        the scene was opened with), edges= (the B-rep edges over the shapes; free curves
        are drawn either way), width=, height=, hint=. No tolerance=: a document is drawn
        at the tolerance it was read with."""
        self._draw("show", self.placements, options, "Scene")

    def view(self, **options):
        """Orbit the model with the viewer in use; returns (azimuth, elevation, zoom)."""
        return self._draw("view", self.placements, options, "Scene")

    def svg(self, path=None, **words) -> "str | None":
        """Every visible placement's wireframe as SVG, from the camera the keywords
        describe -- the same words `show` takes, read by the library itself rather
        than a viewer: view= (front back left right top bottom iso), az=, el= over
        it, up= (default from the convention this scene was opened with), fov= (0,
        the default, is orthographic), size=(width, height), margin= (fraction of
        the content's extent left each side), tolerance= (how far a written curve
        may stray, in page units), stroke=, width= (the stroke's, in page units),
        background= (`None` for transparent), edges=, curves=, isocurves=,
        polylines= (which line sets are drawn; edges alone by default).

        With `path`, writes the file and returns `None`; without, returns the SVG
        text. Raises `CadaclysmError` on a refused option (naming the field) or a
        failed write."""
        o = _svg_options(self._default_up(), **words)
        if path is not None:
            ok = _lib().cadaclysm_scene_svg(self._handle, str(path).encode(), ctypes.byref(o))
            if not ok:
                raise CadaclysmError(_last_error() or f"could not write {path}")
            return None
        p = _lib().cadaclysm_scene_svg_text(self._handle, ctypes.byref(o))
        if p is None:
            raise CadaclysmError(_last_error() or "svg")
        return p.decode("utf-8")

    def _default_up(self) -> str:
        """`"y"` or `"z"`: which axis is up by default, from the convention this
        scene was opened with. Shared by `_draw` (the viewer) and `svg` (the
        library's own camera), so the two agree without either scene keeping the
        other's notion of "default"."""
        return "y" if (self.convention & 0xFF) in _Y_UP else "z"

    def _draw(self, mode, placements, options, owner):
        if "tolerance" in options:
            raise TypeError(f"{owner}.{mode} takes no tolerance: a document is drawn at the "
                            "tolerance it was read with")
        viewer = _viewer()
        opts = viewer.options("iso", default_up=self._default_up(), **options)
        edges = options.get("edges", True)
        meshes, lines = _drawn_placements(placements, edges)
        # Lines are drawn only while the edges flag is clear, so free curves keep it clear;
        # only a picture with no lines at all may be asked for no (screen-space) edges.
        opts["flags"] = viewer.NO_EDGES if not edges and not lines else 0
        last = viewer.draw(mode, self.path.name, meshes, lines, opts)
        if mode == "view":
            viewer.announce(owner.lower(), last)
        return last


# ---- opening --------------------------------------------------------------


def declared_schema(model: Path) -> str:
    """The schema a STEP or IFC file says it speaks, from its own header.

    `FILE_SCHEMA(('IFC2X3'))` sits near the top of the file, so a few kilobytes
    is plenty and a 300 MB IFC costs nothing to ask.
    """
    with Path(model).open("rb") as f:
        head = f.read(8192).decode("latin-1")
    found = re.search(r"FILE_SCHEMA\s*\(\s*\(\s*'([^']+)'", head, re.IGNORECASE)
    return found.group(1) if found else ""


def _plain(name: str) -> str:
    return "".join(c for c in name.upper() if c.isalnum())


def resolve_schema(model: Path, schema):
    """`schema` resolved to `(chosen, fallbacks)` — one `.exp`, or a list to try.

    A file is taken as given. A directory is matched against what the model
    says it speaks: the ABI registers exactly one schema per open, so something
    has to choose, and the file itself is the one that knows. Where the
    declared name resembles no filename the whole directory comes back as
    fallbacks to try in turn — AP203 calls itself CONFIG_CONTROL_DESIGN, and
    there will be others.
    """
    if schema is None:
        return None, []
    schema = Path(schema)
    if schema.is_file():
        return schema, []
    if not schema.is_dir():
        raise CadaclysmError(f"schema {schema} is neither a file nor a directory")
    available = sorted(schema.glob("*.exp"))
    if not available:
        raise CadaclysmError(f"no .exp schemas in {schema}")

    declared = _plain(declared_schema(model))
    matches = [
        exp
        for exp in available
        if declared
        and (declared.startswith(_plain(exp.stem)) or _plain(exp.stem).startswith(declared))
    ]
    if matches:
        # The longest name that still matches is the most specific one.
        return max(matches, key=lambda exp: len(_plain(exp.stem))), []
    return None, available


def open(path, schema=None, convention=Convention.NATIVE,  # noqa: A001 - the verb this module is for
         colors=False) -> Scene:
    """Open a CAD file.

    `schema` names an EXPRESS schema (`.exp`) beyond the ones built into the
    library — every schema the project ships is compiled in, so a STEP or IFC
    file opens with None, and one is passed only for a schema the library does
    not carry (it replaces a built-in of the same name). A directory is allowed
    and is matched against what the file says it speaks.

    `convention` is the space to read the file into — a `Convention`, optionally
    OR'd with `FILE_UNITS` and `UV_WORLD`. The library does the converting, so
    every array a caller reads out is already in it; there is nothing left for
    the caller to rotate or scale. The default keeps the file's own axes and
    units, so a script written before this parameter existed is unaffected.

    There is no `surfaces` argument, and there used to be. Every body now carries
    both descriptions -- its triangles and its trimmed surfaces -- and builds
    whichever is asked for, so `Node.mesh` and `Node.surfaces` are both there to
    read on any document, and reading one costs nothing towards the other. A file
    no longer has to be opened twice, or opened again, to be looked at the other
    way.

    A `.zip` opens its first readable member; `Scene.source_name` says which.

    Raises `CadaclysmError` on failure, carrying what the library said. An
    unrecognised `convention` is one of the failures it raises on, so a typo
    cannot be mistaken for `NATIVE`. It never returns None, so a null handle
    cannot reach a later call.
    """
    path = Path(path)
    if not path.exists():
        raise CadaclysmError(f"{path}: no such file")

    library = _lib()

    # A directory goes over whole rather than being narrowed to one file here.
    # The library walks it and keys each schema under the name that schema
    # itself *declares*, which is the only authority on the matter: `ap203.exp`
    # declares `config_control_design`, so choosing by filename hands it to a
    # file whose FILE_SCHEMA says AP203 -- and, having matched, leaves nothing
    # to fall back to. `123Block_Color.stp` is refused that way and opens fine
    # when the directory is passed through, its real schema being the one in
    # `ap203e2_mim_lf.exp`.
    if schema is not None and Path(schema).is_dir():
        options, _held = _options(convention, schema, colors)
        pointer = library.cadaclysm_open(str(path).encode(), ctypes.byref(options))
        if pointer:
            return Scene(pointer, path, Path(schema), int(convention))
        raise CadaclysmError(f"{path.name}: {_last_error()}")

    chosen, fallbacks = resolve_schema(path, schema)
    for candidate in [chosen] if chosen is not None or not fallbacks else fallbacks:
        options, _held = _options(convention, candidate, colors)
        pointer = library.cadaclysm_open(str(path).encode(), ctypes.byref(options))
        if pointer:
            return Scene(pointer, path, candidate, int(convention))
    raise CadaclysmError(f"{path.name}: {_last_error()}")


def open_memory(data, format, schema=None, name="<memory>",  # noqa: A002
                convention=Convention.NATIVE, colors=False) -> Scene:
    """Open a CAD file already in bytes.

    `format` names the kind as an extension would — `"step"`, `"ifc"`, `"igs"`,
    `"brep"`, `"3dm"`, `"scad"` — since there is no file name to take it from.
    A leading dot is allowed and ignored. `schema` must be a path here: there
    is no file on disk to read a `FILE_SCHEMA` line out of. `convention` is as
    `open` takes it.
    """
    buffer = (ctypes.c_uint8 * len(data)).from_buffer_copy(data)
    options, _held = _options(convention, schema, colors)
    pointer = _lib().cadaclysm_open_memory(
        buffer,
        len(data),
        str(format).encode(),
        ctypes.byref(options),
    )
    if not pointer:
        raise CadaclysmError(f"{name}: {_last_error()}")
    return Scene(pointer, Path(name), Path(schema) if schema is not None else None,
                 int(convention))


# ---- a look at a file, when run directly ----------------------------------


def _main(argv) -> int:
    """`python cadaclysm.py model.stp [schema]` — the tree and the totals.

    Here so the module can be run against a file without a window, a GPU or
    anything installed beyond the standard library.
    """
    if not argv:
        print(__doc__.strip().splitlines()[0])
        print(f"usage: python {Path(__file__).name} MODEL [SCHEMA]")
        return 2
    with open(argv[0], argv[1] if len(argv) > 1 else None) as scene:
        print(f"cadaclysm {scene.version} - {scene.path.name}")
        if scene.schema_path:
            print(f"  schema: {scene.schema_path.name}")
        print(f"  {scene.schema or '(no schema)'}, {scene.metres_per_unit} m/unit, "
              f"{len(scene)} nodes, {len(scene.roots)} roots")
        for node in scene.walk():
            drawn = " *" if node.can_mesh else ""
            print(f"  {'  ' * node.depth}{node.label}  [{node.kind}]{drawn}")
        for note in scene.diagnostics:
            print(f"  diagnostic: {note}")
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
