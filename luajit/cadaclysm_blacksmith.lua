--[[
cadaclysm_blacksmith for LuaJIT: the B-rep kernel -- build, combine, fillet and
write exact solids.

The same object model as cadaclysm_blacksmith.py, name for name, over the C ABI
through LuaJIT's FFI. Nothing is compiled: the declarations are generated from
include/cadaclysm_blacksmith.h (gen_cdef.py) and the library is loaded as it
is. Runs anywhere LuaJIT does: LÖVE, LÖVR, a plain `luajit` interpreter.

    local bs = require("cadaclysm_blacksmith")
    local Axis, Profile, Selector, Workplane = bs.Axis, bs.Profile, bs.Selector, bs.Workplane

    local outline = Profile.rect(80, 40):with_hole(Profile.circle(4))
    local plate = Workplane.xy():extrude(outline, 6):solid()
    local pin = Workplane.from_solid(plate)
      :faces(Selector.max(Axis.Z)):workplane()
      :cylinder(5, 10):solid()                  -- seated over the hole, on material
    local part = plate:join(pin)
    local corners = {}
    for _, e in ipairs(part.edges) do              -- the plate's own vertical corners
      if e.is_line and math.abs(e.direction[3]) > 0.99 then corners[#corners + 1] = e end
    end
    part = part:fillet(corners, 1.0)
    part:step("plate.stp")
    local positions, normals, indices = part:mesh(0.05)

**Every array borrows from its solid.** `Solid:mesh` and `Solid:edge_polylines`
hand back views into the library's own cache rather than copies: a view's
`pointer` is a `const float *` / `const uint32_t *` straight into it. Each view
holds its Solid, so the garbage collector cannot free the solid under a view
still reachable. Two things invalidate a view, as in Python: `Solid:close()`,
and meshing the same solid again at a *different* tolerance (which replaces
the cache). Where Python would then read freed memory, a view here refuses:
`view.pointer`, `view:get(i)`, `view:row(i)` and `view:copy()` raise
`BuildError` once its solid is closed or its cache filling replaced (after
0.05, 0.5, 0.05 the first view is stale even though the tolerance is back).
A raw pointer taken out *before* that is not checked -- take it again after
any call that may re-mesh. `view:copy()` gives a plain Lua array that is always
safe. Strings are copied on the way out.

**Indices are the ABI's.** A face or edge index, a `body`, a corner number
counts from zero, exactly as Python's; the Lua arrays this module builds
(`solid.edges`, `edge.faces`, `Frame` triples) count from one, as Lua does.

**Errors.** Every step raises a `BuildError` (a table with a `message` and a
`__tostring`) at once, with the library's own text. The text is per OS thread,
so it is always read on the thread that failed; each `love.thread` is its own
Lua state and must require this module itself.

**Solids from files.** `Solid.open`, `Solid.open_all`, `Solid.from_node` and
`Solid:to_scene` go through the reader module, cadaclysm.lua, required only
when they are called: the kernel works without the reader library present.
The reader's brep is handed to this library by pointer and shared, never
copied, so the two libraries must come from the same release (the call checks).

`join`/`cut`/`common` default their `tolerance` to 0.05, not the tighter 1e-6
`fillet`, `chamfer` and `shell` use, for cost: a boolean meshes both solids at
its tolerance.
]]

local ffi = require("ffi")

local M = {}

-- The declarations, once per LuaJIT state: a second `ffi.cdef` of the same
-- struct is an error, and a module reloaded by hand would otherwise hit it.
local prefix = (...) and (...):match("^(.-)[^%.]*$") or ""
if not pcall(ffi.typeof, "struct CadaclysmBlacksmithMesh") then
  ffi.cdef(require(prefix .. "cadaclysm_blacksmith_cdef"))
end

--- This file's own version (the workspace's); `version()` is the loaded library's.
M.__version__ = "0.4.4"

--- What the ABI returns for "no such face" and uses for "the whole solid".
M.NONE = 0xFFFFFFFF

--- The units `step`/`write_step` write in, by name.
M.UNITS = { m = 0, mm = 1, ["in"] = 2 }

local NONE = M.NONE
local UNITS = M.UNITS

-- ---- errors -------------------------------------------------------------------

--- What the library refused, in its own words (`cadaclysm_blacksmith_last_error`):
--- a table `{ message = ... }` whose `tostring` is the message.
---@class BuildError
---@field message string
local BuildError = {}
BuildError.__index = BuildError
BuildError.__tostring = function(e) return e.message end
M.BuildError = BuildError

local function raise(message)
  error(setmetatable({ message = message }, BuildError), 2)
end

-- ---- small helpers -------------------------------------------------------------

-- A class whose `getters` read like fields: `solid.faces`, not `solid:faces()`
-- -- Python's properties.
local function class(cls, getters)
  cls.__index = function(self, key)
    if getters then
      local get = getters[key]
      if get then return get(self) end
    end
    return cls[key]
  end
  return cls
end

-- Python's `Name(...)` for a class that has a public constructor.
local function callable(cls)
  return setmetatable(cls, { __call = function(_, ...) return cls.new(...) end })
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

local function parent_of(path)
  return path:match("^(.*)/[^/]*$")
end

-- Whether `path` names a regular file (not a directory, not nothing).
local function is_file(path)
  local ok, f = pcall(io.open, path, "rb")
  if not ok or not f then return false end
  local data, err = f:read(1)
  f:close()
  return data ~= nil or err == nil
end

local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("*a")
  f:close()
  return data
end

local function write_text(path, text)
  local f, err = io.open(tostring(path), "w")
  if not f then raise(tostring(err)) end
  f:write(text)
  f:close()
end

local function repr(v)
  if type(v) == "string" then return "'" .. v .. "'" end
  return tostring(v)
end

-- The directory this file sits in on the real file system, or nil when it is
-- only inside a LÖVE archive and has none.
local function module_dir()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) ~= "@" then return nil end
  local file = source:sub(2):gsub("\\", "/")
  if love and love.filesystem and love.filesystem.getRealDirectory then
    local real = love.filesystem.getRealDirectory(file)
    if real then file = real:gsub("\\", "/") .. "/" .. file end
  end
  return parent_of(file) or "."
end

