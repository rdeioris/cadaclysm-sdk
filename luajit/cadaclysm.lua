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
  "cadaclysm_metres_per_unit", "cadaclysm_bounds", "cadaclysm_diagnostic_count",
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
  "cadaclysm_node_transform", "cadaclysm_node_bounds", "cadaclysm_node_mesh",
  "cadaclysm_node_surfaces", "cadaclysm_node_brep",
  "cadaclysm_node_edges", "cadaclysm_node_curves", "cadaclysm_node_isocurves",
  "cadaclysm_brep_layout_id", "cadaclysm_brep_manifold", "cadaclysm_brep_release",
  "cadaclysm_mesh_format_count", "cadaclysm_mesh_format", "cadaclysm_mesh_format_extension",
  "cadaclysm_pick_file",
  "cadaclysm_mesh_format_label", "cadaclysm_format_count", "cadaclysm_format_name", "cadaclysm_format_extensions",
  "cadaclysm_pick_save", "cadaclysm_geometry_diagnostic_count", "cadaclysm_geometry_diagnostic",
  "cadaclysm_forget_meshes",
  "cadaclysm_lod_levels", "cadaclysm_node_mesh_lod", "cadaclysm_node_lod_error",
  "cadaclysm_node_edge_beziers", "cadaclysm_node_curve_beziers", "cadaclysm_node_isocurve_beziers",
  "cadaclysm_node_collision", "cadaclysm_node_collision_hull",
  "cadaclysm_node_bounds_placed", "cadaclysm_node_is_meshed",
  "cadaclysm_node_surface_edges", "cadaclysm_node_surface_isocurves",
  "cadaclysm_node_surface_pick", "cadaclysm_node_surface_proxy_mesh",
  "cadaclysm_node_triangle_estimate", "cadaclysm_realize_meshes",
  "cadaclysm_meshlets_build", "cadaclysm_meshlets_count", "cadaclysm_meshlets_free",
  "cadaclysm_meshlet_triangle_count", "cadaclysm_meshlet_vertex_count", "cadaclysm_meshlet_level",
  "cadaclysm_meshlet_group", "cadaclysm_meshlet_error", "cadaclysm_meshlet_child_count",
  "cadaclysm_meshlet_positions", "cadaclysm_meshlet_normals", "cadaclysm_meshlet_indices",
  "cadaclysm_meshlet_children",
  "cadaclysm_svg_options_init", "cadaclysm_scene_svg_text", "cadaclysm_scene_svg",
  "cadaclysm_node_svg_text", "cadaclysm_node_svg",
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

--- Give the reference back now. Idempotent.
function Brep:release()
  local p = rawget(self, "_ptr")
  if p ~= nil then
    self._ptr = nil
    ffi.gc(p, nil)
    lib().cadaclysm_brep_release(p)
  end
end

-- ---- meshlets --------------------------------------------------------------------

--- A mesh split into meshlets, optionally with coarser levels above them, for a
--- mesh-shader or Nanite-style renderer. Built from any mesh and owned by you:
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

-- ---- svg -----------------------------------------------------------------------------

--- The seven camera angles `svg_text`/`svg`'s `view=` understands, as (azimuth,
--- elevation) in degrees -- the same table `cadaclysm_viewer.VIEWS` gives
--- Python's `show()` and `svg()` both.
local SVG_VIEWS = {
  front = { -90, 0 }, back = { 90, 0 }, left = { 180, 0 }, right = { 0, 0 },
  top = { -90, 90 }, bottom = { -90, -90 }, iso = { -50, 28 },
}

--- `CadaclysmSvgOptions.background`'s "none" value: no `<rect>` behind the
--- drawing, the page left to whatever the viewer composites it onto.
local SVG_TRANSPARENT = 0xffffffff

--- A colour as the ABI's packed `0xRRGGBB`: `"#rrggbb"` or a `{r, g, b}` table.
local function svg_colour(colour)
  if type(colour) == "string" then
    local hex = colour:gsub("^#", "")
    if #hex ~= 6 then fail(("colour '%s': '#rrggbb' or {r, g, b}"):format(colour), 3) end
    return tonumber(hex, 16)
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
  o.stroke = words.stroke ~= nil and svg_colour(words.stroke) or 0x000000
  o.stroke_width = words.width or 1.0
  o.background = words.background ~= nil and svg_colour(words.background) or SVG_TRANSPARENT
  local edges = words.edges
  if edges == nil then edges = true end
  o.flags = bit.bor(edges and 1 or 0, words.curves and 2 or 0, words.isocurves and 4 or 0, words.polylines and 8 or 0)
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
--- Its triangles, in their own frame, built now if they have not been.
function Node_get.mesh(self) return mesh(self.scene, lib().cadaclysm_node_mesh(h(self), self.index)) end
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
--- Its free curves, as polylines. A 2D drawing is all of these.
function Node_get.curves(self) return polylines(self.scene, lib().cadaclysm_node_curves(h(self), self.index)) end
--- Its interior surface lines, as polylines, so a curved face reads as curved.
function Node_get.isocurves(self)
  return polylines(self.scene, lib().cadaclysm_node_isocurves(h(self), self.index))
end
--- Its feature edges as cubic Bézier curves, exact where the file's curves were, where
--- `edges` are their chords. Builds the geometry if needed.
function Node_get.edge_beziers(self) return beziers(self.scene, lib().cadaclysm_node_edge_beziers(h(self), self.index)) end
--- Its free curves as cubic Béziers; see `edge_beziers`.
function Node_get.curve_beziers(self) return beziers(self.scene, lib().cadaclysm_node_curve_beziers(h(self), self.index)) end
--- Its isocurves as cubic Béziers; see `edge_beziers`.
function Node_get.isocurve_beziers(self) return beziers(self.scene, lib().cadaclysm_node_isocurve_beziers(h(self), self.index)) end

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
--- Whether its mesh has been built and is held.
function Node_get.is_meshed(self) return lib().cadaclysm_node_is_meshed(h(self), self.index) end
--- Its face boundaries from its trimmed surfaces: the outline that costs no tessellation,
--- in the surfaces' frame (`scene.surface_matrix`); empty without surfaces.
function Node_get.surface_edges(self) return polylines(self.scene, lib().cadaclysm_node_surface_edges(h(self), self.index)) end
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
    self._ptr = nil
    ffi.gc(p, nil)
    lib().cadaclysm_close(p)
  end
end

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
--- What this file held that the reader could not build.
function Scene_get.diagnostics(self)
  local L, handle, out = lib(), self:handle(), {}
  for i = 0, L.cadaclysm_diagnostic_count(handle) - 1 do
    out[#out + 1] = text(L.cadaclysm_diagnostic(handle, i))
  end
  return out
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

--- Drop every mesh the scene has built; the next ask rebuilds. Every mesh and
--- polylines table handed out before this points at freed memory.
function Scene:forget_meshes() lib().cadaclysm_forget_meshes(self:handle()) end

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
