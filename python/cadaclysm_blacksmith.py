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

from __future__ import annotations

import ctypes
import enum
import math
import numbers
import operator
import os
import platform
import sys
from ctypes import (POINTER, c_bool, c_char_p, c_double, c_float, c_int32, c_size_t, c_uint8, c_uint32, c_uint64, c_void_p)
from pathlib import Path as _FsPath   # `Path` here is the outline builder
from typing import TYPE_CHECKING

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
    "Assembly", "Axis", "Box", "BuildError", "Chain", "Classifier", "Closest", "Collider", "CollisionHit", "Curve", "Edge", "FemEdge", "FemMesh", "FemVertex", "Frame", "Hit", "Intersection", "Job", "Manifold",
    "Length", "Mass", "OrientedBox", "Operation", "Overlap", "Path", "Piece", "Profile", "Program", "Report", "ReportItem", "Selector", "Slant", "Solid", "SolidHits", "Spot", "Stock", "Subd", "SubdMesh", "SubdReport", "SweepPath", "Tool", "Workplane",
    "boxes_apart",
    "brep_layout_id", "build_date", "default_schema", "library_path", "license", "license_info", "license_notice_count",
    "option", "pair_freedom_count", "set_option", "version",
    "svg", "write_brep", "write_brep_text", "write_sat", "write_sat_text", "write_step", "write_step_assembly", "write_step_assembly_text", "write_step_text", "__version__",
]

# This file's own version (the workspace's); `version()` is the loaded library's.
__version__ = "0.11.0"

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


class _Closest(ctypes.Structure):
    #: `CadaclysmBlacksmithClosest`. `kind_a`/`kind_b` are static C strings ("face", "edge",
    #: "vertex") the library never frees; `edge_*` is NONE where the feature has no fillet-table
    #: edge. Pinned by `tests/bindings.rs`.
    _fields_ = [("distance", c_double), ("on_a", c_double * 3), ("on_b", c_double * 3),
                ("kind_a", c_char_p), ("index_a", c_uint32), ("edge_a", c_uint32),
                ("kind_b", c_char_p), ("index_b", c_uint32), ("edge_b", c_uint32), ("refined", c_int32)]


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


class _Curve(ctypes.Structure):
    _fields_ = [("kind", c_char_p), ("origin", _Point), ("x", _Point), ("y", _Point), ("z", _Point),
                ("radius", c_double), ("radius2", c_double), ("t0", c_double), ("t1", c_double),
                ("degree", c_uint32), ("knots", POINTER(c_double)), ("knot_count", c_uint32),
                ("poles", POINTER(c_double)), ("pole_count", c_uint32), ("weights", POINTER(c_double))]


class _Chain(ctypes.Structure):
    _fields_ = [("points", POINTER(c_double)), ("point_count", c_uint32), ("face_a", c_uint32), ("face_b", c_uint32),
                ("closed", c_bool), ("tangent", c_bool), ("has_curve", c_bool)]


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
_D = POINTER(c_double)
_U = POINTER(c_uint32)
_SOLID = c_void_p
_PROFILE = c_void_p
_PATH = c_void_p
_SWEEP_PATH = c_void_p
_HITS = c_void_p
_INTERSECTION = c_void_p
_FEM = c_void_p
_PROFILE_LIST = c_void_p
_ASSEMBLY = c_void_p
_COLLIDER = c_void_p
_CLASSIFIER = c_void_p
_COLLISIONS = c_void_p
_TESSELLATION = c_void_p
_TOOL = c_void_p
_STOCK = c_void_p
_JOB = c_void_p
_PROGRAMS = c_void_p
_REPORT = c_void_p
_OPERATIONS = c_void_p
_SUBD = c_void_p

