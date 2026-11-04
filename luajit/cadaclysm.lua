--[[
cadaclysm for LuaJIT: open CAD files and read their tree, meshes, edges and surfaces.

The same object model as cadaclysm.py -- a Scene of Nodes, drawn through Placements
-- over the C ABI through LuaJIT's FFI, member for member under Python's names.
Nothing is compiled: the declarations are generated from include/cadaclysm.h
(gen_cdef.py) and the library is loaded as it is. Runs anywhere LuaJIT's FFI does:
LÖVE, LÖVR, a plain `luajit`.

    local cadaclysm = require("cadaclysm")
    local scene = cadaclysm.open("part.step")
    for node in scene:walk() do print(("  "):rep(node.depth) .. node.label) end
    for _, placement in ipairs(scene.placements) do
      local mesh = placement.geometry.mesh      -- borrowed const float* / uint32_t*
      local m = placement.raw_transform         -- 16 numbers, column-major
    end
    scene:close()

**Fields, not calls.** What Python spells as a property is a field here
(`node.name`, `scene.nodes`, `bounds.size`), computed when read, so nothing goes
stale; what Python calls is a method (`scene:query(filter)`, `node:save_mesh(path)`).

**Borrowed memory.** A Mesh's and a Polylines' pointers point into the scene: no
copy, which is what makes a ten-million-triangle file affordable. Every view holds
its scene, so the collector cannot free the scene under a view still reachable;
an explicit `scene:close()` invalidates them all, as in Python. `mesh:copy()` makes
memory of the caller's own.

**`...64` in double.** `mesh64`, `edge_beziers64`, `curve_beziers64`,
`isocurve_beziers64`, `bounds64` and `bounds_placed64` read the document's own
`double` coordinates rather than the `float` a plain `mesh`/`bounds` narrows to --
what a far-from-origin file needs. `mesh64`'s pointers are also borrowed, but from
the document's mesh rather than the narrowed copy `mesh` keeps: `scene:forget_meshes()`
frees what a held `Mesh64` points into (a held `Mesh` survives a forget, its own copy
kept); `edge_beziers64`/`curve_beziers64`/`isocurve_beziers64` are unaffected by a
forget, like their `float` twins. `mesh64:copy()` makes memory of the caller's own,
safe past a forget or a close.

**Indices are the ABI's.** `node.index` and the indices a Mesh holds count from
zero, as the library does; the Lua arrays this module builds count from one.

**Transforms.** `transform` is a 4x4 `m[row][col]` (the offset is `m[1][4]`,
`m[2][4]`, `m[3][4]`), as Python's numpy one is; `raw_transform` is the ABI's own
16 numbers, column-major -- the order a GPU uniform wants.

**Errors** are raised as `cadaclysm.CadaclysmError` values: `tostring(err)` is the
message, `getmetatable(err) == cadaclysm.CadaclysmError` identifies one.

**Threads.** Each `love.thread` (or LÖVR thread) is its own Lua state and requires
this module itself; the error text is per OS thread, read on the thread that failed.
]]

local ffi = require("ffi")

local M = {}

-- The declarations, once per LuaJIT state: a second `ffi.cdef` of the same struct
-- is an error, and a module loaded twice under two names would otherwise hit it.
local prefix = (...) and (...):match("^(.-)[^%.]*$") or ""
if not pcall(ffi.typeof, "struct CadaclysmOpenOptions") then
  ffi.cdef(require(prefix .. "cadaclysm_cdef"))
end

-- ---- errors ----------------------------------------------------------------------

--- What every failure here raises: `{ message = ... }`, printing as its message.
---@class CadaclysmError
---@field message string
local CadaclysmError = {}
CadaclysmError.__index = CadaclysmError
CadaclysmError.__tostring = function(e) return e.message end
M.CadaclysmError = CadaclysmError

local function fail(message, level)
  error(setmetatable({ message = message }, CadaclysmError), (level or 1) + 1)
end

-- ---- constants -------------------------------------------------------------------

--- The node index the C API uses for "no such node". The wrapper hands back `nil`
--- where a node may be missing, so this matters only when reading raw indices.
M.NONE = 0xffffffff

--- OR into a convention: keep the preset's axes but the file's own units.
M.FILE_UNITS = 0x100
--- OR into a convention: ask for `Mesh.uvs`, one world unit per unit of `u`.
M.UV_WORLD = 0x200

--- The space to read a file into. `NATIVE` keeps the file's own axes and units.
---@class Convention
---@field NATIVE integer
---@field UNREAL integer
---@field UNITY integer
---@field Y_UP integer
---@field BLENDER integer
---@field FILE_UNITS integer
---@field UV_WORLD integer
local Convention = { NATIVE = 0, UNREAL = 1, UNITY = 2, Y_UP = 3, BLENDER = 4 }
Convention.FILE_UNITS, Convention.UV_WORLD = M.FILE_UNITS, M.UV_WORLD
M.Convention = Convention

local PRESETS = { native = 0, unreal = 1, unity = 2, ["y-up"] = 3, blender = 4 }

--- `"unreal"`, or `"unreal+file-units"`, as the packed number `open` takes. Raises
--- on a name it does not know rather than reading it as `NATIVE`.
function Convention.parse(text)
  local preset, rest = tostring(text):lower():match("^%s*([^+]*)(.-)%s*$")
  local packed = PRESETS[preset]
  if not packed then
    fail(("no convention called '%s': native, unreal, unity, y-up or blender"):format(preset), 2)
  end
  for flag in rest:gmatch("[^+]+") do
    if flag ~= "file-units" then fail(("no convention flag called '%s': file-units"):format(flag), 2) end
    packed = bit.bor(packed, M.FILE_UNITS)
  end
  return packed
end

--- Which field of an attribute holds its value; zero means the attribute was not there.
---@class ValueKind
---@field NONE integer
---@field TEXT integer
---@field INTEGER integer
---@field REAL integer
---@field BOOLEAN integer
---@field LIST integer
---@field REFERENCE integer
local ValueKind = { NONE = 0, TEXT = 1, INTEGER = 2, REAL = 3, BOOLEAN = 4, LIST = 5, REFERENCE = 6 }
M.ValueKind = ValueKind

-- ---- the library -----------------------------------------------------------------

local function library_name()
  if ffi.os == "Windows" then return "cadaclysm_capi.dll" end
  if ffi.os == "OSX" then return "libcadaclysm_capi.dylib" end
  return "libcadaclysm_capi.so"
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

local function is_dir(path)
  local f = io.open(path, "rb")
  if f then
    local _, _, code = f:read(1)
    f:close()
    return code == 21 -- EISDIR: POSIX opens a directory and fails the read
  end
  return os.rename(path, path) and true or false -- Windows refuses to open one at all
end

local function parent_of(path)
  return path:match("^(.*)/[^/]*$")
end

-- The directory this file sits in on the real file system, or nil when it is only
-- inside a LÖVE archive and has none.
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

