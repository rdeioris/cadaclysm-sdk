"""The cadaclysm_blacksmith C ABI, as Python objects: this file is the whole binding.

    from cadaclysm_blacksmith import Axis, Profile, Selector, Workplane

    outline = Profile.rect(80, 40).with_hole(Profile.circle(4))
    plate = Workplane.xy().extrude(outline, 6).solid()
    pin = (Workplane.from_solid(plate)
           .faces(Selector.max(Axis.Z)).workplane()
           .cylinder(5, 10).solid())             # seated over the hole, on material
    part = plate.join(pin)
    corners = [e for e in part.edges                          # the plate's own corners:
               if e.is_line and abs(e.direction[2]) > 0.99    # vertical lines
               and all(part.face_kind(f) == "plane" for f in e.faces)]  # between planes
    part = part.fillet(corners, 1.0)
    part.step("plate.stp")
    positions, normals, indices = part.mesh(tolerance=0.05)

It uses `ctypes` and the published header `include/cadaclysm_blacksmith.h`, the
way any Python program would -- no generated bindings, no Rust, no build system
(Python 3.8+). Under Pyodide, in the website's notebook, the same file runs
against the blacksmith compiled to wasm instead, through one shim behind `_lib()`.
Drop it beside your own script and point `CADACLYSM_BLACKSMITH_LIBRARY` at the
shared library if it is not where this looks by default (`target/release` or
`target/debug` of the repository this file ships in).

`numpy` is imported only when a mesh or polylines are asked for.

## Every array borrows from its solid

`Solid.mesh`, `Solid.face_triangles` and `Solid.edge_polylines` hand back **read-only numpy views into
the library's own cache** rather than copies. Each view keeps its `Solid` alive
through `.base`, so a view cannot outlive the solid by having merely dropped the
last reference to it. Two things can still invalidate a view:

* `Solid.close()` (or leaving a `with` block), which frees the handle.
* Meshing the same solid again at a *different* tolerance, which replaces the
  cache the earlier views point into.

Call `.copy()` on any array that must outlive either. Strings are copied on the
way out and are always safe. Under Pyodide (the website's notebook) the arrays
are copies and never invalidate.

## The chain mirrors the Rust `Workplane`

A build call (`cuboid`, `cylinder`, `extrude`, `extrude_tapered`, `revolve`,
`sweep`, `loft`) makes a fresh `Solid`;
combining two solids is explicit -- build the pin as its own solid, then
`plate.join(pin)`. Every step here raises `BuildError` at once with the
library's own text, rather than latching the first error until some final call.

## Frames

Every call taking a `frame` reads twelve numbers: an origin, then the x, y and z
axes. `Frame` builds them and checks the axes are square and right-handed, so
they need not be typed out -- `Frame.xy((0, 0, 5))` is the XY plane at z = 5,
`Frame.at(point, normal)` the plane through a point facing a direction, and
`Frame.of(solid.face_frame(i))` a face's frame to read or move:

    lid = Solid.extrude(Profile.rect(30, 30), Frame.xy((0, 0, 20)), 2)
    boss = Solid.extrude(Profile.circle(6), Frame.at((10, 0, 0), (1, 1, 0)), 4)

## Solids from files

`Solid.open("housing.step")` reads a STEP, ACIS, Rhino, OCCT `.brep`, IGES or IFC
file's body as a solid to cut, fillet, join with parts built here and write back
out (`Solid.open_all` for every body; JT and OpenSCAD are meshes and have none).
On the desktop it goes through the reader module, `cadaclysm.py`, and
`Solid.from_node(scene, node)` takes one node of a scene you already have open:
the reader's brep is handed to this library by pointer and shared, never copied,
so the two libraries must come from the same release (the call checks). In the
notebook the wasm reads the file itself. What an imported solid can do is what
its geometry allows -- see `Solid.open`.

`join`/`cut`/`common` default their `tolerance` to `0.05`, not the tighter
`1e-6` `fillet`, `chamfer` and `shell` use, for cost: a boolean meshes both
solids at its tolerance, and a curved solid at `1e-6` is hundreds of thousands
of triangles. `0.05` is what the crate's own boolean tests run at; a tighter one
is as correct, only slower.
"""

import ctypes
import enum
import numbers
import operator
import os
import platform
import sys
from ctypes import (POINTER, c_bool, c_char_p, c_double, c_float, c_size_t, c_uint32, c_uint64, c_void_p)
from pathlib import Path as _FsPath   # `Path` here is the outline builder
from typing import TYPE_CHECKING

if TYPE_CHECKING:   # names the annotations use; imported when used, never at load
    import cadaclysm
    import numpy

__all__ = [
    "Axis", "BuildError", "Edge", "Frame", "Manifold", "Path", "Profile", "Selector", "Slant", "Solid", "SweepPath", "Workplane",
    "brep_layout_id", "build_date", "default_schema", "library_path", "license", "license_info", "license_notice_count",
    "version",
    "write_step", "write_step_text", "__version__",
]

# This file's own version (the workspace's); `version()` is the loaded library's.
__version__ = "0.5.1"

NONE = 0xFFFFFFFF
UNITS = {"m": 0, "mm": 1, "in": 2}


class BuildError(Exception):
    """What the library refused, in its own words (`cadaclysm_blacksmith_last_error`)."""


# ---- the library ----------------------------------------------------------


def _library_name() -> str:
    suffix = {"Windows": ".dll", "Darwin": ".dylib"}.get(platform.system(), ".so")
    return "cadaclysm_blacksmith.dll" if suffix == ".dll" else "libcadaclysm_blacksmith" + suffix


def library_path() -> _FsPath:
    """Where the shared library is, preferring a release build over a debug one.

    `CADACLYSM_BLACKSMITH_LIBRARY` first, so this file works dropped beside a script
    anywhere; then next to this file; then a `lib/` directory in any ancestor
    (the SDK layout); then a `target/release` (or `target/debug`) in any ancestor
    (this repository's layout).
    """
    if _WASM:
        return _FsPath("cadaclysm_wasm")   # the exports on `globalThis.cadaclysm`; nothing to load
    name = _library_name()
    override = os.environ.get("CADACLYSM_BLACKSMITH_LIBRARY")
    if override:
        candidate = _FsPath(override)
        # A directory or the library itself, since both are things to point at.
        candidate = candidate / name if candidate.is_dir() else candidate
        if candidate.exists():
            return candidate
        raise BuildError(f"CADACLYSM_BLACKSMITH_LIBRARY={override} names nothing that exists")

    here = _FsPath(__file__).resolve().parent
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
    raise BuildError(
        f"{name} not found. Looked in:\n"
        + "".join(f"    {c}\n" for c in searched)
        + "Build it with:\n    cargo build --release -p cadaclysm-blacksmith-capi\n"
        "or run fetch.py in an SDK checkout, or point CADACLYSM_BLACKSMITH_LIBRARY at it."
    )


def default_schema() -> _FsPath:
    """`ap203.exp`: `CADACLYSM_SCHEMAS/ap203.exp` if set; else beside this file (the pip
    package); else in a `schemas/` directory in any ancestor, nearest first (the SDK's,
    beside `python/`, or this repository's, at its root).

    The `ap203.exp` file this finds is no longer needed: the kernel writes against
    its built-in AP203 when no schema is given. This function stays for compatibility
    and the parity gates; nothing here calls it to write STEP any more."""
    override = os.environ.get("CADACLYSM_SCHEMAS")
    candidates = []
    if override:
        candidates.append(_FsPath(override) / "ap203.exp")
    here = _FsPath(__file__).resolve().parent
    candidates.append(here / "ap203.exp")
    candidates += [ancestor / "schemas" / "ap203.exp" for ancestor in [here, *here.parents]]
    url = os.environ.get("CADACLYSM_SCHEMA_URL")
    if _WASM and override and url and not (_FsPath(override) / "ap203.exp").exists():
        # The notebook's worker names where the schema is served from; fetched once
        # into Pyodide's file system, synchronously -- allowed off the main thread.
        # A plain XMLHttpRequest rather than `pyodide.http.open_url`, which checks no
        # status: a 404 page must not be cached as the schema for the session.
        from js import XMLHttpRequest
        request = XMLHttpRequest.new()
        request.open("GET", url + "ap203.exp", False)
        request.send()
        if request.status != 200:
            raise BuildError(f"schema: {request.status} fetching {url}ap203.exp")
        _FsPath(override).mkdir(parents=True, exist_ok=True)
        (_FsPath(override) / "ap203.exp").write_text(str(request.response))
    for c in candidates:
        if c.exists():
            return c
    raise BuildError(
        "ap203.exp not found (none is needed to write STEP: leave schema out for the "
        "built-in AP203, or pass a schema name, a .exp path or EXPRESS text)"
    )


class _Mesh(ctypes.Structure):
    _fields_ = [("positions", POINTER(c_float)), ("normals", POINTER(c_float)),
                ("indices", POINTER(c_uint32)), ("vertex_count", c_uint32), ("index_count", c_uint32)]


class _Polylines(ctypes.Structure):
    _fields_ = [("points", POINTER(c_float)), ("offsets", POINTER(c_uint32)),
                ("point_count", c_uint32), ("polyline_count", c_uint32)]


class _FaceTriangles(ctypes.Structure):
    _fields_ = [("counts", POINTER(c_uint32)), ("face_count", c_uint32)]


class _Edge(ctypes.Structure):
    _fields_ = [("kind", c_char_p), ("faces", POINTER(c_uint32)), ("face_count", c_uint32),
                ("segments", POINTER(c_double)), ("segment_count", c_uint32)]


_PROGRESS = ctypes.CFUNCTYPE(None, c_char_p, c_size_t, c_size_t, c_void_p)
_D = POINTER(c_double)
_U = POINTER(c_uint32)
_SOLID = c_void_p
_PROFILE = c_void_p
_PATH = c_void_p
_SWEEP_PATH = c_void_p

