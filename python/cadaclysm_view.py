"""Draw SDK objects through a view library -- `solid.show()`, `scene.view()`.

A view library implements `cadaclysm_view.h`. The one in use is, in order: the last
`use(library)`; the library named by `CADACLYSM_VIEW`; the terminal library bundled
with the SDK (`cadaclysm_terminal`). `use()` takes the two words `"terminal"` and
`"wgpu"` (`cadaclysm_view`, a GPU window), a path to a view library, or -- for tests
-- an object implementing the contract's functions directly; `CADACLYSM_VIEW` takes
the same two words or a path. Importing this module loads no library.

`View`/`pump` are elsewhere; nothing here is needed directly except `use()`.

The objects' `show`/`view` methods call `present()`, by handle on every library: on wgpu
into the one shared window (or a fresh one for `view()`); on the terminal (or a library of
your own) `show` prints one still from a fresh view, `view` runs it.
"""

from __future__ import annotations

import atexit
import contextlib
import ctypes
import math
import os
import sys
import threading
import time
import weakref
from ctypes import POINTER, c_bool, c_char_p, c_double, c_float, c_uint32, c_void_p

ABI_MAJOR = 1
ABI_MINOR = 4
VIEWS = {"front": (-90.0, 0.0), "back": (90.0, 0.0), "left": (180.0, 0.0), "right": (0.0, 0.0),
         "top": (-90.0, 90.0), "bottom": (-90.0, -90.0), "iso": (-50.0, 28.0)}
NO_EDGES = 1

_RADIANS_PER_PIXEL = 0.01   # cadaclysm_view::view::ORBIT_PER_PIXEL: a drag's turn per pixel
_ZOOM_PER_STEP = 0.9        # cadaclysm_view::view::ZOOM_PER_STEP: one wheel step's distance ratio
_STANDARD_TOP, _STANDARD_FRONT = 0, 1

_OPEN, _CLOSED = 1, 2
_INPUT_CLOSE, _INPUT_PICKED = 1, 2
_WINDOW_KINDS = {"win32": 1, "xlib": 2, "xcb": 3, "wayland": 4, "appkit": 5}
_SURFACES = {"exact": 0, "triangles": 1}
_LOD_MOTION = {"detailed": 0, "smooth": 1}
_STANDARD = {"top": 0, "front": 1, "right": 2, "iso": 3}
_LAYERS = {"surfaces": 0, "edges": 1, "curves": 2, "isocurves": 3, "grid": 4}
_GRIDS = {"none": 0, "top": 1, "front": 2, "right": 3}
_EVENTS = {"pointer_down": 1, "pointer_move": 2, "pointer_up": 3, "pointer_cancel": 4, "wheel": 5, "key": 6}
_POINTERS = {"mouse": 0, "touch": 1, "pen": 2}


class ViewError(RuntimeError):
    """A view library could not be found, loaded or could not draw."""


class _Options(ctypes.Structure):
    #: CadaclysmViewOptions, cadaclysm_view.h 1.4.
    _fields_ = [("size", c_uint32), ("surfaces", c_uint32), ("backend", c_uint32), ("y_up", c_uint32),
                ("title", c_char_p), ("width", c_uint32), ("height", c_uint32), ("offscreen", c_uint32)]


class _Window(ctypes.Structure):
    _fields_ = [("size", c_uint32), ("kind", c_uint32), ("window", c_void_p), ("window_id", ctypes.c_uint64),
                ("display", c_void_p), ("width", c_uint32), ("height", c_uint32)]


class _Image(ctypes.Structure):
    _fields_ = [("size", c_uint32), ("corners", c_float * 12), ("rgba", POINTER(ctypes.c_uint8)),
                ("width", c_uint32), ("height", c_uint32), ("opacity", c_float), ("flip_x", c_uint32), ("flip_y", c_uint32)]


class _Event(ctypes.Structure):
    _fields_ = [("size", c_uint32), ("kind", c_uint32), ("pointer_id", c_uint32), ("pointer", c_uint32),
                ("button", c_uint32), ("shift", c_uint32), ("x", c_float), ("y", c_float), ("wheel_y", c_float),
                ("key", c_char_p), ("key_down", c_uint32), ("time_ms", c_double)]


class _Viewport(ctypes.Structure):
    _fields_ = [("size", c_uint32), ("rect", c_uint32 * 4), ("view", c_float * 16), ("projection", c_float * 16),
                ("eye", c_float * 3), ("grid", c_uint32)]


class _Mesh(ctypes.Structure):
    #: CadaclysmViewMesh, cadaclysm_view.h 1.1.
    _fields_ = [("size", c_uint32), ("positions", POINTER(c_float)), ("vertex_count", c_uint32),
                ("normals", POINTER(c_float)), ("indices", POINTER(c_uint32)), ("index_count", c_uint32),
                ("edges", POINTER(c_float)), ("edge_count", c_uint32), ("rgb", POINTER(c_float))]


class _Camera(ctypes.Structure):
    #: CadaclysmViewCamera, cadaclysm_view.h 1.2.
    _fields_ = [("size", c_uint32), ("eye", c_float * 3), ("target", c_float * 3), ("up", c_float * 3),
                ("orthographic", c_uint32)]


class _Pick(ctypes.Structure):
    #: CadaclysmViewPick, cadaclysm_view.h 1.0.
    _fields_ = [("size", c_uint32), ("item", c_uint32), ("node", c_uint32), ("face", c_uint32)]


class _Lod(ctypes.Structure):
    #: CadaclysmViewLod, cadaclysm_view.h 1.4.
    _fields_ = [("size", c_uint32), ("min_triangles", c_uint32), ("motion", c_uint32)]


V = c_void_p
F = POINTER(c_float)

