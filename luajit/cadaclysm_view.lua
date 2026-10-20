--[[
Drawing through cadaclysm_view.h: the terminal by default, the GPU window with
`use_wgpu()`, a host's window with `View.in_window`, or offscreen with `View.offscreen`.

    local view = require("cadaclysm_view")
    view.use_wgpu()
    part:show()                                  -- blocks until the window is closed
    local v = view.View.offscreen(800, 600)      -- no display needed
    v:show_solid(part); v:standard("iso"); v:frame(); v:save("part.png")

Solids and scenes are shown by handle; an Item holds the object it shows, so a solid
dropped by the caller stays drawable until the item is removed or the view closed. A
scene must stay open while an item shows it: `scene:close()` removes those items first.
A view nobody holds is destroyed by the garbage collector; `v:close()` does it at once.

The library is loaded on first use, and the reader and the kernel are not: a script that
only draws meshes or curves loads the view library alone.

A window of a view's own on the wgpu library is kept live by `v:run()` (which blocks until
it is closed), `view.pump(ms)` from the script's own loop, or `obj:show()` / `obj:view()`,
which run it for you. There is no background timer: a Lua state is one thread, and a host
(LOVE, LOVR) has a loop of its own to call `pump` from.

**Errors** are `ViewError` values: `tostring(err)` is the message, `getmetatable(err) ==
view.ViewError` identifies one. A refusal carries the library's own reason, as Python's does.
]]
local ffi = require("ffi")
local bit = require("bit")

-- The declarations, once per LuaJIT state, through the same prefix logic as cadaclysm.lua so
-- a host that requires this module as `lib.cadaclysm_view` (LOVE, LOVR) finds its siblings.
local prefix = (...) and (...):match("^(.-)[^%.]*$") or ""
if not pcall(ffi.typeof, "struct CadaclysmViewOptions") then
  ffi.cdef(require(prefix .. "cadaclysm_view_cdef"))
end

local M = {}

-- 1.6: text -- cadaclysm_view_show_text, _set_text, _load_font and the text layer.
-- 1.7: the machining and timeline calls (not bound here yet).
-- 1.8: the pick's `clicks` and `point`, cadaclysm_view_set_double_click_frames, _focus, _navigation.
-- 1.9: cadaclysm_view_set_lighting and _lighting (headlight or studio).
-- 1.10: the viewport cameras -- each move's trailing viewport, camera/set_camera, viewport_rects, aim, pivot, tap.
-- 1.11: cadaclysm_view_show_points.
local ABI_MAJOR, ABI_MINOR = 1, 11
local NAVIGATION_FLY = 1   -- CADACLYSM_VIEW_NAVIGATION_FLY (ORBIT is 0)
local OPEN, CLOSED = 1, 2
local INPUT_CLOSE, NONE_COMING = 1, 0xFFFFFFFF
local UINT_MAX = 4294967295

-- Names to numbers, with their order kept for the messages that list them.
local function names(list)
  local t = { _list = list }
  for i, n in ipairs(list) do t[n] = i - 1 end
  return t
end
local STANDARD = names({ "top", "front", "right", "iso" })
local LAYERS = names({ "surfaces", "edges", "curves", "isocurves", "grid", "text" })
local GRIDS = names({ "none", "top", "front", "right" })
local LOD_MOTION = names({ "detailed", "smooth" })
local SURFACES = names({ "exact", "triangles" })
local LIGHTING = names({ "headlight", "studio" })
local ALIGN = names({ "top-left", "top", "top-right", "left", "centre", "right", "bottom-left", "bottom", "bottom-right" })
ALIGN.center = ALIGN.centre   -- the American spelling is taken too (and named in the message)
ALIGN._list = { "top-left", "top", "top-right", "left", "centre", "center", "right", "bottom-left", "bottom", "bottom-right" }
local TEXT_MODES = names({ "label", "world" })
local POINTERS = names({ "mouse", "touch", "pen" })
local CAMERA_KINDS = names({ "orbit", "fly", "ortho", "fixed" })
local EVENTS = { pointer_down = 1, pointer_move = 2, pointer_up = 3, pointer_cancel = 4, wheel = 5, key = 6,
  _list = { "pointer_down", "pointer_move", "pointer_up", "pointer_cancel", "wheel", "key" } }
local WINDOWS = { win32 = 1, xlib = 2, xcb = 3, wayland = 4, appkit = 5,
  _list = { "win32", "xlib", "xcb", "wayland", "appkit" } }
local VIEWS = { front = { -90, 0 }, back = { 90, 0 }, left = { 180, 0 }, right = { 0, 0 },
  top = { -90, 90 }, bottom = { -90, -90 }, iso = { -50, 28 } }
local VIEW_LIST = { "front", "back", "left", "right", "top", "bottom", "iso" }
local ORBIT_PER_PIXEL, ZOOM_PER_STEP = 0.01, 0.9   -- cadaclysm_view::view
M.OPEN, M.CLOSED, M.VIEWS = OPEN, CLOSED, VIEWS

---@class ViewError
---@field message string
local ViewError = { __tostring = function(e) return e.message end }
ViewError.__index = ViewError
M.ViewError = ViewError
local function fail(message, level)
  error(setmetatable({ message = message }, ViewError), (level or 1) + 1)
end

local function describe(v)
  if v == nil then return "nil" end
  if type(v) == "string" then return ("%q"):format(v) end
  return type(v)
end

-- ---- clocks and sleeping -----------------------------------------------------------------

-- A blocking sleep (pump's wait with no window of its own, pick's retry) and a millisecond
-- clock for input events. Declared with pcall: another module may have declared them, and
-- whatever a platform lacks falls back to what plain Lua has.
local sleep_impl, now_impl
if ffi.os == "Windows" then
  pcall(ffi.cdef, "void Sleep(uint32_t ms);")
  pcall(ffi.cdef, "uint64_t GetTickCount64(void);")
  sleep_impl = function(ms) ffi.C.Sleep(ms) end
  if pcall(function() return ffi.C.GetTickCount64 end) then
    now_impl = function() return tonumber(ffi.C.GetTickCount64()) end
  end
else
  pcall(ffi.cdef, "int usleep(uint32_t usec);")
  pcall(ffi.cdef, "int clock_gettime(int clock, void *ts);")
  sleep_impl = function(ms) ffi.C.usleep(ms * 1000) end
  if pcall(function() return ffi.C.clock_gettime end) then
    local ts, clock = ffi.new("long[2]"), ffi.os == "OSX" and 6 or 1   -- CLOCK_MONOTONIC
    now_impl = function()
      if ffi.C.clock_gettime(clock, ts) ~= 0 then return os.clock() * 1000 end
      return tonumber(ts[0]) * 1000 + tonumber(ts[1]) / 1e6
    end
  end
end
now_impl = now_impl or function() return os.clock() * 1000 end

local function sleep_ms(ms)
  if not ms or ms ~= ms or ms <= 0 then return end
  ms = math.floor(ms)
  while ms > 0 do   -- usleep refuses a second or more on some systems
    local slice = math.min(ms, 500)
    sleep_impl(slice)
    ms = ms - slice
  end
end

-- ---- argument checks: this module's own errors, never a raw Lua one -----------------------

local function number(v, what)
  if type(v) ~= "number" or v ~= v then fail(what .. ": a number, not " .. describe(v), 3) end
  return v
end

-- `level`: how many calls up the caller to blame is, counted from uint's caller (default 1).
local function uint(v, what, level)
  if type(v) ~= "number" or v ~= math.floor(v) or v < 0 or v > UINT_MAX then
    fail(what .. ": a whole number from 0 to " .. UINT_MAX .. ", not " .. describe(v), 2 + (level or 1))
  end
  return v
end

local function name_of(table_, value, what)
  local n = type(value) == "string" and table_[value]
  if not n then
    fail(("%s %s: one of %s"):format(what, describe(value), table.concat(table_._list, ", ")), 3)
  end
  return n
end

local function table_of(v, what)
  if type(v) ~= "table" then fail(what .. ": a table of numbers, not " .. describe(v), 3) end
  return v
end

-- A Lua array as a C array that is never NULL, even empty (an empty list must reach the
-- library as an empty list, not as the NULL that means "none"). Returns the array and its count.
local function carray(ctype, t, what)
  table_of(t, what)
  local whole = ctype == "uint8_t" and 255 or ctype:sub(1, 4) == "uint" and UINT_MAX or nil
  local n = #t
  local a = ffi.new(ctype .. "[?]", math.max(n, 1))
  for i = 1, n do
    local v = t[i]
    if type(v) ~= "number" then fail(("%s: item %d is %s, not a number"):format(what, i, describe(v)), 3) end
    if whole and (v ~= math.floor(v) or v < 0 or v > whole) then
      fail(("%s: item %d is %s, not a whole number from 0 to %d"):format(what, i, tostring(v), whole), 3)
    end
    a[i - 1] = v
  end
  return a, n
end

-- Exactly `n` numbers as a C array (a colour: C reads three; a matrix: sixteen).
local function exactly(ctype, t, n, what)
  if t == nil then return nil end
  local a, count = carray(ctype, t, what)
  if count ~= n then fail(("%s: %d numbers, not %d"):format(what, n, count), 3) end
  return a
end