_ENTRY_POINTS = [
    ("cadaclysm_blacksmith_last_error", c_char_p, []),
    ("cadaclysm_blacksmith_license_set", ctypes.c_bool, [c_char_p]),
    ("cadaclysm_blacksmith_license_info", c_char_p, []),
    ("cadaclysm_blacksmith_license_notice_count", c_uint64, []),
    ("cadaclysm_blacksmith_build_date", c_char_p, []),
    ("cadaclysm_blacksmith_version", c_char_p, []),
    ("cadaclysm_blacksmith_solid_free", None, [_SOLID]),
    ("cadaclysm_blacksmith_named", _SOLID, [_SOLID, c_char_p]),
    ("cadaclysm_blacksmith_solid_name", c_char_p, [_SOLID]),
    ("cadaclysm_blacksmith_profile_free", None, [_PROFILE]),
    ("cadaclysm_blacksmith_profile_rect", _PROFILE, [c_double, c_double]),
    ("cadaclysm_blacksmith_profile_circle", _PROFILE, [c_double]),
    ("cadaclysm_blacksmith_profile_slot", _PROFILE, [c_double, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_profile_regular_polygon", _PROFILE, [c_double, c_double, c_double, c_uint32, c_double]),
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
    ("cadaclysm_blacksmith_profile_round", _PROFILE, [_PROFILE, c_double, _U, c_size_t, c_bool]),
    ("cadaclysm_blacksmith_profile_chain", _PROFILE, [POINTER(c_void_p), c_size_t, c_double]),
    ("cadaclysm_blacksmith_profile_from_loops", _PROFILE, [POINTER(c_void_p), c_size_t]),
    ("cadaclysm_blacksmith_profile_close_loop", _PROFILE, [_PROFILE]),
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
    ("cadaclysm_blacksmith_classifier_new", _CLASSIFIER, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_classifier_contains", c_bool, [_CLASSIFIER, _D, _U]),
    ("cadaclysm_blacksmith_classifier_free", None, [_CLASSIFIER]),
    ("cadaclysm_blacksmith_contains", c_bool, [_SOLID, _D, c_double, _U]),
    ("cadaclysm_blacksmith_closest", c_bool, [_SOLID, _SOLID, c_double, _PROGRESS, c_void_p, POINTER(_Closest)]),
    ("cadaclysm_blacksmith_face_ref", c_bool, [_SOLID, c_uint32, _D]),
    ("cadaclysm_blacksmith_find_face", c_int32, [_SOLID, _D, c_int32, c_double]),
    ("cadaclysm_blacksmith_frame_midplane", c_bool, [_D, _D, _D]),
    ("cadaclysm_blacksmith_frame_through", c_bool, [_D, _D, _D, _D]),
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
    ("cadaclysm_blacksmith_intersection_free", None, [_INTERSECTION]),
    ("cadaclysm_blacksmith_intersection_chain_count", c_uint32, [_INTERSECTION]),
    ("cadaclysm_blacksmith_intersection_chain", c_bool, [_INTERSECTION, c_uint32, POINTER(_Chain)]),
    ("cadaclysm_blacksmith_intersection_curve", c_bool, [_INTERSECTION, c_uint32, POINTER(_Curve)]),
    ("cadaclysm_blacksmith_intersection_overlap_count", c_uint32, [_INTERSECTION]),
    ("cadaclysm_blacksmith_intersection_overlap", c_bool, [_INTERSECTION, c_uint32, POINTER(_Overlap)]),
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
    ("cadaclysm_blacksmith_step", c_void_p, [POINTER(c_void_p), c_size_t, c_char_p, c_uint32]),
    ("cadaclysm_blacksmith_step_assembly", c_void_p, [POINTER(c_void_p), POINTER(c_char_p), c_size_t, POINTER(c_uint32), POINTER(c_double), c_size_t, c_char_p, c_uint32]),
    ("cadaclysm_blacksmith_sat_text", c_void_p, [POINTER(c_void_p), c_size_t, c_uint32]),
    ("cadaclysm_blacksmith_sat", c_bool, [POINTER(c_void_p), c_size_t, c_char_p, c_uint32]),
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
    ("cadaclysm_blacksmith_from_brep", _SOLID, [c_void_p, c_char_p]),
    ("cadaclysm_blacksmith_brep_layout_id", c_char_p, []),
    ("cadaclysm_blacksmith_assembly_new", _ASSEMBLY, [c_char_p]),
    ("cadaclysm_blacksmith_assembly_free", None, [_ASSEMBLY]),
    ("cadaclysm_blacksmith_assembly_name", c_char_p, [_ASSEMBLY]),
    ("cadaclysm_blacksmith_assembly_place_solid", c_void_p, [_ASSEMBLY, _SOLID, _D, c_char_p]),
    ("cadaclysm_blacksmith_assembly_place_assembly", c_void_p, [_ASSEMBLY, _ASSEMBLY, _D, c_char_p]),
    ("cadaclysm_blacksmith_assembly_step", c_void_p, [_ASSEMBLY, c_char_p, c_uint32]),
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
    ("cadaclysm_blacksmith_report_count", c_uint32, [_REPORT]),
    ("cadaclysm_blacksmith_report_kind", c_char_p, [_REPORT, c_uint32]),
    ("cadaclysm_blacksmith_report_at", c_bool, [_REPORT, c_uint32, _D]),
    ("cadaclysm_blacksmith_report_size", c_double, [_REPORT, c_uint32]),
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
    ("cadaclysm_blacksmith_subd_insert_loop", _SUBD, [_SUBD, c_uint32, c_uint32, c_double]),
    ("cadaclysm_blacksmith_subd_mirror_on", _SUBD, [_SUBD, c_uint32]),
    ("cadaclysm_blacksmith_subd_mirror_off", _SUBD, [_SUBD]),
    ("cadaclysm_blacksmith_subd_full", _SUBD, [_SUBD]),
    ("cadaclysm_blacksmith_subd_edge_loop", _SUBD, [_SUBD, c_uint32, c_uint32]),
    ("cadaclysm_blacksmith_subd_smooth_mesh", c_bool, [_SUBD, c_uint32, POINTER(_SubdMesh)]),
    ("cadaclysm_blacksmith_subd_pick", c_bool, [_SUBD, _D, c_uint32, _U]),
    ("cadaclysm_blacksmith_subd_to_solid", _SOLID, [_SUBD, c_double, c_double, c_uint32, POINTER(_SubdReport)]),
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
    _BOOLS = {"path_line_to", "path_arc_to", "path_bezier_to", "path_nurbs_to", "path_conic_to",
              "path_parabola_by_vertex", "path_parabola_by_focus", "sweep_path_line_to",
              "sweep_path_arc", "slant_of_plane", "face_frame", "face_ref", "frame_midplane", "frame_through", "bounds", "bounds64", "box", "job_stock", "edge", "colour", "profile_colour", "edge_colour", "parse_colour", "manifold", "license_set", "assembly_link", "assembly_joint",
              "assembly_pair", "assembly_pair_with", "assembly_state", "assembly_sequence", "assembly_base",
              "hit", "edge_curve", "intersection_chain", "intersection_curve", "intersection_overlap", "hits_piece", "report_at",
              "fem_mesh_view", "fem_mesh_edge", "fem_mesh_vertex", "fem_mesh_open_edge", "fem_mesh_folded_edge",
              "fem_mesh_crossing",
              # collider: `solid_bounds_box`/`box_moved` write a `Box` out-param, `boxes_apart`
              # a bool, `collider_stats`/`collisions_hit` a record -- the C return is a plain
              # success flag either way, so a failure (an exception thrown) is `False` here too.
              # `box_overlaps` is deliberately absent: its C return **is** the answer, not a
              # success flag, so it takes the generic "return result" path instead.
              "solid_bounds_box", "box_moved", "boxes_apart", "collider_stats", "collisions_hit",
              # its wasm export always throws ("the wasm writes no file"); `FemMesh.save_msh`
              # never reaches it under Pyodide, writing `msh_text()` through Pyodide's own
              # filesystem as `write_sat`/`write_brep`/`svg` do, so this is the shape a direct
              # `_lib()` call would still get right rather than a path the module takes
              "fem_mesh_save_msh",
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
              # the kernel options: `option_set` returns C's success flag, and `option_get`'s
              # export returns the value C writes through `*out` (see `_back`)
              "option_set", "option_get",
              # SubD: `subd_parts`/`subd_smooth_mesh` fill a views struct and `subd_pick` an
              # id pair, C returning a success flag; `subd_pick`'s null (nothing near) is
              # `False` with an empty `last_error` in `_back`, as C leaves it
              "subd_parts", "subd_smooth_mesh", "subd_pick"}
    _FAILS = {"tool_number": NONE, "tool_diameter": float("nan"), "tool_flute_length": float("nan"),
              "tool_angle": float("nan"), "tool_corner_radius": float("nan"),
              "select_face": NONE, "leaked_edges": NONE, "unpaired_edges": NONE,
              "mesh": _Mesh(), "mesh64": _Mesh64(), "mesh_face_triangles": _FaceTriangles(), "edge_polylines": _Polylines(),
              "profile_polylines": _Polylines(), "edge_polyline_colours": _Colours(),
              "programs_count": NONE, "programs_tool": NONE,
              # `_report`/`_operations` check these against `NONE` before indexing, the same
              # precedent `programs_count`/`programs_tool` set
              "report_count": NONE, "operations_count": NONE, "operations_tool": NONE, "operations_param_count": NONE}
    # results that C writes into an out-array of doubles at this position, and the
    # wasm returns as a typed array (`bounds` fills two, `edge` a record: see `_back`)
    _OUT = {"slant_of_plane": 3, "face_frame": 2, "face_ref": 2, "frame_midplane": 2, "frame_through": 3, "report_at": 2}
    # argument positions the C call has and the wasm call does not: an array's
    # count (a typed array knows its length), the progress `user` pointer, and
    # the out-arguments above
    _DROP = {"profile_polygon": (1,), "path_nurbs_to": (2, 5), "join": (4,), "cut": (4,), "common": (4,),
             "split_sheet": (4,), "trim": (5,), "drop_faces": (2,), "profile_round": (3,), "profile_spline": (1,), "profile_chain": (1,), "profile_from_loops": (1,), "profile_piece_count": (2,), "profile_piece": (2,), "profile_trim_count": (2,), "profile_trim_chain": (2,), "loft_through": (2,), "loft_through_open": (2,), "fillet": (2, 6), "chamfer": (2,), "shell": (3, 6), "thicken": (4,), "push_pull": (5,), "push_pull_faces": (2, 6), "split": (4,), "split_by_plane": (4,), "split_by_profile": (5,), "step": (1,), "step_assembly": (2, 5), "assembly_link": (3,), "assembly_state": (5,), "assembly_sequence": (5,), "assembly_posed": (4,), "sat_text": (1,), "brep_text": (1,), "profile_text": (4,),
             "slant_of_plane": (3,), "face_frame": (2,), "face_ref": (2,), "bounds": (2, 3), "bounds64": (2, 3), "box": (1, 2), "job_stock": (1, 2), "edge": (2,), "colour": (2,), "profile_colour": (1,), "edges_coloured": (2,), "edge_colour": (2,), "parse_colour": (1,), "manifold": (1,), "hit": (2,), "edge_curve": (2,), "report_at": (2,),
             "intersect": (4,), "intersection_chain": (2,), "intersection_curve": (2,), "intersection_overlap": (2,), "svg_text": (1,), "drawing_svg_text": (1, 3),
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
             # the point count: the wasm's `xy` is a Float64Array of x, y pairs
             "job_drill": (3,),
             # the drill count: the wasm's `drills` is an array of tool handles carrying
             # its own length, as `job_drill`'s `xy` carries its own point count
             "job_machine": (4,),
             # `mass_properties` drops its `CadaclysmBlacksmithMassProperties` out-param: the
             # export returns the figures as a flat array of doubles instead
             "mass_properties": (2,),
             # the measurements drop their out-param (the export returns the figures, the
             # containment code or the closest record instead); `closest` its `progress` and
             # `user` too -- the wasm takes no progress callback
             "oriented_box": (2,), "edge_length": (3,), "profile_length": (2,),
             "classifier_contains": (2,), "contains": (3,), "closest": (3, 4, 5),
             # `option_get` drops its `*out`: the export returns the value instead
             "option_get": (1,),
             # SubD: every array's count (a typed array knows its own length), and the
             # out-params -- `subd_parts`/`subd_smooth_mesh`'s struct, `subd_pick`'s id pair
             # and `subd_to_solid`'s report -- which the exports return instead (see `_back`)
             "subd_from_parts": (1, 3, 5, 7, 9), "subd_parts": (1,), "subd_transform": (3,),
             "subd_set_crease": (2,), "subd_set_pin": (2,), "subd_extrude": (2,), "subd_inset": (2,),
             "subd_smooth_mesh": (2,), "subd_pick": (3,), "subd_to_solid": (4,)}
    # strings the C side returns as `const char*`, and the module decodes
    # `solid_name`'s wasm export returns an empty string for an unnamed solid
    # (see its own doc comment in crates/cadaclysm-wasm/src/blacksmith.rs), and
    # `str(result).encode()` below turns that into `b""` -- falsy exactly like
    # the `None` a null `const char*` decodes to on the native backend, so
    # every call site's `if raw` reads the same on both.
    _TEXTS = {"tool_shape", "version", "build_date", "face_kind", "license_info", "brep_layout_id", "assembly_name", "solid_name",
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
            if a._type_ is c_char_p:   # a name per part (`step_assembly`), as a JS array of strings
                return to_js([v.decode("utf-8") for v in a])
            kind = js.Float64Array if a._type_ is c_double else js.Uint8Array if a._type_ is c_uint8 else js.Uint32Array
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
        if short in ("edge_length", "profile_length"):   # 4 doubles, into the `_Length` (flags as 1.0/0.0)
            raw, v = args[3 if short == "edge_length" else 2]._obj, [float(x) for x in result]
            if len(v) != 4:
                raise BuildError(f"{short}: the wasm returned {len(v)} figures, not 4")
            raw.length, raw.error, raw.accuracy_met, raw.from_polyline = v[0], v[1], int(v[2]), int(v[3])
            return True
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
        if short == "option_get":   # the value, into the `c_double` behind `ctypes.byref`
            args[1]._obj.value = float(result)
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
                 isocurves=False, polylines=False, silhouettes=True) -> _SvgOptions:
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
    o.flags = ((1 if edges else 0) | (2 if curves else 0) | (4 if isocurves else 0)
               | (8 if polylines else 0) | (16 if silhouettes else 0))
    return o


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
            reason = lib.cadaclysm_blacksmith_report_reason(handle, i)
            if reason is None:
                _fail("report_reason")
            region = _profile_list(lib.cadaclysm_blacksmith_report_region(handle, i), "report_region")
            items.append(ReportItem(kind.decode("utf-8"), (out[0], out[1], out[2]), size, reason.decode("utf-8"), region))
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
    ``"boolean.finest_tolerance"``, ``"profile_boolean.point_budget"`` and
    ``"measure.default_accuracy"``. Raises `BuildError` -- and changes nothing -- for
    a name that is not an option or a value it does not take, saying which and what
    it takes."""
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
        """A regular polygon of `sides` sides (at least 3) on the circle of
        `radius` about `centre`, its first corner at `angle` radians from the
        sketch's x axis, the rest counter-clockwise."""
        cx, cy = centre
        return Profile(_lib().cadaclysm_blacksmith_profile_regular_polygon(cx, cy, radius, max(0, int(sides)), angle))

    @staticmethod
    def star(centre: Point2, outer: float, inner: float, points: int, angle: float = 0.0) -> "Profile":
        """A star of `points` tips (at least 3) on the circle of `outer` about
        `centre`, its inner corners on the circle of `inner` (positive, under
        `outer`), alternating: the first tip at `angle` radians from the
        sketch's x axis, the rest counter-clockwise."""
        cx, cy = centre
        return Profile(_lib().cadaclysm_blacksmith_profile_star(cx, cy, outer, inner, max(0, int(points)), angle))

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
    def chain(pieces: Iterable[Profile], tolerance: float = 1e-6) -> "Profile":
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

    def close_loop(self) -> "Profile":
        """This profile closed -- the forge's sketch "close": where its last segment
        stops short of its start (a path ended open), a straight segment back to it;
        where it already comes back to within 1e-9 of its extent, its last segment
        made to land on the start exactly. A closed profile comes back as it is.
        Holes are closed the same way."""
        return Profile(_lib().cadaclysm_blacksmith_profile_close_loop(self._handle))

    def with_hole(self, hole: "Profile") -> "Profile":
        return Profile(_lib().cadaclysm_blacksmith_profile_with_hole(self._handle, hole._handle))

    def to_arcs(self, tolerance: float = 0.01) -> "Profile":
        """This profile with every free-form side (a Bezier, a conic, a NURBS) replaced
        by lines and arcs within `tolerance` of it -- what a G-code writer can say.
        Lines and arcs pass through as they are, every loop closes on itself exactly,
        holes are converted the same way. Raises `BuildError` for a `tolerance` not
        positive and finite, or a spline that does not evaluate."""
        return Profile(_lib().cadaclysm_blacksmith_profile_to_arcs(self._handle, tolerance))

    def offset(self, distance: float, tolerance: float = 0.01) -> "list[Profile]":
        """This profile grown by `distance` (shrunk where it is negative), as zero or
        more profiles, all lines and arcs: outward corners rounded by `|distance|`,
        holes moving against the boundary (a hole shrinks as the profile grows).
        Free-form sides are fitted to `tolerance` first (`to_arcs`). A shrink that
        eats the whole profile is an empty list. Raises `BuildError` for a `distance`
        not finite, a `tolerance` not positive and finite, a loop with no sides, or
        loops that cross or touch."""
        return _profile_list(_lib().cadaclysm_blacksmith_profile_offset(self._handle, distance, tolerance), "profile_offset")

    def hits(self, other: Profile, tolerance: float = 1e-6) -> "list[Hit]":
        """Where this profile's curves cross, touch or run along `other`'s, both read in
        one plane, as :class:`Hit` values ordered along this profile. Points closer than
        `tolerance` merge; two curves within `tolerance` of each other for longer than it
        are one run when they part only where one ends or the stretch is flat -- one curve
        following the other, offset within `tolerance` or tilted by under about half of it,
        even where it leaves mid-both; a tangency or a shallow crossing is one point. A loop
        that stops short of its start is an open chain."""
        lib = _lib()
        h = lib.cadaclysm_blacksmith_profile_hits(self._handle, other._handle, tolerance)
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

    def common(self, other: Profile, tolerance: float = 1e-6) -> "list[Profile]":
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
        return _profile_list(_lib().cadaclysm_blacksmith_profile_common(self._handle, other._handle, tolerance), "profile_common")

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

    def pieces(self, cutters: Iterable[Profile], tolerance: float = 1e-6) -> "list[Profile]":
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
        n = lib.cadaclysm_blacksmith_profile_piece_count(self._handle, handles, len(cutters), tolerance)
        if n == 0:
            _fail("profile_piece_count")
        return [Profile(lib.cadaclysm_blacksmith_profile_piece(self._handle, handles, len(cutters), k, tolerance)) for k in range(n)]

    def trim(self, cutters: Iterable[Profile], piece: int, tolerance: float = 1e-6) -> "list[Profile]":
        """This curve with piece `piece` of `pieces(cutters)` taken away -- the
        sketch trim: what is left, as open profiles. One for a closed curve (its
        other pieces run together, starting where the removed piece ended), the
        stretches before and after for an open one, none where the piece was the
        whole curve. Raises `BuildError` for a piece the curve does not have."""
        cutters = list(cutters)
        handles = (c_void_p * len(cutters))(*[c._handle for c in cutters])   # zero-length with none: the wasm takes an array, never None
        lib = _lib()
        n = lib.cadaclysm_blacksmith_profile_trim_count(self._handle, handles, len(cutters), int(piece), tolerance)
        if n == 0:
            if _text(lib.cadaclysm_blacksmith_last_error()):
                _fail("profile_trim_count")
            return []
        return [Profile(lib.cadaclysm_blacksmith_profile_trim_chain(self._handle, handles, len(cutters), int(piece), k, tolerance)) for k in range(n)]

    def length(self, accuracy: float = 0.0) -> "Length":
        """The perimeter of the outer loop -- holes are not counted -- as a `Length`, its exact
        curves measured to the relative `accuracy` (0 asks for the library's default)."""
        out = _Length()
        if not _lib().cadaclysm_blacksmith_profile_length(self._handle, float(accuracy), ctypes.byref(out)):
            _fail("profile_length")
        return Length(out)

    def polylines(self, tolerance: float = 0.05) -> "list[numpy.ndarray]":
        """The outline, then each hole, as float32 (k,3) read-only arrays at z = 0,
        within `tolerance` of the profile's arcs and splines -- what a viewer draws it
        with. A closed loop repeats its first point at the end; an open chain (a profile
        ended open) stays open, the segments it has. Copies, valid for good (see the
        module docs)."""
        p = _lib().cadaclysm_blacksmith_profile_polylines(self._handle, tolerance)
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
    def along(curve: Profile, frame: FrameLike, tolerance: float = 0.05, open: bool = True) -> "SweepPath":  # noqa: A002
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


class Solid:
    """An exact B-rep solid (or open sheet). Immutable; every operation returns
    a new one. `close()` frees it; so does leaving a `with` block or the garbage
    collector."""

    __slots__ = ("_handle", "__weakref__")

    def __init__(self, handle: int | None):
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

    # -- building
    @staticmethod
    def cuboid(x: float, y: float, z: float) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_cuboid(x, y, z))

    @staticmethod
    def cylinder(r: float, h: float) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_cylinder(r, h))

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
    def open(path: FilePath, body: int | None = None) -> "Solid":  # noqa: A003 - `Solid.open`, the verb
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

    # -- combining
    def _combine(self, f, other: "Solid", tolerance, progress, merge=False) -> "Solid":
        cb, _keep = _progress(progress)
        out = Solid(f(self._h(), other._h(), tolerance, cb, None))
        return out.merge_flush() if merge else out

    def join(self, other: "Solid", tolerance: float = 0.05, progress: Progress = None, merge: bool = False) -> "Solid":
        """This solid and `other` as one. `merge=True` merges the flush faces the
        join leaves where the two meet in a plane or on one cylinder (`merge_flush`),
        off by default, so face and edge numbers stay as they were."""
        return self._combine(_lib().cadaclysm_blacksmith_join, other, tolerance, progress, merge)

    def cut(self, other: "Solid", tolerance: float = 0.05, progress: Progress = None, merge: bool = False) -> "Solid":
        """This solid with `other` removed; `merge` as `join`'s."""
        return self._combine(_lib().cadaclysm_blacksmith_cut, other, tolerance, progress, merge)

    def common(self, other: "Solid", tolerance: float = 0.05, progress: Progress = None, merge: bool = False) -> "Solid":
        """What this solid and `other` share; `merge` as `join`'s."""
        return self._combine(_lib().cadaclysm_blacksmith_common, other, tolerance, progress, merge)

    def trim(self, tool: "Solid", keep: Literal["outside", "inside"] = "outside", tolerance: float = 0.05,
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
        return Solid(_lib().cadaclysm_blacksmith_trim(self._h(), tool._h(), keep == "inside", tolerance, cb, None))

    def split_sheet(self, tool: "Solid", tolerance: float = 0.05, progress: Progress = None) -> "Solid":
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

    def intersect(self, other: "Solid", tolerance: float = 0.05, progress: Progress = None) -> "Intersection":
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
        be empty for a partial overlap whose outlines cross. Known limit: a crossing
        narrower than `tolerance` -- two surfaces passing within it without their
        meshes crossing -- can be missed; near-tangent contact is where this bites.

        `progress(phase, done, total)` hears "meet" on the exact route; "mesh",
        "cull", "cross", "snap" and "curve" where it falls back to the mesh route.
        Raises `BuildError` for a `tolerance` not positive and finite, a
        solid with no faces, or one that meshes to nothing."""
        lib = _lib()
        cb, _keep = _progress(progress)
        h = lib.cadaclysm_blacksmith_intersect(self._h(), other._h(), tolerance, cb, None)
        if not h:
            _fail("intersect")
        try:
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
        finally:
            lib.cadaclysm_blacksmith_intersection_free(h)

    def section(self, z: float, tolerance: float = 0.05) -> "list[Profile]":
        """This solid cut by the plane `Z = z`: its closed outlines there, in XY,
        nested into profiles with holes (boundaries counter-clockwise, holes
        clockwise), a line or a circle crossing kept exact and any other curve as
        lines within `tolerance`. A plane that misses the solid is an empty list.
        Raises `BuildError` for a `z` not finite, a `tolerance` not positive and
        finite, a face lying in the plane (section a little above or below it), or
        a crossing that does not close."""
        return _profile_list(_lib().cadaclysm_blacksmith_solid_section(self._h(), z, tolerance), "solid_section")

    def hits(self, profile: "Profile", frame: FrameLike, tolerance: float = 0.05,
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
        h = lib.cadaclysm_blacksmith_solid_profile_hits(self._h(), profile._handle, _frame(frame), tolerance, cb, None)
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

    def bounds_at(self, tolerance: float) -> "tuple[tuple[float, float, float], tuple[float, float, float]]":
        """The solid's axis-aligned bounds, over the positions of its cached
        tessellation at `tolerance` (the same cache `mesh` fills and reuses,
        so a second call at the same tolerance is free): `((min_x, min_y,
        min_z), (max_x, max_y, max_z))`."""
        lo, hi = (c_double * 3)(), (c_double * 3)()
        if not _lib().cadaclysm_blacksmith_bounds(self._h(), tolerance, lo, hi):
            _fail("bounds")
        return tuple(lo), tuple(hi)

    def bounds64(self, tolerance: float = 0.05) -> "tuple[tuple[float, float, float], tuple[float, float, float]]":
        """`bounds` from the float64 positions: exact far from the origin."""
        lo, hi = (c_double * 3)(), (c_double * 3)()
        if not _lib().cadaclysm_blacksmith_bounds64(self._h(), tolerance, lo, hi):
            _fail("bounds64")
        return tuple(lo), tuple(hi)

    def leaked_edges(self, tolerance: float = 0.05) -> int:
        """How many edges of `mesh(tolerance)` -- the triangles `mesh` and
        `face_triangles` hand out -- are bound by anything other than exactly
        two triangles -- zero for a closed solid. A hole, a fold, and a seam
        two solids share along a line (four triangles) all count here;
        `unpaired_edges` is the check that lets the seam pass. A body past its
        triangle ceiling leaves faces empty, and those open the edges they
        share with faces that meshed."""
        n = _lib().cadaclysm_blacksmith_leaked_edges(self._h(), tolerance)
        if n == NONE:
            _fail("leaked_edges")
        return n

    def unpaired_edges(self, tolerance: float = 0.05) -> int:
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

    def is_watertight(self, tolerance: float = 0.05) -> bool:
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

    def bounds_box(self, tolerance: float = 0.05) -> "Box":
        """This solid's box at `tolerance`: its boolean mesh, padded by twice that
        -- the broad phase's own bound, cheaper to move and test than the solid
        itself (`Collider` builds one per part at construction)."""
        out = _Box()
        if not _lib().cadaclysm_blacksmith_solid_bounds_box(self._h(), tolerance, ctypes.byref(out)):
            _fail("solid_bounds_box")
        return _box_of(out)

    # -- out
    def mesh(self, tolerance: float = 0.05) -> "tuple[numpy.ndarray, numpy.ndarray, numpy.ndarray]":
        """`(positions, normals, indices)` as read-only numpy arrays (float32
        (n,3), float32 (n,3), uint32 (m,)): read-only numpy views owned by a held
        tessellation of the solid at `tolerance`: nothing invalidates them -- not a
        re-mesh at another tolerance, not the solid's `close()` (copies under
        Pyodide) -- see the module docs."""
        if _WASM:
            m = _lib().cadaclysm_blacksmith_mesh(self._h(), tolerance)
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

    def mesh64(self, tolerance: float = 0.05) -> "tuple[numpy.ndarray, numpy.ndarray, numpy.ndarray]":
        """`mesh` in float64: the same tessellation (the same indices), positions and
        normals unnarrowed: read-only numpy views owned by a held tessellation of the
        solid at `tolerance`: nothing invalidates them -- not a re-mesh at another
        tolerance, not the solid's `close()` (copies under Pyodide)."""
        if _WASM:
            m = _lib().cadaclysm_blacksmith_mesh64(self._h(), tolerance)
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

    def face_triangles(self, tolerance: float = 0.05) -> "numpy.ndarray":
        """How many triangles each face meshed to at `tolerance`, a read-only
        uint32 array with one count per face in face order: the triangles of
        `mesh(tolerance)` run face by face, so face `f`'s are the `counts[f]`
        after the first `counts[:f].sum()`. The counts sum to the mesh's
        triangle count; a face that meshed to nothing counts zero. Read-only numpy
        views owned by a held tessellation of the solid at `tolerance`: nothing
        invalidates them -- not a re-mesh at another tolerance, not the solid's
        `close()` (copies under Pyodide)."""
        if _WASM:
            t = _lib().cadaclysm_blacksmith_mesh_face_triangles(self._h(), tolerance)
            if not t.counts:
                _fail("mesh_face_triangles")
            return _copied(t.counts, (t.face_count,), "u4")
        held = _Tessellation(self, tolerance, "mesh_face_triangles")
        t = _lib().cadaclysm_blacksmith_tessellation_face_triangles(held._handle_)
        return _view(held, t.counts, (t.face_count,), "u4")

    def edge_polylines(self, tolerance: float = 0.05) -> "list[numpy.ndarray]":
        """The feature edges as a list of float32 (k,3) read-only arrays: read-only
        numpy views owned by a held tessellation of the solid at `tolerance`: nothing
        invalidates them -- not a re-mesh at another tolerance, not the solid's
        `close()` (copies under Pyodide)."""
        if _WASM:
            p = _lib().cadaclysm_blacksmith_edge_polylines(self._h(), tolerance)
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

    def contains(self, point: Point3, tolerance: float = 0.05) -> str:
        """Where `point` is relative to this closed solid: `"inside"`, `"outside"`, or `"on"`
        within `tolerance` of its boundary -- absolute, in model units (default 0.05). Meshes
        the body every call -- for
        more than a few points build a `classifier` once. Raises `BuildError` for an open body,
        a point not finite, or a `tolerance` not positive and finite."""
        out = c_uint32(NONE)
        if not _lib().cadaclysm_blacksmith_contains(self._h(), _point3(point, "contains"), float(tolerance),
                                                     ctypes.byref(out)):
            _fail("contains")
        return _containment(out.value, "contains")

    def classifier(self, tolerance: float = 0.05) -> "Classifier":
        """A `Classifier` for this closed solid at `tolerance` -- absolute, in model units
        (default 0.05): the body meshed once, then asked point after point. It keeps its own
        reference to the body, so it goes on answering after this solid is closed."""
        return Classifier(self, tolerance)

    def closest(self, other: "Solid", tolerance: float = 0.05, progress: Progress = None) -> "Closest":
        """The closest points between this solid's boundary and `other`'s, to `tolerance` --
        absolute, in model units (default 0.05) -- as a `Closest`; this solid is side `a`.
        Boundaries are measured, not volumes: a solid inside another is its gap to the outer
        one's skin, never 0 by containment (ask `contains` for that). `progress(phase, done,
        total)` hears "meshing", "pruning" and "refining"; in the browser it is never called.
        Raises `BuildError` for a `tolerance` not positive and finite or a solid with no faces."""
        cb, _keep = _progress(progress)
        out = _Closest()
        if not _lib().cadaclysm_blacksmith_closest(self._h(), other._h(), float(tolerance), cb, None,
                                                    ctypes.byref(out)):
            _fail("closest")
        return Closest(out)

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

    def find_face(self, face_ref: Sequence[float], hint: int | None = None, tolerance: float = 1e-3) -> "int | None":
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
        found = _lib().cadaclysm_blacksmith_find_face(self._h(), (c_double * 8)(*values), -1 if hint is None else int(hint), tolerance)
        if found == -2:
            _fail("find_face")
        return None if found < 0 else int(found)

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

    def edge_polyline_colours(self, tolerance: float = 0.05) -> "list[tuple[float, float, float] | None]":
        """A colour per polyline of `edge_polylines(tolerance)`, as drawn: (r, g, b),
        or None for a polyline on no coloured edge; an empty list where the solid has
        no edge paint at all. Copied out, as every solid array is."""
        c = _lib().cadaclysm_blacksmith_edge_polyline_colours(self._h(), tolerance)
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

    def fillet(self, edges: Iterable[Edge | int], radius: float, tolerance: float = 1e-6,
               progress: Progress = None) -> "Solid":
        """`edges`: `Edge` objects or their indices."""
        which = _indices(edges, "fillet", "edges", edges=True)
        arr = (c_uint32 * len(which))(*which)
        cb, _keep = _progress(progress)
        return Solid(_lib().cadaclysm_blacksmith_fillet(self._h(), arr, len(which), radius, tolerance, cb, None))

    def chamfer(self, edges: Iterable[Edge | int], distance: float, tolerance: float = 1e-6) -> "Solid":
        """`fillet` with a flat bevel: each edge cut back `distance` along both
        its faces. `edges`: `Edge` objects or their indices."""
        which = _indices(edges, "chamfer", "edges", edges=True)
        arr = (c_uint32 * len(which))(*which)
        return Solid(_lib().cadaclysm_blacksmith_chamfer(self._h(), arr, len(which), distance, tolerance))

    def push_pull(self, face: int | Iterable[int], distance: float, tolerance: float = 0.05,
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
            return Solid(_lib().cadaclysm_blacksmith_push_pull(self._h(), k, distance, tolerance, cb, None))
        if face is None or isinstance(face, (bool, str, bytes, Edge)) or isinstance(face, numbers.Number):
            thing = "an Edge" if isinstance(face, Edge) else repr(face)
            raise TypeError(f"push_pull: face must be a face index or a list of indices, not {thing}")
        which = _indices(face, "push_pull", "face")
        arr = (c_uint32 * len(which))(*which)
        return Solid(_lib().cadaclysm_blacksmith_push_pull_faces(self._h(), arr, len(which), distance, tolerance, cb, None))

    def split(self, tool: "Solid", tolerance: float = 0.05, progress: Progress = None) -> "list[Solid]":
        """This solid split by `tool` into bodies: a
        closed `tool` gives the parts outside it, then the parts inside; a flat
        sheet (a `face`) splits by the whole plane it lies on. Each connected
        part is a body of its own, so a U cut across both arms is three. The
        new faces are pieces of the tool's; colours carry over."""
        cb, _keep = _progress(progress)
        return Solid(_lib().cadaclysm_blacksmith_split(self._h(), tool._h(), tolerance, cb, None)).lumps()

    def split_by_plane(self, plane: FrameLike, tolerance: float = 0.05, progress: Progress = None) -> "list[Solid]":
        """This solid split by the plane through `plane`'s origin, square to its
        z: the bodies in front of it (on z's side) first, then those behind."""
        cb, _keep = _progress(progress)
        return Solid(_lib().cadaclysm_blacksmith_split_by_plane(self._h(), _frame(plane), tolerance, cb, None)).lumps()

    def split_by_profile(self, profile: "Profile", frame: FrameLike, tolerance: float = 0.05, progress: Progress = None) -> "list[Solid]":
        """This solid split by the closed `profile` drawn on `frame`, pushed straight
        through it along the frame's z both ways -- a split by a sketch
        profile: the bodies outside the profile first, then those inside. Where the
        plane lies along z does not matter, only the outline across it."""
        cb, _keep = _progress(progress)
        return Solid(_lib().cadaclysm_blacksmith_split_by_profile(self._h(), profile._handle, _frame(frame), tolerance, cb, None)).lumps()

    def lumps(self) -> "list[Solid]":
        """This solid's connected bodies, each a solid of its own -- faces
        sharing an edge are one body. One body comes back as itself; a boolean
        that leaves two parts, or a split, gives several, in the order of
        their first faces."""
        h = self._h()
        n = _lib().cadaclysm_blacksmith_lump_count(h)
        if n == 0:
            _fail("lump_count")
        return [Solid(_lib().cadaclysm_blacksmith_lump(h, i)) for i in range(n)]

    def refillet(self, face: int, radius: float, tolerance: float = 1e-6) -> "Solid":
        """The round `face` belongs to -- a fillet's bands, balls and rim bands joined
        to that face -- made again at `radius`, as a press-pull on a fillet
        face: taken back to the sharp edges it replaced, and those rounded again.
        Rounds of straight edges between planes and of circular rims beside a plane."""
        return Solid(_lib().cadaclysm_blacksmith_refillet(self._h(), face, radius, tolerance))

    def unfillet(self, face: int) -> "Solid":
        """The round `face` belongs to taken off, the faces beside it sharp again --
        the delete of a fillet face. The same rounds as `refillet`."""
        return Solid(_lib().cadaclysm_blacksmith_unfillet(self._h(), face))

    def rechamfer(self, face: int, distance: float, tolerance: float = 1e-6) -> "Solid":
        """The chamfer `face` belongs to -- its bevels, flat or round a rim, and the
        corner triangles joined to that face -- cut again at `distance`, as a press-pull on a chamfer face: taken back to the sharp edges it cut, and those
        bevelled again."""
        return Solid(_lib().cadaclysm_blacksmith_rechamfer(self._h(), face, distance, tolerance))

    def unchamfer(self, face: int) -> "Solid":
        """The chamfer `face` belongs to taken off, the faces beside it sharp again --
        the delete of a chamfer face. The same chamfers as `rechamfer`."""
        return Solid(_lib().cadaclysm_blacksmith_unchamfer(self._h(), face))

    def merge_flush(self) -> "Solid":
        """This solid with its flush faces merged: flat faces on one plane, facing one
        way and meeting, made one face, and the vertices left mid-way along a straight
        edge taken out -- the seams a `join` leaves where two parts are flush."""
        return Solid(_lib().cadaclysm_blacksmith_merge_flush(self._h()))

    def shell(self, thickness: float, open: Iterable[int] = (), tolerance: float = 1e-6,  # noqa: A002
              progress: Progress = None) -> "Solid":
        """`open`: face indices removed so the hollow is reachable."""
        which = _indices(open, "shell", "open")
        arr = (c_uint32 * len(which))(*which)
        cb, _keep = _progress(progress)
        return Solid(_lib().cadaclysm_blacksmith_shell(self._h(), thickness, arr, len(which), tolerance, cb, None))

    def thicken(self, thickness: float, tolerance: float = 1e-6, progress: Progress = None) -> "Solid":
        """This sheet made a solid `thickness` thick: its faces,
        their twins moved `thickness` along the faces' normals (against them for a
        negative thickness), and a wall round every open edge. A closed sheet thickens
        to a hollow."""
        cb, _keep = _progress(progress)
        return Solid(_lib().cadaclysm_blacksmith_thicken(self._h(), thickness, tolerance, cb, None))

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
    its first point) -- empty for a partial overlap whose outlines cross."""

    __slots__ = ("faces", "loops")

    faces: tuple[int, int]
    loops: tuple[tuple[tuple[float, float, float], ...], ...]

    def __init__(self, faces: tuple[int, int], loops: tuple[tuple[tuple[float, float, float], ...], ...]):
        self.faces, self.loops = faces, loops

    def __repr__(self) -> str:
        return f"Overlap(faces={self.faces}, loops={len(self.loops)})"


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

    def __init__(self, solid: Solid, tolerance: float = 0.05):
        self._handle = _checked(_lib().cadaclysm_blacksmith_classifier_new(solid._h(), float(tolerance)),
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


class Collider:
    """Parts meshed once, asked pose after pose which of them interfere: `solids`
    at rest, meshed at `tolerance`; `groups` one group index per solid (`None`:
    each solid its own group -- `check` then takes one frame per solid), `allowed`
    pairs of part indices never tested (designed contacts, by part index, flat:
    `(a0, b0, a1, b1, ...)`). `close()` frees this handle; so does leaving a `with`
    block or the garbage collector."""

    __slots__ = ("_handle",)

    def __init__(self, solids: Iterable[Solid], tolerance: float = 0.05, groups: Sequence[int] | None = None,
                 allowed: Iterable[int] = ()):
        handles = [s._h() for s in solids]
        if groups is not None and len(groups) != len(handles):
            raise BuildError(f"Collider: groups must have one entry per solid ({len(handles)} solids, {len(groups)} groups)")
        parts = (c_void_p * len(handles))(*handles)
        groups_arr = None if groups is None else (c_uint32 * len(groups))(*[int(g) for g in groups])
        allowed = [int(v) for v in allowed]
        allowed_arr = (c_uint32 * len(allowed))(*allowed)
        h = _lib().cadaclysm_blacksmith_collider_new(parts, len(handles), tolerance, groups_arr, allowed_arr, len(allowed) // 2)
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
        self._handle_ = _lib().cadaclysm_blacksmith_tessellation(solid._h(), tolerance)
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
        report. The reader module's `Node.fem_mesh` sets it for a node with no brep (a
        JT, an STL, an OpenSCAD body), where it also says which space the mesh is in --
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
    `"undercut"` or `"too_deep"`), `at` (x, y, z), `size` (its meaning per `kind`),
    `reason` (one sentence naming the tool involved), and `region` (its XY area, as
    a list of `Profile`). Read-only."""

    __slots__ = ("kind", "at", "size", "reason", "region")

    kind: str
    at: tuple[float, float, float]
    size: float
    reason: str
    region: list[Profile]

    def __init__(self, kind: str, at: "tuple[float, float, float]", size: float, reason: str, region: "list[Profile]"):
        object.__setattr__(self, "kind", kind)
        object.__setattr__(self, "at", at)
        object.__setattr__(self, "size", size)
        object.__setattr__(self, "reason", reason)
        object.__setattr__(self, "region", region)

    def __setattr__(self, key: str, value: object) -> None:
        raise AttributeError(f"ReportItem.{key} is read-only")

    def __delattr__(self, key: str) -> None:
        raise AttributeError(f"ReportItem.{key} is read-only")

    def __repr__(self) -> str:
        return f"ReportItem(kind={self.kind!r}, at={self.at!r}, size={self.size!r}, reason={self.reason!r}, region={len(self.region)} profile(s))"


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

    def machine(self, part: "Solid", end_mill: Tool, drills: Tool | Iterable[Tool] = (), stepover: float | None = None,
                stepdown: float | None = None, skin: float = 0.3, peck: float | None = None) -> Report:
        """Recognise `part` and append the operations that make it: faced, contoured
        and pocketed with `end_mill`, its holes drilled with whichever of `drills`
        fits each -- a tool per required diameter. `stepover` and `stepdown` default
        to the kernel's own (`None`, not a number, asks for that); `skin` (at least 0,
        default 0.3) is how far above the part's lowest point the outline stops, so
        the part stays attached to the stock -- `0` cuts through; `peck` defaults to
        none (a drill straight to depth). `drills` may be one `Tool` as well as a list
        of them. Returns a `Report` of what could not be cut. Raises `TypeError` for a
        `part` that is not a `Solid`, an `end_mill` or a drill that is not a `Tool`;
        `BuildError` for what the kernel refuses (a drill as `end_mill`, ...); the job
        changes only on success -- a refusal leaves it exactly as it was. Raises
        `ValueError` when two of the offered tools share a number but are different
        tools; only the tools the added operations use are kept in `Job.tools`."""
        if not isinstance(part, Solid):
            raise TypeError(f"machine: part must be a Solid, not {type(part).__name__}")
        if not isinstance(end_mill, Tool):
            raise TypeError(f"machine: end_mill must be a Tool, not {type(end_mill).__name__}")
        tools = [drills] if isinstance(drills, Tool) else list(drills)
        for i, t in enumerate(tools):
            if not isinstance(t, Tool):
                raise TypeError(f"machine: drills[{i}] must be a Tool, not {type(t).__name__}")
        offered = {}
        for t in (end_mill, *tools):
            other = offered.setdefault(t.number, t)
            if other is not t and _tool_key(other) != _tool_key(t):
                raise ValueError(f"machine: tool T{t.number} differs from the tool T{other.number} offered with it")
        before = len(self.operations())
        handles = (c_void_p * len(tools))(*[t._handle for t in tools])   # zero-length with none: the wasm takes an array, never None
        handle = _lib().cadaclysm_blacksmith_job_machine(
            self._handle, part._h(), end_mill._handle, handles, len(tools),
            float("nan") if stepover is None else stepover,
            float("nan") if stepdown is None else stepdown,
            skin,
            float("nan") if peck is None else peck,
        )
        report = _report(handle, "job_machine")   # raises on a refusal: nothing is kept then
        used = {op.tool for op in self.operations()[before:]}   # only a tool a program uses can be found by its T number
        self._keep(*[t for t in (end_mill, *tools) if t.number in used])
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

    def __iter__(self) -> Iterator[float]:
        return iter(self._v)

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Frame) and self._v == other._v

    def __hash__(self) -> int:
        return hash(self._v)

    def __repr__(self) -> str:
        return f"Frame(origin={self.origin}, x={self.x}, y={self.y}, z={self.z})"


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
    `silhouettes=False` draws the lines alone).

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
