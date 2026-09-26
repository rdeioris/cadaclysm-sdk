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

**`mesh64` and `bounds_at64`.** `Solid:mesh64` hands back the very same
tessellation `Solid:mesh` does -- same cache, same generation, same `indices`
view -- with `positions`/`normals` unnarrowed (`float64` views, not `float32`):
exact far from the origin, where `mesh`'s are not. `Solid:bounds_at64` is
`bounds_at` from those same unnarrowed positions. Both share `mesh`/`bounds_at`'s
staleness rule: meshing again at a different tolerance stales every view from
the tolerance before, `mesh64`'s included.

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
  "cadaclysm_blacksmith_profile_regular_polygon", "cadaclysm_blacksmith_profile_star", "cadaclysm_blacksmith_profile_text",
  "cadaclysm_blacksmith_profile_spline",
  "cadaclysm_blacksmith_profile_polygon", "cadaclysm_blacksmith_profile_with_hole",
  "cadaclysm_blacksmith_translate_profile", "cadaclysm_blacksmith_profile_hits", "cadaclysm_blacksmith_hits_free",
  "cadaclysm_blacksmith_hit_count", "cadaclysm_blacksmith_hit", "cadaclysm_blacksmith_solid_profile_hits",
  "cadaclysm_blacksmith_hits_piece_count", "cadaclysm_blacksmith_hits_piece", "cadaclysm_blacksmith_hits_piece_profile",
  "cadaclysm_blacksmith_profile_common",
  "cadaclysm_blacksmith_profile_list_count", "cadaclysm_blacksmith_profile_list_get", "cadaclysm_blacksmith_profile_list_free",
  "cadaclysm_blacksmith_profile_round", "cadaclysm_blacksmith_profile_chain",
  "cadaclysm_blacksmith_profile_from_loops", "cadaclysm_blacksmith_profile_close_loop", "cadaclysm_blacksmith_profile_polylines",
  "cadaclysm_blacksmith_profile_piece_count", "cadaclysm_blacksmith_profile_piece", "cadaclysm_blacksmith_profile_trim_count",
  "cadaclysm_blacksmith_profile_trim_chain",
  "cadaclysm_blacksmith_path_begin", "cadaclysm_blacksmith_path_line_to", "cadaclysm_blacksmith_path_arc_to",
  "cadaclysm_blacksmith_path_bezier_to", "cadaclysm_blacksmith_path_conic_to", "cadaclysm_blacksmith_path_parabola_by_vertex",
  "cadaclysm_blacksmith_path_parabola_by_focus", "cadaclysm_blacksmith_path_parabola",
  "cadaclysm_blacksmith_path_nurbs_to", "cadaclysm_blacksmith_path_end",
  "cadaclysm_blacksmith_path_end_open", "cadaclysm_blacksmith_path_free", "cadaclysm_blacksmith_cuboid",
  "cadaclysm_blacksmith_cylinder", "cadaclysm_blacksmith_cone", "cadaclysm_blacksmith_sphere",
  "cadaclysm_blacksmith_torus", "cadaclysm_blacksmith_wedge", "cadaclysm_blacksmith_extrude",
  "cadaclysm_blacksmith_extrude_open", "cadaclysm_blacksmith_extrude_tapered",
  "cadaclysm_blacksmith_extrude_open_tapered", "cadaclysm_blacksmith_extrude_between",
  "cadaclysm_blacksmith_extrude_open_between", "cadaclysm_blacksmith_slant_of_plane", "cadaclysm_blacksmith_frame_midplane", "cadaclysm_blacksmith_frame_through", "cadaclysm_blacksmith_loft",
  "cadaclysm_blacksmith_loft_open", "cadaclysm_blacksmith_loft_through", "cadaclysm_blacksmith_loft_through_open", "cadaclysm_blacksmith_revolve", "cadaclysm_blacksmith_revolve_open",
  "cadaclysm_blacksmith_coil", "cadaclysm_blacksmith_revolve_in_plane", "cadaclysm_blacksmith_revolve_open_in_plane",
  "cadaclysm_blacksmith_sweep_path_begin", "cadaclysm_blacksmith_sweep_path_line_to",
  "cadaclysm_blacksmith_sweep_path_arc", "cadaclysm_blacksmith_sweep_path_along", "cadaclysm_blacksmith_sweep_path_free",
  "cadaclysm_blacksmith_sweep", "cadaclysm_blacksmith_sweep_open", "cadaclysm_blacksmith_pipe",
  "cadaclysm_blacksmith_extrude_faces", "cadaclysm_blacksmith_face", "cadaclysm_blacksmith_face_sheet",
  "cadaclysm_blacksmith_drop_faces", "cadaclysm_blacksmith_place", "cadaclysm_blacksmith_translate",
  "cadaclysm_blacksmith_scaled",
  "cadaclysm_blacksmith_rotate", "cadaclysm_blacksmith_mirror", "cadaclysm_blacksmith_join", "cadaclysm_blacksmith_cut",
  "cadaclysm_blacksmith_common", "cadaclysm_blacksmith_split_sheet", "cadaclysm_blacksmith_trim",
  "cadaclysm_blacksmith_fillet", "cadaclysm_blacksmith_chamfer", "cadaclysm_blacksmith_shell",
  "cadaclysm_blacksmith_thicken", "cadaclysm_blacksmith_push_pull", "cadaclysm_blacksmith_push_pull_faces",
  "cadaclysm_blacksmith_merge_flush",
  "cadaclysm_blacksmith_refillet", "cadaclysm_blacksmith_unfillet", "cadaclysm_blacksmith_rechamfer",
  "cadaclysm_blacksmith_unchamfer", "cadaclysm_blacksmith_split", "cadaclysm_blacksmith_split_by_plane",
  "cadaclysm_blacksmith_lump_count", "cadaclysm_blacksmith_lump", "cadaclysm_blacksmith_face_count",
  "cadaclysm_blacksmith_select_face", "cadaclysm_blacksmith_face_frame", "cadaclysm_blacksmith_face_ref",
  "cadaclysm_blacksmith_find_face", "cadaclysm_blacksmith_coloured",
  "cadaclysm_blacksmith_profile_coloured", "cadaclysm_blacksmith_profile_colour",
  "cadaclysm_blacksmith_colour",
  "cadaclysm_blacksmith_edges_coloured", "cadaclysm_blacksmith_edge_colour", "cadaclysm_blacksmith_edge_polyline_colours",
  "cadaclysm_blacksmith_face_kind", "cadaclysm_blacksmith_edge_count",
  "cadaclysm_blacksmith_edge", "cadaclysm_blacksmith_edge_curve", "cadaclysm_blacksmith_mesh", "cadaclysm_blacksmith_mesh64", "cadaclysm_blacksmith_mesh_face_triangles",
  "cadaclysm_blacksmith_intersect", "cadaclysm_blacksmith_intersection_free", "cadaclysm_blacksmith_intersection_chain_count",
  "cadaclysm_blacksmith_intersection_chain", "cadaclysm_blacksmith_intersection_curve",
  "cadaclysm_blacksmith_intersection_overlap_count", "cadaclysm_blacksmith_intersection_overlap",
  "cadaclysm_blacksmith_edge_polylines",
  "cadaclysm_blacksmith_bounds", "cadaclysm_blacksmith_bounds64", "cadaclysm_blacksmith_leaked_edges", "cadaclysm_blacksmith_unpaired_edges",
  "cadaclysm_blacksmith_manifold", "cadaclysm_blacksmith_step", "cadaclysm_blacksmith_sat_text",
  "cadaclysm_blacksmith_sat", "cadaclysm_blacksmith_brep_text", "cadaclysm_blacksmith_brep",
  "cadaclysm_blacksmith_string_free",
  "cadaclysm_blacksmith_from_brep", "cadaclysm_blacksmith_brep_layout_id",
  "cadaclysm_blacksmith_svg_options_init", "cadaclysm_blacksmith_svg_text", "cadaclysm_blacksmith_svg",
  "cadaclysm_blacksmith_fem_options_init", "cadaclysm_blacksmith_fem_mesh",
  "cadaclysm_blacksmith_fem_mesh_view", "cadaclysm_blacksmith_fem_mesh_edge",
  "cadaclysm_blacksmith_fem_mesh_vertex", "cadaclysm_blacksmith_fem_mesh_open_edge",
  "cadaclysm_blacksmith_fem_mesh_folded_edge", "cadaclysm_blacksmith_fem_mesh_msh_text",
  "cadaclysm_blacksmith_fem_mesh_save_msh", "cadaclysm_blacksmith_fem_mesh_free",
  "cadaclysm_blacksmith_drawing_svg_text", "cadaclysm_blacksmith_drawing_svg",
  "cadaclysm_blacksmith_named", "cadaclysm_blacksmith_solid_name",
  "cadaclysm_blacksmith_assembly_new", "cadaclysm_blacksmith_assembly_free", "cadaclysm_blacksmith_assembly_name",
  "cadaclysm_blacksmith_assembly_place_solid", "cadaclysm_blacksmith_assembly_place_assembly",
  "cadaclysm_blacksmith_assembly_step",
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

-- Classes the list checker names in its refusals, filled in where each is defined
-- (`Edge`, far below): `uint32s` is defined before them and cannot name them lexically.
local named = {}

-- A list argument as a uint32_t array, never null -- an empty list is not "none": `list`
-- must be a list (a table that is not a record -- an Edge or a Solid is refused) and each
-- item an index (a whole number, 0 to 4294967295) or, where `edges`, an Edge. Refused
-- here, named, before the kernel is asked: one edge is `{ edge }`, never read as none
-- (docs/superpowers/specs/2026-09-25-list-arguments-refused-clearly-design.md).
local function uint32s(list, call, param, edges)
  local function described(v)
    if named.Edge and type(v) == "table" and getmetatable(v) == named.Edge then return "an Edge" end
    return repr(v)
  end
  -- Its length is how many keys it has, not `#list`: Lua's `#` stops at any border, so
  -- `{ 5, nil, 7 }` may read as one item and the 7 go missing. A key that is not a whole
  -- number from 1 is a record's (an Edge, a Solid, `foo = "bar"`), so not a list. With
  -- `n` keys, a hole anywhere leaves a place at or below `n` empty, so the loop below meets
  -- it first and refuses it as a nil item -- never walking to, or sizing the array by, one
  -- stray huge key.
  local n, is_list = 0, type(list) == "table"
  if is_list then
    for k in pairs(list) do
      if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then is_list = false break end
      n = n + 1
    end
  end
  if not is_list then
    raise(("%s: %s must be a list of %s, not %s"):format(call, param, edges and "Edge objects or indices" or "indices", described(list)))
  end
  local out = ffi.new("uint32_t[?]", math.max(n, 1))
  for i = 1, n do
    local v = list[i]
    if edges and named.Edge and type(v) == "table" and getmetatable(v) == named.Edge then v = v.index end
    if type(v) ~= "number" or v < 0 or v > 4294967295 or v ~= math.floor(v) then
      raise(("%s: %s[%d] is not %s: %s"):format(call, param, i, edges and "an Edge or an index" or "an index", described(list[i])))
    end
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
-- `progress` raised, frees the result (with `free`, the solid free by default)
-- and raises that. A Lua error must never unwind through the library's frames,
-- so the callback catches it and the raise waits until the call has returned.
local function progress_callback(progress, free)
  if progress == nil then
    return nil, function(result) return result end
  end
  free = free or function(result) lib().cadaclysm_blacksmith_solid_free(result) end
  local raised
  local cb = ffi.cast("CadaclysmBlacksmithProgress", function(phase, done, total, _user)
    if raised ~= nil then return end
    local ok, err = pcall(progress, text(phase), tonumber(done), tonumber(total))
    if not ok then raised = err end
  end)
  return cb, function(result)
    cb:free()
    if raised ~= nil then
      if result ~= nil then free(result) end
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
--- (`{n, 3}` or `{m}`), `size` (elements), `dtype` ("float32"/"uint32"/"float64"), and the
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

