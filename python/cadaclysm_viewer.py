"""Draw SDK objects through a viewer library -- `solid.show()`, `scene.view()`.

A viewer is a C library implementing `cadaclysm_viewer.h`. The one in use is, in
order: the last `use(library)`; the library named by `CADACLYSM_VIEWER`; the
terminal viewer bundled with the SDK (`cadaclysm_terminal`). Importing a viewer
package calls `use()` on its library, which is how a viewer is chosen.

The objects' `show`/`view` methods call `draw()`; nothing here is needed directly
except `use()`.
"""

from __future__ import annotations

import ctypes
import math
import os
import sys
from ctypes import POINTER, c_bool, c_char_p, c_double, c_float, c_uint32, c_void_p

ABI_MAJOR = 1
VIEWS = {"front": (-90.0, 0.0), "back": (90.0, 0.0), "left": (180.0, 0.0), "right": (0.0, 0.0),
         "top": (-90.0, 90.0), "bottom": (-90.0, -90.0), "iso": (-50.0, 28.0)}
NO_EDGES = 1


class ViewerError(RuntimeError):
    """A viewer could not be found, loaded or could not draw."""


class _Options(ctypes.Structure):
    #: Field order must match `CadaclysmViewerOptions` in cadaclysm_viewer.h.
    _fields_ = [("size", c_uint32), ("up", c_uint32), ("azimuth", c_double), ("elevation", c_double),
                ("zoom", c_double), ("width", c_uint32), ("height", c_uint32), ("flags", c_uint32),
                ("hint", c_char_p)]


_SIGNATURES = {
    "cadaclysm_viewer_abi_version": (c_uint32, []),
    "cadaclysm_viewer_name": (c_char_p, []),
    "cadaclysm_viewer_last_error": (c_char_p, []),
    "cadaclysm_viewer_scene_new": (c_void_p, [c_char_p]),
    "cadaclysm_viewer_scene_free": (None, [c_void_p]),
    "cadaclysm_viewer_scene_add_mesh": (c_bool, [c_void_p, POINTER(c_float), POINTER(c_float), c_uint32,
                                                 POINTER(c_uint32), c_uint32, POINTER(c_double), POINTER(c_float)]),
    "cadaclysm_viewer_scene_add_polylines": (c_bool, [c_void_p, POINTER(c_float), c_uint32, POINTER(c_uint32),
                                                      c_uint32, POINTER(c_double), POINTER(c_float)]),
    "cadaclysm_viewer_show": (c_bool, [c_void_p, POINTER(_Options)]),
    "cadaclysm_viewer_view": (c_bool, [c_void_p, POINTER(_Options), POINTER(_Options)]),
}


class Viewer:
    """A loaded viewer library."""

    def __init__(self, library, path=None):
        self._library, self.path = library, path
        version = library.cadaclysm_viewer_abi_version()
        if version >> 16 != ABI_MAJOR:
            raise ViewerError(f"{path or library}: viewer ABI {version >> 16}.{version & 0xFFFF}, "
                              f"this SDK needs {ABI_MAJOR}.x")
        self.name = _text(library.cadaclysm_viewer_name())

    def __repr__(self):
        return f"<Viewer {self.name}>"


_current = None


def _text(raw) -> str:
    return raw.decode("utf-8", "replace") if isinstance(raw, bytes) else str(raw or "")


def _load(path) -> Viewer:
    try:
        library = ctypes.CDLL(str(path))
    except OSError as e:
        raise ViewerError(f"{path}: could not load the viewer library: {e}") from None
    for name, (restype, argtypes) in _SIGNATURES.items():
        try:
            function = getattr(library, name)
        except AttributeError:
            raise ViewerError(f"{path}: not a viewer library (no {name})") from None
        function.restype, function.argtypes = restype, argtypes
    return Viewer(library, str(path))


def use(library) -> Viewer:
    """Draw with `library` from now on: a path to a viewer library (or, for tests,
    an object with the contract's functions). Returns the viewer."""
    global _current
    _current = _load(library) if isinstance(library, (str, os.PathLike)) else Viewer(library)
    return _current


