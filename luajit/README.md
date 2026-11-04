# cadaclysm for LuaJIT

Open CAD files and build exact solids from Lua, through LuaJIT's FFI: in
[LÖVE](https://github.com/love2d/love/releases) (Love2D), [LÖVR](https://github.com/bjornbytes/lovr/releases)
or a plain `luajit`. Nothing is compiled; the two libraries are loaded as they are.
The same object model as the Python module, name for name.

| File | What it is |
| --- | --- |
| `cadaclysm.lua` | The reader: `Scene`, `Node`, `Placement`, `Mesh`, `Polylines`, `Surfaces`, `Brep` ... |
| `cadaclysm_blacksmith.lua` | The kernel: `Profile`, `Path`, `Workplane`, `Solid`, `Frame`, `Selector` ... |
| `cadaclysm_cdef.lua`, `cadaclysm_blacksmith_cdef.lua` | The C headers as `ffi.cdef` text, **generated** by `gen_cdef.py` (in the repository); do not edit |
| `cadaclysm_love.lua` | LÖVE helper: meshes into `love.graphics` meshes, a lit 3D pass, 2D line work in one draw call |
| `cadaclysm_lovr.lua` | LÖVR helper: meshes and edges into LÖVR meshes, a lit shader, a camera, a table-top placement |
| `cadaclysm_view.lua`, `cadaclysm_view_cdef.lua` | Drawing: the terminal, a GPU window (`use_wgpu()`), a host's window, offscreen |
| `smoke/` | The smoke test every wrapper has: `luajit smoke/main.lua samples/cube.scad` |
| `test/` | The test suite: `luajit test/main.lua`, `lovec test` or `lovr test` |
| `examples/` | `love-part`, `love-drawing`, `love-forge`, `lovr-part`, and two fuller viewers |

```lua
local cadaclysm = require("cadaclysm")
local scene = cadaclysm.open("part.step", nil, "y-up")   -- metres, Y up
for node in scene:walk() do print(("  "):rep(node.depth) .. node.label) end
for _, placement in ipairs(scene.placements) do
  local mesh = placement.geometry.mesh      -- borrowed const float* / const uint32_t*
  local m = placement.raw_transform         -- 16 numbers, column-major
end
scene:close()

local bs = require("cadaclysm_blacksmith")
local part = bs.Solid.cuboid(20, 20, 20)
part = part:fillet(part.edges, 2)
part:step("box.stp")
```

## Install

Put this folder on `package.path`, or copy its files beside your `main.lua`, and the
libraries from the SDK's `lib/` (`python fetch.py`) beside them. The reader's library
is found through `CADACLYSM_LIBRARY` (the kernel's through
`CADACLYSM_BLACKSMITH_LIBRARY`), then beside the Lua file, beside a fused LÖVE game's
executable, and in a `lib/` or `target/release` of any parent; `load(path)` names it
outright. The website's [LÖVE and LÖVR page](https://cadaclysm.blitter.studio/engines/love.html)
walks through it with pictures, and the [LuaJIT reference](https://cadaclysm.blitter.studio/docs/luajit.html)
lists every call.

## Drawing

```lua
local view = require("cadaclysm_view")
view.use_wgpu()                    -- the GPU window; the terminal is the default
part:show()                        -- blocks until the window is closed
local camera = scene:view({ view = "top" })
local v = view.View.offscreen(800, 600)
v:show_solid(part); v:standard("iso"); v:frame(); v:save("part.png"); v:close()
```

Solids and scenes are drawn by handle. The library is found through
`CADACLYSM_TERMINAL_LIBRARY` / `CADACLYSM_VIEW_LIBRARY` as the reader's is;
`CADACLYSM_VIEW` (`terminal`, `wgpu` or a path) picks one without code. In LÖVE or LÖVR,
`View.in_window{ kind = ..., window = ..., width = ..., height = ... }` draws into the
engine's own window from its native handle, beside `cadaclysm_love.lua` and
`cadaclysm_lovr.lua`; the host forwards input with `v:input{...}`, calls `v:resize` and
`v:draw`, and `view.pump(0)` from its own loop keeps a window of the library's own live.

A CAM job plays on the view's timeline, as Python's `show_machining` does:

```lua
local m = v:show_machining({ { { number = 1, shape = "flat", diameter = 6, flute_length = 20 }, gcode } },
                           { { -42, -27, 0 }, { 42, 27, 14 } }, nil, { cell = 0.5 })
v:play(4)                          -- v:pause(), v:seek(s), v:loop(on), v:time(), v:duration(), v:playing(), v:status()
m:seek_move(m:info().moves)        -- m:colour_by("tool"), m:overlays(path, tool), m:heights() (nx * ny numbers)
```

## Notes

- **Fields, not calls.** What Python spells as a property is a field here
  (`node.name`, `bounds.size`, `solid.faces`); what Python calls is a method
  (`scene:query(filter)`, `solid:fillet(edges, 2)`). `Path.end` is `path:end_()`,
  `end` being a Lua keyword.
- **Borrowed memory.** Mesh and polyline pointers point into the scene; views keep
  their scene alive, and `scene:close()` invalidates them. A kernel mesh view owns a
  held tessellation instead, so it stays valid across any re-mesh and the solid's own
  close (`view.valid` always reports `true`).
- **Indices** the library counts (nodes, faces, edges, mesh indices) count from zero;
  the Lua arrays the wrapper builds count from one.
- **Errors** are `CadaclysmError` / `BuildError` values: `pcall` catches them,
  `tostring(err)` is the message.
- **Where it cannot run:** love.js (no FFI) and 32-bit builds. A fused `.love` cannot
  load a library from inside its archive; ship the libraries beside the executable.
- **LÖVR 0.19:** `lovr.filesystem.getSource()` can be relative, `lovr.event.quit(code)`
  exits 0 whatever the code (the smoke and tests use `os.exit`), and on Windows it
  prints to a console of its own -- `CADACLYSM_SMOKE_LOG` / `CADACLYSM_TEST_LOG` write
  the report to a file.

Measured on Windows with a 5.8-million-triangle assembly (2,813 meshes): LÖVE 11.5
uploads it in 0.6-0.9 s and draws 57 fps; LÖVR 0.19 uploads it in 0.3 s and draws
123 fps with its 853k edge segments; `love-drawing`'s one-mesh line work draws the same
853k segments at 397 fps.