_ENTRY_POINTS = [
    ("cadaclysm_blacksmith_last_error", c_char_p, []),
    ("cadaclysm_blacksmith_license_set", ctypes.c_bool, [c_char_p]),
    ("cadaclysm_blacksmith_license_info", c_char_p, []),
    ("cadaclysm_blacksmith_license_notice_count", c_uint64, []),
    ("cadaclysm_blacksmith_build_date", c_char_p, []),
    ("cadaclysm_blacksmith_version", c_char_p, []),
    ("cadaclysm_blacksmith_solid_free", None, [_SOLID]),
    ("cadaclysm_blacksmith_profile_free", None, [_PROFILE]),
    ("cadaclysm_blacksmith_profile_rect", _PROFILE, [c_double, c_double]),
    ("cadaclysm_blacksmith_profile_circle", _PROFILE, [c_double]),
    ("cadaclysm_blacksmith_profile_slot", _PROFILE, [c_double, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_profile_regular_polygon", _PROFILE, [c_double, c_double, c_double, c_uint32, c_double]),
    ("cadaclysm_blacksmith_profile_spline", _PROFILE, [_D, c_size_t, c_uint32, _D, c_bool]),
    ("cadaclysm_blacksmith_profile_polygon", _PROFILE, [_D, c_size_t]),
    ("cadaclysm_blacksmith_profile_with_hole", _PROFILE, [_PROFILE, _PROFILE]),
    ("cadaclysm_blacksmith_translate_profile", _PROFILE, [_PROFILE, c_double, c_double]),
    ("cadaclysm_blacksmith_profile_round", _PROFILE, [_PROFILE, c_double, _U, c_size_t, c_bool]),
    ("cadaclysm_blacksmith_profile_chain", _PROFILE, [POINTER(c_void_p), c_size_t, c_double]),
    ("cadaclysm_blacksmith_profile_from_loops", _PROFILE, [POINTER(c_void_p), c_size_t]),
    ("cadaclysm_blacksmith_profile_close_loop", _PROFILE, [_PROFILE]),
    ("cadaclysm_blacksmith_profile_polylines", _Polylines, [_PROFILE, c_double]),
    ("cadaclysm_blacksmith_path_begin", _PATH, [c_double, c_double]),
    ("cadaclysm_blacksmith_path_line_to", c_bool, [_PATH, c_double, c_double]),
    ("cadaclysm_blacksmith_path_arc_to", c_bool, [_PATH, c_double, c_double, c_double, c_double, c_bool]),
    ("cadaclysm_blacksmith_path_bezier_to", c_bool, [_PATH] + [c_double] * 6),
    ("cadaclysm_blacksmith_path_nurbs_to", c_bool, [_PATH, _D, c_size_t, _D, _D, c_size_t, c_uint32]),
    ("cadaclysm_blacksmith_path_end", _PROFILE, [_PATH]),
    ("cadaclysm_blacksmith_path_end_open", _PROFILE, [_PATH]),
    ("cadaclysm_blacksmith_path_free", None, [_PATH]),
    ("cadaclysm_blacksmith_cuboid", _SOLID, [c_double] * 3),
    ("cadaclysm_blacksmith_cylinder", _SOLID, [c_double] * 2),
    ("cadaclysm_blacksmith_cone", _SOLID, [c_double] * 2),
    ("cadaclysm_blacksmith_sphere", _SOLID, [c_double]),
    ("cadaclysm_blacksmith_torus", _SOLID, [c_double] * 2),
    ("cadaclysm_blacksmith_wedge", _SOLID, [c_double] * 4),
    ("cadaclysm_blacksmith_extrude", _SOLID, [_PROFILE, _D, c_double]),
    ("cadaclysm_blacksmith_extrude_open", _SOLID, [_PROFILE, _D, c_double]),
    ("cadaclysm_blacksmith_extrude_tapered", _SOLID, [_PROFILE, _D, c_double, c_double]),
    ("cadaclysm_blacksmith_extrude_open_tapered", _SOLID, [_PROFILE, _D, c_double, c_double]),
    ("cadaclysm_blacksmith_extrude_between", _SOLID, [_PROFILE, _D, _D, _D]),
    ("cadaclysm_blacksmith_extrude_open_between", _SOLID, [_PROFILE, _D, _D, _D]),
    ("cadaclysm_blacksmith_slant_of_plane", c_bool, [_D, _D, _D, _D]),
    ("cadaclysm_blacksmith_loft", _SOLID, [_PROFILE, _D, _PROFILE, _D]),
    ("cadaclysm_blacksmith_loft_open", _SOLID, [_PROFILE, _D, _PROFILE, _D]),
    ("cadaclysm_blacksmith_loft_through", _SOLID, [POINTER(c_void_p), _D, c_size_t]),
    ("cadaclysm_blacksmith_loft_through_open", _SOLID, [POINTER(c_void_p), _D, c_size_t]),
    ("cadaclysm_blacksmith_revolve", _SOLID, [_PROFILE, _D, c_double]),
    ("cadaclysm_blacksmith_revolve_open", _SOLID, [_PROFILE, _D, c_double]),
    ("cadaclysm_blacksmith_coil", _SOLID, [_PROFILE, _D, c_double, c_double]),
    ("cadaclysm_blacksmith_revolve_in_plane", _SOLID, [_PROFILE, _D, _D, c_double]),
    ("cadaclysm_blacksmith_revolve_open_in_plane", _SOLID, [_PROFILE, _D, _D, c_double]),
    ("cadaclysm_blacksmith_sweep_path_begin", _SWEEP_PATH, [c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_sweep_path_line_to", c_bool, [_SWEEP_PATH, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_sweep_path_arc", c_bool, [_SWEEP_PATH] + [c_double] * 7),
    ("cadaclysm_blacksmith_sweep_path_along", _SWEEP_PATH, [_PROFILE, _D, c_double, c_bool]),
    ("cadaclysm_blacksmith_sweep_path_free", None, [_SWEEP_PATH]),
    ("cadaclysm_blacksmith_sweep", _SOLID, [_PROFILE, _D, _SWEEP_PATH]),
    ("cadaclysm_blacksmith_sweep_open", _SOLID, [_PROFILE, _D, _SWEEP_PATH]),
    ("cadaclysm_blacksmith_pipe", _SOLID, [_SWEEP_PATH, c_double, c_double]),
    ("cadaclysm_blacksmith_extrude_faces", _SOLID, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_face", _SOLID, [_PROFILE, _D]),
    ("cadaclysm_blacksmith_face_sheet", _SOLID, [_SOLID, c_uint32]),
    ("cadaclysm_blacksmith_drop_faces", _SOLID, [_SOLID, _U, c_size_t]),
    ("cadaclysm_blacksmith_place", _SOLID, [_SOLID, _D]),
    ("cadaclysm_blacksmith_translate", _SOLID, [_SOLID, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_rotate", _SOLID, [_SOLID, _D, c_double]),
    ("cadaclysm_blacksmith_mirror", _SOLID, [_SOLID, _D]),
    ("cadaclysm_blacksmith_join", _SOLID, [_SOLID, _SOLID, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_cut", _SOLID, [_SOLID, _SOLID, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_common", _SOLID, [_SOLID, _SOLID, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_split_sheet", _SOLID, [_SOLID, _SOLID, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_trim", _SOLID, [_SOLID, _SOLID, c_bool, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_fillet", _SOLID, [_SOLID, _U, c_size_t, c_double, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_chamfer", _SOLID, [_SOLID, _U, c_size_t, c_double, c_double]),
    ("cadaclysm_blacksmith_shell", _SOLID, [_SOLID, c_double, _U, c_size_t, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_thicken", _SOLID, [_SOLID, c_double, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_push_pull", _SOLID, [_SOLID, c_uint32, c_double, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_push_pull_faces", _SOLID, [_SOLID, _U, c_size_t, c_double, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_merge_flush", _SOLID, [_SOLID]),
    ("cadaclysm_blacksmith_refillet", _SOLID, [_SOLID, c_uint32, c_double, c_double]),
    ("cadaclysm_blacksmith_unfillet", _SOLID, [_SOLID, c_uint32]),
    ("cadaclysm_blacksmith_rechamfer", _SOLID, [_SOLID, c_uint32, c_double, c_double]),
    ("cadaclysm_blacksmith_unchamfer", _SOLID, [_SOLID, c_uint32]),
    ("cadaclysm_blacksmith_split", _SOLID, [_SOLID, _SOLID, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_split_by_plane", _SOLID, [_SOLID, _D, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_lump_count", c_uint32, [_SOLID]),
    ("cadaclysm_blacksmith_lump", _SOLID, [_SOLID, c_uint32]),
    ("cadaclysm_blacksmith_face_count", c_uint32, [_SOLID]),
    ("cadaclysm_blacksmith_select_face", c_uint32, [_SOLID, c_uint32, _D, c_uint32]),
    ("cadaclysm_blacksmith_face_frame", c_bool, [_SOLID, c_uint32, _D]),
    ("cadaclysm_blacksmith_frame_midplane", c_bool, [_D, _D, _D]),
    ("cadaclysm_blacksmith_frame_through", c_bool, [_D, _D, _D, _D]),
    ("cadaclysm_blacksmith_coloured", _SOLID, [_SOLID, c_uint32, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_colour", c_bool, [_SOLID, c_uint32, _D]),
    ("cadaclysm_blacksmith_face_kind", c_char_p, [_SOLID, c_uint32]),
    ("cadaclysm_blacksmith_edge_count", c_uint32, [_SOLID]),
    ("cadaclysm_blacksmith_edge", c_bool, [_SOLID, c_uint32, POINTER(_Edge)]),
    ("cadaclysm_blacksmith_mesh", _Mesh, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_mesh_face_triangles", _FaceTriangles, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_edge_polylines", _Polylines, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_bounds", c_bool, [_SOLID, c_double, _D, _D]),
    ("cadaclysm_blacksmith_leaked_edges", c_uint32, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_unpaired_edges", c_uint32, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_manifold", c_bool, [_SOLID, _U]),
    ("cadaclysm_blacksmith_step", c_void_p, [POINTER(c_void_p), c_size_t, c_char_p, c_uint32]),
    ("cadaclysm_blacksmith_string_free", None, [c_void_p]),
    ("cadaclysm_blacksmith_from_brep", _SOLID, [c_void_p, c_char_p]),
    ("cadaclysm_blacksmith_brep_layout_id", c_char_p, []),
]

# Under Pyodide (the website's notebook) there is no shared library to load: the
# same entry points are wasm exports on `globalThis.cadaclysm`, and `_lib()` hands
# out the shim below instead of a `ctypes.CDLL`.
_WASM = sys.platform == "emscripten"


class _WasmLibrary:
    """The same entry points over the wasm module (`globalThis.cadaclysm`,
    built from `crates/cadaclysm-wasm`), shaped so every `_lib().name(...)`
    call site above and below runs unchanged: handles are ints, a ctypes
    array in becomes a typed array, an out-array is filled back, a failing
    call records its message and returns the C ABI's null/false/NONE.

    A wasm export takes the C call's arguments minus the ones a JS value
    carries in itself (an array's count, the progress `user` pointer, the
    out-arguments); it returns what C wrote through an out-argument; and it
    throws a JS `Error` -- whose message is the C ABI's own text -- where C
    returns null and leaves `last_error`. The tables below say which is
    which, per entry point; the rest of the module never sees the difference.
    """

    # what a failing call returns, by the C ABI's convention for that name:
    # `False` for the bool-returning verbs, a zeroed struct (a null pointer in
    # it) for the struct-returning ones, NONE for the u32 ones that reserve
    # it, and 0 (a null handle, or a count the caller checks `last_error` on)
    # for everything else
    _BOOLS = {"path_line_to", "path_arc_to", "path_bezier_to", "path_nurbs_to", "sweep_path_line_to",
              "sweep_path_arc", "slant_of_plane", "face_frame", "frame_midplane", "frame_through", "bounds", "edge", "colour", "manifold", "license_set"}
    _FAILS = {"select_face": NONE, "leaked_edges": NONE, "unpaired_edges": NONE,
              "mesh": _Mesh(), "mesh_face_triangles": _FaceTriangles(), "edge_polylines": _Polylines(),
              "profile_polylines": _Polylines()}
    # results that C writes into an out-array of doubles at this position, and the
    # wasm returns as a typed array (`bounds` fills two, `edge` a record: see `_back`)
    _OUT = {"slant_of_plane": 3, "face_frame": 2, "frame_midplane": 2, "frame_through": 3}
    # argument positions the C call has and the wasm call does not: an array's
    # count (a typed array knows its length), the progress `user` pointer, and
    # the out-arguments above
    _DROP = {"profile_polygon": (1,), "path_nurbs_to": (2, 5), "join": (4,), "cut": (4,), "common": (4,),
             "split_sheet": (4,), "trim": (5,), "drop_faces": (2,), "profile_round": (3,), "profile_spline": (1,), "profile_chain": (1,), "profile_from_loops": (1,), "loft_through": (2,), "loft_through_open": (2,), "fillet": (2, 6), "chamfer": (2,), "shell": (3, 6), "thicken": (4,), "push_pull": (5,), "push_pull_faces": (2, 6), "split": (4,), "split_by_plane": (4,), "step": (1,),
             "slant_of_plane": (3,), "face_frame": (2,), "bounds": (2, 3), "edge": (2,), "colour": (2,), "manifold": (1,)}
    # strings the C side returns as `const char*`, and the module decodes
    _TEXTS = {"version", "build_date", "face_kind", "license_info", "brep_layout_id"}

    def __init__(self):
        import js
        self._js = js.cadaclysm
        self._error = None

    # -- the two the C side owns memory for, and the browser has none
    def cadaclysm_blacksmith_last_error(self):
        return self._error.encode() if self._error else None

    def cadaclysm_blacksmith_string_free(self, _text):
        pass

    def open_file(self, data: bytes, extension: str) -> "list[int]":
        """Every body a file draws, as solid handles -- the wasm reads the file
        itself, readers and kernel being one module. Not a C entry point, so it
        sits outside the table the rest goes through."""
        from pyodide.ffi import JsException, to_js
        try:
            return [int(h) for h in self._js.cadaclysm_blacksmith_open_file(to_js(memoryview(data)), extension)]
        except JsException as e:
            if self._trapped(e):
                raise
            raise BuildError(self._message(e)) from None

    def __getattr__(self, name):
        prefix = "cadaclysm_blacksmith_"   # str.removeprefix is 3.9+; this module runs on 3.8
        short = name[len(prefix):] if name.startswith(prefix) else name
        if name == short or name.startswith("_"):
            raise AttributeError(name)
        try:
            function = getattr(self._js, name)
        except AttributeError:
            raise BuildError(f"the wasm module has no {name}: rebuild it with `sh web/build.sh`") from None
        dropped = self._DROP.get(short, ())

        def call(*args):
            from pyodide.ffi import JsException
            self._error = None
            if short == "select_face" and args[2] is None:
                args = (args[0], args[1], (c_double * 0)(), args[3])   # the direction, unread for kinds 0/1/3
            passed = [self._arg(a) for i, a in enumerate(args) if i not in dropped]
            try:
                result = function(*passed)
            except JsException as e:
                if self._trapped(e):
                    raise   # not a refusal: the kernel is dead, and the page reboots it
                self._error = self._message(e)
                return self._FAILS.get(short, False if short in self._BOOLS else 0)
            return self._back(short, args, result)

        setattr(self, name, call)   # resolved once; `Solid.close` asks for `solid_free` per solid
        return call

    @staticmethod
    def _trapped(e) -> bool:
        """A `WebAssembly.RuntimeError`: the wasm trapped (a panic aborts, the
        tables stay borrowed), which no `last_error` can stand for."""
        import js
        error = getattr(e, "js_error", None)
        return error is not None and bool(js.WebAssembly.RuntimeError.prototype.isPrototypeOf(error))

    @staticmethod
    def _message(e) -> str:
        """The thrown `Error`'s own message: what the C side would have left in `last_error`."""
        text = getattr(getattr(e, "js_error", None), "message", None) or str(e)
        return text[len("Error: "):] if text.startswith("Error: ") else text

    def _arg(self, a):
        """One C argument as the wasm takes it: numbers and handles as they are,
        text as a string, a ctypes array as a typed array, a progress callback
        as itself (Pyodide lends it to JS for the call, which is as long as
        the wasm holds it)."""
        import js
        from pyodide.ffi import to_js
        if a is None or isinstance(a, bool):
            return a
        if isinstance(a, numbers.Integral):   # `int`, and numpy's, as `c_uint32` takes them
            return operator.index(a)
        if isinstance(a, numbers.Real):       # `float`, and numpy's, as `c_double` takes them
            return float(a)
        if isinstance(a, bytes):
            return a.decode("utf-8")
        if isinstance(a, ctypes.Array):
            kind = js.Float64Array if a._type_ is c_double else js.Uint32Array
            return kind.new(to_js([v for v in a]))
        if callable(a):
            return lambda phase, done, total: a(phase, int(done), int(total))
        raise BuildError(f"the wasm backend cannot pass {type(a).__name__}")

    def _back(self, short, args, result):
        """The wasm's return, as the C call's: written into the out-argument
        and `True` where C fills one, `bytes` where C returns a C string, the
        mesh/polyline arrays under the C struct's names, else as it is."""
        if short == "edge":
            raw = args[2]._obj   # the `_Edge` behind `ctypes.byref(raw)`; the arrays live in it
            raw.kind = str(result.kind).encode()
            raw.faces = (c_uint32 * len(result.faces))(*[int(v) for v in result.faces])
            raw.face_count = len(result.faces)
            raw.segments = (c_double * len(result.segments))(*[float(v) for v in result.segments])
            raw.segment_count = len(result.segments) // 6
            return True
        if short == "colour":   # the three doubles, or null where there is no colour: C's `false`
            if result is None:
                return False
            args[2][0:3] = [float(v) for v in result]
            return True
        if short == "manifold":   # eight counts, into C's `uint32_t` out-array
            args[1][0:8] = [int(v) for v in result]
            return True
        if short == "bounds":
            values = [float(v) for v in result]
            args[2][0:3], args[3][0:3] = values[0:3], values[3:6]
            return True
        if short in self._OUT:
            out = args[self._OUT[short]]
            out[0:len(out)] = [float(v) for v in result]
            return True
        if short in self._BOOLS:
            return True
        if short in self._TEXTS:
            return str(result).encode()
        if short in ("mesh", "edge_polylines", "profile_polylines"):
            return _JsArrays(result)
        if short == "mesh_face_triangles":   # the counts themselves, a `Uint32Array`
            return _JsArrays(result, "counts")
        return result


class _JsArrays:
    """A `mesh`/`edge_polylines`/`mesh_face_triangles` result: the typed arrays
    under the C struct's names (`bare` names a result that is the one array)."""

    def __init__(self, js_object, bare=None):
        if bare is not None:
            self.counts, self.face_count = js_object, len(js_object)
            return
        for name in ("positions", "normals", "indices", "points", "offsets"):
            if hasattr(js_object, name):
                setattr(self, name, getattr(js_object, name))
        if hasattr(self, "positions"):
            self.vertex_count, self.index_count = len(self.positions) // 3, len(self.indices)
        if hasattr(self, "points"):
            self.point_count, self.polyline_count = len(self.points) // 3, len(self.offsets) - 1


_library = None


def _lib() -> ctypes.CDLL:
    global _library
    if _library is None:
        if _WASM:
            _library = _WasmLibrary()
            return _library
        path = library_path()
        library = ctypes.CDLL(str(path))
        for name, restype, argtypes in _ENTRY_POINTS:
            try:
                function = getattr(library, name)
            except AttributeError:
                raise BuildError(
                    f"{path} has no {name}: the library is older than this copy of "
                    f"cadaclysm_blacksmith.py, which declares {len(_ENTRY_POINTS)} entry points. "
                    "Rebuild it with `cargo build --release -p cadaclysm-blacksmith-capi`."
                ) from None
            function.restype, function.argtypes = restype, argtypes
        _library = library
    return _library


def _text(raw) -> str:
    return raw.decode("utf-8", "replace") if raw else ""


def _fail(what: str):
    """Raise the library's own reason, or `what` if it left none."""
    raise BuildError(_text(_lib().cadaclysm_blacksmith_last_error()) or what)


def _rgb(colour):
    """(r, g, b) from "#rgb", "#rrggbb" or three numbers; the range is the
    library's to check."""
    if isinstance(colour, str):
        h = colour.strip()
        h = h[1:] if h.startswith("#") else h
        if len(h) in (3, 6) and all(c in "0123456789abcdefABCDEF" for c in h):
            h = "".join(c * 2 for c in h) if len(h) == 3 else h
            return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    else:
        try:
            r, g, b = (float(c) for c in colour)
            return r, g, b
        except (TypeError, ValueError):
            pass
    raise BuildError(f'coloured: a colour is "#rgb", "#rrggbb" or (r, g, b) in 0..1, not {colour!r}')


def _checked(handle, what: str):
    if not handle:
        _fail(what)
    return handle


def _doubles(values, count: int, what: str):
    values = [float(v) for v in values]
    if len(values) != count:
        raise BuildError(f"{what}: expected {count} numbers, got {len(values)}")
    return (c_double * count)(*values)


def _frame(frame):
    """Twelve numbers, or ((ox,oy,oz),(xx,xy,xz),(yx,yy,yz),(zx,zy,zz))."""
    flat = list(frame)
    if len(flat) == 4:
        flat = [v for row in flat for v in row]
    return _doubles(flat, 12, "frame")


def _axis(axis):
    """Six numbers, or ((px,py,pz),(dx,dy,dz))."""
    flat = list(axis)
    if len(flat) == 2:
        flat = [v for row in flat for v in row]
    return _doubles(flat, 6, "axis")


def _reader(what: str):
    """The reader module, `cadaclysm.py`, with a message saying where it lives."""
    try:
        import cadaclysm
    except ImportError:
        raise ImportError(
            f"{what} needs the reader module: put crates/cadaclysm-capi/examples on sys.path "
            "and build its library with `cargo build --release -p cadaclysm-capi`"
        ) from None
    return cadaclysm


def _from_brep(node, what: str, missing_ok=False):
    """The node's brep as a solid, shared: the reader's reference handed across
    and given straight back, the solid holding one of its own."""
    brep = node.brep
    if brep is None:
        if missing_ok:
            return None
        raise BuildError(f"{what} has no brep: only a B-rep body has one (STEP, ACIS, Rhino, OCCT .brep, "
                         "IGES, IFC), not a mesh, a curve or a CSG body")
    with brep:
        return Solid(_lib().cadaclysm_blacksmith_from_brep(brep.pointer, brep.layout_id().encode()))


def _is_identity(matrix) -> bool:
    return all(float(matrix[i][j]) == (1.0 if i == j else 0.0) for i in range(4) for j in range(4))


def _close_all(solids) -> None:
    for s in solids:
        s.close()


_numpy_module = None


def _numpy():
    global _numpy_module
    if _numpy_module is None:
        import numpy
        _numpy_module = numpy
    return _numpy_module


class _Borrowed:
    """One block of a solid's cache, exposed through the array interface so the
    numpy view is read-only and holds the solid as its `.base`."""

    __slots__ = ("_solid", "__array_interface__")

    def __init__(self, solid, pointer, shape, typestr):
        self._solid = solid
        self.__array_interface__ = {
            "version": 3,
            "data": (ctypes.cast(pointer, c_void_p).value, True),
            "shape": shape,
            "typestr": typestr,
        }


def _view(solid, pointer, shape, dtype):
    numpy = _numpy()
    if _WASM:
        # `pointer` is the wasm's typed array: copied out, so the view is read-only
        # and has a `.base` as the borrowed one does, but never invalidates.
        if pointer is None or 0 in shape:
            return numpy.zeros(shape, dtype=dtype)
        array = numpy.frombuffer(pointer.to_bytes(), dtype=dtype).reshape(shape)
        array.flags.writeable = False
        return array
    if not pointer or 0 in shape:
        return numpy.zeros(shape, dtype=dtype)
    return numpy.asarray(_Borrowed(solid, pointer, shape, numpy.dtype(dtype).str))


def license(text_or_path) -> None:
    """Load a license: the certificate text, or the path of a file holding it (see cadaclysm.py's)."""
    text = text_or_path if isinstance(text_or_path, str) else os.fspath(text_or_path)
    if not _lib().cadaclysm_blacksmith_license_set(text.encode("utf-8")):
        _fail("license refused")


def license_info() -> str:
    """One line about the license the library is running under (see cadaclysm.py's).

    Never null: the license line, or, without one, ``"unlicensed"``
    (``"unlicensed -- <reason>"`` when a license was found but did not
    verify).
    """
    return _text(_lib().cadaclysm_blacksmith_license_info())


def license_notice_count() -> int:
    """How many unlicensed notices this library has printed to stderr in this
    process (see cadaclysm.py's)."""
    return int(_lib().cadaclysm_blacksmith_license_notice_count())


def build_date() -> str:
    return _text(_lib().cadaclysm_blacksmith_build_date())


def version() -> str:
    """The version of the library actually loaded, which is the one worth reporting."""
    return _text(_lib().cadaclysm_blacksmith_version())


def brep_layout_id() -> str:
    """How the loaded library lays a brep out in memory: its compiler, target and
    source. `Solid.from_node` works only where this equals the reader library's
    (`cadaclysm.Brep.layout_id()`) -- the two from the same release."""
    return _text(_lib().cadaclysm_blacksmith_brep_layout_id())


# ---- drawing ----------------------------------------------------------------


def _viewer():
    """The viewer loader, imported only when something is drawn: `cadaclysm.viewer` (the
    wheel), `cadaclysm_viewer` on the path, then beside this module, then the reader's
    examples beside the kernel's in a checkout. A directory joins `sys.path` only when it
    holds `cadaclysm_viewer.py`."""
    try:
        from cadaclysm import viewer
        return viewer
    except ImportError:
        pass
    try:
        import cadaclysm_viewer
        return cadaclysm_viewer
    except ModuleNotFoundError as e:
        if e.name != "cadaclysm_viewer":
            raise
    here = _FsPath(__file__).resolve().parent
    folders = [here]
    if len(here.parents) > 1:
        folders.append(here.parents[1] / "cadaclysm-capi" / "examples")
    for folder in folders:
        if (folder / "cadaclysm_viewer.py").is_file():
            if str(folder) not in sys.path:
                sys.path.append(str(folder))
            import cadaclysm_viewer
            return cadaclysm_viewer
    raise ModuleNotFoundError("no viewer loader: cadaclysm_viewer.py is neither installed nor beside "
                              "cadaclysm_blacksmith.py -- reinstall cadaclysm", name="cadaclysm_viewer")


def _edges_as_polylines(runs):
    """A list of (k,3) runs as the loader's (points, counts) pair."""
    import numpy as np

    if not runs:
        return []
    return [(np.concatenate(runs), np.array([len(r) for r in runs], "u4"), None, None)]


def _lines_only(options):
    """A profile's keywords without `edges`: its lines are its picture, and the viewer
    draws no lines under NO_EDGES."""
    return {k: v for k, v in options.items() if k != "edges"}


def _not_in_the_notebook():
    """The notebook draws with its own show(obj): refused before anything is meshed
    or asked of the wasm, which may predate an entry point the drawing uses."""
    if sys.platform == "emscripten":
        raise RuntimeError("in the notebook, draw with show(obj)")


def _draw(obj, mode, meshes, polylines, default_view, kw):
    _not_in_the_notebook()
    viewer = _viewer()
    opts = viewer.options(default_view, **kw)
    last = viewer.draw(mode, type(obj).__name__, meshes, polylines, opts)
    if mode == "view":
        viewer.announce(type(obj).__name__.lower(), last)
    return last


# ---- profiles -------------------------------------------------------------


class Profile:
    """A closed outline with holes, in its own x/y. Immutable; every method
    returns a new one."""

    __slots__ = ("_handle",)

    def __init__(self, handle):
        self._handle = _checked(handle, "profile")

    def __del__(self):
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_profile_free(h)

    @staticmethod
    def rect(w, h) -> "Profile":
        return Profile(_lib().cadaclysm_blacksmith_profile_rect(w, h))

    @staticmethod
    def circle(r) -> "Profile":
        return Profile(_lib().cadaclysm_blacksmith_profile_circle(r))

    @staticmethod
    def slot(centre, length, r) -> "Profile":
        cx, cy = centre
        return Profile(_lib().cadaclysm_blacksmith_profile_slot(cx, cy, length, r))

    @staticmethod
    def polygon(points) -> "Profile":
        flat = [float(v) for p in points for v in p]
        n = len(flat) // 2
        return Profile(_lib().cadaclysm_blacksmith_profile_polygon((c_double * len(flat))(*flat), n))

    @staticmethod
    def regular_polygon(centre, radius, sides, angle=0.0) -> "Profile":
        """A regular polygon of `sides` sides (at least 3) on the circle of
        `radius` about `centre`, its first corner at `angle` radians from the
        sketch's x axis, the rest counter-clockwise."""
        cx, cy = centre
        return Profile(_lib().cadaclysm_blacksmith_profile_regular_polygon(cx, cy, radius, max(0, int(sides)), angle))

    @staticmethod
    def spline(points, degree=3, weights=None, closed=False) -> "Profile":
        """A spline of `degree` through the control polygon `points` (`weights`
        one per point, or None). Open, it starts on the first point and ends on
        the last -- an open chain; `closed=True`, it is periodic, smooth through
        its own start -- a closed profile. The degree is lowered to fit the
        points. Raises `BuildError` for a degree of zero, too few points (two
        open, three closed), a weight not positive, or not one weight per point."""
        flat = [float(v) for p in points for v in p]
        n = len(flat) // 2
        # The library reads exactly one weight per point, whatever the list holds
        # (the wasm refuses a wrong count in its own words: this one is the same on both).
        weights = None if weights is None else [float(x) for x in weights]
        if weights is not None and len(weights) != n:
            raise BuildError(f"spline: {len(weights)} weights for {n} points; give one per point")
        w = None if weights is None else (c_double * n)(*weights)
        return Profile(_lib().cadaclysm_blacksmith_profile_spline((c_double * len(flat))(*flat), n, max(0, int(degree)), w, bool(closed)))

    @staticmethod
    def path(start) -> "Path":
        return Path(start)

    @staticmethod
    def chain(pieces, tolerance=1e-6) -> "Profile":
        """Open profiles joined end to end into one -- the forge's merge. The
        pieces (paths ended open) may come in any order and either way round:
        each next one is the first of the rest with an end within `tolerance`
        of either end of the chain so far, reversed where that makes it meet.
        Every segment is kept exactly; a joint is the chain's own point. Closed
        where the chain's two ends meet, otherwise an open chain. Raises
        `BuildError` for no pieces, a piece empty, with holes or closed on its
        own, or one that meets none of the others, named by its index."""
        pieces = list(pieces)
        handles = (c_void_p * len(pieces))(*[p._handle for p in pieces])
        return Profile(_lib().cadaclysm_blacksmith_profile_chain(handles, len(pieces), tolerance))

    @staticmethod
    def from_loops(loops) -> "Profile":
        """Closed loops, in any order, as one profile: the loop enclosing the most
        area is the boundary and every other a hole in it, in the order given --
        a sketch's rectangle and the circles drawn inside it. Each loop is a
        closed profile with no holes of its own (a loop closing within rounding
        is closed exactly), wound either way. Raises `BuildError`, naming loops
        by their index, for a loop that is open, empty or of no area, loops that
        cross or touch, a hole outside the boundary, or one inside another hole."""
        loops = list(loops)
        handles = (c_void_p * len(loops))(*[p._handle for p in loops])
        return Profile(_lib().cadaclysm_blacksmith_profile_from_loops(handles, len(loops)))

    def close_loop(self) -> "Profile":
        """This profile closed -- the forge's sketch "close": where its last segment
        stops short of its start (a path ended open), a straight segment back to it;
        where it already comes back to within 1e-9 of its extent, its last segment
        made to land on the start exactly. A closed profile comes back as it is.
        Holes are closed the same way."""
        return Profile(_lib().cadaclysm_blacksmith_profile_close_loop(self._handle))

    def with_hole(self, hole: "Profile") -> "Profile":
        return Profile(_lib().cadaclysm_blacksmith_profile_with_hole(self._handle, hole._handle))

    def translate(self, dx, dy) -> "Profile":
        return Profile(_lib().cadaclysm_blacksmith_translate_profile(self._handle, dx, dy))

    def round(self, radius, corners=None, open=False) -> "Profile":  # noqa: A002, A003
        """This profile with its corners rounded by `radius`: where two straight
        segments meet, both are cut back and an exact arc tangent to both put
        between them. A corner next to an arc or a spline is left as it is.

        `corners=None` rounds every such corner, the holes' too; a list picks
        corners of the boundary alone -- corner `k` is where segment `k` ends,
        and a picked corner that is not between two lines raises. `open=True`
        reads the profile as an open chain (from `Path.end_open`): its two ends
        stay square. Closed, the corner where the last segment meets the first
        is rounded too (so `Profile.rect` has four corners). Raises `BuildError`
        naming the corner or segment the radius does not fit."""
        if corners is None:
            picked, count = None, 0
        else:
            ks = [int(k) for k in corners]
            picked, count = (c_uint32 * len(ks))(*ks), len(ks)
        return Profile(_lib().cadaclysm_blacksmith_profile_round(self._handle, radius, picked, count, bool(open)))

    def polylines(self, tolerance=0.05) -> "list[numpy.ndarray]":
        """The outline, then each hole, as float32 (k,3) read-only views at z = 0,
        within `tolerance` of the profile's arcs and splines -- what a viewer draws it
        with. A closed loop repeats its first point at the end; an open chain (a profile
        ended open) stays open, the segments it has. Valid until the profile is freed or
        asked again at another tolerance."""
        p = _lib().cadaclysm_blacksmith_profile_polylines(self._handle, tolerance)
        if not p.offsets:
            _fail("profile_polylines")
        points = _view(self, p.points, (p.point_count, 3), "f4")
        offsets = [p.offsets[i] for i in range(p.polyline_count + 1)]
        return [points[a:b] for a, b in zip(offsets, offsets[1:])]

    def show(self, tolerance=0.05, **options) -> None:
        """Draw the outline and holes with the viewer in use, from the top by default.
        Keywords as `Solid.show`; `edges=` is accepted and ignored, the lines being the
        whole picture."""
        _not_in_the_notebook()
        _draw(self, "show", [], _edges_as_polylines(self.polylines(tolerance)), "top", _lines_only(options))

    def view(self, tolerance=0.05, **options):
        """Orbit the outline with the viewer in use; returns (azimuth, elevation, zoom)."""
        _not_in_the_notebook()
        return _draw(self, "view", [], _edges_as_polylines(self.polylines(tolerance)), "top", _lines_only(options))


class Path:
    """An outline drawn a segment at a time; `end()` closes it into a `Profile`
    and consumes the builder."""

    __slots__ = ("_handle",)

    def __init__(self, start):
        x, y = start
        self._handle = _checked(_lib().cadaclysm_blacksmith_path_begin(x, y), "path_begin")

    def __del__(self):
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_path_free(h)

    def _live(self):
        if not self._handle:
            raise BuildError("path: already ended")
        return self._handle

    def _step(self, ok: bool, what: str) -> "Path":
        if not ok:
            _fail(what)
        return self

    def line_to(self, x, y) -> "Path":
        return self._step(_lib().cadaclysm_blacksmith_path_line_to(self._live(), x, y), "path_line_to")

    def arc_to(self, x, y, centre, ccw=True) -> "Path":
        cx, cy = centre
        return self._step(_lib().cadaclysm_blacksmith_path_arc_to(self._live(), x, y, cx, cy, ccw), "path_arc_to")

    def bezier_to(self, c1, c2, to) -> "Path":
        return self._step(_lib().cadaclysm_blacksmith_path_bezier_to(self._live(), *c1, *c2, *to), "path_bezier_to")

    def nurbs_to(self, control, knots, degree, weights=None) -> "Path":
        """`control`: every control point after the current one, the endpoint
        last; `weights`: one per control point *including* the current one, or
        None; `knots`: the full repeated knot vector."""
        flat = [float(v) for p in control for v in p]
        n = len(flat) // 2
        # The library reads one weight per control point plus the current point's.
        weights = None if weights is None else [float(v) for v in weights]
        if weights is not None and len(weights) != n + 1:
            raise BuildError(f"nurbs_to: {len(weights)} weights for {n + 1} control points "
                             f"(the current point and {n} given); give one per point")
        w = (c_double * len(weights))(*weights) if weights is not None else None
        k = (c_double * len(knots))(*[float(v) for v in knots])
        ok = _lib().cadaclysm_blacksmith_path_nurbs_to(self._live(), (c_double * len(flat))(*flat), n, w, k, len(knots), degree)
        return self._step(ok, "path_nurbs_to")

    def end_open(self) -> Profile:
        """The path as it stands, without closing it: an open chain for
        `extrude_open`, `sweep_open` or `loft_open` (a closed sweep closes it
        with a straight side). Consumes the builder as `end` does."""
        h, self._handle = self._live(), None
        return Profile(_lib().cadaclysm_blacksmith_path_end_open(h))

    def end(self) -> Profile:
        h, self._handle = self._live(), None   # consumed whether or not end succeeds
        return Profile(_lib().cadaclysm_blacksmith_path_end(h))


class SweepPath:
    """A 3D path a profile is carried along -- lines and arcs, a point at a
    time -- for `Solid.sweep`/`Solid.sweep_open`. Named apart from `Path` (the
    2D outline builder) because it plays a different role: a sweep path has no
    closing rule of its own, so `sweep`/`sweep_open` only *borrow* it rather
    than consuming it -- the same path can be swept more than once, open or
    closed. Free it with `close()` (or let `__del__` do it) once done."""

    __slots__ = ("_handle",)

    def __init__(self, at):
        x, y, z = at
        self._handle = _checked(_lib().cadaclysm_blacksmith_sweep_path_begin(x, y, z), "sweep_path_begin")

    def __del__(self):
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_sweep_path_free(h)

    @staticmethod
    def at(point) -> "SweepPath":
        return SweepPath(point)

    @staticmethod
    def along(curve: Profile, frame, tolerance=0.05, open=True) -> "SweepPath":  # noqa: A002
        """The path the 2D chain `curve` (usually `Path.end_open()`) draws on
        `frame`: a line a straight piece, an arc a circular one, and a Bezier or
        spline fitted with biarcs -- pairs of arcs tangent to each other and to
        the curve -- until each stays within `tolerance` of it, so the path is
        tangent throughout and every wall swept along it exact. `open=False`
        closes the path back to its start along the side a profile leaves
        implicit. For `Solid.sweep`, whose frame must start where the path does
        and face along it."""
        self = SweepPath.__new__(SweepPath)
        h = _lib().cadaclysm_blacksmith_sweep_path_along(curve._handle, _frame(frame), tolerance, bool(open))
        self._handle = _checked(h, "sweep_path_along")
        return self

    def _live(self):
        if not self._handle:
            raise BuildError("sweep_path: closed")
        return self._handle

    def _step(self, ok: bool, what: str) -> "SweepPath":
        if not ok:
            _fail(what)
        return self

    def line_to(self, point) -> "SweepPath":
        x, y, z = point
        return self._step(_lib().cadaclysm_blacksmith_sweep_path_line_to(self._live(), x, y, z), "sweep_path_line_to")

    def arc(self, centre, axis, angle) -> "SweepPath":
        """Turn `angle` radians about the axis through `centre` with direction
        `axis` (need not be unit); `angle` must be in `(0, 2*pi]`."""
        cx, cy, cz = centre
        ax, ay, az = axis
        ok = _lib().cadaclysm_blacksmith_sweep_path_arc(self._live(), cx, cy, cz, ax, ay, az, angle)
        return self._step(ok, "sweep_path_arc")

    def close(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_sweep_path_free(h)


class Slant:
    """A plane a sweep starts or ends on, read as a height over the sketch
    plane at each point: `at + grad · p`. Flat (`grad` zero) for `extrude`'s
    own caps; sloped for a mitre -- the mitred end of a sweep's straight
    piece, where it meets the plane bisecting its corner with the next."""

    __slots__ = ("at", "grad")

    def __init__(self, at, grad=(0.0, 0.0)):
        self.at = float(at)
        self.grad = (float(grad[0]), float(grad[1]))

    @staticmethod
    def flat(at) -> "Slant":
        return Slant(at)

    @staticmethod
    def of_plane(frame, point, normal) -> "Slant":
        """The plane through `point` square to `normal`, read as heights over
        `frame`. Raises `BuildError` when the plane holds the sweep direction
        itself (`normal` square to `frame`'s z), so no height is on it."""
        out = (c_double * 3)()
        px, py, pz = point
        nx, ny, nz = normal
        ok = _lib().cadaclysm_blacksmith_slant_of_plane(
            _frame(frame), (c_double * 3)(px, py, pz), (c_double * 3)(nx, ny, nz), out
        )
        if not ok:
            _fail("slant_of_plane")
        return Slant(out[0], (out[1], out[2]))

    def _raw(self):
        return (c_double * 3)(self.at, self.grad[0], self.grad[1])

    def __repr__(self):
        return f"Slant({self.at!r}, {self.grad!r})"


def _slant(value) -> Slant:
    """A `Slant`, or a bare number treated as `Slant.flat(value)`."""
    return value if isinstance(value, Slant) else Slant.flat(value)


# ---- solids ---------------------------------------------------------------


def _progress(callback):
    """The C trampoline for a Python `callback(phase, done, total)`, or None."""
    if _WASM:
        return callback, None   # the wasm takes the Python callable itself
    if callback is None:
        return _PROGRESS(), None
    def trampoline(phase, done, total, _user):
        callback(_text(phase), done, total)
    cb = _PROGRESS(trampoline)
    return cb, cb   # the second keeps the CFUNCTYPE object alive for the call


class Solid:
    """An exact B-rep solid (or open sheet). Immutable; every operation returns
    a new one. `close()` frees it; so does leaving a `with` block or the garbage
    collector."""

    __slots__ = ("_handle", "__weakref__")

    def __init__(self, handle):
        self._handle = _checked(handle, "solid")

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def __del__(self):
        self.close()

    def close(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_solid_free(h)

    def _h(self):
        if not self._handle:
            raise BuildError("solid: closed")
        return self._handle

    # -- building
    @staticmethod
    def cuboid(x, y, z) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_cuboid(x, y, z))

    @staticmethod
    def cylinder(r, h) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_cylinder(r, h))

    @staticmethod
    def cone(r, h) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_cone(r, h))

    @staticmethod
    def sphere(r) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_sphere(r))

    @staticmethod
    def torus(major, minor) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_torus(major, minor))

    @staticmethod
    def wedge(x, y, z, top_x) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_wedge(x, y, z, top_x))

    @staticmethod
    def extrude(profile: Profile, frame, height) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_extrude(profile._handle, _frame(frame), height))

    @staticmethod
    def extrude_open(profile: Profile, frame, height) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_extrude_open(profile._handle, _frame(frame), height))

    @staticmethod
    def extrude_tapered(profile: Profile, frame, height, taper) -> "Solid":
        """`extrude` with a draft: the walls lean out by `taper` radians as they
        rise (in, when negative), every wall exact -- a plane off a line, a
        cone off an arc. A taper of zero is `extrude`."""
        return Solid(_lib().cadaclysm_blacksmith_extrude_tapered(profile._handle, _frame(frame), height, taper))

    @staticmethod
    def extrude_open_tapered(profile: Profile, frame, height, taper) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_extrude_open_tapered(profile._handle, _frame(frame), height, taper))

    @staticmethod
    def extrude_between(profile: Profile, frame, bottom, top) -> "Solid":
        """`extrude` between two planes instead of two heights: `bottom` and
        `top` are each a `Slant` (or a bare number, treated as
        `Slant.flat(number)`). The profile's walls run from where `bottom`
        cuts them to where `top` does, the caps lying on those planes. With
        both flat this *is* `extrude` (bit for bit); with a slope it is the
        mitred end of a sweep's straight piece. Raises `BuildError` where the
        top plane comes down to or through the bottom across the profile."""
        return Solid(_lib().cadaclysm_blacksmith_extrude_between(
            profile._handle, _frame(frame), _slant(bottom)._raw(), _slant(top)._raw()
        ))

    @staticmethod
    def extrude_open_between(profile: Profile, frame, bottom, top) -> "Solid":
        """`extrude_between` without the caps: an open sheet of walls running
        from `bottom` to `top`, as `extrude_open` is to `extrude`."""
        return Solid(_lib().cadaclysm_blacksmith_extrude_open_between(
            profile._handle, _frame(frame), _slant(bottom)._raw(), _slant(top)._raw()
        ))

    @staticmethod
    def loft(a: Profile, frame_a, b: Profile, frame_b) -> "Solid":
        """The solid between `a` on `frame_a` and `b` on `frame_b`: ruled walls
        between matching sides (the profiles must have the same number of
        sides, and no holes), capped by the two profiles."""
        return Solid(_lib().cadaclysm_blacksmith_loft(a._handle, _frame(frame_a), b._handle, _frame(frame_b)))

    @staticmethod
    def loft_open(a: Profile, frame_a, b: Profile, frame_b) -> "Solid":
        """`loft` without the caps: the sheet ruled between the two curves."""
        return Solid(_lib().cadaclysm_blacksmith_loft_open(a._handle, _frame(frame_a), b._handle, _frame(frame_b)))

    @staticmethod
    def loft_through(sections) -> "Solid":
        """The solid smooth through every section -- `(profile, frame)` pairs, in order:
        each wall interpolates its side across all the profiles (cubic through four or
        more, quadratic through three, `loft` through two), capped by the first and the
        last. The profiles must have the same number of sides and no holes."""
        return Solid._lofted_through(sections, _lib().cadaclysm_blacksmith_loft_through)

    @staticmethod
    def loft_through_open(sections) -> "Solid":
        """`loft_through` without the caps: the sheet through the curves."""
        return Solid._lofted_through(sections, _lib().cadaclysm_blacksmith_loft_through_open)

    @staticmethod
    def _lofted_through(sections, call) -> "Solid":
        sections = list(sections)
        handles = (c_void_p * max(len(sections), 1))(*[p._handle for p, _ in sections])
        numbers = [v for _, f in sections for v in _frame(f)]
        frames = (c_double * max(len(numbers), 1))(*numbers)
        return Solid(call(handles, frames, len(sections)))

    @staticmethod
    def revolve(profile: Profile, axis, angle) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_revolve(profile._handle, _axis(axis), angle))

    @staticmethod
    def revolve_open(profile: Profile, axis, angle) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_revolve_open(profile._handle, _axis(axis), angle))

    @staticmethod
    def revolve_in_plane(profile: Profile, frame, a, b, angle) -> "Solid":
        """`profile`, drawn on `frame`, swung `angle` radians about the axis
        through the sketch points `a` and `b` (each `(x, y)` on the frame) --
        the profile and its axis drawn together, as a sketch draws them, where
        `revolve` reads the profile as (radius, height). The profile may lie on
        either side of the axis and touch it, not cross it; the sweep starts
        where the profile is drawn and turns right-handed about `b - a`."""
        axis = (c_double * 4)(float(a[0]), float(a[1]), float(b[0]), float(b[1]))
        return Solid(_lib().cadaclysm_blacksmith_revolve_in_plane(profile._handle, _frame(frame), axis, angle))

    @staticmethod
    def revolve_open_in_plane(profile: Profile, frame, a, b, angle) -> "Solid":
        """`revolve_in_plane` for a curve: its segments swung into a sheet."""
        axis = (c_double * 4)(float(a[0]), float(a[1]), float(b[0]), float(b[1]))
        return Solid(_lib().cadaclysm_blacksmith_revolve_open_in_plane(profile._handle, _frame(frame), axis, angle))

    @staticmethod
    def sweep(profile: Profile, frame, path: SweepPath) -> "Solid":
        """`profile`, drawn on `frame`, carried along `path` into a closed
        solid: a straight piece of the path is an extrusion, a circular piece
        a revolution about the arc's axis, so nothing is approximated -- a
        circle along an arc is an exact torus wall. `path` is only borrowed,
        not consumed; sweep it again, open or closed, as often as needed."""
        return Solid(_lib().cadaclysm_blacksmith_sweep(profile._handle, _frame(frame), path._live()))

    @staticmethod
    def coil(profile: Profile, axis, pitch, turns) -> "Solid":
        """`profile` coiled about `axis` (a point and a direction): read as
        `revolve` reads it -- x the distance from the axis, y along it -- and
        turned `turns` times while climbing `pitch` along the axis each turn:
        a spring, a thread. The walls follow the helix to a few millionths of
        the radius; the two ends are the profile itself, flat. From a full turn
        up the pitch must be taller than the profile."""
        return Solid(_lib().cadaclysm_blacksmith_coil(profile._handle, _axis(axis), pitch, turns))

    @staticmethod
    def pipe(path: SweepPath, radius, thickness=0.0) -> "Solid":
        """A circle of `radius` swept along `path`, square to its start --
        Fusion's Pipe: a rod, or with a positive `thickness` a tube whose walls
        are that thick. `path` is only borrowed, as by `sweep`."""
        return Solid(_lib().cadaclysm_blacksmith_pipe(path._live(), radius, thickness))

    @staticmethod
    def sweep_open(profile: Profile, frame, path: SweepPath) -> "Solid":
        """`sweep` for a curve rather than a face: one wall per segment per
        piece, no caps -- an open sheet, the way `extrude_open` is to
        `extrude`."""
        return Solid(_lib().cadaclysm_blacksmith_sweep_open(profile._handle, _frame(frame), path._live()))

    # -- from files
    @staticmethod
    def from_node(scene, node, placed=True) -> "Solid":
        """The body `node` of a `cadaclysm.Scene` draws, as a solid -- **sharing the
        reader's brep, not copying it**. `node`: a `cadaclysm.Node` or its index.
        The scene can be closed before the solid is: the brep lives on.

        `placed` puts it where the node's `transform` does, which is where its
        mesh draws; a node at the identity (a part file's one body) stays shared,
        a moved one is a moved copy. `placed=False` keeps the node's own frame.
        In the file's own units and axes either way. A block member is drawn once
        per placement of its block: iterate `scene.placements` for those, or use
        `Solid.open_all`.

        Needs `cadaclysm.py` and its library, from the same release as this
        one's -- the brep is handed across by pointer, and the two libraries'
        layouts are compared first. What a solid from a file can then do: see
        `Solid.open`.
        """
        cadaclysm = _reader("from_node")
        if not isinstance(node, cadaclysm.Node):
            node = cadaclysm.Node(scene, int(node))
        solid = _from_brep(node, f"from_node: node {node.index} ({node.name or node.kind or '?'})")
        if not placed:
            return solid
        if scene.convention != cadaclysm.Convention.NATIVE and not _is_identity(node.transform):
            raise BuildError(
                "from_node: placed=True needs the scene opened with Convention.NATIVE -- the brep is in "
                "the file's own axes and the node's transform is not; open NATIVE, or pass placed=False"
            )
        return solid._placed(node.transform, "from_node")

    @staticmethod
    def open(path, body=None) -> "Solid":  # noqa: A003 - `Solid.open`, the verb
        """The body a CAD file holds, as a solid: a STEP (AP203/214/242), ACIS
        `.sat`, Rhino `.3dm`, OCCT `.brep`, IGES or IFC file, read where it
        draws, in the file's own units and axes. A file drawing several bodies
        needs `body=` (0-based, in drawing order) or `Solid.open_all`.

        What such a solid can do is what its geometry allows: fillet and chamfer
        want line and circle edges; booleans take any surface, but the new edges
        they trace on a free-form (NURBS) face are not always writable back to
        STEP; and every verb meshes its operands first, so its cost grows with
        the body's face count -- a 3,000-face import is seconds, not
        milliseconds.

        On the desktop this reads through `cadaclysm.py` and hands each body
        across with `from_node`; in the notebook the wasm reads the file itself.
        """
        solids = Solid.open_all(path)
        name = _FsPath(path).name
        if body is None and len(solids) == 1:
            return solids[0]
        if body is None:
            _close_all(solids)
            raise BuildError(f"open: {name} holds {len(solids)} bodies: pass body= (0 to {len(solids) - 1}), "
                             "or use Solid.open_all")
        if not 0 <= int(body) < len(solids):
            _close_all(solids)
            raise BuildError(f"open: {name} has no body {body}: it holds {len(solids)}")
        keep = solids.pop(int(body))
        _close_all(solids)
        return keep

    @staticmethod
    def open_all(path) -> "list[Solid]":
        """Every body a CAD file draws, as solids placed where it draws them: one
        per placement, so a part placed twice is two solids. See `Solid.open`."""
        path = _FsPath(path)
        extension = path.suffix.lower().lstrip(".")
        if _WASM:
            try:
                data = path.read_bytes()
            except OSError as e:
                raise BuildError(f"open: {e}") from None
            return [Solid(h) for h in _lib().open_file(data, extension)]
        cadaclysm = _reader("open")
        try:
            scene = cadaclysm.open(path)
        except (cadaclysm.CadaclysmError, OSError) as e:
            raise BuildError(f"open: {e}") from None
        solids = []
        try:
            for placement in scene.placements:
                node = placement.geometry
                what = f"open: {node.name or node.kind or node.index}"
                solid = _from_brep(node, what, missing_ok=True)
                if solid is not None:
                    solids.append(solid._placed(placement.transform, what))
        except BuildError:
            _close_all(solids)
            raise
        finally:
            scene.close()
        if not solids:
            raise BuildError(
                f"open: the .{extension} file draws no B-rep body -- only a STEP, ACIS, Rhino, OCCT .brep, "
                "IGES or IFC body can be a solid, not a mesh, a curve or a CSG body"
            )
        return solids

    def _placed(self, matrix, what: str) -> "Solid":
        """`self` moved by a 4x4 row-major placement: itself at the identity, a moved
        copy for a rigid move (a mirror included), refused for a scale or shear, which
        a brep cannot follow exactly (a cylinder's radius is a number, not a point)."""
        if _is_identity(matrix):
            return self
        numpy = _numpy()
        m = numpy.asarray(matrix, dtype=float)
        axes = m[:3, :3]
        if not numpy.allclose(axes.T @ axes, numpy.eye(3), atol=1e-9):
            raise BuildError(f"{what}: the placement scales or shears, which a brep cannot follow")
        frame = (tuple(m[:3, 3]), tuple(m[:3, 0]), tuple(m[:3, 1]), tuple(m[:3, 2]))
        return self.place(frame)

    @staticmethod
    def face(profile: Profile, frame) -> "Solid":
        """The flat sheet `profile` bounds on `frame`: one planar face, each hole
        a hole through it, its normal `frame`'s z (however the profile winds),
        every edge the exact line, arc or spline its segment is. An open sheet
        -- raise it with `extrude_faces`, cut it with `trim` or `split_sheet`."""
        return Solid(_lib().cadaclysm_blacksmith_face(profile._handle, _frame(frame)))

    def face_sheet(self, face: int) -> "Solid":
        """Face `face` alone, as an open sheet: its surface, its loops and the
        exact curves on its edges, the rest of the solid left behind -- what
        extruding a solid's face starts from (`part.face_sheet(top).extrude_faces(5)`
        is the prism over the top face)."""
        return Solid(_lib().cadaclysm_blacksmith_face_sheet(self._h(), face))

    def drop_faces(self, faces) -> "Solid":
        """This solid without the faces at `faces` (repeats allowed): the rest
        keep their surfaces, loops and curves, in their order, so an index into
        the result is this one's with the dropped ones closed up. An open sheet
        unless nothing was dropped."""
        ks = [int(k) for k in faces]
        return Solid(_lib().cadaclysm_blacksmith_drop_faces(self._h(), (c_uint32 * len(ks))(*ks), len(ks)))

    def extrude_faces(self, height) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_extrude_faces(self._h(), height))

    def place(self, frame) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_place(self._h(), _frame(frame)))

    def translate(self, dx, dy, dz) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_translate(self._h(), dx, dy, dz))

    def rotate(self, axis, radians) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_rotate(self._h(), _axis(axis), radians))

    def mirror(self, plane) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_mirror(self._h(), _frame(plane)))

    # -- combining
    def _combine(self, f, other: "Solid", tolerance, progress, merge=False) -> "Solid":
        cb, _keep = _progress(progress)
        out = Solid(f(self._h(), other._h(), tolerance, cb, None))
        return out.merge_flush() if merge else out

    def join(self, other: "Solid", tolerance=0.05, progress=None, merge=False) -> "Solid":
        """This solid and `other` as one. `merge=True` merges the flush faces the
        join leaves where the two meet in a plane or on one cylinder (`merge_flush`),
        as Fusion does -- off by default, so face and edge numbers stay as they were."""
        return self._combine(_lib().cadaclysm_blacksmith_join, other, tolerance, progress, merge)

    def cut(self, other: "Solid", tolerance=0.05, progress=None, merge=False) -> "Solid":
        """This solid with `other` removed; `merge` as `join`'s."""
        return self._combine(_lib().cadaclysm_blacksmith_cut, other, tolerance, progress, merge)

    def common(self, other: "Solid", tolerance=0.05, progress=None, merge=False) -> "Solid":
        """What this solid and `other` share; `merge` as `join`'s."""
        return self._combine(_lib().cadaclysm_blacksmith_common, other, tolerance, progress, merge)

    def trim(self, tool: "Solid", keep="outside", tolerance=0.05, progress=None) -> "Solid":
        """`self` (a sheet or a solid) cut along the closed `tool`'s boundary and
        the pieces on one side thrown away: `keep="outside"` keeps what lies
        outside the tool -- a hole punched through the sheet -- and
        `keep="inside"` what lies within it, the sheet cut to the tool's
        outline. `split_sheet` then `drop_faces` of the other side, in one call;
        the kept pieces come out in `self`'s face order."""
        if keep not in ("outside", "inside"):
            raise BuildError(f"trim: keep must be 'outside' or 'inside', not {keep!r}")
        cb, _keep = _progress(progress)
        return Solid(_lib().cadaclysm_blacksmith_trim(self._h(), tool._h(), keep == "inside", tolerance, cb, None))

    def split_sheet(self, tool: "Solid", tolerance=0.05, progress=None) -> "Solid":
        """`self` (a sheet or a solid) cut along `tool`'s boundary, nothing
        removed: every face of `self` comes back in its pieces outside `tool`
        and its pieces inside, each piece a face -- a surface trim starts
        here, cutting the surface along the tool's silhouette so the pieces
        to keep can be chosen afterwards. `tool` must be a closed solid;
        `self` may be an open sheet.

        The pieces come out in `self`'s own face order, each face's outside
        pieces before its inside pieces, so an index into the result names a
        piece for as long as `self` and `tool` stand -- `result.face_kind(i)`
        and the rest of the query surface still work per-face.

        Keep or discard pieces with `drop_faces`; `trim` is the split with one
        side dropped, in one call."""
        return self._combine(_lib().cadaclysm_blacksmith_split_sheet, tool, tolerance, progress)

    # -- asking
    @property
    def faces(self) -> int:
        h = self._h()
        n = _lib().cadaclysm_blacksmith_face_count(h)
        if n == 0 and _text(_lib().cadaclysm_blacksmith_last_error()):
            _fail("face_count")
        return n

    def face_kind(self, face: int) -> str:
        raw = _lib().cadaclysm_blacksmith_face_kind(self._h(), face)
        if not raw:
            _fail("face_kind")
        return _text(raw)

    @property
    def bounds(self) -> "tuple[tuple[float, float, float], tuple[float, float, float]]":
        """`bounds_at(0.05)` -- the bounds of the tessellation at tolerance
        0.05. Use `bounds_at` for a different tolerance."""
        return self.bounds_at(0.05)

    def bounds_at(self, tolerance) -> "tuple[tuple[float, float, float], tuple[float, float, float]]":
        """The solid's axis-aligned bounds, over the positions of its cached
        tessellation at `tolerance` (the same cache `mesh` fills and reuses,
        so a second call at the same tolerance is free): `((min_x, min_y,
        min_z), (max_x, max_y, max_z))`."""
        lo, hi = (c_double * 3)(), (c_double * 3)()
        if not _lib().cadaclysm_blacksmith_bounds(self._h(), tolerance, lo, hi):
            _fail("bounds")
        return tuple(lo), tuple(hi)

    def leaked_edges(self, tolerance=0.05) -> int:
        """How many edges of the mesh at `tolerance` are bound by anything
        other than exactly two triangles -- zero for a closed solid. A seam
        two solids share along a line (four triangles, two pairs) does *not*
        count here; a genuine hole or a fold does."""
        n = _lib().cadaclysm_blacksmith_leaked_edges(self._h(), tolerance)
        if n == NONE:
            _fail("leaked_edges")
        return n

    def unpaired_edges(self, tolerance=0.05) -> int:
        """How many edges of the mesh at `tolerance` have directed triangle
        uses that do not cancel out -- zero for a closed, consistently
        oriented solid. Where `leaked_edges` asks for exactly two triangles
        on an edge, this asks that they run opposite ways: a seam two solids
        share along a line pairs off and is *not* counted here even though
        four triangles meet there, while a fold -- two triangles running the
        same way -- is."""
        n = _lib().cadaclysm_blacksmith_unpaired_edges(self._h(), tolerance)
        if n == NONE:
            _fail("unpaired_edges")
        return n

    def is_watertight(self, tolerance=0.05) -> bool:
        """`leaked_edges(tolerance) == 0`."""
        return self.leaked_edges(tolerance) == 0

    @property
    def manifold(self) -> "Manifold":
        """Whether the faces make a manifold -- every edge bordered by one face
        or two, the faces round every vertex one fan -- and whether it is
        closed, as a `Manifold` record. Read off the solid's topology, not a
        mesh, so it takes no tolerance; whether the faces all face out is
        `unpaired_edges`'s question."""
        out = (c_uint32 * 8)()
        if not _lib().cadaclysm_blacksmith_manifold(self._h(), out):
            _fail("manifold")
        return Manifold(tuple(out))

    # -- out
    def mesh(self, tolerance=0.05) -> "tuple[numpy.ndarray, numpy.ndarray, numpy.ndarray]":
        """`(positions, normals, indices)` as read-only numpy views (float32
        (n,3), float32 (n,3), uint32 (m,)) into the solid's cache at
        `tolerance`. See the module docs for what invalidates them."""
        m = _lib().cadaclysm_blacksmith_mesh(self._h(), tolerance)
        if not m.positions:
            _fail("mesh")
        n = m.vertex_count
        return (_view(self, m.positions, (n, 3), "f4"),
                _view(self, m.normals, (n, 3), "f4"),
                _view(self, m.indices, (m.index_count,), "u4"))

    def face_triangles(self, tolerance=0.05) -> "numpy.ndarray":
        """How many triangles each face meshed to at `tolerance`, a read-only
        uint32 view with one count per face in face order: the triangles of
        `mesh(tolerance)` run face by face, so face `f`'s are the `counts[f]`
        after the first `counts[:f].sum()`. The counts sum to the mesh's
        triangle count; a face that meshed to nothing counts zero. Same cache
        and lifetime as `mesh`."""
        t = _lib().cadaclysm_blacksmith_mesh_face_triangles(self._h(), tolerance)
        if not t.counts:
            _fail("mesh_face_triangles")
        return _view(self, t.counts, (t.face_count,), "u4")

    def edge_polylines(self, tolerance=0.05) -> "list[numpy.ndarray]":
        """The feature edges as a list of float32 (k,3) read-only views."""
        p = _lib().cadaclysm_blacksmith_edge_polylines(self._h(), tolerance)
        if not p.offsets:
            _fail("edge_polylines")
        points = _view(self, p.points, (p.point_count, 3), "f4")
        offsets = [p.offsets[i] for i in range(p.polyline_count + 1)]
        return [points[a:b] for a, b in zip(offsets, offsets[1:])]

    def show(self, tolerance=0.05, **options) -> None:
        """Draw the solid with the viewer in use -- in a terminal, the picture is left
        in the scrollback. Each face is drawn in its own colour (`face_colour`: a
        colour of its own, else the solid's). Keywords: view= (front back left right
        top bottom iso), az=, el=, zoom=, up=, edges=, width=, height=, hint=."""
        _not_in_the_notebook()
        _draw(self, "show", *self._drawn(tolerance, options), "iso", options)

    def view(self, tolerance=0.05, **options):
        """Orbit the solid with the viewer in use until it is closed; returns
        (azimuth, elevation, zoom) where it was left. Keywords as `show`."""
        _not_in_the_notebook()
        return _draw(self, "view", *self._drawn(tolerance, options), "iso", options)

    def _drawn(self, tolerance, options):
        positions, normals, indices = self.mesh(tolerance)
        edges = _edges_as_polylines(self.edge_polylines(tolerance)) if options.get("edges", True) else []
        whole = self.colour
        colours = [self.face_colour(f) for f in range(self.faces)]
        if all(c == whole for c in colours):
            return [(positions, normals, indices, None, whole)], edges
        # Faces coloured apart from the solid: one mesh per colour, each holding
        # its faces' triangles over just the vertices they use.
        numpy = _numpy()
        counts = self.face_triangles(tolerance)
        triangles = indices.reshape(-1, 3)
        if len(counts) != len(colours) or int(counts.sum()) != len(triangles):
            raise BuildError(f"show: {len(counts)} faces meshed {int(counts.sum())} triangles, "
                             f"the mesh has {len(triangles)} over {len(colours)} faces")
        groups = list(dict.fromkeys(colours))   # the distinct colours, in face order
        group_of_face = numpy.array([groups.index(c) for c in colours], dtype=numpy.intp)
        group_of_triangle = numpy.repeat(group_of_face, counts)
        meshes = []
        for g, rgb in enumerate(groups):
            corners = triangles[group_of_triangle == g].reshape(-1)
            if not corners.size:
                continue   # its faces all meshed to nothing: no mesh, rather than an empty one
            used, local = numpy.unique(corners, return_inverse=True)
            meshes.append((positions[used], normals[used], local.reshape(-1).astype(numpy.uint32), None, rgb))
        return meshes, edges

    def step_text(self, schema=None, unit="mm") -> str:
        return write_step_text([self], schema, unit)

    def step(self, path, schema=None, unit="mm") -> None:
        _FsPath(path).write_text(self.step_text(schema, unit), encoding="utf-8")

    # -- selecting and edges
    def select_face(self, selector: "Selector") -> int:
        kind, v, index = selector._raw()
        i = _lib().cadaclysm_blacksmith_select_face(self._h(), kind, v, index)
        if i == NONE:
            _fail("select_face")
        return i

    def face_frame(self, face: int) -> "tuple[float, ...]":
        """Twelve floats: origin, x, y, z of the workplane on `face` -- its centre,
        world X laid onto it and its outward normal, as `Frame.at` lays them."""
        out = (c_double * 12)()
        if not _lib().cadaclysm_blacksmith_face_frame(self._h(), face, out):
            _fail("face_frame")
        return tuple(out)

    # -- colour
    def coloured(self, colour, face=None) -> "Solid":
        """This solid coloured -- `colour` is "#rgb", "#rrggbb" or (r, g, b)
        in 0..1 -- or with `face` (an index, as `select_face` returns) just
        that face, whose colour then wins over the solid's. What is made from
        a coloured solid inherits: a move keeps every colour; a boolean,
        fillet, chamfer or shell gives each face the colour of the face it
        lies on (a cut's bore the tool's), and a new face the solid's."""
        r, g, b = _rgb(colour)
        return Solid(_lib().cadaclysm_blacksmith_coloured(self._h(), self._face_or_none(face, "coloured"), r, g, b))

    @property
    def colour(self) -> "tuple[float, float, float] | None":
        """The solid's colour, (r, g, b) in 0..1, or None."""
        return self._colour(NONE)

    def face_colour(self, face: int) -> "tuple[float, float, float] | None":
        """`face`'s colour as drawn -- its own, else the solid's -- or None."""
        return self._colour(self._face_or_none(face, "colour"))

    def _face_or_none(self, face, what: str) -> int:
        if face is None:
            return NONE
        face = operator.index(face)
        if not 0 <= face < NONE:   # a negative index would wrap to NONE, the whole solid
            raise BuildError(f"{what}: face {face} is not one of the solid's {self.faces}")
        return face

    def _colour(self, face: int) -> "tuple[float, float, float] | None":
        out = (c_double * 3)()
        if _lib().cadaclysm_blacksmith_colour(self._h(), face, out):
            return tuple(out)
        if _text(_lib().cadaclysm_blacksmith_last_error()):
            _fail("colour")
        return None

    @property
    def edges(self) -> "list[Edge]":
        """The edges a fillet indexes, as `Edge` records (copied; safe to keep)."""
        h = self._h()
        n = _lib().cadaclysm_blacksmith_edge_count(h)
        if n == 0 and _text(_lib().cadaclysm_blacksmith_last_error()):
            _fail("edge_count")
        out = []
        raw = _Edge()
        for i in range(n):
            if not _lib().cadaclysm_blacksmith_edge(h, i, ctypes.byref(raw)):
                _fail("edge")
            faces = tuple(raw.faces[j] for j in range(raw.face_count))
            flat = [raw.segments[j] for j in range(6 * raw.segment_count)]
            segments = tuple((tuple(flat[k:k + 3]), tuple(flat[k + 3:k + 6])) for k in range(0, len(flat), 6))
            out.append(Edge(i, _text(raw.kind), faces, segments))
        return out

    def fillet(self, edges, radius, tolerance=1e-6, progress=None) -> "Solid":
        """`edges`: `Edge` objects or their indices."""
        which = [e.index if isinstance(e, Edge) else int(e) for e in edges]
        arr = (c_uint32 * len(which))(*which)
        cb, _keep = _progress(progress)
        return Solid(_lib().cadaclysm_blacksmith_fillet(self._h(), arr, len(which), radius, tolerance, cb, None))

    def chamfer(self, edges, distance, tolerance=1e-6) -> "Solid":
        """`fillet` with a flat bevel: each edge cut back `distance` along both
        its faces. `edges`: `Edge` objects or their indices."""
        which = [e.index if isinstance(e, Edge) else int(e) for e in edges]
        arr = (c_uint32 * len(which))(*which)
        return Solid(_lib().cadaclysm_blacksmith_chamfer(self._h(), arr, len(which), distance, tolerance))

    def push_pull(self, face, distance, tolerance=0.05, progress=None) -> "Solid":
        """Face `face` pushed out by `distance` along its outward normal (pulled in,
        negative) the way Fusion and Rhino extrude a face: the prism over it joined on
        (cut out), and the flush faces merged -- a box's top raised is one taller box
        of six faces, not a box and a prism with every side wall split at the seam.
        A face on a cylinder, a cone, a sphere or a torus moves out along its normal
        instead, the surface a step out -- a boss fatter, a bore or a countersink
        narrower, a dome fuller -- with the flat faces beside it carried along; any
        other curved face is refused. `tolerance` and `progress` as `join`'s.

        `face` may be a list of faces, pushed together as Fusion's press-pull on a
        selection: each by its own rule, one after another, each found again after
        the pushes before it renumbered the faces -- a box's top and a side pushed 5
        is the box 5 taller and 5 wider. A face on the same curved surface as one
        before it, and joined to it, moved with that one and is not pushed twice."""
        cb, _keep = _progress(progress)
        if isinstance(face, int):
            return Solid(_lib().cadaclysm_blacksmith_push_pull(self._h(), face, distance, tolerance, cb, None))
        which = [int(f) for f in face]
        arr = (c_uint32 * len(which))(*which)
        return Solid(_lib().cadaclysm_blacksmith_push_pull_faces(self._h(), arr, len(which), distance, tolerance, cb, None))

    def split(self, tool: "Solid", tolerance=0.05, progress=None) -> list:
        """This solid split by `tool` into bodies -- Fusion's Split Body: a
        closed `tool` gives the parts outside it, then the parts inside; a flat
        sheet (a `face`) splits by the whole plane it lies on. Each connected
        part is a body of its own, so a U cut across both arms is three. The
        new faces are pieces of the tool's; colours carry over."""
        cb, _keep = _progress(progress)
        return Solid(_lib().cadaclysm_blacksmith_split(self._h(), tool._h(), tolerance, cb, None)).lumps()

    def split_by_plane(self, plane, tolerance=0.05, progress=None) -> list:
        """This solid split by the plane through `plane`'s origin, square to its
        z: the bodies in front of it (on z's side) first, then those behind."""
        cb, _keep = _progress(progress)
        return Solid(_lib().cadaclysm_blacksmith_split_by_plane(self._h(), _frame(plane), tolerance, cb, None)).lumps()

    def lumps(self) -> list:
        """This solid's connected bodies, each a solid of its own -- faces
        sharing an edge are one body. One body comes back as itself; a boolean
        that leaves two parts, or a split, gives several, in the order of
        their first faces."""
        h = self._h()
        n = _lib().cadaclysm_blacksmith_lump_count(h)
        if n == 0:
            _fail("lump_count")
        return [Solid(_lib().cadaclysm_blacksmith_lump(h, i)) for i in range(n)]

    def refillet(self, face, radius, tolerance=1e-6) -> "Solid":
        """The round `face` belongs to -- a fillet's bands, balls and rim bands joined
        to that face -- made again at `radius`, as Fusion's press-pull on a fillet
        face: taken back to the sharp edges it replaced, and those rounded again.
        Rounds of straight edges between planes and of circular rims beside a plane."""
        return Solid(_lib().cadaclysm_blacksmith_refillet(self._h(), face, radius, tolerance))

    def unfillet(self, face) -> "Solid":
        """The round `face` belongs to taken off, the faces beside it sharp again --
        Fusion's delete of a fillet face. The same rounds as `refillet`."""
        return Solid(_lib().cadaclysm_blacksmith_unfillet(self._h(), face))

    def rechamfer(self, face, distance, tolerance=1e-6) -> "Solid":
        """The chamfer `face` belongs to -- its bevels, flat or round a rim, and the
        corner triangles joined to that face -- cut again at `distance`, as Fusion's
        press-pull on a chamfer face: taken back to the sharp edges it cut, and those
        bevelled again."""
        return Solid(_lib().cadaclysm_blacksmith_rechamfer(self._h(), face, distance, tolerance))

    def unchamfer(self, face) -> "Solid":
        """The chamfer `face` belongs to taken off, the faces beside it sharp again --
        Fusion's delete of a chamfer face. The same chamfers as `rechamfer`."""
        return Solid(_lib().cadaclysm_blacksmith_unchamfer(self._h(), face))

    def merge_flush(self) -> "Solid":
        """This solid with its flush faces merged: flat faces on one plane, facing one
        way and meeting, made one face, and the vertices left mid-way along a straight
        edge taken out -- the seams a `join` leaves where two parts are flush."""
        return Solid(_lib().cadaclysm_blacksmith_merge_flush(self._h()))

    def shell(self, thickness, open=(), tolerance=1e-6, progress=None) -> "Solid":  # noqa: A002
        """`open`: face indices removed so the hollow is reachable."""
        which = [int(f) for f in open]
        arr = (c_uint32 * len(which))(*which)
        cb, _keep = _progress(progress)
        return Solid(_lib().cadaclysm_blacksmith_shell(self._h(), thickness, arr, len(which), tolerance, cb, None))

    def thicken(self, thickness, tolerance=1e-6, progress=None) -> "Solid":
        """This sheet made a solid `thickness` thick -- Fusion's Thicken: its faces,
        their twins moved `thickness` along the faces' normals (against them for a
        negative thickness), and a wall round every open edge. A closed sheet thickens
        to a hollow."""
        cb, _keep = _progress(progress)
        return Solid(_lib().cadaclysm_blacksmith_thicken(self._h(), thickness, tolerance, cb, None))

    def to_scene(self, schema=None) -> "cadaclysm.Scene":
        """This solid as a reader `Scene`, through STEP text and `cadaclysm.open_memory`
        -- the door to `viewer.py` and the tree walk. Needs `cadaclysm.py`
        importable and its library built. `schema` as `step_text` takes it; the
        reader is given the schema's **path** only when it names an existing file,
        since it carries every built-in schema itself and there is no file here to
        read a `FILE_SCHEMA` line out of."""
        try:
            import cadaclysm
        except ImportError:
            raise ImportError(
                "to_scene needs the reader module: put crates/cadaclysm-capi/examples on sys.path "
                "and build its library with `cargo build --release -p cadaclysm-capi`"
            ) from None
        schema_path = _schema_file(schema)
        return cadaclysm.open_memory(self.step_text(schema).encode(), "stp", schema=schema_path)


class Axis(enum.Enum):
    X = 0
    Y = 1
    Z = 2


class Selector:
    """Which face: furthest along an axis, furthest against it, by outward
    normal, or by index -- `Selector::Max/Min/Normal/Index` in the crate."""

    __slots__ = ("_kind", "_v", "_index")

    def __init__(self, kind, v=None, index=0):
        self._kind, self._v, self._index = kind, v, index

    @staticmethod
    def max(axis: Axis) -> "Selector":  # noqa: A003
        return Selector(0, None, axis.value)

    @staticmethod
    def min(axis: Axis) -> "Selector":  # noqa: A003
        return Selector(1, None, axis.value)

    @staticmethod
    def normal(direction) -> "Selector":
        return Selector(2, tuple(float(v) for v in direction), 0)

    @staticmethod
    def index(i: int) -> "Selector":
        return Selector(3, None, int(i))

    def _raw(self):
        v = (c_double * 3)(*self._v) if self._v is not None else None
        return self._kind, v, self._index


class Edge:
    """One edge of a solid, as plain data: its index (what `fillet` takes), the
    curve kind, the faces meeting on it, and its segments' ends."""

    __slots__ = ("index", "kind", "faces", "segments")

    def __init__(self, index, kind, faces, segments):
        self.index, self.kind, self.faces, self.segments = index, kind, faces, segments

    @property
    def is_line(self) -> bool:
        return self.kind == "line"

    @property
    def direction(self) -> "tuple[float, float, float] | None":
        """Unit direction of a line edge (from its first segment), else None."""
        if not self.is_line or not self.segments:
            return None
        (a, b) = self.segments[0]
        d = [q - p for p, q in zip(a, b)]
        n = sum(x * x for x in d) ** 0.5
        return tuple(x / n for x in d) if n > 0 else None

    def __repr__(self):
        return f"Edge({self.index}, {self.kind!r}, faces={self.faces})"


class Manifold:
    """Whether a solid's faces make a manifold, as plain data (`Solid.manifold`):
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


_XY = (0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1)
_XZ = (0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0)
_YZ = (0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0)

# How far from square a frame's axes may be (the cosine between two of them).
_SQUARE = 1e-6


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _unit(v, what):
    x, y, z = (float(c) for c in v)
    n = (x * x + y * y + z * z) ** 0.5
    if not (1e-12 < n < float("inf")):
        raise BuildError(f"{what} has no direction")
    return (x / n, y / n, z / n)


class Frame:
    """An origin and three unit axes, square to each other and right-handed
    (z = x × y): the plane a profile is drawn on (its x/y) and the direction it
    is built along (its z). Iterates as the twelve numbers every call taking a
    `frame` reads, so pass it wherever one goes. Immutable.

    The constructor normalises the axes and raises `BuildError` when they are
    not square or not right-handed."""

    __slots__ = ("_v",)

    def __init__(self, origin, x, y, z):
        o = tuple(float(c) for c in origin)
        if len(o) != 3 or not all(abs(c) < float("inf") for c in o):
            raise BuildError("Frame: origin must be three finite numbers")
        x, y, z = _unit(x, "Frame: x"), _unit(y, "Frame: y"), _unit(z, "Frame: z")
        if max(abs(_dot(x, y)), abs(_dot(y, z)), abs(_dot(z, x))) > _SQUARE:
            raise BuildError("Frame: the axes are not square to each other")
        if _dot(_cross(x, y), z) < 0:
            raise BuildError("Frame: the axes are left-handed (z must be x × y)")
        self._v = tuple(c + 0.0 for c in o + x + y + z)  # + 0.0: no -0.0 to print or compare

    @staticmethod
    def of(frame) -> "Frame":
        """Twelve numbers or four triples -- what `Solid.face_frame` and
        `Workplane.frame` hand back -- checked as the constructor checks."""
        v = tuple(_frame(frame))
        return Frame(v[0:3], v[3:6], v[6:9], v[9:12])

    @staticmethod
    def xy(origin=(0, 0, 0)) -> "Frame":
        """The world XY plane through `origin`: z up, as `Workplane.xy`."""
        return Frame(origin, _XY[3:6], _XY[6:9], _XY[9:12])

    @staticmethod
    def xz(origin=(0, 0, 0)) -> "Frame":
        """The world XZ plane through `origin`: x along X, y along Z, so z is -Y, as `Workplane.xz`."""
        return Frame(origin, _XZ[3:6], _XZ[6:9], _XZ[9:12])

    @staticmethod
    def yz(origin=(0, 0, 0)) -> "Frame":
        """The world YZ plane through `origin`: x along Y, y along Z, so z is +X, as `Workplane.yz`."""
        return Frame(origin, _YZ[3:6], _YZ[6:9], _YZ[9:12])

    @staticmethod
    def at(origin, normal, x=None) -> "Frame":
        """The plane through `origin` square to `normal` (the frame's z). Its x
        axis is `x` laid onto that plane; with none, world X laid onto it, or
        world Y when the normal is within about 25° of X -- the axes
        `Solid.face_frame` gives a face facing `normal`. So a normal along +Z,
        -Y or +X gives exactly `xy`, `xz` or `yz`."""
        z = _unit(normal, "Frame.at: normal")
        if x is None:
            x = (1.0, 0.0, 0.0) if abs(z[0]) <= 0.9 else (0.0, 1.0, 0.0)
        hint = _unit(x, "Frame.at: x")
        d = _dot(hint, z)
        if abs(d) > 1 - _SQUARE:
            raise BuildError("Frame.at: x lies along the normal")
        x = _unit(tuple(h - d * n for h, n in zip(hint, z)), "Frame.at: x")
        return Frame(origin, x, _cross(z, x), z)

    @staticmethod
    def midplane(a, b) -> "Frame":
        """The plane midway between the planes of frames a and b: halfway between parallel planes, on a's axes; for planes that meet, the plane bisecting them through the line they meet on, its x along that line -- Fusion's midplane. `a` and `b` are frames or twelve numbers."""
        out = (c_double * 12)()
        if not _lib().cadaclysm_blacksmith_frame_midplane(_frame(a), _frame(b), out):
            _fail("frame_midplane")
        return Frame.of(tuple(out))

    @staticmethod
    def through(p, q, r) -> "Frame":
        """The plane through three points: its origin p, its x towards q, its z the normal they turn about counter-clockwise. Raises `BuildError` for three points on one line."""
        out = (c_double * 12)()
        if not _lib().cadaclysm_blacksmith_frame_through((c_double * 3)(*p), (c_double * 3)(*q), (c_double * 3)(*r), out):
            _fail("frame_through")
        return Frame.of(tuple(out))

    @property
    def origin(self) -> "tuple[float, float, float]":
        return self._v[0:3]

    @property
    def x(self) -> "tuple[float, float, float]":
        return self._v[3:6]

    @property
    def y(self) -> "tuple[float, float, float]":
        return self._v[6:9]

    @property
    def z(self) -> "tuple[float, float, float]":
        return self._v[9:12]

    def translate(self, dx, dy, dz) -> "Frame":
        """This frame moved by (`dx`, `dy`, `dz`) in world coordinates."""
        o = self.origin
        return Frame((o[0] + dx, o[1] + dy, o[2] + dz), self.x, self.y, self.z)

    def offset(self, distance) -> "Frame":
        """This frame moved `distance` along its own z."""
        return self.translate(*(distance * c for c in self.z))

    def __iter__(self):
        return iter(self._v)

    def __eq__(self, other):
        return isinstance(other, Frame) and self._v == other._v

    def __hash__(self):
        return hash(self._v)

    def __repr__(self):
        return f"Frame(origin={self.origin}, x={self.x}, y={self.y}, z={self.z})"


class Workplane:
    """The fluent chain, mirroring the Rust `Workplane`: a frame, the solid built
    so far, and the face last picked. A build call *replaces* the solid (as
    `Workplane::set_brep` does); combine solids explicitly with `Solid.join`.
    Every step raises `BuildError` at once rather than latching it."""

    __slots__ = ("frame", "_solid", "_selected")

    def __init__(self, frame, solid=None):
        self.frame = tuple(float(v) for v in _frame(frame))
        self._solid = solid
        self._selected = None

    @staticmethod
    def xy() -> "Workplane":
        return Workplane(_XY)

    @staticmethod
    def xz() -> "Workplane":
        return Workplane(_XZ)

    @staticmethod
    def yz() -> "Workplane":
        return Workplane(_YZ)

    @staticmethod
    def on(frame) -> "Workplane":
        return Workplane(frame)

    @staticmethod
    def from_solid(solid: Solid) -> "Workplane":
        return Workplane(_XY, solid)

    def _set(self, solid: Solid) -> "Workplane":
        self._solid, self._selected = solid, None
        return self

    def cuboid(self, x, y, z) -> "Workplane":
        return self._set(Solid.cuboid(x, y, z).place(self.frame))

    def cylinder(self, r, h) -> "Workplane":
        return self._set(Solid.cylinder(r, h).place(self.frame))

    def extrude(self, profile: Profile, height) -> "Workplane":
        return self._set(Solid.extrude(profile, self.frame, height))

    def face(self, profile: Profile) -> "Workplane":
        """The flat sheet `profile` bounds on this workplane's frame -- `Solid.face`."""
        return self._set(Solid.face(profile, self.frame))

    def revolve(self, profile: Profile, angle) -> "Workplane":
        """About this workplane's own y axis through its origin, as the Rust chain."""
        o, y = self.frame[0:3], self.frame[6:9]
        return self._set(Solid.revolve(profile, (o, y), angle))

    def translate(self, dx, dy, dz) -> "Workplane":
        """Slide the current solid. Unlike `_set` (`cuboid`, `cylinder`, ...),
        this keeps `faces()`'s selection: a rigid translation carries every
        face along at the same index, exactly as Rust's `Workplane::translate`
        (`workplane.rs`) writes the moved solid back without touching
        `selected`. This differs from Rust in one way: Rust's `translate` is a
        silent no-op on an empty workplane (nothing to move), while here it
        raises `BuildError` at once, like every other step in this chain."""
        if self._solid is None:
            raise BuildError("translate: the workplane holds no solid (BuildError::Empty)")
        self._solid = self._solid.translate(dx, dy, dz)
        return self

    def faces(self, selector: Selector) -> "Workplane":
        if self._solid is None:
            raise BuildError("faces: the workplane holds no solid (BuildError::Empty)")
        self._selected = self._solid.select_face(selector)
        return self

    def workplane(self) -> "Workplane":
        """Adopt the frame on the face last picked; a no-op if none is."""
        if self._solid is not None and self._selected is not None:
            self.frame = self._solid.face_frame(self._selected)
        return self

    def solid(self) -> Solid:
        if self._solid is None:
            raise BuildError("solid: nothing was built (BuildError::Empty)")
        return self._solid


def _schema_file(schema):
    """`schema`'s path, if it is a `str`/`Path` with no newline in it that names a
    regular file -- else `None`. A filesystem error while checking (e.g. a long
    single-line string with no separators, over `NAME_MAX` on POSIX) counts as
    "not a file", not a crash."""
    if not isinstance(schema, (str, _FsPath)) or "\n" in str(schema):
        return None
    try:
        path = _FsPath(schema)
        return path if path.is_file() else None
    except (OSError, ValueError):
        return None


def _schema_text(schema):
    """`schema` is None (the built-in AP203), the path of a schema file, a built-in
    schema's name, or a custom schema's EXPRESS text -- see `write_step_text`."""
    if schema is None:
        return None
    schema_file = _schema_file(schema)
    if schema_file is not None:
        return schema_file.read_bytes()
    if isinstance(schema, str):
        return schema.encode()
    raise BuildError(f"schema: {schema!r} is neither a file, a schema name nor schema text")


def write_step_text(solids, schema=None, unit="mm") -> str:
    """`schema` is one of four things: `None` (the kernel's built-in AP203); the
    path of a schema file (a string or `Path` with no newline in it, naming an
    existing file), read and sent as EXPRESS text; the bare name of a built-in
    schema (case-insensitive, e.g. `"AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF"`
    -- an unknown name raises `BuildError`); or a custom schema's own EXPRESS text."""
    if unit not in UNITS:
        raise BuildError(f"unit must be one of {sorted(UNITS)}")
    handles = (c_void_p * len(solids))(*[s._h() for s in solids])
    text = _lib().cadaclysm_blacksmith_step(handles, len(solids), _schema_text(schema), UNITS[unit])
    if not text:
        _fail("step")
    if _WASM:
        return text   # the wasm returns the text itself, nothing to free
    try:
        return ctypes.string_at(text).decode("utf-8")
    finally:
        _lib().cadaclysm_blacksmith_string_free(text)


def write_step(path, solids, schema=None, unit="mm") -> None:
    """One STEP file (AP203 unless `schema` names another), each solid its own body.
    `schema` as `write_step_text`."""
    _FsPath(path).write_text(write_step_text(solids, schema, unit), encoding="utf-8")
