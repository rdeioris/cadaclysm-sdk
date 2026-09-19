"""The terminal viewer bundled with the SDK: sixel, kitty or half blocks, over ssh
included. Importing this module selects the terminal viewer; after another viewer was
selected, call `cadaclysm_terminal.select()` to switch back.

The library is cadaclysm-terminal, free to use (no license check).
"""

import os
import sys
from pathlib import Path

__all__ = ["NotFound", "library_path", "select"]


def _name() -> str:
    if sys.platform == "win32":
        return "cadaclysm_terminal.dll"
    return "libcadaclysm_terminal.dylib" if sys.platform == "darwin" else "libcadaclysm_terminal.so"


class NotFound(FileNotFoundError):
    """The default search found no library; `searched` is every place it looked."""

    def __init__(self, searched):
        self.searched = list(searched)
        super().__init__(f"{_name()} not found in: " + ", ".join(str(c) for c in self.searched))


def library_path() -> Path:
    """Where the terminal viewer library is: CADACLYSM_TERMINAL_LIBRARY (the library, or
    a directory holding it), beside this module (the wheel), `lib/` or
    `target/{release,debug}` in an ancestor (a checkout).

    CADACLYSM_TERMINAL_LIBRARY, when set, is authoritative: it is not a candidate to
    fall through from, so a value that names nothing raises rather than searching on.
    Nothing found by the default search raises `NotFound`, which lists where it looked.
    """
    override = os.environ.get("CADACLYSM_TERMINAL_LIBRARY")
    if override:
        candidate = Path(override)
        # A directory or the library itself, like CADACLYSM_LIBRARY.
        candidate = candidate / _name() if candidate.is_dir() else candidate
        if candidate.is_file():
            return candidate
        raise FileNotFoundError(f"CADACLYSM_TERMINAL_LIBRARY={override} names nothing that exists"
                                + (f" (no {_name()} in that directory)" if Path(override).is_dir() else ""))

    candidates = []
    here = Path(__file__).resolve().parent
    candidates.append(here / _name())
    for folder in (here, *here.parents):
        candidates += [folder / "lib" / _name(), folder / "target" / "release" / _name(),
                       folder / "target" / "debug" / _name()]
    for c in candidates:
        if c.is_file():
            return c
    raise NotFound(candidates)


def select() -> "Viewer":  # noqa: F821 -- the loader's Viewer, not imported at module scope
    """Make the terminal viewer the one in use, and return it. Called once when this
    module is imported; call it again after another viewer was selected, to switch
    back (a second `import cadaclysm_terminal` is a no-op once it is cached)."""
    try:
        from cadaclysm import viewer
    except ImportError:
        import cadaclysm_viewer as viewer
    return viewer.use(library_path())


select()
