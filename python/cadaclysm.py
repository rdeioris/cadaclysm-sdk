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

`numpy` is imported only when triangles or polylines are actually asked for. A
script that walks the tree and reads attributes needs nothing but the standard
library.

## Everything borrows from the scene

Every pointer this ABI hands back — names, ids, attribute text, vertex and
index arrays — points into the open document and dies with it. Nothing here
copies by default, so nothing here is safe after `Scene.close()`, which is
what leaving a `with` block does.

Strings are the easy half: `ctypes` decodes `char *` into a Python `str` on the
way out, so `node.name` is already a copy and outlives anything.

Arrays are the sharp half, and **`node.mesh` hands back read-only numpy views
into the library's own memory** rather than copies. That is the deliberate
choice: `ufi.stp` is 90.5M triangles, and copying every mesh to be safe would
cost gigabytes and seconds to hand back arrays most callers upload to the GPU
and drop. Two things make the unsafe use hard to reach by accident:

* The arrays are read-only, so a stray write cannot corrupt the document.
* Each array keeps the `Scene` alive through its `.base`, so a view cannot
  outlive the scene by having merely dropped the last reference to it.

That leaves exactly one way to dangle: keeping a view past an explicit
`close()`. Call `mesh.copy()` for arrays that must outlive the scene, or
finish with them inside the `with`.
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
    "Bounds",
    "Brep",
    "CadaclysmError",
    "Convention",
    "FILE_UNITS",
    "Manifold",
    "Mesh",
    "NONE",
    "Node",
    "Placement",
    "Polylines",
    "Scene",
    "UV_WORLD",
    "ValueKind",
    "build_date",
    "declared_schema",
    "library_path",
    "license",
    "license_info",
    "license_notice_count",
    "mesh_formats",
    "open",
    "open_memory",
    "pick_file",
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