def _no_viewer(searched: str) -> ViewerError:
    return ViewerError(f"no viewer: the terminal viewer library was not found (searched: {searched}) "
                       "-- reinstall cadaclysm, set CADACLYSM_TERMINAL_LIBRARY to the library, "
                       "or set CADACLYSM_VIEWER")


def _bundled():
    """The terminal library shipped with the SDK.

    Only its absence is quiet about the cause: no terminal module, or a default search
    that found no library, raises the no-viewer message naming where it looked. A wrong
    CADACLYSM_TERMINAL_LIBRARY, or a library that is there and will not load, raises
    its own error -- those are not "no viewer", they are a broken one.
    """
    try:
        try:
            from cadaclysm import terminal  # the wheel
        except ImportError as e:
            if e.name not in ("cadaclysm", "cadaclysm.terminal"):
                raise
            import cadaclysm_terminal as terminal  # a checkout
        return terminal.library_path()
    except ModuleNotFoundError as e:
        if e.name not in ("cadaclysm_terminal", "cadaclysm.terminal"):  # the latter: the wheel's shim
            raise
        raise _no_viewer("no cadaclysm.terminal or cadaclysm_terminal module is installed") from None
    except FileNotFoundError as e:
        searched = getattr(e, "searched", None)
        if searched is None:  # CADACLYSM_TERMINAL_LIBRARY named something that is not there
            raise ViewerError(str(e)) from None
        raise _no_viewer(", ".join(str(c) for c in searched)) from None


def current() -> Viewer:
    """The viewer `show`/`view` draw with (see the module docstring for the order)."""
    global _current
    if _current is None:
        if sys.platform == "emscripten":
            raise ViewerError("in the notebook, draw with show(obj)")
        path = os.environ.get("CADACLYSM_VIEWER") or _bundled()
        if not path:
            raise _no_viewer("nothing")
        _current = _load(path)
    return _current


def _reset() -> None:
    """Forget the viewer in use (tests)."""
    global _current
    _current = None


def options(default_view, view=None, az=None, el=None, zoom=None, up=None, edges=True,
            width=None, height=None, hint=None, default_up="z") -> dict:
    """The common keywords as the contract's fields."""
    name = view or default_view
    if isinstance(name, str):
        if name not in VIEWS:
            raise ValueError(f"view {name!r}: one of {', '.join(VIEWS)}")
        base_az, base_el = VIEWS[name]
    else:
        base_az, base_el = name
    width, height = int(width or 0), int(height or 0)
    if width < 0 or height < 0:
        raise ValueError(f"width={width}, height={height}: a size is pixels, 0 or more (0 = the viewer decides)")
    up = (up or default_up).lower()
    if up not in ("y", "z"):
        raise ValueError(f"up {up!r}: 'y' or 'z'")
    return {"up": 1 if up == "y" else 0,
            "azimuth": float(base_az if az is None else az),
            "elevation": float(base_el if el is None else el),
            "zoom": math.nan if zoom is None else float(zoom),
            "width": width, "height": height,
            "flags": 0 if edges else NO_EDGES, "hint": hint}


def _struct(o: dict) -> _Options:
    s = _Options()
    s.size = ctypes.sizeof(_Options)
    for key in ("up", "azimuth", "elevation", "zoom", "width", "height", "flags"):
        setattr(s, key, o[key])
    s.hint = o["hint"].encode("utf-8", "replace") if o["hint"] else None
    return s


def _deref(p):
    """The `_Options` behind a structure, a `ctypes.byref()` or a POINTER."""
    if isinstance(p, _Options):
        return p
    if hasattr(p, "_obj"):  # ctypes.byref(...)
        return p._obj
    return p.contents


def _read(pointer) -> dict:
    """Options passed to a viewer, back as a dict (the tests' fake uses it)."""
    s = _deref(pointer)
    return {k: getattr(s, k) for k in ("up", "azimuth", "elevation", "zoom", "width", "height", "flags")}


def _write(pointer, **fields) -> None:
    s = _deref(pointer)
    for k, v in fields.items():
        setattr(s, k, v)


def _floats(a, count):
    import numpy as np

    a = np.ascontiguousarray(a, dtype=np.float32).reshape(-1)
    return a, a.ctypes.data_as(POINTER(c_float))