-- ---- the FEM surface mesh --------------------------------------------------------

--- One B-rep edge of a FEM mesh: the chain of nodes along it, and where that chain
--- breaks. Plain data, copied out of the handle, so an edge outlives the mesh it came
--- from -- a chain is tens of numbers where the flat arrays are millions.
---
--- `nodes` are this mesh's node indices in order along the edge, its end vertices
--- included; a closed edge repeats no node. **`runs` says where the chain breaks**, as
--- the ABI's own offsets into `nodes` **counting from zero**, where `nodes` is a Lua
--- array counting from one -- so `chains()` does that arithmetic once rather than
--- leaving every caller to. Read each chain as one polyline and join nothing across a
--- run boundary: the two ends either side of one are two points of the edge with no
--- mesh edge between them. `{0}` is the ordinary answer, and a caller reading `nodes`
--- as one polyline without looking here silently jumps the gap.
---
--- `faces` is `{face_a, face_b}` and `ends` is `{end_a, end_b}`, the second of each
--- `NONE` where there is none -- an open sheet's rim, or both ends at one vertex (a
--- closed edge, a circle's rim, a full-turn seam). **`0` is a real face and a real
--- vertex, not a sentinel.** Which end comes first is the first trim's direction and
--- means nothing else. `ends` index `FemMesh.vertices` from zero, so the vertex of
--- `e.ends[1]` is `mesh.vertices[e.ends[1] + 1]`.
---
--- `closed` where the nodes make one loop -- never where there is more than one run.
--- `seam` where one face bounds the edge twice, a closed surface's seam rather than a
--- real boundary; both `faces` are then that same face.
---
--- `id` is **the solid's own edge id**, not this mesh's edge index: `FemMesh.edges` is
--- a densely renumbered subset of the solid's edges, ascending by id, with every edge
--- collapsed to a point left out. Everything else that names an edge here means the
--- index -- a `node_kind` of 1 read through `node_entity`, the third number of an
--- `open_edges` or `folded_edges` row, and the `edge_<i>` physical group of
--- `msh_text()`.
---@class FemEdge
---@field id integer  the solid's own B-rep edge id, not this mesh's edge index
---@field nodes integer[]  this mesh's node indices along the edge
---@field runs integer[]  where each run of `nodes` begins, from zero
---@field faces integer[]  {face_a, face_b}, the second NONE on a rim
---@field ends integer[]  {end_a, end_b}, into `FemMesh.vertices`, from zero
---@field closed boolean
---@field seam boolean
local FemEdge = {}
FemEdge.__index = FemEdge
M.FemEdge = FemEdge
FemEdge.__tostring = function(e)
  return ("FemEdge(id=%d, nodes=%d, runs=%d, faces=(%d, %d), ends=(%d, %d), closed=%s, seam=%s)")
    :format(e.id, #e.nodes, #e.runs, e.faces[1], e.faces[2], e.ends[1], e.ends[2],
      tostring(e.closed), tostring(e.seam))
end

--- `nodes` broken at `runs`: a Lua array of Lua arrays of node indices, one per run,
--- which together hold exactly `nodes` in order. One entry for the ordinary single-run
--- edge, and the place the zero-based `runs` are turned into Lua's own one-based
--- slices -- do that by hand and an off-by-one drops or repeats a node.
function FemEdge:chains()
  local out = {}
  for k = 1, #self.runs do
    local from, to = self.runs[k] + 1, self.runs[k + 1] or #self.nodes
    local chain = {}
    for i = from, to do chain[#chain + 1] = self.nodes[i] end
    out[#out + 1] = chain
  end
  return out
end

--- One B-rep vertex of a FEM mesh: the node the mesh put there, if any, and where the
--- topology says it is, if that is known. Plain data.
---
--- `node` is the mesh node at this vertex, or `NONE` where the mesh has none there.
--- **A sentinel here is ordinary, not a fault**: the analysis rebuilds a vertex wherever
--- two trims meet, and a pole's polyline runs give a sphere 48 of them where the mesh
--- has 2 points, so a caller walking these skips the sentinel rather than treating it
--- as a gap.
---
--- `point` is `{x, y, z}` where the vertex is, in the same space and under the same
--- `placement` as `FemMesh.nodes` -- the solid's own vertex rather than a mesh node, so
--- the two can differ by the mesher's rounding. **Meaningless unless `has_position`**:
--- it is `{0, 0, 0}` then, which is a point no geometry has and which a solver would
--- take for a node at the origin.
---@class FemVertex
---@field node integer  the mesh node there, or `NONE`
---@field point number[]  {x, y, z}, meaningless unless `has_position`
---@field has_position boolean
local FemVertex = {}
FemVertex.__index = FemVertex
M.FemVertex = FemVertex
FemVertex.__tostring = function(v)
  return ("FemVertex(node=%d, point=(%g, %g, %g), has_position=%s)")
    :format(v.node, v.point[1], v.point[2], v.point[3], tostring(v.has_position))
end

--- One solid meshed for a solver: nodes welded by bits, triangles wound outward, every
--- node tagged with the lowest-dimension B-rep entity it lies on, and every crack
--- reported rather than closed. What `solid:fem_mesh()` returns, and **owned by you**:
--- `free()` it (the collector does otherwise).
---
--- **The five flat arrays are the library's own memory, lent as they are**: `nodes` is
--- a `const double *`, three a node; `triangles` a `const uint32_t *`, three a triangle
--- and counting from zero; `triangle_face`, `node_kind` and `node_entity`
--- `const uint32_t *`, one per triangle or per node. No copy, which is what makes a
--- million-element solver mesh affordable.
---
--- **This is the one array product here that is not the solid's**, and the difference
--- matters. `Solid:mesh` hands back `View`s over the solid's tessellation cache, which
--- a `close()` or a mesh at another tolerance replaces -- so a `View` checks a
--- generation and raises once stale. A FEM mesh is **its own handle**: its pointers are
--- built with it and never move, it is not in that cache, and neither closing the solid
--- nor meshing it again at any tolerance touches it. So these are plain **fields** with
--- no generation and no check, and reusing the `View` machine here would refuse reads
--- the library never refuses.
---
--- **So hold the FemMesh for as long as you read one of its arrays.** Because they are
--- fields rather than accessors, nothing here refuses a read after `free()`: a pointer
--- taken out of one is a bare cdata pointer into memory the library has given back, and
--- reading it reads whatever is there by then. Copy into a Lua table what must outlive
--- the handle. The methods below *do* refuse, naming themselves. That is the same sharp
--- edge the note at the top of this file documents for the solid's own views, and it is
--- documented rather than enforced for the same reason.
---
--- `edges`, `vertices`, `open_edges` and `folded_edges` are computed when read, one C
--- call a row, and are copies: read them once into a local rather than inside a loop.
---@class FemMesh
---@field nodes ffi.cdata*  const double *, 3 a node
---@field node_count integer
---@field triangles ffi.cdata*  const uint32_t *, 3 a triangle, from zero
---@field triangle_count integer
---@field triangle_face ffi.cdata*  const uint32_t *, one a triangle
---@field node_kind ffi.cdata*  const uint32_t *, one a node: 0 a vertex, 1 an edge, 2 a face
---@field node_entity ffi.cdata*  const uint32_t *, one a node, read by its `node_kind`
---@field face_count integer  the solid's faces
---@field watertight boolean
---@field from_mesh boolean  always false here: every solid has a brep behind it
---@field min_angle number  the smallest interior angle of any triangle, in degrees
---@field worst_triangle integer  the triangle with that angle, into `triangles`
---@field longest_edge number  the longest triangle edge, placed
local FemMesh = {}
local FemMesh_get = {}
class(FemMesh, FemMesh_get)
M.FemMesh = FemMesh

local function free_fem_mesh(m) lib().cadaclysm_blacksmith_fem_mesh_free(m) end

local function fem_handle(self)
  local p = rawget(self, "_ptr")
  if p == nil then raise("fem mesh: freed") end
  return p
end

--- Whether `free()` has run.
function FemMesh_get.freed(self) return rawget(self, "_ptr") == nil end

--- Give the mesh back, and with it every array lent from it. Idempotent; the collector
--- does it otherwise.
function FemMesh:free()
  local p = rawget(self, "_ptr")
  if p ~= nil then
    self._ptr = nil
    ffi.gc(p, nil)
    free_fem_mesh(p)
  end
end

-- A `const uint32_t *` of `count` entries as a Lua array (from one) of the library's
-- own numbers (from zero): a copy, so it outlives the handle.
local function fem_indices(ptr, count)
  local out = {}
  for i = 0, count - 1 do out[i + 1] = ptr[i] end
  return out
end

--- One `FemEdge` per B-rep edge, in the order a `node_kind` of 1 indexes them.
--- **This list's own numbering, not the solid's**: each `FemEdge.id` carries the
--- solid's own edge id.
function FemMesh_get.edges(self)
  local L, handle, out = lib(), fem_handle(self), {}
  local raw = ffi.new("struct CadaclysmBlacksmithFemEdge")
  for i = 0, self._edge_count - 1 do
    if not L.cadaclysm_blacksmith_fem_mesh_edge(handle, i, raw) then fail("fem_mesh_edge " .. i) end
    out[#out + 1] = setmetatable({
      id = raw.id,
      nodes = fem_indices(raw.nodes, raw.node_count),
      runs = fem_indices(raw.runs, raw.run_count),
      faces = { raw.face_a, raw.face_b },
      ends = { raw.end_a, raw.end_b },
      closed = raw.closed,
      seam = raw.seam,
    }, FemEdge)
  end
  return out
end

--- One `FemVertex` per B-rep vertex, in the order a `node_kind` of 0 indexes them.
function FemMesh_get.vertices(self)
  local L, handle, out = lib(), fem_handle(self), {}
  local raw = ffi.new("struct CadaclysmBlacksmithFemVertex")
  for i = 0, self._vertex_count - 1 do
    if not L.cadaclysm_blacksmith_fem_mesh_vertex(handle, i, raw) then fail("fem_mesh_vertex " .. i) end
    out[#out + 1] = setmetatable({
      node = raw.node,
      point = { raw.point[0], raw.point[1], raw.point[2] },
      has_position = raw.has_position,
    }, FemVertex)
  end
  return out
end