class _Polylines(ctypes.Structure):
    _fields_ = [
        ("positions", POINTER(c_float)),
        ("counts", POINTER(c_uint32)),
        ("polyline_count", c_uint32),
        ("vertex_count", c_uint32),
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
    ("cadaclysm_node_parent", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_node_child_count", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_node_child", c_uint32, [c_void_p, c_uint32, c_uint32]),
    ("cadaclysm_node_depth", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_node_name", c_char_p, [c_void_p, c_uint32]),
    ("cadaclysm_node_kind", c_char_p, [c_void_p, c_uint32]),
    ("cadaclysm_node_visible", c_bool, [c_void_p, c_uint32]),
    ("cadaclysm_node_save_mesh", c_bool, [c_void_p, c_uint32, c_char_p, c_char_p]),
    ("cadaclysm_scene_save", c_bool, [c_void_p, c_char_p, c_char_p]),
    ("cadaclysm_mesh_format_count", c_uint32, []),
    ("cadaclysm_mesh_format", c_char_p, [c_uint32]),
    ("cadaclysm_mesh_format_extension", c_char_p, [c_uint32]),
    ("cadaclysm_query", c_uint32,
     [c_void_p, c_char_p, POINTER(c_uint32), c_uint32]),
    # `NULL` for the parent, which is a `const CadaclysmWindow *`. A viewer with
    # a window of its own should pass one; this binding does not, because pyglet
    # hands out a window handle only through platform-specific attributes and a
    # wrong pointer here reaches a platform API.
    ("cadaclysm_pick_file", c_char_p, [c_void_p]),
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
    ("cadaclysm_node_surfaces", _Surfaces, [c_void_p, c_uint32]),
    ("cadaclysm_node_brep", c_void_p, [c_void_p, c_uint32]),
    ("cadaclysm_brep_release", None, [c_void_p]),
    ("cadaclysm_brep_manifold", c_bool, [c_void_p, POINTER(c_uint32)]),
    ("cadaclysm_brep_layout_id", c_char_p, []),
    ("cadaclysm_surface_matrix", None, [c_void_p, POINTER(c_float)]),
    ("cadaclysm_node_bounds", _Bounds, [c_void_p, c_uint32]),
    ("cadaclysm_node_instance_of", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_node_select_as", c_uint32, [c_void_p, c_uint32]),
    ("cadaclysm_node_generator", c_char_p, [c_void_p, c_uint32]),
    ("cadaclysm_diagnostic_count", c_uint32, [c_void_p]),
    ("cadaclysm_diagnostic", c_char_p, [c_void_p, c_uint32]),
    ("cadaclysm_node_edges", _Polylines, [c_void_p, c_uint32]),
    ("cadaclysm_node_curves", _Polylines, [c_void_p, c_uint32]),
    ("cadaclysm_node_isocurves", _Polylines, [c_void_p, c_uint32]),
    ("cadaclysm_realize_all", c_uint32, [c_void_p]),
    ("cadaclysm_realized", c_uint32, [c_void_p]),
    ("cadaclysm_realize_total", c_uint32, [c_void_p]),
    ("cadaclysm_cancel", None, [c_void_p]),
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


def mesh_formats() -> "list[tuple[str, str]]":
    """Every format `Node.save_mesh` writes, as `(name, extension)`.

    Ask rather than hard-code: a format added to the library turns up in a menu
    built from this without the client being touched, which is the whole reason
    the ABI enumerates them. The extension is carried because it is not
    derivable -- `stl-ascii` writes a `.stl`.
    """
    library = _lib()
    return [
        (_text(library.cadaclysm_mesh_format(i)),
         _text(library.cadaclysm_mesh_format_extension(i)))
        for i in range(library.cadaclysm_mesh_format_count())
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


# ---- borrowed memory, seen as numpy ---------------------------------------


class _Borrowed:
    """One block of the scene's memory, exposed through the array interface.

    Two properties come out of building views this way rather than with
    `numpy.ctypeslib.as_array`, and both are load-bearing:

    * `data` carries the read-only flag, so `numpy` marks the array
      unwriteable and a stray assignment raises instead of scribbling on the
      document's own vertex buffer.
    * The array `numpy` builds holds this object as its `.base`, and this
      object holds the scene — so no view can outlive the scene by having
      merely dropped the last reference to it. An explicit `close()` still
      invalidates every view, which is the documented sharp edge.
    """

    __slots__ = ("_scene", "__array_interface__")

    def __init__(self, scene, pointer, shape, typestr):
        self._scene = scene
        self.__array_interface__ = {
            "version": 3,
            "data": (ctypes.cast(pointer, c_void_p).value, True),
            "shape": shape,
            "typestr": typestr,
        }


def _view(scene, pointer, shape, dtype):
    """A read-only numpy view of `shape` over borrowed memory, or None if null."""
    if not pointer:
        return None
    numpy = _numpy()
    return numpy.asarray(_Borrowed(scene, pointer, shape, numpy.dtype(dtype).str))


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
    docstring — and `normals` is None for a mesh that carries none.

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
    def mesh(self) -> Mesh:
        """Its triangles, in their own frame, built now if they have not been.

        Where the node instances another these are the instanced node's
        triangles in the instanced node's frame, so two occurrences of one
        shape hand back the *same* arrays and two different transforms. Read
        the module docstring on what these views may not outlive.
        """
        raw = _lib().cadaclysm_node_mesh(self.scene._handle, self.index)
        n = raw.vertex_count
        return Mesh(
            _view(self.scene, raw.positions, (n, 3), "float32"),
            _view(self.scene, raw.normals, (n, 3), "float32"),
            # Two floats a vertex, not three: `uvs` holds `vertex_count * 2`.
            _view(self.scene, raw.uvs, (n, 2), "float32"),
            # Four floats a vertex: `colors` holds `vertex_count * 4`, RGBA.
            _view(self.scene, raw.colors, (n, 4), "float32"),
            _view(self.scene, raw.indices, (raw.index_count,), "uint32"),
            n,
            raw.index_count,
        )

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

    def walk(self):
        """This node and every node under it, parents before children."""
        stack = [self]
        while stack:
            node = stack.pop()
            yield node
            stack.extend(reversed(node.children))


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
    def diagnostics(self) -> "list[str]":
        """What this file held that the reader could not build."""
        library, handle = _lib(), self._handle
        return [
            _text(library.cadaclysm_diagnostic(handle, i))
            for i in range(library.cadaclysm_diagnostic_count(handle))
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