_SIGNATURES = {
    "cadaclysm_view_abi_version": (c_uint32, []),
    "cadaclysm_view_last_error": (c_char_p, []),
    "cadaclysm_view_name": (c_char_p, []),
    "cadaclysm_view_create": (V, [POINTER(_Window), POINTER(_Options)]),
    "cadaclysm_view_destroy": (None, [V]),
    "cadaclysm_view_pump": (c_uint32, [V, c_uint32]),
    "cadaclysm_view_run": (c_bool, [V, POINTER(_Camera), POINTER(_Pick)]),
    "cadaclysm_view_resize": (c_bool, [V, c_uint32, c_uint32]),
    "cadaclysm_view_needs_draw": (c_bool, [V]),
    "cadaclysm_view_draw": (c_bool, [V]),
    "cadaclysm_view_size": (c_bool, [V, POINTER(c_uint32), POINTER(c_uint32)]),
    "cadaclysm_view_image": (c_bool, [V, POINTER(ctypes.c_uint8), ctypes.c_size_t]),
    "cadaclysm_view_show": (c_uint32, [V, V]),
    "cadaclysm_view_remove": (c_bool, [V, c_uint32]),
    "cadaclysm_view_set_surfaces": (c_bool, [V, c_uint32]),
    "cadaclysm_view_surfaces": (c_uint32, [V]),
    "cadaclysm_view_orbit": (None, [V, c_float, c_float]),
    "cadaclysm_view_pan": (None, [V, c_float, c_float]),
    "cadaclysm_view_zoom": (None, [V, c_float]),
    "cadaclysm_view_frame": (c_bool, [V, c_uint32]),
    "cadaclysm_view_standard": (c_bool, [V, c_uint32]),
    "cadaclysm_view_set_orthographic": (None, [V, c_bool]),
    "cadaclysm_view_set_layer": (c_bool, [V, c_uint32, c_bool]),
    "cadaclysm_view_set_background": (None, [V, F]),
    "cadaclysm_view_set_node_visible": (c_bool, [V, c_uint32, c_uint32, c_bool]),
    "cadaclysm_view_set_node_color": (c_bool, [V, c_uint32, c_uint32, F]),
    "cadaclysm_view_set_node_highlight": (c_bool, [V, c_uint32, c_uint32, F]),
    "cadaclysm_view_set_viewports": (c_bool, [V, POINTER(_Viewport), c_uint32]),
    "cadaclysm_view_request_pick": (None, [V, c_uint32, c_uint32]),
    "cadaclysm_view_request_pick_in": (None, [V, c_uint32, c_uint32, c_uint32]),
    "cadaclysm_view_pick_result": (c_bool, [V, POINTER(_Pick)]),
    "cadaclysm_view_frame_node": (c_bool, [V, c_uint32, c_uint32]),
    "cadaclysm_view_look": (None, [V, c_float, c_float]),
    "cadaclysm_view_dolly": (None, [V, c_float]),
    "cadaclysm_view_input": (c_uint32, [V, POINTER(_Event)]),
    "cadaclysm_view_show_mesh": (c_uint32, [V, POINTER(_Mesh)]),
    "cadaclysm_view_show_lines": (c_uint32, [V, F, c_uint32, F]),
    "cadaclysm_view_show_curves": (c_uint32, [V, F, c_uint32, F]),
    "cadaclysm_view_show_image": (c_uint32, [V, POINTER(_Image)]),
    "cadaclysm_view_set_colour": (c_bool, [V, c_uint32, F]),
    "cadaclysm_view_set_xray": (c_bool, [V, c_uint32, c_bool]),
    "cadaclysm_view_set_face_colours": (c_bool, [V, c_uint32, POINTER(c_uint32), F, c_uint32]),
    "cadaclysm_view_set_placement": (c_bool, [V, c_uint32, POINTER(c_double)]),
    "cadaclysm_view_set_node_transforms": (c_bool, [V, c_uint32, POINTER(c_double), c_uint32]),
    "cadaclysm_view_set_lod": (c_bool, [V, POINTER(_Lod)]),
    "cadaclysm_view_wake_ms": (c_uint32, [V]),
    "cadaclysm_view_show_solid": (c_uint32, [V, V, c_double, F]),
}


class Library:
    """A loaded view library."""

    def __init__(self, library, path=None):
        self._library, self.path = library, path
        version = library.cadaclysm_view_abi_version()
        major, minor = version >> 16, version & 0xFFFF
        if major != ABI_MAJOR or minor < ABI_MINOR:
            raise ViewError(f"{path or library}: view ABI {major}.{minor}, this SDK needs "
                             f"{ABI_MAJOR}.{ABI_MINOR} or a later {ABI_MAJOR}.x")
        self.name = _text(library.cadaclysm_view_name())

    @property
    def kind(self) -> str:
        """"wgpu" (cadaclysm_view), "terminal" (cadaclysm_terminal), or "other" (a library of your own)."""
        if self.name.startswith("cadaclysm-view "):
            return "wgpu"
        return "terminal" if self.name.startswith("cadaclysm-terminal ") else "other"

    def __repr__(self):
        return f"<Library {self.name}>"


_current = None


def _text(raw) -> str:
    return raw.decode("utf-8", "replace") if isinstance(raw, bytes) else str(raw or "")


def _load(path) -> Library:
    try:
        library = ctypes.CDLL(str(path))
    except OSError as e:
        raise ViewError(f"{path}: could not load the view library: {e}") from None
    # The ABI version first: a real 1.2 library has every symbol here except
    # `cadaclysm_view_name` (added in 1.3), so binding in table order would raise "not a
    # view library" for it instead of the ABI message. Checking the version before
    # binding the rest reports the true reason.
    try:
        abi_version = library.cadaclysm_view_abi_version
    except AttributeError:
        raise ViewError(f"{path}: not a view library (no cadaclysm_view_abi_version)") from None
    abi_version.restype, abi_version.argtypes = _SIGNATURES["cadaclysm_view_abi_version"]
    version = abi_version()
    major, minor = version >> 16, version & 0xFFFF
    if major != ABI_MAJOR or minor < ABI_MINOR:
        raise ViewError(f"{path}: view ABI {major}.{minor}, this SDK needs "
                         f"{ABI_MAJOR}.{ABI_MINOR} or a later {ABI_MAJOR}.x")
    for name, (restype, argtypes) in _SIGNATURES.items():
        try:
            function = getattr(library, name)
        except AttributeError:
            raise ViewError(f"{path}: not a view library (no {name})") from None
        function.restype, function.argtypes = restype, argtypes
    return Library(library, str(path))


def _library_file(stem: str) -> str:
    if sys.platform == "win32":
        return f"{stem}.dll"
    return f"lib{stem}.dylib" if sys.platform == "darwin" else f"lib{stem}.so"


def wgpu_library_path():
    """Where `cadaclysm_view` (the wgpu library) is: CADACLYSM_VIEW_LIBRARY (the library, or a
    directory holding it; authoritative), beside this module, its parent (the wheel's package),
    then `lib/`, `target/release/` or `target/debug/` in an ancestor (a checkout)."""
    from pathlib import Path

    name = _library_file("cadaclysm_view")
    override = os.environ.get("CADACLYSM_VIEW_LIBRARY")
    if override:
        candidate = Path(override) / name if Path(override).is_dir() else Path(override)
        if candidate.is_file():
            return candidate
        raise ViewError(f"CADACLYSM_VIEW_LIBRARY={override} names nothing that exists")
    here = Path(__file__).resolve().parent
    candidates = [here / name, here.parent / name]
    for folder in (here, *here.parents):
        candidates += [folder / "lib" / name, folder / "target" / "release" / name, folder / "target" / "debug" / name]
    for c in candidates:
        if c.is_file():
            return c
    raise ViewError(f"no view library: {name} was not found (searched: {', '.join(str(c) for c in candidates)}) "
                    "-- reinstall cadaclysm, set CADACLYSM_VIEW_LIBRARY to it, or use('terminal')")


def _resolve(word):
    """A path for `use`'s argument: the two words, else the path itself."""
    if word == "terminal":
        path = _bundled()
        if not path:
            raise _no_library("nothing")
        return path
    if word == "wgpu":
        return wgpu_library_path()
    return word


def use(library) -> Library:
    """Draw with `library` from now on: "terminal" (the default), "wgpu" (cadaclysm_view, a GPU
    window), a path to a view library, or (tests) an object with the contract's functions."""
    global _current
    if isinstance(library, (str, os.PathLike)):
        _current = _load(_resolve(library) if library in ("terminal", "wgpu") else library)
    else:
        _current = Library(library)
    return _current