-- One flattened census, row by row: the shape `open_edges` and `folded_edges` share,
-- so the two cannot drift.
local function fem_census(self, row, count, what)
  local handle = fem_handle(self)
  local a, b, edge = ffi.new("uint32_t[1]"), ffi.new("uint32_t[1]"), ffi.new("uint32_t[1]")
  local out = {}
  for i = 0, count - 1 do
    if not row(handle, i, a, b, edge) then fail(what .. " " .. i) end
    out[#out + 1] = { a[0], b[0], edge[0] }
  end
  return out
end

--- Every crack, as `{a, b, brep_edge}`: a directed mesh edge `{a, b}` with no `{b, a}`,
--- and the B-rep edge both nodes lie on, or `NONE` where they share none.
---
--- **Empty unless the solid's topology is closed**, whose mesh is otherwise not asked
--- about at all -- an open sheet from `face`, `face_sheet`, `drop_faces` or
--- `extrude_open` reports `watertight` false with this and `folded_edges` both empty,
--- and *that trio together* says "not asked", not "nothing found".
function FemMesh_get.open_edges(self)
  local L = lib()
  return fem_census(self, function(h, i, a, b, e) return L.cadaclysm_blacksmith_fem_mesh_open_edge(h, i, a, b, e) end,
    self._open_edge_count, "fem_mesh_open_edge")
end

--- Every fold, as `open_edges` reports a crack: a directed mesh edge used by more than
--- one triangle.
---
--- **A solid can be folded without being open** -- one no thicker than a line leaves no
--- hole for an open edge to find -- and the closure census's own known-bad bodies are
--- folds rather than open cracks, so a caller that checks only `open_edges` calls such a
--- solid sound. Empty under the same rule as `open_edges`.
function FemMesh_get.folded_edges(self)
  local L = lib()
  return fem_census(self, function(h, i, a, b, e) return L.cadaclysm_blacksmith_fem_mesh_folded_edge(h, i, a, b, e) end,
    self._folded_edge_count, "fem_mesh_folded_edge")
end

--- The mesh as Gmsh 4.1 ASCII `.msh` text: an entity per B-rep vertex, edge and face,
--- a volume where the solid closes, and a physical group naming each.
---
--- **On this side of the ABI the library's text is owned** and released here with
--- `cadaclysm_blacksmith_string_free`, as every other text this library hands over
--- (`step_text`, `sat_text`, `brep_text`, `svg_text`): two asks give two independent
--- texts and neither dies with the handle. `cadaclysm.FemMesh.msh_text` is the other
--- way round -- it borrows a slot on its own handle and must not be freed -- so a reader
--- porting one side's reasoning onto the other leaks or double-frees.
---
--- **The unlicensed notice is printed here**, and on `save_msh`, this library noticing
--- on its writers where the reader library notices in its own constructor and on
--- neither `.msh` call. Raises `BuildError` for a mesh the writer refuses, naming the
--- field it cannot honour, and for a freed handle.
function FemMesh:msh_text()
  local out = lib().cadaclysm_blacksmith_fem_mesh_msh_text(fem_handle(self))
  if out == nil then fail("fem_mesh_msh_text") end
  local result = ffi.string(out)
  lib().cadaclysm_blacksmith_string_free(out)
  return result
end

--- `msh_text()` written to `path` by the library itself: the same bytes from the same
--- writer, straight to the file rather than through a string this side has to free.
--- Raises `BuildError` for a mesh the writer refuses or a file it cannot write. The
--- notice is printed here too; see `msh_text`.
function FemMesh:save_msh(path)
  if not lib().cadaclysm_blacksmith_fem_mesh_save_msh(fem_handle(self), tostring(path)) then
    fail("fem_mesh_save_msh")
  end
end

FemMesh.__tostring = function(m)
  if rawget(m, "_ptr") == nil then return "FemMesh(freed)" end
  return ("FemMesh(nodes=%d, triangles=%d, watertight=%s, from_mesh=%s)")
    :format(m.node_count, m.triangle_count, tostring(m.watertight), tostring(m.from_mesh))
end

-- The handle wrapped, its view read once: every pointer in the view is built with the
-- handle and good until it is freed (nothing in this ABI is built lazily), so asking
-- again per field would be one C call per array for the same answer.
local function fem_mesh(ptr)
  local raw = ffi.new("struct CadaclysmBlacksmithFemMeshView")
  if not lib().cadaclysm_blacksmith_fem_mesh_view(ptr, raw) then
    local reason = last_error()
    free_fem_mesh(ptr)
    error(setmetatable({ message = reason ~= "" and reason or "fem_mesh_view" }, BuildError), 3)
  end
  return setmetatable({
    _ptr = ffi.gc(ptr, free_fem_mesh),
    nodes = raw.nodes,
    node_count = raw.node_count,
    triangles = raw.triangles,
    triangle_count = raw.triangle_count,
    triangle_face = raw.triangle_face,
    node_kind = raw.node_kind,
    node_entity = raw.node_entity,
    face_count = raw.face_count,
    _edge_count = raw.edge_count,
    _vertex_count = raw.vertex_count,
    _open_edge_count = raw.open_edge_count,
    _folded_edge_count = raw.folded_edge_count,
    watertight = raw.watertight,
    from_mesh = raw.from_mesh,
    min_angle = raw.min_angle,
    worst_triangle = raw.worst_triangle,
    longest_edge = raw.longest_edge,
  }, FemMesh)
end

-- ---- profiles -----------------------------------------------------------------------

local function free_profile(p) lib().cadaclysm_blacksmith_profile_free(p) end
local function free_path(p) lib().cadaclysm_blacksmith_path_free(p) end
local function free_sweep_path(p) lib().cadaclysm_blacksmith_sweep_path_free(p) end
local function free_solid(p) lib().cadaclysm_blacksmith_solid_free(p) end

--- A closed outline with holes, in its own x/y. Immutable; every method returns a new one.
---@class Profile
local Profile = {}
local Profile_get = {}
class(Profile, Profile_get)
M.Profile = Profile

local function new_profile(handle, what)
  checked(handle, what or "profile")
  return setmetatable({ _handle = ffi.gc(handle, free_profile) }, Profile)
end

--- The profiles of a list the library handed back (nil: raise), each a handle of
--- its own, the list freed.
local function profile_list(h, what)
  if h == nil then fail(what) end
  local ok, result = pcall(function()
    local n = lib().cadaclysm_blacksmith_profile_list_count(h)
    local out = {}
    for i = 0, n - 1 do
      out[#out + 1] = new_profile(lib().cadaclysm_blacksmith_profile_list_get(h, i), "profile_list_get")
    end
    return out
  end)
  lib().cadaclysm_blacksmith_profile_list_free(h)
  if not ok then error(result, 0) end
  return result
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

--- A star of `points` tips (at least 3) on the circle of `outer` about
--- `centre`, its inner corners on the circle of `inner` (positive, under
--- `outer`), alternating: the first tip at `angle` radians (default 0) from the
--- sketch's x axis, the rest counter-clockwise.
function Profile.star(centre, outer, inner, points, angle)
  if angle == nil then angle = 0.0 end
  local cx, cy = pair(centre, "centre")
  points = math.max(0, math.floor(number(points, "points")))
  return new_profile(lib().cadaclysm_blacksmith_profile_star(cx, cy, outer, inner, points, angle))
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

--- Start drawing on the arc of the parabola with `vertex` ({vx, vy}), axis direction
--- `axis` ({ax, ay}) and focal length `focal`, over the across-axis coordinates
--- `from..to`: the path begins at the arc's first point and holds the arc -- a
--- reflector from rim to rim, `Profile.parabola({0, 0}, {0, 1}, 20, -50, 50)` a dish
--- 100 wide opening up.
function Profile.parabola(vertex, axis, focal, from, to)
  local vx, vy = pair(vertex, "vertex")
  local ax, ay = pair(axis, "axis")
  local h = checked(lib().cadaclysm_blacksmith_path_parabola(vx, vy, ax, ay, focal, from, to), "path_parabola")
  return M.Path._from_handle(h)
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

--- The cutters' handles for the trim's calls: a C array, and how many.
local function cutter_handles(cutters, what)
  local n = #cutters
  local handles = ffi.new("const struct CadaclysmBlacksmithProfile *[?]", math.max(n, 1))
  for i = 1, n do handles[i - 1] = profile_handle(cutters[i], what) end
  return handles, n
end

--- This curve cut where the `cutters` (Profiles) cross, touch or run along it
--- -- the sketch trim's pieces: in order along the curve from its start, each an
--- open profile of portions of this one's own segments (a line's stretch a line,
--- an arc's an arc, a spline's the same spline over part of its domain). One
--- piece, this curve, where nothing cuts it; a closed curve's piece round its
--- start is one piece. Cuts closer than `tolerance` (default 1e-6) to each other
--- fold onto one. Raises `BuildError` for a curve with no segments.
function Profile:pieces(cutters, tolerance)
  if tolerance == nil then tolerance = 1e-6 end
  local handles, n = cutter_handles(cutters, "pieces")
  local count = lib().cadaclysm_blacksmith_profile_piece_count(self._handle, handles, n, tolerance)
  if count == 0 then fail("profile_piece_count") end
  local found = {}
  for i = 0, count - 1 do
    found[i + 1] = new_profile(lib().cadaclysm_blacksmith_profile_piece(self._handle, handles, n, i, tolerance))
  end
  return found
end

--- This curve with piece `piece` (from zero, of `pieces`) taken away -- the
--- sketch trim: what is left, as open profiles. One for a closed curve (its other
--- pieces run together from where the removed one ended), the stretches before
--- and after for an open one, none where the piece was the whole curve. Raises
--- `BuildError` for a piece the curve does not have.
function Profile:trim(cutters, piece, tolerance)
  if tolerance == nil then tolerance = 1e-6 end
  local handles, n = cutter_handles(cutters, "trim")
  local count = lib().cadaclysm_blacksmith_profile_trim_count(self._handle, handles, n, piece, tolerance)
  if count == 0 and last_error() ~= "" then fail("profile_trim_count") end
  local found = {}
  for i = 0, count - 1 do
    found[i + 1] = new_profile(lib().cadaclysm_blacksmith_profile_trim_chain(self._handle, handles, n, piece, i, tolerance))
  end
  return found
end

--- This outline with `hole` (a Profile) cut out of it.
function Profile:with_hole(hole)
  return new_profile(lib().cadaclysm_blacksmith_profile_with_hole(self._handle, profile_handle(hole, "with_hole")))
end

--- This profile moved by (`dx`, `dy`).
function Profile:translate(dx, dy)
  return new_profile(lib().cadaclysm_blacksmith_translate_profile(self._handle, dx, dy))
end

--- This outline coloured -- `colour` is "#rgb", "#rrggbb" or {r, g, b} in 0..1: how
--- it is drawn. The verbs that make a profile from one carry it; a solid made from it
--- takes nothing.
function Profile:coloured(colour)
  local r, g, b = rgb(colour)
  return new_profile(lib().cadaclysm_blacksmith_profile_coloured(self._handle, r, g, b))
end

--- The outline's colour, {r, g, b} in 0..1, or nil.
function Profile_get.colour(self)
  local out = ffi.new("double[3]")
  if lib().cadaclysm_blacksmith_profile_colour(self._handle, out) then return { out[0], out[1], out[2] } end
  if last_error() ~= "" then fail("profile_colour") end
  return nil
end

--- Where this profile's curves cross, touch or run along `other`'s, both read
--- in one plane, as an array of `Hit` records ordered along this profile.
--- Points closer than `tolerance` (default 1e-6) merge; two curves within
--- `tolerance` of each other for longer than it are one run when they part
--- only where one ends or the stretch is flat -- one curve following the
--- other, offset within `tolerance` or tilted by under about half of it, even
--- where it leaves mid-both; a tangency or a shallow crossing is one point. A
--- loop that stops short of its start is an open chain.
function Profile:hits(other, tolerance)
  if tolerance == nil then tolerance = 1e-6 end
  local h = lib().cadaclysm_blacksmith_profile_hits(self._handle, profile_handle(other, "hits"), tolerance)
  if h == nil then fail("profile_hits") end
  local ok, result = pcall(function()
    local n = lib().cadaclysm_blacksmith_hit_count(h)
    local raw = ffi.new("CadaclysmBlacksmithHit")
    local out = {}
    for i = 0, n - 1 do
      if not lib().cadaclysm_blacksmith_hit(h, i, raw) then fail("hit") end
      out[#out + 1] = M.Hit.of(raw)
    end
    return out
  end)
  lib().cadaclysm_blacksmith_hits_free(h)
  if not ok then error(result, 0) end
  return result
end

--- The region this profile and `other` share, both read in one plane, as an
--- array of zero or more profiles -- each boundary counter-clockwise, each
--- hole clockwise, arcs and splines kept exact. Both must be closed and
--- simple. No shared area is an empty array. Errors for a `tolerance`
--- (default 1e-6) not positive and finite, or a profile open or crossing
--- itself.
function Profile:common(other, tolerance)
  if tolerance == nil then tolerance = 1e-6 end
  return profile_list(lib().cadaclysm_blacksmith_profile_common(self._handle, profile_handle(other, "common"), tolerance), "profile_common")
end

--- `text` set in a font, one profile per closed shape -- a letter with its
--- counters as holes (`o` one, `8` two; `i` is two profiles) -- on the sketch
--- plane, the baseline along x from the origin, each outline counter-clockwise
--- and its holes clockwise, a curved side the font's own cubic Bezier kept
--- exactly: an extruded `O` has curved walls. `size` (default 10) is roughly
--- the height of a capital. `font` is a family, optionally with a style
--- (`"Liberation Sans:style=Bold"`), a font file's path, or nil/empty for the
--- bundled Liberation Sans Regular -- which also serves when the family is not
--- found; `font_bytes` (a string of bytes) a font file's contents, used instead
--- of `font` when given. `halign` is "left" (default), "center" or "right";
--- `valign` "baseline" (default), "bottom", "center" or "top"; `spacing`
--- (default 1) multiplies the gap between glyphs; `direction` "ltr" (default)
--- or "rtl". Empty text is an empty table. Raises a BuildError for a size or
--- spacing not positive and finite, an alignment or direction not one of those
--- words, font bytes that are not a font.
function Profile.text(text, size, font, halign, valign, spacing, direction, font_bytes)
  if size == nil then size = 10.0 end
  if spacing == nil then spacing = 1.0 end
  local bytes, count = nil, 0
  if font_bytes ~= nil then
    bytes = ffi.cast("const uint8_t *", font_bytes)
    count = #font_bytes
  end
  local h = lib().cadaclysm_blacksmith_profile_text(tostring(text), number(size, "size"), font == nil and "" or tostring(font),
    bytes, count, halign == nil and "left" or tostring(halign), valign == nil and "baseline" or tostring(valign),
    number(spacing, "spacing"), direction == nil and "ltr" or tostring(direction))
  return profile_list(h, "profile_text")
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
  if corners ~= nil then picked, count = uint32s(corners, "round", "corners") end
  return new_profile(lib().cadaclysm_blacksmith_profile_round(self._handle, radius, picked, count, open and true or false))
end

-- The kernel's profile_polylines, kept for the viewer follow-up (as Go keeps it): the
-- outline then each hole as polylines at z = 0 within `tolerance`, copied out -- a Lua
-- array of {x, y, z, x, y, z, ...} runs, one per loop -- since the library's arrays
-- belong to the profile and go stale when it is asked again at another tolerance.
local function profile_polylines(profile, tolerance)
  local p = lib().cadaclysm_blacksmith_profile_polylines(profile_handle(profile, "profile_polylines"), tolerance)
  if p.offsets == nil then fail("profile_polylines") end
  local out = {}
  for i = 0, p.polyline_count - 1 do
    local run = {}
    for k = 3 * p.offsets[i], 3 * p.offsets[i + 1] - 1 do run[#run + 1] = p.points[k] end
    out[i + 1] = run
  end
  return out
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

-- A path already begun elsewhere (`Profile.parabola`'s starter), taking over its handle.
function Path._from_handle(handle)
  return setmetatable({ _handle = ffi.gc(handle, free_path) }, Path)
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

--- A conic arc to (`x`, `y`) through the control point `control` ({cx, cy}) with
--- middle weight `weight`: under 1 an elliptical arc, 1 a parabola, over 1 a
--- hyperbola -- the rational quadratic Bezier, kept exact.
function Path:conic_to(x, y, control, weight)
  local cx, cy = pair(control, "control")
  return self:_step(lib().cadaclysm_blacksmith_path_conic_to(self:_live(), x, y, cx, cy, weight), "path_conic_to")
end

--- A parabolic arc to (`x`, `y`) whose end tangents meet at `control`: `conic_to`
--- with weight 1.
function Path:parabola_to(x, y, control)
  return self:conic_to(x, y, control, 1.0)
end

--- A hyperbolic arc to (`x`, `y`) through `control` with middle `weight` over 1.
function Path:hyperbola_to(x, y, control, weight)
  if not (weight > 1.0) then
    raise("hyperbola_to: the weight must be over 1 (1 is a parabola, under 1 an ellipse)")
  end
  return self:conic_to(x, y, control, weight)
end

--- The parabolic arc to (`x`, `y`) with `vertex` ({vx, vy}): its axis and focal
--- length solved from the two ends. Raises when no parabola with that vertex
--- passes through both.
function Path:parabola_by_vertex(x, y, vertex)
  local vx, vy = pair(vertex, "vertex")
  return self:_step(lib().cadaclysm_blacksmith_path_parabola_by_vertex(self:_live(), x, y, vx, vy), "path_parabola_by_vertex")
end

--- The parabolic arc to (`x`, `y`) with `focus` ({fx, fy}): of the two through the
--- ends, the one whose vertex lies between the ends' projections, then the one whose
--- arc cups the focus (the focus between the arc and its chord), then the more
--- symmetric; with the focus beyond the chord that is the arch over the ends, not the
--- shallow dish -- draw that one with `Profile.parabola`.
function Path:parabola_by_focus(x, y, focus)
  local fx, fy = pair(focus, "focus")
  return self:_step(lib().cadaclysm_blacksmith_path_parabola_by_focus(self:_live(), x, y, fx, fy), "path_parabola_by_focus")
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

-- ---- svg -------------------------------------------------------------------------------

--- The seven camera angles `svg_text`/`svg`'s `view=` understands, as (azimuth,
--- elevation) in degrees -- as the reader's own `cadaclysm.lua`.
local SVG_VIEWS = {
  front = { -90, 0 }, back = { 90, 0 }, left = { 180, 0 }, right = { 0, 0 },
  top = { -90, 90 }, bottom = { -90, -90 }, iso = { -50, 28 },
}

--- `CadaclysmBlacksmithSvgOptions.background`'s "none" value: no `<rect>`
--- behind the drawing. The reader library's own `CADACLYSM_SVG_TRANSPARENT`,
--- same value.
local SVG_TRANSPARENT = 0xffffffff

--- A colour as the ABI's packed `0xRRGGBB`: `"#rrggbb"` or a `{r, g, b}` table.
local function svg_colour(colour)
  if type(colour) == "string" then
    local hex = colour:gsub("^#", "")
    if #hex ~= 6 then raise(("colour '%s': '#rrggbb' or {r, g, b}"):format(colour)) end
    return tonumber(hex, 16)
  end
  return bit.bor(bit.lshift(math.floor(colour[1]), 16), bit.lshift(math.floor(colour[2]), 8), math.floor(colour[3]))
end

--- `words` packed into a `CadaclysmBlacksmithSvgOptions` -- as the reader's
--- own `svg_options`, but with no scene to default `up` from: a solid carries
--- no convention of its own, so `up=` falls back to `"z"` rather than a
--- scene's.
local function svg_options(words)
  words = words or {}
  local view = words.view or "iso"
  local angles = SVG_VIEWS[view]
  if not angles then
    raise(("view '%s': one of front, back, left, right, top, bottom, iso"):format(tostring(view)))
  end
  local o = ffi.new("CadaclysmBlacksmithSvgOptions")
  lib().cadaclysm_blacksmith_svg_options_init(o)
  o.up = tostring(words.up or "z"):lower() == "y" and 1 or 0
  o.azimuth = words.az ~= nil and words.az or angles[1]
  o.elevation = words.el ~= nil and words.el or angles[2]
  o.fov = words.fov or 0.0
  local size = words.size or { 1000, 1000 }
  o.width, o.height = size[1], size[2]
  o.margin = words.margin or 0.05
  o.tolerance = words.tolerance or 0.1
  o.stroke = words.stroke ~= nil and svg_colour(words.stroke) or 0x000000
  o.stroke_width = words.width or 1.0
  o.background = words.background ~= nil and svg_colour(words.background) or SVG_TRANSPARENT
  local edges = words.edges
  if edges == nil then edges = true end
  o.flags = bit.bor(edges and 1 or 0, words.curves and 2 or 0, words.isocurves and 4 or 0, words.polylines and 8 or 0)
  return o
end

--- `words` with `view` defaulted to `"top"` instead of `svg_options`'s own `"iso"` --
--- a profile lies in `z = 0`, so its own plane already is the page, unlike a solid's,
--- which has no plane of its own to prefer. A copy: the caller's own table is never
--- touched, and a `words.view` the caller did set (even `"iso"`) is kept as given.
local function profile_svg_words(words)
  local merged = { view = "top" }
  for k, v in pairs(words or {}) do merged[k] = v end
  return merged
end

-- ---- solids ---------------------------------------------------------------------------

--- An exact B-rep solid (or open sheet). Immutable; every operation returns a
--- new one. `close()` frees it; so does the garbage collector.
---@class Solid
local Solid = {}
local Solid_get = {}
class(Solid, Solid_get)
M.Solid = Solid

local Edge, Curve, Intersection, Chain, Overlap, SolidHits, Piece, Manifold, Selector

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

-- The profiles' handles and their frames' numbers, twelve each, for a loft through them.
local function sections_arg(sections, what)
  local n = #sections
  local handles = ffi.new("const struct CadaclysmBlacksmithProfile *[?]", math.max(n, 1))
  local frames = ffi.new("double[?]", math.max(12 * n, 1))
  for i = 1, n do
    handles[i - 1] = profile_handle(sections[i][1], what)
    local f = frame_arg(sections[i][2])
    for k = 0, 11 do frames[12 * (i - 1) + k] = f[k] end
  end
  return handles, frames, n
end

--- The solid smooth through every section -- `{profile, frame}` pairs, in order: each
--- wall interpolates its side across all the profiles (cubic through four or more,
--- quadratic through three, `loft` through two), capped by the first and the last.
function Solid.loft_through(sections)
  return new_solid(lib().cadaclysm_blacksmith_loft_through(sections_arg(sections, "loft_through")))
end

--- `loft_through` without the caps: the sheet through the curves.
function Solid.loft_through_open(sections)
  return new_solid(lib().cadaclysm_blacksmith_loft_through_open(sections_arg(sections, "loft_through_open")))
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

--- A circle of `radius` swept along `path`, square to its start: a
--- rod, or with a positive `thickness` (default 0) a tube whose walls
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
  local arr, n = uint32s(faces, "drop_faces", "faces")
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

--- This solid scaled by `factor` about the origin: every length times `factor`, exactly.
function Solid:scaled(factor)
  return new_solid(lib().cadaclysm_blacksmith_scaled(self:_h(), factor))
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

--- Where this solid's faces cross or coincide with `other`'s, at `tolerance`
--- (0.05), as an `Intersection`: `chains` along the curves the faces meet on and
--- `overlaps` where a face pair coincides. Neither solid is changed; either may be
--- an open sheet. No crossing is an empty result, never an error.
---
--- Each `Chain`'s points are within `tolerance` of both faces' exact surfaces;
--- there is one chain per face pair per branch -- chains are not joined across a
--- face boundary or a closed curve's seam, so join them by matching ends. A chain's
--- `curve` is its exact curve where the kernel found one every point lies within
--- `tolerance` of, else nil; `tangent` is set where the surfaces are near-tangent
--- along the chain or the snap did not settle (the points are then the best
--- estimate) -- a closed chain that does not go once round its own curve (a sliver
--- where two surfaces barely cross) has no curve, `tangent` still true. An `Overlap`
--- is a coincident face pair with the shared region's rings (outer first, holes
--- after), which may be empty for a partial overlap whose outlines cross. Known
--- limit: a crossing narrower than `tolerance` -- two surfaces passing within it
--- without their meshes crossing -- can be missed; near-tangent contact is where
--- this bites.
---
--- `progress(phase, done, total)` hears "mesh", "cull", "cross", "snap" and "curve".
--- Raises for a `tolerance` not positive and finite, a solid with no faces, or one
--- that meshes to nothing.
function Solid:intersect(other, tolerance, progress)
  if tolerance == nil then tolerance = 0.05 end
  local a, b = self:_h(), solid_handle(other)
  local L = lib()
  local cb, done = progress_callback(progress, function(h) L.cadaclysm_blacksmith_intersection_free(h) end)
  local h = done(L.cadaclysm_blacksmith_intersect(a, b, tolerance, cb, nil))
  if h == nil then fail("intersect") end
  local ok, result = pcall(function()
    local chains, raw, raw_curve = {}, ffi.new("CadaclysmBlacksmithChain"), ffi.new("CadaclysmBlacksmithCurve")
    for i = 0, L.cadaclysm_blacksmith_intersection_chain_count(h) - 1 do
      if not L.cadaclysm_blacksmith_intersection_chain(h, i, raw) then fail("intersection_chain") end
      local curve = nil
      if raw.has_curve then
        if not L.cadaclysm_blacksmith_intersection_curve(h, i, raw_curve) then fail("intersection_curve") end
        curve = Curve.of(raw_curve)
      end
      chains[#chains + 1] = Chain.of(raw, curve)
    end
    local overlaps, raw_overlap = {}, ffi.new("CadaclysmBlacksmithOverlap")
    for i = 0, L.cadaclysm_blacksmith_intersection_overlap_count(h) - 1 do
      if not L.cadaclysm_blacksmith_intersection_overlap(h, i, raw_overlap) then fail("intersection_overlap") end
      overlaps[#overlaps + 1] = Overlap.of(raw_overlap)
    end
    return Intersection.new(chains, overlaps)
  end)
  L.cadaclysm_blacksmith_intersection_free(h)
  if not ok then error(result, 0) end
  return result
end

--- Where `profile`, placed on `frame`, pierces this solid's faces, and the pieces
--- its loops cut into, at `tolerance` (0.05), as a `SolidHits`. Neither is changed.
---
--- A point hit lies within `tolerance` of the segment's exact curve and of the
--- face's exact surface, inside the face's trim; its profile spot (`a_start`:
--- loop, segment, t) and face spot (`b_start`: face, u, v) evaluate to the point
--- within `tolerance`; `touch` where the curve's tangent lies within 1e-3 (sine) of
--- the surface's tangent plane there (a graze), false at a crossing. A run is a
--- stretch of one segment lying within `tolerance` of one face and inside it,
--- longer than `tolerance`. Hits within `tolerance` of each other merge (a hit at a
--- segment join reported once, as (k, t = 1); a closed loop's closing join reads
--- (0, 0)). Every point is in world space (the
--- frame applied).
---
--- Pieces only for a closed body -- an open body has none -- in loop order,
--- covering every loop exactly; a piece's spots read a segment join as the next
--- segment's start (k + 1, 0), and an open chain runs from (0, 0) to (n - 1, 1); a
--- loop no hit cuts is one closed piece. `inside` by the piece middle's winding
--- number over the body's mesh; a piece lying on the surface is inside. Known
--- limit: a segment passing within `tolerance` of a face without crossing its mesh
--- can be missed (near-tangent grazes).
---
--- `progress(phase, done, total)` hears "mesh", "cull", "hits" and "pieces".
--- Raises for a `tolerance` not positive and finite, a solid with no faces or that
--- meshes to nothing, a profile with no segments, or a free-form segment that is
--- not an evaluable NURBS curve.
function Solid:hits(profile, frame, tolerance, progress)
  if tolerance == nil then tolerance = 0.05 end
  local s, p, f = self:_h(), profile_handle(profile, "hits"), frame_arg(frame)
  local L = lib()
  local cb, done = progress_callback(progress, function(h) L.cadaclysm_blacksmith_hits_free(h) end)
  local h = done(L.cadaclysm_blacksmith_solid_profile_hits(s, p, f, tolerance, cb, nil))
  if h == nil then fail("solid_profile_hits") end
  local ok, result = pcall(function()
    local hits, raw = {}, ffi.new("CadaclysmBlacksmithHit")
    for i = 0, L.cadaclysm_blacksmith_hit_count(h) - 1 do
      if not L.cadaclysm_blacksmith_hit(h, i, raw) then fail("hit") end
      hits[#hits + 1] = M.Hit.of(raw)
    end
    local pieces = {}
    local inside, start, end_ = ffi.new("bool[1]"), ffi.new("CadaclysmBlacksmithSpot"), ffi.new("CadaclysmBlacksmithSpot")
    for i = 0, L.cadaclysm_blacksmith_hits_piece_count(h) - 1 do
      if not L.cadaclysm_blacksmith_hits_piece(h, i, inside, start, end_) then fail("hits_piece") end
      local own = new_profile(L.cadaclysm_blacksmith_hits_piece_profile(h, i), "hits_piece_profile")
      pieces[#pieces + 1] = Piece.of(inside[0], start, end_, own)
    end
    return SolidHits.new(hits, pieces)
  end)
  L.cadaclysm_blacksmith_hits_free(h)
  if not ok then error(result, 0) end
  return result
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

--- `bounds_at` from the same tessellation's unnarrowed positions: exact far from
--- the origin, where `bounds_at`'s (widened from `float`) are not. Same cache as
--- `bounds_at` and `mesh`/`mesh64` -- a second call at the same tolerance costs
--- nothing extra.
function Solid:bounds_at64(tolerance)
  local lo, hi = ffi.new("double[3]"), ffi.new("double[3]")
  if not lib().cadaclysm_blacksmith_bounds64(self:_h(), tolerance, lo, hi) then fail("bounds64") end
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

-- -- naming

--- This solid, named `name`. The name rides through an operation with exactly
--- one source solid (`place`, `translate`, `rotate`, `mirror`, `scaled`,
--- `coloured`, `edges_coloured`, `fillet`, `chamfer`, `shell`, `thicken`,
--- `face_sheet`, `drop_faces`, `lump`, `trim`, `split_by_plane`, `push_pull`,
--- and so on) and is dropped by one with two or more sources (`join`, `cut`,
--- `common`, `split_sheet`, `split`) and by a fresh primitive or sweep. It is
--- what `Assembly:place` defaults a placement's own name to, and the product
--- name a lone named solid gets written into STEP (`step`/`step_text` --
--- SAT and OCCT `.brep` have no product name to set). Raises `BuildError` for
--- an empty name, or for `name` not a string.
function Solid:named(name)
  if type(name) ~= "string" then raise("named: expected a string, got " .. repr(name)) end
  return new_solid(lib().cadaclysm_blacksmith_named(self:_h(), name))
end

--- This solid's name, or nil, as `named` set it, kept or dropped by whatever
--- built this solid. **The library's borrowed pointer is null for both "no
--- name" and a failure**, so this never reads `last_error` -- the same rule
--- `text()` cannot honour (it maps null to `""`, losing the distinction), so
--- this checks the raw pointer itself rather than going through it.
function Solid_get.name(self)
  local raw = lib().cadaclysm_blacksmith_solid_name(self:_h())
  if raw == nil then return nil end
  return ffi.string(raw)
end

-- -- out

--- This solid meshed for a solver, as a `FemMesh`: nodes welded by bits, triangles
--- wound outward, each node tagged with the lowest-dimension B-rep entity it lies on,
--- and every crack reported rather than closed. **Owned by you**: `free()` it.
---
--- `tolerance` is the chordal tolerance in model units, finite and above zero (default
--- 0.01, not `mesh`'s 0.05 -- this is not the tessellation cache and shares nothing
--- with it), and **it alone governs how closely the mesh follows the geometry**.
--- `max_size` is a size ceiling, finite and zero or more (default 0, no ceiling --
--- curvature alone): **it bounds the boundary and targets the interior**, which is not a
--- longest-element-edge guarantee. It adds boundary nodes without refining boundary
--- geometry, and `FemMesh.longest_edge` is what the mesh actually came to -- the figure
--- to check against it. Those two defaults are `FemOptions::default()`'s own, restated
--- here so the signature says what a caller gets; the library's struct is still filled
--- by `cadaclysm_blacksmith_fem_options_init` first, so a field added to it later
--- defaults without this line being touched.
---
--- **Neither number is checked here**, on purpose: the reader library's `Node:fem_mesh`
--- has a path (a node with no brep) that takes no options at all and accepts any value,
--- and a wrapper that validated either field would refuse there what the library
--- allows. Both are passed through and the library's own refusal is what a caller sees
--- -- which on this side is every bad value, every solid here having a brep.
---
--- `placement` is a `Frame`, twelve numbers or four triples -- origin, x, y, z -- as
--- every frame here, and nil for the identity, a solid meshed in its own coordinates
--- being the common case; it is applied in double precision throughout. The reader's
--- `Node:fem_mesh` takes **sixteen**, column-major, so a caller moving between the two
--- reformats the placement.
---
--- `progress(phase, done, total)` hears **"meshing"** and **"welding"**. An opened phase
--- is not a promise of a closed one: a refused call opens no phase at all, and a solid
--- that meshes to no triangles reports "meshing" through to `1 of 1` and then raises
--- with no "welding". A callback that raises fails this call rather than the process,
--- as everywhere else here.
---
--- **A cracked body is not a failure**: it comes back with `FemMesh.watertight` false
--- and its cracks in `FemMesh.open_edges` / `FemMesh.folded_edges`, and nothing is
--- welded shut to make it look sound. Raises `BuildError` for a tolerance or `max_size`
--- the mesher refuses, a placement that is not twelve finite numbers or is not
--- invertible, a closed solid this module cannot mesh, and a solid that meshes to no
--- triangles.
---
--- **No unlicensed notice here**: `FemMesh:msh_text` and `FemMesh:save_msh` print it,
--- this library noticing on its writers rather than on its builders -- where the reader
--- library notices in its own constructor and on neither `.msh` call.
function Solid:fem_mesh(tolerance, max_size, placement, progress)
  local handle = self:_h()
  local frame = nil
  if placement ~= nil then frame = frame_arg(placement) end
  local o = ffi.new("struct CadaclysmBlacksmithFemOptions")
  lib().cadaclysm_blacksmith_fem_options_init(o)
  o.size = ffi.sizeof(o)
  o.tolerance = tolerance == nil and 0.01 or tolerance
  o.max_size = max_size == nil and 0.0 or max_size
  local cb, done = progress_callback(progress, free_fem_mesh)
  local h = done(lib().cadaclysm_blacksmith_fem_mesh(handle, frame, o, cb, nil))
  if h == nil then fail("fem_mesh") end
  return fem_mesh(h)
end

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

--- `mesh` in `double`: the very same tessellation at `tolerance` (default 0.05,
--- same cache, same generation, same index view) with `positions`/`normals`
--- unnarrowed -- three views (float64 (n, 3), float64 (n, 3), uint32 (m)). Exact
--- far from the origin, where `mesh`'s `float` positions are not.
function Solid:mesh64(tolerance)
  if tolerance == nil then tolerance = 0.05 end
  local m = lib().cadaclysm_blacksmith_mesh64(self:_h(), tolerance)
  if m.positions == nil then fail("mesh64") end
  local generation = self:_filled(tolerance)
  local n = m.vertex_count
  return view(self, generation, m.positions, { n, 3 }, "float64"),
    view(self, generation, m.normals, { n, 3 }, "float64"),
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

-- The kernel's mesh_face_triangles, kept for the viewer follow-up (as Go keeps it): how
-- many triangles each face meshed to at `tolerance`, in face order, summing to `mesh`'s
-- triangle count at the same tolerance -- copied out into a Lua array of numbers.
local function mesh_face_triangles(solid, tolerance)
  local t = lib().cadaclysm_blacksmith_mesh_face_triangles(solid:_h(), tolerance)
  if t.counts == nil then fail("mesh_face_triangles") end
  local out = {}
  for i = 0, t.face_count - 1 do out[i + 1] = t.counts[i] end
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

--- This solid as ACIS SAT text; `unit` "mm" (default), "m" or "in". See
--- `write_sat_text`.
function Solid:sat_text(unit)
  if unit == nil then unit = "mm" end
  return M.write_sat_text({ self }, unit)
end

--- Write this solid to an ACIS SAT file at `path`, by the library itself; `unit`
--- as `sat_text`.
function Solid:sat(path, unit)
  if unit == nil then unit = "mm" end
  M.write_sat(path, { self }, unit)
end

--- This solid as OCCT `.brep` text; see `write_brep_text`.
function Solid:brep_text()
  return M.write_brep_text({ self })
end

--- Write this solid to a `.brep` file at `path`, by the library itself.
function Solid:brep(path)
  M.write_brep(path, { self })
end

--- This solid's wireframe as SVG text, from the camera `words` describes --
--- the library's own camera, not a viewer. See `write_svg_text`.
function Solid:svg_text(words)
  return M.write_svg_text({ self }, words)
end

--- This solid written to an SVG file at `path`, by the library itself.
function Solid:svg(path, words)
  M.write_svg(path, { self }, words)
end

--- This profile's own loops as SVG text, from the camera `words` describes, `view`
--- defaulting to `"top"` -- see `profile_svg_words`. See `write_svg_text`.
function Profile:svg_text(words)
  return M.write_svg_text({ self }, profile_svg_words(words))
end

--- This profile written to an SVG file at `path`, by the library itself; see
--- `Profile:svg_text` for the `top` default.
function Profile:svg(path, words)
  M.write_svg(path, { self }, profile_svg_words(words))
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

--- Face `face` by what it is, eight numbers: the surface's kind (plane 0,
--- cylinder 1, cone 2, sphere 3, torus 4, NURBS 5, revolution 6, extrusion 7,
--- sum 8), a point on the surface at the face's middle (x y z), the outward
--- normal there (x y z), and the face's extent -- what a feature made on the
--- face keeps, to find the face again with `find_face` when the solid has been
--- rebuilt with its faces moved, split or renumbered. Take it before any move
--- you apply to the solid, and look it up on the unmoved one.
function Solid:face_ref(face)
  local out = ffi.new("double[8]")
  if not lib().cadaclysm_blacksmith_face_ref(self:_h(), face, out) then fail("face_ref") end
  local t = {}
  for i = 0, 7 do t[i + 1] = out[i] end
  return t
end

--- The face `face_ref` (from `face_ref`) refers to: among the faces of that
--- kind whose surface passes through the point, facing the same way, the one
--- the point lies in -- or, where it lies in none, the one whose boundary
--- comes nearest. `hint` is the index the face had, preferred among faces that
--- fit equally well; `tolerance` (default 1e-3) how far the point may sit off
--- a surface to still be on it. Nil where the face is gone.
function Solid:find_face(face_ref, hint, tolerance)
  if #face_ref ~= 8 then raise("find_face: a face reference is eight numbers") end
  local ref = ffi.new("double[8]", face_ref)
  local found = lib().cadaclysm_blacksmith_find_face(self:_h(), ref, hint == nil and -1 or hint, tolerance or 1e-3)
  if found == -2 then fail("find_face") end
  if found < 0 then return nil end
  return found
end

-- edge_indices is needed by both fillet/chamfer and edges_coloured, so it is defined
-- once here, ahead of the colour section that is the first to use it.
local function edge_indices(edges, call)
  return uint32s(edges, call, "edges", true)
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

--- This solid with its edges coloured: every edge, or with `edges` (`Edge` records or
--- indices, as `fillet` takes them) just those, whose colour then wins over the
--- all-edges one; an empty list colours none. Inherited as face colours are.
function Solid:edges_coloured(colour, edges)
  local r, g, b = rgb(colour)
  if edges == nil then
    return new_solid(lib().cadaclysm_blacksmith_edges_coloured(self:_h(), nil, 0, r, g, b))
  end
  -- edge_indices -> uint32s never returns a null pointer, even for {}: a non-null
  -- pointer with count 0 is "none", as the C ABI reads it.
  local arr, n = edge_indices(edges, "edges_coloured")
  return new_solid(lib().cadaclysm_blacksmith_edges_coloured(self:_h(), arr, n, r, g, b))
end

--- Edge `edge`'s (an `Edge` or its index) colour as drawn -- its own, else the solid's
--- edge colour -- or nil.
function Solid:edge_colour(edge)
  local index = (type(edge) == "table" and getmetatable(edge) == Edge) and edge.index or edge
  local out = ffi.new("double[3]")
  if lib().cadaclysm_blacksmith_edge_colour(self:_h(), index, out) then return { out[0], out[1], out[2] } end
  if last_error() ~= "" then fail("edge_colour") end
  return nil
end

--- A colour per polyline of `edge_polylines(tolerance)`, as drawn: {r, g, b}, or
--- `false` for a polyline on no coloured edge (a Lua array holds no nil); an empty
--- array where the solid has no edge paint at all. Copied out.
function Solid:edge_polyline_colours(tolerance)
  if tolerance == nil then tolerance = 0.05 end
  local c = lib().cadaclysm_blacksmith_edge_polyline_colours(self:_h(), tolerance)
  if c.rgb == nil and last_error() ~= "" then fail("edge_polyline_colours") end
  -- This call tessellates like every other cache reader, even to report "no paint": it can
  -- replace the cache a view taken earlier is still borrowing, so it must bump the
  -- generation those views check, even though this method copies its own result out and
  -- keeps nothing borrowed itself.
  self:_filled(tolerance)
  if c.rgb == nil then return {} end
  local out = {}
  for i = 0, c.count - 1 do
    local v = c.rgb + 3 * i
    -- Not `v[0] < 0 and false or {...}`: `false` is falsy, so that is always the table.
    if v[0] < 0 then
      out[i + 1] = false
    else
      out[i + 1] = { v[0], v[1], v[2] }
    end
  end
  return out
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
    out[i + 1] = Edge.new(i, text(raw.kind), faces, segments, Solid._edge_curve(L, h, i))
  end
  return out
end

-- Edge `i`'s exact curve copied out, or nil for an edge with none (the library's
-- "has no exact curve"); any other refusal is raised.
function Solid._edge_curve(L, h, i)
  local raw = ffi.new("CadaclysmBlacksmithCurve")
  if L.cadaclysm_blacksmith_edge_curve(h, i, raw) then return Curve.of(raw) end
  if last_error():find("has no exact curve", 1, true) then return nil end
  fail("edge_curve")
end

--- The edges (`Edge` records or their indices) rounded by `radius`.
--- `tolerance` defaults to 1e-6; `progress` as `join`'s.
function Solid:fillet(edges, radius, tolerance, progress)
  if tolerance == nil then tolerance = 1e-6 end
  local arr, n = edge_indices(edges, "fillet")
  local a = self:_h()
  local cb, done = progress_callback(progress)
  local h = done(lib().cadaclysm_blacksmith_fillet(a, arr, n, radius, tolerance, cb, nil))
  return new_solid(h)
end

--- `fillet` with a flat bevel: each edge cut back `distance` along both its faces.
function Solid:chamfer(edges, distance, tolerance)
  if tolerance == nil then tolerance = 1e-6 end
  local arr, n = edge_indices(edges, "chamfer")
  return new_solid(lib().cadaclysm_blacksmith_chamfer(self:_h(), arr, n, distance, tolerance))
end

--- Face `face` pushed out by `distance` along its outward normal (pulled in,
--- negative) as a face extrude does it: the prism joined on (cut
--- out) and the flush faces merged. A face on a cylinder, cone, sphere or torus
--- moves out along its normal instead. `tolerance` (default 0.05) and `progress`
--- as `join`'s.
---
--- `face` may be a list of faces, pushed together as a press-pull on a
--- selection: each by its own rule, one after another, each found again after the
--- pushes before it renumbered the faces -- a box's top and a side pushed 5 is the
--- box 5 taller and 5 wider. A face on the same curved surface as one before it, and
--- joined to it, moved with that one and is not pushed twice.
function Solid:push_pull(face, distance, tolerance, progress)
  if tolerance == nil then tolerance = 0.05 end
  local a = self:_h()
  local cb, done = progress_callback(progress)
  local h
  local is_edge = named.Edge and type(face) == "table" and getmetatable(face) == named.Edge
  if type(face) == "number" then
    if face < 0 or face > 4294967295 or face ~= math.floor(face) then
      raise(("push_pull: face must be a face index or a list of indices, not %s"):format(repr(face)))
    end
    h = done(lib().cadaclysm_blacksmith_push_pull(a, face, distance, tolerance, cb, nil))
  elseif face == nil or type(face) == "string" or is_edge then
    local thing = is_edge and "an Edge" or repr(face)
    raise(("push_pull: face must be a face index or a list of indices, not %s"):format(thing))
  else
    local arr, n = uint32s(face, "push_pull", "face")
    h = done(lib().cadaclysm_blacksmith_push_pull_faces(a, arr, n, distance, tolerance, cb, nil))
  end
  return new_solid(h)
end

--- This solid split by `tool` into bodies (a Lua array):
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

--- The round `face` belongs to made again at `radius` -- a press-pull on
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
  local arr, n = uint32s(open, "shell", "open")
  local a = self:_h()
  local cb, done = progress_callback(progress)
  local h = done(lib().cadaclysm_blacksmith_shell(a, thickness, arr, n, tolerance, cb, nil))
  return new_solid(h)
end

--- This sheet made a solid `thickness` thick: its faces,
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

--- One edge's, or one intersection chain's, exact curve as plain data copied out
--- (`Edge.curve`, `Chain.curve`): `kind` is "line", "circle", "ellipse", "parabola", "hyperbola" or "nurbs".
---
--- `t0..t1` is the edge's parameter range on its own curve: a line's fraction
--- (0..1 over `origin -> origin + x`, where `x` is the full `to - from`, NOT unit
--- -- so `point(t) = origin + x*t`); a circle's or ellipse's angle in radians
--- about `origin` in the `x, y` plane (`point(t) = origin + x*radius*cos(t) +
--- y*radius2*sin(t)`, `radius2 = radius` for a circle); a NURBS's knot parameter
--- (`knots[degree] <= t0 < t1 <= knots[n]`). Frame vectors `x, y, z` are unit
--- for conics; for a line `x` is the direction with length = the line's length
--- and `y, z` are zero.
---
--- For a NURBS the frame is zero and so are the radii; for a conic or a line
--- `degree` is 0 and `knots`, `poles` are empty. `#knots == #poles + degree + 1`
--- (Lua arrays from 1; the convention above indexes from zero); `weights` is one
--- per pole, or nil for a non-rational (plain B-spline) curve, a conic or a line.
---@class Curve
---@field kind string
---@field origin number[]  {x, y, z}
---@field x number[]  {x, y, z}
---@field y number[]  {x, y, z}
---@field z number[]  {x, y, z}
---@field radius number
---@field radius2 number
---@field t0 number
---@field t1 number
---@field degree integer
---@field knots number[]
---@field poles table[]  {{x, y, z}, ...}
---@field weights number[]|nil
Curve = {}
class(Curve)
callable(Curve)
M.Curve = Curve

function Curve.new(kind, origin, x, y, z, radius, radius2, t0, t1, degree, knots, poles, weights)
  return setmetatable({ kind = kind, origin = origin, x = x, y = y, z = z, radius = radius, radius2 = radius2,
    t0 = t0, t1 = t1, degree = degree, knots = knots, poles = poles, weights = weights }, Curve)
end

-- A `Curve` copied out of the library's struct.
function Curve.of(raw)
  local function point(p) return { tonumber(p.x), tonumber(p.y), tonumber(p.z) } end
  local function doubles(at, n)
    local out = {}
    if at ~= nil then for j = 0, n - 1 do out[j + 1] = tonumber(at[j]) end end
    return out
  end
  local n = tonumber(raw.pole_count)
  local flat, poles = doubles(raw.poles, 3 * n), {}
  for k = 1, n do poles[k] = { flat[3 * k - 2], flat[3 * k - 1], flat[3 * k] } end
  local weights = nil
  if raw.weights ~= nil then weights = doubles(raw.weights, n) end
  return Curve.new(text(raw.kind), point(raw.origin), point(raw.x), point(raw.y), point(raw.z), tonumber(raw.radius),
    tonumber(raw.radius2), tonumber(raw.t0), tonumber(raw.t1), tonumber(raw.degree),
    doubles(raw.knots, tonumber(raw.knot_count)), poles, weights)
end

Curve.__tostring = function(self)
  if self.kind == "nurbs" then
    return ("Curve('nurbs', degree=%d, poles=%d, rational=%s, t0=%s, t1=%s)"):format(self.degree, #self.poles,
      tostring(self.weights ~= nil), tostring(self.t0), tostring(self.t1))
  end
  local o = self.origin
  return ("Curve('%s', origin=(%s, %s, %s), radius=%s, t0=%s, t1=%s)"):format(self.kind, tostring(o[1]), tostring(o[2]),
    tostring(o[3]), tostring(self.radius), tostring(self.t0), tostring(self.t1))
end

--- One edge of a solid, as plain data: `index` (what `fillet` takes, from zero),
--- `kind` (the curve), `faces` (the faces meeting on it, indices from zero),
--- `segments` ({{a, b}, ...}, each end a triple) and `curve` (the exact `Curve`,
--- nil for an edge with none, kind "other").
---@class Edge
---@field index integer  from zero
---@field kind string
---@field faces integer[]  from zero
---@field segments table[]  {{a, b}, ...}, each end {x, y, z}
---@field curve Curve|nil
Edge = {}
named.Edge = Edge
local Edge_get = {}
class(Edge, Edge_get)
callable(Edge)
M.Edge = Edge

function Edge.new(index, kind, faces, segments, curve)
  return setmetatable({ index = index, kind = kind, faces = faces, segments = segments, curve = curve }, Edge)
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

--- Where a hit lands on one side: a profile's `loop_index` (0 the boundary or
--- the open chain, then the holes in the order they were added), `segment`, and
--- `t` from 0 to 1 along it, with `face` NONE -- or a solid's `face` at (`u`,
--- `v`), with `loop_index` and `segment` NONE. Indices count from zero, as the
--- library does.
---@class Spot
---@field loop_index integer  from zero; NONE on a face
---@field segment integer  from zero; NONE on a face
---@field t number
---@field face integer  NONE on a profile
---@field u number
---@field v number
local Spot = {}
class(Spot)
callable(Spot)
M.Spot = Spot

function Spot.new(loop_index, segment, t, face, u, v)
  return setmetatable({ loop_index = loop_index, segment = segment, t = t, face = face, u = u, v = v }, Spot)
end

Spot.__tostring = function(self)
  return ("Spot(loop_index=%d, segment=%d, t=%s, face=%d, u=%s, v=%s)"):format(self.loop_index, self.segment,
    tostring(self.t), self.face, tostring(self.u), tostring(self.v))
end

--- One place two curves meet, copied out (`Profile:hits`). A point (`run`
--- false): `start` equals `end` ({x, y, z}), and `touch` is true where the
--- curves are tangent rather than crossing. A run (`run` true): they coincide
--- from `start` to `end`. `a_start`/`a_end` are where on the first curve,
--- `b_start`/`b_end` where on the second, as `Spot` records. A point at the
--- join of two segments is reported once, on either: as segment k at `t` 1 or
--- as segment k + 1 at `t` 0.
-- `n` xyz triples at `at`, copied out as {x, y, z} triples.
local function points_at(at, n)
  local out = {}
  if at ~= nil then
    for k = 0, n - 1 do out[k + 1] = { tonumber(at[3 * k]), tonumber(at[3 * k + 1]), tonumber(at[3 * k + 2]) } end
  end
  return out
end

--- What `Solid:intersect` found, copied out: `chains` (one per face pair per
--- branch) and `overlaps` (one per coincident face pair). Both empty where the
--- solids do not meet.
---@class Intersection
---@field chains Chain[]
---@field overlaps Overlap[]
Intersection = {}
class(Intersection)
callable(Intersection)
M.Intersection = Intersection

function Intersection.new(chains, overlaps)
  return setmetatable({ chains = chains, overlaps = overlaps }, Intersection)
end

Intersection.__tostring = function(self)
  return ("Intersection(chains=%d, overlaps=%d)"):format(#self.chains, #self.overlaps)
end

--- One branch of one face pair's crossing (`Intersection.chains`): `points`
--- ({x, y, z} triples in walk order; a closed chain does not repeat its first
--- point), `closed`, `faces` ({face in a, face in b}, indices from zero), `tangent`
--- (the surfaces near-tangent along it, or the snap unsettled -- the points their
--- best estimate) and `curve`, its exact `Curve` over the chain's own `t0..t1`, or
--- nil where the kernel found none. A chain may stop at a face boundary or a closed
--- curve's seam and continue as another: join chains by matching ends.
---@class Chain
---@field points table[]  {{x, y, z}, ...}
---@field closed boolean
---@field faces integer[]  {face in a, face in b}, from zero
---@field tangent boolean
---@field curve Curve|nil
Chain = {}
class(Chain)
callable(Chain)
M.Chain = Chain

function Chain.new(points, closed, faces, tangent, curve)
  return setmetatable({ points = points, closed = closed, faces = faces, tangent = tangent, curve = curve }, Chain)
end

-- A `Chain` copied out of the library's struct, with its curve already read.
function Chain.of(raw, curve)
  return Chain.new(points_at(raw.points, tonumber(raw.point_count)), raw.closed,
    { tonumber(raw.face_a), tonumber(raw.face_b) }, raw.tangent, curve)
end

Chain.__tostring = function(self)
  return ("Chain(points=%d, closed=%s, faces=(%d, %d), tangent=%s, curve=%s)"):format(#self.points,
    tostring(self.closed), self.faces[1], self.faces[2], tostring(self.tangent), tostring(self.curve))
end

--- A face of `a` and a face of `b` that coincide (`Intersection.overlaps`):
--- `faces` ({face in a, face in b}, indices from zero) and `loops`, the shared
--- region's rings as tables of {x, y, z} triples (outer first, holes after; each
--- ring closed without repeating its first point) -- empty for a partial overlap
--- whose outlines cross.
---@class Overlap
---@field faces integer[]  {face in a, face in b}, from zero
---@field loops table[]  {{{x, y, z}, ...}, ...}
Overlap = {}
class(Overlap)
callable(Overlap)
M.Overlap = Overlap

function Overlap.new(faces, loops)
  return setmetatable({ faces = faces, loops = loops }, Overlap)
end

-- An `Overlap` copied out of the library's struct: ring `r` runs from
-- `loop_offsets[r]` to the next start, the last to `point_count`.
function Overlap.of(raw)
  local points, n = points_at(raw.points, tonumber(raw.point_count)), tonumber(raw.loop_count)
  local loops = {}
  for r = 0, n - 1 do
    local first = tonumber(raw.loop_offsets[r])
    local last = r + 1 < n and tonumber(raw.loop_offsets[r + 1]) or tonumber(raw.point_count)
    local ring = {}
    for k = first + 1, last do ring[#ring + 1] = points[k] end
    loops[r + 1] = ring
  end
  return Overlap.new({ tonumber(raw.face_a), tonumber(raw.face_b) }, loops)
end

Overlap.__tostring = function(self)
  return ("Overlap(faces=(%d, %d), loops=%d)"):format(self.faces[1], self.faces[2], #self.loops)
end

---@class Hit
---@field run boolean
---@field touch boolean
---@field start number[]  {x, y, z}
---@field end number[]  {x, y, z}; `start` again for a point
---@field a_start Spot
---@field a_end Spot
---@field b_start Spot
---@field b_end Spot
local Hit = {}
class(Hit)
callable(Hit)
M.Hit = Hit

function Hit.new(run, touch, start, end_, a_start, a_end, b_start, b_end)
  return setmetatable({ run = run, touch = touch, start = start, ["end"] = end_, a_start = a_start, a_end = a_end,
    b_start = b_start, b_end = b_end }, Hit)
end

local function spot_of(raw)
  return Spot.new(tonumber(raw.loop_index), tonumber(raw.segment), tonumber(raw.t), tonumber(raw.face),
    tonumber(raw.u), tonumber(raw.v))
end

-- A `Hit` copied out of the library's struct.
function Hit.of(raw)
  return Hit.new(raw.run, raw.touch, { tonumber(raw.start.x), tonumber(raw.start.y), tonumber(raw.start.z) },
    { tonumber(raw["end"].x), tonumber(raw["end"].y), tonumber(raw["end"].z) }, spot_of(raw.a_start),
    spot_of(raw.a_end), spot_of(raw.b_start), spot_of(raw.b_end))
end

--- What `Solid:hits` found, copied out: `hits` (`Hit` records ordered along the
--- profile; `a_start`/`a_end` on the profile, `b_start`/`b_end` on the solid's
--- faces: a `face` at (`u`, `v`)) and `pieces` (`Piece` records, empty for an open
--- body).
---@class SolidHits
---@field hits Hit[]
---@field pieces Piece[]
SolidHits = {}
class(SolidHits)
callable(SolidHits)
M.SolidHits = SolidHits

function SolidHits.new(hits, pieces)
  return setmetatable({ hits = hits, pieces = pieces }, SolidHits)
end

SolidHits.__tostring = function(self)
  return ("SolidHits(hits=%d, pieces=%d)"):format(#self.hits, #self.pieces)
end

--- One stretch of a profile loop between two cuts (`SolidHits.pieces`): `inside`
--- (by its middle's winding number over the body; a piece lying on the surface is
--- inside), `start`/`end` (profile `Spot` records -- a segment join reads as the
--- next segment's start (k + 1, 0), an open chain runs from (0, 0) to (n - 1, 1); a
--- loop no hit cuts is one closed piece) and `profile`, the piece's own open chain
--- (what `SweepPath.along` with `open` sweeps).
---@class Piece
---@field inside boolean
---@field start Spot
---@field end Spot
---@field profile Profile
Piece = {}
class(Piece)
callable(Piece)
M.Piece = Piece

function Piece.new(inside, start, end_, profile)
  return setmetatable({ inside = inside, start = start, ["end"] = end_, profile = profile }, Piece)
end

-- A `Piece` copied out of the library's out-parameters, with its profile already read.
function Piece.of(inside, start, end_, profile)
  return Piece.new(inside, spot_of(start), spot_of(end_), profile)
end

Piece.__tostring = function(self)
  return ("Piece(inside=%s, start=%s, end=%s)"):format(tostring(self.inside), tostring(self.start),
    tostring(self["end"]))
end

Hit.__tostring = function(self)
  local s, e = self.start, self["end"]
  return ("Hit(run=%s, touch=%s, start=(%s, %s, %s), end=(%s, %s, %s))"):format(tostring(self.run),
    tostring(self.touch), tostring(s[1]), tostring(s[2]), tostring(s[3]), tostring(e[1]), tostring(e[2]),
    tostring(e[3]))
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

--- The plane midway between the planes of frames a and b: halfway between parallel planes, on a's axes; for planes that meet, the plane bisecting them through the line they meet on, its x along that line.
function Frame.midplane(a, b)
  local out = ffi.new("double[12]")
  if not lib().cadaclysm_blacksmith_frame_midplane(frame_arg(a), frame_arg(b), out) then fail("frame_midplane") end
  return Frame.of({ out[0], out[1], out[2], out[3], out[4], out[5], out[6], out[7], out[8], out[9], out[10], out[11] })
end

--- The plane through three points: its origin p, its x towards q, its z the normal they turn about counter-clockwise. Raises `BuildError` for three points on one line.
function Frame.through(p, q, r)
  local out = ffi.new("double[12]")
  if not lib().cadaclysm_blacksmith_frame_through(doubles(p, 3, "p"), doubles(q, 3, "q"), doubles(r, 3, "r"), out) then
    fail("frame_through")
  end
  return Frame.of({ out[0], out[1], out[2], out[3], out[4], out[5], out[6], out[7], out[8], out[9], out[10], out[11] })
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

--- Several solids (a Lua array) as one ACIS SAT file's text, each its own body:
--- the analytic surfaces as their own records, splines and swept surfaces as
--- exact NURBS, in the layout Rhino's own exporter writes. `unit` "mm"
--- (default), "m" or "in" goes into the header as millimetres per unit.
function M.write_sat_text(solids, unit)
  if unit == nil then unit = "mm" end
  if UNITS[unit] == nil then raise("unit must be one of ['in', 'm', 'mm']") end
  local n = #solids
  local handles = ffi.new("const struct CadaclysmBlacksmithSolid *[?]", math.max(n, 1))
  for i = 1, n do handles[i - 1] = solid_handle(solids[i], "write_sat_text") end
  local out = lib().cadaclysm_blacksmith_sat_text(handles, n, UNITS[unit])
  if out == nil then fail("sat_text") end
  local result = ffi.string(out)
  lib().cadaclysm_blacksmith_string_free(out)
  return result
end

--- `write_sat_text` written to `path` by the library itself, which names the
--- file in its refusal when it cannot.
function M.write_sat(path, solids, unit)
  if unit == nil then unit = "mm" end
  if UNITS[unit] == nil then raise("unit must be one of ['in', 'm', 'mm']") end
  local n = #solids
  local handles = ffi.new("const struct CadaclysmBlacksmithSolid *[?]", math.max(n, 1))
  for i = 1, n do handles[i - 1] = solid_handle(solids[i], "write_sat") end
  if not lib().cadaclysm_blacksmith_sat(handles, n, tostring(path), UNITS[unit]) then fail("sat") end
end

--- One OCCT `.brep` file's text, each solid its own solid under one compound (one
--- solid is the file's root): the exact surfaces and curves, with a curve in each
--- face's own parameters for every edge, so OCCT's `BRepTools::Read` gives a shape
--- `BRepCheck_Analyzer` finds valid. No unit is declared -- a `.brep` carries none.
function M.write_brep_text(solids)
  local n = #solids
  local handles = ffi.new("const struct CadaclysmBlacksmithSolid *[?]", math.max(n, 1))
  for i = 1, n do handles[i - 1] = solid_handle(solids[i], "write_brep_text") end
  local out = lib().cadaclysm_blacksmith_brep_text(handles, n)
  if out == nil then fail("brep_text") end
  local result = ffi.string(out)
  lib().cadaclysm_blacksmith_string_free(out)
  return result
end

--- `write_brep_text` written to `path` by the library itself.
function M.write_brep(path, solids)
  local n = #solids
  local handles = ffi.new("const struct CadaclysmBlacksmithSolid *[?]", math.max(n, 1))
  for i = 1, n do handles[i - 1] = solid_handle(solids[i], "write_brep") end
  if not lib().cadaclysm_blacksmith_brep(handles, n, tostring(path)) then fail("brep") end
end

-- ---- assemblies -----------------------------------------------------------------------

local function free_assembly(a) lib().cadaclysm_blacksmith_assembly_free(a) end

--- A mutable tree of placements: a name, and zero or more solids or other
--- assemblies placed in it at a frame. Unlike `Solid`, placing shares rather
--- than copies -- placing one assembly under another does not snapshot it, so
--- a later placement on the shared one shows up wherever it already sits.
--- `close()` frees this handle; it does not free what was placed in it if
--- that is still reachable from somewhere else (another assembly, or a
--- variable still holding it). `Assembly.new(name)` or `Assembly(name)`.
---@class Assembly
local Assembly = {}
local Assembly_get = {}
class(Assembly, Assembly_get)
callable(Assembly)
M.Assembly = Assembly

--- A new, empty assembly called `name`. Raises `BuildError` for `name` not a string.
function Assembly.new(name)
  if type(name) ~= "string" then raise("Assembly.new: expected a string, got " .. repr(name)) end
  local h = checked(lib().cadaclysm_blacksmith_assembly_new(name), "assembly_new")
  return setmetatable({ _handle = ffi.gc(h, free_assembly) }, Assembly)
end

function Assembly:_h()
  local h = rawget(self, "_handle")
  if h == nil then raise("assembly: closed") end
  return h
end

--- This assembly's own name, given when it was made.
function Assembly_get.name(self)
  return text(lib().cadaclysm_blacksmith_assembly_name(self:_h()))
end

--- Place `thing` (a `Solid` or another `Assembly`) at `frame` (twelve numbers,
--- four triples or a `Frame`, right-handed and orthonormal) in this assembly,
--- called `name` -- or, left nil, `thing`'s own name (`Solid.name`, or
--- "part" for an unnamed solid, or the placed assembly's own name), numbered
--- past any already taken here ("bolt", "bolt 2", ...). An explicit `name`
--- already taken here raises `BuildError`. Placing an assembly that is this
--- one, or anywhere above this one in the tree already, raises, naming the
--- cycle, since writing that out would never terminate. Returns the
--- placement's name.
function Assembly:place(thing, frame, name)
  if name ~= nil and type(name) ~= "string" then raise("assembly: place's name must be nil or a string, got " .. repr(name)) end
  local f = frame_arg(frame)
  local h = self:_h()
  local raw, what
  if type(thing) == "table" and getmetatable(thing) == Solid then
    raw = lib().cadaclysm_blacksmith_assembly_place_solid(h, thing:_h(), f, name)
    what = "assembly_place_solid"
  elseif type(thing) == "table" and getmetatable(thing) == Assembly then
    raw = lib().cadaclysm_blacksmith_assembly_place_assembly(h, thing:_h(), f, name)
    what = "assembly_place_assembly"
  else
    raise("assembly: place takes a Solid or an Assembly, got " .. repr(thing))
  end
  if raw == nil then fail(what) end
  local result = ffi.string(raw)
  lib().cadaclysm_blacksmith_string_free(raw)
  return result
end

--- This assembly, and everything placed under it, as one STEP file: this
--- assembly the root product, each sub-assembly and each distinct part (the
--- same solid with the same paint and name) written once, each placement an
--- occurrence named as it was placed. `schema` and `unit` as
--- `write_step_text`. Raises `BuildError` where this assembly, or a
--- sub-assembly reachable from it, places nothing -- a reader would never
--- show it.
function Assembly:step_text(schema, unit)
  if unit == nil then unit = "mm" end
  if UNITS[unit] == nil then raise("unit must be one of ['in', 'm', 'mm']") end
  local out = lib().cadaclysm_blacksmith_assembly_step(self:_h(), schema_text(schema), UNITS[unit])
  if out == nil then fail("assembly_step") end
  local result = ffi.string(out)
  lib().cadaclysm_blacksmith_string_free(out)
  return result
end

--- Write this assembly to a STEP file at `path`; `schema` and `unit` as `step_text`.
function Assembly:step(path, schema, unit)
  if unit == nil then unit = "mm" end
  write_text(path, self:step_text(schema, unit))
end

--- This assembly as a reader `Scene`, through STEP text and
--- `cadaclysm.open_memory` -- `Solid:to_scene`'s own door, over the whole
--- tree instead of one solid. Needs cadaclysm.lua and its library.
function Assembly:to_scene(schema)
  local cadaclysm = reader("to_scene")
  return cadaclysm.open_memory(self:step_text(schema), "stp", schema_file(schema))
end

--- Free the handle now. Idempotent; does not free what was placed here if it
--- is still reachable from elsewhere. The garbage collector does it
--- otherwise.
function Assembly:close()
  local h = rawget(self, "_handle")
  if h ~= nil then
    self._handle = nil
    ffi.gc(h, nil)
    free_assembly(h)
  end
end

Assembly.__tostring = function(self)
  if rawget(self, "_handle") == nil then return "Assembly(closed)" end
  return ("Assembly(%q)"):format(self.name)
end

-- ---- SVG ----------------------------------------------------------------------------

--- `things` (a Lua array, any mix of `Solid` and `Profile`, in any order) split into
--- its solids and profiles, each in the order given -- what `write_svg_text`/`write_svg`
--- draw together. Raises where an entry is neither, worded as every other binding's.
local function drawables(things)
  local solids, profiles = {}, {}
  for _, t in ipairs(things) do
    local meta = type(t) == "table" and getmetatable(t) or nil
    if meta == Solid then
      solids[#solids + 1] = t
    elseif meta == Profile then
      profiles[#profiles + 1] = t
    else
      raise("svg: only solids and profiles can be drawn")
    end
  end
  return solids, profiles
end

--- Several solids and profiles (a Lua array, any mix, in any order) as one SVG's text,
--- each its own `<g>` -- see `Solid:svg_text`/`Profile:svg_text` for `words`. A list of
--- solids alone still draws exactly as it always did, through the same entry point;
--- only a list that holds a profile calls the kernel's widened drawing pair, which
--- refuses in the same words either way, so the two look identical from here.
function M.write_svg_text(things, words)
  local o = svg_options(words)
  local solids, profiles = drawables(things)
  local n = #solids
  local handles = ffi.new("const struct CadaclysmBlacksmithSolid *[?]", math.max(n, 1))
  for i = 1, n do handles[i - 1] = solid_handle(solids[i], "write_svg_text") end
  local out
  if #profiles == 0 then
    out = lib().cadaclysm_blacksmith_svg_text(handles, n, o)
  else
    local pn = #profiles
    local phandles = ffi.new("const struct CadaclysmBlacksmithProfile *[?]", math.max(pn, 1))
    for i = 1, pn do phandles[i - 1] = profile_handle(profiles[i], "write_svg_text") end
    out = lib().cadaclysm_blacksmith_drawing_svg_text(handles, n, phandles, pn, o)
  end
  if out == nil then fail("svg_text") end
  local result = ffi.string(out)
  lib().cadaclysm_blacksmith_string_free(out)
  return result
end

--- `write_svg_text` written to `path` by the library itself.
function M.write_svg(path, things, words)
  local o = svg_options(words)
  local solids, profiles = drawables(things)
  local n = #solids
  local handles = ffi.new("const struct CadaclysmBlacksmithSolid *[?]", math.max(n, 1))
  for i = 1, n do handles[i - 1] = solid_handle(solids[i], "write_svg") end
  local ok
  if #profiles == 0 then
    ok = lib().cadaclysm_blacksmith_svg(handles, n, tostring(path), o)
  else
    local pn = #profiles
    local phandles = ffi.new("const struct CadaclysmBlacksmithProfile *[?]", math.max(pn, 1))
    for i = 1, pn do phandles[i - 1] = profile_handle(profiles[i], "write_svg") end
    ok = lib().cadaclysm_blacksmith_drawing_svg(handles, n, phandles, pn, tostring(path), o)
  end
  if not ok then fail("svg") end
end

return M
