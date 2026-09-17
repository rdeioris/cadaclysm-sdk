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
way any Python program would -- no generated bindings, no Rust, no build system.
Drop it beside your own script and point `CADACLYSM_BLACKSMITH_LIBRARY` at the
shared library if it is not where this looks by default (`target/release` or
`target/debug` of the repository this file ships in).

`numpy` is imported only when a mesh or polylines are asked for.

## Every array borrows from its solid

`Solid.mesh` and `Solid.edge_polylines` hand back **read-only numpy views into
the library's own cache** rather than copies. Each view keeps its `Solid` alive
through `.base`, so a view cannot outlive the solid by having merely dropped the
last reference to it. Two things can still invalidate a view:

* `Solid.close()` (or leaving a `with` block), which frees the handle.
* Meshing the same solid again at a *different* tolerance, which replaces the
  cache the earlier views point into.

Call `.copy()` on any array that must outlive either. Strings are copied on the
way out and are always safe.

## The chain mirrors the Rust `Workplane`

A build call (`cuboid`, `cylinder`, `extrude`, `extrude_tapered`, `revolve`,
`sweep`, `loft`) makes a fresh `Solid`;
combining two solids is explicit -- build the pin as its own solid, then
`plate.join(pin)`. Every step here raises `BuildError` at once with the
library's own text, rather than latching the first error until some final call.

`join`/`cut`/`common` default their `tolerance` to `0.05`, not the tighter
`1e-6` `fillet`, `chamfer` and `shell` use, for cost: a boolean meshes both
solids at its tolerance, and a curved solid at `1e-6` is hundreds of thousands
of triangles. `0.05` is what the crate's own boolean tests run at; a tighter one
is as correct, only slower.
"""

import ctypes
import enum
import os
import platform
from ctypes import (POINTER, c_bool, c_char_p, c_double, c_float, c_size_t, c_uint32, c_uint64, c_void_p)
from pathlib import Path as _FsPath   # `Path` here is the outline builder

__all__ = [
    "Axis", "BuildError", "Edge", "Path", "Profile", "Selector", "Slant", "Solid", "SweepPath", "Workplane",
    "build_date", "default_schema", "library_path", "license", "license_info", "license_notice_count", "version",
    "write_step", "write_step_text",
]

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
    """`schemas/ap203.exp`: `CADACLYSM_SCHEMAS/ap203.exp` if set, else the repository's."""
    override = os.environ.get("CADACLYSM_SCHEMAS")
    candidates = []
    if override:
        candidates.append(_FsPath(override) / "ap203.exp")
    here = _FsPath(__file__).resolve().parent
    if len(here.parents) >= 3:
        candidates.append(here.parents[2] / "schemas" / "ap203.exp")
    for c in candidates:
        if c.exists():
            return c
    raise BuildError("ap203.exp not found; pass schema= (a path or the schema's text)")


class _Mesh(ctypes.Structure):
    _fields_ = [("positions", POINTER(c_float)), ("normals", POINTER(c_float)),
                ("indices", POINTER(c_uint32)), ("vertex_count", c_uint32), ("index_count", c_uint32)]