local function ancestors(dir)
  local out = {}
  while dir and dir ~= "" do
    out[#out + 1] = dir
    dir = parent_of(dir)
  end
  return out
end

-- ---- the library ----------------------------------------------------------------

local function library_name()
  if ffi.os == "Windows" then return "cadaclysm_blacksmith.dll" end
  if ffi.os == "OSX" then return "libcadaclysm_blacksmith.dylib" end
  return "libcadaclysm_blacksmith.so"
end

--- Where the shared library is. `CADACLYSM_BLACKSMITH_LIBRARY` first (the library
--- or its directory), so this file works dropped beside a script anywhere; then
--- beside this file, beside a LÖVE game's executable; then a `lib/` directory in
--- any ancestor (the SDK layout); then a `target/release` (or `target/debug`) in
--- any ancestor (this repository's layout). Raises `BuildError` when there is none.
function M.library_path()
  local name = library_name()
  local override = os.getenv("CADACLYSM_BLACKSMITH_LIBRARY")
  if override and override ~= "" then
    local o = override:gsub("\\", "/")
    if exists(o .. "/" .. name) then return o .. "/" .. name end
    if exists(o) then return o end
    raise("CADACLYSM_BLACKSMITH_LIBRARY=" .. override .. " names nothing that exists")
  end
  local searched = {}
  local here = module_dir()
  if here then searched[#searched + 1] = here .. "/" .. name end
  if love and love.filesystem and love.filesystem.getSourceBaseDirectory then
    searched[#searched + 1] = love.filesystem.getSourceBaseDirectory():gsub("\\", "/") .. "/" .. name
  end
  local dirs = ancestors(here)
  for _, d in ipairs(dirs) do searched[#searched + 1] = d .. "/lib/" .. name end
  for _, d in ipairs(dirs) do
    searched[#searched + 1] = d .. "/target/release/" .. name
    searched[#searched + 1] = d .. "/target/debug/" .. name
  end
  for _, candidate in ipairs(searched) do
    if exists(candidate) then return candidate end
  end
  raise(name .. " not found. Looked in:\n    " .. table.concat(searched, "\n    ")
    .. "\nBuild it with:\n    cargo build --release -p cadaclysm-blacksmith-capi\n"
    .. "or run fetch.py in an SDK checkout, or point CADACLYSM_BLACKSMITH_LIBRARY at it.")
end

--- `ap203.exp`: `CADACLYSM_SCHEMAS/ap203.exp` if set; else beside this file; else
--- in a `schemas/` directory in any ancestor, nearest first. No longer needed to
--- write STEP (the kernel writes against its built-in AP203 when no schema is
--- given); kept for compatibility. Raises `BuildError` when there is none.
function M.default_schema()
  local candidates = {}
  local override = os.getenv("CADACLYSM_SCHEMAS")
  if override and override ~= "" then
    candidates[#candidates + 1] = override:gsub("\\", "/") .. "/ap203.exp"
  end
  local here = module_dir()
  if here then
    candidates[#candidates + 1] = here .. "/ap203.exp"
    for _, d in ipairs(ancestors(here)) do candidates[#candidates + 1] = d .. "/schemas/ap203.exp" end
  end
  for _, c in ipairs(candidates) do
    if exists(c) then return c end
  end
  raise("ap203.exp not found (none is needed to write STEP: leave schema out for the "
    .. "built-in AP203, or pass a schema name, a .exp path or EXPRESS text)")
end

-- Every entry point this module calls, checked when the library loads: LuaJIT
-- resolves a symbol on first use, so a library older than this file would
-- otherwise fail mid-build with a bare "cannot resolve symbol".
local ENTRY_POINTS = {
  "cadaclysm_blacksmith_last_error", "cadaclysm_blacksmith_license_set", "cadaclysm_blacksmith_license_info",
  "cadaclysm_blacksmith_license_notice_count", "cadaclysm_blacksmith_build_date", "cadaclysm_blacksmith_version",
  "cadaclysm_blacksmith_solid_free", "cadaclysm_blacksmith_profile_free", "cadaclysm_blacksmith_profile_rect",
  "cadaclysm_blacksmith_profile_circle", "cadaclysm_blacksmith_profile_slot",
  "cadaclysm_blacksmith_profile_regular_polygon", "cadaclysm_blacksmith_profile_spline",
  "cadaclysm_blacksmith_profile_polygon", "cadaclysm_blacksmith_profile_with_hole",
  "cadaclysm_blacksmith_translate_profile", "cadaclysm_blacksmith_profile_round", "cadaclysm_blacksmith_profile_chain",
  "cadaclysm_blacksmith_profile_from_loops", "cadaclysm_blacksmith_profile_close_loop",
  "cadaclysm_blacksmith_path_begin", "cadaclysm_blacksmith_path_line_to", "cadaclysm_blacksmith_path_arc_to",
  "cadaclysm_blacksmith_path_bezier_to", "cadaclysm_blacksmith_path_nurbs_to", "cadaclysm_blacksmith_path_end",
  "cadaclysm_blacksmith_path_end_open", "cadaclysm_blacksmith_path_free", "cadaclysm_blacksmith_cuboid",
  "cadaclysm_blacksmith_cylinder", "cadaclysm_blacksmith_cone", "cadaclysm_blacksmith_sphere",
  "cadaclysm_blacksmith_torus", "cadaclysm_blacksmith_wedge", "cadaclysm_blacksmith_extrude",
  "cadaclysm_blacksmith_extrude_open", "cadaclysm_blacksmith_extrude_tapered",
  "cadaclysm_blacksmith_extrude_open_tapered", "cadaclysm_blacksmith_extrude_between",
  "cadaclysm_blacksmith_extrude_open_between", "cadaclysm_blacksmith_slant_of_plane", "cadaclysm_blacksmith_loft",
  "cadaclysm_blacksmith_loft_open", "cadaclysm_blacksmith_revolve", "cadaclysm_blacksmith_revolve_open",
  "cadaclysm_blacksmith_coil", "cadaclysm_blacksmith_revolve_in_plane", "cadaclysm_blacksmith_revolve_open_in_plane",
  "cadaclysm_blacksmith_sweep_path_begin", "cadaclysm_blacksmith_sweep_path_line_to",
  "cadaclysm_blacksmith_sweep_path_arc", "cadaclysm_blacksmith_sweep_path_along", "cadaclysm_blacksmith_sweep_path_free",
  "cadaclysm_blacksmith_sweep", "cadaclysm_blacksmith_sweep_open", "cadaclysm_blacksmith_pipe",
  "cadaclysm_blacksmith_extrude_faces", "cadaclysm_blacksmith_face", "cadaclysm_blacksmith_face_sheet",
  "cadaclysm_blacksmith_drop_faces", "cadaclysm_blacksmith_place", "cadaclysm_blacksmith_translate",
  "cadaclysm_blacksmith_rotate", "cadaclysm_blacksmith_mirror", "cadaclysm_blacksmith_join", "cadaclysm_blacksmith_cut",
  "cadaclysm_blacksmith_common", "cadaclysm_blacksmith_split_sheet", "cadaclysm_blacksmith_trim",
  "cadaclysm_blacksmith_fillet", "cadaclysm_blacksmith_chamfer", "cadaclysm_blacksmith_shell",
  "cadaclysm_blacksmith_thicken", "cadaclysm_blacksmith_push_pull", "cadaclysm_blacksmith_push_pull_faces",
  "cadaclysm_blacksmith_merge_flush",
  "cadaclysm_blacksmith_refillet", "cadaclysm_blacksmith_unfillet", "cadaclysm_blacksmith_rechamfer",
  "cadaclysm_blacksmith_unchamfer", "cadaclysm_blacksmith_split", "cadaclysm_blacksmith_split_by_plane",
  "cadaclysm_blacksmith_lump_count", "cadaclysm_blacksmith_lump", "cadaclysm_blacksmith_face_count",
  "cadaclysm_blacksmith_select_face", "cadaclysm_blacksmith_face_frame", "cadaclysm_blacksmith_coloured",
  "cadaclysm_blacksmith_colour", "cadaclysm_blacksmith_face_kind", "cadaclysm_blacksmith_edge_count",
  "cadaclysm_blacksmith_edge", "cadaclysm_blacksmith_mesh", "cadaclysm_blacksmith_edge_polylines",
  "cadaclysm_blacksmith_bounds", "cadaclysm_blacksmith_leaked_edges", "cadaclysm_blacksmith_unpaired_edges",
  "cadaclysm_blacksmith_manifold", "cadaclysm_blacksmith_step", "cadaclysm_blacksmith_string_free",
  "cadaclysm_blacksmith_from_brep", "cadaclysm_blacksmith_brep_layout_id",
}

local C

local function bind(path)
  local ok, loaded = pcall(ffi.load, path)
  if not ok then raise(tostring(loaded)) end
  for _, name in ipairs(ENTRY_POINTS) do
    if not pcall(function() return loaded[name] end) then
      raise(path .. " has no " .. name .. ": the library is older than this copy of "
        .. "cadaclysm_blacksmith.lua, which declares " .. #ENTRY_POINTS .. " entry points. "
        .. "Rebuild it with `cargo build --release -p cadaclysm-blacksmith-capi`.")
    end
  end
  C = loaded
  return C
end

local function lib()
  return C or bind(M.library_path())
end

--- Load the library from `path` rather than searching for it -- a LÖVE game
--- that keeps it in its save directory, say. Call before anything else.
function M.load(path)
  bind(path)
  return M
end

local function text(raw)
  if raw == nil then return "" end
  return ffi.string(raw)
end

local function last_error()
  return text(lib().cadaclysm_blacksmith_last_error())
end

-- Raise the library's own reason, or `what` if it left none.
local function fail(what)
  local reason = last_error()
  error(setmetatable({ message = reason ~= "" and reason or what }, BuildError), 2)
end

local function checked(handle, what)
  if handle == nil then fail(what) end
  return handle
end

local function number(v, what)
  local n = tonumber(v)
  if n == nil then raise(what .. ": " .. repr(v) .. " is not a number") end
  return n
end

local function doubles(values, count, what)
  if type(values) ~= "table" then raise(what .. ": expected " .. count .. " numbers, got " .. repr(values)) end
  if #values ~= count then raise(("%s: expected %d numbers, got %d"):format(what, count, #values)) end
  local out = ffi.new("double[?]", count)
  for i = 1, count do out[i - 1] = number(values[i], what) end
  return out
end

-- A list of 3-number rows (or anything indexable 1..3) flattened.
local function flatten(rows)
  local flat = {}
  for _, row in ipairs(rows) do
    if type(row) == "table" then
      local v = rawget(row, "_v") or row
      for j = 1, #v do flat[#flat + 1] = v[j] end
    else
      flat[#flat + 1] = row
    end
  end
  return flat
end

local Frame

-- Twelve numbers, four triples, or a Frame.
local function frame_arg(frame)
  if type(frame) == "table" and getmetatable(frame) == Frame then return doubles(frame._v, 12, "frame") end
  if type(frame) == "table" and #frame == 4 then return doubles(flatten(frame), 12, "frame") end
  return doubles(frame, 12, "frame")
end

-- Six numbers, or {{px,py,pz},{dx,dy,dz}}.
local function axis_arg(axis)
  if type(axis) == "table" and #axis == 2 then return doubles(flatten(axis), 6, "axis") end
  return doubles(axis, 6, "axis")
end

-- {{x,y}, ...} as a flat double array and its point count.
local function pairs_arg(points, what)
  local flat = flatten(points)
  local n = #flat
  local out = ffi.new("double[?]", math.max(n, 1))
  for i = 1, n do out[i - 1] = number(flat[i], what) end
  return out, math.floor(n / 2)
end

local function uint32s(list, what)
  local n = #list
  local out = ffi.new("uint32_t[?]", math.max(n, 1))   -- never null: an empty list is not "none"
  for i = 1, n do
    local v = number(list[i], what)
    if v < 0 or v ~= math.floor(v) then raise(what .. ": " .. repr(list[i]) .. " is not an index") end
    out[i - 1] = v
  end
  return out, n
end

local function triple(v, what)
  local d = doubles(v, 3, what)
  return d[0], d[1], d[2]
end

local function pair(v, what)
  local d = doubles(v, 2, what)
  return d[0], d[1]
end

-- (r, g, b) from "#rgb", "#rrggbb" or three numbers; the range is the library's to check.
local function rgb(colour)
  if type(colour) == "string" then
    local h = colour:match("^%s*(.-)%s*$")
    if h:sub(1, 1) == "#" then h = h:sub(2) end
    if (#h == 3 or #h == 6) and not h:find("[^0-9a-fA-F]") then
      if #h == 3 then h = h:gsub(".", "%0%0") end
      return tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255
    end
  elseif type(colour) == "table" and #colour == 3 then
    local r, g, b = tonumber(colour[1]), tonumber(colour[2]), tonumber(colour[3])
    if r and g and b then return r, g, b end
  end
  raise('coloured: a colour is "#rgb", "#rrggbb" or (r, g, b) in 0..1, not ' .. repr(colour))
end

-- The reader module, cadaclysm.lua, with a message saying where it lives.
local function reader(what)
  local ok, cadaclysm = pcall(require, prefix .. "cadaclysm")
  if not ok then
    raise(what .. " needs the reader module: put cadaclysm.lua beside this file (or on package.path) "
      .. "and build its library with `cargo build --release -p cadaclysm-capi` (" .. tostring(cadaclysm) .. ")")
  end
  return cadaclysm
end

-- A placement as rows: `m[row][col]` (the reader's `transform`), or the flat
-- column-major sixteen (`raw_transform`) turned into rows.
local function rows_of(m)
  if type(m[1]) == "table" then return m end
  local r = {}
  for row = 1, 4 do
    r[row] = {}
    for col = 1, 4 do r[row][col] = m[(col - 1) * 4 + row] end
  end
  return r
end

local function is_identity(m)
  m = rows_of(m)
  for i = 1, 4 do
    for j = 1, 4 do
      if tonumber(m[i][j]) ~= (i == j and 1 or 0) then return false end
    end
  end
  return true
end

local function close_all(solids)
  for _, s in ipairs(solids) do s:close() end
end

local function nonempty(s)
  if s == nil or s == "" then return nil end
  return s
end

-- ---- progress ----------------------------------------------------------------------

-- The C callback for a Lua `progress(phase, done, total)`, or nil, and the
-- function that takes the call's result back: it frees the callback and, if
-- `progress` raised, frees the result and raises that. A Lua error must never
-- unwind through the library's frames, so the callback catches it and the
-- raise waits until the call has returned.
local function progress_callback(progress)
  if progress == nil then
    return nil, function(result) return result end
  end
  local raised
  local cb = ffi.cast("CadaclysmBlacksmithProgress", function(phase, done, total, _user)
    if raised ~= nil then return end
    local ok, err = pcall(progress, text(phase), tonumber(done), tonumber(total))
    if not ok then raised = err end
  end)
  return cb, function(result)
    cb:free()
    if raised ~= nil then
      if result ~= nil then lib().cadaclysm_blacksmith_solid_free(result) end
      error(raised, 0)
    end
    return result
  end
end

-- ---- module functions ------------------------------------------------------------

--- Load a license: the certificate text, or the path of a file holding it.
function M.license(text_or_path)
  if not lib().cadaclysm_blacksmith_license_set(tostring(text_or_path)) then
    fail("license refused")
  end
end

--- One line about the license the library is running under. Never empty: the
--- license line, or, without one, "unlicensed" ("unlicensed -- <reason>" when a
--- license was found but did not verify).
function M.license_info()
  return text(lib().cadaclysm_blacksmith_license_info())
end

--- How many unlicensed notices this library has printed to stderr in this process.
function M.license_notice_count()
  return tonumber(lib().cadaclysm_blacksmith_license_notice_count())
end

--- The date the loaded library was built.
function M.build_date()
  return text(lib().cadaclysm_blacksmith_build_date())
end

--- The version of the library actually loaded, which is the one worth reporting.
function M.version()
  return text(lib().cadaclysm_blacksmith_version())
end

--- How the loaded library lays a brep out in memory: its compiler, target and
--- source. `Solid.from_node` works only where this equals the reader library's
--- (`cadaclysm.Brep.layout_id()`) -- the two from the same release.
function M.brep_layout_id()
  return text(lib().cadaclysm_blacksmith_brep_layout_id())
end

-- ---- borrowed arrays -------------------------------------------------------------

--- One block of a solid's cache: `pointer` (checked on every read), `shape`
--- (`{n, 3}` or `{m}`), `size` (elements), `dtype` ("float32"/"uint32"), and the
--- `solid` it borrows from. See the note at the top.
local View = {}
local View_get = {}
class(View, View_get)

local function view(solid, generation, pointer, shape, dtype)
  local size = 1
  for _, n in ipairs(shape) do size = size * n end
  if pointer == nil or size == 0 then pointer = nil end
  return setmetatable({ solid = solid, _generation = generation, _pointer = pointer,
    shape = shape, size = size, dtype = dtype }, View)
end

function View:_check()
  local solid = self.solid
  if rawget(solid, "_ptr") == nil then raise("the view is stale: its solid is closed") end
  if solid._cache_generation ~= self._generation then
    raise("the view is stale: the solid's tessellation has been replaced since (now at tolerance "
      .. tostring(solid._cache_tolerance) .. ")")
  end
end

--- The `const float *` / `const uint32_t *` into the library's cache, or nil when
--- empty. Raises `BuildError` once stale.
function View_get.pointer(self)
  self:_check()
  return self._pointer
end

--- Whether the view still reads live memory: its solid open and its cache filling current.
function View_get.valid(self)
  return pcall(self._check, self) == true
end

--- Element `i` of the flat array, counting from zero.
function View:get(i)
  self:_check()
  if i < 0 or i >= self.size then raise(("index %d out of range (0 to %d)"):format(i, self.size - 1)) end
  return self._pointer[i]
end

--- Row `i` (from zero) of an (n, 3) view as three numbers; of a flat view, element `i`.
function View:row(i)
  self:_check()
  local width = self.shape[2] or 1
  if i < 0 or i >= self.shape[1] then raise(("row %d out of range (0 to %d)"):format(i, self.shape[1] - 1)) end
  local p = self._pointer
  if width == 3 then return p[3 * i], p[3 * i + 1], p[3 * i + 2] end
  return p[i]
end

--- The elements in memory of our own: a flat Lua array (1-based), safe to outlive the solid.
function View:copy()
  self:_check()
  local out, p = {}, self._pointer
  for i = 0, self.size - 1 do out[i + 1] = p[i] end
  return out
end

View.__tostring = function(self)
  return ("View(%s, shape=(%s))"):format(self.dtype, table.concat(self.shape, ", "))
end

-- ---- profiles -----------------------------------------------------------------------

local function free_profile(p) lib().cadaclysm_blacksmith_profile_free(p) end
local function free_path(p) lib().cadaclysm_blacksmith_path_free(p) end
local function free_sweep_path(p) lib().cadaclysm_blacksmith_sweep_path_free(p) end
local function free_solid(p) lib().cadaclysm_blacksmith_solid_free(p) end

--- A closed outline with holes, in its own x/y. Immutable; every method returns a new one.
---@class Profile
local Profile = {}
class(Profile)
M.Profile = Profile

local function new_profile(handle, what)
  checked(handle, what or "profile")
  return setmetatable({ _handle = ffi.gc(handle, free_profile) }, Profile)
end

local function profile_handle(p, what)
  if type(p) ~= "table" or getmetatable(p) ~= Profile then raise((what or "profile") .. ": expected a Profile, got " .. repr(p)) end
  return p._handle
end

--- A `w` by `h` rectangle centred on the origin.
function Profile.rect(w, h)
  return new_profile(lib().cadaclysm_blacksmith_profile_rect(w, h))
end

--- A circle of radius `r` about the origin.
function Profile.circle(r)
  return new_profile(lib().cadaclysm_blacksmith_profile_circle(r))
end

--- A slot (two half-circles joined by straight sides) about `centre` ({x, y}),
--- `length` between the arcs' centres, of radius `r`.
function Profile.slot(centre, length, r)
  local cx, cy = pair(centre, "centre")
  return new_profile(lib().cadaclysm_blacksmith_profile_slot(cx, cy, length, r))
end

--- A closed polygon through `points` ({{x, y}, ...}).
function Profile.polygon(points)
  local xy, n = pairs_arg(points, "polygon")
  return new_profile(lib().cadaclysm_blacksmith_profile_polygon(xy, n))
end

--- A regular polygon of `sides` sides (at least 3) on the circle of `radius`
--- about `centre`, its first corner at `angle` radians (default 0) from the
--- sketch's x axis, the rest counter-clockwise.
function Profile.regular_polygon(centre, radius, sides, angle)
  if angle == nil then angle = 0.0 end
  local cx, cy = pair(centre, "centre")
  sides = math.max(0, math.floor(number(sides, "sides")))
  return new_profile(lib().cadaclysm_blacksmith_profile_regular_polygon(cx, cy, radius, sides, angle))
end

--- A spline of `degree` (default 3) through the control polygon `points`
--- (`weights` one per point, or nil). Open, it starts on the first point and
--- ends on the last -- an open chain; `closed` true, it is periodic, smooth
--- through its own start -- a closed profile. The degree is lowered to fit the
--- points. Raises `BuildError` for a degree of zero, too few points (two open,
--- three closed), a weight not positive, or not one weight per point.
function Profile.spline(points, degree, weights, closed)
  if degree == nil then degree = 3 end
  if closed == nil then closed = false end
  local xy, n = pairs_arg(points, "spline")
  local w = nil
  -- The library reads exactly one weight per point, whatever the list holds.
  if weights ~= nil and #weights ~= n then
    raise(("spline: %d weights for %d points; give one per point"):format(#weights, n))
  end
  if weights ~= nil then w = doubles(weights, #weights, "weights") end
  degree = math.max(0, math.floor(number(degree, "degree")))
  return new_profile(lib().cadaclysm_blacksmith_profile_spline(xy, n, degree, w, closed and true or false))
end

--- A `Path` starting at `start` ({x, y}), to draw an outline a segment at a time.
function Profile.path(start)
  return M.Path.new(start)
end

--- Open profiles joined end to end into one -- the forge's merge. The pieces
--- (paths ended open) may come in any order and either way round: each next one
--- is the first of the rest with an end within `tolerance` (default 1e-6) of
--- either end of the chain so far, reversed where that makes it meet. Every
--- segment is kept exactly. Closed where the chain's two ends meet, otherwise an
--- open chain. Raises `BuildError` for no pieces, a piece empty, with holes or
--- closed on its own, or one that meets none of the others, named by its index.
function Profile.chain(pieces, tolerance)
  if tolerance == nil then tolerance = 1e-6 end
  local n = #pieces
  local handles = ffi.new("const struct CadaclysmBlacksmithProfile *[?]", math.max(n, 1))
  for i = 1, n do handles[i - 1] = profile_handle(pieces[i], "chain") end
  return new_profile(lib().cadaclysm_blacksmith_profile_chain(handles, n, tolerance))
end

--- Closed loops, in any order, as one profile: the loop enclosing the most area
--- is the boundary and every other a hole in it, in the order given. Each loop
--- is a closed profile with no holes of its own, wound either way. Raises
--- `BuildError`, naming loops by their index (from zero), for a loop that is
--- open, empty or of no area, loops that cross or touch, a hole outside the
--- boundary, or one inside another hole.
function Profile.from_loops(loops)
  local n = #loops
  local handles = ffi.new("const struct CadaclysmBlacksmithProfile *[?]", math.max(n, 1))
  for i = 1, n do handles[i - 1] = profile_handle(loops[i], "from_loops") end
  return new_profile(lib().cadaclysm_blacksmith_profile_from_loops(handles, n))
end

--- This profile closed -- the forge's sketch "close": where its last segment
--- stops short of its start (a path ended open), a straight segment back to it;
--- where it already comes back to within 1e-9 of its extent, its last segment
--- made to land on the start exactly. A closed profile comes back as it is.
--- Holes are closed the same way.
function Profile:close_loop()
  return new_profile(lib().cadaclysm_blacksmith_profile_close_loop(self._handle))
end

--- This outline with `hole` (a Profile) cut out of it.
function Profile:with_hole(hole)
  return new_profile(lib().cadaclysm_blacksmith_profile_with_hole(self._handle, profile_handle(hole, "with_hole")))
end

--- This profile moved by (`dx`, `dy`).
function Profile:translate(dx, dy)
  return new_profile(lib().cadaclysm_blacksmith_translate_profile(self._handle, dx, dy))
end

--- This profile with its corners rounded by `radius`: where two straight
--- segments meet, both are cut back and an exact arc tangent to both put
--- between them; a corner next to an arc or a spline is left as it is.
--- `corners` nil rounds every such corner, the holes' too; a list picks corners
--- of the boundary alone -- corner `k` (from zero) is where segment `k` ends.
--- `open` true reads the profile as an open chain: its two ends stay square.
--- Raises `BuildError` naming the corner or segment the radius does not fit.
function Profile:round(radius, corners, open)
  if open == nil then open = false end
  local picked, count = nil, 0
  if corners ~= nil then picked, count = uint32s(corners, "round") end
  return new_profile(lib().cadaclysm_blacksmith_profile_round(self._handle, radius, picked, count, open and true or false))
end

-- ---- paths ---------------------------------------------------------------------------

--- An outline drawn a segment at a time; `end` closes it into a `Profile` and
--- consumes the builder. `Path.new(start)` or `Path(start)`, `start` = {x, y}.
---@class Path
local Path = {}
class(Path)
callable(Path)
M.Path = Path

--- A path starting at `start` ({x, y}).
function Path.new(start)
  local x, y = pair(start, "start")
  local h = checked(lib().cadaclysm_blacksmith_path_begin(x, y), "path_begin")
  return setmetatable({ _handle = ffi.gc(h, free_path) }, Path)
end

function Path:_live()
  local h = rawget(self, "_handle")
  if h == nil then raise("path: already ended") end
  return h
end

function Path:_step(ok, what)
  if not ok then fail(what) end
  return self
end

-- The handle, taken out of the builder: consumed whether or not the call succeeds.
function Path:_take()
  local h = self:_live()
  self._handle = nil
  ffi.gc(h, nil)
  return h
end

--- A straight segment to (`x`, `y`).
function Path:line_to(x, y)
  return self:_step(lib().cadaclysm_blacksmith_path_line_to(self:_live(), x, y), "path_line_to")
end

--- A circular arc to (`x`, `y`) about `centre` ({cx, cy}), counter-clockwise
--- unless `ccw` is false (default true).
function Path:arc_to(x, y, centre, ccw)
  if ccw == nil then ccw = true end
  local cx, cy = pair(centre, "centre")
  return self:_step(lib().cadaclysm_blacksmith_path_arc_to(self:_live(), x, y, cx, cy, ccw and true or false),
    "path_arc_to")
end

--- A cubic Bezier through the control points `c1`, `c2` ({x, y}) to `to`.
function Path:bezier_to(c1, c2, to)
  local ax, ay = pair(c1, "c1")
  local bx, by = pair(c2, "c2")
  local x, y = pair(to, "to")
  return self:_step(lib().cadaclysm_blacksmith_path_bezier_to(self:_live(), ax, ay, bx, by, x, y), "path_bezier_to")
end

--- A NURBS segment: `control` is every control point after the current one, the
--- endpoint last; `knots` the full repeated knot vector; `weights` one per
--- control point *including* the current one, or nil.
function Path:nurbs_to(control, knots, degree, weights)
  local c, n = pairs_arg(control, "nurbs_to")
  local w = nil
  -- The library reads one weight per control point plus the current point's.
  if weights ~= nil and #weights ~= n + 1 then
    raise(("nurbs_to: %d weights for %d control points (the current point and %d given); give one per point")
      :format(#weights, n + 1, n))
  end
  if weights ~= nil then w = doubles(weights, #weights, "weights") end
  local k = doubles(knots, #knots, "knots")
  local ok = lib().cadaclysm_blacksmith_path_nurbs_to(self:_live(), c, n, w, k, #knots, degree)
  return self:_step(ok, "path_nurbs_to")
end

--- The path as it stands, without closing it: an open chain for `extrude_open`,
--- `sweep_open` or `loft_open` (a closed sweep closes it with a straight side).
--- Consumes the builder as `end` does.
function Path:end_open()
  local h = self:_take()
  return new_profile(lib().cadaclysm_blacksmith_path_end_open(h))
end

--- The outline closed into a `Profile`; consumes the builder whether or not it
--- succeeds. `end` is a Lua keyword: call it as `path["end"](path)`, or `path:end_()`.
Path["end"] = function(self)
  local h = self:_take()
  return new_profile(lib().cadaclysm_blacksmith_path_end(h))
end
Path.end_ = Path["end"]

-- ---- sweep paths ---------------------------------------------------------------------

--- A 3D path a profile is carried along -- lines and arcs, a point at a time --
--- for `Solid.sweep`/`Solid.sweep_open`/`Solid.pipe`, which only *borrow* it: the
--- same path can be swept more than once. Free it with `close()` (or let the
--- collector do it). `SweepPath.new(at)` or `SweepPath(at)`, `at` = {x, y, z}.
---@class SweepPath
local SweepPath = {}
class(SweepPath)
callable(SweepPath)
M.SweepPath = SweepPath

--- A sweep path starting at `at` ({x, y, z}).
function SweepPath.new(at)
  local x, y, z = triple(at, "at")
  local h = checked(lib().cadaclysm_blacksmith_sweep_path_begin(x, y, z), "sweep_path_begin")
  return setmetatable({ _handle = ffi.gc(h, free_sweep_path) }, SweepPath)
end

--- A sweep path starting at `point`.
function SweepPath.at(point)
  return SweepPath.new(point)
end

--- The path the 2D chain `curve` (usually `Path:end_open()`) draws on `frame`: a
--- line a straight piece, an arc a circular one, and a Bezier or spline fitted
--- with biarcs until each stays within `tolerance` (default 0.05) of it, so the
--- path is tangent throughout. `open` false (default true) closes the path back
--- to its start along the side a profile leaves implicit.
function SweepPath.along(curve, frame, tolerance, open)
  if tolerance == nil then tolerance = 0.05 end
  if open == nil then open = true end
  local h = lib().cadaclysm_blacksmith_sweep_path_along(profile_handle(curve, "along"), frame_arg(frame), tolerance,
    open and true or false)
  h = checked(h, "sweep_path_along")
  return setmetatable({ _handle = ffi.gc(h, free_sweep_path) }, SweepPath)
end

function SweepPath:_live()
  local h = rawget(self, "_handle")
  if h == nil then raise("sweep_path: closed") end
  return h
end

function SweepPath:_step(ok, what)
  if not ok then fail(what) end
  return self
end

--- A straight piece to `point` ({x, y, z}).
function SweepPath:line_to(point)
  local x, y, z = triple(point, "point")
  return self:_step(lib().cadaclysm_blacksmith_sweep_path_line_to(self:_live(), x, y, z), "sweep_path_line_to")
end

--- Turn `angle` radians about the axis through `centre` with direction `axis`
--- (need not be unit); `angle` must be in (0, 2*pi].
function SweepPath:arc(centre, axis, angle)
  local cx, cy, cz = triple(centre, "centre")
  local ax, ay, az = triple(axis, "axis")
  local ok = lib().cadaclysm_blacksmith_sweep_path_arc(self:_live(), cx, cy, cz, ax, ay, az, angle)
  return self:_step(ok, "sweep_path_arc")
end

--- Free the path. Idempotent.
function SweepPath:close()
  local h = rawget(self, "_handle")
  if h ~= nil then
    self._handle = nil
    ffi.gc(h, nil)
    lib().cadaclysm_blacksmith_sweep_path_free(h)
  end
end

-- ---- slants --------------------------------------------------------------------------

--- A plane a sweep starts or ends on, read as a height over the sketch plane at
--- each point: `at + grad . p`. Flat (`grad` zero) for `extrude`'s own caps;
--- sloped for a mitre. Fields `at` (a number) and `grad` ({gx, gy}).
--- `Slant.new(at, grad)` or `Slant(at, grad)`.
---@class Slant
---@field at number
---@field grad number[]  {gx, gy}
local Slant = {}
class(Slant)
callable(Slant)
M.Slant = Slant

--- A slant at height `at` with gradient `grad` (default {0, 0}).
function Slant.new(at, grad)
  if grad == nil then grad = { 0.0, 0.0 } end
  return setmetatable({ at = number(at, "at"), grad = { number(grad[1], "grad"), number(grad[2], "grad") } }, Slant)
end

--- The flat plane at height `at`.
function Slant.flat(at)
  return Slant.new(at)
end

--- The plane through `point` square to `normal`, read as heights over `frame`.
--- Raises `BuildError` when the plane holds the sweep direction itself (`normal`
--- square to `frame`'s z), so no height is on it.
function Slant.of_plane(frame, point, normal)
  local out = ffi.new("double[3]")
  local ok = lib().cadaclysm_blacksmith_slant_of_plane(frame_arg(frame), doubles(point, 3, "point"),
    doubles(normal, 3, "normal"), out)
  if not ok then fail("slant_of_plane") end
  return Slant.new(out[0], { out[1], out[2] })
end

function Slant:_raw()
  return ffi.new("double[3]", self.at, self.grad[1], self.grad[2])
end

Slant.__tostring = function(self)
  return ("Slant(%s, (%s, %s))"):format(tostring(self.at), tostring(self.grad[1]), tostring(self.grad[2]))
end

-- A Slant, or a bare number treated as `Slant.flat(value)`.
local function slant(value)
  if type(value) == "table" and getmetatable(value) == Slant then return value end
  return Slant.flat(value)
end

-- ---- solids ---------------------------------------------------------------------------

--- An exact B-rep solid (or open sheet). Immutable; every operation returns a
--- new one. `close()` frees it; so does the garbage collector.
---@class Solid
local Solid = {}
local Solid_get = {}
class(Solid, Solid_get)
M.Solid = Solid

local Edge, Manifold, Selector

local function new_solid(handle, what)
  checked(handle, what or "solid")
  return setmetatable({ _ptr = ffi.gc(handle, free_solid), _cache_generation = 0 }, Solid)
end

local function solid_handle(s, what)
  if type(s) ~= "table" or getmetatable(s) ~= Solid then raise((what or "solid") .. ": expected a Solid, got " .. repr(s)) end
  return s:_h()
end

--- Free the solid. Idempotent; every view borrowed from it refuses to read afterwards.
function Solid:close()
  local h = rawget(self, "_ptr")
  if h ~= nil then
    self._ptr = nil
    ffi.gc(h, nil)
    lib().cadaclysm_blacksmith_solid_free(h)
  end
end

function Solid:_h()
  local h = rawget(self, "_ptr")
  if h == nil then raise("solid: closed") end
  return h
end

-- Record that a call just tessellated at `tolerance`: a new filling of the
-- cache if it differs from the one it held. Returns the generation a view made
-- now belongs to.
function Solid:_filled(tolerance)
  if self._cache_tolerance ~= tolerance then
    self._cache_tolerance = tolerance
    self._cache_generation = self._cache_generation + 1
  end
  return self._cache_generation
end

-- -- building

--- A box `x` by `y` by `z`, centred on the origin. Six planes.
function Solid.cuboid(x, y, z)
  return new_solid(lib().cadaclysm_blacksmith_cuboid(x, y, z))
end

--- A cylinder of radius `r` and height `h`, based on z=0 and rising along +z.
function Solid.cylinder(r, h)
  return new_solid(lib().cadaclysm_blacksmith_cylinder(r, h))
end

--- A cone of base radius `r` and height `h`, apex up.
function Solid.cone(r, h)
  return new_solid(lib().cadaclysm_blacksmith_cone(r, h))
end

--- A ball of radius `r` about the origin.
function Solid.sphere(r)
  return new_solid(lib().cadaclysm_blacksmith_sphere(r))
end

--- A torus about the z axis: `major` to the tube's centre, `minor` the tube's radius.
function Solid.torus(major, minor)
  return new_solid(lib().cadaclysm_blacksmith_torus(major, minor))
end

--- A wedge: an `x` by `y` by `z` box whose top narrows to `top_x` along x.
function Solid.wedge(x, y, z, top_x)
  return new_solid(lib().cadaclysm_blacksmith_wedge(x, y, z, top_x))
end

--- `profile` on `frame` extruded `height` along the frame's z.
function Solid.extrude(profile, frame, height)
  return new_solid(lib().cadaclysm_blacksmith_extrude(profile_handle(profile), frame_arg(frame), height))
end

--- `extrude` for a curve rather than a face: the walls alone, an open sheet.
function Solid.extrude_open(profile, frame, height)
  return new_solid(lib().cadaclysm_blacksmith_extrude_open(profile_handle(profile), frame_arg(frame), height))
end

--- `extrude` with a draft: the walls lean out by `taper` radians as they rise
--- (in, when negative), every wall exact -- a plane off a line, a cone off an
--- arc. A taper of zero is `extrude`.
function Solid.extrude_tapered(profile, frame, height, taper)
  return new_solid(lib().cadaclysm_blacksmith_extrude_tapered(profile_handle(profile), frame_arg(frame), height, taper))
end

--- `extrude_tapered` without the caps: an open sheet.
function Solid.extrude_open_tapered(profile, frame, height, taper)
  return new_solid(lib().cadaclysm_blacksmith_extrude_open_tapered(profile_handle(profile), frame_arg(frame), height,
    taper))
end

--- `extrude` between two planes instead of two heights: `bottom` and `top` are
--- each a `Slant` (or a bare number, `Slant.flat(number)`). With both flat this
--- *is* `extrude`, bit for bit; with a slope it is the mitred end of a sweep's
--- straight piece. Raises `BuildError` where the top plane comes down to or
--- through the bottom across the profile.
function Solid.extrude_between(profile, frame, bottom, top)
  return new_solid(lib().cadaclysm_blacksmith_extrude_between(profile_handle(profile), frame_arg(frame),
    slant(bottom):_raw(), slant(top):_raw()))
end

--- `extrude_between` without the caps: an open sheet of walls running from
--- `bottom` to `top`, as `extrude_open` is to `extrude`.
function Solid.extrude_open_between(profile, frame, bottom, top)
  return new_solid(lib().cadaclysm_blacksmith_extrude_open_between(profile_handle(profile), frame_arg(frame),
    slant(bottom):_raw(), slant(top):_raw()))
end

--- The solid between `a` on `frame_a` and `b` on `frame_b`: ruled walls between
--- matching sides (the profiles must have the same number of sides, and no
--- holes), capped by the two profiles.
function Solid.loft(a, frame_a, b, frame_b)
  return new_solid(lib().cadaclysm_blacksmith_loft(profile_handle(a), frame_arg(frame_a), profile_handle(b),
    frame_arg(frame_b)))
end

--- `loft` without the caps: the sheet ruled between the two curves.
function Solid.loft_open(a, frame_a, b, frame_b)
  return new_solid(lib().cadaclysm_blacksmith_loft_open(profile_handle(a), frame_arg(frame_a), profile_handle(b),
    frame_arg(frame_b)))
end

--- The profile swung `angle` radians about `axis` (a point and a direction:
--- six numbers or two triples); its x is the radius, its y the height.
function Solid.revolve(profile, axis, angle)
  return new_solid(lib().cadaclysm_blacksmith_revolve(profile_handle(profile), axis_arg(axis), angle))
end

--- `revolve` for a curve: an open sheet.
function Solid.revolve_open(profile, axis, angle)
  return new_solid(lib().cadaclysm_blacksmith_revolve_open(profile_handle(profile), axis_arg(axis), angle))
end

local function sketch_axis(a, b)
  local ax, ay = pair(a, "a")
  local bx, by = pair(b, "b")
  return ffi.new("double[4]", ax, ay, bx, by)
end

--- `profile`, drawn on `frame`, swung `angle` radians about the axis through
--- the sketch points `a` and `b` (each {x, y} on the frame) -- the profile and
--- its axis drawn together. The profile may lie on either side of the axis and
--- touch it, not cross it; the sweep turns right-handed about `b - a`.
function Solid.revolve_in_plane(profile, frame, a, b, angle)
  return new_solid(lib().cadaclysm_blacksmith_revolve_in_plane(profile_handle(profile), frame_arg(frame),
    sketch_axis(a, b), angle))
end

--- `revolve_in_plane` for a curve: its segments swung into a sheet.
function Solid.revolve_open_in_plane(profile, frame, a, b, angle)
  return new_solid(lib().cadaclysm_blacksmith_revolve_open_in_plane(profile_handle(profile), frame_arg(frame),
    sketch_axis(a, b), angle))
end

local function sweep_path_handle(path)
  if type(path) ~= "table" or getmetatable(path) ~= SweepPath then raise("sweep: expected a SweepPath, got " .. repr(path)) end
  return path:_live()
end

--- `profile`, drawn on `frame`, carried along `path` (a SweepPath) into a closed
--- solid: a straight piece is an extrusion, a circular piece a revolution, so
--- nothing is approximated. `path` is only borrowed, not consumed.
function Solid.sweep(profile, frame, path)
  return new_solid(lib().cadaclysm_blacksmith_sweep(profile_handle(profile), frame_arg(frame), sweep_path_handle(path)))
end

--- `profile` coiled about `axis` (a point and a direction): x the distance from
--- the axis, y along it -- turned `turns` times while climbing `pitch` each turn:
--- a spring, a thread. From a full turn up the pitch must be taller than the profile.
function Solid.coil(profile, axis, pitch, turns)
  return new_solid(lib().cadaclysm_blacksmith_coil(profile_handle(profile), axis_arg(axis), pitch, turns))
end

--- A circle of `radius` swept along `path`, square to its start -- Fusion's
--- Pipe: a rod, or with a positive `thickness` (default 0) a tube whose walls
--- are that thick. `path` is only borrowed.
function Solid.pipe(path, radius, thickness)
  if thickness == nil then thickness = 0.0 end
  return new_solid(lib().cadaclysm_blacksmith_pipe(sweep_path_handle(path), radius, thickness))
end

--- `sweep` for a curve rather than a face: one wall per segment per piece, no
--- caps -- an open sheet.
function Solid.sweep_open(profile, frame, path)
  return new_solid(lib().cadaclysm_blacksmith_sweep_open(profile_handle(profile), frame_arg(frame),
    sweep_path_handle(path)))
end

-- -- from files

-- The node's brep as a solid, shared: the reader's reference handed across and
-- given straight back, the solid holding one of its own.
local function from_brep(cadaclysm, node, what, missing_ok)
  local brep = node.brep
  if brep == nil then
    if missing_ok then return nil end
    raise(what .. " has no brep: only a B-rep body has one (STEP, ACIS, Rhino, OCCT .brep, "
      .. "IGES, IFC), not a mesh, a curve or a CSG body")
  end
  local ok, handle = pcall(function()
    return lib().cadaclysm_blacksmith_from_brep(ffi.cast("const void *", brep.pointer), cadaclysm.Brep.layout_id())
  end)
  if brep.release then brep:release() end
  if not ok then error(handle, 0) end
  return new_solid(handle, what)
end

--- The body `node` of a reader `Scene` draws, as a solid -- **sharing the
--- reader's brep, not copying it**. `node`: a reader `Node` or its index (from
--- zero). The scene can be closed before the solid is. `placed` (default true)
--- puts it where the node's `transform` does, which is where its mesh draws; a
--- node at the identity stays shared, a moved one is a moved copy; false keeps
--- the node's own frame. In the file's own units and axes either way. Needs
--- cadaclysm.lua and its library, from the same release as this one's.
function Solid.from_node(scene, node, placed)
  if placed == nil then placed = true end
  local cadaclysm = reader("from_node")
  if type(node) ~= "table" or getmetatable(node) ~= cadaclysm.Node then
    node = cadaclysm.Node.new(scene, math.floor(number(node, "from_node")))
  end
  local label = nonempty(node.name) or nonempty(node.kind) or "?"
  local solid = from_brep(cadaclysm, node, ("from_node: node %d (%s)"):format(node.index, label))
  if not placed then return solid end
  local transform = node.transform
  local native = cadaclysm.Convention and (cadaclysm.Convention.NATIVE or cadaclysm.Convention.native) or 0
  if scene.convention ~= nil and scene.convention ~= native and not is_identity(transform) then
    solid:close()
    raise("from_node: placed=True needs the scene opened with Convention.NATIVE -- the brep is in "
      .. "the file's own axes and the node's transform is not; open NATIVE, or pass placed=False")
  end
  return solid:_placed(transform, "from_node")
end

--- The body a CAD file holds, as a solid: a STEP (AP203/214/242), ACIS `.sat`,
--- Rhino `.3dm`, OCCT `.brep`, IGES or IFC file, read where it draws, in the
--- file's own units and axes. A file drawing several bodies needs `body` (from
--- zero, in drawing order) or `Solid.open_all`. Fillet and chamfer want line and
--- circle edges; booleans take any surface, but the new edges they trace on a
--- free-form face are not always writable back to STEP; every verb meshes its
--- operands first, so its cost grows with the body's face count.
function Solid.open(path, body)
  local solids = Solid.open_all(path)
  local name = tostring(path):gsub("\\", "/"):match("[^/]*$")
  if body == nil and #solids == 1 then return solids[1] end
  if body == nil then
    close_all(solids)
    raise(("open: %s holds %d bodies: pass body= (0 to %d), or use Solid.open_all"):format(name, #solids, #solids - 1))
  end
  local index = math.floor(number(body, "open"))
  if index < 0 or index >= #solids then
    close_all(solids)
    raise(("open: %s has no body %s: it holds %d"):format(name, tostring(body), #solids))
  end
  local keep = table.remove(solids, index + 1)
  close_all(solids)
  return keep
end

--- Every body a CAD file draws, as solids placed where it draws them (a Lua
--- array): one per placement, so a part placed twice is two solids. See `Solid.open`.
function Solid.open_all(path)
  path = tostring(path)
  local extension = (path:match("%.([^%./\\]*)$") or ""):lower()
  local cadaclysm = reader("open")
  local ok, scene = pcall(cadaclysm.open, path)
  if not ok then raise("open: " .. tostring(scene)) end
  local solids = {}
  local good, err = pcall(function()
    for _, placement in ipairs(scene.placements) do
      local node = placement.geometry
      local what = "open: " .. (nonempty(node.name) or nonempty(node.kind) or tostring(node.index))
      local solid = from_brep(cadaclysm, node, what, true)
      if solid ~= nil then solids[#solids + 1] = solid:_placed(placement.transform, what) end
    end
  end)
  scene:close()
  if not good then
    close_all(solids)
    error(err, 0)
  end
  if #solids == 0 then
    raise("open: the ." .. extension .. " file draws no B-rep body -- only a STEP, ACIS, Rhino, OCCT .brep, "
      .. "IGES or IFC body can be a solid, not a mesh, a curve or a CSG body")
  end
  return solids
end

-- `self` moved by a 4x4 placement (rows, or the flat column-major sixteen):
-- itself at the identity, a moved copy for a rigid move (a mirror included; this
-- one closed), refused for a scale or shear, which a brep cannot follow.
function Solid:_placed(matrix, what)
  if is_identity(matrix) then return self end
  local m = rows_of(matrix)
  for a = 1, 3 do
    for b = 1, 3 do
      local dot = m[1][a] * m[1][b] + m[2][a] * m[2][b] + m[3][a] * m[3][b]
      local want = a == b and 1 or 0
      if math.abs(dot - want) > 1e-9 + 1e-5 * want then   -- numpy.allclose(atol=1e-9)
        self:close()
        raise(what .. ": the placement scales or shears, which a brep cannot follow")
      end
    end
  end
  local frame = {
    m[1][4], m[2][4], m[3][4],
    m[1][1], m[2][1], m[3][1],
    m[1][2], m[2][2], m[3][2],
    m[1][3], m[2][3], m[3][3],
  }
  local ok, moved = pcall(self.place, self, frame)
  self:close()
  if not ok then error(moved, 0) end
  return moved
end

--- The flat sheet `profile` bounds on `frame`: one planar face, each hole a hole
--- through it, its normal `frame`'s z, every edge the exact curve its segment is.
--- An open sheet -- raise it with `extrude_faces`, cut it with `trim` or `split_sheet`.
function Solid.face(profile, frame)
  return new_solid(lib().cadaclysm_blacksmith_face(profile_handle(profile), frame_arg(frame)))
end

--- Face `face` (from zero) alone, as an open sheet: its surface, its loops and
--- the exact curves on its edges -- what extruding a solid's face starts from.
function Solid:face_sheet(face)
  return new_solid(lib().cadaclysm_blacksmith_face_sheet(self:_h(), face))
end

--- This solid without the faces at `faces` (a list of indices from zero,
--- repeats allowed): the rest keep their order. An open sheet unless nothing
--- was dropped.
function Solid:drop_faces(faces)
  local arr, n = uint32s(faces, "drop_faces")
  return new_solid(lib().cadaclysm_blacksmith_drop_faces(self:_h(), arr, n))
end

--- This sheet's faces raised `height` into a solid.
function Solid:extrude_faces(height)
  return new_solid(lib().cadaclysm_blacksmith_extrude_faces(self:_h(), height))
end

--- This solid placed on `frame`: its own origin and axes moved onto the frame's.
function Solid:place(frame)
  return new_solid(lib().cadaclysm_blacksmith_place(self:_h(), frame_arg(frame)))
end

--- This solid moved by (`dx`, `dy`, `dz`).
function Solid:translate(dx, dy, dz)
  return new_solid(lib().cadaclysm_blacksmith_translate(self:_h(), dx, dy, dz))
end

--- This solid turned `radians` about `axis` (a point and a direction).
function Solid:rotate(axis, radians)
  return new_solid(lib().cadaclysm_blacksmith_rotate(self:_h(), axis_arg(axis), radians))
end

--- This solid mirrored across the plane of `plane` (a frame: the plane its x and y span).
function Solid:mirror(plane)
  return new_solid(lib().cadaclysm_blacksmith_mirror(self:_h(), frame_arg(plane)))
end

-- -- combining

local function merged(out, merge)
  if not merge then return out end
  local ok, result = pcall(out.merge_flush, out)
  out:close()
  if not ok then error(result, 0) end
  return result
end

--- This solid and `other` as one. `tolerance` defaults to 0.05; `progress`, if
--- given, is called as `progress(phase, done, total)`. `merge` true merges the
--- flush faces the join leaves (`merge_flush`) -- off by default, so face and
--- edge numbers stay as they were.
function Solid:join(other, tolerance, progress, merge)
  if tolerance == nil then tolerance = 0.05 end
  local a, b = self:_h(), solid_handle(other)
  local cb, done = progress_callback(progress)
  local h = done(lib().cadaclysm_blacksmith_join(a, b, tolerance, cb, nil))
  return merged(new_solid(h), merge)
end

--- This solid with `other` removed; `tolerance`, `progress` and `merge` as `join`'s.
function Solid:cut(other, tolerance, progress, merge)
  if tolerance == nil then tolerance = 0.05 end
  local a, b = self:_h(), solid_handle(other)
  local cb, done = progress_callback(progress)
  local h = done(lib().cadaclysm_blacksmith_cut(a, b, tolerance, cb, nil))
  return merged(new_solid(h), merge)
end

--- What this solid and `other` share; `tolerance`, `progress` and `merge` as `join`'s.
function Solid:common(other, tolerance, progress, merge)
  if tolerance == nil then tolerance = 0.05 end
  local a, b = self:_h(), solid_handle(other)
  local cb, done = progress_callback(progress)
  local h = done(lib().cadaclysm_blacksmith_common(a, b, tolerance, cb, nil))
  return merged(new_solid(h), merge)
end

--- `self` (a sheet or a solid) cut along the closed `tool`'s boundary and the
--- pieces on one side thrown away: `keep` "outside" (default) keeps what lies
--- outside the tool -- a hole punched through -- and "inside" what lies within
--- it. The kept pieces come out in `self`'s face order.
function Solid:trim(tool, keep, tolerance, progress)
  if keep == nil then keep = "outside" end
  if tolerance == nil then tolerance = 0.05 end
  if keep ~= "outside" and keep ~= "inside" then
    raise("trim: keep must be 'outside' or 'inside', not " .. repr(keep))
  end
  local a, b = self:_h(), solid_handle(tool)
  local cb, done = progress_callback(progress)
  local h = done(lib().cadaclysm_blacksmith_trim(a, b, keep == "inside", tolerance, cb, nil))
  return new_solid(h)
end

--- `self` (a sheet or a solid) cut along `tool`'s boundary, nothing removed:
--- every face comes back as its pieces outside `tool` then its pieces inside, in
--- `self`'s own face order, each piece a face. `tool` must be a closed solid.
--- Keep or discard pieces with `drop_faces`; `trim` is the split with one side dropped.
function Solid:split_sheet(tool, tolerance, progress)
  if tolerance == nil then tolerance = 0.05 end
  local a, b = self:_h(), solid_handle(tool)
  local cb, done = progress_callback(progress)
  local h = done(lib().cadaclysm_blacksmith_split_sheet(a, b, tolerance, cb, nil))
  return new_solid(h)
end

-- -- asking

--- How many faces the solid has.
function Solid_get.faces(self)
  local h = self:_h()
  local n = lib().cadaclysm_blacksmith_face_count(h)
  if n == 0 and last_error() ~= "" then fail("face_count") end
  return n
end

--- What surface face `face` (from zero) lies on: "plane", "cylinder", "cone", ...
function Solid:face_kind(face)
  local raw = lib().cadaclysm_blacksmith_face_kind(self:_h(), face)
  if raw == nil then fail("face_kind") end
  return text(raw)
end

--- `bounds_at(0.05)` -- the bounds of the tessellation at tolerance 0.05.
function Solid_get.bounds(self)
  return self:bounds_at(0.05)
end

--- The solid's axis-aligned bounds over its cached tessellation at `tolerance`
--- (the same cache `mesh` fills and reuses): `{{min_x, min_y, min_z}, {max_x, max_y, max_z}}`.
function Solid:bounds_at(tolerance)
  local lo, hi = ffi.new("double[3]"), ffi.new("double[3]")
  if not lib().cadaclysm_blacksmith_bounds(self:_h(), tolerance, lo, hi) then fail("bounds") end
  self:_filled(tolerance)
  return { { lo[0], lo[1], lo[2] }, { hi[0], hi[1], hi[2] } }
end

--- How many edges of the mesh at `tolerance` (default 0.05) are bound by
--- anything other than exactly two triangles -- zero for a closed solid. A seam
--- two solids share along a line does *not* count; a hole or a fold does.
function Solid:leaked_edges(tolerance)
  if tolerance == nil then tolerance = 0.05 end
  local n = lib().cadaclysm_blacksmith_leaked_edges(self:_h(), tolerance)
  if n == NONE then fail("leaked_edges") end
  return n
end

--- How many edges of the mesh at `tolerance` (default 0.05) have directed
--- triangle uses that do not cancel out -- zero for a closed, consistently
--- oriented solid. Unlike `leaked_edges` this counts a fold and not a seam.
function Solid:unpaired_edges(tolerance)
  if tolerance == nil then tolerance = 0.05 end
  local n = lib().cadaclysm_blacksmith_unpaired_edges(self:_h(), tolerance)
  if n == NONE then fail("unpaired_edges") end
  return n
end

--- `leaked_edges(tolerance) == 0`.
function Solid:is_watertight(tolerance)
  if tolerance == nil then tolerance = 0.05 end
  return self:leaked_edges(tolerance) == 0
end

--- Whether the faces make a manifold -- every edge bordered by one face or two,
--- the faces round every vertex one fan -- and whether it is closed, as a
--- `Manifold` record. Read off the topology, so it takes no tolerance.
function Solid_get.manifold(self)
  local out = ffi.new("uint32_t[8]")
  if not lib().cadaclysm_blacksmith_manifold(self:_h(), out) then fail("manifold") end
  local row = {}
  for i = 0, 7 do row[i + 1] = out[i] end
  return Manifold.new(row)
end

-- -- out

--- `positions, normals, indices` at `tolerance` (default 0.05): three views
--- (float32 (n, 3), float32 (n, 3), uint32 (m)) into the solid's cache --
--- `view.pointer` is the raw pointer, `view.size` its element count. See the
--- note at the top for what makes them stale.
function Solid:mesh(tolerance)
  if tolerance == nil then tolerance = 0.05 end
  local m = lib().cadaclysm_blacksmith_mesh(self:_h(), tolerance)
  if m.positions == nil then fail("mesh") end
  local generation = self:_filled(tolerance)
  local n = m.vertex_count
  return view(self, generation, m.positions, { n, 3 }, "float32"),
    view(self, generation, m.normals, { n, 3 }, "float32"),
    view(self, generation, m.indices, { m.index_count }, "uint32")
end

--- The feature edges at `tolerance` (default 0.05) as a Lua array of float32
--- (k, 3) views, one per polyline, borrowed as `mesh`'s are.
function Solid:edge_polylines(tolerance)
  if tolerance == nil then tolerance = 0.05 end
  local p = lib().cadaclysm_blacksmith_edge_polylines(self:_h(), tolerance)
  if p.offsets == nil then fail("edge_polylines") end
  local generation = self:_filled(tolerance)
  local out = {}
  for i = 0, p.polyline_count - 1 do
    local a, b = p.offsets[i], p.offsets[i + 1]
    local pointer = p.points ~= nil and (p.points + 3 * a) or nil
    out[i + 1] = view(self, generation, pointer, { b - a, 3 }, "float32")
  end
  return out
end

--- This solid as STEP text: `schema` as `write_step_text` takes it, `unit` "mm"
--- (default), "m" or "in".
function Solid:step_text(schema, unit)
  if unit == nil then unit = "mm" end
  return M.write_step_text({ self }, schema, unit)
end

--- Write this solid to a STEP file at `path`; `schema` and `unit` as `step_text`.
function Solid:step(path, schema, unit)
  if unit == nil then unit = "mm" end
  write_text(path, self:step_text(schema, unit))
end

-- -- selecting and edges

--- The index (from zero) of the face a `Selector` picks.
function Solid:select_face(selector)
  local kind, v, index = selector:_raw()
  local i = lib().cadaclysm_blacksmith_select_face(self:_h(), kind, v, index)
  if i == NONE then fail("select_face") end
  return i
end

--- Twelve numbers: origin, x, y, z of the workplane on `face` -- its centre,
--- world X laid onto it and its outward normal, as `Frame.at` lays them.
function Solid:face_frame(face)
  local out = ffi.new("double[12]")
  if not lib().cadaclysm_blacksmith_face_frame(self:_h(), face, out) then fail("face_frame") end
  local t = {}
  for i = 0, 11 do t[i + 1] = out[i] end
  return t
end

-- -- colour

function Solid:_face_or_none(face, what)
  if face == nil then return NONE end
  if type(face) ~= "number" or face ~= math.floor(face) or face < 0 or face >= NONE then
    raise(("%s: face %s is not one of the solid's %d"):format(what, tostring(face), self.faces))
  end
  return face
end

function Solid:_colour(face)
  local out = ffi.new("double[3]")
  if lib().cadaclysm_blacksmith_colour(self:_h(), face, out) then return { out[0], out[1], out[2] } end
  if last_error() ~= "" then fail("colour") end
  return nil
end

--- This solid coloured -- `colour` is "#rgb", "#rrggbb" or {r, g, b} in 0..1 --
--- or with `face` (an index, as `select_face` returns) just that face, whose
--- colour then wins over the solid's. What is made from a coloured solid inherits.
function Solid:coloured(colour, face)
  local r, g, b = rgb(colour)
  return new_solid(lib().cadaclysm_blacksmith_coloured(self:_h(), self:_face_or_none(face, "coloured"), r, g, b))
end

--- The solid's colour, {r, g, b} in 0..1, or nil.
function Solid_get.colour(self)
  return self:_colour(NONE)
end

--- `face`'s colour as drawn -- its own, else the solid's -- or nil.
function Solid:face_colour(face)
  return self:_colour(self:_face_or_none(face, "colour"))
end

--- The edges a fillet indexes, as `Edge` records (copied; safe to keep), a Lua array.
function Solid_get.edges(self)
  local L, h = lib(), self:_h()
  local n = L.cadaclysm_blacksmith_edge_count(h)
  if n == 0 and last_error() ~= "" then fail("edge_count") end
  local out, raw = {}, ffi.new("CadaclysmBlacksmithEdge")
  for i = 0, n - 1 do
    if not L.cadaclysm_blacksmith_edge(h, i, raw) then fail("edge") end
    local faces = {}
    for j = 0, raw.face_count - 1 do faces[j + 1] = raw.faces[j] end
    local segments = {}
    for k = 0, raw.segment_count - 1 do
      local s = raw.segments + 6 * k
      segments[k + 1] = { { s[0], s[1], s[2] }, { s[3], s[4], s[5] } }
    end
    out[i + 1] = Edge.new(i, text(raw.kind), faces, segments)
  end
  return out
end

local function edge_indices(edges)
  local which = {}
  for i, e in ipairs(edges) do
    if type(e) == "table" and getmetatable(e) == Edge then which[i] = e.index else which[i] = e end
  end
  return uint32s(which, "edges")
end

--- The edges (`Edge` records or their indices) rounded by `radius`.
--- `tolerance` defaults to 1e-6; `progress` as `join`'s.
function Solid:fillet(edges, radius, tolerance, progress)
  if tolerance == nil then tolerance = 1e-6 end
  local arr, n = edge_indices(edges)
  local a = self:_h()
  local cb, done = progress_callback(progress)
  local h = done(lib().cadaclysm_blacksmith_fillet(a, arr, n, radius, tolerance, cb, nil))
  return new_solid(h)
end

--- `fillet` with a flat bevel: each edge cut back `distance` along both its faces.
function Solid:chamfer(edges, distance, tolerance)
  if tolerance == nil then tolerance = 1e-6 end
  local arr, n = edge_indices(edges)
  return new_solid(lib().cadaclysm_blacksmith_chamfer(self:_h(), arr, n, distance, tolerance))
end

--- Face `face` pushed out by `distance` along its outward normal (pulled in,
--- negative) the way Fusion and Rhino extrude a face: the prism joined on (cut
--- out) and the flush faces merged. A face on a cylinder, cone, sphere or torus
--- moves out along its normal instead. `tolerance` (default 0.05) and `progress`
--- as `join`'s.
---
--- `face` may be a list of faces, pushed together as Fusion's press-pull on a
--- selection: each by its own rule, one after another, each found again after the
--- pushes before it renumbered the faces -- a box's top and a side pushed 5 is the
--- box 5 taller and 5 wider. A face on the same curved surface as one before it, and
--- joined to it, moved with that one and is not pushed twice.
function Solid:push_pull(face, distance, tolerance, progress)
  if tolerance == nil then tolerance = 0.05 end
  local a = self:_h()
  local cb, done = progress_callback(progress)
  local h
  if type(face) == "table" then
    local arr, n = uint32s(face, "push_pull")
    h = done(lib().cadaclysm_blacksmith_push_pull_faces(a, arr, n, distance, tolerance, cb, nil))
  else
    h = done(lib().cadaclysm_blacksmith_push_pull(a, face, distance, tolerance, cb, nil))
  end
  return new_solid(h)
end

--- This solid split by `tool` into bodies (a Lua array) -- Fusion's Split Body:
--- a closed `tool` gives the parts outside it, then the parts inside; a flat
--- sheet splits by the whole plane it lies on.
function Solid:split(tool, tolerance, progress)
  if tolerance == nil then tolerance = 0.05 end
  local a, b = self:_h(), solid_handle(tool)
  local cb, done = progress_callback(progress)
  local all = new_solid(done(lib().cadaclysm_blacksmith_split(a, b, tolerance, cb, nil)))
  local ok, bodies = pcall(all.lumps, all)
  all:close()
  if not ok then error(bodies, 0) end
  return bodies
end

--- This solid split by the plane through `plane`'s origin, square to its z: the
--- bodies in front of it (on z's side) first, then those behind (a Lua array).
function Solid:split_by_plane(plane, tolerance, progress)
  if tolerance == nil then tolerance = 0.05 end
  local a, b = self:_h(), frame_arg(plane)
  local cb, done = progress_callback(progress)
  local all = new_solid(done(lib().cadaclysm_blacksmith_split_by_plane(a, b, tolerance, cb, nil)))
  local ok, bodies = pcall(all.lumps, all)
  all:close()
  if not ok then error(bodies, 0) end
  return bodies
end

--- This solid's connected bodies, each a solid of its own (a Lua array), in the
--- order of their first faces.
function Solid:lumps()
  local h = self:_h()
  local n = lib().cadaclysm_blacksmith_lump_count(h)
  if n == 0 then fail("lump_count") end
  local bodies = {}
  local ok, err = pcall(function()
    for i = 0, n - 1 do bodies[i + 1] = new_solid(lib().cadaclysm_blacksmith_lump(h, i)) end
  end)
  if not ok then
    close_all(bodies)
    error(err, 0)
  end
  return bodies
end

--- The round `face` belongs to made again at `radius` -- Fusion's press-pull on
--- a fillet face. `tolerance` defaults to 1e-6.
function Solid:refillet(face, radius, tolerance)
  if tolerance == nil then tolerance = 1e-6 end
  return new_solid(lib().cadaclysm_blacksmith_refillet(self:_h(), face, radius, tolerance))
end

--- The round `face` belongs to taken off, the faces beside it sharp again.
function Solid:unfillet(face)
  return new_solid(lib().cadaclysm_blacksmith_unfillet(self:_h(), face))
end

--- The chamfer `face` belongs to cut again at `distance`. `tolerance` defaults to 1e-6.
function Solid:rechamfer(face, distance, tolerance)
  if tolerance == nil then tolerance = 1e-6 end
  return new_solid(lib().cadaclysm_blacksmith_rechamfer(self:_h(), face, distance, tolerance))
end

--- The chamfer `face` belongs to taken off, the faces beside it sharp again.
function Solid:unchamfer(face)
  return new_solid(lib().cadaclysm_blacksmith_unchamfer(self:_h(), face))
end

--- This solid with its flush faces merged: flat faces on one plane, facing one
--- way and meeting, made one face -- the seams a `join` leaves where two parts
--- are flush.
function Solid:merge_flush()
  return new_solid(lib().cadaclysm_blacksmith_merge_flush(self:_h()))
end

--- This solid hollowed to walls `thickness` thick; `open` (default {}) lists the
--- face indices removed so the hollow is reachable. `tolerance` defaults to
--- 1e-6; `progress` as `join`'s.
function Solid:shell(thickness, open, tolerance, progress)
  if open == nil then open = {} end
  if tolerance == nil then tolerance = 1e-6 end
  local arr, n = uint32s(open, "shell")
  local a = self:_h()
  local cb, done = progress_callback(progress)
  local h = done(lib().cadaclysm_blacksmith_shell(a, thickness, arr, n, tolerance, cb, nil))
  return new_solid(h)
end

--- This sheet made a solid `thickness` thick -- Fusion's Thicken: its faces,
--- their twins moved `thickness` along the normals, and a wall round every open
--- edge. `tolerance` defaults to 1e-6; `progress` as `join`'s.
function Solid:thicken(thickness, tolerance, progress)
  if tolerance == nil then tolerance = 1e-6 end
  local a = self:_h()
  local cb, done = progress_callback(progress)
  local h = done(lib().cadaclysm_blacksmith_thicken(a, thickness, tolerance, cb, nil))
  return new_solid(h)
end

local schema_file

--- This solid as a reader `Scene`, through STEP text and `cadaclysm.open_memory`.
--- `schema` as `step_text` takes it; the reader is given the schema's path only
--- when it names an existing file. Needs cadaclysm.lua and its library.
function Solid:to_scene(schema)
  local cadaclysm = reader("to_scene")
  return cadaclysm.open_memory(self:step_text(schema), "stp", schema_file(schema))
end

-- A callback may fire only from a C call made by code the JIT did not compile.
for _, name in ipairs({ "join", "cut", "common", "trim", "split_sheet", "fillet", "push_pull", "split",
  "split_by_plane", "shell", "thicken" }) do
  jit.off(Solid[name])
end

-- ---- selecting -------------------------------------------------------------------------

--- The axes `Selector.max` and `Selector.min` take.
---@class Axis
---@field X integer
---@field Y integer
---@field Z integer
local Axis = { X = 0, Y = 1, Z = 2 }
M.Axis = Axis

--- Which face: furthest along an axis, furthest against it, by outward normal,
--- or by index -- `Selector::Max/Min/Normal/Index` in the crate.
---@class Selector
Selector = {}
class(Selector)
callable(Selector)
M.Selector = Selector

function Selector.new(kind, v, index)
  if index == nil then index = 0 end
  return setmetatable({ _kind = kind, _v = v, _index = index }, Selector)
end

local function axis_value(axis)
  if type(axis) == "string" then axis = Axis[axis:upper()] end
  if axis ~= 0 and axis ~= 1 and axis ~= 2 then raise("axis: expected Axis.X, Axis.Y or Axis.Z, got " .. repr(axis)) end
  return axis
end

--- The face furthest along `axis` (an `Axis`).
function Selector.max(axis)
  return Selector.new(0, nil, axis_value(axis))
end

--- The face furthest against `axis`.
function Selector.min(axis)
  return Selector.new(1, nil, axis_value(axis))
end

--- The face whose outward normal is nearest `direction` ({x, y, z}; need not be unit).
function Selector.normal(direction)
  local x, y, z = triple(direction, "normal")
  return Selector.new(2, { x, y, z }, 0)
end

--- The face with index `i` (from zero).
function Selector.index(i)
  return Selector.new(3, nil, math.floor(number(i, "index")))
end

function Selector:_raw()
  local v = nil
  if self._v ~= nil then v = ffi.new("double[3]", self._v[1], self._v[2], self._v[3]) end
  return self._kind, v, self._index
end

-- ---- plain records ------------------------------------------------------------------

--- One edge of a solid, as plain data: `index` (what `fillet` takes, from zero),
--- `kind` (the curve), `faces` (the faces meeting on it, indices from zero) and
--- `segments` ({{a, b}, ...}, each end a triple).
---@class Edge
---@field index integer  from zero
---@field kind string
---@field faces integer[]  from zero
---@field segments table[]  {{a, b}, ...}, each end {x, y, z}
Edge = {}
local Edge_get = {}
class(Edge, Edge_get)
callable(Edge)
M.Edge = Edge

function Edge.new(index, kind, faces, segments)
  return setmetatable({ index = index, kind = kind, faces = faces, segments = segments }, Edge)
end

--- Whether the edge is a straight line.
function Edge_get.is_line(self)
  return self.kind == "line"
end

--- Unit direction of a line edge (from its first segment) as {x, y, z}, else nil.
function Edge_get.direction(self)
  if not self.is_line or #self.segments == 0 then return nil end
  local a, b = self.segments[1][1], self.segments[1][2]
  local d = { b[1] - a[1], b[2] - a[2], b[3] - a[3] }
  local n = math.sqrt(d[1] * d[1] + d[2] * d[2] + d[3] * d[3])
  if n > 0 then return { d[1] / n, d[2] / n, d[3] / n } end
  return nil
end

Edge.__tostring = function(self)
  local faces = {}
  for i, f in ipairs(self.faces) do faces[i] = tostring(f) end
  return ("Edge(%d, '%s', faces=(%s))"):format(self.index, self.kind, table.concat(faces, ", "))
end

--- Whether a solid's faces make a manifold, as plain data (`Solid.manifold`):
--- `faces`, `edges`, `vertices`, `boundary_edges` (one face borders them),
--- `non_manifold_edges` (three or more do), `non_manifold_vertices`;
--- `is_manifold` where there are none of the last two, and `is_closed` where
--- there is no boundary edge either.
---@class Manifold
---@field faces integer
---@field edges integer
---@field vertices integer
---@field boundary_edges integer
---@field non_manifold_edges integer
---@field non_manifold_vertices integer
---@field is_manifold boolean
---@field is_closed boolean
Manifold = {}
class(Manifold)
callable(Manifold)
M.Manifold = Manifold

function Manifold.new(row)
  return setmetatable({
    faces = tonumber(row[1]), edges = tonumber(row[2]), vertices = tonumber(row[3]),
    boundary_edges = tonumber(row[4]), non_manifold_edges = tonumber(row[5]),
    non_manifold_vertices = tonumber(row[6]),
    is_manifold = row[7] ~= 0 and row[7] ~= false, is_closed = row[8] ~= 0 and row[8] ~= false,
  }, Manifold)
end

Manifold.__tostring = function(self)
  return ("Manifold(faces=%d, edges=%d, vertices=%d, boundary_edges=%d, non_manifold_edges=%d, "
    .. "non_manifold_vertices=%d, is_manifold=%s, is_closed=%s)"):format(self.faces, self.edges, self.vertices,
    self.boundary_edges, self.non_manifold_edges, self.non_manifold_vertices, tostring(self.is_manifold),
    tostring(self.is_closed))
end

-- ---- frames ---------------------------------------------------------------------------

local XY = { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 }
local XZ = { 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0 }
local YZ = { 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0 }

-- How far from square a frame's axes may be (the cosine between two of them).
local SQUARE = 1e-6

local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function cross(a, b)
  return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
end
local function slice(t, i, j)
  local out = {}
  for k = i, j do out[#out + 1] = t[k] end
  return out
end

local function unit(v, what)
  local x, y, z = triple(v, what)
  local n = math.sqrt(x * x + y * y + z * z)
  if not (n > 1e-12 and n < math.huge) then raise(what .. " has no direction") end
  return { x / n, y / n, z / n }
end

--- An origin and three unit axes, square to each other and right-handed
--- (z = x cross y): the plane a profile is drawn on (its x/y) and the direction
--- it is built along (its z). Pass it wherever a `frame` goes; `frame[i]` reads
--- its twelve numbers (i = 1..12) as Python's iteration does. Immutable.
--- `Frame.new(origin, x, y, z)` or `Frame(origin, x, y, z)`: normalises the axes
--- and raises `BuildError` when they are not square or not right-handed.
---@class Frame
Frame = {}
local Frame_get = {}
M.Frame = Frame
Frame.__index = function(self, key)
  if type(key) == "number" then return rawget(self, "_v")[key] end
  local get = Frame_get[key]
  if get then return get(self) end
  return Frame[key]
end
callable(Frame)

function Frame.new(origin, x, y, z)
  local o = doubles(origin, 3, "Frame: origin")
  local ov = { o[0], o[1], o[2] }
  for i = 1, 3 do
    if not (math.abs(ov[i]) < math.huge) then raise("Frame: origin must be three finite numbers") end
  end
  x, y, z = unit(x, "Frame: x"), unit(y, "Frame: y"), unit(z, "Frame: z")
  if math.max(math.abs(dot(x, y)), math.abs(dot(y, z)), math.abs(dot(z, x))) > SQUARE then
    raise("Frame: the axes are not square to each other")
  end
  if dot(cross(x, y), z) < 0 then raise("Frame: the axes are left-handed (z must be x × y)") end
  local v = {}
  for _, part in ipairs({ ov, x, y, z }) do
    for i = 1, 3 do v[#v + 1] = part[i] + 0.0 end   -- + 0.0: no -0.0 to print or compare
  end
  return setmetatable({ _v = v }, Frame)
end

--- Twelve numbers or four triples -- what `Solid:face_frame` and
--- `Workplane.frame` hand back -- checked as the constructor checks.
function Frame.of(frame)
  local d = frame_arg(frame)
  local v = {}
  for i = 0, 11 do v[i + 1] = d[i] end
  return Frame.new(slice(v, 1, 3), slice(v, 4, 6), slice(v, 7, 9), slice(v, 10, 12))
end

--- The world XY plane through `origin` (default {0, 0, 0}): z up, as `Workplane.xy`.
function Frame.xy(origin)
  if origin == nil then origin = { 0, 0, 0 } end
  return Frame.new(origin, slice(XY, 4, 6), slice(XY, 7, 9), slice(XY, 10, 12))
end

--- The world XZ plane through `origin`: x along X, y along Z, so z is -Y, as `Workplane.xz`.
function Frame.xz(origin)
  if origin == nil then origin = { 0, 0, 0 } end
  return Frame.new(origin, slice(XZ, 4, 6), slice(XZ, 7, 9), slice(XZ, 10, 12))
end

--- The world YZ plane through `origin`: x along Y, y along Z, so z is +X, as `Workplane.yz`.
function Frame.yz(origin)
  if origin == nil then origin = { 0, 0, 0 } end
  return Frame.new(origin, slice(YZ, 4, 6), slice(YZ, 7, 9), slice(YZ, 10, 12))
end

--- The plane through `origin` square to `normal` (the frame's z). Its x axis is
--- `x` laid onto that plane; with none, world X laid onto it, or world Y when
--- the normal is within about 25 degrees of X -- the axes `Solid:face_frame`
--- gives a face facing `normal`. So +Z, -Y or +X give exactly `xy`, `xz`, `yz`.
function Frame.at(origin, normal, x)
  local z = unit(normal, "Frame.at: normal")
  if x == nil then
    if math.abs(z[1]) <= 0.9 then x = { 1.0, 0.0, 0.0 } else x = { 0.0, 1.0, 0.0 } end
  end
  local hint = unit(x, "Frame.at: x")
  local d = dot(hint, z)
  if math.abs(d) > 1 - SQUARE then raise("Frame.at: x lies along the normal") end
  local ax = unit({ hint[1] - d * z[1], hint[2] - d * z[2], hint[3] - d * z[3] }, "Frame.at: x")
  return Frame.new(origin, ax, cross(z, ax), z)
end

--- The origin, {x, y, z}.
function Frame_get.origin(self) return slice(self._v, 1, 3) end
--- The x axis, a unit {x, y, z}.
function Frame_get.x(self) return slice(self._v, 4, 6) end
--- The y axis, a unit {x, y, z}.
function Frame_get.y(self) return slice(self._v, 7, 9) end
--- The z axis (the normal), a unit {x, y, z}.
function Frame_get.z(self) return slice(self._v, 10, 12) end

--- This frame moved by (`dx`, `dy`, `dz`) in world coordinates.
function Frame:translate(dx, dy, dz)
  local o = self.origin
  return Frame.new({ o[1] + dx, o[2] + dy, o[3] + dz }, self.x, self.y, self.z)
end

--- This frame moved `distance` along its own z.
function Frame:offset(distance)
  local z = self.z
  return self:translate(distance * z[1], distance * z[2], distance * z[3])
end

--- The twelve numbers as a fresh Lua array.
function Frame:values()
  return slice(self._v, 1, 12)
end

Frame.__eq = function(a, b)
  for i = 1, 12 do
    if a._v[i] ~= b._v[i] then return false end
  end
  return true
end

Frame.__tostring = function(self)
  local function t(v) return "(" .. table.concat(v, ", ") .. ")" end
  return ("Frame(origin=%s, x=%s, y=%s, z=%s)"):format(t(self.origin), t(self.x), t(self.y), t(self.z))
end

-- ---- the workplane chain ----------------------------------------------------------------

--- The fluent chain, mirroring the Rust `Workplane`: `frame` (twelve numbers),
--- the solid built so far, and the face last picked. A build call *replaces* the
--- solid; combine solids explicitly with `Solid:join`. Every step raises
--- `BuildError` at once. `Workplane.new(frame, solid)` or `Workplane(frame, solid)`.
---@class Workplane
---@field frame number[]  twelve numbers
local Workplane = {}
class(Workplane)
callable(Workplane)
M.Workplane = Workplane

function Workplane.new(frame, solid)
  local d = frame_arg(frame)
  local f = {}
  for i = 0, 11 do f[i + 1] = d[i] end
  return setmetatable({ frame = f, _solid = solid, _selected = nil }, Workplane)
end

--- The world XY plane.
function Workplane.xy() return Workplane.new(XY) end
--- The world XZ plane (z is -Y).
function Workplane.xz() return Workplane.new(XZ) end
--- The world YZ plane (z is +X).
function Workplane.yz() return Workplane.new(YZ) end
--- A workplane on `frame`.
function Workplane.on(frame) return Workplane.new(frame) end
--- A workplane on XY holding `solid`, to pick its faces.
function Workplane.from_solid(solid) return Workplane.new(XY, solid) end

function Workplane:_set(solid)
  self._solid, self._selected = solid, nil
  return self
end

--- A cuboid placed on this workplane's frame; replaces the solid.
function Workplane:cuboid(x, y, z)
  return self:_set(Solid.cuboid(x, y, z):place(self.frame))
end

--- A cylinder placed on this workplane's frame; replaces the solid.
function Workplane:cylinder(r, h)
  return self:_set(Solid.cylinder(r, h):place(self.frame))
end

--- `profile` extruded `height` from this workplane's frame; replaces the solid.
function Workplane:extrude(profile, height)
  return self:_set(Solid.extrude(profile, self.frame, height))
end

--- The flat sheet `profile` bounds on this workplane's frame -- `Solid.face`.
function Workplane:face(profile)
  return self:_set(Solid.face(profile, self.frame))
end

--- `profile` revolved `angle` radians about this workplane's own y axis through
--- its origin, as the Rust chain; replaces the solid.
function Workplane:revolve(profile, angle)
  local f = self.frame
  return self:_set(Solid.revolve(profile, { { f[1], f[2], f[3] }, { f[7], f[8], f[9] } }, angle))
end

--- Slide the current solid, keeping `faces`'s selection (a rigid translation
--- carries every face along at the same index). Raises `BuildError` on an empty
--- workplane, where Rust's is a silent no-op.
function Workplane:translate(dx, dy, dz)
  if self._solid == nil then raise("translate: the workplane holds no solid (BuildError::Empty)") end
  self._solid = self._solid:translate(dx, dy, dz)
  return self
end

--- Pick a face of the current solid with a `Selector`.
function Workplane:faces(selector)
  if self._solid == nil then raise("faces: the workplane holds no solid (BuildError::Empty)") end
  self._selected = self._solid:select_face(selector)
  return self
end

--- Adopt the frame on the face last picked; a no-op if none is.
function Workplane:workplane()
  if self._solid ~= nil and self._selected ~= nil then
    self.frame = self._solid:face_frame(self._selected)
  end
  return self
end

--- The solid built so far; raises `BuildError` if nothing was.
function Workplane:solid()
  if self._solid == nil then raise("solid: nothing was built (BuildError::Empty)") end
  return self._solid
end

-- ---- STEP -------------------------------------------------------------------------------

-- `schema`'s path, if it is a string with no newline in it that names a regular
-- file -- else nil. A string the file system refuses to look up counts as "not a file".
schema_file = function(schema)
  if type(schema) ~= "string" or schema:find("\n", 1, true) then return nil end
  if is_file(schema) then return schema end
  return nil
end

-- `schema` is nil (the built-in AP203), the path of a schema file, a built-in
-- schema's name, or a custom schema's EXPRESS text.
local function schema_text(schema)
  if schema == nil then return nil end
  local file = schema_file(schema)
  if file ~= nil then return read_file(file) end
  if type(schema) == "string" then return schema end
  raise("schema: " .. repr(schema) .. " is neither a file, a schema name nor schema text")
end

--- Several solids (a Lua array) as one STEP file's text, each its own body.
--- `schema` is one of four things: nil (the kernel's built-in AP203); the path
--- of a schema file (no newline in it, naming an existing file), read and sent
--- as EXPRESS text; the bare name of a built-in schema (case-insensitive, e.g.
--- "AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF" -- an unknown name raises
--- `BuildError`); or a custom schema's own EXPRESS text. `unit` "mm" (default),
--- "m" or "in".
function M.write_step_text(solids, schema, unit)
  if unit == nil then unit = "mm" end
  if UNITS[unit] == nil then raise("unit must be one of ['in', 'm', 'mm']") end
  local n = #solids
  local handles = ffi.new("const struct CadaclysmBlacksmithSolid *[?]", math.max(n, 1))
  for i = 1, n do handles[i - 1] = solid_handle(solids[i], "write_step_text") end
  local out = lib().cadaclysm_blacksmith_step(handles, n, schema_text(schema), UNITS[unit])
  if out == nil then fail("step") end
  local result = ffi.string(out)
  lib().cadaclysm_blacksmith_string_free(out)
  return result
end

--- One STEP file at `path` (AP203 unless `schema` names another), each solid
--- its own body. `schema` and `unit` as `write_step_text`.
function M.write_step(path, solids, schema, unit)
  if unit == nil then unit = "mm" end
  write_text(path, M.write_step_text(solids, schema, unit))
end

return M