def _matrix(m):
    return None if m is None else (c_double * 16)(*[float(v) for v in m])


def _rgba(rgb):
    return None if rgb is None else (c_float * 4)(*[float(v) for v in list(rgb)[:3]], 1.0)


def _on_a_terminal(viewer: Viewer) -> None:
    """Refuse, for the terminal viewer, a process whose output is not a terminal's.

    Jupyter's kernel and IDLE replace `sys.stdout` with an object that is not file
    descriptor 1, so the escape codes would go past it into the kernel's or IDLE's own
    stdout. A redirected script (`python x.py > out.six`) keeps fd 1 and still writes the
    picture. Other viewers -- a window, say -- are not the terminal's business here.
    """
    if not viewer.name.startswith("cadaclysm-terminal "):
        return
    if "ipykernel" in sys.modules:
        where = "this is a Jupyter kernel, which is not one"
    else:
        try:
            fd = sys.stdout.fileno()
        except Exception:
            fd = None
        if fd == 1:
            return
        where = "sys.stdout here is not the process's standard output (IDLE, pythonw, a captured stream)"
    raise ViewerError(f"the terminal viewer draws on a terminal: {where} -- run the script from a terminal "
                      "(redirecting its output to a file works too), or select another viewer")


def draw(mode, name, meshes, polylines, opts):
    """Build a scene from `meshes` and `polylines` and show or view it.

    meshes: (positions (n,3), normals (n,3) or None, indices (m,), column-major 4x4 as
    16 numbers or None, rgb or None). polylines: (points (n,3), counts (k,), matrix or
    None, rgb or None). Returns (azimuth, elevation, zoom) after `view`, else None.
    """
    import numpy as np

    viewer = current()
    _on_a_terminal(viewer)
    lib = viewer._library
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.flush()
        except Exception:
            pass
    scene = lib.cadaclysm_viewer_scene_new(name.encode("utf-8", "replace") if name else None)
    if not scene:
        raise ViewerError(f"{viewer.name}: {_text(lib.cadaclysm_viewer_last_error())}")
    keep = []  # arrays must outlive the calls that read them
    try:
        for positions, normals, indices, matrix, rgb in meshes:
            p, pp = _floats(positions, 3)
            n, np_ = (None, None) if normals is None else _floats(normals, 3)
            i = np.ascontiguousarray(indices, dtype=np.uint32).reshape(-1)
            keep += [p, n, i]
            ok = lib.cadaclysm_viewer_scene_add_mesh(scene, pp, np_, p.size // 3,
                                                     i.ctypes.data_as(POINTER(c_uint32)), i.size,
                                                     _matrix(matrix), _rgba(rgb))
            if not ok:
                raise ViewerError(f"{viewer.name}: {_text(lib.cadaclysm_viewer_last_error())}")
        for points, counts, matrix, rgb in polylines:
            p, pp = _floats(points, 3)
            c = np.ascontiguousarray(counts, dtype=np.uint32).reshape(-1)
            keep += [p, c]
            ok = lib.cadaclysm_viewer_scene_add_polylines(scene, pp, p.size // 3,
                                                          c.ctypes.data_as(POINTER(c_uint32)), c.size,
                                                          _matrix(matrix), _rgba(rgb))
            if not ok:
                raise ViewerError(f"{viewer.name}: {_text(lib.cadaclysm_viewer_last_error())}")
        o = _struct(opts)
        if mode == "view":
            last = _Options()
            last.size = ctypes.sizeof(_Options)  # the contract's out_last size rule
            ok = lib.cadaclysm_viewer_view(scene, ctypes.byref(o), ctypes.byref(last))
            result = (last.azimuth, last.elevation, last.zoom) if ok else None
        else:
            ok = lib.cadaclysm_viewer_show(scene, ctypes.byref(o))
            result = None
        if not ok:
            raise ViewerError(f"{viewer.name}: {_text(lib.cadaclysm_viewer_last_error())}")
        return result
    finally:
        lib.cadaclysm_viewer_scene_free(scene)


def announce(owner: str, last) -> None:
    """After `view()`: the call that shows where the user left the camera."""
    if last:
        az, el, _ = last
        print(f"{owner}.show(az={az:.0f}, el={el:.0f})")