--- Where the shared library is: `CADACLYSM_LIBRARY` first (the library or its
--- directory), then beside this file, beside a fused LÖVE game's executable, then
--- a `lib/` (the SDK layout) or `target/release` / `target/debug` (the repository's)
--- in any ancestor of this file.
function M.library_path()
  local name = library_name()
  local override = os.getenv("CADACLYSM_LIBRARY")
  if override then
    override = override:gsub("\\", "/")
    if exists(override .. "/" .. name) then return override .. "/" .. name end
    if exists(override) then return override end
    fail("CADACLYSM_LIBRARY=" .. override .. " names nothing that exists", 2)
  end
  local searched = {}
  local here = module_dir()
  if here then searched[#searched + 1] = here .. "/" .. name end
  if love and love.filesystem and love.filesystem.getSourceBaseDirectory then
    searched[#searched + 1] = love.filesystem.getSourceBaseDirectory():gsub("\\", "/") .. "/" .. name
  end
  local dirs, dir = {}, here
  while dir and dir ~= "" do
    dirs[#dirs + 1] = dir
    dir = parent_of(dir)
  end
  for _, d in ipairs(dirs) do searched[#searched + 1] = d .. "/lib/" .. name end
  for _, d in ipairs(dirs) do
    searched[#searched + 1] = d .. "/target/release/" .. name
    searched[#searched + 1] = d .. "/target/debug/" .. name
  end
  for _, candidate in ipairs(searched) do
    if exists(candidate) then return candidate end
  end
  fail(name .. " not found. Looked in:\n    " .. table.concat(searched, "\n    ")
    .. "\nBuild it with `cargo build --release -p cadaclysm-capi`, run fetch.py in an"
    .. " SDK checkout, or point CADACLYSM_LIBRARY at it.", 2)
end

-- Every entry point this module calls, checked when the library loads: LuaJIT
-- resolves a symbol on first use, so a library older than this file would otherwise
-- fail mid-draw with a bare "cannot resolve symbol".
local ENTRY_POINTS = {
  "cadaclysm_last_error", "cadaclysm_version", "cadaclysm_build_date",
  "cadaclysm_license_set", "cadaclysm_license_info", "cadaclysm_license_notice_count",
  "cadaclysm_open", "cadaclysm_open_memory", "cadaclysm_open_options_init", "cadaclysm_close",
  "cadaclysm_source_name", "cadaclysm_schema", "cadaclysm_schema_read",
  "cadaclysm_metres_per_unit", "cadaclysm_bounds", "cadaclysm_bounds64", "cadaclysm_diagnostic_count",
  "cadaclysm_diagnostic", "cadaclysm_node_count", "cadaclysm_root_count", "cadaclysm_root",
  "cadaclysm_query", "cadaclysm_realize_all", "cadaclysm_realized", "cadaclysm_realize_total",
  "cadaclysm_cancel", "cadaclysm_scene_save", "cadaclysm_surface_matrix",
  "cadaclysm_placement_count", "cadaclysm_placement_geometry", "cadaclysm_placement_select",
  "cadaclysm_placement_transform",
  "cadaclysm_node_name", "cadaclysm_node_id", "cadaclysm_node_kind", "cadaclysm_node_visible",
  "cadaclysm_node_depth", "cadaclysm_node_generator", "cadaclysm_node_parent",
  "cadaclysm_node_child_count", "cadaclysm_node_child", "cadaclysm_node_instance_of",
  "cadaclysm_node_select_as", "cadaclysm_node_attribute_count", "cadaclysm_node_attribute",
  "cadaclysm_node_can_mesh", "cadaclysm_node_save_mesh", "cadaclysm_node_color",
  "cadaclysm_node_transform", "cadaclysm_node_bounds", "cadaclysm_node_bounds64", "cadaclysm_node_mesh",
  "cadaclysm_node_mesh64",
  "cadaclysm_node_surfaces", "cadaclysm_node_brep",
  "cadaclysm_node_edges", "cadaclysm_node_curves", "cadaclysm_node_isocurves",
  "cadaclysm_node_edge_colors", "cadaclysm_node_surface_edge_colors",
  "cadaclysm_brep_layout_id", "cadaclysm_brep_manifold", "cadaclysm_brep_sew", "cadaclysm_brep_release",
  "cadaclysm_brep_health", "cadaclysm_brep_health_free", "cadaclysm_brep_health_summary",
  "cadaclysm_brep_health_free_edges", "cadaclysm_brep_health_wires", "cadaclysm_brep_health_small",
  "cadaclysm_brep_health_crack_edges", "cadaclysm_brep_healed", "cadaclysm_brep_heal_body", "cadaclysm_brep_heal_free",
  "cadaclysm_brep_heal_summary", "cadaclysm_brep_heal_fixes", "cadaclysm_brep_heal_refused",
  "cadaclysm_brep_edge_tolerance",
  "cadaclysm_mesh_format_count", "cadaclysm_mesh_format", "cadaclysm_mesh_format_extension",
  "cadaclysm_pick_file",
  "cadaclysm_mesh_format_label", "cadaclysm_format_count", "cadaclysm_format_name", "cadaclysm_format_extensions",
  "cadaclysm_pick_save", "cadaclysm_geometry_diagnostic_count", "cadaclysm_geometry_diagnostic",
  "cadaclysm_forget_meshes",
  "cadaclysm_lod_levels", "cadaclysm_node_mesh_lod", "cadaclysm_node_lod_error",
  "cadaclysm_node_edge_beziers", "cadaclysm_node_curve_beziers", "cadaclysm_node_isocurve_beziers",
  "cadaclysm_node_edge_beziers64", "cadaclysm_node_curve_beziers64", "cadaclysm_node_isocurve_beziers64",
  "cadaclysm_node_collision", "cadaclysm_node_collision_hull",
  "cadaclysm_node_bounds_placed", "cadaclysm_node_bounds_placed64", "cadaclysm_node_is_meshed",
  "cadaclysm_node_surface_edges", "cadaclysm_node_surface_edge_beziers", "cadaclysm_node_surface_isocurves",
  "cadaclysm_node_surface_pick", "cadaclysm_node_surface_proxy_mesh",
  "cadaclysm_node_triangle_estimate", "cadaclysm_realize_meshes",
  "cadaclysm_meshlets_build", "cadaclysm_meshlets_count", "cadaclysm_meshlets_free",
  "cadaclysm_meshlet_triangle_count", "cadaclysm_meshlet_vertex_count", "cadaclysm_meshlet_level",
  "cadaclysm_meshlet_group", "cadaclysm_meshlet_error", "cadaclysm_meshlet_child_count",
  "cadaclysm_meshlet_positions", "cadaclysm_meshlet_normals", "cadaclysm_meshlet_indices",
  "cadaclysm_meshlet_children",
  "cadaclysm_fem_options_init", "cadaclysm_node_fem_mesh", "cadaclysm_fem_mesh_view",
  "cadaclysm_fem_mesh_edge", "cadaclysm_fem_mesh_vertex", "cadaclysm_fem_mesh_open_edge",
  "cadaclysm_fem_mesh_folded_edge", "cadaclysm_fem_mesh_crossing_count", "cadaclysm_fem_mesh_crossing",
  "cadaclysm_fem_mesh_msh_text",
  "cadaclysm_fem_mesh_save_msh", "cadaclysm_fem_mesh_free",
  "cadaclysm_svg_options_init", "cadaclysm_scene_svg_text", "cadaclysm_scene_svg",
  "cadaclysm_node_svg_text", "cadaclysm_node_svg", "cadaclysm_node_silhouette_beziers",
  "cadaclysm_link_count", "cadaclysm_link_name", "cadaclysm_link_node_count", "cadaclysm_link_node",
  "cadaclysm_joint_count", "cadaclysm_joint_name", "cadaclysm_joint_start", "cadaclysm_joint_end",
}

local C

local function bind(path)
  local loaded = ffi.load(path)
  for _, name in ipairs(ENTRY_POINTS) do
    if not pcall(function() return loaded[name] end) then
      fail(path .. " has no " .. name .. ": the library is older than this copy of"
        .. " cadaclysm.lua. Rebuild it with `cargo build --release -p cadaclysm-capi`.", 3)
    end
  end
  C = loaded
  return C
end

local function lib()
  return C or bind(M.library_path())
end

--- Load the library from `path` rather than searching for it -- a LÖVE game that
--- keeps it in its save directory, say. Call before anything else.
function M.load(path)
  bind(path)
  return M
end

local function text(raw)
  if raw == nil then return "" end
  return ffi.string(raw)
end

local function last_error()
  return text(lib().cadaclysm_last_error())
end

--- The version of the library actually loaded, which is the one worth reporting.
function M.version() return text(lib().cadaclysm_version()) end

--- When the loaded library was built, `YYYY-MM-DD`; a licence covers every build
--- dated on or before its expiry.
function M.build_date() return text(lib().cadaclysm_build_date()) end

--- How many coarser levels `node:mesh_lod` offers above the mesh itself (level 0).
function M.lod_levels() return lib().cadaclysm_lod_levels() end

--- One line about the licence in use, or `unlicensed` (`unlicensed -- <reason>` when
--- a licence was found but did not verify). Never nil.
function M.license_info() return text(lib().cadaclysm_license_info()) end

--- How many unlicensed notices the library has printed to stderr in this process;
--- a game with no console can poll this and show its own banner.
function M.license_notice_count() return tonumber(lib().cadaclysm_license_notice_count()) end

--- Load a licence: the certificate text, or the path of a file holding it. Raises
--- with the reason when it does not verify; the previous licence stays in use.
function M.license(text_or_path)
  if not lib().cadaclysm_license_set(tostring(text_or_path)) then
    local reason = last_error()
    fail(reason ~= "" and reason or "license refused", 2)
  end
end

--- Every format `node:save_mesh` writes, as `{ {name, extension, label}, ... }`. Build a
--- menu from this rather than hard-coding it; the label is what to show in it.
function M.mesh_formats()
  local L, out = lib(), {}
  for i = 0, L.cadaclysm_mesh_format_count() - 1 do
    out[#out + 1] = { text(L.cadaclysm_mesh_format(i)), text(L.cadaclysm_mesh_format_extension(i)),
                      text(L.cadaclysm_mesh_format_label(i)) }
  end
  return out
end

--- Every format this build reads, as `{ {name, {extension, ...}}, ... }`: what an open
--- dialog's filter is built from. The library hands the extensions over
--- semicolon-separated; they are split here.
function M.formats()
  local L, out = lib(), {}
  for i = 0, L.cadaclysm_format_count() - 1 do
    local extensions = {}
    for e in text(L.cadaclysm_format_extensions(i)):gmatch("[^;]+") do extensions[#extensions + 1] = e end
    out[#out + 1] = { text(L.cadaclysm_format_name(i)), extensions }
  end
  return out
end

--- Ask the user for a file through the platform's own open dialog, filtered to what
--- this build reads. `nil` when they cancel or no dialog is available. Blocks.
function M.pick_file()
  local raw = lib().cadaclysm_pick_file(nil)
  if raw == nil then return nil end
  return ffi.string(raw) -- borrowed only until the next picker call, so copied now
end

--- Ask the user where to save, through the platform's own dialog, `suggested_name`
--- prefilled. `nil` when they cancel or no dialog is available. Blocks.
function M.pick_save(suggested_name)
  local raw = lib().cadaclysm_pick_save(nil, suggested_name and tostring(suggested_name) or nil)
  if raw == nil then return nil end
  return ffi.string(raw) -- borrowed only until the next picker call, so copied now
end

-- ---- classes ---------------------------------------------------------------------

-- A class whose `getters` read like fields: `node.name`, not `node:name()`.
local function class(getters)
  local methods = {}
  methods.__index = function(self, key)
    local get = getters[key]
    if get then return get(self) end
    return methods[key]
  end
  return methods
end

-- A float written as cadaclysm's own Rust `Display` writes it: the shortest decimal
-- that reads back to the same number, never in exponent form.
local function decimal_text(v)
  if v ~= v then return "NaN" end
  if v == math.huge then return "inf" end
  if v == -math.huge then return "-inf" end
  local s
  for p = 1, 17 do
    s = ("%." .. p .. "g"):format(v)
    if tonumber(s) == v then break end
  end
  local sign, mantissa, exponent = s:match("^(-?)([%d%.]+)e([-+]%d+)$")
  if not sign then return s end
  local int, frac = mantissa:match("^(%d+)%.?(%d*)$")
  local digits, point = int .. frac, #int + tonumber(exponent)
  if point <= 0 then
    s = "0." .. ("0"):rep(-point) .. digits
  elseif point >= #digits then
    s = digits .. ("0"):rep(point - #digits)
  else
    s = digits:sub(1, point) .. "." .. digits:sub(point + 1)
  end
  return sign .. s
end
M._decimal_text = decimal_text

-- A 4x4 `m[row][col]` from the ABI's 16 column-major numbers.
local function rows(t)
  return { { t[1], t[5], t[9], t[13] }, { t[2], t[6], t[10], t[14] },
           { t[3], t[7], t[11], t[15] }, { t[4], t[8], t[12], t[16] } }
end

-- The 16 numbers of a `double[16]` the library filled, as a Lua array.
local function sixteen(out)
  local t = {}
  for i = 0, 15 do t[i + 1] = out[i] end
  return t
end

--- An axis-aligned box, or all zeros where there was nothing to bound. `min` and
--- `max` are `{x, y, z}`.
local Bounds_get = {}
---@class Bounds
---@field min number[]  {x, y, z}
---@field max number[]  {x, y, z}
local Bounds = class(Bounds_get)
M.Bounds = Bounds

local function bounds(raw)
  return setmetatable({
    min = { raw.min[0], raw.min[1], raw.min[2] },
    max = { raw.max[0], raw.max[1], raw.max[2] },
  }, Bounds)
end

-- `CadaclysmBounds64`'s fields are `double`, `CadaclysmBounds`'s `float`, but a Lua
-- number is already as wide as a `double`: reading either costs nothing extra, so
-- the same `Bounds` shape serves both -- this helper exists to read the `64` struct
-- by name at each call site, matching the ABI's own `bounds64` naming.
local function bounds64(raw) return bounds(raw) end

--- Whether this is the all-zero box the ABI uses for "nothing here".
function Bounds_get.is_empty(self)
  for i = 1, 3 do
    if self.min[i] ~= 0 or self.max[i] ~= 0 then return false end
  end
  return true
end
--- `{dx, dy, dz}`.
function Bounds_get.size(self)
  return { self.max[1] - self.min[1], self.max[2] - self.min[2], self.max[3] - self.min[3] }
end
--- `{x, y, z}` in the middle.
function Bounds_get.centre(self)
  return { (self.min[1] + self.max[1]) / 2, (self.min[2] + self.max[2]) / 2, (self.min[3] + self.max[3]) / 2 }
end
Bounds.__tostring = function(b)
  return ("Bounds(min=(%g, %g, %g), max=(%g, %g, %g))"):format(b.min[1], b.min[2], b.min[3], b.max[1], b.max[2], b.max[3])
end

--- One thing the file said about a node: `name`, `kind` (a `ValueKind`) and `value`,
--- already the Lua type the kind names (string, number, boolean, or nil for NONE).
local Attribute_get = {}
---@class Attribute
---@field name string
---@field kind integer  a ValueKind
---@field value string|number|boolean|nil
local Attribute = class(Attribute_get)
M.Attribute = Attribute

--- The value rendered for display, as the library's own Rust `Display` does -- the
--- same text every other wrapper prints.
function Attribute_get.text(self)
  local v, kind = self.value, self.kind
  if v == nil then return "" end
  if kind == ValueKind.REAL then return decimal_text(v) end
  if kind == ValueKind.BOOLEAN then return v and "true" or "false" end
  if kind == ValueKind.INTEGER then return ("%d"):format(v) end
  return tostring(v)
end
Attribute.__tostring = function(a) return ("Attribute(name=%q, value=%s)"):format(a.name, a.text) end

local function attribute(raw)
  -- A null name is the terminator; an attribute the file named "" is a real one.
  if raw.name == nil then return nil end
  local kind = tonumber(raw.kind)
  if kind < 0 or kind > 6 then kind = ValueKind.NONE end
  local value
  if kind == ValueKind.TEXT or kind == ValueKind.LIST or kind == ValueKind.REFERENCE then
    value = text(raw.text)
  elseif kind == ValueKind.INTEGER then
    value = tonumber(raw.integer)
  elseif kind == ValueKind.REAL then
    value = raw.real
  elseif kind == ValueKind.BOOLEAN then
    value = raw.boolean
  end
  return setmetatable({ name = text(raw.name), kind = kind, value = value }, Attribute)
end

-- ---- meshes and polylines --------------------------------------------------------

--- A node's triangles, in the node's own frame. `positions` and `normals` are
--- `const float *`, 3 a vertex; `uvs` 2; `colors` 4 (RGBA); `indices` is
--- `const uint32_t *`, three to a triangle, counting from zero. Any may be nil but
--- `positions` and `indices` on a mesh with triangles. Borrowed from the scene.
local Mesh_get = {}
---@class Mesh
---@field positions ffi.cdata*  const float *, 3 a vertex
---@field normals ffi.cdata*|nil
---@field uvs ffi.cdata*|nil  2 a vertex
---@field colors ffi.cdata*|nil  RGBA, 4 a vertex
---@field indices ffi.cdata*  const uint32_t *, 3 a triangle
---@field vertex_count integer
---@field index_count integer
local Mesh = class(Mesh_get)
M.Mesh = Mesh

function Mesh_get.triangle_count(self) return math.floor(self.index_count / 3) end
--- True for a node with no triangles (a curve, an assembly).
function Mesh_get.is_empty(self) return self.index_count == 0 or self.positions == nil end

--- The position of vertex `i` (from zero), as three numbers.
function Mesh:position(i)
  local p = self.positions
  return p[3 * i], p[3 * i + 1], p[3 * i + 2]
end

local function owned(ptr, ctype, count)
  if ptr == nil then return nil end
  local out = ffi.new(ctype .. "[?]", count)
  ffi.copy(out, ptr, ffi.sizeof(ctype) * count)
  return out
end

--- The same triangles in memory of the caller's own, safe to outlive the scene.
function Mesh:copy()
  local n = self.vertex_count
  return setmetatable({
    positions = owned(self.positions, "float", n * 3),
    normals = owned(self.normals, "float", n * 3),
    uvs = owned(self.uvs, "float", n * 2),
    colors = owned(self.colors, "float", n * 4),
    indices = owned(self.indices, "uint32_t", self.index_count),
    vertex_count = n,
    index_count = self.index_count,
  }, Mesh)
end
Mesh.__tostring = function(m) return ("Mesh(vertices=%d, triangles=%d)"):format(m.vertex_count, m.triangle_count) end

local function null_to_nil(p)
  if p == nil then return nil end
  return p
end

local function mesh(scene, raw)
  return setmetatable({
    scene = scene,
    positions = null_to_nil(raw.positions),
    normals = null_to_nil(raw.normals),
    uvs = null_to_nil(raw.uvs),
    colors = null_to_nil(raw.colors),
    indices = null_to_nil(raw.indices),
    vertex_count = raw.vertex_count,
    index_count = raw.index_count,
  }, Mesh)
end

--- `Mesh` in `double`: the document's own mesh, **lent as it is** -- `positions`,
--- `normals` and `uvs` are `const double *`, three (two for `uvs`) a vertex, where
--- `mesh` hands back a `float` copy of the same triangles (its `positions` are
--- exactly these narrowed). For a caller that uses the mesh as geometry -- an
--- exporter, a measurement, a solver -- and wants the file's own coordinates, which
--- `float` cannot hold far from the origin. `colors` stays `const float *` (RGBA in
--- 0..1 needs no more); `indices` is `const uint32_t *`, as `Mesh`'s.
---
--- **A `scene:forget_meshes()` frees what this points into**, unlike `Mesh`'s arrays,
--- which are the library's own narrowed copy and survive a forget untouched. A
--- `Mesh64` read before a forget must not be read after one; ask `node.mesh64` again.
--- Each one is stamped with the scene's forget count, so reading one of its arrays
--- after a forget raises a `CadaclysmError` ("stale view") rather than reading freed
--- memory -- a pointer already taken out of it before the forget is not caught.
--- `:copy()` makes Lua tables of the caller's own, safe past a forget or a close.
local Mesh64_get = {}
---@class Mesh64
---@field positions ffi.cdata*  const double *, 3 a vertex
---@field normals ffi.cdata*|nil
---@field uvs ffi.cdata*|nil  2 a vertex
---@field colors ffi.cdata*|nil  RGBA, still float, 4 a vertex
---@field indices ffi.cdata*  const uint32_t *, 3 a triangle
---@field vertex_count integer
---@field index_count integer
local Mesh64 = class(Mesh64_get)
M.Mesh64 = Mesh64

function Mesh64_get.triangle_count(self) return math.floor(self.index_count / 3) end
--- True for a node with no triangles (a curve, an assembly).
function Mesh64_get.is_empty(self)
  return self.index_count == 0 or (rawget(self, "positions") or rawget(self, "_positions")) == nil
end

-- The arrays of a lent Mesh64 are getters, so each read checks the scene first: still
-- open, and no forget since this was made. A `:copy()` holds its arrays as plain fields
-- and never gets here, save for an array it does not have, which has no scene to check.
local function lent(name)
  local key = "_" .. name
  return function(self)
    local scene = rawget(self, "scene")
    if scene then
      scene:handle()
      if (rawget(scene, "_forgets") or 0) ~= rawget(self, "_forgets") then
        fail("mesh64: stale view: the scene has forgotten its meshes since, freeing the document's own mesh this lends (ask the node again)", 3)
      end
    end
    return rawget(self, key)
  end
end
for _, name in ipairs({ "positions", "normals", "uvs", "colors", "indices" }) do
  Mesh64_get[name] = lent(name)
end

--- The position of vertex `i` (from zero), as three numbers.
function Mesh64:position(i)
  local p = self.positions
  return p[3 * i], p[3 * i + 1], p[3 * i + 2]
end

--- The same triangles in memory of the caller's own, safe to outlive a forget or the scene.
function Mesh64:copy()
  local n = self.vertex_count
  return setmetatable({
    positions = owned(self.positions, "double", n * 3),
    normals = owned(self.normals, "double", n * 3),
    uvs = owned(self.uvs, "double", n * 2),
    colors = owned(self.colors, "float", n * 4),
    indices = owned(self.indices, "uint32_t", self.index_count),
    vertex_count = n,
    index_count = self.index_count,
  }, Mesh64)
end
Mesh64.__tostring = function(m) return ("Mesh64(vertices=%d, triangles=%d)"):format(m.vertex_count, m.triangle_count) end

local function mesh64(scene, raw)
  return setmetatable({
    scene = scene,
    -- The scene's forget count when this was made; see Scene:forget_meshes.
    _forgets = rawget(scene, "_forgets") or 0,
    _positions = null_to_nil(raw.positions),
    _normals = null_to_nil(raw.normals),
    _uvs = null_to_nil(raw.uvs),
    _colors = null_to_nil(raw.colors),
    _indices = null_to_nil(raw.indices),
    vertex_count = raw.vertex_count,
    index_count = raw.index_count,
  }, Mesh64)
end

--- A node's feature edges or free curves, already flattened to points: `positions`
--- is `const float *`, 3 a point, the runs end to end; `counts` is
--- `const uint32_t *`, how long each run is. Borrowed from the scene.
local Polylines_get = {}
---@class Polylines
---@field positions ffi.cdata*  const float *, 3 a point
---@field counts ffi.cdata*  const uint32_t *
---@field polyline_count integer
---@field vertex_count integer
local Polylines = class(Polylines_get)
M.Polylines = Polylines

function Polylines_get.is_empty(self) return self.polyline_count == 0 or self.positions == nil end

--- Every run as `start, count` (start counting from zero into `positions`).
function Polylines:runs()
  local i, start = -1, 0
  return function()
    i = i + 1
    if i >= self.polyline_count then return nil end
    local n = self.counts[i]
    local s = start
    start = start + n
    return s, n
  end
end

--- Indices into `positions` making line-segment endpoint pairs, as a `uint32_t` array
--- (from zero) and its length: a run of n points is n - 1 segments.
function Polylines:segment_indices()
  local total = 0
  if not self.is_empty then
    for _, n in self:runs() do
      if n >= 2 then total = total + 2 * (n - 1) end
    end
  end
  local out, k = ffi.new("uint32_t[?]", math.max(total, 1)), 0
  if total > 0 then
    for s, n in self:runs() do
      for i = s, s + n - 2 do
        out[k], out[k + 1] = i, i + 1
        k = k + 2
      end
    end
  end
  return out, total
end

--- The endpoint pairs themselves, as a `float` array of 3 a point and the number of
--- points (twice the segment count), in the node's own frame.
function Polylines:segments()
  local idx, n = self:segment_indices()
  local out, p = ffi.new("float[?]", math.max(n * 3, 1)), self.positions
  for i = 0, n - 1 do
    local s = idx[i] * 3
    out[3 * i], out[3 * i + 1], out[3 * i + 2] = p[s], p[s + 1], p[s + 2]
  end
  return out, n
end
Polylines.__tostring = function(p)
  return ("Polylines(polylines=%d, vertices=%d)"):format(p.polyline_count, p.vertex_count)
end

local function polylines(scene, raw)
  return setmetatable({
    scene = scene,
    positions = null_to_nil(raw.positions),
    counts = null_to_nil(raw.counts),
    polyline_count = raw.polyline_count,
    vertex_count = raw.vertex_count,
  }, Polylines)
end

--- One RGBA table per polyline of a `CadaclysmEdgeColors`, `false` for a polyline the
--- file does not style (Lua arrays cannot hold `nil` holes; this is the convention
--- `blacksmith.edge_polyline_colours` also uses), copied out as plain Lua tables.
local function edge_colours(raw)
  if raw.rgba == nil or raw.count == 0 then return {} end
  local out = {}
  for i = 0, raw.count - 1 do
    local v = raw.rgba + 4 * i
    -- Not the `cond and false or x` idiom: that breaks when the true branch's
    -- own value is `false`, which is exactly this line's "unstyled" case.
    if v[3] < 0 then out[i + 1] = false else out[i + 1] = { v[0], v[1], v[2], v[3] } end
  end
  return out
end

--- Edges, curves or isocurves as cubic Bézier curves, exact where the file's curves
--- were: `points` is `const float *`, four control points a curve, three floats each
--- (`count * 12`); `weights` is `const float *`, one a control point (`count * 4`), all
--- ones for a polynomial curve. Borrowed from the scene; `:copy()` makes Lua tables.
---@class Beziers
---@field points ffi.cdata*
---@field weights ffi.cdata*
---@field count integer
local Beziers = {}
Beziers.__index = Beziers
M.Beziers = Beziers
Beziers.__tostring = function(b) return ("Beziers(count=%d)"):format(b.count) end

--- The same curves as Lua tables of numbers, safe to keep after the scene closes.
function Beziers:copy()
  local points, weights = {}, {}
  for i = 0, self.count * 12 - 1 do points[i + 1] = self.points[i] end
  for i = 0, self.count * 4 - 1 do weights[i + 1] = self.weights[i] end
  return { points = points, weights = weights, count = self.count }
end

local function beziers(scene, raw)
  return setmetatable({
    scene = scene,
    points = null_to_nil(raw.points),
    weights = null_to_nil(raw.weights),
    count = raw.count,
  }, Beziers)
end

--- `Beziers` in `double`: `points` and `weights` are `const double *` over the same
--- shape (four control points a curve, three doubles each; one weight a control
--- point). Borrowed from the scene until it is closed, same as `Beziers` -- unlike
--- `Mesh64`, a `scene:forget_meshes()` does not touch these (edges, curves and
--- isocurves are not part of the mesh cache a forget drops). `:copy()` makes Lua
--- tables of the caller's own.
---@class Beziers64
---@field points ffi.cdata*
---@field weights ffi.cdata*
---@field count integer
local Beziers64 = {}
Beziers64.__index = Beziers64
M.Beziers64 = Beziers64
Beziers64.__tostring = function(b) return ("Beziers64(count=%d)"):format(b.count) end

--- The same curves as Lua tables of numbers, safe to keep after the scene closes.
function Beziers64:copy()
  local points, weights = {}, {}
  for i = 0, self.count * 12 - 1 do points[i + 1] = self.points[i] end
  for i = 0, self.count * 4 - 1 do weights[i + 1] = self.weights[i] end
  return { points = points, weights = weights, count = self.count }
end

local function beziers64(scene, raw)
  return setmetatable({
    scene = scene,
    points = null_to_nil(raw.points),
    weights = null_to_nil(raw.weights),
    count = raw.count,
  }, Beziers64)
end

--- What a node turned out to be for a physics engine: a box, sphere, capsule or
--- cylinder where one fits within `error`, else a convex hull. `frame` (16 numbers,
--- column-major) and `half_extent` are always the true oriented box. Plain data.
---@class Collision
---@field shape integer
---@field confidence integer
---@field axis integer
---@field frame number[]
---@field half_extent number[]
---@field radius number
---@field height number
---@field error number
---@field hull_vertex_count integer
---@field hull_index_count integer
---@field shape_name string
local Collision_get = {}
local COLLISION_NAMES = { [0] = "none", "box", "sphere", "capsule", "cylinder", "hull" }
--- `none`, `box`, `sphere`, `capsule`, `cylinder` or `hull`.
function Collision_get.shape_name(self) return COLLISION_NAMES[self.shape] or tostring(self.shape) end
local Collision = class(Collision_get)
M.Collision = Collision
Collision.__tostring = function(c) return ("Collision(%s, error=%g)"):format(c.shape_name, c.error) end

--- A node's convex hull for a physics engine: `positions` `const float *` (3 a vertex),
--- `indices` `const uint32_t *` (3 a triangle). Borrowed from the scene.
---@class CollisionHull
---@field positions ffi.cdata*
---@field indices ffi.cdata*
---@field vertex_count integer
---@field index_count integer
local CollisionHull = {}
CollisionHull.__index = CollisionHull
M.CollisionHull = CollisionHull
CollisionHull.__tostring = function(h) return ("CollisionHull(vertices=%d, triangles=%d)"):format(h.vertex_count, h.index_count / 3) end

-- ---- surfaces --------------------------------------------------------------------

--- One trimmed face: the surface, plus the loops that cut it. `kind` is 0 plane,
--- 1 cylinder, 2 cone, 3 sphere, 4 torus, 5 revolution, 6 extrusion, 7 NURBS, 8 sum.
--- `origin`, `ax`, `ay`, `az` are `{x, y, z}` (the frame); `domain` is
--- `{u_min, v_min, u_max, v_max}`; `scalars` 4 kind-dependent numbers. `loops` is a
--- list of `{ points = const float *, count = N }` (u, v pairs, each loop closing
--- implicitly); `profile`, `profile2` are `{ values = const float *, count = N }`
--- (4 floats an entry) and `nurbs` `{ values, count }`. Borrowed from the scene.
---@class Face
---@field kind integer
---@field reversed boolean
---@field transposed boolean
---@field origin number[]
---@field ax number[]
---@field ay number[]
---@field az number[]
---@field domain number[]
---@field scalars number[]
---@field loops table[]  {points, count}
---@field profile table  {values, count}
---@field profile2 table  {values, count}
---@field nurbs table  {values, count}
local Face = {}
Face.__index = Face
M.Face = Face
Face.__tostring = function(f)
  local names = { [0] = "plane", "cylinder", "cone", "sphere", "torus", "revolution", "extrusion", "nurbs", "sum" }
  return ("Face(%s, %d loops)"):format(names[f.kind] or tostring(f.kind), #f.loops)
end

--- A part's faces as surfaces and trims: `faces` is a list of Face. In the file's own
--- frame, unlike everything else here -- see `Scene.surface_matrix`.
---@class Surfaces
---@field faces Face[]
local Surfaces = {}
Surfaces.__index = Surfaces
Surfaces.Face = Face
M.Surfaces = Surfaces
Surfaces.__tostring = function(s) return ("Surfaces(%d faces)"):format(#s.faces) end

local function vec3(a) return { a[0], a[1], a[2] } end
local function vec4(a) return { a[0], a[1], a[2], a[3] } end

local function surfaces(scene, raw)
  local faces = {}
  for i = 0, raw.face_count - 1 do
    local f = raw.faces[i]
    local loops = {}
    for k = 0, f.loop_count - 1 do
      local start, length = raw.loops[2 * (f.loop_start + k)], raw.loops[2 * (f.loop_start + k) + 1]
      loops[#loops + 1] = { points = raw.points + 2 * start, count = length, scene = scene }
    end
    local function run(values, start, count, width)
      return { values = count > 0 and (values + width * start) or nil, count = count, scene = scene }
    end
    faces[#faces + 1] = setmetatable({
      kind = f.kind, reversed = f.reversed ~= 0, transposed = f.transposed ~= 0,
      origin = vec3(f.origin), ax = vec3(f.ax), ay = vec3(f.ay), az = vec3(f.az),
      domain = vec4(f.domain), scalars = vec4(f.scalars), loops = loops,
      profile = run(raw.profiles, f.profile_start, f.profile_count, 4),
      profile2 = run(raw.profiles, f.profile2_start, f.profile2_count, 4),
      nurbs = run(raw.nurbs, f.nurbs_start, f.nurbs_count, 1),
    }, Face)
  end
  return setmetatable({ faces = faces }, Surfaces)
end

-- ---- breps -------------------------------------------------------------------------

--- Whether a brep's faces make a manifold, as plain data: `faces`, `edges`,
--- `vertices`, `boundary_edges`, `non_manifold_edges`, `non_manifold_vertices`, and
--- the booleans `is_manifold` and `is_closed` (it encloses a solid).
---@class Manifold
---@field faces integer
---@field edges integer
---@field vertices integer
---@field boundary_edges integer
---@field non_manifold_edges integer
---@field non_manifold_vertices integer
---@field is_manifold boolean
---@field is_closed boolean
local Manifold = {}
Manifold.__index = Manifold
M.Manifold = Manifold
Manifold.__tostring = function(m)
  return ("Manifold(faces=%d, edges=%d, vertices=%d, boundary_edges=%d, non_manifold_edges=%d, "
    .. "non_manifold_vertices=%d, is_manifold=%s, is_closed=%s)"):format(m.faces, m.edges, m.vertices,
    m.boundary_edges, m.non_manifold_edges, m.non_manifold_vertices, tostring(m.is_manifold), tostring(m.is_closed))
end

--- A body's exact B-rep, shared with the scene rather than copied: a reference of its
--- own, given back by `release()` or the collector. It outlives the scene. For
--- `cadaclysm_blacksmith.Solid.from_node`, which takes it across by `pointer` after
--- comparing `layout_id`s, and for asking whether it is a manifold.
local Brep_get = {}
---@class Brep
local Brep = class(Brep_get)
M.Brep = Brep

--- The `const struct CadaclysmBrep *` itself.
function Brep_get.pointer(self)
  local p = rawget(self, "_ptr")
  if p == nil then fail("brep: released", 2) end
  return p
end

--- How this library lays a brep out in memory; the blacksmith shares one only with
--- a library whose id equals its own.
function Brep.layout_id() return text(lib().cadaclysm_brep_layout_id()) end

--- Whether its faces make a manifold, read off the topology the file wrote.
function Brep_get.manifold(self)
  local out = ffi.new("uint32_t[8]")
  if not lib().cadaclysm_brep_manifold(self.pointer, out) then
    local reason = last_error()
    fail(reason ~= "" and reason or "manifold", 2)
  end
  return setmetatable({
    faces = out[0], edges = out[1], vertices = out[2], boundary_edges = out[3],
    non_manifold_edges = out[4], non_manifold_vertices = out[5],
    is_manifold = out[6] ~= 0, is_closed = out[7] ~= 0,
  }, Manifold)
end

--- What `Brep:sewed` did, as plain data: `pairs` (the edges it joined), `free_before`
--- and `free_after` (the free edges), `refused` (how many groups of free edges between
--- the same two vertices it left free: too far apart for the tolerance, or more than
--- two), `worst_gap` (the widest gap it sewed), and the two tolerances it used,
--- `tolerance` and `vertex`.
---@class SewReport
---@field pairs integer
---@field free_before integer
---@field free_after integer
---@field refused integer
---@field worst_gap number
---@field tolerance number
---@field vertex number
local SewReport = {}
SewReport.__index = SewReport
M.SewReport = SewReport

--- This brep with its free edges sewn, and what was sewn: a new `Brep` (yours to
--- `release()`) and a `SewReport`; this one is left as it was. Two free edges become one
--- shared edge where both their ends coincide within `vertex` -- by default the rounding
--- `manifold` merges vertices at -- and their curves lie within `tolerance` of each
--- other, by default `vertex` too, so only edges that are one curve written twice are
--- joined. A larger `tolerance` also joins two curves between the same two vertices that
--- part by up to it; `vertex` is what decides which edges are candidates at all, and
--- raising it is what could close a slot. Nothing moves. `nil` takes the default.
---@param tolerance number|nil
---@param vertex number|nil
---@return Brep, SewReport
function Brep:sewed(tolerance, vertex)
  local counts = ffi.new("uint32_t[4]")
  local gaps = ffi.new("double[3]")
  local p = lib().cadaclysm_brep_sew(self.pointer, tolerance or 0 / 0, vertex or 0 / 0, counts, gaps)
  if p == nil then
    local reason = last_error()
    fail(reason ~= "" and reason or "sew", 2)
  end
  return setmetatable({ _ptr = ffi.gc(p, lib().cadaclysm_brep_release) }, Brep),
    setmetatable({
      pairs = counts[0], free_before = counts[1], free_after = counts[2], refused = counts[3],
      worst_gap = gaps[0], tolerance = gaps[1], vertex = gaps[2],
    }, SewReport)
end

--- Give the reference back now. Idempotent.
function Brep:release()
  local p = rawget(self, "_ptr")
  if p ~= nil then
    self._ptr = nil
    ffi.gc(p, nil)
    lib().cadaclysm_brep_release(p)
  end
end

-- ---- health and healing ----------------------------------------------------------

-- In a block of its own: only the report classes, `Brep:health`, `Brep:healed` and
-- `Brep:edge_tolerance` (and the decoders, for the tests) leave it.
do

--- One free edge (`HealthReport.free_edges`): a side only one face bounds, with its
--- nearest partner. `trim` the face's side, `edge` the edge it lies on (nil for a side
--- with no edge), `face` the face it bounds, `wire` its free wire (a number from zero
--- into `wires`), `partner` the nearest free edge across the gap as a number from zero
--- into `free_edges` (nil if there is none), `shared_ends` how many of its two ends it
--- shares with the partner (2 is what `Brep:sewed` joins), its `length` and the `gap`
--- to the partner (`math.huge` without one).
---@class FreeEdge
---@field trim integer
---@field edge integer|nil
---@field face integer
---@field wire integer
---@field partner integer|nil
---@field shared_ends integer
---@field length number
---@field gap number
local FreeEdge = {}
FreeEdge.__index = FreeEdge
M.FreeEdge = FreeEdge

--- A chain of free edges end to end (`HealthReport.wires`): the rows `first` to
--- `first + count` (from zero) of `free_edges`, whether it `closed` on itself, its total
--- `length` and the `widest_gap` from any of its edges to a partner.
---@class FreeWire
---@field first integer
---@field count integer
---@field closed boolean
---@field length number
---@field widest_gap number
local FreeWire = {}
FreeWire.__index = FreeWire
M.FreeWire = FreeWire

--- Something below the tolerance (`HealthReport.small`): `kind` is "short_edge",
--- "collapsed_edge", "sliver_face", "tiny_face", "tiny_body" or "small_hole"; `index` its
--- edge, face or body number (a small hole's is its loop number); `size` how small.
---@class SmallFeature
---@field kind string
---@field index integer
---@field size number
local SmallFeature = {}
SmallFeature.__index = SmallFeature
M.SmallFeature = SmallFeature

--- What a mesh of the body shows (`Brep:health(tolerance, true)`): whether it is
--- `watertight`, how many mesh edges are `open` (one triangle) or `folded` (more than
--- two), how many pairs of triangles pass through each other (`crossings`), and the
--- brep `edges` the cracks lie along. Only a closed body is counted.
---@class Cracks
---@field watertight boolean
---@field open integer
---@field folded integer
---@field crossings integer
---@field edges integer[]
local Cracks = {}
Cracks.__index = Cracks
M.Cracks = Cracks

--- What is wrong with a body, as plain data (`Brep:health`): the `tolerance` and
--- `rounding` it judged at and the body's `extent` (its diagonal); the `free_edges`,
--- their `wires`, the features below the tolerance (`small`); the `loose_edges`
--- (`worst_loose` the widest gap among them); what sewing would do (`sew_pairs` joined,
--- `sew_refused` groups left, `sew_worst_gap`); `worst_gap`, the widest gap between a
--- free edge and its partner; and, if asked for, the mesh's `cracks` (nil otherwise).
---@class HealthReport
---@field tolerance number
---@field rounding number
---@field extent number
---@field free_edges FreeEdge[]
---@field wires FreeWire[]
---@field small SmallFeature[]
---@field loose_edges integer
---@field worst_loose number
---@field sew_pairs integer
---@field sew_refused integer
---@field sew_worst_gap number
---@field cracks Cracks|nil
---@field worst_gap number
local HealthReport = {}
HealthReport.__index = HealthReport
M.HealthReport = HealthReport

--- The free edges of wire number `wire` (from zero, as `FreeEdge.wire` numbers it), in order.
---@param wire integer
---@return FreeEdge[]
function HealthReport:wire_edges(wire)
  local w = type(wire) == "number" and self.wires[wire + 1] or nil
  if w == nil then fail(("wire_edges: no wire %s (%d wires)"):format(tostring(wire), #self.wires), 2) end
  local out = {}
  for i = 1, w.count do out[i] = self.free_edges[w.first + i] end
  return out
end

--- One small feature `Brep:healed` removed: its `kind` (as `SmallFeature.kind`), its
--- `index` in the input (as `health` gave it), its `size`, and how far the vertices it
--- merged `moved`.
---@class HealFix
---@field kind string
---@field index integer
---@field size number
---@field moved number
local HealFix = {}
HealFix.__index = HealFix
M.HealFix = HealFix

--- One small feature `Brep:healed` left, and why: `kind` and `index` as in `HealFix`;
--- `why` is "would_empty_loop", "closed", "seam", "chain", "neighbours_part", "uneven",
--- "non_manifold", "has_holes", "body_guard", "toggled" or "unsupported"; `figure` the
--- chain's width or the neighbours' gap, else 0.
---@class HealRefusal
---@field kind string
---@field index integer
---@field why string
---@field figure number
local HealRefusal = {}
HealRefusal.__index = HealRefusal
M.HealRefusal = HealRefusal

--- What `Brep:healed` did, as plain data: the `tolerance` it healed at, the furthest any
--- trim `moved`, whether the body guard refused fixes (`guarded`), the `fixes` made and the
--- features `refused`; and the body's health before and after at that tolerance -- its
--- small features, free edges, whether it is closed, and its non-manifold edges.
---@class HealReport
---@field tolerance number
---@field moved number
---@field guarded boolean
---@field fixes HealFix[]
---@field refused HealRefusal[]
---@field small_before integer
---@field small_after integer
---@field free_before integer
---@field free_after integer
---@field closed_before boolean
---@field closed_after boolean
---@field nonmanifold_before integer
---@field nonmanifold_after integer
local HealReport = {}
HealReport.__index = HealReport
M.HealReport = HealReport

local NO_ID = 0xFFFFFFFF
local KINDS = { [0] = "short_edge", "collapsed_edge", "sliver_face", "tiny_face", "tiny_body", "small_hole" }
local WHYS = { [0] = "would_empty_loop", "closed", "seam", "chain", "neighbours_part", "uneven", "non_manifold",
  "has_holes", "body_guard", "toggled", "unsupported" }

local function named(table_, code, what)
  local name = table_[code]
  if name == nil then fail(what .. ": the library sent an unknown code " .. tostring(code), 3) end
  return name
end

-- The flat rows of the health C ABI (Lua lists from one) as a `HealthReport`: Python's
-- `_health_report`, index for index.
local function health_report(counts, sizes, free_ids, free_sizes, wire_runs, wire_sizes, small_items, small_sizes,
                             crack_edges)
  local free = {}
  for i = 0, math.floor(#free_ids / 6) - 1 do
    local b, s = 6 * i, 2 * i
    local edge, partner = free_ids[b + 2], free_ids[b + 5]
    free[i + 1] = setmetatable({
      trim = free_ids[b + 1], edge = edge ~= NO_ID and edge or nil, face = free_ids[b + 3], wire = free_ids[b + 4],
      partner = partner ~= NO_ID and partner or nil, shared_ends = free_ids[b + 6],
      length = free_sizes[s + 1], gap = free_sizes[s + 2],
    }, FreeEdge)
  end
  local wires = {}
  for i = 0, math.floor(#wire_runs / 3) - 1 do
    wires[i + 1] = setmetatable({
      first = wire_runs[3 * i + 1], count = wire_runs[3 * i + 2], closed = wire_runs[3 * i + 3] ~= 0,
      length = wire_sizes[2 * i + 1], widest_gap = wire_sizes[2 * i + 2],
    }, FreeWire)
  end
  local small = {}
  for i = 0, #small_sizes - 1 do
    small[i + 1] = setmetatable({
      kind = named(KINDS, small_items[2 * i + 1], "health"), index = small_items[2 * i + 2], size = small_sizes[i + 1],
    }, SmallFeature)
  end
  local cracks
  if counts[13] == 1 then
    local edges = {}
    for i, e in ipairs(crack_edges) do edges[i] = e end
    cracks = setmetatable({
      watertight = counts[14] ~= 0, open = counts[15], folded = counts[16], crossings = counts[17], edges = edges,
    }, Cracks)
  end
  return setmetatable({
    tolerance = sizes[1], rounding = sizes[2], extent = sizes[3], worst_gap = sizes[4],
    free_edges = free, wires = wires, small = small,
    loose_edges = counts[10], worst_loose = sizes[5], sew_pairs = counts[11], sew_refused = counts[12],
    sew_worst_gap = sizes[6], cracks = cracks,
  }, HealthReport)
end
M._health_report = health_report

-- The flat rows of the heal C ABI as a `HealReport`: Python's `_heal_report`.
local function heal_report(counts, sizes, fix_items, fix_sizes, refused_items, refused_sizes)
  local fixes = {}
  for i = 0, math.floor(#fix_items / 2) - 1 do
    fixes[i + 1] = setmetatable({
      kind = named(KINDS, fix_items[2 * i + 1], "healed"), index = fix_items[2 * i + 2],
      size = fix_sizes[2 * i + 1], moved = fix_sizes[2 * i + 2],
    }, HealFix)
  end
  local refused = {}
  for i = 0, #refused_sizes - 1 do
    refused[i + 1] = setmetatable({
      kind = named(KINDS, refused_items[3 * i + 1], "healed"), index = refused_items[3 * i + 2],
      why = named(WHYS, refused_items[3 * i + 3], "healed"), figure = refused_sizes[i + 1],
    }, HealRefusal)
  end
  return setmetatable({
    tolerance = sizes[1], moved = sizes[2], guarded = counts[3] ~= 0, fixes = fixes, refused = refused,
    small_before = counts[4], small_after = counts[5], free_before = counts[6], free_after = counts[7],
    closed_before = counts[8] ~= 0, closed_after = counts[9] ~= 0,
    nonmanifold_before = counts[10], nonmanifold_after = counts[11],
  }, HealReport)
end
M._heal_report = heal_report

-- `n` elements of a C array as a Lua list.
local function listed(arr, n)
  local out = {}
  for i = 1, n do out[i] = tonumber(arr[i - 1]) end
  return out
end

local function refused_by(what)
  local reason = last_error()
  fail(reason ~= "" and reason or what, 3)
end

-- `tolerance` as the C ABI takes it: nil is NaN, the default.
local function tolerance_of(tolerance, what)
  if tolerance == nil then return 0 / 0 end
  if type(tolerance) ~= "number" then fail(what .. ": tolerance must be a number, got " .. tostring(tolerance), 3) end
  return tolerance
end

--- What is wrong with this brep, as a `HealthReport`: the free edges (the sides one face
--- bounds) and the wires they chain into, with each edge's nearest partner and the gap to
--- it; the features below `tolerance`; the loose edges; and what `sewed` would join and
--- leave. `tolerance` is the length below which a feature is "small" and a gap closes --
--- nil, or a value that is not finite and positive, takes the default, `1e-4` times the
--- diagonal (the report shows what was used). `mesh` true also meshes the brep and reports
--- where the mesh cracks (`cracks`); without it `cracks` is nil. Nothing moves.
---@param tolerance number|nil
---@param mesh boolean|nil
---@return HealthReport
function Brep:health(tolerance, mesh)
  local pointer = self.pointer
  local L = lib()
  local h = L.cadaclysm_brep_health(pointer, tolerance_of(tolerance, "health"), mesh and true or false)
  if h == nil then refused_by("health") end
  local ok, report = pcall(function()
    local counts, sizes = ffi.new("uint32_t[18]"), ffi.new("double[8]")
    if not L.cadaclysm_brep_health_summary(h, counts, sizes) then refused_by("health") end
    local n = tonumber(L.cadaclysm_brep_health_free_edges(h, nil, nil))
    local free_ids, free_sizes = ffi.new("uint32_t[?]", 6 * n + 1), ffi.new("double[?]", 2 * n + 1)
    if n > 0 then L.cadaclysm_brep_health_free_edges(h, free_ids, free_sizes) end
    local w = tonumber(L.cadaclysm_brep_health_wires(h, nil, nil))
    local wire_runs, wire_sizes = ffi.new("uint32_t[?]", 3 * w + 1), ffi.new("double[?]", 2 * w + 1)
    if w > 0 then L.cadaclysm_brep_health_wires(h, wire_runs, wire_sizes) end
    local s = tonumber(L.cadaclysm_brep_health_small(h, nil, nil))
    local small_items, small_sizes = ffi.new("uint32_t[?]", 2 * s + 1), ffi.new("double[?]", s + 1)
    if s > 0 then L.cadaclysm_brep_health_small(h, small_items, small_sizes) end
    local c = tonumber(L.cadaclysm_brep_health_crack_edges(h, nil))
    local crack_ids = ffi.new("uint32_t[?]", c + 1)
    if c > 0 then L.cadaclysm_brep_health_crack_edges(h, crack_ids) end
    return health_report(listed(counts, 18), listed(sizes, 8), listed(free_ids, 6 * n), listed(free_sizes, 2 * n),
      listed(wire_runs, 3 * w), listed(wire_sizes, 2 * w), listed(small_items, 2 * s), listed(small_sizes, s),
      listed(crack_ids, c))
  end)
  L.cadaclysm_brep_health_free(h)
  if not ok then error(report, 0) end
  return report
end

--- This brep with its small features removed, and what was done: a new `Brep` (yours to
--- `release()`) and a `HealReport`; this one is left as it was. The features are the ones
--- `health` lists as small at `tolerance`: short and collapsed edges, sliver and tiny
--- faces, small holes. Every fix is a vertex merge, and an edge it moves records how far as
--- its `edge_tolerance`. A guard compares the result's health with this one's and refuses
--- fixes that made it worse (`guarded`). `edges`, `faces` and `holes` (each true unless
--- `false`) switch each kind of fix; a kind switched off is refused as "toggled".
--- `tolerance` nil, or a value that is not finite and positive, takes the default.
---@param tolerance number|nil
---@param edges boolean|nil
---@param faces boolean|nil
---@param holes boolean|nil
---@return Brep, HealReport
function Brep:healed(tolerance, edges, faces, holes)
  local pointer = self.pointer
  local L = lib()
  local flags = (edges ~= false and 1 or 0) + (faces ~= false and 2 or 0) + (holes ~= false and 4 or 0)
  local h = L.cadaclysm_brep_healed(pointer, tolerance_of(tolerance, "healed"), flags)
  if h == nil then refused_by("healed") end
  local ok, body, report = pcall(function()
    local counts, sizes = ffi.new("uint32_t[11]"), ffi.new("double[2]")
    if not L.cadaclysm_brep_heal_summary(h, counts, sizes) then refused_by("healed") end
    local n = tonumber(L.cadaclysm_brep_heal_fixes(h, nil, nil))
    local fix_items, fix_sizes = ffi.new("uint32_t[?]", 2 * n + 1), ffi.new("double[?]", 2 * n + 1)
    if n > 0 then L.cadaclysm_brep_heal_fixes(h, fix_items, fix_sizes) end
    local r = tonumber(L.cadaclysm_brep_heal_refused(h, nil, nil))
    local refused_items, refused_sizes = ffi.new("uint32_t[?]", 3 * r + 1), ffi.new("double[?]", r + 1)
    if r > 0 then L.cadaclysm_brep_heal_refused(h, refused_items, refused_sizes) end
    local made = heal_report(listed(counts, 11), listed(sizes, 2), listed(fix_items, 2 * n), listed(fix_sizes, 2 * n),
      listed(refused_items, 3 * r), listed(refused_sizes, r))
    local p = L.cadaclysm_brep_heal_body(h)
    if p == nil then refused_by("healed") end
    return setmetatable({ _ptr = ffi.gc(p, L.cadaclysm_brep_release) }, Brep), made
  end)
  L.cadaclysm_brep_heal_free(h)
  if not ok then error(body, 0) end
  return body, report
end

--- How far brep edge `edge` (as a `HealFix` or `FreeEdge` names one) may lie off its
--- curve: 0 for an exact edge, the distance healing (or sewing) moved it where that is
--- recorded, nil when no trim names the id (an edge healing removed). `edge` is a whole
--- number from 0 to 4294967295.
---@param edge integer
---@return number|nil
function Brep:edge_tolerance(edge)
  local pointer = self.pointer
  if type(edge) ~= "number" or edge ~= math.floor(edge) or edge < 0 or edge > 4294967295 then
    fail("edge_tolerance: edge must be a whole number from 0 to 4294967295, got " .. tostring(edge), 2)
  end
  local t = lib().cadaclysm_brep_edge_tolerance(pointer, edge)
  if t ~= t then return nil end
  return t
end

end

-- ---- meshlets --------------------------------------------------------------------

--- A mesh split into meshlets, optionally with coarser levels above them, for a
--- mesh-shader or meshlet-based renderer. Built from any mesh and owned by you:
--- `free()` it (the collector does otherwise).
---@class Meshlets
---@field count integer
---@field freed boolean
local Meshlets_get = {}
local Meshlets = class(Meshlets_get)
M.Meshlets = Meshlets

local function meshlets_handle(self)
  local p = rawget(self, "_ptr")
  if p == nil then fail("meshlets: freed", 3) end
  return p
end

--- A `const float *`/`const uint32_t *` as the C call wants it, from cdata handed out
--- by this module or from a Lua table of numbers (copied into `ctype`).
local function c_array(value, ctype)
  if value == nil then return nil end
  if type(value) == "table" then return ffi.new(ctype .. "[?]", #value, value) end
  return value
end

--- Split `positions` (three floats a vertex), `normals` (the same, or nil) and
--- `indices` (three a triangle) -- cdata as `mesh.positions` hands them out, or Lua
--- tables -- into meshlets of at most `max_triangles` and `max_vertices` each: the
--- consumer's own limits, with no default (Nanite 128/256, mesh shaders 124/64).
--- `vertex_count` and `index_count` say how long the arrays are (cdata carries no
--- length); a Lua table whose length disagrees with them fails before the library is
--- called. `levels` above 0 groups and simplifies each level into the next until one
--- meshlet is left.
function Meshlets.build(positions, normals, indices, vertex_count, index_count, max_triangles, max_vertices, levels)
  if not (max_triangles and max_triangles > 0 and max_vertices and max_vertices > 0) then
    fail("meshlets: max_triangles and max_vertices are required", 2)
  end
  if index_count % 3 ~= 0 then fail("meshlets: indices must hold three a triangle", 2) end
  if type(positions) == "table" and #positions ~= vertex_count * 3 then
    fail("meshlets: positions holds " .. #positions .. " floats, not vertex_count * 3", 2)
  end
  if type(normals) == "table" and #normals ~= vertex_count * 3 then
    fail("meshlets: normals holds " .. #normals .. " floats, not vertex_count * 3", 2)
  end
  if type(indices) == "table" and #indices ~= index_count then
    fail("meshlets: indices holds " .. #indices .. " entries, not index_count", 2)
  end
  local p, n, i = c_array(positions, "float"), c_array(normals, "float"), c_array(indices, "uint32_t")
  local ptr = lib().cadaclysm_meshlets_build(p, n, vertex_count, i, index_count, max_triangles, max_vertices, levels or 0)
  if ptr == nil then
    local reason = last_error()
    fail(reason ~= "" and reason or "meshlets: build failed", 2)
  end
  return setmetatable({ _ptr = ffi.gc(ptr, lib().cadaclysm_meshlets_free) }, Meshlets)
end

--- Whether `free()` has run.
function Meshlets_get.freed(self) return rawget(self, "_ptr") == nil end
--- How many meshlets, every level counted.
function Meshlets_get.count(self) return lib().cadaclysm_meshlets_count(meshlets_handle(self)) end

--- Give the meshlets back. Idempotent.
function Meshlets:free()
  local p = rawget(self, "_ptr")
  if p ~= nil then
    self._ptr = nil
    ffi.gc(p, nil)
    lib().cadaclysm_meshlets_free(p)
  end
end

function Meshlets:triangle_count(i) return lib().cadaclysm_meshlet_triangle_count(meshlets_handle(self), i) end
function Meshlets:vertex_count(i) return lib().cadaclysm_meshlet_vertex_count(meshlets_handle(self), i) end
--- 0 for a leaf over the mesh itself, higher for a simplified level above it.
function Meshlets:level(i) return lib().cadaclysm_meshlet_level(meshlets_handle(self), i) end
function Meshlets:group(i) return lib().cadaclysm_meshlet_group(meshlets_handle(self), i) end
--- How far this meshlet's level moved the surface; zero at level 0.
function Meshlets:error(i) return lib().cadaclysm_meshlet_error(meshlets_handle(self), i) end
function Meshlets:child_count(i) return lib().cadaclysm_meshlet_child_count(meshlets_handle(self), i) end

---@class Meshlet
---@field index integer
---@field level integer
---@field group integer
---@field error number
---@field vertex_count integer
---@field triangle_count integer
---@field positions number[]
---@field normals number[]
---@field indices integer[]
---@field children integer[]
--- One meshlet's arrays and numbers, copied out as Lua tables.
function Meshlets:meshlet(i)
  local L, h = lib(), meshlets_handle(self)
  local vertices, triangles, kids = L.cadaclysm_meshlet_vertex_count(h, i), L.cadaclysm_meshlet_triangle_count(h, i), L.cadaclysm_meshlet_child_count(h, i)
  local positions, normals = ffi.new("float[?]", math.max(1, vertices * 3)), ffi.new("float[?]", math.max(1, vertices * 3))
  local indices, children = ffi.new("uint32_t[?]", math.max(1, triangles * 3)), ffi.new("uint32_t[?]", math.max(1, kids))
  L.cadaclysm_meshlet_positions(h, i, positions)
  L.cadaclysm_meshlet_normals(h, i, normals)
  L.cadaclysm_meshlet_indices(h, i, indices)
  L.cadaclysm_meshlet_children(h, i, children)
  local function tbl(c, n) local t = {} for k = 0, n - 1 do t[k + 1] = c[k] end return t end
  return {
    index = i, level = L.cadaclysm_meshlet_level(h, i), group = L.cadaclysm_meshlet_group(h, i), error = L.cadaclysm_meshlet_error(h, i),
    vertex_count = vertices, triangle_count = triangles,
    positions = tbl(positions, vertices * 3), normals = tbl(normals, vertices * 3), indices = tbl(indices, triangles * 3), children = tbl(children, kids),
  }
end

-- ---- the FEM surface mesh ---------------------------------------------------------

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
--- mesh edge between them, a crack along the edge or a stretch of it the mesher
--- sampled on one face only. `{0}` is the ordinary answer, and a caller reading
--- `nodes` as one polyline without looking here silently jumps the gap.
---
--- `faces` is `{face_a, face_b}` and `ends` is `{end_a, end_b}`, the second of each
--- `cadaclysm.NONE` where there is none -- an open body's rim, or both ends at one
--- vertex (a closed edge, a circle's rim, a full-turn seam). **`0` is a real face and
--- a real vertex, not a sentinel.** Which end comes first is the first trim's
--- direction and means nothing else: the pair bounds the edge, it does not orient it.
--- `ends` index `FemMesh.edges`' own `vertices` list from zero, so the vertex of
--- `e.ends[1]` is `mesh.vertices[e.ends[1] + 1]`.
---
--- `closed` where the nodes make one loop -- never where there is more than one run.
--- `seam` where one face bounds the edge twice, a closed surface's seam rather than a
--- real boundary; both `faces` are then that same face.
---
--- `id` is **the body's own edge id**, not this mesh's edge index: `FemMesh.edges` is
--- a densely renumbered subset of the body's edges, ascending by id, with every edge
--- collapsed to a point left out, so edge 0 of a STEP body's mesh routinely has an
--- `id` in the hundreds. Everything else that names an edge here means the index -- a
--- `node_kind` of 1 read through `node_entity`, the third number of an `open_edges` or
--- `folded_edges` row, and the `edge_<i>` physical group of `msh_text()` -- and this is
--- the one way back from any of them to the topology the file wrote.
---@class FemEdge
---@field id integer  the body's own B-rep edge id, not this mesh's edge index
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
--- which together hold exactly `nodes` in order. One entry for the ordinary
--- single-run edge, and the place the zero-based `runs` are turned into Lua's own
--- one-based slices -- do that by hand and an off-by-one drops or repeats a node.
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
--- `node` is the mesh node at this vertex, or `cadaclysm.NONE` where the mesh has none
--- there. **A sentinel here is ordinary, not a fault**: the analysis rebuilds a vertex
--- wherever two trims meet, and a pole's polyline runs give a sphere 48 of them where
--- the mesh has 2 points, so a caller walking these skips the sentinel rather than
--- treating it as a gap.
---
--- `point` is `{x, y, z}` where the vertex is, in the same space and under the same
--- placement as `FemMesh.nodes` -- the file's own vertex rather than a mesh node, so
--- the two can differ by the reader's rounding. **Meaningless unless `has_position`**:
--- it is `{0, 0, 0}` then, which is a point no geometry has and which a solver would
--- take for a node at the origin.
---@class FemVertex
---@field node integer  the mesh node there, or `cadaclysm.NONE`
---@field point number[]  {x, y, z}, meaningless unless `has_position`
---@field has_position boolean
local FemVertex = {}
FemVertex.__index = FemVertex
M.FemVertex = FemVertex
FemVertex.__tostring = function(v)
  return ("FemVertex(node=%d, point=(%g, %g, %g), has_position=%s)")
    :format(v.node, v.point[1], v.point[2], v.point[3], tostring(v.has_position))
end

--- One body meshed for a solver: nodes welded by bits, triangles wound outward, every
--- node tagged with the lowest-dimension B-rep entity it lies on, and every crack
--- reported rather than closed. What `node:fem_mesh()` returns, and **owned by you**:
--- `free()` it (the collector does otherwise).
---
--- **The five flat arrays are the library's own memory, lent as they are**: `nodes` is
--- a `const double *`, three a node; `triangles` a `const uint32_t *`, three a
--- triangle and counting from zero; `triangle_face`, `node_kind` and `node_entity`
--- `const uint32_t *` one per triangle or per node. No copy, which is what makes a
--- million-element solver mesh affordable. They are **fields filled when the mesh was
--- built**, as a `Mesh`'s are, with the mesh itself standing where a `Mesh`'s `scene`
--- stands: the owner of every one of them is this object and not the scene, so
--- `scene:close()` neither frees this mesh nor stales it, and neither does meshing the
--- body again -- only `free()`, or the collector reclaiming the handle.
---
--- **So hold the FemMesh for as long as you read one of its arrays.** Because they are
--- plain fields rather than accessors, nothing here refuses a read after `free()`: a
--- pointer taken out of one is a bare cdata pointer into memory the library has given
--- back, and reading it reads whatever is there by then. There is no `copy()` here, as
--- `Mesh` has: read the numbers you want into a Lua table while the mesh is still yours.
--- The methods below *do* refuse, naming themselves. This is the same sharp edge the
--- note at the top of this file documents for the scene's own views, and it is
--- documented rather than enforced for the same reason.
---
--- `edges`, `vertices`, `open_edges`, `folded_edges` and `crossings` are computed when
--- read, one C call a row, and are copies: read them once into a local rather than
--- inside a loop.
---@class FemMesh
---@field nodes ffi.cdata*  const double *, 3 a node
---@field node_count integer
---@field triangles ffi.cdata*  const uint32_t *, 3 a triangle, from zero
---@field triangle_count integer
---@field triangle_face ffi.cdata*  const uint32_t *, one a triangle
---@field node_kind ffi.cdata*  const uint32_t *, one a node: 0 a vertex, 1 an edge, 2 a face
---@field node_entity ffi.cdata*  const uint32_t *, one a node, read by its `node_kind`
---@field face_count integer  the body's faces
---@field watertight boolean
---@field from_mesh boolean
---@field min_angle number  the smallest interior angle of any triangle, in degrees
---@field worst_triangle integer  the triangle with that angle, into `triangles`
---@field longest_edge number  the longest triangle edge, placed
local FemMesh_get = {}
local FemMesh = class(FemMesh_get)
M.FemMesh = FemMesh

local function fem_handle(self)
  local p = rawget(self, "_ptr")
  if p == nil then fail("fem mesh: freed", 3) end
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
    lib().cadaclysm_fem_mesh_free(p)
  end
end

-- A `const uint32_t *` of `count` entries as a Lua array (from one) of the library's
-- own numbers (from zero): a copy, so it outlives the handle.
local function fem_indices(ptr, count)
  local out = {}
  for i = 0, count - 1 do out[i + 1] = ptr[i] end
  return out
end

--- One `FemEdge` per B-rep edge, in the order a `node_kind` of 1 indexes them. Empty
--- for a `from_mesh` body, which has no B-rep edges at all. **This list's own
--- numbering, not the body's**: each `FemEdge.id` carries the body's own edge id.
function FemMesh_get.edges(self)
  local L, handle, raw, out = lib(), fem_handle(self), ffi.new("struct CadaclysmFemEdge"), {}
  for i = 0, self._edge_count - 1 do
    if not L.cadaclysm_fem_mesh_edge(handle, i, raw) then
      local reason = last_error()
      fail(reason ~= "" and reason or ("fem mesh edge " .. i), 2)
    end
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
--- Empty for a `from_mesh` body.
function FemMesh_get.vertices(self)
  local L, handle, raw, out = lib(), fem_handle(self), ffi.new("struct CadaclysmFemVertex"), {}
  for i = 0, self._vertex_count - 1 do
    if not L.cadaclysm_fem_mesh_vertex(handle, i, raw) then
      local reason = last_error()
      fail(reason ~= "" and reason or ("fem mesh vertex " .. i), 2)
    end
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
    if not row(handle, i, a, b, edge) then
      local reason = last_error()
      fail(reason ~= "" and reason or (what .. " " .. i), 3)
    end
    out[#out + 1] = { a[0], b[0], edge[0] }
  end
  return out
end

--- Every crack, as `{a, b, brep_edge}`: a directed mesh edge `{a, b}` with no `{b, a}`,
--- and the B-rep edge both nodes lie on, or `cadaclysm.NONE` where they share none.
---
--- **Empty unless the body's topology is closed -- for a B-rep body**, whose mesh is
--- otherwise not asked about at all: such a body reports `watertight` false with this
--- and `folded_edges` both empty, and *that trio together* says "not asked", not
--- "nothing found".
---
--- **A `from_mesh` body is the other case, and the opposite one.** A bare mesh carries
--- no topology to say whether it ought to close, so its census always runs over the
--- welded triangles: an open render mesh reports its cracks here with `watertight`
--- false, a closed one reports `watertight` true, and an empty census there really
--- does mean "nothing found".
function FemMesh_get.open_edges(self)
  local L = lib()
  return fem_census(self, function(h, i, a, b, e) return L.cadaclysm_fem_mesh_open_edge(h, i, a, b, e) end,
    self._open_edge_count, "fem mesh open edge")
end

--- Every fold, as `open_edges` reports a crack: a directed mesh edge used by more than
--- one triangle.
---
--- **A body can be folded without being open**, and the closure census's own pinned
--- rows are folds rather than open cracks -- a solid no thicker than a line leaves no
--- hole for an open edge to find. A caller that checks only `open_edges` calls such a
--- body sound. Empty under the same rule as `open_edges`.
function FemMesh_get.folded_edges(self)
  local L = lib()
  return fem_census(self, function(h, i, a, b, e) return L.cadaclysm_fem_mesh_folded_edge(h, i, a, b, e) end,
    self._folded_edge_count, "fem mesh folded edge")
end

--- Every pair of triangles that pass through each other, as `{a, b}` with `a < b`,
--- sorted: an edge of one through the other's interior. Their B-rep faces are
--- `triangle_face[a]` and `[b]`.
---
--- **Computed for every body, open or closed.** The census `watertight`, `open_edges`
--- and `folded_edges` report is topological and cannot see a surface passing through
--- itself; a mesh is ready for a volume mesher when it is `watertight` **and** this is
--- empty -- Gmsh refuses one that crosses. A copy.
function FemMesh_get.crossings(self)
  local L = lib()
  local handle = fem_handle(self)
  local count = L.cadaclysm_fem_mesh_crossing_count(handle)
  local a, b = ffi.new("uint32_t[1]"), ffi.new("uint32_t[1]")
  local out = {}
  for i = 0, count - 1 do
    if not L.cadaclysm_fem_mesh_crossing(handle, i, a, b) then
      local reason = last_error()
      fail(reason ~= "" and reason or ("fem mesh crossing " .. i), 3)
    end
    out[#out + 1] = { a[0], b[0] }
  end
  return out
end

--- The mesh as Gmsh 4.1 ASCII `.msh` text: an entity per B-rep vertex, edge and face,
--- a volume where the body closes, and a physical group naming each.
---
--- **On this side of the ABI the library's text is borrowed** -- a slot on this handle,
--- replaced by the next call on it and gone when the mesh is freed. It is copied out
--- here, so what you hold is a Lua string of your own that outlives the handle, and
--- nothing has to be freed. `cadaclysm_blacksmith.FemMesh.msh_text` is the other way
--- round: an owned string the wrapper releases, two asks giving two independent texts.
--- A reader porting one side's reasoning onto the other leaks or double-frees.
---
--- **No unlicensed notice is printed here.** `node:fem_mesh()` gave it once when the
--- mesh was built, and this ABI deliberately does not repeat it on either `.msh` call
--- -- where the kernel library notices on both of its writers and *not* on its
--- builder. Each matches its own siblings, so moving the call to look like the other
--- side would break a convention.
---
--- Raises `CadaclysmError` for a mesh the writer refuses, naming the field it cannot
--- honour, and for a freed handle.
function FemMesh:msh_text()
  local p = lib().cadaclysm_fem_mesh_msh_text(fem_handle(self))
  if p == nil then
    local reason = last_error()
    fail(reason ~= "" and reason or "msh text", 2)
  end
  return ffi.string(p)
end

--- `msh_text()` written to `path` by the library itself: the same bytes from the same
--- writer, straight to the file rather than through the borrowed slot, so a
--- `msh_text()` call on this handle from another thread cannot free the text under the
--- write. Raises `CadaclysmError` for a mesh the writer refuses or a file it cannot
--- write, naming the path. No notice here either; see `msh_text`.
function FemMesh:save_msh(path)
  if not lib().cadaclysm_fem_mesh_save_msh(fem_handle(self), tostring(path)) then
    local reason = last_error()
    fail(reason ~= "" and reason or ("could not write " .. tostring(path)), 2)
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
  local raw = ffi.new("struct CadaclysmFemMeshView")
  if not lib().cadaclysm_fem_mesh_view(ptr, raw) then
    local reason = last_error()
    lib().cadaclysm_fem_mesh_free(ptr)
    fail(reason ~= "" and reason or "fem mesh view", 3)
  end
  return setmetatable({
    _ptr = ffi.gc(ptr, lib().cadaclysm_fem_mesh_free),
    nodes = null_to_nil(raw.nodes),
    node_count = raw.node_count,
    triangles = null_to_nil(raw.triangles),
    triangle_count = raw.triangle_count,
    triangle_face = null_to_nil(raw.triangle_face),
    node_kind = null_to_nil(raw.node_kind),
    node_entity = null_to_nil(raw.node_entity),
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

-- ---- svg -----------------------------------------------------------------------------

--- The seven camera angles `svg_text`/`svg`'s `view=` understands, as (azimuth,
--- elevation) in degrees -- the same table `cadaclysm_view.VIEWS` gives
--- Python's `show()` and `svg()` both.
local SVG_VIEWS = {
  front = { -90, 0 }, back = { 90, 0 }, left = { 180, 0 }, right = { 0, 0 },
  top = { -90, 90 }, bottom = { -90, -90 }, iso = { -50, 28 },
}

--- `CadaclysmSvgOptions.background`'s "none" value: no `<rect>` behind the
--- drawing, the page left to whatever the viewer composites it onto.
local SVG_TRANSPARENT = 0xffffffff

-- r, g, b in 0..1 from colour text -- "#rgb", "#rrggbb" or a CSS colour name -- read by the
-- library's own parser; nil if it refused the text.
local function colour_text(text)
  local out = ffi.new("double[3]")
  if lib().cadaclysm_parse_colour(text, out) then return out[0], out[1], out[2] end
  return nil
end

--- A colour as the ABI's packed `0xRRGGBB`: `"#rrggbb"`, a CSS colour name or a `{r, g,
--- b}` table (0..255). `what` names the field in the error, e.g. "svg: stroke".
local function svg_colour(colour, what)
  if type(colour) == "string" then
    local r, g, b = colour_text(colour)
    if r then
      return math.floor(r * 255 + 0.5) * 65536 + math.floor(g * 255 + 0.5) * 256 + math.floor(b * 255 + 0.5)
    end
    fail(("%s: a colour is \"#rgb\", \"#rrggbb\", a CSS colour name or {r, g, b} in 0..255, not '%s'")
      :format(what, colour), 3)
  end
  return bit.bor(bit.lshift(math.floor(colour[1]), 16), bit.lshift(math.floor(colour[2]), 8), math.floor(colour[3]))
end

--- `words` (a table: `view=`, `az=`, `el=`, `up=`, `fov=`, `size=` ({width,
--- height}), `margin=`, `tolerance=`, `stroke=`, `width=` (the stroke's),
--- `background=`, `edges=`, `curves=`, `isocurves=`, `polylines=`) packed
--- into a `CadaclysmSvgOptions`. `default_up` is `"y"` or `"z"`, what `up=`
--- falls back to when left out.
local function svg_options(default_up, words)
  words = words or {}
  local view = words.view or "iso"
  local angles = SVG_VIEWS[view]
  if not angles then
    fail(("view '%s': one of front, back, left, right, top, bottom, iso"):format(tostring(view)), 3)
  end
  local o = ffi.new("CadaclysmSvgOptions")
  lib().cadaclysm_svg_options_init(o)
  o.up = tostring(words.up or default_up):lower() == "y" and 1 or 0
  o.azimuth = words.az ~= nil and words.az or angles[1]
  o.elevation = words.el ~= nil and words.el or angles[2]
  o.fov = words.fov or 0.0
  local size = words.size or { 1000, 1000 }
  o.width, o.height = size[1], size[2]
  o.margin = words.margin or 0.05
  o.tolerance = words.tolerance or 0.1
  o.stroke = words.stroke ~= nil and svg_colour(words.stroke, "svg: stroke") or 0x000000
  o.stroke_width = words.width or 1.0
  o.background = words.background ~= nil and svg_colour(words.background, "svg: background") or SVG_TRANSPARENT
  local edges = words.edges
  if edges == nil then edges = true end
  -- `silhouettes` (16) is ON by default, as the library is: a sphere's and a torus's
  -- only curves are the seams where their one face meets itself, which are not edges
  -- of the body and are never drawn, so without the outline those two draw a blank
  -- page. A line set in its own right -- `silhouettes` with `edges = false` draws the
  -- outline alone, and `silhouettes = false` draws the lines alone.
  local silhouettes = words.silhouettes
  if silhouettes == nil then silhouettes = true end
  o.flags = bit.bor(edges and 1 or 0, words.curves and 2 or 0, words.isocurves and 4 or 0, words.polylines and 8 or 0,
                    silhouettes and 16 or 0)
  return o
end

-- ---- nodes -------------------------------------------------------------------------

local Node_get = {}
---@class Node
---@field scene Scene
---@field index integer  from zero
local Node = class(Node_get)
M.Node = Node

--- One node of the document: an assembly, a shape, a placement. A handle: every
--- field asks the scene when read, so nothing goes stale and nothing is built that is
--- never looked at. `scene` and `index` (from zero) are plain fields.
function Node.new(scene, index)
  return setmetatable({ scene = scene, index = index }, Node)
end
local node = Node.new

--- Draw this node: its scene by handle with the siblings along the path from its root hidden
--- (the ancestors' own geometry stays), framed on the node. Options as `Scene:show`.
function Node:show(options)
  return require(prefix .. "cadaclysm_view")._present(self, self.scene:_drawing(options), false)
end
--- Orbit this node as `Node:show` draws it; the camera it was left at and the last pick.
function Node:view(options)
  return require(prefix .. "cadaclysm_view")._present(self, self.scene:_drawing(options), true)
end

local function node_or_nil(scene, index)
  if index == M.NONE then return nil end
  return node(scene, index)
end

local function h(self) return self.scene:handle() end

function Node_get.name(self) return text(lib().cadaclysm_node_name(h(self), self.index)) end
--- What the file calls it: a STEP `#N`, an IFC GlobalId, a Rhino UUID.
function Node_get.id(self) return text(lib().cadaclysm_node_id(h(self), self.index)) end
--- What the file calls its type: an IFC entity, an openNURBS class, a shape kind.
function Node_get.kind(self) return text(lib().cadaclysm_node_kind(h(self), self.index)) end
--- The file's own opening state for this node alone; `visible_now` asks the ancestors.
function Node_get.visible(self) return lib().cadaclysm_node_visible(h(self), self.index) end
--- `visible`, with every ancestor consulted.
function Node_get.visible_now(self)
  local n = self
  while n do
    if not n.visible then return false end
    n = n.parent
  end
  return true
end
--- Whether the file says this cannot be selected (a Rhino object or its layer).
function Node_get.locked(self)
  for _, a in ipairs(self.attributes) do
    if a.name == "Locked" then return a.value and true or false end
  end
  return false
end
--- Something to put in a tree row: the name, else the kind, else `#index`.
function Node_get.label(self)
  local name = self.name
  if name ~= "" then return name end
  local kind = self.kind
  if kind ~= "" then return kind end
  return "#" .. self.index
end
--- How far down the tree it sits, a root being zero.
function Node_get.depth(self) return lib().cadaclysm_node_depth(h(self), self.index) end
--- What its geometry was before it was triangles: `brep`, `mesh`, `csg`, or empty.
function Node_get.generator(self) return text(lib().cadaclysm_node_generator(h(self), self.index)) end
--- The node containing this one, or nil for a root.
function Node_get.parent(self)
  return node_or_nil(self.scene, lib().cadaclysm_node_parent(h(self), self.index))
end
function Node_get.children(self)
  local L, handle, out = lib(), h(self), {}
  for i = 0, L.cadaclysm_node_child_count(handle, self.index) - 1 do
    out[#out + 1] = node(self.scene, L.cadaclysm_node_child(handle, self.index, i))
  end
  return out
end
--- The node whose geometry this one places, or nil: one mesh, many transforms.
function Node_get.instance_of(self)
  return node_or_nil(self.scene, lib().cadaclysm_node_instance_of(h(self), self.index))
end
--- What a click on this node's geometry should select -- itself, usually.
function Node_get.select_as(self)
  local chosen = lib().cadaclysm_node_select_as(h(self), self.index)
  if chosen == M.NONE then return self end
  return node(self.scene, chosen)
end
--- Everything the file said about this node, as Attributes.
function Node_get.attributes(self)
  local L, handle, out = lib(), h(self), {}
  for i = 0, L.cadaclysm_node_attribute_count(handle, self.index) - 1 do
    local a = attribute(L.cadaclysm_node_attribute(handle, self.index, i))
    if a then out[#out + 1] = a end
  end
  return out
end
--- Whether this node draws anything. Builds nothing.
function Node_get.can_mesh(self) return lib().cadaclysm_node_can_mesh(h(self), self.index) end
--- `{r, g, b, a}` if the file gave one, else nil.
function Node_get.colour(self)
  local rgba = ffi.new("float[4]")
  if not lib().cadaclysm_node_color(h(self), self.index, rgba) then return nil end
  return { rgba[0], rgba[1], rgba[2], rgba[3] }
end
--- Where its geometry sits, as a 4x4 `m[row][col]`; see `raw_transform`.
function Node_get.transform(self) return rows(self.raw_transform) end
--- The same matrix in the ABI's own order: 16 numbers, column-major.
function Node_get.raw_transform(self)
  local out = ffi.new("double[16]")
  lib().cadaclysm_node_transform(h(self), self.index, out)
  return sixteen(out)
end
--- The extent of what it draws, in its own frame. Builds the geometry.
function Node_get.bounds(self) return bounds(lib().cadaclysm_node_bounds(h(self), self.index)) end
--- `bounds` in `double`: the same box, unnarrowed. Not part of the mesh cache, so
--- unaffected by `scene:forget_meshes()`.
function Node_get.bounds64(self) return bounds64(lib().cadaclysm_node_bounds64(h(self), self.index)) end
--- Its triangles, in their own frame, built now if they have not been.
function Node_get.mesh(self) return mesh(self.scene, lib().cadaclysm_node_mesh(h(self), self.index)) end
--- `mesh` in `double`: the document's own mesh, lent as it is -- see `Mesh64`.
--- Invalidated by `scene:forget_meshes()`, unlike `mesh`.
function Node_get.mesh64(self) return mesh64(self.scene, lib().cadaclysm_node_mesh64(h(self), self.index)) end
--- Its triangles at a coarser level of detail: 0 is `mesh` itself, 1 up to
--- `lod_levels()` each about a quarter of the triangles of the one before, and past
--- that empty. Every level shares the level-0 vertices (the same `positions`, only
--- `indices` differ), so upload the vertices once and switch level by index range.
function Node:mesh_lod(level) return mesh(self.scene, lib().cadaclysm_node_mesh_lod(h(self), self.index, level)) end
--- How far `mesh_lod(level)` moved the surface, in the scene's units. Zero at level 0.
function Node:lod_error(level) return lib().cadaclysm_node_lod_error(h(self), self.index, level) end
--- Its faces as surfaces and trim loops, where the reader built them.
function Node_get.surfaces(self)
  return surfaces(self.scene, lib().cadaclysm_node_surfaces(h(self), self.index))
end
--- Its exact B-rep, shared, for `cadaclysm_blacksmith.Solid.from_node`; nil where
--- it has none (a mesh, a curve, a CSG body).
function Node_get.brep(self)
  local p = lib().cadaclysm_node_brep(h(self), self.index)
  if p == nil then return nil end
  return setmetatable({ _ptr = ffi.gc(p, lib().cadaclysm_brep_release) }, Brep)
end
--- Its feature edges, as polylines to draw an overlay from.
function Node_get.edges(self) return polylines(self.scene, lib().cadaclysm_node_edges(h(self), self.index)) end
--- One RGBA table per polyline of `edges`, `false` for an edge the file does not
--- style; empty when nothing is styled.
function Node_get.edge_colours(self) return edge_colours(lib().cadaclysm_node_edge_colors(h(self), self.index)) end
--- Its free curves, as polylines. A 2D drawing is all of these.
function Node_get.curves(self) return polylines(self.scene, lib().cadaclysm_node_curves(h(self), self.index)) end
--- Its interior surface lines, as polylines, so a curved face reads as curved.
function Node_get.isocurves(self)
  return polylines(self.scene, lib().cadaclysm_node_isocurves(h(self), self.index))
end
--- Its feature edges as cubic Bézier curves, exact where the file's curves were, where
--- `edges` are their chords. Builds the geometry if needed.
function Node_get.edge_beziers(self) return beziers(self.scene, lib().cadaclysm_node_edge_beziers(h(self), self.index)) end
--- `edge_beziers` in `double`; see `Beziers64`.
function Node_get.edge_beziers64(self) return beziers64(self.scene, lib().cadaclysm_node_edge_beziers64(h(self), self.index)) end
--- Its free curves as cubic Béziers; see `edge_beziers`.
function Node_get.curve_beziers(self) return beziers(self.scene, lib().cadaclysm_node_curve_beziers(h(self), self.index)) end
--- `curve_beziers` in `double`; see `Beziers64`.
function Node_get.curve_beziers64(self) return beziers64(self.scene, lib().cadaclysm_node_curve_beziers64(h(self), self.index)) end
--- Its isocurves as cubic Béziers; see `edge_beziers`.
function Node_get.isocurve_beziers(self) return beziers(self.scene, lib().cadaclysm_node_isocurve_beziers(h(self), self.index)) end
--- `isocurve_beziers` in `double`; see `Beziers64`.
function Node_get.isocurve_beziers64(self) return beziers64(self.scene, lib().cadaclysm_node_isocurve_beziers64(h(self), self.index)) end

--- The collision body for what this node draws, building its mesh if it is not built.
--- `hull_budget` is the most triangles a hull may have; 0 (the default) asks for the
--- Unity limit (255). `nil` for a node that draws nothing. Cached per node and budget.
function Node:collision(hull_budget)
  local raw = ffi.new("struct CadaclysmCollision")
  raw.size = ffi.sizeof(raw)
  if not lib().cadaclysm_node_collision(h(self), self.index, hull_budget or 0, raw) then return nil end
  local frame, half_extent = {}, {}
  for i = 0, 15 do frame[i + 1] = raw.frame[i] end
  for i = 0, 2 do half_extent[i + 1] = raw.half_extent[i] end
  return setmetatable({
    shape = raw.shape, confidence = raw.confidence, axis = raw.axis,
    frame = frame, half_extent = half_extent,
    radius = raw.radius, height = raw.height, error = raw.error,
    hull_vertex_count = raw.hull_vertex_count, hull_index_count = raw.hull_index_count,
  }, Collision)
end

--- The convex hull `collision` counted, as triangles. Empty for a node that draws nothing.
--- A view into the scene, good until it closes or this node is asked for a different
--- `hull_budget`, which refits and frees it.
function Node:collision_hull(hull_budget)
  local raw = lib().cadaclysm_node_collision_hull(h(self), self.index, hull_budget or 0)
  return setmetatable({
    scene = self.scene,
    positions = null_to_nil(raw.positions),
    indices = null_to_nil(raw.indices),
    vertex_count = raw.vertex_count,
    index_count = raw.index_count,
  }, CollisionHull)
end

-- -- the surface path: for a renderer drawing exact surfaces, never triangles --

--- The box of what this node draws under `placement` (16 numbers, column-major, as
--- `placement.raw_transform`; nil for the identity), for a part drawn from its
--- surfaces: tighter than placing the corners of `bounds`. All zeros without surfaces.
function Node:bounds_placed(placement)
  local m = nil
  if placement ~= nil then
    if #placement ~= 16 then fail("bounds_placed: a placement is 16 numbers", 2) end
    m = ffi.new("double[16]", placement)
  end
  return bounds(lib().cadaclysm_node_bounds_placed(h(self), self.index, m))
end
--- `bounds_placed` in `double`; see `bounds64`.
function Node:bounds_placed64(placement)
  local m = nil
  if placement ~= nil then
    if #placement ~= 16 then fail("bounds_placed64: a placement is 16 numbers", 2) end
    m = ffi.new("double[16]", placement)
  end
  return bounds64(lib().cadaclysm_node_bounds_placed64(h(self), self.index, m))
end
--- Whether its mesh has been built and is held.
function Node_get.is_meshed(self) return lib().cadaclysm_node_is_meshed(h(self), self.index) end
--- Its face boundaries from its trimmed surfaces: the outline that costs no tessellation,
--- in the surfaces' frame (`scene.surface_matrix`); empty without surfaces.
function Node_get.surface_edges(self) return polylines(self.scene, lib().cadaclysm_node_surface_edges(h(self), self.index)) end
--- Its edges as the exact curves, where the reader has them without meshing (a Rhino
--- extrusion's rims are its profile), and empty everywhere else: try it before
--- `surface_edges`, whose trims are thinned to the mesh tolerance. The same segments as
--- `edge_beziers`, in the same space -- not the surfaces' frame, so no `surface_matrix`.
function Node_get.surface_edge_beziers(self) return beziers(self.scene, lib().cadaclysm_node_surface_edge_beziers(h(self), self.index)) end
--- `edge_colours` for `surface_edges`.
function Node_get.surface_edge_colours(self) return edge_colours(lib().cadaclysm_node_surface_edge_colors(h(self), self.index)) end
--- Its isocurves from its trimmed surfaces, clipped to the trims, without meshing.
function Node_get.surface_isocurves(self) return polylines(self.scene, lib().cadaclysm_node_surface_isocurves(h(self), self.index)) end
--- Where the segment `from`..`to` (each `{x, y, z}`, in the surfaces' frame) first meets
--- its surfaces, as `{x, y, z}`, or nil.
function Node:surface_pick(from, to)
  local a, b, out = ffi.new("double[3]", from), ffi.new("double[3]", to), ffi.new("double[3]")
  if not lib().cadaclysm_node_surface_pick(h(self), self.index, a, b, out) then return nil end
  return { out[0], out[1], out[2] }
end
--- A coarse, unwelded mesh over its surfaces for ray tracing and distance fields,
--- `cells` by `cells` a face; built once per part; empty without surfaces.
function Node:surface_proxy_mesh(cells) return mesh(self.scene, lib().cadaclysm_node_surface_proxy_mesh(h(self), self.index, cells)) end
--- About how many triangles `mesh` would give, without building it; -1 where the
--- reader cannot say. Treat -1 as unknown, never as zero.
function Node_get.triangle_estimate(self) return tonumber(lib().cadaclysm_node_triangle_estimate(h(self), self.index)) end

--- This node's body meshed for a solver, as a `FemMesh`: nodes welded by bits,
--- triangles wound outward, each node tagged with the lowest-dimension B-rep entity it
--- lies on, and every crack reported rather than closed. **Owned by you**: `free()` it.
---
--- `tolerance` is the chordal tolerance in model units, finite and above zero (default
--- 0.01), and **it alone governs how closely the mesh follows the geometry**.
--- `max_size` is a size ceiling, finite and zero or more (default 0, no ceiling --
--- curvature alone): **it bounds the boundary and targets the interior**, which is not
--- a longest-element-edge guarantee. It adds boundary nodes without refining boundary
--- geometry, and `FemMesh.longest_edge` is what the mesh actually came to -- the figure
--- to check against it. Those two defaults are `FemOptions::default()`'s own, restated
--- here so the signature says what a caller gets; the library's struct is still filled
--- by `cadaclysm_fem_options_init` first, so a field added to it later defaults without
--- this line being touched.
---
--- **Neither number is checked here**, on purpose: a node with no brep is meshed by a
--- call that takes no options at all, so a `tolerance` of 0 or NaN and a `max_size` of
--- -1 or NaN all come back with a mesh there, where the brep path refuses each. The
--- library is the one that knows which path it took, so both are passed through and its
--- own refusal is what a caller sees.
---
--- `placement` is 16 numbers, column-major, as `bounds_placed` takes them (nil for the
--- identity), applied in double precision throughout. Its length *is* checked here,
--- because the ABI receives only a pointer and cannot. `cadaclysm_blacksmith`'s
--- `Solid:fem_mesh` takes **twelve** instead -- origin, x, y, z -- so a caller moving
--- between the two reformats the placement.
---
--- **The space is the body's, not the scene's, for a B-rep -- and the scene's for a
--- mesh**, which `FemMesh.from_mesh` is the flag for; read it there, because under a
--- non-native convention the two are different spaces.
---
--- Meshed in the part's own frame and following the hop from an instance to the shape
--- it draws that `mesh` follows, so a node instanced six times meshes once.
---
--- **A cracked body is not a failure**: it comes back with `FemMesh.watertight` false
--- and its cracks in `FemMesh.open_edges` / `FemMesh.folded_edges`, and nothing is
--- welded shut to make it look sound. Raises `CadaclysmError` for a tolerance or size
--- the mesher refuses, a placement that is not 16 numbers or is not finite and
--- invertible, a node with neither a brep nor a mesh (an assembly, a storey, a layer,
--- an empty definition, a curve), and a body that meshes to no triangles at all.
---
--- Prints the unlicensed notice once, here, and not again on either of `FemMesh`'s
--- `.msh` calls.
function Node:fem_mesh(tolerance, max_size, placement)
  local m = nil
  if placement ~= nil then
    if #placement ~= 16 then fail("fem_mesh: a placement is 16 numbers, not " .. #placement, 2) end
    m = ffi.new("double[16]", placement)
  end
  local o = ffi.new("struct CadaclysmFemOptions")
  lib().cadaclysm_fem_options_init(o)
  o.size = ffi.sizeof(o)
  o.tolerance = tolerance == nil and 0.01 or tolerance
  o.max_size = max_size == nil and 0.0 or max_size
  local p = lib().cadaclysm_node_fem_mesh(h(self), self.index, m, o)
  if p == nil then
    local reason = last_error()
    fail(reason ~= "" and reason or "fem_mesh", 2)
  end
  return fem_mesh(p)
end

--- Write this node's mesh to `path`; `fmt` is one of `mesh_formats()` (default "stl").
function Node:save_mesh(path, fmt)
  if not lib().cadaclysm_node_save_mesh(h(self), self.index, tostring(path), fmt or "stl") then
    local reason = last_error()
    fail(reason ~= "" and reason or ("could not write " .. tostring(path)), 2)
  end
end

--- This node's own wireframe as SVG text, in its own frame -- `Scene:svg_text`'s
--- words, one `<g id="node-<index>">`, no placement. Raises `CadaclysmError` on
--- a refused option (naming the field). Borrowed by the library: copied out
--- before this returns, and replaced by the scene's next `svg_text` or `svg`.
function Node:svg_text(words)
  local o = svg_options(self.scene:_default_up(), words)
  local p = lib().cadaclysm_node_svg_text(h(self), self.index, o)
  if p == nil then
    local reason = last_error()
    fail(reason ~= "" and reason or "svg", 2)
  end
  return ffi.string(p)
end

--- `svg_text` written to `path` by the library itself.
function Node:svg(path, words)
  local o = svg_options(self.scene:_default_up(), words)
  if not lib().cadaclysm_node_svg(h(self), self.index, tostring(path), o) then
    local reason = last_error()
    fail(reason ~= "" and reason or ("could not write " .. tostring(path)), 2)
  end
end

--- This node's silhouette from the camera the words describe -- where its surfaces turn away
--- from the eye, which no edge of it lies on. `Scene:svg_text`'s camera words: `view`, `az`,
--- `el`, `up`, `fov`, and `size` and `tolerance`, which matter here (the library reads the
--- tolerance as a fraction of the page, `tolerance / size[1]`); the line-set words, `margin`,
--- `stroke`, `width` and `background` change nothing. Returns `{ points, weights, count }`
--- as `Beziers64:copy()` does: Lua tables of numbers, four control points a curve, three
--- numbers each (`count * 12`), one weight a control point (`count * 4`), all ones for a
--- polynomial curve.
---
--- **Copied, unlike every other `Beziers64`.** The library keeps one silhouette slot per scene
--- and the next silhouette call on that scene, for any node, refills it in place, so the
--- pointers it hands back are a view that the next call changes under you. Copied here before
--- this returns, so `first` below keeps its own numbers, and so does a loop over a scene's
--- nodes collecting each one's silhouette:
---
---     local first = node:silhouette_beziers({ view = "front" })
---     local second = node:silhouette_beziers({ view = "iso" })
---
--- A body with no silhouette (every face planar) is an empty answer, `count == 0` and empty
--- tables, not an error. Raises `CadaclysmError` on a refused option (a tolerance that is not
--- finite and positive, say) or a body the library cannot measure; the message begins
--- `silhouette: `.
function Node:silhouette_beziers(words)
  local o = svg_options(self.scene:_default_up(), words)
  local raw = lib().cadaclysm_node_silhouette_beziers(h(self), self.index, o)
  if raw.points == nil or raw.weights == nil or raw.count == 0 then
    -- Both the empty answer and a refusal are all-null with count 0: the thread's error is
    -- what tells them apart, and the call clears it at entry.
    local reason = last_error()
    if reason ~= "" then fail(reason, 2) end
    return { points = {}, weights = {}, count = 0 }
  end
  return beziers64(self.scene, raw):copy()
end

--- This node and every node under it, parents before children: `for n in node:walk()`.
function Node:walk()
  local stack = { self }
  return function()
    local n = table.remove(stack)
    if not n then return nil end
    local children = n.children
    for i = #children, 1, -1 do stack[#stack + 1] = children[i] end
    return n
  end
end

Node.__eq = function(a, b) return a.scene == b.scene and a.index == b.index end
Node.__tostring = function(self) return ("<Node %d %s>"):format(self.index, self.label) end

-- ---- placements ----------------------------------------------------------------------

--- One drawing of one node's geometry, at one place. **Iterate these to draw**, and
--- nodes to build a tree: a block's members draw once per placement of it.
local Placement_get = {}
---@class Placement
---@field scene Scene
---@field index integer  from zero
local Placement = class(Placement_get)
M.Placement = Placement

local function placement(scene, index) return setmetatable({ scene = scene, index = index }, Placement) end

--- The node whose mesh and edges this draws; every copy of one shape names the same.
function Placement_get.geometry(self)
  return node(self.scene, lib().cadaclysm_placement_geometry(h(self), self.index))
end
--- What a click on this drawing should select.
function Placement_get.select(self)
  return node(self.scene, lib().cadaclysm_placement_select(h(self), self.index))
end
--- Where to draw it, as a 4x4 `m[row][col]`, composed from the root down.
function Placement_get.transform(self) return rows(self.raw_transform) end
--- The same, 16 numbers column-major.
function Placement_get.raw_transform(self)
  local out = ffi.new("double[16]")
  lib().cadaclysm_placement_transform(h(self), self.index, out)
  return sixteen(out)
end
Placement.__tostring = function(self) return ("Placement(index=%d)"):format(self.index) end

-- ---- links and joints -------------------------------------------------------------

--- A rigid body of the file's mechanism: the nodes that move together when a joint
--- moves it. From `Scene.links`; borrows from the scene like `Node`.
local Link_get = {}
---@class Link
---@field scene Scene
---@field index integer  from zero
local Link = class(Link_get)
M.Link = Link

local function link(scene, index) return setmetatable({ scene = scene, index = index }, Link) end

--- Its name, as the file gives it.
function Link_get.name(self) return text(lib().cadaclysm_link_name(h(self), self.index)) end
--- The topmost node of each subtree it moves, in node order: moving these moves
--- everything under them.
function Link_get.nodes(self)
  local out, handle = {}, h(self)
  for i = 0, lib().cadaclysm_link_node_count(handle, self.index) - 1 do
    out[#out + 1] = node(self.scene, lib().cadaclysm_link_node(handle, self.index, i))
  end
  return out
end
Link.__eq = function(a, b) return a.scene == b.scene and a.index == b.index end
Link.__tostring = function(self) return ("<Link %d %s>"):format(self.index, self.name) end

-- ---- pairs and freedoms -----------------------------------------------------------

local PAIR_KIND_NAMES = {
  "revolute", "prismatic", "cylindrical", "spherical", "spherical_with_pin",
  "planar", "universal", "homokinetic", "screw", "fully_constrained",
  "unconstrained", "low_order", "other",
}
local MOTION_NAMES = { "rotation", "translation" }
local AXIS_NAMES = { "x", "y", "z" }

--- One degree of freedom of a `Pair`: which motion, about or along which contact-frame
--- axis, and its optional range. From `Pair.freedoms`.
local Freedom_get = {}
---@class Freedom
---@field motion string  "rotation" or "translation"
---@field axis string  "x", "y" or "z"
---@field lower number|nil  radians, or the scene's length unit; nil for unbounded
---@field upper number|nil
local Freedom = class(Freedom_get)
M.Freedom = Freedom

local function freedom(motion, axis, lower, upper)
  return setmetatable({ motion = motion, axis = axis, lower = lower, upper = upper }, Freedom)
end
Freedom.__tostring = function(self)
  return ("<Freedom %s %s [%s, %s]>"):format(self.motion, self.axis, tostring(self.lower), tostring(self.upper))
end

--- A kinematic pair: the kind of relative motion a joint allows between its two links.
--- From `Joint.pair`.
local Pair_get = {}
---@class Pair
---@field kind string  one of the thirteen pair kinds
---@field type_name string|nil  for "other": the pair's entity type name ("GEAR_PAIR")
---@field kind_name string  the kind by name, finer than `kind`: "gear" and "rack_and_pinion" where `kind` reads "other"
---@field parameters number[]  the pair's own numbers: screw {pitch}, rack_and_pinion {pinion_radius}, gear {radius_first, radius_second, ratio, bevel, helical_angle}; {} otherwise
---@field pitch number|nil  for "screw": length per revolution, in the scene's units
---@field frame_start number[][]  m[row][col], like Node.transform
---@field frame_end number[][]
---@field raw_frame_start number[]  the same 16 numbers, column-major, like Node.raw_transform
---@field raw_frame_end number[]
---@field freedoms Freedom[]
local Pair = class(Pair_get)
M.Pair = Pair

local function pair(kind, type_name, pitch, frame_start, frame_end, raw_frame_start, raw_frame_end, freedoms,
                    kind_name, parameters)
  return setmetatable({
    kind = kind, type_name = type_name, pitch = pitch,
    frame_start = frame_start, frame_end = frame_end,
    raw_frame_start = raw_frame_start, raw_frame_end = raw_frame_end,
    freedoms = freedoms, kind_name = kind_name or kind, parameters = parameters or {},
  }, Pair)
end
Pair.__tostring = function(self) return ("<Pair %s>"):format(self.kind) end

--- A connection between two links of the file's mechanism, and, when the file names
--- one, the kinematic pair saying how it moves. From `Scene.joints`.
local Joint_get = {}
---@class Joint
---@field scene Scene
---@field index integer  from zero
local Joint = class(Joint_get)
M.Joint = Joint

local function joint(scene, index) return setmetatable({ scene = scene, index = index }, Joint) end

--- Its name, as the file gives it.
function Joint_get.name(self) return text(lib().cadaclysm_joint_name(h(self), self.index)) end
--- The link it starts at, in the file's order -- not a parent: a mechanism may be a
--- network with loops.
function Joint_get.start(self) return link(self.scene, lib().cadaclysm_joint_start(h(self), self.index)) end
--- The link it ends at, in the file's order. `end_`, not `end`, which is a Lua keyword
--- -- as with `Path:end_`.
function Joint_get.end_(self) return link(self.scene, lib().cadaclysm_joint_end(h(self), self.index)) end
--- How this joint moves: the kinematic pair naming it, or nil when the file names none.
function Joint_get.pair(self)
  local L, handle = lib(), h(self)
  local kind_index = tonumber(L.cadaclysm_joint_pair_kind(handle, self.index))
  if kind_index < 0 then return nil end
  local type_name_raw = L.cadaclysm_joint_pair_type(handle, self.index)
  local type_name = nil
  if type_name_raw ~= nil then type_name = ffi.string(type_name_raw) end
  local pitch = tonumber(L.cadaclysm_joint_pair_pitch(handle, self.index))
  if pitch ~= pitch then pitch = nil end -- NaN means "no pitch"
  local out_start, out_end = ffi.new("double[16]"), ffi.new("double[16]")
  L.cadaclysm_joint_pair_frames(handle, self.index, out_start, out_end)
  local raw_start, raw_end = sixteen(out_start), sixteen(out_end)
  local freedoms = {}
  for i = 0, L.cadaclysm_joint_freedom_count(handle, self.index) - 1 do
    local raw = ffi.new("CadaclysmFreedom")
    if L.cadaclysm_joint_freedom(handle, self.index, i, raw) then
      local lower, upper = nil, nil
      if raw.has_lower then lower = tonumber(raw.lower) end
      if raw.has_upper then upper = tonumber(raw.upper) end
      freedoms[#freedoms + 1] = freedom(
        MOTION_NAMES[tonumber(raw.motion) + 1], AXIS_NAMES[tonumber(raw.axis) + 1], lower, upper)
    end
  end
  local kind_name_raw = L.cadaclysm_joint_pair_kind_name(handle, self.index)
  local kind_name = nil
  if kind_name_raw ~= nil then kind_name = ffi.string(kind_name_raw) end
  local parameters = {}
  local parameter_count = tonumber(L.cadaclysm_joint_pair_parameters(handle, self.index, nil, 0))
  if parameter_count > 0 then
    local buffer = ffi.new("double[?]", parameter_count)
    L.cadaclysm_joint_pair_parameters(handle, self.index, buffer, parameter_count)
    for i = 1, parameter_count do parameters[i] = tonumber(buffer[i - 1]) end
  end
  return pair(PAIR_KIND_NAMES[kind_index + 1], type_name, pitch,
              rows(raw_start), rows(raw_end), raw_start, raw_end, freedoms, kind_name, parameters)
end
Joint.__eq = function(a, b) return a.scene == b.scene and a.index == b.index end
Joint.__tostring = function(self) return ("<Joint %d %s>"):format(self.index, self.name) end

-- ---- mechanism states ---------------------------------------------------------------

--- One row of a `State`: the joint it sets, and the values it sets it to, one per
--- freedom of the joint's pair, in the pair's freedom order.
local StateValue_get = {}
---@class StateValue
---@field joint Joint
---@field values number[]
local StateValue = class(StateValue_get)
M.StateValue = StateValue

local function state_value(joint_obj, values)
  return setmetatable({ joint = joint_obj, values = values }, StateValue)
end
StateValue.__tostring = function(self)
  return ("<StateValue %s [%s]>"):format(self.joint.name, table.concat(self.values, ", "))
end

--- A named pose of the file's mechanism: a `MECHANISM_STATE_REPRESENTATION`. From
--- `Scene.states`.
local State_get = {}
---@class State
---@field index integer  its position in the scene's states
---@field name string  as the file gives it
---@field values StateValue[]  one row per joint this state sets, in file order
local State = class(State_get)
M.State = State

local function read_state(scene, index)
  local L, handle = lib(), scene:handle()
  local name = text(L.cadaclysm_state_name(handle, index))
  local values = {}
  for row = 0, L.cadaclysm_state_value_count(handle, index) - 1 do
    local joint_out = ffi.new("uint32_t[1]")
    local count = L.cadaclysm_state_value(handle, index, row, joint_out, nil, 0)
    local raw = ffi.new("double[?]", count)
    L.cadaclysm_state_value(handle, index, row, joint_out, raw, count)
    if joint_out[0] ~= M.NONE then
      local row_values = {}
      for i = 0, count - 1 do row_values[i + 1] = raw[i] end
      values[#values + 1] = state_value(joint(scene, joint_out[0]), row_values)
    end
  end
  return setmetatable({ index = index, name = name, values = values }, State)
end
State.__tostring = function(self) return ("<State %d %s>"):format(self.index, self.name) end

-- ---- sequences -------------------------------------------------------------------

local copy_pose -- defined with `Pose`, below
local INTERPOLATIONS = { [0] = "undefined", "discontinuous", "synchronous", "linear" }

--- One step of a `Sequence`: the `State` it reaches, its parameter `t`, and how the
--- motion leaves it for the next -- `interpolation`, one of `"undefined"`,
--- `"discontinuous"`, `"synchronous"`, `"linear"`.
---@class Segment
---@field state State
---@field t number
---@field interpolation string
local Segment = {}
Segment.__index = Segment
M.Segment = Segment
Segment.__tostring = function(self)
  return ("<Segment %s t=%s %s>"):format(self.state.name, self.t, self.interpolation)
end

--- A motion the file records: an `INTERPOLATED_CONFIGURATION_SEQUENCE`, its states at
--- increasing parameter values. From `Scene.sequences`.
---
--- `pose(t)` poses it at parameter `t`, in the file's own parameter: a segment is a
--- keyframe of its state, a `"discontinuous"` segment holds until the next and every
--- other kind moves linearly, an open sequence holds its ends and a `closed` one wraps.
--- To play it on a clock: with a duration, stretch `start`..`end` (plus the closing
--- span when closed) to it; with none, read the parameter as seconds -- times
--- `seconds_per_unit` where the file states a time unit.
---
--- Lua reserves `end`, so the last segment's parameter is `end_`, as `Joint.end_` is.
local Sequence_get = {}
---@class Sequence
---@field index integer  its position in the scene's sequences
---@field name string  the sequence's name
---@field closed boolean  whether the motion returns to its first segment
---@field seconds_per_unit number|nil  seconds per unit of the parameter, or nil where the
---  file states no time unit (the parameter is then read as seconds)
---@field segments Segment[]  in file order (at least two)
---@field start number  the first segment's parameter
---@field end_ number  the last segment's parameter (the closing span not included)
local Sequence = class(Sequence_get)
M.Sequence = Sequence

local function read_sequence(scene, index)
  return setmetatable({ index = index, _scene = scene }, Sequence)
end
Sequence.__tostring = function(self) return ("<Sequence %d %s>"):format(self.index, self.name) end
function Sequence_get.name(self)
  return text(lib().cadaclysm_sequence_name(self._scene:handle(), self.index))
end
function Sequence_get.closed(self)
  return lib().cadaclysm_sequence_closed(self._scene:handle(), self.index)
end
function Sequence_get.seconds_per_unit(self)
  local value = lib().cadaclysm_sequence_seconds_per_unit(self._scene:handle(), self.index)
  if value == 0 then return nil end
  return value
end
function Sequence_get.segments(self)
  local L, handle, out = lib(), self._scene:handle(), {}
  for i = 0, L.cadaclysm_sequence_segment_count(handle, self.index) - 1 do
    local state, t, interpolation = ffi.new("uint32_t[1]"), ffi.new("double[1]"), ffi.new("uint32_t[1]")
    L.cadaclysm_sequence_segment(handle, self.index, i, state, t, interpolation)
    out[i + 1] = setmetatable({
      state = read_state(self._scene, state[0]),
      t = t[0],
      interpolation = INTERPOLATIONS[interpolation[0]] or "undefined",
    }, Segment)
  end
  return out
end
function Sequence_get.start(self) return self.segments[1].t end
Sequence_get.end_ = function(self)
  local segments = self.segments
  return segments[#segments].t
end
--- The mechanism posed by this sequence at parameter `t`, with `ground` (a `Link`, or
--- nil for the default ground) held fixed as `Scene.pose` does. Raises `CadaclysmError`
--- for a `t` that is not finite.
function Sequence:pose(t, ground)
  local ground_index = ground == nil and M.NONE or ground.index
  local ptr = lib().cadaclysm_pose_sequence(self._scene:handle(), self.index, t, ground_index)
  if ptr == nil then fail(last_error(), 2) end
  return copy_pose(self._scene, ptr)
end

-- ---- work schedules --------------------------------------------------------------

-- The words of the C enums, indexed by their values.
local SCHEDULE_KINDS = { [0] = "planned", "actual", "baseline", "notdefined", "other" }
local TASK_KINDS = {
  [0] = "attendance", "construction", "demolition", "dismantle", "disposal", "installation",
  "logistic", "maintenance", "move", "operation", "removal", "renovation", "notdefined", "other",
}
local LINK_KINDS = { [0] = "finish_start", "start_start", "finish_finish", "start_finish", "notdefined", "other" }
local DATES = { scheduled = 0, actual = 1 }
local PHASES = { [0] = "unbuilt", "building", "built", "demolishing", "demolished" }
local TIME_FIELDS = {
  "schedule_start", "schedule_finish", "early_start", "early_finish", "late_start",
  "late_finish", "actual_start", "actual_finish", "duration",
}

--- What one element is doing on a date: `WorkSchedule:at`'s rows. `node` is the `Node`;
--- `phase` is `"unbuilt"`, `"building"`, `"built"`, `"demolishing"` or `"demolished"`;
--- `progress` is 0..1 through the window that governs the phase; `variance` is the seconds
--- late (positive) or early (negative) against the schedule, or nil where there is none.
---@class ElementState
---@field node Node
---@field phase string
---@field progress number
---@field variance number|nil
local ElementState = {}
ElementState.__index = ElementState
M.ElementState = ElementState
ElementState.__tostring = function(self)
  return ("<ElementState %s %s %.2f>"):format(self.node.name, self.phase, self.progress)
end

--- Every date pair a task gives, each seconds since 1970-01-01T00:00 (no zone;
--- `os.date('!%Y-%m-%dT%H:%M:%S', seconds)` reads one) or nil where the file gives none.
---@class TaskTime
---@field schedule_start number|nil
---@field schedule_finish number|nil
---@field early_start number|nil
---@field early_finish number|nil
---@field late_start number|nil
---@field late_finish number|nil
---@field actual_start number|nil
---@field actual_finish number|nil
---@field duration number|nil  seconds
local TaskTime = {}
TaskTime.__index = TaskTime
M.TaskTime = TaskTime

--- A building's programme: an `IfcWorkSchedule` and the tasks it controls. From
--- `Scene.schedules`.
---
--- `at(date)` says what each element it names is doing on a date. Dates are numbers,
--- seconds since 1970-01-01T00:00.
local WorkSchedule_get = {}
---@class WorkSchedule
---@field index integer  its position in the scene's schedules
---@field name string  its name, else its identification, else `schedule #k`
---@field identification string  `""` where none
---@field kind string  `"planned"`, `"actual"`, `"baseline"`, `"notdefined"` or `"other"`
---@field kind_name string  the text of a user-defined kind (`kind == "other"`); `""` otherwise
---@field start number|nil  the schedule's start, or nil where the file gives none
---@field finish number|nil  the schedule's finish, or nil where the file gives none
---@field tasks Task[]  in file order
---@field links TaskLink[]  its task links (`IfcRelSequence`), in file order
local WorkSchedule = class(WorkSchedule_get)
M.WorkSchedule = WorkSchedule

local function read_schedule(scene, index)
  return setmetatable({ index = index, _scene = scene }, WorkSchedule)
end
WorkSchedule.__tostring = function(self) return ("<WorkSchedule %d %s>"):format(self.index, self.name) end
function WorkSchedule_get.name(self)
  return text(lib().cadaclysm_schedule_name(self._scene:handle(), self.index))
end
function WorkSchedule_get.identification(self)
  return text(lib().cadaclysm_schedule_identification(self._scene:handle(), self.index))
end
function WorkSchedule_get.kind(self)
  return SCHEDULE_KINDS[lib().cadaclysm_schedule_kind(self._scene:handle(), self.index)] or "notdefined"
end
function WorkSchedule_get.kind_name(self)
  return text(lib().cadaclysm_schedule_kind_name(self._scene:handle(), self.index))
end
function WorkSchedule_get.start(self)
  local out = ffi.new("double[1]")
  if not lib().cadaclysm_schedule_start(self._scene:handle(), self.index, out) then return nil end
  return out[0]
end
function WorkSchedule_get.finish(self)
  local out = ffi.new("double[1]")
  if not lib().cadaclysm_schedule_finish(self._scene:handle(), self.index, out) then return nil end
  return out[0]
end

--- One task of a `WorkSchedule`. From `WorkSchedule.tasks`.
---
--- `kind` is `"attendance"`, `"construction"`, `"demolition"`, `"dismantle"`, `"disposal"`,
--- `"installation"`, `"logistic"`, `"maintenance"`, `"move"`, `"operation"`, `"removal"`,
--- `"renovation"`, `"notdefined"` or `"other"`; `kind_name` is the text of a user-defined
--- one. `parent` is the summary task nesting it, nil at the top. `nodes` are the nodes it
--- builds or removes.
local Task_get = {}
---@class Task
---@field index integer  its position in the schedule's tasks
---@field schedule WorkSchedule
---@field name string
---@field identification string  `""` where none
---@field kind string
---@field kind_name string  the text of a user-defined kind (`kind == "other"`); `""` otherwise
---@field status string  as the file writes it, `""` where none
---@field milestone boolean
---@field parent Task|nil
---@field time TaskTime
---@field nodes Node[]
local Task = class(Task_get)
M.Task = Task

local function read_task(schedule, index)
  return setmetatable({ index = index, schedule = schedule }, Task)
end
Task.__tostring = function(self) return ("<Task %d %s>"):format(self.index, self.name) end
local function task_args(self) return self.schedule._scene:handle(), self.schedule.index, self.index end
function Task_get.name(self) return text(lib().cadaclysm_task_name(task_args(self))) end
function Task_get.identification(self) return text(lib().cadaclysm_task_identification(task_args(self))) end
function Task_get.kind(self) return TASK_KINDS[lib().cadaclysm_task_kind(task_args(self))] or "notdefined" end
function Task_get.kind_name(self) return text(lib().cadaclysm_task_kind_name(task_args(self))) end
function Task_get.status(self) return text(lib().cadaclysm_task_status(task_args(self))) end
function Task_get.milestone(self) return lib().cadaclysm_task_milestone(task_args(self)) end
function Task_get.parent(self)
  local out = ffi.new("uint32_t[1]")
  local handle, s, t = task_args(self)
  if not lib().cadaclysm_task_parent(handle, s, t, out) then return nil end
  return read_task(self.schedule, out[0])
end
function Task_get.time(self)
  local raw = ffi.new("CadaclysmTaskTime[1]")
  local handle, s, t = task_args(self)
  lib().cadaclysm_task_time(handle, s, t, raw)
  local out = setmetatable({}, TaskTime)
  for _, name in ipairs(TIME_FIELDS) do
    if raw[0]["has_" .. name] then out[name] = raw[0][name] end
  end
  return out
end
function Task_get.nodes(self)
  local L = lib()
  local handle, s, t = task_args(self)
  local count = L.cadaclysm_task_node_count(handle, s, t)
  local out = {}
  if count == 0 then return out end
  local ids = ffi.new("uint32_t[?]", count)
  L.cadaclysm_task_nodes(handle, s, t, ids, count)
  for i = 0, count - 1 do out[i + 1] = node(self.schedule._scene, ids[i]) end
  return out
end

--- A sequence between two tasks of one schedule. From `WorkSchedule.links`.
---
--- `from` is the predecessor, `to` the successor; `kind` is `"finish_start"`,
--- `"start_start"`, `"finish_finish"`, `"start_finish"`, `"notdefined"` or `"other"`
--- (`kind_name` is the text of a user-defined one, `""` otherwise); `lag` is the time lag in
--- seconds, or nil where the file gives none.
---@class TaskLink
---@field from Task
---@field to Task
---@field kind string
---@field kind_name string
---@field lag number|nil
local TaskLink = {}
TaskLink.__index = TaskLink
M.TaskLink = TaskLink
TaskLink.__tostring = function(self) return ("<TaskLink %s -> %s %s>"):format(self.from.name, self.to.name, self.kind) end

function WorkSchedule_get.tasks(self)
  local handle, out = self._scene:handle(), {}
  for i = 0, lib().cadaclysm_task_count(handle, self.index) - 1 do out[i + 1] = read_task(self, i) end
  return out
end
function WorkSchedule_get.links(self)
  local L, handle, out = lib(), self._scene:handle(), {}
  local tasks = self.tasks
  for i = 0, L.cadaclysm_task_link_count(handle, self.index) - 1 do
    local from, to, kind = ffi.new("uint32_t[1]"), ffi.new("uint32_t[1]"), ffi.new("uint32_t[1]")
    local lag, has_lag = ffi.new("double[1]"), ffi.new("bool[1]")
    L.cadaclysm_task_link(handle, self.index, i, from, to, kind, lag, has_lag)
    out[i + 1] = setmetatable({
      from = tasks[from[0] + 1],
      to = tasks[to[0] + 1],
      kind = LINK_KINDS[kind[0]] or "notdefined",
      kind_name = text(L.cadaclysm_task_link_kind_name(handle, self.index, i)),
      lag = has_lag[0] and lag[0] or nil,
    }, TaskLink)
  end
  return out
end

--- What each element this schedule names is doing on `date` (seconds since
--- 1970-01-01T00:00), in node order; elements no task names are not listed. `dates` is
--- `"scheduled"` (the default) or `"actual"` -- which of a task's dates to play. Raises
--- `CadaclysmError` for any other `dates` and for a `date` that is not finite.
function WorkSchedule:at(date, dates)
  if dates == nil then dates = "scheduled" end
  local which = DATES[dates]
  if which == nil then fail("dates must be 'scheduled' or 'actual'", 2) end
  local L, handle = lib(), self._scene:handle()
  local count = L.cadaclysm_schedule_at(handle, self.index, date, which, nil, 0)
  if count < 0 then fail(last_error(), 2) end
  count = tonumber(count)
  local out = {}
  if count == 0 then return out end
  local rows = ffi.new("CadaclysmElementState[?]", count)
  L.cadaclysm_schedule_at(handle, self.index, date, which, rows, count)
  for i = 0, count - 1 do
    local r = rows[i]
    out[i + 1] = setmetatable({
      node = node(self._scene, r.node),
      phase = PHASES[r.phase] or "unbuilt",
      progress = r.progress,
      variance = r.has_variance and r.variance or nil,
    }, ElementState)
  end
  return out
end

-- ---- posing ----------------------------------------------------------------------

--- A posed mechanism: `Scene.pose` or `Scene.pose_state`'s answer. The document itself
--- is unchanged.
---
--- Copied eagerly out of the C handle at construction time (`copy_pose`), so a `Pose`
--- holds no C pointer and outlives the call that made it -- closing the scene does not
--- invalidate it.
local Pose_get = {}
---@class Pose
---@field ground Link  the link held fixed
---@field unsolved Joint[]  loop-closing joints not honoured, in file order
---@field out_of_range table[]  {joint=Joint, freedom=integer, value=number}, one per given
---  value outside its freedom's range
---@field diagnostics string[]  what the couplings (gear, rack and pinion, a loop-closing screw)
---  could not solve, or found disagreeing, in file order, in the kernel's words
local Pose = class(Pose_get)
M.Pose = Pose

local function pose_obj(scene, ground, unsolved, out_of_range, transforms, diagnostics)
  return setmetatable({
    scene = scene, ground = ground, unsolved = unsolved, out_of_range = out_of_range, diagnostics = diagnostics or {},
    _transforms = transforms,
  }, Pose)
end
Pose.__tostring = function(self) return ("<Pose ground=%s>"):format(tostring(self.ground)) end

--- `node`'s posed transform, as a 4x4 `m[row][col]` -- the same shape `Node.transform`
--- returns.
function Pose:transform(node) return rows(self:raw_transform(node)) end
--- The same matrix in the ABI's own column-major order, as 16 numbers, exactly as
--- `Node.raw_transform` lays them out.
function Pose:raw_transform(node) return self._transforms[node.index + 1] end

--- Draw this pose's scene as `Scene:show` does -- by handle -- with every node's posed transform
--- handed to the view (`cadaclysm_view_set_node_transforms`). An unposed pose draws exactly what
--- `Scene:show` does. Options as `Scene:show`.
function Pose:show(options)
  return require(prefix .. "cadaclysm_view")._present(self.scene, self.scene:_drawing(options), false, self._transforms)
end
--- `Pose:show`'s orbiting twin; returns what `Scene:view` returns.
function Pose:view(options)
  return require(prefix .. "cadaclysm_view")._present(self.scene, self.scene:_drawing(options), true, self._transforms)
end

-- Reads everything out of a `CadaclysmPose *` into a `Pose`, then frees it (ruling 2 of
-- the posing plan: wrappers copy eagerly, never holding the C pointer). `ffi.gc` is not
-- needed here: the free runs in a `pcall`-protected copy, so an error midway through
-- copying still frees the handle before it propagates.
function copy_pose(scene, ptr)
  local L = lib()
  local ok, result = pcall(function()
    local ground = link(scene, L.cadaclysm_pose_ground(ptr))
    local transforms = {}
    for i = 0, L.cadaclysm_pose_node_count(ptr) - 1 do
      local raw = ffi.new("double[16]")
      L.cadaclysm_pose_node_transform(ptr, i, raw)
      transforms[i + 1] = sixteen(raw)
    end
    local unsolved = {}
    for i = 0, L.cadaclysm_pose_unsolved_count(ptr) - 1 do
      local j = L.cadaclysm_pose_unsolved(ptr, i)
      if j ~= M.NONE then unsolved[#unsolved + 1] = joint(scene, j) end
    end
    local out_of_range = {}
    for i = 0, L.cadaclysm_pose_out_of_range_count(ptr) - 1 do
      local joint_out = ffi.new("uint32_t[1]")
      local freedom_out = ffi.new("uint32_t[1]")
      local value_out = ffi.new("double[1]")
      if L.cadaclysm_pose_out_of_range(ptr, i, joint_out, freedom_out, value_out) then
        out_of_range[#out_of_range + 1] = { joint = joint(scene, joint_out[0]),
          freedom = tonumber(freedom_out[0]), value = value_out[0] }
      end
    end
    local diagnostics = {}
    for i = 0, tonumber(L.cadaclysm_pose_diagnostic_count(ptr)) - 1 do
      local raw = L.cadaclysm_pose_diagnostic(ptr, i)
      if raw ~= nil then diagnostics[#diagnostics + 1] = ffi.string(raw) end
    end
    return pose_obj(scene, ground, unsolved, out_of_range, transforms, diagnostics)
  end)
  L.cadaclysm_pose_free(ptr)
  if not ok then error(result, 0) end
  return result
end

-- ---- the scene ---------------------------------------------------------------------

--- An open document: `path`, `schema_path` (the `.exp` used, or nil) and
--- `convention` (the packed number it was opened with) are plain fields. Close it
--- when done; everything it hands back borrows from it.
local Scene_get = {}
---@class Scene
---@field path string
---@field schema_path string|nil
---@field convention integer
local Scene = class(Scene_get)
M.Scene = Scene

--- The raw handle, refusing a closed one: a use after close is a Lua error at the
--- call site rather than a dangling pointer handed to the library.
function Scene:handle()
  local p = rawget(self, "_ptr")
  if p == nil then fail(self.path .. ": the scene is closed", 3) end
  return p
end

--- Give the document back. Idempotent; every borrowed view reads freed memory after.
function Scene:close()
  local p = rawget(self, "_ptr")
  if p ~= nil then
    -- A view drawing this scene holds its handle: the items showing it go first. Only when the
    -- view module was ever loaded, so closing a scene opens no library.
    local view = package.loaded[prefix .. "cadaclysm_view"]
    if type(view) == "table" then view._release(self) end
    self._ptr = nil
    ffi.gc(p, nil)
    lib().cadaclysm_close(p)
  end
end

-- The options a draw is given, with `up` defaulted from the scene when the caller named none.
function Scene:_drawing(options)
  if options == nil then options = {} end
  if type(options) ~= "table" then return options end
  local o = {}
  for k, v in pairs(options) do o[k] = v end
  if o.up == nil then o.up = self:_default_up() end
  return o
end

--- Draw every visible placement by handle with the view library in use (cadaclysm_view.lua):
--- blocks until the window is closed on the GPU library, prints a still on the terminal.
--- Options: view, azimuth, elevation, zoom, up (default from the convention), edges, width,
--- height, title. No tolerance: a document is drawn at the tolerance it was read with.
function Scene:show(options) return require(prefix .. "cadaclysm_view")._present(self, self:_drawing(options), false) end
--- Orbit the model until the window is closed; the camera it was left at and the last pick.
function Scene:view(options) return require(prefix .. "cadaclysm_view")._present(self, self:_drawing(options), true) end

--- Whether `close` has run.
function Scene_get.closed(self) return rawget(self, "_ptr") == nil end
--- The version of the library that read it.
function Scene_get.version() return M.version() end
--- The schema the file named, or empty for a format that names none.
function Scene_get.schema(self) return text(lib().cadaclysm_schema(self:handle())) end
--- The schema that actually read it, which is not always the one it named.
function Scene_get.schema_read(self) return text(lib().cadaclysm_schema_read(self:handle())) end
--- Whether something other than the file's own schema read it (bare names compared).
function Scene_get.substituted(self)
  local read = self.schema_read
  if read == "" then return false end
  local function bare(entry)
    return ((entry:match("^[^{]*") or ""):gsub("^%s+", ""):gsub("[%s%.]+$", ""):lower())
  end
  local want = bare(read)
  for part in self.schema:gmatch("[^,]+") do
    if bare(part) == want then return false end
  end
  return true
end
--- What one length in the file is worth in metres, or 1 where it did not say.
function Scene_get.metres_per_unit(self) return lib().cadaclysm_metres_per_unit(self:handle()) end
--- Everything the model covers, in world coordinates. **Meshes all of it.**
function Scene_get.bounds(self) return bounds(lib().cadaclysm_bounds(self:handle())) end
--- `bounds` in `double`: the same union box, unnarrowed. **Meshes all of it**, as `bounds` does.
function Scene_get.bounds64(self) return bounds64(lib().cadaclysm_bounds64(self:handle())) end
--- What this file held that the reader could not build.
function Scene_get.diagnostics(self)
  local L, handle, out = lib(), self:handle(), {}
  for i = 0, L.cadaclysm_diagnostic_count(handle) - 1 do
    out[#out + 1] = text(L.cadaclysm_diagnostic(handle, i))
  end
  return out
end
--- The rigid bodies of the file's mechanism, in the file's order.
function Scene_get.links(self)
  local L, handle, out = lib(), self:handle(), {}
  for i = 0, L.cadaclysm_link_count(handle) - 1 do out[#out + 1] = link(self, i) end
  return out
end
--- The connections between those links, in the file's order, each with its kinematic
--- pair when the file names one.
function Scene_get.joints(self)
  local L, handle, out = lib(), self:handle(), {}
  for i = 0, L.cadaclysm_joint_count(handle) - 1 do out[#out + 1] = joint(self, i) end
  return out
end
--- The file's named mechanism states, e.g. STEP's `MECHANISM_STATE_REPRESENTATION`s.
--- Empty for a file that records none.
function Scene_get.states(self)
  local L, handle, out = lib(), self:handle(), {}
  for i = 0, L.cadaclysm_state_count(handle) - 1 do out[#out + 1] = read_state(self, i) end
  return out
end
--- The file's motion sequences, e.g. STEP's `INTERPOLATED_CONFIGURATION_SEQUENCE`s.
--- Empty for a file that records none.
function Scene_get.sequences(self)
  local L, handle, out = lib(), self:handle(), {}
  for i = 0, L.cadaclysm_sequence_count(handle) - 1 do out[#out + 1] = read_sequence(self, i) end
  return out
end
--- The file's IFC work schedules (`IfcWorkSchedule`). Empty for a file that records none.
function Scene_get.schedules(self)
  local L, handle, out = lib(), self:handle(), {}
  for i = 0, L.cadaclysm_schedule_count(handle) - 1 do out[#out + 1] = read_schedule(self, i) end
  return out
end
--- The link the file declares as the mechanism's base, or nil when it declares none
--- (the default ground is then the link on the most joints; see `pose`).
function Scene_get.base(self)
  local index = lib().cadaclysm_kinematics_base(self:handle())
  if index == M.NONE then return nil end
  return link(self, index)
end
--- The mechanism posed by `values`: rows naming a `Joint` and the values to set it to,
--- one per freedom of its pair -- exactly `State.values`'s row type, so
--- `pose(state.values)` poses like `pose_state(state)` -- with `ground` (a `Link`, or
--- nil for the default ground) held fixed. Values outside a freedom's range are used
--- as given and reported in the answer's `out_of_range`.
---
--- Raises `CadaclysmError` on a bad row (a joint given twice, one with the wrong
--- number of values, ...) or a file with no mechanism, carrying
--- `cadaclysm_last_error`'s text unchanged.
function Scene:pose(values, ground)
  local L, handle = lib(), self:handle()
  values = values or {}
  local n = #values
  local joints_arr, counts_arr = ffi.new("uint32_t[?]", n), ffi.new("uint32_t[?]", n)
  local flat = {}
  for i, row in ipairs(values) do
    joints_arr[i - 1] = row.joint.index
    counts_arr[i - 1] = #row.values
    for _, v in ipairs(row.values) do flat[#flat + 1] = v end
  end
  local values_arr = ffi.new("double[?]", #flat)
  for i, v in ipairs(flat) do values_arr[i - 1] = v end
  local ground_index = ground == nil and M.NONE or ground.index
  local ptr = L.cadaclysm_pose(handle, joints_arr, counts_arr, values_arr, n, ground_index)
  if ptr == nil then fail(last_error(), 2) end
  return copy_pose(self, ptr)
end
--- The mechanism posed by `state`'s values, with `ground` held fixed as `pose` does.
--- Raises `CadaclysmError` as `pose` does.
function Scene:pose_state(state, ground)
  local ground_index = ground == nil and M.NONE or ground.index
  local ptr = lib().cadaclysm_pose_state(self:handle(), state.index, ground_index)
  if ptr == nil then fail(last_error(), 2) end
  return copy_pose(self, ptr)
end
--- What the reader built but the geometry stage could not finish: a face that would
--- not trim, a surface that would not mesh. `diagnostics` is what the file held that
--- could not be read; this is what the geometry did.
function Scene_get.geometry_diagnostics(self)
  local L, handle, out = lib(), self:handle(), {}
  for i = 0, L.cadaclysm_geometry_diagnostic_count(handle) - 1 do
    out[#out + 1] = text(L.cadaclysm_geometry_diagnostic(handle, i))
  end
  return out
end
--- The archive member this was read from, or nil for a plain file.
function Scene_get.source_name(self)
  local raw = lib().cadaclysm_source_name(self:handle())
  if raw == nil then return nil end
  return ffi.string(raw)
end
--- How many nodes it has, geometry or not.
function Scene_get.node_count(self) return lib().cadaclysm_node_count(self:handle()) end
--- Every node, in index order.
function Scene_get.nodes(self)
  local out = {}
  for i = 0, self.node_count - 1 do out[i + 1] = node(self, i) end
  return out
end
--- The nodes nothing else contains.
function Scene_get.roots(self)
  local L, handle, out = lib(), self:handle(), {}
  for i = 0, L.cadaclysm_root_count(handle) - 1 do
    local index = L.cadaclysm_root(handle, i)
    if index ~= M.NONE then out[#out + 1] = node(self, index) end
  end
  return out
end
--- What this document draws and where. Not the nodes -- see Placement.
function Scene_get.placements(self)
  local out = {}
  for i = 0, lib().cadaclysm_placement_count(self:handle()) - 1 do out[i + 1] = placement(self, i) end
  return out
end
--- How many nodes `realize_all` has finished with. Safe to read from another thread.
function Scene_get.realized(self) return lib().cadaclysm_realized(self:handle()) end
--- How many there will be in all -- zero until `realize_all` starts.
function Scene_get.realize_total(self) return lib().cadaclysm_realize_total(self:handle()) end
--- The 4x4 `m[row][col]` that puts `Node.surfaces` in the space everything else is in.
function Scene_get.surface_matrix(self)
  local out = ffi.new("float[16]")
  lib().cadaclysm_surface_matrix(self:handle(), out)
  local t = {}
  for i = 0, 15 do t[i + 1] = out[i] end
  return rows(t)
end

--- Node `index`, counting from zero as the ABI does.
function Scene:node(index)
  local count = self.node_count
  if index < 0 or index >= count then fail(("node %d of %d"):format(index, count), 2) end
  return node(self, index)
end

--- Every node reachable from the roots, parents before children: `for n in scene:walk()`.
function Scene:walk()
  local roots, r, inner = self.roots, 0, nil
  return function()
    while true do
      if inner then
        local n = inner()
        if n then return n end
      end
      r = r + 1
      if not roots[r] then return nil end
      inner = roots[r]:walk()
    end
  end
end

--- The indices (from zero) of the nodes a filter matches, in document order:
--- `class == ON_Brep and within(class == ON_Layer and name == Walls)`. Raises with the
--- parser's message on a filter that will not parse; no match is an empty list.
function Scene:query(filter)
  local L, handle = lib(), self:handle()
  local total = L.cadaclysm_query(handle, filter, nil, 0)
  if total == 0 then
    local reason = last_error()
    if reason ~= "" then fail(self.path .. ": " .. reason, 2) end
    return {}
  end
  local out = ffi.new("uint32_t[?]", total)
  local written = L.cadaclysm_query(handle, filter, out, total)
  local t = {}
  for i = 0, math.min(written, total) - 1 do t[i + 1] = out[i] end
  return t
end

--- Build every mesh now, across all cores, and say how many were built.
function Scene:realize_all() return lib().cadaclysm_realize_all(self:handle()) end

--- `realize_all` leaving alone every node that carries surfaces when `skip_surfaced`
--- is true (the default); returns how many were built.
function Scene:realize_meshes(skip_surfaced)
  if skip_surfaced == nil then skip_surfaced = true end
  return lib().cadaclysm_realize_meshes(self:handle(), skip_surfaced and 1 or 0)
end

--- Drop every mesh the scene has built; the next ask rebuilds. What it frees is the
--- document's own mesh: this counts the forget, because `node.mesh64` lends that, so a
--- `Mesh64` from before it raises a stale view when read. `mesh`, the line views and the
--- Béziers are the library's own caches, which a forget does not touch.
function Scene:forget_meshes()
  lib().cadaclysm_forget_meshes(self:handle())
  self._forgets = (rawget(self, "_forgets") or 0) + 1
end

--- Ask a running `realize_all` to stop. One-way, for the life of the scene.
function Scene:cancel() lib().cadaclysm_cancel(self:handle()) end

--- Write the whole scene: `fmt` is "glb" (default), "gltf" or "obj".
function Scene:save(path, fmt)
  if not lib().cadaclysm_scene_save(self:handle(), tostring(path), fmt or "glb") then
    local reason = last_error()
    fail(reason ~= "" and reason or ("could not write " .. tostring(path)), 2)
  end
end

--- `"y"` or `"z"`: which axis is up by default, from `convention` -- `UNITY`
--- and `Y_UP` give `"y"`, every other convention `"z"`. What `svg_text`/`svg`'s
--- `up=` falls back to when left out. `FILE_UNITS`/`UV_WORLD` are masked out
--- first, since they OR into the packed convention a scene carries.
function Scene:_default_up()
  local base = bit.band(self.convention, bit.bnot(bit.bor(M.FILE_UNITS, M.UV_WORLD)))
  return (base == Convention.UNITY or base == Convention.Y_UP) and "y" or "z"
end

--- Every visible placement's wireframe as SVG text, from the camera `words`
--- describes -- the library's own camera, not a viewer: `view=` (front back
--- left right top bottom iso), `az=`, `el=` over it, `up=` (default from the
--- convention this scene was opened with), `fov=` (0, the default, is
--- orthographic), `size=` ({width, height}), `margin=`, `tolerance=`,
--- `stroke=`, `width=` (the stroke's, in page units), `background=` (nil for
--- transparent), `edges=`, `curves=`, `isocurves=`, `polylines=` (which line
--- sets are drawn; edges alone by default). Raises `CadaclysmError` on a
--- refused option, naming the field. Borrowed by the library: copied out
--- before this returns, and replaced by this scene's next `svg_text` or `svg`.
function Scene:svg_text(words)
  local o = svg_options(self:_default_up(), words)
  local p = lib().cadaclysm_scene_svg_text(self:handle(), o)
  if p == nil then
    local reason = last_error()
    fail(reason ~= "" and reason or "svg", 2)
  end
  return ffi.string(p)
end

--- `svg_text` written to `path` by the library itself.
function Scene:svg(path, words)
  local o = svg_options(self:_default_up(), words)
  if not lib().cadaclysm_scene_svg(self:handle(), tostring(path), o) then
    local reason = last_error()
    fail(reason ~= "" and reason or ("could not write " .. tostring(path)), 2)
  end
end

Scene.__tostring = function(self)
  if self.closed then return ("<Scene %s (closed)>"):format(self.path) end
  return ("<Scene %s (%d nodes)>"):format(self.path, self.node_count)
end

-- ---- opening ---------------------------------------------------------------------

--- The schema a STEP or IFC file says it speaks (its `FILE_SCHEMA` line), read from
--- the first few kilobytes. Empty when it names none.
function M.declared_schema(model)
  local f = io.open(tostring(model), "rb")
  if not f then return "" end
  local head = f:read(8192) or ""
  f:close()
  return head:match("[Ff][Ii][Ll][Ee]_[Ss][Cc][Hh][Ee][Mm][Aa]%s*%(%s*%(%s*'([^']+)'") or ""
end

local function plain(name) return (name:upper():gsub("[^%w]", "")) end

local function list_exp(dir)
  local out = {}
  local windows = package.config:sub(1, 1) == "\\"
  local cmd = windows and ('dir /b "%s\\*.exp" 2>nul'):format(dir:gsub("/", "\\"))
    or ("ls -1 '%s' 2>/dev/null"):format(dir)
  local pipe = io.popen(cmd)
  if pipe then
    for line in pipe:lines() do
      if line:lower():match("%.exp$") then out[#out + 1] = dir .. "/" .. line end
    end
    pipe:close()
  end
  table.sort(out)
  return out
end

local function stem_of(path) return path:match("([^/]+)%.[^./]*$") or path end

--- `schema` resolved to `chosen, fallbacks`: a file is taken as given; a directory is
--- matched against what the model declares, the longest matching name winning, and
--- where nothing matches the whole directory comes back as fallbacks to try in turn.
function M.resolve_schema(model, schema)
  if schema == nil then return nil, {} end
  schema = tostring(schema):gsub("\\", "/")
  if not is_dir(schema) then
    if exists(schema) then return schema, {} end
    fail(("schema %s is neither a file nor a directory"):format(schema), 2)
  end
  local available = list_exp(schema)
  if #available == 0 then fail(("no .exp schemas in %s"):format(schema), 2) end
  local declared = plain(M.declared_schema(model))
  local best, best_len = nil, -1
  if declared ~= "" then
    for _, exp in ipairs(available) do
      local stem = plain(stem_of(exp))
      if declared:sub(1, #stem) == stem or stem:sub(1, #declared) == declared then
        if #stem > best_len then best, best_len = exp, #stem end
      end
    end
  end
  if best then return best, {} end
  return nil, available
end

-- What an open call's options point into, held across the call where no JIT trace
-- can decide it is dead.
local in_flight

local function options(convention, schema, colors)
  local o = ffi.new("CadaclysmOpenOptions")
  lib().cadaclysm_open_options_init(o)
  if convention == nil then convention = Convention.NATIVE end
  if type(convention) == "string" then convention = Convention.parse(convention) end
  o.convention = bit.band(convention, bit.bnot(bit.bor(M.FILE_UNITS, M.UV_WORLD)))
  o.file_units = bit.band(convention, M.FILE_UNITS) ~= 0
  o.uvs = bit.band(convention, M.UV_WORLD) ~= 0 and 1 or 0
  o.colors = colors and 1 or 0
  local held = {}
  if schema ~= nil then
    local path = tostring(schema)
    local array = ffi.new("const char *[1]")
    array[0] = path
    o.schemas, o.schema_count = array, 1
    held = { array, path }
  end
  return o, held, convention
end

local function wrap(pointer, path, schema_path, convention)
  local scene = setmetatable({ path = path, schema_path = schema_path, convention = convention }, Scene)
  scene._ptr = ffi.gc(pointer, lib().cadaclysm_close)
  return scene
end

--- Open a CAD file and read its tree; geometry is built lazily, node by node.
--- `schema`: an extra EXPRESS `.exp` (or a directory of them) beyond the built-in
--- ones. `convention`: a `Convention` value, optionally OR'd with `FILE_UNITS` and
--- `UV_WORLD`, or a name `Convention.parse` takes ("y-up", "unreal+file-units").
--- `colors`: per-vertex colours on multi-coloured bodies. Raises on failure.
function M.open(path, schema, convention, colors)
  path = tostring(path)
  if not exists(path) and not is_dir(path) then fail(path .. ": no such file", 2) end
  local L = lib()
  if schema ~= nil and is_dir(tostring(schema)) then
    -- A directory goes over whole: the library keys each schema by the name it declares.
    local o, packed
    o, in_flight, packed = options(convention, schema, colors)
    local pointer = L.cadaclysm_open(path, o)
    in_flight = nil
    if pointer ~= nil then return wrap(pointer, path, tostring(schema), packed) end
    fail(path .. ": " .. last_error(), 2)
  end
  local chosen, fallbacks = M.resolve_schema(path, schema)
  local candidates = (chosen ~= nil or #fallbacks == 0) and { chosen or false } or fallbacks
  for _, candidate in ipairs(candidates) do
    local o, packed
    o, in_flight, packed = options(convention, candidate or nil, colors)
    local pointer = L.cadaclysm_open(path, o)
    in_flight = nil
    if pointer ~= nil then return wrap(pointer, path, candidate or nil, packed) end
  end
  fail(path .. ": " .. last_error(), 2)
end

--- Open a file already in memory. `data` is a Lua string; `format` names the kind as
--- an extension would ("step", "ifc", "igs", "3dm", "brep", "scad"). `schema` must be
--- a path here. `name` is what `path` and errors will say. Otherwise as `open`.
function M.open_memory(data, format, schema, name, convention, colors)
  name = name or "<memory>"
  local o, packed
  o, in_flight, packed = options(convention, schema, colors)
  local pointer = lib().cadaclysm_open_memory(ffi.cast("const uint8_t *", data), #data, tostring(format), o)
  in_flight = nil
  if pointer == nil then fail(name .. ": " .. last_error(), 2) end
  return wrap(pointer, name, schema ~= nil and tostring(schema) or nil, packed)
end

return M