def _no_library(searched: str) -> ViewError:
    return ViewError(f"no view library: the terminal library was not found (searched: {searched}) "
                      "-- reinstall cadaclysm, set CADACLYSM_TERMINAL_LIBRARY to the library, "
                      "or set CADACLYSM_VIEW")


def _bundled():
    """The terminal library shipped with the SDK.

    Only its absence is quiet about the cause: no terminal module, or a default search
    that found no library, raises the no-library message naming where it looked. A wrong
    CADACLYSM_TERMINAL_LIBRARY, or a library that is there and will not load, raises
    its own error -- those are not "no view library", they are a broken one.
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
        raise _no_library("no cadaclysm.terminal or cadaclysm_terminal module is installed") from None
    except FileNotFoundError as e:
        searched = getattr(e, "searched", None)
        if searched is None:  # CADACLYSM_TERMINAL_LIBRARY named something that is not there
            raise ViewError(str(e)) from None
        raise _no_library(", ".join(str(c) for c in searched)) from None


def current() -> Library:
    """The view library `show`/`view` draw with (see the module docstring for the order)."""
    global _current
    if _current is None:
        if sys.platform == "emscripten":
            raise ViewError("in the notebook, draw with show(obj)")
        _current = _load(_resolve(os.environ.get("CADACLYSM_VIEW") or "terminal"))
    return _current


def _reset() -> None:
    """Forget the view library in use, and every window-keeping state Task 6 adds
    (`_hook`, `_windows`, `_shared`, `_atexit_registered`, `_repl_function`): tests
    must pass whatever order they run in, so nothing of this module's own leaks between
    them (P12)."""
    global _current, _hook, _repl_function, _atexit_registered, _shared
    _remove_hook()   # a REPL/IPython/Jupyter hook a test installed must not outlive it
    _current = None
    _hook = None
    _repl_function = None
    _atexit_registered = False
    _shared = None
    _windows.clear()


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
        raise ValueError(f"width={width}, height={height}: a size is pixels, 0 or more (0 = the library decides)")
    up = (up or default_up).lower()
    if up not in ("y", "z"):
        raise ValueError(f"up {up!r}: 'y' or 'z'")
    return {"up": 1 if up == "y" else 0,
            "azimuth": float(base_az if az is None else az),
            "elevation": float(base_el if el is None else el),
            "zoom": math.nan if zoom is None else float(zoom),
            "width": width, "height": height,
            "flags": 0 if edges else NO_EDGES, "hint": hint}


def _deref(p):
    """The structure behind a structure, a `ctypes.byref()` or a `POINTER`."""
    if hasattr(p, "_obj"):  # ctypes.byref(...)
        return p._obj
    if hasattr(p, "contents"):  # a POINTER
        return p.contents
    return p


def _floats(a):
    import numpy as np

    a = np.ascontiguousarray(a, dtype=np.float32).reshape(-1)
    return a, a.ctypes.data_as(POINTER(c_float))


def _matrix(m):
    """A column-major 4x4 as 16 doubles; a short `m` raises before building the array (a
    ctypes fixed array silently zero-pads a short initializer instead of refusing it)."""
    if m is None:
        return None
    values = [float(v) for v in m]
    if len(values) != 16:
        raise ValueError(f"16 numbers, not {len(values)}")
    return (c_double * 16)(*values)


def _rgb3(rgb):
    if rgb is None:
        return None
    array = _f32(rgb, 3)
    return array, ctypes.cast(array, POINTER(c_float))


def _on_a_terminal(library: Library) -> None:
    """Refuse, for the terminal library, a process whose output is not a terminal's.

    Jupyter's kernel and IDLE replace `sys.stdout` with an object that is not file
    descriptor 1, so the escape codes would go past it into the kernel's or IDLE's own
    stdout. A redirected script (`python x.py > out.six`) keeps fd 1 and still writes the
    picture. Other libraries -- a window, say -- are not the terminal's business here.
    """
    if not library.name.startswith("cadaclysm-terminal "):
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
    raise ViewError(f"the terminal library draws on a terminal: {where} -- run the script from a terminal "
                     "(redirecting its output to a file works too), or select another view library")


def _aim(lib, v, opts) -> None:
    """The camera the options ask for: the top view straight down the up axis
    (`standard`), any other angle an orbit from the front (az -90, el 0), then the fit.
    The zoom (`_zoom`) is a separate step, applied by the caller after whichever framing
    -- this one's `frame(0)`, or (for a `Node`) `item.frame_node()` -- runs last, since
    framing resets the distance zoom sets."""
    az, el = opts["azimuth"], opts["elevation"]
    if el >= 90.0 and az == -90.0:
        lib.cadaclysm_view_standard(v, _STANDARD_TOP)
    else:
        lib.cadaclysm_view_standard(v, _STANDARD_FRONT)
        dx = -math.radians(az + 90.0) / _RADIANS_PER_PIXEL   # the view's yaw is az + 90; a drag right turns it back
        dy = math.radians(el) / _RADIANS_PER_PIXEL
        if dx or dy:
            lib.cadaclysm_view_orbit(v, dx, dy)
    lib.cadaclysm_view_frame(v, 0)


def _zoom(lib, v, opts) -> None:
    """The zoom the options ask for -- a multiple of the fit, as wheel steps. Must run
    after the last framing step (`_aim`'s `frame(0)`, or a `Node`'s `frame_node()`)."""
    zoom = opts["zoom"]
    if not math.isnan(zoom) and zoom > 0:
        lib.cadaclysm_view_zoom(v, math.log(zoom) / -math.log(_ZOOM_PER_STEP))


def _camera(cam: _Camera, pick: _Pick, y_up: bool) -> dict:
    """What `run` handed back, with the azimuth and elevation `show(az=, el=)` takes:
    the eye's direction from the target in the drawing's Z-up orbit frame.

    At either pole the eye sits directly over (or under) the target, so that direction
    is exactly zero (and, at `pitch = +-PI/2` in f32, the library's own eye/target may
    already have rounded it away entirely) -- `atan2` on it would return an arbitrary
    angle, breaking the round trip through `announce()`/`show(az=, el=)` for a top or
    bottom view. There the azimuth instead comes from the up vector, which stays well
    defined at the pole (`Camera::basis` builds it from `yaw` alone): the eye's
    horizontal direction there is `-up` for the north pole and `+up` for the south
    one -- the camera looks along `-up`/`+up` respectively once pitch is +-90."""
    eye, target, up = tuple(cam.eye), tuple(cam.target), tuple(cam.up)
    d = [e - t for e, t in zip(eye, target)]
    up_o = up
    if y_up:
        d = [d[0], -d[2], d[1]]      # cadaclysm_view::camera::to_orbit
        up_o = (up[0], -up[2], up[1])
    length = math.sqrt(sum(c * c for c in d)) or 1.0
    d = [c / length for c in d]
    if math.hypot(d[0], d[1]) < 1e-4:
        sign = -1.0 if d[2] < 0.0 else 1.0
        azimuth = math.degrees(math.atan2(-sign * up_o[1], -sign * up_o[0]))
    else:
        azimuth = math.degrees(math.atan2(d[1], d[0]))
    elevation = math.degrees(math.asin(max(-1.0, min(1.0, d[2]))))
    return {"eye": eye, "target": target, "up": up, "orthographic": bool(cam.orthographic),
            "azimuth": azimuth, "elevation": elevation,
            "pick": {"item": pick.item, "node": pick.node, "face": pick.face} if pick.item else None}


_shared = None   # the one window `obj.show()` draws into, on the wgpu library


@contextlib.contextmanager
def _hint(hint):
    """`hint=` ("sixel", "kitty", "blocks") as CADACLYSM_TERMINAL_GRAPHICS around a create only."""
    old = os.environ.get("CADACLYSM_TERMINAL_GRAPHICS")
    if hint:
        os.environ["CADACLYSM_TERMINAL_GRAPHICS"] = hint
    try:
        yield
    finally:
        if hint:
            if old is None:
                os.environ.pop("CADACLYSM_TERMINAL_GRAPHICS", None)
            else:
                os.environ["CADACLYSM_TERMINAL_GRAPHICS"] = old


def _shared_view(opts, title):
    global _shared
    if _shared is not None and (_shared._v is None or _shared._closed or _shared._up != opts["up"]):
        _shared.close()
        _shared = None
    if _shared is None:
        _shared = View(title=title, width=opts["width"], height=opts["height"], up="y" if opts["up"] else "z")
    return _shared


_views = weakref.WeakSet()   # every live View, walked by `_release()`; weak so a View
                              # dropped without close() still reaches __del__/GC and
                              # destroys its native view instead of leaking it


def _release(obj) -> None:
    """Remove every item that shows `obj` -- directly, or (a node item, shown through its
    scene) by keeping it -- from every live view, before `obj`'s own handle is freed.

    `cadaclysm_view.h` requires whatever an item shows (unlike a solid, which
    `show_solid` copies at show time) to stay open until the item is removed or the view
    is destroyed; a caller whose handle is about to be freed (`Scene.close()`) calls this
    first so a view never reads a freed one.

    The order, safest first: every view of this thread is dealt with before anything can
    raise -- an open one has the items removed; one whose window the user closed (closed,
    not yet destroyed: its items refuse every call) is destroyed now, the destroy it owed
    anyway, which drops all its items at once. A view made on another thread cannot be called
    from this one, and freeing a scene it still draws would have it read freed memory -- so
    when one still shows `obj`, this raises after the thread's own views are done, and the
    caller keeps `obj` open (it leaks rather than crashes; close it again once that thread has
    closed its view).
    """
    me = threading.get_ident()
    foreign = []
    for view in list(_views):
        if view._v is None or not any(i._keeps is obj for i in view._items.values()):
            continue
        if view._thread != me:
            foreign.append(view)
        elif view._closed:
            view.close()
        else:
            for item in [i for i in view._items.values() if i._keeps is obj]:
                item.remove()
    if foreign:
        raise ViewError(f"{len(foreign)} view(s) made on another thread still show this -- close "
                        "them from their own thread first; it stays open until then")


def present(mode, obj, *, name, default_view, keywords, owner, tolerance=0.05, transforms=None):
    """`obj.show()` / `obj.view()`, by handle on every library. The wgpu library: `show`
    replaces what the shared window shows and returns. The terminal (or a library of your
    own): `show` prints one still from a fresh view. `view` everywhere: a fresh view, run until
    closed; the camera and last pick come back and `announce` prints them. `transforms`, for a
    scene: one posed world transform per node (`Pose.show`), set on its item before drawing."""
    library = current()
    _on_a_terminal(library)
    opts = options(default_view, **keywords)
    shared = library.kind == "wgpu" and mode == "show"
    if shared:
        view = _shared_view(opts, name)
        view._clear()
    else:
        for stream in (sys.stdout, sys.stderr):
            try:
                stream.flush()
            except Exception:
                pass
        with _hint(opts["hint"]):
            view = View(title=name, width=opts["width"], height=opts["height"], up="y" if opts["up"] else "z")
    try:
        kind = type(obj).__name__
        if kind == "Profile":
            item = view._show_profile(obj, tolerance=tolerance)
        elif kind == "Solid":
            item = view.show_solid(obj, tolerance=tolerance)
        else:
            item = view.show(obj)
        if transforms is not None:
            item.node_transforms(transforms)
        view.layer("edges", not (opts["flags"] & NO_EDGES))
        _aim(view._lib, view._v, opts)
        if kind == "Node":
            item.frame_node(obj)
        _zoom(view._lib, view._v, opts)
        if mode == "show":
            view.draw()
            return None
        last = view.run()
    finally:
        if not shared:
            view.close()
    announce(owner, last)
    return last


def announce(owner: str, last) -> None:
    """After `view()`: the call that shows where the user left the camera."""
    if last:
        print(f"{owner}.show(az={last['azimuth']:.0f}, el={last['elevation']:.0f})")


# ---- views ----------------------------------------------------------------------


_windows = []      # windows of the views' own on the wgpu library, open, in the order made
_hook = None       # what keeps them live: "repl", "ipython", "jupyter", "script" or None
_repl_function = None
_HOOK_TYPE = ctypes.CFUNCTYPE(ctypes.c_int)   # PyOS_InputHook runs without the GIL; CFUNCTYPE takes it
_atexit_registered = False


def _opened(view) -> None:
    """A window of the view's own was made: tracked so `pump()` and the exit wait reach it,
    and -- for the first one -- a hook is installed to keep it live wherever it was made
    (the REPL, IPython, Jupyter or a script)."""
    _windows.append(view)
    if _hook is None:
        _install_hook(_where())


def _forget(view) -> None:
    """A view's window closed or the view was destroyed. Removed from `_windows` so `pump()`
    and the exit wait stop reaching it; the last window gone drops the REPL/IPython/Jupyter
    hook (a script's `atexit` hook stays -- a later window may still open). The shared window
    `present()` draws `show()` into is forgotten when it goes: a closed-but-not-yet-destroyed
    one is also destroyed here, so the next `show()` opens a fresh one instead of reusing a
    dead handle."""
    global _shared
    if view in _windows:
        _windows.remove(view)
    if _shared is view:
        _shared = None
        if view._v is not None and view._closed:
            view.close()
    if not _windows and _hook in ("repl", "ipython", "jupyter"):
        _remove_hook()


def _own_windows() -> list:
    """The open windows the calling thread made: the ones its `pump()` reaches."""
    me = threading.get_ident()
    return [v for v in _windows if v._v is not None and not v._closed and v._thread == me]


def pump(timeout=0.0) -> int:
    """Handles every open window's events, draws what is owed, waits at most `timeout`
    seconds; the number of windows still open. For a script's own loop: the REPL, IPython and
    Jupyter pump by themselves.

    Only windows belonging to the calling thread are pumped here -- a view made on another
    thread is pumped from that thread's own call, not skipped as an error. With none of its
    own, the call just waits `timeout` (a loop around it does not spin). Every pumped
    window's state is handled (a `_CLOSED` one closes it) before any error is raised, so one
    failing window cannot stop a later one in the same call from being noticed."""
    alive = _own_windows()
    if not alive:
        if timeout and timeout > 0:
            time.sleep(float(timeout))
        return sum(1 for v in _windows if not v._closed)
    states = [alive[0]._call("cadaclysm_view_pump", int(max(0.0, float(timeout)) * 1000))]
    states += [v._call("cadaclysm_view_pump", 0) for v in alive[1:]]
    errors = []
    for v, state in zip(alive, states):
        if state == _CLOSED:
            v._window_closed()
        elif state != _OPEN:
            errors.append(v._error())
    if errors:
        raise errors[0]
    return sum(1 for v in _windows if not v._closed)


def _shell():
    ipython = sys.modules.get("IPython")
    get = getattr(ipython, "get_ipython", None)
    return get() if get else None


def _where() -> str:
    """Which loop keeps a window live here, detected as matplotlib detects it."""
    shell = _shell()
    if shell is not None:
        return "jupyter" if getattr(shell, "kernel", None) is not None else "ipython"
    if hasattr(sys, "ps1") or sys.flags.interactive:
        return "repl"
    return "script"


def _notice(loop: str) -> None:
    print(f"cadaclysm.view: {loop} already runs the event loop -- call cadaclysm.view.pump() from it "
          "to keep the view's windows live", file=sys.stderr)


def _stdin_ready() -> bool:
    if sys.platform == "win32":
        import msvcrt
        return msvcrt.kbhit()
    import select
    return bool(select.select([sys.stdin], [], [], 0)[0])


def _stdin_is_a_console() -> bool:
    try:
        return sys.stdin is not None and sys.stdin.isatty()
    except (AttributeError, ValueError, OSError):
        return False


def _input_hook_slot():
    return ctypes.c_void_p.in_dll(ctypes.pythonapi, "PyOS_InputHook")


def _repl_loop() -> int:
    try:
        while _own_windows() and not _stdin_ready():
            pump(0.016)
    except BaseException as e:   # nothing may cross back into the interpreter's C
        print(f"cadaclysm.view: {e!r}", file=sys.stderr)
    return 0


def _ipython_loop(context) -> None:
    try:
        while _own_windows() and not context.input_is_ready():
            pump(0.016)
    except BaseException as e:   # nothing may cross back into IPython's own loop (it would
                                  # either kill the session or, logged and not rescheduled,
                                  # leave windows frozen with `_hook` stuck on "ipython")
        print(f"cadaclysm.view: {e!r}", file=sys.stderr)
        _remove_hook()


def _jupyter_loop(kernel) -> None:
    """ipykernel calls this between its own iterations while it is the kernel's event loop."""
    interval = float(getattr(kernel, "_poll_interval", 0.05))
    try:
        pump(interval)   # with no window of this thread's own, it just waits `interval`
    except BaseException as e:   # as `_ipython_loop`: ipykernel>=6 calls this again and again
                                  # (Ruling 7) -- a failure left uncaught would either escape
                                  # into the kernel or leave `_hook` stuck on "jupyter" forever
        print(f"cadaclysm.view: {e!r}", file=sys.stderr)
        _remove_hook()


def _wait_for_windows() -> None:
    """A script's end: wait for every window of this thread's to be closed; Ctrl-C closes
    them. A window the user closes (Escape, the close button) stops the wait -- `pump()`/
    `input()` already took it out of `_windows` -- but still owes a destroy (spec's "destroy
    is still owed"), which this pays before the script actually exits.

    Only this thread's windows are waited on and destroyed: one made on another thread (by
    now a finished or daemon thread -- `threading` joins the rest before `atexit`) is never
    pumped from here, so waiting on it would never end, and closing it from here is refused.
    Nothing escapes: a failing pump is reported and ends the wait, and a second Ctrl-C while
    the windows are being destroyed does not stop them from being destroyed."""
    me = threading.get_ident()
    tracked = _own_windows()
    try:
        while _own_windows():
            pump(0.1)
            tracked += [v for v in _own_windows() if v not in tracked]
    except KeyboardInterrupt:
        pass
    except Exception as e:
        print(f"cadaclysm.view: {e!r}", file=sys.stderr)
    for v in tracked:
        while v._v is not None and v._thread == me:
            try:
                v.close()
            except KeyboardInterrupt:
                continue   # the destroy is still owed: try again
            except Exception as e:
                print(f"cadaclysm.view: {e!r}", file=sys.stderr)
                break


def _install_hook(where) -> None:
    global _hook, _repl_function, _atexit_registered
    if where == "repl":
        if sys.platform == "win32" and not _stdin_is_a_console():
            # msvcrt.kbhit() polls the console, never a pipe or file: under `python -i < file`
            # the hook would pump on, waiting for a key that is not coming.
            print("cadaclysm.view: the REPL reads from a pipe or file, so no window is kept live "
                  "between its lines -- call cadaclysm.view.pump() to keep them live", file=sys.stderr)
            return
        slot = _input_hook_slot()
        if slot.value:
            _notice("another input hook (tkinter or a GUI toolkit)")
            return
        _repl_function = _HOOK_TYPE(_repl_loop)
        slot.value = ctypes.cast(_repl_function, ctypes.c_void_p).value
        _hook = "repl"
    elif where == "ipython":
        shell = _shell()
        if getattr(shell, "active_eventloop", None) not in (None, "cadaclysm"):
            _notice(f"%gui {shell.active_eventloop}")
            return
        from IPython.terminal.pt_inputhooks import register
        register("cadaclysm", _ipython_loop)
        shell.enable_gui("cadaclysm")
        _hook = "ipython"
    elif where == "jupyter":
        shell = _shell()
        running = getattr(shell.kernel, "eventloop", None)
        if running is not None and running is not _jupyter_loop:
            _notice(f"%gui {getattr(running, '__name__', running)}")
            return
        from ipykernel.eventloops import register_integration
        register_integration("cadaclysm")(_jupyter_loop)
        shell.enable_gui("cadaclysm")
        _hook = "jupyter"
    elif where == "script":
        if not _atexit_registered:
            atexit.register(_wait_for_windows)
            _atexit_registered = True
        _hook = "script"


def _remove_hook() -> None:
    global _hook
    if _hook == "repl":
        slot = _input_hook_slot()
        if slot.value == ctypes.cast(_repl_function, ctypes.c_void_p).value:
            slot.value = None
    elif _hook in ("ipython", "jupyter"):
        shell = _shell()
        if shell is not None:
            shell.enable_gui(None)
    _hook = None


def _f32(values, n):
    """`n` numbers as a ctypes float array; a short `values` raises before building it."""
    values = list(values)
    if len(values) < n:
        raise ValueError(f"{n} numbers, not {len(values)}")
    return (c_float * n)(*[float(x) for x in values[:n]])


def _rgba(rgb):
    """3 or 4 numbers as four floats (alpha 1 where only three were given)."""
    values = [float(x) for x in rgb]
    return _f32(values + [1.0] if len(values) == 3 else values, 4)


def _png(rgba) -> bytes:
    """`rgba` (h, w, 4) uint8 as a PNG: filter 0 rows, zlib, the chunk CRCs. No Pillow."""
    import struct
    import zlib
    h, w = rgba.shape[:2]
    raw = b"".join(b"\x00" + rgba[y].tobytes() for y in range(h))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def _node_index(node) -> int:
    return int(getattr(node, "index", node))


class Item:
    """One thing shown in a `View`. Holds what it shows (a `Solid`, a `Scene`), whose handle the
    view reads in place."""

    __slots__ = ("view", "id", "_keeps")

    def __init__(self, view, item_id, keeps=None):
        self.view, self.id, self._keeps = view, item_id, keeps

    def __repr__(self):
        return f"<Item {self.id}>"

    def remove(self):
        self.view._ok("cadaclysm_view_remove", self.id)
        self.view._items.pop(self.id, None)
        self._keeps = None

    def colour(self, rgb):
        self.view._ok("cadaclysm_view_set_colour", self.id, _f32(rgb, 3))

    def placement(self, matrix):
        """A column-major 4x4 as 16 numbers; None takes it back."""
        self.view._ok("cadaclysm_view_set_placement", self.id, _matrix(matrix))

    def node_transforms(self, transforms):
        """Poses a shown scene: one world transform per node (column-major 4x4s as 16 numbers
        each, `Pose.raw_transform`'s layout -- every node of the scene, in index order),
        drawn in place of each node's rest transform. None restores the rest pose."""
        if transforms is None:
            self.view._ok("cadaclysm_view_set_node_transforms", self.id, None, 0)
            return
        values = []
        for k, m in enumerate(transforms):
            m = [float(v) for v in m]
            if len(m) != 16:
                raise ValueError(f"transform {k}: 16 numbers, not {len(m)}")
            values += m
        count = len(values) // 16
        self.view._ok("cadaclysm_view_set_node_transforms", self.id, (c_double * len(values))(*values), count)

    def face_colours(self, faces, rgba):
        faces = [int(f) for f in faces]
        values = [float(c) for quad in rgba for c in quad]
        if len(values) != 4 * len(faces):
            raise ValueError(f"{4 * len(faces)} numbers (rgba, 4 a face), not {len(values)}")
        colours = (c_float * len(values))(*values)
        self.view._ok("cadaclysm_view_set_face_colours", self.id, (c_uint32 * len(faces))(*faces), colours, len(faces))

    def xray(self, on=True):
        self.view._ok("cadaclysm_view_set_xray", self.id, bool(on))

    def frame(self):
        self.view._ok("cadaclysm_view_frame", self.id)

    def node_visible(self, node, on=True):
        self.view._ok("cadaclysm_view_set_node_visible", self.id, _node_index(node), bool(on))

    def node_colour(self, node, rgba):
        self.view._ok("cadaclysm_view_set_node_color", self.id, _node_index(node), None if rgba is None else _rgba(rgba))

    def node_highlight(self, node, rgba):
        self.view._ok("cadaclysm_view_set_node_highlight", self.id, _node_index(node), None if rgba is None else _rgba(rgba))

    def frame_node(self, node):
        self.view._ok("cadaclysm_view_frame_node", self.id, _node_index(node))


def _window_struct(window, display, kind, width, height):
    if not width or not height:
        raise ValueError("a host's window needs width= and height=: its client size in physical pixels")
    kind = kind or {"win32": "win32", "darwin": "appkit"}.get(sys.platform, "xlib")
    if kind not in _WINDOW_KINDS:
        raise ValueError(f"kind {kind!r}: one of {', '.join(_WINDOW_KINDS)}")
    if kind in ("xlib", "xcb", "wayland") and not display:
        raise ValueError(f"kind {kind!r} needs display= (the Display*, xcb_connection_t* or wl_display*)")
    w = _Window()
    w.size, w.kind = ctypes.sizeof(_Window), _WINDOW_KINDS[kind]
    if kind in ("xlib", "xcb"):
        w.window_id = int(window)
    else:
        w.window = int(window)
    w.display = int(display) if display else None
    w.width, w.height = int(width), int(height)
    return w


class View:
    """A view of `cadaclysm_view.h`: a window of its own (no `window`), a host's window
    (`window=` its handle), or `View.offscreen(width, height)`. Belongs to the thread that made it."""

    def __init__(self, window=None, display=None, *, kind=None, title=None, width=0, height=0,
                 surfaces="exact", up="z", _offscreen=False):
        if surfaces not in _SURFACES:
            raise ValueError(f"surfaces {surfaces!r}: 'exact' or 'triangles'")
        if up not in ("y", "z"):
            raise ValueError(f"up {up!r}: 'y' or 'z'")
        self._v = None
        library = current()
        self._library, self._lib = library, library._library
        self._thread = threading.get_ident()
        self._items, self._closed, self._up, self._drawn = {}, False, 1 if up == "y" else 0, False
        self._own = window is None and not _offscreen
        o = _Options()
        o.size, o.surfaces, o.y_up = ctypes.sizeof(_Options), _SURFACES[surfaces], self._up
        o.title = (title or "Cadaclysm").encode("utf-8", "replace")
        o.width, o.height, o.offscreen = int(width), int(height), 1 if _offscreen else 0
        w = None if window is None else _window_struct(window, display, kind, width, height)
        v = self._lib.cadaclysm_view_create(None if w is None else ctypes.byref(w), ctypes.byref(o))
        if not v:
            message = _text(self._lib.cadaclysm_view_last_error())
            if "no display" in message:
                message += " -- draw without a display with View.offscreen(width, height), or use('terminal')"
            raise ViewError(message)
        self._v = v
        _views.add(self)
        if self._own and library.kind == "wgpu":
            _opened(self)

    @classmethod
    def offscreen(cls, width, height, *, surfaces="exact", up="z"):
        """A view with no window and no display, read with `image()`/`save()`."""
        return cls(width=width, height=height, surfaces=surfaces, up=up, _offscreen=True)

    def __repr__(self):
        return f"<View {self._library.name}{' closed' if self._v is None else ''}>"

    # -- the calls --
    def _call(self, name, *args):
        if threading.get_ident() != self._thread:
            raise ViewError(f"{name}: a view belongs to the thread that made it")
        if self._v is None:
            raise ViewError(f"{name}: the view is closed")
        if self._closed:
            raise ViewError(f"{name}: the window is closed")
        return getattr(self._lib, name)(self._v, *args)

    def _error(self):
        return ViewError(_text(self._lib.cadaclysm_view_last_error()) or "the view library failed")

    def _ok(self, name, *args):
        result = self._call(name, *args)
        if not result:
            raise self._error()
        return result

    def _void(self, name, *args):
        self._call(name, *args)
        if _text(self._lib.cadaclysm_view_last_error()):
            raise self._error()

    def _item(self, item_id, keeps=None):
        item = Item(self, item_id, keeps)
        self._items[item_id] = item
        return item

    # -- showing --
    def show(self, obj, rgb=None):
        """A `Solid`, `Scene` or `Node` by handle, a `Profile` as lines, an (n, 3) array as a
        triangle soup, or `(positions, indices)` as a mesh."""
        kind = type(obj).__name__
        if kind == "Solid" and hasattr(obj, "_h"):
            return self.show_solid(obj, rgb=rgb)
        if kind == "Scene" and hasattr(obj, "placements"):
            return self.show_scene(obj)
        if kind == "Node" and hasattr(obj, "scene"):
            return self._show_node(obj)
        if kind == "Profile" and hasattr(obj, "polylines"):
            return self._show_profile(obj, rgb=rgb)
        if isinstance(obj, tuple) and len(obj) == 2:
            return self.show_mesh(obj[0], obj[1], rgb=rgb)
        import numpy as np
        points = np.ascontiguousarray(obj, dtype=np.float32).reshape(-1, 3)
        if len(points) % 3:
            raise ValueError(f"a triangle soup is three points a triangle, not {len(points)}")
        return self.show_mesh(points, np.arange(len(points), dtype=np.uint32), rgb=rgb)

    def show_solid(self, solid, tolerance=0.05, rgb=None):
        packed = _rgb3(rgb)
        return self._item(self._ok("cadaclysm_view_show_solid", solid._h(), float(tolerance),
                                   None if packed is None else packed[1]), solid)

    def show_scene(self, scene):
        return self._item(self._ok("cadaclysm_view_show", scene._handle), scene)

    def _show_node(self, node):
        """The node's scene by handle with the siblings along the path from its root hidden:
        the other roots, and at every ancestor the children not on the path. The ancestors'
        own geometry stays visible; the node's subtree is untouched."""
        item = self.show_scene(node.scene)
        path = []
        n = node
        while n is not None:
            path.append(n)
            n = n.parent
        path.reverse()
        for root in node.scene.roots:
            if root.index != path[0].index:
                item.node_visible(root, False)
        for parent, child in zip(path, path[1:]):
            for sibling in parent.children:
                if sibling.index != child.index:
                    item.node_visible(sibling, False)
        return item

    def _show_profile(self, profile, tolerance=0.05, rgb=None):
        import numpy as np
        runs = profile.polylines(tolerance)
        pairs = [np.hstack((r[:-1], r[1:])) for r in runs if len(r) > 1]
        colour = rgb if rgb is not None else profile.colour
        return self.show_lines(np.concatenate(pairs) if pairs else np.empty((0, 6), "f4"), rgb=colour)

    def show_mesh(self, positions, indices, normals=None, edges=None, rgb=None):
        """`positions`/`indices`/`normals`/`edges` are read into the C struct via `.ctypes.data_as`
        pointers; the backing numpy arrays (`p`, `i`, `n`, `e`) are kept alive by staying local
        variables in scope for the whole call (no separate `keep` list is needed).

        The library has no field for a normals count -- it reads `vertex_count` of them, so a
        short `normals` would be read past its end; checked against `positions`, as the old
        `draw()` path did. `edges` carries no outside count either: `edge_count` is derived from
        its own size, so a short array cannot be over-read, but one that is not a whole number of
        segments (two points, six numbers, each) is refused rather than silently truncated."""
        import numpy as np
        p, pp = _floats(positions)
        i = np.ascontiguousarray(indices, dtype=np.uint32).reshape(-1)
        m = _Mesh()
        m.size, m.positions, m.vertex_count = ctypes.sizeof(_Mesh), pp, p.size // 3
        m.indices, m.index_count = i.ctypes.data_as(POINTER(c_uint32)), i.size
        if normals is not None:
            n, m.normals = _floats(normals)
            if n.size != p.size:
                raise ValueError(f"a mesh has {p.size // 3} positions but {n.size // 3} normals")
        if edges is not None:
            e, m.edges = _floats(edges)
            if e.size % 6:
                raise ValueError(f"edges is two points a segment (6 numbers), not {e.size}")
            m.edge_count = e.size // 6
        packed = _rgb3(rgb)
        if packed is not None:
            m.rgb = packed[1]
        return self._item(self._ok("cadaclysm_view_show_mesh", ctypes.byref(m)))

    def show_lines(self, segments, rgb=None):
        """Segments as (n, 6) or (n, 2, 3): two points each."""
        s, sp = _floats(segments)
        packed = _rgb3(rgb)
        return self._item(self._ok("cadaclysm_view_show_lines", sp, s.size // 6, None if packed is None else packed[1]))

    def show_curves(self, beziers, rgb=None):
        """(n, 4, 4): n rational cubic Béziers, four `x, y, z, w` control points each."""
        import numpy as np
        b = np.ascontiguousarray(beziers, dtype=np.float32)
        if b.ndim == 2 and b.shape == (4, 4):
            b = b[None]
        if b.ndim != 3 or b.shape[1:] != (4, 4):
            raise ValueError(f"show_curves takes (n, 4, 4) control points, not {b.shape}")
        packed = _rgb3(rgb)
        return self._item(self._ok("cadaclysm_view_show_curves", b.ctypes.data_as(POINTER(c_float)), len(b),
                                   None if packed is None else packed[1]))

    def show_image(self, corners, rgba, opacity=1.0):
        """`rgba` (h, w, 4) uint8, rows top first, on the quad `corners` (bottom-left,
        bottom-right, top-right, top-left)."""
        import numpy as np
        pixels = np.ascontiguousarray(rgba, dtype=np.uint8)
        if pixels.ndim != 3 or pixels.shape[2] != 4:
            raise ValueError(f"show_image takes (h, w, 4) rgba, not {pixels.shape}")
        image = _Image()
        image.size, image.corners = ctypes.sizeof(_Image), _f32(np.asarray(corners, float).reshape(-1), 12)
        image.rgba = pixels.ctypes.data_as(POINTER(ctypes.c_uint8))
        image.height, image.width = pixels.shape[:2]
        image.opacity = float(opacity)
        return self._item(self._ok("cadaclysm_view_show_image", ctypes.byref(image)))

    def _clear(self):
        for item in list(self._items.values()):
            item.remove()

    # -- the camera --
    def orbit(self, dx, dy): self._void("cadaclysm_view_orbit", float(dx), float(dy))
    def pan(self, dx, dy): self._void("cadaclysm_view_pan", float(dx), float(dy))
    def zoom(self, steps): self._void("cadaclysm_view_zoom", float(steps))
    def look(self, dx, dy): self._void("cadaclysm_view_look", float(dx), float(dy))
    def dolly(self, ratio): self._void("cadaclysm_view_dolly", float(ratio))
    def orthographic(self, on=True): self._void("cadaclysm_view_set_orthographic", bool(on))
    def frame(self): self._ok("cadaclysm_view_frame", 0)

    def standard(self, name):
        if name not in _STANDARD:
            raise ValueError(f"standard view {name!r}: one of {', '.join(_STANDARD)}")
        self._ok("cadaclysm_view_standard", _STANDARD[name])

    def viewports(self, panes):
        if not panes:
            self._ok("cadaclysm_view_set_viewports", None, 0)
            return
        array = (_Viewport * len(panes))()
        for slot, pane in zip(array, panes):
            slot.size = ctypes.sizeof(_Viewport)
            slot.rect[:] = [int(x) for x in pane["rect"]]
            slot.view[:] = [float(x) for x in pane["view"]]
            slot.projection[:] = [float(x) for x in pane["projection"]]
            slot.eye[:] = [float(x) for x in pane["eye"]]
            slot.grid = _GRIDS[pane.get("grid", "none")]
        self._ok("cadaclysm_view_set_viewports", array, len(panes))

    # -- the rest --
    def pick(self, x, y, viewport=0):
        """What is under pixel (x, y) of `viewport`: {"item", "node", "face"}, or None.

        A view never drawn is drawn first: the library answers a pick from the frame it has
        drawn, so one asked before any draw finds nothing. A failure other than "no answer
        yet" raises at once with the library's own message."""
        if not self._drawn:
            self.draw()
        self._void("cadaclysm_view_request_pick_in", int(viewport), int(x), int(y))
        out = _Pick()
        out.size = ctypes.sizeof(_Pick)
        waiting = ""
        for _ in range(200):
            self.draw()
            if self._call("cadaclysm_view_pick_result", ctypes.byref(out)):
                return {"item": out.item, "node": out.node, "face": out.face} if out.item else None
            waiting = _text(self._lib.cadaclysm_view_last_error())
            if waiting and not waiting.endswith("no pick result"):
                raise ViewError(waiting)
            time.sleep(0.01)
        raise ViewError(f"pick: the answer never landed ({waiting or 'no error reported'})")

    def last_pick(self):
        """The newest pick answer that has landed since the last call, without waiting: a tap
        or click in the view's own window (`pump()` lands them as it draws), or a double
        click's, or one asked with `pick`'s request. None while none has landed; `{}` when
        the pick found nothing under the pixel; else {"item", "node", "face"}. Each answer
        is read once, and a newer one replaces one not read yet."""
        out = _Pick()
        out.size = ctypes.sizeof(_Pick)
        if self._call("cadaclysm_view_pick_result", ctypes.byref(out)):
            return {"item": out.item, "node": out.node, "face": out.face} if out.item else {}
        waiting = _text(self._lib.cadaclysm_view_last_error())
        if waiting and not waiting.endswith("no pick result"):
            raise ViewError(waiting)
        return None

    @property
    def closed(self):
        """True once the view's own window has closed (its close button, Escape, the end of
        `run`) or `close()` destroyed the view: what a loop around `pump()` stops on."""
        return self._v is None or self._closed

    def draw(self):
        self._ok("cadaclysm_view_draw")
        self._drawn = True

    def run(self):
        """Blocks until the window is closed; the camera and the last pick, as `view()` returns them."""
        cam, pick = _Camera(), _Pick()
        cam.size, pick.size = ctypes.sizeof(_Camera), ctypes.sizeof(_Pick)
        self._ok("cadaclysm_view_run", ctypes.byref(cam), ctypes.byref(pick))
        self._window_closed()
        return _camera(cam, pick, self._up == 1)

    def image(self):
        """One frame, (height, width, 4) uint8 RGBA, rows top first."""
        import numpy as np
        w, h = self.size
        img = np.zeros((h, w, 4), np.uint8)
        self._ok("cadaclysm_view_image", img.ctypes.data_as(POINTER(ctypes.c_uint8)), img.nbytes)
        return img

    def save(self, path):
        """The frame as a PNG."""
        from pathlib import Path
        Path(path).write_bytes(_png(self.image()))

    def input(self, event):
        """One event as a dict of `CadaclysmViewEvent`'s fields: "type" (pointer_down,
        pointer_move, pointer_up, pointer_cancel, wheel, key), x, y, button, shift, pointer,
        pointer_id, wheel_y, key, key_down, time_ms. The `CADACLYSM_VIEW_INPUT_*` bits; on a window
        of the view's own, the close bit (Escape) ends it as the user closing the window does
        (closed state, items raise "window closed") -- `close()` still owes the destroy."""
        e = _Event()
        e.size, e.kind = ctypes.sizeof(_Event), _EVENTS[event["type"]]
        e.pointer_id, e.pointer = int(event.get("pointer_id", 0)), _POINTERS[event.get("pointer", "mouse")]
        e.button, e.shift = int(event.get("button", 0)), 1 if event.get("shift") else 0
        e.x, e.y, e.wheel_y = float(event.get("x", 0)), float(event.get("y", 0)), float(event.get("wheel_y", 0))
        key = event.get("key")
        e.key = None if key is None else key.encode()
        e.key_down = 1 if event.get("key_down", True) else 0
        e.time_ms = float(event.get("time_ms", time.monotonic() * 1000.0))
        bits = self._call("cadaclysm_view_input", ctypes.byref(e))
        if not bits and _text(self._lib.cadaclysm_view_last_error()):
            raise self._error()
        if bits & _INPUT_CLOSE and self._own:
            self._window_closed()
        return bits

    def resize(self, width, height):
        self._ok("cadaclysm_view_resize", int(width), int(height))

    @property
    def size(self):
        """(width, height): what `image()` reads, in physical pixels."""
        w, h = c_uint32(), c_uint32()
        self._ok("cadaclysm_view_size", ctypes.byref(w), ctypes.byref(h))
        return w.value, h.value

    @property
    def needs_draw(self):
        return bool(self._call("cadaclysm_view_needs_draw"))

    @property
    def surfaces(self):
        return "exact" if self._call("cadaclysm_view_surfaces") == 0 else "triangles"

    @surfaces.setter
    def surfaces(self, value):
        self._ok("cadaclysm_view_set_surfaces", _SURFACES[value])

    def layer(self, name, on=True):
        if name not in _LAYERS:
            raise ValueError(f"layer {name!r}: one of {', '.join(_LAYERS)}")
        self._ok("cadaclysm_view_set_layer", _LAYERS[name], bool(on))

    def background(self, rgb):
        self._void("cadaclysm_view_set_background", _f32(rgb, 3))

    def lod(self, motion="detailed", min_triangles=0):
        """Levels of detail for this view: parts of `min_triangles` or more (0: the library's
        default, 2,048) get coarser levels, built in the background after each show, and a
        moving frame draws as `motion` says -- "detailed" keeps every frame whole but for
        levels within half a pixel, "smooth" holds the frame rate while moving and refines
        once the camera rests (see `wake_ms`). `motion=None` turns levels off (the default)."""
        if motion is None:
            self._ok("cadaclysm_view_set_lod", None)
            return
        if motion not in _LOD_MOTION:
            raise ValueError(f"motion {motion!r}: one of {', '.join(_LOD_MOTION)} or None")
        lod = _Lod(ctypes.sizeof(_Lod), int(min_triangles), _LOD_MOTION[motion])
        self._ok("cadaclysm_view_set_lod", ctypes.byref(lod))

    @property
    def wake_ms(self):
        """Milliseconds until `needs_draw` turns true by itself (a resting frame refining the
        picture); 0 when one is owed now, None when none is coming."""
        ms = self._call("cadaclysm_view_wake_ms")
        return None if ms == 0xFFFFFFFF else int(ms)

    def _window_closed(self):
        """The window closed (its close button, Escape, the end of `run`)."""
        self._closed = True
        _forget(self)

    def close(self):
        """Destroys the view (and closes its window). Safe to call twice."""
        if self._v is None:
            return
        if threading.get_ident() != self._thread:
            raise ViewError("close: a view belongs to the thread that made it")
        v, self._v = self._v, None
        try:
            _views.discard(self)
            _forget(self)
            for item in self._items.values():
                item._keeps = None  # P2: the kept reference dies on close() too, not only remove()
            self._items.clear()
        finally:   # once `_v` is gone nothing else can destroy it: not even a Ctrl-C skips this
            self._lib.cadaclysm_view_destroy(v)

    def __del__(self):
        try:
            if getattr(self, "_v", None) is not None and threading.get_ident() == self._thread:
                self.close()
        except Exception:
            pass
