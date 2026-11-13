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

`numpy` is imported only when a mesh, polylines or a FEM mesh's arrays are asked for.

## A solid's arrays and a FEM mesh's are views; a profile's polylines are copies

`Solid.mesh`, `Solid.mesh64`, `Solid.face_triangles` and `Solid.edge_polylines` hand
back **read-only numpy views**, each owned by a held tessellation of the solid at the
tolerance asked -- not by the solid, and not by its own tessellation cache. Nothing
invalidates them: not meshing the solid again at another tolerance -- `mesh`, but
also `bounds_at`, `bounds64`, `face_triangles`, `edge_polylines` and
`edge_polyline_colours` -- and not the solid's `close()`. The held tessellation stays
alive exactly as long as some view of it does, through the array's `.base`. The
solid's own cache still keeps one tolerance, but memory is bounded only by what you
keep: a view pins its whole tessellation -- positions, normals, indices, edges, face
counts, in both precisions -- until it and every array cut from it are freed or
collected, so a view held from every tolerance you have ever meshed at holds every
one of those tessellations too. For data that must outlive the view, `.copy()` it and
drop the view. Under Pyodide (the website's notebook) the arrays are **read-only
numpy copies** instead, and never invalidate: a JS typed array has no address this
side to view. Strings are copied too.

`Profile.polylines` hands back **read-only numpy copies** of the library's profile
tessellation cache; a profile keeps every tolerance it has been asked at (unlike a
solid), so nothing about it is ever replaced, but a view into it would dangle once
the profile itself closes, and there is no held handle of the kind a solid's
tessellation gets to keep it open, so they are copied out instead.

`Solid.fem_mesh` is the one array product that is **not** the solid's: it hands
back a `FemMesh`, a handle of its own whose arrays are **read-only numpy views
into its memory** (a solver mesh is megabytes). Each view keeps the `FemMesh`
alive through `.base`; only its explicit `free()` (or leaving a `with` block)
invalidates them -- not the solid's `close()`, and not meshing again. Call
`.copy()` on any FEM array that must outlive `free()`.

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

`Solid.open("housing.step")` reads a STEP, ACIS, Rhino, OCCT `.brep`, IGES, IFC or OpenSCAD
file's body as a solid to cut, fillet, join with parts built here and write back
out (`Solid.open_all` for every body; a file that holds only meshes has none).
On the desktop it goes through the reader module, `cadaclysm.py`, and
`Solid.from_node(scene, node)` takes one node of a scene you already have open:
the reader's brep is handed to this library by pointer and shared, never copied,
so both modules must load the same release of the library (the call checks). In the
notebook the wasm reads the file itself. What an imported solid can do is what
its geometry allows -- see `Solid.open`.

`join`/`cut`/`common` default their `tolerance` to `0.05`, not the tighter
`1e-6` `fillet`, `chamfer` and `shell` use, for cost: a boolean meshes both
solids at its tolerance, and a curved solid at `1e-6` is hundreds of thousands
of triangles. `0.05` is what the crate's own boolean tests run at; a tighter one
is as correct, only slower.

## Tolerances

Every default above stays what it is: `join(a, b)` still means `0.05`. Passing
`tolerance=None` (or 0) to a verb that takes a distance tolerance -- a boolean,
fillet, shell, split, section, hit test, mesh, curve fit or profile verb -- opts
into the model's own: `effective_tolerance(*solids)`, the larger of the loosest
absolute tolerance the inputs declare and the option `tolerance.relative`
(default `1e-4`) times their size. A solid declares what its file said
(`Solid.tolerances`, a `Tolerances(absolute, angular)` with None for what it
did not say; `Scene.tolerances` in the reader module is the file's), every
verb's result inherits the loosest of its inputs', and `Solid.with_tolerances`
sets it. `tolerance.angular` (default one degree) stands in where nothing
declares an angle.
"""

from __future__ import annotations

import contextlib
import ctypes
import dataclasses
import enum
import json
import math
import numbers
import operator
import os
import platform
import sys
import time
import types
import warnings
from ctypes import (POINTER, c_bool, c_char_p, c_double, c_float, c_int32, c_size_t, c_uint8, c_uint32, c_uint64, c_void_p)
import collections.abc as _abc
from dataclasses import dataclass, field
from pathlib import Path as _FsPath   # `Path` here is the outline builder
from typing import TYPE_CHECKING, NamedTuple

if TYPE_CHECKING:   # names the annotations use; imported when used, never at load
    from typing import Any, Callable, Dict, Iterable, Iterator, List, Literal, Mapping, NoReturn, Optional, Sequence, Tuple, Union

    import cadaclysm
    import numpy

    # The shapes the signatures below take, spelled once. Never evaluated at run time,
    # so `typing`'s 3.8 spellings here; the annotations themselves use 3.10's.

    #: A colour: "#rgb", "#rrggbb", a CSS colour name, or an (r, g, b) triple -- in
    #: 0..1 for `coloured`/`edges_coloured`, 0..255 for `svg`'s `stroke`/`background`.
    Colour = Union[str, Tuple[float, float, float]]
    #: A point or a direction: (x, y) or (x, y, z), any sequence of numbers -- a numpy
    #: array included.
    Point2 = Union[Sequence[float], "numpy.ndarray"]
    Point3 = Union[Sequence[float], "numpy.ndarray"]
    #: An `RTree` entry's box: a `Box`, (min, max) as two triples, six numbers, or a point
    #: (x, y, z), which stands for a zero box.
    BoxLike = Union["Box", Sequence[Sequence[float]], Sequence[float], "numpy.ndarray"]
    #: Where a call reads a `frame`: a `Frame`, twelve numbers (origin, x, y, z), or
    #: four triples (a numpy array of either shape included).
    FrameLike = Union["Frame", Sequence[float], Sequence[Sequence[float]], "numpy.ndarray"]
    #: An axis: six numbers (a point, then a direction), or two triples.
    AxisLike = Union[Sequence[float], Sequence[Sequence[float]], "numpy.ndarray"]
    #: A file to read or write.
    FilePath = Union[str, "os.PathLike[str]"]
    #: `schema=`: None (the built-in AP203), a schema file's path, a built-in schema's
    #: name, or a schema's EXPRESS text.
    Schema = Union[str, _FsPath, None]
    #: `unit=`: what a written file's lengths are in.
    Unit = Literal["m", "mm", "in"]
    #: `view=`: a named camera direction.
    ViewName = Literal["front", "back", "left", "right", "top", "bottom", "iso"]
    #: `progress=`: called as `progress(phase, done, total)`; what it returns is ignored.
    Progress = Optional[Callable[[str, int, int], object]]
    #: A joint or state key: a "/"-joined path, or the names themselves.
    JointKey = Union[str, Sequence[str]]

__all__ = [
    "Assembly", "At", "Axis", "Box", "BuildError", "Chain", "Clash", "Classifier", "Closest", "Collider", "CollisionHit", "Commit", "Continuity", "Cracks", "Curvature", "CurvatureTurns", "Curve", "CurveBodyFoot", "CurveMeshFoot", "CurvePair", "Document", "Dof", "Edge", "FaceSide", "FaceThickness", "FemEdge",
    "FemMesh", "FemVertex", "Finding", "Frame", "FreeEdge", "FreeWire", "HealFix", "HealRefusal", "HealReport", "HealthReport", "HighlightKink", "History", "Hit", "HoleReport", "Interpolator", "Intersection", "Job", "JoinReport", "KnotContinuity", "Length", "Manifold", "Mass", "MeshPoint", "MeshThickness", "NurbsCurve", "Operation",
    "NearestObject", "OrientedBox", "Overlap", "PartDof", "PatchReport", "Path", "Pattern", "PatternReport", "Piece", "PointFoot", "Profile", "Program", "Projector", "Quaternion", "RTree", "Region", "Report", "ReportItem", "Selector", "Sketch", "Slant", "SmallFeature", "Solid", "SolidHits",
    "SolveReport", "Spot", "Stock", "Subd", "SubdMesh",
    "SubdReport", "SweepPath", "SweptClash", "SymmetryReport", "Thickness", "ThicknessGauge", "ThicknessMesh", "Tolerances", "Tool", "Transform", "TriangleMesh", "Workplane",
    "Arc", "Circle", "Cone", "Cuboid", "CurveFoot", "Cylinder", "Ellipse", "Interval", "Line", "Ray", "Rectangle", "Sphere", "SurfaceFoot",
    "Torus", "Triangle",
    "boxes_apart", "clash", "closest_points", "effective_tolerance", "k_neighbors", "mesh_thickness", "swept_clash", "thickness",
    "brep_layout_id", "build_date", "default_schema", "library_path", "license", "license_info", "license_notice_count",
    "option", "pair_freedom_count", "set_option", "version",
    "Hlr", "HlrLine", "Page", "HLR_KINDS", "PAGE_UNITS", "dxf_profiles", "hlr", "hlr_mesh", "projected_outline",
    "mesh_file", "rhino3dm_bytes", "svg", "write_3dm", "write_brep", "write_brep_text", "write_sat", "write_sat_text", "write_step", "write_step_assembly", "write_step_assembly_text", "write_step_text", "__version__",
]

# This file's own version (the workspace's); `version()` is the loaded library's.
__version__ = "0.14.2"

NONE = 0xFFFFFFFF
UNITS = {"m": 0, "mm": 1, "in": 2}
_NURBS_LEVELS = {"procedural": 0, "analytic": 1, "all": 2}   # CADACLYSM_BLACKSMITH_NURBS_*


class BuildError(Exception):
    """What the library refused, in its own words (`cadaclysm_blacksmith_last_error`).
    `ids` is the sketch ids a `Sketch` refusal names -- the constraints a new one
    conflicts with, the entities still using a point -- and empty for any other."""

    ids: list[int]

    def __init__(self, *args: object, ids: Iterable[int] | None = None) -> None:
        super().__init__(*args)
        self.ids = [int(i) for i in ids] if ids else []


# ---- the library ----------------------------------------------------------


#: The libraries that carry the kernel, in the order they are looked for: the single
#: library's flavours that hold it, then the separate library of earlier releases.
#: As `cadaclysm-capi-rt`'s `KERNEL_STEMS`.
_LIBRARY_STEMS = ['cadaclysm', 'cadaclysm_kernel_reader', 'cadaclysm_kernel', 'cadaclysm_blacksmith']


def _library_names() -> list[str]:
    suffix = {"Windows": ".dll", "Darwin": ".dylib"}.get(platform.system(), ".so")
    return [stem + suffix if suffix == ".dll" else "lib" + stem + suffix for stem in _LIBRARY_STEMS]


def library_path() -> _FsPath:
    """Where the shared library is, preferring a release build over a debug one.

    `CADACLYSM_BLACKSMITH_LIBRARY` first (the two separate libraries' variable), then `CADACLYSM_LIBRARY`: a file, or a directory to look in; then next to this file; then
    a `lib/` directory in any ancestor (the SDK layout); then a `target/release` (or
    `target/debug`) in any ancestor (this repository's layout). Each place is asked for
    every name in `_LIBRARY_STEMS`, in order: one library of any flavour that holds
    the kernel, else the separate library of earlier releases.
    """
    if _WASM:
        return _FsPath("cadaclysm_wasm")   # the exports on `globalThis.cadaclysm`; nothing to load
    names = _library_names()
    P = _FsPath
    override = os.environ.get("CADACLYSM_BLACKSMITH_LIBRARY")
    variable = "CADACLYSM_BLACKSMITH_LIBRARY"
    if not override:
        override, variable = os.environ.get("CADACLYSM_LIBRARY"), "CADACLYSM_LIBRARY"
    if override:
        candidate = P(override)
        # A directory or the library itself, since both are things to point at.
        if candidate.is_dir():
            for name in names:
                if (candidate / name).exists():
                    return candidate / name
        elif candidate.exists():
            # `CADACLYSM_LIBRARY` was the reader's alone before the single library: naming
            # the separate reader, it is not for this library, and the search goes on.
            if not (variable == "CADACLYSM_LIBRARY" and candidate.name == _library_names()[0].replace("cadaclysm", "cadaclysm_capi", 1)):
                return candidate
        if variable == "CADACLYSM_LIBRARY" and candidate.exists():
            override = None   # a directory with none of the kernel's names, or the separate reader
    if override:
        raise BuildError(f"{variable}={override} names nothing that exists"
                      + (f" (looked for {', '.join(names)})" if candidate.is_dir() else ""))

    here = P(__file__).resolve().parent
    # Walking up from this file: an SDK checkout keeps the library in `lib/` beside
    # the wrappers; the repository this example ships in keeps it in `target/release`
    # (or `target/debug`, a fallback for a machine that only built that).
    places = [here]
    places += [ancestor / "lib" for ancestor in [here, *here.parents]]
    for ancestor in [here, *here.parents]:
        places += [ancestor / "target" / profile for profile in ("release", "debug")]
    searched = [place / name for place in places for name in names]
    for candidate in searched:
        if candidate.exists():
            return candidate
    raise BuildError(
        f"none of {', '.join(names)} found. Looked in:\n"
        + "".join(f"    {place}\n" for place in places)
        + "Build one with:\n    cargo build --release -p cadaclysm-blacksmith-capi\n"
        "or run fetch.py in an SDK checkout, or point CADACLYSM_LIBRARY at it."
    )


def _flavour_of(library) -> tuple[str, str] | None:
    """`(flavour, features)` for one of the single library's flavours, or None for a
    separate library of an earlier release, which exports neither call."""
    try:
        flavour, features = library.cadaclysm_flavour, library.cadaclysm_features
    except AttributeError:
        return None
    flavour.restype = features.restype = ctypes.c_char_p
    flavour.argtypes = features.argtypes = []
    return flavour().decode(), features().decode()


def _not_in_flavour(name: str, flavour: str, features: str):
    """What a flavour that leaves `name` out binds in its place: a call that says so."""
    def missing(*_args):
        raise BuildError(f"{_short_name(name)}: not in this library's flavour ('{flavour}', "
                      f"features {features or 'none'}); the full flavour has it")
    missing.__name__ = name
    return missing


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


class _Mesh64(ctypes.Structure):
    #: `CadaclysmBlacksmithMesh64`: `_Mesh` in `double`. Pinned by `tests/bindings.rs`.
    _fields_ = [("positions", POINTER(c_double)), ("normals", POINTER(c_double)), ("indices", POINTER(c_uint32)),
                ("vertex_count", c_uint32), ("index_count", c_uint32)]


class _Polylines(ctypes.Structure):
    _fields_ = [("points", POINTER(c_float)), ("offsets", POINTER(c_uint32)),
                ("point_count", c_uint32), ("polyline_count", c_uint32)]


class _MassProperties(ctypes.Structure):
    #: `CadaclysmBlacksmithMassProperties`. The four flags are `int32_t` and come first, so the
    #: doubles that follow are already eight-aligned and C adds no padding between them.
    _fields_ = [("closed", c_int32), ("inverted", c_int32), ("accuracy_met", c_int32), ("from_mesh", c_int32),
                ("area", c_double), ("area_error", c_double),
                ("volume", c_double), ("volume_error", c_double),
                ("centroid", c_double * 3), ("centroid_error", c_double),
                ("inertia", c_double * 9), ("inertia_error", c_double),
                ("principal_moments", c_double * 3), ("principal_axes", c_double * 9)]


class _OrientedBox(ctypes.Structure):
    #: `CadaclysmBlacksmithOrientedBox`: `axes` row-major, row `i` is axis `i`. Pinned by
    #: `tests/bindings.rs`.
    _fields_ = [("centre", c_double * 3), ("axes", c_double * 9), ("half", c_double * 3)]


class _Length(ctypes.Structure):
    #: `CadaclysmBlacksmithLength`: the two flags are `int32_t` 0/1, as `_MassProperties`'.
    _fields_ = [("length", c_double), ("error", c_double), ("accuracy_met", c_int32), ("from_polyline", c_int32)]


class _At(ctypes.Structure):
    #: `CadaclysmBlacksmithAt`: `segment` NONE on an edge, `from_polyline` an `int32_t` 0/1.
    #: Pinned by `tests/bindings.rs`.
    _fields_ = [("point", c_double * 3), ("tangent", c_double * 3), ("parameter", c_double), ("segment", c_uint32),
                ("error", c_double), ("from_polyline", c_int32)]


class _Curvature(ctypes.Structure):
    #: `CadaclysmBlacksmithCurvature`: `has_centre` an `int32_t` 0/1. Pinned by `tests/bindings.rs`.
    _fields_ = [("kappa", c_double), ("tangent", c_double * 3), ("normal", c_double * 3), ("binormal", c_double * 3),
                ("centre", c_double * 3), ("has_centre", c_int32)]


class _KnotContinuity(ctypes.Structure):
    #: `CadaclysmBlacksmithKnotContinuity`. Pinned by `tests/bindings.rs`.
    _fields_ = [("angle", c_double), ("angle_parameter", c_double), ("angle_at", c_double * 3), ("curvature", c_double),
                ("curvature_parameter", c_double), ("curvature_at", c_double * 3)]


class _JoinReport(ctypes.Structure):
    #: `CadaclysmBlacksmithJoinReport`: `closed` an `int32_t` 0/1. Pinned by `tests/bindings.rs`.
    _fields_ = [("sewn", c_uint32), ("naked_before", c_uint32), ("naked_after", c_uint32), ("refused", c_uint32),
                ("turned", c_uint32), ("worst_gap", c_double), ("closed", c_int32)]


class _Continuity(ctypes.Structure):
    #: `CadaclysmBlacksmithContinuity`. Pinned by `tests/bindings.rs`.
    _fields_ = [("gap", c_double), ("gap_at", c_double * 3), ("angle", c_double), ("angle_at", c_double * 3),
                ("curvature", c_double), ("curvature_at", c_double * 3), ("samples", c_uint32)]


class _CurvatureTurns(ctypes.Structure):
    #: `CadaclysmBlacksmithCurvatureTurns`. Pinned by `tests/bindings.rs`.
    _fields_ = [("gaussian_positive", c_uint32), ("gaussian_negative", c_uint32), ("gaussian_turns", c_uint32),
                ("mean_positive", c_uint32), ("mean_negative", c_uint32), ("mean_turns", c_uint32), ("samples", c_uint32)]


class _HighlightKink(ctypes.Structure):
    #: `CadaclysmBlacksmithHighlightKink`. Pinned by `tests/bindings.rs`.
    _fields_ = [("angle", c_double), ("at", c_double * 3), ("light_point", c_double * 3), ("light_direction", c_double * 3),
                ("samples", c_uint32)]


class _PatchBoundary(ctypes.Structure):
    #: `CadaclysmBlacksmithPatchBoundary`: `sheet` NULL for a curve boundary. Pinned by `tests/bindings.rs`.
    _fields_ = [("sheet", c_void_p), ("face", c_uint32), ("side", c_uint32), ("from", c_double), ("to", c_double),
                ("level", c_uint32), ("curve", c_void_p)]


class _PatchReport(ctypes.Structure):
    #: `CadaclysmBlacksmithPatchReport`. Pinned by `tests/bindings.rs`.
    _fields_ = [("faces", c_uint32), ("boundary", _Continuity), ("internal", _Continuity), ("corner_angle", c_double)]


class _Closest(ctypes.Structure):
    #: `CadaclysmBlacksmithClosest`. `kind_a`/`kind_b` are static C strings ("face", "edge",
    #: "vertex") the library never frees; `edge_*` is NONE where the feature has no fillet-table
    #: edge. Pinned by `tests/bindings.rs`.
    _fields_ = [("distance", c_double), ("on_a", c_double * 3), ("on_b", c_double * 3),
                ("kind_a", c_char_p), ("index_a", c_uint32), ("edge_a", c_uint32),
                ("kind_b", c_char_p), ("index_b", c_uint32), ("edge_b", c_uint32), ("refined", c_int32)]


class _PointFoot(ctypes.Structure):
    #: `CadaclysmBlacksmithPointFoot`, 96 bytes. `kind` is a static C string the library never
    #: frees; `index` the kernel id, `edge` the edge-table row or NONE; `uv` NaN off a face.
    _fields_ = [("distance", c_double), ("point", c_double * 3), ("kind", c_char_p), ("index", c_uint32),
                ("edge", c_uint32), ("uv", c_double * 2), ("normal", c_double * 3), ("refined", c_int32)]


class _CurvePair(ctypes.Structure):
    #: `CadaclysmBlacksmithCurvePair`, 72 bytes: side `a` the curve asked, side `b` the other.
    _fields_ = [("distance", c_double), ("t_a", c_double), ("point_a", c_double * 3), ("t_b", c_double),
                ("point_b", c_double * 3)]


class _CurveBodyFoot(ctypes.Structure):
    #: `CadaclysmBlacksmithCurveBodyFoot`, 144 bytes: the curve's side, then the body's as a
    #: `_PointFoot`; `crossing` 1 where the curve meets the boundary.
    _fields_ = [("distance", c_double), ("t", c_double), ("point_on_curve", c_double * 3), ("body", _PointFoot),
                ("crossing", c_int32)]


class _MeshPoint(ctypes.Structure):
    #: `CadaclysmBlacksmithMeshPoint`, 72 bytes: `kind` 0 face, 1 edge, 2 vertex; an unused
    #: `vertices` slot is `UINT32_MAX`.
    _fields_ = [("point", c_double * 3), ("distance", c_double), ("triangle", c_uint32), ("kind", c_uint32),
                ("barycentric", c_double * 3), ("vertices", c_uint32 * 2)]


class _CurveMeshFoot(ctypes.Structure):
    #: `CadaclysmBlacksmithCurveMeshFoot`, 120 bytes: the curve's side, then the mesh's as a
    #: `_MeshPoint`; `crossing` 1 where the curve passes through the mesh.
    _fields_ = [("distance", c_double), ("t", c_double), ("point_on_curve", c_double * 3), ("mesh", _MeshPoint),
                ("crossing", c_int32)]


class _NearestObject(ctypes.Structure):
    #: `CadaclysmBlacksmithNearestObject`, 408 bytes. Only the member `answer_kind` names is
    #: filled (0 `body`, 1 `pair`, 2 neither, 3 `mesh`); every field of the others is zero (a NULL
    #: `kind`). C writes the whole struct, `mesh` included, whatever the set holds.
    _fields_ = [("which", c_uint32), ("answer_kind", c_int32), ("distance", c_double), ("t", c_double),
                ("point_on_curve", c_double * 3), ("point_on_item", c_double * 3), ("body", _CurveBodyFoot),
                ("pair", _CurvePair), ("mesh", _CurveMeshFoot)]


class _RTreeHit(ctypes.Structure):
    #: `CadaclysmBlacksmithRTreeHit`: an entry's id and the distance to its box (0 for a search
    #: hit). Pinned by `tests/bindings.rs`.
    _fields_ = [("id", c_uint32), ("distance", c_double)]


class _RTreePair(ctypes.Structure):
    #: `CadaclysmBlacksmithRTreePair`: two entry ids. Pinned by `tests/bindings.rs`.
    _fields_ = [("a", c_uint32), ("b", c_uint32)]


class _Region(ctypes.Structure):
    #: `CadaclysmBlacksmithRegion`: one region of a solid -- `finite` 0 for region 0, its box,
    #: how many face sides bound it and how many shells. Pinned by `tests/bindings.rs`.
    _fields_ = [("finite", c_int32), ("min", c_double * 3), ("max", c_double * 3), ("sides", c_uint32), ("shells", c_uint32)]


class _FaceSide(ctypes.Structure):
    #: `CadaclysmBlacksmithFaceSide`: a face and which side of it, +1 where its normal points.
    #: Pinned by `tests/bindings.rs`.
    _fields_ = [("face", c_uint32), ("sense", c_int32)]


class Mass:
    """What a solid measures, per unit density, each figure beside a bound on its own error.

    Per unit density is the primitive: a body's `mass` is `density * volume` and its inertia scales
    the same way, so `Mass.of(solid).mass(7850)` for steel in kilograms where the model is in metres.
    Nothing here multiplies by a density on your behalf -- an assembly of two materials would have to
    undo it.

    `volume`, `centroid`, `inertia` and `principal_moments` mean something only where `closed`. On an
    open body they are zero and `area` is still measured, which is what a sheet is. Where
    `accuracy_met` is false the refinement stopped before the accuracy asked for: the figures are
    honest, they are simply less certain, and the errors say by how much.
    """

    __slots__ = ("closed", "inverted", "accuracy_met", "from_mesh", "area", "area_error", "volume",
                 "volume_error", "centroid", "centroid_error", "inertia", "inertia_error",
                 "principal_moments", "principal_axes")

    closed: bool
    inverted: bool
    accuracy_met: bool
    from_mesh: bool
    area: float
    area_error: float
    volume: float
    volume_error: float
    centroid: tuple[float, float, float]
    centroid_error: float
    inertia: tuple[tuple[float, float, float], tuple[float, float, float], tuple[float, float, float]]
    inertia_error: float
    principal_moments: tuple[float, float, float]
    principal_axes: tuple[tuple[float, float, float], tuple[float, float, float], tuple[float, float, float]]

    def __init__(self, raw: "_MassProperties"):
        self.closed = bool(raw.closed)
        self.inverted = bool(raw.inverted)
        self.accuracy_met = bool(raw.accuracy_met)
        self.from_mesh = bool(raw.from_mesh)
        self.area = raw.area
        self.area_error = raw.area_error
        self.volume = raw.volume
        self.volume_error = raw.volume_error
        self.centroid = tuple(raw.centroid)
        self.centroid_error = raw.centroid_error
        #: Three rows of three, about the centroid, products of inertia negated.
        self.inertia = tuple(tuple(raw.inertia[r * 3 + c] for c in range(3)) for r in range(3))  # pyright: ignore[reportAttributeAccessIssue]
        self.inertia_error = raw.inertia_error
        #: Ascending.
        self.principal_moments = tuple(raw.principal_moments)
        #: Unit, orthogonal, right-handed; row `i` belongs to moment `i`.
        self.principal_axes = tuple(tuple(raw.principal_axes[r * 3 + c] for c in range(3)) for r in range(3))  # pyright: ignore[reportAttributeAccessIssue]

    @staticmethod
    def of(solid: "Solid", accuracy: float = 0.0) -> "Mass":
        """Measure `solid`. `accuracy` is relative; 0 asks for the library's default."""
        return solid.mass(accuracy)

    def mass(self, density: float) -> float:
        """`density * volume`, in whatever units the model and the density agree on."""
        return float(density) * self.volume

    def __repr__(self) -> str:
        if not self.closed:
            return f"Mass(open, area={self.area:.6g}+-{self.area_error:.3g})"
        return (f"Mass(area={self.area:.6g}+-{self.area_error:.3g}, volume={self.volume:.6g}"
                f"+-{self.volume_error:.3g}, centroid={tuple(round(c, 9) for c in self.centroid)})")


def _rows(flat) -> "tuple[tuple[float, float, float], tuple[float, float, float], tuple[float, float, float]]":
    """Nine row-major numbers as three rows of three."""
    return tuple(tuple(flat[r * 3 + c] for c in range(3)) for r in range(3))  # pyright: ignore[reportReturnType]


class OrientedBox:
    """A closed solid's box on its principal axes (`Solid.oriented_box`): `centre`, three unit
    `axes` (row `i` is axis `i`, orthonormal and right-handed) and the `half` extent along each.

    The axes are the inertia's, so the box is tight for a body with a clear long direction but not
    the minimal box in general -- and where two moments are equal (a cube, a cylinder about its
    axis) any axes in that plane are as principal as the others, so which ones come back is a free
    choice. The `half` extents are grown by the tolerance the measurement settled on, so they hold
    the body and may exceed its own extent by about that much. `centre` is the box's middle, not
    the centroid. An open body has no oriented box.
    """

    __slots__ = ("centre", "axes", "half")

    centre: tuple[float, float, float]
    axes: tuple[tuple[float, float, float], tuple[float, float, float], tuple[float, float, float]]
    half: tuple[float, float, float]

    def __init__(self, raw: "_OrientedBox"):
        self.centre = tuple(raw.centre)  # pyright: ignore[reportAttributeAccessIssue]
        self.axes = _rows(raw.axes)
        self.half = tuple(raw.half)  # pyright: ignore[reportAttributeAccessIssue]

    def __repr__(self) -> str:
        return f"OrientedBox(centre={tuple(round(c, 9) for c in self.centre)}, half={tuple(round(h, 9) for h in self.half)})"


class Length:
    """A measured length (`Solid.edge_length`, `Profile.length`) beside an estimate of its error.

    `error` is an estimate of the distance from the true length, not a proof: where `accuracy_met`
    it bounds the error in practice; where not, the refinement stopped at its depth limit and the
    figure is less certain than was asked. `from_polyline` says the curve was a sampled polyline,
    exact for its points and not for whatever they were sampled from.
    """

    __slots__ = ("length", "error", "accuracy_met", "from_polyline")

    length: float
    error: float
    accuracy_met: bool
    from_polyline: bool

    def __init__(self, raw: "_Length"):
        self.length = raw.length
        self.error = raw.error
        self.accuracy_met = bool(raw.accuracy_met)
        self.from_polyline = bool(raw.from_polyline)

    def __repr__(self) -> str:
        return f"Length({self.length:.9g}+-{self.error:.3g})"


class At:
    """A point at arc length (`Solid.edge_point_at_length`, `Profile.point_at_length`, and
    every sample of the divides): the `point`, the unit `tangent` there (zero where the curve
    stops), the curve's own `parameter`, and `error`, an estimate of how far the arc length to
    it can be trusted.

    `segment` is `None` on a solid's edge; on a profile it is the side the point lies on (its
    segment index, or the segment count for the implicit closing side), and `parameter` is that
    side's own -- a line's 0..1, an arc's angle about its centre, a spline's parameter.
    `from_polyline` says the curve was a sampled polyline, exact for its points only.
    """

    __slots__ = ("point", "tangent", "parameter", "segment", "error", "from_polyline")

    point: "tuple[float, float, float]"
    tangent: "tuple[float, float, float]"
    parameter: float
    segment: "int | None"
    error: float
    from_polyline: bool

    def __init__(self, raw: "_At"):
        self.point = (float(raw.point[0]), float(raw.point[1]), float(raw.point[2]))
        self.tangent = (float(raw.tangent[0]), float(raw.tangent[1]), float(raw.tangent[2]))
        self.parameter = float(raw.parameter)
        self.segment = None if raw.segment == NONE else int(raw.segment)
        self.error = float(raw.error)
        self.from_polyline = bool(raw.from_polyline)

    def __repr__(self) -> str:
        p = ", ".join(f"{v:.9g}" for v in self.point)
        on = "" if self.segment is None else f", segment={self.segment}"
        return f"At(({p}), parameter={self.parameter:.9g}{on}, +-{self.error:.3g})"


class Closest:
    """The closest points between two solids' boundaries (`Solid.closest`), side `a` the solid
    asked, side `b` the other.

    Each side names the feature its point lies on: `kind` is `"face"`, `"edge"` or `"vertex"`,
    `index` the kernel's id for it, and `edge` the index `fillet`/`chamfer`/`Solid.edges` use
    for an edge feature -- `None` for a face or a vertex, and for an edge the fillet table does
    not hold (a trim with no exact curve).

    Boundaries are measured: a body wholly inside another is the gap between their skins, not 0,
    and boundaries that cross are 0 apart. A `refined` answer is never below the true minimum and
    within the tolerance of it wherever the face pair holding the minimum refines to its own
    nearest pair. Where a nearer candidate did not converge, or left its trims and its boundary
    search found nothing, the mesh's answer comes back instead with `refined` False: within
    `[d - 2/3 tolerance, d + tolerance]` of the true minimum `d`.
    """

    __slots__ = ("distance", "on_a", "on_b", "kind_a", "index_a", "edge_a", "kind_b", "index_b", "edge_b",
                 "refined")

    distance: float
    on_a: tuple[float, float, float]
    on_b: tuple[float, float, float]
    kind_a: str
    index_a: int
    edge_a: int | None
    kind_b: str
    index_b: int
    edge_b: int | None
    refined: bool

    def __init__(self, raw: "_Closest"):
        self.distance = raw.distance
        self.on_a = tuple(raw.on_a)  # pyright: ignore[reportAttributeAccessIssue]
        self.on_b = tuple(raw.on_b)  # pyright: ignore[reportAttributeAccessIssue]
        self.kind_a, self.index_a = _text(raw.kind_a), raw.index_a
        self.edge_a = None if raw.edge_a == NONE else raw.edge_a
        self.kind_b, self.index_b = _text(raw.kind_b), raw.index_b
        self.edge_b = None if raw.edge_b == NONE else raw.edge_b
        self.refined = bool(raw.refined)

    def __repr__(self) -> str:
        return f"Closest({self.distance:.9g}, a={self.kind_a} {self.index_a}, b={self.kind_b} {self.index_b})"


class PointFoot(NamedTuple):
    """The nearest point of a solid (or of one face) to a query point (`Solid.closest_point`,
    `Projector.closest_point`, `Solid.face_closest_point`).

    `point` lies on the body's boundary: a query inside a closed body is answered by its nearest
    boundary point, not 0. `distance` is from the query point to `point`.

    What the point lies on is named as `Closest` names each side: `kind` is `"face"`, `"edge"` or
    `"vertex"`, `index` the kernel's id for it (the face index, the edge's kernel id, the vertex
    index), and `edge` the index `Solid.edges` uses -- what `edge_length`, `fillet`, `chamfer` and
    `Solid.edge_closest_point` take -- for an edge foot; `None` for a face, a vertex, and an edge
    the fillet table does not hold. Read `edge`, not `index`, for the public edge number.

    `uv` is the face parameter of a foot inside a face, `None` for an edge or a vertex foot. `normal` is unit: a face foot's outward normal; an edge or vertex
    foot's direction from the foot to the query point; on the body (`distance` 0) the mean of the
    adjacent faces' outward normals.

    `refined` is True when the foot was refined onto the exact geometry: `distance` is then never
    below the true minimum and within the tolerance of it. False is the mesh's answer, within
    `[d - 2/3 tolerance, d + tolerance]` of the true minimum `d`. A face's answer is always
    refined."""
    point: "tuple[float, float, float]"
    distance: float
    kind: str
    index: int
    edge: "int | None"
    uv: "tuple[float, float] | None"
    normal: "tuple[float, float, float]"
    refined: bool


def _point_foot(raw: "_PointFoot") -> PointFoot:
    """A `_PointFoot` the library filled, copied out: `uv` NaN is `None`, `edge` NONE is `None`."""
    u, v = float(raw.uv[0]), float(raw.uv[1])
    return PointFoot((float(raw.point[0]), float(raw.point[1]), float(raw.point[2])), float(raw.distance),
                     _text(raw.kind), int(raw.index), None if raw.edge == NONE else int(raw.edge),
                     None if math.isnan(u) or math.isnan(v) else (u, v),
                     (float(raw.normal[0]), float(raw.normal[1]), float(raw.normal[2])), bool(raw.refined))


def _unlimited(max_distance: "float | None") -> float:
    """A `max_distance` as the C ABI takes it: None is no limit, NaN (as +inf is)."""
    return float("nan") if max_distance is None else float(max_distance)


class CurvePair(NamedTuple):
    """The nearest points of two curves (`NurbsCurve.closest_points`): side `a` on the curve
    asked, at its parameter `t_a`, side `b` on the other, at `t_b`, `distance` apart. Exact."""
    distance: float
    t_a: float
    point_a: "tuple[float, float, float]"
    t_b: float
    point_b: "tuple[float, float, float]"


class CurveBodyFoot(NamedTuple):
    """The nearest points of a curve and a solid's boundary (`Solid.curve_closest_points`,
    `Projector.curve_closest_points`): `point_on_curve` at the curve's parameter `t`, and
    `point_on_body`, `distance` apart.

    `crossing` is True where the curve passes through the boundary: `distance` is then exactly
    0 and the earliest crossing in `t` answers.

    The body's side is the point query's foot at `point_on_curve`, named as `PointFoot` names it: `kind` is `"face"`, `"edge"` or
    `"vertex"`, `index` the kernel's id for it, and `edge` the index `Solid.edges` uses -- what
    `edge_length`, `fillet` and `Solid.edge_closest_point` take -- for an edge foot, `None`
    otherwise; read `edge`, not `index`, for the public edge number. `uv` is the face parameter
    of a foot inside a face, `None` for an edge or a vertex foot; `normal` is unit, as
    `PointFoot.normal`. `refined` False is the mesh's answer, within
    `[d - 2/3 tolerance, d + tolerance]` of the true minimum `d`."""
    distance: float
    t: float
    point_on_curve: "tuple[float, float, float]"
    point_on_body: "tuple[float, float, float]"
    kind: str
    index: int
    edge: "int | None"
    uv: "tuple[float, float] | None"
    normal: "tuple[float, float, float]"
    refined: bool
    crossing: bool


class NearestObject(NamedTuple):
    """The nearest of a list of things to a curve (`NurbsCurve.closest_object`): `which` the
    item's index in the list, `distance` from `point_on_curve` (at the curve's parameter `t`) to
    `point_on_item`. `answer` is the item's own answer: a `CurveBodyFoot` for a solid or a
    projector, a `CurvePair` (side `a` the curve asked) for a curve, a `CurveMeshFoot` for a
    `TriangleMesh`, None for a point."""
    which: int
    distance: float
    t: float
    point_on_curve: "tuple[float, float, float]"
    point_on_item: "tuple[float, float, float]"
    answer: "CurveBodyFoot | CurvePair | CurveMeshFoot | None"


_MESH_KINDS = ("face", "edge", "vertex")


@dataclass(frozen=True)
class MeshPoint:
    """The nearest point of a `TriangleMesh` to a query point (`TriangleMesh.closest_point`).
    Exact: no tolerance, no `refined` figure.

    `point` lies on the mesh, `distance` from the query point to it. `triangle` is the
    lowest-numbered triangle holding the point: where it lies on an edge or a vertex several
    triangles share, the lower triangle answers. `barycentric` are the point's three weights on
    that triangle's corners, in index order, summing to 1.

    `kind` is the feature the point lies on, `"face"` (inside `triangle`), `"edge"` or
    `"vertex"`, and `vertices` names it: an edge's two vertex indices ascending, a vertex's one,
    `()` for a face."""
    point: "tuple[float, float, float]"
    distance: float
    triangle: int
    barycentric: "tuple[float, float, float]"
    kind: str
    vertices: "tuple[int, ...]"


@dataclass(frozen=True)
class CurveMeshFoot:
    """The nearest points of a curve and a `TriangleMesh` (`TriangleMesh.curve_closest_points`,
    and a `NearestObject`'s answer for a mesh): `point_on_curve` at the curve's parameter `t`,
    and `point_on_mesh`, `distance` apart. Exact: no tolerance, no `refined` figure.

    `crossing` is True where the curve passes through a triangle: `distance` is then exactly 0
    and the earliest crossing in `t` answers. A curve that touches without passing through is
    distance 0, `crossing` False. Among equal distances the lower triangle, then the lower `t`,
    answers. The mesh's side is named as `MeshPoint` names it, flat: `triangle`, `barycentric`,
    `kind` and `vertices`."""
    distance: float
    t: float
    point_on_curve: "tuple[float, float, float]"
    point_on_mesh: "tuple[float, float, float]"
    triangle: int
    barycentric: "tuple[float, float, float]"
    kind: str
    vertices: "tuple[int, ...]"
    crossing: bool


def _mesh_kind(kind: int) -> str:
    if not 0 <= kind < len(_MESH_KINDS):
        raise BuildError(f"triangle mesh: the library answered kind {kind}, not 0, 1 or 2")
    return _MESH_KINDS[kind]


def _mesh_point(raw: "_MeshPoint") -> MeshPoint:
    """A `_MeshPoint` the library filled, copied out: `kind` as its word, the `vertices` slots
    that are NONE dropped."""
    return MeshPoint(_triple(raw.point), float(raw.distance), int(raw.triangle), _triple(raw.barycentric),
                     _mesh_kind(raw.kind), tuple(int(v) for v in raw.vertices if v != NONE))


def _curve_mesh_foot(raw: "_CurveMeshFoot") -> CurveMeshFoot:
    """A `_CurveMeshFoot` the library filled, copied out flat, the mesh's side as `_mesh_point`
    reads it."""
    m = _mesh_point(raw.mesh)
    return CurveMeshFoot(float(raw.distance), float(raw.t), _triple(raw.point_on_curve), m.point, m.triangle,
                         m.barycentric, m.kind, m.vertices, bool(raw.crossing))


def _triple(v) -> "tuple[float, float, float]":
    return (float(v[0]), float(v[1]), float(v[2]))


def _curve_pair(raw: "_CurvePair") -> CurvePair:
    """A `_CurvePair` the library filled, copied out."""
    return CurvePair(float(raw.distance), float(raw.t_a), _triple(raw.point_a), float(raw.t_b), _triple(raw.point_b))


def _curve_body_foot(raw: "_CurveBodyFoot") -> CurveBodyFoot:
    """A `_CurveBodyFoot` the library filled, copied out flat: the body's `uv` NaN and `edge`
    NONE are `None`, as `_point_foot` reads them."""
    body = _point_foot(raw.body)
    return CurveBodyFoot(float(raw.distance), float(raw.t), _triple(raw.point_on_curve), body.point, body.kind,
                         body.index, body.edge, body.uv, body.normal, body.refined, bool(raw.crossing))


def _nearest_object(raw: "_NearestObject") -> NearestObject:
    """A `_NearestObject` the library filled: only the member `answer_kind` names is read (the
    others are zero bytes, `body`'s `kind` NULL; 2, a point, has none)."""
    kind = raw.answer_kind
    answer = (_curve_body_foot(raw.body) if kind == 0 else _curve_pair(raw.pair) if kind == 1
              else _curve_mesh_foot(raw.mesh) if kind == 3 else None)
    return NearestObject(int(raw.which), float(raw.distance), float(raw.t), _triple(raw.point_on_curve),
                         _triple(raw.point_on_item), answer)


class Beziers:
    """Curves as cubic Béziers: `points` is `(count, 4, 3)` and `weights` is
    `(count, 4)`, four control points and four weights a curve.

    Unlike the reader's `Beziers`, these arrays are **the wrapper's own** -- the
    kernel hands its buffer over and this releases it before returning, so there
    is nothing to outlive. They are read-only, non-contiguous views over one
    owned copy held in `.base`; `copy()` makes writable, contiguous arrays of
    your own. A rational curve (a circle's arc) carries the weights that make it exact; a
    polynomial one carries ones.
    """

    __slots__ = ("points", "weights", "count")

    def __init__(self, points: numpy.ndarray | None, weights: numpy.ndarray | None, count: int) -> None:
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


class _Colours(ctypes.Structure):
    _fields_ = [("rgb", POINTER(c_double)), ("count", c_uint32)]


class _FaceTriangles(ctypes.Structure):
    _fields_ = [("counts", POINTER(c_uint32)), ("face_count", c_uint32)]


class _Edge(ctypes.Structure):
    _fields_ = [("kind", c_char_p), ("faces", POINTER(c_uint32)), ("face_count", c_uint32),
                ("segments", POINTER(c_double)), ("segment_count", c_uint32)]


class _Point(ctypes.Structure):
    _fields_ = [("x", c_double), ("y", c_double), ("z", c_double)]


class _Spot(ctypes.Structure):
    _fields_ = [("loop_index", c_uint32), ("segment", c_uint32), ("t", c_double),
                ("face", c_uint32), ("u", c_double), ("v", c_double)]


class _Hit(ctypes.Structure):
    _fields_ = [("run", c_bool), ("touch", c_bool), ("start", _Point), ("end", _Point),
                ("a_start", _Spot), ("a_end", _Spot), ("b_start", _Spot), ("b_end", _Spot)]


class _SvgOptions(ctypes.Structure):
    #: `CadaclysmBlacksmithSvgOptions`. Field order and `size` are the whole
    #: contract -- `cadaclysm_blacksmith_svg_options_init` fills the library's
    #: whole struct, so this list must match the header field for field, and it
    #: may never reorder.
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


class _HlrOptions(ctypes.Structure):
    #: `CadaclysmBlacksmithHlrOptions`, field for field as the header has it (`size` is the
    #: contract, as `_SvgOptions`'s).
    _fields_ = [
        ("size", c_uint32),
        ("projection", c_uint32),
        ("direction", c_double * 3),
        ("up", c_double * 3),
        ("eye", c_double * 3),
        ("target", c_double * 3),
        ("tolerance", c_double),
        ("smooth_angle", c_double),
        ("feature_angle", c_double),
        ("iso", c_uint32),
        ("reserved", c_uint32),
    ]


class _HlrLine(ctypes.Structure):
    #: `CadaclysmBlacksmithHlrLine`.
    _fields_ = [
        ("kind", c_uint32),
        ("visible", c_uint32),
        ("solid", c_uint32),
        ("source_kind", c_uint32),
        ("source", c_uint32),
        ("source2", c_uint32),
        ("bezier_count", c_uint32),
        ("reserved", c_uint32),
        ("length2d", c_double),
        ("length3d", c_double),
    ]


class _HlrReport(ctypes.Structure):
    #: `CadaclysmBlacksmithHlrReport`.
    _fields_ = [(name, c_uint32) for name in (
        "candidates", "segments", "crossings", "pieces", "degenerate", "rays", "mesh_hits", "rejected",
        "grazes", "unsettled", "mesh_only", "fallback_edges", "failed_solids", "reserved")] + [
        ("candidate_length", c_double), ("degenerate_length", c_double), ("tolerance", c_double)]


class _Curve(ctypes.Structure):
    _fields_ = [("kind", c_char_p), ("origin", _Point), ("x", _Point), ("y", _Point), ("z", _Point),
                ("radius", c_double), ("radius2", c_double), ("t0", c_double), ("t1", c_double),
                ("degree", c_uint32), ("knots", POINTER(c_double)), ("knot_count", c_uint32),
                ("poles", POINTER(c_double)), ("pole_count", c_uint32), ("weights", POINTER(c_double))]


class _Chain(ctypes.Structure):
    _fields_ = [("points", POINTER(c_double)), ("point_count", c_uint32), ("face_a", c_uint32), ("face_b", c_uint32),
                ("closed", c_bool), ("tangent", c_bool), ("has_curve", c_bool)]


class _Finding(ctypes.Structure):
    _fields_ = [("kind", c_char_p), ("argument", c_uint32), ("index", c_uint32), ("other", c_uint32), ("size", c_double)]


class _Overlap(ctypes.Structure):
    _fields_ = [("face_a", c_uint32), ("face_b", c_uint32), ("points", POINTER(c_double)),
                ("loop_offsets", POINTER(c_uint32)), ("point_count", c_uint32), ("loop_count", c_uint32)]


class _Box(ctypes.Structure):
    #: `CadaclysmBlacksmithBox`: `lo` and `hi`, three doubles each -- bit-compatible
    #: with six contiguous doubles, which is how a `Box` crosses *in* to a call
    #: (`_box_words`, as a frame crosses in); this struct is only ever an out-param.
    _fields_ = [("lo", c_double * 3), ("hi", c_double * 3)]


class _ColliderStats(ctypes.Structure):
    #: `CadaclysmBlacksmithColliderStats`: nine counts of one `collider_check` call.
    _fields_ = [("considered", c_uint32), ("world_boxes", c_uint32), ("oriented_boxes", c_uint32),
                ("skipped_share", c_uint32), ("cached", c_uint32), ("closed_form", c_uint32),
                ("meshed", c_uint32), ("refused", c_uint32), ("confirmed", c_uint32)]


class _CollisionHit(ctypes.Structure):
    #: `CadaclysmBlacksmithCollisionHit`: a pair that interferes (`overlap` True) or
    #: could not be decided (`text` says why). `positions`/`normals` are
    #: `vertex_count` world xyz triples; `indices` is `index_count` entries.
    _fields_ = [("a", c_uint32), ("b", c_uint32), ("overlap", c_bool), ("depth", c_double),
                ("positions", POINTER(c_double)), ("normals", POINTER(c_double)), ("indices", POINTER(c_uint32)),
                ("vertex_count", c_uint32), ("index_count", c_uint32), ("text", c_char_p)]


class _Clash(ctypes.Structure):
    #: `CadaclysmBlacksmithClash`: one pair of a clash call. `kind`, `kind_a`, `kind_b` and `text`
    #: borrow from the clashes handle (here from the struct itself under Pyodide); `edge_*` is NONE
    #: where the feature has no fillet-table edge, and `kind_*` is "none" for a penetrating or
    #: refused pair. Pinned by `tests/bindings.rs`.
    _fields_ = [("a", c_uint32), ("b", c_uint32), ("kind", c_char_p), ("distance", c_double),
                ("on_a", c_double * 3), ("on_b", c_double * 3),
                ("kind_a", c_char_p), ("index_a", c_uint32), ("edge_a", c_uint32),
                ("kind_b", c_char_p), ("index_b", c_uint32), ("edge_b", c_uint32),
                ("refined", c_int32), ("depth", c_double), ("text", c_char_p)]


class _Thickness(ctypes.Structure):
    #: `CadaclysmBlacksmithThickness`: one reading on a solid. `vertex` is NONE for a reading at
    #: a point (`thickness_gauge_at`); `sphere` is NaN where the kernel's is `None`. Pinned by
    #: `tests/bindings.rs`.
    _fields_ = [("body", c_uint32), ("vertex", c_uint32), ("face", c_uint32), ("point", c_double * 3),
                ("thickness", c_double), ("opposite", c_double * 3), ("opposite_body", c_uint32),
                ("opposite_face", c_uint32), ("knife", c_bool), ("exact_thickness", c_double),
                ("exact_opposite", c_double * 3), ("sphere", c_double)]


class _MeshThickness(ctypes.Structure):
    #: `CadaclysmBlacksmithMeshThickness`: one reading on a plain mesh, its indices within
    #: their own meshes. Pinned by `tests/bindings.rs`.
    _fields_ = [("mesh", c_uint32), ("vertex", c_uint32), ("thickness", c_double), ("point", c_double * 3),
                ("opposite", c_double * 3), ("opposite_mesh", c_uint32), ("opposite_triangle", c_uint32),
                ("knife", c_bool)]


class _FaceThickness(ctypes.Structure):
    #: `CadaclysmBlacksmithFaceThickness`: one thickness for a face; `found` false (nothing found) leaves
    #: the numbers NaN and `uniform` false. Pinned by `tests/bindings.rs`.
    _fields_ = [("found", c_bool), ("thickness", c_double), ("min", c_double), ("max", c_double),
                ("uniform", c_bool)]


class _ThicknessMesh(ctypes.Structure):
    #: `CadaclysmBlacksmithThicknessMesh`: a body's measuring mesh, borrowed from the gauge
    #: (`ThicknessGauge.mesh` copies it out at once; under Pyodide the arrays are copies kept
    #: on the struct). Pinned by `tests/bindings.rs`.
    _fields_ = [("positions", POINTER(c_double)), ("normals", POINTER(c_double)), ("indices", POINTER(c_uint32)),
                ("faces", POINTER(c_uint32)), ("vertex_count", c_uint32), ("triangle_count", c_uint32)]


class _SweptClash(ctypes.Structure):
    #: `CadaclysmBlacksmithSweptClash`: one pair of a swept clash call -- its first time (in pose
    #: units) and how many time ranges it stays in clash. Pinned by `tests/bindings.rs`.
    _fields_ = [("a", c_uint32), ("b", c_uint32), ("first_time", c_double), ("interval_count", c_uint32)]


class _FemOptions(ctypes.Structure):
    #: `CadaclysmBlacksmithFemOptions`. Field order and `size` are the whole
    #: contract, as `_SvgOptions` above: `cadaclysm_blacksmith_fem_options_init`
    #: fills the library's whole struct, so this list must match the header field
    #: for field -- `cadaclysm-capi/tests/bindings.rs` pins it -- and it may never
    #: reorder. A field the library has and this list does not is written *past*
    #: what `Solid.fem_mesh` allocated.
    _fields_ = [("size", c_size_t), ("tolerance", c_double), ("max_size", c_double)]


class _FemMeshView(ctypes.Structure):
    #: `CadaclysmBlacksmithFemMeshView`: every pointer borrowed from the FEM handle
    #: and dead with it, the counts in elements (`nodes` holds `node_count * 3`
    #: doubles). Pinned against the header by `cadaclysm-capi/tests/bindings.rs`,
    #: which is the only thing between a missing field here and reading
    #: `min_angle` out of `watertight`.
    _fields_ = [("nodes", POINTER(c_double)), ("node_count", c_uint32),
                ("triangles", POINTER(c_uint32)), ("triangle_count", c_uint32),
                ("triangle_face", POINTER(c_uint32)), ("node_kind", POINTER(c_uint32)),
                ("node_entity", POINTER(c_uint32)), ("face_count", c_uint32),
                ("edge_count", c_uint32), ("vertex_count", c_uint32),
                ("open_edge_count", c_uint32), ("folded_edge_count", c_uint32),
                ("watertight", c_bool), ("from_mesh", c_bool), ("min_angle", c_double),
                ("worst_triangle", c_uint32), ("longest_edge", c_double)]


class _FemEdge(ctypes.Structure):
    #: `CadaclysmBlacksmithFemEdge`: one B-rep edge's node chain. Pinned by bindings.rs.
    _fields_ = [("id", c_uint32), ("nodes", POINTER(c_uint32)), ("node_count", c_uint32),
                ("runs", POINTER(c_uint32)), ("run_count", c_uint32),
                ("face_a", c_uint32), ("face_b", c_uint32), ("end_a", c_uint32),
                ("end_b", c_uint32), ("closed", c_bool), ("seam", c_bool)]


class _FemVertex(ctypes.Structure):
    #: `CadaclysmBlacksmithFemVertex`. `point` is three doubles in the struct, not a
    #: pointer. Pinned by bindings.rs.
    _fields_ = [("node", c_uint32), ("point", c_double * 3), ("has_position", c_bool)]


class _SubdParts(ctypes.Structure):
    #: `CadaclysmBlacksmithSubdParts`: a cage's parts as views into its handle, valid
    #: until the handle is freed (`Subd` copies them out at once). Pinned by bindings.rs.
    _fields_ = [("positions", POINTER(c_double)), ("vertex_count", c_uint32),
                ("face_sizes", POINTER(c_uint32)), ("face_count", c_uint32),
                ("face_indices", POINTER(c_uint32)), ("index_count", c_uint32),
                ("creases", POINTER(c_uint32)), ("crease_count", c_uint32),
                ("pins", POINTER(c_uint32)), ("pin_count", c_uint32),
                ("symmetry_axis", c_int32), ("symmetry_tolerance", c_double),
                ("selection_kind", c_uint32), ("selection", POINTER(c_uint32)), ("selection_count", c_uint32)]


class _SubdMesh(ctypes.Structure):
    #: `CadaclysmBlacksmithSubdMesh`: one level of a cage's smooth surface, views valid
    #: until the handle is freed. Pinned by bindings.rs.
    _fields_ = [("positions", POINTER(c_double)), ("vertex_count", c_uint32),
                ("normals", POINTER(c_double)), ("indices", POINTER(c_uint32)),
                ("index_count", c_uint32), ("triangle_face", POINTER(c_uint32))]


class _SubdReport(ctypes.Structure):
    #: `CadaclysmBlacksmithSubdReport`: what `subd_to_solid` did and how close it came.
    #: Pinned by bindings.rs.
    _fields_ = [("regular", c_uint32), ("refined", c_uint32), ("steps", c_uint32), ("levels", c_uint32),
                ("deviation", c_double), ("g1_angle_deg", c_double),
                ("deviation_at", c_double * 3), ("g1_at", c_double * 3)]


_PROGRESS = ctypes.CFUNCTYPE(None, c_char_p, c_size_t, c_size_t, c_void_p)
# `CadaclysmBlacksmithDocumentProgress`: the node id, then as `_PROGRESS`.
_DOCUMENT_PROGRESS = ctypes.CFUNCTYPE(None, c_char_p, c_char_p, c_size_t, c_size_t, c_void_p)
_D = POINTER(c_double)
_U = POINTER(c_uint32)
_SOLID = c_void_p
_PROFILE = c_void_p
_PATH = c_void_p
_SWEEP_PATH = c_void_p
_HITS = c_void_p
_INTERSECTION = c_void_p
_CHECK = c_void_p
_FEM = c_void_p
_PROFILE_LIST = c_void_p
_ASSEMBLY = c_void_p
_SKETCH = c_void_p
_SZ = POINTER(c_size_t)
_COLLIDER = c_void_p
_CLASSIFIER = c_void_p
_PROJECTOR = c_void_p
_COLLISIONS = c_void_p
_CLASHES = c_void_p
_SWEPT_CLASHES = c_void_p
_THICKNESS_GAUGE = c_void_p
_THICKNESSES = c_void_p
_MESH_THICKNESSES = c_void_p
_SAMPLES = c_void_p
_RTREE = c_void_p
_INTERPOLATOR = c_void_p
_RTREE_HITS = c_void_p
_RTREE_PAIRS = c_void_p
_REGIONS = c_void_p
_TESSELLATION = c_void_p
_TOOL = c_void_p
_STOCK = c_void_p
_JOB = c_void_p
_PROGRAMS = c_void_p
_REPORT = c_void_p
_OPERATIONS = c_void_p
_SUBD = c_void_p
_NURBS_CURVE = c_void_p
_TRIANGLE_MESH = c_void_p
_HLR = c_void_p
_PAGE = c_void_p
_DOCUMENT = c_void_p
_HISTORY = c_void_p

_ENTRY_POINTS = [
    ("cadaclysm_blacksmith_last_error", c_char_p, []),
    ("cadaclysm_blacksmith_license_set", ctypes.c_bool, [c_char_p]),
    ("cadaclysm_blacksmith_license_info", c_char_p, []),
    ("cadaclysm_blacksmith_license_notice_count", c_uint64, []),
    ("cadaclysm_blacksmith_build_date", c_char_p, []),
    ("cadaclysm_blacksmith_version", c_char_p, []),
    ("cadaclysm_blacksmith_solid_free", None, [_SOLID]),
    ("cadaclysm_blacksmith_health", c_void_p, [_SOLID, c_double, c_bool]),
    ("cadaclysm_blacksmith_health_free", None, [c_void_p]),
    ("cadaclysm_blacksmith_health_summary", c_bool, [c_void_p, _U, _D]),
    ("cadaclysm_blacksmith_health_free_edges", c_uint32, [c_void_p, _U, _D]),
    ("cadaclysm_blacksmith_health_wires", c_uint32, [c_void_p, _U, _D]),
    ("cadaclysm_blacksmith_health_small", c_uint32, [c_void_p, _U, _D]),
    ("cadaclysm_blacksmith_health_crack_edges", c_uint32, [c_void_p, _U]),
    ("cadaclysm_blacksmith_healed", c_void_p, [_SOLID, c_double, c_uint32]),
    ("cadaclysm_blacksmith_heal_body", _SOLID, [c_void_p]),
    ("cadaclysm_blacksmith_heal_free", None, [c_void_p]),
    ("cadaclysm_blacksmith_heal_summary", c_bool, [c_void_p, _U, _D]),
    ("cadaclysm_blacksmith_heal_fixes", c_uint32, [c_void_p, _U, _D]),
    ("cadaclysm_blacksmith_heal_refused", c_uint32, [c_void_p, _U, _D]),
    ("cadaclysm_blacksmith_edge_tolerance", c_double, [_SOLID, c_uint32]),
    ("cadaclysm_blacksmith_effective_tolerance", c_double, [POINTER(c_void_p), c_size_t]),
    ("cadaclysm_blacksmith_solid_tolerances", c_bool, [_SOLID, POINTER(c_double), POINTER(c_double)]),
    ("cadaclysm_blacksmith_solid_with_tolerances", _SOLID, [_SOLID, c_double, c_double]),
    ("cadaclysm_blacksmith_vertex_tolerance", c_double, [_SOLID, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_named", _SOLID, [_SOLID, c_char_p]),
    ("cadaclysm_blacksmith_solid_name", c_char_p, [_SOLID]),
    ("cadaclysm_blacksmith_with_material", _SOLID, [_SOLID, c_char_p]),
    ("cadaclysm_blacksmith_solid_material", c_char_p, [_SOLID]),
    ("cadaclysm_blacksmith_styled", _SOLID, [_SOLID, c_char_p, c_char_p]),
    ("cadaclysm_blacksmith_solid_style_location", c_char_p, [_SOLID]),
    ("cadaclysm_blacksmith_solid_style_identification", c_char_p, [_SOLID]),
    ("cadaclysm_blacksmith_profile_free", None, [_PROFILE]),
    ("cadaclysm_blacksmith_profile_rect", _PROFILE, [c_double, c_double]),
    ("cadaclysm_blacksmith_profile_circle", _PROFILE, [c_double]),
    ("cadaclysm_blacksmith_profile_slot", _PROFILE, [c_double, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_profile_regular_polygon", _PROFILE, [c_double, c_double, c_double, c_uint32, c_double]),
    ("cadaclysm_blacksmith_profile_circumscribed_polygon", _PROFILE, [c_double, c_double, c_double, c_uint32, c_double]),
    ("cadaclysm_blacksmith_profile_star", _PROFILE, [c_double, c_double, c_double, c_double, c_uint32, c_double]),
    ("cadaclysm_blacksmith_profile_spline", _PROFILE, [_D, c_size_t, c_uint32, _D, c_bool]),
    ("cadaclysm_blacksmith_profile_polygon", _PROFILE, [_D, c_size_t]),
    ("cadaclysm_blacksmith_profile_with_hole", _PROFILE, [_PROFILE, _PROFILE]),
    ("cadaclysm_blacksmith_profile_hits", _HITS, [_PROFILE, _PROFILE, c_double]),
    ("cadaclysm_blacksmith_hits_free", None, [_HITS]),
    ("cadaclysm_blacksmith_hit_count", c_uint32, [_HITS]),
    ("cadaclysm_blacksmith_hit", c_bool, [_HITS, c_uint32, POINTER(_Hit)]),
    ("cadaclysm_blacksmith_solid_profile_hits", _HITS, [_SOLID, _PROFILE, _D, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_hits_piece_count", c_uint32, [_HITS]),
    ("cadaclysm_blacksmith_hits_piece", c_bool, [_HITS, c_uint32, POINTER(c_bool), POINTER(_Spot), POINTER(_Spot)]),
    ("cadaclysm_blacksmith_hits_piece_profile", _PROFILE, [_HITS, c_uint32]),
    ("cadaclysm_blacksmith_profile_common", _PROFILE_LIST, [_PROFILE, _PROFILE, c_double]),
    ("cadaclysm_blacksmith_profile_text", _PROFILE_LIST, [c_char_p, c_double, c_char_p, POINTER(c_uint8), c_size_t, c_char_p, c_char_p, c_double, c_char_p]),
    ("cadaclysm_blacksmith_profile_list_count", c_uint32, [_PROFILE_LIST]),
    ("cadaclysm_blacksmith_profile_list_get", _PROFILE, [_PROFILE_LIST, c_uint32]),
    ("cadaclysm_blacksmith_profile_list_free", None, [_PROFILE_LIST]),
    ("cadaclysm_blacksmith_translate_profile", _PROFILE, [_PROFILE, c_double, c_double]),
    ("cadaclysm_blacksmith_profile_rotate", _PROFILE, [_PROFILE, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_profile_scale", _PROFILE, [_PROFILE, c_double, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_profile_mirror", _PROFILE, [_PROFILE, c_double, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_profile_transform2d", _PROFILE, [_PROFILE, _D]),
    ("cadaclysm_blacksmith_profile_round", _PROFILE, [_PROFILE, c_double, _U, c_size_t, c_bool]),
    ("cadaclysm_blacksmith_profile_chain", _PROFILE, [POINTER(c_void_p), c_size_t, c_double]),
    ("cadaclysm_blacksmith_profile_from_loops", _PROFILE, [POINTER(c_void_p), c_size_t]),
    ("cadaclysm_blacksmith_profile_close_loop", _PROFILE, [_PROFILE]),
    ("cadaclysm_blacksmith_profile_polyline", _PROFILE, [_D, c_size_t, c_bool]),
    ("cadaclysm_blacksmith_profile_arc", _PROFILE, [c_double, c_double, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_profile_arc_through", _PROFILE, [c_double, c_double, c_double, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_profile_ellipse", _PROFILE, [c_double, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_profile_from_beziers", _PROFILE, [_D, c_size_t, c_bool]),
    ("cadaclysm_blacksmith_profile_bezier_count", c_uint32, [_PROFILE]),
    ("cadaclysm_blacksmith_profile_beziers", c_bool, [_PROFILE, _D, _D]),
    ("cadaclysm_blacksmith_profile_loops", c_bool, [POINTER(c_void_p), c_size_t, c_double, _U]),
    ("cadaclysm_blacksmith_profile_chain_order", c_bool, [POINTER(c_void_p), c_size_t, c_double, _U]),
    ("cadaclysm_blacksmith_profile_piece_count", c_uint32, [_PROFILE, POINTER(c_void_p), c_size_t, c_double]),
    ("cadaclysm_blacksmith_profile_piece", _PROFILE, [_PROFILE, POINTER(c_void_p), c_size_t, c_uint32, c_double]),
    ("cadaclysm_blacksmith_profile_trim_count", c_uint32, [_PROFILE, POINTER(c_void_p), c_size_t, c_uint32, c_double]),
    ("cadaclysm_blacksmith_profile_trim_chain", _PROFILE, [_PROFILE, POINTER(c_void_p), c_size_t, c_uint32, c_uint32, c_double]),
    ("cadaclysm_blacksmith_profile_polylines", _Polylines, [_PROFILE, c_double]),
    ("cadaclysm_blacksmith_path_begin", _PATH, [c_double, c_double]),
    ("cadaclysm_blacksmith_path_line_to", c_bool, [_PATH, c_double, c_double]),
    ("cadaclysm_blacksmith_path_arc_to", c_bool, [_PATH, c_double, c_double, c_double, c_double, c_bool]),
    ("cadaclysm_blacksmith_path_bezier_to", c_bool, [_PATH] + [c_double] * 6),
    ("cadaclysm_blacksmith_path_nurbs_to", c_bool, [_PATH, _D, c_size_t, _D, _D, c_size_t, c_uint32]),
    ("cadaclysm_blacksmith_path_conic_to", c_bool, [_PATH] + [c_double] * 5),
    ("cadaclysm_blacksmith_path_parabola_by_vertex", c_bool, [_PATH] + [c_double] * 4),
    ("cadaclysm_blacksmith_path_parabola_by_focus", c_bool, [_PATH] + [c_double] * 4),
    ("cadaclysm_blacksmith_path_parabola", _PATH, [c_double] * 7),
    ("cadaclysm_blacksmith_path_end", _PROFILE, [_PATH]),
    ("cadaclysm_blacksmith_path_end_open", _PROFILE, [_PATH]),
    ("cadaclysm_blacksmith_path_free", None, [_PATH]),
    ("cadaclysm_blacksmith_cuboid", _SOLID, [c_double] * 3),
    ("cadaclysm_blacksmith_cylinder", _SOLID, [c_double] * 2),
    ("cadaclysm_blacksmith_cone", _SOLID, [c_double] * 2),
    ("cadaclysm_blacksmith_sphere", _SOLID, [c_double]),
    ("cadaclysm_blacksmith_torus", _SOLID, [c_double] * 2),
    ("cadaclysm_blacksmith_wedge", _SOLID, [c_double] * 4),
    ("cadaclysm_blacksmith_pyramid", _SOLID, [c_uint32, c_double, c_double]),
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
    ("cadaclysm_blacksmith_scaled", _SOLID, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_rotate", _SOLID, [_SOLID, _D, c_double]),
    ("cadaclysm_blacksmith_mirror", _SOLID, [_SOLID, _D]),
    ("cadaclysm_blacksmith_solid_transform", _SOLID, [_SOLID, _D, _U]),
    ("cadaclysm_blacksmith_solid_convert_to_nurbs", _SOLID, [_SOLID, c_uint32, _U]),
    ("cadaclysm_blacksmith_join", _SOLID, [_SOLID, _SOLID, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_cut", _SOLID, [_SOLID, _SOLID, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_common", _SOLID, [_SOLID, _SOLID, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_split_sheet", _SOLID, [_SOLID, _SOLID, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_trim", _SOLID, [_SOLID, _SOLID, c_bool, c_double, _PROGRESS, c_void_p]),
    # a sheet trimmed by a curve on it, sheets joined: native only for now (see `Solid.trim_by_curve`).
    ("cadaclysm_blacksmith_split_by_curve", _SOLID, [_SOLID, _NURBS_CURVE, _D, c_double]),
    ("cadaclysm_blacksmith_split_along_curve", _SOLID, [_SOLID, _NURBS_CURVE, c_double]),
    ("cadaclysm_blacksmith_panel_gap", c_bool, [_SOLID, _NURBS_CURVE, c_double, c_double, c_double, POINTER(c_void_p)]),
    ("cadaclysm_blacksmith_trim_by_curve", _SOLID, [_SOLID, _NURBS_CURVE, _D, c_bool, c_double]),
    ("cadaclysm_blacksmith_flange", _SOLID, [_SOLID, _U, c_size_t, _NURBS_CURVE, c_double, c_bool, _D]),
    ("cadaclysm_blacksmith_extrude_to", _SOLID, [_SOLID, _U, c_size_t, _D, _SOLID, c_double, c_bool, _D]),
    ("cadaclysm_blacksmith_join_sheets", _SOLID, [POINTER(c_void_p), c_size_t, c_double, POINTER(_JoinReport)]),
    # an opening recessed into a sheet: the four face counts into the `uint32_t[4]`
    ("cadaclysm_blacksmith_recess", _SOLID, [_SOLID, _NURBS_CURVE, c_double, c_double, c_double, c_bool, c_double, _U]),
    # a symmetric body from one half: the report's seven figures into the `double[7]`
    ("cadaclysm_blacksmith_mirror_join", _SOLID, [_SOLID, _D, c_double, c_double, _D]),
    ("cadaclysm_blacksmith_pattern_rectangular", c_uint32, [_D, c_uint32, c_double, _D, c_uint32, c_double, c_bool, _U, c_uint32, _D]),
    ("cadaclysm_blacksmith_pattern_circular", c_uint32, [_D, c_uint32, c_double, c_bool, _U, c_uint32, _D]),
    ("cadaclysm_blacksmith_pattern_along", c_uint32, [_NURBS_CURVE, c_uint32, c_double, c_uint32, _U, c_uint32, _D]),
    ("cadaclysm_blacksmith_pattern", _SOLID, [_SOLID, _D, c_uint32, c_double, _D]),
    ("cadaclysm_blacksmith_pattern_feature", _SOLID, [_SOLID, _SOLID, c_uint32, _D, c_uint32, c_double, _D]),
    ("cadaclysm_blacksmith_hole", _SOLID, [_SOLID, _D, c_uint32, c_double, _D, c_uint32, c_double, c_double, c_uint32, c_uint32,
                                           c_double, c_double, c_double, c_double, _D, _D]),
    ("cadaclysm_blacksmith_hole_tool", _SOLID, [_SOLID, _D, c_uint32, c_double, _D, c_uint32, c_double, c_double, c_uint32, c_uint32,
                                                c_double, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_rib", _SOLID, [_SOLID, _NURBS_CURVE, _D, c_double, c_uint32, _D, c_double]),
    ("cadaclysm_blacksmith_rib_tool", _SOLID, [_SOLID, _NURBS_CURVE, _D, c_double, c_uint32, _D, c_double]),
    ("cadaclysm_blacksmith_web", _SOLID, [_SOLID, POINTER(_NURBS_CURVE), c_uint32, _D, c_double, c_uint32, c_double, c_bool, c_double]),
    ("cadaclysm_blacksmith_web_tool", _SOLID, [_SOLID, POINTER(_NURBS_CURVE), c_uint32, _D, c_double, c_uint32, c_double, c_bool, c_double]),
    ("cadaclysm_blacksmith_fillet", _SOLID, [_SOLID, _U, c_size_t, c_double, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_fillet_varying", _SOLID, [_SOLID, _U, c_size_t, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_fillet_each", _SOLID, [_SOLID, _U, _D, c_size_t, c_double]),
    ("cadaclysm_blacksmith_fillet_law", _SOLID, [_SOLID, _U, c_size_t, _D, _D, c_size_t, c_double]),
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
    ("cadaclysm_blacksmith_split_by_profile", _SOLID, [_SOLID, _PROFILE, _D, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_lump_count", c_uint32, [_SOLID]),
    ("cadaclysm_blacksmith_lump", _SOLID, [_SOLID, c_uint32]),
    ("cadaclysm_blacksmith_face_count", c_uint32, [_SOLID]),
    ("cadaclysm_blacksmith_select_face", c_uint32, [_SOLID, c_uint32, _D, c_uint32]),
    ("cadaclysm_blacksmith_face_frame", c_bool, [_SOLID, c_uint32, _D]),
    ("cadaclysm_blacksmith_mass_properties", c_bool, [_SOLID, c_double, POINTER(_MassProperties)]),
    # measurement beside the mass: points cross as `_D` of 3, answers into caller-owned structs
    ("cadaclysm_blacksmith_oriented_box", c_bool, [_SOLID, c_double, POINTER(_OrientedBox)]),
    ("cadaclysm_blacksmith_edge_length", c_bool, [_SOLID, c_uint32, c_double, POINTER(_Length)]),
    ("cadaclysm_blacksmith_profile_length", c_bool, [_PROFILE, c_double, POINTER(_Length)]),
    ("cadaclysm_blacksmith_edge_point_at_length", c_bool, [_SOLID, c_uint32, c_double, c_double, POINTER(_At)]),
    ("cadaclysm_blacksmith_edge_divide_by_count", _SAMPLES, [_SOLID, c_uint32, c_uint32, c_double]),
    ("cadaclysm_blacksmith_edge_divide_by_length", _SAMPLES, [_SOLID, c_uint32, c_double, c_double]),
    ("cadaclysm_blacksmith_profile_point_at_length", c_bool, [_PROFILE, c_double, c_double, POINTER(_At)]),
    ("cadaclysm_blacksmith_profile_divide_by_count", _SAMPLES, [_PROFILE, c_uint32, c_double]),
    ("cadaclysm_blacksmith_profile_divide_by_length", _SAMPLES, [_PROFILE, c_double, c_double]),
    ("cadaclysm_blacksmith_samples_count", c_uint32, [_SAMPLES]),
    ("cadaclysm_blacksmith_samples_at", c_bool, [_SAMPLES, c_uint32, POINTER(_At)]),
    ("cadaclysm_blacksmith_samples_free", None, [_SAMPLES]),
    # curves in space: an owned `CadaclysmBlacksmithNurbsCurve`, points as `_D` of 3 a point.
    # Native only for now: the web build has no exports for them (see `NurbsCurve`).
    ("cadaclysm_blacksmith_nurbs_curve_new", _NURBS_CURVE, [_D, c_size_t, _D, c_uint32, _D, c_size_t]),
    ("cadaclysm_blacksmith_nurbs_curve_through", _NURBS_CURVE, [_D, c_size_t, c_uint32, c_bool, _D, _D]),
    ("cadaclysm_blacksmith_nurbs_curve_fit", _NURBS_CURVE, [_D, c_size_t, c_uint32, c_double, _D]),
    # fairing and its checks
    ("cadaclysm_blacksmith_nurbs_curve_fair", _NURBS_CURVE, [_D, c_size_t, c_uint32, c_double, c_bool, c_double, c_double, _D]),
    ("cadaclysm_blacksmith_nurbs_curve_faired", _NURBS_CURVE, [_NURBS_CURVE, c_uint32, c_double, c_bool, c_double, c_double, _D]),
    ("cadaclysm_blacksmith_nurbs_curve_inflections", _SAMPLES, [_NURBS_CURVE]),
    ("cadaclysm_blacksmith_nurbs_curve_knot_continuity", c_bool, [_NURBS_CURVE, POINTER(_KnotContinuity)]),
    ("cadaclysm_blacksmith_nurbs_curve_from_edge", _NURBS_CURVE, [_SOLID, c_uint32]),
    ("cadaclysm_blacksmith_nurbs_curve_from_face_isocurve", _NURBS_CURVE, [_SOLID, c_uint32, c_bool, c_double]),
    ("cadaclysm_blacksmith_nurbs_curve_blend", _NURBS_CURVE, [_NURBS_CURVE, c_bool, _NURBS_CURVE, c_bool, c_uint32, c_double]),
    ("cadaclysm_blacksmith_nurbs_curve_projected_to_plane", _NURBS_CURVE, [_NURBS_CURVE, _D, _D, _D]),
    ("cadaclysm_blacksmith_nurbs_curve_projected_to_face", _NURBS_CURVE, [_NURBS_CURVE, _SOLID, c_uint32, _D, c_double, _D]),
    ("cadaclysm_blacksmith_nurbs_curve_pulled_to_face", _NURBS_CURVE, [_NURBS_CURVE, _SOLID, c_uint32, c_double, _D]),
    ("cadaclysm_blacksmith_nurbs_curve_offset_on_sheet", _NURBS_CURVE, [_NURBS_CURVE, _SOLID, c_double, c_double, _D]),
    ("cadaclysm_blacksmith_nurbs_curve_reversed", _NURBS_CURVE, [_NURBS_CURVE]),
    ("cadaclysm_blacksmith_nurbs_curve_trimmed", _NURBS_CURVE, [_NURBS_CURVE, c_double, c_double]),
    ("cadaclysm_blacksmith_nurbs_curve_extended", _NURBS_CURVE, [_NURBS_CURVE, c_bool, c_double]),
    ("cadaclysm_blacksmith_nurbs_curve_elevated", _NURBS_CURVE, [_NURBS_CURVE, c_uint32]),
    ("cadaclysm_blacksmith_nurbs_curve_joined", _NURBS_CURVE, [POINTER(_NURBS_CURVE), c_size_t, c_double]),
    ("cadaclysm_blacksmith_nurbs_curve_tween", c_bool, [_NURBS_CURVE, _NURBS_CURVE, c_uint32, c_uint32, c_uint32, c_bool, c_double,
                                                        POINTER(_NURBS_CURVE)]),
    ("cadaclysm_blacksmith_nurbs_curve_transformed", _NURBS_CURVE, [_NURBS_CURVE, _D]),
    ("cadaclysm_blacksmith_nurbs_curve_clone", _NURBS_CURVE, [_NURBS_CURVE]),
    ("cadaclysm_blacksmith_nurbs_curve_free", None, [_NURBS_CURVE]),
    ("cadaclysm_blacksmith_nurbs_curve_degree", c_uint32, [_NURBS_CURVE]),
    ("cadaclysm_blacksmith_nurbs_curve_control_count", c_uint32, [_NURBS_CURVE]),
    ("cadaclysm_blacksmith_nurbs_curve_knot_count", c_uint32, [_NURBS_CURVE]),
    ("cadaclysm_blacksmith_nurbs_curve_control_points", c_bool, [_NURBS_CURVE, _D]),
    ("cadaclysm_blacksmith_nurbs_curve_weights", c_bool, [_NURBS_CURVE, _D]),
    ("cadaclysm_blacksmith_nurbs_curve_knots", c_bool, [_NURBS_CURVE, _D]),
    ("cadaclysm_blacksmith_nurbs_curve_is_rational", c_bool, [_NURBS_CURVE]),
    ("cadaclysm_blacksmith_nurbs_curve_is_closed", c_bool, [_NURBS_CURVE]),
    ("cadaclysm_blacksmith_nurbs_curve_domain", c_bool, [_NURBS_CURVE, _D]),
    ("cadaclysm_blacksmith_nurbs_curve_point", c_bool, [_NURBS_CURVE, c_double, _D]),
    ("cadaclysm_blacksmith_nurbs_curve_derivatives", c_bool, [_NURBS_CURVE, c_double, c_uint32, _D]),
    ("cadaclysm_blacksmith_nurbs_curve_curvature", c_bool, [_NURBS_CURVE, c_double, POINTER(_Curvature)]),
    ("cadaclysm_blacksmith_nurbs_curve_length", c_bool, [_NURBS_CURVE, c_double, POINTER(_Length)]),
    ("cadaclysm_blacksmith_nurbs_curve_point_at_length", c_bool, [_NURBS_CURVE, c_double, c_double, POINTER(_At)]),
    ("cadaclysm_blacksmith_nurbs_curve_divide_by_count", _SAMPLES, [_NURBS_CURVE, c_uint32, c_double]),
    ("cadaclysm_blacksmith_nurbs_curve_divide_by_length", _SAMPLES, [_NURBS_CURVE, c_double, c_double]),
    ("cadaclysm_blacksmith_nurbs_curve_plane_hits", _SAMPLES, [_NURBS_CURVE, _D, _D]),
    ("cadaclysm_blacksmith_nurbs_curve_face_hits", _SAMPLES, [_NURBS_CURVE, _SOLID, c_uint32, c_double]),
    # surfaces from curves: sheets (open solids); curve arrays as `c_void_p * n`. Native only.
    ("cadaclysm_blacksmith_loft_curves", _SOLID, [POINTER(_NURBS_CURVE), c_size_t, c_uint32, c_bool, c_bool]),
    ("cadaclysm_blacksmith_sweep_rail", _SOLID, [_NURBS_CURVE, POINTER(_NURBS_CURVE), c_size_t, c_uint32, _D, c_double, _D]),
    ("cadaclysm_blacksmith_sweep_two_rails", _SOLID, [_NURBS_CURVE, _NURBS_CURVE, POINTER(_NURBS_CURVE), c_size_t, c_double, _D]),
    ("cadaclysm_blacksmith_edge_surface", _SOLID, [POINTER(_NURBS_CURVE), c_size_t, c_double, _D]),
    ("cadaclysm_blacksmith_network_surface", _SOLID, [POINTER(_NURBS_CURVE), c_size_t, POINTER(_NURBS_CURVE), c_size_t, c_double, _D]),
    # continuity between sheets' sides (a side 0 u0, 1 u1, 2 v0, 3 v1). Native only.
    ("cadaclysm_blacksmith_continuity", c_bool, [_SOLID, c_uint32, c_uint32, _SOLID, c_uint32, c_uint32, c_uint32, POINTER(_Continuity)]),
    # an edge's two faces
    ("cadaclysm_blacksmith_edge_continuity", c_bool, [_SOLID, c_uint32, c_uint32, POINTER(_Continuity)]),
    # fairing a sheet and the numbers that judge a surface: where its curvatures turn, how its
    # highlight lines kink across an edge
    ("cadaclysm_blacksmith_surface_faired", _SOLID, [_SOLID, c_uint32, c_double, c_uint32, c_uint32, c_uint32, POINTER(c_int32), c_uint32, _D]),
    ("cadaclysm_blacksmith_curvature_turns", c_bool, [_SOLID, c_uint32, c_uint32, POINTER(_CurvatureTurns)]),
    ("cadaclysm_blacksmith_curvature_turn_points", _SAMPLES, [_SOLID, c_uint32, c_uint32, c_bool]),
    ("cadaclysm_blacksmith_highlight_kink", c_bool, [_SOLID, c_uint32, c_uint32, POINTER(_HighlightKink)]),
    ("cadaclysm_blacksmith_match_side", _SOLID, [_SOLID, c_uint32, c_uint32, _SOLID, c_uint32, c_uint32, c_uint32]),
    ("cadaclysm_blacksmith_blend_sides", _SOLID, [_SOLID, c_uint32, c_uint32, _SOLID, c_uint32, c_uint32, c_uint32, c_double]),
    ("cadaclysm_blacksmith_n_sided_patch", _SOLID, [POINTER(_PatchBoundary), c_size_t, c_double, c_double, POINTER(_PatchReport)]),
    # surface fillets: the rails come back through out-pointers, owned. Native only.
    ("cadaclysm_blacksmith_fillet_surfaces", _SOLID, [_SOLID, c_uint32, _SOLID, c_uint32, c_double, c_double, c_bool, c_bool, c_double,
                                                      POINTER(_NURBS_CURVE), POINTER(_NURBS_CURVE), _D]),
    ("cadaclysm_blacksmith_classifier_new", _CLASSIFIER, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_classifier_contains", c_bool, [_CLASSIFIER, _D, _U]),
    ("cadaclysm_blacksmith_classifier_free", None, [_CLASSIFIER]),
    ("cadaclysm_blacksmith_contains", c_bool, [_SOLID, _D, c_double, _U]),
    ("cadaclysm_blacksmith_closest", c_bool, [_SOLID, _SOLID, c_double, _PROGRESS, c_void_p, POINTER(_Closest)]),
    # closest point from a point: 1 found, 0 beyond max_distance, -1 a refusal (test `< 0`)
    ("cadaclysm_blacksmith_closest_point", c_int32, [_SOLID, _D, c_double, c_double, POINTER(_PointFoot)]),
    ("cadaclysm_blacksmith_projector_new", _PROJECTOR, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_projector_closest_point", c_int32, [_PROJECTOR, _D, c_double, POINTER(_PointFoot)]),
    ("cadaclysm_blacksmith_projector_free", None, [_PROJECTOR]),
    ("cadaclysm_blacksmith_face_closest_point", c_int32, [_SOLID, c_uint32, _D, POINTER(_PointFoot)]),
    ("cadaclysm_blacksmith_edge_closest_point", c_int32, [_SOLID, c_uint32, _D, _D]),
    ("cadaclysm_blacksmith_nurbs_curve_closest_point", c_int32, [_NURBS_CURVE, _D, _D]),
    # closest points from a curve: 1 found, 0 beyond max_distance, -1 a refusal (test `< 0`)
    ("cadaclysm_blacksmith_nurbs_curve_closest_point_within", c_int32, [_NURBS_CURVE, _D, c_double, _D]),
    ("cadaclysm_blacksmith_nurbs_curve_closest_points", c_int32, [_NURBS_CURVE, _NURBS_CURVE, c_double, POINTER(_CurvePair)]),
    ("cadaclysm_blacksmith_curve_closest_points", c_int32, [_SOLID, _NURBS_CURVE, c_double, c_double, POINTER(_CurveBodyFoot)]),
    ("cadaclysm_blacksmith_projector_curve_closest_points", c_int32, [_PROJECTOR, _NURBS_CURVE, c_double, POINTER(_CurveBodyFoot)]),
    # kinds (0 solid, 1 curve, 2 point, 3 projector, 4 mesh) and their count, then each kind's array and count
    ("cadaclysm_blacksmith_nurbs_curve_closest_object", c_int32, [_NURBS_CURVE, POINTER(c_uint8), c_uint32,
                                                                  POINTER(c_void_p), c_uint32, POINTER(c_void_p), c_uint32,
                                                                  _D, c_uint32, POINTER(c_void_p), c_uint32,
                                                                  POINTER(c_void_p), c_uint32,
                                                                  c_double, c_double, POINTER(_NearestObject)]),
    # closest points against a triangle mesh: the handle, its counts and box, and the two queries
    # (1 found, 0 beyond max_distance, -1 a refusal: test `< 0`)
    ("cadaclysm_blacksmith_triangle_mesh_new", _TRIANGLE_MESH, [_D, c_uint32, POINTER(c_uint32), c_uint32]),
    ("cadaclysm_blacksmith_solid_triangle_mesh", _TRIANGLE_MESH, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_triangle_mesh_free", None, [_TRIANGLE_MESH]),
    ("cadaclysm_blacksmith_triangle_mesh_vertex_count", c_uint32, [_TRIANGLE_MESH]),
    ("cadaclysm_blacksmith_triangle_mesh_triangle_count", c_uint32, [_TRIANGLE_MESH]),
    ("cadaclysm_blacksmith_triangle_mesh_bounds", c_bool, [_TRIANGLE_MESH, _D]),
    ("cadaclysm_blacksmith_triangle_mesh_closest_point", c_int32, [_TRIANGLE_MESH, _D, c_double, POINTER(_MeshPoint)]),
    ("cadaclysm_blacksmith_triangle_mesh_curve_closest_points", c_int32, [_TRIANGLE_MESH, _NURBS_CURVE, c_double,
                                                                         POINTER(_CurveMeshFoot)]),
    ("cadaclysm_blacksmith_face_ref", c_bool, [_SOLID, c_uint32, _D]),
    ("cadaclysm_blacksmith_find_face", c_int32, [_SOLID, _D, c_int32, c_double]),
    # identity and attributes (plan C2): ids, origins, attributes, history, edge and vertex refs
    ("cadaclysm_blacksmith_solid_tracked", _SOLID, [_SOLID]),
    ("cadaclysm_blacksmith_solid_is_tracked", c_bool, [_SOLID]),
    ("cadaclysm_blacksmith_face_id", c_uint64, [_SOLID, c_uint32]),
    ("cadaclysm_blacksmith_face_with_id", c_uint32, [_SOLID, c_uint64]),
    ("cadaclysm_blacksmith_face_origin_count", c_uint32, [_SOLID, c_uint32]),
    ("cadaclysm_blacksmith_face_origin_at", c_bool, [_SOLID, c_uint32, c_uint32, _U, POINTER(c_uint64)]),
    ("cadaclysm_blacksmith_edge_id", c_uint64, [_SOLID, c_uint32]),
    ("cadaclysm_blacksmith_edge_with_id", c_uint32, [_SOLID, c_uint64]),
    ("cadaclysm_blacksmith_edge_origin_count", c_uint32, [_SOLID, c_uint32]),
    ("cadaclysm_blacksmith_edge_origin_at", c_bool, [_SOLID, c_uint32, c_uint32, _U, POINTER(c_uint64)]),
    ("cadaclysm_blacksmith_origins_through", _SOLID, [_SOLID, _SOLID]),
    ("cadaclysm_blacksmith_with_attribute", _SOLID, [_SOLID, c_char_p, c_char_p]),
    ("cadaclysm_blacksmith_without_attribute", _SOLID, [_SOLID, c_char_p]),
    ("cadaclysm_blacksmith_attribute", c_char_p, [_SOLID, c_char_p]),
    ("cadaclysm_blacksmith_attribute_count", c_uint32, [_SOLID]),
    ("cadaclysm_blacksmith_attribute_key_at", c_char_p, [_SOLID, c_uint32]),
    ("cadaclysm_blacksmith_attribute_value_at", c_char_p, [_SOLID, c_uint32]),
    ("cadaclysm_blacksmith_with_face_attribute", _SOLID, [_SOLID, c_uint32, c_char_p, c_char_p]),
    ("cadaclysm_blacksmith_without_face_attribute", _SOLID, [_SOLID, c_uint32, c_char_p]),
    ("cadaclysm_blacksmith_face_attribute", c_char_p, [_SOLID, c_uint32, c_char_p]),
    ("cadaclysm_blacksmith_face_attribute_count", c_uint32, [_SOLID, c_uint32]),
    ("cadaclysm_blacksmith_face_attribute_key_at", c_char_p, [_SOLID, c_uint32, c_uint32]),
    ("cadaclysm_blacksmith_face_attribute_value_at", c_char_p, [_SOLID, c_uint32, c_uint32]),
    ("cadaclysm_blacksmith_history", _HISTORY, [_SOLID, POINTER(c_void_p), c_size_t]),
    ("cadaclysm_blacksmith_edge_history", _HISTORY, [_SOLID, POINTER(c_void_p), c_size_t]),
    ("cadaclysm_blacksmith_history_free", None, [_HISTORY]),
    ("cadaclysm_blacksmith_history_kept_count", c_uint32, [_HISTORY]),
    ("cadaclysm_blacksmith_history_kept_at", c_bool, [_HISTORY, c_uint32, _U, POINTER(c_uint64), POINTER(c_uint64)]),
    ("cadaclysm_blacksmith_history_modified_count", c_uint32, [_HISTORY]),
    ("cadaclysm_blacksmith_history_modified_at", c_bool, [_HISTORY, c_uint32, _U, POINTER(c_uint64)]),
    ("cadaclysm_blacksmith_history_modified_output_count", c_uint32, [_HISTORY, c_uint32]),
    ("cadaclysm_blacksmith_history_modified_output_at", c_uint64, [_HISTORY, c_uint32, c_uint32]),
    ("cadaclysm_blacksmith_history_generated_count", c_uint32, [_HISTORY]),
    ("cadaclysm_blacksmith_history_generated_at", c_uint64, [_HISTORY, c_uint32]),
    ("cadaclysm_blacksmith_history_deleted_count", c_uint32, [_HISTORY]),
    ("cadaclysm_blacksmith_history_deleted_at", c_bool, [_HISTORY, c_uint32, _U, POINTER(c_uint64)]),
    ("cadaclysm_blacksmith_edge_ref", c_bool, [_SOLID, c_uint32, _D]),
    ("cadaclysm_blacksmith_find_edge", c_int32, [_SOLID, _D, c_double]),
    ("cadaclysm_blacksmith_vertex_count", c_uint32, [_SOLID]),
    ("cadaclysm_blacksmith_vertex_ref", c_bool, [_SOLID, c_uint32, _D]),
    ("cadaclysm_blacksmith_find_vertex", c_int32, [_SOLID, _D, c_double]),
    ("cadaclysm_blacksmith_frame_midplane", c_bool, [_D, _D, _D]),
    ("cadaclysm_blacksmith_frame_through", c_bool, [_D, _D, _D, _D]),
    ("cadaclysm_blacksmith_transform_translation", c_bool, [_D, _D]),
    ("cadaclysm_blacksmith_transform_rotation", c_bool, [_D, c_double, _D]),
    ("cadaclysm_blacksmith_transform_mirror", c_bool, [_D, _D]),
    ("cadaclysm_blacksmith_transform_scale", c_bool, [_D, c_double, _D]),
    ("cadaclysm_blacksmith_transform_scale_xyz", c_bool, [_D, c_double, c_double, c_double, _D]),
    ("cadaclysm_blacksmith_transform_shear", c_bool, [_D, _D, c_double, _D]),
    ("cadaclysm_blacksmith_transform_plane_to_plane", c_bool, [_D, _D, _D]),
    ("cadaclysm_blacksmith_transform_change_basis", c_bool, [_D, _D, _D]),
    ("cadaclysm_blacksmith_transform_planar_projection", c_bool, [_D, _D]),
    ("cadaclysm_blacksmith_transform_project_along", c_bool, [_D, _D, _D]),
    ("cadaclysm_blacksmith_transform_compose", c_bool, [_D, _D, _D]),
    ("cadaclysm_blacksmith_transform_inverse", c_bool, [_D, _D]),
    ("cadaclysm_blacksmith_transform_is_rigid", c_uint32, [_D, c_double]),
    ("cadaclysm_blacksmith_transform_is_similarity", c_double, [_D, c_double]),
    ("cadaclysm_blacksmith_transform_decompose_rigid", c_bool, [_D, c_double, _D]),
    ("cadaclysm_blacksmith_transform_decompose_similarity", c_bool, [_D, c_double, _D]),
    ("cadaclysm_blacksmith_transform_decompose_affine", c_bool, [_D, _D]),
    ("cadaclysm_blacksmith_quaternion_from_axis_angle", c_bool, [_D, c_double, _D]),
    ("cadaclysm_blacksmith_quaternion_from_transform", c_bool, [_D, _D]),
    ("cadaclysm_blacksmith_quaternion_to_transform", c_bool, [_D, _D, _D]),
    ("cadaclysm_blacksmith_quaternion_slerp", c_bool, [_D, _D, c_double, _D]),
    # value geometry: a value is a flat array of doubles tagged by its kind (CADACLYSM_BLACKSMITH_VALUE_*)
    ("cadaclysm_blacksmith_value_size", c_uint32, [c_uint32]),
    ("cadaclysm_blacksmith_value_check", c_bool, [c_uint32, _D, _D]),
    ("cadaclysm_blacksmith_value_bounds", c_bool, [c_uint32, _D, _D]),
    ("cadaclysm_blacksmith_value_transform", c_bool, [c_uint32, _D, _D, _D]),
    ("cadaclysm_blacksmith_curve_value_point_at", c_bool, [c_uint32, _D, c_double, _D]),
    ("cadaclysm_blacksmith_curve_value_tangent_at", c_bool, [c_uint32, _D, c_double, _D]),
    ("cadaclysm_blacksmith_curve_value_length", c_bool, [c_uint32, _D, _D]),
    ("cadaclysm_blacksmith_curve_value_closest_point", c_bool, [c_uint32, _D, _D, _D]),
    ("cadaclysm_blacksmith_curve_value_to_nurbs", _NURBS_CURVE, [c_uint32, _D]),   # native only
    ("cadaclysm_blacksmith_circle_through", c_bool, [_D, _D, _D, _D]),
    ("cadaclysm_blacksmith_arc_through", c_bool, [_D, _D, _D, _D]),
    ("cadaclysm_blacksmith_arc_from_start_tangent_end", c_bool, [_D, _D, _D, _D]),
    ("cadaclysm_blacksmith_ellipse_from_circle", c_bool, [_D, _D]),
    ("cadaclysm_blacksmith_surface_value_point_at", c_bool, [c_uint32, _D, c_double, c_double, _D]),
    ("cadaclysm_blacksmith_surface_value_normal_at", c_bool, [c_uint32, _D, c_double, c_double, _D]),
    ("cadaclysm_blacksmith_surface_value_closest_point", c_bool, [c_uint32, _D, _D, _D]),
    ("cadaclysm_blacksmith_surface_value_domain", c_bool, [c_uint32, _D, _D]),
    ("cadaclysm_blacksmith_surface_value_nurbs_sheet", _SOLID, [c_uint32, _D]),
    ("cadaclysm_blacksmith_solid_value_contains", c_uint32, [c_uint32, _D, _D, c_double]),
    ("cadaclysm_blacksmith_solid_value_area", c_bool, [c_uint32, _D, _D]),
    ("cadaclysm_blacksmith_solid_value_volume", c_bool, [c_uint32, _D, _D]),
    ("cadaclysm_blacksmith_solid_value_to_solid", _SOLID, [c_uint32, _D]),
    ("cadaclysm_blacksmith_cuboid_from_bounds", c_bool, [_D, _D, _D]),
    ("cadaclysm_blacksmith_cuboid_around", c_bool, [_D, _D, c_size_t, _D]),
    ("cadaclysm_blacksmith_cuboid_corners", c_bool, [_D, _D]),
    ("cadaclysm_blacksmith_cuboid_point_at", c_bool, [_D, c_double, c_double, c_double, _D]),
    ("cadaclysm_blacksmith_cuboid_closest_point", c_bool, [_D, _D, _D]),
    ("cadaclysm_blacksmith_frame_fit", c_bool, [_D, c_size_t, _D, _D]),
    ("cadaclysm_blacksmith_rectangle_corners", c_bool, [_D, _D]),
    ("cadaclysm_blacksmith_rectangle_area", c_bool, [_D, _D]),
    ("cadaclysm_blacksmith_rectangle_closest_point", c_bool, [_D, _D, c_bool, _D]),
    ("cadaclysm_blacksmith_rectangle_contains", c_uint32, [_D, _D, c_double]),
    ("cadaclysm_blacksmith_rectangle_to_sheet", _SOLID, [_D]),
    ("cadaclysm_blacksmith_triangle_area", c_bool, [_D, _D]),
    ("cadaclysm_blacksmith_triangle_perimeter", c_bool, [_D, _D]),
    ("cadaclysm_blacksmith_triangle_centroid", c_bool, [_D, _D]),
    ("cadaclysm_blacksmith_triangle_circumcircle", c_bool, [_D, _D]),
    ("cadaclysm_blacksmith_triangle_point_at", c_bool, [_D, c_double, c_double, c_double, _D]),
    ("cadaclysm_blacksmith_triangle_barycentric", c_bool, [_D, _D, _D]),
    ("cadaclysm_blacksmith_triangle_closest_point", c_bool, [_D, _D, _D]),
    ("cadaclysm_blacksmith_triangle_edge", c_bool, [_D, c_uint32, _D]),
    ("cadaclysm_blacksmith_triangle_to_sheet", _SOLID, [_D]),
    ("cadaclysm_blacksmith_ray_point_at", c_bool, [_D, c_double, _D]),
    ("cadaclysm_blacksmith_ray_closest_point", c_bool, [_D, _D, _D]),
    ("cadaclysm_blacksmith_coloured", _SOLID, [_SOLID, c_uint32, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_colour", c_bool, [_SOLID, c_uint32, _D]),
    ("cadaclysm_blacksmith_parse_colour", c_bool, [c_char_p, _D]),
    ("cadaclysm_blacksmith_option_set", c_bool, [c_char_p, c_double]),
    ("cadaclysm_blacksmith_option_get", c_bool, [c_char_p, POINTER(c_double)]),
    ("cadaclysm_blacksmith_profile_coloured", _PROFILE, [_PROFILE, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_profile_colour", c_bool, [_PROFILE, _D]),
    ("cadaclysm_blacksmith_edges_coloured", _SOLID, [_SOLID, _U, c_size_t, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_edge_colour", c_bool, [_SOLID, c_uint32, _D]),
    ("cadaclysm_blacksmith_edge_polyline_colours", _Colours, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_face_kind", c_char_p, [_SOLID, c_uint32]),
    ("cadaclysm_blacksmith_edge_count", c_uint32, [_SOLID]),
    ("cadaclysm_blacksmith_edge", c_bool, [_SOLID, c_uint32, POINTER(_Edge)]),
    ("cadaclysm_blacksmith_edge_curve", c_bool, [_SOLID, c_uint32, POINTER(_Curve)]),
    ("cadaclysm_blacksmith_intersect", _INTERSECTION, [_SOLID, _SOLID, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_self_intersect", _INTERSECTION, [_SOLID, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_intersection_free", None, [_INTERSECTION]),
    ("cadaclysm_blacksmith_intersection_chain_count", c_uint32, [_INTERSECTION]),
    ("cadaclysm_blacksmith_intersection_chain", c_bool, [_INTERSECTION, c_uint32, POINTER(_Chain)]),
    ("cadaclysm_blacksmith_intersection_curve", c_bool, [_INTERSECTION, c_uint32, POINTER(_Curve)]),
    ("cadaclysm_blacksmith_intersection_overlap_count", c_uint32, [_INTERSECTION]),
    ("cadaclysm_blacksmith_intersection_overlap", c_bool, [_INTERSECTION, c_uint32, POINTER(_Overlap)]),
    ("cadaclysm_blacksmith_check", _CHECK, [_SOLID, _SOLID, c_char_p, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_check_free", None, [_CHECK]),
    ("cadaclysm_blacksmith_check_count", c_uint32, [_CHECK]),
    ("cadaclysm_blacksmith_check_finding", c_bool, [_CHECK, c_uint32, POINTER(_Finding)]),
    # The collider: `_D`/`_D` for a `Box` in and out of `box_moved`/`box_overlaps`/
    # `boxes_apart` -- six contiguous doubles, bit-compatible with `CadaclysmBlacksmithBox`
    # (see `_box_words`) -- and `POINTER(_Box)` only where the C ABI writes one out.
    ("cadaclysm_blacksmith_solid_bounds_box", c_bool, [_SOLID, c_double, POINTER(_Box)]),
    ("cadaclysm_blacksmith_box_moved", c_bool, [_D, _D, POINTER(_Box)]),
    ("cadaclysm_blacksmith_box_overlaps", c_bool, [_D, _D]),
    ("cadaclysm_blacksmith_boxes_apart", c_bool, [_D, _D, _D, _D, POINTER(c_bool)]),
    ("cadaclysm_blacksmith_collider_new", _COLLIDER, [POINTER(c_void_p), c_uint32, c_double, _U, _U, c_uint32]),
    ("cadaclysm_blacksmith_collider_free", None, [_COLLIDER]),
    ("cadaclysm_blacksmith_collider_group_count", c_uint32, [_COLLIDER]),
    ("cadaclysm_blacksmith_collider_stats", c_bool, [_COLLIDER, POINTER(_ColliderStats)]),
    ("cadaclysm_blacksmith_collider_check", _COLLISIONS, [_COLLIDER, _D, c_uint32, c_uint32, c_uint32]),
    ("cadaclysm_blacksmith_collisions_free", None, [_COLLISIONS]),
    ("cadaclysm_blacksmith_collider_clash", _CLASHES, [_COLLIDER, _D, c_uint32, c_double, c_uint32, c_uint32]),
    ("cadaclysm_blacksmith_clash", _CLASHES, [POINTER(c_void_p), c_uint32, POINTER(c_void_p), c_uint32, c_double, c_double, _U, c_uint32]),
    ("cadaclysm_blacksmith_clashes_free", None, [_CLASHES]),
    ("cadaclysm_blacksmith_clashes_count", c_uint32, [_CLASHES]),
    ("cadaclysm_blacksmith_clashes_at", c_bool, [_CLASHES, c_uint32, POINTER(_Clash)]),
    ("cadaclysm_blacksmith_clashes_solid", _SOLID, [_CLASHES, c_uint32]),
    ("cadaclysm_blacksmith_clashes_intersect", _INTERSECTION, [_CLASHES, c_uint32]),
    ("cadaclysm_blacksmith_collider_swept_clash", _SWEPT_CLASHES, [_COLLIDER, _D, c_uint32, c_uint32, c_double, c_double, c_uint32, c_uint32, c_uint32]),
    ("cadaclysm_blacksmith_swept_clash", _SWEPT_CLASHES, [POINTER(c_void_p), c_uint32, _D, POINTER(c_void_p), c_uint32, _D, c_uint32, c_double, c_double, c_double, c_uint32, _U, c_uint32]),
    ("cadaclysm_blacksmith_swept_clashes_free", None, [_SWEPT_CLASHES]),
    ("cadaclysm_blacksmith_swept_clashes_count", c_uint32, [_SWEPT_CLASHES]),
    ("cadaclysm_blacksmith_swept_clashes_at", c_bool, [_SWEPT_CLASHES, c_uint32, POINTER(_SweptClash)]),
    ("cadaclysm_blacksmith_swept_clashes_interval", c_bool, [_SWEPT_CLASHES, c_uint32, c_uint32, _D]),
    ("cadaclysm_blacksmith_swept_clashes_firsts", _CLASHES, [_SWEPT_CLASHES]),
    # Wall thickness: a gauge over solids, its readings as list handles copied out and freed
    # at once, and `mesh_thickness` over plain meshes laid end to end.
    ("cadaclysm_blacksmith_thickness_gauge_new", _THICKNESS_GAUGE, [POINTER(c_void_p), c_uint32, c_double]),
    ("cadaclysm_blacksmith_thickness_gauge_free", None, [_THICKNESS_GAUGE]),
    ("cadaclysm_blacksmith_thickness_gauge_body_count", c_uint32, [_THICKNESS_GAUGE]),
    ("cadaclysm_blacksmith_thickness_gauge_tolerance", c_double, [_THICKNESS_GAUGE]),
    ("cadaclysm_blacksmith_thickness_gauge_mesh", c_bool, [_THICKNESS_GAUGE, c_uint32, POINTER(_ThicknessMesh)]),
    ("cadaclysm_blacksmith_thickness_gauge_measure", _THICKNESSES, [_THICKNESS_GAUGE, c_double, c_double]),
    ("cadaclysm_blacksmith_thickness_gauge_at", _THICKNESSES, [_THICKNESS_GAUGE, c_uint32, c_uint32, _D, c_double, c_double]),
    ("cadaclysm_blacksmith_thickness_gauge_face", c_bool, [_THICKNESS_GAUGE, c_uint32, c_uint32, _D, c_double, POINTER(_FaceThickness)]),
    ("cadaclysm_blacksmith_thicknesses_free", None, [_THICKNESSES]),
    ("cadaclysm_blacksmith_thicknesses_count", c_uint32, [_THICKNESSES]),
    ("cadaclysm_blacksmith_thicknesses_at", c_bool, [_THICKNESSES, c_uint32, POINTER(_Thickness)]),
    ("cadaclysm_blacksmith_mesh_thickness", _MESH_THICKNESSES, [_D, _U, _U, _U, c_uint32, c_double, c_double]),
    ("cadaclysm_blacksmith_mesh_thicknesses_free", None, [_MESH_THICKNESSES]),
    ("cadaclysm_blacksmith_mesh_thicknesses_count", c_uint32, [_MESH_THICKNESSES]),
    ("cadaclysm_blacksmith_mesh_thicknesses_at", c_bool, [_MESH_THICKNESSES, c_uint32, POINTER(_MeshThickness)]),
    ("cadaclysm_blacksmith_rtree_new", _RTREE, []),
    ("cadaclysm_blacksmith_rtree_from_boxes", _RTREE, [_U, _D, c_uint32]),
    ("cadaclysm_blacksmith_rtree_from_points", _RTREE, [_D, c_uint32]),
    ("cadaclysm_blacksmith_rtree_from_triangles", _RTREE, [_D, c_uint32, _U, c_uint32]),
    ("cadaclysm_blacksmith_solid_face_tree", _RTREE, [_SOLID]),
    ("cadaclysm_blacksmith_rtree_insert", c_bool, [_RTREE, c_uint32, _D]),
    ("cadaclysm_blacksmith_rtree_insert_point", c_bool, [_RTREE, c_uint32, _D]),
    ("cadaclysm_blacksmith_rtree_remove", c_bool, [_RTREE, c_uint32, _D]),
    ("cadaclysm_blacksmith_rtree_count", c_uint32, [_RTREE]),
    ("cadaclysm_blacksmith_rtree_bounds", c_bool, [_RTREE, _D]),
    ("cadaclysm_blacksmith_rtree_free", None, [_RTREE]),
    ("cadaclysm_blacksmith_rtree_search", _RTREE_HITS, [_RTREE, _D]),
    ("cadaclysm_blacksmith_rtree_within", _RTREE_HITS, [_RTREE, _D, c_double]),
    ("cadaclysm_blacksmith_rtree_nearest", _RTREE_HITS, [_RTREE, _D, c_uint32]),
    ("cadaclysm_blacksmith_rtree_ray", _RTREE_HITS, [_RTREE, _D, _D, c_double]),
    ("cadaclysm_blacksmith_rtree_hits_count", c_uint32, [_RTREE_HITS]),
    ("cadaclysm_blacksmith_rtree_hits_at", c_bool, [_RTREE_HITS, c_uint32, POINTER(_RTreeHit)]),
    ("cadaclysm_blacksmith_rtree_hits_free", None, [_RTREE_HITS]),
    ("cadaclysm_blacksmith_rtree_overlaps", _RTREE_PAIRS, [_RTREE, _RTREE, c_double]),
    ("cadaclysm_blacksmith_rtree_self_overlaps", _RTREE_PAIRS, [_RTREE, c_double]),
    ("cadaclysm_blacksmith_rtree_pairs_count", c_uint32, [_RTREE_PAIRS]),
    ("cadaclysm_blacksmith_rtree_pairs_at", c_bool, [_RTREE_PAIRS, c_uint32, POINTER(_RTreePair)]),
    ("cadaclysm_blacksmith_rtree_pairs_free", None, [_RTREE_PAIRS]),
    ("cadaclysm_blacksmith_merge", _SOLID, [_SOLID, _SOLID, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_regions", _REGIONS, [_SOLID]),
    ("cadaclysm_blacksmith_regions_count", c_uint32, [_REGIONS]),
    ("cadaclysm_blacksmith_regions_at", c_bool, [_REGIONS, c_uint32, POINTER(_Region)]),
    ("cadaclysm_blacksmith_regions_side_at", c_bool, [_REGIONS, c_uint32, c_uint32, POINTER(_FaceSide)]),
    ("cadaclysm_blacksmith_regions_free", None, [_REGIONS]),
    ("cadaclysm_blacksmith_region_solid", _SOLID, [_SOLID, c_uint32]),
    ("cadaclysm_blacksmith_interpolator_new", _INTERPOLATOR, [_D, c_uint32, c_uint32, c_bool]),
    ("cadaclysm_blacksmith_interpolator_count", c_uint32, [_INTERPOLATOR]),
    ("cadaclysm_blacksmith_interpolator_dimension", c_uint32, [_INTERPOLATOR]),
    ("cadaclysm_blacksmith_interpolator_cyclic", c_bool, [_INTERPOLATOR]),
    ("cadaclysm_blacksmith_interpolator_at", c_bool, [_INTERPOLATOR, c_double, c_uint32, _D, c_uint32]),
    ("cadaclysm_blacksmith_interpolator_sample", c_bool, [_INTERPOLATOR, _D, c_uint32, c_uint32, _D, c_uint32]),
    ("cadaclysm_blacksmith_interpolator_free", None, [_INTERPOLATOR]),
    ("cadaclysm_blacksmith_collisions_count", c_uint32, [_COLLISIONS]),
    ("cadaclysm_blacksmith_collisions_hit", c_bool, [_COLLISIONS, c_uint32, POINTER(_CollisionHit)]),
    ("cadaclysm_blacksmith_collisions_solid", _SOLID, [_COLLISIONS, c_uint32]),
    ("cadaclysm_blacksmith_mesh", _Mesh, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_mesh64", _Mesh64, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_mesh_face_triangles", _FaceTriangles, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_edge_polylines", _Polylines, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_tessellation", _TESSELLATION, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_tessellation_free", None, [_TESSELLATION]),
    ("cadaclysm_blacksmith_tessellation_mesh", _Mesh, [_TESSELLATION]),
    ("cadaclysm_blacksmith_tessellation_mesh64", _Mesh64, [_TESSELLATION]),
    ("cadaclysm_blacksmith_tessellation_face_triangles", _FaceTriangles, [_TESSELLATION]),
    ("cadaclysm_blacksmith_tessellation_edge_polylines", _Polylines, [_TESSELLATION]),
    ("cadaclysm_blacksmith_bounds", c_bool, [_SOLID, c_double, _D, _D]),
    ("cadaclysm_blacksmith_bounds64", c_bool, [_SOLID, c_double, _D, _D]),
    ("cadaclysm_blacksmith_box", c_bool, [_SOLID, _D, _D]),
    ("cadaclysm_blacksmith_leaked_edges", c_uint32, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_unpaired_edges", c_uint32, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_manifold", c_bool, [_SOLID, _U]),
    ("cadaclysm_blacksmith_face_round_radius", c_double, [_SOLID, c_uint32]),
    ("cadaclysm_blacksmith_face_chamfer_distance", c_double, [_SOLID, c_uint32]),
    ("cadaclysm_blacksmith_edge_bezier_count", c_uint32, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_edge_beziers", c_bool, [_SOLID, c_double, _D]),
    ("cadaclysm_blacksmith_isocurve_bezier_count", c_uint32, [_SOLID, c_uint32, c_double]),
    ("cadaclysm_blacksmith_isocurve_beziers", c_bool, [_SOLID, c_uint32, c_double, _D]),
    ("cadaclysm_blacksmith_mesh_file", c_void_p, [POINTER(c_void_p), c_size_t, c_char_p, POINTER(c_char_p), _D, c_double, POINTER(c_size_t)]),
    ("cadaclysm_blacksmith_step", c_void_p, [POINTER(c_void_p), c_size_t, c_char_p, c_uint32]),
    ("cadaclysm_blacksmith_step_assembly", c_void_p, [POINTER(c_void_p), POINTER(c_char_p), c_size_t, POINTER(c_uint32), POINTER(c_double), c_size_t, c_char_p, c_uint32]),
    ("cadaclysm_blacksmith_sat_text", c_void_p, [POINTER(c_void_p), c_size_t, c_uint32]),
    ("cadaclysm_blacksmith_sat", c_bool, [POINTER(c_void_p), c_size_t, c_char_p, c_uint32]),
    ("cadaclysm_blacksmith_3dm_bytes", c_void_p, [POINTER(c_void_p), c_size_t, c_uint32, POINTER(c_size_t)]),
    ("cadaclysm_blacksmith_3dm", c_bool, [POINTER(c_void_p), c_size_t, c_char_p, c_uint32]),
    ("cadaclysm_blacksmith_bytes_free", None, [c_void_p, c_size_t]),
    ("cadaclysm_blacksmith_svg_options_init", None, [POINTER(_SvgOptions)]),
    ("cadaclysm_blacksmith_svg_text", c_void_p, [POINTER(c_void_p), c_size_t, POINTER(_SvgOptions)]),
    ("cadaclysm_blacksmith_svg", c_bool, [POINTER(c_void_p), c_size_t, c_char_p, POINTER(_SvgOptions)]),
    ("cadaclysm_blacksmith_silhouette_beziers", POINTER(c_double), [_SOLID, POINTER(_SvgOptions), POINTER(c_uint32)]),
    ("cadaclysm_blacksmith_silhouette_beziers_free", None, [POINTER(c_double), c_uint32]),
    ("cadaclysm_blacksmith_drawing_svg_text", c_void_p, [POINTER(c_void_p), c_size_t, POINTER(c_void_p), c_size_t, POINTER(_SvgOptions)]),
    ("cadaclysm_blacksmith_drawing_svg", c_bool, [POINTER(c_void_p), c_size_t, POINTER(c_void_p), c_size_t, c_char_p, POINTER(_SvgOptions)]),
    ("cadaclysm_blacksmith_brep_text", c_void_p, [POINTER(c_void_p), c_size_t]),
    ("cadaclysm_blacksmith_brep", c_bool, [POINTER(c_void_p), c_size_t, c_char_p]),
    ("cadaclysm_blacksmith_string_free", None, [c_void_p]),
    # Mechanical drawings, stages 1 and 2 (docs/superpowers/plans/2026-11-12-mechanical-drawings-abi-python.md):
    # hidden-line removal, the projected outline, the page and DXF profiles. Native only for now:
    # each method refuses under Pyodide in words (`_native`) until the web build exports them.
    ("cadaclysm_blacksmith_hlr_options_init", None, [POINTER(_HlrOptions)]),
    ("cadaclysm_blacksmith_hlr", _HLR, [POINTER(c_void_p), c_size_t, POINTER(_HlrOptions)]),
    ("cadaclysm_blacksmith_hlr_mesh", _HLR, [POINTER(c_void_p), c_size_t, POINTER(_HlrOptions)]),
    ("cadaclysm_blacksmith_hlr_line_count", c_uint32, [_HLR]),
    ("cadaclysm_blacksmith_hlr_line", c_bool, [_HLR, c_uint32, POINTER(_HlrLine)]),
    ("cadaclysm_blacksmith_hlr_line_beziers2d", c_bool, [_HLR, c_uint32, _D]),
    ("cadaclysm_blacksmith_hlr_line_beziers3d", c_bool, [_HLR, c_uint32, _D]),
    ("cadaclysm_blacksmith_hlr_report", c_bool, [_HLR, POINTER(_HlrReport)]),
    ("cadaclysm_blacksmith_hlr_free", None, [_HLR]),
    ("cadaclysm_blacksmith_projected_outline", _PROFILE_LIST, [POINTER(c_void_p), c_size_t, POINTER(_HlrOptions)]),
    ("cadaclysm_blacksmith_page_new", _PAGE, [c_uint32]),
    ("cadaclysm_blacksmith_page_add_view", c_bool, [_PAGE, _HLR, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_page_add_profile", c_bool, [_PAGE, _PROFILE, c_char_p, c_double, c_double]),
    ("cadaclysm_blacksmith_page_add_hatch", c_bool, [_PAGE, _PROFILE, c_char_p, c_char_p, c_double, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_page_add_text", c_bool, [_PAGE, c_char_p, c_char_p, c_double, c_double, c_double, c_double, c_char_p, c_char_p]),
    ("cadaclysm_blacksmith_page_entity_count", c_uint32, [_PAGE]),
    ("cadaclysm_blacksmith_page_svg_text", c_void_p, [_PAGE]),
    ("cadaclysm_blacksmith_page_dxf_text", c_void_p, [_PAGE]),
    ("cadaclysm_blacksmith_page_free", None, [_PAGE]),
    ("cadaclysm_blacksmith_dxf_profiles", _PROFILE_LIST, [c_char_p, c_double]),
    ("cadaclysm_blacksmith_from_brep", _SOLID, [c_void_p, c_char_p]),
    ("cadaclysm_blacksmith_brep_layout_id", c_char_p, []),
    ("cadaclysm_blacksmith_assembly_new", _ASSEMBLY, [c_char_p]),
    ("cadaclysm_blacksmith_assembly_free", None, [_ASSEMBLY]),
    ("cadaclysm_blacksmith_assembly_name", c_char_p, [_ASSEMBLY]),
    ("cadaclysm_blacksmith_assembly_place_solid", c_void_p, [_ASSEMBLY, _SOLID, _D, c_char_p]),
    ("cadaclysm_blacksmith_assembly_place_assembly", c_void_p, [_ASSEMBLY, _ASSEMBLY, _D, c_char_p]),
    ("cadaclysm_blacksmith_assembly_step", c_void_p, [_ASSEMBLY, c_char_p, c_uint32]),
    ("cadaclysm_blacksmith_assembly_3dm_bytes", c_void_p, [_ASSEMBLY, c_uint32, POINTER(c_size_t)]),
    ("cadaclysm_blacksmith_assembly_3dm", c_bool, [_ASSEMBLY, c_char_p, c_uint32]),
    ("cadaclysm_blacksmith_assembly_link", c_bool, [_ASSEMBLY, c_char_p, POINTER(c_char_p), c_size_t]),
    ("cadaclysm_blacksmith_assembly_joint", c_bool, [_ASSEMBLY, c_char_p, c_char_p, c_char_p]),
    ("cadaclysm_blacksmith_assembly_pair", c_bool,
     [_ASSEMBLY, c_char_p, c_char_p, _D, _D, _D, _D, POINTER(c_bool), POINTER(c_bool), c_size_t, c_double]),
    ("cadaclysm_blacksmith_assembly_pair_with", c_bool,
     [_ASSEMBLY, c_char_p, c_char_p, _D, _D, _D, _D, POINTER(c_bool), POINTER(c_bool), c_size_t, _D, c_size_t]),
    ("cadaclysm_blacksmith_assembly_state", c_bool, [_ASSEMBLY, c_char_p, POINTER(c_char_p), POINTER(c_uint32), _D, c_size_t]),
    ("cadaclysm_blacksmith_assembly_sequence", c_bool, [_ASSEMBLY, c_char_p, POINTER(c_char_p), POINTER(c_double), POINTER(c_char_p), c_size_t, c_bool]),
    ("cadaclysm_blacksmith_assembly_base", c_bool, [_ASSEMBLY, c_char_p]),
    ("cadaclysm_blacksmith_assembly_posed", _ASSEMBLY, [_ASSEMBLY, POINTER(c_char_p), POINTER(c_uint32), _D, c_size_t, c_char_p, c_char_p]),
    # An assembly's parts by placement path (each path **owned**: `c_void_p`, then
    # `string_free`), and its own mechanism swept along joint keyframes into plan 2a's swept
    # clashes list. The wasm has one `assembly_parts` call for the first two (`Assembly.parts`).
    ("cadaclysm_blacksmith_assembly_part_count", c_uint32, [_ASSEMBLY]),
    ("cadaclysm_blacksmith_assembly_part_path", c_void_p, [_ASSEMBLY, c_uint32]),
    ("cadaclysm_blacksmith_assembly_swept_clash", _SWEPT_CLASHES,
     [_ASSEMBLY, POINTER(c_char_p), POINTER(c_uint32), c_size_t, _D, c_uint32, c_char_p, c_double, c_double, c_double,
      c_uint32, _U, c_uint32, c_bool]),
    ("cadaclysm_blacksmith_pair_freedom_count", c_uint32, [c_char_p]),
    # The FEM surface mesh: one handle per meshed solid, freed by the caller. Its
    # `.msh` text is **owned** (`c_void_p`, then `string_free`), as every other text
    # this library hands over -- unlike the reader library's, which borrows from a
    # slot on its own handle. See `FemMesh.msh_text`.
    ("cadaclysm_blacksmith_fem_options_init", None, [POINTER(_FemOptions)]),
    ("cadaclysm_blacksmith_fem_mesh", _FEM, [_SOLID, _D, POINTER(_FemOptions), _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_fem_mesh_free", None, [_FEM]),
    ("cadaclysm_blacksmith_fem_mesh_view", c_bool, [_FEM, POINTER(_FemMeshView)]),
    ("cadaclysm_blacksmith_fem_mesh_edge", c_bool, [_FEM, c_uint32, POINTER(_FemEdge)]),
    ("cadaclysm_blacksmith_fem_mesh_vertex", c_bool, [_FEM, c_uint32, POINTER(_FemVertex)]),
    ("cadaclysm_blacksmith_fem_mesh_open_edge", c_bool, [_FEM, c_uint32, _U, _U, _U]),
    ("cadaclysm_blacksmith_fem_mesh_folded_edge", c_bool, [_FEM, c_uint32, _U, _U, _U]),
    ("cadaclysm_blacksmith_fem_mesh_crossing_count", c_uint32, [_FEM]),
    ("cadaclysm_blacksmith_fem_mesh_crossing", c_bool, [_FEM, c_uint32, _U, _U]),
    ("cadaclysm_blacksmith_fem_mesh_msh_text", c_void_p, [_FEM]),
    ("cadaclysm_blacksmith_fem_mesh_save_msh", c_bool, [_FEM, c_char_p]),
    # machining: the kernel's lines-and-arcs verbs, then Tool, Stock, Job and the
    # program list a job writes
    ("cadaclysm_blacksmith_profile_to_arcs", _PROFILE, [_PROFILE, c_double]),
    ("cadaclysm_blacksmith_profile_offset", _PROFILE_LIST, [_PROFILE, c_double, c_double]),
    ("cadaclysm_blacksmith_solid_section", _PROFILE_LIST, [_SOLID, c_double, c_double]),
    ("cadaclysm_blacksmith_tool_flat", _TOOL, [c_uint32, c_double, c_double, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_tool_ball", _TOOL, [c_uint32, c_double, c_double, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_tool_drill", _TOOL, [c_uint32, c_double, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_tool_with_ramp_angle", _TOOL, [_TOOL, c_double]),
    ("cadaclysm_blacksmith_tool_free", None, [_TOOL]),
    ("cadaclysm_blacksmith_stock_box", _STOCK, [c_double, c_double, c_double, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_stock_around", _STOCK, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_stock_free", None, [_STOCK]),
    ("cadaclysm_blacksmith_job_new", _JOB, [_STOCK, c_double]),
    ("cadaclysm_blacksmith_job_set_clearance", c_bool, [_JOB, c_double]),
    ("cadaclysm_blacksmith_job_set_tolerance", c_bool, [_JOB, c_double]),
    ("cadaclysm_blacksmith_job_set_spindle_dwell", c_bool, [_JOB, c_double]),
    ("cadaclysm_blacksmith_job_set_resolution", c_bool, [_JOB, c_double]),
    ("cadaclysm_blacksmith_job_set_name", c_bool, [_JOB, c_char_p]),
    ("cadaclysm_blacksmith_job_face", c_bool, [_JOB, _TOOL, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_job_contour", c_bool, [_JOB, _TOOL, _PROFILE, c_double, c_double, c_uint32, c_double, c_bool, c_bool]),
    ("cadaclysm_blacksmith_job_pocket", c_bool, [_JOB, _TOOL, _PROFILE, c_double, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_job_drill", c_bool, [_JOB, _TOOL, _D, c_size_t, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_job_gcode", _PROGRAMS, [_JOB]),
    ("cadaclysm_blacksmith_job_camotics", _PROGRAMS, [_JOB, c_char_p]),
    ("cadaclysm_blacksmith_job_free", None, [_JOB]),
    ("cadaclysm_blacksmith_programs_count", c_uint32, [_PROGRAMS]),
    ("cadaclysm_blacksmith_programs_tool", c_uint32, [_PROGRAMS, c_uint32]),
    ("cadaclysm_blacksmith_programs_name", c_char_p, [_PROGRAMS, c_uint32]),
    ("cadaclysm_blacksmith_programs_text", c_char_p, [_PROGRAMS, c_uint32]),
    ("cadaclysm_blacksmith_programs_free", None, [_PROGRAMS]),
    # a tool's and a job's own figures read back: what the notebook's machining view
    # plays a job with (Job.stock, Job.tools, Tool.shape, ...)
    ("cadaclysm_blacksmith_tool_number", c_uint32, [_TOOL]),
    ("cadaclysm_blacksmith_tool_shape", c_char_p, [_TOOL]),
    ("cadaclysm_blacksmith_tool_diameter", c_double, [_TOOL]),
    ("cadaclysm_blacksmith_tool_flute_length", c_double, [_TOOL]),
    ("cadaclysm_blacksmith_tool_angle", c_double, [_TOOL]),
    ("cadaclysm_blacksmith_tool_corner_radius", c_double, [_TOOL]),
    ("cadaclysm_blacksmith_job_stock", c_bool, [_JOB, _D, _D]),
    # automatic CAM: recognise a part and append what makes it, then read back what
    # was left uncut (the report) and every operation a job holds so far
    ("cadaclysm_blacksmith_job_machine", _REPORT, [_JOB, _SOLID, _TOOL, POINTER(c_void_p), c_size_t, c_double, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_job_machine_with", _REPORT, [_JOB, _SOLID, POINTER(c_void_p), c_size_t, POINTER(c_void_p), c_size_t, c_double, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_job_machine_relieved", _REPORT, [_JOB, _SOLID, POINTER(c_void_p), c_size_t, POINTER(c_void_p), c_size_t, c_double, c_double, c_double, c_double, c_bool]),
    ("cadaclysm_blacksmith_report_count", c_uint32, [_REPORT]),
    ("cadaclysm_blacksmith_report_kind", c_char_p, [_REPORT, c_uint32]),
    ("cadaclysm_blacksmith_report_at", c_bool, [_REPORT, c_uint32, _D]),
    ("cadaclysm_blacksmith_report_size", c_double, [_REPORT, c_uint32]),
    ("cadaclysm_blacksmith_report_top", c_double, [_REPORT, c_uint32]),
    ("cadaclysm_blacksmith_report_bottom", c_double, [_REPORT, c_uint32]),
    ("cadaclysm_blacksmith_report_reason", c_char_p, [_REPORT, c_uint32]),
    ("cadaclysm_blacksmith_report_region", _PROFILE_LIST, [_REPORT, c_uint32]),
    ("cadaclysm_blacksmith_report_text", c_char_p, [_REPORT]),
    ("cadaclysm_blacksmith_report_free", None, [_REPORT]),
    ("cadaclysm_blacksmith_job_operations", _OPERATIONS, [_JOB]),
    ("cadaclysm_blacksmith_operations_count", c_uint32, [_OPERATIONS]),
    ("cadaclysm_blacksmith_operations_kind", c_char_p, [_OPERATIONS, c_uint32]),
    ("cadaclysm_blacksmith_operations_tool", c_uint32, [_OPERATIONS, c_uint32]),
    ("cadaclysm_blacksmith_operations_param_count", c_uint32, [_OPERATIONS, c_uint32]),
    ("cadaclysm_blacksmith_operations_param_name", c_char_p, [_OPERATIONS, c_uint32, c_uint32]),
    ("cadaclysm_blacksmith_operations_param_value", c_double, [_OPERATIONS, c_uint32, c_uint32]),
    ("cadaclysm_blacksmith_operations_free", None, [_OPERATIONS]),
    # The Kiln's SubD cage. Every count counts elements: an edge selection passes 2 * count ids.
    ("cadaclysm_blacksmith_subd_cuboid", _SUBD, [c_double, c_double, c_double, c_uint32, c_uint32, c_uint32]),
    ("cadaclysm_blacksmith_subd_cylinder", _SUBD, [c_double, c_double, c_uint32, c_uint32, c_bool]),
    ("cadaclysm_blacksmith_subd_sphere", _SUBD, [c_double, c_uint32]),
    ("cadaclysm_blacksmith_subd_torus", _SUBD, [c_double, c_double, c_uint32, c_uint32]),
    ("cadaclysm_blacksmith_subd_from_parts", _SUBD, [_D, c_uint32, _U, c_uint32, _U, c_uint32, _U, c_uint32, _U, c_uint32, c_int32, c_double]),
    ("cadaclysm_blacksmith_subd_parts", c_bool, [_SUBD, POINTER(_SubdParts)]),
    ("cadaclysm_blacksmith_subd_free", None, [_SUBD]),
    ("cadaclysm_blacksmith_subd_transform", _SUBD, [_SUBD, c_uint32, _U, c_uint32, _D]),
    ("cadaclysm_blacksmith_subd_set_crease", _SUBD, [_SUBD, _U, c_uint32, c_bool]),
    ("cadaclysm_blacksmith_subd_set_pin", _SUBD, [_SUBD, _U, c_uint32, c_bool]),
    ("cadaclysm_blacksmith_subd_extrude", _SUBD, [_SUBD, _U, c_uint32, c_double]),
    ("cadaclysm_blacksmith_subd_inset", _SUBD, [_SUBD, _U, c_uint32, c_double, c_bool]),
    ("cadaclysm_blacksmith_subd_subdivide", _SUBD, [_SUBD, _U, c_uint32]),
    ("cadaclysm_blacksmith_subd_insert_loop", _SUBD, [_SUBD, c_uint32, c_uint32, c_double]),
    ("cadaclysm_blacksmith_subd_mirror_on", _SUBD, [_SUBD, c_uint32]),
    ("cadaclysm_blacksmith_subd_mirror_off", _SUBD, [_SUBD]),
    ("cadaclysm_blacksmith_subd_full", _SUBD, [_SUBD]),
    ("cadaclysm_blacksmith_subd_edge_loop", _SUBD, [_SUBD, c_uint32, c_uint32]),
    ("cadaclysm_blacksmith_subd_smooth_mesh", c_bool, [_SUBD, c_uint32, POINTER(_SubdMesh)]),
    ("cadaclysm_blacksmith_subd_pick", c_bool, [_SUBD, _D, c_uint32, _U]),
    ("cadaclysm_blacksmith_subd_to_solid", _SOLID, [_SUBD, c_double, c_double, c_uint32, POINTER(_SubdReport)]),
    # the 2D constraint sketcher (`Sketch`). A `const uint32_t *` list comes back as a
    # bare address (`c_void_p`) borrowed from the sketch, copied out at once by `_ids`.
    ("cadaclysm_blacksmith_sketch_new", _SKETCH, []),
    ("cadaclysm_blacksmith_sketch_free", None, [_SKETCH]),
    ("cadaclysm_blacksmith_sketch_from_profile", _SKETCH, [_PROFILE, c_bool, c_double]),
    ("cadaclysm_blacksmith_sketch_add_point", c_uint32, [_SKETCH, c_double, c_double]),
    ("cadaclysm_blacksmith_sketch_add_line", c_uint32, [_SKETCH, c_uint32, c_uint32]),
    ("cadaclysm_blacksmith_sketch_add_circle", c_uint32, [_SKETCH, c_uint32, c_double]),
    ("cadaclysm_blacksmith_sketch_add_arc", c_uint32, [_SKETCH, c_uint32, c_uint32, c_uint32]),
    ("cadaclysm_blacksmith_sketch_add_bezier", c_uint32, [_SKETCH, c_uint32, c_double, c_double, c_double, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_sketch_add_conic", c_uint32, [_SKETCH, c_uint32, c_double, c_double, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_sketch_add_nurbs", c_uint32, [_SKETCH, c_uint32, c_uint32, _D, c_size_t, _D, _D, c_size_t]),
    ("cadaclysm_blacksmith_sketch_add_rect", c_void_p, [_SKETCH, c_double, c_double, c_double, c_double, _SZ]),
    ("cadaclysm_blacksmith_sketch_kind", c_uint32, [_SKETCH, c_uint32]),
    ("cadaclysm_blacksmith_sketch_entities", c_void_p, [_SKETCH, _SZ]),
    ("cadaclysm_blacksmith_sketch_point", c_bool, [_SKETCH, c_uint32, _D]),
    ("cadaclysm_blacksmith_sketch_set_point", c_bool, [_SKETCH, c_uint32, c_double, c_double]),
    ("cadaclysm_blacksmith_sketch_radius", c_double, [_SKETCH, c_uint32]),
    ("cadaclysm_blacksmith_sketch_set_radius", c_bool, [_SKETCH, c_uint32, c_double]),
    ("cadaclysm_blacksmith_sketch_centre", c_uint32, [_SKETCH, c_uint32]),
    ("cadaclysm_blacksmith_sketch_ends", c_void_p, [_SKETCH, c_uint32, _SZ]),
    ("cadaclysm_blacksmith_sketch_set_construction", c_bool, [_SKETCH, c_uint32, c_bool]),
    ("cadaclysm_blacksmith_sketch_is_construction", c_bool, [_SKETCH, c_uint32]),
    ("cadaclysm_blacksmith_sketch_is_reference", c_bool, [_SKETCH, c_uint32]),
    ("cadaclysm_blacksmith_sketch_remove_entity", c_void_p, [_SKETCH, c_uint32, _SZ]),
    ("cadaclysm_blacksmith_sketch_reference", c_uint32, [_SKETCH, _SKETCH, c_uint32]),
    ("cadaclysm_blacksmith_sketch_update_reference", c_bool, [_SKETCH, c_uint32, _SKETCH, _D]),
    ("cadaclysm_blacksmith_sketch_constrain", c_uint32, [_SKETCH, c_uint32, _U, c_size_t, c_double, c_bool, c_uint32, c_uint32]),
    ("cadaclysm_blacksmith_sketch_constraints", c_void_p, [_SKETCH, _SZ]),
    ("cadaclysm_blacksmith_sketch_constraint_kind", c_uint32, [_SKETCH, c_uint32]),
    ("cadaclysm_blacksmith_sketch_constraint_refs", c_void_p, [_SKETCH, c_uint32, _SZ]),
    ("cadaclysm_blacksmith_sketch_constraint_value", c_double, [_SKETCH, c_uint32]),
    ("cadaclysm_blacksmith_sketch_constraint_driving", c_bool, [_SKETCH, c_uint32]),
    ("cadaclysm_blacksmith_sketch_constraint_sense", c_uint32, [_SKETCH, c_uint32]),
    ("cadaclysm_blacksmith_sketch_constraint_end", c_uint32, [_SKETCH, c_uint32]),
    ("cadaclysm_blacksmith_sketch_is_joint_tangent", c_bool, [_SKETCH, c_uint32]),
    ("cadaclysm_blacksmith_sketch_remove", c_bool, [_SKETCH, c_uint32]),
    ("cadaclysm_blacksmith_sketch_set_value", c_bool, [_SKETCH, c_uint32, c_double, _D]),
    ("cadaclysm_blacksmith_sketch_set_driving", c_bool, [_SKETCH, c_uint32, c_bool, _D]),
    ("cadaclysm_blacksmith_sketch_measure", c_double, [_SKETCH, c_uint32]),
    ("cadaclysm_blacksmith_sketch_solve", c_bool, [_SKETCH, _D]),
    ("cadaclysm_blacksmith_sketch_drag", c_bool, [_SKETCH, _U, _D, c_size_t, _D]),
    ("cadaclysm_blacksmith_sketch_report_ids", c_void_p, [_SKETCH, _SZ]),
    ("cadaclysm_blacksmith_sketch_diagnose", c_bool, [_SKETCH, _D]),
    ("cadaclysm_blacksmith_sketch_dof_list", c_void_p, [_SKETCH, c_uint32, _SZ]),
    ("cadaclysm_blacksmith_sketch_dof_part", c_bool, [_SKETCH, c_uint32, _D]),
    ("cadaclysm_blacksmith_sketch_dof_part_list", c_void_p, [_SKETCH, c_uint32, c_uint32, _SZ]),
    ("cadaclysm_blacksmith_sketch_profiles", _PROFILE_LIST, [_SKETCH, c_double]),
    ("cadaclysm_blacksmith_sketch_open_chains", _PROFILE_LIST, [_SKETCH, c_double]),
    ("cadaclysm_blacksmith_document_new", _DOCUMENT, [c_char_p]),
    ("cadaclysm_blacksmith_document_load", _DOCUMENT, [c_char_p]),
    ("cadaclysm_blacksmith_document_save", c_void_p, [_DOCUMENT]),
    ("cadaclysm_blacksmith_document_apply", c_void_p, [_DOCUMENT, c_char_p, c_char_p]),
    ("cadaclysm_blacksmith_document_preview", c_void_p, [_DOCUMENT, c_char_p]),
    ("cadaclysm_blacksmith_document_preview_begin", c_bool, [_DOCUMENT]),
    ("cadaclysm_blacksmith_document_end_preview", c_void_p, [_DOCUMENT]),
    ("cadaclysm_blacksmith_document_batch_begin", c_bool, [_DOCUMENT, c_char_p]),
    ("cadaclysm_blacksmith_document_batch_end", c_void_p, [_DOCUMENT]),
    ("cadaclysm_blacksmith_document_batch_abort", c_void_p, [_DOCUMENT]),
    ("cadaclysm_blacksmith_document_undo", c_void_p, [_DOCUMENT]),
    ("cadaclysm_blacksmith_document_redo", c_void_p, [_DOCUMENT]),
    ("cadaclysm_blacksmith_document_params", c_void_p, [_DOCUMENT]),
    ("cadaclysm_blacksmith_document_evaluate", c_void_p, [_DOCUMENT, c_bool]),
    ("cadaclysm_blacksmith_document_evaluate_with", c_void_p, [_DOCUMENT, c_bool, _DOCUMENT_PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_document_result_kind", c_void_p, [_DOCUMENT, c_char_p]),
    ("cadaclysm_blacksmith_document_result_solid", _SOLID, [_DOCUMENT, c_char_p]),
    ("cadaclysm_blacksmith_document_result_profile", _PROFILE, [_DOCUMENT, c_char_p]),
    ("cadaclysm_blacksmith_document_result_profile_count", c_uint32, [_DOCUMENT, c_char_p]),
    ("cadaclysm_blacksmith_document_result_profile_at", _PROFILE, [_DOCUMENT, c_char_p, c_uint32]),
    ("cadaclysm_blacksmith_document_result_nurbs_curve", _NURBS_CURVE, [_DOCUMENT, c_char_p]),
    ("cadaclysm_blacksmith_document_result_subd", _SUBD, [_DOCUMENT, c_char_p]),
    ("cadaclysm_blacksmith_document_value", c_void_p, [_DOCUMENT, c_char_p]),
    ("cadaclysm_blacksmith_document_errors", c_void_p, [_DOCUMENT]),
    ("cadaclysm_blacksmith_document_kinds", c_void_p, []),
    ("cadaclysm_blacksmith_document_profile_path", c_void_p, [_PROFILE]),
    ("cadaclysm_blacksmith_document_solid_body", c_void_p, [_SOLID]),
    ("cadaclysm_bim_document_new", _DOCUMENT, [c_char_p]),
    ("cadaclysm_bim_document_load", _DOCUMENT, [c_char_p]),
    ("cadaclysm_bim_kinds", c_void_p, []),
    ("cadaclysm_parts_catalog_load", c_bool, [c_char_p]),
    ("cadaclysm_parts_document_new", _DOCUMENT, []),
    ("cadaclysm_parts_document_load", _DOCUMENT, [c_char_p]),
    ("cadaclysm_parts_kinds", c_void_p, []),
    ("cadaclysm_bim_document_export_ifc", c_void_p, [_DOCUMENT, c_char_p]),
    ("cadaclysm_bim_sheet_svg", c_void_p, [_DOCUMENT, c_char_p]),
    ("cadaclysm_bim_sheet_pdf", c_void_p, [_DOCUMENT, c_char_p, POINTER(c_size_t)]),
    ("cadaclysm_bim_sheets_pdf", c_void_p, [_DOCUMENT, c_char_p, POINTER(c_size_t)]),
    ("cadaclysm_blacksmith_document_branch_new", c_void_p, [_DOCUMENT, c_char_p, c_char_p]),
    ("cadaclysm_blacksmith_document_branch_switch", c_void_p, [_DOCUMENT, c_char_p]),
    ("cadaclysm_blacksmith_document_tips", c_void_p, [_DOCUMENT]),
    ("cadaclysm_blacksmith_document_branch_rename", c_bool, [_DOCUMENT, c_char_p, c_char_p]),
    ("cadaclysm_blacksmith_document_branch_delete", c_bool, [_DOCUMENT, c_char_p]),
    ("cadaclysm_blacksmith_document_branch_list", c_void_p, [_DOCUMENT]),
    ("cadaclysm_blacksmith_document_log", c_void_p, [_DOCUMENT, c_char_p]),
    ("cadaclysm_blacksmith_document_free", None, [_DOCUMENT]),
]

# Under Pyodide (the website's notebook) there is no shared library to load: the
# same entry points are wasm exports on `globalThis.cadaclysm`, and `_lib()` hands
# out the shim below instead of a `ctypes.CDLL`.
_WASM = sys.platform == "emscripten"


# The arc-length divides, and a curve's divides and crossings: C hands back a
# `CadaclysmBlacksmithSamples *` read by `samples_count`/`samples_at` and freed, the wasm a flat
# array of 10 doubles a sample (no list handle there, so `samples_*` are native only -- the shim
# never calls them).
_DIVIDES = ("edge_divide_by_count", "edge_divide_by_length", "profile_divide_by_count", "profile_divide_by_length",
            "nurbs_curve_divide_by_count", "nurbs_curve_divide_by_length", "nurbs_curve_plane_hits", "nurbs_curve_face_hits")


def _at_from_doubles(raw: "_At", v: "list[float]", what: str) -> None:
    """10 doubles in `CadaclysmBlacksmithAt`'s order, into `raw`. Unpacked whole, so a field
    left out of the unpacking is an error rather than a zero the struct already held."""
    if len(v) != 10:
        raise BuildError(f"{what}: the wasm returned {len(v)} figures, not 10")
    parameter, segment, error, from_polyline = v[6:]
    raw.point[:], raw.tangent[:] = v[0:3], v[3:6]
    raw.parameter, raw.segment, raw.error, raw.from_polyline = parameter, int(segment), error, int(from_polyline)


class _WasmSamples:
    """A divide's answer over the wasm: its flat doubles, 10 a sample."""

    __slots__ = ("doubles",)

    def __init__(self, doubles: "list[float]"):
        self.doubles = doubles


def _samples(what: str, list_: "Any") -> "list[At]":
    """A divide's samples as `At`s: the native list read and freed at once, or the wasm's flat
    array cut 10 at a time. A null list (0) is the call's refusal."""
    if not list_:
        _fail(what)
    if isinstance(list_, _WasmSamples):
        out = []
        for k in range(0, len(list_.doubles), 10):
            raw = _At()
            _at_from_doubles(raw, list_.doubles[k:k + 10], what)
            out.append(At(raw))
        return out
    lib = _lib()
    try:
        raw = _At()
        out = []
        for i in range(lib.cadaclysm_blacksmith_samples_count(list_)):
            if not lib.cadaclysm_blacksmith_samples_at(list_, i, ctypes.byref(raw)):
                _fail("samples_at")
            out.append(At(raw))
        return out
    finally:
        lib.cadaclysm_blacksmith_samples_free(list_)


# The R-tree's queries: C hands back a `CadaclysmBlacksmithRTreeHits *` or `...Pairs *` read row
# by row and freed, the wasm a flat array of 2 doubles a row -- `(id, distance)` or `(a, b)` --
# with no list handle, so `rtree_hits_*` / `rtree_pairs_*` are native only.
_RTREE_QUERIES = ("rtree_search", "rtree_within", "rtree_nearest", "rtree_ray", "rtree_overlaps", "rtree_self_overlaps")


class _WasmRows:
    """An answer over the wasm that C hands out as a list handle: its flat doubles (an R-tree
    query's 2 a row, a solid's regions as `_regions` reads them). Truthy even when empty -- an
    empty answer is not the 0 a refusal is."""

    __slots__ = ("doubles",)

    def __init__(self, doubles: "list[float]"):
        self.doubles = doubles


def _rtree_hits(what: str, list_: "Any") -> "list[tuple[int, float]]":
    """A search/within/nearest answer as `(id, distance)` pairs: the native list read and freed
    at once, or the wasm's flat array cut 2 at a time. A null list (0) is the call's refusal."""
    if not list_:
        _fail(what)
    if isinstance(list_, _WasmRows):
        v = list_.doubles
        return [(int(v[k]), v[k + 1]) for k in range(0, len(v), 2)]
    lib = _lib()
    try:
        raw = _RTreeHit()
        out = []
        for i in range(lib.cadaclysm_blacksmith_rtree_hits_count(list_)):
            if not lib.cadaclysm_blacksmith_rtree_hits_at(list_, i, ctypes.byref(raw)):
                _fail("rtree_hits_at")
            out.append((int(raw.id), float(raw.distance)))
        return out
    finally:
        lib.cadaclysm_blacksmith_rtree_hits_free(list_)


def _rtree_pairs(what: str, list_: "Any") -> "list[tuple[int, int]]":
    """An overlaps answer as `(a, b)` id pairs, as `_rtree_hits` reads hits."""
    if not list_:
        _fail(what)
    if isinstance(list_, _WasmRows):
        v = list_.doubles
        return [(int(v[k]), int(v[k + 1])) for k in range(0, len(v), 2)]
    lib = _lib()
    try:
        raw = _RTreePair()
        out = []
        for i in range(lib.cadaclysm_blacksmith_rtree_pairs_count(list_)):
            if not lib.cadaclysm_blacksmith_rtree_pairs_at(list_, i, ctypes.byref(raw)):
                _fail("rtree_pairs_at")
            out.append((int(raw.a), int(raw.b)))
        return out
    finally:
        lib.cadaclysm_blacksmith_rtree_pairs_free(list_)


def _regions(list_: "Any") -> "list[Region]":
    """A solid's regions: the native `CadaclysmBlacksmithRegions *` read and freed at once, or
    the wasm's flat array -- per region `finite, min x3, max x3, sides, shells`, then `sides`
    pairs `(face, sense)`. A null list (0) is the call's refusal."""
    if not list_:
        _fail("regions")
    out = []
    if isinstance(list_, _WasmRows):
        v, k = list_.doubles, 0
        while k < len(v):
            finite, lo, hi, n, shells = v[k], v[k + 1:k + 4], v[k + 4:k + 7], int(v[k + 7]), int(v[k + 8])
            k += 9
            sides = tuple(FaceSide(int(v[k + 2 * j]), int(v[k + 2 * j + 1])) for j in range(n))
            k += 2 * n
            out.append(Region(len(out), finite == 1, Box(lo, hi), sides, shells))
        return out
    lib = _lib()
    try:
        raw, side = _Region(), _FaceSide()
        for i in range(lib.cadaclysm_blacksmith_regions_count(list_)):
            if not lib.cadaclysm_blacksmith_regions_at(list_, i, ctypes.byref(raw)):
                _fail("regions_at")
            sides = []
            for k in range(raw.sides):
                if not lib.cadaclysm_blacksmith_regions_side_at(list_, i, k, ctypes.byref(side)):
                    _fail("regions_side_at")
                sides.append(FaceSide(int(side.face), int(side.sense)))
            out.append(Region(i, bool(raw.finite), Box(tuple(raw.min), tuple(raw.max)), tuple(sides), int(raw.shells)))
        return out
    finally:
        lib.cadaclysm_blacksmith_regions_free(list_)


class _WasmHistory:
    """A history over the wasm: the export's one flat `u64` array, parsed into the four lists
    `History` has -- `nk`, then `(operand, id, out)` each; `nm`, then `(operand, id, n, outs...)`
    each; `ng`, then the ids; `nd`, then `(operand, id)` each. The shim answers C's `history_*`
    readers from it, so `Solid.history` reads one code path. Truthy even when empty."""

    __slots__ = ("kept", "modified", "generated", "deleted")

    def __init__(self, flat: "list[int]"):
        at = 0

        def take(n):
            nonlocal at
            if at + n > len(flat):
                raise BuildError(f"history: the wasm returned {len(flat)} numbers, cut short at {at}")
            out = flat[at:at + n]
            at += n
            return out

        self.kept = [((k, i), o) for k, i, o in (take(3) for _ in range(take(1)[0]))]
        self.modified = []
        for _ in range(take(1)[0]):
            k, i, n = take(3)
            self.modified.append(((k, i), take(n)))
        self.generated = take(take(1)[0])
        self.deleted = [(k, i) for k, i in (take(2) for _ in range(take(1)[0]))]
        if at != len(flat):
            raise BuildError(f"history: the wasm returned {len(flat)} numbers, {len(flat) - at} past the lists")

    def __bool__(self) -> bool:
        return True


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

    # C names whose wasm export is spelled otherwise: the wasm's export entry point has no
    # `document_` in its name
    _RENAMED = {"cadaclysm_bim_document_export_ifc": "cadaclysm_bim_export_ifc"}

    # what a failing call returns, by the C ABI's convention for that name:
    # `False` for the bool-returning verbs, a zeroed struct (a null pointer in
    # it) for the struct-returning ones, NONE for the u32 ones that reserve
    # it, and 0 (a null handle, or a count the caller checks `last_error` on)
    # for everything else
    _BOOLS = {"path_line_to", "path_arc_to", "path_bezier_to", "path_nurbs_to", "path_conic_to",
              "path_parabola_by_vertex", "path_parabola_by_focus", "sweep_path_line_to",
              "sweep_path_arc", "slant_of_plane", "face_frame", "face_ref", "frame_midplane", "frame_through", "bounds", "bounds64", "box", "job_stock", "edge", "colour", "profile_colour", "edge_colour", "parse_colour", "manifold", "edge_beziers", "isocurve_beziers", "license_set", "assembly_link", "assembly_joint",
              "assembly_pair", "assembly_pair_with", "assembly_state", "assembly_sequence", "assembly_base",
              "hit", "edge_curve", "intersection_chain", "intersection_curve", "intersection_overlap", "hits_piece", "report_at",
              "fem_mesh_view", "fem_mesh_edge", "fem_mesh_vertex", "fem_mesh_open_edge", "fem_mesh_folded_edge",
              "fem_mesh_crossing",
              # collider: `solid_bounds_box`/`box_moved` write a `Box` out-param, `boxes_apart`
              # a bool, `collider_stats`/`collisions_hit` a record -- the C return is a plain
              # success flag either way, so a failure (an exception thrown) is `False` here too.
              # `box_overlaps` is deliberately absent: its C return **is** the answer, not a
              # success flag, so it takes the generic "return result" path instead.
              "solid_bounds_box", "box_moved", "boxes_apart", "collider_stats", "collisions_hit", "clashes_at",
              # swept clash: a row record and an interval's two doubles, behind a success flag
              "swept_clashes_at", "swept_clashes_interval", "check_finding",
              # wall thickness: the mesh, the face reading and each row are records C writes
              # through an out-param behind a success flag; the exports return them instead
              "thickness_gauge_mesh", "thickness_gauge_face", "thicknesses_at", "mesh_thicknesses_at",
              # its wasm export always throws ("the wasm writes no file"); `FemMesh.save_msh`
              # never reaches it under Pyodide, writing `msh_text()` through Pyodide's own
              # filesystem as `write_sat`/`write_brep`/`svg` do, so this is the shape a direct
              # `_lib()` call would still get right rather than a path the module takes
              "fem_mesh_save_msh",
              # the transforms and quaternions: a success flag, the answer in the out-array (`_OUT`)
              "transform_translation", "transform_rotation", "transform_mirror", "transform_scale", "transform_scale_xyz", "transform_shear", "transform_plane_to_plane", "transform_change_basis", "transform_planar_projection", "transform_project_along",
              "transform_compose", "transform_inverse", "transform_decompose_rigid", "transform_decompose_similarity", "transform_decompose_affine", "quaternion_from_axis_angle", "quaternion_from_transform", "quaternion_to_transform", "quaternion_slerp",
              # the values' calls: a success flag, the answer in the out-array (`_OUT`, `_SCALARS`;
              # `frame_fit`'s two outs in `_back`)
              "value_check", "value_bounds", "value_transform", "curve_value_point_at", "curve_value_tangent_at", "curve_value_length",
              "curve_value_closest_point", "circle_through", "arc_through", "arc_from_start_tangent_end", "ellipse_from_circle",
              "surface_value_point_at", "surface_value_normal_at", "surface_value_closest_point", "surface_value_domain",
              "solid_value_area", "solid_value_volume", "cuboid_from_bounds", "cuboid_around", "cuboid_corners", "cuboid_point_at",
              "cuboid_closest_point", "frame_fit",
              "rectangle_corners", "rectangle_area", "rectangle_closest_point", "triangle_area", "triangle_perimeter",
              "triangle_centroid", "triangle_circumcircle", "triangle_point_at", "triangle_barycentric",
              "triangle_closest_point", "triangle_edge", "ray_point_at", "ray_closest_point",
              # a job's settings and operations change it in place, true or a refusal
              "job_set_clearance", "job_set_tolerance", "job_set_spindle_dwell", "job_set_resolution",
              "job_set_name", "job_face", "job_contour", "job_pocket", "job_drill",
              # `mass_properties` writes a `CadaclysmBlacksmithMassProperties` out-param and
              # returns a plain success flag, as `solid_bounds_box` writes a `Box`
              "mass_properties",
              # the measurements beside it: `oriented_box`/`edge_length`/`profile_length`/`closest`
              # write a struct, `classifier_contains`/`contains` a code (where 0, outside, is an
              # answer and not a failure) -- a success flag every one, as `mass_properties`
              "oriented_box", "edge_length", "profile_length", "classifier_contains", "contains", "closest",
              # arc-length sampling: the two point calls write a `CadaclysmBlacksmithAt`, a success
              # flag as `edge_length`'s. The divides are not here: C returns a list handle, the
              # wasm a flat array (see `_back`), and a failure is the 0 a null handle is
              "edge_point_at_length", "profile_point_at_length",
              # the R-tree: `rtree_insert`/`_insert_point` return nothing over the wasm and C's
              # success flag here, `rtree_bounds` writes its 6 doubles (see `_OUT`). `rtree_remove`
              # is deliberately absent: its C return **is** the answer (false for an absent
              # entry, with no error), so it takes the generic "return result" path
              "rtree_insert", "rtree_insert_point", "rtree_bounds",
              # the interpolator: `_at`/`_sample` write their doubles into the caller's array
              # (see `_OUT`), C's return a success flag. `interpolator_cyclic` is absent: its C
              # return **is** the answer, as `rtree_remove`'s
              "interpolator_at", "interpolator_sample",
              # the kernel options: `option_set` returns C's success flag, and `option_get`'s
              # export returns the value C writes through `*out` (see `_back`)
              "option_set", "option_get",
              # SubD: `subd_parts`/`subd_smooth_mesh` fill a views struct and `subd_pick` an
              # id pair, C returning a success flag; `subd_pick`'s null (nothing near) is
              # `False` with an empty `last_error` in `_back`, as C leaves it
              "subd_parts", "subd_smooth_mesh", "subd_pick",
              # the sketch: its mutators' `Js<()>` and the `double out[N]` writers, a plain
              # success flag in C either way. `is_construction`/`is_reference`/
              # `is_joint_tangent`/`constraint_driving` are absent, as `box_overlaps` is:
              # their C return is the answer, not a success flag.
              "sketch_set_point", "sketch_set_radius", "sketch_set_construction", "sketch_remove",
              "sketch_point", "sketch_update_reference", "sketch_set_value", "sketch_set_driving",
              "sketch_solve", "sketch_drag", "sketch_diagnose", "sketch_dof_part",
              # the document: the four calls whose export returns nothing and C a success flag
              "document_preview_begin", "document_batch_begin", "document_branch_rename", "document_branch_delete",
              # identity: an origin C writes through two out-pointers (the export returns
              # `[operand, id]`, see `_back`), and the edge and vertex references' out-arrays
              "face_origin_at", "edge_origin_at", "edge_ref", "vertex_ref",
              # tolerances: the declaration's two out-doubles (the export returns them, see `_back`)
              "solid_tolerances",
              # NurbsCurve's readers: a success flag, the answer in the out-array (`_OUT`) or the
              # record (`_back`); `nurbs_curve_tween` writes its handles (`_back`). `is_rational` and
              # `is_closed` are absent, as `box_overlaps` is: their C return is the answer
              "nurbs_curve_control_points", "nurbs_curve_weights", "nurbs_curve_knots", "nurbs_curve_domain",
              "nurbs_curve_point", "nurbs_curve_derivatives", "nurbs_curve_curvature", "nurbs_curve_length",
              "nurbs_curve_point_at_length", "nurbs_curve_tween",
              # a profile's Béziers (the out-array, `_OUT`) and a chain's order (`_back`)
              "profile_beziers", "profile_loops", "profile_chain_order",
              # the panel gap: a success flag, the two panels' handles in `_back`
              "panel_gap",
              # the sheets' continuity, an edge's and a curve's knots': a success flag, the record in `_back`
              "continuity", "edge_continuity", "nurbs_curve_knot_continuity",
              # a face's curvature turns and an edge's highlight kink: a success flag, the record in `_back`
              "curvature_turns", "highlight_kink",
              # a triangle mesh's box: C's success flag, the six doubles in the out-array (`_OUT`)
              "triangle_mesh_bounds"}
    # the sketch's borrowed `const uint32_t *` lists, by the position of their `size_t *count`:
    # the export returns the list itself (a `Uint32Array`), which `_back` copies out to a
    # Python list, filling the count behind `ctypes.byref` from its length as it does
    # for `silhouette_beziers`; `_ids` takes that list as it is
    _LISTS = {"sketch_add_rect": 5, "sketch_entities": 1, "sketch_ends": 2, "sketch_remove_entity": 2,
              "sketch_constraints": 1, "sketch_constraint_refs": 2, "sketch_report_ids": 1,
              "sketch_dof_list": 2, "sketch_dof_part_list": 3}
    _FAILS = {"tool_number": NONE, "tool_diameter": float("nan"), "tool_flute_length": float("nan"),
              "tool_angle": float("nan"), "tool_corner_radius": float("nan"),
              "select_face": NONE, "leaked_edges": NONE, "unpaired_edges": NONE,
              "face_round_radius": float("nan"), "face_chamfer_distance": float("nan"),
              "mesh": _Mesh(), "mesh64": _Mesh64(), "mesh_face_triangles": _FaceTriangles(), "edge_polylines": _Polylines(),
              "profile_polylines": _Polylines(), "edge_polyline_colours": _Colours(),
              "programs_count": NONE, "programs_tool": NONE,
              # `_report`/`_operations` check these against `NONE` before indexing, the same
              # precedent `programs_count`/`programs_tool` set
              "report_count": NONE, "operations_count": NONE, "operations_tool": NONE, "operations_param_count": NONE,
              # the sketch's ids start at 0, so a refused id-returning call must come back
              # as C's `NONE`, not the generic 0; its double readers as C's NaN; its lists
              # as C's null (`None`, what a null `c_void_p` reads as natively)
              "sketch_add_point": NONE, "sketch_add_line": NONE, "sketch_add_circle": NONE, "sketch_add_arc": NONE,
              "sketch_add_bezier": NONE, "sketch_add_conic": NONE, "sketch_add_nurbs": NONE, "sketch_kind": NONE,
              "sketch_centre": NONE, "sketch_reference": NONE, "sketch_constrain": NONE,
              "sketch_constraint_kind": NONE, "sketch_constraint_sense": NONE, "sketch_constraint_end": NONE,
              "sketch_radius": float("nan"), "sketch_measure": float("nan"), "sketch_constraint_value": float("nan"),
              # a profile list's count: C reserves NONE for a node that is not one
              "document_result_profile_count": NONE,
              # the map classifiers: C's NONE and NaN, never the generic 0 (0 is "no" and "not a similarity")
              "transform_is_rigid": NONE, "transform_is_similarity": float("nan"),
              # the values: containment's NONE; `value_size`'s export throws on an unknown kind,
              # where C answers 0
              "solid_value_contains": NONE, "value_size": 0, "rectangle_contains": NONE,
              # a gauge's tolerance: C's NaN for a refusal, never the generic 0
              "thickness_gauge_tolerance": float("nan"),
              # identity: C's NONE for a refused count and for "no face has the id"; -2 for a
              # malformed face, edge or vertex reference (-1, "gone", is an answer); None for a refused
              # attribute read
              "face_with_id": NONE, "edge_with_id": NONE, "face_origin_count": NONE, "edge_origin_count": NONE,
              "find_face": -2, "find_edge": -2, "find_vertex": -2, "attribute": None, "face_attribute": None,
              # tolerances: C's NaN for a refusal, never the generic 0 (0 is an effective tolerance)
              "effective_tolerance": float("nan"), "vertex_tolerance": float("nan"),
              # closest point from a point: C's int32 -1 for a refusal (0 is "beyond max_distance")
              "closest_point": -1, "projector_closest_point": -1, "face_closest_point": -1,
              "edge_closest_point": -1, "nurbs_curve_closest_point": -1,
              # closest points from a curve: the same int32 -1 (0 is "beyond max_distance")
              "nurbs_curve_closest_point_within": -1, "nurbs_curve_closest_points": -1, "curve_closest_points": -1,
              "projector_curve_closest_points": -1, "nurbs_curve_closest_object": -1,
              # closest points against a triangle mesh: the same int32 -1 (0 is "beyond max_distance")
              "triangle_mesh_closest_point": -1, "triangle_mesh_curve_closest_points": -1,
              **{short: None for short in _LISTS}}
    # results that C writes into an out-array of doubles at this position, and the
    # wasm returns as a typed array (`bounds` fills two, `edge` a record: see `_back`)
    _OUT = {"edge_beziers": 2, "isocurve_beziers": 3, "profile_beziers": 2, "slant_of_plane": 3, "face_frame": 2, "face_ref": 2, "frame_midplane": 2, "frame_through": 3, "report_at": 2,
            "rtree_bounds": 1, "interpolator_at": 3, "interpolator_sample": 4, "triangle_mesh_bounds": 1,
            # the sketch's point (2), solve reports (3) and diagnoses (3)
            "sketch_point": 2, "sketch_update_reference": 3, "sketch_set_value": 3, "sketch_set_driving": 3,
            "sketch_solve": 1, "sketch_drag": 4, "sketch_diagnose": 1, "sketch_dof_part": 2,
            # the transforms and quaternions: their one out-array, last
            "transform_translation": 1, "transform_rotation": 2, "transform_mirror": 1, "transform_scale": 2,
            "transform_scale_xyz": 4, "transform_shear": 3, "transform_plane_to_plane": 2, "transform_change_basis": 2,
            "transform_planar_projection": 1, "transform_project_along": 2, "transform_compose": 2, "transform_inverse": 1,
            "transform_decompose_rigid": 2, "transform_decompose_similarity": 2, "transform_decompose_affine": 1,
            "quaternion_from_axis_angle": 2, "quaternion_from_transform": 1, "quaternion_to_transform": 2, "quaternion_slerp": 3,
            # the values: their one out-array, last (`cuboid_around`'s count dropped, its out not)
            "value_check": 2, "value_bounds": 2, "value_transform": 3, "curve_value_point_at": 3, "curve_value_tangent_at": 3,
            "curve_value_closest_point": 3, "circle_through": 3, "arc_through": 3, "arc_from_start_tangent_end": 3,
            "ellipse_from_circle": 1, "surface_value_point_at": 4, "surface_value_normal_at": 4, "surface_value_closest_point": 3,
            "surface_value_domain": 2, "cuboid_from_bounds": 2, "cuboid_around": 3, "cuboid_corners": 1, "cuboid_point_at": 4,
            "cuboid_closest_point": 2, "rectangle_corners": 1, "rectangle_closest_point": 3, "triangle_centroid": 1,
            "triangle_circumcircle": 1, "triangle_point_at": 4, "triangle_barycentric": 2, "triangle_closest_point": 2,
            "triangle_edge": 2, "ray_point_at": 2, "ray_closest_point": 2,
            # a swept clash's interval, `[start, end]`
            "swept_clashes_interval": 3,
            # the edge and vertex references
            "edge_ref": 2, "vertex_ref": 2,
            # a curve's reads: their one out-array, last
            "nurbs_curve_control_points": 1, "nurbs_curve_weights": 1, "nurbs_curve_knots": 1, "nurbs_curve_domain": 1,
            "nurbs_curve_point": 2, "nurbs_curve_derivatives": 3}
    # the one double C writes through `out` at this position, which the export returns as a
    # plain number (not an array, as `_OUT`'s)
    _SCALARS = {"curve_value_length": 2, "solid_value_area": 2, "solid_value_volume": 2, "rectangle_area": 1,
                "triangle_area": 1, "triangle_perimeter": 1}
    # `uint64_t` arguments, by position: an id crosses into the wasm as a JS `BigInt` (a plain
    # number would be refused by the export's `u64`)
    _U64_ARGS = {"face_with_id": (1,), "edge_with_id": (1,)}
    # argument positions the C call has and the wasm call does not: an array's
    # count (a typed array knows its length), the progress `user` pointer, and
    # the out-arguments above
    _DROP = {"profile_polygon": (1,), "path_nurbs_to": (2, 5), "join": (4,), "document_evaluate_with": (3,), "merge": (4,), "cut": (4,), "common": (4,),
             "split_sheet": (4,), "trim": (5,), "drop_faces": (2,), "profile_round": (3,), "profile_spline": (1,), "profile_chain": (1,), "profile_from_loops": (1,), "profile_piece_count": (2,), "profile_piece": (2,), "profile_trim_count": (2,), "profile_trim_chain": (2,), "loft_through": (2,), "loft_through_open": (2,), "fillet": (2, 6), "chamfer": (2,), "shell": (3, 6), "thicken": (4,), "push_pull": (5,), "push_pull_faces": (2, 6), "split": (4,), "split_by_plane": (4,), "split_by_profile": (5,), "step": (1,), "step_assembly": (2, 5), "assembly_link": (3,), "assembly_state": (5,), "assembly_sequence": (5,), "assembly_posed": (4,), "sat_text": (1,), "3dm_bytes": (1, 3), "assembly_3dm_bytes": (2,), "brep_text": (1,), "profile_text": (4,),
             "slant_of_plane": (3,), "face_frame": (2,), "face_ref": (2,), "bounds": (2, 3), "bounds64": (2, 3), "box": (1, 2), "job_stock": (1, 2), "edge": (2,), "colour": (2,), "profile_colour": (1,), "edges_coloured": (2,), "edge_colour": (2,), "parse_colour": (1,), "manifold": (1,), "edge_beziers": (2,), "isocurve_beziers": (3,), "mesh_file": (1, 6), "bim_sheet_pdf": (2,), "bim_sheets_pdf": (2,), "hit": (2,), "edge_curve": (2,), "report_at": (2,),
             "intersect": (4,), "self_intersect": (3,), "check": (5,), "check_finding": (2,), "intersection_chain": (2,), "intersection_curve": (2,), "intersection_overlap": (2,), "svg_text": (1,), "drawing_svg_text": (1, 3),
             # the count out-param: the export returns the curves' own array (see `_back`)
             "silhouette_beziers": (2,),
             "solid_profile_hits": (5,), "hits_piece": (2, 3, 4),
             # `fem_mesh`'s index counts the tuple `call` rewrites below, not the C call's:
             # the options struct becomes two scalars, so `user` has moved from 4 to 5.
             "fem_mesh": (5,), "fem_mesh_view": (1,), "fem_mesh_edge": (2,), "fem_mesh_vertex": (2,),
             "fem_mesh_open_edge": (2, 3, 4), "fem_mesh_folded_edge": (2, 3, 4), "fem_mesh_crossing": (2, 3),
             # collider: `solid_bounds_box`/`box_moved` drop their `Box` out-param; `boxes_apart`
             # its `bool` out-param; `collider_new` its `solids` count and `allowed` count (a
             # typed array knows its own length); `collider_check` its `frame_count`;
             # `collider_stats`/`collisions_hit` their out-record.
             "solid_bounds_box": (2,), "box_moved": (2,), "boxes_apart": (4,),
             "collider_new": (1, 5), "collider_check": (2,), "collider_stats": (1,), "collisions_hit": (2,),
             # clash: `collider_clash` drops its `frame_count`; `clash` both set counts (typed
             # arrays know their length) and its `allowed` pair count (the export takes the
             # flat numbers); `clashes_at` its out-record, which the export returns instead
             "collider_clash": (2,), "clash": (1, 3, 7), "clashes_at": (2,),
             # swept clash: `collider_swept_clash` drops its `frame_count` (the export reads it
             # off the numbers and the pose count); `swept_clash` both set counts and its
             # `allowed` pair count; `swept_clashes_at` its out-record and
             # `swept_clashes_interval` its out-array, which the exports return instead
             "collider_swept_clash": (3,), "swept_clash": (1, 4, 12), "swept_clashes_at": (2,),
             "swept_clashes_interval": (3,),
             # an assembly's sweep: `joint_count` (the joints and counts arrays know their
             # length) and the `allowed` pair count (the export takes the flat numbers)
             "assembly_swept_clash": (3, 12),
             # wall thickness: `thickness_gauge_new` its solids count; the mesh, face and row
             # readers their out-record, which the export returns instead; `mesh_thickness` its
             # `mesh_count` (the counts arrays know their own length)
             "thickness_gauge_new": (1,), "thickness_gauge_mesh": (2,), "thickness_gauge_face": (5,),
             "thicknesses_at": (2,), "mesh_thicknesses_at": (2,), "mesh_thickness": (4,),
             # the point count: the wasm's `xy` is a Float64Array of x, y pairs
             "job_drill": (3,),
             # the drill count: the wasm's `drills` is an array of tool handles carrying
             # its own length, as `job_drill`'s `xy` carries its own point count
             "job_machine": (4,),
             # both tool counts: the wasm's `end_mills` and `drills` are arrays of tool
             # handles carrying their own lengths
             "job_machine_with": (3, 5),
             "job_machine_relieved": (3, 5),
             # `mass_properties` drops its `CadaclysmBlacksmithMassProperties` out-param: the
             # export returns the figures as a flat array of doubles instead
             "mass_properties": (2,),
             # the measurements drop their out-param (the export returns the figures, the
             # containment code or the closest record instead); `closest` its `progress` and
             # `user` too -- the wasm takes no progress callback
             "oriented_box": (2,), "edge_length": (3,), "profile_length": (2,),
             # arc-length sampling's two point calls drop their `At` out-param, the export
             # returning its 10 doubles instead
             "edge_point_at_length": (4,), "profile_point_at_length": (3,),
             # the R-tree: the entry/point/triangle counts (a typed array knows its length) and
             # `rtree_bounds`' out-array, which the export returns instead
             "rtree_from_boxes": (2,), "rtree_from_points": (1,), "rtree_from_triangles": (1, 3), "rtree_bounds": (1,),
             # the interpolator: the sample and `t` counts (a typed array knows its length), and
             # the out-array and its length, which the export returns instead
             "interpolator_new": (1,), "interpolator_at": (3, 4), "interpolator_sample": (2, 4, 5),
             "classifier_contains": (2,), "contains": (3,), "closest": (3, 4, 5),
             # closest point from a point: the foot out-param or the five doubles' out-array,
             # which the export returns instead (a foot object or null, a plain array: `_back`)
             "closest_point": (4,), "projector_closest_point": (3,), "face_closest_point": (3,),
             "edge_closest_point": (3,), "nurbs_curve_closest_point": (2,),
             # closest points from a curve: the out-param or out-array, which the export returns
             # instead (null beyond the limit: `_back`). `nurbs_curve_closest_object`'s index counts
             # the tuple `call` folds its arrays into -- (curve, items, max, tolerance, out)
             "nurbs_curve_closest_point_within": (3,), "nurbs_curve_closest_points": (3,), "curve_closest_points": (4,),
             "projector_curve_closest_points": (3,), "nurbs_curve_closest_object": (4,),
             # closest points against a triangle mesh: the constructor's two counts (a typed array
             # knows its length), `bounds`' out-array and the queries' out-params, which the
             # exports return instead (null beyond the limit: `_back`)
             "triangle_mesh_new": (1, 3), "triangle_mesh_bounds": (1,), "triangle_mesh_closest_point": (3,),
             "triangle_mesh_curve_closest_points": (3,),
             # `option_get` drops its `*out`: the export returns the value instead
             "option_get": (1,),
             # SubD: every array's count (a typed array knows its own length), and the
             # out-params -- `subd_parts`/`subd_smooth_mesh`'s struct, `subd_pick`'s id pair
             # and `subd_to_solid`'s report -- which the exports return instead (see `_back`)
             "subd_from_parts": (1, 3, 5, 7, 9), "subd_parts": (1,), "subd_transform": (3,),
             "subd_set_crease": (2,), "subd_set_pin": (2,), "subd_extrude": (2,), "subd_inset": (2,),
             "subd_subdivide": (2,),
             "subd_smooth_mesh": (2,), "subd_pick": (3,), "subd_to_solid": (4,),
             # the counted verbs: their `inexact_out`, which the export returns beside the handle (see `_back`)
             "solid_transform": (2,), "solid_convert_to_nurbs": (2,),
             # the N-sided patch's report, which the export returns after the handle (see `_back`);
             # its boundaries cross as two arrays, rewritten in `call`
             "n_sided_patch": (4,),
             # identity: an origin's two out-pointers (the export returns them), the references' out-arrays
             "face_origin_at": (3, 4), "edge_origin_at": (3, 4), "edge_ref": (2,), "vertex_ref": (2,),
             # tolerances: the solids count (a typed array knows its length), the declaration's outs
             "effective_tolerance": (1,), "solid_tolerances": (1, 2),
             # the values: the point counts (a typed array knows its length); `frame_fit`'s outs
             # too, the export returning frame and deviation as 13 numbers (see `_back`)
             "cuboid_around": (2,), "frame_fit": (1, 2, 3),
             # NurbsCurve: the point, weight, knot and curve counts (a typed array knows its
             # length); a fitted curve's `error_out` and the tweens' `out`, which the exports
             # return instead (see `_back`); the reads' out-arrays and records
             "nurbs_curve_new": (1, 5), "nurbs_curve_through": (1,), "nurbs_curve_fit": (1, 4),
             "nurbs_curve_projected_to_face": (5,), "nurbs_curve_pulled_to_face": (4,), "nurbs_curve_joined": (1,),
             "nurbs_curve_tween": (7,), "nurbs_curve_control_points": (1,), "nurbs_curve_weights": (1,),
             "nurbs_curve_knots": (1,), "nurbs_curve_domain": (1,), "nurbs_curve_point": (2,),
             "nurbs_curve_derivatives": (3,), "nurbs_curve_curvature": (2,), "nurbs_curve_length": (2,),
             "nurbs_curve_point_at_length": (3,), "nurbs_curve_fair": (1, 7), "nurbs_curve_faired": (6,),
             "nurbs_curve_knot_continuity": (1,), "edge_continuity": (3,),
             # a faired sheet's `error_out`, which the export returns after the solid; the records
             "surface_faired": (8,), "curvature_turns": (3,), "highlight_kink": (3,),
             # the sketch curves: the point and Bézier counts, the piece counts, and the
             # out-arrays the exports return instead (`_OUT`, `_back`)
             "profile_polyline": (1,), "profile_from_beziers": (1,), "profile_beziers": (2,),
             "profile_loops": (1, 3), "profile_chain_order": (1, 3),
             # the sheets from curves, the surface fillets, trim and join: every curve, sheet and
             # edge count (a typed array knows its length), and the error, rails and report C
             # writes through an out-argument, which the exports return after the solid (`_back`)
             "loft_curves": (1,), "sweep_rail": (2, 6), "sweep_two_rails": (3, 5), "edge_surface": (1, 3),
             "network_surface": (1, 3, 5), "continuity": (7,), "fillet_surfaces": (9, 10, 11), "fillet_varying": (2,),
             "fillet_law": (2, 5),
             "join_sheets": (1, 3), "flange": (2, 6), "extrude_to": (2, 7), "recess": (7,), "mirror_join": (4,),
             # holes, ribs and webs, patterns: every count (a typed array knows its length), the
             # reports and bottoms C writes, which the exports return after the solid, and the
             # placements' `out`, which the exports return instead of a count (`_back`)
             "hole": (2, 14, 15), "hole_tool": (2,), "pattern": (2, 4), "pattern_feature": (4, 6), "web": (2,), "web_tool": (2,),
             "pattern_rectangular": (8, 9), "pattern_circular": (5, 6), "pattern_along": (5, 6),
             # the panel verbs: the offset's `error_out` and the panel gap's `out`, which the exports return
             "nurbs_curve_offset_on_sheet": (4,), "panel_gap": (5,),
             # the sketch: `add_nurbs`' point and knot counts, `constrain`'s ref count,
             # `drag`'s count and report, the other out-arrays above, and every list's
             # count (`_LISTS`)
             "sketch_add_nurbs": (4, 7), "sketch_constrain": (3,), "sketch_drag": (3, 4),
             **{short: (at,) for short, at in _OUT.items() if short.startswith("sketch_") and short != "sketch_drag"},
             **{short: (at,) for short, at in _LISTS.items()}}
    # handle arrays the module pads to one entry for ctypes, by (array, count) position
    # double arrays padded to one entry for ctypes, by (array, count, doubles a count) position
    _PADDED_DOUBLES = {"hole": (1, 2, 3), "hole_tool": (1, 2, 3), "pattern": (1, 2, 16), "pattern_feature": (3, 4, 16)}
    _PADDED = {"nurbs_curve_joined": ((0, 1),), "loft_curves": ((0, 1),), "sweep_rail": ((1, 2),), "sweep_two_rails": ((2, 3),),
               "edge_surface": ((0, 1),), "network_surface": ((0, 1), (2, 3)), "join_sheets": ((0, 1),),
               "web": ((1, 2),), "web_tool": ((1, 2),)}
    # strings the C side returns as `const char*`, and the module decodes
    # `solid_name`'s wasm export returns an empty string for an unnamed solid
    # (see its own doc comment in crates/cadaclysm-wasm/src/blacksmith.rs), and
    # `str(result).encode()` below turns that into `b""` -- falsy exactly like
    # the `None` a null `const char*` decodes to on the native backend, so
    # every call site's `if raw` reads the same on both.
    _TEXTS = {"tool_shape", "version", "build_date", "face_kind", "license_info", "brep_layout_id", "assembly_name", "solid_name",
              "solid_material", "solid_style_location", "solid_style_identification",
              "programs_name", "programs_text", "report_kind", "report_reason", "report_text",
              "operations_kind", "operations_param_name"}

    def __init__(self):
        import js
        self._js = js.cadaclysm
        self._error = None

    # -- the two the C side owns memory for, and the browser has none
    def cadaclysm_blacksmith_last_error(self):
        # `None` when no call failed; an empty `str` encodes to `b""`, as C's empty
        # `last_error` reads over ctypes (`subd_pick`'s "nothing near": `_nothing_near`)
        return self._error.encode() if self._error is not None else None

    def cadaclysm_blacksmith_string_free(self, _text):
        pass

    def cadaclysm_blacksmith_silhouette_beziers_free(self, _data, _count):
        pass   # the curves came back as a JS array; there is no C block to release

    # -- identity: a history is one flat array over the wasm (`_WasmHistory`), not a handle, and
    # C's readers are answered from it here; `history_free` has nothing to free (the wasm's own
    # export of that name is the document undo history's, which this never reaches)
    def _history(self, short: str, out, inputs, count):
        from pyodide.ffi import JsException
        import js
        from pyodide.ffi import to_js
        self._error = None
        handles = [int(v) for v in list(inputs)[:count]]
        try:
            flat = getattr(self._js, "cadaclysm_blacksmith_" + short)(out, js.Uint32Array.new(to_js(handles)))
        except JsException as e:
            if self._trapped(e):
                raise
            self._error = self._message(e)
            return 0
        return _WasmHistory([int(v) for v in flat])

    def cadaclysm_blacksmith_history(self, out, inputs, count):
        return self._history("history", out, inputs, count)

    def cadaclysm_blacksmith_edge_history(self, out, inputs, count):
        return self._history("edge_history", out, inputs, count)

    def cadaclysm_blacksmith_history_free(self, _history):
        pass

    def _entry(self, what: str, rows: list, i: int):
        self._error = None
        if not 0 <= i < len(rows):
            self._error = f"{what}: entry {i} of {len(rows)}"
            return None
        return rows[i]

    def cadaclysm_blacksmith_history_kept_count(self, h):
        return len(h.kept)

    def cadaclysm_blacksmith_history_kept_at(self, h, i, operand, id_, out_id):
        row = self._entry("history_kept_at", h.kept, i)
        if row is None:
            return False
        (operand._obj.value, id_._obj.value), out_id._obj.value = row
        return True

    def cadaclysm_blacksmith_history_modified_count(self, h):
        return len(h.modified)

    def cadaclysm_blacksmith_history_modified_at(self, h, i, operand, id_):
        row = self._entry("history_modified_at", h.modified, i)
        if row is None:
            return False
        operand._obj.value, id_._obj.value = row[0]
        return True

    def cadaclysm_blacksmith_history_modified_output_count(self, h, i):
        row = self._entry("history_modified_output_count", h.modified, i)
        return NONE if row is None else len(row[1])

    def cadaclysm_blacksmith_history_modified_output_at(self, h, i, j):
        row = self._entry("history_modified_output_at", h.modified, i)
        if row is None:
            return 0
        if not 0 <= j < len(row[1]):
            self._error = f"history_modified_output_at: output {j} of {len(row[1])}"
            return 0
        return row[1][j]

    def cadaclysm_blacksmith_history_generated_count(self, h):
        return len(h.generated)

    def cadaclysm_blacksmith_history_generated_at(self, h, i):
        row = self._entry("history_generated_at", h.generated, i)
        return 0 if row is None else row

    def cadaclysm_blacksmith_history_deleted_count(self, h):
        return len(h.deleted)

    def cadaclysm_blacksmith_history_deleted_at(self, h, i, operand, id_):
        row = self._entry("history_deleted_at", h.deleted, i)
        if row is None:
            return False
        operand._obj.value, id_._obj.value = row
        return True

    # -- attributes: the wasm hands a solid's (a face's) keys and values over as two whole lists;
    # C's count and `_at` readers are answered from them, each refusal under its own C name
    def _texts(self, what: str, export: str, *args):
        result = getattr(self, "cadaclysm_blacksmith_" + export)(*args)
        if self._error is not None:
            lead, colon, rest = self._error.partition(":")
            self._error = what + colon + rest if colon else self._error
            return None
        return [str(v) for v in result]

    def cadaclysm_blacksmith_attribute_count(self, solid):
        keys = self._texts("attribute_count", "attribute_keys", solid)
        return 0 if keys is None else len(keys)

    def cadaclysm_blacksmith_face_attribute_count(self, solid, face):
        keys = self._texts("face_attribute_count", "face_attribute_keys", solid, face)
        return NONE if keys is None else len(keys)

    def _text_at(self, what: str, texts, i: int):
        if texts is None:
            return None
        if not 0 <= i < len(texts):
            self._error = f"{what}: attribute {i} of {len(texts)}"
            return None
        return texts[i].encode()

    def cadaclysm_blacksmith_attribute_key_at(self, solid, i):
        return self._text_at("attribute_key_at", self._texts("attribute_key_at", "attribute_keys", solid), i)

    def cadaclysm_blacksmith_attribute_value_at(self, solid, i):
        return self._text_at("attribute_value_at", self._texts("attribute_value_at", "attribute_values", solid), i)

    def cadaclysm_blacksmith_face_attribute_key_at(self, solid, face, i):
        return self._text_at("face_attribute_key_at", self._texts("face_attribute_key_at", "face_attribute_keys", solid, face), i)

    def cadaclysm_blacksmith_face_attribute_value_at(self, solid, face, i):
        return self._text_at("face_attribute_value_at", self._texts("face_attribute_value_at", "face_attribute_values", solid, face), i)

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

    def health_object(self, solid: int, tolerance: float, mesh: bool) -> "Any":
        """`cadaclysm_blacksmith_health`'s wasm export: the whole report as one JS object of
        flat rows (`counts`, `sizes`, `freeEdgeIds`, ...), not the handle C hands back and
        reads through six accessors. Not a C entry point, so it sits outside the table."""
        from pyodide.ffi import JsException
        self._error = None
        try:
            return self._js.cadaclysm_blacksmith_health(solid, tolerance, mesh)
        except JsException as e:
            if self._trapped(e):
                raise
            raise BuildError(self._message(e)) from None

    def healed_object(self, solid: int, tolerance: float, flags: int) -> "Any":
        """`cadaclysm_blacksmith_healed`'s wasm export: the healed solid's handle (`solid`) and
        the whole report as one JS object of flat rows (`counts`, `sizes`, `fixItems`, ...),
        not the handle C hands back and reads through five accessors. Not a C entry point,
        so it sits outside the table."""
        from pyodide.ffi import JsException
        self._error = None
        try:
            return self._js.cadaclysm_blacksmith_healed(solid, tolerance, flags)
        except JsException as e:
            if self._trapped(e):
                raise
            raise BuildError(self._message(e)) from None

    def __getattr__(self, name):
        prefix = "cadaclysm_blacksmith_"   # str.removeprefix is 3.9+; this module runs on 3.8
        short = name[len(prefix):] if name.startswith(prefix) else name
        if name.startswith("cadaclysm_bim_"):
            # The building documents' entry points keep their own prefix in the wasm too;
            # `short` keeps `bim_` so it never meets a `cadaclysm_blacksmith_` one's tables.
            short = name[len("cadaclysm_"):]
        if name == short or name.startswith("_"):
            raise AttributeError(name)
        try:
            function = getattr(self._js, self._RENAMED.get(name, name))
        except AttributeError:
            raise BuildError(f"the wasm module has no {name}: rebuild it with `sh web/build.sh`") from None
        dropped = self._DROP.get(short, ())

        def call(*args):
            from pyodide.ffi import JsException
            _checked_u32(name, args)
            self._error = None
            if short == "select_face" and args[2] is None:
                args = (args[0], args[1], (c_double * 0)(), args[3])   # the direction, unread for kinds 0/1/3
            if short == "clash" and args[2] is None:
                # `b` null with a zero count is "`a` against itself" in C; the export reads an
                # empty array the same way, and has no null to read
                args = (args[0], args[1], (c_void_p * 0)(), *args[3:])
            if short == "swept_clash" and args[3] is None:
                # one set: `b` and `poses_b` null with a zero count, empty arrays to the export
                args = (*args[:3], (c_void_p * 0)(), args[4], (c_double * 0)(), *args[6:])
            if short == "thickness_gauge_face" and args[3] is None:
                # `at` null is "over the face's vertices" in C; the export reads an empty array so
                args = (args[0], args[1], args[2], (c_double * 0)(), *args[4:])
            if short == "fem_mesh":
                # cadaclysm_blacksmith_fem_mesh(solid, frame, tolerance, max_size, progress):
                # the options struct behind `ctypes.byref(o)` (args[2]) becomes its two
                # fields, as `svg_text`'s becomes a flat array below, because the wasm
                # export takes them as scalars and has no options-init to fill a struct
                # (see its own doc comment in crates/cadaclysm-wasm/src/blacksmith.rs).
                # `frame` stays as it is: `None` for the identity, which reaches the
                # export's `Option<Float64Array>` as `null` -- never a zero-length array,
                # which that export refuses as a frame of no numbers.
                o = args[2]._obj
                args = (args[0], args[1], o.tolerance, o.max_size, args[3], args[4])
            if short == "step_assembly":
                # The module pads all four of its arrays to at least one entry, so
                # ctypes always has a buffer to point at even with nothing to write.
                # Over the wasm the two counts that say how much of each is real
                # (args[2], args[5]) are dropped -- a typed array carries its own
                # length -- so the padding has to come off here, or an empty call
                # would arrive as one null part at a one-number frame.
                parts, places = args[2], args[5]
                args = ((c_void_p * parts)(*args[0][:parts]), (c_char_p * parts)(*args[1][:parts]), parts,
                        (c_uint32 * places)(*args[3][:places]), (c_double * (12 * places))(*args[4][:12 * places]),
                        places, args[6], args[7])
            if short == "svg_text":
                # cadaclysm_blacksmith_svg_text(solids: &[u32], words: &[f64]) -- the
                # options struct behind `ctypes.byref(o)` (args[2]) has no cheaper way
                # to cross into JS than its own twelve fields after `size`, in struct
                # order (`up` an integral f64 like `stroke`/`background`/`flags`); see
                # the wasm export's own doc comment in crates/cadaclysm-wasm/src/blacksmith.rs.
                o = args[2]._obj
                args = (args[0], args[1], (c_double * 12)(
                    o.up, o.azimuth, o.elevation, o.fov, o.width, o.height,
                    o.margin, o.tolerance, o.stroke_width, o.stroke, o.background, o.flags,
                ))
            if short == "silhouette_beziers":
                # cadaclysm_blacksmith_silhouette_beziers(solid: u32, words: &[f64]) -- the
                # same twelve-word flattening as svg_text below, the options struct
                # behind args[1]; the count out-param (args[2]) is dropped and filled
                # back from the returned array's length in `_back`.
                o = args[1]._obj
                args = (args[0], (c_double * 12)(
                    o.up, o.azimuth, o.elevation, o.fov, o.width, o.height,
                    o.margin, o.tolerance, o.stroke_width, o.stroke, o.background, o.flags,
                ), args[2])
            if short == "drawing_svg_text":
                # cadaclysm_blacksmith_drawing_svg_text(solids: &[u32], profiles: &[u32],
                # words: &[f64]) -- the same twelve-word flattening as svg_text above,
                # with the options struct now behind args[4] (solids, solid_count,
                # profiles, profile_count, options); DROP's (1, 3) drops both counts,
                # leaving solids, profiles and words in that order.
                o = args[4]._obj
                args = (args[0], args[1], args[2], args[3], (c_double * 12)(
                    o.up, o.azimuth, o.elevation, o.fov, o.width, o.height,
                    o.margin, o.tolerance, o.stroke_width, o.stroke, o.background, o.flags,
                ))
            if short == "assembly_pair":
                # cadaclysm_blacksmith_assembly_pair(assembly, joint, kind, frame, end_frame,
                # lower, upper, pitch) -- lower/upper (args[5], args[6]) fold has_lower/
                # has_upper (args[7], args[8]) into themselves as `NaN` standing for "this
                # side unbounded", the wasm export's own convention (see its doc comment in
                # crates/cadaclysm-wasm/src/blacksmith.rs); freedom_count (args[9]) drops,
                # since a typed array carries its own length.
                lower, upper, has_lower, has_upper, count = args[5], args[6], args[7], args[8], args[9]
                if lower is None:
                    lo_nan = up_nan = None
                else:
                    lo_nan = (c_double * count)(*(lower[i] if has_lower[i] else float("nan") for i in range(count)))
                    up_nan = (c_double * count)(*(upper[i] if has_upper[i] else float("nan") for i in range(count)))
                args = (args[0], args[1], args[2], args[3], args[4], lo_nan, up_nan, args[10])
            if short == "assembly_pair_with":
                # cadaclysm_blacksmith_assembly_pair_with(assembly, joint, kind, frame,
                # end_frame, lower, upper, params) -- the ranges fold as assembly_pair's do,
                # and param_count (args[11]) drops with freedom_count: params (args[10]) is
                # a typed array carrying its own length, never null (the export takes a
                # plain array).
                lower, upper, has_lower, has_upper, count = args[5], args[6], args[7], args[8], args[9]
                if lower is None:
                    lo_nan = up_nan = None
                else:
                    lo_nan = (c_double * count)(*(lower[i] if has_lower[i] else float("nan") for i in range(count)))
                    up_nan = (c_double * count)(*(upper[i] if has_upper[i] else float("nan") for i in range(count)))
                params = args[10] if args[10] is not None else (c_double * 0)()
                args = (args[0], args[1], args[2], args[3], args[4], lo_nan, up_nan, params)
            if short == "n_sided_patch":
                # cadaclysm_blacksmith_n_sided_patch(ids: &[u32], ranges: &[f64], bulge, tolerance):
                # the `_PatchBoundary` rows (args[0], args[1] of them) have no cheaper way into JS
                # than their fields, the handles and indices 5 a row (a null sheet or curve 0) and
                # the range's two ends 2 a row; see the export's doc comment.
                rows = args[0][:args[1]]
                ids = [v for b in rows for v in (b.sheet or 0, b.face, b.side, b.level, b.curve or 0)]
                ends = [v for b in rows for v in (getattr(b, "from"), b.to)]
                args = ((c_uint32 * len(ids))(*ids), (c_double * len(ends))(*ends), args[2], args[3], args[4])
            if short == "nurbs_curve_closest_object":
                # (curve, kinds, count, solids, n, curves, n, points, n, projectors, n, meshes, n, max,
                # tolerance, out): the five arrays fold back into the export's one list of items, in
                # order, `{solid: h}`, `{curve: h}`, `{point: [x, y, z]}`, `{projector: h}` or
                # `{mesh: h}` each (`_arg` passes a list of dicts as a JS array of objects). The
                # arrays are padded to one entry for ctypes; the counts say how much is real.
                kinds, count = args[1], args[2]
                taken = {0: 0, 1: 0, 2: 0, 3: 0, 4: 0}
                items = []
                for k in kinds[:count]:
                    i = taken[k]
                    taken[k] += 1
                    if k == 2:
                        items.append({"point": [float(v) for v in args[7][3 * i:3 * i + 3]]})
                    else:
                        array = {0: args[3], 1: args[5], 3: args[9], 4: args[11]}[k]
                        items.append({("solid", "curve", None, "projector", "mesh")[k]: array[i] or 0})
                args = (args[0], items, args[13], args[14], args[15])
            if short == "triangle_mesh_new":
                # (positions, vertex_count, indices, triangle_count): `TriangleMesh` pads an empty
                # array to one entry for ctypes, and the export reads a typed array's own length --
                # so each is cut to its 3 * count, or `[]` would reach it as one stray number
                nv, nt = args[1], args[3]
                args = ((c_double * (3 * nv))(*args[0][:3 * nv]), nv, (c_uint32 * (3 * nt))(*args[2][:3 * nt]), nt)
            if short in self._PADDED:
                # `_curve_array` and `join_sheets` pad an empty list to one null handle for ctypes;
                # the count that says so drops, so the padding comes off here, as `step_assembly`'s does
                args = list(args)
                for at, count in self._PADDED[short]:
                    args[at] = (c_void_p * args[count])(*args[at][:args[count]])
                args = tuple(args)
            if short in self._PADDED_DOUBLES:
                # `_xyz` and `_transforms` pad an empty list to one double, likewise cut to the count
                args = list(args)
                at, count, per = self._PADDED_DOUBLES[short]
                args[at] = (c_double * (per * args[count]))(*args[at][:per * args[count]])
                args = tuple(args)
            passed = [self._arg(a) for i, a in enumerate(args) if i not in dropped]
            if short in self._U64_ARGS:
                import js
                passed = [js.BigInt(str(int(a))) if i in self._U64_ARGS[short] else a for i, a in enumerate(passed)]
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
            if a._type_ is c_char_p:   # a name per part (`step_assembly`), as a JS array of strings
                return to_js([v.decode("utf-8") for v in a])
            kind = (js.Float64Array if a._type_ is c_double else js.Uint8Array if a._type_ is c_uint8 else js.Int32Array if a._type_ is c_int32
                    else js.Uint32Array)
            return kind.new(to_js([v for v in a]))
        if isinstance(a, list):   # a list of plain dicts (`nurbs_curve_closest_object`'s items): JS objects
            return to_js(a, dict_converter=js.Object.fromEntries)
        if callable(a):   # (phase, done, total), or `document_evaluate_with`'s (node, phase, done, total)
            return lambda *xs: a(*xs[:-2], int(xs[-2]), int(xs[-1]))
        raise BuildError(f"the wasm backend cannot pass {type(a).__name__}")

    def _back(self, short, args, result):
        """The wasm's return, as the C call's: written into the out-argument
        and `True` where C fills one, `bytes` where C returns a C string, the
        mesh/polyline arrays under the C struct's names, else as it is."""
        if short in ("mesh_file", "bim_sheet_pdf", "bim_sheets_pdf"):
            # the bytes themselves (a `Uint8Array`); the length into the `c_size_t` behind `ctypes.byref`
            data = bytes(result.to_py())
            args[-1]._obj.value = len(data)
            return data
        if short in ("3dm_bytes", "assembly_3dm_bytes"):
            # `{bytes, notes}`: the bytes themselves (the length into the `c_size_t`
            # behind `ctypes.byref`), and what C leaves in `last_error` on success
            data = bytes(result.bytes.to_py())
            args[-1]._obj.value = len(data)
            notes = str(result.notes)
            self._error = notes or None
            return data
        if short == "edge":
            raw = args[2]._obj   # the `_Edge` behind `ctypes.byref(raw)`; the arrays live in it
            raw.kind = str(result.kind).encode()
            raw.faces = (c_uint32 * len(result.faces))(*[int(v) for v in result.faces])
            raw.face_count = len(result.faces)
            raw.segments = (c_double * len(result.segments))(*[float(v) for v in result.segments])
            raw.segment_count = len(result.segments) // 6
            return True
        if short == "hit":   # the record, into the `_Hit` behind `ctypes.byref(raw)`
            raw = args[2]._obj
            raw.run, raw.touch = bool(result.run), bool(result.touch)
            for name in ("start", "end"):
                p = getattr(result, name)
                setattr(raw, name, _Point(float(p[0]), float(p[1]), float(p[2])))
            for name in ("a_start", "a_end", "b_start", "b_end"):
                s = getattr(result, name)
                setattr(raw, name, _Spot(int(s.loop_index), int(s.segment), float(s.t),
                                         int(s.face), float(s.u), float(s.v)))
            return True
        if short == "hits_piece":   # `inside` and the two spots, into the `c_bool` and `_Spot`s behind `ctypes.byref`
            args[2]._obj.value = bool(result.inside)
            for at, name in ((3, "start"), (4, "end")):
                raw, s = args[at]._obj, getattr(result, name)
                raw.loop_index, raw.segment, raw.t = int(s.loop_index), int(s.segment), float(s.t)
                raw.face, raw.u, raw.v = int(s.face), float(s.u), float(s.v)
            return True
        if short in ("edge_curve", "intersection_curve"):   # the record, into the `_Curve` behind `ctypes.byref(raw)`
            raw = args[2]._obj
            raw.kind = str(result.kind).encode()
            for name in ("origin", "x", "y", "z"):
                p = getattr(result, name)
                setattr(raw, name, _Point(float(p[0]), float(p[1]), float(p[2])))
            raw.radius, raw.radius2 = float(result.radius), float(result.radius2)
            raw.t0, raw.t1, raw.degree = float(result.t0), float(result.t1), int(result.degree)
            # the arrays live in fresh `c_double` arrays kept on the struct (as `edge` keeps its)
            raw.knots = (c_double * len(result.knots))(*[float(v) for v in result.knots])
            raw.knot_count = len(result.knots)
            raw.poles = (c_double * len(result.poles))(*[float(v) for v in result.poles])
            raw.pole_count = len(result.poles) // 3
            weights = getattr(result, "weights", None)
            raw.weights = None if weights is None else (c_double * len(weights))(*[float(v) for v in weights])
            return True
        if short == "intersection_chain":   # the record, into the `_Chain` behind `ctypes.byref(raw)`
            raw = args[2]._obj
            raw.points = (c_double * len(result.points))(*[float(v) for v in result.points])
            raw.point_count = len(result.points) // 3
            raw.face_a, raw.face_b = int(result.face_a), int(result.face_b)
            raw.closed, raw.tangent, raw.has_curve = bool(result.closed), bool(result.tangent), bool(result.has_curve)
            return True
        if short == "check_finding":   # the record, into the `_Finding` behind `ctypes.byref(raw)`
            raw = args[2]._obj
            raw.kind = str(result.kind).encode("utf-8")
            raw.argument, raw.index, raw.other = int(result.argument), int(result.index), int(result.other)
            raw.size = float(result.size)
            return True
        if short == "intersection_overlap":   # the record, into the `_Overlap` behind `ctypes.byref(raw)`
            raw = args[2]._obj
            raw.face_a, raw.face_b = int(result.face_a), int(result.face_b)
            raw.points = (c_double * len(result.points))(*[float(v) for v in result.points])
            raw.point_count = len(result.points) // 3
            raw.loop_offsets = (c_uint32 * len(result.loop_offsets))(*[int(v) for v in result.loop_offsets])
            raw.loop_count = len(result.loop_offsets)
            return True
        if short in ("solid_bounds_box", "box_moved"):   # a `Box`'s six numbers, into the `_Box` behind `ctypes.byref(raw)`
            raw = args[2]._obj
            # `result` is a JS typed array under Pyodide: sliced directly it raises
            # "Slice subscripting isn't implemented for typed arrays" (a JsProxy
            # limitation), so it is read out to a plain Python list first, as
            # `bounds`/`bounds64` above already do for the same reason.
            values = [float(v) for v in result]
            raw.lo[:] = values[0:3]
            raw.hi[:] = values[3:6]
            return True
        if short == "boxes_apart":   # the answer, into the `c_bool` behind `ctypes.byref`
            args[4]._obj.value = bool(result)
            return True
        if short == "mass_properties":
            # The 34 figures, in `_MassProperties`' own field order, into the struct behind
            # `ctypes.byref(raw)` -- the export's doc comment in crates/cadaclysm-wasm/src/
            # blacksmith.rs says why they cross flat. Read out to a plain list first: a JS
            # typed array cannot be sliced under Pyodide, as `solid_bounds_box` notes above.
            raw = args[2]._obj
            v = [float(x) for x in result]
            if len(v) != 34:
                raise BuildError(f"mass_properties: the wasm returned {len(v)} figures, not 34")
            raw.closed, raw.inverted, raw.accuracy_met, raw.from_mesh = (int(x) for x in v[0:4])
            raw.area, raw.area_error, raw.volume, raw.volume_error = v[4:8]
            raw.centroid[:] = v[8:11]
            raw.centroid_error = v[11]
            raw.inertia[:] = v[12:21]
            raw.inertia_error = v[21]
            raw.principal_moments[:] = v[22:25]
            raw.principal_axes[:] = v[25:34]
            return True
        if short == "oriented_box":   # 15 doubles -- centre, axes row-major, half -- into the `_OrientedBox`
            raw, v = args[2]._obj, [float(x) for x in result]
            if len(v) != 15:
                raise BuildError(f"oriented_box: the wasm returned {len(v)} figures, not 15")
            raw.centre[:], raw.axes[:], raw.half[:] = v[0:3], v[3:12], v[12:15]
            return True
        if short in ("edge_length", "profile_length", "nurbs_curve_length"):   # 4 doubles, into the `_Length` (flags as 1.0/0.0)
            raw, v = args[3 if short == "edge_length" else 2]._obj, [float(x) for x in result]
            if len(v) != 4:
                raise BuildError(f"{short}: the wasm returned {len(v)} figures, not 4")
            raw.length, raw.error, raw.accuracy_met, raw.from_polyline = v[0], v[1], int(v[2]), int(v[3])
            return True
        if short in ("edge_point_at_length", "profile_point_at_length", "nurbs_curve_point_at_length"):   # 10 doubles, into the `_At`
            _at_from_doubles(args[4 if short == "edge_point_at_length" else 3]._obj, [float(x) for x in result], short)
            return True
        if short in ("nurbs_curve_fit", "nurbs_curve_fair", "nurbs_curve_faired", "nurbs_curve_projected_to_face", "nurbs_curve_pulled_to_face",
                     "nurbs_curve_offset_on_sheet", "sweep_rail", "sweep_two_rails", "edge_surface", "network_surface", "flange", "extrude_to",
                     "surface_faired"):
            # `[curve or sheet, error]`: the error into the `c_double` behind `ctypes.byref`, last
            v = [float(x) for x in result]
            args[-1]._obj.value = v[1]
            return int(v[0])
        if short == "fillet_surfaces":   # `[sheet, rail_a, rail_b, error]`: each behind its `ctypes.byref`
            v = [float(x) for x in result]
            args[9]._obj.value, args[10]._obj.value, args[11]._obj.value = int(v[1]), int(v[2]), v[3]
            return int(v[0])
        if short == "join_sheets":   # `[solid, 6 figures, closed]`, into the `_JoinReport`
            v = [float(x) for x in result]
            if len(v) != 8:
                raise BuildError(f"{short}: the wasm returned {len(v)} figures, not 8")
            raw = args[3]._obj
            raw.sewn, raw.naked_before, raw.naked_after, raw.refused, raw.turned = (int(x) for x in v[1:6])
            raw.worst_gap, raw.closed = v[6], int(v[7])
            return int(v[0])
        if short == "recess":   # `[solid, sheet, fillet, walls, pane]`, the counts into the `uint32_t[4]`
            v = [float(x) for x in result]
            if len(v) != 5:
                raise BuildError(f"{short}: the wasm returned {len(v)} figures, not 5")
            args[7][:] = [int(x) for x in v[1:]]
            return int(v[0])
        if short == "mirror_join":   # `[solid, seams, squared, moved, gap, angle, curvature, naked]`, into the `double[7]`
            v = [float(x) for x in result]
            if len(v) != 8:
                raise BuildError(f"{short}: the wasm returned {len(v)} figures, not 8")
            args[4][:] = v[1:]
            return int(v[0])
        if short in ("pattern_rectangular", "pattern_circular", "pattern_along"):
            # the placements themselves, 16 doubles each: C's count, and into `out` when given
            v = [float(x) for x in result]
            if args[-1] is not None:
                args[-1][:len(v)] = v
            return len(v) // 16
        if short in ("pattern", "pattern_feature"):   # `[solid, instances, booleans, missed]`, into the `double[3]`
            v = [float(x) for x in result]
            if len(v) != 4:
                raise BuildError(f"{short}: the wasm returned {len(v)} figures, not 4")
            if args[-1] is not None:
                args[-1][:] = v[1:]
            return int(v[0])
        if short == "hole":   # `[solid, holes, faces_added, bottom...]`, into the `double[2]` and the bottoms
            v = [float(x) for x in result]
            if args[14] is not None:
                args[14][:] = v[1:3]
            if args[15] is not None:
                args[15][:len(v) - 3] = v[3:]
            return int(v[0])
        if short in ("continuity", "edge_continuity"):   # 13 doubles, into the `_Continuity`
            raw, v = args[7 if short == "continuity" else 3]._obj, [float(x) for x in result]
            if len(v) != 13:
                raise BuildError(f"{short}: the wasm returned {len(v)} figures, not 13")
            raw.gap, raw.angle, raw.curvature, raw.samples = v[0], v[4], v[8], int(v[12])
            raw.gap_at[:], raw.angle_at[:], raw.curvature_at[:] = v[1:4], v[5:8], v[9:12]
            return True
        if short == "curvature_turns":   # 7 numbers, into the `_CurvatureTurns`
            raw, v = args[3]._obj, [int(x) for x in result]
            if len(v) != 7:
                raise BuildError(f"{short}: the wasm returned {len(v)} figures, not 7")
            (raw.gaussian_positive, raw.gaussian_negative, raw.gaussian_turns, raw.mean_positive, raw.mean_negative,
             raw.mean_turns, raw.samples) = v
            return True
        if short == "highlight_kink":   # 11 numbers, into the `_HighlightKink`
            raw, v = args[3]._obj, [float(x) for x in result]
            if len(v) != 11:
                raise BuildError(f"{short}: the wasm returned {len(v)} figures, not 11")
            raw.angle, raw.samples = v[0], int(v[10])
            raw.at[:], raw.light_point[:], raw.light_direction[:] = v[1:4], v[4:7], v[7:10]
            return True
        if short == "curvature_turn_points":   # 10 doubles a point, none for a face that keeps its signs
            v = [float(x) for x in result]
            if len(v) % 10:
                raise BuildError(f"{short}: the wasm returned {len(v)} figures, not 10 a point")
            return _WasmSamples(v)
        if short == "panel_gap":   # `[left, right]`, into the caller's `out` array
            args[5][0], args[5][1] = (int(v) for v in result)
            return True
        if short == "nurbs_curve_tween":   # the tweens' handles, into the caller's `out` array
            handles = [int(v) for v in result]
            args[7][0:len(handles)] = handles
            return True
        if short == "nurbs_curve_curvature":   # 14 doubles, into the `_Curvature`
            raw, v = args[2]._obj, [float(x) for x in result]
            if len(v) != 14:
                raise BuildError(f"{short}: the wasm returned {len(v)} figures, not 14")
            raw.kappa = v[0]
            raw.tangent[:], raw.normal[:], raw.binormal[:], raw.centre[:] = v[1:4], v[4:7], v[7:10], v[10:13]
            raw.has_centre = int(v[13])
            return True
        if short == "nurbs_curve_knot_continuity":   # 10 doubles, into the `_KnotContinuity`
            raw, v = args[1]._obj, [float(x) for x in result]
            if len(v) != 10:
                raise BuildError(f"{short}: the wasm returned {len(v)} figures, not 10")
            raw.angle, raw.angle_parameter, raw.curvature, raw.curvature_parameter = v[0], v[1], v[5], v[6]
            raw.angle_at[:], raw.curvature_at[:] = v[2:5], v[7:10]
            return True
        if short == "nurbs_curve_inflections":   # 10 doubles an inflection, none for a curve bending one way
            v = [float(x) for x in result]
            if len(v) % 10:
                raise BuildError(f"{short}: the wasm returned {len(v)} figures, not 10 an inflection")
            return _WasmSamples(v)
        if short in _DIVIDES:   # 10 doubles a sample: the list itself, which `_samples` reads
            v = [float(x) for x in result]
            if not v or len(v) % 10:
                raise BuildError(f"{short}: the wasm returned {len(v)} figures, not 10 a sample")
            return _WasmSamples(v)
        if short == "regions":   # 9 doubles a region, then 2 a side: the list itself, which `_regions` reads
            return _WasmRows([float(x) for x in result])
        if short in _RTREE_QUERIES:   # 2 doubles a row: the list itself, which `_rtree_hits`/`_rtree_pairs` read
            v = [float(x) for x in result]
            if len(v) % 2:
                raise BuildError(f"{short}: the wasm returned {len(v)} figures, not 2 a row")
            return _WasmRows(v)
        if short in ("classifier_contains", "contains"):   # the code, into the `c_uint32` behind `ctypes.byref`
            args[2 if short == "classifier_contains" else 3]._obj.value = int(result)
            return True
        if short == "closest":   # the record, into the `_Closest` behind `ctypes.byref(raw)`
            raw = args[5]._obj
            raw.distance = float(result.distance)
            raw.on_a[:] = [float(v) for v in result.on_a]
            raw.on_b[:] = [float(v) for v in result.on_b]
            # C's `kind_*` are static strings; here the struct keeps the encoded bytes alive itself
            raw.kind_a, raw.index_a, raw.edge_a = str(result.kind_a).encode(), int(result.index_a), int(result.edge_a)
            raw.kind_b, raw.index_b, raw.edge_b = str(result.kind_b).encode(), int(result.index_b), int(result.edge_b)
            raw.refined = 1 if bool(result.refined) else 0
            return True
        if short in ("closest_point", "projector_closest_point", "face_closest_point"):
            # a foot object into the `_PointFoot` behind `ctypes.byref(raw)` and C's 1; the
            # export's null (beyond `max_distance`) is C's 0, the struct untouched
            if _js_null(result):
                return 0
            _foot_into(args[{"closest_point": 4, "projector_closest_point": 3, "face_closest_point": 3}[short]]._obj, result)
            return 1
        if short in ("edge_closest_point", "nurbs_curve_closest_point"):   # five doubles into the out-array, C's 1
            v = [float(x) for x in result]
            if len(v) != 5:
                raise BuildError(f"{short}: the wasm returned {len(v)} figures, not 5")
            args[3 if short == "edge_closest_point" else 2][0:5] = v
            return 1
        if short in ("nurbs_curve_closest_point_within", "nurbs_curve_closest_points", "curve_closest_points",
                     "projector_curve_closest_points", "nurbs_curve_closest_object"):
            # closest points from a curve: the export's null (beyond `max_distance`) is C's 0, the
            # out-argument untouched; else its answer into the out-argument, the last, and C's 1
            if _js_null(result):
                return 0
            out = args[-1]
            if short == "nurbs_curve_closest_point_within":   # five doubles, as `nurbs_curve_closest_point`'s
                v = [float(x) for x in result]
                if len(v) != 5:
                    raise BuildError(f"{short}: the wasm returned {len(v)} figures, not 5")
                out[0:5] = v
            elif short == "nurbs_curve_closest_points":
                _pair_into(out._obj, result)
            elif short == "nurbs_curve_closest_object":
                raw = out._obj
                raw.which, raw.answer_kind = int(result.which), int(result.answer_kind)
                raw.distance, raw.t = float(result.distance), float(result.t)
                raw.point_on_curve[:] = [float(v) for v in result.point_on_curve]
                raw.point_on_item[:] = [float(v) for v in result.point_on_item]
                if raw.answer_kind == 0:
                    _curve_body_into(raw.body, result.body)
                elif raw.answer_kind == 1:
                    _pair_into(raw.pair, result.pair)
                elif raw.answer_kind == 3:
                    _curve_mesh_into(raw.mesh, result.mesh)
            else:
                _curve_body_into(out._obj, result)
            return 1
        if short in ("triangle_mesh_closest_point", "triangle_mesh_curve_closest_points"):
            # the export's null (beyond `max_distance`) is C's 0, the struct untouched; else its
            # object into the struct behind `ctypes.byref`, the last argument, and C's 1
            if _js_null(result):
                return 0
            (_mesh_point_into if short == "triangle_mesh_closest_point" else _curve_mesh_into)(args[-1]._obj, result)
            return 1
        if short == "collider_stats":   # the nine counts, into the `_ColliderStats` behind `ctypes.byref(raw)`
            raw = args[1]._obj
            for name in ("considered", "world_boxes", "oriented_boxes", "skipped_share", "cached",
                         "closed_form", "meshed", "refused", "confirmed"):
                setattr(raw, name, int(getattr(result, name)))
            return True
        if short == "collisions_hit":   # the record, into the `_CollisionHit` behind `ctypes.byref(raw)`
            raw = args[2]._obj
            raw.a, raw.b = int(result.a), int(result.b)
            raw.overlap, raw.depth = bool(result.overlap), float(result.depth)
            raw.positions = (c_double * len(result.positions))(*[float(v) for v in result.positions])
            raw.normals = (c_double * len(result.normals))(*[float(v) for v in result.normals])
            raw.indices = (c_uint32 * len(result.indices))(*[int(v) for v in result.indices])
            raw.vertex_count = len(result.positions) // 3
            raw.index_count = len(result.indices)
            raw.text = str(result.text).encode()
            return True
        if short == "clashes_at":   # the row, into the `_Clash` behind `ctypes.byref(raw)`
            raw = args[2]._obj
            raw.a, raw.b = int(result.a), int(result.b)
            raw.kind, raw.distance = str(result.kind).encode(), float(result.distance)
            raw.on_a[:] = [float(v) for v in result.on_a]
            raw.on_b[:] = [float(v) for v in result.on_b]
            raw.kind_a, raw.index_a, raw.edge_a = str(result.kind_a).encode(), int(result.index_a), int(result.edge_a)
            raw.kind_b, raw.index_b, raw.edge_b = str(result.kind_b).encode(), int(result.index_b), int(result.edge_b)
            raw.refined, raw.depth = 1 if bool(result.refined) else 0, float(result.depth)
            raw.text = str(result.text).encode()
            return True
        if short == "swept_clashes_at":   # the row, into the `_SweptClash` behind `ctypes.byref(raw)`
            raw = args[2]._obj
            raw.a, raw.b = int(result.a), int(result.b)
            raw.first_time, raw.interval_count = float(result.first_time), int(result.interval_count)
            return True
        if short == "thickness_gauge_mesh":   # the copies, into the `_ThicknessMesh` behind `ctypes.byref(raw)`
            # kept as ctypes arrays on the struct (as `subd_smooth_mesh` keeps its), so
            # `ThicknessGauge.mesh` reads the same pointers on both backends
            raw = args[2]._obj
            positions, normals = [float(v) for v in result.positions], [float(v) for v in result.normals]
            indices, faces = [int(v) for v in result.indices], [int(v) for v in result.faces]
            raw.positions, raw.normals = (c_double * len(positions))(*positions), (c_double * len(normals))(*normals)
            raw.indices, raw.faces = (c_uint32 * len(indices))(*indices), (c_uint32 * len(faces))(*faces)
            raw.vertex_count, raw.triangle_count = len(positions) // 3, len(faces)
            return True
        if short == "thickness_gauge_face":   # `{found, ...}`, into the `_FaceThickness`; a null number is C's NaN
            raw = args[5]._obj
            raw.found, raw.uniform = bool(result.found), bool(result.uniform)
            raw.thickness, raw.min, raw.max = (_js_number(getattr(result, name)) for name in ("thickness", "min", "max"))
            return True
        if short == "thicknesses_at":   # the row, into the `_Thickness`; null `vertex` is C's NONE, null `sphere` NaN
            raw = args[2]._obj
            raw.body, raw.face = int(result.body), int(result.face)
            raw.vertex = NONE if _js_null(result.vertex) else int(result.vertex)
            raw.point[:] = [float(v) for v in result.point]
            raw.thickness = float(result.thickness)
            raw.opposite[:] = [float(v) for v in result.opposite]
            raw.opposite_body, raw.opposite_face = int(result.opposite_body), int(result.opposite_face)
            raw.knife, raw.exact_thickness = bool(result.knife), float(result.exact_thickness)
            raw.exact_opposite[:] = [float(v) for v in result.exact_opposite]
            raw.sphere = _js_number(result.sphere)
            return True
        if short == "mesh_thicknesses_at":   # the row, into the `_MeshThickness`
            raw = args[2]._obj
            raw.mesh, raw.vertex, raw.thickness = int(result.mesh), int(result.vertex), float(result.thickness)
            raw.point[:] = [float(v) for v in result.point]
            raw.opposite[:] = [float(v) for v in result.opposite]
            raw.opposite_mesh, raw.opposite_triangle = int(result.opposite_mesh), int(result.opposite_triangle)
            raw.knife = bool(result.knife)
            return True
        if short == "subd_parts":   # the copies, into the `_SubdParts` behind `ctypes.byref(raw)`
            # Kept as ctypes arrays on the struct (as `collisions_hit` keeps its), so `Subd`
            # reads the views the same way on both backends; the counts are the C struct's,
            # not the arrays' lengths (vertices, faces, pairs).
            raw = args[1]._obj
            positions = [float(v) for v in result.positions]
            sizes, loop = [int(v) for v in result.face_sizes], [int(v) for v in result.face_indices]
            creases, pins = [int(v) for v in result.creases], [int(v) for v in result.pins]
            selection, kind = [int(v) for v in result.selection], int(result.selection_kind)
            raw.positions, raw.vertex_count = (c_double * len(positions))(*positions), len(positions) // 3
            raw.face_sizes, raw.face_count = (c_uint32 * len(sizes))(*sizes), len(sizes)
            raw.face_indices, raw.index_count = (c_uint32 * len(loop))(*loop), len(loop)
            raw.creases, raw.crease_count = (c_uint32 * len(creases))(*creases), len(creases) // 2
            raw.pins, raw.pin_count = (c_uint32 * len(pins))(*pins), len(pins)
            raw.symmetry_axis, raw.symmetry_tolerance = int(result.symmetry_axis), float(result.symmetry_tolerance)
            raw.selection_kind = kind
            raw.selection = (c_uint32 * len(selection))(*selection)
            raw.selection_count = len(selection) // 2 if kind == 1 else len(selection)
            return True
        if short == "subd_smooth_mesh":   # the copies, into the `_SubdMesh` behind `ctypes.byref(raw)`
            raw = args[2]._obj
            positions, normals = [float(v) for v in result.positions], [float(v) for v in result.normals]
            indices, faces = [int(v) for v in result.indices], [int(v) for v in result.triangle_face]
            raw.positions, raw.vertex_count = (c_double * len(positions))(*positions), len(positions) // 3
            raw.normals = (c_double * len(normals))(*normals)
            raw.indices, raw.index_count = (c_uint32 * len(indices))(*indices), len(indices)
            raw.triangle_face = (c_uint32 * len(faces))(*faces)
            return True
        if short == "subd_pick":
            # `[a, b]` into C's two-id out-array; null is "nothing near", which C gives as
            # `false` with an **empty** `last_error` (never a refusal's text). A JS `null`
            # may arrive as Pyodide's `jsnull` rather than `None`, so both are read as it.
            try:
                from pyodide.ffi import jsnull
            except ImportError:   # an older Pyodide, whose JS null is always `None`
                jsnull = None
            if result is None or result is jsnull:
                self._error = ""
                return False
            args[3][0:2] = [int(v) for v in result]
            return True
        if short in ("solid_transform", "solid_convert_to_nurbs"):   # `[solid, inexact]`: the count behind `ctypes.byref`
            values = [int(v) for v in result]
            args[2]._obj.value = values[1]
            return values[0]
        if short == "n_sided_patch":   # `[solid, 28 numbers]`: the report into the `_PatchReport` behind `ctypes.byref`
            v = [float(x) for x in result]
            raw = args[4]._obj
            raw.faces = int(v[1])
            for c, at in ((raw.boundary, 2), (raw.internal, 15)):
                c.gap, c.gap_at[:], c.angle, c.angle_at[:] = v[at], v[at + 1:at + 4], v[at + 4], v[at + 5:at + 8]
                c.curvature, c.curvature_at[:], c.samples = v[at + 8], v[at + 9:at + 12], int(v[at + 12])
            raw.corner_angle = v[28]
            return int(v[0])
        if short == "subd_to_solid":   # `[solid, report]`: the report into the `_SubdReport` behind `ctypes.byref`
            handle, report = result[0], result[1]
            raw = args[4]._obj
            raw.regular, raw.refined = int(report.regular), int(report.refined)
            raw.steps, raw.levels = int(report.steps), int(report.levels)
            raw.deviation, raw.g1_angle_deg = float(report.deviation), float(report.g1_angle_deg)
            raw.deviation_at[:] = [float(v) for v in report.deviation_at]
            raw.g1_at[:] = [float(v) for v in report.g1_at]
            return int(handle)
        if short == "fem_mesh_view":   # the arrays and the summary, into the `_FemMeshView` behind `ctypes.byref(raw)`
            raw = args[1]._obj
            # The typed arrays are copied into ctypes arrays kept on the struct (as
            # `edge` keeps its), rather than handed on as JS objects: a pointer field
            # cannot hold one, and `_view` reads a ctypes array the same way on either
            # backend. `nodes`/`triangles`/`node_kind` are new names, so this is a
            # branch of its own rather than an entry in `_JsArrays`.
            raw.nodes = (c_double * len(result.nodes))(*[float(v) for v in result.nodes])
            raw.triangles = (c_uint32 * len(result.triangles))(*[int(v) for v in result.triangles])
            raw.triangle_face = (c_uint32 * len(result.triangle_face))(*[int(v) for v in result.triangle_face])
            raw.node_kind = (c_uint32 * len(result.node_kind))(*[int(v) for v in result.node_kind])
            raw.node_entity = (c_uint32 * len(result.node_entity))(*[int(v) for v in result.node_entity])
            raw.node_count, raw.triangle_count = int(result.node_count), int(result.triangle_count)
            raw.face_count, raw.edge_count = int(result.face_count), int(result.edge_count)
            raw.vertex_count = int(result.vertex_count)
            raw.open_edge_count = int(result.open_edge_count)
            raw.folded_edge_count = int(result.folded_edge_count)
            raw.watertight, raw.from_mesh = bool(result.watertight), bool(result.from_mesh)
            raw.min_angle, raw.worst_triangle = float(result.min_angle), int(result.worst_triangle)
            raw.longest_edge = float(result.longest_edge)
            return True
        if short == "fem_mesh_edge":   # the record, into the `_FemEdge` behind `ctypes.byref(raw)`
            raw = args[2]._obj
            # The counts are the arrays' own lengths: the wasm object carries no
            # `node_count`/`run_count`, a typed array knowing its own length.
            raw.id = int(result.id)
            raw.nodes = (c_uint32 * len(result.nodes))(*[int(v) for v in result.nodes])
            raw.node_count = len(result.nodes)
            raw.runs = (c_uint32 * len(result.runs))(*[int(v) for v in result.runs])
            raw.run_count = len(result.runs)
            raw.face_a, raw.face_b = int(result.face_a), int(result.face_b)
            raw.end_a, raw.end_b = int(result.end_a), int(result.end_b)
            raw.closed, raw.seam = bool(result.closed), bool(result.seam)
            return True
        if short == "fem_mesh_vertex":   # the record, into the `_FemVertex` behind `ctypes.byref(raw)`
            raw = args[2]._obj
            raw.node = int(result.node)
            raw.point[:] = [float(v) for v in result.point]   # a fixed array in the struct, not a pointer
            raw.has_position = bool(result.has_position)
            return True
        if short in ("fem_mesh_open_edge", "fem_mesh_folded_edge"):   # a census row, into three `c_uint32`s
            for at, name in ((2, "a"), (3, "b"), (4, "brep_edge")):
                args[at]._obj.value = int(getattr(result, name))
            return True
        if short == "fem_mesh_crossing":   # a crossing, into two `c_uint32`s
            args[2]._obj.value = int(result.a)
            args[3]._obj.value = int(result.b)
            return True
        if short in ("face_origin_at", "edge_origin_at"):   # `[operand, id]`, into the two out-pointers
            operand, id_ = (int(v) for v in result)
            args[3]._obj.value, args[4]._obj.value = operand, id_
            return True
        if short in ("face_id", "edge_id"):   # a `BigInt`, as the `int` ctypes reads a `uint64_t` as
            return int(result)
        if short in ("attribute", "face_attribute"):   # C's null where there is none; `b""` is an empty value
            return None if _js_null(result) else str(result).encode()
        if short in ("colour", "profile_colour", "edge_colour"):   # three doubles, or null where there is no colour: C's `false`
            if result is None:
                return False
            out = args[1] if short == "profile_colour" else args[2]
            out[0:3] = [float(v) for v in result]
            return True
        if short == "silhouette_beziers":
            # sixteen doubles a curve, the count into the `c_uint32` behind `ctypes.byref`;
            # an empty array is the empty answer, which C gives as null with no error
            args[2]._obj.value = len(result) // 16
            return result if len(result) else None
        if short in ("profile_loops", "profile_chain_order"):   # the loops' records, or the `[index, turned]` pairs, into C's `uint32_t` out-array
            values = [int(v) for v in result]
            args[3][0:len(values)] = values
            return True
        if short in self._LISTS:   # the ids, copied out; the count into the `c_size_t` behind `ctypes.byref`
            ids = [int(v) for v in result]
            args[self._LISTS[short]]._obj.value = len(ids)
            return ids
        if short == "option_get":   # the value, into the `c_double` behind `ctypes.byref`
            args[1]._obj.value = float(result)
            return True
        if short == "solid_tolerances":   # `[absolute, angular]`, into the two `c_double`s behind `ctypes.byref`
            for out, v in zip(args[1:3], result):
                if out is not None:
                    out._obj.value = float(v)
            return True
        if short == "parse_colour":   # [r, g, b] into the `c_double * 3` out-array
            args[1][:] = [float(v) for v in result]
            return True
        if short == "edge_polyline_colours":   # the `Float64Array`, under the C struct's names
            return _JsColours(result)
        if short == "manifold":   # eight counts, into C's `uint32_t` out-array
            args[1][0:8] = [int(v) for v in result]
            return True
        if short in ("bounds", "bounds64"):
            values = [float(v) for v in result]
            args[2][0:3], args[3][0:3] = values[0:3], values[3:6]
            return True
        if short in ("box", "job_stock"):
            values = [float(v) for v in result]
            args[1][0:3], args[2][0:3] = values[0:3], values[3:6]
            return True
        if short == "frame_fit":   # 13 numbers: the frame into `out`, the deviation behind `ctypes.byref`, if asked
            values = [float(v) for v in result]
            args[2][0:12] = values[0:12]
            if args[3] is not None:
                args[3]._obj.value = values[12]
            return True
        if short in self._SCALARS:
            args[self._SCALARS[short]][0] = float(result)
            return True
        if short in self._OUT:
            out = args[self._OUT[short]]
            out[0:len(out)] = [float(v) for v in result]
            return True
        if short in self._BOOLS:
            return True
        if short in self._TEXTS:
            return str(result).encode()
        if short in ("mesh", "mesh64", "edge_polylines", "profile_polylines"):
            return _JsArrays(result)
        if short == "mesh_face_triangles":   # the counts themselves, a `Uint32Array`
            return _JsArrays(result, "counts")
        return result


def _foot_into(raw: "_PointFoot", foot) -> None:
    """A wasm point-foot object into a `_PointFoot`, as C fills it."""
    raw.distance = float(foot.distance)
    raw.point[:] = [float(v) for v in foot.point]
    # C's `kind` is a static string; here the struct keeps the encoded bytes alive itself
    raw.kind, raw.index, raw.edge = str(foot.kind).encode(), int(foot.index), int(foot.edge)
    raw.uv[:] = [float(v) for v in foot.uv]
    raw.normal[:] = [float(v) for v in foot.normal]
    raw.refined = 1 if bool(foot.refined) else 0


def _pair_into(raw: "_CurvePair", pair) -> None:
    """A wasm curve-pair object into a `_CurvePair`."""
    raw.distance, raw.t_a, raw.t_b = float(pair.distance), float(pair.t_a), float(pair.t_b)
    raw.point_a[:] = [float(v) for v in pair.point_a]
    raw.point_b[:] = [float(v) for v in pair.point_b]


def _curve_body_into(raw: "_CurveBodyFoot", found) -> None:
    """A wasm curve-body object into a `_CurveBodyFoot`, its `body` a point-foot object."""
    raw.distance, raw.t = float(found.distance), float(found.t)
    raw.point_on_curve[:] = [float(v) for v in found.point_on_curve]
    _foot_into(raw.body, found.body)
    raw.crossing = 1 if bool(found.crossing) else 0


def _mesh_point_into(raw: "_MeshPoint", found) -> None:
    """A wasm mesh-point object into a `_MeshPoint`, as C fills it: `kind` its number, the
    `vertices` the export dropped back as NONE."""
    raw.point[:] = [float(v) for v in found.point]
    raw.distance, raw.triangle = float(found.distance), int(found.triangle)
    raw.barycentric[:] = [float(v) for v in found.barycentric]
    kind = str(found.kind)
    if kind not in _MESH_KINDS:
        raise BuildError(f"triangle mesh: the wasm answered kind {kind!r}, not face, edge or vertex")
    raw.kind = _MESH_KINDS.index(kind)
    vertices = [int(v) for v in found.vertices]
    if len(vertices) > 2:
        raise BuildError(f"triangle mesh: the wasm answered {len(vertices)} vertices, not 2 at most")
    raw.vertices[:] = vertices + [NONE] * (2 - len(vertices))


def _curve_mesh_into(raw: "_CurveMeshFoot", found) -> None:
    """A wasm curve-mesh object into a `_CurveMeshFoot`, its `mesh` a mesh-point object."""
    raw.distance, raw.t = float(found.distance), float(found.t)
    raw.point_on_curve[:] = [float(v) for v in found.point_on_curve]
    _mesh_point_into(raw.mesh, found.mesh)
    raw.crossing = 1 if bool(found.crossing) else 0


def _js_null(value) -> bool:
    """A JS `null` as Pyodide hands it over: `None`, or `pyodide.ffi.jsnull` in a Pyodide that
    keeps the two apart (as `subd_pick` reads it)."""
    if value is None:
        return True
    try:
        from pyodide.ffi import jsnull
    except ImportError:   # an older Pyodide, whose JS null is always `None`
        return False
    return value is jsnull


def _js_number(value) -> float:
    """A JS number, or C's NaN for a JS `null` (the wasm's spelling of "none")."""
    return float("nan") if _js_null(value) else float(value)


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


class _JsColours:
    """An `edge_polyline_colours` result: the typed array as `rgb`, and `count` (`rgb` is
    falsy when empty, as the C struct's null pointer is)."""

    def __init__(self, js_array):
        self.rgb = js_array if len(js_array) else None
        self.count = len(js_array) // 3


_library = None
_flavour: tuple[str, str] = ("", "")


def _short_name(name: str) -> str:
    """An entry point's name as its refusals spell it: `thickness_gauge_at` for
    `cadaclysm_blacksmith_thickness_gauge_at`, `bim_...` for `cadaclysm_bim_...`."""
    for prefix in ("cadaclysm_blacksmith_", "cadaclysm_"):
        if name.startswith(prefix):
            return name[len(prefix):]
    return name


# Each entry point's `c_uint32` argument positions. ctypes wraps an int past 32 bits (or a
# negative one, -1 becoming NONE) without a word, and the wasm truncates a float, so an index
# like 2**32 or 0.5 would quietly read 0: every such argument is checked on its way in.
_U32_ARGS = {name: tuple(i for i, t in enumerate(argtypes) if t is c_uint32)
             for name, _restype, argtypes in _ENTRY_POINTS}


def _checked_u32(name: str, args) -> None:
    for i in _U32_ARGS.get(name, ()):
        if i >= len(args):
            break
        value = args[i]
        if isinstance(value, (bool, ctypes._SimpleCData)):   # a flag, or already a C integer
            continue
        try:
            k = operator.index(value)
        except TypeError:
            k = None
        if k is None or not 0 <= k <= 0xFFFFFFFF:
            raise BuildError(f"{_short_name(name)}: argument {i + 1} {value!r} is not a whole number "
                             "from 0 to 4294967295")


def _u32_guarded(name: str, function):
    def call(*args):
        _checked_u32(name, args)
        return function(*args)
    call.__name__ = name
    return call


def _lib() -> ctypes.CDLL:
    global _library, _flavour
    if _library is None:
        if _WASM:
            _library = _WasmLibrary()
            return _library
        path = library_path()
        library = ctypes.CDLL(str(path))
        # A flavour of the single library binds what it has: an entry point it leaves out
        # (the writers and parts in the kernel and kernel-reader flavours) becomes a call
        # that raises, naming the flavour. A flavour with no kernel (the reader flavour)
        # is refused here, at first use. A separate library of an earlier release must
        # have every entry point, as before.
        flavoured = _flavour_of(library)
        if flavoured is not None and "kernel" not in flavoured[1].split(","):
            raise BuildError(
                f"{path}: the '{flavoured[0]}' flavour has no kernel; load cadaclysm, "
                "cadaclysm_kernel_reader or cadaclysm_kernel")
        for name, restype, argtypes in _ENTRY_POINTS:
            try:
                function = getattr(library, name)
            except AttributeError:
                if flavoured is not None:
                    setattr(library, name, _not_in_flavour(name, *flavoured))
                    continue
                raise BuildError(
                    f"{path} has no {name}: the library is older than this copy of "
                    f"cadaclysm_blacksmith.py, which declares {len(_ENTRY_POINTS)} entry points. "
                    "Rebuild it with `cargo build --release -p cadaclysm-blacksmith-capi`."
                ) from None
            function.restype, function.argtypes = restype, argtypes
            if _U32_ARGS[name]:
                setattr(library, name, _u32_guarded(name, function))
        _flavour = flavoured or ("kernel", "")
        _library = library
    return _library


def flavour() -> str:
    """Which library this is: `"full"`, `"kernel-reader"` or `"kernel"` for a flavour of the
    single library, `"kernel"` for the separate `cadaclysm_blacksmith` of earlier releases,
    `"wasm"` in the browser."""
    if _WASM:
        return "wasm"
    _lib()
    return _flavour[0]


def features() -> str:
    """The features the library was built with, comma-separated
    (`"nodes,kernel,write-breps,write-meshes,bim,parts"`), or `""` for the separate
    `cadaclysm_blacksmith` of earlier releases and in the browser."""
    if _WASM:
        return ""
    _lib()
    return _flavour[1]


def _text(raw) -> str:
    return raw.decode("utf-8", "replace") if raw else ""


def _fail(what: str) -> NoReturn:
    """Raise the library's own reason, or `what` if it left none."""
    raise BuildError(_text(_lib().cadaclysm_blacksmith_last_error()) or what)


def _fail_tessellation(what: str) -> NoReturn:
    """`_fail` for a call routed through `cadaclysm_blacksmith_tessellation`: that entry
    point fails with a leading "tessellation:" naming itself, not the caller, so this
    rewrites that prefix back to `what` -- the method name `mesh`/`mesh64`/
    `mesh_face_triangles`/`edge_polylines` reported before each held a tessellation of its
    own -- leaving the rest of the library's message untouched."""
    reason = _text(_lib().cadaclysm_blacksmith_last_error())
    prefix = "tessellation:"
    if reason.startswith(prefix):
        reason = what + ":" + reason[len(prefix):]
    raise BuildError(reason or what)


# A NUL truncates silently going through ctypes (a native call never sees what
# follows it), so the kernel's own control-character refusal for a job name
# never fires natively -- only under Pyodide, where the wasm kernel reads the
# whole string. Catch it here instead, in the kernel's own words, so both paths
# refuse alike.
_NUL_NAME_ERROR = "job: a name must be non-empty and without brackets, slashes, quotes, control characters, or : * ? < > |"


def _reject_nul(s: str) -> None:
    if "\0" in s:
        raise BuildError(_NUL_NAME_ERROR)


def _colour_text(text: str):
    """(r, g, b) in 0..1 from colour text -- "#rgb", "#rrggbb" or a CSS colour name --
    read by the library's own parser, so every wrapper takes the same forms; None if
    the library refused it."""
    out = (c_double * 3)()
    if _lib().cadaclysm_blacksmith_parse_colour(text.encode("utf-8"), out):
        return tuple(out)
    return None


def _packed(colour) -> int:
    """A colour as the ABI's packed `0xRRGGBB`: "#rgb", "#rrggbb", a CSS colour name or
    an `(r, g, b)` triple in 0..255."""
    if isinstance(colour, str):
        rgb = _colour_text(colour)
        if rgb is None:
            raise ValueError(f'colour {colour!r}: a colour is "#rgb", "#rrggbb", a CSS colour name or (r, g, b) in 0..255')
        r, g, b = (round(c * 255) for c in rgb)
    else:
        r, g, b = colour
    return (int(r) << 16) | (int(g) << 8) | int(b)


def _svg_options(*, view="iso", az=None, el=None, up=None, fov=0.0, size=(1000, 1000), margin=0.05,
                 tolerance=0.1, stroke="#000000", width=1.0, background=None, edges=True, curves=False,
                 isocurves=False, polylines=False, silhouettes=True, hidden=None) -> _SvgOptions:
    """`Solid.svg`/`svg()`'s keywords, packed into `CadaclysmBlacksmithSvgOptions` --
    as the reader's own `_svg_options`, but with no scene convention to default
    `up` from: a solid's own frame is Z up unless `up=` says otherwise, as
    `show`'s `view.options` already defaults it. Colours as `"#rgb"`,
    `"#rrggbb"`, a CSS colour name or an (r, g, b) triple in 0..255."""
    VIEWS = _viewer().VIEWS   # the same search show() uses: cadaclysm_view.py is not
                              # beside this file, so a bare import only works by accident

    if view not in VIEWS:
        raise ValueError(f"view {view!r}: one of {', '.join(VIEWS)}")
    base_az, base_el = VIEWS[view]
    o = _SvgOptions()
    # The wasm has no svg_options_init export (its svg_text takes the fields that follow
    # `size` as numbers, every one set below), so only the DLL is asked for its defaults.
    if not _WASM:
        _lib().cadaclysm_blacksmith_svg_options_init(ctypes.byref(o))
    o.up = 1 if (up or "z").lower() == "y" else 0
    o.azimuth = float(base_az if az is None else az)
    o.elevation = float(base_el if el is None else el)
    o.fov = float(fov)
    o.width, o.height = float(size[0]), float(size[1])
    o.margin, o.tolerance, o.stroke_width = float(margin), float(tolerance), float(width)
    o.stroke = _packed(stroke)
    o.background = NONE if background is None else _packed(background)
    # `silhouettes` (16) is a line set in its own right: alone it draws an
    # outline-only page. Only naming nothing at all is refused. It is ON by
    # default, matching `cadaclysm_blacksmith_svg_options_init`, because
    # `edges=` alone cannot draw every body: a sphere's and a torus's only
    # curves are their seams, which are not edges of the body and are never
    # drawn, so those two came back as a blank page. `silhouettes=False`
    # gives the old edges-only drawing.
    # `hidden`: None draws every line; "removed" draws what is seen of each solid (hidden-line
    # removal, the solids hiding one another); "dashed" draws that and the hidden lines dashed.
    if hidden not in _SVG_HIDDEN:
        raise ValueError(f"hidden {hidden!r}: None, 'removed' or 'dashed'")
    o.flags = ((1 if edges else 0) | (2 if curves else 0) | (4 if isocurves else 0)
               | (8 if polylines else 0) | (16 if silhouettes else 0) | _SVG_HIDDEN[hidden])
    return o


# `svg(hidden=...)`: CADACLYSM_BLACKSMITH_SVG_HIDDEN_REMOVED (32) and _HIDDEN_DASHED (64).
_SVG_HIDDEN = {None: 0, "removed": 32, "dashed": 64}


def _rgb(colour):
    """(r, g, b) from "#rgb", "#rrggbb", a CSS colour name or three numbers; the range
    is the library's to check."""
    if isinstance(colour, str):
        rgb = _colour_text(colour)
        if rgb is not None:
            return rgb
    else:
        try:
            r, g, b = (float(c) for c in colour)
            return r, g, b
        except (TypeError, ValueError):
            pass
    raise BuildError(f'coloured: a colour is "#rgb", "#rrggbb", a CSS colour name or (r, g, b) in 0..1, not {colour!r}')


def _indices(value, call, param, edges=False):
    """A list argument as indices: `value` must be a list -- any iterable but a string, a
    number or an `Edge` -- and each item an index (a whole number, 0 to 4294967295) or,
    where `edges`, an `Edge`. Refused here, named, before the kernel is asked: one edge is
    `[edge]`, never read as none."""
    what = "Edge objects or indices" if edges else "indices"
    if isinstance(value, (str, bytes, numbers.Number, Edge)) or not hasattr(value, "__iter__"):
        thing = "an Edge" if isinstance(value, Edge) else repr(value)
        raise TypeError(f"{call}: {param} must be a list of {what}, not {thing}")
    item_is = "an Edge or an index" if edges else "an index"
    out = []
    for i, item in enumerate(value):
        if edges and isinstance(item, Edge):
            out.append(item.index)
            continue
        try:
            k = operator.index(item)
        except TypeError:
            shown = "an Edge" if isinstance(item, Edge) else repr(item)
            raise TypeError(f"{call}: {param}[{i}] is not {item_is}: {shown}") from None
        if not 0 <= k <= 0xFFFFFFFF:
            raise ValueError(f"{call}: {param}[{i}] is not {item_is}: {k}")
        out.append(k)
    return out


def _joint_path(key) -> str:
    """A joint or state key as the kernel reads it: a str as it is; a tuple or list of
    names escaped ("\\" before every "/" and "\\" in a name) and joined by "/"."""
    if isinstance(key, str):
        return key
    return "/".join(str(n).replace("\\", "\\\\").replace("/", "\\/") for n in key)


def _names(value, call, param):
    """A list argument of names: `value` must be a list -- any iterable but a string -- and
    each item a `str`. Refused here, named, before the kernel is asked: one name is
    `[name]`, never read a character at a time."""
    if isinstance(value, (str, bytes)) or not hasattr(value, "__iter__"):
        raise TypeError(f"{call}: {param} must be a list of names, not {value!r}")
    out = []
    for i, item in enumerate(value):
        if not isinstance(item, str):
            raise TypeError(f"{call}: {param}[{i}] is not a name: {item!r}")
        out.append(item)
    return out


def _checked(handle, what: str):
    if not handle:
        _fail(what)
    return handle


def _profile_list(handle, what: str) -> "list[Profile]":
    """The profiles of a list the library handed back (null: raise), each as a handle
    of its own, the list freed."""
    if not handle:
        _fail(what)
    lib = _lib()
    try:
        n = lib.cadaclysm_blacksmith_profile_list_count(handle)
        return [Profile(_checked(lib.cadaclysm_blacksmith_profile_list_get(handle, i), "profile_list_get")) for i in range(n)]
    finally:
        lib.cadaclysm_blacksmith_profile_list_free(handle)


def _ok(done, what: str) -> None:
    """A bool entry point's result: raise the library's reason where it is false."""
    if not done:
        _fail(what)


def _programs(handle, what: str) -> "list[Program]":
    """The files of a program list the library handed back (null: raise), copied
    out as `Program`s -- the list's strings live only as long as it does -- and
    the list freed."""
    if not handle:
        _fail(what)
    lib = _lib()
    try:
        n = lib.cadaclysm_blacksmith_programs_count(handle)
        if n == NONE:
            _fail("programs_count")
        out = []
        for i in range(n):
            tool = lib.cadaclysm_blacksmith_programs_tool(handle, i)
            name = lib.cadaclysm_blacksmith_programs_name(handle, i)
            text = lib.cadaclysm_blacksmith_programs_text(handle, i)
            if tool == NONE or name is None or text is None:
                _fail("programs")
            out.append(Program(tool, name.decode("utf-8"), text.decode("utf-8")))
        return out
    finally:
        lib.cadaclysm_blacksmith_programs_free(handle)


def _report(handle, what: str) -> "Report":
    """A report the library handed back (null: raise), read eagerly into `ReportItem`s
    -- each item's region copied out through `_profile_list` -- and the report freed:
    no handle from this call outlives it."""
    if not handle:
        _fail(what)
    lib = _lib()
    try:
        n = lib.cadaclysm_blacksmith_report_count(handle)
        if n == NONE:
            _fail("report_count")
        items = []
        for i in range(n):
            kind = lib.cadaclysm_blacksmith_report_kind(handle, i)
            if kind is None:
                _fail("report_kind")
            out = (c_double * 3)()
            if not lib.cadaclysm_blacksmith_report_at(handle, i, out):
                _fail("report_at")
            size = lib.cadaclysm_blacksmith_report_size(handle, i)
            top = lib.cadaclysm_blacksmith_report_top(handle, i)
            bottom = lib.cadaclysm_blacksmith_report_bottom(handle, i)
            reason = lib.cadaclysm_blacksmith_report_reason(handle, i)
            if reason is None:
                _fail("report_reason")
            region = _profile_list(lib.cadaclysm_blacksmith_report_region(handle, i), "report_region")
            items.append(ReportItem(kind.decode("utf-8"), (out[0], out[1], out[2]), size, reason.decode("utf-8"), region, top, bottom))
        text = lib.cadaclysm_blacksmith_report_text(handle)
        if text is None:
            _fail("report_text")
        return Report(items, text.decode("utf-8"))
    finally:
        lib.cadaclysm_blacksmith_report_free(handle)


def _operation_param(name: str, value: float):
    """One `operations_param_value`, typed as the spec picks by its name: `side`
    0/1/2 to "outside"/"inside"/"on", `climb`/`open` to bool, `points` to int, a
    `NaN` `peck` to `None`; every other value stays a float."""
    if name == "side":
        return {0.0: "outside", 1.0: "inside", 2.0: "on"}.get(value, value)
    if name in ("climb", "open"):
        return bool(value)
    if name == "points":
        return int(value)
    if name == "peck":
        return None if math.isnan(value) else value
    return value


def _operations(handle, what: str) -> "list[Operation]":
    """The operations of a list the library handed back (null: raise), read eagerly
    into `Operation`s, and the list freed: no handle from this call outlives it."""
    if not handle:
        _fail(what)
    lib = _lib()
    try:
        n = lib.cadaclysm_blacksmith_operations_count(handle)
        if n == NONE:
            _fail("operations_count")
        out = []
        for i in range(n):
            kind = lib.cadaclysm_blacksmith_operations_kind(handle, i)
            tool = lib.cadaclysm_blacksmith_operations_tool(handle, i)
            if kind is None or tool == NONE:
                _fail("operations")
            param_count = lib.cadaclysm_blacksmith_operations_param_count(handle, i)
            if param_count == NONE:
                _fail("operations_param_count")
            params = {}
            for k in range(param_count):
                name = lib.cadaclysm_blacksmith_operations_param_name(handle, i, k)
                if name is None:
                    _fail("operations_param_name")
                name = name.decode("utf-8")
                value = lib.cadaclysm_blacksmith_operations_param_value(handle, i, k)
                params[name] = _operation_param(name, value)
            out.append(Operation(kind.decode("utf-8"), tool, params))
        return out
    finally:
        lib.cadaclysm_blacksmith_operations_free(handle)


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
                         "IGES, IFC, OpenSCAD), not a mesh, a curve or a CSG body")
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
    """One block of borrowed memory, exposed through the array interface so the numpy
    view is read-only and holds its owner as its `.base`.

    **The owner is whatever the memory belongs to.** A `FemMesh`'s arrays borrow from
    that handle, so the owner is the `FemMesh` and its `free()` is what invalidates
    them; a solid's mesh arrays borrow from a held `_Tessellation`, so the owner is
    that handle, freed only when the last view of it is. A profile's tessellation
    cache is never lent this way -- `_copied` reads it through one of these with no
    owner and copies it out at once."""

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
    numpy = _numpy()
    if _WASM:
        from pyodide.ffi import JsProxy
        # A JS typed array lives in the JS heap, which has no address this side, so it
        # is copied out -- read-only, with a `.base` as a borrowed view has, but it
        # never invalidates. A **ctypes** pointer under Pyodide is addressable
        # exactly as on the desktop and falls through to the borrowed path:
        # `fem_mesh_view`'s own `_back` branch converts its typed arrays into ctypes
        # arrays kept on the out-struct, so the FEM arrays come through here the same
        # way on both backends.
        #
        # `isinstance` against `JsProxy` rather than `hasattr(pointer, "to_bytes")`,
        # which is what a JS object and a plain `int` both answer to: a future caller
        # handing this a raw address would otherwise take this branch silently and fail
        # inside `frombuffer` instead of being read as the pointer it is.
        if isinstance(pointer, JsProxy):
            if 0 in shape:
                return numpy.zeros(shape, dtype=dtype)
            array = numpy.frombuffer(pointer.to_bytes(), dtype=dtype).reshape(shape)
            array.flags.writeable = False
            return array
    if not pointer or 0 in shape:
        return numpy.zeros(shape, dtype=dtype)
    return numpy.asarray(_Borrowed(owner, pointer, shape, numpy.dtype(dtype).str))


def _copied(pointer, shape, dtype):
    """`_view`, copied out: for a profile's tessellation cache -- a profile keeps every
    tolerance it has been asked at, so nothing about it is ever replaced, but a view into
    it would dangle once the profile itself closes (`Profile.close()` in the other
    wrappers; here, once collected), and there is no held handle of the kind a solid's
    tessellation gets to keep it open -- so `Profile.polylines` gets memory of its own --
    and for a solid's mesh arrays under Pyodide, where a JS typed array has no address
    this side to view. Read-only, as a borrowed view and the Pyodide copy are."""
    array = _view(None, pointer, shape, dtype)
    if isinstance(array.base, _Borrowed):
        array = array.copy()
        array.flags.writeable = False
    return array


def license(text_or_path: str | os.PathLike[str]) -> None:
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


def set_option(name: str, value: float) -> None:
    """Set a kernel option, by its name, for the whole process from the next call on.

    The options are numbers under stable names: ``"boolean.mesh_budget"``,
    ``"boolean.finest_tolerance"``, ``"profile_boolean.point_budget"``,
    ``"measure.default_accuracy"``, ``"tolerance.relative"``, ``"tolerance.angular"``,
    ``"step.validation_properties"`` and ``"step.validation_accuracy"`` (the module's
    tolerances section says what the tolerance pair does; the STEP pair is described at
    `Solid.step`). Raises `BuildError` -- and changes nothing -- for
    a name that is not an option or a value it does not take, saying which and what
    it takes.

    ``step.validation_properties`` (0 or 1, default 0) makes `Solid.step` and
    `write_step` stamp each body with its geometric validation properties -- the area,
    the volume and the centroid this kernel measures for it, in the file's own length
    unit, there for the kernel that reads the file to check the transfer against its own
    measurement. They are measured at ``step.validation_accuracy`` (default 1e-5, above
    0 and below 1), which is what the option costs: every body in the file, tens of
    seconds on a free-form one at a fine accuracy. With no schema named the file moves
    to AP242; a named schema that cannot state them raises. Assembly files never carry
    them, and a reader finds them again under a node's ``attributes``."""
    if not _lib().cadaclysm_blacksmith_option_set(str(name).encode("utf-8"), float(value)):
        _fail(f"option {name!r} refused")


def option(name: str) -> float:
    """A kernel option's value, by its name: what `set_option` last set, else its
    default. Raises `BuildError` for a name that is not an option, listing the ones
    there are."""
    out = c_double()
    if not _lib().cadaclysm_blacksmith_option_get(str(name).encode("utf-8"), ctypes.byref(out)):
        _fail(f"no option {name!r}")
    return out.value


class Tolerances(NamedTuple):
    """What a solid (or a file) declares about its own precision: `absolute`, a length in the
    model's own units, and `angular`, in radians -- each None where the source said nothing."""
    absolute: "float | None"
    angular: "float | None"


def _tolerance(tolerance: "float | None") -> float:
    """A verb's distance tolerance as the C ABI takes it: None is unset, NaN, which the
    library works at the inputs' `effective_tolerance` (as it does 0)."""
    return float("nan") if tolerance is None else float(tolerance)


def _declared(value: float) -> "float | None":
    return None if math.isnan(value) else float(value)


def effective_tolerance(*solids: "Solid") -> float:
    """The tolerance a verb given `tolerance=None` (or 0) works at over `solids`: the larger of
    the loosest absolute tolerance they declare and `option("tolerance.relative")` times the
    largest of their sizes, never finer than their coordinates can represent. 0 for no solids,
    or solids with nothing to size by -- which a verb refuses."""
    handles = [s._h() for s in solids]
    arr = (c_void_p * len(handles))(*handles)
    t = _lib().cadaclysm_blacksmith_effective_tolerance(arr, len(handles))
    if math.isnan(t):
        _fail("effective_tolerance")
    return float(t)


def pair_freedom_count(kind: str) -> int:
    """How many freedoms a pair kind has, so a caller can size `Assembly.pair`'s
    `ranges`. 0 for an unknown name, and for `fully_constrained`, which has none."""
    return int(_lib().cadaclysm_blacksmith_pair_freedom_count(kind.encode("utf-8")))


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
    """The view loader: `cadaclysm.view` (the wheel), `cadaclysm_view` on the
    path, then beside this module, then the reader's examples beside the kernel's in
    a checkout. A directory joins `sys.path` only when it holds `cadaclysm_view.py`.

    Imported when something is drawn (`show`/`view`), and by `_svg_options` for its
    `VIEWS` table alone -- `cadaclysm_view.py` lives in the reader's `examples/`,
    not this module's, so `svg()` needs the same search `show()` does rather than a
    bare `import cadaclysm_view` that only happens to work when that directory is
    already on `sys.path` for some other reason."""
    try:
        from cadaclysm import view
        return view
    except ImportError:
        pass
    try:
        import cadaclysm_view
        return cadaclysm_view
    except ModuleNotFoundError as e:
        if e.name != "cadaclysm_view":
            raise
    here = _FsPath(__file__).resolve().parent
    folders = [here]
    if len(here.parents) > 1:
        folders.append(here.parents[1] / "cadaclysm-capi" / "examples")
    for folder in folders:
        if (folder / "cadaclysm_view.py").is_file():
            if str(folder) not in sys.path:
                sys.path.append(str(folder))
            import cadaclysm_view
            return cadaclysm_view
    raise ModuleNotFoundError("no view loader: cadaclysm_view.py is neither installed nor beside "
                              "cadaclysm_blacksmith.py -- reinstall cadaclysm", name="cadaclysm_view")


def _lines_only(options):
    """A profile's keywords without `edges`: its lines are its picture, and the viewer
    draws no lines under NO_EDGES."""
    return {k: v for k, v in options.items() if k != "edges"}


def _not_in_the_notebook():
    """The notebook draws with its own show(obj): refused before anything is meshed
    or asked of the wasm, which may predate an entry point the drawing uses."""
    if sys.platform == "emscripten":
        raise RuntimeError("in the notebook, draw with show(obj)")


def _present(obj, mode, tolerance, default_view, kw) -> Any:
    """`show`/`view` through the view loader, by handle."""
    _not_in_the_notebook()
    return _viewer().present(mode, obj, name=type(obj).__name__, default_view=default_view, keywords=kw,
                             owner=type(obj).__name__.lower(), tolerance=tolerance)


def _job_stock_box(job: Job) -> Tuple[Tuple[float, ...], Tuple[float, ...]]:
    """The job's stock as `(min, max)` -- plan 4a's getters, the one place 4b reads them."""
    lo, hi = job.stock
    return tuple(float(v) for v in lo), tuple(float(v) for v in hi)


def _job_tool(job: Job, number: int) -> Tool:
    """The `Tool` the job was given as `T<number>` (plan 4a keeps them by number)."""
    try:
        return job.tools[number]
    except KeyError:
        raise ValueError(f"job.show: program uses T{number}, which the job does not hold") from None


def _tool_options(tool: Tool) -> Dict[str, Any]:
    """A tool's description as `cadaclysm_view`'s `show_machining` takes it."""
    out = {"number": tool.number, "shape": tool.shape, "diameter": tool.diameter, "flute_length": tool.flute_length}
    if tool.shape == "vbit":
        out["angle"] = tool.angle
    if tool.shape == "bullnose":
        out["corner_radius"] = tool.corner_radius
    return out


def _present_job(job: Job, mode: str, part: Optional[Solid], tolerance: float, kw: Dict[str, Any]) -> Any:
    """`Job.show`/`Job.view` through the view loader: the job's programs, tools and stock,
    and the part's mesh, played on the GPU library's stock."""
    _not_in_the_notebook()
    if part is not None and not isinstance(part, Solid):
        raise TypeError(f"job.{mode}: part must be a Solid, not {type(part).__name__}")
    spec = job._machining(part, tolerance)
    if not spec["programs"]:
        raise ValueError(f"job.{mode}: the job has no operations to play")
    return _viewer().present(mode, job, name="Job", default_view="iso", keywords=kw, owner="job",
                             tolerance=tolerance, machining=spec)


# ---- profiles -------------------------------------------------------------


class Profile:
    """A closed outline with holes, in its own x/y. Immutable; every method
    returns a new one."""

    __slots__ = ("_handle",)

    def __init__(self, handle: int | None):
        self._handle = _checked(handle, "profile")

    def __del__(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_profile_free(h)

    @staticmethod
    def rect(w: float, h: float) -> "Profile":
        return Profile(_lib().cadaclysm_blacksmith_profile_rect(w, h))

    @staticmethod
    def circle(r: float) -> "Profile":
        return Profile(_lib().cadaclysm_blacksmith_profile_circle(r))

    @staticmethod
    def slot(centre: Point2, length: float, r: float) -> "Profile":
        cx, cy = centre
        return Profile(_lib().cadaclysm_blacksmith_profile_slot(cx, cy, length, r))

    @staticmethod
    def polygon(points: Iterable[Point2]) -> "Profile":
        flat = [float(v) for p in points for v in p]
        n = len(flat) // 2
        return Profile(_lib().cadaclysm_blacksmith_profile_polygon((c_double * len(flat))(*flat), n))

    @staticmethod
    def regular_polygon(centre: Point2, radius: float, sides: int, angle: float = 0.0) -> "Profile":
        """A regular polygon of `sides` sides (3 to 1000000) on the circle of
        `radius` about `centre`, its first corner at `angle` radians from the
        sketch's x axis, the rest counter-clockwise."""
        cx, cy = centre
        return Profile(_lib().cadaclysm_blacksmith_profile_regular_polygon(cx, cy, radius, _u32(sides, "profile_regular_polygon: sides"), angle))

    @staticmethod
    def circumscribed_polygon(centre: Point2, radius: float, sides: int, angle: float = 0.0) -> "Profile":
        """A regular polygon of `sides` sides (3 to 1000000) whose sides touch the circle of
        `radius` about `centre` -- the polygon across flats, a nut's hex: its corners on the
        circle of `radius / cos(pi / sides)`, the first at `angle` radians from the sketch's x
        axis, the rest counter-clockwise, on the same rays as `regular_polygon`'s corners with
        the same `angle`; each side's midpoint on the circle of `radius`."""
        cx, cy = centre
        return Profile(_lib().cadaclysm_blacksmith_profile_circumscribed_polygon(cx, cy, radius, _u32(sides, "profile_circumscribed_polygon: sides"), angle))

    @staticmethod
    def star(centre: Point2, outer: float, inner: float, points: int, angle: float = 0.0) -> "Profile":
        """A star of `points` tips (3 to 1000000) on the circle of `outer` about
        `centre`, its inner corners on the circle of `inner` (positive, under
        `outer`), alternating: the first tip at `angle` radians from the
        sketch's x axis, the rest counter-clockwise."""
        cx, cy = centre
        return Profile(_lib().cadaclysm_blacksmith_profile_star(cx, cy, outer, inner, _u32(points, "profile_star: points"), angle))

    @staticmethod
    def spline(points: Iterable[Point2], degree: int = 3, weights: Iterable[float] | None = None,
               closed: bool = False) -> "Profile":
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
    def path(start: Point2) -> "Path":
        return Path(start)

    @staticmethod
    def parabola(vertex: Point2, axis: Point2, focal: float, from_: float, to: float) -> "Path":
        """Start drawing on the arc of the parabola with `vertex`, axis direction `axis`
        and focal length `focal`, over the across-axis coordinates `from_..to`: the path
        begins at the arc's first point and holds the arc -- a reflector from rim to rim,
        `Profile.parabola((0, 0), (0, 1), 20, -50, 50)` a dish 100 wide opening up."""
        vx, vy = vertex
        ax, ay = axis
        return Path._from_handle(_checked(_lib().cadaclysm_blacksmith_path_parabola(vx, vy, ax, ay, focal, from_, to), "path_parabola"))

    @staticmethod
    def chain(pieces: Iterable[Profile], tolerance: "float | None" = 1e-6) -> "Profile":
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
        return Profile(_lib().cadaclysm_blacksmith_profile_chain(handles, len(pieces), _tolerance(tolerance)))

    @staticmethod
    def from_loops(loops: Iterable[Profile]) -> "Profile":
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

    @staticmethod
    def polyline(points: Iterable[Point2], closed: bool = False) -> "Profile":
        """A polyline through `points` in order, a straight segment per side: an
        open chain, or `closed=True` with a side from the last point back to the
        first. A side of no length is kept, so a corner dragged onto its
        neighbour still draws. Raises `BuildError` for fewer than two points
        (three closed) or a coordinate not finite."""
        flat = [float(v) for p in points for v in p]
        n = len(flat) // 2
        return Profile(_lib().cadaclysm_blacksmith_profile_polyline((c_double * len(flat))(*flat), n, bool(closed)))

    @staticmethod
    def arc(centre: Point2, r: float, a0: float, a1: float) -> "Profile":
        """The arc of radius `r` about `centre` from angle `a0` counter-clockwise
        to `a1` (radians from the sketch's x axis), one exact arc, open: the
        sweep is taken the counter-clockwise way round, `a1` brought past `a0`
        when it is not. Equal angles are the whole circle, closed, starting at
        `a0`. Raises `BuildError` for a radius not positive and finite."""
        cx, cy = centre
        return Profile(_lib().cadaclysm_blacksmith_profile_arc(cx, cy, r, a0, a1))

    @staticmethod
    def arc_through(start: Point2, through: Point2, end: Point2) -> "Profile":
        """The arc from `start` through `through` to `end`, one exact arc leaving
        the start, open: the circle through the three points, swept the way round
        that passes `through`. Raises `BuildError` when the three are in a line."""
        (x0, y0), (xm, ym), (x1, y1) = start, through, end
        return Profile(_lib().cadaclysm_blacksmith_profile_arc_through(x0, y0, xm, ym, x1, y1))

    @staticmethod
    def ellipse(centre: Point2, rx: float, ry: float) -> "Profile":
        """The ellipse about `centre` with semi-axes `rx` along x and `ry` along
        y, closed: four exact quarter conics counter-clockwise from the point
        `rx` along x. Raises `BuildError` for a semi-axis not positive and finite."""
        cx, cy = centre
        return Profile(_lib().cadaclysm_blacksmith_profile_ellipse(cx, cy, rx, ry))

    @staticmethod
    def from_beziers(beziers: Iterable[float], recognise: bool = True) -> "Profile":
        """Rational cubic Béziers end to end -- sixteen numbers each, `x y z w`
        per control point, the record `beziers()` hands back -- as one open
        profile, the first one's start its start. `recognise`: a straight Bézier
        becomes an exact line and a circular one an exact arc, the rest kept as
        curves -- what a trim, an extrusion or a fillet wants; `False` keeps every
        Bézier as the exact cubic it is, so `chain` and `close_loop` hand the same
        Béziers back. Raises `BuildError` for none, a count not a multiple of
        sixteen, a number not finite or a weight not positive."""
        flat = [float(v) for v in beziers]
        if len(flat) % 16:
            raise BuildError(f"profile_from_beziers: {len(flat)} numbers are not whole Béziers of sixteen")
        return Profile(_lib().cadaclysm_blacksmith_profile_from_beziers((c_double * len(flat))(*flat), len(flat) // 16, bool(recognise)))

    def beziers(self, frame: "FrameLike | None" = None) -> "tuple[float, ...]":
        """This profile as rational cubic Béziers, sixteen numbers each (`x y z w`
        per control point, the point Cartesian and its weight beside it): a line
        one straight Bézier, an arc exact conic pieces of a quarter turn or less,
        a free-form side its own decomposition -- the outline from its start,
        then each hole's. On the sketch plane (z = 0), or with `frame` (twelve
        numbers, a `Frame`) carried onto that frame's plane."""
        lib = _lib()
        n = lib.cadaclysm_blacksmith_profile_bezier_count(self._handle)
        out = (c_double * (16 * n))()
        f = None if frame is None else (c_double * 12)(*_frame(frame))
        _ok(lib.cadaclysm_blacksmith_profile_beziers(self._handle, f, out), "profile_beziers")
        return tuple(out)

    @staticmethod
    def loops(pieces: Iterable[Profile], tolerance: "float | None" = 1e-6) -> "list[list[int]]":
        """The closed loops among `pieces`, each read by its two ends, the way a
        CAD sketch finds them: ends meet within `tolerance`; a loop is a chain of
        pieces through corners where exactly two ends meet (a corner of three or
        more is ambiguous, and no loop runs through it); a piece whose own ends
        meet, a closed one included, is a loop of its own. Each loop is its
        pieces' indices in the order it runs, from its lowest; each piece is in
        at most one. Raises `BuildError` for a piece with holes or nothing drawn."""
        pieces = list(pieces)
        handles = (c_void_p * len(pieces))(*[p._handle for p in pieces])
        out = (c_uint32 * (2 * len(pieces)))()
        _ok(_lib().cadaclysm_blacksmith_profile_loops(handles, len(pieces), _tolerance(tolerance), out), "profile_loops")
        flat, found, at = list(out), [], 0
        while at < len(flat) and flat[at]:   # a length of 0 ends the records
            found.append(flat[at + 1:at + 1 + flat[at]])
            at += 1 + flat[at]
        return found

    @staticmethod
    def chain_order(pieces: Iterable[Profile], tolerance: "float | None" = 1e-6) -> "list[tuple[int, bool]]":
        """The order `chain` takes `pieces` in, from the chain's start to its end:
        per piece its index and whether it was turned round to meet. Raises
        `BuildError` as `chain` does."""
        pieces = list(pieces)
        handles = (c_void_p * len(pieces))(*[p._handle for p in pieces])
        out = (c_uint32 * (2 * len(pieces)))()
        _ok(_lib().cadaclysm_blacksmith_profile_chain_order(handles, len(pieces), _tolerance(tolerance), out), "profile_chain_order")
        return [(int(out[2 * i]), bool(out[2 * i + 1])) for i in range(len(pieces))]

    def close_loop(self) -> "Profile":
        """This profile closed -- the forge's sketch "close": where its last segment
        stops short of its start (a path ended open), a straight segment back to it;
        where it already comes back to within 1e-9 of its extent, its last segment
        made to land on the start exactly. A closed profile comes back as it is.
        Holes are closed the same way."""
        return Profile(_lib().cadaclysm_blacksmith_profile_close_loop(self._handle))

    def with_hole(self, hole: "Profile") -> "Profile":
        return Profile(_lib().cadaclysm_blacksmith_profile_with_hole(self._handle, hole._handle))

    def to_arcs(self, tolerance: "float | None" = 0.01) -> "Profile":
        """This profile with every free-form side (a Bezier, a conic, a NURBS) replaced
        by lines and arcs within `tolerance` of it -- what a G-code writer can say.
        Lines and arcs pass through as they are, every loop closes on itself exactly,
        holes are converted the same way. Raises `BuildError` for a `tolerance` not
        positive and finite, or a spline that does not evaluate."""
        return Profile(_lib().cadaclysm_blacksmith_profile_to_arcs(self._handle, _tolerance(tolerance)))

    def offset(self, distance: float, tolerance: "float | None" = 0.01) -> "list[Profile]":
        """This profile grown by `distance` (shrunk where it is negative), as zero or
        more profiles, all lines and arcs: outward corners rounded by `|distance|`,
        holes moving against the boundary (a hole shrinks as the profile grows).
        Free-form sides are fitted to `tolerance` first (`to_arcs`). A shrink that
        eats the whole profile is an empty list. Raises `BuildError` for a `distance`
        not finite, a `tolerance` not positive and finite, a loop with no sides, or
        loops that cross or touch."""
        return _profile_list(_lib().cadaclysm_blacksmith_profile_offset(self._handle, distance, _tolerance(tolerance)), "profile_offset")

    def hits(self, other: Profile, tolerance: "float | None" = 1e-6) -> "list[Hit]":
        """Where this profile's curves cross, touch or run along `other`'s, both read in
        one plane, as :class:`Hit` values ordered along this profile. Points closer than
        `tolerance` merge; two curves within `tolerance` of each other for longer than it
        are one run when they part only where one ends or the stretch is flat -- one curve
        following the other, offset within `tolerance` or tilted by under about half of it,
        even where it leaves mid-both; a tangency or a shallow crossing is one point. A loop
        that stops short of its start is an open chain."""
        lib = _lib()
        h = lib.cadaclysm_blacksmith_profile_hits(self._handle, other._handle, _tolerance(tolerance))
        if not h:
            _fail("profile_hits")
        try:
            n = lib.cadaclysm_blacksmith_hit_count(h)
            raw = _Hit()
            out = []
            for i in range(n):
                if not lib.cadaclysm_blacksmith_hit(h, i, ctypes.byref(raw)):
                    _fail("hit")
                out.append(_hit_of(raw))
            return out
        finally:
            lib.cadaclysm_blacksmith_hits_free(h)

    def common(self, other: Profile, tolerance: "float | None" = 1e-6) -> "list[Profile]":
        """The region this profile and `other` share, both read in one plane, as zero or
        more profiles -- each boundary counter-clockwise, each hole clockwise, arcs and
        splines kept exact. Two loops of a result may touch at a point (two holes whose
        corners meet, one from each input): a right point set that the verbs needing
        simple loops -- `extrude`, a boolean taking it as an input -- refuse. Both must
        be closed and simple. No shared area is an empty list. Raises `BuildError` for a
        `tolerance` not positive and finite, a profile open or crossing itself, a
        `tolerance` too fine for these profiles (following their arcs and splines to a
        tenth of it would take more than 8 million points, about 128 MB), and, as a
        defect rather than an outcome, a result that fails to close."""
        return _profile_list(_lib().cadaclysm_blacksmith_profile_common(self._handle, other._handle, _tolerance(tolerance)), "profile_common")

    @staticmethod
    def text(text: str, size: float = 10.0, font: str | os.PathLike[str] = "",
             halign: Literal["left", "center", "right"] = "left",
             valign: Literal["baseline", "bottom", "center", "top"] = "baseline", spacing: float = 1.0,
             direction: Literal["ltr", "rtl"] = "ltr", font_bytes: bytes | None = None) -> "list[Profile]":
        """`text` set in a font, one profile per closed shape -- a letter with its
        counters as holes (`o` one, `8` two; `i` is two profiles) -- on the sketch
        plane, the baseline along x from the origin, each outline counter-clockwise
        and its holes clockwise, a curved side the font's own cubic Bezier kept
        exactly: an extruded `O` has curved walls. `size` is roughly the height of a
        capital. `font` is a family, optionally with a style
        (`"Liberation Sans:style=Bold"`), a font file's path, or empty for the bundled
        Liberation Sans Regular -- which also serves when the family is not found;
        `font_bytes` a font file's bytes, used instead of `font` when given. `halign`
        is "left", "center" or "right"; `valign` "baseline", "bottom", "center" or
        "top"; `spacing` multiplies the gap between glyphs; `direction` "ltr" or
        "rtl". Empty text is an empty list. Raises `BuildError` for a size or spacing
        not positive and finite, an alignment or direction not one of those words,
        font bytes that are not a font."""
        data = (c_uint8 * len(font_bytes))(*font_bytes) if font_bytes is not None else None
        h = _lib().cadaclysm_blacksmith_profile_text(str(text).encode("utf-8"), size, str(font).encode("utf-8"), data,
                                                     len(font_bytes) if font_bytes is not None else 0,
                                                     str(halign).encode("utf-8"), str(valign).encode("utf-8"), spacing, str(direction).encode("utf-8"))
        return _profile_list(h, "profile_text")

    def translate(self, dx: float, dy: float) -> "Profile":
        return Profile(_lib().cadaclysm_blacksmith_translate_profile(self._handle, dx, dy))

    def rotate(self, centre: Point2, radians: float) -> "Profile":
        """This outline turned `radians` (counter-clockwise) about `centre`."""
        cx, cy = centre
        return Profile(_lib().cadaclysm_blacksmith_profile_rotate(self._handle, float(cx), float(cy), float(radians)))

    def scale(self, centre: Point2, sx: float, sy: float) -> "Profile":
        """This outline scaled by `sx`, `sy` about `centre`: an arc stays an arc where the two
        are equal in size, and becomes exact conics otherwise. A negative factor mirrors; a
        zero one is singular and raises `BuildError`."""
        cx, cy = centre
        return Profile(_lib().cadaclysm_blacksmith_profile_scale(self._handle, float(cx), float(cy), float(sx), float(sy)))

    def mirror(self, point: Point2, direction: Point2) -> "Profile":
        """This outline reflected across the line through `point` along `direction`. A zero
        `direction` raises `BuildError`."""
        (px, py), (dx, dy) = point, direction
        return Profile(_lib().cadaclysm_blacksmith_profile_mirror(self._handle, float(px), float(py), float(dx), float(dy)))

    def transform2d(self, m: "Sequence[float]") -> "Profile":
        """This outline under the 2D affine map `m`, six numbers row-major (2×3):
        `x' = m0·x + m1·y + m2`, `y' = m3·x + m4·y + m5`. A singular map raises `BuildError`."""
        return Profile(_lib().cadaclysm_blacksmith_profile_transform2d(self._handle, _doubles(m, 6, "profile_transform2d")))

    def coloured(self, colour: Colour) -> "Profile":
        """This outline coloured -- `colour` is "#rgb", "#rrggbb", a CSS colour name
        or (r, g, b) in 0..1: how it is drawn. The verbs that make a profile from one
        carry it; a solid made from it takes nothing (colour a solid with `Solid.coloured`)."""
        r, g, b = _rgb(colour)
        return Profile(_lib().cadaclysm_blacksmith_profile_coloured(self._handle, r, g, b))

    @property
    def colour(self) -> "tuple[float, float, float] | None":
        """The outline's colour, (r, g, b) in 0..1, or None."""
        out = (c_double * 3)()
        if _lib().cadaclysm_blacksmith_profile_colour(self._handle, out):
            return tuple(out)
        if _text(_lib().cadaclysm_blacksmith_last_error()):
            _fail("profile_colour")
        return None

    def round(self, radius: float, corners: Iterable[int] | None = None, open: bool = False) -> "Profile":  # noqa: A002, A003
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
            ks = _indices(corners, "round", "corners")
            picked, count = (c_uint32 * len(ks))(*ks), len(ks)
        return Profile(_lib().cadaclysm_blacksmith_profile_round(self._handle, radius, picked, count, bool(open)))

    def pieces(self, cutters: Iterable[Profile], tolerance: "float | None" = 1e-6) -> "list[Profile]":
        """This curve cut where the `cutters` (profiles) cross, touch or run along
        it -- the sketch trim's pieces: in order along the curve from its start,
        each an open profile of portions of this one's own segments (a line's
        stretch a line, an arc's an arc, a spline's the same spline over part of
        its domain). One piece, this curve, where nothing cuts it; a closed
        curve's piece round its start is one piece. `tolerance` is how close two
        curves must come to meet; cuts closer than it to each other fold onto
        one. Raises `BuildError` for a curve with no segments."""
        cutters = list(cutters)
        handles = (c_void_p * len(cutters))(*[c._handle for c in cutters])   # zero-length with none: the wasm takes an array, never None
        lib = _lib()
        n = lib.cadaclysm_blacksmith_profile_piece_count(self._handle, handles, len(cutters), _tolerance(tolerance))
        if n == 0:
            _fail("profile_piece_count")
        return [Profile(lib.cadaclysm_blacksmith_profile_piece(self._handle, handles, len(cutters), k, _tolerance(tolerance))) for k in range(n)]

    def trim(self, cutters: Iterable[Profile], piece: int, tolerance: "float | None" = 1e-6) -> "list[Profile]":
        """This curve with piece `piece` of `pieces(cutters)` taken away -- the
        sketch trim: what is left, as open profiles. One for a closed curve (its
        other pieces run together, starting where the removed piece ended), the
        stretches before and after for an open one, none where the piece was the
        whole curve. Raises `BuildError` for a piece the curve does not have."""
        cutters = list(cutters)
        handles = (c_void_p * len(cutters))(*[c._handle for c in cutters])   # zero-length with none: the wasm takes an array, never None
        lib = _lib()
        n = lib.cadaclysm_blacksmith_profile_trim_count(self._handle, handles, len(cutters), int(piece), _tolerance(tolerance))
        if n == 0:
            if _text(lib.cadaclysm_blacksmith_last_error()):
                _fail("profile_trim_count")
            return []
        return [Profile(lib.cadaclysm_blacksmith_profile_trim_chain(self._handle, handles, len(cutters), int(piece), k, _tolerance(tolerance))) for k in range(n)]

    def length(self, accuracy: float = 0.0) -> "Length":
        """The perimeter of the outer loop -- holes are not counted -- as a `Length`, its exact
        curves measured to the relative `accuracy` (0 asks for the library's default)."""
        out = _Length()
        if not _lib().cadaclysm_blacksmith_profile_length(self._handle, float(accuracy), ctypes.byref(out)):
            _fail("profile_length")
        return Length(out)

    def point_at_length(self, s: float, accuracy: float = 0.0) -> "At":
        """The point at arc length `s` along the outer loop from its start, `s` in
        `[0, length]`, measured to the relative `accuracy` (0 asks for the default); `segment`
        names the side it lies on. Raises `BuildError` for an `s` off the loop."""
        out = _At()
        if not _lib().cadaclysm_blacksmith_profile_point_at_length(self._handle, float(s), float(accuracy), ctypes.byref(out)):
            _fail("profile_point_at_length")
        return At(out)

    def divide_by_count(self, n: int, accuracy: float = 0.0) -> "list[At]":
        """The outer loop in `n` pieces of equal arc length: `n` samples from its start, the
        loop being closed. Raises `BuildError` for an `n` of 0 or above 1 000 000, and `ValueError`
        for an `n` that is not a whole number from 0 to 4294967295."""
        return _samples("profile_divide_by_count", _lib().cadaclysm_blacksmith_profile_divide_by_count(
            self._handle, _u32(n, "profile_divide_by_count: n"), float(accuracy)))

    def divide_by_length(self, step: float, accuracy: float = 0.0) -> "list[At]":
        """Samples of the outer loop every `step` of arc length from its start, the last piece
        whatever is left over and the start never repeated. Raises `BuildError` for a `step` not
        positive and finite or giving more than 1 000 000 samples."""
        return _samples("profile_divide_by_length", _lib().cadaclysm_blacksmith_profile_divide_by_length(
            self._handle, float(step), float(accuracy)))

    def document_path(self) -> "dict[str, Any]":
        """This profile as its exact segments, as a `profile.path` node holds it:
        `{"start": [x, y], "segments": [...], "holes": [...], "colour": [r, g, b]}`, each segment
        a dict with a `type` of `line`, `arc`, `bezier`, `conic` or `nurbs` and its points --
        arcs and NURBS as they are, not flattened as `polylines` flattens them -- and `colour`
        only where the profile has one. `Document.add_profile` puts it in a document."""
        return json.loads(_owned_text(_lib().cadaclysm_blacksmith_document_profile_path(self._handle), "document_profile_path"))

    def polylines(self, tolerance: "float | None" = 0.05) -> "list[numpy.ndarray]":
        """The outline, then each hole, as float32 (k,3) read-only arrays at z = 0,
        within `tolerance` of the profile's arcs and splines -- what a viewer draws it
        with. A closed loop repeats its first point at the end; an open chain (a profile
        ended open) stays open, the segments it has. Copies, valid for good (see the
        module docs)."""
        p = _lib().cadaclysm_blacksmith_profile_polylines(self._handle, _tolerance(tolerance))
        if not p.offsets:
            _fail("profile_polylines")
        points = _copied(p.points, (p.point_count, 3), "f4")
        offsets = [p.offsets[i] for i in range(p.polyline_count + 1)]
        return [points[a:b] for a, b in zip(offsets, offsets[1:])]

    def show(self, tolerance: float = 0.05, **options: Any) -> None:
        """Draw the outline and holes with the viewer in use, from the top by default --
        with the GPU library (`cadaclysm.view.wgpu`), into one shared window that stays
        open; with the terminal, a still. Keywords as `Solid.show`; `edges=` is accepted
        and ignored, the lines being the whole picture."""
        _present(self, "show", tolerance, "top", _lines_only(options))

    def view(self, tolerance: float = 0.05, **options: Any) -> dict[str, Any]:
        """Orbit the outline with the view library in use; returns the camera (eye,
        target, up, orthographic) and the last pick."""
        return _present(self, "view", tolerance, "top", _lines_only(options))

    def svg(self, path: FilePath | None = None, *, view: ViewName = "top", **words: Any) -> "str | None":
        """This profile's own loops as SVG, from directly above by default -- a
        sketch lies in z = 0, so its own plane already is the page, unlike a
        solid's `Solid.svg` (`view="iso"`), which has no plane of its own to
        prefer. The rest of the keywords are `svg()`'s. With `path`, writes the
        file and returns `None`; without, returns the SVG text. Raises
        `BuildError` on a refused option or a failed write."""
        return svg([self], path, view=view, **words)


class Path:
    """An outline drawn a segment at a time; `end()` closes it into a `Profile`
    and consumes the builder."""

    __slots__ = ("_handle",)

    def __init__(self, start: Point2):
        x, y = start
        self._handle = _checked(_lib().cadaclysm_blacksmith_path_begin(x, y), "path_begin")

    @classmethod
    def _from_handle(cls, handle) -> "Path":
        path = cls.__new__(cls)
        path._handle = handle
        return path

    def __del__(self) -> None:
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

    def line_to(self, x: float, y: float) -> "Path":
        return self._step(_lib().cadaclysm_blacksmith_path_line_to(self._live(), x, y), "path_line_to")

    def arc_to(self, x: float, y: float, centre: Point2, ccw: bool = True) -> "Path":
        cx, cy = centre
        return self._step(_lib().cadaclysm_blacksmith_path_arc_to(self._live(), x, y, cx, cy, ccw), "path_arc_to")

    def bezier_to(self, c1: Point2, c2: Point2, to: Point2) -> "Path":
        return self._step(_lib().cadaclysm_blacksmith_path_bezier_to(self._live(), *c1, *c2, *to), "path_bezier_to")

    def nurbs_to(self, control: Iterable[Point2], knots: Sequence[float], degree: int,
                 weights: Iterable[float] | None = None) -> "Path":
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

    def conic_to(self, x: float, y: float, control: Point2, weight: float) -> "Path":
        """A conic arc to (`x`, `y`) through the control point `control` with middle
        weight `weight`: under 1 an elliptical arc, 1 a parabola, over 1 a hyperbola --
        the rational quadratic Bezier, kept exact."""
        cx, cy = control
        return self._step(_lib().cadaclysm_blacksmith_path_conic_to(self._live(), x, y, cx, cy, weight), "path_conic_to")

    def parabola_to(self, x: float, y: float, control: Point2) -> "Path":
        """A parabolic arc to (`x`, `y`) whose end tangents meet at `control`: `conic_to` with weight 1."""
        return self.conic_to(x, y, control, 1.0)

    def hyperbola_to(self, x: float, y: float, control: Point2, weight: float) -> "Path":
        """A hyperbolic arc to (`x`, `y`) through `control` with middle `weight` over 1."""
        if not (weight > 1.0):
            raise BuildError("hyperbola_to: the weight must be over 1 (1 is a parabola, under 1 an ellipse)")
        return self.conic_to(x, y, control, weight)

    def parabola_by_vertex(self, x: float, y: float, vertex: Point2) -> "Path":
        """The parabolic arc to (`x`, `y`) with `vertex`: its axis and focal length solved
        from the two ends. Raises when no parabola with that vertex passes through both."""
        vx, vy = vertex
        return self._step(_lib().cadaclysm_blacksmith_path_parabola_by_vertex(self._live(), x, y, vx, vy), "path_parabola_by_vertex")

    def parabola_by_focus(self, x: float, y: float, focus: Point2) -> "Path":
        """The parabolic arc to (`x`, `y`) with `focus`: of the two through the ends, the
        one whose vertex lies between the ends' projections, then the one whose arc cups
        the focus (the focus between the arc and its chord), then the more symmetric; with
        the focus beyond the chord that is the arch over the ends, not the shallow dish --
        draw that one with `Profile.parabola`."""
        fx, fy = focus
        return self._step(_lib().cadaclysm_blacksmith_path_parabola_by_focus(self._live(), x, y, fx, fy), "path_parabola_by_focus")

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

    def __init__(self, at: Point3):
        x, y, z = at
        self._handle = _checked(_lib().cadaclysm_blacksmith_sweep_path_begin(x, y, z), "sweep_path_begin")

    def __del__(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_sweep_path_free(h)

    @staticmethod
    def at(point: Point3) -> "SweepPath":
        return SweepPath(point)

    @staticmethod
    def along(curve: Profile, frame: FrameLike, tolerance: "float | None" = 0.05, open: bool = True) -> "SweepPath":  # noqa: A002
        """The path the 2D chain `curve` (usually `Path.end_open()`) draws on
        `frame`: a line a straight piece, an arc a circular one, and a Bezier or
        spline fitted with biarcs -- pairs of arcs tangent to each other and to
        the curve -- until each stays within `tolerance` of it, so the path is
        tangent throughout and every wall swept along it exact. `open=False`
        closes the path back to its start along the side a profile leaves
        implicit. For `Solid.sweep`, whose frame must start where the path does
        and face along it."""
        self = SweepPath.__new__(SweepPath)
        h = _lib().cadaclysm_blacksmith_sweep_path_along(curve._handle, _frame(frame), _tolerance(tolerance), bool(open))
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

    def line_to(self, point: Point3) -> "SweepPath":
        x, y, z = point
        return self._step(_lib().cadaclysm_blacksmith_sweep_path_line_to(self._live(), x, y, z), "sweep_path_line_to")

    def arc(self, centre: Point3, axis: Point3, angle: float) -> "SweepPath":
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

    at: float
    grad: tuple[float, float]

    def __init__(self, at: float, grad: Point2 = (0.0, 0.0)):
        self.at = float(at)
        self.grad = (float(grad[0]), float(grad[1]))

    @staticmethod
    def flat(at: float) -> "Slant":
        return Slant(at)

    @staticmethod
    def of_plane(frame: FrameLike, point: Point3, normal: Point3) -> "Slant":
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

    def __repr__(self) -> str:
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


@dataclass(frozen=True)
class History:
    """What a verb did to its inputs' faces (or edges), read off the result's ids and origins
    alone (`Solid.history`, `Solid.edge_history`). An input is named `(operand, id)`: the
    operand its index in the inputs as passed (the verb's operand order: a boolean's target 0,
    its tool 1), the id its `face_id`. Every list is in `(operand, id)` order, `generated` in id
    order -- the shape of OpenCascade's `BRepTools_History`:

    - `kept`: an input that became exactly one output, keeping its id -- `(input, output id)`;
    - `modified`: an input split (several outputs name it), merged (its output has other
      origins too) or renumbered (a cut's bore, a later operand's clashing id) --
      `(input, [output ids])`, a split's first piece, which keeps the id, first;
    - `generated`: the outputs with no origin (a fillet's round, the faces a split cuts);
    - `deleted`: the inputs no output names (a cut tool's caps)."""

    kept: "list[tuple[tuple[int, int], int]]"
    modified: "list[tuple[tuple[int, int], list[int]]]"
    generated: "list[int]"
    deleted: "list[tuple[int, int]]"

    def __repr__(self) -> str:
        return (f"History(kept={len(self.kept)}, modified={len(self.modified)}, "
                f"generated={len(self.generated)}, deleted={len(self.deleted)})")


def _read_history(lib, h) -> History:
    """The four lists of history handle `h` (the C handle, or the wasm shim's `_WasmHistory`),
    read through C's readers; the caller frees it."""
    operand, id_, out = c_uint32(), c_uint64(), c_uint64()
    kept, modified, deleted = [], [], []
    for i in range(lib.cadaclysm_blacksmith_history_kept_count(h)):
        _ok(lib.cadaclysm_blacksmith_history_kept_at(h, i, ctypes.byref(operand), ctypes.byref(id_), ctypes.byref(out)), "history_kept_at")
        kept.append(((operand.value, id_.value), out.value))
    for i in range(lib.cadaclysm_blacksmith_history_modified_count(h)):
        _ok(lib.cadaclysm_blacksmith_history_modified_at(h, i, ctypes.byref(operand), ctypes.byref(id_)), "history_modified_at")
        n = lib.cadaclysm_blacksmith_history_modified_output_count(h, i)
        if n == NONE:
            _fail("history_modified_output_count")
        modified.append(((operand.value, id_.value), [lib.cadaclysm_blacksmith_history_modified_output_at(h, i, j) for j in range(n)]))
    generated = [lib.cadaclysm_blacksmith_history_generated_at(h, i) for i in range(lib.cadaclysm_blacksmith_history_generated_count(h))]
    for i in range(lib.cadaclysm_blacksmith_history_deleted_count(h)):
        _ok(lib.cadaclysm_blacksmith_history_deleted_at(h, i, ctypes.byref(operand), ctypes.byref(id_)), "history_deleted_at")
        deleted.append((operand.value, id_.value))
    return History(kept=kept, modified=modified, generated=generated, deleted=deleted)


def _id(value, what: str) -> int:
    """An id argument: a whole number from 0 to 2**64 - 1 (ctypes would wrap anything else)."""
    try:
        k = operator.index(value)
    except TypeError:
        k = None
    if isinstance(value, bool) or k is None or not 0 <= k < 1 << 64:
        raise BuildError(f"{what}: {value!r} is not an id (a whole number from 0 to 2**64 - 1)")
    return k


def _key(key, what: str) -> bytes:
    if not isinstance(key, str):
        raise TypeError(f"{what}: a key is a str, not {type(key).__name__}")
    return key.encode("utf-8")


def _value(value, what: str) -> bytes:
    if not isinstance(value, str):
        raise TypeError(f"{what}: a value is a str, not {type(value).__name__}")
    return value.encode("utf-8")


def _attribute_map(count, key_at, value_at, *args) -> "types.MappingProxyType":
    """A read-only mapping of the attributes C lists by count and `_at` (in key order)."""
    out = {}
    for i in range(count):
        k, v = key_at(*args, i), value_at(*args, i)
        if k is None or v is None:
            _fail("attributes")
        out[k.decode("utf-8")] = v.decode("utf-8")
    return types.MappingProxyType(out)


class Solid:
    """An exact B-rep solid (or open sheet). Immutable; every operation returns
    a new one. `close()` frees it; so does leaving a `with` block or the garbage
    collector."""

    __slots__ = ("_handle", "__weakref__", "sheet_error", "inexact_trims", "_attributes", "patch_report")

    sheet_error: "float | None"
    #: The trims `transform` or `convert_to_nurbs` lost making this solid (see `transform`); 0 on any other.
    inexact_trims: int

    def __init__(self, handle: int | None):
        self.sheet_error = None
        self.inexact_trims = 0
        self._attributes = None
        self._handle = _checked(handle, "solid")

    def __enter__(self) -> "Solid":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()

    def close(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_solid_free(h)

    def _h(self):
        if not self._handle:
            raise BuildError("solid: closed")
        return self._handle

    # -- naming
    def named(self, name: str) -> "Solid":
        """This solid, named `name`. The name rides through an operation with
        exactly one source solid (`place`, `translate`, `coloured`, `fillet`, ...)
        and is dropped by one with two or more (`join`, `cut`, `common`, ...) and
        by a fresh primitive or sweep -- see `Solid.name`. It is what `Assembly.place`
        defaults a placement's own name to, and the product name a lone named
        solid gets when written to STEP (`step`/`step_text`). Refused for an
        empty name."""
        return Solid(_lib().cadaclysm_blacksmith_named(self._h(), name.encode("utf-8")))

    @property
    def name(self) -> "str | None":
        """This solid's name, or `None` if it has none -- what `named` set, kept
        or dropped by whatever built this solid (see `named`)."""
        raw = _lib().cadaclysm_blacksmith_solid_name(self._h())
        return raw.decode("utf-8") if raw else None

    # -- material and look defined outside the file
    def with_material(self, material: str) -> "Solid":
        """This solid made of `material` -- a name, written to STEP as the
        product's `MATERIAL_DESIGNATION`. Kept by every operation as the solid's
        colour is: a move keeps it, a boolean's result is made of its first
        solid's. Writing it moves `step`'s default schema to AP242; a named schema
        without the entity drops it, as it drops a colour. Refused when blank."""
        return Solid(_lib().cadaclysm_blacksmith_with_material(self._h(), material.encode("utf-8")))

    @property
    def material(self) -> "str | None":
        """What this solid is made of, or `None` -- see `with_material`."""
        raw = _lib().cadaclysm_blacksmith_solid_material(self._h())
        return raw.decode("utf-8") if raw else None

    def styled(self, location: "str | None" = None, identification: "str | None" = None) -> "Solid":
        """This solid drawn in a style defined outside the file: `identification`
        the style's name in the library at `location` -- a MaterialX or MDL file
        and a material in it, say. Either may be left out, not both. Written to
        STEP as an `EXTERNALLY_DEFINED_STYLE` beside the solid's colour, which a
        reader without the library draws instead (AP242 or AP214: the default
        schema moves to AP242). Kept by operations as `with_material`'s material is."""
        enc = lambda t: None if t is None else t.encode("utf-8")  # noqa: E731
        return Solid(_lib().cadaclysm_blacksmith_styled(self._h(), enc(location), enc(identification)))

    @property
    def style_location(self) -> "str | None":
        """Where this solid's outside style lives (`styled`'s `location`), or `None`."""
        raw = _lib().cadaclysm_blacksmith_solid_style_location(self._h())
        return raw.decode("utf-8") if raw else None

    @property
    def style_identification(self) -> "str | None":
        """This solid's outside style's name in its library (`styled`'s
        `identification`), or `None`."""
        raw = _lib().cadaclysm_blacksmith_solid_style_identification(self._h())
        return raw.decode("utf-8") if raw else None

    # -- building
    @staticmethod
    def cuboid(x: float, y: float, z: float) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_cuboid(x, y, z))

    @staticmethod
    def cylinder(r: float, h: float) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_cylinder(r, h))

    # ---- surfaces from curves: sheets, one face on one NURBS surface ----------------------

    @staticmethod
    def loft_curves(sections: "Iterable[NurbsCurve]", degree: int = 3, loose: bool = False, closed: bool = False) -> "Solid":
        """The sheet lofted through `sections` (:class:`NurbsCurve`), `degree` across them
        (lowered to fit); `loose=True` shapes it by them instead, through the first and last
        only; `closed=True` makes it periodic across them, the last section back to the first."""
        arr, n = _curve_array(sections)
        return Solid(_lib().cadaclysm_blacksmith_loft_curves(arr, n, _u32(degree, "loft_curves: degree"), bool(loose), bool(closed)))

    @staticmethod
    def sweep_rail(rail: "NurbsCurve", sections: "Iterable[NurbsCurve]", frame: str = "rmf", up: "Point3 | None" = None,
                   tolerance: "float | None" = 1e-3) -> "Solid":
        """`sections` swept along `rail`, each carried by the rail's frame from the rail point
        nearest its centre and blended between: `frame="rmf"` rotation-minimising, `"fixed"`
        keeping `up` upright. Fitted within `tolerance`; the sheet's `sheet_error` says how close."""
        kinds = {"rmf": 0, "fixed": 1}
        if frame not in kinds:
            raise ValueError(f"sweep_rail: frame is 'rmf' or 'fixed', not {frame!r}")
        arr, n = _curve_array(sections)
        err = c_double(0.0)
        solid = Solid(_lib().cadaclysm_blacksmith_sweep_rail(rail._handle, arr, n, kinds[frame], _vec3(up), _tolerance(tolerance), ctypes.byref(err)))
        solid.sheet_error = err.value
        return solid

    @staticmethod
    def sweep_two_rails(rail_a: "NurbsCurve", rail_b: "NurbsCurve", sections: "Iterable[NurbsCurve]", tolerance: "float | None" = 1e-3) -> "Solid":
        """`sections` swept between two rails: each section's first end on `rail_a` and last on
        `rail_b`, carried by the rotation and uniform scale that keep them there, the rails
        matched by arc length. Fitted within `tolerance` (`sheet_error`)."""
        arr, n = _curve_array(sections)
        err = c_double(0.0)
        solid = Solid(_lib().cadaclysm_blacksmith_sweep_two_rails(rail_a._handle, rail_b._handle, arr, n, _tolerance(tolerance), ctypes.byref(err)))
        solid.sheet_error = err.value
        return solid

    @staticmethod
    def edge_surface(curves: "Iterable[NurbsCurve]", tolerance: "float | None" = 1e-3) -> "Solid":
        """The Coons sheet of 2, 3 or 4 boundary curves meeting end to end within `tolerance`
        (in order round the boundary, each either way round): exact for non-rational
        boundaries, rational ones fitted first (`sheet_error`)."""
        arr, n = _curve_array(curves)
        err = c_double(0.0)
        solid = Solid(_lib().cadaclysm_blacksmith_edge_surface(arr, n, _tolerance(tolerance), ctypes.byref(err)))
        solid.sheet_error = err.value
        return solid

    def continuity(self, side: str, other: "Solid", other_side: str, face: int = 0, other_face: int = 0,
                   samples: int = 64) -> "Continuity":
        """How well face `face`'s side `side` (`"u0"`, `"u1"`, `"v0"`, `"v1"`: a boundary isocurve of
        its NURBS surface) meets `other`'s face `other_face` along `other_side`: the largest gap,
        angle between the normals and difference of curvature across the edge, with where each is."""
        out = _Continuity()
        _ok(_lib().cadaclysm_blacksmith_continuity(self._handle, _u32(face, "continuity: face"), _sheet_side(side), other._handle,
                                                   _u32(other_face, "continuity: other_face"), _sheet_side(other_side),
                                                   _u32(samples, "continuity: samples"), ctypes.byref(out)), "continuity")
        return Continuity(out)

    def edge_continuity(self, edge: "Edge | int", samples: int = 64) -> "Continuity":
        """How well the two faces of edge `edge` meet along it: `samples` points along the edge,
        each projected onto both faces, and the largest gap between the two, angle between the
        faces' normals (each the way its face faces: a square crease reads pi/2) and difference
        of their normal curvatures across the edge -- :meth:`continuity`'s figures for any two
        faces of one body, of any kind of surface. A test fails a design on these: a G1 seam
        reads an angle near 0, a G2 one a curvature near 0 too."""
        e = edge.index if isinstance(edge, Edge) else edge
        out = _Continuity()
        _ok(_lib().cadaclysm_blacksmith_edge_continuity(self._handle, _u32(e, "edge_continuity: edge"),
                                                        _u32(samples, "edge_continuity: samples"), ctypes.byref(out)), "edge_continuity")
        return Continuity(out)

    def faired(self, tolerance: "float | None" = 1e-3, degree: int = 3, controls: "tuple[int, int] | None" = None,
               keep: "int | None | dict[str, int | None] | tuple[int | None, int | None, int | None, int | None]" = 2,
               no_inflection: "str | None" = None, face: int = 0) -> "Solid":
        """Face `face` faired, as a sheet of its own: the smoothest surface within `tolerance` of its
        NURBS surface -- least squares plus its third derivatives squared (what a zebra's ripple
        costs), weighed as heavily as the tolerance allows. A sheet lofted through traced sections
        wobbles between them; this spends the tolerance on smoothness.

        `controls` None fairs on the face's own net, its degree raised to `degree` (3 to 7) and its
        spans split to a dozen each way at least, so a kept side is kept exactly; `(n_u, n_v)` fairs
        on a uniform net that size, its kept sides within the tolerance. `keep` says what each side
        keeps -- one level for all four, or per side as a dict by `"u0"`, `"u1"`, `"v0"`, `"v1"` or
        a 4-tuple in that order: None free to move, 0 its position, 1 the tangent plane across it,
        2 the curvature too (what :meth:`matched` gave it with a neighbour). `no_inflection` `"u"`,
        `"v"` or `"uv"` holds the isocurves along those directions from turning their curvature
        over -- each bends to the side it bends to most -- which turns a roof lofted through wobbly
        sections into a dome. Raises `BuildError` where no such fair is within the tolerance. Its
        `sheet_error` is the largest distance found between the two surfaces."""
        if isinstance(keep, dict):
            unknown = set(keep) - set(_SHEET_SIDES)
            if unknown:
                raise ValueError(f"a side is 'u0', 'u1', 'v0' or 'v1', not {sorted(unknown)[0]!r}")
            levels = [keep.get(side, 2) for side in ("u0", "u1", "v0", "v1")]
        elif isinstance(keep, (tuple, list)):
            if len(keep) != 4:
                raise ValueError(f"keep takes 4 levels (u0, u1, v0, v1), not {len(keep)}")
            levels = list(keep)
        else:
            levels = [keep] * 4
        held = {None: 0, "": 0, "u": 1, "v": 2, "uv": 3, "vu": 3}
        if no_inflection not in held:
            raise ValueError(f"no_inflection is 'u', 'v', 'uv' or None, not {no_inflection!r}")
        cu, cv = (0, 0) if controls is None else controls
        arr = (c_int32 * 4)(*[-1 if k is None else int(k) for k in levels])
        err = c_double(0.0)
        solid = Solid(_lib().cadaclysm_blacksmith_surface_faired(self._handle, _u32(face, "surface_faired: face"), _tolerance(tolerance),
                                                               _u32(degree, "surface_faired: degree"), _u32(cu, "surface_faired: controls"),
                                                               _u32(cv, "surface_faired: controls"), arr, held[no_inflection], ctypes.byref(err)))
        solid.sheet_error = err.value
        return solid

    def curvature_turns(self, face: int = 0, samples: int = 32) -> "CurvatureTurns":
        """Where face `face`'s Gaussian and mean curvature change sign, on a grid of `samples` steps
        each way over its surface (8 at fewest): how many separate areas of each sign, and the
        points between opposite signs (:class:`CurvatureTurns`). A dome or a saddle reads one area
        of one sign and no turn; a sheet whose sections wobble reads several -- the surface's
        form of :meth:`NurbsCurve.inflections`, the number a test fails a wobbly panel on."""
        out = _CurvatureTurns()
        f, n = _u32(face, "curvature_turns: face"), _u32(samples, "curvature_turns: samples")
        _ok(_lib().cadaclysm_blacksmith_curvature_turns(self._handle, f, n, ctypes.byref(out)), "curvature_turns")
        points = lambda mean: (_samples("curvature_turn_points", _lib().cadaclysm_blacksmith_curvature_turn_points(self._handle, f, n, mean))   # noqa: E731
                               if (out.mean_turns if mean else out.gaussian_turns) else [])
        return CurvatureTurns(out, points(False), points(True))

    def highlight_kink(self, edge: "Edge | int", samples: int = 64) -> "HighlightKink":
        """The worst kink of the highlight lines crossing edge `edge`, at `samples` points along it:
        the lines of straight light tubes parallel to the surface a body's size away, every tube
        direction tried. They run on through an edge where the two faces' curvatures agree (G2)
        and kink where it jumps -- a fillet's seam with a flat face among them. Beside
        :meth:`edge_continuity`'s curvature jump, this is the number a zebra shows."""
        e = edge.index if isinstance(edge, Edge) else edge
        out = _HighlightKink()
        _ok(_lib().cadaclysm_blacksmith_highlight_kink(self._handle, _u32(e, "highlight_kink: edge"), _u32(samples, "highlight_kink: samples"),
                                                       ctypes.byref(out)), "highlight_kink")
        return HighlightKink(out)

    def matched(self, side: str, other: "Solid", other_side: str, level: int = 2, face: int = 0, other_face: int = 0) -> "Solid":
        """Face `face` as a sheet of its own, its side `side` bent to meet `other`'s `other_side` at
        G`level`: 0 position, 1 tangent plane, 2 curvature. The opposite side stays where it was."""
        return Solid(_lib().cadaclysm_blacksmith_match_side(self._handle, _u32(face, "match_side: face"), _sheet_side(side), other._handle,
                                                            _u32(other_face, "match_side: other_face"), _sheet_side(other_side),
                                                            _u32(level, "match_side: level")))

    @staticmethod
    def fillet_surfaces(a: "Solid", b: "Solid", radius: float, radius_end: "float | None" = None, flip_a: bool = False,
                        flip_b: bool = False, tolerance: "float | None" = 1e-3, face_a: int = 0,
                        face_b: int = 0) -> "tuple[Solid, NurbsCurve, NurbsCurve]":
        """The rolling-ball fillet between `a`'s face `face_a` and `b`'s face `face_b` (their whole
        NURBS surfaces): the ball on the side each face's normal points to (`flip_a`/`flip_b`: the
        other side), of `radius`, or running linearly from `radius` to `radius_end` along the fillet.
        Returns the fillet sheet (its `sheet_error` set) and the contact curves on `a` and `b`, to
        trim them back with :meth:`trim_by_curve` and join with :meth:`join_sheets`."""
        ra, rb, err = c_void_p(), c_void_p(), c_double(0.0)
        end = radius if radius_end is None else radius_end
        h = _lib().cadaclysm_blacksmith_fillet_surfaces(a._handle, _u32(face_a, "fillet_surfaces: face_a"), b._handle,
                                                         _u32(face_b, "fillet_surfaces: face_b"), float(radius), float(end),
                                                         bool(flip_a), bool(flip_b), _tolerance(tolerance),
                                                         ctypes.byref(ra), ctypes.byref(rb), ctypes.byref(err))
        sheet = Solid(h)
        sheet.sheet_error = err.value
        return sheet, NurbsCurve._of(ra.value, "fillet_surfaces"), NurbsCurve._of(rb.value, "fillet_surfaces")

    @staticmethod
    def blend_sides(a: "Solid", side_a: str, b: "Solid", side_b: str, level: int = 2, bulge: float = 1.0,
                    face_a: int = 0, face_b: int = 0) -> "Solid":
        """A sheet spanning from `a`'s side to `b`'s, meeting each at G`level` (1 or 2); `bulge`
        scales how far it leaves each edge along its neighbour's tangent."""
        return Solid(_lib().cadaclysm_blacksmith_blend_sides(a._handle, _u32(face_a, "blend_sides: face_a"), _sheet_side(side_a), b._handle,
                                                             _u32(face_b, "blend_sides: face_b"), _sheet_side(side_b),
                                                             _u32(level, "blend_sides: level"), float(bulge)))

    @staticmethod
    def n_sided_patch(boundaries: "Iterable[Any]", bulge: float = 1.0, tolerance: "float | None" = 0.01) -> "Solid":
        """The sheet filling a hole of 3 or more sides (Rhino's Patch, OCCT's MakeFilling, on
        sheets' sides): N four-sided NURBS faces round a central point, G1 or G2 to each other.
        Each boundary, in order round the hole and either way round, is a sheet's side met at G2,
        `(sheet, side)`; `(sheet, side, level)` with `level` 0, 1 or 2; a dict with `sheet`,
        `side` and any of `level`, `face` and `range` (`(from, to)` of the side's parameter, the
        whole side `(0, 1)`, backwards `(1, 0)`); or a :class:`NurbsCurve`, met at G0. A side is
        `"u0"`, `"u1"`, `"v0"` or `"v1"`. The boundaries must meet end to end within `tolerance`;
        `bulge` scales how far the patch leaves each neighbour along its tangent.

        Face `i` meets boundary `i`'s second half along its `"v0"` side and boundary `i + 1`'s
        first half along its `"u1"`, so :meth:`continuity` measures each neighbour; the result's
        `patch_report` holds the worst of them, measured the same way."""
        rows = []
        for i, b in enumerate(boundaries):
            if isinstance(b, NurbsCurve):
                rows.append(_PatchBoundary(None, 0, 0, 0.0, 1.0, 0, b._handle))
                continue
            if isinstance(b, dict):
                b = dict(b)
                sheet, side = b.pop("sheet"), b.pop("side")
                level, face, rng = b.pop("level", 2), b.pop("face", 0), b.pop("range", (0.0, 1.0))
                if b:
                    raise ValueError(f"n_sided_patch: boundary {i}: unknown keys {sorted(b)}")
            else:
                sheet, side, *more = b
                if len(more) > 1:
                    raise ValueError(f"n_sided_patch: boundary {i} is (sheet, side) or (sheet, side, level)")
                level, face, rng = (more[0] if more else 2), 0, (0.0, 1.0)
            rows.append(_PatchBoundary(sheet._handle, _u32(face, "n_sided_patch: face"), _sheet_side(side), float(rng[0]), float(rng[1]),
                                       _u32(level, "n_sided_patch: level"), None))
        arr = (_PatchBoundary * max(len(rows), 1))(*rows)
        out = _PatchReport()
        solid = Solid(_lib().cadaclysm_blacksmith_n_sided_patch(arr, len(rows), float(bulge), _tolerance(tolerance), ctypes.byref(out)))
        solid.patch_report = PatchReport(out)
        return solid

    @staticmethod
    def network_surface(u_curves: "Iterable[NurbsCurve]", v_curves: "Iterable[NurbsCurve]", tolerance: "float | None" = 1e-3) -> "Solid":
        """The Gordon sheet of a curve network: `u_curves` (in order across the other way) and
        `v_curves`, every one of the first crossing every one of the second within `tolerance`.
        `sheet_error` is the largest distance from the sheet to the curves given."""
        ua, un = _curve_array(u_curves)
        va, vn = _curve_array(v_curves)
        err = c_double(0.0)
        solid = Solid(_lib().cadaclysm_blacksmith_network_surface(ua, un, va, vn, _tolerance(tolerance), ctypes.byref(err)))
        solid.sheet_error = err.value
        return solid

    @staticmethod
    def cone(r: float, h: float) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_cone(r, h))

    @staticmethod
    def sphere(r: float) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_sphere(r))

    @staticmethod
    def torus(major: float, minor: float) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_torus(major, minor))

    @staticmethod
    def wedge(x: float, y: float, z: float, top_x: float) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_wedge(x, y, z, top_x))

    @staticmethod
    def pyramid(sides: int, r: float, h: float) -> "Solid":
        """A right pyramid of ``sides`` sides (at least 3): its base the regular polygon
        of circumradius ``r`` on z=0, its first corner on +x, its tip at (0, 0, ``h``)."""
        return Solid(_lib().cadaclysm_blacksmith_pyramid(max(0, int(sides)), r, h))

    @staticmethod
    def extrude(profile: Profile, frame: FrameLike, height: float) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_extrude(profile._handle, _frame(frame), height))

    @staticmethod
    def extrude_open(profile: Profile, frame: FrameLike, height: float) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_extrude_open(profile._handle, _frame(frame), height))

    @staticmethod
    def extrude_tapered(profile: Profile, frame: FrameLike, height: float, taper: float) -> "Solid":
        """`extrude` with a draft: the walls lean out by `taper` radians as they
        rise (in, when negative), every wall exact -- a plane off a line, a
        cone off an arc. A taper of zero is `extrude`."""
        return Solid(_lib().cadaclysm_blacksmith_extrude_tapered(profile._handle, _frame(frame), height, taper))

    @staticmethod
    def extrude_open_tapered(profile: Profile, frame: FrameLike, height: float, taper: float) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_extrude_open_tapered(profile._handle, _frame(frame), height, taper))

    @staticmethod
    def extrude_between(profile: Profile, frame: FrameLike, bottom: Slant | float, top: Slant | float) -> "Solid":
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
    def extrude_open_between(profile: Profile, frame: FrameLike, bottom: Slant | float, top: Slant | float) -> "Solid":
        """`extrude_between` without the caps: an open sheet of walls running
        from `bottom` to `top`, as `extrude_open` is to `extrude`."""
        return Solid(_lib().cadaclysm_blacksmith_extrude_open_between(
            profile._handle, _frame(frame), _slant(bottom)._raw(), _slant(top)._raw()
        ))

    @staticmethod
    def loft(a: Profile, frame_a: FrameLike, b: Profile, frame_b: FrameLike) -> "Solid":
        """The solid between `a` on `frame_a` and `b` on `frame_b`: ruled walls
        between matching sides (the profiles must have the same number of
        sides, and no holes), capped by the two profiles."""
        return Solid(_lib().cadaclysm_blacksmith_loft(a._handle, _frame(frame_a), b._handle, _frame(frame_b)))

    @staticmethod
    def loft_open(a: Profile, frame_a: FrameLike, b: Profile, frame_b: FrameLike) -> "Solid":
        """`loft` without the caps: the sheet ruled between the two curves."""
        return Solid(_lib().cadaclysm_blacksmith_loft_open(a._handle, _frame(frame_a), b._handle, _frame(frame_b)))

    @staticmethod
    def loft_through(sections: Iterable[tuple[Profile, FrameLike]]) -> "Solid":
        """The solid smooth through every section -- `(profile, frame)` pairs, in order:
        each wall interpolates its side across all the profiles (cubic through four or
        more, quadratic through three, `loft` through two), capped by the first and the
        last. The profiles must have the same number of sides and no holes."""
        return Solid._lofted_through(sections, _lib().cadaclysm_blacksmith_loft_through)

    @staticmethod
    def loft_through_open(sections: Iterable[tuple[Profile, FrameLike]]) -> "Solid":
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
    def revolve(profile: Profile, axis: AxisLike, angle: float) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_revolve(profile._handle, _axis(axis), angle))

    @staticmethod
    def revolve_open(profile: Profile, axis: AxisLike, angle: float) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_revolve_open(profile._handle, _axis(axis), angle))

    @staticmethod
    def revolve_in_plane(profile: Profile, frame: FrameLike, a: Point2, b: Point2, angle: float) -> "Solid":
        """`profile`, drawn on `frame`, swung `angle` radians about the axis
        through the sketch points `a` and `b` (each `(x, y)` on the frame) --
        the profile and its axis drawn together, as a sketch draws them, where
        `revolve` reads the profile as (radius, height). The profile may lie on
        either side of the axis and touch it, not cross it; the sweep starts
        where the profile is drawn and turns right-handed about `b - a`."""
        axis = (c_double * 4)(float(a[0]), float(a[1]), float(b[0]), float(b[1]))
        return Solid(_lib().cadaclysm_blacksmith_revolve_in_plane(profile._handle, _frame(frame), axis, angle))

    @staticmethod
    def revolve_open_in_plane(profile: Profile, frame: FrameLike, a: Point2, b: Point2, angle: float) -> "Solid":
        """`revolve_in_plane` for a curve: its segments swung into a sheet."""
        axis = (c_double * 4)(float(a[0]), float(a[1]), float(b[0]), float(b[1]))
        return Solid(_lib().cadaclysm_blacksmith_revolve_open_in_plane(profile._handle, _frame(frame), axis, angle))

    @staticmethod
    def sweep(profile: Profile, frame: FrameLike, path: SweepPath) -> "Solid":
        """`profile`, drawn on `frame`, carried along `path` into a closed
        solid: a straight piece of the path is an extrusion, a circular piece
        a revolution about the arc's axis, so nothing is approximated -- a
        circle along an arc is an exact torus wall. `path` is only borrowed,
        not consumed; sweep it again, open or closed, as often as needed."""
        return Solid(_lib().cadaclysm_blacksmith_sweep(profile._handle, _frame(frame), path._live()))

    @staticmethod
    def coil(profile: Profile, axis: AxisLike, pitch: float, turns: float) -> "Solid":
        """`profile` coiled about `axis` (a point and a direction): read as
        `revolve` reads it -- x the distance from the axis, y along it -- and
        turned `turns` times while climbing `pitch` along the axis each turn:
        a spring, a thread. The walls follow the helix to a few millionths of
        the radius; the two ends are the profile itself, flat. From a full turn
        up the pitch must be taller than the profile."""
        return Solid(_lib().cadaclysm_blacksmith_coil(profile._handle, _axis(axis), pitch, turns))

    @staticmethod
    def pipe(path: SweepPath, radius: float, thickness: float = 0.0) -> "Solid":
        """A circle of `radius` swept along `path`, square to its start: a rod, or with a positive `thickness` a tube whose walls
        are that thick. `path` is only borrowed, as by `sweep`."""
        return Solid(_lib().cadaclysm_blacksmith_pipe(path._live(), radius, thickness))

    @staticmethod
    def sweep_open(profile: Profile, frame: FrameLike, path: SweepPath) -> "Solid":
        """`sweep` for a curve rather than a face: one wall per segment per
        piece, no caps -- an open sheet, the way `extrude_open` is to
        `extrude`."""
        return Solid(_lib().cadaclysm_blacksmith_sweep_open(profile._handle, _frame(frame), path._live()))

    # -- from files
    @staticmethod
    def from_node(scene: cadaclysm.Scene, node: cadaclysm.Node | int, placed: bool = True) -> "Solid":
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
        one's -- the brep is handed across by pointer, and the two modules'
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
    def open(path: FilePath, body: int | None = None) -> "Solid":  # noqa: A003 - `Solid.open`, the verb
        """The body a CAD file holds, as a solid: a STEP (AP203/214/242), ACIS
        `.sat`, Rhino `.3dm`, OCCT `.brep`, IGES, IFC or OpenSCAD file, read where it
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
    def open_all(path: FilePath) -> "list[Solid]":
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
                "IGES, IFC or OpenSCAD body can be a solid, not a mesh, a curve or a CSG body"
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
    def face(profile: Profile, frame: FrameLike) -> "Solid":
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

    def drop_faces(self, faces: Iterable[int]) -> "Solid":
        """This solid without the faces at `faces` (repeats allowed): the rest
        keep their surfaces, loops and curves, in their order, so an index into
        the result is this one's with the dropped ones closed up. An open sheet
        unless nothing was dropped."""
        ks = _indices(faces, "drop_faces", "faces")
        return Solid(_lib().cadaclysm_blacksmith_drop_faces(self._h(), (c_uint32 * len(ks))(*ks), len(ks)))

    def extrude_faces(self, height: float) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_extrude_faces(self._h(), height))

    def place(self, frame: FrameLike) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_place(self._h(), _frame(frame)))

    def translate(self, dx: float, dy: float, dz: float) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_translate(self._h(), dx, dy, dz))

    def scaled(self, factor: float) -> "Solid":
        """This solid scaled by `factor` about the origin: every length times
        `factor`, exactly. `factor` must be positive and finite."""
        return Solid(_lib().cadaclysm_blacksmith_scaled(self._h(), factor))

    def rotate(self, axis: AxisLike, radians: float) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_rotate(self._h(), _axis(axis), radians))

    def mirror(self, plane: FrameLike) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_mirror(self._h(), _frame(plane)))

    def transform(self, t: "Transform | Sequence[float]") -> "Solid":
        """This solid through the affine map `t` -- a `Transform`, or 16 numbers row-major (or
        four rows of four) -- exact, its colours and name kept. A rigid map or a similarity
        keeps every surface's kind. A map within 1e-6 of a similarity (`AᵀA` against `k²I`,
        relative to `k²` -- a rotation written in float32 among them) is applied as the exact
        similarity nearest it, which moves a point `p` by at most about `1e-6·|A|·|p|`; it too
        keeps every kind, though `Transform.is_rigid` and `is_similarity` (1e-9 by default)
        may say no to it. Any other map (a non-uniform scale, a shear) turns the curved
        surfaces into their exact NURBS and maps those.

        The result's `inexact_trims` counts the trims **lost by this call**: face boundaries
        that survive only as a polyline lifted through the old surface, where no exact edge
        curve was left (the one definition is `Reparametrised::inexact_trims` in the Rust
        kernel). It is per call, not this solid's history, and 0 for a rigid map or a
        similarity. Raises `BuildError` for a singular map (it flattens the solid), a
        non-finite one, or a non-affine one (its bottom row not `0 0 0 1`)."""
        lost = c_uint32(0)
        out = Solid(_lib().cadaclysm_blacksmith_solid_transform(self._h(), _matrix(t, "solid_transform"), ctypes.byref(lost)))
        out.inexact_trims = lost.value
        return out

    def convert_to_nurbs(self, level: str = "all") -> "Solid":
        """This solid with its surfaces rewritten as their exact NURBS: `"procedural"` the
        revolutions, extrusions and sums; `"analytic"` those and the cylinders, cones, spheres
        and tori, so every curved face can be edited by its control points; `"all"` everything,
        planes and edge curves too, a body made only of NURBS. Colours and name kept; `inexact_trims` counts the
        trims this call lost, as `transform`'s does."""
        try:
            code = _NURBS_LEVELS[level]
        except (KeyError, TypeError):   # TypeError: an unhashable level
            raise BuildError(f'convert_to_nurbs: level {level!r} is not "procedural", "analytic" or "all"') from None
        lost = c_uint32(0)
        out = Solid(_lib().cadaclysm_blacksmith_solid_convert_to_nurbs(self._h(), code, ctypes.byref(lost)))
        out.inexact_trims = lost.value
        return out

    # -- combining
    def _combine(self, f, other: "Solid", tolerance, progress, merge=False) -> "Solid":
        cb, _keep = _progress(progress)
        out = Solid(f(self._h(), other._h(), _tolerance(tolerance), cb, None))
        if not merge:
            return out
        # One verb to the caller: the merge's origins read back through the boolean's, so a
        # tracked result names this solid as operand 0 and `other` as 1, not the faces between.
        merged = out.merge_flush()
        return Solid(_lib().cadaclysm_blacksmith_origins_through(merged._h(), out._h())) if out.is_tracked else merged

    def join(self, other: "Solid", tolerance: "float | None" = 0.05, progress: Progress = None, merge: bool = False) -> "Solid":
        """This solid and `other` as one. `merge=True` merges the flush faces the
        join leaves where the two meet in a plane or on one cylinder (`merge_flush`),
        off by default, so face and edge numbers stay as they were. Merged or not, a
        tracked result's origins name this solid as operand 0 and `other` as 1: a merged
        face names one origin in each it lies on (see `face_origins`)."""
        return self._combine(_lib().cadaclysm_blacksmith_join, other, tolerance, progress, merge)

    def cut(self, other: "Solid", tolerance: "float | None" = 0.05, progress: Progress = None, merge: bool = False) -> "Solid":
        """This solid with `other` removed; `merge` as `join`'s."""
        return self._combine(_lib().cadaclysm_blacksmith_cut, other, tolerance, progress, merge)

    def common(self, other: "Solid", tolerance: "float | None" = 0.05, progress: Progress = None, merge: bool = False) -> "Solid":
        """What this solid and `other` share; `merge` as `join`'s."""
        return self._combine(_lib().cadaclysm_blacksmith_common, other, tolerance, progress, merge)

    def trim(self, tool: "Solid", keep: Literal["outside", "inside"] = "outside", tolerance: "float | None" = 0.05,
             progress: Progress = None) -> "Solid":
        """`self` (a sheet or a solid) cut along the closed `tool`'s boundary and
        the pieces on one side thrown away: `keep="outside"` keeps what lies
        outside the tool -- a hole punched through the sheet -- and
        `keep="inside"` what lies within it, the sheet cut to the tool's
        outline. `split_sheet` then `drop_faces` of the other side, in one call;
        the kept pieces come out in `self`'s face order."""
        if keep not in ("outside", "inside"):
            raise BuildError(f"trim: keep must be 'outside' or 'inside', not {keep!r}")
        cb, _keep = _progress(progress)
        return Solid(_lib().cadaclysm_blacksmith_trim(self._h(), tool._h(), keep == "inside", _tolerance(tolerance), cb, None))

    def split_by_curve(self, curve: "NurbsCurve", direction: "Point3 | None" = None, tolerance: "float | None" = 0.05) -> "Solid":
        """This sheet cut along `curve` -- one lying on it, say projected or pulled onto it --
        and nothing removed: every face comes back in its pieces outside the cutter, then its
        pieces inside, each a face, as `split_sheet` orders them. The cutter is `curve` run
        along `direction` (None: the mean of the sheet's normals along the curve) through the
        whole sheet. A closed curve's inside is the island it bounds; an open curve's is the
        side left of its run, seen from where `direction` points, and an open curve is run on
        straight past both ends, so it should cross the sheet's boundary. Where the cut lies on
        the curve the rim is one edge carrying the curve's own span exactly, which another
        sheet's edge along the curve sews to."""
        return Solid(_lib().cadaclysm_blacksmith_split_by_curve(self._h(), curve._handle, _vec3(direction), _tolerance(tolerance)))

    def split_along_curve(self, curve: "NurbsCurve", tolerance: "float | None" = 0.01) -> "Solid":
        """This sheet cut along `curve`, a curve lying on it (within ten times `tolerance`),
        with no direction: the cut is made in each face's own parameters, so it follows the
        curve wherever the sheet rolls, and runs across the seams of a joined sheet. An open
        curve is run on along the sheet past both ends to its boundary; a closed one cuts out
        the island it bounds. Nothing is removed. Where the cut lies on the curve the rim is
        one edge carrying the curve's own span exactly. Raises `BuildError` where the curve
        leaves the sheet."""
        return Solid(_lib().cadaclysm_blacksmith_split_along_curve(self._h(), curve._handle, _tolerance(tolerance)))

    def panel_gap(self, curve: "NurbsCurve", gap: float = 4.0, flange: float = -10.0,
                  tolerance: "float | None" = 0.01) -> "tuple[Solid, Solid]":
        """This sheet parted along `curve` (lying on it, as for `split_along_curve`) into two
        panels with a shut line between them: each is trimmed back `gap / 2` from the curve
        along the sheet, and gets a flange `abs(flange)` deep along its cut edge only -- turned
        under (against the outward normal) for a negative `flange`, out for a positive one, none
        for 0. An open curve should cross the sheet's boundary; a closed one cuts out an island.
        The panel left of the curve's run (seen from the outward normal) first, then the right
        one; a loop run counter-clockwise from that side has the island on its left. Raises
        `BuildError` where the curve leaves the sheet or the gap leaves nothing of a panel."""
        out = (c_void_p * 2)()
        if not _lib().cadaclysm_blacksmith_panel_gap(self._h(), curve._handle, float(gap), float(flange),
                                                     _tolerance(tolerance), out):
            _fail("panel_gap")
        return Solid(out[0]), Solid(out[1])

    def trim_by_curve(self, curve: "NurbsCurve", keep: Literal["outside", "inside", "left", "right"] = "outside",
                      direction: "Point3 | None" = None, tolerance: "float | None" = 0.05) -> "Solid":
        """This sheet cut along `curve` and one side thrown away (see `split_by_curve`):
        `keep="inside"` keeps the island a closed curve bounds, `"outside"` the sheet with the
        hole; for an open curve `"left"` (the same as `"inside"`) keeps the side left of its
        run seen from where `direction` points, `"right"` the other. Raises `BuildError` where
        nothing of the sheet lies on the kept side."""
        if keep not in ("outside", "inside", "left", "right"):
            raise BuildError(f"trim_by_curve: keep must be 'outside', 'inside', 'left' or 'right', not {keep!r}")
        return Solid(_lib().cadaclysm_blacksmith_trim_by_curve(self._h(), curve._handle, _vec3(direction),
                                                               keep in ("inside", "left"), _tolerance(tolerance)))

    def flange(self, edges: "Iterable[Edge | int]", section: "NurbsCurve", tolerance: "float | None" = 1e-3,
               join: bool = True) -> "Solid":
        """`section` swept along each of `edges` (naked edges of this sheet: `Edge` objects or
        their indices) on the face's own frame: at every point of the edge the section's `x`
        runs outward from the face -- square to the edge, in the face's tangent plane -- and its
        `y` along the face's normal, so a section from `(0, 0)` to `(0, -10)` turns the edge
        under by 10 all along it however the panel curves, `(0, 0)` to `(10, 0)` carries the
        face on, and a lip stands proud with `y > 0`. `section` is a curve in the plane
        `z = 0` starting at the origin. With `join` the sweeps come back sewn to this sheet (its
        faces first, then one per edge), else alone, sewn to each other. Each sweep is fitted
        within `tolerance`; `sheet_error` says how close. Raises `BuildError` for an edge
        bordered by two faces, a section not starting at the origin, and sweeps that did not sew
        on."""
        which = _indices(edges, "flange", "edges", edges=True)
        arr = (c_uint32 * len(which))(*which)
        err = c_double(0.0)
        solid = Solid(_lib().cadaclysm_blacksmith_flange(self._h(), arr, len(which), section._handle, _tolerance(tolerance),
                                                         bool(join), ctypes.byref(err)))
        solid.sheet_error = err.value
        return solid

    def extrude_to(self, edges: "Iterable[Edge | int]", direction: "Point3", target: "Solid",
                   tolerance: "float | None" = 1e-3, join: bool = True) -> "Solid":
        """Each of `edges` (naked edges of this sheet: `Edge` objects or their indices) slid
        along `direction` until it meets `target`: every point of the edge travels along the
        direction to its first hit on `target`'s faces (trimmed, not their whole surfaces). One
        wall per edge -- the edge's own curve swept straight, bounded by the curve through the
        hits, fitted within `tolerance` of every hit (`sheet_error`) -- so a wheel arch cut in a
        panel runs in to the well's inner wall as its liner. With `join` the walls come back
        sewn to this sheet (its faces first, then one per edge), else alone, sewn to each other.
        Raises `BuildError` naming the point whose line misses the target."""
        which = _indices(edges, "extrude_to", "edges", edges=True)
        arr = (c_uint32 * len(which))(*which)
        err = c_double(0.0)
        solid = Solid(_lib().cadaclysm_blacksmith_extrude_to(self._h(), arr, len(which), _vec3(direction), target._h(),
                                                             _tolerance(tolerance), bool(join), ctypes.byref(err)))
        solid.sheet_error = err.value
        return solid

    @staticmethod
    def join_sheets(sheets: "Iterable[Solid]", tolerance: "float | None" = 0.0) -> "tuple[Solid, JoinReport]":
        """`sheets` joined into one body, their faces in order, and a :class:`JoinReport` of
        what was done: every two naked edges whose ends and curves agree within `tolerance`
        (0: a rounding of the body's size) sewn into one -- a gap closed is kept as that edge's
        own tolerance -- the faces turned to agree, and a closed result turned to face out, a
        solid the booleans, `mass` and the writers take. Edges with exact curves are compared
        to the tolerance however coarsely each was sampled. At a tolerance above 0 a
        T-junction is sewn too: one sheet's edge along part of another's is first cut where the
        other's corner lies on it."""
        sheets = list(sheets)
        handles = (c_void_p * max(len(sheets), 1))(*[s._h() for s in sheets])
        report = _JoinReport()
        joined = Solid(_lib().cadaclysm_blacksmith_join_sheets(handles, len(sheets), _tolerance(tolerance), ctypes.byref(report)))
        return joined, JoinReport(report)

    def mirror_join(self, plane: FrameLike, snap: float = 0.0, tolerance: "float | None" = 0.0) -> "tuple[Solid, SymmetryReport]":
        """This half and its reflection across `plane` (its z the plane's normal) joined into
        one symmetric body -- half a car, a hull or a bottle modelled once -- the half's faces
        first, and a :class:`SymmetryReport` of how well the seam on the plane meets.

        With `snap` above 0, every NURBS face that is its whole surface and has a side whose
        control points all lie within `snap` of the plane is squared to it first: that side
        pulled onto the plane, the next row of control points stood straight off it along the
        normal (keeping its distance from the plane). The surface then crosses the plane at
        90 degrees, so it meets its mirror tangent and curvature continuous; nothing past that
        row moves. `snap` 0 mirrors the half as it is, a crease wherever it leans. The halves
        are sewn within `tolerance` (0: a rounding of the body's size). Raises `BuildError` for
        a half on both sides of the plane, no edge of it on the plane, or a face that cannot be
        squared (its next row on the plane or past it)."""
        report = (c_double * 7)()
        out = Solid(_lib().cadaclysm_blacksmith_mirror_join(self._h(), _frame(plane), float(snap), _tolerance(tolerance), report))
        return out, SymmetryReport(report)

    def pattern(self, transforms: "Iterable[Transform | Iterable[float]]", tolerance: "float | None" = None) -> "tuple[Solid, PatternReport]":
        """This body and its copies at `transforms` (rigid :class:`Transform` s, typically from
        :class:`Pattern`; instance 0 the identity keeps the original) as one body -- a pattern of
        bodies. Copies apart from each other are put together with no boolean at all; copies that
        overlap are joined, one boolean a group. Raises `BuildError` for no transforms or one
        that is not rigid."""
        flat, n = _transforms(transforms)
        report = (c_double * 3)()
        out = Solid(_lib().cadaclysm_blacksmith_pattern(self._h(), flat, n, _tolerance(tolerance), report))
        return out, PatternReport(report)

    def pattern_feature(self, tool: "Solid", op: str, transforms: "Iterable[Transform | Iterable[float]]",
                        tolerance: "float | None" = None) -> "tuple[Solid, PatternReport]":
        """`tool` (any closed solid, typically a `_tool` method's result) placed at each of
        `transforms` and applied to this body by `op`, `"cut"` or `"join"` -- a pattern of
        features (Fusion's compute type *identical*). Copies apart from each other go into one
        multi-lump tool and one boolean; overlapping copies fall into a few groups. A copy that
        shares no volume with the body is `missed`: dropped for a cut, kept as a body of its own
        for a join. Raises `ValueError` for an unknown `op`, `BuildError` for no transforms, one
        not rigid, or a tool that is not closed."""
        code = _choice(_FEATURE_OPS, op, "pattern_feature", "op")
        flat, n = _transforms(transforms)
        report = (c_double * 3)()
        out = Solid(_lib().cadaclysm_blacksmith_pattern_feature(self._h(), tool._h(), code, flat, n, _tolerance(tolerance), report))
        return out, PatternReport(report)

    def _hole_args(self, what: str, points, diameter, direction, extent, depth, tip_angle, face, head, head_diameter, head_depth,
                   head_angle, tolerance) -> tuple:
        ext = _choice(_HOLE_EXTENTS, extent, what, "extent")
        kind = _choice(_HOLE_HEADS, head, what, "head")
        arr, n = _hole_points(points, what)
        return (self._h(), arr, n, float(diameter), _vec3(direction), ext, float("nan") if depth is None else float(depth),
                float(tip_angle), NONE if face is None else int(face), kind, float(head_diameter), float(head_depth),
                float(head_angle), _tolerance(tolerance))

    def hole(self, points: "Point3 | Iterable[Point3]", diameter: float, *, direction: "Point3 | None" = None,
             extent: str = "through", depth: "float | None" = None, tip_angle: float = math.radians(118), face: "int | None" = None,
             head: "str | None" = None, head_diameter: float = 0.0, head_depth: float = 0.0, head_angle: float = math.radians(90),
             tolerance: "float | None" = None) -> "tuple[Solid, HoleReport]":
        """This body drilled at `points` (one point, or several: one hole each, all one spec, one
        cut) -- the bore an exact cylinder of `diameter`, a counterbore an exact cylinder, a
        countersink and a drill point exact cones -- and a :class:`HoleReport`.

        `direction` is the drilling direction, into the material, shared by every point; None
        drills each point along the inward normal of the face it lies on (on an edge, the
        lowest-numbered face's). `extent`: `"through"` everything ahead of the point;
        `"blind"`, `depth` of full bore then a drill point of included angle `tip_angle` (0 or
        pi: a flat bottom); `"to_face"`, until the axis first meets face `face`, the bore ending
        on it; `"to_next"`, until the bore first leaves the material. `head`: None, or
        `"counterbore"` (`head_diameter` across, `head_depth` deep) or `"countersink"`
        (`head_diameter` across at the point, included angle `head_angle`), measured from the
        point. Angles in radians. Raises `ValueError` for an unknown `extent` or `head`, and
        `BuildError` for a diameter not positive, a depth or face its extent does not take, a
        head not wider than the bore, an angle out of range, a point not on a face with no
        direction, a hole that removes nothing, or a face the axis never meets."""
        args = self._hole_args("hole", points, diameter, direction, extent, depth, tip_angle, face, head, head_diameter, head_depth,
                               head_angle, tolerance)
        n = args[2]
        report, bottoms = (c_double * 2)(), (c_double * max(n, 1))()
        out = Solid(_lib().cadaclysm_blacksmith_hole(*args, report, bottoms))
        return out, HoleReport(report, bottoms[:n])

    def hole_tool(self, points: "Point3 | Iterable[Point3]", diameter: float, *, direction: "Point3 | None" = None,
                  extent: str = "through", depth: "float | None" = None, tip_angle: float = math.radians(118), face: "int | None" = None,
                  head: "str | None" = None, head_diameter: float = 0.0, head_depth: float = 0.0, head_angle: float = math.radians(90),
                  tolerance: "float | None" = None) -> "Solid":
        """The tool :meth:`hole` cuts with, from the same arguments: a closed solid, one lump a
        point -- for :meth:`pattern_feature` or a boolean of your own."""
        args = self._hole_args("hole_tool", points, diameter, direction, extent, depth, tip_angle, face, head, head_diameter,
                               head_depth, head_angle, tolerance)
        return Solid(_lib().cadaclysm_blacksmith_hole_tool(*args))

    def rib(self, curve: "NurbsCurve", plane: FrameLike, thickness: float, *, side: str = "both", toward: "Point3 | None" = None,
            tolerance: "float | None" = None) -> "Solid":
        """This body with a rib along `curve`, an open curve lying in `plane` (a frame): the region
        of the plane between the curve and the body on the `toward` side (a direction in the
        plane; None: toward the body's nearest point), the curve's ends carried on along their
        tangents to the body, thickened `thickness` along the plane's normal -- `side` `"both"`
        (half each side), `"front"` (+z) or `"back"` (-z) -- and joined. Raises `ValueError` for
        an unknown `side`, `BuildError` for a curve closed or not in the plane, a thickness not
        positive, a slab that meets nothing, or a region not closed by the body."""
        code = _choice(_RIB_SIDES, side, "rib", "side")
        return Solid(_lib().cadaclysm_blacksmith_rib(self._h(), curve._handle, _frame(plane), float(thickness), code, _vec3(toward),
                                                     _tolerance(tolerance)))

    def rib_tool(self, curve: "NurbsCurve", plane: FrameLike, thickness: float, *, side: str = "both", toward: "Point3 | None" = None,
                 tolerance: "float | None" = None) -> "Solid":
        """The slab :meth:`rib` joins, alone, from the same arguments."""
        code = _choice(_RIB_SIDES, side, "rib_tool", "side")
        return Solid(_lib().cadaclysm_blacksmith_rib_tool(self._h(), curve._handle, _frame(plane), float(thickness), code, _vec3(toward),
                                                          _tolerance(tolerance)))

    def web(self, curves: "NurbsCurve | Iterable[NurbsCurve]", plane: FrameLike, thickness: float, *, side: str = "both",
            depth: "float | None" = None, both_ways: bool = False, tolerance: "float | None" = None) -> "Solid":
        """This body with a web along each of `curves` (one open curve or several, in `plane`):
        each offset in the plane to `thickness` -- `side` `"both"`, `"left"` or `"right"` of the
        curve's run, the plane's normal up -- its ends carried along their tangents to the body,
        its walls run along the plane's normal until they meet the body (`depth` None) or for
        `depth`, one way (the normal's) or both when `both_ways`. All the webs are one tool and
        one join; crossing curves make a network. Raises `ValueError` for an unknown `side`,
        `BuildError` for no curves, one closed or not in the plane, a thickness not positive,
        or walls that meet nothing or are not closed by the body."""
        code = _choice(_WEB_SIDES, side, "web", "side")
        arr, n = _curve_array([curves] if isinstance(curves, NurbsCurve) else curves)
        return Solid(_lib().cadaclysm_blacksmith_web(self._h(), arr, n, _frame(plane), float(thickness), code,
                                                     float("nan") if depth is None else float(depth), bool(both_ways), _tolerance(tolerance)))

    def web_tool(self, curves: "NurbsCurve | Iterable[NurbsCurve]", plane: FrameLike, thickness: float, *, side: str = "both",
                 depth: "float | None" = None, both_ways: bool = False, tolerance: "float | None" = None) -> "Solid":
        """The walls :meth:`web` joins, alone, from the same arguments."""
        code = _choice(_WEB_SIDES, side, "web_tool", "side")
        arr, n = _curve_array([curves] if isinstance(curves, NurbsCurve) else curves)
        return Solid(_lib().cadaclysm_blacksmith_web_tool(self._h(), arr, n, _frame(plane), float(thickness), code,
                                                          float("nan") if depth is None else float(depth), bool(both_ways), _tolerance(tolerance)))

    def recess(self, outline: "NurbsCurve", depth: float, draft: float = 0.0, fillet: float = 0.0, pane: bool = True,
               tolerance: "float | None" = 0.05) -> "tuple[Solid, tuple[int, int, int, int]]":
        """This sheet with an opening recessed into it along `outline` -- a window, a lamp, a
        grille or an air intake set into a panel -- and how many of the result's faces are each
        part's: `(sheet, fillet, walls, pane)`, the faces in that order.

        `outline` is a closed curve on the sheet (one face or several joined); each of its
        points is found on the sheet, so it may stand a little off it. The walls run back
        `depth` along the sheet's own normal at every point of the rim -- not along one view --
        behind the face (against its normal; negative: in front), leaning in toward the opening
        by `draft` radians (negative: out) and meeting on the mitre at the outline's corners.
        `fillet` above 0 rounds the rim between the sheet and the walls (the outline must then
        be smooth). `pane` closes the back with one patch whose four sides end where the
        outline turns most, so it does not twist. Every piece is sewn to the next: only the
        sheet's own boundary is left naked, and the walls' foot without a pane. Raises
        `BuildError` for an outline that is not closed, a corner with a fillet, or a fillet
        deeper than the walls."""
        faces = (c_uint32 * 4)()
        out = Solid(_lib().cadaclysm_blacksmith_recess(self._h(), outline._handle, float(depth), float(draft), float(fillet),
                                                       bool(pane), _tolerance(tolerance), faces))
        return out, (faces[0], faces[1], faces[2], faces[3])

    def split_sheet(self, tool: "Solid", tolerance: "float | None" = 0.05, progress: Progress = None) -> "Solid":
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

    def intersect(self, other: "Solid", tolerance: "float | None" = 0.05, progress: Progress = None) -> "Intersection":
        """Where this solid's faces cross or coincide with `other`'s, at `tolerance`,
        as an :class:`Intersection`: `chains` along the curves the faces meet on and
        `overlaps` where a face pair coincides. Neither solid is changed; either may
        be an open sheet. No crossing is an empty result, never an error.

        Each :class:`Chain`'s points are within `tolerance` of both faces' exact
        surfaces; there is one chain per face pair per branch -- chains are not
        joined across a face boundary or a closed curve's seam, so join them by
        matching ends. A chain's `curve` is its exact curve where the kernel found
        one every point lies within `tolerance` of, else `None`; `tangent` is set
        where the surfaces are near-tangent along the chain or the snap did not
        settle (the points are then the best estimate) -- a closed chain that does
        not go once round its own curve (a sliver where two surfaces barely cross)
        has no curve, `tangent` still true. An :class:`Overlap` is a coincident face
        pair with the shared region's rings (outer first, holes after), which may
        be empty for a partial overlap of curved faces whose outlines cross. Known limit: a crossing
        narrower than `tolerance` -- two surfaces passing within it without their
        meshes crossing -- can be missed; near-tangent contact is where this bites.

        `progress(phase, done, total)` hears "meet" on the exact route; "mesh",
        "cull", "cross", "snap" and "curve" where it falls back to the mesh route.
        Raises `BuildError` for a `tolerance` not positive and finite, a
        solid with no faces, or one that meshes to nothing."""
        lib = _lib()
        cb, _keep = _progress(progress)
        h = lib.cadaclysm_blacksmith_intersect(self._h(), other._h(), _tolerance(tolerance), cb, None)
        if not h:
            _fail("intersect")
        try:
            return _intersection_of(h)
        finally:
            lib.cadaclysm_blacksmith_intersection_free(h)

    def self_intersections(self, tolerance: "float | None" = 0.05, progress: Progress = None) -> "Intersection":
        """Where this solid passes through itself, at `tolerance`, as an
        :class:`Intersection` -- :meth:`intersect`'s result with this solid on both
        sides, so each :class:`Chain` and :class:`Overlap` names two faces of this
        solid. Never along its own topology: faces meeting at their shared edges and
        vertices are not a crossing, so a clean solid is an empty result, never an
        error. A chain whose two faces are one face is that face folding through
        itself, and has no `curve`. The solid is not changed; it may be an open sheet.

        The solid is meshed once and crossed against itself, the exact face-pair
        engine refining each crossing of two faces, so the mesh route's known limit
        holds: a crossing narrower than `tolerance` -- two faces passing within it
        without their meshes crossing -- can be missed.

        `progress(phase, done, total)` hears "mesh", "cull", "cross", "snap" and
        "curve". Raises `BuildError` for a `tolerance` not positive and finite, a
        solid with no faces, or one that meshes to nothing."""
        lib = _lib()
        cb, _keep = _progress(progress)
        h = lib.cadaclysm_blacksmith_self_intersect(self._h(), _tolerance(tolerance), cb, None)
        if not h:
            _fail("self_intersect")
        try:
            return _intersection_of(h)
        finally:
            lib.cadaclysm_blacksmith_intersection_free(h)

    def check(self, other: "Solid | None" = None, operation: "str | None" = None, tolerance: "float | None" = 0.05,
              progress: Progress = None) -> "list[Finding]":
        """What is wrong with this solid (and `other`, if given) as the arguments of
        `operation`, at `tolerance`, as a list of :class:`Finding` -- OCCT's
        `BRepAlgoAPI_Check`, gathered from what the kernel already measures. An empty
        list is a valid pair; nothing is changed.

        Each argument is checked alone whatever the operation: no faces (`no_faces`),
        features smaller than `tolerance` as :meth:`health` finds them (`short_edge`,
        `collapsed_edge`, `sliver_face`, `tiny_face`, `tiny_body`, `small_hole`), shared
        edges whose sides part (`loose_edge`), and where it passes through itself as
        :meth:`self_intersections` finds it (`self_intersection`, `self_overlap`, or
        `unmeshable` where it could not be meshed to look). `operation` -- `"join"`,
        `"cut"`, `"common"`, `"split_sheet"`, `"trim"`, `"merge"` or `"intersect"` --
        adds what that verb refuses each argument for: a boolean wants both closed
        (`open`, one finding per free edge) and holding no region wall (`region_wall`, a
        merge's body); a split or trim only its tool (`other`) closed; a merge closed
        manifolds (`non_manifold`) of planes, cylinders, cones, spheres and tori
        (`face_kind`, per face). Without `other`, this solid is held to what the
        operation asks of its first argument. A free edge is no fault without an operation
        that asks for a closed solid: an open sheet is a fine body.

        Not checked: an edge's curve leaving its face's surface, a surface only C0
        inside a face, sub-shapes a boolean would merge.

        `progress(phase, done, total)` hears "health", then "mesh", "cull", "cross",
        "snap" and "curve". Raises `BuildError` for an unknown operation or a
        `tolerance` not positive and finite."""
        lib = _lib()
        cb, _keep = _progress(progress)
        b = None if other is None else other._h()
        op = None if operation is None else str(operation).encode("utf-8")
        h = lib.cadaclysm_blacksmith_check(self._h(), b, op, _tolerance(tolerance), cb, None)
        if not h:
            _fail("check")
        try:
            out, raw = [], _Finding()
            for i in range(lib.cadaclysm_blacksmith_check_count(h)):
                if not lib.cadaclysm_blacksmith_check_finding(h, i, ctypes.byref(raw)):
                    _fail("check_finding")
                out.append(Finding(raw.kind.decode("utf-8"), int(raw.argument), None if raw.index == NONE else int(raw.index),
                                   None if raw.other == NONE else int(raw.other), float(raw.size)))
            return out
        finally:
            lib.cadaclysm_blacksmith_check_free(h)

    def section(self, z: float, tolerance: "float | None" = 0.05) -> "list[Profile]":
        """This solid cut by the plane `Z = z`: its closed outlines there, in XY,
        nested into profiles with holes (boundaries counter-clockwise, holes
        clockwise), a line or a circle crossing kept exact and any other curve as
        lines within `tolerance`. A plane that misses the solid is an empty list.
        Raises `BuildError` for a `z` not finite, a `tolerance` not positive and
        finite, a face lying in the plane (section a little above or below it), or
        a crossing that does not close."""
        return _profile_list(_lib().cadaclysm_blacksmith_solid_section(self._h(), z, _tolerance(tolerance)), "solid_section")

    def hits(self, profile: "Profile", frame: FrameLike, tolerance: "float | None" = 0.05,
             progress: Progress = None) -> "SolidHits":
        """Where `profile`, placed on `frame`, pierces this solid's faces, and the
        pieces its loops cut into, as a :class:`SolidHits`. Neither is changed.

        A point hit lies within `tolerance` of the segment's exact curve and of the
        face's exact surface, inside the face's trim; its profile spot (`a_start`:
        loop, segment, t) and face spot (`b_start`: face, u, v) evaluate to the point
        within `tolerance`; `touch` where the curve's tangent lies within 1e-3 (sine)
        of the surface's tangent plane there (a graze), false at a crossing. A run is
        a stretch of one segment lying within `tolerance` of one face and inside it,
        longer than `tolerance`. Hits within `tolerance` of each other merge (a hit at
        a segment join reported once, as `(k, t = 1)`; a closed loop's closing join
        reads `(0, 0)`). Every point is in world space
        (the frame applied).

        Pieces (:class:`Piece`) only for a closed body -- an open body has none -- in
        loop order, covering every loop exactly; a piece's spots read a segment join
        as the next segment's start `(k + 1, 0)`, and an open chain runs from `(0, 0)`
        to `(n - 1, 1)`; a loop no hit cuts is one closed piece. `inside` by the piece
        middle's winding number over the body's mesh; a piece lying on the surface is
        inside. Known limit: a segment passing within `tolerance` of a face without
        crossing its mesh can be missed (near-tangent grazes).

        `progress(phase, done, total)` hears "mesh", "cull", "hits" and "pieces".
        Raises `BuildError` for a `tolerance` not positive and finite, a solid with no
        faces or that meshes to nothing, a profile with no segments, or a free-form
        segment that is not an evaluable NURBS curve."""
        lib = _lib()
        cb, _keep = _progress(progress)
        h = lib.cadaclysm_blacksmith_solid_profile_hits(self._h(), profile._handle, _frame(frame), _tolerance(tolerance), cb, None)
        if not h:
            _fail("solid_profile_hits")
        try:
            hits, raw = [], _Hit()
            for i in range(lib.cadaclysm_blacksmith_hit_count(h)):
                if not lib.cadaclysm_blacksmith_hit(h, i, ctypes.byref(raw)):
                    _fail("hit")
                hits.append(_hit_of(raw))
            pieces, inside, start, end = [], c_bool(), _Spot(), _Spot()
            for i in range(lib.cadaclysm_blacksmith_hits_piece_count(h)):
                if not lib.cadaclysm_blacksmith_hits_piece(h, i, ctypes.byref(inside), ctypes.byref(start), ctypes.byref(end)):
                    _fail("hits_piece")
                own = Profile(_checked(lib.cadaclysm_blacksmith_hits_piece_profile(h, i), "hits_piece_profile"))
                pieces.append(Piece(bool(inside.value), _spot_of(start), _spot_of(end), own))
            return SolidHits(hits, pieces)
        finally:
            lib.cadaclysm_blacksmith_hits_free(h)

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
        """The solid's axis-aligned box, `((min_x, min_y, min_z), (max_x, max_y,
        max_z))`, at the same cost whatever its size: its mesh at a thousandth of
        its own extent, in float64, so the box is inside the exact one and short
        of it by at most that. Worked out once per solid, apart from the
        tessellation `mesh` caches -- asking it never invalidates a mesh's
        arrays. `bounds_at` is the box of the mesh at a tolerance you name."""
        lo, hi = (c_double * 3)(), (c_double * 3)()
        if not _lib().cadaclysm_blacksmith_box(self._h(), lo, hi):
            _fail("box")
        return tuple(lo), tuple(hi)

    def bounds_at(self, tolerance: "float | None") -> "tuple[tuple[float, float, float], tuple[float, float, float]]":
        """The solid's axis-aligned bounds, over the positions of its cached
        tessellation at `tolerance` (the same cache `mesh` fills and reuses,
        so a second call at the same tolerance is free): `((min_x, min_y,
        min_z), (max_x, max_y, max_z))`."""
        lo, hi = (c_double * 3)(), (c_double * 3)()
        if not _lib().cadaclysm_blacksmith_bounds(self._h(), _tolerance(tolerance), lo, hi):
            _fail("bounds")
        return tuple(lo), tuple(hi)

    def bounds64(self, tolerance: "float | None" = 0.05) -> "tuple[tuple[float, float, float], tuple[float, float, float]]":
        """`bounds` from the float64 positions: exact far from the origin."""
        lo, hi = (c_double * 3)(), (c_double * 3)()
        if not _lib().cadaclysm_blacksmith_bounds64(self._h(), _tolerance(tolerance), lo, hi):
            _fail("bounds64")
        return tuple(lo), tuple(hi)

    def leaked_edges(self, tolerance: "float | None" = 0.05) -> int:
        """How many edges of `mesh(tolerance)` -- the triangles `mesh` and
        `face_triangles` hand out -- are bound by anything other than exactly
        two triangles -- zero for a closed solid. A hole, a fold, and a seam
        two solids share along a line (four triangles) all count here;
        `unpaired_edges` is the check that lets the seam pass. A body past its
        triangle ceiling leaves faces empty, and those open the edges they
        share with faces that meshed."""
        n = _lib().cadaclysm_blacksmith_leaked_edges(self._h(), _tolerance(tolerance))
        if n == NONE:
            _fail("leaked_edges")
        return n

    def unpaired_edges(self, tolerance: "float | None" = 0.05) -> int:
        """How many edges of the mesh at `tolerance` have directed triangle
        uses that do not cancel out -- zero for a closed, consistently
        oriented solid. Where `leaked_edges` asks for exactly two triangles
        on an edge, this asks that they run opposite ways: a seam two solids
        share along a line pairs off and is *not* counted here even though
        four triangles meet there, while a fold -- two triangles running the
        same way -- is."""
        n = _lib().cadaclysm_blacksmith_unpaired_edges(self._h(), _tolerance(tolerance))
        if n == NONE:
            _fail("unpaired_edges")
        return n

    def is_watertight(self, tolerance: "float | None" = 0.05) -> bool:
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

    def face_round_radius(self, face: int) -> float:
        """The radius of the round face `face` belongs to -- a fillet's face that
        `unfillet` can take back -- 0 where it is none. Raises `BuildError` for a face
        the solid does not have."""
        r = _lib().cadaclysm_blacksmith_face_round_radius(self._h(), face)
        if math.isnan(r):
            _fail("face_round_radius")
        return r

    def face_chamfer_distance(self, face: int) -> float:
        """The distance of the chamfer face `face` belongs to -- a bevel `unchamfer`
        can take back -- 0 where it is none. Raises `BuildError` for a face the solid
        does not have."""
        d = _lib().cadaclysm_blacksmith_face_chamfer_distance(self._h(), face)
        if math.isnan(d):
            _fail("face_chamfer_distance")
        return d

    def edge_beziers(self, tolerance: "float | None" = None) -> "tuple[float, ...]":
        """The edges as rational cubic Béziers, sixteen numbers each (`x y z w` per
        control point, the point Cartesian and its weight beside it) -- what a viewer
        draws the edges by: exact where an edge's curve has a Bézier form, flattened
        within `tolerance` where it has none (None: the solid's effective tolerance)."""
        lib = _lib()
        t = _tolerance(tolerance)
        n = lib.cadaclysm_blacksmith_edge_bezier_count(self._h(), t)
        out = (c_double * (16 * n))()
        _ok(lib.cadaclysm_blacksmith_edge_beziers(self._h(), t, out), "edge_beziers")
        return tuple(out)

    def isocurve_beziers(self, density: int = 4, tolerance: "float | None" = None) -> "tuple[float, ...]":
        """The faces' isoparametric curves as rational cubic Béziers, sixteen numbers
        each as `edge_beziers` gives them: `density` interior lines each way on every
        curved face, clipped to the face, plus the lines at the ends of its parameter
        span; a flat face draws none. Exact where the surface has a closed form for the
        line, flattened within `tolerance` elsewhere (None: the solid's effective
        tolerance)."""
        lib = _lib()
        t = _tolerance(tolerance)
        n = lib.cadaclysm_blacksmith_isocurve_bezier_count(self._h(), density, t)
        out = (c_double * (16 * n))()
        _ok(lib.cadaclysm_blacksmith_isocurve_beziers(self._h(), density, t, out), "isocurve_beziers")
        return tuple(out)

    def face_tree(self) -> "RTree":
        """An `RTree` over this solid's faces: one entry per face, its id the face index the
        other face calls take, its box holding the face (the box the boolean's broad phase pairs
        faces by, grown by a thousandth of the solid's extent). No faces give an empty tree."""
        return RTree._adopt(_lib().cadaclysm_blacksmith_solid_face_tree(self._h()), "solid_face_tree")

    def health(self, tolerance: "float | None" = None, mesh: bool = False) -> "HealthReport":
        """What is wrong with this solid, as a `HealthReport`: the free edges (the sides one
        face bounds) and the wires they chain into, with each edge's nearest partner and the
        gap to it; the features below `tolerance`; the loose edges; and what sewing would
        join and leave. `tolerance` is the length below which a feature is "small" and a
        gap closes -- `None`, or a value that is not finite and positive, takes the default
        (the report shows what was used). `mesh=True` also meshes the solid and reports
        where the mesh cracks (`cracks`); without it `cracks` is `None`. Nothing moves."""
        lib = _lib()
        nan = float("nan")
        tol = nan if tolerance is None else float(tolerance)
        if _WASM:
            r = lib.health_object(self._h(), tol, bool(mesh))
            return _health_report([int(v) for v in r.counts], [float(v) for v in r.sizes],
                                  [int(v) for v in r.freeEdgeIds], [float(v) for v in r.freeEdgeSizes],
                                  [int(v) for v in r.wireRuns], [float(v) for v in r.wireSizes],
                                  [int(v) for v in r.smallItems], [float(v) for v in r.smallSizes],
                                  [int(v) for v in r.crackEdges])
        handle = _checked(lib.cadaclysm_blacksmith_health(self._h(), tol, bool(mesh)), "health")
        try:
            counts = (c_uint32 * 18)()
            sizes = (c_double * 8)()
            if not lib.cadaclysm_blacksmith_health_summary(handle, counts, sizes):
                _fail("health")
            n = lib.cadaclysm_blacksmith_health_free_edges(handle, None, None)
            free_ids, free_sizes = (c_uint32 * (6 * n))(), (c_double * (2 * n))()
            if n:
                lib.cadaclysm_blacksmith_health_free_edges(handle, free_ids, free_sizes)
            n = lib.cadaclysm_blacksmith_health_wires(handle, None, None)
            wire_runs, wire_sizes = (c_uint32 * (3 * n))(), (c_double * (2 * n))()
            if n:
                lib.cadaclysm_blacksmith_health_wires(handle, wire_runs, wire_sizes)
            n = lib.cadaclysm_blacksmith_health_small(handle, None, None)
            small_items, small_sizes = (c_uint32 * (2 * n))(), (c_double * n)()
            if n:
                lib.cadaclysm_blacksmith_health_small(handle, small_items, small_sizes)
            n = lib.cadaclysm_blacksmith_health_crack_edges(handle, None)
            cracks = (c_uint32 * n)()
            if n:
                lib.cadaclysm_blacksmith_health_crack_edges(handle, cracks)
            return _health_report(list(counts), list(sizes), list(free_ids), list(free_sizes), list(wire_runs),
                                  list(wire_sizes), list(small_items), list(small_sizes), list(cracks))
        finally:
            lib.cadaclysm_blacksmith_health_free(handle)

    def healed(self, tolerance: "float | None" = None, edges: bool = True, faces: bool = True,
               holes: bool = True) -> "tuple[Solid, HealReport]":
        """This solid with its small features removed, and what was done, as a new `Solid`
        and a `HealReport`; this one is left as it was. The features are the ones `health`
        lists as small at `tolerance`: short and collapsed edges, sliver and tiny faces,
        small holes. Every fix is a vertex merge, and an edge it moves records how far as
        its `edge_tolerance`. A guard compares the result's health with this one's and
        refuses fixes that made it worse (`guarded`). `edges`, `faces` and `holes` switch
        each kind of fix; a kind switched off is refused as "toggled". `tolerance` `None`,
        or a value that is not finite and positive, takes the default (the report shows
        what was used)."""
        lib = _lib()
        tol = float("nan") if tolerance is None else float(tolerance)
        flags = _heal_flags(edges, faces, holes)
        if _WASM:
            r = lib.healed_object(self._h(), tol, flags)
            healed = Solid(int(r.solid))
            return healed, _heal_report([int(v) for v in r.counts], [float(v) for v in r.sizes],
                                        [int(v) for v in r.fixItems], [float(v) for v in r.fixSizes],
                                        [int(v) for v in r.refusedItems], [float(v) for v in r.refusedSizes])
        handle = _checked(lib.cadaclysm_blacksmith_healed(self._h(), tol, flags), "healed")
        try:
            counts = (c_uint32 * 11)()
            sizes = (c_double * 2)()
            if not lib.cadaclysm_blacksmith_heal_summary(handle, counts, sizes):
                _fail("healed")
            n = lib.cadaclysm_blacksmith_heal_fixes(handle, None, None)
            fix_items, fix_sizes = (c_uint32 * (2 * n))(), (c_double * (2 * n))()
            if n:
                lib.cadaclysm_blacksmith_heal_fixes(handle, fix_items, fix_sizes)
            n = lib.cadaclysm_blacksmith_heal_refused(handle, None, None)
            refused_items, refused_sizes = (c_uint32 * (3 * n))(), (c_double * n)()
            if n:
                lib.cadaclysm_blacksmith_heal_refused(handle, refused_items, refused_sizes)
            report = _heal_report(list(counts), list(sizes), list(fix_items), list(fix_sizes),
                                  list(refused_items), list(refused_sizes))
            return Solid(_checked(lib.cadaclysm_blacksmith_heal_body(handle), "healed")), report
        finally:
            lib.cadaclysm_blacksmith_heal_free(handle)

    def edge_tolerance(self, edge: int) -> "float | None":
        """How far brep edge `edge` (as a `HealFix` names one) may lie off its curve: 0 for
        an exact edge, the distance healing (or sewing) moved it where that is recorded,
        `None` when no trim names the id (an edge healing removed)."""
        lib = _lib()
        t = lib.cadaclysm_blacksmith_edge_tolerance(self._h(), int(edge))
        if math.isnan(t) and _text(lib.cadaclysm_blacksmith_last_error()):
            _fail("edge_tolerance")
        return None if math.isnan(t) else float(t)

    @property
    def tolerances(self) -> Tolerances:
        """What this solid declares about its own precision: `Tolerances(absolute, angular)`,
        read from its file, inherited through every verb from the loosest of its inputs, or
        set by `with_tolerances`; None in a field nothing declared. A verb given
        `tolerance=None` works at `effective_tolerance(self)`, which takes it into account."""
        absolute, angular = c_double(), c_double()
        if not _lib().cadaclysm_blacksmith_solid_tolerances(self._h(), ctypes.byref(absolute), ctypes.byref(angular)):
            _fail("solid_tolerances")
        return Tolerances(_declared(absolute.value), _declared(angular.value))

    def with_tolerances(self, absolute: "float | None" = None, angular: "float | None" = None) -> "Solid":
        """A new solid: this one declaring `absolute` (a length) and `angular` (radians)
        instead of what it declared, its name, paint and marks kept. None (or 0) declares
        nothing for that field. Raises `BuildError` for a negative or infinite value."""
        return Solid(_checked(_lib().cadaclysm_blacksmith_solid_with_tolerances(self._h(), _tolerance(absolute), _tolerance(angular)),
                              "solid_with_tolerances"))

    def vertex_tolerance(self, point: Point3) -> "float | None":
        """How loose this solid's vertex at `point` is, where its producer said (an OCCT `.brep`
        records one per vertex): the tolerance of the nearest recorded vertex within its own
        tolerance of `point`. None where none is recorded there."""
        x, y, z = _point3(point, "vertex_tolerance")
        lib = _lib()
        t = lib.cadaclysm_blacksmith_vertex_tolerance(self._h(), x, y, z)
        if math.isnan(t) and _text(lib.cadaclysm_blacksmith_last_error()):
            _fail("vertex_tolerance")
        return _declared(t)

    def bounds_box(self, tolerance: "float | None" = 0.05) -> "Box":
        """This solid's box at `tolerance`: its boolean mesh, padded by twice that
        -- the broad phase's own bound, cheaper to move and test than the solid
        itself (`Collider` builds one per part at construction)."""
        out = _Box()
        if not _lib().cadaclysm_blacksmith_solid_bounds_box(self._h(), _tolerance(tolerance), ctypes.byref(out)):
            _fail("solid_bounds_box")
        return _box_of(out)

    # -- out
    def mesh(self, tolerance: "float | None" = 0.05) -> "tuple[numpy.ndarray, numpy.ndarray, numpy.ndarray]":
        """`(positions, normals, indices)` as read-only numpy arrays (float32
        (n,3), float32 (n,3), uint32 (m,)): read-only numpy views owned by a held
        tessellation of the solid at `tolerance`: nothing invalidates them -- not a
        re-mesh at another tolerance, not the solid's `close()` (copies under
        Pyodide) -- see the module docs."""
        if _WASM:
            m = _lib().cadaclysm_blacksmith_mesh(self._h(), _tolerance(tolerance))
            if not m.positions:
                _fail("mesh")
            n = m.vertex_count
            return (_copied(m.positions, (n, 3), "f4"),
                    _copied(m.normals, (n, 3), "f4"),
                    _copied(m.indices, (m.index_count,), "u4"))
        held = _Tessellation(self, tolerance, "mesh")
        m = _lib().cadaclysm_blacksmith_tessellation_mesh(held._handle_)
        n = m.vertex_count
        return (_view(held, m.positions, (n, 3), "f4"), _view(held, m.normals, (n, 3), "f4"),
                _view(held, m.indices, (m.index_count,), "u4"))

    def mesh64(self, tolerance: "float | None" = 0.05) -> "tuple[numpy.ndarray, numpy.ndarray, numpy.ndarray]":
        """`mesh` in float64: the same tessellation (the same indices), positions and
        normals unnarrowed: read-only numpy views owned by a held tessellation of the
        solid at `tolerance`: nothing invalidates them -- not a re-mesh at another
        tolerance, not the solid's `close()` (copies under Pyodide)."""
        if _WASM:
            m = _lib().cadaclysm_blacksmith_mesh64(self._h(), _tolerance(tolerance))
            if not m.positions:
                _fail("mesh64")
            n = m.vertex_count
            return (_copied(m.positions, (n, 3), "f8"),
                    _copied(m.normals, (n, 3), "f8"),
                    _copied(m.indices, (m.index_count,), "u4"))
        held = _Tessellation(self, tolerance, "mesh64")
        m = _lib().cadaclysm_blacksmith_tessellation_mesh64(held._handle_)
        n = m.vertex_count
        return (_view(held, m.positions, (n, 3), "f8"), _view(held, m.normals, (n, 3), "f8"),
                _view(held, m.indices, (m.index_count,), "u4"))

    def face_triangles(self, tolerance: "float | None" = 0.05) -> "numpy.ndarray":
        """How many triangles each face meshed to at `tolerance`, a read-only
        uint32 array with one count per face in face order: the triangles of
        `mesh(tolerance)` run face by face, so face `f`'s are the `counts[f]`
        after the first `counts[:f].sum()`. The counts sum to the mesh's
        triangle count; a face that meshed to nothing counts zero. Read-only numpy
        views owned by a held tessellation of the solid at `tolerance`: nothing
        invalidates them -- not a re-mesh at another tolerance, not the solid's
        `close()` (copies under Pyodide)."""
        if _WASM:
            t = _lib().cadaclysm_blacksmith_mesh_face_triangles(self._h(), _tolerance(tolerance))
            if not t.counts:
                _fail("mesh_face_triangles")
            return _copied(t.counts, (t.face_count,), "u4")
        held = _Tessellation(self, tolerance, "mesh_face_triangles")
        t = _lib().cadaclysm_blacksmith_tessellation_face_triangles(held._handle_)
        return _view(held, t.counts, (t.face_count,), "u4")

    def edge_polylines(self, tolerance: "float | None" = 0.05) -> "list[numpy.ndarray]":
        """The feature edges as a list of float32 (k,3) read-only arrays: read-only
        numpy views owned by a held tessellation of the solid at `tolerance`: nothing
        invalidates them -- not a re-mesh at another tolerance, not the solid's
        `close()` (copies under Pyodide)."""
        if _WASM:
            p = _lib().cadaclysm_blacksmith_edge_polylines(self._h(), _tolerance(tolerance))
            if not p.offsets:
                _fail("edge_polylines")
            points = _copied(p.points, (p.point_count, 3), "f4")
            offsets = [p.offsets[i] for i in range(p.polyline_count + 1)]
            return [points[a:b] for a, b in zip(offsets, offsets[1:])]
        held = _Tessellation(self, tolerance, "edge_polylines")
        p = _lib().cadaclysm_blacksmith_tessellation_edge_polylines(held._handle_)
        points = _view(held, p.points, (p.point_count, 3), "f4")
        offsets = [p.offsets[i] for i in range(p.polyline_count + 1)]
        return [points[a:b] for a, b in zip(offsets, offsets[1:])]

    def fem_mesh(self, tolerance: float = 0.01, max_size: float = 0.0, placement: FrameLike | None = None,
                 progress: Progress = None) -> "FemMesh":
        """This solid meshed for a solver, as a `FemMesh`: nodes welded by bits,
        triangles wound outward, each node tagged with the lowest-dimension B-rep
        entity it lies on, and every crack reported rather than closed.

        `tolerance` is the chordal tolerance in model units, finite and above zero, and
        **it alone governs how closely the mesh follows the geometry**. `max_size` is a
        size ceiling, finite and zero or more, `0` being no ceiling (curvature alone):
        **it bounds the boundary and targets the interior**, which is not a
        longest-element-edge guarantee. It adds boundary nodes without refining boundary
        geometry, and `FemMesh.longest_edge` is what the mesh actually came to -- the
        figure to check against it.

        Those two defaults are `FemOptions::default()`'s own, restated here because
        **there is nothing to ask under Pyodide**: the wasm kernel has no
        `fem_options_init` export, its `fem_mesh` taking the two as plain scalars, so a
        signature that said "the library's default" would have no default in the
        notebook. The DLL's own init is still called where there is one, so a field
        added to the struct later defaults without this line being touched; only these
        two are overwritten. (`cadaclysm.py`'s `Node.fem_mesh` restates the same pair,
        for symmetry rather than necessity -- the reader wrapper has no wasm backend.)

        `placement` is a `Frame` or twelve numbers -- origin, x, y, z -- as every frame
        in this module, and None for the identity; it is applied in float64 throughout.
        This is the one frame argument here that may be omitted, a solid meshed in its
        own coordinates being the common case where a sweep without a frame is nothing
        at all. The reader module's `Node.fem_mesh` takes **sixteen**, column-major, so
        a caller moving between the two reformats the placement.

        `progress(phase, done, total)` hears **"meshing"** and **"welding"**. An opened
        phase is not a promise of a closed one: a refused call opens no phase at all,
        and a solid that meshes to no triangles reports "meshing" through to `1 of 1`
        and then raises with no "welding" -- that close says the mesher finished, not
        that it produced something.

        **A cracked body is not a failure**: it comes back with `watertight` False and
        its cracks in `open_edges` / `folded_edges`, and nothing is welded shut to make
        it look sound. Raises `BuildError` for a tolerance or `max_size` the mesher
        refuses, a placement that is not twelve finite numbers or is not invertible, a
        closed solid this module cannot mesh, and a solid that meshes to no triangles.

        No unlicensed notice here: `FemMesh.msh_text` and `FemMesh.save_msh` print it,
        this library noticing on its writers rather than on its builders."""
        options = _FemOptions()
        # `init` writes `sizeof(CadaclysmBlacksmithFemOptions)` bytes as the *library*
        # knows that type, into the struct `_FemOptions` declares -- which is why
        # `cadaclysm-capi/tests/bindings.rs` pins the two field for field. The wasm has
        # no such export (its `fem_mesh` takes the two numbers as scalars, both set
        # below), exactly as `_svg_options` finds for `svg_options_init`. `size` is then
        # set to this header's own sizeof, which is what the growth rule asks of a
        # caller and what leaves the struct valid on the wasm path too.
        if not _WASM:
            _lib().cadaclysm_blacksmith_fem_options_init(ctypes.byref(options))
        options.size = ctypes.sizeof(_FemOptions)
        options.tolerance, options.max_size = float(tolerance), float(max_size)
        cb, _keep = _progress(progress)
        # None, never an empty array: the wasm export reads `null` as the identity and
        # refuses a zero-length frame as twelve numbers it did not get.
        frame = None if placement is None else _frame(placement)
        h = _lib().cadaclysm_blacksmith_fem_mesh(self._h(), frame, ctypes.byref(options), cb, None)
        if not h:
            _fail("fem_mesh")
        return FemMesh(h)

    def show(self, tolerance: float = 0.05, **options: Any) -> None:
        """Draw the solid with the viewer in use -- with the GPU library
        (`cadaclysm.view.wgpu`), into one shared window that stays open; with the
        terminal, a still, left in the scrollback. Each face is drawn in its own colour
        (`face_colour`: a colour of its own, else the solid's). Keywords: view= (front
        back left right top bottom iso), az=, el=, zoom=, up=, edges=, width=, height=, hint=."""
        _present(self, "show", tolerance, "iso", options)

    def view(self, tolerance: float = 0.05, **options: Any) -> dict[str, Any]:
        """Orbit the solid with the view library in use until it is closed; returns
        the camera (eye, target, up, orthographic) and the last pick, where it was
        left. Keywords as `show`."""
        return _present(self, "view", tolerance, "iso", options)

    def step_text(self, schema: Schema = None, unit: Unit = "mm") -> str:
        return write_step_text([self], schema, unit)

    def step(self, path: FilePath, schema: Schema = None, unit: Unit = "mm") -> None:
        _FsPath(path).write_text(self.step_text(schema, unit), encoding="utf-8")

    def sat_text(self, unit: Unit = "mm") -> str:
        """The solid as ACIS SAT text: analytic surfaces as their own records,
        splines and swept surfaces as exact NURBS."""
        return write_sat_text([self], unit)

    def sat(self, path: FilePath, unit: Unit = "mm") -> None:
        """`sat_text` written to `path` by the library itself."""
        write_sat(path, [self], unit)

    def rhino3dm_bytes(self, unit: Unit = "mm") -> bytes:
        """The solid as a Rhino `.3dm` (`rhino3dm_bytes`): its exact brep, named and
        coloured as the solid is."""
        return rhino3dm_bytes([self], unit)

    def write_3dm(self, path: FilePath, unit: Unit = "mm") -> None:
        """`rhino3dm_bytes` written to `path` by the library itself."""
        write_3dm(path, [self], unit)

    def svg(self, path: FilePath | None = None, **words: Any) -> "str | None":
        """This solid's wireframe as SVG, from the camera the keywords describe --
        `show`'s words, read by the library itself rather than a viewer. With
        `path`, writes the file and returns `None`; without, returns the SVG
        text. Raises `BuildError` on a refused option or a failed write."""
        return svg([self], path, **words)

    def silhouette_beziers(self, **words: Any) -> Beziers:
        """This solid's silhouette from the camera the keywords describe -- the
        curves where its surfaces turn away from the eye, which no edge of it
        lies on, so a sphere has an outline here that its wireframe has none of.

        `svg`'s own camera words, so the same words that draw a picture ask about
        the same eye. `flags` is not read: a silhouette asks for an eye and a
        tolerance, never a line set.

        Exact Béziers where the surface has a closed silhouette form -- sphere,
        cylinder, cone, extrusion -- and a straight-chord polyline carried as
        degree-1 Béziers for every other surface, a torus and a NURBS patch
        included: there is no spline fitter here.

        A solid with no silhouette (every face planar, say) gives a `Beziers`
        that is falsey with `count` 0, which is not an error: the library clears
        its error slot as this call starts (it runs under the library's `guard`),
        so a null return with an empty slot is the empty answer. `BuildError` on a refused option.
        """
        options = _svg_options(**words)
        count = c_uint32(0)
        data = _lib().cadaclysm_blacksmith_silhouette_beziers(self._h(), ctypes.byref(options), ctypes.byref(count))
        if not data:
            # Null is either the empty answer or a refusal, told apart by the
            # error slot. The library clears it as this call starts
            # (it runs under `guard`), so an empty answer leaves it empty and a stale error from
            # an earlier call cannot leak in -- this check depends on that. `_fail` raises
            # unconditionally with a fallback, which is not wanted here: an empty
            # message means the empty answer.
            reason = _text(_lib().cadaclysm_blacksmith_last_error())
            if reason:
                raise BuildError(reason)
            return Beziers(None, None, 0)
        n = count.value
        try:
            # Stride 16 a curve: four control points (x, y, z) then four
            # weights. `_copied` really does copy here -- on the desktop path
            # `_view(None, ptr, ...)` returns `numpy.asarray(_Borrowed(...))`, so
            # `_copied` takes its `array.copy()` branch -- which is what makes
            # the free below safe.
            flat = _copied(data, (n, 16), "f8")
        finally:
            _lib().cadaclysm_blacksmith_silhouette_beziers_free(data, count)
        return Beziers(flat[:, :12].reshape(n, 4, 3), flat[:, 12:], n)

    def document_body(self) -> "dict[str, Any]":
        """This solid as a `solid.body` node holds it: the kernel's own B-rep as a dict of its
        tables (surfaces, curves, trims, loops, faces), every number as it is, and its colours
        (`colour`, `face_colours`, `edges_colour`, `edge_colours`, each only where set), so the
        node gives back exactly this body, drawn as it was. `Document.add_solid` puts it in a
        document."""
        return json.loads(_owned_text(_lib().cadaclysm_blacksmith_document_solid_body(self._handle), "document_solid_body"))

    def brep_text(self) -> str:
        """This solid as OCCT `.brep` text: the exact surfaces and curves,
        with a curve in each face's own parameters for every edge, so OCCT's
        `BRepTools::Read` gives a shape `BRepCheck_Analyzer` finds valid. No unit
        is declared -- a `.brep` carries none -- so the numbers are the numbers."""
        return write_brep_text([self])

    def brep(self, path: FilePath) -> None:
        """`brep_text()` written to `path`, by the library itself."""
        write_brep(path, [self])

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

    def mass(self, accuracy: float = 0.0) -> "Mass":
        """What this solid measures, per unit density: area, volume, centroid and inertia, each
        with a bound on its own error. `accuracy` is relative; 0 asks for the default, a part in
        ten million. See `Mass`.

        Works on a solid read from a file as much as one built here: the reader hands its brep over
        by pointer, so `Solid.from_node(scene, node).mass()` measures what the file holds.
        """
        out = _MassProperties()
        if not _lib().cadaclysm_blacksmith_mass_properties(self._h(), float(accuracy), ctypes.byref(out)):
            _fail("mass")
        return Mass(out)

    def oriented_box(self, accuracy: float = 0.0) -> "OrientedBox":
        """This closed solid's box on its principal axes, as an `OrientedBox` -- tight along a
        clear long direction, not the minimal box in general. `accuracy` is the relative accuracy
        of the inertia the axes come from; 0 or less asks for the box's own default, 1e-5 (not
        `measure.default_accuracy`). The box costs a mass integration at `accuracy` -- tens of
        seconds at 1e-7 on free-form bodies read from files -- and a finer one buys little box:
        the half extents are grown by `diag * max(accuracy, tau/16)`, `tau` the integration's
        tolerance, which starts at 5e-4 of the diagonal, so a body that settles at once (planes,
        cylinders, cones) is grown by about 3.1e-5 of its diagonal however fine `accuracy` is.
        Raises `BuildError` for an open body, which has no inside to take moments of, or an
        `accuracy` that is NaN or infinite."""
        out = _OrientedBox()
        if not _lib().cadaclysm_blacksmith_oriented_box(self._h(), float(accuracy), ctypes.byref(out)):
            _fail("oriented_box")
        return OrientedBox(out)

    def edge_length(self, edge: "Edge | int", accuracy: float = 0.0) -> "Length":
        """The length of edge `edge` (an index into `edges`, or the `Edge` itself) over its own
        range, as a `Length` measured to the relative `accuracy` (0 asks for the default). Raises
        `BuildError` for an edge past the end or one with no curve to measure."""
        index = edge.index if isinstance(edge, Edge) else operator.index(edge)
        out = _Length()
        if not _lib().cadaclysm_blacksmith_edge_length(self._h(), index, float(accuracy), ctypes.byref(out)):
            _fail("edge_length")
        return Length(out)

    def edge_point_at_length(self, edge: "Edge | int", s: float, accuracy: float = 0.0) -> "At":
        """The point at arc length `s` along edge `edge` (an index into `edges`, or the `Edge`
        itself) from the start of its own range, `s` in `[0, edge_length]`, measured to the
        relative `accuracy` (0 asks for the default). `segment` is `None` on an edge. Raises
        `BuildError` for an `s` off the edge, an edge past the end or one with no exact curve."""
        index = edge.index if isinstance(edge, Edge) else operator.index(edge)
        out = _At()
        if not _lib().cadaclysm_blacksmith_edge_point_at_length(self._h(), index, float(s), float(accuracy), ctypes.byref(out)):
            _fail("edge_point_at_length")
        return At(out)

    def edge_divide_by_count(self, edge: "Edge | int", n: int, accuracy: float = 0.0) -> "list[At]":
        """Edge `edge` in `n` pieces of equal arc length: `n + 1` samples from its start to its
        end, or `n` for an edge that closes on itself (a whole circle). Raises `BuildError` for
        an `n` of 0 or above 1 000 000, `ValueError` for an `n` that is not a whole number from 0
        to 4294967295, and as `edge_point_at_length`."""
        index = edge.index if isinstance(edge, Edge) else operator.index(edge)
        return _samples("edge_divide_by_count", _lib().cadaclysm_blacksmith_edge_divide_by_count(
            self._h(), index, _u32(n, "edge_divide_by_count: n"), float(accuracy)))

    def edge_divide_by_length(self, edge: "Edge | int", step: float, accuracy: float = 0.0) -> "list[At]":
        """Samples of edge `edge` every `step` of arc length from its start: the last piece is
        whatever is left over, its end a sample only where a step lands on it, and a closed edge
        never repeats its start. Raises `BuildError` for a `step` not positive and finite or
        giving more than 1 000 000 samples, and as `edge_point_at_length`."""
        index = edge.index if isinstance(edge, Edge) else operator.index(edge)
        return _samples("edge_divide_by_length", _lib().cadaclysm_blacksmith_edge_divide_by_length(
            self._h(), index, float(step), float(accuracy)))

    def contains(self, point: Point3, tolerance: "float | None" = 0.05) -> str:
        """Where `point` is relative to this closed solid: `"inside"`, `"outside"`, or `"on"`
        within `tolerance` of its boundary -- absolute, in model units (default 0.05). Meshes
        the body every call -- for
        more than a few points build a `classifier` once. Raises `BuildError` for an open body,
        a point not finite, or a `tolerance` not positive and finite."""
        out = c_uint32(NONE)
        if not _lib().cadaclysm_blacksmith_contains(self._h(), _point3(point, "contains"), _tolerance(tolerance),
                                                     ctypes.byref(out)):
            _fail("contains")
        return _containment(out.value, "contains")

    def classifier(self, tolerance: "float | None" = 0.05) -> "Classifier":
        """A `Classifier` for this closed solid at `tolerance` -- absolute, in model units
        (default 0.05): the body meshed once, then asked point after point. It keeps its own
        reference to the body, so it goes on answering after this solid is closed."""
        return Classifier(self, tolerance)

    def closest(self, other: "Solid", tolerance: "float | None" = 0.05, progress: Progress = None) -> "Closest":
        """The closest points between this solid's boundary and `other`'s, to `tolerance` --
        absolute, in model units (default 0.05) -- as a `Closest`; this solid is side `a`.
        Boundaries are measured, not volumes: a solid inside another is its gap to the outer
        one's skin, never 0 by containment (ask `contains` for that). `progress(phase, done,
        total)` hears "meshing", "pruning" and "refining"; in the browser it is never called.
        Raises `BuildError` for a `tolerance` not positive and finite or a solid with no faces."""
        cb, _keep = _progress(progress)
        out = _Closest()
        if not _lib().cadaclysm_blacksmith_closest(self._h(), other._h(), _tolerance(tolerance), cb, None,
                                                    ctypes.byref(out)):
            _fail("closest")
        return Closest(out)

    def closest_point(self, p: Point3, max_distance: "float | None" = None,
                      tolerance: "float | None" = None) -> "PointFoot | None":
        """The nearest point of this solid's boundary to `p`, as a `PointFoot`, or `None` where it
        lies beyond `max_distance` (None, NaN or +inf: no limit; a point a rounding error past it
        is not beyond, so 0 finds a point on the body). `tolerance` -- absolute, in model units;
        None is the solids' `effective_tolerance` -- sizes the mesh search only: a `refined` False
        answer is within `[d - 2/3 tolerance, d + tolerance]` of the true distance `d`. Meshes the
        body every call: for more than a few points build a `projector` once. Raises `BuildError`
        for a point not finite, a negative `max_distance`, a negative or infinite `tolerance`, or a
        body that meshes to nothing."""
        out = _PointFoot()
        found = _lib().cadaclysm_blacksmith_closest_point(self._h(), _point3(p, "closest_point"), _unlimited(max_distance),
                                                          _tolerance(tolerance), ctypes.byref(out))
        if found < 0:
            _fail("closest_point")
        return _point_foot(out) if found else None

    def projector(self, tolerance: "float | None" = None) -> "Projector":
        """A `Projector` for this solid at `tolerance` -- absolute, in model units; None is the
        solid's `effective_tolerance`: the body meshed once, then asked `closest_point` point
        after point. It keeps its own reference to the body, so it goes on answering after this
        solid is closed. Open bodies and sheets are accepted."""
        return Projector(self, tolerance)

    def triangle_mesh(self, tolerance: "float | None" = None) -> "TriangleMesh":
        """This solid's **measuring** tessellation as a `TriangleMesh`: the mesh the measuring
        queries search, within a third of `tolerance` of the surface -- finer than the display
        mesh `mesh` gives at the same tolerance. Answers against it are exact for the mesh, not
        for the body. `tolerance` -- absolute, in model units; None (or 0, or NaN) is the solid's
        `effective_tolerance`. The mesh is a copy: it answers on after this solid is closed.
        Raises `BuildError` for a negative or infinite `tolerance` or a body that meshes to
        nothing."""
        return TriangleMesh._adopt(_lib().cadaclysm_blacksmith_solid_triangle_mesh(self._h(), _tolerance(tolerance)),
                                   "solid_triangle_mesh")

    def curve_closest_points(self, curve: "NurbsCurve", max_distance: "float | None" = None,
                             tolerance: "float | None" = None) -> "CurveBodyFoot | None":
        """The nearest points of `curve` and this solid's boundary, as a `CurveBodyFoot` --
        `crossing` True, distance 0, where the curve passes through the boundary (the earliest
        crossing in `t`) -- or `None` where the body lies beyond `max_distance` (None, NaN or
        +inf: no limit). `tolerance` -- absolute, in model units; None is the solid's
        `effective_tolerance` -- sizes the march along the curve and the mesh search: a `refined`
        False answer is within `[d - 2/3 tolerance, d + tolerance]` of the true distance `d`.
        Meshes the body every call: for more than a few curves build a `projector` once. Raises
        `BuildError` for a negative `max_distance`, a negative or infinite `tolerance`, a body
        that meshes to nothing, or a curve too long for the tolerance."""
        out = _CurveBodyFoot()
        found = _lib().cadaclysm_blacksmith_curve_closest_points(self._h(), curve._handle, _unlimited(max_distance),
                                                                 _tolerance(tolerance), ctypes.byref(out))
        if found < 0:
            _fail("curve_closest_points")
        return _curve_body_foot(out) if found else None

    def face_closest_point(self, face: int, p: Point3) -> "PointFoot":
        """The nearest point to `p` of face `face` alone, inside its trims or on its boundary, as a
        `PointFoot`: exact, no mesh, always `refined`. Raises `BuildError` for a face past the end
        (`face_closest_point: face 99 of 6`), a point not finite, or a face that gives no point."""
        out = _PointFoot()
        if _lib().cadaclysm_blacksmith_face_closest_point(self._h(), operator.index(face), _point3(p, "face_closest_point"),
                                                          ctypes.byref(out)) < 0:
            _fail("face_closest_point")
        return _point_foot(out)

    def edge_closest_point(self, edge: "Edge | int", p: Point3) -> "tuple[float, tuple[float, float, float], float]":
        """The nearest point to `p` of edge `edge` (an index into `edges` -- a `PointFoot`'s `edge`
        -- or the `Edge` itself), on its own curve over its range: `(t, point, distance)`, `t` the
        parameter `Edge.curve` and `edge_point_at_length` use. Exact, no mesh. Raises `BuildError`
        for an edge past the end, one with no exact curve, or a point not finite."""
        index = edge.index if isinstance(edge, Edge) else operator.index(edge)
        out = (c_double * 5)()
        if _lib().cadaclysm_blacksmith_edge_closest_point(self._h(), index, _point3(p, "edge_closest_point"), out) < 0:
            _fail("edge_closest_point")
        return (out[0], (out[1], out[2], out[3]), out[4])

    def thickness_at_face(self, face: int, at: Point3 | None = None, *, maximum: float,
                          tolerance: "float | None" = 0.01) -> "FaceThickness | None":
        """One thickness for face `face` of this solid alone, on a
        `ThicknessGauge` meshed at `tolerance` (default 0.01), used once and freed -- build the
        gauge yourself to ask more than once. `None` where nothing is found; see
        `ThicknessGauge.thickness_at_face`."""
        with ThicknessGauge([self], tolerance) as gauge:
            return gauge.thickness_at_face(0, face, at, maximum=maximum)

    def face_ref(self, face: int) -> "tuple[float, ...]":
        """Face `face` by what it is, eight floats: the surface's kind (plane 0,
        cylinder 1, cone 2, sphere 3, torus 4, NURBS 5, revolution 6, extrusion
        7, sum 8), a point on the surface at the face's middle (x, y, z), the
        outward normal there (x, y, z), and the face's extent. A reference a
        feature made on the face keeps, to find the face again with `find_face`
        when the solid has been rebuilt with its faces moved, split or
        renumbered -- take it before any move you apply to the solid, and look
        it up on the unmoved one. Raises `BuildError` for a face the solid does
        not have."""
        out = (c_double * 8)()
        if not _lib().cadaclysm_blacksmith_face_ref(self._h(), face, out):
            _fail("face_ref")
        return tuple(out)

    def find_face(self, face_ref: Sequence[float], hint: int | None = None, tolerance: "float | None" = 1e-3) -> "int | None":
        """The face `face_ref` (from `face_ref`) refers to: among the faces of
        that kind whose surface passes through the point, facing the same way,
        the one the point lies in -- or, where it lies in none (the face shrank
        away, a hole opened under it), the one whose boundary comes nearest.
        `hint` is the index the face had, preferred among faces that fit equally
        well; `tolerance` how far the point may sit off a surface to still be on
        it. None where the face is gone. Raises `BuildError` for a malformed
        reference."""
        values = [float(v) for v in face_ref]
        if len(values) != 8:
            raise BuildError("find_face: a face reference is eight numbers")
        found = _lib().cadaclysm_blacksmith_find_face(self._h(), (c_double * 8)(*values), -1 if hint is None else int(hint), _tolerance(tolerance))
        if found == -2:
            _fail("find_face")
        return None if found < 0 else int(found)

    def edge_ref(self, edge: int) -> "tuple[float, ...]":
        """Edge `edge` (an index into `edges`) by what it is, fifteen floats: its kind (line 0,
        circle 1, ellipse 2, B-spline 3, other 4), its midpoint (x, y, z), its unit tangent
        there (x, y, z), its length, the outward normals there of the two faces meeting on it
        (x, y, z each; an open sheet's rim gives the one face's twice), and its span -- how far
        from the midpoint `find_edge` may find it on a resized solid. `face_ref`'s twin: a
        reference to find the edge again with `find_edge` once the solid has been rebuilt. Raises
        `BuildError` for an edge past the table or one with no length to measure."""
        out = (c_double * 15)()
        if not _lib().cadaclysm_blacksmith_edge_ref(self._h(), edge, out):
            _fail("edge_ref")
        return tuple(out)

    def find_edge(self, edge_ref: Sequence[float], tolerance: "float | None" = 1e-3) -> "int | None":
        """The edge `edge_ref` (from `edge_ref`) refers to: of the edges of that kind passing
        within `tolerance` of its midpoint and running the same way, the one of nearest length;
        where none does (the solid was resized), the edge of that kind running the same way
        between faces facing the same two ways, the only one or the one clearly nearest, no
        farther than the span. None where the edge is gone. Raises `BuildError` for a
        malformed reference or a tolerance not positive."""
        values = [float(v) for v in edge_ref]
        if len(values) != 15:
            raise BuildError("find_edge: an edge reference is fifteen finite numbers")
        found = _lib().cadaclysm_blacksmith_find_edge(self._h(), (c_double * 15)(*values), _tolerance(tolerance))
        if found == -2:
            _fail("find_edge")
        return None if found < 0 else int(found)

    @property
    def vertex_count(self) -> int:
        """How many vertices this solid has: its edges' ends, welded, in the order
        `vertex_ref` and `find_vertex` index."""
        n = _lib().cadaclysm_blacksmith_vertex_count(self._h())
        if n == 0 and _text(_lib().cadaclysm_blacksmith_last_error()):
            _fail("vertex_count")
        return n

    def vertex_ref(self, vertex: int) -> "tuple[float, float, float]":
        """Vertex `vertex` by where it is: (x, y, z). Raises `BuildError` for a vertex the
        solid does not have."""
        out = (c_double * 3)()
        if not _lib().cadaclysm_blacksmith_vertex_ref(self._h(), vertex, out):
            _fail("vertex_ref")
        return (out[0], out[1], out[2])

    def find_vertex(self, vertex_ref: Sequence[float], tolerance: "float | None" = 1e-3) -> "int | None":
        """The vertex nearest `vertex_ref` (any point: a `vertex_ref`, or one picked) within
        `tolerance`; None where no vertex is that near. Raises `BuildError` for a point that is
        not three finite numbers or a tolerance not positive."""
        values = [float(v) for v in vertex_ref]
        if len(values) != 3:
            raise BuildError("find_vertex: a vertex reference is three finite numbers")
        found = _lib().cadaclysm_blacksmith_find_vertex(self._h(), (c_double * 3)(*values), _tolerance(tolerance))
        if found == -2:
            _fail("find_vertex")
        return None if found < 0 else int(found)

    # -- identity: ids on faces and edges, where each came from, and a verb's history
    def tracked(self) -> "Solid":
        """This solid tracked: its faces numbered 1..n in face order and its edges 1..m in the
        edge table's order, each its own origin. Tracking is opt-in and rides on from here: a
        verb on a tracked solid gives a tracked result, its faces keeping the ids of the faces
        they lie on, and naming those as their origins. A tracked solid comes back as it is."""
        return Solid(_lib().cadaclysm_blacksmith_solid_tracked(self._h()))

    @property
    def is_tracked(self) -> bool:
        """Whether this solid carries face and edge ids (`tracked`, or made from a tracked
        solid, or given an attribute)."""
        tracked = _lib().cadaclysm_blacksmith_solid_is_tracked(self._h())
        if not tracked and _text(_lib().cadaclysm_blacksmith_last_error()):
            _fail("solid_is_tracked")
        return bool(tracked)

    def _id_of(self, call, index: int, what: str) -> "int | None":
        id_ = call(self._h(), index)
        if id_ == 0:
            if _text(_lib().cadaclysm_blacksmith_last_error()):
                _fail(what)
            return None
        return int(id_)

    def face_id(self, face: int) -> "int | None":
        """Face `face`'s id, None where this solid is untracked. An id stays with its face
        through every verb that keeps the face -- a move, a boolean, a fillet of another edge --
        so it names "the same face, through my edits" within a session; a piece split off, a
        later operand's face whose id an earlier one already has, and a face on no input get
        fresh ids, the same run after run. Ids are not written to files: to find a face on a
        model rebuilt or read again, use `face_ref`. Raises `BuildError` for a face the solid
        does not have."""
        return self._id_of(_lib().cadaclysm_blacksmith_face_id, face, "face_id")

    def face_with_id(self, id: int) -> "int | None":  # noqa: A002
        """The face whose id is `id`, None where no face has it (an untracked solid, a face a
        verb deleted)."""
        found = _lib().cadaclysm_blacksmith_face_with_id(self._h(), _id(id, "face_with_id"))
        if found == NONE:
            if _text(_lib().cadaclysm_blacksmith_last_error()):
                _fail("face_with_id")
            return None
        return int(found)

    def _origins(self, count, at, index: int, what: str) -> "list[tuple[int, int]]":
        n = count(self._h(), index)
        if n == NONE:
            _fail(what + "_origin_count")
        operand, id_ = c_uint32(), c_uint64()
        out = []
        for i in range(n):
            _ok(at(self._h(), index, i, ctypes.byref(operand), ctypes.byref(id_)), what + "_origin_at")
            out.append((operand.value, id_.value))
        return out

    def face_origins(self, face: int) -> "list[tuple[int, int]]":
        """The input faces face `face` came from, as `(operand, id)`: the operand its input's
        index in the verb's operand order (a boolean's target 0, its tool 1), the id that
        input face's `face_id`. The face it lies on most first; empty for a face the verb
        generated (a fillet's round, a split's cut face) or an untracked solid; more than one
        for a face merged from several (`join(merge=True)`). Raises `BuildError` for a face the
        solid does not have."""
        lib = _lib()
        return self._origins(lib.cadaclysm_blacksmith_face_origin_count, lib.cadaclysm_blacksmith_face_origin_at, face, "face")

    def edge_id(self, edge: int) -> "int | None":
        """Edge `edge`'s id (an index into `edges`), as `face_id`."""
        return self._id_of(_lib().cadaclysm_blacksmith_edge_id, edge, "edge_id")

    def edge_with_id(self, id: int) -> "int | None":  # noqa: A002
        """The edge whose id is `id`, None where no edge has it."""
        found = _lib().cadaclysm_blacksmith_edge_with_id(self._h(), _id(id, "edge_with_id"))
        if found == NONE:
            if _text(_lib().cadaclysm_blacksmith_last_error()):
                _fail("edge_with_id")
            return None
        return int(found)

    def edge_origins(self, edge: int) -> "list[tuple[int, int]]":
        """The input edge edge `edge` lies on, as `face_origins`: one `(operand, id)`, or
        none for a new edge (edge merges are not seen)."""
        lib = _lib()
        return self._origins(lib.cadaclysm_blacksmith_edge_origin_count, lib.cadaclysm_blacksmith_edge_origin_at, edge, "edge")

    def _history(self, what: str, inputs: "tuple[Solid, ...]") -> History:
        lib = _lib()
        handles = (c_void_p * max(len(inputs), 1))(*[s._h() for s in inputs])
        h = getattr(lib, "cadaclysm_blacksmith_" + what)(self._h(), handles, len(inputs))
        if not h:
            _fail(what)
        try:
            return _read_history(lib, h)
        finally:
            lib.cadaclysm_blacksmith_history_free(h)

    def history(self, *inputs: "Solid") -> History:
        """What the verb that made this solid did to the faces of `inputs` -- passed in its
        operand order (`a.cut(b).history(a, b)`) -- read off this solid's ids and origins
        alone, as a `History`. Raises `BuildError` where this solid or an input is untracked,
        or an origin names an operand past the inputs."""
        return self._history("history", inputs)

    def edge_history(self, *inputs: "Solid") -> History:
        """`history` for the edges, by edge id."""
        return self._history("edge_history", inputs)

    # -- attributes: text on a solid (written to STEP files) and on its faces (in memory)
    @property
    def attributes(self) -> "_abc.Mapping[str, str]":
        """This solid's attributes, a read-only mapping in key order. A solid's attributes go
        with it through every verb (a verb's result takes its first operand's) and are written
        to STEP files as user-defined attributes."""
        if self._attributes is None:
            lib, h = _lib(), self._h()
            n = lib.cadaclysm_blacksmith_attribute_count(h)
            if n == 0 and _text(lib.cadaclysm_blacksmith_last_error()):
                _fail("attribute_count")
            self._attributes = _attribute_map(n, lib.cadaclysm_blacksmith_attribute_key_at, lib.cadaclysm_blacksmith_attribute_value_at, h)
        return self._attributes

    def attribute(self, key: str) -> "str | None":
        """Attribute `key`, None where this solid has none."""
        raw = _lib().cadaclysm_blacksmith_attribute(self._h(), _key(key, "attribute"))
        if raw is None:
            if _text(_lib().cadaclysm_blacksmith_last_error()):
                _fail("attribute")
            return None
        return raw.decode("utf-8")

    def with_attribute(self, key: str, value: str) -> "Solid":
        """This solid with attribute `key` set to `value`, over any it had: a new solid, tracked
        if this one was not. Keys and values are text (no NUL); an empty key is refused."""
        return Solid(_lib().cadaclysm_blacksmith_with_attribute(self._h(), _key(key, "with_attribute"), _value(value, "with_attribute")))

    def with_attributes(self, **attributes: str) -> "Solid":
        """This solid with every attribute given set, in key order."""
        out = self
        for key in sorted(attributes):
            out = out.with_attribute(key, attributes[key])
        return out

    def without_attribute(self, key: str) -> "Solid":
        """This solid without attribute `key`: a new solid, equal to this one where it had none."""
        return Solid(_lib().cadaclysm_blacksmith_without_attribute(self._h(), _key(key, "without_attribute")))

    def face_attributes(self, face: int) -> "_abc.Mapping[str, str]":
        """Face `face`'s attributes, a read-only mapping in key order. A face's attributes
        follow its id: kept through a verb, and copied to every face that names it as an origin
        (each piece of a split face has its parent's). They stay in memory: no file carries
        them. Raises `BuildError` for a face the solid does not have."""
        lib, h = _lib(), self._h()
        n = lib.cadaclysm_blacksmith_face_attribute_count(h, face)
        if n == NONE:
            _fail("face_attribute_count")
        return _attribute_map(n, lib.cadaclysm_blacksmith_face_attribute_key_at, lib.cadaclysm_blacksmith_face_attribute_value_at, h, face)

    def face_attribute(self, face: int, key: str) -> "str | None":
        """Face `face`'s attribute `key`, None where it has none. Raises `BuildError` for a
        face the solid does not have."""
        raw = _lib().cadaclysm_blacksmith_face_attribute(self._h(), face, _key(key, "face_attribute"))
        if raw is None:
            if _text(_lib().cadaclysm_blacksmith_last_error()):
                _fail("face_attribute")
            return None
        return raw.decode("utf-8")

    def with_face_attribute(self, face: int, key: str, value: str) -> "Solid":
        """This solid with face `face`'s attribute `key` set to `value`: a new solid, tracked if
        this one was not. Refused as `with_attribute`, and for a face the solid does not have."""
        what = "with_face_attribute"
        return Solid(_lib().cadaclysm_blacksmith_with_face_attribute(self._h(), face, _key(key, what), _value(value, what)))

    def with_face_attributes(self, face: int, **attributes: str) -> "Solid":
        """This solid with every attribute given set on face `face`, in key order."""
        out = self
        for key in sorted(attributes):
            out = out.with_face_attribute(face, key, attributes[key])
        return out

    def without_face_attribute(self, face: int, key: str) -> "Solid":
        """This solid without face `face`'s attribute `key`: a new solid, equal to this one where
        the face had none."""
        return Solid(_lib().cadaclysm_blacksmith_without_face_attribute(self._h(), face, _key(key, "without_face_attribute")))

    # -- colour
    def coloured(self, colour: Colour, face: int | None = None) -> "Solid":
        """This solid coloured -- `colour` is "#rgb", "#rrggbb", a CSS colour
        name or (r, g, b) in 0..1 -- or with `face` (an index, as `select_face` returns) just
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

    def edges_coloured(self, colour: Colour, edges: Iterable[Edge | int] | None = None) -> "Solid":
        """This solid with its edges coloured -- `colour` is "#rgb", "#rrggbb", a CSS
        colour name or (r, g, b) in 0..1 -- every edge, or with `edges` (`Edge`
        objects or their indices, as `fillet` takes them) just those, whose colour
        then wins over the all-edges one. An empty list colours no edge. A rigid
        move keeps every edge colour; a boolean, fillet, chamfer or shell gives each
        edge the colour of the input edge it lies on, and a new edge (a cut's rim, a
        round's edges) the all-edges colour."""
        r, g, b = _rgb(colour)
        if edges is None:
            return Solid(_lib().cadaclysm_blacksmith_edges_coloured(self._h(), None, 0, r, g, b))
        which = _indices(edges, "edges_coloured", "edges", edges=True)
        arr = (c_uint32 * len(which))(*which)
        return Solid(_lib().cadaclysm_blacksmith_edges_coloured(self._h(), arr, len(which), r, g, b))

    def edge_colour(self, edge: Edge | int) -> "tuple[float, float, float] | None":
        """Edge `edge`'s colour as drawn -- its own, else the solid's edge colour -- or None."""
        index = edge.index if isinstance(edge, Edge) else operator.index(edge)
        out = (c_double * 3)()
        if _lib().cadaclysm_blacksmith_edge_colour(self._h(), index, out):
            return tuple(out)
        if _text(_lib().cadaclysm_blacksmith_last_error()):
            _fail("edge_colour")
        return None

    def edge_polyline_colours(self, tolerance: "float | None" = 0.05) -> "list[tuple[float, float, float] | None]":
        """A colour per polyline of `edge_polylines(tolerance)`, as drawn: (r, g, b),
        or None for a polyline on no coloured edge; an empty list where the solid has
        no edge paint at all. Copied out, as every solid array is."""
        c = _lib().cadaclysm_blacksmith_edge_polyline_colours(self._h(), _tolerance(tolerance))
        if not c.rgb:
            if _text(_lib().cadaclysm_blacksmith_last_error()):
                _fail("edge_polyline_colours")
            return []
        values = [float(c.rgb[i]) for i in range(3 * c.count)]
        return [None if values[3 * i] < 0 else (values[3 * i], values[3 * i + 1], values[3 * i + 2]) for i in range(c.count)]

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
        curve = _Curve()
        for i in range(n):
            if not _lib().cadaclysm_blacksmith_edge(h, i, ctypes.byref(raw)):
                _fail("edge")
            faces = tuple(raw.faces[j] for j in range(raw.face_count))
            flat = [raw.segments[j] for j in range(6 * raw.segment_count)]
            segments = tuple((tuple(flat[k:k + 3]), tuple(flat[k + 3:k + 6])) for k in range(0, len(flat), 6))
            out.append(Edge(i, _text(raw.kind), faces, segments, self._edge_curve(h, i, curve)))
        return out

    @staticmethod
    def _edge_curve(h, i, raw) -> "Curve | None":
        """Edge `i`'s exact curve copied out, or `None` for an edge with none (the
        library's "has no exact curve"); any other refusal is raised."""
        if _lib().cadaclysm_blacksmith_edge_curve(h, i, ctypes.byref(raw)):
            return _curve_of(raw)
        if "has no exact curve" in _text(_lib().cadaclysm_blacksmith_last_error()):
            return None
        _fail("edge_curve")

    def fillet(self, edges: Iterable[Edge | int], radius: "float | Sequence[float]", tolerance: "float | None" = 1e-6,
               progress: Progress = None, radius_end: "float | None" = None) -> "Solid":
        """`edges`: `Edge` objects or their indices. A spline edge -- the crease between two
        faces on NURBS surfaces, as between a fender patch and a door patch -- is rounded by a
        ball rolled along it, in a call of its own (not with straight or circular edges);
        `tolerance` is then the fillet surface's fit, floored at a millionth of the body. Its ends
        lie on the shell's free edges, or at a corner where three or more creases meet, every one
        of them picked in the same call: the corner between their fillets is blended. `radius`
        a list (spline edges only) gives each edge its own, in the order of `edges`. `radius_end`
        (spline edges only) runs the radius linearly from `radius` to it in arc length along the
        edge, `radius` at the end where the edge's curve starts."""
        which = _indices(edges, "fillet", "edges", edges=True)
        arr = (c_uint32 * len(which))(*which)
        if not isinstance(radius, numbers.Real):
            radii = [float(r) for r in radius]
            if len(radii) != len(which):
                raise ValueError(f"fillet: {len(radii)} radii for {len(which)} edges")
            if radius_end is not None:
                raise ValueError("fillet: radius_end runs one radius; with a radius for each edge leave it out")
            _native("Solid.fillet(radius=[...])")
            rs = (c_double * len(radii))(*radii)
            return Solid(_lib().cadaclysm_blacksmith_fillet_each(self._h(), arr, rs, len(which), _tolerance(tolerance)))
        if radius_end is not None and radius_end != radius:
            return Solid(_lib().cadaclysm_blacksmith_fillet_varying(self._h(), arr, len(which), radius, radius_end, _tolerance(tolerance)))
        cb, _keep = _progress(progress)
        return Solid(_lib().cadaclysm_blacksmith_fillet(self._h(), arr, len(which), radius, _tolerance(tolerance), cb, None))

    def fillet_law(self, edges: Iterable[Edge | int], law: "Sequence[tuple[float, float]]", tolerance: "float | None" = 1e-6) -> "Solid":
        """A chain of spline edges rounded with the radius following a law along it: `law` is the
        radius at stations along the chain, each `(share, radius)` -- the share of the chain's arc
        length from its start, 0 to 1 -- run through smoothly by a monotone cubic, so the radius
        never swings past its stations, and held flat before the first station and after the last.
        A shoulder fillet growing from 4 at one end to 12 at the other is `[(0, 4), (1, 12)]`.
        `edges` (`Edge` objects or indices) must run end to end into one open chain, each running
        on tangent into the next; the chain runs the way the first edge's curve does. Where the
        faces either side change from one edge to the next they must meet smooth along a seam
        through the vertex between. One edge is a chain of one. `tolerance` is the fillet
        surfaces' fit, floored at a millionth of the body."""
        which = _indices(edges, "fillet_law", "edges", edges=True)
        stations = [(float(f), float(r)) for f, r in law]
        arr = (c_uint32 * len(which))(*which)
        shares = (c_double * len(stations))(*[f for f, _ in stations])
        radii = (c_double * len(stations))(*[r for _, r in stations])
        return Solid(_lib().cadaclysm_blacksmith_fillet_law(self._h(), arr, len(which), shares, radii, len(stations), _tolerance(tolerance)))

    def chamfer(self, edges: Iterable[Edge | int], distance: float, tolerance: "float | None" = 1e-6) -> "Solid":
        """`fillet` with a flat bevel: each edge cut back `distance` along both
        its faces. `edges`: `Edge` objects or their indices."""
        which = _indices(edges, "chamfer", "edges", edges=True)
        arr = (c_uint32 * len(which))(*which)
        return Solid(_lib().cadaclysm_blacksmith_chamfer(self._h(), arr, len(which), distance, _tolerance(tolerance)))

    def push_pull(self, face: int | Iterable[int], distance: float, tolerance: "float | None" = 0.05,
                  progress: Progress = None) -> "Solid":
        """Face `face` pushed out by `distance` along its outward normal (pulled in,
        negative) as a face extrude does it: the prism over it joined on
        (cut out), and the flush faces merged -- a box's top raised is one taller box
        of six faces, not a box and a prism with every side wall split at the seam.
        A face on a cylinder, a cone, a sphere or a torus moves out along its normal
        instead, the surface a step out -- a boss fatter, a bore or a countersink
        narrower, a dome fuller -- with the flat faces beside it carried along; any
        other curved face is refused. `tolerance` and `progress` as `join`'s.

        `face` may be a list of faces, pushed together as a press-pull on a
        selection: each by its own rule, one after another, each found again after
        the pushes before it renumbered the faces -- a box's top and a side pushed 5
        is the box 5 taller and 5 wider. A face on the same curved surface as one
        before it, and joined to it, moved with that one and is not pushed twice."""
        cb, _keep = _progress(progress)
        # One face is an index on its own (a numpy integer too); anything else is the list form.
        if isinstance(face, numbers.Integral) and not isinstance(face, bool):
            k = operator.index(face)
            if not 0 <= k <= 0xFFFFFFFF:
                raise ValueError(f"push_pull: face must be a face index or a list of indices, not {k}")
            return Solid(_lib().cadaclysm_blacksmith_push_pull(self._h(), k, distance, _tolerance(tolerance), cb, None))
        if face is None or isinstance(face, (bool, str, bytes, Edge)) or isinstance(face, numbers.Number):
            thing = "an Edge" if isinstance(face, Edge) else repr(face)
            raise TypeError(f"push_pull: face must be a face index or a list of indices, not {thing}")
        which = _indices(face, "push_pull", "face")
        arr = (c_uint32 * len(which))(*which)
        return Solid(_lib().cadaclysm_blacksmith_push_pull_faces(self._h(), arr, len(which), distance, _tolerance(tolerance), cb, None))

    def split(self, tool: "Solid", tolerance: "float | None" = 0.05, progress: Progress = None) -> "list[Solid]":
        """This solid split by `tool` into bodies: a
        closed `tool` gives the parts outside it, then the parts inside; a flat
        sheet (a `face`) splits by the whole plane it lies on. Each connected
        part is a body of its own, so a U cut across both arms is three. The
        new faces are pieces of the tool's; colours carry over. On a tracked solid each
        body's faces name this solid as operand 0 and the tool as 1, as the split made
        them (`face_origins`, `history`)."""
        cb, _keep = _progress(progress)
        return Solid(_lib().cadaclysm_blacksmith_split(self._h(), tool._h(), _tolerance(tolerance), cb, None)).lumps()

    def split_by_plane(self, plane: FrameLike, tolerance: "float | None" = 0.05, progress: Progress = None) -> "list[Solid]":
        """This solid split by the plane through `plane`'s origin, square to its
        z: the bodies in front of it (on z's side) first, then those behind. On a tracked
        solid each body's faces name this solid as operand 0: a face cut in two is a piece
        in each body, one keeping its id; the cut faces are generated."""
        cb, _keep = _progress(progress)
        return Solid(_lib().cadaclysm_blacksmith_split_by_plane(self._h(), _frame(plane), _tolerance(tolerance), cb, None)).lumps()

    def split_by_profile(self, profile: "Profile", frame: FrameLike, tolerance: "float | None" = 0.05, progress: Progress = None) -> "list[Solid]":
        """This solid split by the closed `profile` drawn on `frame`, pushed straight
        through it along the frame's z both ways -- a split by a sketch
        profile: the bodies outside the profile first, then those inside. Where the
        plane lies along z does not matter, only the outline across it."""
        cb, _keep = _progress(progress)
        return Solid(_lib().cadaclysm_blacksmith_split_by_profile(self._h(), profile._handle, _frame(frame), _tolerance(tolerance), cb, None)).lumps()

    def lumps(self) -> "list[Solid]":
        """This solid's connected bodies, each a solid of its own -- faces
        sharing an edge are one body. One body comes back as itself; a boolean
        that leaves two parts, or a split, gives several, in the order of
        their first faces. A body is some of this solid's faces, not a solid made from
        it: each face and edge keeps its id and its origins as this solid has them."""
        h = self._h()
        n = _lib().cadaclysm_blacksmith_lump_count(h)
        if n == 0:
            _fail("lump_count")
        return [Solid(_lib().cadaclysm_blacksmith_lump(h, i)) for i in range(n)]

    def merge(self, other: "Solid", tolerance: "float | None" = 0.05, progress: Progress = None) -> "Solid":
        """This solid and `other` as one body that keeps every piece -- a union that keeps the
        inside pieces: its regions are this solid less `other`, the two together, and `other`
        less this one (those that are not empty), and the walls between them are faces of both.
        The body is non-manifold where a wall meets the outside (edges of three or four faces),
        so the verbs that need a manifold solid -- the booleans, fillet, chamfer, shell, thicken,
        the mass -- refuse it; take its cells with `regions` and `region_solid`.

        Built exactly: both solids closed, every face a plane, cylinder, cone, sphere or torus.
        Walls of the two lying on one another in part are a case it refuses, in words."""
        cb, _keep = _progress(progress)
        return Solid(_lib().cadaclysm_blacksmith_merge(self._h(), other._h(), _tolerance(tolerance), cb, None))

    def regions(self) -> "list[Region]":
        """The regions of space this solid's faces bound, region 0 the infinite one: two for an
        ordinary solid (outside, inside), one per cell for a merge's body, one more per cavity.
        Each lists its `sides` -- a face and `sense` +1 where the region is the side the face's
        normal points to, -1 the other -- and its `shells`, 1 plus one per void inside it."""
        return _regions(_lib().cadaclysm_blacksmith_regions(self._h()))

    def region_solid(self, region: int) -> "Solid":
        """Finite region `region` (an index into `regions()`) as a closed solid of its own: the
        faces bounding it, each turned to point out of it, each keeping its colour. Region 0,
        the infinite one, is refused."""
        return Solid(_lib().cadaclysm_blacksmith_region_solid(self._h(), region))

    def refillet(self, face: int, radius: float, tolerance: "float | None" = 1e-6) -> "Solid":
        """The round `face` belongs to -- a fillet's bands, balls and rim bands joined
        to that face -- made again at `radius`, as a press-pull on a fillet
        face: taken back to the sharp edges it replaced, and those rounded again.
        Rounds of straight edges between planes and of circular rims beside a plane."""
        return Solid(_lib().cadaclysm_blacksmith_refillet(self._h(), face, radius, _tolerance(tolerance)))

    def unfillet(self, face: int) -> "Solid":
        """The round `face` belongs to taken off, the faces beside it sharp again --
        the delete of a fillet face. The same rounds as `refillet`."""
        return Solid(_lib().cadaclysm_blacksmith_unfillet(self._h(), face))

    def rechamfer(self, face: int, distance: float, tolerance: "float | None" = 1e-6) -> "Solid":
        """The chamfer `face` belongs to -- its bevels, flat or round a rim, and the
        corner triangles joined to that face -- cut again at `distance`, as a press-pull on a chamfer face: taken back to the sharp edges it cut, and those
        bevelled again."""
        return Solid(_lib().cadaclysm_blacksmith_rechamfer(self._h(), face, distance, _tolerance(tolerance)))

    def unchamfer(self, face: int) -> "Solid":
        """The chamfer `face` belongs to taken off, the faces beside it sharp again --
        the delete of a chamfer face. The same chamfers as `rechamfer`."""
        return Solid(_lib().cadaclysm_blacksmith_unchamfer(self._h(), face))

    def merge_flush(self) -> "Solid":
        """This solid with its flush faces merged: flat faces on one plane, facing one
        way and meeting, made one face, and the vertices left mid-way along a straight
        edge taken out -- the seams a `join` leaves where two parts are flush."""
        return Solid(_lib().cadaclysm_blacksmith_merge_flush(self._h()))

    def shell(self, thickness: float, open: Iterable[int] = (), tolerance: "float | None" = 1e-6,  # noqa: A002
              progress: Progress = None) -> "Solid":
        """`open`: face indices removed so the hollow is reachable."""
        which = _indices(open, "shell", "open")
        arr = (c_uint32 * len(which))(*which)
        cb, _keep = _progress(progress)
        return Solid(_lib().cadaclysm_blacksmith_shell(self._h(), thickness, arr, len(which), _tolerance(tolerance), cb, None))

    def thicken(self, thickness: float, tolerance: "float | None" = 1e-6, progress: Progress = None) -> "Solid":
        """This sheet made a solid `thickness` thick: its faces,
        their twins moved `thickness` along the faces' normals (against them for a
        negative thickness), and a wall round every open edge. A closed sheet thickens
        to a hollow."""
        cb, _keep = _progress(progress)
        return Solid(_lib().cadaclysm_blacksmith_thicken(self._h(), thickness, _tolerance(tolerance), cb, None))

    def to_scene(self, schema: Schema = None) -> "cadaclysm.Scene":
        """This solid as a reader `Scene`, through STEP text and `cadaclysm.open_memory`
        -- the door to the reader's tree walk and its writers. Needs `cadaclysm.py`
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


class Assembly:
    """A mutable tree of placements: a name, and zero or more solids or other
    assemblies placed in it at a frame. `place` returns the placement's name
    (`name`, or a default -- see below) so a caller can keep it. Unlike
    `Solid`, placing shares rather than copies: placing one assembly under
    another does not snapshot it, so a later `place` on the shared one shows
    up wherever it already sits (see `place`'s own note on cycles). `close()`
    frees this handle; so does leaving a `with` block or the garbage
    collector -- it does **not** free what was placed here if that is still
    reachable from somewhere else (an assembly's `Arc`, shared, per the C
    ABI's own doc)."""

    __slots__ = ("_handle",)

    def __init__(self, name: str):
        self._handle = _checked(_lib().cadaclysm_blacksmith_assembly_new(name.encode("utf-8")), "assembly")

    def __enter__(self) -> "Assembly":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()

    def close(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_assembly_free(h)

    def _h(self):
        if not self._handle:
            raise BuildError("assembly: closed")
        return self._handle

    @property
    def name(self) -> str:
        return _text(_lib().cadaclysm_blacksmith_assembly_name(self._h()))

    def place(self, thing: "Solid | Assembly", frame: FrameLike, name: "str | None" = None) -> str:
        """Place `thing` (a `Solid` or another `Assembly`) at `frame` (twelve
        numbers, right-handed and orthonormal) in this assembly, called `name`
        -- or, with `name` left as `None`, `thing`'s own name (`thing.name` for
        a `Solid`, `"part"` for an unnamed one, or the placed assembly's
        `name`), numbered past any already taken here (`"bolt"`, `"bolt 2"`,
        ...). An explicit `name` already taken here is refused. Placing an
        assembly that is this one, or anywhere above this one in the tree
        already, is refused (`BuildError` naming the cycle), since writing
        that out would never terminate. Returns the placement's name."""
        raw = name.encode("utf-8") if name is not None else None
        if isinstance(thing, Assembly):
            text = _lib().cadaclysm_blacksmith_assembly_place_assembly(self._h(), thing._h(), _frame(frame), raw)
        elif isinstance(thing, Solid):
            text = _lib().cadaclysm_blacksmith_assembly_place_solid(self._h(), thing._h(), _frame(frame), raw)
        else:
            raise BuildError(f"place: a Solid or an Assembly, not {type(thing).__name__}")
        if not text:
            _fail("assembly_place")
        if _WASM:
            return text   # the wasm returns the text itself, nothing to free
        try:
            return ctypes.string_at(text).decode("utf-8")
        finally:
            _lib().cadaclysm_blacksmith_string_free(text)

    def link(self, name: str, placements: Iterable[str]) -> None:
        """Declare a rigid link `name` over placements of this assembly, by their names
        (any iterable of str). Written as an AP242 kinematic link when the assembly is
        written; see spec 2026-09-25-blacksmith-mechanisms-design.md for the rules."""
        names = _names(placements, "link", "placements")
        raw = (c_char_p * len(names))(*[n.encode("utf-8") for n in names])
        if not _lib().cadaclysm_blacksmith_assembly_link(self._h(), name.encode("utf-8"), raw, len(names)):
            _fail("assembly_link")

    def joint(self, name: str, start: str, end: str) -> None:
        """Connect this assembly's links `start` and `end` (kept in that order), as an
        AP242 kinematic joint."""
        if not _lib().cadaclysm_blacksmith_assembly_joint(
            self._h(), name.encode("utf-8"), start.encode("utf-8"), end.encode("utf-8")
        ):
            _fail("assembly_joint")

    def pair(self, joint: str, kind: str, frame: FrameLike, end_frame: FrameLike | None = None,
             ranges: Iterable[Sequence[float | None] | None] | None = None, pitch: float | None = None) -> None:
        """Give joint `joint` its pair: `kind` (a name of the kind table -- `revolute`,
        `prismatic`, `cylindrical`, `screw`, `spherical`, `spherical_with_pin`, `planar`,
        `universal`, `homokinetic`, `fully_constrained` or `unconstrained`), the contact
        frame at rest, an optional `end_frame` (the frame the pair reaches at its rest
        values; `frame` itself, i.e. all-zero rest values, when omitted), `ranges` (a
        sequence, one entry per freedom of `kind`, each `None` or a `(lower, upper)` pair
        with either side `None`; omitted entirely for a kind that allows none), and `pitch`
        (required and non-zero for `screw`, refused for any other kind). Raises
        `BuildError` with the kernel's own text when a rule refuses it; the assembly is
        then unchanged."""
        frame = _frame(frame)  # pyright: ignore[reportAssignmentType]
        end_frame_arg = _frame(end_frame) if end_frame is not None else None
        if ranges is None:
            lower = upper = has_lower = has_upper = None
            freedom_count = 0
        else:
            ranges = list(ranges)
            freedom_count = len(ranges)
            lower = (c_double * freedom_count)(*(0.0 if r is None or r[0] is None else float(r[0]) for r in ranges))
            upper = (c_double * freedom_count)(*(0.0 if r is None or r[1] is None else float(r[1]) for r in ranges))
            has_lower = (c_bool * freedom_count)(*(False if r is None else r[0] is not None for r in ranges))
            has_upper = (c_bool * freedom_count)(*(False if r is None else r[1] is not None for r in ranges))
        pitch_arg = float("nan") if pitch is None else float(pitch)
        if not _lib().cadaclysm_blacksmith_assembly_pair(
            self._h(), joint.encode("utf-8"), kind.encode("utf-8"), frame, end_frame_arg,
            lower, upper, has_lower, has_upper, freedom_count, pitch_arg,
        ):
            _fail("assembly_pair")

    def pair_with(self, joint: str, kind: str, frame: FrameLike, end_frame: FrameLike | None = None,
                  ranges: Iterable[Sequence[float | None] | None] | None = None,
                  params: Iterable[float] = ()) -> None:
        """`pair` with the kind's own numbers in place of the pitch, for the coupled pairs:
        `kind` any name `pair` takes, or `gear` or `rack_and_pinion`; `params` `[pitch]`
        for a screw, `[pinion_radius]` for a rack and pinion, `[radius_first,
        radius_second, ratio]` or those plus `[bevel, helical_angle]` (radians) for a gear
        -- the ratio the second link's rotation over the first's, signed (two meshing
        external gears turn opposite ways, so theirs is negative) -- and none for any
        other kind. `frame`, `end_frame` and `ranges` read as in `pair`. Raises
        `BuildError` with the kernel's own text when a rule refuses it (a wrong number of
        parameters among them); the assembly is then unchanged."""
        frame = _frame(frame)  # pyright: ignore[reportAssignmentType]
        end_frame_arg = _frame(end_frame) if end_frame is not None else None
        if ranges is None:
            lower = upper = has_lower = has_upper = None
            freedom_count = 0
        else:
            ranges = list(ranges)
            freedom_count = len(ranges)
            lower = (c_double * freedom_count)(*(0.0 if r is None or r[0] is None else float(r[0]) for r in ranges))
            upper = (c_double * freedom_count)(*(0.0 if r is None or r[1] is None else float(r[1]) for r in ranges))
            has_lower = (c_bool * freedom_count)(*(False if r is None else r[0] is not None for r in ranges))
            has_upper = (c_bool * freedom_count)(*(False if r is None else r[1] is not None for r in ranges))
        values = [float(p) for p in params]
        raw_params = (c_double * len(values))(*values)
        if not _lib().cadaclysm_blacksmith_assembly_pair_with(
            self._h(), joint.encode("utf-8"), kind.encode("utf-8"), frame, end_frame_arg,
            lower, upper, has_lower, has_upper, freedom_count, raw_params, len(values),
        ):
            _fail("assembly_pair_with")

    def state(self, name: str,
              values: Mapping[str, Sequence[float]] | Iterable[tuple[str, Sequence[float]]]) -> None:
        """Add a named state to this assembly: `values` maps joint names to their values,
        in each joint's pair's freedom order (a mapping, or an iterable of `(joint,
        values)` pairs). Raises `BuildError` with the kernel's own text when a rule
        refuses it; the assembly is then unchanged."""
        rows = list(values.items()) if hasattr(values, "items") else list(values)  # pyright: ignore[reportAttributeAccessIssue]
        joints = [j.encode("utf-8") for j, _ in rows]
        raw_joints = (c_char_p * len(rows))(*joints)
        counts = (c_uint32 * len(rows))(*(len(v) for _, v in rows))
        flat = [float(x) for _, v in rows for x in v]
        raw_values = (c_double * len(flat))(*flat)
        if not _lib().cadaclysm_blacksmith_assembly_state(
            self._h(), name.encode("utf-8"), raw_joints, counts, raw_values, len(rows)
        ):
            _fail("assembly_state")

    def sequence(self, name: str, segments: Iterable[tuple[str, float, str]], seconds: bool = False) -> None:
        """Add a named motion sequence over this assembly's states: `segments` is an
        iterable of `(state_name, t, interpolation)`, the parameters non-decreasing, each
        `interpolation` one of `"undefined"`, `"discontinuous"`, `"synchronous"`,
        `"linear"`. `seconds=True` writes the parameter's unit as the second. Closed or
        open is the last segment's interpolation (closed unless `"discontinuous"`).
        Raises `BuildError` with the kernel's reason, the assembly left as it was."""
        rows = [(str(s), float(t), str(i)) for s, t, i in segments]
        n = len(rows)
        states = (c_char_p * n)(*(s.encode("utf-8") for s, _, _ in rows))
        ts = (c_double * n)(*(t for _, t, _ in rows))
        interpolations = (c_char_p * n)(*(i.encode("utf-8") for _, _, i in rows))
        if not _lib().cadaclysm_blacksmith_assembly_sequence(
            self._h(), name.encode("utf-8"), states, ts, interpolations, n, bool(seconds)
        ):
            _fail("assembly_sequence")

    def base(self, link: str) -> None:
        """Declare this assembly's base link. Raises `BuildError` with the kernel's own
        text when a rule refuses it; the assembly is then unchanged."""
        if not _lib().cadaclysm_blacksmith_assembly_base(self._h(), link.encode("utf-8")):
            _fail("assembly_base")

    def posed(self,
              values: Mapping[JointKey, float | Sequence[float]] | Iterable[tuple[JointKey, float | Sequence[float]]] | None = None,
              state: JointKey | None = None, ground: str | None = None) -> "Assembly":
        """This assembly with its mechanism posed, as a new `Assembly`: `values` maps
        joint keys to their values (a mapping, or an iterable of `(key, values)` pairs)
        -- a key a path of placement names then the joint's name joined by "/" (a "/" or
        "\\" inside a name escaped with "\\"), or a tuple or list of the names, which this
        escapes and joins; a value a number for a one-freedom joint, else a sequence in the
        pair's freedom order (radians, the assembly's units). `state` a state's path,
        applied first and overridden row by row; `ground` one of this assembly's own links
        held fixed. A sub-assembly no key reaches is shared with this one. Raises
        `BuildError` with the kernel's own text; this assembly is unchanged either way."""
        rows = list(values.items()) if hasattr(values, "items") else list(values or ())  # pyright: ignore[reportAttributeAccessIssue, reportOptionalMemberAccess]
        keys = [_joint_path(k) for k, _ in rows]
        lists = [[float(v)] if isinstance(v, numbers.Real) else [float(x) for x in v] for _, v in rows]  # pyright: ignore[reportGeneralTypeIssues]
        flat = [x for row in lists for x in row]
        raw_keys = (c_char_p * len(keys))(*[k.encode("utf-8") for k in keys])
        counts = (c_uint32 * len(lists))(*(len(row) for row in lists))
        raw_values = (c_double * len(flat))(*flat)
        state_raw = _joint_path(state).encode("utf-8") if state is not None else None
        ground_raw = ground.encode("utf-8") if ground is not None else None
        handle = _lib().cadaclysm_blacksmith_assembly_posed(
            self._h(), raw_keys, counts, raw_values, len(rows), state_raw, ground_raw
        )
        if not handle:
            _fail("assembly_posed")
        posed = Assembly.__new__(Assembly)
        posed._handle = handle
        return posed

    def parts(self) -> list[str]:
        """The placement path of every solid under this assembly, at any depth: depth
        first, placements in order, names joined by "/" with a "/" or "\\" inside a name
        escaped with "\\" (as `posed`'s keys). The index `swept_clash`'s rows use."""
        lib = _lib()
        if _WASM:
            # the wasm lists them in one call (a JS string needs no free)
            names = lib.cadaclysm_blacksmith_assembly_parts(self._h())
            if isinstance(names, int):   # the shim's failure value: the call threw
                _fail("assembly_parts")
            return [str(n) for n in names]
        out = []
        for i in range(lib.cadaclysm_blacksmith_assembly_part_count(self._h())):
            raw = lib.cadaclysm_blacksmith_assembly_part_path(self._h(), i)
            if not raw:
                _fail("assembly_part_path")
            try:
                out.append(ctypes.string_at(raw).decode("utf-8"))
            finally:
                lib.cadaclysm_blacksmith_string_free(raw)
        return out

    def swept_clash(self,
                    keyframes: Iterable[Mapping[JointKey, float | Sequence[float]] | Iterable[tuple[JointKey, float | Sequence[float]]]],
                    clearance: float = 0.0, tolerance: "float | None" = 0.05, resolution: float = 1e-3, max_steps: int = 100000,
                    allowed: Iterable[tuple[int, int]] = (), ground: str | None = None,
                    joined: bool = False) -> "list[SweptClash]":
        """Every pair of this assembly's solids (indexed as `parts()` lists them) that
        penetrates, touches or comes within `clearance` of the other anywhere while this
        assembly's own mechanism moves through `keyframes`, as `SweptClash` rows. Each
        keyframe maps joint keys to values as `posed`'s `values` does, and every keyframe
        names the same joints (the first fixes their order); time runs in keyframe units,
        keyframe `k` at time `k`. Between two keyframes each joint value moves linearly and
        each link is posed from those values, so a link swinging about a joint goes round
        its arc, not along its chord. Only this assembly's own joints move: a sub-assembly
        rides the link its placement is in. `ground` one of this assembly's links held fixed
        (`None` for its default); solids in no link stay still. Pairs on two links a joint
        joins are not tested unless `joined`; `allowed` pairs of part indices are never
        tested. `tolerance` meshes the parts; `resolution` and `max_steps` as
        `Collider.swept_clash`. Raises `BuildError` in the kernel's `swept_clash:` words."""
        frames = [list(k.items()) if hasattr(k, "items") else list(k) for k in keyframes]  # pyright: ignore[reportAttributeAccessIssue]
        rows = [[(_joint_path(j), [float(v)] if isinstance(v, numbers.Real) else [float(x) for x in v]) for j, v in frame]  # pyright: ignore[reportGeneralTypeIssues]
                for frame in frames]
        first = rows[0] if rows else []
        keys = [j for j, _ in first]
        counts = [len(v) for _, v in first]
        flat = [x for _, v in first for x in v]
        for k, row in enumerate(rows[1:], start=1):
            # C takes one joint set for every keyframe: a later keyframe naming other joints
            # is refused here, in the kernel's words, before C is called
            named = [j for j, _ in row]
            for j in keys + named:
                if j not in named:
                    raise BuildError(f"swept_clash: joint '{j}' is in keyframe 0 and not in keyframe {k}")
                if j not in keys:
                    raise BuildError(f"swept_clash: joint '{j}' is in keyframe {k} and not in keyframe 0")
            if len(set(named)) != len(named):
                twice = next(j for i, j in enumerate(named) if j in named[:i])
                raise BuildError(f"swept_clash: joint '{twice}' is given twice")
            values = dict(row)
            for j, n in zip(keys, counts):
                if len(values[j]) != n:
                    raise BuildError(f"swept_clash: joint '{j}' has {n} values in keyframe 0 and {len(values[j])} in keyframe {k}")
                flat += values[j]
        pairs = []
        for pair in allowed:
            try:
                a, b = pair
                a, b = operator.index(a), operator.index(b)
                if not (0 <= a <= 0xFFFFFFFF and 0 <= b <= 0xFFFFFFFF):
                    raise ValueError(pair)
                pairs += [a, b]
            except (TypeError, ValueError):
                raise BuildError(f"swept_clash: allowed pair {pair!r} is not two indices") from None
        raw_keys = (c_char_p * len(keys))(*[j.encode("utf-8") for j in keys])
        raw_counts = (c_uint32 * len(counts))(*counts)
        raw_values = (c_double * len(flat))(*flat)
        allowed_arr = (c_uint32 * len(pairs))(*pairs)
        ground_raw = ground.encode("utf-8") if ground is not None else None
        h = _lib().cadaclysm_blacksmith_assembly_swept_clash(
            self._h(), raw_keys, raw_counts, len(keys), raw_values, len(rows), ground_raw, _tolerance(tolerance), clearance,
            resolution, max_steps, allowed_arr, len(pairs) // 2, bool(joined))
        if not h:
            _fail("assembly_swept_clash")
        return _swept_clashes_of(h)

    def step_text(self, schema: Schema = None, unit: Unit = "mm") -> str:
        """This assembly, and everything placed under it, as one STEP file: this
        assembly the root product, each sub-assembly and each distinct part (the
        same solid with the same paint and name) written once, each placement an
        occurrence named as it was placed (`write_step_assembly_text`'s shape,
        built from a tree instead of a flat placement list). `schema` and `unit`
        as `Solid.step_text`. Refused (`BuildError`) if this assembly, or a
        sub-assembly reachable from it, places nothing -- a reader would never
        show it."""
        if unit not in UNITS:
            raise BuildError(f"unit must be one of {sorted(UNITS)}")
        text = _lib().cadaclysm_blacksmith_assembly_step(self._h(), _schema_text(schema), UNITS[unit])
        if not text:
            _fail("assembly_step")
        if _WASM:
            return text   # the wasm returns the text itself, nothing to free
        try:
            return ctypes.string_at(text).decode("utf-8")
        finally:
            _lib().cadaclysm_blacksmith_string_free(text)

    def step(self, path: FilePath, schema: Schema = None, unit: Unit = "mm") -> None:
        """`step_text` written to `path`."""
        _FsPath(path).write_text(self.step_text(schema, unit), encoding="utf-8")

    def rhino3dm_bytes(self, unit: Unit = "mm") -> bytes:
        """This assembly, and everything placed under it, as one Rhino `.3dm`: each
        distinct part (as `step_text` counts them) a block holding its body, each
        sub-assembly a block of references to what it places -- nested assemblies are
        nested blocks -- and this assembly's own placements references at the top of the
        file, on a layer named after it. Each reference is named as its placement was;
        block names are made ones Rhino takes and numbered past any taken, regardless of
        case. `unit` and the warnings as `rhino3dm_bytes`. Refused (`BuildError`) as
        `step_text` is, for an assembly reachable from this one that places nothing."""
        if unit not in UNITS:
            raise BuildError(f"unit must be one of {sorted(UNITS)}")
        length = c_size_t(0)
        raw = _lib().cadaclysm_blacksmith_assembly_3dm_bytes(self._h(), UNITS[unit], ctypes.byref(length))
        return _taken_3dm(raw, length, "assembly_3dm_bytes")

    def write_3dm(self, path: FilePath, unit: Unit = "mm") -> None:
        """`rhino3dm_bytes` written to `path` by the library itself, which names the
        file in its refusal when it cannot."""
        if _WASM:
            _write_3dm_bytes(path, self.rhino3dm_bytes(unit), "assembly_3dm")
            return
        if unit not in UNITS:
            raise BuildError(f"unit must be one of {sorted(UNITS)}")
        if not _lib().cadaclysm_blacksmith_assembly_3dm(self._h(), os.fsencode(str(path)), UNITS[unit]):
            _fail("assembly_3dm")
        _warn_3dm()

    def to_scene(self, schema: Schema = None) -> "cadaclysm.Scene":
        """This assembly as a reader `Scene`, through STEP text and
        `cadaclysm.open_memory` -- `Solid.to_scene`'s own door, over the whole
        tree instead of one solid. Needs `cadaclysm.py` importable and its
        library built."""
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

    def __init__(self, kind: int, v: tuple[float, ...] | None = None, index: int = 0):
        self._kind, self._v, self._index = kind, v, index

    @staticmethod
    def max(axis: Axis) -> "Selector":  # noqa: A003
        return Selector(0, None, axis.value)

    @staticmethod
    def min(axis: Axis) -> "Selector":  # noqa: A003
        return Selector(1, None, axis.value)

    @staticmethod
    def normal(direction: Point3) -> "Selector":
        return Selector(2, tuple(float(v) for v in direction), 0)

    @staticmethod
    def index(i: int) -> "Selector":
        return Selector(3, None, int(i))

    def _raw(self):
        v = (c_double * 3)(*self._v) if self._v is not None else None
        return self._kind, v, self._index


class Spot:
    """Where a hit lands on one side: a profile's `loop_index` (0 the boundary or the
    open chain, then the holes in the order they were added), `segment`, and `t` from
    0 to 1 along it, with `face` NONE -- or a solid's `face` at (`u`, `v`), with
    `loop_index` and `segment` NONE."""
    __slots__ = ("loop_index", "segment", "t", "face", "u", "v")

    loop_index: int
    segment: int
    t: float
    face: int
    u: float
    v: float

    def __init__(self, loop_index: int, segment: int, t: float, face: int, u: float, v: float):
        self.loop_index, self.segment, self.t = loop_index, segment, t
        self.face, self.u, self.v = face, u, v

    def __repr__(self) -> str:
        return (f"Spot(loop_index={self.loop_index}, segment={self.segment}, t={self.t}, "
                f"face={self.face}, u={self.u}, v={self.v})")


class Hit:
    """One place two curves meet, copied out. A point (`run` false): `start` equals
    `end`, and `touch` is true where the curves are tangent rather than crossing. A run
    (`run` true): they coincide from `start` to `end`. `a_start`/`a_end` are where on
    the first curve, `b_start`/`b_end` where on the second, as :class:`Spot` values.
    Where a side ends at a point, `touch` is true if the two continue each other
    smoothly and false at a corner. A point at the join of two segments is reported
    once, on either: as segment k at `t` 1 or as segment k + 1 at `t` 0."""
    __slots__ = ("run", "touch", "start", "end", "a_start", "a_end", "b_start", "b_end")

    run: bool
    touch: bool
    start: tuple[float, float, float]
    end: tuple[float, float, float]
    a_start: Spot
    a_end: Spot
    b_start: Spot
    b_end: Spot

    def __init__(self, run: bool, touch: bool, start: tuple[float, float, float], end: tuple[float, float, float],
                 a_start: Spot, a_end: Spot, b_start: Spot, b_end: Spot):
        self.run, self.touch, self.start, self.end = run, touch, start, end
        self.a_start, self.a_end, self.b_start, self.b_end = a_start, a_end, b_start, b_end

    def __repr__(self) -> str:
        return f"Hit(run={self.run}, touch={self.touch}, start={self.start}, end={self.end})"


def _spot_of(raw):
    return Spot(raw.loop_index, raw.segment, raw.t, raw.face, raw.u, raw.v)


def _hit_of(raw):
    return Hit(bool(raw.run), bool(raw.touch), (raw.start.x, raw.start.y, raw.start.z),
               (raw.end.x, raw.end.y, raw.end.z), _spot_of(raw.a_start), _spot_of(raw.a_end),
               _spot_of(raw.b_start), _spot_of(raw.b_end))


class Curve:
    """One edge's, or one intersection chain's, exact curve as plain data copied out
    (:attr:`Edge.curve`, :attr:`Chain.curve`): `kind` is `"line"`, `"circle"`,
    `"ellipse"` or `"nurbs"`.

    `t0..t1` is the edge's parameter range on its own curve: a line's fraction (0..1
    over `origin -> origin + x`, where `x` is the full `to - from`, NOT unit -- so
    `point(t) = origin + x*t`); a circle's or ellipse's angle in radians about
    `origin` in the `x, y` plane (`point(t) = origin + x*radius*cos(t) + y*radius2*sin(t)`,
    `radius2 = radius` for a circle); a NURBS's knot parameter
    (`knots[degree] <= t0 < t1 <= knots[n]`). Frame vectors `x, y, z` are unit for
    conics; for a line `x` is the direction with length = the line's length and
    `y, z` are zero. Always `t0 < t1`: an edge whose segments run against its curve's
    own parameter reports the same range -- read the direction from :attr:`Edge.segments`,
    not from the range.

    `origin`, `x`, `y`, `z` are 3-tuples (all zero for a NURBS, whose `radius` and
    `radius2` are 0 too). For a conic or a line `degree` is 0 and `knots`, `poles` are
    empty tuples; for a NURBS `knots` is the knot vector, `poles` a tuple of 3-tuples
    (`len(knots) == len(poles) + degree + 1`) and `weights` one per pole, or `None`
    for a non-rational (plain B-spline) curve -- `None` for a conic or a line too."""

    __slots__ = ("kind", "origin", "x", "y", "z", "radius", "radius2", "t0", "t1", "degree",
                 "knots", "poles", "weights")

    kind: str
    origin: tuple[float, float, float]
    x: tuple[float, float, float]
    y: tuple[float, float, float]
    z: tuple[float, float, float]
    radius: float
    radius2: float
    t0: float
    t1: float
    degree: int
    knots: tuple[float, ...]
    poles: tuple[tuple[float, float, float], ...]
    weights: tuple[float, ...] | None

    def __init__(self, kind: str, origin: tuple[float, float, float], x: tuple[float, float, float],
                 y: tuple[float, float, float], z: tuple[float, float, float], radius: float, radius2: float,
                 t0: float, t1: float, degree: int, knots: tuple[float, ...],
                 poles: tuple[tuple[float, float, float], ...], weights: tuple[float, ...] | None):
        self.kind, self.origin, self.x, self.y, self.z = kind, origin, x, y, z
        self.radius, self.radius2, self.t0, self.t1, self.degree = radius, radius2, t0, t1, degree
        self.knots, self.poles, self.weights = knots, poles, weights

    @property
    def value(self) -> "Line | Circle | Arc | Ellipse | None":
        """This curve as a value: a line `Line(origin, origin + x)`; a circle a `Circle` over a
        full turn, else the `Arc` over `t0..t1`; an ellipse its whole `Ellipse` (the range stays
        here: there is no elliptical-arc value); a NURBS None."""
        frame = (*self.origin, *self.x, *self.y, *self.z)
        if self.kind == "line":
            return Line(self.origin, tuple(o + d for o, d in zip(self.origin, self.x)))
        if self.kind == "circle":
            if self.t1 - self.t0 >= 2 * math.pi - 1e-12:
                return Circle(frame, self.radius)
            return Arc(frame, self.radius, (self.t0, self.t1))
        if self.kind == "ellipse":
            return Ellipse(frame, self.radius, self.radius2)
        return None

    def __repr__(self) -> str:
        if self.kind == "nurbs":
            return (f"Curve({self.kind!r}, degree={self.degree}, poles={len(self.poles)}, "
                    f"rational={self.weights is not None}, t0={self.t0}, t1={self.t1})")
        if self.kind == "line":
            return f"Curve({self.kind!r}, origin={self.origin}, x={self.x}, t0={self.t0}, t1={self.t1})"
        return (f"Curve({self.kind!r}, origin={self.origin}, radius={self.radius}, "
                f"radius2={self.radius2}, t0={self.t0}, t1={self.t1})")


def _curve_of(raw):
    p = lambda q: (q.x, q.y, q.z)   # noqa: E731
    knots = tuple(raw.knots[j] for j in range(raw.knot_count))
    flat = [raw.poles[j] for j in range(3 * raw.pole_count)]
    poles = tuple(tuple(flat[k:k + 3]) for k in range(0, len(flat), 3))
    weights = tuple(raw.weights[j] for j in range(raw.pole_count)) if raw.weights else None
    return Curve(_text(raw.kind), p(raw.origin), p(raw.x), p(raw.y), p(raw.z), raw.radius, raw.radius2,
                 raw.t0, raw.t1, raw.degree, knots, poles, weights)


class Edge:
    """One edge of a solid, as plain data: its index (what `fillet` takes), the
    curve kind, the faces meeting on it, its segments' ends, and its exact
    :class:`Curve` (`None` for an edge with no exact curve, kind `"other"`)."""

    __slots__ = ("index", "kind", "faces", "segments", "curve")

    index: int
    kind: str
    faces: tuple[int, ...]
    segments: tuple[tuple[tuple[float, float, float], tuple[float, float, float]], ...]
    curve: Curve | None

    def __init__(self, index: int, kind: str, faces: tuple[int, ...],
                 segments: tuple[tuple[tuple[float, float, float], tuple[float, float, float]], ...],
                 curve: Curve | None = None):
        self.index, self.kind, self.faces, self.segments = index, kind, faces, segments
        self.curve = curve

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

    def __repr__(self) -> str:
        return f"Edge({self.index}, {self.kind!r}, faces={self.faces})"


class JoinReport:
    """What :meth:`Solid.join_sheets` did: `sewn` edges (each two naked edges become one shared
    edge), the widest `worst_gap` between two sewn edges (0 where all met exactly), the naked
    edges -- bordered by one face -- `naked_before` (once the T-junctions are cut) and
    `naked_after`, `refused` groups of naked
    edges that share both ends but were left apart (too far apart, or three or more), faces
    `turned`, and whether the result is `closed`: a solid."""

    __slots__ = ("sewn", "worst_gap", "naked_before", "naked_after", "refused", "turned", "closed")

    sewn: int
    worst_gap: float
    naked_before: int
    naked_after: int
    refused: int
    turned: int
    closed: bool

    def __init__(self, raw: "_JoinReport"):
        self.sewn, self.naked_before, self.naked_after = int(raw.sewn), int(raw.naked_before), int(raw.naked_after)
        self.refused, self.turned = int(raw.refused), int(raw.turned)
        self.worst_gap, self.closed = float(raw.worst_gap), bool(raw.closed)

    def __repr__(self) -> str:
        return (f"JoinReport(sewn={self.sewn}, naked {self.naked_before} -> {self.naked_after}, refused={self.refused}, "
                f"turned={self.turned}, worst_gap={self.worst_gap:.3g}, closed={self.closed})")


class Curvature:
    """A curve's bending at a parameter (:meth:`NurbsCurve.curvature`): `kappa` (1 / radius),
    the unit `tangent`, the unit `normal` toward the centre and the `binormal`
    (`tangent x normal`), and the `centre` of the osculating circle -- `None` on a straight
    piece, where `kappa` is 0 and `normal`, `binormal` are zero."""

    __slots__ = ("kappa", "tangent", "normal", "binormal", "centre")

    kappa: float
    tangent: "tuple[float, float, float]"
    normal: "tuple[float, float, float]"
    binormal: "tuple[float, float, float]"
    centre: "tuple[float, float, float] | None"

    def __init__(self, raw: "_Curvature"):
        v = lambda a: (float(a[0]), float(a[1]), float(a[2]))   # noqa: E731
        self.kappa = float(raw.kappa)
        self.tangent, self.normal, self.binormal = v(raw.tangent), v(raw.normal), v(raw.binormal)
        self.centre = v(raw.centre) if raw.has_centre else None

    def __repr__(self) -> str:
        return f"Curvature(kappa={self.kappa:.9g}, centre={self.centre})"


def _xyz(points: "Iterable[Point3]", what: str) -> "tuple[Any, int]":
    """Points as the flat C array of three doubles each, and their count."""
    flat = []
    for p in points:
        p = tuple(float(v) for v in p)
        if len(p) != 3:
            raise ValueError(f"{what}: a point has three coordinates, not {len(p)}")
        flat.extend(p)
    return (c_double * max(len(flat), 1))(*flat), len(flat) // 3


def _vec3(v: "Point3 | None") -> "Any":
    """A direction as three doubles, or None for the C ABI's NULL."""
    if v is None:
        return None
    v = tuple(float(x) for x in v)
    if len(v) != 3:
        raise ValueError(f"a vector has three coordinates, not {len(v)}")
    return (c_double * 3)(*v)


class SymmetryReport:
    """What :meth:`Solid.mirror_join` did: the `seams` (edges on the plane, one face from each
    half), the faces `squared` to the plane and the furthest a control point `moved` doing it;
    the seam's worst `gap`, `angle` between the two sides' normals (radians) and `curvature`
    (the largest difference of their normal curvatures in any one direction); and the `naked`
    edges left on the body."""

    __slots__ = ("seams", "squared", "moved", "gap", "angle", "curvature", "naked")

    seams: int
    squared: int
    moved: float
    gap: float
    angle: float
    curvature: float
    naked: int

    def __init__(self, raw: "Sequence[float]"):
        self.seams, self.squared, self.naked = int(raw[0]), int(raw[1]), int(raw[6])
        self.moved, self.gap, self.angle, self.curvature = float(raw[2]), float(raw[3]), float(raw[4]), float(raw[5])

    def __repr__(self) -> str:
        return (f"SymmetryReport(seams={self.seams}, squared={self.squared}, moved={self.moved:.3g}, gap={self.gap:.3g}, "
                f"angle={self.angle:.3g}, curvature={self.curvature:.3g}, naked={self.naked})")


# The C ABI's codes for the holes, ribs and webs, patterns choices (`CADACLYSM_BLACKSMITH_HOLE_*`, ...).
_HOLE_EXTENTS = {"through": 0, "blind": 1, "to_face": 2, "to_next": 3}
_HOLE_HEADS = {None: 0, "simple": 0, "counterbore": 1, "countersink": 2}
_FEATURE_OPS = {"cut": 0, "join": 1}
_RIB_SIDES = {"both": 0, "front": 1, "back": 2}
_WEB_SIDES = {"both": 0, "left": 1, "right": 2}
_ORIENTS = {"fixed": 0, "path": 1}


def _choice(table: "dict", value: object, what: str, name: str) -> int:
    """`value`'s code in `table`; `ValueError` naming the call and the choices otherwise."""
    try:
        return table[value]
    except (KeyError, TypeError):
        known = ", ".join(repr(k) for k in table if k is not None)
        raise ValueError(f"{what}: {name} {value!r} is not one of {known}") from None


def _hole_points(points, what: str) -> "tuple[Any, int]":
    """One point or several, as `_xyz` takes them."""
    pts = list(points)
    if len(pts) == 3 and all(isinstance(v, numbers.Real) for v in pts):
        pts = [pts]
    return _xyz(pts, what)


def _transforms(transforms) -> "tuple[Any, int]":
    """Transforms (or 16 numbers each) as the flat C array of 16 doubles each, and their count."""
    flat = [v for t in transforms for v in Transform(t)]
    return (c_double * max(len(flat), 1))(*flat), len(flat) // 16


def _skips(skip) -> "Any":
    s = [int(i) for i in skip]
    if any(i < 0 for i in s):
        raise ValueError(f"skip: instance index {min(s)} is negative")
    return (c_uint32 * len(s))(*s)


class PatternReport:
    """What :meth:`Solid.pattern` or :meth:`Solid.pattern_feature` did: the `instances` placed
    (after the skips), the `booleans` run (copies apart from each other share one), and the copies
    of a feature's tool `missed` -- sharing no volume with the body, dropped for a cut and kept as
    a body of their own for a join."""

    __slots__ = ("instances", "booleans", "missed")

    instances: int
    booleans: int
    missed: int

    def __init__(self, raw: "Sequence[float]"):
        self.instances, self.booleans, self.missed = int(raw[0]), int(raw[1]), int(raw[2])

    def __repr__(self) -> str:
        return f"PatternReport(instances={self.instances}, booleans={self.booleans}, missed={self.missed})"


class HoleReport:
    """What :meth:`Solid.hole` did: the `holes` drilled (one a point), per hole the `bottoms` --
    the distance along the axis from the point to where the bore ends, the drill point excluded
    (`depth` for a blind hole; for the others the deepest point of the material it passes, rim
    included) -- and `faces_added`, the result's faces on no surface of the body."""

    __slots__ = ("holes", "bottoms", "faces_added")

    holes: int
    bottoms: "tuple[float, ...]"
    faces_added: int

    def __init__(self, raw: "Sequence[float]", bottoms: "Sequence[float]"):
        self.holes, self.faces_added = int(raw[0]), int(raw[1])
        self.bottoms = tuple(float(b) for b in bottoms)

    def __repr__(self) -> str:
        return f"HoleReport(holes={self.holes}, bottoms={self.bottoms}, faces_added={self.faces_added})"


class Pattern:
    """Placements for :meth:`Solid.pattern` and :meth:`Solid.pattern_feature`: lists of rigid
    :class:`Transform` s, instance 0 the identity (the original). `skip` leaves instances out by
    index (Fusion's suppressed instances), 0 included. Angles are radians."""

    @staticmethod
    def _placements(what: str, call) -> "list[Transform]":
        n = call(None)
        if not n:
            _fail(what)
        out = (c_double * (16 * n))()
        if call(out) != n:
            _fail(what)
        return [Transform(out[16 * i:16 * i + 16]) for i in range(n)]

    @staticmethod
    def rectangular(direction1: Point3, count1: int, spacing1: float, direction2: "Point3 | None" = None, count2: int = 1,
                    spacing2: float = 0.0, symmetric: bool = False, skip: "Iterable[int]" = ()) -> "list[Transform]":
        """`count1` instances `spacing1` apart along `direction1`, times `count2` `spacing2` apart
        along `direction2` (None: one row); row-major, direction 1 fastest. `symmetric` puts
        `count` on each side of the original along each direction (`2 count - 1`, at offsets
        `0, +s, -s, +2s, ...`)."""
        s = _skips(skip)
        d1, d2 = _doubles(direction1, 3, "pattern_rectangular"), _vec3(direction2)
        return Pattern._placements("pattern_rectangular", lambda out: _lib().cadaclysm_blacksmith_pattern_rectangular(
            d1, count1, float(spacing1), d2, count2, float(spacing2), bool(symmetric), s, len(s), out))

    @staticmethod
    def circular(axis_point: Point3, axis_direction: Point3, count: int, angle: float = math.tau, symmetric: bool = False,
                 skip: "Iterable[int]" = ()) -> "list[Transform]":
        """`count` instances about the line through `axis_point` along `axis_direction`: a full
        turn (`angle` 2 pi) spaces them evenly, less spreads them over `angle` with both ends
        occupied. `symmetric` spreads `count` over `angle` on each side (not with a full turn).
        Radians, right-handed about the direction."""
        s = _skips(skip)
        axis = _doubles([*axis_point, *axis_direction], 6, "pattern_circular")
        return Pattern._placements("pattern_circular", lambda out: _lib().cadaclysm_blacksmith_pattern_circular(
            axis, count, float(angle), bool(symmetric), s, len(s), out))

    @staticmethod
    def along(curve: "NurbsCurve", count: int, spacing: "float | None" = None, orient: str = "fixed",
              skip: "Iterable[int]" = ()) -> "list[Transform]":
        """`count` instances along `curve` by arc length from its start, `spacing` apart, or
        spread over its whole length with both ends occupied (`spacing` None). `orient`
        `"fixed"` translates each copy; `"path"` also turns it by the curve's
        rotation-minimising frame from the first instance's."""
        code = _choice(_ORIENTS, orient, "pattern_along", "orient")
        s = _skips(skip)
        return Pattern._placements("pattern_along", lambda out: _lib().cadaclysm_blacksmith_pattern_along(
            curve._handle, count, float("nan") if spacing is None else float(spacing), code, s, len(s), out))


class Continuity:
    """How well two faces meet along their sides (:meth:`Solid.continuity`): the largest `gap`
    between the sides (G0), the largest `angle` between their normals in radians (G1), the largest
    difference of normal `curvature` across the edge (G2), each with where it was found (`gap_at`,
    `angle_at`, `curvature_at`), and how many points were asked (`samples`)."""

    __slots__ = ("gap", "gap_at", "angle", "angle_at", "curvature", "curvature_at", "samples")

    gap: float
    gap_at: "tuple[float, float, float]"
    angle: float
    angle_at: "tuple[float, float, float]"
    curvature: float
    curvature_at: "tuple[float, float, float]"
    samples: int

    def __init__(self, raw: "_Continuity"):
        v = lambda a: (float(a[0]), float(a[1]), float(a[2]))   # noqa: E731
        self.gap, self.gap_at = float(raw.gap), v(raw.gap_at)
        self.angle, self.angle_at = float(raw.angle), v(raw.angle_at)
        self.curvature, self.curvature_at = float(raw.curvature), v(raw.curvature_at)
        self.samples = int(raw.samples)

    def __repr__(self) -> str:
        return f"Continuity(gap={self.gap:.3g}, angle={self.angle:.3g}, curvature={self.curvature:.3g})"


class CurvatureTurns:
    """Where a face's curvatures change sign (:meth:`Solid.curvature_turns`): how many separate
    areas the sample grid finds where the Gaussian curvature is positive and negative
    (`gaussian_positive`, `gaussian_negative`) and the mean curvature (`mean_positive`,
    `mean_negative`, about the face's outward normal), and the points between opposite signs
    (`gaussian_turns`, `mean_turns`: :class:`At`, `tangent` the face's unit normal there,
    `parameter` its `u`). A sample within a millionth of the face's size of flat is neither sign:
    a cylinder's patch reads no Gaussian area at all."""

    __slots__ = ("gaussian_positive", "gaussian_negative", "gaussian_turns", "mean_positive", "mean_negative", "mean_turns", "samples")

    gaussian_positive: int
    gaussian_negative: int
    gaussian_turns: "list[At]"
    mean_positive: int
    mean_negative: int
    mean_turns: "list[At]"
    samples: int

    def __init__(self, raw: "_CurvatureTurns", gaussian_turns: "list[At]", mean_turns: "list[At]"):
        self.gaussian_positive, self.gaussian_negative = int(raw.gaussian_positive), int(raw.gaussian_negative)
        self.mean_positive, self.mean_negative = int(raw.mean_positive), int(raw.mean_negative)
        self.gaussian_turns, self.mean_turns, self.samples = gaussian_turns, mean_turns, int(raw.samples)

    def __repr__(self) -> str:
        return (f"CurvatureTurns(gaussian=+{self.gaussian_positive}/-{self.gaussian_negative} {len(self.gaussian_turns)} turns, "
                f"mean=+{self.mean_positive}/-{self.mean_negative} {len(self.mean_turns)} turns)")


class HighlightKink:
    """The worst kink of the highlight lines crossing an edge (:meth:`Solid.highlight_kink`): the
    `angle` in radians (0 to pi/2) between a line on one face and the same line on the other, the
    point `at` along the edge, and the light that shows it -- a straight tube through
    `light_point` along `light_direction` (unit) -- from `samples` points along the edge."""

    __slots__ = ("angle", "at", "light_point", "light_direction", "samples")

    angle: float
    at: "tuple[float, float, float]"
    light_point: "tuple[float, float, float]"
    light_direction: "tuple[float, float, float]"
    samples: int

    def __init__(self, raw: "_HighlightKink"):
        v = lambda a: (float(a[0]), float(a[1]), float(a[2]))   # noqa: E731
        self.angle, self.at, self.light_point, self.light_direction = float(raw.angle), v(raw.at), v(raw.light_point), v(raw.light_direction)
        self.samples = int(raw.samples)

    def __repr__(self) -> str:
        return f"HighlightKink(angle={self.angle:.3g})"


class KnotContinuity:

    """How smoothly a curve runs through its own knots (:meth:`NurbsCurve.knot_continuity`; a
    closed curve's seam among them): the largest turn of its tangent in radians (`angle`) and
    the largest jump of its curvature vector `kappa * normal` (`curvature`), each with the
    parameter and the point it was found at. A curve with no inner knot reads zero at its start."""

    __slots__ = ("angle", "angle_parameter", "angle_at", "curvature", "curvature_parameter", "curvature_at")

    angle: float
    angle_parameter: float
    angle_at: "tuple[float, float, float]"
    curvature: float
    curvature_parameter: float
    curvature_at: "tuple[float, float, float]"

    def __init__(self, raw: "_KnotContinuity"):
        v = lambda a: (float(a[0]), float(a[1]), float(a[2]))   # noqa: E731
        self.angle, self.angle_parameter, self.angle_at = float(raw.angle), float(raw.angle_parameter), v(raw.angle_at)
        self.curvature, self.curvature_parameter = float(raw.curvature), float(raw.curvature_parameter)
        self.curvature_at = v(raw.curvature_at)

    def __repr__(self) -> str:
        return f"KnotContinuity(angle={self.angle:.3g}, curvature={self.curvature:.3g})"


def _no_inflection(span: "bool | tuple[float | None, float | None] | None") -> "tuple[bool, float, float]":
    """`no_inflection` as the C ABI takes it: the flag and the span's two ends, NaN for an open one."""
    if span is None or span is False:
        return False, 0.0, 0.0
    if span is True:
        return True, float("nan"), float("nan")
    lo, hi = span
    return True, float("nan") if lo is None else float(lo), float("nan") if hi is None else float(hi)


class PatchReport:
    """How well an N-sided patch (:meth:`Solid.n_sided_patch`) meets: `faces` sub-patches, the
    worst `boundary` :class:`Continuity` against the neighbours (the gap over every side, the
    angle over those met at G1 or G2, the curvature jump over those at G2), the worst `internal`
    one across the patch's own spokes, and `corner_angle` (radians), the most a corner of the hole
    leaves no patch able to meet: zero where the neighbours meet each other at G1."""

    faces: int
    boundary: "Continuity"
    internal: "Continuity"
    corner_angle: float

    def __init__(self, raw: "_PatchReport"):
        self.faces = int(raw.faces)
        self.boundary, self.internal = Continuity(raw.boundary), Continuity(raw.internal)
        self.corner_angle = float(raw.corner_angle)

    def __repr__(self) -> str:
        return f"PatchReport(faces={self.faces}, boundary={self.boundary!r}, internal={self.internal!r}, corner_angle={self.corner_angle:.3g})"


_SHEET_SIDES = {"u0": 0, "u1": 1, "v0": 2, "v1": 3}


def _sheet_side(side: str) -> int:
    if side not in _SHEET_SIDES:
        raise ValueError(f"a side is 'u0', 'u1', 'v0' or 'v1', not {side!r}")
    return _SHEET_SIDES[side]


def _curve_array(curves: "Iterable[NurbsCurve]") -> "tuple[Any, int]":
    """Curves as the C array of their handles, and their count; the curves stay alive with the
    caller's list for the call."""
    handles = [c._handle for c in curves]
    return (c_void_p * max(len(handles), 1))(*handles), len(handles)


# `NurbsCurve.tween`'s methods, as `cadaclysm_blacksmith_nurbs_curve_tween` numbers them.
_TWEEN_METHODS = {"plain": 0, "matching": 1, "sampling": 2}


def _native(what: str) -> None:
    """Refuse a native-only call under Pyodide, in words, rather than as a missing export."""
    if isinstance(_lib(), _WasmLibrary):
        raise BuildError(f"{what}: not in the web build yet (native Python only)")


class NurbsCurve:
    """A curve in space -- always a NURBS, so a line, an arc or a conic is an exact rational
    one -- to model with: built through points, read off an edge or a face, projected onto a
    plane or a face, trimmed, extended and blended; asked for its points, derivatives,
    curvature, length and crossings. Immutable; every edit returns a new curve.

    Not :class:`Curve`, which is the plain data an edge's curve is copied out as;
    :meth:`from_edge` turns an edge into one of these.

    A face here is its whole surface: projecting onto, pulling to and crossing a face ignore
    its trims."""

    __slots__ = ("_handle", "fit_error")

    fit_error: "float | None"

    def __init__(self, points: "Iterable[Point3]", degree: int = 3, weights: "Iterable[float] | None" = None,
                 knots: "Iterable[float] | None" = None):
        """The curve with control points `points`, of `degree` (1 to 7), `weights` one per
        point (positive) or None, and the full knot vector `knots`
        (`len(points) + degree + 1` values, non-decreasing) or None for clamped and uniform."""
        self._handle = None
        self.fit_error = None
        xyz, n = _xyz(points, "nurbs_curve_new")
        w = None if weights is None else [float(x) for x in weights]
        k = None if knots is None else [float(x) for x in knots]
        if w is not None and len(w) != n:
            raise BuildError(f"nurbs_curve_new: {len(w)} weights for {n} points; give one per point")
        self._handle = _checked(_lib().cadaclysm_blacksmith_nurbs_curve_new(
            xyz, n, None if w is None else (c_double * max(len(w), 1))(*w), _u32(degree, "nurbs_curve_new: degree"),
            None if k is None else (c_double * max(len(k), 1))(*k), 0 if k is None else len(k)), "nurbs_curve_new")

    @classmethod
    def _of(cls, handle, what: str, fit_error: "float | None" = None) -> "NurbsCurve":
        c = cls.__new__(cls)
        c._handle = None
        c._handle = _checked(handle, what)
        c.fit_error = fit_error
        return c

    def __del__(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_nurbs_curve_free(h)

    # ---- building -----------------------------------------------------------------------

    @classmethod
    def through(cls, points: "Iterable[Point3]", degree: int = 3, closed: bool = False,
                start_tangent: "Point3 | None" = None, end_tangent: "Point3 | None" = None) -> "NurbsCurve":
        """The curve of `degree` (1 to 7) through `points` in order, chord-length
        parametrised. `closed=True` closes it back to the first point, smooth across the seam;
        an open curve may leave along `start_tangent` and arrive along `end_tangent`
        (directions; their length does not matter)."""
        xyz, n = _xyz(points, "nurbs_curve_through")
        return cls._of(_lib().cadaclysm_blacksmith_nurbs_curve_through(
            xyz, n, _u32(degree, "nurbs_curve_through: degree"), bool(closed), _vec3(start_tangent), _vec3(end_tangent)),
            "nurbs_curve_through")

    @classmethod
    def fit(cls, points: "Iterable[Point3]", degree: int = 3, tolerance: "float | None" = 1e-3) -> "NurbsCurve":
        """A curve of `degree` within `tolerance` of every point, through the first and the last
        (least squares); its `fit_error` is the largest distance from a point to it."""
        xyz, n = _xyz(points, "nurbs_curve_fit")
        err = c_double(0.0)
        h = _lib().cadaclysm_blacksmith_nurbs_curve_fit(xyz, n, _u32(degree, "nurbs_curve_fit: degree"), _tolerance(tolerance), ctypes.byref(err))
        return cls._of(h, "nurbs_curve_fit", err.value)

    @classmethod
    def fair(cls, points: "Iterable[Point3]", degree: int = 5, tolerance: "float | None" = 1e-3,
             no_inflection: "bool | tuple[float | None, float | None] | None" = None) -> "NurbsCurve":
        """The smoothest curve of `degree` (3 to 7) within `tolerance` of every point, through the
        first and the last: least squares plus the curvature's derivative squared, weighed as
        heavily as the tolerance allows. Where :meth:`fit` follows the points' noise, this spends
        the tolerance on a calm curvature comb -- a design line traced off a drawing comes back
        fair. `no_inflection=True` keeps the curvature from turning over anywhere; a pair of point
        indices `(i, j)` (fractions between points, None an open end) only between those points.
        Raises `BuildError` where no such curve is within the tolerance. Its `fit_error` is the
        largest distance from a point to it."""
        xyz, n = _xyz(points, "nurbs_curve_fair")
        held, lo, hi = _no_inflection(no_inflection)
        err = c_double(0.0)
        h = _lib().cadaclysm_blacksmith_nurbs_curve_fair(xyz, n, _u32(degree, "nurbs_curve_fair: degree"), _tolerance(tolerance), held, lo, hi,
                                                          ctypes.byref(err))
        return cls._of(h, "nurbs_curve_fair", err.value)

    @classmethod
    def from_edge(cls, solid: "Solid", edge: "Edge | int") -> "NurbsCurve":
        """Edge `edge` of `solid` as an exact NURBS over the edge's own span of its curve,
        running the way the edge runs."""
        e = edge.index if isinstance(edge, Edge) else edge
        return cls._of(_lib().cadaclysm_blacksmith_nurbs_curve_from_edge(solid._handle, _u32(e, "nurbs_curve_from_edge: edge")),
                       "nurbs_curve_from_edge")

    @classmethod
    def isocurve(cls, solid: "Solid", face: int, along_u: bool, at: float) -> "NurbsCurve":
        """The isocurve of face `face` of `solid`'s surface: along `u` at `v = at` when
        `along_u`, else along `v` at `u = at`. NURBS faces only."""
        return cls._of(_lib().cadaclysm_blacksmith_nurbs_curve_from_face_isocurve(
            solid._handle, _u32(face, "nurbs_curve_from_face_isocurve: face"), bool(along_u), float(at)),
            "nurbs_curve_from_face_isocurve")

    @classmethod
    def blend(cls, a: "NurbsCurve", a_end: bool, b: "NurbsCurve", b_end: bool, continuity: int = 2,
              bulge: float = 1.0) -> "NurbsCurve":
        """The curve bridging `a` (at its end when `a_end`, else its start) to `b` (at its end
        when `b_end`, else its start): `continuity` 1 matches position and tangent (a cubic),
        2 also the curvature (a quintic); `bulge` (positive) scales how far the tangents reach."""
        return cls._of(_lib().cadaclysm_blacksmith_nurbs_curve_blend(
            a._handle, bool(a_end), b._handle, bool(b_end), _u32(continuity, "nurbs_curve_blend: continuity"), float(bulge)),
            "nurbs_curve_blend")

    @classmethod
    def joined(cls, curves: "Iterable[NurbsCurve]", tolerance: float = 1e-6) -> "NurbsCurve":
        """`curves` joined end to end into one curve (Rhino's JoinCurves): in the order given,
        each turned where needed so its start meets the previous one's end within `tolerance`
        (the joint placed at the midpoint of the two ends). All are raised to the highest
        degree among them and each runs over `k..k + 1`, joined C0 -- a corner stays a corner;
        a rational curve keeps its points. One curve gives a copy; none, or a gap past
        `tolerance`, raises `BuildError` naming the two curves."""
        arr, n = _curve_array(curves)
        return cls._of(_lib().cadaclysm_blacksmith_nurbs_curve_joined(arr, n, float(tolerance)), "nurbs_curve_joined")

    def tween(self, other: "NurbsCurve", count: int, method: str = "matching", samples: "int | None" = None,
              align: bool = True, tolerance: "float | None" = None) -> "list[NurbsCurve]":
        """`count` curves blending evenly from this curve to `other` (Rhino's CreateTweenCurves
        family), tween `i` at the fraction `(i + 1) / (count + 1)`. `method`:

        - ``"plain"``: control point by control point; the curves must already share one
          structure (degree, control-point count, knots), as Rhino's CreateTweenCurves needs.
        - ``"matching"``: the curves made compatible exactly (degree elevation, knot merging),
          then blended in homogeneous coordinates -- rational curves stay rational.
        - ``"sampling"``: both divided by arc length into `samples` pieces (required here,
          refused otherwise), and a cubic interpolated through the blended samples.

        `align` turns `other`, and moves a closed curve's seam, to line it up with this one
        first (Rhino's calls leave that to the caller). `tolerance` None: the inputs' effective
        tolerance. A count of 0, one curve closed and the other open, plain on curves that are
        not compatible, or too few samples raises `BuildError`."""
        if method not in _TWEEN_METHODS:
            raise ValueError(f"nurbs_curve_tween: method must be one of {', '.join(_TWEEN_METHODS)}, not {method!r}")
        if method == "sampling":
            if samples is None:
                raise ValueError("nurbs_curve_tween: sampling needs samples")
        elif samples is not None:
            raise ValueError(f"nurbs_curve_tween: samples is read only by sampling, not {method}")
        n = _u32(count, "nurbs_curve_tween: count")
        out = (c_void_p * max(n, 1))()
        if not _lib().cadaclysm_blacksmith_nurbs_curve_tween(
                self._handle, other._handle, n, _TWEEN_METHODS[method],
                _u32(samples or 0, "nurbs_curve_tween: samples"), bool(align), _tolerance(tolerance), out):
            _fail("nurbs_curve_tween")
        return [NurbsCurve._of(out[i], "nurbs_curve_tween") for i in range(n)]

    # ---- edits ----------------------------------------------------------------------------

    def projected_to_plane(self, origin: "Point3", normal: "Point3", direction: "Point3 | None" = None) -> "NurbsCurve":
        """This curve projected onto the plane through `origin` with `normal`, along
        `direction` (None: the normal). Exact."""
        return NurbsCurve._of(_lib().cadaclysm_blacksmith_nurbs_curve_projected_to_plane(
            self._handle, _vec3(origin), _vec3(normal), _vec3(direction)), "nurbs_curve_projected_to_plane")

    def projected_to_face(self, solid: "Solid", face: int, direction: "Point3", tolerance: "float | None" = 1e-3) -> "NurbsCurve":
        """This curve projected along `direction` onto face `face` of `solid` (its whole
        surface), fitted within `tolerance`; the result's `fit_error` is the largest distance
        between it and the surface. Raises `BuildError` where a point's ray misses."""
        err = c_double(0.0)
        h = _lib().cadaclysm_blacksmith_nurbs_curve_projected_to_face(
            self._handle, solid._handle, _u32(face, "nurbs_curve_projected_to_face: face"), _vec3(direction),
            _tolerance(tolerance), ctypes.byref(err))
        return NurbsCurve._of(h, "nurbs_curve_projected_to_face", err.value)

    def pulled_to_face(self, solid: "Solid", face: int, tolerance: "float | None" = 1e-3) -> "NurbsCurve":
        """This curve pulled onto face `face` of `solid` (its whole surface): every point to
        its nearest surface point, fitted within `tolerance` (`fit_error` as for the projection)."""
        err = c_double(0.0)
        h = _lib().cadaclysm_blacksmith_nurbs_curve_pulled_to_face(
            self._handle, solid._handle, _u32(face, "nurbs_curve_pulled_to_face: face"), _tolerance(tolerance), ctypes.byref(err))
        return NurbsCurve._of(h, "nurbs_curve_pulled_to_face", err.value)

    def offset_on_sheet(self, solid: "Solid", distance: float, tolerance: "float | None" = 1e-3) -> "NurbsCurve":
        """This curve, lying on the sheet `solid` (any of its faces, within ten times
        `tolerance`), offset `distance` along it: every point walked that far across the sheet,
        square to the curve -- left of its run seen from the outward normal for a positive
        `distance` -- crossing the seams of a joined sheet, onto the surface continued past its
        edge where it leaves it -- and fitted within `tolerance`. The result's `fit_error` is the
        larger of the fit's error and its distance off the sheet. Raises `BuildError` where the
        curve does not lie on the sheet."""
        err = c_double(0.0)
        h = _lib().cadaclysm_blacksmith_nurbs_curve_offset_on_sheet(
            self._handle, solid._handle, float(distance), _tolerance(tolerance), ctypes.byref(err))
        return NurbsCurve._of(h, "nurbs_curve_offset_on_sheet", err.value)

    def reversed(self) -> "NurbsCurve":
        """The same curve run the other way over the same domain."""
        return NurbsCurve._of(_lib().cadaclysm_blacksmith_nurbs_curve_reversed(self._handle), "nurbs_curve_reversed")

    def trimmed(self, t0: float, t1: float) -> "NurbsCurve":
        """The part from `t0` to `t1` (`t0 < t1`, inside the domain), over `t0..t1`."""
        return NurbsCurve._of(_lib().cadaclysm_blacksmith_nurbs_curve_trimmed(self._handle, float(t0), float(t1)),
                              "nurbs_curve_trimmed")

    def extended(self, length: float, at_start: bool = False) -> "NurbsCurve":
        """This curve continued `length` past its end (or start) along its own end polynomial --
        position, tangent and curvature there unchanged, every old parameter its old point."""
        return NurbsCurve._of(_lib().cadaclysm_blacksmith_nurbs_curve_extended(self._handle, bool(at_start), float(length)),
                              "nurbs_curve_extended")

    def elevated(self, by: int = 1) -> "NurbsCurve":
        """The same curve at degree `degree + by` (at most 12)."""
        return NurbsCurve._of(_lib().cadaclysm_blacksmith_nurbs_curve_elevated(self._handle, _u32(by, "nurbs_curve_elevated: by")),
                              "nurbs_curve_elevated")

    def transformed(self, t: "Transform | Sequence[float]") -> "NurbsCurve":
        """This curve through the affine map `t`: its control points mapped, weights and knots
        kept -- exact. A singular map (a projection) is allowed."""
        return NurbsCurve._of(_lib().cadaclysm_blacksmith_nurbs_curve_transformed(self._handle, _matrix(t, "nurbs_curve_transformed")),
                              "nurbs_curve_transformed")

    # ---- reading --------------------------------------------------------------------------

    @property
    def degree(self) -> int:
        return int(_lib().cadaclysm_blacksmith_nurbs_curve_degree(self._handle))

    @property
    def control_points(self) -> "tuple[tuple[float, float, float], ...]":
        n = _lib().cadaclysm_blacksmith_nurbs_curve_control_count(self._handle)
        out = (c_double * (3 * n))()
        _ok(_lib().cadaclysm_blacksmith_nurbs_curve_control_points(self._handle, out), "nurbs_curve_control_points")
        return tuple((out[3 * i], out[3 * i + 1], out[3 * i + 2]) for i in range(n))

    @property
    def weights(self) -> "tuple[float, ...]":
        n = _lib().cadaclysm_blacksmith_nurbs_curve_control_count(self._handle)
        out = (c_double * n)()
        _ok(_lib().cadaclysm_blacksmith_nurbs_curve_weights(self._handle, out), "nurbs_curve_weights")
        return tuple(out)

    @property
    def knots(self) -> "tuple[float, ...]":
        n = _lib().cadaclysm_blacksmith_nurbs_curve_knot_count(self._handle)
        out = (c_double * n)()
        _ok(_lib().cadaclysm_blacksmith_nurbs_curve_knots(self._handle, out), "nurbs_curve_knots")
        return tuple(out)

    @property
    def domain(self) -> "tuple[float, float]":
        out = (c_double * 2)()
        _ok(_lib().cadaclysm_blacksmith_nurbs_curve_domain(self._handle, out), "nurbs_curve_domain")
        return (out[0], out[1])

    @property
    def is_rational(self) -> bool:
        return bool(_lib().cadaclysm_blacksmith_nurbs_curve_is_rational(self._handle))

    @property
    def is_closed(self) -> bool:
        return bool(_lib().cadaclysm_blacksmith_nurbs_curve_is_closed(self._handle))

    def point(self, t: float) -> "tuple[float, float, float]":
        """The point at parameter `t`, inside the domain."""
        out = (c_double * 3)()
        _ok(_lib().cadaclysm_blacksmith_nurbs_curve_point(self._handle, float(t), out), "nurbs_curve_point")
        return (out[0], out[1], out[2])

    def derivatives(self, t: float, order: int = 2) -> "list[tuple[float, float, float]]":
        """The point and its derivatives at `t` up to `order` (at most 8): `[C, C', C'', ...]`."""
        k = _u32(order, "nurbs_curve_derivatives: order")
        out = (c_double * (3 * (min(k, 8) + 1)))()
        _ok(_lib().cadaclysm_blacksmith_nurbs_curve_derivatives(self._handle, float(t), k, out), "nurbs_curve_derivatives")
        return [(out[3 * i], out[3 * i + 1], out[3 * i + 2]) for i in range(k + 1)]

    def curvature(self, t: float) -> "Curvature":
        """The curvature and Frenet frame at `t`."""
        out = _Curvature()
        _ok(_lib().cadaclysm_blacksmith_nurbs_curve_curvature(self._handle, float(t), ctypes.byref(out)), "nurbs_curve_curvature")
        return Curvature(out)

    def length(self, accuracy: float = 0.0) -> "Length":
        """The curve's length, to the relative `accuracy` (0 asks for the default)."""
        out = _Length()
        _ok(_lib().cadaclysm_blacksmith_nurbs_curve_length(self._handle, float(accuracy), ctypes.byref(out)), "nurbs_curve_length")
        return Length(out)

    def point_at_length(self, s: float, accuracy: float = 0.0) -> "At":
        """The point at arc length `s` from the curve's start."""
        out = _At()
        _ok(_lib().cadaclysm_blacksmith_nurbs_curve_point_at_length(self._handle, float(s), float(accuracy), ctypes.byref(out)),
            "nurbs_curve_point_at_length")
        return At(out)

    def closest_point(self, p: Point3, max_distance: "float | None" = None) -> "CurveFoot | None":
        """The nearest point of the curve to `p` over its whole domain, as a `CurveFoot`: its
        parameter `t`, the `point`, and `unique` -- False where another point of the curve is as
        near (a point on a circle's axis) and `point` is a pick among them. Exact. `None` where
        it lies beyond `max_distance` (None, NaN or +inf: no limit, the same answer as with
        none). Raises `BuildError` for a point not finite or a negative `max_distance`."""
        out = (c_double * 5)()
        if max_distance is None:
            if _lib().cadaclysm_blacksmith_nurbs_curve_closest_point(self._handle, _point3(p, "nurbs_curve_closest_point"), out) < 0:
                _fail("nurbs_curve_closest_point")
        else:
            found = _lib().cadaclysm_blacksmith_nurbs_curve_closest_point_within(
                self._handle, _point3(p, "nurbs_curve_closest_point_within"), float(max_distance), out)
            if found < 0:
                _fail("nurbs_curve_closest_point_within")
            if not found:
                return None
        return CurveFoot(out[0], (out[1], out[2], out[3]), out[4] != 0.0)

    def closest_points(self, other: "NurbsCurve", max_distance: "float | None" = None) -> "CurvePair | None":
        """The nearest points of this curve and `other`, as a `CurvePair` (side `a` this curve,
        `distance` 0 where they cross; among equal distances the smallest `t_a`, then `t_b`),
        or `None` where they lie farther apart than `max_distance` (None, NaN or +inf: no
        limit). Exact. Raises `BuildError` for a negative `max_distance`."""
        out = _CurvePair()
        found = _lib().cadaclysm_blacksmith_nurbs_curve_closest_points(self._handle, other._handle, _unlimited(max_distance),
                                                                       ctypes.byref(out))
        if found < 0:
            _fail("nurbs_curve_closest_points")
        return _curve_pair(out) if found else None

    def closest_object(self, items: "Iterable[Solid | NurbsCurve | Projector | TriangleMesh | Point3]",
                       max_distance: "float | None" = None, tolerance: "float | None" = None) -> "NearestObject | None":
        """The item of `items` nearest to this curve, as a `NearestObject` -- `which` its index,
        `answer` its own answer (`Solid.curve_closest_points`', `Projector.curve_closest_points`',
        `closest_points`' or `TriangleMesh.curve_closest_points`') -- or `None` where none lies
        within `max_distance` (None, NaN or +inf: no limit) or `items` is empty. Each item is a
        `Solid`, a `NurbsCurve`, a `Projector`, a `TriangleMesh` (answered exactly) or a point
        (three numbers). Items are asked in order, each with the best
        distance so far as its limit, and once one touches the curve no later one is asked;
        equal distances go to the earlier item. `tolerance` (absolute; None: each solid's
        `effective_tolerance`) sizes each solid's search; a projector keeps its own, and its
        lock is held for the whole curve query (other threads asking it wait). Raises
        `BuildError` for an item of none of those kinds or a point not finite (both naming
        `item <i>`), a negative `max_distance`, a negative or infinite `tolerance`, or a body's
        own refusal."""
        what = "nurbs_curve_closest_object"
        # Every item object stays referenced until the C call returns: only raw handles go in the
        # arrays, and a generator's fresh TriangleMesh (or Solid) would otherwise be freed by its
        # `__del__` mid-loop, leaving C to read a freed handle.
        items = list(items)
        kinds, solids, curves, points, projectors, meshes = [], [], [], [], [], []
        for i, item in enumerate(items):
            if isinstance(item, Solid):
                kinds.append(0)
                solids.append(item._h())
            elif isinstance(item, NurbsCurve):
                kinds.append(1)
                curves.append(item._handle)
            elif isinstance(item, Projector):
                kinds.append(3)
                projectors.append(item._h())
            elif isinstance(item, TriangleMesh):
                kinds.append(4)
                meshes.append(item._h())
            else:
                try:
                    xyz = [] if isinstance(item, (str, bytes)) else [float(v) for v in item]
                except (TypeError, ValueError):
                    xyz = []
                if len(xyz) != 3:
                    raise BuildError(f"{what}: item {i}: not a Solid, a NurbsCurve, a Projector, a TriangleMesh or a point of 3 numbers, "
                                     f"got {item!r}")
                kinds.append(2)
                points.extend(xyz)

        def handles(hs):   # padded to one entry for ctypes; the count says how many are real
            return (c_void_p * max(len(hs), 1))(*hs)

        out = _NearestObject()
        found = _lib().cadaclysm_blacksmith_nurbs_curve_closest_object(
            self._handle, (c_uint8 * max(len(kinds), 1))(*kinds), len(kinds), handles(solids), len(solids),
            handles(curves), len(curves), (c_double * max(len(points), 1))(*points), len(points) // 3,
            handles(projectors), len(projectors), handles(meshes), len(meshes), _unlimited(max_distance), _tolerance(tolerance),
            ctypes.byref(out))
        if found < 0:
            _fail(what)
        return _nearest_object(out) if found else None

    def divide_by_count(self, n: int, accuracy: float = 0.0) -> "list[At]":
        """The curve in `n` pieces of equal arc length: `n + 1` samples, `n` for a closed curve."""
        return _samples("nurbs_curve_divide_by_count", _lib().cadaclysm_blacksmith_nurbs_curve_divide_by_count(
            self._handle, _u32(n, "nurbs_curve_divide_by_count: n"), float(accuracy)))

    def divide_by_length(self, step: float, accuracy: float = 0.0) -> "list[At]":
        """Samples every `step` of arc length from the start; a closed curve never repeats it."""
        return _samples("nurbs_curve_divide_by_length", _lib().cadaclysm_blacksmith_nurbs_curve_divide_by_length(
            self._handle, float(step), float(accuracy)))

    def plane_hits(self, origin: "Point3", normal: "Point3") -> "list[At]":
        """Where the curve crosses the plane through `origin` with `normal`, in parameter order
        (`error` each point's distance from the plane). Raises `BuildError` for a curve lying in
        the plane; a touch that does not cross is not listed."""
        return _samples("nurbs_curve_plane_hits", _lib().cadaclysm_blacksmith_nurbs_curve_plane_hits(
            self._handle, _vec3(origin), _vec3(normal)))

    def face_hits(self, solid: "Solid", face: int, tolerance: "float | None" = 1e-3) -> "list[At]":
        """Where the curve crosses face `face` of `solid` (its whole surface), within
        `tolerance` of it, in parameter order (`error` each point's distance from the surface)."""
        return _samples("nurbs_curve_face_hits", _lib().cadaclysm_blacksmith_nurbs_curve_face_hits(
            self._handle, solid._handle, _u32(face, "nurbs_curve_face_hits: face"), _tolerance(tolerance)))

    def comb(self, n: int = 64, scale: float = 1.0) -> "list[tuple[tuple[float, float, float], tuple[float, float, float]]]":
        """A curvature comb to draw: at `n + 1` even parameters, the curve point and that point
        moved by `-scale * kappa * normal` (out of the bend). Straight stretches give zero teeth."""
        lo, hi = self.domain
        steps = max(int(n), 1)
        out = []
        for i in range(steps + 1):
            t = lo + (hi - lo) * i / steps
            k = self.curvature(t)
            p = self.point(t)
            out.append((p, (p[0] - scale * k.kappa * k.normal[0], p[1] - scale * k.kappa * k.normal[1],
                            p[2] - scale * k.kappa * k.normal[2])))
        return out

    def faired(self, degree: int = 5, tolerance: "float | None" = 1e-3,
               no_inflection: "bool | tuple[float | None, float | None] | None" = None) -> "NurbsCurve":
        """This curve faired: the smoothest curve of `degree` within `tolerance` of it, from its
        start to its end, as :meth:`fair` makes one from points; `no_inflection`'s pair is this
        curve's own parameters here. Its `fit_error` is the largest distance found between them."""
        held, lo, hi = _no_inflection(no_inflection)
        err = c_double(0.0)
        h = _lib().cadaclysm_blacksmith_nurbs_curve_faired(self._handle, _u32(degree, "nurbs_curve_faired: degree"), _tolerance(tolerance), held,
                                                            lo, hi, ctypes.byref(err))
        return NurbsCurve._of(h, "nurbs_curve_faired", err.value)

    def inflections(self) -> "list[At]":
        """Where the curvature turns from one side to the other, in parameter order (`error`
        zero): the comb flipping sides. Empty for a curve that bends one way only -- what a test
        of a design line asks for."""
        return _samples("nurbs_curve_inflections", _lib().cadaclysm_blacksmith_nurbs_curve_inflections(self._handle))

    def knot_continuity(self) -> "KnotContinuity":
        """The largest turn of the tangent and jump of the curvature at the curve's knots."""
        out = _KnotContinuity()
        _ok(_lib().cadaclysm_blacksmith_nurbs_curve_knot_continuity(self._handle, ctypes.byref(out)), "nurbs_curve_knot_continuity")
        return KnotContinuity(out)

    def __repr__(self) -> str:
        lo, hi = self.domain
        return (f"NurbsCurve(degree={self.degree}, controls={len(self.control_points)}, "
                f"rational={self.is_rational}, domain=({lo:.9g}, {hi:.9g}))")


class SolidHits:
    """What :meth:`Solid.hits` found, copied out: `hits` (:class:`Hit`, ordered along
    the profile; `a_start`/`a_end` on the profile, `b_start`/`b_end` on the solid's
    faces: `face` at (`u`, `v`)) and `pieces` (:class:`Piece`, empty for an open body)."""

    __slots__ = ("hits", "pieces")

    hits: list[Hit]
    pieces: list[Piece]

    def __init__(self, hits: list[Hit], pieces: list[Piece]):
        self.hits, self.pieces = hits, pieces

    def __repr__(self) -> str:
        return f"SolidHits(hits={len(self.hits)}, pieces={len(self.pieces)})"


class Piece:
    """One stretch of a profile loop between two cuts (:attr:`SolidHits.pieces`):
    `inside` (by its middle's winding number over the body; a piece lying on the
    surface is inside), `start`/`end` (profile :class:`Spot` values -- a segment join
    reads as the next segment's start `(k + 1, 0)`, an open chain runs from `(0, 0)`
    to `(n - 1, 1)`; a loop no hit cuts is one closed piece) and `profile`, the
    piece's own open chain (what `SweepPath.along(open=True)` sweeps)."""

    __slots__ = ("inside", "start", "end", "profile")

    inside: bool
    start: Spot
    end: Spot
    profile: Profile

    def __init__(self, inside: bool, start: Spot, end: Spot, profile: Profile):
        self.inside, self.start, self.end, self.profile = inside, start, end, profile

    def __repr__(self) -> str:
        return f"Piece(inside={self.inside}, start={self.start}, end={self.end})"


def _intersection_of(h) -> "Intersection":
    """An intersection handle read out into plain data; the caller frees the handle."""
    lib = _lib()
    chains, raw, curve = [], _Chain(), _Curve()
    for i in range(lib.cadaclysm_blacksmith_intersection_chain_count(h)):
        if not lib.cadaclysm_blacksmith_intersection_chain(h, i, ctypes.byref(raw)):
            _fail("intersection_chain")
        exact = None
        if raw.has_curve:
            if not lib.cadaclysm_blacksmith_intersection_curve(h, i, ctypes.byref(curve)):
                _fail("intersection_curve")
            exact = _curve_of(curve)
        chains.append(_chain_of(raw, exact))
    overlaps, raw = [], _Overlap()
    for i in range(lib.cadaclysm_blacksmith_intersection_overlap_count(h)):
        if not lib.cadaclysm_blacksmith_intersection_overlap(h, i, ctypes.byref(raw)):
            _fail("intersection_overlap")
        overlaps.append(_overlap_of(raw))
    return Intersection(chains, overlaps)


class Intersection:
    """What :meth:`Solid.intersect` found, copied out: `chains` (:class:`Chain`, one
    per face pair per branch) and `overlaps` (:class:`Overlap`, one per coincident
    face pair). Both empty where the solids do not meet."""

    __slots__ = ("chains", "overlaps")

    chains: list[Chain]
    overlaps: list[Overlap]

    def __init__(self, chains: list[Chain], overlaps: list[Overlap]):
        self.chains, self.overlaps = chains, overlaps

    def __repr__(self) -> str:
        return f"Intersection(chains={len(self.chains)}, overlaps={len(self.overlaps)})"


class Chain:
    """One branch of one face pair's crossing (:attr:`Intersection.chains`): `points`
    (3-tuples in walk order; a closed chain does not repeat its first point),
    `closed`, `faces` (`(face in a, face in b)`), `tangent` (the surfaces near-tangent
    along it, or the snap unsettled -- the points their best estimate) and `curve`,
    its exact :class:`Curve` over the chain's own `t0..t1`, or `None` where the
    kernel found none. A chain may stop at a face boundary or a closed curve's seam
    and continue as another: join chains by matching ends."""

    __slots__ = ("points", "closed", "faces", "tangent", "curve")

    points: tuple[tuple[float, float, float], ...]
    closed: bool
    faces: tuple[int, int]
    tangent: bool
    curve: Curve | None

    def __init__(self, points: tuple[tuple[float, float, float], ...], closed: bool, faces: tuple[int, int],
                 tangent: bool, curve: Curve | None = None):
        self.points, self.closed, self.faces, self.tangent, self.curve = points, closed, faces, tangent, curve

    def __repr__(self) -> str:
        return (f"Chain(points={len(self.points)}, closed={self.closed}, faces={self.faces}, "
                f"tangent={self.tangent}, curve={self.curve!r})")


class Overlap:
    """A face of `a` and a face of `b` that coincide (:attr:`Intersection.overlaps`):
    `faces` (`(face in a, face in b)`) and `loops`, the shared region's rings as
    tuples of 3-tuples (outer first, holes after; each ring closed without repeating
    its first point) -- empty for a partial overlap of curved faces whose outlines cross."""

    __slots__ = ("faces", "loops")

    faces: tuple[int, int]
    loops: tuple[tuple[tuple[float, float, float], ...], ...]

    def __init__(self, faces: tuple[int, int], loops: tuple[tuple[tuple[float, float, float], ...], ...]):
        self.faces, self.loops = faces, loops

    def __repr__(self) -> str:
        return f"Overlap(faces={self.faces}, loops={len(self.loops)})"


@dataclass(frozen=True)
class Finding:
    """One thing wrong with one argument (:meth:`Solid.check`): `kind` names it,
    `argument` is 0 for the solid checked and 1 for `other`, and `index`, `other` and
    `size` are what the kind gives (`None`, `None` and 0 where it gives none):
    `open` -- the edge (`None` for a trim naming none), its face, its length;
    `face_kind` -- the face; `short_edge` -- the edge, its length; `collapsed_edge` --
    the trim; `sliver_face` -- the face, its width; `tiny_face` -- the face, its area;
    `tiny_body` -- its diagonal; `small_hole` -- the loop, its area or width;
    `loose_edge` -- the edge, how far its sides part; `self_intersection` -- the two
    faces (one face twice for a fold), the crossing's length; `self_overlap` -- the two
    faces."""

    kind: str
    argument: int
    index: "int | None"
    other: "int | None"
    size: float


def _points_of(raw, count):
    flat = [raw[j] for j in range(3 * count)]
    return tuple(tuple(flat[k:k + 3]) for k in range(0, len(flat), 3))


def _chain_of(raw, curve):
    return Chain(_points_of(raw.points, raw.point_count), bool(raw.closed), (raw.face_a, raw.face_b), bool(raw.tangent), curve)


def _overlap_of(raw):
    points = _points_of(raw.points, raw.point_count)
    ends = [raw.loop_offsets[j] for j in range(raw.loop_count)] + [raw.point_count]
    loops = tuple(points[ends[r]:ends[r + 1]] for r in range(raw.loop_count))
    return Overlap((raw.face_a, raw.face_b), loops)


@dataclass(frozen=True)
class FreeEdge:
    """One side a single face bounds (a free edge): its `trim` (the face's side), the
    `edge` it lies on (`None` for a side with no edge), the `face` and free `wire` it is on,
    its nearest `partner` side across the gap (`None` if there is none), how many of its two
    ends it `shared_ends` with that partner, its `length` and the `gap` to the partner
    (`math.inf` without one)."""

    trim: int
    edge: "int | None"
    face: int
    wire: int
    partner: "int | None"
    shared_ends: int
    length: float
    gap: float


@dataclass(frozen=True)
class FreeWire:
    """A chain of free edges end to end: the rows `free_edges[first:first + count]`, whether
    it `closed` on itself, its total `length` and the `widest_gap` to any partner."""

    first: int
    count: int
    closed: bool
    length: float
    widest_gap: float


@dataclass(frozen=True)
class SmallFeature:
    """Something below the tolerance: `kind` is "short_edge", "collapsed_edge",
    "sliver_face", "tiny_face", "tiny_body" or "small_hole"; `index` its edge, face, body
    or loop number; `size` how small."""

    kind: str
    index: int
    size: float


@dataclass(frozen=True)
class Cracks:
    """What a mesh of the body shows (`health(mesh=True)`): whether it is `watertight`, how
    many mesh edges are `open` or `folded`, how many `crossings`, and the brep `edges` it
    cracks along."""

    watertight: bool
    open: int
    folded: int
    crossings: int
    edges: "tuple[int, ...]"


@dataclass(frozen=True)
class HealthReport:
    """What is wrong with a body, as plain data (`health`): the `tolerance` and `rounding`
    it judged at and the body's `extent`; the free edges, their wires, the features below
    the tolerance; the loose edges (`worst_loose` the farthest from any face); what sewing
    would do (`sew_pairs` joined, `sew_refused`, `sew_worst_gap`); and, if asked for with
    `mesh=True`, the mesh's `cracks`."""

    tolerance: float
    rounding: float
    extent: float
    free_edges: "tuple[FreeEdge, ...]"
    wires: "tuple[FreeWire, ...]"
    small: "tuple[SmallFeature, ...]"
    loose_edges: int
    worst_loose: float
    sew_pairs: int
    sew_refused: int
    sew_worst_gap: float
    cracks: "Cracks | None"
    _worst_gap: float = field(default=math.inf, init=False, repr=False)

    @property
    def worst_gap(self) -> float:
        """The widest gap between a free edge and its partner."""
        return self._worst_gap

    def wire_edges(self, wire: int) -> "tuple[FreeEdge, ...]":
        """The free edges of wire number `wire`, in order."""
        w = self.wires[wire]
        return self.free_edges[w.first:w.first + w.count]


_HEALTH_KINDS = ("short_edge", "collapsed_edge", "sliver_face", "tiny_face", "tiny_body", "small_hole")


def _health_report(counts, sizes, free_ids, free_sizes, wire_runs, wire_sizes, small_items, small_sizes,
                   crack_edges) -> HealthReport:
    """The flat rows of the health C ABI (or the wasm object) as a `HealthReport`."""
    none = 0xFFFFFFFF
    n = len(free_ids) // 6
    free = tuple(
        FreeEdge(int(free_ids[6 * i]), None if free_ids[6 * i + 1] == none else int(free_ids[6 * i + 1]),
                 int(free_ids[6 * i + 2]), int(free_ids[6 * i + 3]),
                 None if free_ids[6 * i + 4] == none else int(free_ids[6 * i + 4]), int(free_ids[6 * i + 5]),
                 float(free_sizes[2 * i]), float(free_sizes[2 * i + 1]))
        for i in range(n))
    wires = tuple(FreeWire(int(wire_runs[3 * i]), int(wire_runs[3 * i + 1]), bool(wire_runs[3 * i + 2]),
                           float(wire_sizes[2 * i]), float(wire_sizes[2 * i + 1]))
                  for i in range(len(wire_runs) // 3))
    small = tuple(SmallFeature(_HEALTH_KINDS[int(small_items[2 * i])], int(small_items[2 * i + 1]),
                               float(small_sizes[i])) for i in range(len(small_sizes)))
    cracks = None
    if counts[12] == 1:
        cracks = Cracks(bool(counts[13]), int(counts[14]), int(counts[15]), int(counts[16]),
                        tuple(int(e) for e in crack_edges))
    report = HealthReport(float(sizes[0]), float(sizes[1]), float(sizes[2]), free, wires, small,
                          int(counts[9]), float(sizes[4]), int(counts[10]), int(counts[11]), float(sizes[5]),
                          cracks)
    object.__setattr__(report, "_worst_gap", float(sizes[3]))
    return report


@dataclass(frozen=True)
class HealFix:
    """One small feature `healed` removed: its `kind` (as `SmallFeature.kind`), its `index`
    in the input (the edge, face or loop number `health` gave it), its `size`, and how far
    the vertex it merged `moved`."""

    kind: str
    index: int
    size: float
    moved: float


@dataclass(frozen=True)
class HealRefusal:
    """One small feature `healed` left, and why: `kind` and `index` as in `HealFix`; `why`
    is "would_empty_loop", "closed", "seam", "chain" (a chain wider than the tolerance),
    "neighbours_part" (a sliver's neighbours part), "uneven" (uneven sliver sides),
    "non_manifold", "has_holes", "body_guard" (the fix made the body's health worse),
    "toggled" (its kind switched off) or "unsupported"; `figure` the chain's width or the
    neighbours' gap, else 0."""

    kind: str
    index: int
    why: str
    figure: float


@dataclass(frozen=True)
class HealReport:
    """What `healed` did, as plain data: the `tolerance` it healed at, the furthest any trim
    `moved`, whether the body guard refused fixes (`guarded`), the `fixes` made and the
    features `refused`; and the body's health before and after at that tolerance -- its small
    features, free edges, whether it is closed, and its non-manifold edges."""

    tolerance: float
    moved: float
    guarded: bool
    fixes: "tuple[HealFix, ...]"
    refused: "tuple[HealRefusal, ...]"
    small_before: int
    small_after: int
    free_before: int
    free_after: int
    closed_before: bool
    closed_after: bool
    nonmanifold_before: int
    nonmanifold_after: int


_HEAL_WHYS = ("would_empty_loop", "closed", "seam", "chain", "neighbours_part", "uneven", "non_manifold",
              "has_holes", "body_guard", "toggled", "unsupported")


def _heal_report(counts, sizes, fix_items, fix_sizes, refused_items, refused_sizes) -> HealReport:
    """The flat rows of the heal C ABI (or the wasm object) as a `HealReport`."""
    fixes = tuple(HealFix(_HEALTH_KINDS[int(fix_items[2 * i])], int(fix_items[2 * i + 1]),
                          float(fix_sizes[2 * i]), float(fix_sizes[2 * i + 1]))
                  for i in range(len(fix_items) // 2))
    refused = tuple(HealRefusal(_HEALTH_KINDS[int(refused_items[3 * i])], int(refused_items[3 * i + 1]),
                                _HEAL_WHYS[int(refused_items[3 * i + 2])], float(refused_sizes[i]))
                    for i in range(len(refused_sizes)))
    return HealReport(float(sizes[0]), float(sizes[1]), bool(counts[2]), fixes, refused,
                      int(counts[3]), int(counts[4]), int(counts[5]), int(counts[6]),
                      bool(counts[7]), bool(counts[8]), int(counts[9]), int(counts[10]))


def _heal_flags(edges: bool, faces: bool, holes: bool) -> int:
    """`healed`'s switches as the C ABI's flag bits: 1 edges, 2 faces, 4 holes."""
    return (1 if edges else 0) | (2 if faces else 0) | (4 if holes else 0)


class Manifold:
    """Whether a solid's faces make a manifold, as plain data (`Solid.manifold`):
    its faces, edges and vertices; the edges one face borders (a sheet's rim),
    the edges three or more do, and the vertices whose faces make more than one
    fan (two solids touching at a corner); `is_manifold` where there are none of
    the last two, and `is_closed` where there is no boundary edge either -- it
    encloses a solid."""

    __slots__ = ("faces", "edges", "vertices", "boundary_edges", "non_manifold_edges", "non_manifold_vertices",
                 "is_manifold", "is_closed")

    faces: int
    edges: int
    vertices: int
    boundary_edges: int
    non_manifold_edges: int
    non_manifold_vertices: int
    is_manifold: bool
    is_closed: bool

    def __init__(self, row: Sequence[int]):
        (self.faces, self.edges, self.vertices, self.boundary_edges, self.non_manifold_edges,
         self.non_manifold_vertices) = (int(v) for v in row[:6])
        self.is_manifold, self.is_closed = bool(row[6]), bool(row[7])

    def __repr__(self) -> str:
        return (f"Manifold(faces={self.faces}, edges={self.edges}, vertices={self.vertices}, "
                f"boundary_edges={self.boundary_edges}, non_manifold_edges={self.non_manifold_edges}, "
                f"non_manifold_vertices={self.non_manifold_vertices}, is_manifold={self.is_manifold}, "
                f"is_closed={self.is_closed})")


class ColliderStats:
    """Counts of one `Collider.check` call, as `Collider.stats` returns them (all zero before
    the first call): `considered`, `world_boxes`, `oriented_boxes`, `skipped_share`, `cached`,
    `closed_form`, `meshed`, `refused`, `confirmed` -- see the C ABI's own doc on
    `CadaclysmBlacksmithColliderStats` for what each counts."""

    __slots__ = ("considered", "world_boxes", "oriented_boxes", "skipped_share", "cached",
                 "closed_form", "meshed", "refused", "confirmed")

    considered: int
    world_boxes: int
    oriented_boxes: int
    skipped_share: int
    cached: int
    closed_form: int
    meshed: int
    refused: int
    confirmed: int

    def __init__(self, raw: _ColliderStats):
        for name in self.__slots__:
            setattr(self, name, int(getattr(raw, name)))

    def __repr__(self) -> str:
        return "ColliderStats(" + ", ".join(f"{name}={getattr(self, name)}" for name in self.__slots__) + ")"


def _box_words(box: "Box"):
    """`box` as six contiguous doubles (lo, then hi): bit-compatible with
    `CadaclysmBlacksmithBox`, which is how a `Box` crosses *into* a call -- as a
    frame does, twelve doubles rather than a `Frame` object."""
    return (c_double * 6)(*box.lo, *box.hi)


def _box_of(raw: "_Box") -> "Box":
    return Box(tuple(float(v) for v in raw.lo), tuple(float(v) for v in raw.hi))


class Box:
    """An axis-aligned box: `lo` and `hi`, three-tuples. The broad phase's own shape
    (`Solid.bounds_box`, `Collider`'s own boxes): cheap to move and to test against
    another, before anything is meshed."""

    __slots__ = ("lo", "hi")

    lo: tuple[float, float, float]
    hi: tuple[float, float, float]

    def __init__(self, lo: Point3, hi: Point3):
        self.lo = tuple(float(c) for c in lo)  # pyright: ignore[reportAttributeAccessIssue]
        self.hi = tuple(float(c) for c in hi)  # pyright: ignore[reportAttributeAccessIssue]
        if len(self.lo) != 3 or len(self.hi) != 3:
            raise BuildError("Box: lo and hi must each be three numbers")

    def moved(self, frame: FrameLike) -> "Box":
        """This box moved by `frame` (rigid), boxed again on the world axes -- not
        this box's corners individually moved, which would not in general be a box
        at all: the *bounding* box of the moved corners."""
        out = _Box()
        if not _lib().cadaclysm_blacksmith_box_moved(_box_words(self), _frame(frame), ctypes.byref(out)):
            _fail("box_moved")
        return _box_of(out)

    def overlaps(self, other: "Box") -> bool:
        """Whether this box and `other` share a point (touching counts)."""
        return bool(_lib().cadaclysm_blacksmith_box_overlaps(_box_words(self), _box_words(other)))

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Box) and self.lo == other.lo and self.hi == other.hi

    def __repr__(self) -> str:
        return f"Box(lo={self.lo}, hi={self.hi})"


@dataclasses.dataclass(frozen=True)
class FaceSide:
    """One side of one face (:meth:`Solid.regions`): `face` the face's index in the solid,
    `sense` +1 for the side its normal points to, -1 for the other. A solid's inside is behind
    its faces, at -1."""

    face: int
    sense: int


@dataclasses.dataclass(frozen=True)
class Region:
    """One region of space a solid's faces bound (:meth:`Solid.regions`): its `index` (0 the
    infinite region, whose `finite` is False), the `box` round the faces bounding it, its
    `sides` ascending by face then sense, and its `shells` -- 1, plus one per void inside it.
    :meth:`Solid.region_solid` takes a finite one as a solid of its own."""

    index: int
    finite: bool
    box: Box
    sides: "tuple[FaceSide, ...]"
    shells: int


def boxes_apart(a: Box, frame_a: FrameLike, b: Box, frame_b: FrameLike) -> bool:
    """True only if box `a` at `frame_a` and box `b` at `frame_b` cannot touch -- a
    separating axis among the boxes' face normals and edge-direction crosses;
    touching is not apart. Sharper than moving each box and asking `overlaps`,
    which boxes the *result* on the world axes again and so can call two oriented
    boxes overlapping when they are not (two unit boxes, the second turned 45
    degrees about z and moved 2.3 along x: their world boxes overlap, but the
    boxes themselves do not touch)."""
    apart = c_bool()
    if not _lib().cadaclysm_blacksmith_boxes_apart(_box_words(a), _frame(frame_a), _box_words(b), _frame(frame_b), ctypes.byref(apart)):
        _fail("boxes_apart")
    return bool(apart.value)


class _CollisionsHandle:
    """Keeps one `collider_check` answer alive for as long as any `CollisionHit` of
    it is: each hit holds one of these, and the last one let go frees the handle --
    the same idiom `Intersection` copies out to plain data with, except a
    `CollisionHit` needs the handle itself back for `solid()`."""

    __slots__ = ("_handle",)

    def __init__(self, handle: int):
        self._handle = handle

    def __del__(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_collisions_free(h)


class CollisionHit:
    """One pair `Collider.check` found overlapping (`kind == "overlap"`), or could
    not decide (`kind == "refused"`, `text` says why): `a`, `b` the part indices,
    `depth` the thinnest side of the overlap's world box (0 for a refused pair),
    `positions`/`normals` read-only float64 `(n, 3)` numpy arrays (world xyz
    triples, three per triangle, unwelded) and `indices` a read-only uint32 array
    into them -- all empty for a refused pair, copied out as `Solid.mesh`'s are.

    `solid()` rebuilds the exact overlap now, from the frames `check` found it
    at; this keeps the collisions handle behind every hit of one `check` call
    alive until the last of them is dropped, freeing it only then."""

    __slots__ = ("a", "b", "kind", "depth", "text", "positions", "normals", "indices", "_keeper", "_index")

    a: int
    b: int
    kind: str
    depth: float
    text: str
    positions: numpy.ndarray
    normals: numpy.ndarray
    indices: numpy.ndarray

    def __init__(self, a: int, b: int, kind: str, depth: float, text: str, positions: numpy.ndarray,
                 normals: numpy.ndarray, indices: numpy.ndarray, keeper: _CollisionsHandle, index: int):
        self.a, self.b, self.kind, self.depth, self.text = a, b, kind, depth, text
        self.positions, self.normals, self.indices = positions, normals, indices
        self._keeper, self._index = keeper, index

    def solid(self) -> "Solid":
        """The exact overlap of this pair at the frames it was found at, as a new
        solid. Raises `BuildError` for a refused pair (`kind == "refused"`) or a
        collisions handle already closed some other way."""
        h = self._keeper._handle
        if not h:
            raise BuildError("collision hit: the collisions handle is closed")
        s = _lib().cadaclysm_blacksmith_collisions_solid(h, self._index)
        if not s:
            _fail("collisions_solid")
        return Solid(s)

    def __repr__(self) -> str:
        return f"CollisionHit(a={self.a}, b={self.b}, kind={self.kind!r}, depth={self.depth})"


def _collision_hit_of(raw, keeper, index) -> CollisionHit:
    positions = _copied(raw.positions, (raw.vertex_count, 3), "f8")
    normals = _copied(raw.normals, (raw.vertex_count, 3), "f8")
    indices = _copied(raw.indices, (raw.index_count,), "u4")
    return CollisionHit(int(raw.a), int(raw.b), "overlap" if raw.overlap else "refused", float(raw.depth),
                         _text(raw.text), positions, normals, indices, keeper, index)


class _ClashesHandle:
    """Keeps one clash call's answer alive for as long as any `Clash` of it is: each row
    holds one of these, and the last one let go frees the handle -- as `_CollisionsHandle`
    does for `CollisionHit`, because `solid()` and `intersect()` need the handle itself back."""

    __slots__ = ("_handle",)

    def __init__(self, handle: int):
        self._handle = handle

    def __del__(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_clashes_free(h)


class Clash:
    """One pair a clash call found: `a`, `b` the part indices (for one set or a collider
    `a < b`; for two sets `a` indexes the first and `b` the second), `kind` one of
    `"penetrating"`, `"touching"` (the boundaries within the tolerance of each other),
    `"too_close"` (apart by more than the tolerance but less than the clearance) or
    `"refused"` (the pair could not be decided; `text` says why).

    `distance` is the gap between the two boundaries (0 for a penetrating or refused pair);
    `on_a` and `on_b` are world points -- the closest pair, or for a penetrating pair the
    centre of the overlap's world box (the origin for a refused one). `kind_a`, `index_a`,
    `edge_a` (and `_b`) say what each point lies on exactly as `Closest` does -- `"face"`,
    `"edge"` or `"vertex"`, the kernel's id, and the fillet-table index (`None` for a face, a
    vertex or an edge the table does not hold) -- and for a penetrating or refused pair
    `kind_a`/`kind_b` are `"none"` with `index_*` and `edge_*` `None`. `refined` is True where the distance is measured on the exact
    surfaces. `depth` is the thinnest side of a penetrating pair's overlap box (0 otherwise).

    `solid()` rebuilds a penetrating pair's shared volume now; `intersect()` where the two
    parts cross or coincide (any pair but a refused one). Both use the placement the pair
    was found at. This keeps the clashes handle behind every row of one call alive until the
    last of them is dropped, freeing it only then."""

    __slots__ = ("a", "b", "kind", "distance", "on_a", "on_b", "kind_a", "index_a", "edge_a", "kind_b", "index_b", "edge_b", "refined", "depth",
                 "text", "_keeper", "_index")

    a: int
    b: int
    kind: str
    distance: float
    on_a: tuple[float, float, float]
    on_b: tuple[float, float, float]
    kind_a: str
    index_a: int | None
    edge_a: int | None
    kind_b: str
    index_b: int | None
    edge_b: int | None
    refined: bool
    depth: float
    text: str

    def __init__(self, raw: "_Clash", keeper: _ClashesHandle, index: int):
        self.a, self.b, self.kind, self.distance = int(raw.a), int(raw.b), _text(raw.kind), float(raw.distance)
        self.on_a = tuple(raw.on_a)  # pyright: ignore[reportAttributeAccessIssue]
        self.on_b = tuple(raw.on_b)  # pyright: ignore[reportAttributeAccessIssue]
        self.kind_a, self.kind_b = _text(raw.kind_a), _text(raw.kind_b)
        none_a, none_b = self.kind_a == "none", self.kind_b == "none"
        self.index_a = None if none_a else int(raw.index_a)
        self.edge_a = None if none_a or raw.edge_a == NONE else int(raw.edge_a)
        self.index_b = None if none_b else int(raw.index_b)
        self.edge_b = None if none_b or raw.edge_b == NONE else int(raw.edge_b)
        self.refined, self.depth, self.text = bool(raw.refined), float(raw.depth), _text(raw.text)
        self._keeper, self._index = keeper, index

    def _h(self):
        h = self._keeper._handle
        if not h:
            raise BuildError("clash: the clashes handle is closed")
        return h

    def solid(self) -> "Solid":
        """The exact shared volume of this penetrating pair at the placement it was found at,
        as a new solid. Raises `BuildError` for a pair that is not penetrating."""
        s = _lib().cadaclysm_blacksmith_clashes_solid(self._h(), self._index)
        if not s:
            _fail("clashes_solid")
        return Solid(s)

    def intersect(self) -> "Intersection":
        """Where this pair's two parts cross or coincide at the placement it was found at, as
        `Solid.intersect` reports it (a touching pair's shared face is an `Overlap`). Raises
        `BuildError` for a refused pair."""
        lib = _lib()
        x = lib.cadaclysm_blacksmith_clashes_intersect(self._h(), self._index)
        if not x:
            _fail("clashes_intersect")
        try:
            return _intersection_of(x)
        finally:
            lib.cadaclysm_blacksmith_intersection_free(x)

    def __repr__(self) -> str:
        return f"Clash(a={self.a}, b={self.b}, kind={self.kind!r}, distance={self.distance:.9g})"


def _clashes_of(h) -> "list[Clash]":
    """A clashes handle read out into rows, each keeping the handle alive; frees it if empty."""
    lib = _lib()
    count = lib.cadaclysm_blacksmith_clashes_count(h)
    if count == 0:
        lib.cadaclysm_blacksmith_clashes_free(h)
        return []
    keeper = _ClashesHandle(h)
    rows = []
    raw = _Clash()
    for i in range(count):
        if not lib.cadaclysm_blacksmith_clashes_at(h, i, ctypes.byref(raw)):
            _fail("clashes_at")
        rows.append(Clash(raw, keeper, i))
    return rows


_CONTAINMENT = ("outside", "inside", "on")   # CADACLYSM_BLACKSMITH_OUTSIDE / _INSIDE / _ON


def _point3(point, what: str):
    """A point as the C ABI takes it, three doubles -- refused by `what`'s name if it is not
    three numbers (a NaN is the library's to refuse, and it does)."""
    try:
        values = [float(v) for v in point]
    except (TypeError, ValueError):
        raise BuildError(f"{what}: a point is 3 numbers, got {point!r}") from None
    if len(values) != 3:
        raise BuildError(f"{what}: a point is 3 numbers, got {len(values)}")
    return (c_double * 3)(*values)


def _containment(code: int, what: str) -> str:
    if code >= len(_CONTAINMENT):
        raise BuildError(f"{what}: the library answered {code}, not a containment code")
    return _CONTAINMENT[code]


class Classifier:
    """A closed solid meshed once and asked where point after point lies (`Solid.classifier`):
    `contains(point)` is `"inside"`, `"outside"` or `"on"` within `tolerance` of the boundary.

    It keeps its own reference to the solid's body, so it answers on after that `Solid` is
    closed. Calls on one classifier serialise (a lock inside the library); build one per thread
    to classify in parallel. `close()` frees this handle; so does leaving a `with` block or the
    garbage collector. Raises `BuildError` for an open body or a `tolerance` not positive and
    finite."""

    __slots__ = ("_handle",)

    def __init__(self, solid: Solid, tolerance: "float | None" = 0.05):
        self._handle = _checked(_lib().cadaclysm_blacksmith_classifier_new(solid._h(), _tolerance(tolerance)),
                                "classifier_new")

    def __enter__(self) -> "Classifier":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()

    def close(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_classifier_free(h)

    def _h(self):
        if not self._handle:
            raise BuildError("classifier: closed")
        return self._handle

    def contains(self, point: Point3) -> str:
        """Where `point` is: `"inside"`, `"outside"`, or `"on"` within the tolerance of the
        boundary. Raises `BuildError` for a point not finite."""
        out = c_uint32(NONE)
        if not _lib().cadaclysm_blacksmith_classifier_contains(self._h(), _point3(point, "classifier_contains"),
                                                                ctypes.byref(out)):
            _fail("classifier_contains")
        return _containment(out.value, "classifier_contains")


class Projector:
    """A solid meshed once and asked for its nearest point to point after point
    (`Solid.projector`): `closest_point(p, max_distance)` answers as `Solid.closest_point` does,
    keeping the mesh, its search tree and the per-face trim judges between queries.

    It keeps its own reference to the solid's body, so it answers on after that `Solid` is
    closed. Calls on one projector serialise (a lock inside the library); build one per thread
    to ask in parallel. `close()` frees this handle; so does leaving a `with` block or the
    garbage collector. Raises `BuildError` for a negative or infinite `tolerance` or a body that
    meshes to nothing."""

    __slots__ = ("_handle",)

    def __init__(self, solid: Solid, tolerance: "float | None" = None):
        self._handle = _checked(_lib().cadaclysm_blacksmith_projector_new(solid._h(), _tolerance(tolerance)),
                                "projector_new")

    def __enter__(self) -> "Projector":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()

    def close(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_projector_free(h)

    def _h(self):
        if not self._handle:
            raise BuildError("projector: closed")
        return self._handle

    def closest_point(self, p: Point3, max_distance: "float | None" = None) -> "PointFoot | None":
        """The nearest point of the body's boundary to `p`, as a `PointFoot`, or `None` beyond
        `max_distance` (None, NaN or +inf: no limit) -- `Solid.closest_point`'s answer. Raises
        `BuildError` for a point not finite or a negative `max_distance`."""
        out = _PointFoot()
        found = _lib().cadaclysm_blacksmith_projector_closest_point(
            self._h(), _point3(p, "projector_closest_point"), _unlimited(max_distance), ctypes.byref(out))
        if found < 0:
            _fail("projector_closest_point")
        return _point_foot(out) if found else None

    def curve_closest_points(self, curve: "NurbsCurve", max_distance: "float | None" = None) -> "CurveBodyFoot | None":
        """The nearest points of `curve` and the body's boundary, as a `CurveBodyFoot`, or `None`
        beyond `max_distance` (None, NaN or +inf: no limit) -- `Solid.curve_closest_points`'
        answer, at the projector's tolerance. The projector's lock is held for the whole curve
        query: other threads asking this projector (points or curves) wait for it. Raises
        `BuildError` for a negative `max_distance` or a curve too long for the tolerance."""
        out = _CurveBodyFoot()
        found = _lib().cadaclysm_blacksmith_projector_curve_closest_points(self._h(), curve._handle, _unlimited(max_distance),
                                                                           ctypes.byref(out))
        if found < 0:
            _fail("projector_curve_closest_points")
        return _curve_body_foot(out) if found else None


def _mesh_numbers(values, what: str, name: str) -> "list":
    """A mesh's positions or indices -- a sequence of 3-sequences, one flat sequence, or a numpy
    array of either shape -- as one flat list, refused by `what`'s name (by index) where it is
    neither."""
    if hasattr(values, "tolist") and not isinstance(values, (str, bytes, bytearray)):
        values = values.tolist()   # a numpy array: Python numbers, nested as it was
    if isinstance(values, (str, bytes, bytearray)):
        raise BuildError(f"{what}: the {name}s are not a sequence: {values!r}")
    items = list(values)
    if all(isinstance(v, numbers.Number) and not isinstance(v, bool) for v in items):
        if len(items) % 3:
            raise BuildError(f"{what}: {len(items)} flat {name} numbers are not 3 a {name}")
        return items
    flat = []
    for i, item in enumerate(items):
        parts = None
        if not isinstance(item, (str, bytes, bytearray)):
            try:
                parts = list(item)
            except TypeError:
                parts = None
        if parts is None or len(parts) != 3:
            raise BuildError(f"{what}: {name} {i} is not 3 numbers: {item!r}")
        flat.extend(parts)
    return flat


class TriangleMesh:
    """A triangle mesh and its search tree, built once and immutable: nearest points
    (`closest_point`) and nearest points to a curve (`curve_closest_points`) are answered
    exactly against it -- no tolerance, no `refined` figure.

    `positions` are the vertices, `indices` the triangles (three vertex indices each, any
    winding); either a sequence of 3-sequences, one flat sequence, or a numpy array. Both are
    copied. A zero-area triangle is accepted and answers as its longest edge. `Solid.triangle_mesh`
    gives a solid's own. Nothing in it changes after it is built, so calls from several threads
    at once are safe and do not serialise. `close()` frees this handle; so does leaving a `with`
    block or the garbage collector. Raises `BuildError` for no triangles, an index past the
    vertex count, a coordinate that is not finite, or a shape that is not 3 numbers a vertex
    and 3 indices a triangle."""

    __slots__ = ("_handle",)

    def __init__(self, positions: "Iterable[Point3] | Iterable[float] | numpy.ndarray",
                 indices: "Iterable[tuple[int, int, int]] | Iterable[int] | numpy.ndarray"):
        what = "triangle_mesh_new"
        flat = []
        for n, v in enumerate(_mesh_numbers(positions, what, "vertex")):
            try:
                flat.append(float(v))
            except (TypeError, ValueError):
                raise BuildError(f"{what}: vertex {n // 3} has a coordinate that is not a number: {v!r}") from None
        ids = [_rtree_u32(k, what, f"triangle {n // 3}'s index") for n, k in enumerate(_mesh_numbers(indices, what, "triangle"))]
        # padded to one entry for ctypes; the counts say how many are real (0 triangles: refused by the library)
        handle = _lib().cadaclysm_blacksmith_triangle_mesh_new((c_double * max(len(flat), 1))(*flat), len(flat) // 3,
                                                               (c_uint32 * max(len(ids), 1))(*ids), len(ids) // 3)
        self._handle = _checked(handle, what)

    @classmethod
    def _adopt(cls, handle, what: str) -> "TriangleMesh":
        mesh = cls.__new__(cls)
        mesh._handle = _checked(handle, what)
        return mesh

    def __enter__(self) -> "TriangleMesh":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()

    def close(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_triangle_mesh_free(h)

    def _h(self):
        if not self._handle:
            raise BuildError("triangle_mesh: closed")
        return self._handle

    def __repr__(self) -> str:
        if not self._handle:
            return "TriangleMesh(closed)"
        return f"TriangleMesh({self.vertex_count} vertices, {self.triangle_count} triangles)"

    @property
    def vertex_count(self) -> int:
        """How many vertices the mesh holds."""
        return int(_lib().cadaclysm_blacksmith_triangle_mesh_vertex_count(self._h()))

    @property
    def triangle_count(self) -> int:
        """How many triangles the mesh holds."""
        return int(_lib().cadaclysm_blacksmith_triangle_mesh_triangle_count(self._h()))

    @property
    def bounds(self) -> "tuple[tuple[float, float, float], tuple[float, float, float]]":
        """The box of every vertex as `(min, max)`."""
        out = (c_double * 6)()
        if not _lib().cadaclysm_blacksmith_triangle_mesh_bounds(self._h(), out):
            _fail("triangle_mesh_bounds")
        v = [float(x) for x in out]
        return (v[0], v[1], v[2]), (v[3], v[4], v[5])

    def closest_point(self, p: Point3, max_distance: "float | None" = None) -> "MeshPoint | None":
        """The nearest point of the mesh to `p`, as a `MeshPoint` -- exact, the lower triangle
        where several share the point -- or `None` where it lies beyond `max_distance` (None, NaN
        or +inf: no limit; a point on the mesh is within 0). Raises `BuildError` for a point not
        finite or a negative `max_distance`."""
        what = "triangle_mesh_closest_point"
        out = _MeshPoint()
        found = _lib().cadaclysm_blacksmith_triangle_mesh_closest_point(self._h(), _point3(p, what), _unlimited(max_distance),
                                                                        ctypes.byref(out))
        if found < 0:
            _fail(what)
        return _mesh_point(out) if found else None

    def curve_closest_points(self, curve: "NurbsCurve", max_distance: "float | None" = None) -> "CurveMeshFoot | None":
        """The nearest points of `curve` and the mesh, as a `CurveMeshFoot` -- exact; `crossing`
        True and distance 0 at the earliest crossing in `t`; among equal distances the lower
        triangle, then the lower `t` -- or `None` where the mesh lies farther than `max_distance`
        (None, NaN or +inf: no limit). A mesh has no inside: a curve within a closed mesh answers
        its distance to the triangles. Raises `BuildError` for a curve that is not valid or a
        negative `max_distance`."""
        what = "triangle_mesh_curve_closest_points"
        out = _CurveMeshFoot()
        found = _lib().cadaclysm_blacksmith_triangle_mesh_curve_closest_points(self._h(), curve._handle,
                                                                               _unlimited(max_distance), ctypes.byref(out))
        if found < 0:
            _fail(what)
        return _curve_mesh_foot(out) if found else None


class Collider:
    """Parts meshed once, asked pose after pose which of them interfere: `solids`
    at rest, meshed at `tolerance`; `groups` one group index per solid (`None`:
    each solid its own group -- `check` then takes one frame per solid), `allowed`
    pairs of part indices never tested (designed contacts, by part index, flat:
    `(a0, b0, a1, b1, ...)`). `close()` frees this handle; so does leaving a `with`
    block or the garbage collector."""

    __slots__ = ("_handle",)

    def __init__(self, solids: Iterable[Solid], tolerance: "float | None" = 0.05, groups: Sequence[int] | None = None,
                 allowed: Iterable[int] = ()):
        handles = [s._h() for s in solids]
        if groups is not None and len(groups) != len(handles):
            raise BuildError(f"Collider: groups must have one entry per solid ({len(handles)} solids, {len(groups)} groups)")
        parts = (c_void_p * len(handles))(*handles)
        groups_arr = None if groups is None else (c_uint32 * len(groups))(*[int(g) for g in groups])
        allowed = [int(v) for v in allowed]
        allowed_arr = (c_uint32 * len(allowed))(*allowed)
        h = _lib().cadaclysm_blacksmith_collider_new(parts, len(handles), _tolerance(tolerance), groups_arr, allowed_arr, len(allowed) // 2)
        self._handle = _checked(h, "collider_new")

    def __enter__(self) -> "Collider":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()

    def close(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_collider_free(h)

    def _h(self):
        if not self._handle:
            raise BuildError("collider: closed")
        return self._handle

    @property
    def group_count(self) -> int:
        """How many groups this collider has -- the highest group index past the
        constructor, plus one."""
        return _lib().cadaclysm_blacksmith_collider_group_count(self._h())

    @property
    def stats(self) -> "ColliderStats":
        """Counts of the last `check` call, as a `ColliderStats` (all zero before the first
        one)."""
        out = _ColliderStats()
        if not _lib().cadaclysm_blacksmith_collider_stats(self._h(), ctypes.byref(out)):
            _fail("collider_stats")
        return ColliderStats(out)

    def check(self, frames: Iterable[FrameLike], share: tuple[int, int] | None = None) -> "list[CollisionHit]":
        """The pairs that interfere, or could not be decided, with each group placed
        at its matching frame in `frames` (one `Frame`, or twelve numbers, per
        group, in group order). `share`: `None`, every pair past the box filters is
        decided now; `(k, n)`, only those whose index is `k` modulo `n` (the shares
        of one pose are disjoint and cover it -- split one `check` across `n`
        workers). `(k, 0)` is the same as `None`: the C ABI reads `n` 0 as every
        pair."""
        flat = []
        for f in frames:
            flat.extend(_frame(f))
        frames_arr = (c_double * len(flat))(*flat)
        share_k, share_n = share if share is not None else (0, 0)
        lib = _lib()
        h = lib.cadaclysm_blacksmith_collider_check(self._h(), frames_arr, len(flat) // 12, share_k, share_n)
        if not h:
            _fail("collider_check")
        count = lib.cadaclysm_blacksmith_collisions_count(h)
        if count == 0:
            lib.cadaclysm_blacksmith_collisions_free(h)
            return []
        keeper = _CollisionsHandle(h)
        hits = []
        raw = _CollisionHit()
        for i in range(count):
            if not lib.cadaclysm_blacksmith_collisions_hit(h, i, ctypes.byref(raw)):
                _fail("collisions_hit")
            hits.append(_collision_hit_of(raw, keeper, i))
        return hits

    def clash(self, frames: Iterable[FrameLike], clearance: float = 0.0,
              share: tuple[int, int] | None = None) -> "list[Clash]":
        """Every pair of parts that penetrates, touches or lies within `clearance` of the
        other, as `Clash` rows in pair order, with each group placed at its matching frame in
        `frames` (as for `check`). `clearance` is zero or more, in model units: a pair apart by
        more than the collider's tolerance but less than it is `"too_close"`. `share` as for
        `check`. The collider keeps each part's closest mesh (at a third of its tolerance) for
        its lifetime once a pair needed one. Raises `BuildError` for a negative or non-finite
        `clearance`, the wrong number of frames or a bad `share`."""
        flat = []
        for f in frames:
            flat.extend(_frame(f))
        frames_arr = (c_double * len(flat))(*flat)
        share_k, share_n = share if share is not None else (0, 0)
        h = _lib().cadaclysm_blacksmith_collider_clash(self._h(), frames_arr, len(flat) // 12, clearance, share_k, share_n)
        if not h:
            _fail("collider_clash")
        return _clashes_of(h)

    def swept_clash(self, poses: Iterable[Iterable[FrameLike]], clearance: float = 0.0, resolution: float = 1e-3,
                    max_steps: int = 100000, share: tuple[int, int] | None = None) -> "list[SweptClash]":
        """Every pair of parts that penetrates, touches or comes within `clearance` of the other
        anywhere on the path through `poses` -- not only at the poses -- as `SweptClash` rows in
        pair order. `poses` is two or more poses, each the `frames` `clash` takes (one frame per
        group). Between two poses each group moves rigidly about the centre of its rest box: that
        point on the straight line between its two places, the rotation turning at a steady rate
        the shorter way round. Time runs in pose units, pose `k` at time `k`.

        No moment where the true gap is below `clearance` less the collider's tolerance (for
        clearance 0: no penetration deeper than the tolerance) falls between two steps.
        `resolution` (in (0, 1], a fraction of a segment) is how closely an interval's end is
        found; `max_steps` the pose-wise tests one pair may take -- a pair that needs more is a
        `"refused"` row. `share` as for `check`, over the pairs whose swept boxes meet. The pose
        caches `check` and `clash` keep are neither read nor filled. Raises `BuildError` for
        fewer than two poses, the wrong number of frames in a pose, a bad frame, `clearance`,
        `resolution` or `share`, or `max_steps` 0."""
        frames = [[_frame(f) for f in pose] for pose in poses]
        counts = {len(pose) for pose in frames}
        if len(counts) > 1:
            # C reads every pose at one frame count: say the first pose that is off, in the
            # kernel's words
            groups = self.group_count
            n = next(len(pose) for pose in frames if len(pose) != groups)
            raise BuildError(f"collider_swept_clash: {n} frames for {groups} groups")
        frame_count = counts.pop() if counts else 0
        flat = [v for pose in frames for f in pose for v in f]
        poses_arr = (c_double * len(flat))(*flat)
        share_k, share_n = share if share is not None else (0, 0)
        h = _lib().cadaclysm_blacksmith_collider_swept_clash(self._h(), poses_arr, len(frames), frame_count, clearance,
                                                             resolution, max_steps, share_k, share_n)
        if not h:
            _fail("collider_swept_clash")
        return _swept_clashes_of(h)


def clash(parts: Iterable[Solid], others: Iterable[Solid] | None = None, clearance: float = 0.0,
          tolerance: "float | None" = 0.05, allowed: Iterable[tuple[int, int]] = ()) -> "list[Clash]":
    """Every pair of `parts` -- or, with `others`, every part of `parts` against every part of
    `others` -- that penetrates, touches or lies within `clearance` of the other, as `Clash`
    rows, the solids as they stand. `tolerance` is the meshing tolerance, absolute (default
    0.05). `allowed` pairs of part indices (each exactly two integers) never tested (designed contacts); with `others` a
    pair is (index in `parts`, index in `others`). In a row `a` indexes `parts` and `b` indexes
    `others` (or `parts` again). Raises `BuildError` for a negative or non-finite `clearance`, a
    `tolerance` not positive and finite, an `allowed` index out of range or a part that is not a
    closed solid."""
    parts = list(parts)
    others = None if others is None else list(others)
    first = [s._h() for s in parts]
    second = None if others is None else [s._h() for s in others]
    if second is not None and not second:
        raise BuildError("clash: an empty set")
    pairs = []
    for pair in allowed:
        try:
            a, b = pair
            a, b = operator.index(a), operator.index(b)
            if not (0 <= a <= 0xFFFFFFFF and 0 <= b <= 0xFFFFFFFF):
                raise ValueError(pair)
            pairs += [a, b]
        except (TypeError, ValueError):
            raise BuildError(f"clash: allowed pair {pair!r} is not two indices") from None
    a_arr = (c_void_p * len(first))(*first)
    b_arr = None if second is None else (c_void_p * len(second))(*second)
    allowed_arr = (c_uint32 * len(pairs))(*pairs)
    h = _lib().cadaclysm_blacksmith_clash(a_arr, len(first), b_arr, 0 if second is None else len(second),
                                          _tolerance(tolerance), clearance, allowed_arr, len(pairs) // 2)
    if not h:
        _fail("clash")
    return _clashes_of(h)


class SweptClash:
    """One pair a swept clash call found: `a`, `b` the part indices (for one set or a collider
    `a < b`; for two sets `a` indexes the first and `b` the second). `first_time` is the first
    time the pair came within the clearance, in pose units (pose `k` at time `k`; for a refused
    pair the time it was refused at), and `first` the `Clash` there -- its kind, distance,
    points, features and depth, at the frames the motion places the parts at that time, so
    `first.solid()` and `first.intersect()` rebuild the contact there. `intervals` are the time
    ranges the pair stays in clash, `(start, end)` tuples, ascending and disjoint (none for a
    refused pair)."""

    __slots__ = ("a", "b", "first_time", "first", "intervals")

    a: int
    b: int
    first_time: float
    first: Clash
    intervals: list[tuple[float, float]]

    def __init__(self, a: int, b: int, first_time: float, first: Clash, intervals: list[tuple[float, float]]):
        self.a, self.b, self.first_time, self.first, self.intervals = a, b, first_time, first, intervals

    def __repr__(self) -> str:
        return f"SweptClash(a={self.a}, b={self.b}, first_time={self.first_time:.9g}, kind={self.first.kind!r}, intervals={self.intervals})"


def _swept_clashes_of(h) -> "list[SweptClash]":
    """A swept clashes handle read out into rows and freed; each row's `first` a `Clash` of the
    handle's first rows, which keep their own clashes handle alive."""
    lib = _lib()
    try:
        count = lib.cadaclysm_blacksmith_swept_clashes_count(h)
        if count == 0:
            return []
        f = lib.cadaclysm_blacksmith_swept_clashes_firsts(h)
        if not f:
            _fail("swept_clashes_firsts")
        firsts = _clashes_of(f)
        rows, raw, span = [], _SweptClash(), (c_double * 2)()
        for i in range(count):
            if not lib.cadaclysm_blacksmith_swept_clashes_at(h, i, ctypes.byref(raw)):
                _fail("swept_clashes_at")
            intervals = []
            for k in range(raw.interval_count):
                if not lib.cadaclysm_blacksmith_swept_clashes_interval(h, i, k, span):
                    _fail("swept_clashes_interval")
                intervals.append((float(span[0]), float(span[1])))
            rows.append(SweptClash(int(raw.a), int(raw.b), float(raw.first_time), firsts[i], intervals))
        return rows
    finally:
        lib.cadaclysm_blacksmith_swept_clashes_free(h)


def swept_clash(parts: Iterable[Solid], poses: Iterable[Iterable[FrameLike]], others: Iterable[Solid] | None = None,
                other_poses: Iterable[Iterable[FrameLike]] | None = None, clearance: float = 0.0, tolerance: "float | None" = 0.05,
                resolution: float = 1e-3, max_steps: int = 100000,
                allowed: Iterable[tuple[int, int]] = ()) -> "list[SweptClash]":
    """Every pair of `parts` -- or, with `others`, every part of `parts` against every part of
    `others` -- that penetrates, touches or comes within `clearance` of the other anywhere on a
    path, as `SweptClash` rows. Each part is its own group: pose `k` of `poses` is one frame
    per part of `parts`, and pose `k` of `other_poses` one per part of `others` (the two go
    together, and have as many poses). The motion between poses, the guarantee, `resolution`
    and `max_steps` are `Collider.swept_clash`'s. `tolerance` is the meshing tolerance,
    absolute (default 0.05). `allowed` pairs of part indices never tested; with `others` a pair
    is (index in `parts`, index in `others`). In a row `a` indexes `parts` and `b` indexes
    `others` (or `parts` again). Raises `BuildError` as `Collider.swept_clash` does, and for an
    empty set, a pose with the wrong number of frames, an `allowed` index out of range or a
    part that is not a closed solid."""
    if (others is None) != (other_poses is None):
        raise BuildError("swept_clash: others and other_poses go together")
    parts = list(parts)
    others = None if others is None else list(others)
    first = [s._h() for s in parts]
    second = None if others is None else [s._h() for s in others]
    frames_a = [[_frame(f) for f in pose] for pose in poses]
    frames_b = None if other_poses is None else [[_frame(f) for f in pose] for pose in other_poses]
    # C reads each set's poses at its part count: the kernel's own checks, in its order
    if frames_b is not None and len(frames_b) != len(frames_a):
        raise BuildError(f"swept_clash: {len(frames_a)} poses for set a, {len(frames_b)} for set b")
    for name, frames, n in (("a", frames_a, len(first)), ("b", frames_b or [], len(second or []))):
        for k, pose in enumerate(frames):
            if len(pose) != n:
                raise BuildError(f"swept_clash: pose {k} of set {name} has {len(pose)} frames for {n} parts")
    if second is not None and not second:
        raise BuildError("swept_clash: an empty set")
    pairs = []
    for pair in allowed:
        try:
            a, b = pair
            a, b = operator.index(a), operator.index(b)
            if not (0 <= a <= 0xFFFFFFFF and 0 <= b <= 0xFFFFFFFF):
                raise ValueError(pair)
            pairs += [a, b]
        except (TypeError, ValueError):
            raise BuildError(f"swept_clash: allowed pair {pair!r} is not two indices") from None
    flat_a = [v for pose in frames_a for f in pose for v in f]
    a_arr = (c_void_p * len(first))(*first)
    poses_a = (c_double * len(flat_a))(*flat_a)
    b_arr, poses_b = None, None
    if second is not None and frames_b is not None:
        flat_b = [v for pose in frames_b for f in pose for v in f]
        b_arr, poses_b = (c_void_p * len(second))(*second), (c_double * len(flat_b))(*flat_b)
    allowed_arr = (c_uint32 * len(pairs))(*pairs)
    h = _lib().cadaclysm_blacksmith_swept_clash(a_arr, len(first), poses_a, b_arr, 0 if second is None else len(second),
                                                poses_b, len(frames_a), _tolerance(tolerance), clearance, resolution, max_steps,
                                                allowed_arr, len(pairs) // 2)
    if not h:
        _fail("swept_clash")
    return _swept_clashes_of(h)


# ---- wall thickness ----------------------------------------------------------


def _xyz3(values) -> "tuple[float, float, float]":
    return (float(values[0]), float(values[1]), float(values[2]))


class Thickness:
    """One wall-thickness reading on a solid (`ThicknessGauge.thickness`/`.thickness_at`,
    module `thickness`). `point` lies on face `face` of body `body` (the body's index in the
    gauge): at vertex `vertex` of that body's measuring mesh (`ThicknessGauge.mesh`), or
    `vertex` `None` for a reading at a point. `thickness` is the nearest-opposing-wall rule (the
    nearest triangle that faces against one of the vertex's own faces, with the vertex behind
    it) on the measuring mesh, to `opposite` on face `opposite_face` of body `opposite_body`;
    `knife` marks a knife edge (thickness 0, `opposite` == `point`). `exact_opposite` is `opposite` moved onto its exact
    face where its foot lies within the tolerance and inside the face's trims, `exact_thickness`
    the distance to it. `sphere` is the diameter of the largest ball tangent at `point` that
    holds none of the surfaces, `None` where none under the maximum does (0 on a knife edge).
    Points are `(x, y, z)` tuples."""

    __slots__ = ("body", "vertex", "face", "point", "thickness", "opposite", "opposite_body", "opposite_face",
                 "knife", "exact_thickness", "exact_opposite", "sphere")

    body: int
    vertex: int | None
    face: int
    point: tuple[float, float, float]
    thickness: float
    opposite: tuple[float, float, float]
    opposite_body: int
    opposite_face: int
    knife: bool
    exact_thickness: float
    exact_opposite: tuple[float, float, float]
    sphere: float | None

    def __init__(self, raw: "_Thickness"):
        self.body, self.face = int(raw.body), int(raw.face)
        self.vertex = None if raw.vertex == NONE else int(raw.vertex)
        self.point, self.thickness, self.opposite = _xyz3(raw.point), float(raw.thickness), _xyz3(raw.opposite)
        self.opposite_body, self.opposite_face = int(raw.opposite_body), int(raw.opposite_face)
        self.knife, self.exact_thickness = bool(raw.knife), float(raw.exact_thickness)
        self.exact_opposite = _xyz3(raw.exact_opposite)
        self.sphere = None if math.isnan(raw.sphere) else float(raw.sphere)

    def __repr__(self) -> str:
        return (f"Thickness(body={self.body}, vertex={self.vertex}, face={self.face}, "
                f"thickness={self.thickness:.9g}, opposite_body={self.opposite_body}, knife={self.knife})")


class FaceThickness:
    """A face's thickness, found (`ThicknessGauge.thickness_at_face`,
    `Solid.thickness_at_face`; where nothing is found those answer `None`):
    `thickness` the median of the face's vertex readings (or the reading at `at`), `min` and
    `max` their extremes, `uniform` whether `max - min` is within the gauge's tolerance."""

    __slots__ = ("thickness", "min", "max", "uniform")

    thickness: float
    min: float
    max: float
    uniform: bool

    def __init__(self, raw: "_FaceThickness"):
        self.thickness, self.min, self.max = float(raw.thickness), float(raw.min), float(raw.max)
        self.uniform = bool(raw.uniform)

    def __repr__(self) -> str:
        return f"FaceThickness(thickness={self.thickness:.9g}, min={self.min:.9g}, max={self.max:.9g}, uniform={self.uniform})"


class ThicknessMesh:
    """A body's measuring mesh (`ThicknessGauge.mesh`), copied out of the gauge: `positions` and
    `normals` (unit, outward) one `(x, y, z)` tuple per vertex -- a reading's `vertex` indexes
    them; no vertex is shared between two faces -- `triangles` three vertex indices each, and
    `faces` the B-rep face of each triangle."""

    __slots__ = ("positions", "normals", "triangles", "faces")

    positions: list[tuple[float, float, float]]
    normals: list[tuple[float, float, float]]
    triangles: list[tuple[int, int, int]]
    faces: list[int]

    def __init__(self, positions: list[tuple[float, float, float]], normals: list[tuple[float, float, float]],
                 triangles: list[tuple[int, int, int]], faces: list[int]):
        self.positions, self.normals, self.triangles, self.faces = positions, normals, triangles, faces

    def __repr__(self) -> str:
        return f"ThicknessMesh(vertices={len(self.positions)}, triangles={len(self.triangles)})"


class MeshThickness:
    """One reading on a plain mesh (`mesh_thickness`): vertex `vertex` of mesh `mesh`, at
    `point`, reads `thickness` to `opposite` on triangle `opposite_triangle` of mesh
    `opposite_mesh` (both indices within that mesh). `knife`: a knife edge, thickness 0 and
    `opposite` == `point`."""

    __slots__ = ("mesh", "vertex", "thickness", "point", "opposite", "opposite_mesh", "opposite_triangle", "knife")

    mesh: int
    vertex: int
    thickness: float
    point: tuple[float, float, float]
    opposite: tuple[float, float, float]
    opposite_mesh: int
    opposite_triangle: int
    knife: bool

    def __init__(self, raw: "_MeshThickness"):
        self.mesh, self.vertex, self.thickness = int(raw.mesh), int(raw.vertex), float(raw.thickness)
        self.point, self.opposite = _xyz3(raw.point), _xyz3(raw.opposite)
        self.opposite_mesh, self.opposite_triangle = int(raw.opposite_mesh), int(raw.opposite_triangle)
        self.knife = bool(raw.knife)

    def __repr__(self) -> str:
        return (f"MeshThickness(mesh={self.mesh}, vertex={self.vertex}, thickness={self.thickness:.9g}, "
                f"opposite_mesh={self.opposite_mesh}, knife={self.knife})")


def _thicknesses_of(h, what: str) -> "list[Thickness]":
    """A thicknesses handle (null: raise `what`'s refusal) read out into rows and freed."""
    if not h:
        _fail(what)
    lib = _lib()
    try:
        raw, rows = _Thickness(), []
        for i in range(lib.cadaclysm_blacksmith_thicknesses_count(h)):
            if not lib.cadaclysm_blacksmith_thicknesses_at(h, i, ctypes.byref(raw)):
                _fail("thicknesses_at")
            rows.append(Thickness(raw))
        return rows
    finally:
        lib.cadaclysm_blacksmith_thicknesses_free(h)


class ThicknessGauge:
    """Wall thickness (the nearest-opposing-wall rule: each vertex reads to the nearest triangle
    that faces against one of its own faces, with the vertex behind it)
    over `solids`, measured against each other: each solid meshed once at `tolerance` --
    absolute, in model units (default 0.01) -- then asked as often as needed. A reading's
    `body` is the solid's index in `solids`. The gauge keeps its own reference to the bodies
    (and to the `Solid`s), so it answers on after they are closed. `close()` frees this handle;
    so does leaving a `with` block or the garbage collector. Raises `BuildError` for a
    `tolerance` not positive and finite."""

    __slots__ = ("_handle", "_solids")

    def __init__(self, solids: Iterable[Solid], tolerance: "float | None" = 0.01):
        self._solids = tuple(solids)
        handles = [s._h() for s in self._solids]
        parts = (c_void_p * len(handles))(*handles)
        self._handle = _checked(_lib().cadaclysm_blacksmith_thickness_gauge_new(parts, len(handles), _tolerance(tolerance)),
                                "thickness_gauge_new")

    def __enter__(self) -> "ThicknessGauge":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()

    def close(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_thickness_gauge_free(h)

    def _h(self):
        if not getattr(self, "_handle", None):
            raise BuildError("thickness_gauge: closed")
        return self._handle

    def __len__(self) -> int:
        """How many bodies the gauge measures."""
        return int(_lib().cadaclysm_blacksmith_thickness_gauge_body_count(self._h()))

    @property
    def tolerance(self) -> float:
        """The tolerance the gauge meshed its bodies at."""
        value = float(_lib().cadaclysm_blacksmith_thickness_gauge_tolerance(self._h()))
        if math.isnan(value):
            _fail("thickness_gauge_tolerance")
        return value

    def __repr__(self) -> str:
        if not getattr(self, "_handle", None):
            return "ThicknessGauge(closed)"
        return f"ThicknessGauge(bodies={len(self)}, tolerance={self.tolerance:g})"

    def thickness(self, maximum: float, sharp_angle: float = 0.0) -> "list[Thickness]":
        """One reading per measuring-mesh vertex that has one within `maximum` (positive and
        finite), by body then vertex; vertices whose interior angle is under `sharp_angle`
        radians (zero or more) are knife edges. Raises `BuildError` for a bad limit."""
        h = _lib().cadaclysm_blacksmith_thickness_gauge_measure(self._h(), float(maximum), float(sharp_angle))
        return _thicknesses_of(h, "thickness_gauge_measure")

    def thickness_at(self, body: int, face: int, point: Point3, maximum: float,
                     sharp_angle: float = 0.0) -> "Thickness | None":
        """The reading at `point`'s foot on face `face` of body `body` (its `vertex` `None`), or
        `None` where the foot lies off the face or the wall is thicker than `maximum`. Raises
        `BuildError` for a body or face past the end, a point not finite or a bad limit."""
        h = _lib().cadaclysm_blacksmith_thickness_gauge_at(self._h(), body, face, _point3(point, "thickness_gauge_at"),
                                                            float(maximum), float(sharp_angle))
        rows = _thicknesses_of(h, "thickness_gauge_at")
        return rows[0] if rows else None

    def thickness_at_face(self, body: int, face: int, at: Point3 | None = None, *,
                          maximum: float) -> "FaceThickness | None":
        """One thickness for face `face` of body `body`: measured at `at`'s foot
        on the face or, with `at` `None`, over the face's vertices; the other bodies are
        measured with it. `None` where nothing is found (nothing reads under
        `maximum`, or `at`'s foot lies off the face). Raises `BuildError` for a body or face
        past the end, an `at` not finite or a bad maximum."""
        out = _FaceThickness()
        at_arr = None if at is None else _point3(at, "thickness_gauge_face")
        if not _lib().cadaclysm_blacksmith_thickness_gauge_face(self._h(), body, face, at_arr, float(maximum),
                                                                 ctypes.byref(out)):
            _fail("thickness_gauge_face")
        return FaceThickness(out) if out.found else None

    def mesh(self, body: int) -> "ThicknessMesh":
        """Body `body`'s measuring mesh, copied out (it outlives the gauge). Raises `BuildError`
        for a body past the end."""
        raw = _ThicknessMesh()
        if not _lib().cadaclysm_blacksmith_thickness_gauge_mesh(self._h(), body, ctypes.byref(raw)):
            _fail("thickness_gauge_mesh")
        n, t = int(raw.vertex_count), int(raw.triangle_count)
        positions = raw.positions[:3 * n] if n else []
        normals = raw.normals[:3 * n] if n else []
        indices = raw.indices[:3 * t] if t else []
        faces = raw.faces[:t] if t else []
        return ThicknessMesh([_xyz3(positions[3 * i:3 * i + 3]) for i in range(n)],
                             [_xyz3(normals[3 * i:3 * i + 3]) for i in range(n)],
                             [(int(indices[3 * i]), int(indices[3 * i + 1]), int(indices[3 * i + 2])) for i in range(t)],
                             [int(f) for f in faces])


def thickness(solids: Iterable[Solid], maximum: float, sharp_angle: float = 0.0,
              tolerance: "float | None" = 0.01) -> "list[Thickness]":
    """`ThicknessGauge(solids, tolerance).thickness(maximum, sharp_angle)` on a gauge used once
    and freed: every reading within `maximum` on the solids, measured against each other."""
    with ThicknessGauge(solids, tolerance) as gauge:
        return gauge.thickness(maximum, sharp_angle)


def mesh_thickness(meshes: Iterable[tuple[Sequence[Point3], Sequence[Sequence[int]]]], maximum: float,
                   sharp_angle: float = 0.0) -> "list[MeshThickness]":
    """The nearest-opposing-wall rule on plain meshes measured against each other: each mesh a
    `(positions, triangles)` pair -- `(x, y, z)` points and triples of indices into its own
    points. One reading per vertex that has one within `maximum` (positive and finite), by mesh
    then vertex; `sharp_angle` as for `ThicknessGauge.thickness`. Raises `BuildError` for a mesh
    that is not such a pair, a triangle past its mesh, a position not finite or a bad limit."""
    positions: list[float] = []
    indices: list[int] = []
    vertex_counts: list[int] = []
    triangle_counts: list[int] = []
    for m, mesh in enumerate(meshes):
        try:
            points, triangles = mesh
        except (TypeError, ValueError):
            raise BuildError(f"mesh_thickness: mesh {m} is not a (positions, triangles) pair") from None
        count = 0
        for i, p in enumerate(points):
            try:
                xyz = [float(v) for v in p]
            except (TypeError, ValueError):
                xyz = []
            if len(xyz) != 3:
                raise BuildError(f"mesh_thickness: mesh {m} position {i} is not three numbers")
            positions += xyz
            count += 1
        vertex_counts.append(count)
        count = 0
        for i, t in enumerate(triangles):
            try:
                ijk = [operator.index(v) for v in t]
            except TypeError:
                ijk = []
            if len(ijk) != 3 or not all(0 <= k <= 0xFFFFFFFF for k in ijk):
                raise BuildError(f"mesh_thickness: mesh {m} triangle {i} is not three indices")
            indices += ijk
            count += 1
        triangle_counts.append(count)
    h = _lib().cadaclysm_blacksmith_mesh_thickness(
        (c_double * len(positions))(*positions), (c_uint32 * len(vertex_counts))(*vertex_counts),
        (c_uint32 * len(indices))(*indices), (c_uint32 * len(triangle_counts))(*triangle_counts),
        len(vertex_counts), float(maximum), float(sharp_angle))
    if not h:
        _fail("mesh_thickness")
    lib = _lib()
    try:
        raw, rows = _MeshThickness(), []
        for i in range(lib.cadaclysm_blacksmith_mesh_thicknesses_count(h)):
            if not lib.cadaclysm_blacksmith_mesh_thicknesses_at(h, i, ctypes.byref(raw)):
                _fail("mesh_thicknesses_at")
            rows.append(MeshThickness(raw))
        return rows
    finally:
        lib.cadaclysm_blacksmith_mesh_thicknesses_free(h)


# ---- the 2D constraint sketcher ----------------------------------------------

# The C ABI's codes, by position; Python speaks the names.
_SKETCH_ENTITY_KINDS = ("point", "line", "circle", "arc", "free_curve")
_SKETCH_CONSTRAINT_KINDS = (
    "coincident", "point_on_line", "point_on_circle", "horizontal", "vertical", "parallel", "perpendicular",
    "collinear", "tangent", "tangent_at_end", "concentric", "equal_length", "equal_radius", "midpoint",
    "symmetric", "fix", "distance", "point_line_distance", "line_distance", "circle_line_distance",
    "circle_distance", "horizontal_distance", "vertical_distance", "length", "angle", "radius", "diameter",
)
_SKETCH_SENSES = ("auto", "positive", "negative")
_SKETCH_ENDS = ("start", "end")
_SKETCH_STATUSES = ("converged", "conflicting", "diverged")
_SKETCH_STATES = ("under", "full", "over")
# `sketch_dof_list`'s and `sketch_dof_part_list`'s `which`
_DOF_REDUNDANT, _DOF_CONFLICTING, _DOF_FREE_ENTITIES = 0, 1, 2
_PART_CONSTRAINTS, _PART_REDUNDANT, _PART_CONFLICTING, _PART_FREE_ENTITIES = 0, 1, 2, 3


def _ids(pointer, count: int, what: str) -> "list[int]":
    """A borrowed `const uint32_t *` list (null: raise), copied out at once -- it is
    valid only until the next call on the same sketch. Under Pyodide the shim has
    already copied it out (`_WasmLibrary._LISTS`): `pointer` is that list."""
    if pointer is None:   # null: a `c_void_p` reads as None natively, and the shim fails to None
        _fail(what)
    if _WASM:
        return pointer
    return list((c_uint32 * count).from_address(pointer)) if count else []


def _pairs(points, what: str) -> "list[float]":
    """`points` as a flat list of x, y floats, each point checked to be a pair."""
    flat = []
    for p in points:
        xy = [float(v) for v in p]
        if len(xy) != 2:
            raise ValueError(f"{what}: each point is an (x, y) pair, not {tuple(p)!r}")
        flat += xy
    return flat


def _exact(value: float, what: str) -> int:
    """A count or code the library hands back as a double: an integral value within i32,
    else the kernel error naming the call (`int()` would truncate a NaN into a raise of
    its own, or a 2.7 into a 2)."""
    value = float(value)
    if not (-2147483648.0 <= value <= 2147483647.0 and value == math.floor(value)):   # NaN fails both
        _fail(what)
    return int(value)


def _sketch_id(value: int, what: str) -> int:
    """An id the library handed back (`NONE`: raise)."""
    if value == NONE:
        _fail(what)
    return value


def _named(table, code: int, what: str) -> str:
    if code == NONE or not 0 <= code < len(table):
        _fail(what)
    return table[code]


def _code(table, name: str, call: str, param: str) -> int:
    try:
        return table.index(name)
    except ValueError:
        raise ValueError(f"{call}: {param} must be one of {', '.join(map(repr, table))}, not {name!r}") from None


class SolveReport:
    """What a solve did: `status` ("converged", "conflicting" or "diverged"), how many
    `iterations`, the largest constraint residual left (`max_residual`), and `ids`: the
    constraints a conflict ran into, or the worst ones of a diverged solve (empty when
    it converged). Plain data."""

    __slots__ = ("status", "iterations", "max_residual", "ids")

    status: str
    iterations: int
    max_residual: float
    ids: list[int]

    def __init__(self, status: str, iterations: int, max_residual: float, ids: list[int]) -> None:
        self.status, self.iterations, self.max_residual, self.ids = status, iterations, max_residual, ids

    @property
    def converged(self) -> bool:
        return self.status == "converged"

    def __repr__(self) -> str:
        return (f"SolveReport(status={self.status!r}, iterations={self.iterations}, "
                f"max_residual={self.max_residual!r}, ids={self.ids!r})")


class PartDof:
    """One independent part of a diagnosed sketch: its `params` (unknowns), how many
    stay `free`, its `state` ("under", "full" or "over"), its `constraints`, the
    `redundant` and `conflicting` ones among them, and its `free_entities`. Plain data."""

    __slots__ = ("params", "free", "state", "constraints", "redundant", "conflicting", "free_entities")

    params: int
    free: int
    state: str
    constraints: list[int]
    redundant: list[int]
    conflicting: list[int]
    free_entities: list[int]

    def __init__(self, params: int, free: int, state: str, constraints: list[int], redundant: list[int],
                 conflicting: list[int], free_entities: list[int]) -> None:
        self.params, self.free, self.state = params, free, state
        self.constraints, self.redundant, self.conflicting, self.free_entities = constraints, redundant, conflicting, free_entities

    def __repr__(self) -> str:
        return f"PartDof(params={self.params}, free={self.free}, state={self.state!r})"


class Dof:
    """A sketch's degrees of freedom (`Sketch.diagnose`): how many are `free`, its
    `state` ("under", "full" or "over"), the `redundant` and `conflicting` constraint
    ids, the `free_entities` (entities that can still move), and the independent
    `parts` it splits into. Plain data."""

    __slots__ = ("free", "state", "redundant", "conflicting", "free_entities", "parts")

    free: int
    state: str
    redundant: list[int]
    conflicting: list[int]
    free_entities: list[int]
    parts: list[PartDof]

    def __init__(self, free: int, state: str, redundant: list[int], conflicting: list[int],
                 free_entities: list[int], parts: list[PartDof]) -> None:
        self.free, self.state = free, state
        self.redundant, self.conflicting, self.free_entities, self.parts = redundant, conflicting, free_entities, parts

    def __repr__(self) -> str:
        return f"Dof(free={self.free}, state={self.state!r}, parts={len(self.parts)})"


class Sketch:
    """A 2D sketch of points, lines, circles, arcs and free curves held by geometric
    constraints and dimensions, solved on request:

        with Sketch() as s:
            corners, sides = s.add_rect((0, 0), (40, 30))
            s.fix(corners[0])
            s.length(sides[0], 60)
            s.solve()
            plate = Solid.extrude(s.profiles()[0], Frame.xy(), 10)

    Entities and constraints are named by integer ids. Entity kinds are "point",
    "line", "circle", "arc" and "free_curve"; constraint kinds the snake_case names
    of the methods that add them ("point_line_distance", ...) -- but for `radius_of`,
    whose kind is "radius": Python has one namespace, and `radius(id)` reads a circle's
    radius. Senses are "auto", "positive" or "negative"; ends "start" or "end".

    A refused call raises `BuildError` with the library's text and, as its `ids`,
    the ids the refusal names: the constraints a new constraint, value or reference
    conflicts with, the entities still using a point (empty when it names none). The
    `SolveReport`s of `solve`, `drag`, `set_value`, `set_driving` and
    `update_reference` carry a returned report's ids the same way.
    `close()` frees this handle; so does leaving a `with` block or the garbage
    collector."""

    __slots__ = ("_handle",)

    def __init__(self) -> None:
        self._handle = _checked(_lib().cadaclysm_blacksmith_sketch_new(), "sketch_new")

    @classmethod
    def from_profile(cls, profile: Profile, infer: bool = True, tolerance: "float | None" = 1e-6) -> "Sketch":
        """A sketch of `profile`'s lines, arcs and curves joined end to end, holes
        included; with `infer` the obvious constraints (horizontal, vertical, tangent
        joints, ...) too. Ends within `tolerance` count as joined."""
        s = cls.__new__(cls)
        s._handle = _checked(_lib().cadaclysm_blacksmith_sketch_from_profile(profile._handle, bool(infer), _tolerance(tolerance)),
                             "sketch_from_profile")
        return s

    def __enter__(self) -> "Sketch":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()

    def close(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_sketch_free(h)

    def _h(self):
        if not getattr(self, "_handle", None):
            raise BuildError("sketch: closed")
        return self._handle

    def _list(self, name: str, *args, refusal: bool = False) -> "list[int]":
        count = c_size_t()
        pointer = getattr(_lib(), "cadaclysm_blacksmith_" + name)(self._h(), *args, ctypes.byref(count))
        if pointer is None and refusal:
            self._refused(name)
        return _ids(pointer, count.value, name)

    def _refused(self, what: str) -> NoReturn:
        """`_fail` for a call that can be refused with ids (`constrain`, `remove_entity`,
        `set_value`, `set_driving`, `update_reference`, `drag`): the reason first --
        under Pyodide the next call clears it -- then the ids `report_ids` holds."""
        reason = _text(_lib().cadaclysm_blacksmith_last_error()) or what
        raise BuildError(reason, ids=self._list("sketch_report_ids"))

    def _solved(self, done, report, what: str) -> SolveReport:
        if not done:
            self._refused(what)
        ids = self._list("sketch_report_ids")
        return SolveReport(_named(_SKETCH_STATUSES, _exact(report[0], what), what), _exact(report[1], what),
                           float(report[2]), ids)

    # -- entities

    def add_point(self, x: float, y: float) -> int:
        """A free point at (`x`, `y`); a coordinate that is not finite is refused."""
        return _sketch_id(_lib().cadaclysm_blacksmith_sketch_add_point(self._h(), float(x), float(y)), "sketch_add_point")

    def add_line(self, a: int, b: int) -> int:
        """A line between the points `a` and `b`."""
        return _sketch_id(_lib().cadaclysm_blacksmith_sketch_add_line(self._h(), a, b), "sketch_add_line")

    def add_circle(self, centre: int, r: float) -> int:
        """A circle of radius `r` about the point `centre`."""
        return _sketch_id(_lib().cadaclysm_blacksmith_sketch_add_circle(self._h(), centre, float(r)), "sketch_add_circle")

    def add_arc(self, centre: int, start: int, end: int) -> int:
        """A counter-clockwise arc about the point `centre` from the point `start` to the point `end`."""
        return _sketch_id(_lib().cadaclysm_blacksmith_sketch_add_arc(self._h(), centre, start, end), "sketch_add_arc")

    def add_bezier(self, start: int, c1: Point2, c2: Point2, to: Point2) -> int:
        """A cubic Bezier free curve from the point `start` through the controls `c1`
        and `c2` to a new end point at `to`; the curve owns its control points."""
        (c1x, c1y), (c2x, c2y), (x, y) = c1, c2, to
        return _sketch_id(_lib().cadaclysm_blacksmith_sketch_add_bezier(
            self._h(), start, float(c1x), float(c1y), float(c2x), float(c2y), float(x), float(y)), "sketch_add_bezier")

    def add_conic(self, start: int, control: Point2, to: Point2, weight: float) -> int:
        """A rational quadratic (conic) free curve from the point `start` with the
        control `control` of `weight` to a new end point at `to`."""
        (cx, cy), (x, y) = control, to
        return _sketch_id(_lib().cadaclysm_blacksmith_sketch_add_conic(
            self._h(), start, float(cx), float(cy), float(x), float(y), float(weight)), "sketch_add_conic")

    def add_nurbs(self, start: int, points: Iterable[Point2], knots: Iterable[float], degree: int = 3,
                  weights: Iterable[float] | None = None) -> int:
        """A NURBS free curve of `degree` from the point `start` through the control
        `points` after it, on `knots`; `weights` None for a plain B-spline, or one per
        control point counting the start (`len(points) + 1`)."""
        flat = _pairs(points, "sketch_add_nurbs")
        n = len(flat) // 2
        knot_list = [float(k) for k in knots]
        degree = operator.index(degree)
        if degree < 0:
            raise ValueError(f"sketch_add_nurbs: degree must not be negative, not {degree}")
        # The library reads exactly `n + 1` weights whatever the list holds: check here.
        w = None if weights is None else [float(v) for v in weights]
        if w is not None and len(w) != n + 1:
            raise BuildError(f"sketch_add_nurbs: {len(w)} weights for {n + 1} control points "
                             f"(the start and {n} given); give one per point")
        return _sketch_id(_lib().cadaclysm_blacksmith_sketch_add_nurbs(
            self._h(), start, degree, (c_double * len(flat))(*flat), n,
            None if w is None else (c_double * len(w))(*w),
            (c_double * len(knot_list))(*knot_list), len(knot_list)), "sketch_add_nurbs")

    def add_rect(self, a: Point2, b: Point2) -> tuple[list[int], list[int]]:
        """The rectangle with opposite corners `a` and `b`: its four corner points,
        counter-clockwise from `a`, and its four sides (side `i` from corner `i`)."""
        (x0, y0), (x1, y1) = a, b
        count = c_size_t()
        pointer = _lib().cadaclysm_blacksmith_sketch_add_rect(self._h(), float(x0), float(y0), float(x1), float(y1),
                                                             ctypes.byref(count))
        ids = _ids(pointer, count.value, "sketch_add_rect")
        return ids[:4], ids[4:]

    def kind(self, id: int) -> str:
        """The kind of entity `id`: "point", "line", "circle", "arc" or "free_curve"."""
        return _named(_SKETCH_ENTITY_KINDS, _lib().cadaclysm_blacksmith_sketch_kind(self._h(), id), "sketch_kind")

    def entities(self) -> list[int]:
        """The live entity ids, ascending."""
        return self._list("sketch_entities")

    def point(self, id: int) -> tuple[float, float]:
        """The point `id`'s position."""
        out = (c_double * 2)()
        _ok(_lib().cadaclysm_blacksmith_sketch_point(self._h(), id, out), "sketch_point")
        return out[0], out[1]

    def set_point(self, id: int, x: float, y: float) -> None:
        """Moves the point `id` to (`x`, `y`) without solving."""
        _ok(_lib().cadaclysm_blacksmith_sketch_set_point(self._h(), id, float(x), float(y)), "sketch_set_point")

    def radius(self, id: int) -> float:
        """The radius of the circle or arc `id` (the RADIUS constraint is `radius_of`)."""
        r = _lib().cadaclysm_blacksmith_sketch_radius(self._h(), id)
        if math.isnan(r):
            _fail("sketch_radius")
        return r

    def set_radius(self, id: int, r: float) -> None:
        """Sets the circle `id`'s radius to `r` without solving."""
        _ok(_lib().cadaclysm_blacksmith_sketch_set_radius(self._h(), id, float(r)), "sketch_set_radius")

    def centre(self, id: int) -> int:
        """The centre point of the circle or arc `id`."""
        return _sketch_id(_lib().cadaclysm_blacksmith_sketch_centre(self._h(), id), "sketch_centre")

    def ends(self, id: int) -> list[int]:
        """The points entity `id` runs between: a line's `[a, b]`, an arc's
        `[start, end]`, a free curve's `[start, controls..., end]`."""
        return self._list("sketch_ends", id)

    def set_construction(self, id: int, on: bool = True) -> None:
        """Marks entity `id` as construction geometry (kept out of profiles), or back."""
        _ok(_lib().cadaclysm_blacksmith_sketch_set_construction(self._h(), id, bool(on)), "sketch_set_construction")

    def is_construction(self, id: int) -> bool:
        """Whether entity `id` is construction geometry (False for an unknown id)."""
        return bool(_lib().cadaclysm_blacksmith_sketch_is_construction(self._h(), id))

    def is_reference(self, id: int) -> bool:
        """Whether entity `id` is a reference copy of another sketch's (False for an unknown id)."""
        return bool(_lib().cadaclysm_blacksmith_sketch_is_reference(self._h(), id))

    def remove_entity(self, id: int) -> list[int]:
        """Removes entity `id` and the constraints on it: the removed constraint ids.
        Refused for a point that lines or circles still use."""
        return self._list("sketch_remove_entity", id, refusal=True)

    def reference(self, other: Sketch, entity: int) -> int:
        """A fixed construction copy of `other`'s entity `entity`, kept in step by
        `update_reference`. `other` must be another sketch."""
        return _sketch_id(_lib().cadaclysm_blacksmith_sketch_reference(self._h(), other._h(), entity), "sketch_reference")

    def update_reference(self, id: int, other: Sketch) -> SolveReport:
        """Refreshes the reference `id` from `other` and re-solves."""
        report = (c_double * 3)()
        return self._solved(_lib().cadaclysm_blacksmith_sketch_update_reference(self._h(), id, other._h(), report),
                            report, "sketch_update_reference")

    # -- constraints: each returns the new constraint's id

    def _constrain(self, kind: str, refs, value: float = 0.0, driving: bool = True, sense: str = "auto",
                   end: str = "start") -> int:
        sense_code = _code(_SKETCH_SENSES, sense, kind, "sense")
        end_code = _code(_SKETCH_ENDS, end, kind, "end")
        ids = [int(r) for r in refs]
        got = _lib().cadaclysm_blacksmith_sketch_constrain(
            self._h(), _SKETCH_CONSTRAINT_KINDS.index(kind), (c_uint32 * len(ids))(*ids), len(ids),
            float(value), bool(driving), sense_code, end_code)
        if got == NONE:
            self._refused("sketch_constrain")
        return got

    def coincident(self, a: int, b: int) -> int:
        return self._constrain("coincident", (a, b))

    def point_on_line(self, point: int, line: int) -> int:
        return self._constrain("point_on_line", (point, line))

    def point_on_circle(self, point: int, circle: int) -> int:
        """`circle` a circle or an arc."""
        return self._constrain("point_on_circle", (point, circle))

    def horizontal(self, a: int, b: int) -> int:
        """The points `a` and `b` level with each other."""
        return self._constrain("horizontal", (a, b))

    def vertical(self, a: int, b: int) -> int:
        """The points `a` and `b` one above the other."""
        return self._constrain("vertical", (a, b))

    def parallel(self, a: int, b: int) -> int:
        return self._constrain("parallel", (a, b))

    def perpendicular(self, a: int, b: int) -> int:
        return self._constrain("perpendicular", (a, b))

    def collinear(self, a: int, b: int) -> int:
        return self._constrain("collinear", (a, b))

    def tangent(self, a: int, b: int, sense: str = "auto") -> int:
        return self._constrain("tangent", (a, b), sense=sense)

    def tangent_at_end(self, curve: int, other: int, end: str = "start") -> int:
        """The free curve `curve` tangent to `other` at its `end` ("start" or "end")."""
        return self._constrain("tangent_at_end", (curve, other), end=end)

    def concentric(self, a: int, b: int) -> int:
        return self._constrain("concentric", (a, b))

    def equal_length(self, a: int, b: int) -> int:
        return self._constrain("equal_length", (a, b))

    def equal_radius(self, a: int, b: int) -> int:
        return self._constrain("equal_radius", (a, b))

    def midpoint(self, point: int, line: int) -> int:
        return self._constrain("midpoint", (point, line))

    def symmetric(self, a: int, b: int, about: int) -> int:
        """The points `a` and `b` mirror images across the line `about`."""
        return self._constrain("symmetric", (a, b, about))

    def fix(self, entity: int) -> int:
        return self._constrain("fix", (entity,))

    def distance(self, a: int, b: int, value: float, driving: bool = True) -> int:
        return self._constrain("distance", (a, b), value, driving)

    def point_line_distance(self, point: int, line: int, value: float, driving: bool = True, sense: str = "auto") -> int:
        return self._constrain("point_line_distance", (point, line), value, driving, sense)

    def line_distance(self, a: int, b: int, value: float, driving: bool = True, sense: str = "auto") -> int:
        return self._constrain("line_distance", (a, b), value, driving, sense)

    def circle_line_distance(self, circle: int, line: int, value: float, driving: bool = True, sense: str = "auto") -> int:
        return self._constrain("circle_line_distance", (circle, line), value, driving, sense)

    def circle_distance(self, a: int, b: int, value: float, driving: bool = True) -> int:
        return self._constrain("circle_distance", (a, b), value, driving)

    def horizontal_distance(self, a: int, b: int, value: float, driving: bool = True) -> int:
        return self._constrain("horizontal_distance", (a, b), value, driving)

    def vertical_distance(self, a: int, b: int, value: float, driving: bool = True) -> int:
        return self._constrain("vertical_distance", (a, b), value, driving)

    def length(self, line: int, value: float, driving: bool = True) -> int:
        return self._constrain("length", (line,), value, driving)

    def angle(self, a: int, b: int, value: float, driving: bool = True) -> int:
        """The angle from line `a` to line `b`, in radians."""
        return self._constrain("angle", (a, b), value, driving)

    def radius_of(self, circle: int, value: float, driving: bool = True) -> int:
        """The RADIUS dimension (kind "radius") -- `radius(id)` reads a radius instead."""
        return self._constrain("radius", (circle,), value, driving)

    def diameter(self, circle: int, value: float, driving: bool = True) -> int:
        return self._constrain("diameter", (circle,), value, driving)

    def constraints(self) -> list[int]:
        """The live constraint ids, ascending."""
        return self._list("sketch_constraints")

    def constraint_kind(self, id: int) -> str:
        """The kind of constraint `id`, e.g. "point_line_distance"."""
        return _named(_SKETCH_CONSTRAINT_KINDS, _lib().cadaclysm_blacksmith_sketch_constraint_kind(self._h(), id),
                      "sketch_constraint_kind")

    def constraint_refs(self, id: int) -> list[int]:
        """The entity ids constraint `id` was made on, in the order given."""
        return self._list("sketch_constraint_refs", id)

    def constraint_value(self, id: int) -> float | None:
        """The value of the dimension `id`; None for a constraint that is not a dimension."""
        v = _lib().cadaclysm_blacksmith_sketch_constraint_value(self._h(), id)
        if math.isnan(v):
            if _text(_lib().cadaclysm_blacksmith_last_error()):
                _fail("sketch_constraint_value")
            return None
        return v

    def constraint_driving(self, id: int) -> bool:
        """Whether the dimension `id` drives the geometry (False for a constraint that is
        not a dimension)."""
        driving = bool(_lib().cadaclysm_blacksmith_sketch_constraint_driving(self._h(), id))
        if not driving and _text(_lib().cadaclysm_blacksmith_last_error()):
            _fail("sketch_constraint_driving")
        return driving

    def constraint_sense(self, id: int) -> str:
        """The sense of constraint `id`; "auto" for a kind without one."""
        return _named(_SKETCH_SENSES, _lib().cadaclysm_blacksmith_sketch_constraint_sense(self._h(), id),
                      "sketch_constraint_sense")

    def constraint_end(self, id: int) -> str:
        """The end ("start" or "end") of the free curve a `tangent_at_end` constraint
        `id` holds; "start" for a kind without one."""
        return _named(_SKETCH_ENDS, _lib().cadaclysm_blacksmith_sketch_constraint_end(self._h(), id),
                      "sketch_constraint_end")

    def is_joint_tangent(self, id: int) -> bool:
        """Whether the tangent constraint `id` joins two curves end to end."""
        return bool(_lib().cadaclysm_blacksmith_sketch_is_joint_tangent(self._h(), id))

    def remove(self, id: int) -> None:
        """Removes the constraint `id`."""
        _ok(_lib().cadaclysm_blacksmith_sketch_remove(self._h(), id), "sketch_remove")

    def set_value(self, id: int, value: float) -> SolveReport:
        """Sets the dimension `id` to `value` and re-solves."""
        report = (c_double * 3)()
        return self._solved(_lib().cadaclysm_blacksmith_sketch_set_value(self._h(), id, float(value), report),
                            report, "sketch_set_value")

    def set_driving(self, id: int, driving: bool) -> SolveReport:
        """Makes the dimension `id` drive the geometry (True) or only report it, and re-solves."""
        report = (c_double * 3)()
        return self._solved(_lib().cadaclysm_blacksmith_sketch_set_driving(self._h(), id, bool(driving), report),
                            report, "sketch_set_driving")

    def measure(self, id: int) -> float:
        """What the geometry measures for the dimension `id` right now."""
        v = _lib().cadaclysm_blacksmith_sketch_measure(self._h(), id)
        if math.isnan(v):
            _fail("sketch_measure")
        return v

    # -- solving and diagnosis

    def solve(self) -> SolveReport:
        """Solves the sketch. A conflicting or diverged solve is reported, not raised."""
        report = (c_double * 3)()
        return self._solved(_lib().cadaclysm_blacksmith_sketch_solve(self._h(), report), report, "sketch_solve")

    def drag(self, moves: Mapping[int, Point2]) -> SolveReport:
        """Drags each point id in `moves` towards its (x, y) while the constraints hold,
        as a live gesture would. Refused for an id that is not a point."""
        keys = sorted(moves, key=int)   # ascending ids: the solve must not depend on dict order
        points = [int(p) for p in keys]
        flat = _pairs((moves[p] for p in keys), "sketch_drag")
        report = (c_double * 3)()
        done = _lib().cadaclysm_blacksmith_sketch_drag(self._h(), (c_uint32 * len(points))(*points),
                                                        (c_double * len(flat))(*flat), len(points), report)
        return self._solved(done, report, "sketch_drag")

    def diagnose(self) -> Dof:
        """The sketch's degrees of freedom, whole and per independent part."""
        lib, h = _lib(), self._h()
        out = (c_double * 3)()
        _ok(lib.cadaclysm_blacksmith_sketch_diagnose(h, out), "sketch_diagnose")
        free, state, part_count = (_exact(out[0], "sketch_diagnose"),
                                   _named(_SKETCH_STATES, _exact(out[1], "sketch_diagnose"), "sketch_diagnose"),
                                   _exact(out[2], "sketch_diagnose"))
        redundant, conflicting, free_entities = (self._list("sketch_dof_list", which)
                                                 for which in (_DOF_REDUNDANT, _DOF_CONFLICTING, _DOF_FREE_ENTITIES))
        parts = []
        part = (c_double * 3)()
        for i in range(part_count):
            _ok(lib.cadaclysm_blacksmith_sketch_dof_part(h, i, part), "sketch_dof_part")
            lists = [self._list("sketch_dof_part_list", i, which)
                     for which in (_PART_CONSTRAINTS, _PART_REDUNDANT, _PART_CONFLICTING, _PART_FREE_ENTITIES)]
            parts.append(PartDof(_exact(part[0], "sketch_dof_part"), _exact(part[1], "sketch_dof_part"),
                                 _named(_SKETCH_STATES, _exact(part[2], "sketch_dof_part"), "sketch_dof_part"), *lists))
        return Dof(free, state, redundant, conflicting, free_entities, parts)

    def profiles(self, tolerance: "float | None" = 1e-6) -> list[Profile]:
        """The closed loops as profiles (nested loops become holes; construction
        geometry left out); ends within `tolerance` join."""
        return _profile_list(_lib().cadaclysm_blacksmith_sketch_profiles(self._h(), _tolerance(tolerance)), "sketch_profiles")

    def open_chains(self, tolerance: "float | None" = 1e-6) -> list[Profile]:
        """The paths that do not close, as profiles; ends within `tolerance` join."""
        return _profile_list(_lib().cadaclysm_blacksmith_sketch_open_chains(self._h(), _tolerance(tolerance)), "sketch_open_chains")


def _rtree_number(v) -> bool:
    """A number as the R-tree calls take one: any real (numpy's included), never a `bool` or a
    string."""
    return isinstance(v, numbers.Real) and not isinstance(v, bool)


def _rtree_real(value, call: str, name: str) -> float:
    """A radius, slack or limit as a float, refused by `call`'s name when it is not a number --
    whether the number is a distance is the library's to say."""
    if not _rtree_number(value):
        raise BuildError(f"{call}: {name} {value!r} is not a number")
    return float(value)


def _rtree_u32(value, call: str, name: str) -> int:
    """An id or a `k` as the C ABI's `uint32_t`, refused by `call`'s name when it is not a whole
    number from 0 to 4294967295 (a `bool` or a float included), rather than wrapped by ctypes."""
    k = None
    if not isinstance(value, bool):
        try:
            k = operator.index(value)
        except TypeError:
            k = None
    if k is None or not 0 <= k <= 0xFFFFFFFF:
        raise BuildError(f"{call}: {name} {value!r} is not a whole number from 0 to 4294967295")
    return k


def _rtree_triple(p) -> "list[float] | None":
    """`p` as 3 floats, or `None` when it is not 3 numbers (a string is not)."""
    if isinstance(p, (str, bytes, bytearray)):
        return None
    try:
        parts = list(p)
    except TypeError:
        return None
    if len(parts) != 3 or not all(_rtree_number(v) for v in parts):
        return None
    return [float(v) for v in parts]


def _rtree_point(point, call: str) -> "ctypes.Array[c_double]":
    """A query point as 3 doubles, refused by `call`'s name when it is not 3 numbers (a NaN is
    the library's to refuse)."""
    values = _rtree_triple(point)
    if values is None:
        raise BuildError(f"{call}: a point is 3 numbers, not {point!r}")
    return (c_double * 3)(*values)


def _box6(box, what: str) -> "tuple[list[float], bool]":
    """A box as the C ABI's 6 doubles `[minx, miny, minz, maxx, maxy, maxz]`, and whether it was
    given as a point: a `Box`, `(min, max)` (two triples), 6 numbers, or a point (3 numbers, a
    zero box). Numbers are reals, never a `bool` or a string, and a string or bytes is no box.
    The shape is refused here by `what`; a NaN or an inverted box is the library's."""
    if isinstance(box, Box):
        return [*box.lo, *box.hi], False
    parts = None
    if not isinstance(box, (str, bytes, bytearray)):
        try:
            parts = list(box)
        except TypeError:
            parts = None
    if parts is not None and len(parts) in (3, 6) and all(_rtree_number(v) for v in parts):
        values = [float(v) for v in parts]
        return (values * 2, True) if len(values) == 3 else (values, False)
    if parts is not None and len(parts) == 2:
        lo, hi = _rtree_triple(parts[0]), _rtree_triple(parts[1])
        if lo is not None and hi is not None:
            return lo + hi, False
    raise BuildError(f"{what}: a box is (min, max), two triples, or a point, not {box!r}")


def _points_flat(points, what: str, name: str = "point") -> "list[float]":
    """Points (3 numbers each, or a numpy (n, 3) array) as one flat list, the shape refused by
    index under `what`."""
    flat: "list[float]" = []
    for i, p in enumerate(points):
        values = _rtree_triple(p)
        if values is None:
            raise BuildError(f"{what}: {name} {i} is not 3 numbers: {p!r}")
        flat.extend(values)
    return flat


class RTree:
    """A spatial index over boxes with ids (an R*-tree): `search` a box for the entries it
    meets, `within` / `nearest` a point for the closest, `overlaps` / `self_overlaps` for every
    pair of boxes that meet. Ids are the caller's own and may repeat; an entry is an id and its
    box, and the same `(id, box)` twice is two entries. Touching boxes meet.

    A box is `(min, max)` -- two `(x, y, z)` triples -- or a `Box`, or 6 numbers; a point
    `(x, y, z)` stands for a zero box. Answers come in a fixed order: `search` ids ascending,
    `within` / `nearest` by distance then id, pairs ascending. `slack` is the largest gap between
    two boxes that still pair. The tree changes in place (`insert`, `remove`); calls on one tree
    must not overlap from two threads. `close()` frees it; so does leaving a `with` block or the
    garbage collector."""

    __slots__ = ("_handle",)

    def __init__(self) -> None:
        self._handle = _checked(_lib().cadaclysm_blacksmith_rtree_new(), "rtree_new")

    @classmethod
    def _adopt(cls, handle, what: str) -> "RTree":
        tree = cls.__new__(cls)
        tree._handle = _checked(handle, what)
        return tree

    @classmethod
    def from_boxes(cls, items: "Iterable[tuple[int, BoxLike]]") -> "RTree":
        """A tree over `(id, box)` pairs at once, packed (sort-tile-recursive): fuller and
        faster to query than the same entries inserted one by one. Raises `BuildError` for the
        first entry whose box is not a box (a NaN, an infinity, `min > max`), by index."""
        ids: "list[int]" = []
        flat: "list[float]" = []
        for i, item in enumerate(items):
            try:
                if isinstance(item, (str, bytes, bytearray)):
                    raise TypeError
                id_, box = item
            except (TypeError, ValueError):
                raise BuildError(f"rtree_from_boxes: entry {i} is not an (id, box) pair: {item!r}") from None
            ids.append(_rtree_u32(id_, "rtree_from_boxes", f"entry {i}'s id"))
            flat.extend(_box6(box, f"rtree_from_boxes: entry {i}")[0])
        handle = _lib().cadaclysm_blacksmith_rtree_from_boxes((c_uint32 * len(ids))(*ids), (c_double * len(flat))(*flat), len(ids))
        return cls._adopt(handle, "rtree_from_boxes")

    @classmethod
    def from_points(cls, points: "Iterable[Point3] | numpy.ndarray") -> "RTree":
        """A tree over `points`, each a zero box whose id is its index. Raises `BuildError` for
        the first point with a NaN or infinite coordinate, by index."""
        flat = _points_flat(points, "rtree_from_points")
        handle = _lib().cadaclysm_blacksmith_rtree_from_points((c_double * len(flat))(*flat), len(flat) // 3)
        return cls._adopt(handle, "rtree_from_points")

    @classmethod
    def from_triangles(cls, positions: "Iterable[Point3] | numpy.ndarray",
                       triangles: "Iterable[tuple[int, int, int]] | numpy.ndarray") -> "RTree":
        """A tree over a mesh's triangles in one call: one entry per triangle of `triangles` (an
        (m, 3) sequence of indices into `positions`, an (n, 3) sequence of points), its id the
        triangle's index, its box its three corners' box.
        Raises `BuildError` for the first corner past the points or at a point with a NaN or
        infinite coordinate, by triangle and point; points no triangle uses are not checked."""
        flat = _points_flat(positions, "rtree_from_triangles")
        indices: "list[int]" = []
        for i, tri in enumerate(triangles):
            parts = None
            if not isinstance(tri, (str, bytes, bytearray)):
                try:
                    parts = list(tri)
                except TypeError:
                    parts = None
            if parts is None or len(parts) != 3:
                raise BuildError(f"rtree_from_triangles: triangle {i} is not 3 indices: {tri!r}")
            indices.extend(_rtree_u32(k, "rtree_from_triangles", f"triangle {i}'s index") for k in parts)
        handle = _lib().cadaclysm_blacksmith_rtree_from_triangles(
            (c_double * len(flat))(*flat), len(flat) // 3, (c_uint32 * len(indices))(*indices), len(indices) // 3)
        return cls._adopt(handle, "rtree_from_triangles")

    def __enter__(self) -> "RTree":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()

    def close(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_rtree_free(h)

    def _h(self):
        if not self._handle:
            raise BuildError("rtree: closed")
        return self._handle

    def __len__(self) -> int:
        """How many entries the tree holds."""
        return int(_lib().cadaclysm_blacksmith_rtree_count(self._h()))

    def __repr__(self) -> str:
        return "RTree(closed)" if not self._handle else f"RTree({len(self)} entries)"

    @property
    def bounds(self) -> "tuple[tuple[float, float, float], tuple[float, float, float]] | None":
        """The union of every entry's box as `(min, max)`, or `None` for an empty tree."""
        h = self._h()
        if len(self) == 0:
            return None
        out = (c_double * 6)()
        if not _lib().cadaclysm_blacksmith_rtree_bounds(h, out):
            _fail("rtree_bounds")
        v = [float(x) for x in out]
        return (v[0], v[1], v[2]), (v[3], v[4], v[5])

    def insert(self, id: int, box: "BoxLike") -> None:
        """Add the entry `(id, box)`, `box` a box or a point. Raises `BuildError`, leaving the
        tree as it was, for a box that is not a box or a point that is not finite."""
        h, id_ = self._h(), _rtree_u32(id, "rtree_insert", "id")
        words, point = _box6(box, "rtree_insert")
        lib = _lib()
        if point:
            ok = lib.cadaclysm_blacksmith_rtree_insert_point(h, id_, (c_double * 3)(*words[:3]))
        else:
            ok = lib.cadaclysm_blacksmith_rtree_insert(h, id_, (c_double * 6)(*words))
        if not ok:
            _fail("rtree_insert_point" if point else "rtree_insert")

    def remove(self, id: int, box: "BoxLike") -> bool:
        """Take out one entry equal to `(id, box)` -- the box it was inserted with, compared
        coordinate by coordinate (a point's is its zero box) -- and say whether there was one:
        `False`, not an error, when there is none. With duplicates, one goes per call. Raises
        `BuildError` for a box that is not a box."""
        h, id_ = self._h(), _rtree_u32(id, "rtree_remove", "id")
        words = _box6(box, "rtree_remove")[0]
        lib = _lib()
        if lib.cadaclysm_blacksmith_rtree_remove(h, id_, (c_double * 6)(*words)):
            return True
        if lib.cadaclysm_blacksmith_last_error():
            _fail("rtree_remove")
        return False

    def search(self, box: "BoxLike") -> "list[int]":
        """The ids of every entry whose box meets `box` (touching counts), ascending. Raises
        `BuildError` for a box that is not a box."""
        h, words = self._h(), _box6(box, "rtree_search")[0]
        return [i for i, _ in _rtree_hits("rtree_search", _lib().cadaclysm_blacksmith_rtree_search(h, (c_double * 6)(*words)))]

    def within(self, point: Point3, r: float) -> "list[tuple[int, float]]":
        """Every entry whose box is within `r` of `point` (Euclidean, 0 inside the box), as
        `(id, distance)` by distance then id. Raises `BuildError` for a point not finite or an
        `r` negative or NaN."""
        h, p, r = self._h(), _rtree_point(point, "rtree_within"), _rtree_real(r, "rtree_within", "radius")
        return _rtree_hits("rtree_within", _lib().cadaclysm_blacksmith_rtree_within(h, p, r))

    def nearest(self, point: Point3, k: int) -> "list[tuple[int, float]]":
        """The `k` entries whose boxes are nearest `point`, as `(id, distance)` by distance then
        id (the smaller ids win a tie); all of them when `k` is over the count. Raises
        `BuildError` for a point not finite or a `k` above 1 000 000."""
        h = self._h()
        return _rtree_hits("rtree_nearest", _lib().cadaclysm_blacksmith_rtree_nearest(
            h, _rtree_point(point, "rtree_nearest"), _rtree_u32(k, "rtree_nearest", "k")))

    def ray(self, origin: Point3, direction: Point3, max_t: float = math.inf) -> "list[tuple[int, float]]":
        """Every entry whose box the ray `origin + t * direction`, `0 <= t <= max_t`, meets, as
        `(id, t)` by `t` then id, `t` where the ray enters the box (0 when `origin` is inside it).
        Touching counts: a ray grazing a face or an edge meets the box. `t` is in units of
        `direction`'s length, which is not normalised; `max_t` may be `math.inf`. Raises
        `BuildError` for an origin or direction not finite, a zero direction, or a `max_t`
        negative or NaN."""
        h = self._h()
        o, d = _rtree_triple(origin), _rtree_triple(direction)
        if o is None:
            raise BuildError(f"rtree_ray: an origin is 3 numbers, not {origin!r}")
        if d is None:
            raise BuildError(f"rtree_ray: a direction is 3 numbers, not {direction!r}")
        return _rtree_hits("rtree_ray", _lib().cadaclysm_blacksmith_rtree_ray(
            h, (c_double * 3)(*o), (c_double * 3)(*d), _rtree_real(max_t, "rtree_ray", "max_t")))

    def overlaps(self, other: "RTree", slack: float = 0.0) -> "list[tuple[int, int]]":
        """Every pair `(a, b)`, `a` an entry of this tree and `b` one of `other`, whose boxes
        are at most `slack` apart on every axis, ascending. Raises `BuildError` for a `slack`
        negative or NaN."""
        h, o = self._h(), other._h()
        return _rtree_pairs("rtree_overlaps", _lib().cadaclysm_blacksmith_rtree_overlaps(h, o, _rtree_real(slack, "rtree_overlaps", "slack")))

    def self_overlaps(self, slack: float = 0.0) -> "list[tuple[int, int]]":
        """Every unordered pair of distinct entries at most `slack` apart, once each as
        `(smaller id, larger id)`, ascending -- an id paired with itself only where two entries
        share it. Raises `BuildError` for a `slack` negative or NaN."""
        h = self._h()
        return _rtree_pairs("rtree_self_overlaps", _lib().cadaclysm_blacksmith_rtree_self_overlaps(h, _rtree_real(slack, "rtree_self_overlaps", "slack")))


#: The interpolator's modes by name, at the C constants' values (`CADACLYSM_BLACKSMITH_INTERPOLATE_*`).
_INTERPOLATOR_MODES = {"nearest": 0, "linear": 1, "cosine": 2, "cubic": 3, "catmull_rom": 4}


def _interpolator_mode(mode: str) -> int:
    """A mode's C value, a name not among the five refused here before any call."""
    try:
        return _INTERPOLATOR_MODES[mode]
    except (KeyError, TypeError):
        raise ValueError(f"interpolator: mode {mode!r} is not one of {', '.join(_INTERPOLATOR_MODES)}") from None


class Interpolator:
    """A list of samples read at a fractional index, as Rhino's `Interpolator`: `t = 2` is
    sample 2, `t = 2.5` halfway between samples 2 and 3. Animation keys, a value along a
    pattern, a smoothed profile of measurements.

    `samples` are numbers (dimension 1, answered as floats) or equal-length sequences -- 2D,
    3D or any dimension, answered as tuples, each component read on its own. An open list
    clamps `t` to `[0, len − 1]` and stops on its end samples; a `cyclic` one wraps `t` with
    period `len` (`t = −0.5` is halfway between the last sample and the first).

    The five modes (Paul Bourke's formulas, in the notation `μ` the fraction past sample `i`,
    `y0 … y3` the samples at `i − 1 … i + 2`): `nearest` the sample at `⌊t + ½⌋`; `linear`
    `y1 + (y2 − y1) μ`; `cosine` linear at `(1 − cos πμ) / 2`, flat at every sample; `cubic`
    Bourke's cubic through every sample (it does not reproduce a ramp); `catmull_rom` through
    every sample, C1, its tangent at each `(y2 − y0) / 2`. Every mode returns the sample itself
    at a whole `t`. An interpolator never changes after it is made. `close()` frees it; so does
    leaving a `with` block or the garbage collector."""

    __slots__ = ("_handle", "_dimension")

    def __init__(self, samples: "Iterable[float] | Iterable[Sequence[float]] | numpy.ndarray", cyclic: bool = False) -> None:
        rows = list(samples)
        if rows and all(isinstance(v, numbers.Real) for v in rows):
            flat, dimension = [float(v) for v in rows], 1
        else:
            try:
                tuples = [[float(v) for v in row] for row in rows]
            except TypeError:
                raise ValueError("interpolator: samples are all numbers or all sequences of numbers") from None
            dimension = len(tuples[0]) if tuples else 1
            if any(len(row) != dimension for row in tuples):
                raise ValueError(f"interpolator: samples differ in length ({sorted({len(row) for row in tuples})})")
            flat = [v for row in tuples for v in row]
        self._handle = None
        self._dimension = dimension
        handle = _lib().cadaclysm_blacksmith_interpolator_new((c_double * len(flat))(*flat), len(rows), dimension, bool(cyclic))
        self._handle = _checked(handle, "interpolator_new")

    def __enter__(self) -> "Interpolator":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()

    def close(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_interpolator_free(h)

    def _h(self):
        if not self._handle:
            raise BuildError("interpolator: closed")
        return self._handle

    def __len__(self) -> int:
        """How many samples."""
        return int(_lib().cadaclysm_blacksmith_interpolator_count(self._h()))

    def __repr__(self) -> str:
        if not self._handle:
            return "Interpolator(closed)"
        return f"Interpolator({len(self)} samples of {self._dimension}{', cyclic' if self.cyclic else ''})"

    @property
    def dimension(self) -> int:
        """How many numbers per sample: 1 answers floats, more answers tuples."""
        return int(_lib().cadaclysm_blacksmith_interpolator_dimension(self._h()))

    @property
    def cyclic(self) -> bool:
        """Whether `t` wraps round the list (else it is clamped to the ends)."""
        return bool(_lib().cadaclysm_blacksmith_interpolator_cyclic(self._h()))

    def _value(self, values: "list[float]") -> "float | tuple[float, ...]":
        return values[0] if self._dimension == 1 else tuple(values)

    def at(self, t: float, mode: str = "linear") -> "float | tuple[float, ...]":
        """The value at the fractional index `t` by `mode` (`"nearest"`, `"linear"`,
        `"cosine"`, `"cubic"` or `"catmull_rom"`; a name not among them raises `ValueError`).
        Raises `BuildError` for a `t` that is NaN or infinite."""
        m, h = _interpolator_mode(mode), self._h()
        out = (c_double * self._dimension)()
        if not _lib().cadaclysm_blacksmith_interpolator_at(h, float(t), m, out, self._dimension):
            _fail("interpolator_at")
        return self._value([float(v) for v in out])

    def sample(self, ts: "Iterable[float]", mode: str = "linear") -> "list[float | tuple[float, ...]]":
        """The values at every `t` of `ts` by `mode`, as `at` reads each, in one call. Raises
        `BuildError` for a value of `t` that is NaN or infinite (by its index) and more than
        1 000 000 values."""
        m, h = _interpolator_mode(mode), self._h()
        values = [float(t) for t in ts]
        if not values:
            return []
        d = self._dimension
        out = (c_double * (len(values) * d))()
        if not _lib().cadaclysm_blacksmith_interpolator_sample(h, (c_double * len(values))(*values), len(values), m, out, len(out)):
            _fail("interpolator_sample")
        flat = [float(v) for v in out]
        return [self._value(flat[k:k + d]) for k in range(0, len(flat), d)]

    def nearest(self, t: float) -> "float | tuple[float, ...]":
        """The sample at `⌊t + ½⌋` (a half rounds up), after the clamp or wrap."""
        return self.at(t, "nearest")

    def linear(self, t: float) -> "float | tuple[float, ...]":
        """Straight between the two samples either side of `t`."""
        return self.at(t, "linear")

    def cosine(self, t: float) -> "float | tuple[float, ...]":
        """Between the two samples either side of `t` on a cosine ease, flat at every sample."""
        return self.at(t, "cosine")

    def cubic(self, t: float) -> "float | tuple[float, ...]":
        """Bourke's cubic over the four samples about `t`, through every sample."""
        return self.at(t, "cubic")

    def catmull_rom(self, t: float) -> "float | tuple[float, ...]":
        """The Catmull-Rom spline over the four samples about `t`: through every sample, C1."""
        return self.at(t, "catmull_rom")


def _rust_number(x: float) -> str:
    """`x` as Rust's `{}` prints an f64 -- the kernel's refusals quote numbers that way."""
    if math.isnan(x):
        return "NaN"
    if math.isinf(x):
        return "inf" if x > 0 else "-inf"
    # repr is the shortest round-trip digits, as Rust's are; Rust lays them out without an exponent.
    sign, body = ("-", repr(-x)) if math.copysign(1.0, x) < 0 else ("", repr(x))
    mantissa, _, exponent = body.partition("e")
    whole, _, fraction = mantissa.partition(".")
    digits = (whole + fraction).lstrip("0")
    shift = int(exponent or 0) - len(fraction)
    stripped = digits.rstrip("0")
    shift += len(digits) - len(stripped)
    digits = stripped
    if not digits:
        return sign + "0"
    if shift >= 0:
        return sign + digits + "0" * shift
    point = len(digits) + shift
    if point > 0:
        return sign + digits[:point] + "." + digits[point:]
    return sign + "0." + "0" * -point + digits


def _point_triples(call: str, hay, needles) -> "tuple[list[list[float]], list[list[float]]]":
    """`hay` and `needles` as triples, refused as the kernel's `closest_points` / `k_neighbors`
    refuse: the first hay point, then needle, that is not finite (or not 3 numbers), by index."""
    out = []
    for name, points in (("hay", hay), ("needle", needles)):
        flat = _points_flat(points, call, f"{name} point")
        triples = [flat[i:i + 3] for i in range(0, len(flat), 3)]
        for i, p in enumerate(triples):
            if not all(math.isfinite(v) for v in p):
                raise BuildError(f"{call}: {name} point {i} is not finite")
        out.append(triples)
    return out[0], out[1]


def closest_points(hay: "Iterable[Point3] | numpy.ndarray", needles: "Iterable[Point3] | numpy.ndarray",
                   limit: float) -> "list[list[int]]":
    """For each needle, the indices of the `hay` points within `limit` of it, by distance then
    index -- one `RTree` over `hay` answers every needle. Raises `BuildError` for a `limit`
    negative or NaN, then the first hay point and the first needle not finite, by index."""
    limit = _rtree_real(limit, "closest_points", "limit")
    if not limit >= 0.0:
        raise BuildError(f"closest_points: limit {_rust_number(limit)} is not a distance")
    hay_points, points = _point_triples("closest_points", hay, needles)
    with RTree.from_points(hay_points) as tree:
        return [[i for i, _ in tree.within(p, limit)] for p in points]


def k_neighbors(hay: "Iterable[Point3] | numpy.ndarray", needles: "Iterable[Point3] | numpy.ndarray",
                k: int) -> "list[list[int]]":
    """For each needle, the indices of the `k` nearest `hay` points, by distance then index (all
    of them when `k` is over the hay count). Raises `BuildError` for the first hay point and the
    first needle not finite, by index, then a `k` that is not a whole number from 0 to 1 000 000
    (the C ABI's cap)."""
    hay_points, points = _point_triples("k_neighbors", hay, needles)
    k = _rtree_u32(k, "k_neighbors", "k")
    if k > 1_000_000:
        raise BuildError(f"k_neighbors: k {k} is not at most 1000000")
    with RTree.from_points(hay_points) as tree:
        return [[i for i, _ in tree.nearest(p, k)] for p in points]


_SUBD_AXES = {"x": 0, "y": 1, "z": 2}
_SUBD_KINDS = {"vertices": 0, "edges": 1, "faces": 2}
_SUBD_PICKS = {"vertex": 0, "edge": 1, "face": 2}


def _u32(value, what: str) -> int:
    """A count or an id as the C ABI reads it (a whole number, 0 to 4294967295), refused
    here, named, rather than wrapped by ctypes."""
    try:
        k = operator.index(value)
    except TypeError:
        raise TypeError(f"{what} must be a whole number, not {value!r}") from None
    if not 0 <= k <= 0xFFFFFFFF:
        raise ValueError(f"{what} is out of range: {k}")
    return k


def _subd_axis(axis, what: str) -> int:
    if not isinstance(axis, str) or axis.lower() not in _SUBD_AXES:
        raise BuildError(f"{what}: axis must be 'x', 'y' or 'z', not {axis!r}")
    return _SUBD_AXES[axis.lower()]


def _subd_pairs(value, call: str, param: str) -> "list[int]":
    """A list of (a, b) vertex pairs -- edges -- as the flat ids the C ABI reads."""
    if isinstance(value, (str, bytes, numbers.Number)) or not hasattr(value, "__iter__"):
        raise TypeError(f"{call}: {param} must be a list of (a, b) vertex pairs, not {value!r}")
    flat = []
    for i, pair in enumerate(value):
        try:
            a, b = pair
        except (TypeError, ValueError):
            raise TypeError(f"{call}: {param}[{i}] is not an (a, b) vertex pair: {pair!r}") from None
        flat.append(_u32(a, f"{call}: {param}[{i}][0]"))
        flat.append(_u32(b, f"{call}: {param}[{i}][1]"))
    return flat


def _subd_array(ctype, values):
    """`values` as a C array, an empty one where there are none: the C ABI reads a zero
    count as no ids whatever the pointer, and the wasm export takes a typed array, which
    a null is not."""
    return (ctype * len(values))(*values)


def _subd_matrix(matrix):
    """Sixteen numbers column-major, as the C ABI reads them, or a 4x4 (nested lists or a
    numpy array), which is row-major as the rest of this wrapper takes a 4x4. Any other
    nesting is refused here, naming the matrix, rather than failing inside `float()`."""
    flat = [list(row) if hasattr(row, "__iter__") else row for row in matrix]
    nested = [isinstance(row, list) for row in flat]
    if any(nested):
        if len(flat) != 4 or not all(nested) or any(len(row) != 4 for row in flat):
            shape = [len(row) if isinstance(row, list) else 1 for row in flat]
            raise BuildError(f"transform: a nested matrix must be 4x4 (four rows of four numbers), not rows of {shape}")
        return _doubles([flat[r][c] for c in range(4) for r in range(4)], 16, "transform matrix")
    return _doubles(flat, 16, "transform matrix")


def _nothing_near(lib) -> bool:
    """Whether the `false` a call just returned means "nothing near" rather than a refusal:
    the C ABI then leaves an **empty** `last_error`, and a refusal's text is never empty.
    Over ctypes that reads back as `b""`. The wasm shim keeps its `_error` as `None` (no
    call failed) or a `str` (the thrown message, or `""` where `subd_pick`'s export
    returned null), and its `last_error` encodes any `str`, the empty one included, so
    both backends answer `b""` here. A JS error thrown with an empty message would read as
    nothing near too, but the ABI's refusals always carry text."""
    error = lib.cadaclysm_blacksmith_last_error()
    return error is not None and len(error) == 0


def _owned(pointer, shape, dtype):
    """A numpy array of memory of its own, copied out of a view into a handle: the caller
    keeps it after the handle closes, and may write to it."""
    return _numpy().array(_view(None, pointer, shape, dtype))


# ---- the document: a node graph of constructive verbs, with parameters and a history ----


def _owned_text(raw, what: str) -> str:
    """Owned text a `document_*` call returned: read and freed (null: raise the library's
    reason). Under Pyodide the wasm returns the string itself, with nothing to free."""
    if not raw:
        _fail(what)
    if _WASM:
        return raw
    try:
        return ctypes.string_at(raw).decode("utf-8")
    finally:
        _lib().cadaclysm_blacksmith_string_free(raw)


def _json_default(value: object) -> object:
    """`json.dumps` for what a field may hold beyond JSON's own: a tuple is a list already,
    numpy's arrays and scalars are theirs by `tolist`."""
    tolist = getattr(value, "tolist", None)
    if callable(tolist):
        return tolist()
    raise TypeError(f"{type(value).__name__} is not JSON: give numbers, text, lists and dicts")


def _document_value(value: object) -> object:
    """A value as `Document.value` hands it over: numbers as floats, lists (points) as tuples,
    records as dicts of the same."""
    if isinstance(value, bool) or value is None or isinstance(value, str):
        return value
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, list):
        return tuple(_document_value(v) for v in value)
    if isinstance(value, dict):
        return {k: _document_value(v) for k, v in value.items()}
    return value


@dataclass(frozen=True)
class Commit:
    """One commit of a `Document`'s history: its `id` (`c0` is the root), its `parents` (ids),
    the `message` it was recorded with, its `author` and `time` (`None` when not set), and the
    `ops` it applied, each as the JSON dict that was sent."""

    id: str
    parents: "tuple[str, ...]" = ()
    message: "str | None" = None
    author: "str | None" = None
    time: "str | None" = None
    ops: "tuple[dict[str, Any], ...]" = ()

    @staticmethod
    def _of(row: "dict[str, Any]") -> "Commit":
        return Commit(str(row["id"]), tuple(row.get("parents") or ()), row.get("message"), row.get("author"),
                      row.get("time"), tuple(row.get("ops") or ()))


class _Params(_abc.MutableMapping):
    """`Document.params`: the document's parameters as a mapping. Reading asks the document;
    assigning sends a `param` op (one commit), and deleting one with a null value."""

    def __init__(self, document: "Document") -> None:
        self._document = document

    def _read(self) -> "dict[str, Any]":
        return json.loads(self._document._text("params", lambda lib, h: lib.cadaclysm_blacksmith_document_params(h)))

    def __getitem__(self, name: str) -> "Any":
        return self._read()[name]

    def __setitem__(self, name: str, value: "Any") -> None:
        if value is None:
            raise ValueError("a parameter cannot be None: delete it instead")
        self._document.apply({"op": "param", "name": name, "value": value})

    def __delitem__(self, name: str) -> None:
        if name not in self._read():
            raise KeyError(name)
        self._document.apply({"op": "param", "name": name, "value": None})

    def __iter__(self) -> "Iterator[str]":
        return iter(self._read())

    def __len__(self) -> int:
        return len(self._read())

    def __repr__(self) -> str:
        return f"Document.params({self._read()!r})"


class Document:
    """A model as data: a graph of nodes (`profile.rect`, `solid.extrude`, `measure.mass`, ...),
    each a blacksmith verb reading other nodes by id, with named parameters any number can be
    an `"=expression"` of, evaluated incrementally, and edited by ops that are undoable and
    branch. Every edit is one commit; the whole thing -- nodes, parameters, history, branches --
    saves as JSON text and loads back to the same document. `Document.kinds()` lists the node
    kinds.

        doc = Document(units="mm")
        doc.params["w"] = 200
        r = doc.add("profile.rect", w="=w", h=100)
        x = doc.add("solid.extrude", profile=r, frame="xy", distance=10)
        solid = doc.result(x)               # a Solid
        doc.set(x, distance=80, message="taller")
        doc.undo()

    A refused op raises `BuildError` with the reason, and the document is unchanged.
    `result`, `value`, `errors` and `evaluate` bring the nodes up to date first, so the answer
    is always the current document's. `close()` frees the document; so does leaving a `with`
    block or the garbage collector. One thread at a time."""

    __slots__ = ("_handle", "__weakref__")

    def __init__(self, units: str = "mm") -> None:
        """An empty document counting lengths in `units` (`mm`, `cm`, `m`, `in` or `ft`)."""
        self._handle = None
        self._handle = _checked(_lib().cadaclysm_blacksmith_document_new(units.encode("utf-8")), "document_new")

    @classmethod
    def load(cls, text: str) -> "Document":
        """The document `save` wrote as `text`: its nodes, parameters, history and branches."""
        doc = cls.__new__(cls)
        doc._handle = None
        doc._handle = _checked(_lib().cadaclysm_blacksmith_document_load(text.encode("utf-8")), "document_load")
        return doc

    @classmethod
    def open(cls, path: FilePath) -> "Document":
        """The document saved in the file `path`."""
        with open(path, encoding="utf-8", newline="") as f:
            return cls.load(f.read())

    @staticmethod
    def kinds() -> "list[dict[str, Any]]":
        """Every node kind the library knows, one dict a kind (`name`, `inputs`, `output`,
        `cost`, `help`)."""
        return json.loads(_owned_text(_lib().cadaclysm_blacksmith_document_kinds(), "document_kinds"))

    # -- building documents
    @classmethod
    def new_bim(cls, units: str = "mm") -> "Document":
        """An empty building document: the blacksmith kinds and the `bim.*` ones, with a
        `bim.project` node whose guid seeds every IFC GlobalId it exports."""
        doc = cls.__new__(cls)
        doc._handle = None
        doc._handle = _checked(_lib().cadaclysm_bim_document_new(units.encode("utf-8")), "bim_document_new")
        if _WASM:
            # The wasm's `_new` is the editor's, whose starter batch adds the project; the C
            # one adds it itself. Here it is added as C adds it: hidden, one commit.
            import uuid
            doc.apply({"op": "add", "node": {"id": "project", "kind": "bim.project", "hidden": True,
                                             "guid": str(uuid.uuid4())}}, "ifc project")
        return doc

    @classmethod
    def load_bim(cls, text: str) -> "Document":
        """A saved building document, opened with the `bim.*` kinds."""
        doc = cls.__new__(cls)
        doc._handle = None
        doc._handle = _checked(_lib().cadaclysm_bim_document_load(text.encode("utf-8")), "bim_document_load")
        return doc

    @classmethod
    def open_bim(cls, path: FilePath) -> "Document":
        """The building document saved in the file `path`."""
        with open(path, encoding="utf-8", newline="") as f:
            return cls.load_bim(f.read())

    @staticmethod
    def bim_kinds() -> "list[dict[str, Any]]":
        """Every node kind a building document knows: the blacksmith's and the `bim.*` ones."""
        return json.loads(_owned_text(_lib().cadaclysm_bim_kinds(), "bim_kinds"))

    # -- bench documents
    @staticmethod
    def parts_catalog(directory: FilePath) -> None:
        """Load the parts catalogue `parts.catalog` nodes build from: a directory holding its
        `index.json` and family files (the robot bench's `catalog/`). Replaces the one loaded."""
        _native("Document.parts_catalog")
        if not _lib().cadaclysm_parts_catalog_load(str(directory).encode("utf-8")):
            _fail("parts_catalog_load")

    @classmethod
    def new_parts(cls) -> "Document":
        """An empty bench document, in mm: the blacksmith kinds (`assembly.*` among them) and
        `parts.catalog`, a catalogue part by its entry and parameters."""
        doc = cls.__new__(cls)
        doc._handle = None
        _native("Document.new_parts")
        doc._handle = _checked(_lib().cadaclysm_parts_document_new(), "parts_document_new")
        return doc

    @classmethod
    def load_parts(cls, text: str) -> "Document":
        """A saved bench document (the robot bench's file), opened with the `parts.*` kinds."""
        doc = cls.__new__(cls)
        doc._handle = None
        _native("Document.load_parts")
        doc._handle = _checked(_lib().cadaclysm_parts_document_load(text.encode("utf-8")), "parts_document_load")
        return doc

    @classmethod
    def open_parts(cls, path: FilePath) -> "Document":
        """The bench document saved in the file `path`."""
        with open(path, encoding="utf-8", newline="") as f:
            return cls.load_parts(f.read())

    @staticmethod
    def parts_kinds() -> "list[dict[str, Any]]":
        """Every node kind a bench document knows: the blacksmith's and the `parts.*` ones."""
        _native("Document.parts_kinds")
        return json.loads(_owned_text(_lib().cadaclysm_parts_kinds(), "parts_kinds"))

    def export_ifc(self, path: "FilePath | None" = None, *, schema: str = "IFC4", geometry: str = "parametric",
                   timestamp: "int | None" = None, name: str = "") -> str:
        """The building as IFC text (`schema` "IFC4" or "IFC2X3", `geometry` "parametric" or
        "exact"); with `path`, also written to that file. `timestamp` (Unix seconds) defaults to
        now. A refused export raises `BuildError` with one reason a line; its `refusals` is a
        list of `(node, reason)`, `node` None for a reason on the whole document. A refusal
        writes no file."""
        options = json.dumps({"schema": schema, "geometry": geometry,
                              "timestamp": int(time.time()) if timestamp is None else timestamp, "name": name})
        try:
            text = _owned_text(_lib().cadaclysm_bim_document_export_ifc(self._h(), options.encode("utf-8")),
                               "bim_document_export_ifc")
        except BuildError as e:
            message = str(e)
            start = message.find('{"refusals"')
            if start < 0:
                raise
            refusals = [(r.get("node"), r["reason"]) for r in json.loads(message[start:])["refusals"]]
            err = BuildError("\n".join(f"{n}: {r}" if n else r for n, r in refusals))
            err.refusals = refusals
            raise err from None
        if path is not None:
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(text)
        return text

    def sheet_svg(self, sheet: str, path: "FilePath | None" = None) -> str:
        """Sheet `sheet` (a `bim.sheet` node's id) as SVG text sized in paper millimetres: its
        frame, title block and viewports (plans, sections, elevations, schedules and 3D views;
        a 3D view is drawn as a box reading "3D view not rendered", since the picture comes from the web editor's renderer). The document
        is evaluated first if it is not. With `path`, also written to that file. A node that is
        missing, not a sheet, or a sheet that did not build raises `BuildError`."""
        text = _owned_text(_lib().cadaclysm_bim_sheet_svg(self._h(), sheet.encode("utf-8")), "bim_sheet_svg")
        if path is not None:
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(text)
        return text

    def sheet_pdf(self, sheet: str, path: "FilePath | None" = None) -> bytes:
        """Sheet `sheet` (a `bim.sheet` node's id) as a one-page PDF the size of its paper, with
        a bookmark naming it ("A-101 Plans"). A 3D view is drawn as a box reading "3D view not
        rendered", since the picture comes from the web editor's renderer. The document is
        evaluated first if it is not. With
        `path`, also written to that file. A node that is missing, not a sheet, or a sheet that
        did not build raises `BuildError`."""
        length = c_size_t(0)
        raw = _lib().cadaclysm_bim_sheet_pdf(self._h(), sheet.encode("utf-8"), ctypes.byref(length))
        return _written(_taken_bytes(raw, length, "bim_sheet_pdf"), path)

    def sheets_pdf(self, sheets: "Sequence[str]", path: "FilePath | None" = None) -> bytes:
        """Sheets `sheets` (ids) as one PDF: a page each in the order given, each its paper's
        size, a bookmark a page. A 3D view is drawn as a box reading "3D view not rendered", since
        the picture comes from the web editor's renderer. With `path`, also written to that file. An empty list, or any
        sheet `sheet_pdf` would refuse, raises `BuildError`. A single id (a `str`) raises
        `TypeError`: use `sheet_pdf`."""
        if isinstance(sheets, str):
            raise TypeError("sheets_pdf takes a list of sheet ids, not one id: use sheet_pdf")
        length = c_size_t(0)
        raw = _lib().cadaclysm_bim_sheets_pdf(self._h(), json.dumps(list(sheets)).encode("utf-8"), ctypes.byref(length))
        return _written(_taken_bytes(raw, length, "bim_sheets_pdf"), path)

    def __enter__(self) -> "Document":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()

    def close(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_document_free(h)

    def _h(self):
        if not self._handle:
            raise BuildError("document: closed")
        return self._handle

    def _text(self, what: str, call: "Callable[[Any, Any], Any]") -> str:
        """`call(lib, handle)`'s owned text, read and freed (null: raise the library's reason)."""
        return _owned_text(call(_lib(), self._h()), "document_" + what)

    def _json(self, what: str, call: "Callable[[Any, Any], Any]") -> "Any":
        return json.loads(self._text(what, call))

    def __repr__(self) -> str:
        if not self._handle:
            return "Document(closed)"
        return f"Document(branch={self.branch!r}, head={self.head.id!r})"

    # -- saving
    def save(self, path: "FilePath | None" = None) -> str:
        """The document as JSON text; with `path`, also written to that file."""
        text = self._text("save", lambda lib, h: lib.cadaclysm_blacksmith_document_save(h))
        if path is not None:
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(text)
        return text

    # -- editing
    @staticmethod
    def _message(message: "str | None") -> "bytes | None":
        return message.encode("utf-8") if message else None

    def apply(self, op: "str | dict[str, Any]", message: "str | None" = None) -> "dict[str, Any]":
        """Applies one op (a JSON dict, or its text: `{"op": "add", "node": {...}}`, `set`,
        `remove`, `rename`, `param`) and records it as one commit with `message`. The changed
        set, `{"added": [ids], "changed": [ids], "removed": [ids], "params": [names]}`."""
        text = op if isinstance(op, str) else json.dumps(op, default=_json_default)
        return self._json("apply", lambda lib, h: lib.cadaclysm_blacksmith_document_apply(
            h, text.encode("utf-8"), self._message(message)))

    def add(self, kind: str, **fields: "Any") -> str:
        """A new node of `kind` (`"profile.rect"`) with `fields` (`w=10`, `h="=w"`, `profile="r1"`
        to read another node), one commit. Its id is made up unless `id=` gives one; it is
        returned. `message=` is the commit's message, not a field."""
        message = fields.pop("message", None)
        changed = self.apply({"op": "add", "node": {"kind": kind, **fields}}, message)
        return changed["added"][0]

    def add_solid(self, solid: "Solid", sheet: bool = False, **fields: "Any") -> str:
        """A node holding `solid` exactly as it is -- one made in code or read from a file -- for
        other nodes to read like any built one: a `solid.body` (a `sheet.body` with `sheet=True`)
        carrying the kernel's own B-rep (`Solid.document_body()`), in this document's units.
        Fillets and other references are taken off it as off any node; replacing its body later
        (`set(id, body=other.document_body())`) re-finds them by geometry. Its id is returned;
        `id=`, `name=` and `message=` as for `add`. Its colours are kept -- the solid's, each
        face's and each edge's -- its name is not."""
        return self.add("sheet.body" if sheet else "solid.body", body=solid.document_body(), **fields)

    def add_profile(self, profile: "Profile", **fields: "Any") -> str:
        """A `profile.path` node holding `profile` exactly (`Profile.document_path()`: arcs and NURBS
        as they are, holes included, its colour kept), in this document's units. Its id is returned; `id=`,
        `name=` and `message=` as for `add`."""
        return self.add("profile.path", path=profile.document_path(), **fields)

    def set(self, id: str, **fields: "Any") -> "dict[str, Any]":
        """Sets `fields` of node `id`, one commit; returns the changed set. `message=` is the
        commit's message, not a field."""
        message = fields.pop("message", None)
        return self.apply({"op": "set", "id": id, "fields": fields}, message)

    def remove(self, id: str, cascade: bool = False, message: "str | None" = None) -> "dict[str, Any]":
        """Removes node `id`. Refused while another node reads it, unless `cascade` takes those
        with it."""
        op: "dict[str, Any]" = {"op": "remove", "id": id}
        if cascade:
            op["cascade"] = True
        return self.apply(op, message)

    def rename(self, id: str, name: "str | None", message: "str | None" = None) -> "dict[str, Any]":
        """Gives node `id` the display name `name` (`None` clears it)."""
        return self.apply({"op": "rename", "id": id, "name": name}, message)

    @property
    def params(self) -> "MutableMapping[str, Any]":
        """The parameters, name to value (a number, or an `"=expression"`): a mutable mapping.
        `doc.params["w"] = 200` is a `param` op, one commit; `del doc.params["w"]` removes it."""
        return _Params(self)

    @contextlib.contextmanager
    def batch(self, message: "str | None" = None) -> "Iterator[None]":
        """`with doc.batch("slot and fillet"):` -- the ops inside apply live and are recorded as
        one commit with `message`. An exception inside rolls every op of the batch back and
        propagates."""
        if not _lib().cadaclysm_blacksmith_document_batch_begin(self._h(), self._message(message)):
            _fail("document_batch_begin")
        try:
            yield
        except BaseException:
            try:
                self._text("batch_abort", lambda lib, h: lib.cadaclysm_blacksmith_document_batch_abort(h))
            except BuildError:
                pass   # the body's own exception is the one to report, not a failed clean-up
            raise
        self._text("batch_end", lambda lib, h: lib.cadaclysm_blacksmith_document_batch_end(h))

    @contextlib.contextmanager
    def preview(self) -> "Iterator[None]":
        """`with doc.preview():` -- the ops inside are applied (and evaluate) but never recorded,
        and are taken back on leaving, normally or by an exception: a drag, a what-if."""
        if not _lib().cadaclysm_blacksmith_document_preview_begin(self._h()):
            _fail("document_preview_begin")
        try:
            yield
        except BaseException:
            try:
                self._text("end_preview", lambda lib, h: lib.cadaclysm_blacksmith_document_end_preview(h))
            except BuildError:
                pass   # the body's own exception is the one to report, not a failed clean-up
            raise
        self._text("end_preview", lambda lib, h: lib.cadaclysm_blacksmith_document_end_preview(h))

    # -- history
    def undo(self) -> bool:
        """Takes back the head commit. False when there was nothing to take back."""
        text = self._text("undo", lambda lib, h: lib.cadaclysm_blacksmith_document_undo(h))
        return text.strip() != "null"

    def redo(self) -> bool:
        """Puts back the commit `undo` took back. False when there was nothing to put back."""
        text = self._text("redo", lambda lib, h: lib.cadaclysm_blacksmith_document_redo(h))
        return text.strip() != "null"

    def _branch_list(self) -> "dict[str, Any]":
        return self._json("branch_list", lambda lib, h: lib.cadaclysm_blacksmith_document_branch_list(h))

    @property
    def can_undo(self) -> bool:
        """Whether `undo` has a commit to take back."""
        return bool(self._branch_list()["can_undo"])

    @property
    def can_redo(self) -> bool:
        """Whether `redo` has a commit to put back."""
        return bool(self._branch_list()["can_redo"])

    @property
    def branch(self) -> "str | None":
        """The current branch's name, or `None` when the head is detached (switched to a commit id)."""
        return self._branch_list()["branch"]

    @property
    def branches(self) -> "dict[str, str]":
        """Every branch, name to the id of its tip commit."""
        return dict(self._branch_list()["branches"])

    def branch_new(self, name: str, at: "str | None" = None) -> None:
        """A new branch `name`. Without `at` it starts at the head and the document switches onto
        it; with `at` (a commit id) it starts there."""
        self._text("branch_new", lambda lib, h: lib.cadaclysm_blacksmith_document_branch_new(
            h, name.encode("utf-8"), at.encode("utf-8") if at else None))

    def switch(self, name_or_commit_id: str) -> None:
        """Moves the head to the branch of that name, else to the commit of that id (which
        detaches the head: `branch` is then `None`). The nodes follow."""
        self._text("branch_switch", lambda lib, h: lib.cadaclysm_blacksmith_document_branch_switch(
            h, name_or_commit_id.encode("utf-8")))

    def branch_rename(self, old: str, new: str) -> None:
        """Renames branch `old` to `new`; refused when `old` is missing or `new` is taken."""
        if not _lib().cadaclysm_blacksmith_document_branch_rename(self._h(), old.encode("utf-8"), new.encode("utf-8")):
            _fail("document_branch_rename")

    def branch_delete(self, name: str) -> None:
        """Deletes branch `name`; the current branch is refused. Its commits stay, as tips."""
        if not _lib().cadaclysm_blacksmith_document_branch_delete(self._h(), name.encode("utf-8")):
            _fail("document_branch_delete")

    def tips(self) -> "list[Commit]":
        """The tips of the lines no branch names -- what an undo followed by an edit leaves
        behind -- each as a whole `Commit`."""
        rows = self._json("tips", lambda lib, h: lib.cadaclysm_blacksmith_document_tips(h))
        return [Commit._of(row) for row in rows]

    def log(self, branch: "str | None" = None) -> "list[Commit]":
        """The commits of `branch`'s line, newest first, the root `c0` last; `None` is the line
        from the head back to the root."""
        rows = self._json("log", lambda lib, h: lib.cadaclysm_blacksmith_document_log(
            h, branch.encode("utf-8") if branch else None))
        return [Commit._of(row) for row in rows]

    @property
    def head(self) -> Commit:
        """The commit the document is at."""
        return self.log()[0]

    # -- evaluating and reading back
    def evaluate(self, cheap_only: bool = False) -> "list[dict[str, Any]]":
        """Evaluates the nodes that are stale (only the cheap kinds with `cheap_only`); the
        status of every node, `{"id", "state": "ok"|"error"|"blocked"|"pending", ...}`."""
        return self._json("evaluate", lambda lib, h: lib.cadaclysm_blacksmith_document_evaluate(h, bool(cheap_only)))

    def evaluate_with(self, progress: "Callable[[str, str, int, int], None] | None", cheap_only: bool = False) -> "list[dict[str, Any]]":
        """`evaluate`, every kernel call's progress heard by `progress(node, phase, done,
        total)`: `node` the id of the node being built (a progress bar, or a note of which node
        was being built when the process died). The same statuses; a cheap-only pass reports
        nothing. `progress` runs on this thread, often, and must not touch the document."""
        if _WASM:
            cb = progress   # the wasm takes the Python callable itself
        elif progress is None:
            cb = _DOCUMENT_PROGRESS()
        else:
            def trampoline(node, phase, done, total, _user):
                progress(_text(node), _text(phase), done, total)
            cb = _DOCUMENT_PROGRESS(trampoline)   # alive in this frame for the call
        return self._json("evaluate_with", lambda lib, h: lib.cadaclysm_blacksmith_document_evaluate_with(h, bool(cheap_only), cb, None))

    def errors(self) -> "list[dict[str, Any]]":
        """The nodes the evaluation left in error or blocked, `{"id", "state", "message"}`."""
        self.evaluate()
        return self._json("errors", lambda lib, h: lib.cadaclysm_blacksmith_document_errors(h))

    def value(self, id: str) -> "Any":
        """Node `id`'s value: a float for a number, a tuple for a point or a list, a dict for a
        record, text as is. Raises `BuildError` for a node with none (missing, or in error)."""
        self.evaluate()
        return self._value(id)

    def _value(self, id: str) -> "Any":
        text = self._text("value", lambda lib, h: lib.cadaclysm_blacksmith_document_value(h, id.encode("utf-8")))
        return _document_value(json.loads(text))

    def result(self, id: str) -> "Any":
        """What node `id` evaluated to, by its kind: a `Solid` (solids and sheets), a `Profile`,
        a list of `Profile`, a `NurbsCurve`, a `Subd`, a list of these (a node laced over a list,
        each item also readable as `id#i`), or the `value` of a number, point, record, list and
        the like; `None` for no such node or one that failed. Each handle is the caller's own
        and outlives later edits."""
        self.evaluate()
        lib, h, key = _lib(), self._h(), id.encode("utf-8")
        kind = self._text("result_kind", lambda lib, h: lib.cadaclysm_blacksmith_document_result_kind(h, key))
        if kind in ("solid", "sheet"):
            return Solid(lib.cadaclysm_blacksmith_document_result_solid(h, key))
        if kind == "profile":
            return Profile(lib.cadaclysm_blacksmith_document_result_profile(h, key))
        if kind == "profiles":
            count = lib.cadaclysm_blacksmith_document_result_profile_count(h, key)
            if count == NONE:
                _fail("document_result_profile_count")
            return [Profile(lib.cadaclysm_blacksmith_document_result_profile_at(h, key, i)) for i in range(count)]
        if kind == "nurbs":
            return NurbsCurve._of(lib.cadaclysm_blacksmith_document_result_nurbs_curve(h, key), "document_result_nurbs_curve")
        if kind == "subd":
            return Subd(lib.cadaclysm_blacksmith_document_result_subd(h, key))
        if kind in ("value", "curve"):   # a plane curve has no handle: its value is `{"type": "curve", "closed": ...}`
            return self._value(id)
        if kind == "list":   # a laced node's: each item read as its own result, `id#0`, `id#1`, ...
            count = len(json.loads(self._text("value", lambda lib, h: lib.cadaclysm_blacksmith_document_value(h, key))))
            return [self.result(f"{id}#{i}") for i in range(count)]
        return None


class SubdMesh:
    """One level of a cage's smooth surface, as `Subd.smooth_mesh` returns it, copied out of
    the cage so it outlives it. `positions` and `normals` are (n, 3) float64 -- limit
    positions and unit outward limit normals; `indices` is (m, 3) uint32, three vertex ids a
    triangle; `triangle_face` is (m,) uint32, the face of the **full** cage each triangle lies
    on (on a mirrored half, face `f` of the half is `f` and its reflection `f + len(faces)`)."""

    __slots__ = ("positions", "normals", "indices", "triangle_face")

    def __init__(self, raw: _SubdMesh):
        n, m = raw.vertex_count, raw.index_count // 3
        self.positions = _owned(raw.positions, (n, 3), "float64")
        self.normals = _owned(raw.normals, (n, 3), "float64")
        self.indices = _owned(raw.indices, (m, 3), "uint32")
        self.triangle_face = _owned(raw.triangle_face, (m,), "uint32")

    def __repr__(self) -> str:
        return f"SubdMesh(vertices={len(self.positions)}, triangles={len(self.indices)})"


class SubdReport:
    """What `Subd.to_solid` did and how close it came: `regular` patches exact from their own
    net and `refined` ones from a refined neighbourhood; the Catmull-Clark `steps` taken first
    (1 or 2); `levels`, the deepest local refinement a patch took (0 when none was refined);
    the largest `deviation` from the limit surface, as a fraction of the cage's bounding-box
    diagonal; the largest tangent break `g1_angle_deg` across a side that is not creased, in
    degrees; and the world points they were measured at, `deviation_at` and `g1_at`."""

    __slots__ = ("regular", "refined", "steps", "levels", "deviation", "g1_angle_deg", "deviation_at", "g1_at")

    def __init__(self, raw: _SubdReport):
        self.regular, self.refined, self.steps, self.levels = raw.regular, raw.refined, raw.steps, raw.levels
        self.deviation, self.g1_angle_deg = raw.deviation, raw.g1_angle_deg
        self.deviation_at, self.g1_at = tuple(raw.deviation_at), tuple(raw.g1_at)

    def __repr__(self) -> str:
        return "SubdReport(" + ", ".join(f"{name}={getattr(self, name)!r}" for name in self.__slots__) + ")"


class Subd:
    """A Catmull-Clark control cage: positions, faces, creased edges, pinned vertices, an
    optional mirror plane, and the selection of the edit that made it. Immutable: every edit
    returns a new `Subd`, with `selection` naming what that edit touched. `to_solid` turns it
    into an exact B-rep. `close()` frees this handle; so does leaving a `with` block or the
    garbage collector. A refusal raises `BuildError` with the kernel's own words."""

    __slots__ = ("_handle", "__weakref__")

    def __init__(self, handle: int | None):
        self._handle = _checked(handle, "subd")

    def __enter__(self) -> "Subd":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()

    def close(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_subd_free(h)

    def _h(self):
        if not self._handle:
            raise BuildError("subd: closed")
        return self._handle

    # -- the primitives
    @classmethod
    def cuboid(cls, size: Sequence[float] = (2.0, 2.0, 2.0), segments: Sequence[int] = (1, 1, 1)) -> "Subd":
        """A box of `size` (x, y, z), centred on the origin, with `segments` quads along
        each axis (1 to 1024)."""
        sx, sy, sz = _doubles(size, 3, "cuboid size")
        counts = _indices(segments, "cuboid", "segments")
        if len(counts) != 3:
            raise BuildError(f"cuboid segments: expected 3 numbers, got {len(counts)}")
        nx, ny, nz = counts
        return cls(_lib().cadaclysm_blacksmith_subd_cuboid(sx, sy, sz, nx, ny, nz))

    @classmethod
    def cylinder(cls, radius: float = 1.0, height: float = 2.0, sides: int = 8, rings: int = 1,
                 creased_rims: bool = True) -> "Subd":
        """A cylinder along +Z: one n-gon cap per end with `sides` sides and `rings` bands of
        quads between them; with `creased_rims` the two rim loops are creased, so the caps
        stay flat. The rims are creased by default, which is what converts: an uncreased
        cylinder of 7 or more sides is refused by `to_solid` at the default tolerances."""
        return cls(_lib().cadaclysm_blacksmith_subd_cylinder(
            radius, height, _u32(sides, "cylinder sides"), _u32(rings, "cylinder rings"), bool(creased_rims)))

    @classmethod
    def sphere(cls, radius: float = 1.0, segments: int = 2) -> "Subd":
        """A quad ball of `radius`: a cube grid with `segments` quads per edge, each vertex
        pushed out to the radius."""
        return cls(_lib().cadaclysm_blacksmith_subd_sphere(radius, _u32(segments, "sphere segments")))

    @classmethod
    def torus(cls, major: float = 3.0, minor: float = 1.0, around: int = 12, tube: int = 8) -> "Subd":
        """A torus around +Z: `around` steps about the axis at `major`, `tube` steps round the
        tube of `minor`, all quads."""
        return cls(_lib().cadaclysm_blacksmith_subd_torus(
            major, minor, _u32(around, "torus around"), _u32(tube, "torus tube")))

    @classmethod
    def from_parts(cls, positions: "Sequence[Sequence[float]] | numpy.ndarray", faces: "Sequence[Sequence[int]]",
                   creases: "Iterable[tuple[int, int]]" = (), pins: Iterable[int] = (),
                   symmetry: "tuple[str, float] | None" = None) -> "Subd":
        """A cage from its parts, the lossless inverse of reading them back: `positions` (n, 3),
        `faces` lists of vertex ids, `creases` (a, b) pairs that are edges, `pins` vertex ids,
        and `symmetry` None or ("x" | "y" | "z", tolerance) for a mirrored half, as `symmetry`
        reports it. The new cage selects nothing."""
        numpy = _numpy()
        points = numpy.asarray(positions, dtype=float)
        if points.ndim != 2 or points.shape[1] != 3:
            raise BuildError(f"from_parts: positions must be (n, 3), not shape {tuple(points.shape)}")
        flat_points = [float(v) for v in points.reshape(-1)]
        sizes, loop = [], []
        for i, face in enumerate(faces):
            ids = _indices(face, "from_parts", f"faces[{i}]")
            sizes.append(len(ids))
            loop.extend(ids)
        crease_ids = _subd_pairs(creases, "from_parts", "creases")
        pin_ids = _indices(pins, "from_parts", "pins")
        if symmetry is None:
            axis, tolerance = -1, 0.0
        else:
            axis_name, tolerance = symmetry
            axis = _subd_axis(axis_name, "from_parts symmetry")
            tolerance = float(tolerance)
        return cls(_lib().cadaclysm_blacksmith_subd_from_parts(
            _subd_array(c_double, flat_points), len(points),
            _subd_array(c_uint32, sizes), len(sizes),
            _subd_array(c_uint32, loop), len(loop),
            _subd_array(c_uint32, crease_ids), len(crease_ids) // 2,
            _subd_array(c_uint32, pin_ids), len(pin_ids),
            axis, tolerance))

    # -- the parts
    def _parts(self, read):
        """`read(parts)` over this cage's parts while their views are alive."""
        out = _SubdParts()
        _ok(_lib().cadaclysm_blacksmith_subd_parts(self._h(), ctypes.byref(out)), "subd_parts")
        return read(out)

    @property
    def positions(self) -> "numpy.ndarray":
        """The cage's vertices, an (n, 3) float64 array of your own: a copy."""
        return self._parts(lambda p: _owned(p.positions, (p.vertex_count, 3), "float64"))

    @property
    def faces(self) -> "list[list[int]]":
        """Each face's vertex ids, in loop order."""
        def read(p):
            sizes = p.face_sizes[:p.face_count] if p.face_count else []
            loop = p.face_indices[:p.index_count] if p.index_count else []
            faces, at = [], 0
            for size in sizes:
                faces.append(list(loop[at:at + size]))
                at += size
            return faces
        return self._parts(read)

    @property
    def creases(self) -> "list[tuple[int, int]]":
        """The creased edges, each (smaller id, larger id), sorted."""
        def read(p):
            ids = p.creases[:2 * p.crease_count] if p.crease_count else []
            return [(ids[i], ids[i + 1]) for i in range(0, len(ids), 2)]
        return self._parts(read)

    @property
    def pins(self) -> "list[int]":
        """The pinned vertices: they refine as corners and stay put."""
        return self._parts(lambda p: list(p.pins[:p.pin_count]) if p.pin_count else [])

    @property
    def symmetry(self) -> "tuple[str, float] | None":
        """None for an ordinary cage; for a mirrored half ("x" | "y" | "z", tolerance): the
        plane's axis and how far from it a vertex counts as on it."""
        def read(p):
            return None if p.symmetry_axis < 0 else ("xyz"[p.symmetry_axis], p.symmetry_tolerance)
        return self._parts(read)

    @property
    def selection(self) -> "tuple[str, list] | None":
        """What the edit that made this cage touched: ("vertices" | "faces", ids) or
        ("edges", [(a, b), ...]); None for a cage no edit selected (a primitive, `from_parts`,
        the mirror calls)."""
        def read(p):
            if p.selection_kind > 2:
                return None
            n = p.selection_count
            if p.selection_kind == 1:
                ids = p.selection[:2 * n] if n else []
                return ("edges", [(ids[i], ids[i + 1]) for i in range(0, len(ids), 2)])
            return (("vertices", "faces")[p.selection_kind // 2], list(p.selection[:n]) if n else [])
        return self._parts(read)

    # -- the edits
    def _edit(self, make, what: str) -> "Subd":
        return Subd(_checked(make(), what))

    def _selected(self, selection, call: str):
        """(kind, ids array, element count) for a ("vertices" | "edges" | "faces", ids) selection."""
        try:
            name, ids = selection
        except (TypeError, ValueError):
            raise TypeError(f'{call}: selection must be ("vertices" | "edges" | "faces", ids), not {selection!r}') from None
        if name not in _SUBD_KINDS:
            raise BuildError(f"{call}: kind must be 'vertices', 'edges' or 'faces', not {name!r}")
        flat = _subd_pairs(ids, call, "selection ids") if name == "edges" else _indices(ids, call, "selection ids")
        return _SUBD_KINDS[name], _subd_array(c_uint32, flat), len(flat) // (2 if name == "edges" else 1)

    def transform(self, selection: "tuple[str, Sequence]", matrix: "Sequence[float] | Sequence[Sequence[float]]") -> "Subd":
        """A new cage with the selected elements moved by `matrix`. `selection` is
        ("vertices" | "edges" | "faces", ids), edges as (a, b) pairs. `matrix` is sixteen
        numbers column-major, or a 4x4 (row-major, as the rest of this wrapper takes one); a
        rotation about a point is baked in by the caller. The new cage selects the same
        elements."""
        kind, ids, count = self._selected(selection, "transform")
        matrix = _subd_matrix(matrix)
        return self._edit(lambda: _lib().cadaclysm_blacksmith_subd_transform(self._h(), kind, ids, count, matrix), "subd_transform")

    def crease(self, edges: "Iterable[tuple[int, int]]", on: bool = True) -> "Subd":
        """A new cage with `edges` ((a, b) pairs) creased, or un-creased when `on` is False;
        it selects them."""
        flat = _subd_pairs(edges, "crease", "edges")
        return self._edit(lambda: _lib().cadaclysm_blacksmith_subd_set_crease(
            self._h(), _subd_array(c_uint32, flat), len(flat) // 2, bool(on)), "subd_set_crease")

    def pin(self, vertices: Iterable[int], on: bool = True) -> "Subd":
        """A new cage with `vertices` pinned (they refine as corners and stay put), or
        released when `on` is False; it selects them."""
        ids = _indices(vertices, "pin", "vertices")
        return self._edit(lambda: _lib().cadaclysm_blacksmith_subd_set_pin(
            self._h(), _subd_array(c_uint32, ids), len(ids), bool(on)), "subd_set_pin")

    def extrude(self, faces: Iterable[int], distance: float) -> "Subd":
        """A new cage with `faces` pushed out by `distance` along each connected region's
        average normal, a quad wall on each boundary edge; the moved faces keep their ids and
        the new cage selects them."""
        ids = _indices(faces, "extrude", "faces")
        return self._edit(lambda: _lib().cadaclysm_blacksmith_subd_extrude(
            self._h(), _subd_array(c_uint32, ids), len(ids), distance), "subd_extrude")

    def inset(self, faces: Iterable[int], amount: float, individual: bool = False) -> "Subd":
        """A new cage with `faces` shrunk by `amount`, in (0, 1), within their surface and a
        ring of quads round each region (each face, with `individual`); the new cage selects
        the inner faces."""
        ids = _indices(faces, "inset", "faces")
        return self._edit(lambda: _lib().cadaclysm_blacksmith_subd_inset(
            self._h(), _subd_array(c_uint32, ids), len(ids), amount, bool(individual)), "subd_inset")

    def subdivide(self, faces: Optional[Iterable[int]] = None) -> "Subd":
        """A new cage with `faces` subdivided once by the Catmull-Clark rules (the whole cage
        when `faces` is None or empty): each face becomes quads round a new point, and an
        unpicked face beside them takes the new edge points as corners. The whole cage keeps
        its smooth surface exactly. The new cage selects the new faces."""
        ids = [] if faces is None else _indices(faces, "subdivide", "faces")
        return self._edit(lambda: _lib().cadaclysm_blacksmith_subd_subdivide(
            self._h(), _subd_array(c_uint32, ids), len(ids)), "subd_subdivide")

    def insert_loop(self, edge: "tuple[int, int]", at: float = 0.5) -> "Subd":
        """A new cage with a loop of edges cut across the ring of quads through `edge` (an
        (a, b) pair), at `a + at * (b - a)` with `at` in (0, 1); it selects the new loop."""
        a, b = _subd_pairs([edge], "insert_loop", "edge")
        return self._edit(lambda: _lib().cadaclysm_blacksmith_subd_insert_loop(self._h(), a, b, at), "subd_insert_loop")

    def edge_loop(self, edge: "tuple[int, int]") -> "list[tuple[int, int]]":
        """The loop of edges through `edge`, straight across each valence-four vertex, the
        picked edge first, each pair smaller id first; empty when `edge` is not an edge of
        the cage."""
        a, b = _subd_pairs([edge], "edge_loop", "edge")
        with self._edit(lambda: _lib().cadaclysm_blacksmith_subd_edge_loop(self._h(), a, b), "subd_edge_loop") as looped:
            selection = looped.selection
        return selection[1] if selection else []

    def mirror_on(self, axis: str) -> "Subd":
        """The positive half of the cage across the plane perpendicular to `axis` ("x", "y" or
        "z") as a mirrored cage: every later edit keeps it symmetric."""
        axis = _subd_axis(axis, "mirror_on")
        return self._edit(lambda: _lib().cadaclysm_blacksmith_subd_mirror_on(self._h(), axis), "subd_mirror_on")

    def mirror_off(self) -> "Subd":
        """The mirror baked: the whole cage as an ordinary one, no longer mirrored."""
        return self._edit(lambda: _lib().cadaclysm_blacksmith_subd_mirror_off(self._h()), "subd_mirror_off")

    def full(self) -> "Subd":
        """The whole cage of a mirrored half -- the half's vertices first, then the reflections
        of those off the plane -- or a copy of an ordinary cage."""
        return self._edit(lambda: _lib().cadaclysm_blacksmith_subd_full(self._h()), "subd_full")

    # -- the surface
    def smooth_mesh(self, levels: int = 3) -> SubdMesh:
        """The smooth surface refined `levels` times (1 to 6), as a `SubdMesh` of copies."""
        out = _SubdMesh()
        _ok(_lib().cadaclysm_blacksmith_subd_smooth_mesh(self._h(), _u32(levels, "smooth_mesh levels"), ctypes.byref(out)),
            "subd_smooth_mesh")
        return SubdMesh(out)

    def pick(self, point: Point3, kind: str) -> "int | tuple[int, int] | None":
        """The cage element of `kind` ("vertex", "edge" or "face") under `point`, a point on
        or near the smooth surface: a vertex or face id, or an edge as (a, b) with the smaller
        id first. None when nothing is within 0.05 of the cage's diagonal -- not an error."""
        if kind not in _SUBD_PICKS:
            raise BuildError(f"pick: kind must be 'vertex', 'edge' or 'face', not {kind!r}")
        at = _doubles(point, 3, "pick point")
        out = (c_uint32 * 2)()
        lib = _lib()
        if not lib.cadaclysm_blacksmith_subd_pick(self._h(), at, _SUBD_PICKS[kind], out):
            if _nothing_near(lib):
                return None
            _fail("subd_pick")
        return (out[0], out[1]) if kind == "edge" else out[0]

    def to_solid(self, tolerance: float = 1e-4, g1_angle: float = 0.1, max_levels: int = 6) -> "tuple[Solid, SubdReport]":
        """The cage as an exact solid, one NURBS face per patch, that every solid call takes,
        and a `SubdReport` of what the conversion did. `tolerance` is the largest deviation
        from the limit surface as a fraction of the cage's diagonal, `g1_angle` the largest
        tangent break across an uncreased side in degrees, `max_levels` the deepest local
        refinement (2 to 6). A `tolerance` or `g1_angle` of 0 or less, or a `max_levels` of 0, takes
        the default; any other `max_levels` outside 2 to 6 is refused. A cage that cannot be
        held within them is refused with the figures it measured."""
        report = _SubdReport()
        handle = _lib().cadaclysm_blacksmith_subd_to_solid(
            self._h(), tolerance, g1_angle, _u32(max_levels, "to_solid max_levels"), ctypes.byref(report))
        return Solid(handle), SubdReport(report)


class FemEdge:
    """One B-rep edge of a FEM mesh: the chain of nodes along it, and where that chain
    breaks. Plain data, copied out of the handle.

    `nodes` are this mesh's node indices in order along the edge, its end vertices
    included; a closed edge repeats no node. **`runs` says where the chain breaks**:
    read `nodes[runs[i]:runs[i + 1]]` (the last run to the end) as one polyline and
    join nothing across a run boundary -- the two ends either side of one are two
    points of the edge with no mesh edge between them. `(0,)` is the ordinary answer,
    and a caller reading `nodes` as one polyline without looking here jumps the gap
    silently.

    `faces` is `(face_a, face_b)` and `ends` is `(end_a, end_b)`, the second of each
    being `NONE` where there is none -- an open sheet's rim, or both ends at one
    vertex (a closed edge, a circle's rim, a full-turn seam). **`0` is a real face and
    a real vertex, not a sentinel.** Which end comes first is the first trim's
    direction and means nothing else. `closed` where the nodes make one loop, never
    with more than one run; `seam` where one face bounds the edge twice, and both
    `faces` are then that face.

    **`faces` numbers the solid's faces as `Solid.face_kind` does; the edges
    themselves are not `Solid.edges`' numbering** -- these are the manifold analysis's,
    ascending by edge id, and `FemMesh.node_entity` indexes this list.

    `id` is **the solid's own edge id**, not this mesh's edge index: the list is a
    densely renumbered subset of the solid's edges, with every edge collapsed to a point
    left out, so a sphere -- whose two pole runs collapse -- reports its seam as edge 0
    with an `id` of 1. Everything else that names an edge here means the index: a
    `node_kind` of 1 read through `node_entity`, the third number of an `open_edges` or
    `folded_edges` row, and the `edge_<i>` physical group of `msh_text`. It is not a row
    of `Solid.edges` either, that table being the solid's edges grouped by geometry; the
    id names the topological edge."""

    __slots__ = ("id", "nodes", "runs", "faces", "ends", "closed", "seam")

    id: int
    nodes: tuple[int, ...]
    runs: tuple[int, ...]
    faces: tuple[int, int]
    ends: tuple[int, int]
    closed: bool
    seam: bool

    def __init__(self, id: int, nodes: tuple[int, ...], runs: tuple[int, ...], faces: tuple[int, int],  # noqa: A002
                 ends: tuple[int, int], closed: bool, seam: bool):
        self.id = id
        self.nodes = nodes
        self.runs = runs
        self.faces = faces
        self.ends = ends
        self.closed = closed
        self.seam = seam

    def __repr__(self) -> str:
        return (f"FemEdge(id={self.id}, nodes={len(self.nodes)}, runs={len(self.runs)}, "
                f"faces={self.faces}, ends={self.ends}, closed={self.closed}, seam={self.seam})")


class FemVertex:
    """One B-rep vertex of a FEM mesh: the node the mesh put there, if any, and where
    the topology says it is, if that is known. Plain data.

    `node` is `NONE` where the mesh has none there, **which is ordinary rather than a
    fault**: the analysis rebuilds a vertex wherever two trims meet, and a pole's
    polyline runs give a sphere 48 of them where the mesh has 2 points, so a caller
    walking these skips the sentinel rather than treating it as a gap.

    `point` is where the vertex is, in the same space and under the same placement as
    `FemMesh.nodes`. **Meaningless unless `has_position`**: it is `(0.0, 0.0, 0.0)`
    then -- a point no geometry has, which a solver would take for a node at the
    origin."""

    __slots__ = ("node", "point", "has_position")

    node: int
    point: tuple[float, float, float]
    has_position: bool

    def __init__(self, node: int, point: tuple[float, float, float], has_position: bool):
        self.node = node
        self.point = point
        self.has_position = has_position

    def __repr__(self) -> str:
        return f"FemVertex(node={self.node}, point={self.point}, has_position={self.has_position})"


class _Tessellation:
    """One mesh of a solid, held: the owner of a mesh's numpy views. Its arrays belong to it,
    not to the solid, so neither a re-mesh at another tolerance nor the solid's close frees
    them; the handle goes when the last view does."""
    __slots__ = ("_handle_", "__weakref__")

    def __init__(self, solid, tolerance, what):
        self._handle_ = _lib().cadaclysm_blacksmith_tessellation(solid._h(), _tolerance(tolerance))
        if not self._handle_:
            _fail_tessellation(what)

    def __del__(self) -> None:
        h, self._handle_ = getattr(self, "_handle_", None), None
        if h and _library is not None:
            try:
                _library.cadaclysm_blacksmith_tessellation_free(h)
            except Exception:
                pass


class FemMesh:
    """One solid meshed for a solver: nodes welded by bits, triangles wound outward,
    every node tagged with the lowest-dimension B-rep entity it lies on, and every
    crack reported rather than closed. Built by `Solid.fem_mesh`, and **owned by
    you**: `free()` it, or use it as a context manager.

    A handle rather than a snapshot, as a `Solid` is, and its big arrays are
    **read-only numpy views into the library's own memory**, exactly as `Solid.mesh`'s
    are: a solver mesh is megabytes, and copying it to hand it over would cost that
    twice, and nothing but its own `free()` replaces this memory. Each array keeps
    *this object* alive through its `.base` -- not the solid, which does not own it
    and whose `close()` does not free it, and not the mesh cache, which meshing again
    at another tolerance replaces. What still dangles is a view kept past an explicit `free()` or the end of a `with`
    block; call `.copy()` on anything that must outlive the handle. Under Pyodide the
    arrays are copies and never invalidate, as everywhere else in this module.

    It is `free()` here where a `Solid` has `close()`: this follows the reader module's
    `FemMesh` and `Meshlets`, the two other handles whose arrays are borrowed views,
    so one FEM mesh is released the same way on both sides of the ABI.

    numpy is imported the first time one of those arrays is asked for. The flags, the
    counts, the quality figures, the edge and vertex records, the crack censuses and
    the `.msh` text need nothing outside the standard library."""

    __slots__ = ("_handle_", "_raw", "__weakref__")

    def __init__(self, handle: int | None):
        self._handle_ = _checked(handle, "fem_mesh")
        # Read once, here. Every pointer in the view is built with the handle and good
        # until it is freed -- nothing in this ABI is built lazily -- so asking again
        # per property would be one C call per array for the same answer.
        raw = _FemMeshView()
        if not _lib().cadaclysm_blacksmith_fem_mesh_view(self._handle_, ctypes.byref(raw)):
            why = _text(_lib().cadaclysm_blacksmith_last_error()) or "fem_mesh_view"
            self.free()
            raise BuildError(why)
        self._raw = raw

    def _h(self):
        if not self._handle_:
            raise BuildError("fem mesh: freed")
        return self._handle_

    @property
    def _live(self) -> "_FemMeshView":
        """The view, the handle checked first: every pointer in it is the handle's, and
        a freed handle's point at nothing."""
        if not self._handle_:
            raise BuildError("fem mesh: freed")
        return self._raw

    @property
    def freed(self) -> bool:
        return not self._handle_

    def free(self) -> None:
        """Give the mesh back, and with it every view taken from it. Idempotent. The
        `.msh` texts are not freed with it: each is already a Python `str`."""
        h, self._handle_ = getattr(self, "_handle_", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_fem_mesh_free(h)

    def __enter__(self) -> "FemMesh":
        return self

    def __exit__(self, *_: object) -> None:
        self.free()

    def __del__(self) -> None:
        try:
            self.free()
        except Exception:  # noqa: BLE001 - the interpreter may be going down
            pass

    # -- the flat arrays, borrowed
    @property
    def nodes(self) -> "numpy.ndarray":
        """Every node's position, a read-only float64 `(node_count, 3)` view -- placed
        by `Solid.fem_mesh`'s `placement`, in the solid's own coordinates otherwise."""
        raw = self._live
        return _view(self, raw.nodes, (raw.node_count, 3), "f8")

    @property
    def triangles(self) -> "numpy.ndarray":
        """Three node indices a triangle, wound outward: a read-only uint32
        `(triangle_count, 3)` view."""
        raw = self._live
        return _view(self, raw.triangles, (raw.triangle_count, 3), "u4")

    @property
    def triangle_face(self) -> "numpy.ndarray":
        """The face each triangle lies on, one per triangle: a read-only uint32 view
        into `range(face_count)`, the same faces `Solid.face_kind` names."""
        raw = self._live
        return _view(self, raw.triangle_face, (raw.triangle_count,), "u4")

    @property
    def node_kind(self) -> "numpy.ndarray":
        """What each node lies on -- `0` a vertex, `1` an edge, `2` a face -- one per
        node, as a read-only uint32 view. Gmsh's own classification rule: the
        lowest-dimension entity the node lies on. `node_entity` says which one."""
        raw = self._live
        return _view(self, raw.node_kind, (raw.node_count,), "u4")

    @property
    def node_entity(self) -> "numpy.ndarray":
        """Which vertex, edge or face each node lies on, by the matching `node_kind`:
        an index into `vertices`, into `edges`, or into the solid's faces. One per
        node, a read-only uint32 view."""
        raw = self._live
        return _view(self, raw.node_entity, (raw.node_count,), "u4")

    # -- the topology, copied out
    @property
    def face_count(self) -> int:
        """The solid's faces -- the same faces `Solid.faces` counts."""
        return self._live.face_count

    @property
    def edges(self) -> "list[FemEdge]":
        """One `FemEdge` per B-rep edge, in the order a `node_kind` of 1 indexes them.
        **Not `Solid.edges`' numbering**, and not the solid's own edge ids either -- each
        `FemEdge.id` carries that; see `FemEdge`."""
        library, handle, raw = _lib(), self._h(), _FemEdge()
        out = []
        for i in range(self._raw.edge_count):
            if not library.cadaclysm_blacksmith_fem_mesh_edge(handle, i, ctypes.byref(raw)):
                _fail(f"fem_mesh_edge {i}")
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
        """One `FemVertex` per B-rep vertex, in the order a `node_kind` of 0 indexes
        them."""
        library, handle, raw = _lib(), self._h(), _FemVertex()
        out = []
        for i in range(self._raw.vertex_count):
            if not library.cadaclysm_blacksmith_fem_mesh_vertex(handle, i, ctypes.byref(raw)):
                _fail(f"fem_mesh_vertex {i}")
            out.append(FemVertex(raw.node, tuple(raw.point), bool(raw.has_position)))
        return out

    # -- the crack census
    @property
    def open_edges(self) -> "list[tuple[int, int, int]]":
        """Every crack, as `(a, b, brep_edge)`: a directed mesh edge `(a, b)` with no
        `(b, a)`, and the B-rep edge both nodes lie on or `NONE` where they share none.

        **Empty unless the solid's topology is closed**, whose mesh is otherwise not
        asked about at all -- an open sheet from `face`, `face_sheet`, `drop_faces` or
        `extrude_open` reports `watertight` False with this and `folded_edges` both
        empty, and *that trio together* says "not asked", not "nothing found"."""
        return self._census(_lib().cadaclysm_blacksmith_fem_mesh_open_edge,
                            self._live.open_edge_count, "fem_mesh_open_edge")

    @property
    def folded_edges(self) -> "list[tuple[int, int, int]]":
        """Every fold, as `open_edges` reports a crack: a directed mesh edge used by
        more than one triangle.

        **A body can be folded without being open** -- a solid no thicker than a line
        leaves no hole for an open edge to find -- so a caller that checks only
        `open_edges` calls such a body sound."""
        return self._census(_lib().cadaclysm_blacksmith_fem_mesh_folded_edge,
                            self._live.folded_edge_count, "fem_mesh_folded_edge")

    @property
    def crossings(self) -> "list[tuple[int, int]]":
        """Every pair of triangles that pass through each other, as `(a, b)` with `a < b`,
        sorted: an edge of one through the other's interior. Their B-rep faces are
        `triangle_face[a]` and `triangle_face[b]`.

        **Computed for every solid, open or closed.** The census `watertight`,
        `open_edges` and `folded_edges` report is topological and cannot see a surface
        passing through itself; a mesh is ready for a volume mesher when it is
        `watertight` **and** this is empty -- Gmsh refuses one that crosses. A copy."""
        handle = self._h()
        count = _lib().cadaclysm_blacksmith_fem_mesh_crossing_count(handle)
        a, b = c_uint32(), c_uint32()
        out = []
        for i in range(count):
            if not _lib().cadaclysm_blacksmith_fem_mesh_crossing(handle, i, ctypes.byref(a), ctypes.byref(b)):
                _fail(f"fem_mesh_crossing {i}")
            out.append((a.value, b.value))
        return out

    def _census(self, call, count: int, what: str) -> "list[tuple[int, int, int]]":
        """One flattened census, row by row: the shape `open_edges` and `folded_edges`
        share, so the two cannot drift."""
        handle = self._h()
        a, b, edge = c_uint32(), c_uint32(), c_uint32()
        out = []
        for i in range(count):
            if not call(handle, i, ctypes.byref(a), ctypes.byref(b), ctypes.byref(edge)):
                _fail(f"{what} {i}")
            out.append((a.value, b.value, edge.value))
        return out

    # -- the summary
    @property
    def watertight(self) -> bool:
        """The topology is closed and the welded mesh is too. **False for every solid
        whose topology is not closed**; see `open_edges` for what an empty census
        beside a False here does and does not mean."""
        return bool(self._live.watertight)

    @property
    def from_mesh(self) -> bool:
        """**Always False here**, and kept so the two ABIs' views are one struct: a
        `Solid` always has a brep behind it, so this library has no mesh-only body to
        report. The reader module's `Node.fem_mesh` sets it for a node with no brep (an
        STL, an OpenSCAD body), where it also says which space the mesh is in --
        here there is only one space, the solid's own under `placement` -- and where a
        true one means the census speaks from the triangles alone rather than from a
        topology. **That second difference cannot arise here**: every solid has a brep
        (`cadaclysm_blacksmith_fem_mesh` only ever calls `fem::fem_mesh_with`, never
        `fem_mesh_of_mesh`), so `open_edges`' "empty unless the topology is closed"
        holds without exception on this side of the ABI."""
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

        **The figure to check against `Solid.fem_mesh`'s `max_size`, and the only one
        that says what the mesh actually is**: `max_size` bounds the boundary segments
        and merely targets the interior, and one small enough to hit the mesher's own
        piece and station ceilings is not honoured at all."""
        return self._live.longest_edge

    # -- out
    def msh_text(self) -> str:
        """The mesh as Gmsh 4.1 ASCII `.msh` text: an entity per B-rep vertex, edge and
        face, a volume where the solid closes, and a physical group naming each.

        **The library's text is owned and released here** with
        `cadaclysm_blacksmith_string_free`, as every other text this library hands over
        (`step_text`, `sat_text`, `brep_text`, `svg`). Two asks give two independent
        texts, and neither dies with the handle. The reader module's
        `FemMesh.msh_text` is the other way round -- it borrows from a slot on its own
        handle and must not be freed -- so a reader porting one side's reasoning onto
        the other leaks or double-frees.

        **The unlicensed notice is printed here**, on this writer and on `save_msh`,
        and *not* by `Solid.fem_mesh`: meshing is not a licensed output and the `.msh`
        file is, which is where `sat_text` and `brep_text` put theirs too. The reader
        library notices in its constructor instead and on neither `.msh` call; each
        matches its own siblings, so moving the call to look like the other side breaks
        a convention.

        Raises `BuildError` for a mesh the writer refuses, naming the field it cannot
        honour, and for a freed handle."""
        text = _lib().cadaclysm_blacksmith_fem_mesh_msh_text(self._h())
        if not text:
            _fail("fem_mesh_msh_text")
        if _WASM:
            return text   # the wasm returns the text itself, nothing to free
        try:
            return ctypes.string_at(text).decode("utf-8")
        finally:
            _lib().cadaclysm_blacksmith_string_free(text)

    def save_msh(self, path: FilePath) -> None:
        """`msh_text()` written to `path`, replacing any file there -- by the library
        itself, or by this module in the browser, where the wasm has no files of the
        page's to write (as `write_sat`, `write_brep` and `svg`).

        Raises `BuildError` for a mesh the writer refuses or a file it cannot write,
        naming the path. Prints the unlicensed notice; see `msh_text`."""
        if _WASM:
            # Refused as the C writer words its own (`fem_mesh_save_msh: <path>: <why>`).
            text = self.msh_text()
            try:
                _FsPath(path).write_text(text, encoding="utf-8")
            except OSError as e:
                raise BuildError(f"fem_mesh_save_msh: {path}: {e.strerror or e}") from None
            return
        if not _lib().cadaclysm_blacksmith_fem_mesh_save_msh(self._h(), str(path).encode("utf-8")):
            _fail("fem_mesh_save_msh")

    def __repr__(self) -> str:
        if self.freed:
            return "FemMesh(freed)"
        raw = self._raw
        return (f"FemMesh(nodes={raw.node_count}, triangles={raw.triangle_count}, "
                f"watertight={bool(raw.watertight)})")


# -- machining: 2.5D milling and drilling, written as Grbl 1.1 G-code


class Tool:
    """A cutter: Grbl tool `number` (1 to 255, the `T` word), `diameter` and
    `flute_length` in mm, `feed` and `plunge` in mm/min, `rpm` its spindle speed,
    ramping into its cuts at `ramp_angle` degrees. Immutable; a job keeps its own
    copy."""

    __slots__ = ("_handle",)

    def __init__(self, handle: int | None):
        self._handle = _checked(handle, "tool")

    def __del__(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_tool_free(h)

    @staticmethod
    def _ramped(handle, ramp_angle, what: str) -> "Tool":
        tool = Tool(_checked(handle, what))
        if ramp_angle == 3.0:   # the library's own default: no second handle
            return tool
        return Tool(_lib().cadaclysm_blacksmith_tool_with_ramp_angle(tool._handle, ramp_angle))

    @staticmethod
    def flat(number: int, diameter: float, flute_length: float, feed: float, plunge: float, rpm: float,
             ramp_angle: float = 3.0) -> "Tool":
        """A flat end mill. Raises `BuildError` for a `number` outside 1..255, a size,
        feed or speed not positive and finite, or a `ramp_angle` outside (0, 90]."""
        return Tool._ramped(_lib().cadaclysm_blacksmith_tool_flat(number, diameter, flute_length, feed, plunge, rpm),
                            ramp_angle, "tool_flat")

    @staticmethod
    def ball(number: int, diameter: float, flute_length: float, feed: float, plunge: float, rpm: float,
             ramp_angle: float = 3.0) -> "Tool":
        """A ball end mill, as `flat` but its tip a half sphere of the diameter; in
        2.5D it cuts where a flat does, `bottom` being the tip."""
        return Tool._ramped(_lib().cadaclysm_blacksmith_tool_ball(number, diameter, flute_length, feed, plunge, rpm),
                            ramp_angle, "tool_ball")

    @staticmethod
    def drill(number: int, diameter: float, flute_length: float, feed: float, rpm: float) -> "Tool":
        """A drill, plunging at `feed`. A job takes it for `Job.drill` only."""
        return Tool(_lib().cadaclysm_blacksmith_tool_drill(number, diameter, flute_length, feed, rpm))

    @property
    def number(self) -> int:
        """The Grbl tool number, 1 to 255 (the `T` word)."""
        n = _lib().cadaclysm_blacksmith_tool_number(self._handle)
        if n == NONE:
            _fail("tool_number")
        return int(n)

    @property
    def shape(self) -> str:
        """The cutting end: "flat", "ball", "drill", "vbit" or "bullnose"."""
        raw = _lib().cadaclysm_blacksmith_tool_shape(self._handle)
        if not raw:
            _fail("tool_shape")
        return raw.decode("utf-8")

    def _size(self, call, what: str) -> float:
        v = float(call(self._handle))
        if math.isnan(v):
            _fail(what)
        return v

    @property
    def diameter(self) -> float:
        """The cutting diameter, in mm."""
        return self._size(_lib().cadaclysm_blacksmith_tool_diameter, "tool_diameter")

    @property
    def flute_length(self) -> float:
        """How far up the cutting edge reaches from the tip, in mm."""
        return self._size(_lib().cadaclysm_blacksmith_tool_flute_length, "tool_flute_length")

    @property
    def angle(self) -> "float | None":
        """A V-bit's included angle, in degrees; None for every other shape."""
        return self._size(_lib().cadaclysm_blacksmith_tool_angle, "tool_angle") if self.shape == "vbit" else None

    @property
    def corner_radius(self) -> "float | None":
        """A bull-nose's corner radius, in mm; None for every other shape."""
        return self._size(_lib().cadaclysm_blacksmith_tool_corner_radius, "tool_corner_radius") if self.shape == "bullnose" else None


class Stock:
    """The block of material a job cuts, an axis-aligned box. Immutable; a job
    keeps its own copy."""

    __slots__ = ("_handle",)

    def __init__(self, handle: int | None):
        self._handle = _checked(handle, "stock")

    def __del__(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_stock_free(h)

    @staticmethod
    def box(min: Point3, max: Point3) -> "Stock":  # noqa: A002 - the spec's own names
        """The box from `min` (x, y, z) to `max`. Raises `BuildError` unless every
        min is below its max and all six are finite."""
        (x0, y0, z0), (x1, y1, z1) = min, max
        return Stock(_lib().cadaclysm_blacksmith_stock_box(x0, y0, z0, x1, y1, z1))

    @staticmethod
    def around(solid: "Solid", margin: float = 0.0) -> "Stock":
        """`solid`'s bounds grown by `margin` in -X, +X, -Y, +Y and +Z; the bottom
        stays at the solid's lowest Z. Raises `BuildError` for a `margin` negative
        or not finite."""
        return Stock(_lib().cadaclysm_blacksmith_stock_around(solid._h(), margin))


class Program:
    """One file a job wrote: a Grbl program (`tool` its `T` number, `name`
    `<job name>-T<n>`, or `<job name>-<k>-T<n>` for a repeated tool) or, from
    `Job.write_camotics`, a simulation copy or the CAMotics project (`tool` 0).
    Read-only."""

    __slots__ = ("tool", "name", "text")

    tool: int
    name: str
    text: str

    def __init__(self, tool: int, name: str, text: str):
        object.__setattr__(self, "tool", tool)
        object.__setattr__(self, "name", name)
        object.__setattr__(self, "text", text)

    def __setattr__(self, key: str, value: object) -> None:
        raise AttributeError(f"Program.{key} is read-only")

    def __delattr__(self, key: str) -> None:
        raise AttributeError(f"Program.{key} is read-only")

    def __repr__(self) -> str:
        return f"Program(tool={self.tool}, name={self.name!r}, {len(self.text)} characters)"


def _tool_key(t: "Tool"):
    """What makes two tools the same cutter: shape, diameter, flute length and the
    shape's own angle or corner radius."""
    return (t.shape, t.diameter, t.flute_length, t.angle, t.corner_radius)


class Operation:
    """One operation of a `Job`, read back by `Job.operations`: `kind` ("face",
    "contour", "pocket" or "drill"), `tool` (its Grbl T number) and `params` -- a
    dict, in the kind-specific order the operation stores. In `params`: `side`
    reads as `"outside"`/`"inside"`/`"on"`; `climb` and `open` as `bool`; `points`
    as `int`; a `NaN` `peck` as `None`; every other value stays a `float`.
    Read-only."""

    __slots__ = ("kind", "tool", "params")

    kind: str
    tool: int
    params: dict[str, float | int | bool | str | None]

    def __init__(self, kind: str, tool: int, params: dict[str, float | int | bool | str | None]):
        object.__setattr__(self, "kind", kind)
        object.__setattr__(self, "tool", tool)
        object.__setattr__(self, "params", params)

    def __setattr__(self, key: str, value: object) -> None:
        raise AttributeError(f"Operation.{key} is read-only")

    def __delattr__(self, key: str) -> None:
        raise AttributeError(f"Operation.{key} is read-only")

    def __repr__(self) -> str:
        return f"Operation(kind={self.kind!r}, tool={self.tool}, params={self.params!r})"


class ReportItem:
    """One thing `Job.machine` left uncut: `kind` (`"corner"`, `"hole"`, `"slope"`,
    `"undercut"`, `"too_deep"` or `"relief"`), `at` (x, y, z), `size` (its meaning per `kind`),
    `reason` (one sentence naming the tool involved), and `region` (its XY area, as
    a list of `Profile`). `top` and `bottom` are the Z range it stands over: a corner
    from the band top it starts at down to the floor it reaches, a hole's top and
    floor, a slope's Z range, a level too deep the flutes' reach and the level, a relief
    the Z range relieved, as for a corner. For a `"relief"`, `size` is the notch depth into
    the walls in mm. Read-only."""

    __slots__ = ("kind", "at", "size", "reason", "top", "bottom", "region")

    kind: str
    at: tuple[float, float, float]
    size: float
    reason: str
    top: float
    bottom: float
    region: list[Profile]

    def __init__(self, kind: str, at: "tuple[float, float, float]", size: float, reason: str, region: "list[Profile]",
                 top: float = float("nan"), bottom: float = float("nan")):
        object.__setattr__(self, "kind", kind)
        object.__setattr__(self, "at", at)
        object.__setattr__(self, "size", size)
        object.__setattr__(self, "reason", reason)
        object.__setattr__(self, "top", top)
        object.__setattr__(self, "bottom", bottom)
        object.__setattr__(self, "region", region)

    def __setattr__(self, key: str, value: object) -> None:
        raise AttributeError(f"ReportItem.{key} is read-only")

    def __delattr__(self, key: str) -> None:
        raise AttributeError(f"ReportItem.{key} is read-only")

    def __repr__(self) -> str:
        return f"ReportItem(kind={self.kind!r}, at={self.at!r}, size={self.size!r}, reason={self.reason!r}, top={self.top!r}, bottom={self.bottom!r}, region={len(self.region)} profile(s))"


class Report:
    """What `Job.machine` could not make: a read-only sequence of `ReportItem`, in
    order, read eagerly when `machine` returns. `len`, iteration and indexing read
    the items; `str(report)` is the kernel's own report text -- one line per item,
    or `"nothing left uncut"`; `bool(report)` is `True` when it has items."""

    __slots__ = ("_items", "_text")

    def __init__(self, items: "list[ReportItem]", text: str):
        object.__setattr__(self, "_items", items)
        object.__setattr__(self, "_text", text)

    def __setattr__(self, key: str, value: object) -> None:
        raise AttributeError(f"Report.{key} is read-only")

    def __delattr__(self, key: str) -> None:
        raise AttributeError(f"Report.{key} is read-only")

    def __len__(self) -> int:
        return len(self._items)

    def __iter__(self) -> Iterator[ReportItem]:
        return iter(self._items)

    def __getitem__(self, i: int) -> ReportItem:
        return self._items[i]

    def __bool__(self) -> bool:
        return bool(self._items)

    def __str__(self) -> str:
        return self._text

    def __repr__(self) -> str:
        return f"Report({len(self._items)} item(s))"


_SIDES = {"outside": 0, "inside": 1, "on": 2}


class Job:
    """A machining job on a `Stock`: operations kept in the order they are added,
    written as one Grbl 1.1 program per run of operations sharing a tool.
    Mutable -- each operation is added in place, and a refused one leaves the
    job as it was. `safe_z` is the absolute Z of rapids between operations and at
    a program's start and end, above the stock's top; an operation enters and
    leaves its passes `clearance` above its top; `tolerance` fits free-form sides
    and offsets; `name` names the programs (`<name>-T<n>`); every program waits
    `spindle_dwell` seconds after starting the spindle; `resolution` is the
    CAMotics project's voxel size in mm. Raises `BuildError` for a `safe_z` not
    above the stock, or a setting the job refuses."""

    __slots__ = ("_handle", "_tools")

    def __init__(self, stock: Stock, safe_z: float, clearance: float = 1.0, tolerance: float = 0.01, name: str = "job",
                 spindle_dwell: float = 2.0, resolution: float = 0.1):
        self._tools: Dict[int, Tool] = {}
        lib = _lib()
        self._handle = _checked(lib.cadaclysm_blacksmith_job_new(stock._handle, safe_z), "job_new")
        # the library starts at the same defaults, so only what differs is set
        if clearance != 1.0:
            self._set(lib.cadaclysm_blacksmith_job_set_clearance, clearance, "job_set_clearance")
        if tolerance != 0.01:
            self._set(lib.cadaclysm_blacksmith_job_set_tolerance, tolerance, "job_set_tolerance")
        if spindle_dwell != 2.0:
            self._set(lib.cadaclysm_blacksmith_job_set_spindle_dwell, spindle_dwell, "job_set_spindle_dwell")
        if resolution != 0.1:
            self._set(lib.cadaclysm_blacksmith_job_set_resolution, resolution, "job_set_resolution")
        if name != "job":
            name = str(name)
            _reject_nul(name)
            self._set(lib.cadaclysm_blacksmith_job_set_name, name.encode("utf-8"), "job_set_name")

    def __del__(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_job_free(h)

    def _set(self, call, value, what: str) -> None:
        _ok(call(self._handle, value), what)

    def face(self, tool: Tool, z: float, stepover: float, stepdown: float) -> None:
        """Face the stock's top down to `z`, in zigzag rows along X `stepover` apart
        and passes at most `stepdown` deep. Raises `BuildError` for a drill, a `z`
        above the stock's top, a stepover past the tool's diameter, ..."""
        _ok(_lib().cadaclysm_blacksmith_job_face(self._handle, tool._handle, z, stepover, stepdown), "job_face")
        self._keep(tool)

    def contour(self, tool: Tool, profile: Profile, top: float, bottom: float,  # noqa: A002
                side: Literal["outside", "inside", "on"] = "outside", stepdown: float = 1.0, climb: bool = True,
                open: bool = False) -> None:
        """Cut along `profile` from `top` to `bottom` in passes at most `stepdown`
        deep: `side` "outside" the profile, "inside" it, or "on" its line; `climb`
        for climb milling, else conventional; `open` to cut the outline as an open
        chain (only "on" its line, and with no holes). Raises `ValueError` for any
        other `side`, `BuildError` for what the job refuses."""
        code = _SIDES.get(side) if isinstance(side, str) else None
        if code is None:
            raise ValueError("side must be 'outside', 'inside' or 'on'")
        _ok(_lib().cadaclysm_blacksmith_job_contour(self._handle, tool._handle, profile._handle, top, bottom, code,
                                                    stepdown, bool(climb), bool(open)), "job_contour")
        self._keep(tool)

    def pocket(self, tool: Tool, profile: Profile, top: float, bottom: float, stepover: float, stepdown: float) -> None:
        """Clear `profile` -- its holes left standing as islands -- from `top` to
        `bottom`, in rings `stepover` apart (at most the tool's radius) and passes at
        most `stepdown` deep. Raises `BuildError` for what the job refuses; a pocket
        too small for the tool is refused by `gcode()`, naming the operation."""
        _ok(_lib().cadaclysm_blacksmith_job_pocket(self._handle, tool._handle, profile._handle, top, bottom,
                                                   stepover, stepdown), "job_pocket")
        self._keep(tool)

    def drill(self, tool: Tool, points: Iterable[Point2], top: float, bottom: float, peck: float | None = None) -> None:
        """Drill a hole at each (x, y) of `points` from `top` to `bottom`, pecking
        `peck` deep at a time (retracting between pecks), or straight to depth for
        `None`. Raises `ValueError` for a point that is not two numbers, `BuildError`
        for what the job refuses (a tool that is not a drill, no points, ...)."""
        pairs = [tuple(p) for p in points]
        if any(len(p) != 2 for p in pairs):
            raise ValueError("drill: every point must be (x, y)")
        flat = [float(v) for p in pairs for v in p]
        xy = (c_double * len(flat))(*flat)   # zero-length with none: the wasm takes an array, never None
        _ok(_lib().cadaclysm_blacksmith_job_drill(self._handle, tool._handle, xy, len(pairs), top, bottom,
                                                  float("nan") if peck is None else peck), "job_drill")
        self._keep(tool)

    def machine(self, part: "Solid", end_mill: "Tool | Iterable[Tool]", drills: Tool | Iterable[Tool] = (), stepover: float | None = None,
                stepdown: float | None = None, skin: float = 0.3, peck: float | None = None,
                corner_relief: bool = False) -> Report:
        """Recognise `part` and append the operations that make it: faced, contoured
        and pocketed with `end_mill` -- or with several end mills, largest first, given
        as a list: each later one cleans what the earlier ones left (inside corners,
        regions too narrow for them, holes no drill matches), with its holes drilled
        with whichever of `drills` fits each -- a tool per required diameter. The
        report then lists only what none of the end mills reached. `stepover` and `stepdown` default
        to the kernel's own (`None`, not a number, asks for that); `skin` (at least 0,
        default 0.3) is how far above the part's lowest point the outline stops, so
        the part stays attached to the stock -- `0` cuts through; `corner_relief` (default off)
        relieves every inside corner the smallest end mill leaves with a dog-bone -- a cut along the
        corner's bisector until the cutter touches the corner, notching both walls -- and reports each
        as a `relief` item instead of a corner; `peck` defaults to
        none (a drill straight to depth). `drills` may be one `Tool` as well as a list
        of them. Returns a `Report` of what could not be cut. Raises `TypeError` for a
        `part` that is not a `Solid`, an `end_mill` or a drill that is not a `Tool`;
        `BuildError` for what the kernel refuses (a drill as `end_mill`, an empty list of
        end mills, one not smaller than the one before, ...); the job changes only on
        success -- a refusal leaves it exactly as it was. `TypeError` also for an
        `end_mill` list element that is not a `Tool`. Raises `ValueError` when two of
        the offered tools share a number but are different tools; only the tools the added operations use are kept in `Job.tools`."""
        if not isinstance(part, Solid):
            raise TypeError(f"machine: part must be a Solid, not {type(part).__name__}")
        if isinstance(end_mill, Tool):
            mills = None
        elif isinstance(end_mill, (str, bytes)) or not isinstance(end_mill, _abc.Iterable):
            raise TypeError(f"machine: end_mill must be a Tool, not {type(end_mill).__name__}")
        else:
            mills = list(end_mill)
            for i, t in enumerate(mills):
                if not isinstance(t, Tool):
                    raise TypeError(f"machine: end_mill[{i}] must be a Tool, not {type(t).__name__}")
        tools = [drills] if isinstance(drills, Tool) else list(drills)
        for i, t in enumerate(tools):
            if not isinstance(t, Tool):
                raise TypeError(f"machine: drills[{i}] must be a Tool, not {type(t).__name__}")
        offered = {}
        for t in (*(mills if mills is not None else [end_mill]), *tools):
            other = offered.setdefault(t.number, t)
            if other is not t and _tool_key(other) != _tool_key(t):
                raise ValueError(f"machine: tool T{t.number} differs from the tool T{other.number} offered with it")
        before = len(self.operations())
        handles = (c_void_p * len(tools))(*[t._handle for t in tools])   # zero-length with none: the wasm takes an array, never None
        options = (float("nan") if stepover is None else stepover,
                   float("nan") if stepdown is None else stepdown,
                   skin,
                   float("nan") if peck is None else peck)
        if corner_relief:
            relieved = [end_mill] if mills is None else mills
            mill_handles = (c_void_p * len(relieved))(*[t._handle for t in relieved])
            handle = _lib().cadaclysm_blacksmith_job_machine_relieved(self._handle, part._h(), mill_handles, len(relieved), handles, len(tools), *options, True)
            what = "job_machine_relieved"
        elif mills is None:
            handle = _lib().cadaclysm_blacksmith_job_machine(self._handle, part._h(), end_mill._handle, handles, len(tools), *options)
            what = "job_machine"
        else:
            mill_handles = (c_void_p * len(mills))(*[t._handle for t in mills])   # zero-length with none: the wasm takes an array
            handle = _lib().cadaclysm_blacksmith_job_machine_with(self._handle, part._h(), mill_handles, len(mills), handles, len(tools), *options)
            what = "job_machine_with"
        report = _report(handle, what)   # raises on a refusal: nothing is kept then
        used = {op.tool for op in self.operations()[before:]}   # only a tool a program uses can be found by its T number
        self._keep(*[t for t in (*(mills if mills is not None else [end_mill]), *tools) if t.number in used])
        return report

    def _keep(self, *tools: Tool) -> None:
        for t in tools:
            self._tools[t.number] = t

    @property
    def stock(self) -> "tuple[tuple[float, float, float], tuple[float, float, float]]":
        """The stock's box as the job holds it, `((min_x, min_y, min_z), (max_x,
        max_y, max_z))` -- what `Stock.box` was given, or what `Stock.around`
        worked out."""
        lo, hi = (c_double * 3)(), (c_double * 3)()
        if not _lib().cadaclysm_blacksmith_job_stock(self._handle, lo, hi):
            _fail("job_stock")
        return tuple(lo), tuple(hi)

    @property
    def tools(self) -> "dict[int, Tool]":
        """The tools this job was given -- by `face`, `contour`, `pocket`, `drill` and
        `machine` (its end mill and each drill it used) -- by Grbl number, so a
        `Program.tool` finds its tool. A refused call adds none; the later of two
        tools with one number wins. A new dict each time."""
        return dict(self._tools)

    def operations(self) -> "list[Operation]":
        """Every operation added to this job so far, in order -- whether added by
        `face`/`contour`/`pocket`/`drill` or by `machine`."""
        return _operations(_lib().cadaclysm_blacksmith_job_operations(self._handle), "job_operations")

    def gcode(self) -> "list[Program]":
        """The job as Grbl 1.1 programs, one per run of consecutive operations
        sharing a tool (T1, T2, T1 gives three), each named `<name>-T<n>` (or
        `<name>-<k>-T<n>` for run `k` of a repeated tool); a list of count 0 for a
        job with no operations. Raises `BuildError` for an operation whose geometry
        the tool cannot cut (named by its index and kind)."""
        return _programs(_lib().cadaclysm_blacksmith_job_gcode(self._handle), "job_gcode")

    def write_camotics(self, path: FilePath) -> "list[str]":
        """A CAMotics project at `path` and its files beside it, named after the
        project's file stem (`out/part.camotics` writes `out/part-T1.nc`), not the
        job's name: each program, a simulation copy of it (`.sim.nc`, which the
        project lists), and the project last. Creates the directory. Returns the
        paths written, the project last. Raises `BuildError` for a path with no file
        stem, what `gcode()` refuses, or a file that cannot be written."""
        path = _FsPath(path)
        stem = path.stem
        _reject_nul(stem)
        files = _programs(_lib().cadaclysm_blacksmith_job_camotics(self._handle, stem.encode("utf-8")), "job_camotics")
        # written here rather than by the library, so the notebook's own filesystem
        # takes them under Pyodide as on the desktop
        folder = path.parent
        try:
            folder.mkdir(parents=True, exist_ok=True)
            written = []
            for i, f in enumerate(files):
                at = path if i == len(files) - 1 else folder / f.name
                with open(at, "w", encoding="utf-8", newline="") as out:   # byte for byte: no CRLF on Windows
                    out.write(f.text)
                written.append(str(at))
        except OSError as e:
            raise BuildError(f"job_camotics: {path}: {e.strerror or e}") from None
        return written

    def _machining(self, part: Optional[Solid], tolerance: float) -> Dict[str, Any]:
        """`View.show_machining`'s keywords for this job: each program with its tool's
        description, the stock box, and `part`'s mesh at `tolerance` (or None)."""
        programs = [(_tool_options(_job_tool(self, p.tool)), p.text) for p in self.gcode()]
        mesh = None
        if part is not None:
            positions, _, indices = part.mesh(tolerance)
            mesh = (positions, indices)
        return {"programs": programs, "stock": _job_stock_box(self), "part": mesh}

    def show(self, part: Optional[Solid] = None, tolerance: float = 0.05, **options: Any) -> None:
        """Play the job on its stock with the GPU view library (`import cadaclysm.view.wgpu`),
        in the one shared window, from its start at real time, and return at once: space
        plays or pauses, left and right step a move, up and down multiply the speed by 4 or
        divide it, Home and End seek the start and the end, L loops; the title is the status
        line. `part`, a `Solid`, colours the stock by deviation from it (meshed at
        `tolerance`). Keywords as `Solid.show`. The terminal library cannot cut a stock:
        it raises `ViewError` naming the GPU library."""
        _present_job(self, "show", part, tolerance, options)

    def view(self, part: Optional[Solid] = None, tolerance: float = 0.05, **options: Any) -> dict[str, Any]:
        """`show` in a fresh window that blocks until it is closed; returns the camera and
        the last pick, as `Solid.view`."""
        return _present_job(self, "view", part, tolerance, options)


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

    def __init__(self, origin: Point3, x: Point3, y: Point3, z: Point3):
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
    def of(frame: FrameLike) -> "Frame":
        """Twelve numbers or four triples -- what `Solid.face_frame` and
        `Workplane.frame` hand back -- checked as the constructor checks."""
        v = tuple(_frame(frame))
        return Frame(v[0:3], v[3:6], v[6:9], v[9:12])

    @staticmethod
    def xy(origin: Point3 = (0, 0, 0)) -> "Frame":
        """The world XY plane through `origin`: z up, as `Workplane.xy`."""
        return Frame(origin, _XY[3:6], _XY[6:9], _XY[9:12])

    @staticmethod
    def xz(origin: Point3 = (0, 0, 0)) -> "Frame":
        """The world XZ plane through `origin`: x along X, y along Z, so z is -Y, as `Workplane.xz`."""
        return Frame(origin, _XZ[3:6], _XZ[6:9], _XZ[9:12])

    @staticmethod
    def yz(origin: Point3 = (0, 0, 0)) -> "Frame":
        """The world YZ plane through `origin`: x along Y, y along Z, so z is +X, as `Workplane.yz`."""
        return Frame(origin, _YZ[3:6], _YZ[6:9], _YZ[9:12])

    @staticmethod
    def at(origin: Point3, normal: Point3, x: Point3 | None = None) -> "Frame":
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
    def midplane(a: FrameLike, b: FrameLike) -> "Frame":
        """The plane midway between the planes of frames a and b: halfway between parallel planes, on a's axes; for planes that meet, the plane bisecting them through the line they meet on, its x along that line. `a` and `b` are frames or twelve numbers."""
        out = (c_double * 12)()
        if not _lib().cadaclysm_blacksmith_frame_midplane(_frame(a), _frame(b), out):
            _fail("frame_midplane")
        return Frame.of(tuple(out))

    @staticmethod
    def through(p: Point3, q: Point3, r: Point3) -> "Frame":
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

    def translate(self, dx: float, dy: float, dz: float) -> "Frame":
        """This frame moved by (`dx`, `dy`, `dz`) in world coordinates."""
        o = self.origin
        return Frame((o[0] + dx, o[1] + dy, o[2] + dz), self.x, self.y, self.z)

    def offset(self, distance: float) -> "Frame":
        """This frame moved `distance` along its own z."""
        return self.translate(*(distance * c for c in self.z))

    def flipped(self) -> "Frame":
        """The same plane facing the other way: x and y swapped, z reversed."""
        return Frame(self.origin, self.y, self.x, tuple(-c for c in self.z))

    def rotated(self, radians: float, axis: Point3) -> "Frame":
        """This frame turned `radians` about `axis` through its origin (`Transform.rotation`)."""
        r = Transform.rotation(self.origin, axis, radians).rows

        def turn(d):
            return tuple(r[4 * i] * d[0] + r[4 * i + 1] * d[1] + r[4 * i + 2] * d[2] for i in range(3))

        return Frame(self.origin, turn(self.x), turn(self.y), turn(self.z))

    def to_local(self, p: Point3) -> "tuple[float, float, float]":
        """`p` in this frame's coordinates."""
        d = tuple(float(c) - o for c, o in zip(p, self.origin))
        return (_dot(d, self.x), _dot(d, self.y), _dot(d, self.z))

    def distance_to(self, p: Point3) -> float:
        """How far `p` sits above the plane, along z (negative below)."""
        return _dot(tuple(float(c) - o for c, o in zip(p, self.origin)), self.z)

    def closest_point(self, p: Point3) -> "tuple[float, float, float]":
        """`p` dropped onto the plane along z."""
        d = self.distance_to(p)
        return tuple(float(c) - d * z for c, z in zip(p, self.z))

    @staticmethod
    def fit(points: "Iterable[Point3]") -> "tuple[Frame, float]":
        """The least-squares plane through `points` (three or more, not on one line) as a frame,
        and the largest distance any point sits off it."""
        xyz, n = _flat_points(points, "frame_fit")
        out, deviation = (c_double * 12)(), c_double()
        if not _lib().cadaclysm_blacksmith_frame_fit(xyz, n, out, ctypes.byref(deviation)):
            _fail("frame_fit")
        return Frame.of(tuple(out)), deviation.value

    def __iter__(self) -> Iterator[float]:
        return iter(self._v)

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Frame) and self._v == other._v

    def __hash__(self) -> int:
        return hash(self._v)

    def __repr__(self) -> str:
        return f"Frame(origin={self.origin}, x={self.x}, y={self.y}, z={self.z})"


#: How far from rigid, or from a similarity, a map may be and still be told one, by default.
_MAP_TOLERANCE = 1e-9
_IDENTITY_ROWS = (1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0)


def _flat16(rows) -> list:
    flat = list(rows)
    # four rows of four -- four plain numbers are not, and fall to the caller's count check
    if len(flat) == 4 and all(hasattr(row, "__iter__") and not isinstance(row, (str, bytes)) for row in flat):
        flat = [v for row in flat for v in row]
    return flat


def _matrix(t, what: str):
    """A `Transform`, 16 numbers row-major or four rows of four, as the C array."""
    return _doubles(t.rows if isinstance(t, Transform) else _flat16(t), 16, what)


class Transform:
    """An affine map of space: a 4×4 matrix, row-major, its bottom row `0 0 0 1`.
    Immutable, with nothing to free; iterates as its 16
    numbers, so it goes wherever 16 numbers do. `a @ b` is `a` after `b`.

    The constructors and the decompositions are the library's own, so every wrapper computes
    them alike. A frame argument is a `Frame` or 12 numbers; one within 1e-6 of right-handed
    and orthonormal is squared up, any other raises `BuildError`."""

    __slots__ = ("_rows",)

    def __init__(self, rows: "Iterable[float]" = _IDENTITY_ROWS):
        r = tuple(float(v) + 0.0 for v in _flat16(rows))   # + 0.0: no -0.0 to print or compare
        if len(r) != 16:
            raise BuildError(f"Transform: a matrix is 16 numbers, got {len(r)}")
        if not all(math.isfinite(v) for v in r):
            raise BuildError("Transform: not finite")
        if r[12:] != (0.0, 0.0, 0.0, 1.0):
            raise BuildError("Transform: the bottom row must be 0 0 0 1 (a projective map is not affine)")
        self._rows = r

    @staticmethod
    def _made(what: str, call) -> "Transform":
        out = (c_double * 16)()
        if not call(out):
            _fail(what)
        return Transform(tuple(out))

    @staticmethod
    def from_rows(rows: "Iterable[float]") -> "Transform":
        """The map 16 numbers state, row-major (or four rows of four)."""
        return Transform(rows)

    @staticmethod
    def identity() -> "Transform":
        return Transform()

    @staticmethod
    def translation(v: Point3) -> "Transform":
        """`p + v`."""
        return Transform._made("transform_translation", lambda out: _lib().cadaclysm_blacksmith_transform_translation(_doubles(v, 3, "transform_translation"), out))

    @staticmethod
    def rotation(point: Point3, direction: Point3, radians: float) -> "Transform":
        """A turn of `radians` about the line through `point` along `direction`, right-handed."""
        axis = _doubles([*point, *direction], 6, "transform_rotation")
        return Transform._made("transform_rotation", lambda out: _lib().cadaclysm_blacksmith_transform_rotation(axis, float(radians), out))

    @staticmethod
    def mirror(plane: FrameLike) -> "Transform":
        """The reflection across `plane` (its z the normal)."""
        return Transform._made("transform_mirror", lambda out: _lib().cadaclysm_blacksmith_transform_mirror(_frame(plane), out))

    @staticmethod
    def scale(centre: Point3, k: float) -> "Transform":
        """A uniform scale by `k` about `centre`."""
        return Transform._made("transform_scale", lambda out: _lib().cadaclysm_blacksmith_transform_scale(_doubles(centre, 3, "transform_scale"), float(k), out))

    @staticmethod
    def scale_xyz(frame: FrameLike, sx: float, sy: float, sz: float) -> "Transform":
        """A scale by `sx`, `sy`, `sz` along `frame`'s axes, about its origin."""
        return Transform._made("transform_scale_xyz", lambda out: _lib().cadaclysm_blacksmith_transform_scale_xyz(_frame(frame), float(sx), float(sy), float(sz), out))

    @staticmethod
    def shear(plane: FrameLike, direction: Point3, factor: float) -> "Transform":
        """Every point slid along `direction` by `factor` times its height above `plane`.
        `direction` is normalised -- `factor` alone sets the slide -- and must lie in the plane."""
        return Transform._made("transform_shear", lambda out: _lib().cadaclysm_blacksmith_transform_shear(_frame(plane), _doubles(direction, 3, "transform_shear"), float(factor), out))

    @staticmethod
    def plane_to_plane(a: FrameLike, b: FrameLike) -> "Transform":
        """The rigid map sending frame `a` onto frame `b`."""
        return Transform._made("transform_plane_to_plane", lambda out: _lib().cadaclysm_blacksmith_transform_plane_to_plane(_frame(a), _frame(b), out))

    @staticmethod
    def change_basis(from_: FrameLike, to: FrameLike) -> "Transform":
        """Coordinates in frame `from_` to coordinates in frame `to`: a change of basis."""
        return Transform._made("transform_change_basis", lambda out: _lib().cadaclysm_blacksmith_transform_change_basis(_frame(from_), _frame(to), out))

    @staticmethod
    def planar_projection(plane: FrameLike) -> "Transform":
        """The orthogonal projection onto `plane` -- singular by design."""
        return Transform._made("transform_planar_projection", lambda out: _lib().cadaclysm_blacksmith_transform_planar_projection(_frame(plane), out))

    @staticmethod
    def project_along(plane: FrameLike, direction: Point3) -> "Transform":
        """The parallel projection onto `plane` along `direction`, which must not lie in it."""
        return Transform._made("transform_project_along", lambda out: _lib().cadaclysm_blacksmith_transform_project_along(_frame(plane), _doubles(direction, 3, "transform_project_along"), out))

    @property
    def rows(self) -> "tuple[float, ...]":
        """The 16 numbers, row-major."""
        return self._rows

    def point(self, p: Point3) -> "tuple[float, float, float]":
        """Where the map takes the point `p`."""
        x, y, z = (float(c) for c in p)
        r = self._rows
        return (r[0] * x + r[1] * y + r[2] * z + r[3], r[4] * x + r[5] * y + r[6] * z + r[7], r[8] * x + r[9] * y + r[10] * z + r[11])

    def __matmul__(self, other: "Transform") -> "Transform":
        if not isinstance(other, Transform):
            return NotImplemented
        return Transform._made("transform_compose", lambda out: _lib().cadaclysm_blacksmith_transform_compose(_matrix(self, "transform_compose"), _matrix(other, "transform_compose"), out))

    def inverse(self) -> "Transform":
        """The map undoing this one; raises `BuildError` for a singular map."""
        return Transform._made("transform_inverse", lambda out: _lib().cadaclysm_blacksmith_transform_inverse(_matrix(self, "transform_inverse"), out))

    def is_rigid(self, tolerance: float = _MAP_TOLERANCE) -> bool:
        """Whether the linear part is orthogonal (`AᵀA = I` to `tolerance`, by default 1e-9):
        a rotation or a mirror. `Solid.transform` is looser: it applies a map within 1e-6 of a
        similarity as that similarity, so a rotation written in float32 can read `is_rigid()`
        False here and still keep every surface's analytic kind there."""
        r = _lib().cadaclysm_blacksmith_transform_is_rigid(_matrix(self, "transform_is_rigid"), float(tolerance))
        if r == NONE:
            _fail("transform_is_rigid")
        return r == 1

    def is_similarity(self, tolerance: float = _MAP_TOLERANCE) -> "float | None":
        """The scale `k` where the linear part is `k` times an orthogonal one (`AᵀA = k²I` to
        `tolerance`, relative to `k²`; by default 1e-9), else None. `Solid.transform` is
        looser: it applies a map within 1e-6 of a similarity as that similarity, so a map that
        reads None here can still keep every surface's analytic kind there."""
        k = _lib().cadaclysm_blacksmith_transform_is_similarity(_matrix(self, "transform_is_similarity"), float(tolerance))
        if math.isnan(k):
            _fail("transform_is_similarity")
        return k if k > 0 else None

    def decompose_rigid(self, tolerance: float = _MAP_TOLERANCE) -> "tuple[tuple[float, float, float], Transform] | None":
        """`(translation, orthogonal part)` for a rigid map, else None."""
        if not self.is_rigid(tolerance):
            return None
        out = (c_double * 19)()
        if not _lib().cadaclysm_blacksmith_transform_decompose_rigid(_matrix(self, "transform_decompose_rigid"), float(tolerance), out):
            _fail("transform_decompose_rigid")
        return tuple(out[0:3]), Transform(tuple(out[3:19]))

    def decompose_similarity(self, tolerance: float = _MAP_TOLERANCE) -> "tuple[tuple[float, float, float], Transform, float] | None":
        """`(translation, orthogonal part, k)` for a similarity, else None."""
        if self.is_similarity(tolerance) is None:
            return None
        out = (c_double * 20)()
        if not _lib().cadaclysm_blacksmith_transform_decompose_similarity(_matrix(self, "transform_decompose_similarity"), float(tolerance), out):
            _fail("transform_decompose_similarity")
        return tuple(out[0:3]), Transform(tuple(out[3:19])), out[19]

    def decompose_affine(self) -> "tuple[tuple[float, float, float], Transform, Transform, tuple[float, float, float]] | None":
        """The polar split of the map: `(translation, rotation, axes, stretch)` with the linear
        part `rotation @ axes @ diag(stretch) @ axesᵀ` -- `rotation` carrying the mirror, `axes`
        a proper rotation whose columns are the stretch directions, the stretches largest
        first. None for a singular map or one stretched past 1e7:1, which has no unique split."""
        out = (c_double * 38)()
        if not _lib().cadaclysm_blacksmith_transform_decompose_affine(_matrix(self, "transform_decompose_affine"), out):
            return None
        return tuple(out[0:3]), Transform(tuple(out[3:19])), Transform(tuple(out[19:35])), tuple(out[35:38])

    def __iter__(self) -> Iterator[float]:
        return iter(self._rows)

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Transform) and self._rows == other._rows

    def __hash__(self) -> int:
        return hash(self._rows)

    def __repr__(self) -> str:
        return f"Transform({list(self._rows)!r})"


class Quaternion:
    """A rotation as `w + xi + yj + zk`. Immutable; iterates as
    `w, x, y, z`. `q` and `-q` are the same rotation; a non-unit one is normalised wherever it
    becomes a rotation, a zero one raises `BuildError` there. `a * b` turns by `b`, then `a`.
    Equality (`==`, and the hash) is by components, so `q != -q` although the two are the same
    rotation: to ask whether two turn alike, compare their `to_transform()` rows to a tolerance."""

    __slots__ = ("_q",)

    def __init__(self, w: float = 1.0, x: float = 0.0, y: float = 0.0, z: float = 0.0):
        q = tuple(float(v) + 0.0 for v in (w, x, y, z))
        if not all(math.isfinite(v) for v in q):
            raise BuildError("Quaternion: not finite")
        self._q = q

    @staticmethod
    def _made(what: str, call) -> "Quaternion":
        out = (c_double * 4)()
        if not call(out):
            _fail(what)
        return Quaternion(*out)

    @staticmethod
    def from_axis_angle(direction: Point3, radians: float) -> "Quaternion":
        return Quaternion._made("quaternion_from_axis_angle", lambda out: _lib().cadaclysm_blacksmith_quaternion_from_axis_angle(_doubles(direction, 3, "quaternion_from_axis_angle"), float(radians), out))

    @staticmethod
    def from_transform(t: "Transform") -> "Quaternion":
        """The rotation in `t`'s linear part (its translation ignored); raises `BuildError`
        unless that is a proper rotation, orthogonal to 1e-9. That is stricter than
        `Solid.transform`, which snaps a map within 1e-6 of a similarity: a rotation rounded to
        float32 is refused here. Take `t.decompose_affine()[1]` (the rotation, orthogonal to
        rounding) first."""
        return Quaternion._made("quaternion_from_transform", lambda out: _lib().cadaclysm_blacksmith_quaternion_from_transform(_matrix(t, "quaternion_from_transform"), out))

    @staticmethod
    def slerp(a: "Quaternion", b: "Quaternion", s: float) -> "Quaternion":
        """From `a` (`s = 0`) to `b` (`s = 1`) the shorter way."""
        return Quaternion._made("quaternion_slerp", lambda out: _lib().cadaclysm_blacksmith_quaternion_slerp(_doubles(a, 4, "quaternion_slerp"), _doubles(b, 4, "quaternion_slerp"), float(s), out))

    def to_transform(self, centre: Point3 = (0.0, 0.0, 0.0)) -> "Transform":
        """This rotation as a `Transform` fixing `centre`."""
        return Transform._made("quaternion_to_transform", lambda out: _lib().cadaclysm_blacksmith_quaternion_to_transform(_doubles(self._q, 4, "quaternion_to_transform"), _doubles(centre, 3, "quaternion_to_transform"), out))

    @property
    def w(self) -> float:
        return self._q[0]

    @property
    def x(self) -> float:
        return self._q[1]

    @property
    def y(self) -> float:
        return self._q[2]

    @property
    def z(self) -> float:
        return self._q[3]

    @staticmethod
    def _norm(vs) -> float:
        """The length of `vs`, scaled by its largest component first, as the ABI's
        `quaternion_from` does: squaring 1e200 overflows and 1e-170 underflows."""
        big = max(abs(v) for v in vs)
        return 0.0 if big == 0 else big * math.sqrt(sum((v / big) ** 2 for v in vs))

    @property
    def length(self) -> float:
        return Quaternion._norm(self._q)

    @property
    def angle(self) -> float:
        """The turn, in `[0, 2π]`."""
        return 2.0 * math.atan2(Quaternion._norm(self._q[1:]), self.w)

    @property
    def axis(self) -> "tuple[float, float, float] | None":
        """The turn's axis, None for the identity."""
        big = max(abs(v) for v in self._q[1:])
        if big == 0:
            return None
        v = tuple(c / big for c in self._q[1:])
        n = math.sqrt(sum(c * c for c in v))
        return (v[0] / n, v[1] / n, v[2] / n)

    def conjugate(self) -> "Quaternion":
        return Quaternion(self.w, -self.x, -self.y, -self.z)

    def normalized(self) -> "Quaternion":
        """The same rotation at unit length, scaled by its largest component before the
        square root (as the ABI's `quaternion_from` does), so 1e200 and 1e-170 normalise."""
        big = max(abs(v) for v in self._q)
        if big == 0:
            raise BuildError("Quaternion.normalized: the quaternion is zero")
        v = tuple(c / big for c in self._q)
        n = math.sqrt(sum(c * c for c in v))
        return Quaternion(*(c / n for c in v))

    def __mul__(self, o: "Quaternion") -> "Quaternion":
        if not isinstance(o, Quaternion):
            return NotImplemented
        a, b = self._q, o._q
        return Quaternion(a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
                          a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
                          a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
                          a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0])

    def __iter__(self) -> Iterator[float]:
        return iter(self._q)

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Quaternion) and self._q == other._q

    def __hash__(self) -> int:
        return hash(self._q)

    def __repr__(self) -> str:
        return f"Quaternion{self._q!r}"


class Interval:
    """A parameter range `t0..t1`, in either order: `length` and `swapped` keep the order,
    the set operations (`grown`, `union`, `intersect`) answer increasing. Immutable and
    hashable; iterates as `(t0, t1)`, so a pair goes wherever an `Interval` does. The
    kernel's own `Interval` in plain Python, checked against the same Rhino records."""

    __slots__ = ("_t",)

    def __init__(self, t0: float, t1: float):
        t = (float(t0) + 0.0, float(t1) + 0.0)
        if not all(math.isfinite(v) for v in t):
            raise BuildError("Interval: not finite")
        object.__setattr__(self, "_t", t)

    def __setattr__(self, name: str, value: object) -> None:
        raise AttributeError(f"Interval is immutable: cannot set {name}")

    @staticmethod
    def of(value: "Interval | Iterable[float]") -> "Interval":
        """An `Interval`, or two numbers, as an `Interval`."""
        if isinstance(value, Interval):
            return value
        t = tuple(value)
        if len(t) != 2:
            raise BuildError(f"Interval: an interval is 2 numbers, got {len(t)}")
        return Interval(*t)

    @property
    def t0(self) -> float:
        return self._t[0]

    @property
    def t1(self) -> float:
        return self._t[1]

    @property
    def length(self) -> float:
        """`t1 - t0`: negative for a decreasing interval."""
        return self._t[1] - self._t[0]

    @property
    def mid(self) -> float:
        return 0.5 * (self._t[0] + self._t[1])

    @property
    def min(self) -> float:
        return min(self._t)

    @property
    def max(self) -> float:
        return max(self._t)

    @property
    def is_increasing(self) -> bool:
        return self._t[0] < self._t[1]

    @property
    def is_singleton(self) -> bool:
        return self._t[0] == self._t[1]

    def swapped(self) -> "Interval":
        return Interval(self._t[1], self._t[0])

    def grown(self, t: float) -> "Interval":
        """The increasing interval holding this one and `t`."""
        return Interval(min(self.min, t), max(self.max, t))

    def union(self, o: "Interval | Iterable[float]") -> "Interval":
        o = Interval.of(o)
        return Interval(min(self.min, o.min), max(self.max, o.max))

    def intersect(self, o: "Interval | Iterable[float]") -> "Interval | None":
        """The increasing overlap, None where the two are apart; touching is a singleton."""
        o = Interval.of(o)
        t0, t1 = max(self.min, o.min), min(self.max, o.max)
        return Interval(t0, t1) if t0 <= t1 else None

    def contains(self, t: float) -> bool:
        """Whether `t` lies in the closed range, either order."""
        return self.min <= t <= self.max

    def parameter_at(self, s: float) -> float:
        """`t0 + s (t1 - t0)`: the fraction `s` of the way from `t0` (outside `0..1` extrapolates)."""
        return self._t[0] + s * (self._t[1] - self._t[0])

    def normalized_parameter_at(self, t: float) -> "float | None":
        """The fraction `t` sits from `t0` toward `t1`; None for a singleton."""
        length = self.length
        return (t - self._t[0]) / length if length != 0.0 else None

    def __iter__(self) -> Iterator[float]:
        return iter(self._t)

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Interval) and self._t == other._t

    def __hash__(self) -> int:
        return hash(("Interval", self._t))

    def __repr__(self) -> str:
        return f"Interval({self._t[0]!r}, {self._t[1]!r})"


class CurveFoot(NamedTuple):
    """The closest point of a curve value: its parameter `t`, the `point`, and `unique` --
    False where the answer is a fixed pick among equals (a circle's axis, an arc's two
    equidistant ends)."""
    t: float
    point: "tuple[float, float, float]"
    unique: bool


class SurfaceFoot(NamedTuple):
    """The closest point of a surface value: its parameters `u`, `v`, the `point`, and
    `unique` (False where the answer is a pick among equals, a sphere's centre)."""
    u: float
    v: float
    point: "tuple[float, float, float]"
    unique: bool


# CADACLYSM_BLACKSMITH_VALUE_*: the kind each value array is tagged with.
_VALUE_LINE, _VALUE_CIRCLE, _VALUE_ARC, _VALUE_ELLIPSE, _VALUE_SPHERE = 0, 1, 2, 3, 4
_VALUE_CYLINDER, _VALUE_CONE, _VALUE_TORUS, _VALUE_CUBOID = 5, 6, 7, 8
_VALUE_RECTANGLE, _VALUE_TRIANGLE, _VALUE_RAY = 9, 10, 11


def _value_array(values) -> "ctypes.Array[c_double]":
    flat = [float(v) for v in values]
    return (c_double * len(flat))(*flat)


def _value_call(name: str, kind: "int | None", v, *args, out: int) -> "tuple[float, ...]":
    """`cadaclysm_blacksmith_<name>(kind, value, *args, out)` -- `kind` None for a call that
    takes none -- its `out` doubles back, or the library's refusal raised. The ctypes and the
    wasm routes alike: `_lib()` is either."""
    buf = (c_double * out)()
    lead = () if kind is None else (kind,)
    if not getattr(_lib(), "cadaclysm_blacksmith_" + name)(*lead, _value_array(v), *args, buf):
        _fail(name)
    return tuple(buf)


def _triple(values) -> "tuple[float, float, float]":
    return (values[0], values[1], values[2])


def _flat_points(points, what: str) -> "tuple[ctypes.Array[c_double], int]":
    """Points (triples, or an (n, 3) array) as one flat array and their count."""
    flat = []
    for p in points:
        flat.extend(_point3(p, what))
    return (c_double * len(flat))(*flat), len(flat) // 3


class _Value:
    """What every value class shares: its canonical array `_v` (squared up by the library's
    `value_check` at construction, so a refusal is the library's), immutability, equality and
    hashing by type and array, iteration as the array, `bounds` and `transform`."""

    __slots__ = ("_v",)
    _KIND = -1
    _FIELDS: "tuple[str, ...]" = ()

    def _set(self, values) -> None:
        object.__setattr__(self, "_v", _value_call("value_check", self._KIND, values, out=len(values)))

    @classmethod
    def _of(cls, values):
        """A value from an array the library handed back, already canonical."""
        obj = cls.__new__(cls)
        object.__setattr__(obj, "_v", tuple(float(v) for v in values))
        return obj

    def __setattr__(self, name: str, value: object) -> None:
        raise AttributeError(f"{type(self).__name__} is immutable: cannot set {name}")

    def bounds(self) -> "tuple[tuple[float, float, float], tuple[float, float, float]]":
        """The world box, `(min, max)`."""
        b = _value_call("value_bounds", self._KIND, self._v, out=6)
        return b[0:3], b[3:6]

    def transform(self, t: "Transform | Sequence[float]"):
        """This value under `t` (a `Transform`, or 16 numbers), a value of the same type. A line
        takes any map keeping its ends apart, an ellipse any keeping it an ellipse, a triangle
        any keeping it a triangle, a ray any keeping its direction, a rectangle any keeping its
        sides square; the rest only a similarity (`Ellipse.from_circle` first for a circle)."""
        return type(self)._of(_value_call("value_transform", self._KIND, self._v, _matrix(t, "value_transform"), out=len(self._v)))

    def __iter__(self) -> Iterator[float]:
        return iter(self._v)

    def __eq__(self, other: object) -> bool:
        return type(other) is type(self) and self._v == other._v

    def __hash__(self) -> int:
        return hash((type(self).__name__, self._v))

    def __repr__(self) -> str:
        fields = ", ".join(f"{name}={getattr(self, name)!r}" for name in self._FIELDS)
        return f"{type(self).__name__}({fields})"


class _CurveValue(_Value):
    __slots__ = ()

    def point_at(self, t: float) -> "tuple[float, float, float]":
        """The point at `t`: a line's `t` runs 0..1, a circle's and an arc's is the angle from
        the frame's x toward its y, an ellipse's the eccentric angle."""
        return _value_call("curve_value_point_at", self._KIND, self._v, float(t), out=3)

    def tangent_at(self, t: float) -> "tuple[float, float, float]":
        """The unit tangent at `t`."""
        return _value_call("curve_value_tangent_at", self._KIND, self._v, float(t), out=3)

    def length(self) -> float:
        """The length (an ellipse's perimeter in closed form)."""
        return _value_call("curve_value_length", self._KIND, self._v, out=1)[0]

    def closest_point(self, p: Point3) -> CurveFoot:
        f = _value_call("curve_value_closest_point", self._KIND, self._v, _point3(p, "curve_value_closest_point"), out=5)
        return CurveFoot(f[0], f[1:4], f[4] != 0.0)

    def distance_to(self, p: Point3) -> float:
        foot = self.closest_point(p)
        return math.dist(foot.point, [float(c) for c in p])

    def to_nurbs(self) -> "NurbsCurve":
        """The exact NURBS form."""
        return NurbsCurve._of(_lib().cadaclysm_blacksmith_curve_value_to_nurbs(self._KIND, _value_array(self._v)), "curve_value_to_nurbs")


class Line(_CurveValue):
    """The segment from `start` to `end`; its parameter runs 0..1."""

    __slots__ = ()
    _KIND = _VALUE_LINE
    _FIELDS = ("start", "end")

    def __init__(self, start: Point3, end: Point3):
        self._set([*_point3(start, "Line"), *_point3(end, "Line")])

    @property
    def start(self) -> "tuple[float, float, float]":
        return self._v[0:3]

    @property
    def end(self) -> "tuple[float, float, float]":
        return self._v[3:6]


class _ConicValue(_CurveValue):
    """A curve on a frame: a circle, an arc, an ellipse (a line has none)."""

    __slots__ = ()

    @property
    def frame(self) -> "Frame":
        """The frame the curve lies on: its centre, the x its angles start from, its normal."""
        return Frame.of(self._v[0:12])


class Circle(_ConicValue):
    """The circle of `radius` about the frame's origin in its x-y plane, counter-clockwise
    about its z, from its x."""

    __slots__ = ()
    _KIND = _VALUE_CIRCLE
    _FIELDS = ("frame", "radius")

    def __init__(self, frame: FrameLike, radius: float):
        self._set([*_frame(frame), float(radius)])

    @staticmethod
    def through(a: Point3, b: Point3, c: Point3) -> "Circle":
        """The circle through three points, x toward `a`, turning `a`, `b`, `c` counter-clockwise."""
        what = "circle_through"
        return Circle._of(_value_call(what, None, _point3(a, what), _point3(b, what), _point3(c, what), out=13))

    @property
    def radius(self) -> float:
        return self._v[12]


class Arc(_ConicValue):
    """The part of a circle over `angle` (an `Interval` or two numbers, increasing by at most a
    full turn)."""

    __slots__ = ()
    _KIND = _VALUE_ARC
    _FIELDS = ("frame", "radius", "angle")

    def __init__(self, frame: FrameLike, radius: float, angle: "Interval | Iterable[float]"):
        a = Interval.of(angle)
        self._set([*_frame(frame), float(radius), a.t0, a.t1])

    @staticmethod
    def through(a: Point3, b: Point3, c: Point3) -> "Arc":
        """The arc from `a` through `b` to `c`."""
        what = "arc_through"
        return Arc._of(_value_call(what, None, _point3(a, what), _point3(b, what), _point3(c, what), out=15))

    @staticmethod
    def from_start_tangent_end(a: Point3, tangent: Point3, c: Point3) -> "Arc":
        """The arc leaving `a` along `tangent` and ending at `c`."""
        what = "arc_from_start_tangent_end"
        return Arc._of(_value_call(what, None, _point3(a, what), _point3(tangent, what), _point3(c, what), out=15))

    @property
    def radius(self) -> float:
        return self._v[12]

    @property
    def angle(self) -> Interval:
        return Interval(self._v[13], self._v[14])

    @property
    def start(self) -> "tuple[float, float, float]":
        return self.point_at(self._v[13])

    @property
    def end(self) -> "tuple[float, float, float]":
        return self.point_at(self._v[14])

    @property
    def mid(self) -> "tuple[float, float, float]":
        return self.point_at(0.5 * (self._v[13] + self._v[14]))


class Ellipse(_ConicValue):
    """The ellipse of radius `r1` along the frame's x and `r2` along its y."""

    __slots__ = ()
    _KIND = _VALUE_ELLIPSE
    _FIELDS = ("frame", "r1", "r2")

    def __init__(self, frame: FrameLike, r1: float, r2: float):
        self._set([*_frame(frame), float(r1), float(r2)])

    @staticmethod
    def from_circle(circle: Circle) -> "Ellipse":
        """`circle` as an ellipse of two equal radii -- which takes any map that keeps it one."""
        if not isinstance(circle, Circle):
            raise BuildError(f"ellipse_from_circle: a Circle, not {type(circle).__name__}")
        return Ellipse._of(_value_call("ellipse_from_circle", None, circle._v, out=14))

    @property
    def r1(self) -> float:
        return self._v[12]

    @property
    def r2(self) -> float:
        return self._v[13]


class _SolidValue(_Value):
    """A closed shape: containment, area, volume and the B-rep solid."""

    __slots__ = ()

    @property
    def frame(self) -> "Frame":
        """The frame the shape is placed on: its origin and axes."""
        return Frame.of(self._v[0:12])

    def contains(self, p: Point3, tolerance: float = 1e-9) -> bool:
        """Whether `p` lies inside the closed shape or within `tolerance` of it."""
        r = _lib().cadaclysm_blacksmith_solid_value_contains(self._KIND, _value_array(self._v), _point3(p, "solid_value_contains"), float(tolerance))
        if r == NONE:
            _fail("solid_value_contains")
        return bool(r)

    def area(self) -> float:
        """The boundary's area, a cylinder's and a cone's caps included."""
        return _value_call("solid_value_area", self._KIND, self._v, out=1)[0]

    def volume(self) -> float:
        return _value_call("solid_value_volume", self._KIND, self._v, out=1)[0]

    def to_solid(self) -> "Solid":
        """The closed B-rep solid."""
        return Solid(_checked(_lib().cadaclysm_blacksmith_solid_value_to_solid(self._KIND, _value_array(self._v)), "solid_value_to_solid"))


class _SurfaceValue(_SolidValue):
    __slots__ = ()

    def point_at(self, u: float, v: float) -> "tuple[float, float, float]":
        return _value_call("surface_value_point_at", self._KIND, self._v, float(u), float(v), out=3)

    def normal_at(self, u: float, v: float) -> "tuple[float, float, float]":
        """The outward unit normal at `(u, v)`."""
        return _value_call("surface_value_normal_at", self._KIND, self._v, float(u), float(v), out=3)

    def closest_point(self, p: Point3) -> SurfaceFoot:
        f = _value_call("surface_value_closest_point", self._KIND, self._v, _point3(p, "surface_value_closest_point"), out=6)
        return SurfaceFoot(f[0], f[1], f[2:5], f[5] != 0.0)

    def distance_to(self, p: Point3) -> float:
        return math.dist(self.closest_point(p).point, [float(c) for c in p])

    def domain(self) -> "tuple[Interval, Interval]":
        """The `u` and `v` ranges."""
        d = _value_call("surface_value_domain", self._KIND, self._v, out=4)
        return Interval(d[0], d[1]), Interval(d[2], d[3])

    def to_nurbs_sheet(self) -> "Solid":
        """The surface alone as an open sheet on its exact NURBS form."""
        return Solid(_checked(_lib().cadaclysm_blacksmith_surface_value_nurbs_sheet(self._KIND, _value_array(self._v)), "surface_value_nurbs_sheet"))


class Sphere(_SurfaceValue):
    """The sphere of `radius` about the frame's origin; `u` the longitude from its x, `v` the
    latitude toward its z."""

    __slots__ = ()
    _KIND = _VALUE_SPHERE
    _FIELDS = ("frame", "radius")

    def __init__(self, frame: FrameLike, radius: float):
        self._set([*_frame(frame), float(radius)])

    @property
    def radius(self) -> float:
        return self._v[12]


class Cylinder(_SurfaceValue):
    """The cylinder of `radius` about the frame's z over `height` (an increasing `Interval`
    along z, or two numbers), capped."""

    __slots__ = ()
    _KIND = _VALUE_CYLINDER
    _FIELDS = ("frame", "radius", "height")

    def __init__(self, frame: FrameLike, radius: float, height: "Interval | Iterable[float]"):
        h = Interval.of(height)
        self._set([*_frame(frame), float(radius), h.t0, h.t1])

    @property
    def radius(self) -> float:
        return self._v[12]

    @property
    def height(self) -> Interval:
        return Interval(self._v[13], self._v[14])


class Cone(_SurfaceValue):
    """The cone of base `radius` on the frame's x-y plane, its apex `height` up its z, capped."""

    __slots__ = ()
    _KIND = _VALUE_CONE
    _FIELDS = ("frame", "radius", "height")

    def __init__(self, frame: FrameLike, radius: float, height: float):
        self._set([*_frame(frame), float(radius), float(height)])

    @property
    def radius(self) -> float:
        return self._v[12]

    @property
    def height(self) -> float:
        return self._v[13]


class Torus(_SurfaceValue):
    """The torus of `major` radius about the frame's z and `minor` radius about that circle."""

    __slots__ = ()
    _KIND = _VALUE_TORUS
    _FIELDS = ("frame", "major", "minor")

    def __init__(self, frame: FrameLike, major: float, minor: float):
        self._set([*_frame(frame), float(major), float(minor)])

    @property
    def major(self) -> float:
        return self._v[12]

    @property
    def minor(self) -> float:
        return self._v[13]


class Cuboid(_SolidValue):
    """The box over `x`, `y`, `z` (increasing `Interval`s, or pairs) along its frame's axes."""

    __slots__ = ()
    _KIND = _VALUE_CUBOID
    _FIELDS = ("frame", "x", "y", "z")

    def __init__(self, frame: FrameLike, x: "Interval | Iterable[float]", y: "Interval | Iterable[float]",
                 z: "Interval | Iterable[float]"):
        x, y, z = Interval.of(x), Interval.of(y), Interval.of(z)
        self._set([*_frame(frame), x.t0, x.t1, y.t0, y.t1, z.t0, z.t1])

    @staticmethod
    def from_bounds(min: Point3, max: Point3) -> "Cuboid":
        """The world-aligned box from `min` to `max`."""
        what = "cuboid_from_bounds"
        out = (c_double * 18)()
        if not _lib().cadaclysm_blacksmith_cuboid_from_bounds(_point3(min, what), _point3(max, what), out):
            _fail(what)
        return Cuboid._of(out)

    @staticmethod
    def around(frame: FrameLike, points: "Iterable[Point3]") -> "Cuboid":
        """The tightest box holding `points`, aligned to `frame`."""
        what = "cuboid_around"
        xyz, n = _flat_points(points, what)
        out = (c_double * 18)()
        if not _lib().cadaclysm_blacksmith_cuboid_around(_frame(frame), xyz, n, out):
            _fail(what)
        return Cuboid._of(out)

    @property
    def x(self) -> Interval:
        return Interval(self._v[12], self._v[13])

    @property
    def y(self) -> Interval:
        return Interval(self._v[14], self._v[15])

    @property
    def z(self) -> Interval:
        return Interval(self._v[16], self._v[17])

    def corners(self) -> "list[tuple[float, float, float]]":
        """The eight corners: the `z0` face counter-clockwise about +z from `(x0, y0)`, then the
        `z1` face in the same order (Rhino's `Box.GetCorners`)."""
        c = _value_call("cuboid_corners", None, self._v, out=24)
        return [c[k:k + 3] for k in range(0, 24, 3)]

    def point_at(self, sx: float, sy: float, sz: float) -> "tuple[float, float, float]":
        """The point the fractions `sx`, `sy`, `sz` of the way along each range."""
        return _value_call("cuboid_point_at", None, self._v, float(sx), float(sy), float(sz), out=3)

    def closest_point(self, p: Point3) -> "tuple[float, float, float]":
        """The closest point of the solid box: `p` itself inside."""
        return _value_call("cuboid_closest_point", None, self._v, _point3(p, "cuboid_closest_point"), out=3)


class Rectangle(_CurveValue):
    """The rectangle over `x` and `y` (increasing `Interval`s, or pairs) in its frame's x-y
    plane -- Rhino's `Rectangle3d`. As a curve it is its boundary: `t` runs 0..4, one unit a
    side from corner 0 counter-clockwise about the frame's z (clamped outside, as Rhino's
    `PointAt`); `closest_point` is the boundary's, not unique on a tie (the centre)."""

    __slots__ = ()
    _KIND = _VALUE_RECTANGLE
    _FIELDS = ("frame", "x", "y")

    def __init__(self, frame: FrameLike, x: "Interval | Iterable[float]", y: "Interval | Iterable[float]"):
        x, y = Interval.of(x), Interval.of(y)
        self._set([*_frame(frame), x.t0, x.t1, y.t0, y.t1])

    @property
    def frame(self) -> "Frame":
        """The frame the rectangle lies on: its ranges run along the frame's x and y."""
        return Frame.of(self._v[0:12])

    @property
    def x(self) -> Interval:
        return Interval(self._v[12], self._v[13])

    @property
    def y(self) -> Interval:
        return Interval(self._v[14], self._v[15])

    def corners(self) -> "list[tuple[float, float, float]]":
        """The four corners in Rhino's `Corner(i)` order: `(x0,y0) (x1,y0) (x1,y1) (x0,y1)`."""
        c = _value_call("rectangle_corners", None, self._v, out=12)
        return [c[k:k + 3] for k in range(0, 12, 3)]

    def area(self) -> float:
        return _value_call("rectangle_area", None, self._v, out=1)[0]

    def closest_point_in(self, p: Point3, include_interior: bool = True) -> "tuple[float, float, float]":
        """Rhino's `ClosestPoint(p, includeInterior)`: `p` projected onto the plane and clamped
        into the filled rectangle with the interior, else the boundary's closest point."""
        what = "rectangle_closest_point"
        return _value_call(what, None, self._v, _point3(p, what), bool(include_interior), out=3)

    def contains(self, p: Point3, tolerance: "float | None" = None) -> str:
        """Where `p`, projected onto the plane, lies (Rhino's `Contains`): `"inside"`,
        `"outside"`, or `"on"` within `tolerance` of the boundary. None (or NaN) is unset: the
        rectangle's own effective tolerance (`tolerance.relative` times its diagonal); 0 is
        exact."""
        what = "rectangle_contains"
        r = _lib().cadaclysm_blacksmith_rectangle_contains(_value_array(self._v), _point3(p, what), _tolerance(tolerance))
        if r == NONE:
            _fail(what)
        return _containment(r, what)

    def to_sheet(self) -> "Solid":
        """The filled rectangle as a one-face planar sheet facing the frame's z."""
        return Solid(_checked(_lib().cadaclysm_blacksmith_rectangle_to_sheet(_value_array(self._v)), "rectangle_to_sheet"))


class Triangle(_Value):
    """The triangle `a`, `b`, `c` -- Rhino's `Triangle3d`. A degenerate one (collinear or
    coincident points) is refused."""

    __slots__ = ()
    _KIND = _VALUE_TRIANGLE
    _FIELDS = ("a", "b", "c")

    def __init__(self, a: Point3, b: Point3, c: Point3):
        self._set([*_point3(a, "Triangle"), *_point3(b, "Triangle"), *_point3(c, "Triangle")])

    @property
    def a(self) -> "tuple[float, float, float]":
        return self._v[0:3]

    @property
    def b(self) -> "tuple[float, float, float]":
        return self._v[3:6]

    @property
    def c(self) -> "tuple[float, float, float]":
        return self._v[6:9]

    def area(self) -> float:
        return _value_call("triangle_area", None, self._v, out=1)[0]

    def perimeter(self) -> float:
        return _value_call("triangle_perimeter", None, self._v, out=1)[0]

    def centroid(self) -> "tuple[float, float, float]":
        """The area centroid, the vertices' mean (Rhino's `AreaCenter`)."""
        return _value_call("triangle_centroid", None, self._v, out=3)

    def circumcircle(self) -> Circle:
        """The circle through `a`, `b`, `c`: x toward `a`, the normal turning them counter-clockwise."""
        return Circle._of(_value_call("triangle_circumcircle", None, self._v, out=13))

    def point_at(self, wa: float, wb: float, wc: float) -> "tuple[float, float, float]":
        """The point of barycentric weights `wa`, `wb`, `wc`, used as given."""
        return _value_call("triangle_point_at", None, self._v, float(wa), float(wb), float(wc), out=3)

    def barycentric(self, p: Point3) -> "tuple[float, float, float]":
        """The weights `(wa, wb, wc)`, summing to 1, of `p` projected onto the plane."""
        return _value_call("triangle_barycentric", None, self._v, _point3(p, "triangle_barycentric"), out=3)

    def closest_point(self, p: Point3) -> "tuple[float, float, float]":
        """The closest point of the filled triangle."""
        return _value_call("triangle_closest_point", None, self._v, _point3(p, "triangle_closest_point"), out=3)

    def distance_to(self, p: Point3) -> float:
        return math.dist(self.closest_point(p), [float(c) for c in p])

    def edge(self, i: int) -> Line:
        """Edge `i` as a line: 0 `a` to `b`, 1 `b` to `c`, 2 `c` to `a`."""
        return Line._of(_value_call("triangle_edge", None, self._v, int(i), out=6))

    def to_sheet(self) -> "Solid":
        """The filled triangle as a one-face planar sheet, its normal turning `a`, `b`, `c`
        counter-clockwise."""
        return Solid(_checked(_lib().cadaclysm_blacksmith_triangle_to_sheet(_value_array(self._v)), "triangle_to_sheet"))


class Ray(_Value):
    """The half-line from `position` along `direction` -- Rhino's `Ray3d`; the direction is
    kept as given, not unitised, so `t` counts lengths of it. A ray has no `bounds`: the
    library refuses it."""

    __slots__ = ()
    _KIND = _VALUE_RAY
    _FIELDS = ("position", "direction")

    def __init__(self, position: Point3, direction: Point3):
        self._set([*_point3(position, "Ray"), *_point3(direction, "Ray")])

    @property
    def position(self) -> "tuple[float, float, float]":
        return self._v[0:3]

    @property
    def direction(self) -> "tuple[float, float, float]":
        return self._v[3:6]

    def point_at(self, t: float) -> "tuple[float, float, float]":
        """`position + t * direction`, any `t` (behind the start too, as Rhino's `PointAt`)."""
        return _value_call("ray_point_at", None, self._v, float(t), out=3)

    def closest_point(self, p: Point3) -> CurveFoot:
        """The closest point on the ray, `t` clamped at 0 (behind the start: the start).
        Always unique."""
        f = _value_call("ray_closest_point", None, self._v, _point3(p, "ray_closest_point"), out=4)
        return CurveFoot(f[0], f[1:4], True)

    def distance_to(self, p: Point3) -> float:
        return math.dist(self.closest_point(p).point, [float(c) for c in p])


class Workplane:
    """The fluent chain, mirroring the Rust `Workplane`: a frame, the solid built
    so far, and the face last picked. A build call *replaces* the solid (as
    `Workplane::set_brep` does); combine solids explicitly with `Solid.join`.
    Every step raises `BuildError` at once rather than latching it."""

    __slots__ = ("frame", "_solid", "_selected")

    frame: tuple[float, ...]

    def __init__(self, frame: FrameLike, solid: Solid | None = None):
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
    def on(frame: FrameLike) -> "Workplane":
        return Workplane(frame)

    @staticmethod
    def from_solid(solid: Solid) -> "Workplane":
        return Workplane(_XY, solid)

    def _set(self, solid: Solid) -> "Workplane":
        self._solid, self._selected = solid, None
        return self

    def cuboid(self, x: float, y: float, z: float) -> "Workplane":
        return self._set(Solid.cuboid(x, y, z).place(self.frame))

    def cylinder(self, r: float, h: float) -> "Workplane":
        return self._set(Solid.cylinder(r, h).place(self.frame))

    def extrude(self, profile: Profile, height: float) -> "Workplane":
        return self._set(Solid.extrude(profile, self.frame, height))

    def face(self, profile: Profile) -> "Workplane":
        """The flat sheet `profile` bounds on this workplane's frame -- `Solid.face`."""
        return self._set(Solid.face(profile, self.frame))

    def revolve(self, profile: Profile, angle: float) -> "Workplane":
        """About this workplane's own y axis through its origin, as the Rust chain."""
        o, y = self.frame[0:3], self.frame[6:9]
        return self._set(Solid.revolve(profile, (o, y), angle))

    def translate(self, dx: float, dy: float, dz: float) -> "Workplane":
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


def write_step_text(solids: Sequence[Solid], schema: Schema = None, unit: Unit = "mm") -> str:
    """`schema` is one of four things: `None` (the kernel's built-in AP203, or AP242
    when any solid, face or edge is coloured -- AP203 has no colour entities); the
    path of a schema file (a string or `Path` with no newline in it, naming an
    existing file), read and sent as EXPRESS text; the bare name of a built-in
    schema (case-insensitive, e.g. `"AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF"`
    -- an unknown name raises `BuildError`); or a custom schema's own EXPRESS text.
    Colours (`coloured`, `edges_coloured`) are written as STEP styling where the
    schema has it, so `Node.colour` reads a solid's back; a named schema without it
    writes the solids bare."""
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


def write_step(path: FilePath, solids: Sequence[Solid], schema: Schema = None, unit: Unit = "mm") -> None:
    """One STEP file (AP203 unless `schema` names another, AP242 if coloured), each solid its own body.
    `schema` as `write_step_text`."""
    _FsPath(path).write_text(write_step_text(solids, schema, unit), encoding="utf-8")


def write_step_assembly_text(parts: Mapping[str, Solid], placements: Iterable[tuple[str, FrameLike]],
                             schema: Schema = None, unit: Unit = "mm") -> str:
    """An assembly as STEP text: `parts` maps a name to a solid in its own coordinates,
    each written once as its own product; `placements` is a list of `(name, frame)`,
    each an occurrence of that part at that frame (a `Frame`, or twelve numbers --
    right-handed and orthonormal), all under one root product, `assembly`. A reader
    tessellates a part once however many times it is placed, and shows each placement
    under its part's name. A part no placement names is not written. `schema` and
    `unit` as `write_step_text`."""
    if unit not in UNITS:
        raise BuildError(f"unit must be one of {sorted(UNITS)}")
    names = list(parts)
    index = {n: i for i, n in enumerate(names)}
    placements = list(placements)
    missing = [n for n, _ in placements if n not in index]
    if missing:
        raise BuildError(f"step_assembly: no part named {missing[0]!r}")
    handles = (c_void_p * max(len(names), 1))(*[parts[n]._h() for n in names])
    labels = (c_char_p * max(len(names), 1))(*[n.encode("utf-8") for n in names])
    which = (c_uint32 * max(len(placements), 1))(*[index[n] for n, _ in placements])
    flat = [v for _, f in placements for v in _frame(f)]
    frames = (c_double * max(len(flat), 1))(*flat)
    text = _lib().cadaclysm_blacksmith_step_assembly(
        handles, labels, len(names), which, frames, len(placements), _schema_text(schema), UNITS[unit]
    )
    if not text:
        _fail("step_assembly")
    if _WASM:
        return text   # the wasm returns the text itself, nothing to free
    try:
        return ctypes.string_at(text).decode("utf-8")
    finally:
        _lib().cadaclysm_blacksmith_string_free(text)


def write_step_assembly(path: FilePath, parts: Mapping[str, Solid], placements: Iterable[tuple[str, FrameLike]],
                        schema: Schema = None, unit: Unit = "mm") -> None:
    """`write_step_assembly_text` written to `path`."""
    _FsPath(path).write_text(write_step_assembly_text(parts, placements, schema, unit), encoding="utf-8")


def write_sat_text(solids: Sequence[Solid], unit: Unit = "mm") -> str:
    """Several solids as one ACIS SAT file, each its own body."""
    if unit not in UNITS:
        raise BuildError(f"unit must be one of {sorted(UNITS)}")
    handles = (c_void_p * len(solids))(*[s._h() for s in solids])
    text = _lib().cadaclysm_blacksmith_sat_text(handles, len(solids), UNITS[unit])
    if not text:
        _fail("sat_text")
    if _WASM:
        return text   # the wasm returns the text itself, nothing to free
    try:
        return ctypes.string_at(text).decode("utf-8")
    finally:
        _lib().cadaclysm_blacksmith_string_free(text)


def write_sat(path: FilePath, solids: Sequence[Solid], unit: Unit = "mm") -> None:
    """`write_sat_text` written to `path` by the library itself, which names the
    file in its refusal when it cannot."""
    if _WASM:
        # The notebook has Pyodide's own filesystem and no C file writer; the
        # refusal is worded as the C writer words its own (`sat: <path>: <why>`).
        text = write_sat_text(solids, unit)
        try:
            _FsPath(path).write_text(text, encoding="utf-8")
        except OSError as e:
            raise BuildError(f"sat: {path}: {e.strerror or e}") from None
        return
    if unit not in UNITS:
        raise BuildError(f"unit must be one of {sorted(UNITS)}")
    handles = (c_void_p * len(solids))(*[s._h() for s in solids])
    if not _lib().cadaclysm_blacksmith_sat(handles, len(solids), os.fsencode(str(path)), UNITS[unit]):
        _fail("sat")


def _warn_3dm() -> None:
    """What a `.3dm` write did not write as itself -- `last_error` on success, a line
    each -- said as one `UserWarning` per line."""
    for line in filter(None, _text(_lib().cadaclysm_blacksmith_last_error()).split("\n")):
        warnings.warn(f"3dm: {line}", stacklevel=3)


def _taken_3dm(raw, length: c_size_t, what: str) -> bytes:
    """The bytes a `.3dm` call handed over, copied out and released, its notes warned."""
    if not raw:
        _fail(what)
    _warn_3dm()
    if _WASM:
        return raw   # the wasm returns the bytes themselves, nothing to free
    try:
        return ctypes.string_at(raw, length.value)
    finally:
        _lib().cadaclysm_blacksmith_bytes_free(raw, length.value)


def _taken_bytes(raw, length: c_size_t, what: str) -> bytes:
    """The bytes a call handed over, copied out and released (the wasm hands the bytes over)."""
    if not raw:
        _fail(what)
    if _WASM:
        return raw   # the wasm returns the bytes themselves, nothing to free
    try:
        return ctypes.string_at(raw, length.value)
    finally:
        _lib().cadaclysm_blacksmith_bytes_free(raw, length.value)


def _written(data: bytes, path: "FilePath | None") -> bytes:
    """`data`, also written to `path` when one is given."""
    if path is not None:
        with open(path, "wb") as f:
            f.write(data)
    return data


def _write_3dm_bytes(path: FilePath, data: bytes, what: str) -> None:
    """The notebook's file form: Pyodide's own filesystem, refused in the C writer's words."""
    try:
        _FsPath(path).write_bytes(data)
    except OSError as e:
        raise BuildError(f"{what}: {path}: {e.strerror or e}") from None


def rhino3dm_bytes(solids: Sequence[Solid], unit: Unit = "mm") -> bytes:
    """Several solids as one Rhino `.3dm` (version 8, which Rhino 8 and 9 open), one
    object each: its exact brep, or -- where a body has no exact form there -- its mesh,
    with a `UserWarning` saying so. Each object is named as its solid is, coloured with
    the solid's own colour (a face's or an edge's own is left out) and carries the
    solid's attributes as user text. `unit` is the file's: the numbers written are the
    numbers held."""
    if unit not in UNITS:
        raise BuildError(f"unit must be one of {sorted(UNITS)}")
    handles = (c_void_p * len(solids))(*[s._h() for s in solids])
    length = c_size_t(0)
    raw = _lib().cadaclysm_blacksmith_3dm_bytes(handles, len(solids), UNITS[unit], ctypes.byref(length))
    return _taken_3dm(raw, length, "3dm_bytes")


def write_3dm(path: FilePath, solids: Sequence[Solid], unit: Unit = "mm") -> None:
    """`rhino3dm_bytes` written to `path` by the library itself, which names the file in
    its refusal when it cannot."""
    if _WASM:
        _write_3dm_bytes(path, rhino3dm_bytes(solids, unit), "3dm")
        return
    if unit not in UNITS:
        raise BuildError(f"unit must be one of {sorted(UNITS)}")
    handles = (c_void_p * len(solids))(*[s._h() for s in solids])
    if not _lib().cadaclysm_blacksmith_3dm(handles, len(solids), os.fsencode(str(path)), UNITS[unit]):
        _fail("3dm")
    _warn_3dm()


def mesh_file(solids: Sequence[Solid], format: str = "stl", names: "Sequence[str] | None" = None,  # noqa: A002
              looks: "Sequence[Sequence[float]] | None" = None, tolerance: "float | None" = None) -> bytes:
    """Several solids meshed at `tolerance` (None: each one's effective tolerance) -- each
    the mesh `Solid.mesh` hands out -- as one file's bytes in `format`: `"stl"` (binary,
    every solid in one body), `"stl-ascii"` (one body named as the first solid), `"obj"`
    (one named object a solid, no material library), `"glb"` or `"gltf"` (one named node
    a solid in a material of its own; the `.gltf` with its buffer embedded). `names` one a
    solid (None: each solid's own name, else `Solid 1`, `Solid 2`, ...). `looks` one a
    solid, six numbers each -- linear `(r, g, b, a, metallic, roughness)` in 0..1 -- the
    glTF's materials (None: each solid's own colour); STL and OBJ ignore them."""
    solids = list(solids)
    handles = (c_void_p * len(solids))(*[s._h() for s in solids])
    if names is None:
        c_names = None
    else:
        names = [str(n) for n in names]
        if len(names) != len(solids):
            raise BuildError(f"mesh_file: {len(names)} names for {len(solids)} solids")
        c_names = (c_char_p * len(names))(*[n.encode("utf-8") for n in names])
    if looks is None:
        c_looks = None
    else:
        flat = [float(v) for look in looks for v in look]
        if len(flat) != 6 * len(solids):
            raise BuildError(f"mesh_file: {len(flat)} look values for {len(solids)} solids -- 6 a solid")
        c_looks = (c_double * len(flat))(*flat)
    length = c_size_t(0)
    raw = _lib().cadaclysm_blacksmith_mesh_file(handles, len(solids), str(format).encode("utf-8"), c_names, c_looks,
                                                _tolerance(tolerance), ctypes.byref(length))
    return _taken_bytes(raw, length, "mesh_file")


def svg(things: Sequence[Solid | Profile], path: FilePath | None = None, **words: Any) -> "str | None":
    """The solids and profiles in `things` (any mix of `Solid` and `Profile`,
    in any order) as one SVG drawing -- a `<g id="solid-<i>">` per solid then
    a `<g id="profile-<i>">` per profile, each its own colour where it carries
    one. `Solid.svg`'s words: view= (front back left right top bottom iso),
    az=, el= over it, up= (default z), fov= (0, the default, is orthographic),
    size=(width, height), margin=, tolerance=, stroke=, width= (the stroke's,
    in page units), background= (`None` for transparent), edges=, curves=,
    isocurves=, polylines= (which line sets are drawn; edges by default),
    silhouettes= (also draw where each solid's surfaces turn away from the eye
    -- the outline a sphere has no edge for; **on by default**, since a sphere
    and a torus have no edges but their seams, which are never drawn, and so
    came back as a blank page without it. A line set in its own right, so
    `silhouettes=True` with `edges=False` draws the outline alone, and
    `silhouettes=False` draws the lines alone), hidden= (None, the default,
    draws every line; `"removed"` draws only what is seen, the solids hiding
    one another; `"dashed"` adds the hidden lines, dashed, in a
    `solid-<i>-hidden` group).

    With `path`, writes the file and returns `None`; without, returns the SVG
    text -- owned by this call, decoded and released before it returns.
    Raises `BuildError` for anything in `things` that is not a `Solid` or a
    `Profile`, and where both lists come out empty."""
    solids = [t for t in things if isinstance(t, Solid)]
    profiles = [t for t in things if isinstance(t, Profile)]
    if len(solids) + len(profiles) != len(things):
        raise BuildError("svg: only solids and profiles can be drawn")
    if path is not None and _WASM:
        # The notebook has Pyodide's own filesystem and no C file writer for SVG --
        # there is no cadaclysm_blacksmith_drawing_svg wasm export, the same gap
        # `sat` has (see `write_sat`) -- so the text this call already knows how
        # to get is written through Pyodide's filesystem instead.
        text = svg(things, None, **words)
        try:
            _FsPath(path).write_text(text, encoding="utf-8")
        except OSError as e:
            raise BuildError(f"svg: {path}: {e.strerror or e}") from None
        return None
    o = _svg_options(**words)
    solid_handles = (c_void_p * len(solids))(*[s._h() for s in solids])
    profile_handles = (c_void_p * len(profiles))(*[p._handle for p in profiles])
    if path is not None:
        if not _lib().cadaclysm_blacksmith_drawing_svg(solid_handles, len(solids), profile_handles, len(profiles),
                                                        os.fsencode(str(path)), ctypes.byref(o)):
            _fail("svg")
        return None
    text = _lib().cadaclysm_blacksmith_drawing_svg_text(solid_handles, len(solids), profile_handles, len(profiles), ctypes.byref(o))
    if not text:
        _fail("svg_text")
    if _WASM:
        return text   # the wasm returns the text itself, nothing to free
    try:
        return ctypes.string_at(text).decode("utf-8")
    finally:
        _lib().cadaclysm_blacksmith_string_free(text)


def write_brep_text(solids: Sequence[Solid]) -> str:
    """Several solids as one `.brep`, each its own solid under one compound (one
    solid is the file's root)."""
    handles = (c_void_p * len(solids))(*[s._h() for s in solids])
    text = _lib().cadaclysm_blacksmith_brep_text(handles, len(solids))
    if not text:
        _fail("brep_text")
    if _WASM:
        return text   # the wasm returns the text itself, nothing to free
    try:
        return ctypes.string_at(text).decode("utf-8")
    finally:
        _lib().cadaclysm_blacksmith_string_free(text)


def write_brep(path: FilePath, solids: Sequence[Solid]) -> None:
    """`write_brep_text` written to `path` -- by the library itself, or by this
    module in the browser, where the wasm has no files of the page's to write."""
    if _WASM:
        # Refused as the C writer words its own (`brep: <path>: <why>`), as write_sat.
        text = write_brep_text(solids)
        try:
            _FsPath(path).write_text(text, encoding="utf-8")
        except OSError as e:
            raise BuildError(f"brep: {path}: {e.strerror or e}") from None
        return
    handles = (c_void_p * len(solids))(*[s._h() for s in solids])
    if not _lib().cadaclysm_blacksmith_brep(handles, len(solids), str(path).encode("utf-8")):
        _fail("brep")


# ---- mechanical drawings: hidden lines, the projected outline, pages, DXF profiles ----

#: `HlrLine.kind`, as `CADACLYSM_BLACKSMITH_HLR_SHARP` .. `_BOUNDARY` number them.
HLR_KINDS = ("sharp", "smooth", "outline", "iso", "boundary")
_HLR_SOURCES = ("edge", "face", "mesh_edge")
#: `Page(units=...)`: the DXF unit codes `cadaclysm_blacksmith_page_new` takes.
PAGE_UNITS = {"unitless": 0, "in": 1, "ft": 2, "mm": 4, "cm": 5, "m": 6}


def _hlr_xyz(name: str, value) -> "tuple[float, float, float]":
    try:
        x, y, z = (float(v) for v in value)
    except (TypeError, ValueError):
        raise ValueError(f"{name} {value!r}: three numbers") from None
    return x, y, z


def _hlr_options(direction=None, up=(0.0, 0.0, 1.0), eye=None, target=(0.0, 0.0, 0.0), tolerance=None, iso=0,
                 smooth_angle=None, feature_angle=None) -> _HlrOptions:
    """The view's keywords packed into `CadaclysmBlacksmithHlrOptions`: `eye` given is a
    perspective from it toward `target`, otherwise a parallel view along `direction` (from the
    eye toward the model; default (0, 1, 0), the front)."""
    o = _HlrOptions()
    _lib().cadaclysm_blacksmith_hlr_options_init(ctypes.byref(o))
    if eye is not None:
        if direction is not None:
            raise ValueError("hlr: give direction (parallel) or eye (perspective), not both")
        o.projection = 1
        o.eye[:] = _hlr_xyz("eye", eye)
        o.target[:] = _hlr_xyz("target", target)
    elif direction is not None:
        o.direction[:] = _hlr_xyz("direction", direction)
    o.up[:] = _hlr_xyz("up", up)
    o.tolerance = _tolerance(tolerance)
    o.iso = int(iso)
    if smooth_angle is not None:
        o.smooth_angle = float(smooth_angle)
    if feature_angle is not None:
        o.feature_angle = float(feature_angle)
    return o


def _flat_beziers(flat, n: int) -> Beziers:
    """`n` Béziers of sixteen doubles each (`x y z w` per control point) as `Beziers`."""
    if n == 0:
        return Beziers(None, None, 0)
    a = _numpy().array(flat, dtype="f8").reshape(n, 4, 4)
    points, weights = a[:, :, :3], a[:, :, 3]
    points.flags.writeable = False
    weights.flags.writeable = False
    return Beziers(points, weights, n)


class HlrLine(NamedTuple):
    """One line of a hidden-line view: `kind` one of `HLR_KINDS`, `visible`, the index of the
    `solid` (or mesh) it belongs to, its `source` -- `("edge", id)`, `("face", index)` or
    `("mesh_edge", a, b)` -- and its curve as rational cubic Béziers on the view plane
    (`beziers2d`, z 0) and in space (`beziers3d`), Bézier for Bézier the same span."""
    kind: str
    visible: bool
    solid: int
    source: tuple
    beziers2d: Beziers
    beziers3d: Beziers
    length2d: float
    length3d: float


class Hlr:
    """A hidden-line view of solids or meshes (`hlr`, `hlr_mesh`): its `lines`, what the
    removal did (`report`, a dict of counts and lengths) and the `tolerance` it worked at.
    Placed on a drawing with `Page.add_view`. Immutable."""

    __slots__ = ("_handle", "lines", "report", "tolerance")

    def __init__(self, handle, what: str):
        self._handle = _checked(handle, what)
        lib = _lib()
        n = lib.cadaclysm_blacksmith_hlr_line_count(handle)
        lines = []
        for i in range(n):
            raw = _HlrLine()
            _ok(lib.cadaclysm_blacksmith_hlr_line(handle, i, ctypes.byref(raw)), "hlr_line")
            m = raw.bezier_count
            b2, b3 = (c_double * (16 * m))(), (c_double * (16 * m))()
            _ok(lib.cadaclysm_blacksmith_hlr_line_beziers2d(handle, i, b2), "hlr_line_beziers2d")
            _ok(lib.cadaclysm_blacksmith_hlr_line_beziers3d(handle, i, b3), "hlr_line_beziers3d")
            kind = _HLR_SOURCES[raw.source_kind]
            source = (kind, raw.source, raw.source2) if kind == "mesh_edge" else (kind, raw.source)
            lines.append(HlrLine(HLR_KINDS[raw.kind], bool(raw.visible), raw.solid, source,
                                 _flat_beziers(b2, m), _flat_beziers(b3, m), raw.length2d, raw.length3d))
        report = _HlrReport()
        _ok(lib.cadaclysm_blacksmith_hlr_report(handle, ctypes.byref(report)), "hlr_report")
        self.lines = lines
        self.report = {name: getattr(report, name) for name, _ in _HlrReport._fields_ if name not in ("reserved", "tolerance")}
        self.tolerance = report.tolerance

    def __del__(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_hlr_free(h)

    def __len__(self) -> int:
        return len(self.lines)

    def visible(self) -> "list[HlrLine]":
        return [line for line in self.lines if line.visible]

    def hidden(self) -> "list[HlrLine]":
        return [line for line in self.lines if not line.visible]


def hlr(solids: "Sequence[Solid]", *, direction=None, up=(0.0, 0.0, 1.0), eye=None, target=(0.0, 0.0, 0.0),
        tolerance: "float | None" = None, iso: int = 0, smooth_angle: "float | None" = None) -> Hlr:
    """Hidden-line removal of `solids`, each where it stands, every solid hiding the others:
    what a drawing of them shows, and what it shows only dashed. Seen along `direction` (from
    the eye toward the model; default `(0, 1, 0)`, the front) with `up` the page's up, or, with
    `eye`, in perspective from `eye` toward `target`. Each line is a span of an edge's own curve
    or a silhouette, exact as rational cubic Béziers; `iso` > 0 adds that many isocurves each way
    on every face; `smooth_angle` (radians, default one degree) is how near tangent two faces are
    for the edge between them to be `"smooth"`. `tolerance` None (or 0) is the solids' effective
    tolerance. View coordinates are the camera's (x right, y up), the origin on the sight line
    through the solids' box centre. `BuildError` for no solids and refused words."""
    _native("hlr")
    o = _hlr_options(direction, up, eye, target, tolerance, iso, smooth_angle)
    handles = (c_void_p * max(len(solids), 1))(*[s._h() for s in solids])
    return Hlr(_lib().cadaclysm_blacksmith_hlr(handles, len(solids), ctypes.byref(o)), "hlr")


def hlr_mesh(meshes: "Sequence[TriangleMesh]", *, direction=None, up=(0.0, 0.0, 1.0), eye=None,
             target=(0.0, 0.0, 0.0), tolerance: "float | None" = None, feature_angle: "float | None" = None) -> Hlr:
    """`hlr` of triangle meshes, each a solid of flat triangles: its lines are the edges whose
    triangles turn by more than `feature_angle` (radians, default thirty degrees), the edges of
    one triangle, and the edges between a triangle facing the eye and one facing away (outlines);
    the triangles hide exactly. Each line's `source` is `("mesh_edge", a, b)`."""
    _native("hlr_mesh")
    o = _hlr_options(direction, up, eye, target, tolerance, 0, None, feature_angle)
    handles = (c_void_p * max(len(meshes), 1))(*[m._h() for m in meshes])
    return Hlr(_lib().cadaclysm_blacksmith_hlr_mesh(handles, len(meshes), ctypes.byref(o)), "hlr_mesh")


def projected_outline(solids: "Sequence[Solid]", *, direction=None, up=(0.0, 0.0, 1.0), eye=None,
                      target=(0.0, 0.0, 0.0), tolerance: "float | None" = None) -> "list[Profile]":
    """The boundary of the union of the solids' projections, as closed profiles in view
    coordinates (as `hlr`'s): each outer loop counter-clockwise with its holes clockwise inside
    it -- a through hole seen along its axis is a hole. `hlr`'s view words."""
    _native("projected_outline")
    o = _hlr_options(direction, up, eye, target, tolerance)
    handles = (c_void_p * max(len(solids), 1))(*[s._h() for s in solids])
    return _profile_list(_lib().cadaclysm_blacksmith_projected_outline(handles, len(solids), ctypes.byref(o)), "projected_outline")


def _layer(layer: "str | None"):
    return None if layer is None else str(layer).encode("utf-8")


class Page:
    """A flat drawing page in `units` (`"mm"`, `"cm"`, `"m"`, `"in"`, `"ft"` or `"unitless"`):
    hidden-line views, profiles, hatches and text placed on it, written as SVG (`svg()`) or DXF
    R2000 (`dxf()`). Layers are made on first use: a view's own -- `visible`, `outline`, `smooth`,
    `iso`, `hidden` (dashed) -- and any other name continuous, colour 7. Mutable: each `add_*`
    changes the page."""

    __slots__ = ("_handle",)

    def __init__(self, units: str = "mm"):
        _native("Page")
        if units not in PAGE_UNITS:
            raise ValueError(f"units {units!r}: one of {', '.join(PAGE_UNITS)}")
        self._handle = _checked(_lib().cadaclysm_blacksmith_page_new(PAGE_UNITS[units]), "page_new")

    def __del__(self) -> None:
        h, self._handle = getattr(self, "_handle", None), None
        if h and _library is not None:
            _library.cadaclysm_blacksmith_page_free(h)

    def __len__(self) -> int:
        """How many entities the page holds."""
        return _lib().cadaclysm_blacksmith_page_entity_count(self._handle)

    def add_view(self, view: Hlr, at: "Point2" = (0.0, 0.0), scale: float = 1.0) -> "Page":
        """`view`'s lines on the page, a view point `p` landing at `at + scale * p`: each line as
        the entities that draw it best (lines, arcs, circles, elliptical arcs, splines)."""
        x, y = at
        _ok(_lib().cadaclysm_blacksmith_page_add_view(self._handle, view._handle, float(x), float(y), float(scale)), "page_add_view")
        return self

    def add_profile(self, profile: Profile, at: "Point2" = (0.0, 0.0), layer: "str | None" = None) -> "Page":
        """`profile`'s outline and holes on `layer` (None: `0`), moved by `at`."""
        x, y = at
        _ok(_lib().cadaclysm_blacksmith_page_add_profile(self._handle, profile._handle, _layer(layer), float(x), float(y)),
            "page_add_profile")
        return self

    def add_hatch(self, profile: Profile, pattern: str = "ANSI31", angle: float = 0.0, scale: float = 1.0,
                  at: "Point2" = (0.0, 0.0), layer: "str | None" = None) -> "Page":
        """`profile` hatched (its holes left out) on `layer` (None: `hatch`), moved by `at`:
        `pattern` `SOLID`, `ANSI31`, `ANSI37` or `ANSI32`/`STEEL`, turned `angle` radians, its
        spacing times `scale`."""
        x, y = at
        _ok(_lib().cadaclysm_blacksmith_page_add_hatch(self._handle, profile._handle, _layer(layer), str(pattern).encode("utf-8"),
                                                       float(angle), float(scale), float(x), float(y)), "page_add_hatch")
        return self

    def add_text(self, text: str, at: "Point2", height: float, angle: float = 0.0, halign: str = "left",
                 valign: str = "baseline", layer: "str | None" = None) -> "Page":
        """One line of `text` on `layer` (None: `text`) at `at`, `height` tall, turned `angle`
        radians; `halign` `left`/`center`/`right`, `valign` `baseline`/`bottom`/`middle`/`top`."""
        x, y = at
        _ok(_lib().cadaclysm_blacksmith_page_add_text(self._handle, str(text).encode("utf-8"), _layer(layer), float(x), float(y),
                                                      float(height), float(angle), halign.encode("utf-8"), valign.encode("utf-8")),
            "page_add_text")
        return self

    def svg(self) -> str:
        """The page as an SVG document, one group per layer."""
        return _owned_text(_lib().cadaclysm_blacksmith_page_svg_text(self._handle), "page_svg_text")

    def dxf(self) -> str:
        """The page as DXF R2000 (`AC1015`) text: the same text for the same page."""
        return _owned_text(_lib().cadaclysm_blacksmith_page_dxf_text(self._handle), "page_dxf_text")


def dxf_profiles(text: str, tolerance: "float | None" = None) -> "list[Profile]":
    """A DXF file's closed loops as profiles: its lines, arcs, circles, ellipses, polylines and
    splines (blocks inserted) chained end to end within `tolerance` (None: the effective
    tolerance over the drawing's extents) into closed loops, holes nested in the loops around
    them. `BuildError` for text that is not DXF, naming the line it stopped at."""
    _native("dxf_profiles")
    return _profile_list(_lib().cadaclysm_blacksmith_dxf_profiles(str(text).encode("utf-8"), _tolerance(tolerance)), "dxf_profiles")