class _Polylines(ctypes.Structure):
    _fields_ = [("points", POINTER(c_float)), ("offsets", POINTER(c_uint32)),
                ("point_count", c_uint32), ("polyline_count", c_uint32)]


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
    ("cadaclysm_blacksmith_profile_polygon", _PROFILE, [_D, c_size_t]),
    ("cadaclysm_blacksmith_profile_with_hole", _PROFILE, [_PROFILE, _PROFILE]),
    ("cadaclysm_blacksmith_translate_profile", _PROFILE, [_PROFILE, c_double, c_double]),
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
    ("cadaclysm_blacksmith_revolve", _SOLID, [_PROFILE, _D, c_double]),
    ("cadaclysm_blacksmith_revolve_open", _SOLID, [_PROFILE, _D, c_double]),
    ("cadaclysm_blacksmith_sweep_path_begin", _SWEEP_PATH, [c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_sweep_path_line_to", c_bool, [_SWEEP_PATH, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_sweep_path_arc", c_bool, [_SWEEP_PATH] + [c_double] * 7),
    ("cadaclysm_blacksmith_sweep_path_free", None, [_SWEEP_PATH]),
    ("cadaclysm_blacksmith_sweep", _SOLID, [_PROFILE, _D, _SWEEP_PATH]),
    ("cadaclysm_blacksmith_sweep_open", _SOLID, [_PROFILE, _D, _SWEEP_PATH]),
    ("cadaclysm_blacksmith_extrude_faces", _SOLID, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_place", _SOLID, [_SOLID, _D]),
    ("cadaclysm_blacksmith_translate", _SOLID, [_SOLID, c_double, c_double, c_double]),
    ("cadaclysm_blacksmith_rotate", _SOLID, [_SOLID, _D, c_double]),
    ("cadaclysm_blacksmith_mirror", _SOLID, [_SOLID, _D]),
    ("cadaclysm_blacksmith_join", _SOLID, [_SOLID, _SOLID, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_cut", _SOLID, [_SOLID, _SOLID, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_common", _SOLID, [_SOLID, _SOLID, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_split_sheet", _SOLID, [_SOLID, _SOLID, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_fillet", _SOLID, [_SOLID, _U, c_size_t, c_double, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_chamfer", _SOLID, [_SOLID, _U, c_size_t, c_double, c_double]),
    ("cadaclysm_blacksmith_shell", _SOLID, [_SOLID, c_double, _U, c_size_t, c_double, _PROGRESS, c_void_p]),
    ("cadaclysm_blacksmith_face_count", c_uint32, [_SOLID]),
    ("cadaclysm_blacksmith_select_face", c_uint32, [_SOLID, c_uint32, _D, c_uint32]),
    ("cadaclysm_blacksmith_face_frame", c_bool, [_SOLID, c_uint32, _D]),
    ("cadaclysm_blacksmith_face_kind", c_char_p, [_SOLID, c_uint32]),
    ("cadaclysm_blacksmith_edge_count", c_uint32, [_SOLID]),
    ("cadaclysm_blacksmith_edge", c_bool, [_SOLID, c_uint32, POINTER(_Edge)]),
    ("cadaclysm_blacksmith_mesh", _Mesh, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_edge_polylines", _Polylines, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_bounds", c_bool, [_SOLID, c_double, _D, _D]),
    ("cadaclysm_blacksmith_leaked_edges", c_uint32, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_unpaired_edges", c_uint32, [_SOLID, c_double]),
    ("cadaclysm_blacksmith_step", c_void_p, [POINTER(c_void_p), c_size_t, c_char_p, c_uint32]),
    ("cadaclysm_blacksmith_string_free", None, [c_void_p]),
]

_library = None


def _lib() -> ctypes.CDLL:
    global _library
    if _library is None:
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
    def path(start) -> "Path":
        return Path(start)

    def with_hole(self, hole: "Profile") -> "Profile":
        return Profile(_lib().cadaclysm_blacksmith_profile_with_hole(self._handle, hole._handle))

    def translate(self, dx, dy) -> "Profile":
        return Profile(_lib().cadaclysm_blacksmith_translate_profile(self._handle, dx, dy))


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
        w = (c_double * len(weights))(*[float(v) for v in weights]) if weights is not None else None
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

    def close(self):
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

    def close(self):
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
    def revolve(profile: Profile, axis, angle) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_revolve(profile._handle, _axis(axis), angle))

    @staticmethod
    def revolve_open(profile: Profile, axis, angle) -> "Solid":
        return Solid(_lib().cadaclysm_blacksmith_revolve_open(profile._handle, _axis(axis), angle))

    @staticmethod
    def sweep(profile: Profile, frame, path: SweepPath) -> "Solid":
        """`profile`, drawn on `frame`, carried along `path` into a closed
        solid: a straight piece of the path is an extrusion, a circular piece
        a revolution about the arc's axis, so nothing is approximated -- a
        circle along an arc is an exact torus wall. `path` is only borrowed,
        not consumed; sweep it again, open or closed, as often as needed."""
        return Solid(_lib().cadaclysm_blacksmith_sweep(profile._handle, _frame(frame), path._live()))

    @staticmethod
    def sweep_open(profile: Profile, frame, path: SweepPath) -> "Solid":
        """`sweep` for a curve rather than a face: one wall per segment per
        piece, no caps -- an open sheet, the way `extrude_open` is to
        `extrude`."""
        return Solid(_lib().cadaclysm_blacksmith_sweep_open(profile._handle, _frame(frame), path._live()))

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
    def _combine(self, f, other: "Solid", tolerance, progress) -> "Solid":
        cb, _keep = _progress(progress)
        return Solid(f(self._h(), other._h(), tolerance, cb, None))

    def join(self, other: "Solid", tolerance=0.05, progress=None) -> "Solid":
        return self._combine(_lib().cadaclysm_blacksmith_join, other, tolerance, progress)

    def cut(self, other: "Solid", tolerance=0.05, progress=None) -> "Solid":
        return self._combine(_lib().cadaclysm_blacksmith_cut, other, tolerance, progress)

    def common(self, other: "Solid", tolerance=0.05, progress=None) -> "Solid":
        return self._combine(_lib().cadaclysm_blacksmith_common, other, tolerance, progress)

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

        There is no way yet, from Python or the C ABI, to build a new solid
        from a chosen subset of a result's faces (no `drop_faces` or
        equivalent exists in this library) -- `split_sheet` only cuts, it
        does not let you keep or discard pieces."""
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
    def bounds(self):
        """`bounds_at(0.05)` -- the bounds of the tessellation at tolerance
        0.05. Use `bounds_at` for a different tolerance."""
        return self.bounds_at(0.05)

    def bounds_at(self, tolerance):
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

    # -- out
    def mesh(self, tolerance=0.05):
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

    def edge_polylines(self, tolerance=0.05):
        """The feature edges as a list of float32 (k,3) read-only views."""
        p = _lib().cadaclysm_blacksmith_edge_polylines(self._h(), tolerance)
        if not p.offsets:
            _fail("edge_polylines")
        points = _view(self, p.points, (p.point_count, 3), "f4")
        offsets = [p.offsets[i] for i in range(p.polyline_count + 1)]
        return [points[a:b] for a, b in zip(offsets, offsets[1:])]

    def step_text(self, schema=None, unit="mm") -> str:
        return write_step_text([self], schema, unit)

    def step(self, path, schema=None, unit="mm"):
        _FsPath(path).write_text(self.step_text(schema, unit), encoding="utf-8")

    # -- selecting and edges
    def select_face(self, selector: "Selector") -> int:
        kind, v, index = selector._raw()
        i = _lib().cadaclysm_blacksmith_select_face(self._h(), kind, v, index)
        if i == NONE:
            _fail("select_face")
        return i

    def face_frame(self, face: int):
        """Twelve floats: origin, x, y, z of the workplane on `face`."""
        out = (c_double * 12)()
        if not _lib().cadaclysm_blacksmith_face_frame(self._h(), face, out):
            _fail("face_frame")
        return tuple(out)

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

    def shell(self, thickness, open=(), tolerance=1e-6, progress=None) -> "Solid":  # noqa: A002
        """`open`: face indices removed so the hollow is reachable."""
        which = [int(f) for f in open]
        arr = (c_uint32 * len(which))(*which)
        cb, _keep = _progress(progress)
        return Solid(_lib().cadaclysm_blacksmith_shell(self._h(), thickness, arr, len(which), tolerance, cb, None))

    def to_scene(self, schema=None):
        """This solid as a reader `Scene`, through STEP text and `cadaclysm.open_memory`
        -- the door to `viewer.py` and the tree walk. Needs `cadaclysm.py`
        importable and its library built."""
        try:
            import cadaclysm
        except ImportError:
            raise ImportError(
                "to_scene needs the reader module: put crates/cadaclysm-capi/examples on sys.path "
                "and build its library with `cargo build --release -p cadaclysm-capi`"
            ) from None
        schema_path = _FsPath(schema) if schema is not None else default_schema()
        return cadaclysm.open_memory(self.step_text(schema_path).encode(), "stp", schema=schema_path)


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
    def direction(self):
        """Unit direction of a line edge (from its first segment), else None."""
        if not self.is_line or not self.segments:
            return None
        (a, b) = self.segments[0]
        d = [q - p for p, q in zip(a, b)]
        n = sum(x * x for x in d) ** 0.5
        return tuple(x / n for x in d) if n > 0 else None

    def __repr__(self):
        return f"Edge({self.index}, {self.kind!r}, faces={self.faces})"


_XY = (0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1)
_XZ = (0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0)
_YZ = (0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0)


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


def _schema_text(schema) -> bytes:
    """`schema` is None (the default lookup), a path, or the schema's text."""
    if schema is None:
        schema = default_schema()
    if isinstance(schema, (str, _FsPath)) and "\n" not in str(schema) and _FsPath(schema).exists():
        return _FsPath(schema).read_bytes()
    if isinstance(schema, str):
        return schema.encode()
    raise BuildError(f"schema: {schema!r} is neither a file nor schema text")


def write_step_text(solids, schema=None, unit="mm") -> str:
    if unit not in UNITS:
        raise BuildError(f"unit must be one of {sorted(UNITS)}")
    handles = (c_void_p * len(solids))(*[s._h() for s in solids])
    text = _lib().cadaclysm_blacksmith_step(handles, len(solids), _schema_text(schema), UNITS[unit])
    if not text:
        _fail("step")
    try:
        return ctypes.string_at(text).decode("utf-8")
    finally:
        _lib().cadaclysm_blacksmith_string_free(text)


def write_step(path, solids, schema=None, unit="mm"):
    """Several solids as one AP203 file, each its own body."""
    _FsPath(path).write_text(write_step_text(solids, schema, unit), encoding="utf-8")