-- A colour's numbers (Python's `_colour`): text -- "#rgb", "#rrggbb" (the "#" optional) or one
-- of the 148 CSS colour names, any case -- read by the library's own cadaclysm_view_parse_colour
-- (three, in 0..1; a ViewError with the library's message where it is no colour), anything else
-- as given. `lib`: the view's library.
local function colour_of(lib, value)
  if type(value) ~= "string" then return value end
  local out = ffi.new("float[3]")
  if not lib.C.cadaclysm_view_parse_colour(value, out) then
    local why = ffi.string(lib.C.cadaclysm_view_last_error())
    fail(why ~= "" and why or ("colour " .. describe(value)), 3)
  end
  return { out[0], out[1], out[2] }
end

-- A colour as three floats: text (through the library), or exactly three numbers; nil stays nil.
local function floats3(t, what, lib) return exactly("float", colour_of(lib, t), 3, what) end

-- A colour as four floats: text (alpha 1), or three or four numbers (alpha 1 where only three
-- were given); nil stays nil.
local function rgba4(c, what, lib)
  if c == nil then return nil end
  local a, n = carray("float", colour_of(lib, c), what)
  if n ~= 3 and n ~= 4 then fail(("%s: 3 or 4 numbers, not %d"):format(what, n), 3) end
  local out = ffi.new("float[4]", a[0], a[1], a[2], n == 4 and a[3] or 1)
  return out
end

-- A node argument: an index (from zero) or anything with an `index`.
local function node_index(node, what)
  if type(node) == "table" then
    if node.index == nil then fail(what .. ": a node (or its index), not a table without an index", 3) end
    node = node.index
  end
  return uint(node, what)
end

-- ---- finding a library -------------------------------------------------------------------

local function file_name(base)
  if ffi.os == "Windows" then return base .. ".dll" end
  if ffi.os == "OSX" then return "lib" .. base .. ".dylib" end
  return "lib" .. base .. ".so"
end

local function is_dir(p)
  local f = io.open(p, "rb")
  if f then
    local _, _, code = f:read(1)
    f:close()
    return code == 21 -- EISDIR: POSIX opens a directory and fails the read
  end
  return os.rename(p, p) and true or false -- Windows refuses to open one at all
end

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

local function module_dir()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) ~= "@" then return nil end
  return (source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$")) or "."
end

local function parent_of(dir) return dir:match("^(.*)/[^/]+$") end

-- `override` and `here` stand in for the variable's value and this file's folder (tests; ""
-- for no variable).
local function find(base, variable, override, here)
  local name = file_name(base)
  local terminal = base:sub(-9) == "_terminal"
  if override == nil then override = os.getenv(variable) end
  if override and override ~= "" then
    override = override:gsub("\\", "/")
    local directory = is_dir(override)
    if directory and exists(override .. "/" .. name) then return override .. "/" .. name end
    if not directory and exists(override) then return override end
    -- Python's words: the terminal's variable also says which file a directory lacks.
    fail(variable .. "=" .. override .. " names nothing that exists"
      .. ((terminal and directory) and (" (no " .. name .. " in that directory)") or ""), 3)
  end
  local searched = {}
  if here == nil then here = module_dir() end
  if here then searched[#searched + 1] = here .. "/" .. name end
  local dirs, dir = {}, here
  while dir and dir ~= "" do dirs[#dirs + 1] = dir; dir = parent_of(dir) end
  for _, d in ipairs(dirs) do searched[#searched + 1] = d .. "/lib/" .. name end
  for _, d in ipairs(dirs) do
    searched[#searched + 1] = d .. "/target/release/" .. name
    searched[#searched + 1] = d .. "/target/debug/" .. name
  end
  for _, c in ipairs(searched) do if exists(c) then return c end end
  local where = table.concat(searched, ", ")
  if terminal then
    fail("no view library: the terminal library was not found (searched: " .. where .. ") "
      .. "-- reinstall cadaclysm, set CADACLYSM_TERMINAL_LIBRARY to the library, or set CADACLYSM_VIEW", 3)
  end
  fail("no view library: " .. name .. " was not found (searched: " .. where .. ") "
    .. "-- reinstall cadaclysm, set " .. variable .. " to it, or use_terminal()", 3)
end
M._find = find

-- Every function this module calls, checked at load: LuaJIT resolves a symbol on first use,
-- so a library missing one would otherwise fail in the middle of a draw.
local ENTRY_POINTS = {
  "cadaclysm_view_last_error", "cadaclysm_view_name", "cadaclysm_view_create", "cadaclysm_view_destroy",
  "cadaclysm_view_pump", "cadaclysm_view_run", "cadaclysm_view_resize", "cadaclysm_view_needs_draw",
  "cadaclysm_view_draw", "cadaclysm_view_show", "cadaclysm_view_remove", "cadaclysm_view_set_surfaces",
  "cadaclysm_view_surfaces", "cadaclysm_view_orbit", "cadaclysm_view_pan", "cadaclysm_view_zoom",
  "cadaclysm_view_frame", "cadaclysm_view_standard", "cadaclysm_view_set_orthographic", "cadaclysm_view_set_layer",
  "cadaclysm_view_set_background", "cadaclysm_view_set_node_visible", "cadaclysm_view_set_node_color",
  "cadaclysm_view_set_node_highlight", "cadaclysm_view_set_viewports", "cadaclysm_view_request_pick",
  "cadaclysm_view_request_pick_in", "cadaclysm_view_pick_result", "cadaclysm_view_frame_node", "cadaclysm_view_look",
  "cadaclysm_view_dolly", "cadaclysm_view_input", "cadaclysm_view_show_mesh", "cadaclysm_view_show_lines",
  "cadaclysm_view_show_points", "cadaclysm_view_show_curves", "cadaclysm_view_show_image", "cadaclysm_view_set_colour", "cadaclysm_view_set_xray",
  "cadaclysm_view_set_face_colours", "cadaclysm_view_set_placement", "cadaclysm_view_show_solid", "cadaclysm_view_image",
  "cadaclysm_view_size", "cadaclysm_view_set_lod", "cadaclysm_view_wake_ms", "cadaclysm_view_set_node_transforms",
  "cadaclysm_view_parse_colour", "cadaclysm_view_load_font", "cadaclysm_view_show_text", "cadaclysm_view_set_text",
  "cadaclysm_view_set_double_click_frames", "cadaclysm_view_focus", "cadaclysm_view_navigation",
  "cadaclysm_view_set_lighting", "cadaclysm_view_lighting",
  "cadaclysm_view_viewport_camera", "cadaclysm_view_set_viewport_camera", "cadaclysm_view_set_viewport_rects",
  "cadaclysm_view_aim", "cadaclysm_view_set_pivot", "cadaclysm_view_set_tap", "cadaclysm_view_orbit_in",
  "cadaclysm_view_pan_in", "cadaclysm_view_zoom_in", "cadaclysm_view_look_in", "cadaclysm_view_dolly_in",
  "cadaclysm_view_frame_in", "cadaclysm_view_standard_in",
}

local open_views = {}   -- windows of a view's own on the wgpu library, in the order made

-- "wgpu" (cadaclysm_view), "terminal" (cadaclysm_terminal) or "other" -- Python's Library.kind.
local function library_kind(name)
  return name:sub(1, 15) == "cadaclysm-view " and "wgpu" or name:sub(1, 19) == "cadaclysm-terminal " and "terminal" or "other"
end

-- Every library ever loaded, by path: a clib that is collected unloads its library, and a
-- level-of-detail thread of a view made with it may still run in its code after another
-- library is chosen. So none is let go while this module lives.
local loaded_clibs = {}

-- A loaded library `C` (a clib, or a table of functions standing in for one) checked as a view
-- library: its ABI version first, so a library missing a newer call says its version, not "no
-- symbol"; then every entry point; then its name.
local function bound(path, C)
  if not pcall(function() return C.cadaclysm_view_abi_version end) then
    fail(path .. ": not a view library (no abi version)", 3)
  end
  local version = C.cadaclysm_view_abi_version()
  local major, minor = bit.rshift(version, 16), bit.band(version, 0xFFFF)
  if major ~= ABI_MAJOR or minor < ABI_MINOR then
    fail(("%s: view ABI %d.%d, this wrapper needs %d.%d or a later %d.x"):format(path, major, minor, ABI_MAJOR, ABI_MINOR, ABI_MAJOR), 3)
  end
  for _, name in ipairs(ENTRY_POINTS) do
    if not pcall(function() return C[name] end) then fail(path .. ": not a view library (no " .. name .. ")", 3) end
  end
  local name = ffi.string(C.cadaclysm_view_name())
  return { C = C, path = path, name = name, kind = library_kind(name) }
end
M._bound = bound

local function load(path)
  local ok, C = pcall(ffi.load, path)
  if not ok then fail(path .. ": could not load the view library: " .. tostring(C), 3) end
  loaded_clibs[path] = C
  return bound(path, C)
end

local current

--- Draw with the terminal library (the default) from now on.
function M.use_terminal() current = load(find("cadaclysm_terminal", "CADACLYSM_TERMINAL_LIBRARY")); return current end
--- Draw with the GPU window library, cadaclysm_view, from now on.
function M.use_wgpu() current = load(find("cadaclysm_view", "CADACLYSM_VIEW_LIBRARY")); return current end
--- Draw with the view library at `path` from now on. (For tests, a table `{ C = functions by their
--- header names, name = the library's name }` stands in for a loaded library.)
function M.use(path)
  if type(path) == "table" and type(path.C) == "table" then
    local name = tostring(path.name or "other")
    current = { C = path.C, path = nil, name = name, kind = library_kind(name) }
    return current
  end
  if type(path) ~= "string" then fail("use: the path of a view library, not " .. describe(path), 2) end
  current = load(path)
  return current
end
--- The library in use: the last use*(), else CADACLYSM_VIEW (terminal, wgpu or a path), else the terminal.
function M.current()
  if current then return current end
  local chosen = os.getenv("CADACLYSM_VIEW")
  if chosen == "wgpu" then return M.use_wgpu() end
  if not chosen or chosen == "" or chosen == "terminal" then return M.use_terminal() end
  return M.use(chosen)
end

--- Forget the library in use and the window list (tests).
function M._reset() current = nil; open_views = {} end
--- The library in use, or nil -- without loading one (tests: closing a scene must not).
function M._loaded() return current end

-- The library's own reason, bare (Python's `_error`).
local function last_error(lib) return ffi.string(lib.C.cadaclysm_view_last_error()) end
local function failure(lib, level)
  local why = last_error(lib)
  fail(why ~= "" and why or "the view library failed", (level or 1) + 1)
end

--- A TTF/OTF font for every view of the library in use: a string naming an existing file is
--- read as a path, any other string is the font's own bytes (so a misspelt path is the
--- library's "not a font", not a file error). Its id is show_text's `font`; font 0 is the
--- bundled Liberation Sans. Choose the library first (use_wgpu/use_terminal/use): a font id
--- belongs to the library that loaded it, and means nothing -- or another font -- to a library
--- chosen afterwards.
function M.load_font(font)
  if type(font) ~= "string" then fail("load_font: a path or the font's bytes, not " .. describe(font), 2) end
  local bytes = font
  local f = #font < 4096 and not font:find(string.char(0), 1, true) and io.open(font, "rb")   -- a long string, or one with a NUL, is bytes, never a path
  if f then
    local read = f:read("*a")   -- nil for a directory
    f:close()
    bytes = read or font
  end
  local lib = M.current()
  local id = lib.C.cadaclysm_view_load_font(bytes, #bytes)
  if id == 0 then failure(lib, 2) end
  return tonumber(id)
end

-- ---- View and Item -----------------------------------------------------------------------

local View, Item = {}, {}
View.__index, Item.__index = View, Item
View.__tostring = function(v)
  return ("<View %s%s>"):format(v._lib.name, rawget(v, "_ptr") == nil and " closed" or "")
end
M.View, M.Item = View, Item
local live_views = setmetatable({}, { __mode = "k" })   -- every live view, weakly: M._release walks it

local function new_view(opts, window, offscreen, w, h)
  if opts ~= nil and type(opts) ~= "table" then fail("view: options are a table, not " .. describe(opts), 3) end
  opts = opts or {}
  local lib = M.current()
  local surfaces = name_of(SURFACES, opts.surfaces or "exact", "surfaces")
  local up = tostring(opts.up or "z"):lower()
  if up ~= "y" and up ~= "z" then fail("up " .. describe(opts.up) .. ": 'y' or 'z'", 3) end
  local title = opts.title ~= nil and tostring(opts.title) or "Cadaclysm"
  if title == "" then title = "Cadaclysm" end
  local o = ffi.new("CadaclysmViewOptions", {
    size = ffi.sizeof("CadaclysmViewOptions"), surfaces = surfaces,
    backend = uint(opts.backend or 0, "backend"), y_up = up == "y" and 1 or 0, title = title,
    width = uint(w or 0, "width"), height = uint(h or 0, "height"), offscreen = offscreen and 1 or 0,
  })
  local p = lib.C.cadaclysm_view_create(window, o)
  local keep = title   -- the string `o.title` points into: kept past the call
  if p == nil then
    local why = last_error(lib)
    if why == "" then why = "the view library failed" end
    if why:find("no display", 1, true) then
      why = why .. " -- draw without a display with View.offscreen(width, height), or use_terminal()"
    end
    fail(why, 3)
  end
  local C = lib.C
  local self = setmetatable({ _lib = lib, _ptr = ffi.gc(p, function(q) C.cadaclysm_view_destroy(q) end),
    _items = {}, _y_up = up == "y", _own = window == nil and not offscreen, _drawn = false, _title = keep }, View)
  live_views[self] = true
  if self._own and lib.kind == "wgpu" then open_views[#open_views + 1] = self end
  return self
end

--- A window of the library's own: { title, width, height, surfaces, up, backend }.
function View.new(opts)
  if opts ~= nil and type(opts) ~= "table" then fail("view: options are a table, not " .. describe(opts), 2) end
  opts = opts or {}
  return new_view(opts, nil, false, opts.width, opts.height)
end
--- A view with no window and no display, `width` x `height` pixels.
function View.offscreen(w, h, opts)
  if w == nil or h == nil then fail("offscreen: a width and a height in pixels, not " .. describe(w) .. " and " .. describe(h), 2) end
  return new_view(opts, nil, true, w, h)
end
--- A host's window: { kind = "win32"|"xlib"|"xcb"|"wayland"|"appkit", window = cdata or number, window_id,
--- display = cdata, width, height }.
function View.in_window(window, opts)
  if type(window) ~= "table" then fail("in_window: a table describing the host's window, not " .. describe(window), 2) end
  if not window.width or not window.height or window.width == 0 or window.height == 0 then
    fail("a host's window needs width and height: its client size in physical pixels", 2)
  end
  local kind = window.kind or (ffi.os == "Windows" and "win32" or ffi.os == "OSX" and "appkit" or "xlib")
  local which = name_of(WINDOWS, kind, "kind")
  if which >= 2 and which <= 4 and window.display == nil then
    fail(("kind %q needs display (the Display*, xcb_connection_t* or wl_display*)"):format(kind), 2)
  end
  local function pointer(v) if type(v) == "number" then return ffi.cast("void *", v) end return v end
  local id = window.window_id
  if id == nil and (kind == "xlib" or kind == "xcb") and type(window.window) == "number" then id = window.window end
  local raw = ffi.new("CadaclysmViewWindow", {
    size = ffi.sizeof("CadaclysmViewWindow"), kind = which,
    window = (kind ~= "xlib" and kind ~= "xcb") and pointer(window.window) or nil,
    window_id = id or 0, display = pointer(window.display),
    width = uint(window.width, "width"), height = uint(window.height, "height"),
  })
  return new_view(opts, raw, false, window.width, window.height)
end

--- The live pointer, refusing a closed view or a closed window. `call` names the library call
--- for the message, as Python's does.
function View:_live(call)
  call = call or "view"
  local p = rawget(self, "_ptr")
  if p == nil then fail(call .. ": the view is closed", 3) end
  if self._window_closed then fail(call .. ": the window is closed", 3) end
  return p
end

function View:_item(id, shown)
  if id == 0 then failure(self._lib, 3) end
  local item = setmetatable({ view = self, id = id, shown = shown }, Item)
  self._items[id] = item
  return item
end

-- Text for a C string: a NUL would end it early, so it is refused rather than cut.
local function text_of(text)
  if type(text) ~= "string" then fail(("text: a string, not %s"):format(type(text)), 3) end
  if text:find("\0", 1, true) then
    fail(("text %q: a NUL character cannot be shown (the C string ends there)"):format(text), 3)
  end
  return text
end

-- A vector of exactly n numbers (never colour text); nil is refused, naming the field.
local function vector(t, n, what)
  if t == nil then fail(("%s: %d numbers, not nil"):format(what, n), 3) end
  return exactly("float", t, n, what)
end

local function ok(self, done) if not done then failure(self._lib, 3) end end

-- After a call with no result: a refusal is the library's last error (Python's `_void`).
local function void_ok(self)
  local why = last_error(self._lib)
  if why ~= "" then fail(why, 3) end
end

--- Whether the view is closed or its window was.
function View:closed() return rawget(self, "_ptr") == nil or self._window_closed == true end

-- What an object is, by metatable, from the modules already loaded: an object of one of the
-- wrapper classes means its module is loaded, so nothing is required here and no library opens.
local function kind_of(obj)
  local mt = type(obj) == "table" and getmetatable(obj) or nil
  if mt == nil then return nil end
  local bs = package.loaded[prefix .. "cadaclysm_blacksmith"]
  if type(bs) == "table" and mt == bs.Solid then return "solid" end
  local cad = package.loaded[prefix .. "cadaclysm"]
  if type(cad) == "table" then
    if mt == cad.Scene then return "scene" end
    if mt == cad.Node then return "node" end
  end
  return nil
end

--- A blacksmith Solid, a Scene or a Node, by handle.
function View:show(obj, rgb, tolerance)
  local kind = kind_of(obj)
  if kind == "solid" then return self:show_solid(obj, tolerance, rgb) end
  if kind == "scene" then return self:show_scene(obj) end
  if kind == "node" then return self:show_node(obj) end
  fail("show: a Solid, Scene or Node, not " .. describe(obj), 2)
end

function View:show_solid(solid, tolerance, rgb)
  if kind_of(solid) ~= "solid" then fail("show_solid: a Solid, not " .. describe(solid), 2) end
  tolerance = tolerance == nil and 0.05 or number(tolerance, "show_solid tolerance")
  local colour = floats3(rgb, "show_solid rgb", self._lib)
  return self:_item(self._lib.C.cadaclysm_view_show_solid(self:_live("cadaclysm_view_show_solid"), solid:_h(), tolerance, colour), solid)
end

function View:show_scene(scene, shown)
  if kind_of(scene) ~= "scene" then fail("show_scene: a Scene, not " .. describe(scene), 2) end
  return self:_item(self._lib.C.cadaclysm_view_show(self:_live("cadaclysm_view_show"), scene:handle()), shown or scene)
end

--- The node's scene by handle, with the siblings along the path from its root hidden: the
--- other roots, and at every ancestor the children not on the path. The ancestors' own
--- geometry stays visible; the node's subtree is untouched.
function View:show_node(node)
  if kind_of(node) ~= "node" then fail("show_node: a Node, not " .. describe(node), 2) end
  local item = self:show_scene(node.scene, node)
  local chain, at = {}, node
  while at do table.insert(chain, 1, at); at = at.parent end
  local level = node.scene.roots
  for _, on in ipairs(chain) do
    for _, other in ipairs(level) do if other.index ~= on.index then item:node_visible(other.index, false) end end
    level = on.children
  end
  return item
end

--- { positions = {...}, indices = {...}, normals = ?, edges = ?, rgb = ? }: three floats a vertex,
--- three indices a triangle, six floats an edge.
function View:show_mesh(mesh)
  if type(mesh) ~= "table" or mesh.positions == nil or mesh.indices == nil then
    fail("show_mesh: positions and indices are required", 2)
  end
  local positions, np = carray("float", mesh.positions, "show_mesh positions")
  if np % 3 ~= 0 then fail(("show_mesh: positions are 3 numbers a vertex, not %d"):format(np), 2) end
  local indices, ni = carray("uint32_t", mesh.indices, "show_mesh indices")
  local normals, edges, ne
  if mesh.normals ~= nil then
    local nn
    normals, nn = carray("float", mesh.normals, "show_mesh normals")
    if nn ~= np then fail(("show_mesh: %d positions but %d normals"):format(np / 3, nn / 3), 2) end
  end
  if mesh.edges ~= nil then
    edges, ne = carray("float", mesh.edges, "show_mesh edges")
    if ne % 6 ~= 0 then fail(("show_mesh: edges are two points a segment (6 numbers), not %d"):format(ne), 2) end
  end
  local rgb = floats3(mesh.rgb, "show_mesh rgb", self._lib)
  local m = ffi.new("CadaclysmViewMesh", {
    size = ffi.sizeof("CadaclysmViewMesh"), positions = positions, vertex_count = math.floor(np / 3), normals = normals,
    indices = indices, index_count = ni, edges = edges, edge_count = ne and ne / 6 or 0,
    rgb = rgb,
  })
  local item = self._lib.C.cadaclysm_view_show_mesh(self:_live("cadaclysm_view_show_mesh"), m)
  local _ = { positions, indices, normals, edges, rgb }   -- held to here: the library read them in place
  return self:_item(item, nil)
end

--- Six floats a segment: { x0, y0, z0, x1, y1, z1, ... }.
function View:show_lines(segments, rgb)
  local s, n = carray("float", segments, "show_lines")
  if n % 6 ~= 0 then fail(("show_lines: 6 numbers a segment, not %d"):format(n), 2) end
  return self:_item(self._lib.C.cadaclysm_view_show_lines(self:_live("cadaclysm_view_show_lines"), s, n / 6, floats3(rgb, "show_lines rgb", self._lib)), nil)
end

--- Three numbers a point: { x0, y0, z0, x1, y1, z1, ... }, each drawn as a disc `size_px` device
--- pixels across (1 to 64, default 8) in `rgb` (nil: the edge colour), as one item. A point does
--- not pick; the item is framed by its points' box. The library refuses a value that is not
--- finite and a size out of range; the terminal library refuses points.
function View:show_points(positions, rgb, size_px)
  local p, n = carray("float", positions, "show_points")
  if n % 3 ~= 0 then fail(("show_points: three numbers a point, not %d"):format(n), 2) end
  if size_px == nil then size_px = 8 end
  if type(size_px) ~= "number" then fail("show_points size_px: a number, not " .. describe(size_px), 2) end
  return self:_item(self._lib.C.cadaclysm_view_show_points(self:_live("cadaclysm_view_show_points"), p, n / 3, floats3(rgb, "show_points rgb", self._lib), size_px), nil)
end

--- Sixteen numbers a rational cubic: four control points as x, y, z, w.
function View:show_curves(beziers, rgb)
  local b, n = carray("float", beziers, "show_curves")
  if n % 16 ~= 0 then fail(("show_curves: 16 numbers a curve, not %d"):format(n), 2) end
  return self:_item(self._lib.C.cadaclysm_view_show_curves(self:_live("cadaclysm_view_show_curves"), b, n / 16, floats3(rgb, "show_curves rgb", self._lib)), nil)
end

--- corners: twelve numbers (bottom-left, bottom-right, top-right, top-left); rgba: a string,
--- an array of bytes (a table, or a uint8_t array cdata) of w * h * 4, rows from the top.
function View:show_image(corners, rgba, w, h, opacity)
  local c, nc = carray("float", corners, "show_image corners")
  if nc ~= 12 then fail(("show_image: corners are 12 numbers, not %d"):format(nc), 2) end
  uint(w, "show_image width")
  uint(h, "show_image height")
  local need = w * h * 4
  local pixels, have
  if type(rgba) == "string" then
    pixels, have = rgba, #rgba
  elseif type(rgba) == "table" then
    pixels, have = carray("uint8_t", rgba, "show_image rgba")
    have = #rgba
  elseif type(rgba) == "cdata" and tostring(ffi.typeof(rgba)):find("%[") and not tostring(ffi.typeof(rgba)):find("%*") then
    pixels, have = rgba, ffi.sizeof(rgba)
  else
    fail("show_image: rgba is a string, a table of bytes or a uint8_t array, not " .. describe(rgba), 2)
  end
  if need ~= have then fail(("show_image: %d x %d pixels need %d bytes (w * h * 4), not %d"):format(w, h, need, have), 2) end
  local img = ffi.new("CadaclysmViewImage", { size = ffi.sizeof("CadaclysmViewImage"),
    rgba = type(pixels) == "string" and ffi.cast("const uint8_t *", pixels) or pixels,
    width = w, height = h, opacity = opacity == nil and 1 or number(opacity, "show_image opacity") })
  for k = 0, 11 do img.corners[k] = c[k] end
  local item = self._lib.C.cadaclysm_view_show_image(self:_live("cadaclysm_view_show_image"), img)
  local _ = pixels   -- held to here: the library read it in place
  return self:_item(item, nil)
end

-- ---- the camera

-- 1.10: every move takes a trailing optional viewport (default 0). Viewport 0 is the plain
-- call, as before (the library's plain calls are viewport 0's); any other the `_in` form.
-- A bad viewport is reported at the caller of the View method, not at the method.
local function viewport_of(viewport, what)
  if viewport == nil then return 0 end
  return (uint(viewport, what .. " viewport", 2))
end

function View:orbit(dx, dy, viewport)
  number(dx, "orbit dx"); number(dy, "orbit dy")
  local vp = viewport_of(viewport, "orbit")
  if vp == 0 then
    self._lib.C.cadaclysm_view_orbit(self:_live("cadaclysm_view_orbit"), dx, dy)
  else
    self._lib.C.cadaclysm_view_orbit_in(self:_live("cadaclysm_view_orbit_in"), vp, dx, dy)
  end
  void_ok(self)
end
function View:pan(dx, dy, viewport)
  number(dx, "pan dx"); number(dy, "pan dy")
  local vp = viewport_of(viewport, "pan")
  if vp == 0 then
    self._lib.C.cadaclysm_view_pan(self:_live("cadaclysm_view_pan"), dx, dy)
  else
    self._lib.C.cadaclysm_view_pan_in(self:_live("cadaclysm_view_pan_in"), vp, dx, dy)
  end
  void_ok(self)
end
function View:zoom(steps, viewport)
  number(steps, "zoom steps")
  local vp = viewport_of(viewport, "zoom")
  if vp == 0 then
    self._lib.C.cadaclysm_view_zoom(self:_live("cadaclysm_view_zoom"), steps)
  else
    self._lib.C.cadaclysm_view_zoom_in(self:_live("cadaclysm_view_zoom_in"), vp, steps)
  end
  void_ok(self)
end
function View:look(dx, dy, viewport)
  number(dx, "look dx"); number(dy, "look dy")
  local vp = viewport_of(viewport, "look")
  if vp == 0 then
    self._lib.C.cadaclysm_view_look(self:_live("cadaclysm_view_look"), dx, dy)
  else
    self._lib.C.cadaclysm_view_look_in(self:_live("cadaclysm_view_look_in"), vp, dx, dy)
  end
  void_ok(self)
end
function View:dolly(ratio, viewport)
  number(ratio, "dolly ratio")
  local vp = viewport_of(viewport, "dolly")
  if vp == 0 then
    self._lib.C.cadaclysm_view_dolly(self:_live("cadaclysm_view_dolly"), ratio)
  else
    self._lib.C.cadaclysm_view_dolly_in(self:_live("cadaclysm_view_dolly_in"), vp, ratio)
  end
  void_ok(self)
end
function View:orthographic(on)
  self._lib.C.cadaclysm_view_set_orthographic(self:_live("cadaclysm_view_set_orthographic"), on ~= false)
  void_ok(self)
end
--- Whether a double click frames what it hit (off by default: it is a pick answered with
--- `clicks` 2 and the camera stays). Applies where the view takes the pick itself (its own
--- window, pump, run); a host reading picks frames if it chooses.
function View:set_double_click_frames(on)
  self._lib.C.cadaclysm_view_set_double_click_frames(self:_live("cadaclysm_view_set_double_click_frames"), on and true or false)
  void_ok(self)
end
--- Moves the orbit point to `point` ({x, y, z}, as a pick's `point`): the eye keeps its direction
--- and distance from it, so the camera moves sideways and does not turn. Leaves fly mode. Other
--- than three numbers is refused before the call; the library refuses a point that is not
--- finite, or while viewports are set, with its own reason.
function View:focus(point)
  if point == nil then fail("focus: 3 numbers, not nil", 2) end
  local at = exactly("float", point, 3, "focus")
  ok(self, self._lib.C.cadaclysm_view_focus(self:_live("cadaclysm_view_focus"), at))
end
--- How a left drag moves the camera: "orbit" (about the target) or "fly" (the view turns about
--- the eye). A fly key (W, A, S, D, E, Q) sent through `input` enters fly mode and it stays after
--- the key is let go; Tab toggles it; frame, standard and focus leave it.
function View:navigation()
  return self._lib.C.cadaclysm_view_navigation(self:_live("cadaclysm_view_navigation")) == NAVIGATION_FLY and "fly" or "orbit"
end
function View:standard(name, viewport)
  local which = name_of(STANDARD, name, "standard view")
  local vp = viewport_of(viewport, "standard")
  if vp == 0 then
    ok(self, self._lib.C.cadaclysm_view_standard(self:_live("cadaclysm_view_standard"), which))
  else
    ok(self, self._lib.C.cadaclysm_view_standard_in(self:_live("cadaclysm_view_standard_in"), vp, which))
  end
end
--- Fit the camera (of `viewport`, default 0) to everything shown.
function View:frame(viewport)
  local vp = viewport_of(viewport, "frame")
  if vp == 0 then
    ok(self, self._lib.C.cadaclysm_view_frame(self:_live("cadaclysm_view_frame"), 0))
  else
    ok(self, self._lib.C.cadaclysm_view_frame_in(self:_live("cadaclysm_view_frame_in"), vp, 0))
  end
end

-- The fields of CadaclysmViewViewportCamera that are arrays, with their lengths, and its numbers.
local CAMERA_ARRAYS = {
  { "view", 16 }, { "projection", 16 }, { "eye", 3 }, { "target", 3 },
  { "axis_view", 3 }, { "axis_right", 3 }, { "axis_up", 3 },
}
local CAMERA_NUMBERS = { "distance", "yaw", "pitch", "speed", "radius", "height" }

--- Viewport `viewport`'s camera (default 0; with no viewports set, the built-in orbit camera):
--- { kind = "orbit"|"fly"|"ortho"|"fixed", rect = {x, y, w, h}, view = 16, projection = 16,
--- eye, target, distance, yaw, pitch, orthographic (a boolean), speed, radius, height,
--- axis_view, axis_right, axis_up }, arrays 1-based, matrices column-major. set_camera takes it back.
function View:camera(viewport)
  local vp = viewport == nil and 0 or uint(viewport, "camera viewport")
  local out = ffi.new("CadaclysmViewViewportCamera", { size = ffi.sizeof("CadaclysmViewViewportCamera") })
  ok(self, self._lib.C.cadaclysm_view_viewport_camera(self:_live("cadaclysm_view_viewport_camera"), vp, out))
  local c = {
    kind = CAMERA_KINDS._list[out.kind + 1] or out.kind,
    rect = { out.rect[0], out.rect[1], out.rect[2], out.rect[3] },
    orthographic = out.orthographic ~= 0,
  }
  for _, f in ipairs(CAMERA_ARRAYS) do
    local name, n = f[1], f[2]
    local a = {}
    for k = 0, n - 1 do a[k + 1] = out[name][k] end
    c[name] = a
  end
  for _, name in ipairs(CAMERA_NUMBERS) do c[name] = out[name] end
  return c
end

--- Gives viewport `viewport` a camera from table `t` (as `camera` returns it): `kind` by name;
--- an ortho camera's basis is `axis_view`, `axis_right`, `axis_up`; a fixed camera's `view`,
--- `projection` and `eye`. Any other field may be left out (zero: the library's default).
--- `rect` is not read (`viewport_rects` moves a viewport).
function View:set_camera(viewport, t)
  uint(viewport, "set_camera viewport")
  if type(t) ~= "table" then fail("set_camera: a camera table, not " .. describe(t), 2) end
  local raw = ffi.new("CadaclysmViewViewportCamera", { size = ffi.sizeof("CadaclysmViewViewportCamera") })
  raw.kind = name_of(CAMERA_KINDS, t.kind, "camera kind")
  for _, f in ipairs(CAMERA_ARRAYS) do
    local name, n = f[1], f[2]
    local a = exactly("float", t[name], n, "camera " .. name)
    if a then for k = 0, n - 1 do raw[name][k] = a[k] end end
  end
  for _, name in ipairs(CAMERA_NUMBERS) do
    if t[name] ~= nil then raw[name] = number(t[name], "camera " .. name) end
  end
  local o = t.orthographic
  raw.orthographic = (o == true or (type(o) == "number" and o ~= 0)) and 1 or 0
  ok(self, self._lib.C.cadaclysm_view_set_viewport_camera(self:_live("cadaclysm_view_set_viewport_camera"), viewport, raw))
end

--- Moves the viewports: one { x, y, w, h } (physical pixels) per viewport set, their cameras kept.
function View:viewport_rects(rects)
  table_of(rects, "viewport_rects")
  local flat = {}
  for i, r in ipairs(rects) do
    if type(r) ~= "table" or #r ~= 4 then fail(("viewport_rects: rect %d is { x, y, w, h }, not %s"):format(i, describe(r)), 2) end
    for k = 1, 4 do flat[#flat + 1] = uint(r[k], ("viewport_rects: rect %d's %s"):format(i, ({ "x", "y", "w", "h" })[k]), 1) end
  end
  local a = carray("uint32_t", flat, "viewport_rects")
  ok(self, self._lib.C.cadaclysm_view_set_viewport_rects(self:_live("cadaclysm_view_set_viewport_rects"), a, #rects))
end

--- Turns viewport `viewport`'s camera to look along `direction` (world); `up`, an ortho
--- camera's screen up, defaults to +Z (+Y for a look along Z). True, or raises with the library's reason.
function View:aim(viewport, direction, up)
  uint(viewport, "aim viewport")
  local d = vector(direction, 3, "aim direction")
  local u = up ~= nil and vector(up, 3, "aim up") or nil
  ok(self, self._lib.C.cadaclysm_view_aim(self:_live("cadaclysm_view_aim"), viewport, d, u))
  return true
end

--- The point (world) Alt and the left button orbit viewport `viewport` about; nil: its own target again.
function View:pivot(viewport, point)
  uint(viewport, "pivot viewport")
  local p = point ~= nil and vector(point, 3, "pivot point") or nil
  ok(self, self._lib.C.cadaclysm_view_set_pivot(self:_live("cadaclysm_view_set_pivot"), viewport, p))
end

--- A click's most travel (`px`, physical pixels) and longest press (`ms`; 0: no limit) for `input` to pick.
function View:tap(px, ms)
  number(px, "tap px"); number(ms, "tap ms")
  ok(self, self._lib.C.cadaclysm_view_set_tap(self:_live("cadaclysm_view_set_tap"), px, ms))
end

--- { { rect = {x, y, w, h}, view = 16, projection = 16, eye = 3, grid = "none"|"top"|"front"|"right" }, ... },
--- matrices column-major. An empty list clears them (the view draws one pane again), as Python's does.
function View:viewports(list)
  table_of(list, "viewports")
  local p = self:_live("cadaclysm_view_set_viewports")
  if #list == 0 then
    ok(self, self._lib.C.cadaclysm_view_set_viewports(p, nil, 0))
    return
  end
  local raw = ffi.new("CadaclysmViewViewport[?]", #list)
  for i, v in ipairs(list) do
    if type(v) ~= "table" then fail(("viewports: pane %d is a table, not %s"):format(i, describe(v)), 2) end
    local slot = raw[i - 1]
    slot.size = ffi.sizeof("CadaclysmViewViewport")
    local rect = exactly("uint32_t", v.rect, 4, "viewport rect")
    local view = exactly("float", v.view, 16, "viewport view")
    local projection = exactly("float", v.projection, 16, "viewport projection")
    local eye = exactly("float", v.eye, 3, "viewport eye")
    if not (rect and view and projection and eye) then fail("viewports: each pane needs rect, view, projection and eye", 2) end
    for k = 0, 3 do slot.rect[k] = rect[k] end
    for k = 0, 15 do slot.view[k] = view[k]; slot.projection[k] = projection[k] end
    for k = 0, 2 do slot.eye[k] = eye[k] end
    slot.grid = name_of(GRIDS, v.grid or "none", "grid")
  end
  ok(self, self._lib.C.cadaclysm_view_set_viewports(p, raw, #list))
end
function View:layer(name, on)
  local which = name_of(LAYERS, name, "layer")
  ok(self, self._lib.C.cadaclysm_view_set_layer(self:_live("cadaclysm_view_set_layer"), which, on ~= false))
end
--- Text shown as one item (cadaclysm_view_show_text): a label anchored to `at`, or world text
--- (`opts.mode = "world"`) in the plane of `opts.right` and `opts.up` through `at`. `opts`: mode
--- ("label"/"world"), size, colour, align (nine names, "centre"/"center"), offset {x, y}, box
--- (a colour, or 3-4 numbers), padding, on_top, font (from load_font), right, up.
function View:show_text(text, at, opts)
  opts = opts or {}
  local s = text_of(text)
  local lib = self._lib
  local t = ffi.new("CadaclysmViewText")
  t.size = ffi.sizeof("CadaclysmViewText")
  t.text = s
  t.mode = name_of(TEXT_MODES, opts.mode or "label", "mode")
  local a = vector(at, 3, "show_text at")
  local size = opts.size == nil and 12 or opts.size
  local padding = opts.padding == nil and 4 or opts.padding
  local font = opts.font == nil and 0 or opts.font
  if type(size) ~= "number" or size ~= size then fail("show_text size: a number, not " .. describe(size), 2) end
  if type(padding) ~= "number" or padding ~= padding then fail("show_text padding: a number, not " .. describe(padding), 2) end
  uint(font, "show_text font")
  local offset = opts.offset ~= nil and vector(opts.offset, 2, "show_text offset") or nil
  local right = opts.right ~= nil and vector(opts.right, 3, "show_text right") or nil
  local up = opts.up ~= nil and vector(opts.up, 3, "show_text up") or nil
  local rgb = floats3(opts.colour or "white", "show_text colour", lib)
  for k = 0, 2 do t.at[k], t.rgb[k] = a[k], rgb[k] end
  if right then for k = 0, 2 do t.right[k] = right[k] end end
  if up then for k = 0, 2 do t.up[k] = up[k] end end
  t.height = size
  t.align = name_of(ALIGN, opts.align or "bottom-left", "align")
  if offset then t.offset[0], t.offset[1] = offset[0], offset[1] end
  if opts.box then local b = rgba4(opts.box, "show_text box", lib); for k = 0, 3 do t.box_rgba[k] = b[k] end end
  t.box_padding = padding
  t.on_top = opts.on_top and 1 or 0
  t.font = font
  local id = lib.C.cadaclysm_view_show_text(self:_live("cadaclysm_view_show_text"), t)
  return self:_item(id, s)   -- the item holds the string while C reads it (it copies; belt and braces)
end

--- The clear colour: text ("#rgb", "#rrggbb", a CSS colour name) or three numbers in 0..1.
function View:background(rgb)
  if rgb == nil then fail("background: 3 numbers, not nil", 2) end
  local c = floats3(rgb, "background", self._lib)
  self._lib.C.cadaclysm_view_set_background(self:_live("cadaclysm_view_set_background"), c)
  void_ok(self)
end
--- "exact" or "triangles": how surfaces are drawn. With an argument, sets it.
function View:surfaces(name)
  if name == nil then
    return self._lib.C.cadaclysm_view_surfaces(self:_live("cadaclysm_view_surfaces")) == 1 and "triangles" or "exact"
  end
  ok(self, self._lib.C.cadaclysm_view_set_surfaces(self:_live("cadaclysm_view_set_surfaces"), name_of(SURFACES, name, "surfaces")))
end
--- "headlight" or "studio": how plain parts are lit, as Python's View.lighting -- the headlight
--- (the default) brightens whatever faces the camera; studio is a key light fixed above the scene
--- with an ambient and a camera fill. With an argument, sets it; another name is refused before C.
function View:lighting(name)
  if name == nil then
    return self._lib.C.cadaclysm_view_lighting(self:_live("cadaclysm_view_lighting")) == 1 and "studio" or "headlight"
  end
  ok(self, self._lib.C.cadaclysm_view_set_lighting(self:_live("cadaclysm_view_set_lighting"), name_of(LIGHTING, name, "lighting")))
end
function View:needs_draw() return self._lib.C.cadaclysm_view_needs_draw(self:_live("cadaclysm_view_needs_draw")) end

-- A hit as every pick answer carries it (Python's `_pick_dict`): the item, node and face,
-- `clicks` (2 for a double click, else 1) and `point` -- where the ray met the model, in the
-- coordinates the items were shown in -- or nil where the library read no depth (no hit to
-- place, a machining stock, the terminal library). Nil for no item.
local function pick_of(raw)
  if raw.item == 0 then return nil end
  return { item = raw.item, node = raw.node, face = raw.face, clicks = raw.clicks,
    point = raw.has_point ~= 0 and { raw.point[0], raw.point[1], raw.point[2] } or nil }
end

--- What is under pixel (x, y) of `viewport` (default 0): { item, node, face, clicks, point }, or nil for nothing.
--- A view never drawn is drawn first: the library answers a pick from the frame it has drawn.
--- A failure other than "no answer yet" raises at once with the library's own message.
function View:pick(x, y, viewport)
  uint(x, "pick x"); uint(y, "pick y")
  viewport = viewport == nil and 0 or uint(viewport, "pick viewport")
  if not self._drawn then self:draw() end
  local p = self:_live(viewport == 0 and "cadaclysm_view_request_pick" or "cadaclysm_view_request_pick_in")
  if viewport == 0 then
    self._lib.C.cadaclysm_view_request_pick(p, x, y)
  else
    self._lib.C.cadaclysm_view_request_pick_in(p, viewport, x, y)
  end
  void_ok(self)
  local out = ffi.new("CadaclysmViewPick", { size = ffi.sizeof("CadaclysmViewPick") })
  local waiting = ""
  for _ = 1, 200 do
    self:draw()
    if self._lib.C.cadaclysm_view_pick_result(p, out) then return pick_of(out) end
    waiting = last_error(self._lib)
    if waiting ~= "" and waiting:sub(-14) ~= "no pick result" then fail(waiting, 2) end
    sleep_ms(10)
  end
  fail("pick: the answer never landed (" .. (waiting ~= "" and waiting or "no error reported") .. ")", 2)
end

--- The newest pick answer that has landed, without asking or waiting (Python's `last_pick`): a
--- click or tap in the view's own window (`pump` lands them as it draws), a double click's
--- (`clicks` 2), or one an `input` asked for, landed by the draws after it. nil while none has;
--- false for a click on nothing; else { item, node, face, clicks, point }. Each answer is read
--- once, and a newer one replaces one not read yet. A failure other than "no answer yet" raises
--- the library's own message.
function View:last_pick()
  local p = self:_live("cadaclysm_view_pick_result")
  local out = ffi.new("CadaclysmViewPick", { size = ffi.sizeof("CadaclysmViewPick") })
  if self._lib.C.cadaclysm_view_pick_result(p, out) then return pick_of(out) or false end
  local waiting = last_error(self._lib)
  if waiting ~= "" and waiting:sub(-14) ~= "no pick result" then fail(waiting, 2) end
  return nil
end

function View:draw() ok(self, self._lib.C.cadaclysm_view_draw(self:_live("cadaclysm_view_draw"))); self._drawn = true end

--- The camera `run` left, with `azimuth`/`elevation` as `show` takes them (Python's `_camera`).
local function camera_of(cam, pick, y_up)
  local eye = { cam.eye[0], cam.eye[1], cam.eye[2] }
  local target = { cam.target[0], cam.target[1], cam.target[2] }
  local up = { cam.up[0], cam.up[1], cam.up[2] }
  local d = { eye[1] - target[1], eye[2] - target[2], eye[3] - target[3] }
  local u = up
  if y_up then d = { d[1], -d[3], d[2] }; u = { up[1], -up[3], up[2] } end
  local length = math.sqrt(d[1] ^ 2 + d[2] ^ 2 + d[3] ^ 2)
  if length == 0 then length = 1 end
  d = { d[1] / length, d[2] / length, d[3] / length }
  local azimuth
  if math.sqrt(d[1] ^ 2 + d[2] ^ 2) < 1e-4 then
    local sign = d[3] < 0 and -1 or 1
    azimuth = math.deg(math.atan2(-sign * u[2], -sign * u[1]))
  else
    azimuth = math.deg(math.atan2(d[2], d[1]))
  end
  local elevation = math.deg(math.asin(math.max(-1, math.min(1, d[3]))))
  return { eye = eye, target = target, up = up, orthographic = cam.orthographic ~= 0, azimuth = azimuth,
    elevation = elevation, pick = pick_of(pick) }
end

--- Blocks until the window is closed; the camera it ended on and the last pick.
function View:run()
  local cam = ffi.new("CadaclysmViewCamera", { size = ffi.sizeof("CadaclysmViewCamera") })
  local pick = ffi.new("CadaclysmViewPick", { size = ffi.sizeof("CadaclysmViewPick") })
  ok(self, self._lib.C.cadaclysm_view_run(self:_live("cadaclysm_view_run"), cam, pick))
  self:_mark_closed()
  return camera_of(cam, pick, self._y_up)
end

--- One frame read back: { width, height, rgba = uint8_t cdata (0-based) }, rows from the top.
function View:image()
  local p = self:_live("cadaclysm_view_image")
  local w, h = ffi.new("uint32_t[1]"), ffi.new("uint32_t[1]")
  if not self._lib.C.cadaclysm_view_size(p, w, h) then failure(self._lib, 2) end   -- the size the next frame is drawn at
  local width, height = tonumber(w[0]), tonumber(h[0])
  local n = width * height * 4
  if n > 0x7fffffff then fail(("image: %d x %d pixels (%d bytes) is too large to read back"):format(width, height, n), 2) end
  local made, rgba = pcall(ffi.new, "uint8_t[?]", math.max(n, 1))
  if not made then fail(("image: %d x %d pixels (%d bytes) is too large to read back"):format(width, height, n), 2) end
  if not self._lib.C.cadaclysm_view_image(p, rgba, n) then failure(self._lib, 2) end
  return { width = width, height = height, rgba = rgba }
end

-- PNG: stored (uncompressed) deflate blocks, so no zlib is needed.
local CRC = {}
for n = 0, 255 do
  local c = n
  for _ = 1, 8 do
    if bit.band(c, 1) ~= 0 then c = bit.bxor(0xEDB88320, bit.rshift(c, 1)) else c = bit.rshift(c, 1) end
  end
  CRC[n] = c
end
local function crc32(s)
  local c = 0xFFFFFFFF
  for i = 1, #s do c = bit.bxor(CRC[bit.band(bit.bxor(c, s:byte(i)), 0xFF)], bit.rshift(c, 8)) end
  return bit.bxor(c, 0xFFFFFFFF)
end
local function be32(n)
  return string.char(bit.band(bit.rshift(n, 24), 255), bit.band(bit.rshift(n, 16), 255), bit.band(bit.rshift(n, 8), 255), bit.band(n, 255))
end
local function chunk(kind, data) return be32(#data) .. kind .. data .. be32(crc32(kind .. data)) end

--- The frame as a PNG file.
function View:save(path)
  if type(path) ~= "string" then fail("save: a path, not " .. describe(path), 2) end
  local img = self:image()
  local stride = img.width * 4
  local rows = {}
  for y = 0, img.height - 1 do rows[#rows + 1] = "\0" .. ffi.string(img.rgba + y * stride, stride) end
  local raw = table.concat(rows)
  local a, b = 1, 0
  for i = 1, #raw do a = (a + raw:byte(i)) % 65521; b = (b + a) % 65521 end
  local z = { "\120\1" }
  local at = 1
  repeat
    local piece = raw:sub(at, at + 65534)
    at = at + #piece
    local last = at > #raw and 1 or 0
    z[#z + 1] = string.char(last, bit.band(#piece, 255), bit.rshift(#piece, 8),
      bit.band(bit.bnot(#piece), 255), bit.band(bit.rshift(bit.bnot(#piece), 8), 255)) .. piece
  until at > #raw
  z[#z + 1] = be32(bit.bor(bit.lshift(b, 16), a))
  local ihdr = be32(img.width) .. be32(img.height) .. "\8\6\0\0\0"
  local f, why = io.open(path, "wb")
  if not f then fail("save: " .. tostring(why), 2) end
  f:write("\137PNG\r\n\26\n", chunk("IHDR", ihdr), chunk("IDAT", table.concat(z)), chunk("IEND", ""))
  f:close()
end

--- { type = "pointer_down"|"pointer_move"|"pointer_up"|"pointer_cancel"|"wheel"|"key", x, y, button, shift,
--- pointer_id, pointer = "mouse"|"touch"|"pen", wheel_y, key, key_down (default true), time_ms (default now) }
--- -> the INPUT_* bits. On a window of the view's own, the close bit (Escape) ends it as the user
--- closing it does.
function View:input(e)
  if type(e) ~= "table" then fail("input: an event table, not " .. describe(e), 2) end
  local kind = name_of(EVENTS, e.type, "event type")
  local key = e.key
  if key ~= nil and type(key) ~= "string" then fail("input key: a string, not " .. describe(key), 2) end
  local raw = ffi.new("CadaclysmViewEvent", {
    size = ffi.sizeof("CadaclysmViewEvent"), kind = kind, pointer_id = uint(e.pointer_id or 0, "pointer_id"),
    pointer = name_of(POINTERS, e.pointer or "mouse", "pointer"), button = uint(e.button or 0, "button"),
    shift = e.shift and 1 or 0, x = number(e.x or 0, "x"), y = number(e.y or 0, "y"),
    wheel_y = number(e.wheel_y or 0, "wheel_y"), key = key, key_down = (e.key_down ~= false) and 1 or 0,
    time_ms = number(e.time_ms or now_impl(), "time_ms"),
  })
  local bits = self._lib.C.cadaclysm_view_input(self:_live("cadaclysm_view_input"), raw)
  local _ = key   -- the string `raw.key` points into: held past the call
  if bits == 0 and last_error(self._lib) ~= "" then failure(self._lib, 2) end
  if bit.band(bits, INPUT_CLOSE) ~= 0 and self._own then self:_mark_closed() end
  return bits
end

function View:resize(w, h)
  uint(w, "resize width"); uint(h, "resize height")
  ok(self, self._lib.C.cadaclysm_view_resize(self:_live("cadaclysm_view_resize"), w, h))
end

--- width, height: what image() reads, in physical pixels.
function View:size()
  local w, h = ffi.new("uint32_t[1]"), ffi.new("uint32_t[1]")
  ok(self, self._lib.C.cadaclysm_view_size(self:_live("cadaclysm_view_size"), w, h))
  return tonumber(w[0]), tonumber(h[0])
end

--- Levels of detail: parts of `min_triangles` or more (0: the library's 2,048) get coarser
--- levels, built in the background after each show; a moving frame draws as `motion` says --
--- "detailed" (the default) or "smooth" (refines once the camera rests, see `wake_ms`).
--- `motion` false turns levels off.
function View:lod(motion, min_triangles)
  if motion == false then
    ok(self, self._lib.C.cadaclysm_view_set_lod(self:_live("cadaclysm_view_set_lod"), nil))
    return
  end
  local m = name_of(LOD_MOTION, motion == nil and "detailed" or motion, "motion")
  local lod = ffi.new("CadaclysmViewLod", { size = ffi.sizeof("CadaclysmViewLod"),
    min_triangles = uint(min_triangles or 0, "lod min_triangles"), motion = m })
  ok(self, self._lib.C.cadaclysm_view_set_lod(self:_live("cadaclysm_view_set_lod"), lod))
end

--- Milliseconds until needs_draw turns true by itself; 0 when a draw is owed now, nil when none is coming.
function View:wake_ms()
  local ms = self._lib.C.cadaclysm_view_wake_ms(self:_live("cadaclysm_view_wake_ms"))
  if ms == NONE_COMING then return nil end
  return tonumber(ms)
end

--- The window closed (its close button, Escape, the end of `run`): closed state; the destroy
--- is still owed to `close()` (or the collector).
function View:_mark_closed() self._window_closed = true end

--- Destroy the view and its window. Idempotent.
function View:close()
  local p = rawget(self, "_ptr")
  if p == nil then return end
  self._ptr = nil
  live_views[self] = nil
  for i = #open_views, 1, -1 do if open_views[i] == self then table.remove(open_views, i) end end
  ffi.gc(p, nil)
  self._lib.C.cadaclysm_view_destroy(p)
  -- Only once the library has let go: what an item shows must outlive the view's use of it.
  for _, item in pairs(self._items) do item.shown = nil end
  self._items = {}
end

--- Handles every open window's events, draws what is owed, waits at most `timeout_ms` (on the
--- first window only); how many are still open. With no window open it just waits `timeout_ms`,
--- so a loop around it does not spin. A negative wait is no wait. Every window's state is taken
--- (a closed one is marked closed; a window whose pump failed stays open, as Python's) before
--- the first refusal is raised.
function M.pump(timeout_ms)
  if timeout_ms ~= nil then number(timeout_ms, "pump timeout") end
  local wait = math.min(math.max(timeout_ms or 0, 0), UINT_MAX)
  local alive = {}
  for _, v in ipairs(open_views) do
    if rawget(v, "_ptr") ~= nil and not v._window_closed then alive[#alive + 1] = v end
  end
  if #alive == 0 then
    open_views = {}
    sleep_ms(wait)
    return 0
  end
  local still, first_error = {}, nil
  for _, v in ipairs(alive) do
    local answer = v._lib.C.cadaclysm_view_pump(rawget(v, "_ptr"), math.floor(wait))
    wait = 0
    if answer == CLOSED then v:_mark_closed()
    else
      still[#still + 1] = v
      if answer ~= OPEN then
        local why = last_error(v._lib)
        first_error = first_error or (why ~= "" and why or "the view library failed")
      end
    end
  end
  open_views = still
  if first_error then fail(first_error, 2) end
  return #still
end

--- Removes every item that shows `obj` (a Scene, directly or through one of its nodes) from
--- every live view before its handle is freed: a shown scene must stay open until its item is
--- removed or the view destroyed. `Scene:close()` calls it first, and only once this module is
--- loaded, so closing a scene opens no library. A view whose window the user closed is
--- destroyed instead. (A Lua state runs on one thread, so Python's other-thread rule has
--- nothing to guard here.)
function M._release(obj)
  local views = {}
  for v in pairs(live_views) do views[#views + 1] = v end
  for _, v in ipairs(views) do
    if rawget(v, "_ptr") ~= nil then
      local showing = {}
      for _, item in pairs(v._items) do
        if item.shown == obj or (type(item.shown) == "table" and rawget(item.shown, "scene") == obj) then
          showing[#showing + 1] = item
        end
      end
      if #showing > 0 then
        if v._window_closed then v:close() else for _, item in ipairs(showing) do item:remove() end end
      end
    end
  end
end

local function item_ok(item, done) if not done then failure(item.view._lib, 3) end end

function Item:remove()
  item_ok(self, self.view._lib.C.cadaclysm_view_remove(self.view:_live("cadaclysm_view_remove"), self.id))
  self.view._items[self.id] = nil
  self.shown = nil
end

--- Poses a shown scene: one world transform per node (sixteen numbers each, column-major,
--- `Pose:raw_transform`'s layout -- every node of the scene, in index order), drawn in place of
--- each node's rest transform. nil restores the rest pose; an empty list is not that: it is a
--- count the library refuses.
function Item:node_transforms(transforms)
  if transforms == nil then
    item_ok(self, self.view._lib.C.cadaclysm_view_set_node_transforms(self.view:_live("cadaclysm_view_set_node_transforms"), self.id, nil, 0))
    return
  end
  table_of(transforms, "node_transforms")
  local flat = ffi.new("double[?]", math.max(16 * #transforms, 1))
  for k, m in ipairs(transforms) do
    if type(m) ~= "table" or #m ~= 16 then
      fail(("transform %d: 16 numbers, not %s"):format(k, type(m) == "table" and tostring(#m) or describe(m)), 2)
    end
    for j = 1, 16 do
      if type(m[j]) ~= "number" then fail(("transform %d: item %d is %s, not a number"):format(k, j, describe(m[j])), 2) end
      flat[16 * (k - 1) + j - 1] = m[j]
    end
  end
  item_ok(self, self.view._lib.C.cadaclysm_view_set_node_transforms(self.view:_live("cadaclysm_view_set_node_transforms"), self.id, flat, #transforms))
end
--- Recolours the item: text ("#rgb", "#rrggbb", a CSS colour name, any case) or three numbers in 0..1.
function Item:colour(rgb)
  if rgb == nil then fail("colour: 3 numbers, not nil", 2) end
  local c = floats3(rgb, "colour", self.view._lib)
  item_ok(self, self.view._lib.C.cadaclysm_view_set_colour(self.view:_live("cadaclysm_view_set_colour"), self.id, c))
end
--- The text item's string replaced, nothing else changed (cadaclysm_view_set_text).
function Item:set_text(text)
  local view = self.view
  item_ok(self, view._lib.C.cadaclysm_view_set_text(view:_live("cadaclysm_view_set_text"), self.id, text_of(text)))
end
--- Sixteen numbers, column-major; nil puts it back.
function Item:placement(m)
  local raw = exactly("double", m, 16, "placement")
  item_ok(self, self.view._lib.C.cadaclysm_view_set_placement(self.view:_live("cadaclysm_view_set_placement"), self.id, raw))
end
--- `faces` (pick numbers) coloured by `rgba`: four numbers a face, flat, or one colour a face --
--- colour text (alpha 1) or a { r, g, b, a } table; `faces` nil clears every face's colour; an
--- empty list colours none, which clears them too (Python's).
function Item:face_colours(faces, rgba)
  local view = self.view
  if faces == nil then
    item_ok(self, view._lib.C.cadaclysm_view_set_face_colours(view:_live("cadaclysm_view_set_face_colours"), self.id, nil, nil, 0))
    return
  end
  local f, n = carray("uint32_t", faces, "face_colours faces")
  local flat = {}
  for _, q in ipairs(table_of(rgba or {}, "face_colours rgba")) do
    if type(q) == "string" then
      local c = colour_of(view._lib, q)
      flat[#flat + 1], flat[#flat + 2], flat[#flat + 3], flat[#flat + 4] = c[1], c[2], c[3], 1
    elseif type(q) == "table" then for _, c in ipairs(q) do flat[#flat + 1] = c end else flat[#flat + 1] = q end
  end
  local c, nc = carray("float", flat, "face_colours rgba")
  if nc ~= 4 * n then fail(("face_colours: %d numbers (rgba, 4 a face), not %d"):format(4 * n, nc), 2) end
  item_ok(self, view._lib.C.cadaclysm_view_set_face_colours(view:_live("cadaclysm_view_set_face_colours"), self.id, f, c, n))
end
function Item:frame() item_ok(self, self.view._lib.C.cadaclysm_view_frame(self.view:_live("cadaclysm_view_frame"), self.id)) end
function Item:xray(on)
  item_ok(self, self.view._lib.C.cadaclysm_view_set_xray(self.view:_live("cadaclysm_view_set_xray"), self.id, on ~= false))
end
function Item:node_visible(node, on)
  local index = node_index(node, "node_visible node")
  item_ok(self, self.view._lib.C.cadaclysm_view_set_node_visible(self.view:_live("cadaclysm_view_set_node_visible"), self.id, index, on ~= false))
end
--- Colours `node` and its subtree: text (alpha 1) or three or four numbers; nil clears.
function Item:node_colour(node, rgba)
  local index = node_index(node, "node_colour node")
  local c = rgba4(rgba, "node_colour", self.view._lib)
  item_ok(self, self.view._lib.C.cadaclysm_view_set_node_color(self.view:_live("cadaclysm_view_set_node_color"), self.id, index, c))
end
--- Tint `node` toward rgba's colour by its alpha (text: alpha 1, the colour itself); nil clears.
function Item:node_highlight(node, rgba)
  local index = node_index(node, "node_highlight node")
  local c = rgba4(rgba, "node_highlight", self.view._lib)
  item_ok(self, self.view._lib.C.cadaclysm_view_set_node_highlight(self.view:_live("cadaclysm_view_set_node_highlight"), self.id, index, c))
end
function Item:frame_node(node)
  local index = node_index(node, "frame_node node")
  item_ok(self, self.view._lib.C.cadaclysm_view_frame_node(self.view:_live("cadaclysm_view_frame_node"), self.id, index))
end

-- ---- show() and view() on the objects ------------------------------------------------------

-- The camera the options ask for: the top view straight down, any other angle an orbit from the
-- front, then the fit -- `frame(0)`, and for a node `frame_node` -- and only then the zoom, since
-- framing resets the distance a zoom sets (Python's `_aim` and `_zoom`). The camera calls here are
-- not checked, as Python's are; `fit`'s own refusals (a node's) are.
local function aim(v, o, fit)
  local C, p = v._lib.C, v:_live("cadaclysm_view_standard")
  if o.elevation >= 90 and o.azimuth == -90 then
    C.cadaclysm_view_standard(p, STANDARD.top)
  else
    C.cadaclysm_view_standard(p, STANDARD.front)
    local dx = -math.rad(o.azimuth + 90) / ORBIT_PER_PIXEL
    local dy = math.rad(o.elevation) / ORBIT_PER_PIXEL
    if dx ~= 0 or dy ~= 0 then C.cadaclysm_view_orbit(p, dx, dy) end
  end
  C.cadaclysm_view_frame(p, 0)
  fit()
  if o.zoom and o.zoom > 0 then C.cadaclysm_view_zoom(p, math.log(o.zoom) / -math.log(ZOOM_PER_STEP)) end
end

local function title_of(obj, kind)
  local scene = kind == "node" and obj.scene or obj
  if kind == "scene" or kind == "node" then
    local file = tostring(rawget(scene, "path") or ""):match("[^/\\]*$")
    if file and file ~= "" then return file end
    return "Cadaclysm"
  end
  return "Solid"
end

--- obj:show() (`orbit` false) and obj:view() (true), by handle on every library: a fresh view.
--- On the wgpu library both run until the window is closed (show returns nothing, view the
--- camera and last pick); elsewhere (the terminal, a library of your own) show prints a still.
--- `transforms`, for a scene (Pose:show): one posed world transform per node, set on its item first.
--- options: view ("front", "back", "left", "right", "top", "bottom", "iso", or { azimuth, elevation }),
--- azimuth/az, elevation/el, zoom, up ("y"|"z"), edges, width, height, title, rgb (colour text or three
--- numbers), tolerance (a Solid's).
function M._present(obj, opts, orbit, transforms)
  if opts ~= nil and type(opts) ~= "table" then fail("options are a table, not " .. describe(opts), 2) end
  opts = opts or {}
  local kind = kind_of(obj)
  if kind == nil then fail("show: a Solid, Scene or Node, not " .. describe(obj), 2) end
  local owner = transforms ~= nil and "Pose" or kind == "solid" and "Solid" or kind == "scene" and "Scene" or "Node"
  local mode = orbit and "view" or "show"
  if opts.tolerance ~= nil and kind ~= "solid" then
    fail(("%s.%s takes no tolerance: a document is drawn at the tolerance it was read with"):format(owner, mode), 2)
  end
  local base = opts.view or "iso"
  local base_az, base_el
  if type(base) == "table" then
    base_az, base_el = base[1], base[2]
    if #base ~= 2 or type(base_az) ~= "number" or type(base_el) ~= "number" then
      fail("view: an { azimuth, elevation } pair, or one of " .. table.concat(VIEW_LIST, ", "), 2)
    end
  else
    local named = type(base) == "string" and VIEWS[base]
    if not named then fail(("view %s: one of %s"):format(describe(base), table.concat(VIEW_LIST, ", ")), 2) end
    base_az, base_el = named[1], named[2]
  end
  local up = tostring(opts.up or "z"):lower()
  if up ~= "y" and up ~= "z" then fail("up " .. describe(opts.up) .. ": 'y' or 'z'", 2) end
  local width, height = opts.width or 0, opts.height or 0
  if type(width) ~= "number" or type(height) ~= "number" or width < 0 or height < 0 then
    fail(("width=%s, height=%s: a size is pixels, 0 or more (0 = the library decides)"):format(tostring(width), tostring(height)), 2)
  end
  local o = {
    azimuth = number(opts.azimuth or opts.az or base_az, "azimuth"),
    elevation = number(opts.elevation or opts.el or base_el, "elevation"),
    zoom = opts.zoom ~= nil and number(opts.zoom, "zoom") or nil,
    edges = opts.edges ~= false,
  }
  local tolerance = kind == "solid" and opts.tolerance or nil
  local lib = M.current()
  pcall(io.stdout.flush, io.stdout)
  pcall(io.stderr.flush, io.stderr)
  local v = View.new({ title = opts.title or title_of(obj, kind), width = width, height = height, up = up })
  local result
  local done, err = pcall(function()
    local item = v:show(obj, opts.rgb, tolerance)
    if transforms ~= nil then item:node_transforms(transforms) end
    v:layer("edges", o.edges)
    aim(v, o, kind == "node" and function() item:frame_node(obj.index) end or function() end)
    if not orbit and lib.kind ~= "wgpu" then v:draw() return end
    result = v:run()
  end)
  v:close()
  if not done then error(err, 0) end
  if orbit then return result end
end

return M
