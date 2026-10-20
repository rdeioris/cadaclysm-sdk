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

**Every mesh or edge view owns a tessellation of its own.** `Solid:mesh`,
`Solid:mesh64` and `Solid:edge_polylines` each take out a held tessellation
(`cadaclysm_blacksmith_tessellation`) rather than borrowing the solid's own
single-tolerance cache: a view's `pointer` is a `const float *` /
`const uint32_t *` straight into its own tessellation, kept alive by `ffi.gc`
until every view sharing it becomes unreachable. Nothing about a view goes
stale: not `Solid:close()`, not meshing the same solid again at any other
tolerance, whatever order those happen in. `view.pointer`, `view:get(i)`,
`view:row(i)` and `view:copy()` always read live memory; `view.valid` always
returns `true`, kept only for compatibility with code written against the old
staleness rule. A raw pointer taken out of a view is only as safe as the view
that produced it staying reachable -- LuaJIT's collector can free a
tessellation nothing else still references, so hold the view, not just its
`pointer`, across anything that might run the collector (the same rule
`FemMesh`'s own doc comment gives its fields, below). `view:copy()` gives a
plain Lua array that is always safe. Strings are copied on the way out. A view
pins its *whole* tessellation -- positions, normals, indices, edges, face
counts, in both precisions -- not just the block you asked for, until every
view over it is unreachable; release waits for LuaJIT's collector. For data
that must outlive the view, `view:copy()` it and drop the view.

**`mesh64` and `bounds_at64`.** `Solid:mesh64` hands back the very same
tessellation `Solid:mesh` does when the solid's own cache still holds that
tolerance -- the same `indices` view -- with `positions`/`normals` unnarrowed
(`float64` views, not `float32`): exact far from the origin, where `mesh`'s
are not; a separate held tessellation of equal content otherwise. Either way,
once held, nothing touches it. `Solid:bounds_at64` is `bounds_at` from those
same unnarrowed positions, read straight off the solid's own cache rather
than a held tessellation -- it hands back numbers, not a view, so there is
nothing to keep alive.

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
M.__version__ = "0.11.0"

--- What the ABI returns for "no such face" and uses for "the whole solid".
M.NONE = 0xFFFFFFFF

--- The units `step`/`write_step` write in, by name.
M.UNITS = { m = 0, mm = 1, ["in"] = 2 }

local NONE = M.NONE
local UNITS = M.UNITS

-- `Assembly:pair`'s `pitch` when the caller gives none: the C ABI reads a NaN pitch as
-- "not given", the same way Python's wrapper passes `float("nan")`.
local NAN = 0 / 0

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
  "cadaclysm_blacksmith_option_set", "cadaclysm_blacksmith_option_get",
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
  "cadaclysm_blacksmith_torus", "cadaclysm_blacksmith_wedge", "cadaclysm_blacksmith_pyramid", "cadaclysm_blacksmith_extrude",
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
  "cadaclysm_blacksmith_split_by_profile",
  "cadaclysm_blacksmith_lump_count", "cadaclysm_blacksmith_lump", "cadaclysm_blacksmith_face_count",
  "cadaclysm_blacksmith_select_face", "cadaclysm_blacksmith_face_frame", "cadaclysm_blacksmith_face_ref",
  "cadaclysm_blacksmith_mass_properties",
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
  "cadaclysm_blacksmith_tessellation", "cadaclysm_blacksmith_tessellation_free",
  "cadaclysm_blacksmith_tessellation_mesh", "cadaclysm_blacksmith_tessellation_mesh64",
  "cadaclysm_blacksmith_tessellation_face_triangles", "cadaclysm_blacksmith_tessellation_edge_polylines",
  "cadaclysm_blacksmith_bounds", "cadaclysm_blacksmith_bounds64", "cadaclysm_blacksmith_box", "cadaclysm_blacksmith_leaked_edges", "cadaclysm_blacksmith_unpaired_edges",
  "cadaclysm_blacksmith_manifold", "cadaclysm_blacksmith_step", "cadaclysm_blacksmith_sat_text",
  "cadaclysm_blacksmith_sat", "cadaclysm_blacksmith_brep_text", "cadaclysm_blacksmith_brep",
  "cadaclysm_blacksmith_string_free",
  "cadaclysm_blacksmith_from_brep", "cadaclysm_blacksmith_brep_layout_id",
  "cadaclysm_blacksmith_svg_options_init", "cadaclysm_blacksmith_svg_text", "cadaclysm_blacksmith_svg",
  "cadaclysm_blacksmith_silhouette_beziers", "cadaclysm_blacksmith_silhouette_beziers_free",
  "cadaclysm_blacksmith_fem_options_init", "cadaclysm_blacksmith_fem_mesh",
  "cadaclysm_blacksmith_fem_mesh_view", "cadaclysm_blacksmith_fem_mesh_edge",
  "cadaclysm_blacksmith_fem_mesh_vertex", "cadaclysm_blacksmith_fem_mesh_open_edge",
  "cadaclysm_blacksmith_fem_mesh_folded_edge",
  "cadaclysm_blacksmith_fem_mesh_crossing_count", "cadaclysm_blacksmith_fem_mesh_crossing",
  "cadaclysm_blacksmith_fem_mesh_msh_text",
  "cadaclysm_blacksmith_fem_mesh_save_msh", "cadaclysm_blacksmith_fem_mesh_free",
  "cadaclysm_blacksmith_drawing_svg_text", "cadaclysm_blacksmith_drawing_svg",
  "cadaclysm_blacksmith_named", "cadaclysm_blacksmith_solid_name",
  "cadaclysm_blacksmith_assembly_new", "cadaclysm_blacksmith_assembly_free", "cadaclysm_blacksmith_assembly_name",
  "cadaclysm_blacksmith_assembly_place_solid", "cadaclysm_blacksmith_assembly_place_assembly",
  "cadaclysm_blacksmith_assembly_step", "cadaclysm_blacksmith_assembly_link", "cadaclysm_blacksmith_assembly_joint",
  "cadaclysm_blacksmith_assembly_pair", "cadaclysm_blacksmith_assembly_pair_with",
  "cadaclysm_blacksmith_assembly_state", "cadaclysm_blacksmith_assembly_posed",
  "cadaclysm_blacksmith_assembly_sequence",
  "cadaclysm_blacksmith_assembly_base",
  "cadaclysm_blacksmith_pair_freedom_count",
  "cadaclysm_blacksmith_solid_bounds_box", "cadaclysm_blacksmith_box_moved", "cadaclysm_blacksmith_box_overlaps",
  "cadaclysm_blacksmith_boxes_apart", "cadaclysm_blacksmith_collider_new", "cadaclysm_blacksmith_collider_free",
  "cadaclysm_blacksmith_collider_group_count", "cadaclysm_blacksmith_collider_stats", "cadaclysm_blacksmith_collider_check",
  "cadaclysm_blacksmith_subd_cuboid", "cadaclysm_blacksmith_subd_cylinder", "cadaclysm_blacksmith_subd_sphere", "cadaclysm_blacksmith_subd_torus", "cadaclysm_blacksmith_subd_from_parts", "cadaclysm_blacksmith_subd_parts",
  "cadaclysm_blacksmith_subd_free", "cadaclysm_blacksmith_subd_transform", "cadaclysm_blacksmith_subd_set_crease", "cadaclysm_blacksmith_subd_set_pin", "cadaclysm_blacksmith_subd_extrude", "cadaclysm_blacksmith_subd_inset", "cadaclysm_blacksmith_subd_insert_loop",
  "cadaclysm_blacksmith_subd_mirror_on", "cadaclysm_blacksmith_subd_mirror_off", "cadaclysm_blacksmith_subd_full", "cadaclysm_blacksmith_subd_edge_loop", "cadaclysm_blacksmith_subd_smooth_mesh", "cadaclysm_blacksmith_subd_pick", "cadaclysm_blacksmith_subd_to_solid",
  "cadaclysm_blacksmith_collisions_free", "cadaclysm_blacksmith_collisions_count", "cadaclysm_blacksmith_collisions_hit",
  "cadaclysm_blacksmith_collisions_solid",
  "cadaclysm_blacksmith_profile_to_arcs", "cadaclysm_blacksmith_profile_offset", "cadaclysm_blacksmith_solid_section",
  "cadaclysm_blacksmith_tool_flat", "cadaclysm_blacksmith_tool_ball", "cadaclysm_blacksmith_tool_drill",
  "cadaclysm_blacksmith_tool_with_ramp_angle", "cadaclysm_blacksmith_tool_free",
  "cadaclysm_blacksmith_stock_box", "cadaclysm_blacksmith_stock_around", "cadaclysm_blacksmith_stock_free",
  "cadaclysm_blacksmith_job_new", "cadaclysm_blacksmith_job_set_clearance", "cadaclysm_blacksmith_job_set_tolerance",
  "cadaclysm_blacksmith_job_set_spindle_dwell", "cadaclysm_blacksmith_job_set_resolution", "cadaclysm_blacksmith_job_set_name",
  "cadaclysm_blacksmith_job_face", "cadaclysm_blacksmith_job_contour", "cadaclysm_blacksmith_job_pocket",
  "cadaclysm_blacksmith_job_drill", "cadaclysm_blacksmith_job_gcode", "cadaclysm_blacksmith_job_camotics",
  "cadaclysm_blacksmith_job_free",
  "cadaclysm_blacksmith_programs_count", "cadaclysm_blacksmith_programs_tool", "cadaclysm_blacksmith_programs_name",
  "cadaclysm_blacksmith_programs_text", "cadaclysm_blacksmith_programs_free",
  "cadaclysm_blacksmith_job_machine", "cadaclysm_blacksmith_report_count", "cadaclysm_blacksmith_report_kind",
  "cadaclysm_blacksmith_report_at", "cadaclysm_blacksmith_report_size", "cadaclysm_blacksmith_report_reason",
  "cadaclysm_blacksmith_report_region", "cadaclysm_blacksmith_report_text", "cadaclysm_blacksmith_report_free",
  "cadaclysm_blacksmith_job_operations", "cadaclysm_blacksmith_operations_count", "cadaclysm_blacksmith_operations_kind",
  "cadaclysm_blacksmith_operations_tool", "cadaclysm_blacksmith_operations_param_count",
  "cadaclysm_blacksmith_operations_param_name", "cadaclysm_blacksmith_operations_param_value",
  "cadaclysm_blacksmith_operations_free",
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
-- here, named, before the kernel is asked: one edge is `{ edge }`, never read as none.
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

-- A list argument of names: `list` must be a table that is not a record (an Edge, a Solid,
-- etc. -- a key that is not a whole number from 1) and each item a string. Refused here,
-- named, before the kernel is asked: one name is `{ name }`, never walked a character at a
-- time.
local function names(list, call, param)
  local n, is_list = 0, type(list) == "table"
  if is_list then
    for k in pairs(list) do
      if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then is_list = false break end
      n = n + 1
    end
  end
  if not is_list then
    raise(("%s: %s must be a list of names, not %s"):format(call, param, repr(list)))
  end
  local out = {}
  for i = 1, n do
    local v = list[i]
    if type(v) ~= "string" then
      raise(("%s: %s[%d] is not a name: %s"):format(call, param, i, repr(v)))
    end
    out[i] = v
  end
  return out, n
end

-- How many items `value` holds as a list (a table that is not a record -- an Edge, a
-- Solid, {foo = "bar"} -- a key that is not a whole number from 1), or nil when it is
-- not one at all (including a bare string, which `type` already marks as not a table,
-- so it is refused rather than walked a character at a time). Shared by `pair`'s
-- `ranges` and `state`'s `rows`, which both need this same list-or-refused check
-- ahead of any kernel call.
local function list_count(value)
  if type(value) ~= "table" then return nil end
  local n = 0
  for k in pairs(value) do
    if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then return nil end
    n = n + 1
  end
  return n
end

local function triple(v, what)
  local d = doubles(v, 3, what)
  return d[0], d[1], d[2]
end

local function pair(v, what)
  local d = doubles(v, 2, what)
  return d[0], d[1]
end

-- r, g, b in 0..1 from colour text -- "#rgb", "#rrggbb" or a CSS colour name -- read by the
-- library's own parser; nil if it refused the text.
local function colour_text(text)
  local out = ffi.new("double[3]")
  if lib().cadaclysm_blacksmith_parse_colour(text, out) then return out[0], out[1], out[2] end
  return nil
end

-- (r, g, b) from "#rgb", "#rrggbb", a CSS colour name or three numbers; the range is the
-- library's to check.
local function rgb(colour)
  if type(colour) == "string" then
    local r, g, b = colour_text(colour)
    if r then return r, g, b end
  elseif type(colour) == "table" and #colour == 3 then
    local r, g, b = tonumber(colour[1]), tonumber(colour[2]), tonumber(colour[3])
    if r and g and b then return r, g, b end
  end
  raise('coloured: a colour is "#rgb", "#rrggbb", a CSS colour name or (r, g, b) in 0..1, not ' .. repr(colour))
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

--- Set a kernel option, by its name, for the whole process from the next call on:
--- "boolean.mesh_budget", "boolean.finest_tolerance", "profile_boolean.point_budget" or
--- "measure.default_accuracy". Raises -- and changes nothing -- for a name that is not
--- an option or a value it does not take, saying which and what it takes.
function M.set_option(name, value)
  if not lib().cadaclysm_blacksmith_option_set(tostring(name), tonumber(value)) then
    fail("option '" .. tostring(name) .. "' refused")
  end
end

--- A kernel option's value, by its name: what set_option last set, else its default.
--- Raises for a name that is not an option, listing the ones there are.
function M.option(name)
  local out = ffi.new("double[1]")
  if not lib().cadaclysm_blacksmith_option_get(tostring(name), out) then
    fail("no option '" .. tostring(name) .. "'")
  end
  return out[0]
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

--- How many freedoms a pair kind has, so a caller can size `Assembly:pair`'s `ranges`.
--- 0 for an unknown name, and for `"fully_constrained"`, which has none.
function M.pair_freedom_count(kind)
  if type(kind) ~= "string" then raise("pair_freedom_count: kind must be a string, got " .. repr(kind)) end
  return tonumber(lib().cadaclysm_blacksmith_pair_freedom_count(kind))
end

-- ---- held tessellations -----------------------------------------------------------

local function free_tessellation(p) lib().cadaclysm_blacksmith_tessellation_free(p) end

-- Raise the library's own reason for a failed cadaclysm_blacksmith_tessellation, with its
-- leading "tessellation:" (that entry point naming itself, not the caller) rewritten to
-- `what` -- the C-level name `hold`'s own caller reported before it held a tessellation of
-- its own -- so callers see the same text as ever.
local function fail_tessellation(what)
  local reason = last_error()
  local rest = reason:match("^tessellation:(.*)$")
  if rest then reason = what .. ":" .. rest end
  error(setmetatable({ message = reason ~= "" and reason or what }, BuildError), 2)
end

-- A held tessellation: the owner of a mesh or edge view's arrays. `hold` tessellates
-- solid at tolerance and hands back a table wrapping the handle, freed by `ffi.gc` once
-- nothing -- no view built over it -- still references this table. Its arrays belong to
-- it, not to the solid: neither closing the solid nor meshing it again at any tolerance
-- touches a tessellation already held.
local function hold(solid, tolerance, what)
  local p = lib().cadaclysm_blacksmith_tessellation(solid:_h(), tolerance)
  if p == nil then fail_tessellation(what) end
  return { _ptr = ffi.gc(p, free_tessellation) }
end

-- cadaclysm_blacksmith_mesh, _mesh64, _mesh_face_triangles and _edge_polylines are no
-- longer called: Solid:mesh, Solid:mesh64, Solid:edge_polylines and the local
-- mesh_face_triangles below each hold a tessellation of their own instead (see the note
-- at the top). Python's object model still names all four, and the SDK's cross-language
-- parity check still requires every binding to call each one somewhere -- named here,
-- under a branch that never runs, the same shape as Go's
-- legacyTessellationEntryPointsForParity.
local function legacy_tessellation_entry_points_for_parity(handle, tolerance)
  if false then
    lib().cadaclysm_blacksmith_mesh(handle, tolerance)
    lib().cadaclysm_blacksmith_mesh64(handle, tolerance)
    lib().cadaclysm_blacksmith_mesh_face_triangles(handle, tolerance)
    lib().cadaclysm_blacksmith_edge_polylines(handle, tolerance)
  end
end

-- ---- views into a held tessellation -------------------------------------------------

--- One block of a held tessellation: `solid` (the Solid the view was made from),
--- `pointer`, `shape` (`{n, 3}` or `{m}`), `size` (elements) and `dtype`
--- ("float32"/"uint32"/"float64"). See the note at the top.
local View = {}
local View_get = {}
class(View, View_get)

local function view(solid, held, pointer, shape, dtype)
  local size = 1
  for _, n in ipairs(shape) do size = size * n end
  if pointer == nil or size == 0 then pointer = nil end
  return setmetatable({ solid = solid, _held = held, _pointer = pointer,
    shape = shape, size = size, dtype = dtype }, View)
end

--- The `const float *` / `const uint32_t *` into the view's own tessellation, or nil
--- when empty. Always live: see the note at the top.
function View_get.pointer(self)
  return self._pointer
end

--- Always `true`. Kept for compatibility: a view once went stale when its solid closed
--- or was re-meshed at another tolerance; it now owns its tessellation and never does.
function View_get.valid(self)
  return true
end

--- Element `i` of the flat array, counting from zero.
function View:get(i)
  if i < 0 or i >= self.size then raise(("index %d out of range (0 to %d)"):format(i, self.size - 1)) end
  return self._pointer[i]
end

--- Row `i` (from zero) of an (n, 3) view as three numbers; of a flat view, element `i`.
function View:row(i)
  local width = self.shape[2] or 1
  if i < 0 or i >= self.shape[1] then raise(("row %d out of range (0 to %d)"):format(i, self.shape[1] - 1)) end
  local p = self._pointer
  if width == 3 then return p[3 * i], p[3 * i + 1], p[3 * i + 2] end
  return p[i]
end

--- The elements in memory of our own: a flat Lua array (1-based), safe to outlive the view.
function View:copy()
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
--- **This is the one array product here read through plain fields rather than a `View`'s
--- methods**, though the reason is no longer staleness: `Solid:mesh`, `Solid:mesh64` and
--- `Solid:edge_polylines` each hold a tessellation of their own too now (see the note at
--- the top), so neither `close()` nor a mesh at another tolerance touches either kind of
--- array any more. A FEM mesh is **its own handle** regardless: its pointers are built
--- with it and never move, it is not in the solid's own cache, and neither closing the
--- solid nor meshing it again at any tolerance ever touched it. So these are plain
--- **fields**, with nothing checking a read the library would never refuse.
---
--- **So hold the FemMesh for as long as you read one of its arrays.** Because they are
--- fields rather than accessors, nothing here refuses a read after `free()`: a pointer
--- taken out of one is a bare cdata pointer into memory the library has given back, and
--- reading it reads whatever is there by then. Copy into a Lua table what must outlive
--- the handle. The methods below *do* refuse, naming themselves. That is the same sharp
--- edge the note at the top of this file documents for the solid's own views, and it is
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

--- Every pair of triangles that pass through each other, as `{a, b}` with `a < b`,
--- sorted: an edge of one through the other's interior. Their B-rep faces are
--- `triangle_face[a]` and `[b]`.
---
--- **Computed for every solid, open or closed.** The census `watertight`, `open_edges`
--- and `folded_edges` report is topological and cannot see a surface passing through
--- itself; a mesh is ready for a volume mesher when it is `watertight` **and** this is
--- empty -- Gmsh refuses one that crosses. A copy.
function FemMesh_get.crossings(self)
  local L = lib()
  local handle = fem_handle(self)
  local count = L.cadaclysm_blacksmith_fem_mesh_crossing_count(handle)
  local a, b = ffi.new("uint32_t[1]"), ffi.new("uint32_t[1]")
  local out = {}
  for i = 0, count - 1 do
    if not L.cadaclysm_blacksmith_fem_mesh_crossing(handle, i, a, b) then fail("fem_mesh_crossing " .. i) end
    out[#out + 1] = { a[0], b[0] }
  end
  return out
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

--- This outline coloured -- `colour` is "#rgb", "#rrggbb", a CSS colour name or {r, g, b}
--- in 0..1: how it is drawn. The verbs that make a profile from one carry it; a solid made from it
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

--- This profile with every free-form side (a Bezier, a conic, a NURBS) replaced by lines
--- and arcs within `tolerance` of it -- what a G-code writer can say. Lines and arcs pass
--- through as they are, every loop closes on itself exactly, holes are converted the same
--- way. `tolerance` defaults to 0.01. Raises `BuildError` for a tolerance not positive and
--- finite, or a spline that does not evaluate.
function Profile:to_arcs(tolerance)
  if tolerance == nil then tolerance = 0.01 end
  return new_profile(lib().cadaclysm_blacksmith_profile_to_arcs(self._handle, tolerance), "profile_to_arcs")
end

--- This profile grown by `distance` (shrunk where it is negative), as zero or more
--- profiles, all lines and arcs: outward corners rounded by |distance|, holes moving
--- against the boundary (a hole shrinks as the profile grows). Free-form sides are fitted
--- to `tolerance` first (`to_arcs`). A shrink that eats the whole profile is an empty
--- table. `tolerance` defaults to 0.01. Raises `BuildError` for a distance not finite, a
--- tolerance not positive and finite, a loop with no sides, or loops that cross or touch.
function Profile:offset(distance, tolerance)
  if tolerance == nil then tolerance = 0.01 end
  return profile_list(lib().cadaclysm_blacksmith_profile_offset(self._handle, distance, tolerance), "profile_offset")
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

--- A colour as the ABI's packed `0xRRGGBB`: `"#rrggbb"`, a CSS colour name or a `{r, g,
--- b}` table (0..255). `what` names the field in the error, e.g. "svg: stroke".
local function svg_colour(colour, what)
  if type(colour) == "string" then
    local r, g, b = colour_text(colour)
    if r then
      return math.floor(r * 255 + 0.5) * 65536 + math.floor(g * 255 + 0.5) * 256 + math.floor(b * 255 + 0.5)
    end
    raise(("%s: a colour is \"#rgb\", \"#rrggbb\", a CSS colour name or {r, g, b} in 0..255, not %s")
      :format(what, repr(colour)))
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

local Edge, Curve, Intersection, Chain, Overlap, SolidHits, Piece, Manifold, Mass, Selector
local Box, ColliderStats, CollisionHit, Collider, box_of, box_words

local function new_solid(handle, what)
  checked(handle, what or "solid")
  return setmetatable({ _ptr = ffi.gc(handle, free_solid) }, Solid)
end

local function solid_handle(s, what)
  if type(s) ~= "table" or getmetatable(s) ~= Solid then raise((what or "solid") .. ": expected a Solid, got " .. repr(s)) end
  return s:_h()
end

--- Free the solid. Idempotent. A mesh or edge view taken out earlier owns its own
--- tessellation and keeps reading regardless -- see the note at the top.
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

--- Draw it with the view library in use, by handle: blocks until the window is closed on the
--- GPU library; on the terminal, prints a still. Options: view, azimuth, elevation, zoom, up,
--- edges, width, height, title, rgb, tolerance (see cadaclysm_view.lua).
function Solid:show(options) return require(prefix .. "cadaclysm_view")._present(self, options, false) end
--- Orbit it until the window is closed; the camera it was left at and the last pick.
function Solid:view(options) return require(prefix .. "cadaclysm_view")._present(self, options, true) end

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

--- A right pyramid of `sides` sides (at least 3): its base the regular polygon
--- of circumradius `r` on z=0, its first corner on +x, its tip at (0, 0, `h`).
function Solid.pyramid(sides, r, h)
  sides = math.max(0, math.floor(number(sides, "sides")))
  return new_solid(lib().cadaclysm_blacksmith_pyramid(sides, r, h))
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

--- This solid cut by the plane Z = `z`: its closed outlines there, in XY, nested into
--- profiles with holes (boundaries counter-clockwise, holes clockwise), a line or a circle
--- crossing kept exact and any other curve as lines within `tolerance`. A plane that misses
--- the solid is an empty table. `tolerance` defaults to 0.05. Raises `BuildError` for a `z`
--- not finite, a tolerance not positive and finite, a face lying in the plane (section a
--- little above or below it), or a crossing that does not close.
function Solid:section(z, tolerance)
  if tolerance == nil then tolerance = 0.05 end
  return profile_list(lib().cadaclysm_blacksmith_solid_section(self:_h(), z, tolerance), "solid_section")
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
--- `progress(phase, done, total)` hears "meet" on the exact route; "mesh", "cull",
--- "cross", "snap" and "curve" where it falls back to the mesh route.
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

--- The solid's axis-aligned box, `{{min_x, min_y, min_z}, {max_x, max_y, max_z}}`, at the
--- same cost whatever its size: its mesh at a thousandth of its own extent, in `double`, so
--- the box is inside the exact one and short of it by at most that. Worked out once per
--- solid, apart from the tessellation `mesh` caches. `bounds_at` is the box of the mesh at a
--- tolerance you name.
function Solid_get.bounds(self)
  local lo, hi = ffi.new("double[3]"), ffi.new("double[3]")
  if not lib().cadaclysm_blacksmith_box(self:_h(), lo, hi) then fail("box") end
  return { { lo[0], lo[1], lo[2] }, { hi[0], hi[1], hi[2] } }
end

--- The solid's axis-aligned bounds over its cached tessellation at `tolerance`
--- (the same cache `mesh` fills and reuses): `{{min_x, min_y, min_z}, {max_x, max_y, max_z}}`.
function Solid:bounds_at(tolerance)
  local lo, hi = ffi.new("double[3]"), ffi.new("double[3]")
  if not lib().cadaclysm_blacksmith_bounds(self:_h(), tolerance, lo, hi) then fail("bounds") end
  return { { lo[0], lo[1], lo[2] }, { hi[0], hi[1], hi[2] } }
end

--- `bounds_at` from the same tessellation's unnarrowed positions: exact far from
--- the origin, where `bounds_at`'s (widened from `float`) are not. Same cache as
--- `bounds_at` and `mesh`/`mesh64` -- a second call at the same tolerance costs
--- nothing extra.
function Solid:bounds_at64(tolerance)
  local lo, hi = ffi.new("double[3]"), ffi.new("double[3]")
  if not lib().cadaclysm_blacksmith_bounds64(self:_h(), tolerance, lo, hi) then fail("bounds64") end
  return { { lo[0], lo[1], lo[2] }, { hi[0], hi[1], hi[2] } }
end

--- `bounds_box_at(0.05)`.
function Solid_get.bounds_box(self)
  return self:bounds_box_at(0.05)
end

--- This solid's box at `tolerance`: its boolean mesh, padded by twice that -- the
--- broad phase's own shape, cheaper to move and test than the solid itself.
function Solid:bounds_box_at(tolerance)
  local raw = ffi.new("CadaclysmBlacksmithBox")
  if not lib().cadaclysm_blacksmith_solid_bounds_box(self:_h(), tolerance, raw) then fail("bounds_box") end
  return box_of(raw)
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
--- (float32 (n, 3), float32 (n, 3), uint32 (m)) over a tessellation held for
--- them alone -- `view.pointer` is the raw pointer, `view.size` its element
--- count. See the note at the top for what that does and does not protect you
--- from.
function Solid:mesh(tolerance)
  if tolerance == nil then tolerance = 0.05 end
  local held = hold(self, tolerance, "mesh")
  local m = lib().cadaclysm_blacksmith_tessellation_mesh(held._ptr)
  local n = m.vertex_count
  return view(self, held, m.positions, { n, 3 }, "float32"),
    view(self, held, m.normals, { n, 3 }, "float32"),
    view(self, held, m.indices, { m.index_count }, "uint32")
end

--- `mesh` in `double`: the very same tessellation at `tolerance` (default 0.05)
--- `mesh` gives when the solid's own cache still holds it -- same index view --
--- with `positions`/`normals` unnarrowed -- three views (float64 (n, 3),
--- float64 (n, 3), uint32 (m)). Exact far from the origin, where `mesh`'s
--- `float` positions are not.
function Solid:mesh64(tolerance)
  if tolerance == nil then tolerance = 0.05 end
  local held = hold(self, tolerance, "mesh64")
  local m = lib().cadaclysm_blacksmith_tessellation_mesh64(held._ptr)
  local n = m.vertex_count
  return view(self, held, m.positions, { n, 3 }, "float64"),
    view(self, held, m.normals, { n, 3 }, "float64"),
    view(self, held, m.indices, { m.index_count }, "uint32")
end

--- The feature edges at `tolerance` (default 0.05) as a Lua array of float32
--- (k, 3) views, one per polyline, over a tessellation held for them alone, as
--- `mesh`'s is.
function Solid:edge_polylines(tolerance)
  if tolerance == nil then tolerance = 0.05 end
  local held = hold(self, tolerance, "edge_polylines")
  local p = lib().cadaclysm_blacksmith_tessellation_edge_polylines(held._ptr)
  local out = {}
  for i = 0, p.polyline_count - 1 do
    local a, b = p.offsets[i], p.offsets[i + 1]
    local pointer = p.points ~= nil and (p.points + 3 * a) or nil
    out[i + 1] = view(self, held, pointer, { b - a, 3 }, "float32")
  end
  return out
end

-- The kernel's mesh_face_triangles, kept for the viewer follow-up (as Go keeps it): how
-- many triangles each face meshed to at `tolerance`, in face order, summing to `mesh`'s
-- triangle count at the same tolerance -- copied out into a Lua array of numbers, out of
-- a tessellation held just for this call (see the note at the top): nothing about the
-- result depends on the solid's own cache once read.
local function mesh_face_triangles(solid, tolerance)
  local held = hold(solid, tolerance, "mesh_face_triangles")
  local t = lib().cadaclysm_blacksmith_tessellation_face_triangles(held._ptr)
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

--- This solid's silhouette from the camera `words` describes (`svg_text`'s) -- where its
--- surfaces turn away from the eye, which no edge of it lies on. Returns `{ points, weights,
--- count }` as the reader's `Node:silhouette_beziers` does: Lua tables of numbers, four
--- control points a curve, three numbers each (`count * 12`), one weight a control point
--- (`count * 4`). The library's block is the caller's to free; it is copied out and freed
--- before this returns, on every path, so there is nothing for the caller to release.
---
--- A body with no silhouette (every face planar) is an empty answer, `count == 0` and
--- empty tables, not an error. Raises `BuildError` on a refused option (a tolerance that
--- is not finite and positive, say), the message beginning `silhouette: `.
function Solid:silhouette_beziers(words)
  local o = svg_options(words)
  local count = ffi.new("uint32_t[1]")
  local data = lib().cadaclysm_blacksmith_silhouette_beziers(solid_handle(self, "silhouette_beziers"), o, count)
  if data == nil then
    -- All-null with count 0 is both the empty answer and a refusal; the thread's error, cleared
    -- at entry, tells them apart.
    if last_error() ~= "" then fail("silhouette_beziers") end
    return { points = {}, weights = {}, count = 0 }
  end
  local n = count[0]
  -- Each curve is 16 doubles: four control points (x, y, z), then four weights.
  local ok, out = pcall(function()
    local points, weights = {}, {}
    for c = 0, n - 1 do
      for i = 0, 11 do points[c * 12 + i + 1] = data[c * 16 + i] end
      for i = 0, 3 do weights[c * 4 + i + 1] = data[c * 16 + 12 + i] end
    end
    return { points = points, weights = weights, count = n }
  end)
  lib().cadaclysm_blacksmith_silhouette_beziers_free(data, n)
  if not ok then error(out, 0) end
  return out
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

--- What the solid measures, per unit density: `area`, `volume`, `centroid`,
--- `inertia` and the principal moments and axes, each beside a bound on its own
--- error, and the flags `closed`, `inverted`, `accuracy_met` and `from_mesh`.
--- `accuracy` is relative; nil or 0 asks for the default, a part in ten million.
---
--- `volume`, `centroid`, `inertia` and `principal_moments` mean something only
--- where `closed` -- on a sheet they are zero and `area` is still measured. A
--- body's mass is `density * volume` and the inertia scales the same way:
--- nothing here assumes a density. Tables are 1-based, `inertia` row-major.
function Solid:mass(accuracy)
  local out = ffi.new("CadaclysmBlacksmithMassProperties[1]")
  if not lib().cadaclysm_blacksmith_mass_properties(self:_h(), accuracy or 0, out) then fail("mass") end
  local m = out[0]
  local function triple(a) return { a[0], a[1], a[2] } end
  local function nine(a)
    local t = {}
    for i = 0, 8 do t[i + 1] = a[i] end
    return t
  end
  return Mass.new({
    closed = m.closed ~= 0,
    inverted = m.inverted ~= 0,
    accuracy_met = m.accuracy_met ~= 0,
    from_mesh = m.from_mesh ~= 0,
    area = m.area,
    area_error = m.area_error,
    volume = m.volume,
    volume_error = m.volume_error,
    centroid = triple(m.centroid),
    centroid_error = m.centroid_error,
    inertia = nine(m.inertia),
    inertia_error = m.inertia_error,
    principal_moments = triple(m.principal_moments),
    principal_axes = nine(m.principal_axes),
  })
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

--- This solid coloured -- `colour` is "#rgb", "#rrggbb", a CSS colour name or {r, g, b}
--- in 0..1 -- or with `face` (an index, as `select_face` returns) just that face, whose
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
  -- This call tessellates the solid's own cache like `bounds_at` does, even to report "no
  -- paint" -- it may re-mesh the solid at `tolerance` -- but a mesh or edge view taken
  -- earlier owns its own tessellation and is untouched by that either way, and this method
  -- copies its own result out and keeps nothing borrowed itself.
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

--- This solid split by the closed `profile` drawn on `frame`, pushed straight
--- through it along the frame's z both ways: the bodies outside the profile first,
--- then those inside (a Lua array). Where the plane lies along z does not matter.
function Solid:split_by_profile(profile, frame, tolerance, progress)
  if tolerance == nil then tolerance = 0.05 end
  local a, p, f = self:_h(), profile_handle(profile, "split_by_profile"), frame_arg(frame)
  local cb, done = progress_callback(progress)
  local all = new_solid(done(lib().cadaclysm_blacksmith_split_by_profile(a, p, f, tolerance, cb, nil)))
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
  "split_by_plane", "split_by_profile", "shell", "thicken" }) do
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

--- What a solid measures, per unit density, each figure beside a bound on its own
--- error: what `Solid:mass` returns.
---
--- Per unit density is the primitive: a body's weight is `density * volume` and
--- its inertia scales the same way, so `weight` is the only figure that takes
--- one. `volume`, `centroid`, `inertia` and `principal_moments` mean something
--- only where `closed`; where `accuracy_met` is false the refinement stopped
--- early and the figures are honest but less certain, which the errors say.
--- Tables are 1-based, `inertia` and `principal_axes` row-major.
---@class Mass
---@field closed boolean           the volume-side figures mean something
---@field inverted boolean         every face pointed inward; given as if not
---@field accuracy_met boolean     every error came under the accuracy asked for
---@field from_mesh boolean        measured on a mesh, so the errors are the rounding floor
---@field area number
---@field area_error number        a bound on `area`'s own error
---@field volume number            where `closed`
---@field volume_error number      a bound on `volume`'s own error
---@field centroid number[]        the volume's, where `closed`
---@field centroid_error number    a bound on the distance to the true centroid
---@field inertia number[]         nine, about the centroid, products negated
---@field inertia_error number     a bound on every entry
---@field principal_moments number[]  three, ascending
---@field principal_axes number[]  nine, unit, right-handed, row `i` for moment `i`
Mass = {}
class(Mass)
callable(Mass)
M.Mass = Mass

function Mass.new(fields)
  return setmetatable(fields, Mass)
end

--- `density * volume`, in whatever units the model and the density agree on.
---@param density number
---@return number
function Mass:weight(density)
  return density * self.volume
end

Mass.__tostring = function(self)
  if not self.closed then
    return ("Mass(open, area=%.6g+-%.3g)"):format(self.area, self.area_error)
  end
  return ("Mass(area=%.6g+-%.3g, volume=%.6g+-%.3g)"):format(
    self.area, self.area_error, self.volume, self.volume_error)
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

-- ---- collider ---------------------------------------------------------------------

--- An axis-aligned box: `lo` and `hi`, three numbers each. The broad phase's own shape
--- (`Solid.bounds_box`, `Collider`'s own boxes): cheap to move and to test against
--- another, before anything is meshed.
---@class Box
---@field lo number[]  {x, y, z}
---@field hi number[]  {x, y, z}
Box = {}
class(Box)
callable(Box)
M.Box = Box

function Box.new(lo, hi)
  return setmetatable({
    lo = { number(lo[1], "lo"), number(lo[2], "lo"), number(lo[3], "lo") },
    hi = { number(hi[1], "hi"), number(hi[2], "hi"), number(hi[3], "hi") },
  }, Box)
end

box_of = function(raw)
  return Box.new({ tonumber(raw.lo[0]), tonumber(raw.lo[1]), tonumber(raw.lo[2]) },
    { tonumber(raw.hi[0]), tonumber(raw.hi[1]), tonumber(raw.hi[2]) })
end

box_words = function(box)
  local raw = ffi.new("CadaclysmBlacksmithBox")
  raw.lo[0], raw.lo[1], raw.lo[2] = box.lo[1], box.lo[2], box.lo[3]
  raw.hi[0], raw.hi[1], raw.hi[2] = box.hi[1], box.hi[2], box.hi[3]
  return raw
end

--- This box moved by `frame` (rigid), boxed again on the world axes -- not this box's
--- corners individually moved, which would not in general be a box at all: the
--- *bounding* box of the moved corners.
function Box:moved(frame)
  local raw, f, out = box_words(self), frame_arg(frame), ffi.new("CadaclysmBlacksmithBox")
  if not lib().cadaclysm_blacksmith_box_moved(raw, f, out) then fail("box_moved") end
  return box_of(out)
end

--- Whether this box and `other` share a point (touching counts).
function Box:overlaps(other)
  return lib().cadaclysm_blacksmith_box_overlaps(box_words(self), box_words(other))
end

Box.__tostring = function(self)
  return ("Box(lo=(%g, %g, %g), hi=(%g, %g, %g))"):format(self.lo[1], self.lo[2], self.lo[3], self.hi[1], self.hi[2], self.hi[3])
end

--- True only if box `a` at `frame_a` and box `b` at `frame_b` cannot touch -- a
--- separating axis among the boxes' face normals and edge-direction crosses; touching
--- is not apart. Sharper than moving each box and asking `Box:overlaps`, which boxes the
--- *result* on the world axes again and so can call two oriented boxes overlapping when
--- they are not (two unit boxes, the second turned 45 degrees about z and moved 2.3
--- along x: their world boxes overlap, but the boxes themselves do not touch).
function M.boxes_apart(a, frame_a, b, frame_b)
  local ra, rb = box_words(a), box_words(b)
  local fa, fb = frame_arg(frame_a), frame_arg(frame_b)
  local apart = ffi.new("bool[1]")
  if not lib().cadaclysm_blacksmith_boxes_apart(ra, fa, rb, fb, apart) then fail("boxes_apart") end
  return apart[0]
end

--- Counts of one `Collider:check` call: the candidate pairs `considered`, how many of
--- them the world boxes and the oriented boxes cleared, how many the share left to
--- another call, how the rest were answered (`cached`, `closed_form`, `meshed`), and how
--- many were `refused`. `confirmed` is the subset of `meshed` that were thin mesh-path
--- overlaps sent to `Solid:common` itself for a final answer.
---@class ColliderStats
---@field considered integer
---@field world_boxes integer
---@field oriented_boxes integer
---@field skipped_share integer
---@field cached integer
---@field closed_form integer
---@field meshed integer
---@field refused integer
---@field confirmed integer
ColliderStats = {}
class(ColliderStats)
M.ColliderStats = ColliderStats

local function collider_stats_of(raw)
  return setmetatable({
    considered = tonumber(raw.considered), world_boxes = tonumber(raw.world_boxes),
    oriented_boxes = tonumber(raw.oriented_boxes), skipped_share = tonumber(raw.skipped_share),
    cached = tonumber(raw.cached), closed_form = tonumber(raw.closed_form),
    meshed = tonumber(raw.meshed), refused = tonumber(raw.refused), confirmed = tonumber(raw.confirmed),
  }, ColliderStats)
end

ColliderStats.__tostring = function(self)
  return ("ColliderStats(considered=%d, world_boxes=%d, oriented_boxes=%d, skipped_share=%d, cached=%d, "
    .. "closed_form=%d, meshed=%d, refused=%d, confirmed=%d)"):format(self.considered, self.world_boxes,
    self.oriented_boxes, self.skipped_share, self.cached, self.closed_form, self.meshed, self.refused, self.confirmed)
end

--- One pair `Collider:check` found overlapping (`overlap` true), or could not decide
--- (`overlap` false; `text` says why, empty for an overlap). `positions`/`normals` are
--- {x, y, z} triples, three per triangle (unwelded); `indices` indexes them (from zero)
--- -- all empty for a refused pair. `depth` is the thinnest side of the overlap's world
--- box, 0 for a refused pair.
---
--- `solid()` rebuilds the exact overlap now, from the frames `Collider:check` found it
--- at; this keeps the collisions handle behind every hit of one `check` call alive
--- until the last of them is collected, freeing it only then (the handle is shared
--- `ffi.gc`'d cdata: LuaJIT frees it only once nothing references it). Named
--- `CollisionHit` rather than the plainer `Hit`, which this module already uses for a
--- curve-crossing result (`Solid:hits`).
---@class CollisionHit
---@field a integer
---@field b integer
---@field overlap boolean
---@field kind string
---@field depth number
---@field text string
---@field positions number[]
---@field normals number[]
---@field indices integer[]
CollisionHit = {}
class(CollisionHit)
M.CollisionHit = CollisionHit

function CollisionHit.of(raw, collisions, index)
  local indices = {}
  if raw.indices ~= nil then
    for k = 0, tonumber(raw.index_count) - 1 do indices[k + 1] = tonumber(raw.indices[k]) end
  end
  return setmetatable({
    a = tonumber(raw.a), b = tonumber(raw.b), overlap = raw.overlap,
    kind = raw.overlap and "overlap" or "refused",
    depth = tonumber(raw.depth),
    text = text(raw.text),
    positions = points_at(raw.positions, tonumber(raw.vertex_count)),
    normals = points_at(raw.normals, tonumber(raw.vertex_count)),
    indices = indices,
    _collisions = collisions, _index = index,
  }, CollisionHit)
end

--- The exact overlap of this pair at the frames `Collider:check` found it at, as a new
--- solid. Raises for a refused pair (`overlap` false) or a collisions handle already
--- closed some other way.
function CollisionHit:solid()
  local h = lib().cadaclysm_blacksmith_collisions_solid(self._collisions, self._index)
  return new_solid(h, "collisions_solid")
end

CollisionHit.__tostring = function(self)
  return ("CollisionHit(a=%d, b=%d, overlap=%s, depth=%g)"):format(self.a, self.b, tostring(self.overlap), self.depth)
end

--- Parts meshed once, asked pose after pose which of them interfere: `solids` at rest,
--- meshed at `tolerance` (0.05), `groups` one group index per solid (nil: each solid its
--- own group -- `check` then takes one frame per solid), `allowed` pairs of part indices
--- never tested (designed contacts, by part index, flat: {a0, b0, a1, b1, ...}).
--- `close()` frees this handle; so does the garbage collector.
---@class Collider
Collider = {}
local Collider_get = {}
class(Collider, Collider_get)
callable(Collider)
M.Collider = Collider

local function free_collider(h)
  lib().cadaclysm_blacksmith_collider_free(h)
end

function Collider.new(solids, tolerance, groups, allowed)
  if tolerance == nil then tolerance = 0.05 end
  local count = #solids
  if groups ~= nil and #groups ~= count then
    raise(("Collider: groups must have one entry per solid (%d solids, %d groups)"):format(count, #groups))
  end
  local parts = ffi.new("const struct CadaclysmBlacksmithSolid *[?]", math.max(count, 1))
  for i, s in ipairs(solids) do parts[i - 1] = solid_handle(s, "collider") end
  local groups_arr = nil
  if groups ~= nil then
    groups_arr = ffi.new("uint32_t[?]", #groups)
    for i, g in ipairs(groups) do groups_arr[i - 1] = g end
  end
  local allowed_flat = allowed or {}
  local allowed_arr = ffi.new("uint32_t[?]", math.max(#allowed_flat, 1))
  for i, v in ipairs(allowed_flat) do allowed_arr[i - 1] = v end
  local h = lib().cadaclysm_blacksmith_collider_new(parts, count, tolerance, groups_arr, allowed_arr, #allowed_flat / 2)
  checked(h, "collider_new")
  return setmetatable({ _ptr = ffi.gc(h, free_collider) }, Collider)
end

--- Free the collider. Idempotent; a `CollisionHit`'s own `solid()` still works
--- afterwards -- it keeps the collisions handle, not this one.
function Collider:close()
  local h = rawget(self, "_ptr")
  if h ~= nil then
    self._ptr = nil
    ffi.gc(h, nil)
    lib().cadaclysm_blacksmith_collider_free(h)
  end
end

function Collider:_h()
  local h = rawget(self, "_ptr")
  if h == nil then raise("collider: closed") end
  return h
end

--- How many groups this collider has -- the highest group index past `new`, plus one.
function Collider_get.group_count(self)
  return tonumber(lib().cadaclysm_blacksmith_collider_group_count(self:_h()))
end

--- Counts of the last `check` call (all zero before the first one).
function Collider_get.stats(self)
  local raw = ffi.new("CadaclysmBlacksmithColliderStats")
  if not lib().cadaclysm_blacksmith_collider_stats(self:_h(), raw) then fail("collider_stats") end
  return collider_stats_of(raw)
end

--- The pairs that interfere, or could not be decided, with each group placed at its
--- matching frame in `frames` (one per group, in group order). `share`: nil, every pair
--- past the box filters is decided now; {k, n}, only those whose index is `k` modulo `n`
--- (the shares of one pose are disjoint and cover it -- split one `check` across `n`
--- workers).
function Collider:check(frames, share)
  local h = self:_h()
  local n = #frames
  local flat = ffi.new("double[?]", math.max(n * 12, 1))
  for i, f in ipairs(frames) do
    local fv = frame_arg(f)
    for k = 0, 11 do flat[(i - 1) * 12 + k] = fv[k] end
  end
  local share_k, share_n = 0, 0
  if share ~= nil then share_k, share_n = share[1], share[2] end
  local found = lib().cadaclysm_blacksmith_collider_check(h, flat, n, share_k, share_n)
  if found == nil then fail("collider_check") end
  local count = tonumber(lib().cadaclysm_blacksmith_collisions_count(found))
  if count == 0 then
    lib().cadaclysm_blacksmith_collisions_free(found)
    return {}
  end
  local kept = ffi.gc(found, function(hh) lib().cadaclysm_blacksmith_collisions_free(hh) end)
  local hits, raw = {}, ffi.new("CadaclysmBlacksmithCollisionHit")
  for i = 0, count - 1 do
    if not lib().cadaclysm_blacksmith_collisions_hit(kept, i, raw) then fail("collisions_hit") end
    hits[#hits + 1] = CollisionHit.of(raw, kept, i)
  end
  return hits
end

-- ---- the Kiln: the SubD cage ---------------------------------------------------------------

local SUBD_AXES = { x = 0, y = 1, z = 2 }
local SUBD_KINDS = { vertices = 0, edges = 1, faces = 2 }
local SUBD_PICKS = { vertex = 0, edge = 1, face = 2 }

local function subd_shown(v)
  if type(v) == "string" then return ("%q"):format(v) end
  return tostring(v)
end

-- A count as the C ABI reads it (a whole number, 0 to 4294967295), refused here, named,
-- rather than wrapped by the FFI conversion.
local function subd_count(value, what)
  if type(value) ~= "number" or value < 0 or value > 4294967295 or value ~= math.floor(value) then
    raise(("%s must be a whole number from 0 to 4294967295, not %s"):format(what, subd_shown(value)))
  end
  return value
end

local function subd_axis(axis, what)
  local k = type(axis) == "string" and SUBD_AXES[axis:lower()] or nil
  if k == nil then raise(("%s: axis must be 'x', 'y' or 'z', not %s"):format(what, subd_shown(axis))) end
  return k
end

-- `{a, b}` vertex pairs -- edges -- as the flat uint32_t array the C ABI reads, and how
-- many pairs.
local function subd_pairs(list, call, param)
  if type(list) ~= "table" then
    raise(("%s: %s must be a list of {a, b} vertex pairs, not %s"):format(call, param, subd_shown(list)))
  end
  local flat = {}
  for i, pair in ipairs(list) do
    local function whole(v) return type(v) == "number" and v >= 0 and v == math.floor(v) end
    if type(pair) ~= "table" or #pair ~= 2 or not whole(pair[1]) or not whole(pair[2]) then
      raise(("%s: %s[%d] is not an {a, b} vertex pair: %s"):format(call, param, i, subd_shown(pair)))
    end
    flat[#flat + 1] = pair[1]
    flat[#flat + 1] = pair[2]
  end
  local ids = uint32s(flat, call, param)
  return ids, #flat / 2
end

-- Positions as the flat doubles the C ABI reads: a flat run of three a vertex, or
-- `{x, y, z}` each. Returns the array and the vertex count.
local function subd_points(positions, call)
  if type(positions) ~= "table" then
    raise(("%s: positions must be numbers, three a vertex, not %s"):format(call, subd_shown(positions)))
  end
  local flat = positions
  if type(positions[1]) == "table" then
    flat = {}
    for i, p in ipairs(positions) do
      if type(p) ~= "table" or #p ~= 3 then
        raise(("%s: positions[%d] must be {x, y, z}, not %s"):format(call, i, subd_shown(p)))
      end
      flat[#flat + 1] = p[1]
      flat[#flat + 1] = p[2]
      flat[#flat + 1] = p[3]
    end
  end
  if #flat % 3 ~= 0 then
    raise(("%s: positions must be three numbers a vertex, not %d"):format(call, #flat))
  end
  local out = ffi.new("double[?]", math.max(#flat, 1))
  for i = 1, #flat do out[i - 1] = number(flat[i], call .. " positions") end
  return out, #flat / 3
end

-- Sixteen numbers column-major, as the C ABI reads them, or a 4x4 of rows (row-major, as
-- Python's `transform` takes one).
local function subd_matrix(matrix)
  if type(matrix) ~= "table" then
    raise(("transform matrix: sixteen numbers column-major or a 4x4, not %s"):format(subd_shown(matrix)))
  end
  if type(matrix[1]) == "table" then
    local ok = #matrix == 4
    for r = 1, 4 do
      if type(matrix[r]) ~= "table" or #matrix[r] ~= 4 then ok = false end
    end
    if not ok then raise("transform matrix: a nested matrix must be 4x4 (four rows of four numbers)") end
    local columns = {}
    for c = 1, 4 do
      for r = 1, 4 do columns[#columns + 1] = matrix[r][c] end
    end
    return doubles(columns, 16, "transform matrix")
  end
  return doubles(matrix, 16, "transform matrix")
end

-- `n` uint32_t values copied out of a view into a Lua list (a view may be NULL when n is 0).
local function subd_ids(ptr, n)
  local out = {}
  for i = 1, n do out[i] = tonumber(ptr[i - 1]) end
  return out
end

-- Flat ids read back as `{a, b}` pairs.
local function subd_pairs_of(ids)
  local out = {}
  for i = 1, #ids - 1, 2 do out[#out + 1] = { ids[i], ids[i + 1] } end
  return out
end

-- `n` triples of doubles copied out of a view as `{x, y, z}` rows.
local function subd_rows(ptr, n)
  local out = {}
  for i = 0, n - 1 do out[i + 1] = { ptr[3 * i], ptr[3 * i + 1], ptr[3 * i + 2] } end
  return out
end

--- One level of a cage's smooth surface, as `Subd:smooth_mesh` returns it, copied out of
--- the cage so it outlives it. `positions` and `normals` are lists of `{x, y, z}` -- limit
--- positions and unit outward limit normals; `indices` is a flat list, three vertex ids
--- a triangle (0-based); `triangle_face` the face of the **full** cage each triangle lies
--- on (on a mirrored half, face `f` of the half is `f` and its reflection `f + #faces`).
---@class SubdMesh
---@field positions number[][]
---@field normals number[][]
---@field indices integer[]
---@field triangle_face integer[]
local SubdMesh = {}
class(SubdMesh)
M.SubdMesh = SubdMesh

local function subd_mesh_of(raw)
  local n, m = tonumber(raw.vertex_count), tonumber(raw.index_count)
  return setmetatable({
    positions = subd_rows(raw.positions, n),
    normals = subd_rows(raw.normals, n),
    indices = subd_ids(raw.indices, m),
    triangle_face = subd_ids(raw.triangle_face, m / 3),
  }, SubdMesh)
end

--- What `Subd:to_solid` did and how close it came: `regular` patches exact from their own
--- net and `refined` ones from a refined neighbourhood; the Catmull-Clark `steps` taken
--- first (1 or 2); `levels`, the deepest local refinement a patch took (0 when none was
--- refined); the largest `deviation` from the limit surface, as a fraction of the cage's
--- bounding-box diagonal; the largest tangent break `g1_angle_deg` across a side that is
--- not creased, in degrees; and the world points they were measured at, `deviation_at` and
--- `g1_at` (`{x, y, z}` each).
---@class SubdReport
---@field regular integer
---@field refined integer
---@field steps integer
---@field levels integer
---@field deviation number
---@field g1_angle_deg number
---@field deviation_at number[]
---@field g1_at number[]
local SubdReport = {}
class(SubdReport)
M.SubdReport = SubdReport

local function subd_report_of(raw)
  return setmetatable({
    regular = tonumber(raw.regular), refined = tonumber(raw.refined),
    steps = tonumber(raw.steps), levels = tonumber(raw.levels),
    deviation = raw.deviation, g1_angle_deg = raw.g1_angle_deg,
    deviation_at = { raw.deviation_at[0], raw.deviation_at[1], raw.deviation_at[2] },
    g1_at = { raw.g1_at[0], raw.g1_at[1], raw.g1_at[2] },
  }, SubdReport)
end

--- A Catmull-Clark control cage: positions, faces, creased edges, pinned vertices, an
--- optional mirror plane, and the selection of the edit that made it. Immutable: every
--- edit returns a new `Subd`, with `selection` naming what that edit touched. `to_solid`
--- turns it into an exact B-rep. `close()` frees this handle; so does the garbage
--- collector. A refusal raises `BuildError` with the kernel's own words. Ids count from
--- zero; an edge is `{a, b}`; a selection is `{kind = "vertices" | "edges" | "faces", ids
--- = {...}}`, an edge selection's ids `{a, b}` pairs.
---@class Subd
local Subd = {}
local Subd_get = {}
class(Subd, Subd_get)
M.Subd = Subd

local function free_subd(h)
  lib().cadaclysm_blacksmith_subd_free(h)
end

local function new_subd(handle, what)
  checked(handle, what or "subd")
  return setmetatable({ _ptr = ffi.gc(handle, free_subd) }, Subd)
end

--- Free the cage. Idempotent.
function Subd:close()
  local h = rawget(self, "_ptr")
  if h ~= nil then
    self._ptr = nil
    ffi.gc(h, nil)
    lib().cadaclysm_blacksmith_subd_free(h)
  end
end

function Subd:_h()
  local h = rawget(self, "_ptr")
  if h == nil then raise("subd: closed") end
  return h
end

-- -- the primitives

--- A box of `size` (`{x, y, z}`, default 2 each), centred on the origin, with `segments`
--- (`{nx, ny, nz}`, default 1 each) quads along each axis (1 to 1024).
function Subd.cuboid(size, segments)
  local s = doubles(size or { 2, 2, 2 }, 3, "cuboid size")
  local counts, n = uint32s(segments or { 1, 1, 1 }, "cuboid", "segments")
  if n ~= 3 then raise(("cuboid segments: expected 3 numbers, got %d"):format(n)) end
  return new_subd(lib().cadaclysm_blacksmith_subd_cuboid(s[0], s[1], s[2], counts[0], counts[1], counts[2]), "subd_cuboid")
end

--- A cylinder along +Z: one n-gon cap per end with `sides` sides and `rings` bands of
--- quads between them; with `creased_rims` the two rim loops are creased, so the caps stay
--- flat. The rims are creased by default (nil is true), which is what converts: an
--- uncreased cylinder of 7 or more sides is refused by `to_solid` at the default
--- tolerances. Defaults: radius 1, height 2, sides 8, rings 1.
function Subd.cylinder(radius, height, sides, rings, creased_rims)
  if creased_rims == nil then creased_rims = true end
  return new_subd(lib().cadaclysm_blacksmith_subd_cylinder(
    number(radius == nil and 1 or radius, "cylinder radius"), number(height == nil and 2 or height, "cylinder height"),
    subd_count(sides == nil and 8 or sides, "cylinder sides"), subd_count(rings == nil and 1 or rings, "cylinder rings"),
    creased_rims and true or false), "subd_cylinder")
end

--- A quad ball of `radius` (default 1): a cube grid with `segments` (default 2) quads per
--- edge, each vertex pushed out to the radius.
function Subd.sphere(radius, segments)
  return new_subd(lib().cadaclysm_blacksmith_subd_sphere(
    number(radius == nil and 1 or radius, "sphere radius"), subd_count(segments == nil and 2 or segments, "sphere segments")),
    "subd_sphere")
end

--- A torus around +Z: `around` (default 12) steps about the axis at `major` (default 3),
--- `tube` (default 8) steps round the tube of `minor` (default 1), all quads.
function Subd.torus(major, minor, around, tube)
  return new_subd(lib().cadaclysm_blacksmith_subd_torus(
    number(major == nil and 3 or major, "torus major"), number(minor == nil and 1 or minor, "torus minor"),
    subd_count(around == nil and 12 or around, "torus around"), subd_count(tube == nil and 8 or tube, "torus tube")),
    "subd_torus")
end

--- A cage from its parts, the lossless inverse of reading them back: `positions` (a flat
--- run of three a vertex, or `{x, y, z}` each), `faces` lists of vertex ids, `creases`
--- `{a, b}` pairs that are edges, `pins` vertex ids, and `symmetry` nil or `{axis = "x" |
--- "y" | "z", tolerance = ...}` for a mirrored half, as `symmetry` reports it. The new
--- cage selects nothing.
function Subd.from_parts(positions, faces, creases, pins, symmetry)
  local points, vertex_count = subd_points(positions, "from_parts")
  if type(faces) ~= "table" then
    raise(("from_parts: faces must be a list of vertex-id lists, not %s"):format(subd_shown(faces)))
  end
  local sizes, loop = {}, {}
  for i, face in ipairs(faces) do
    local _, n = uint32s(face, "from_parts", ("faces[%d]"):format(i))
    sizes[i] = n
    for k = 1, n do loop[#loop + 1] = face[k] end
  end
  local size_arr, face_count = uint32s(sizes, "from_parts", "faces")
  local loop_arr, index_count = uint32s(loop, "from_parts", "faces")
  local crease_arr, crease_count = subd_pairs(creases or {}, "from_parts", "creases")
  local pin_arr, pin_count = uint32s(pins or {}, "from_parts", "pins")
  local axis, tolerance = -1, 0
  if symmetry ~= nil then
    local name, within = symmetry.axis, symmetry.tolerance
    if name == nil and within == nil then name, within = symmetry[1], symmetry[2] end
    axis = subd_axis(name, "from_parts symmetry")
    tolerance = number(within, "from_parts symmetry")
  end
  return new_subd(lib().cadaclysm_blacksmith_subd_from_parts(points, vertex_count, size_arr, face_count,
    loop_arr, index_count, crease_arr, crease_count, pin_arr, pin_count, axis, tolerance), "subd_from_parts")
end

-- -- the parts, every one a copy

-- Reads the handle's parts view, runs `read` on it, and returns what it copied out.
function Subd:_parts(read)
  local out = ffi.new("CadaclysmBlacksmithSubdParts")
  if not lib().cadaclysm_blacksmith_subd_parts(self:_h(), out) then fail("subd_parts") end
  return read(out)
end

--- The cage's vertices, a list of `{x, y, z}` of your own: a copy.
function Subd_get.positions(self)
  return self:_parts(function(p) return subd_rows(p.positions, tonumber(p.vertex_count)) end)
end

--- Each face's vertex ids, in loop order.
function Subd_get.faces(self)
  return self:_parts(function(p)
    local sizes = subd_ids(p.face_sizes, tonumber(p.face_count))
    local loop = subd_ids(p.face_indices, tonumber(p.index_count))
    local faces, at = {}, 0
    for i, size in ipairs(sizes) do
      local face = {}
      for k = 1, size do face[k] = loop[at + k] end
      faces[i] = face
      at = at + size
    end
    return faces
  end)
end

--- The creased edges, each `{smaller id, larger id}`, sorted.
function Subd_get.creases(self)
  return self:_parts(function(p) return subd_pairs_of(subd_ids(p.creases, 2 * tonumber(p.crease_count))) end)
end

--- The pinned vertices: they refine as corners and stay put.
function Subd_get.pins(self)
  return self:_parts(function(p) return subd_ids(p.pins, tonumber(p.pin_count)) end)
end

--- nil for an ordinary cage; for a mirrored half, `{axis, tolerance}`: the plane's axis
--- ("x", "y" or "z") and how far from it a vertex counts as on it.
function Subd_get.symmetry(self)
  return self:_parts(function(p)
    if p.symmetry_axis < 0 then return nil end
    return { axis = ("xyz"):sub(p.symmetry_axis + 1, p.symmetry_axis + 1), tolerance = p.symmetry_tolerance }
  end)
end

--- What the edit that made this cage touched: `{kind = "vertices" | "faces", ids}` or
--- `{kind = "edges", ids = {{a, b}, ...}}`; nil for a cage no edit selected (a primitive,
--- `from_parts`, the mirror calls).
function Subd_get.selection(self)
  return self:_parts(function(p)
    local kind, count = tonumber(p.selection_kind), tonumber(p.selection_count)
    if kind > 2 then return nil end
    if kind == 1 then return { kind = "edges", ids = subd_pairs_of(subd_ids(p.selection, 2 * count)) } end
    return { kind = kind == 0 and "vertices" or "faces", ids = subd_ids(p.selection, count) }
  end)
end

-- -- the edits, every one a new cage

local function subd_selected(selection, call)
  if type(selection) ~= "table" then
    raise(("%s: selection must be {kind = 'vertices' | 'edges' | 'faces', ids = ...}, not %s"):format(call, subd_shown(selection)))
  end
  local kind = selection.kind
  if type(kind) ~= "string" or SUBD_KINDS[kind] == nil then
    raise(("%s: kind must be 'vertices', 'edges' or 'faces', not %s"):format(call, subd_shown(kind)))
  end
  local ids, count
  if kind == "edges" then
    ids, count = subd_pairs(selection.ids, call, "selection ids")
  else
    ids, count = uint32s(selection.ids, call, "selection ids")
  end
  return SUBD_KINDS[kind], ids, count
end

--- A new cage with the selected elements moved by `matrix`, and the same elements
--- selected. `selection` is `{kind, ids}`; `matrix` sixteen numbers column-major, or a 4x4
--- of rows (row-major); a rotation about a point is baked in by the caller.
function Subd:transform(selection, matrix)
  local h = self:_h()
  local kind, ids, count = subd_selected(selection, "transform")
  local m = subd_matrix(matrix)
  return new_subd(lib().cadaclysm_blacksmith_subd_transform(h, kind, ids, count, m), "subd_transform")
end

--- A new cage with `edges` (`{a, b}` pairs) creased, or un-creased when `on` is false
--- (default true); it selects them.
function Subd:crease(edges, on)
  local h = self:_h()
  local flat, count = subd_pairs(edges, "crease", "edges")
  if on == nil then on = true end
  return new_subd(lib().cadaclysm_blacksmith_subd_set_crease(h, flat, count, on and true or false), "subd_set_crease")
end

--- A new cage with `vertices` pinned (they refine as corners and stay put), or released
--- when `on` is false (default true); it selects them.
function Subd:pin(vertices, on)
  local h = self:_h()
  local ids, count = uint32s(vertices, "pin", "vertices")
  if on == nil then on = true end
  return new_subd(lib().cadaclysm_blacksmith_subd_set_pin(h, ids, count, on and true or false), "subd_set_pin")
end

--- A new cage with `faces` pushed out by `distance` along each connected region's average
--- normal, a quad wall on each boundary edge; it selects the moved faces.
function Subd:extrude(faces, distance)
  local h = self:_h()
  local ids, count = uint32s(faces, "extrude", "faces")
  return new_subd(lib().cadaclysm_blacksmith_subd_extrude(h, ids, count, number(distance, "extrude distance")), "subd_extrude")
end

--- A new cage with `faces` shrunk by `amount`, in (0, 1), within their surface and a ring
--- of quads round each region (each face, with `individual`); it selects the inner faces.
function Subd:inset(faces, amount, individual)
  local h = self:_h()
  local ids, count = uint32s(faces, "inset", "faces")
  return new_subd(lib().cadaclysm_blacksmith_subd_inset(h, ids, count, number(amount, "inset amount"),
    individual and true or false), "subd_inset")
end

--- A new cage with a loop of edges cut across the ring of quads through `edge` (`{a, b}`),
--- at `a + at * (b - a)` with `at` in (0, 1) (default 0.5); it selects the new loop.
function Subd:insert_loop(edge, at)
  if type(edge) ~= "table" then
    raise(("%s: edge[1] is not an {a, b} vertex pair: %s"):format("insert_loop", subd_shown(edge)))
  end
  local h = self:_h()
  local ids = subd_pairs({ edge }, "insert_loop", "edge")
  return new_subd(lib().cadaclysm_blacksmith_subd_insert_loop(h, ids[0], ids[1],
    number(at == nil and 0.5 or at, "insert_loop at")), "subd_insert_loop")
end

--- The loop of edges through `edge`, straight across each valence-four vertex, the picked
--- edge first, each `{smaller, larger}`; empty when `edge` is not an edge of the cage.
function Subd:edge_loop(edge)
  if type(edge) ~= "table" then
    raise(("%s: edge[1] is not an {a, b} vertex pair: %s"):format("edge_loop", subd_shown(edge)))
  end
  local h = self:_h()
  local ids = subd_pairs({ edge }, "edge_loop", "edge")
  local looped = new_subd(lib().cadaclysm_blacksmith_subd_edge_loop(h, ids[0], ids[1]), "subd_edge_loop")
  -- Free the loop's handle now even when reading its selection raises, then raise that.
  local ok, selection = pcall(function() return looped.selection end)
  looped:close()
  if not ok then error(selection, 0) end
  return selection and selection.ids or {}
end

--- The positive half of the cage across the plane perpendicular to `axis` ("x", "y" or
--- "z"), as a mirrored cage: every later edit keeps it symmetric.
function Subd:mirror_on(axis)
  local h = self:_h()
  local k = subd_axis(axis, "mirror_on")
  return new_subd(lib().cadaclysm_blacksmith_subd_mirror_on(h, k), "subd_mirror_on")
end

--- The mirror baked: the whole cage as an ordinary one, no longer mirrored.
function Subd:mirror_off()
  return new_subd(lib().cadaclysm_blacksmith_subd_mirror_off(self:_h()), "subd_mirror_off")
end

--- The whole cage of a mirrored half -- the half's vertices first, then their reflections
--- -- or a copy of an ordinary cage.
function Subd:full()
  return new_subd(lib().cadaclysm_blacksmith_subd_full(self:_h()), "subd_full")
end

-- -- the surface

--- The smooth surface refined `levels` times (1 to 6, default 3), as a `SubdMesh` of copies.
function Subd:smooth_mesh(levels)
  local h = self:_h()
  local n = subd_count(levels == nil and 3 or levels, "smooth_mesh levels")
  local out = ffi.new("CadaclysmBlacksmithSubdMesh")
  if not lib().cadaclysm_blacksmith_subd_smooth_mesh(h, n, out) then fail("subd_smooth_mesh") end
  return subd_mesh_of(out)
end

--- The cage element of `kind` ("vertex", "edge" or "face") under `point` (`{x, y, z}`), a
--- point on or near the smooth surface: a vertex or face id, or an edge as `{a, b}` with
--- the smaller id first. nil when nothing is within 0.05 of the cage's diagonal -- not an
--- error; a point that is not finite is refused.
function Subd:pick(point, kind)
  local h = self:_h()
  if type(kind) ~= "string" or SUBD_PICKS[kind] == nil then
    raise(("pick: kind must be 'vertex', 'edge' or 'face', not %s"):format(subd_shown(kind)))
  end
  local at = doubles(point, 3, "pick point")
  local out = ffi.new("uint32_t[2]")
  if not lib().cadaclysm_blacksmith_subd_pick(h, at, SUBD_PICKS[kind], out) then
    -- Nothing near leaves an empty `last_error`; a refusal's text is never empty.
    if last_error() == "" then return nil end
    fail("subd_pick")
  end
  if kind == "edge" then return { tonumber(out[0]), tonumber(out[1]) } end
  return tonumber(out[0])
end

--- The cage as an exact solid, one NURBS face per patch, and a `SubdReport` of what the
--- conversion did: two values, `solid, report`. `tolerance` (default 1e-4) is the largest
--- deviation from the limit surface as a fraction of the cage's diagonal, `g1_angle`
--- (default 0.1) the largest tangent break across an uncreased side in degrees,
--- `max_levels` (default 6) the deepest local refinement (2 to 6). A `tolerance` or
--- `g1_angle` of 0 or less, or a `max_levels` of 0, takes the default. A cage that cannot
--- be held within them is refused with the figures it measured.
function Subd:to_solid(tolerance, g1_angle, max_levels)
  local h = self:_h()
  local report = ffi.new("CadaclysmBlacksmithSubdReport")
  local solid = new_solid(lib().cadaclysm_blacksmith_subd_to_solid(h,
    number(tolerance == nil and 1e-4 or tolerance, "to_solid tolerance"),
    number(g1_angle == nil and 0.1 or g1_angle, "to_solid g1_angle"),
    subd_count(max_levels == nil and 6 or max_levels, "to_solid max_levels"), report), "subd_to_solid")
  return solid, subd_report_of(report)
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

--- Connect `placements` (a Lua array of placement names -- not one string, which would
--- otherwise be read a character at a time) into a link called `name` in this assembly,
--- written as an AP242 kinematic link. An empty name, a name already taken by another
--- link here, an empty `placements`, a placement named twice, a placement this assembly
--- does not have, or a placement already claimed by another link here all raise
--- `BuildError`, and the assembly is left unchanged.
function Assembly:link(name, placements)
  if type(name) ~= "string" then raise("assembly: link's name must be a string, got " .. repr(name)) end
  local list, n = names(placements, "link", "placements")
  -- The array is sized at least 1 so a zero-length link still reaches C as a valid
  -- pointer with count 0, rather than NULL, and gets the kernel's own refusal.
  local arr = ffi.new("const char*[?]", math.max(n, 1))
  for i = 1, n do
    arr[i - 1] = list[i]   -- `list` stays referenced for the whole call below, so these Lua
                            -- strings the array now points into cannot be collected.
  end
  if not lib().cadaclysm_blacksmith_assembly_link(self:_h(), name, arr, n) then fail("assembly_link") end
end

--- Connect this assembly's links `start` and `end` (kept in that order) as a joint
--- called `name`, written as an AP242 kinematic joint. An empty name, a name already
--- taken by another joint here, a link this assembly does not have, a link joined to
--- itself, or a (start, end) pair already joined all raise `BuildError`; the reverse
--- pair is a different joint.
function Assembly:joint(name, start, end_)
  if type(name) ~= "string" then raise("assembly: joint's name must be a string, got " .. repr(name)) end
  if type(start) ~= "string" then raise("assembly: joint's start must be a string, got " .. repr(start)) end
  if type(end_) ~= "string" then raise("assembly: joint's end must be a string, got " .. repr(end_)) end
  if not lib().cadaclysm_blacksmith_assembly_joint(self:_h(), name, start, end_) then fail("assembly_joint") end
end

--- Give joint `joint` its pair: `kind` (a name of the kind table -- "revolute",
--- "prismatic", "cylindrical", "screw", "spherical", "spherical_with_pin", "planar",
--- "universal", "homokinetic", "fully_constrained" or "unconstrained"), the contact
--- frame at rest (twelve numbers, four triples or a `Frame`), and an optional `opts`
--- table: `end_frame` (the frame the pair reaches at its rest values; `frame` itself
--- when left nil), `ranges` (an array `{{lower, upper}, ...}`, one entry per freedom of
--- `kind`, kept in that order; either side `nil` for unbounded; left nil entirely for a
--- kind that allows none), and `pitch` (required and non-zero for "screw", refused for
--- any other kind). Raises `BuildError` with the kernel's own text when a rule refuses
--- it; the assembly is then unchanged.
function Assembly:pair(joint_name, kind, frame, opts)
  if type(joint_name) ~= "string" then raise("assembly: pair's joint must be a string, got " .. repr(joint_name)) end
  if type(kind) ~= "string" then raise("assembly: pair's kind must be a string, got " .. repr(kind)) end
  if opts ~= nil and type(opts) ~= "table" then raise("assembly: pair's opts must be a table, got " .. repr(opts)) end
  opts = opts or {}
  local f = frame_arg(frame)
  local ef = nil
  if opts.end_frame ~= nil then ef = frame_arg(opts.end_frame) end

  local ranges = opts.ranges
  local lower, upper, has_lower, has_upper, freedom_count = nil, nil, nil, nil, 0
  if ranges ~= nil then
    freedom_count = list_count(ranges)
    if freedom_count == nil then
      raise("pair: ranges must be a list of {lower, upper} pairs, not " .. repr(ranges))
    end
    local size = math.max(freedom_count, 1)
    lower, upper = ffi.new("double[?]", size), ffi.new("double[?]", size)
    has_lower, has_upper = ffi.new("bool[?]", size), ffi.new("bool[?]", size)
    for i = 1, freedom_count do
      local r = ranges[i]
      if type(r) ~= "table" then
        raise(("pair: ranges[%d] must be a table {lower, upper}, not %s"):format(i, repr(r)))
      end
      local lo, hi = r[1], r[2]
      if lo == nil then
        lower[i - 1], has_lower[i - 1] = 0.0, false
      else
        lower[i - 1], has_lower[i - 1] = number(lo, ("pair: ranges[%d][1]"):format(i)), true
      end
      if hi == nil then
        upper[i - 1], has_upper[i - 1] = 0.0, false
      else
        upper[i - 1], has_upper[i - 1] = number(hi, ("pair: ranges[%d][2]"):format(i)), true
      end
    end
  end

  local pitch_arg = NAN
  if opts.pitch ~= nil then pitch_arg = number(opts.pitch, "pair: pitch") end

  if not lib().cadaclysm_blacksmith_assembly_pair(
    self:_h(), joint_name, kind, f, ef, lower, upper, has_lower, has_upper, freedom_count, pitch_arg
  ) then
    fail("assembly_pair")
  end
end

--- `Assembly:pair` with the kind's own numbers in place of `opts.pitch`, for the coupled
--- pairs: `kind` any name `pair` takes, or "gear" or "rack_and_pinion". `params` is a plain
--- list of numbers: `{pitch}` for a screw, `{pinion_radius}` for a rack and pinion,
--- `{radius_first, radius_second, ratio}` or those plus `{bevel, helical_angle}` (radians)
--- for a gear -- the ratio the second link's rotation over the first's, signed (two meshing
--- external gears turn opposite ways, so theirs is negative) -- and none for any other
--- kind. `frame` and `opts` (`end_frame`, `ranges`) read as in `pair`; `opts.pitch` is not
--- taken here. Raises `BuildError` with the kernel's own text when a rule refuses it (a
--- wrong number of parameters among them); the assembly is then unchanged.
function Assembly:pair_with(joint_name, kind, frame, opts, params)
  if type(joint_name) ~= "string" then raise("assembly: pair_with's joint must be a string, got " .. repr(joint_name)) end
  if type(kind) ~= "string" then raise("assembly: pair_with's kind must be a string, got " .. repr(kind)) end
  if opts ~= nil and type(opts) ~= "table" then raise("assembly: pair_with's opts must be a table, got " .. repr(opts)) end
  opts = opts or {}
  local f = frame_arg(frame)
  local ef = nil
  if opts.end_frame ~= nil then ef = frame_arg(opts.end_frame) end

  local ranges = opts.ranges
  local lower, upper, has_lower, has_upper, freedom_count = nil, nil, nil, nil, 0
  if ranges ~= nil then
    freedom_count = list_count(ranges)
    if freedom_count == nil then
      raise("pair_with: ranges must be a list of {lower, upper} pairs, not " .. repr(ranges))
    end
    local size = math.max(freedom_count, 1)
    lower, upper = ffi.new("double[?]", size), ffi.new("double[?]", size)
    has_lower, has_upper = ffi.new("bool[?]", size), ffi.new("bool[?]", size)
    for i = 1, freedom_count do
      local r = ranges[i]
      if type(r) ~= "table" then
        raise(("pair_with: ranges[%d] must be a table {lower, upper}, not %s"):format(i, repr(r)))
      end
      local lo, hi = r[1], r[2]
      if lo == nil then
        lower[i - 1], has_lower[i - 1] = 0.0, false
      else
        lower[i - 1], has_lower[i - 1] = number(lo, ("pair_with: ranges[%d][1]"):format(i)), true
      end
      if hi == nil then
        upper[i - 1], has_upper[i - 1] = 0.0, false
      else
        upper[i - 1], has_upper[i - 1] = number(hi, ("pair_with: ranges[%d][2]"):format(i)), true
      end
    end
  end

  local param_count = 0
  local param_arr = nil
  if params ~= nil then
    param_count = list_count(params)
    if param_count == nil then raise("pair_with: params must be a list of numbers, not " .. repr(params)) end
    param_arr = ffi.new("double[?]", math.max(param_count, 1))
    for i = 1, param_count do param_arr[i - 1] = number(params[i], ("pair_with: params[%d]"):format(i)) end
  end

  if not lib().cadaclysm_blacksmith_assembly_pair_with(
    self:_h(), joint_name, kind, f, ef, lower, upper, has_lower, has_upper, freedom_count, param_arr, param_count
  ) then
    fail("assembly_pair_with")
  end
end

--- Add a named state to this assembly: `rows` is an array `{{joint, {values}}, ...}`,
--- kept in that order, each setting one joint to its values in that joint's pair's
--- freedom order. Raises `BuildError` with the kernel's own text when a rule refuses
--- it; the assembly is then unchanged.
function Assembly:state(name, rows)
  if type(name) ~= "string" then raise("assembly: state's name must be a string, got " .. repr(name)) end
  local row_count = list_count(rows)
  if row_count == nil then
    raise("state: rows must be a list of {joint, values} rows, not " .. repr(rows))
  end
  -- `joint_names` stays referenced for the whole call below, so the Lua strings
  -- `joint_ptrs` now points into cannot be collected.
  local joint_names = {}
  local joint_ptrs = ffi.new("const char*[?]", math.max(row_count, 1))
  local counts = ffi.new("uint32_t[?]", math.max(row_count, 1))
  local flat = {}
  for i = 1, row_count do
    local row = rows[i]
    if type(row) ~= "table" then
      raise(("state: rows[%d] must be a table {joint, values}, not %s"):format(i, repr(row)))
    end
    local joint_name, values = row[1], row[2]
    if type(joint_name) ~= "string" then
      raise(("state: rows[%d][1] is not a joint name: %s"):format(i, repr(joint_name)))
    end
    local value_count = list_count(values)
    if value_count == nil then
      raise(("state: rows[%d][2] must be a list of numbers, not %s"):format(i, repr(values)))
    end
    joint_names[i] = joint_name
    joint_ptrs[i - 1] = joint_name
    counts[i - 1] = value_count
    for j = 1, value_count do
      flat[#flat + 1] = number(values[j], ("state: rows[%d][2][%d]"):format(i, j))
    end
  end
  local values_arr = ffi.new("double[?]", math.max(#flat, 1))
  for i = 1, #flat do values_arr[i - 1] = flat[i] end
  if not lib().cadaclysm_blacksmith_assembly_state(self:_h(), name, joint_ptrs, counts, values_arr, row_count) then
    fail("assembly_state")
  end
end

--- A joint or state key as the kernel reads it: a string as it is; a list of names
--- escaped (a backslash before every "/" and backslash in a name) and joined by "/".
local function joint_path(key, what)
  if type(key) == "string" then return key end
  local n = list_count(key)
  if n == nil or n == 0 then
    raise(what .. " must be a string or a list of names, not " .. repr(key))
  end
  local parts = {}
  for i = 1, n do
    if type(key[i]) ~= "string" then raise(("%s[%d] is not a name: %s"):format(what, i, repr(key[i]))) end
    parts[i] = (key[i]:gsub("[\\/]", "\\%0"))
  end
  return table.concat(parts, "/")
end

--- This assembly with its mechanism posed, as a new `Assembly`. `values` is the joints'
--- values: an array of rows `{key, value}`, or a table mapping string keys to values;
--- a key is a path of placement names then the joint's name joined by "/" (a "/" or backslash
--- inside a name escaped with a backslash), or a list of the names, which this escapes and
--- joins; a value is a number for a one-freedom joint, else a list in the pair's
--- freedom order (radians, the assembly's units). `state` is a state's path (a string or
--- a list of names), applied first and overridden row by row; `ground` is one of this
--- assembly's own links, held fixed. A sub-assembly no key reaches is shared with this
--- one. Raises `BuildError` with the kernel's own text; this assembly is unchanged either
--- way.
---@param values? table
---@param state? string|string[]
---@param ground? string
---@return Assembly
function Assembly:posed(values, state, ground)
  local rows = {}
  if values ~= nil then
    local count = list_count(values)
    if count ~= nil then
      for i = 1, count do
        local row = values[i]
        if type(row) ~= "table" then
          raise(("posed: values[%d] must be a table {key, value}, not %s"):format(i, repr(row)))
        end
        rows[i] = { row[1], row[2] }
      end
    elseif type(values) == "table" then
      local keys = {}
      for k in pairs(values) do
        if type(k) ~= "string" then raise("posed: a values map takes string keys, not " .. repr(k)) end
        keys[#keys + 1] = k
      end
      table.sort(keys)
      for i, k in ipairs(keys) do rows[i] = { k, values[k] } end
    else
      raise("posed: values must be a list of {key, value} rows or a map, not " .. repr(values))
    end
  end
  if state ~= nil then state = joint_path(state, "posed: state") end
  if ground ~= nil and type(ground) ~= "string" then
    raise("posed: ground must be a string, got " .. repr(ground))
  end
  local row_count = #rows
  local joint_names = {}   -- kept referenced while `joint_ptrs` points into them
  local joint_ptrs = ffi.new("const char*[?]", math.max(row_count, 1))
  local counts = ffi.new("uint32_t[?]", math.max(row_count, 1))
  local flat = {}
  for i = 1, row_count do
    local key, value = rows[i][1], rows[i][2]
    local name = joint_path(key, ("posed: rows[%d][1]"):format(i))
    local list = value
    if type(value) == "number" then list = { value } end
    local value_count = list_count(list)
    if value_count == nil then
      raise(("posed: rows[%d][2] must be a number or a list of numbers, not %s"):format(i, repr(value)))
    end
    joint_names[i] = name
    joint_ptrs[i - 1] = name
    counts[i - 1] = value_count
    for j = 1, value_count do
      flat[#flat + 1] = number(list[j], ("posed: rows[%d][2][%d]"):format(i, j))
    end
  end
  local values_arr = ffi.new("double[?]", math.max(#flat, 1))
  for i = 1, #flat do values_arr[i - 1] = flat[i] end
  local h = lib().cadaclysm_blacksmith_assembly_posed(
    self:_h(), joint_ptrs, counts, values_arr, row_count, state, ground)
  if h == nil then fail("assembly_posed") end
  return setmetatable({ _handle = ffi.gc(h, free_assembly) }, Assembly)
end

--- Add a named motion sequence to this assembly: `segments` is an array
--- `{{state, t, interpolation}, ...}`, the state's name, its parameter (non-decreasing)
--- and one of "undefined", "discontinuous", "synchronous", "linear". The sequence is
--- closed unless the last segment is "discontinuous". `seconds` (default false) says
--- the parameter is in seconds, written as a time unit. Raises `BuildError` with the
--- kernel's own text when a rule refuses it; the assembly is then unchanged.
function Assembly:sequence(name, segments, seconds)
  if type(name) ~= "string" then raise("assembly: sequence's name must be a string, got " .. repr(name)) end
  local count = list_count(segments)
  if count == nil then
    raise("sequence: segments must be a list of {state, t, interpolation}, not " .. repr(segments))
  end
  local states_ptr = ffi.new("const char*[?]", math.max(count, 1))
  local interp_ptr = ffi.new("const char*[?]", math.max(count, 1))
  local ts = ffi.new("double[?]", math.max(count, 1))
  -- The Lua strings stay referenced for the whole call below.
  local keep = {}
  for i = 1, count do
    local seg = segments[i]
    if type(seg) ~= "table" then
      raise(("sequence: segments[%d] must be a table {state, t, interpolation}, not %s"):format(i, repr(seg)))
    end
    local state, t, word = seg[1], seg[2], seg[3]
    if type(state) ~= "string" then
      raise(("sequence: segments[%d][1] is not a state name: %s"):format(i, repr(state)))
    end
    if type(word) ~= "string" then
      raise(("sequence: segments[%d][3] is not an interpolation word: %s"):format(i, repr(word)))
    end
    keep[#keep + 1] = state
    keep[#keep + 1] = word
    states_ptr[i - 1] = state
    interp_ptr[i - 1] = word
    ts[i - 1] = number(t, ("sequence: segments[%d][2]"):format(i))
  end
  if not lib().cadaclysm_blacksmith_assembly_sequence(
    self:_h(), name, states_ptr, ts, interp_ptr, count, seconds and true or false
  ) then
    fail("assembly_sequence")
  end
end

--- Declare this assembly's base link. Raises `BuildError` with the kernel's own text
--- when a rule refuses it; the assembly is then unchanged.
function Assembly:base(link_name)
  if type(link_name) ~= "string" then raise("assembly: base's link must be a string, got " .. repr(link_name)) end
  if not lib().cadaclysm_blacksmith_assembly_base(self:_h(), link_name) then fail("assembly_base") end
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

-- ---- machining -----------------------------------------------------------------------

local function free_tool(p) lib().cadaclysm_blacksmith_tool_free(p) end
local function free_stock(p) lib().cadaclysm_blacksmith_stock_free(p) end
local function free_job(p) lib().cadaclysm_blacksmith_job_free(p) end

local function or_nan(v)
  if v == nil then return 0 / 0 end
  return v
end

--- A cutter: Grbl tool `number` (1 to 255, the T word), `diameter` and `flute_length` in
--- mm, `feed` and `plunge` in mm/min, `rpm` its spindle speed, ramping into its cuts at
--- `ramp_angle` degrees. Immutable; a `Job` keeps its own copy, so a tool going out of
--- scope after it is used changes nothing there.
---@class Tool
local Tool = {}
class(Tool)
M.Tool = Tool

local function new_tool(handle, what)
  checked(handle, what or "tool")
  return setmetatable({ _handle = ffi.gc(handle, free_tool) }, Tool)
end

local function tool_handle(t, what)
  if type(t) ~= "table" or getmetatable(t) ~= Tool then raise((what or "tool") .. ": expected a Tool, got " .. repr(t)) end
  return t._handle
end

local function tool_number(n)
  n = math.floor(number(n, "number"))
  if n < 0 then n = 0 end
  return n
end

-- `made` at the library's own default ramp angle (3 degrees), turned to `ramp_angle` when
-- that differs -- the unramped handle freed at once, not left to the collector.
local function ramped(made, ramp_angle, what)
  local t = new_tool(made, what)
  if ramp_angle == 3.0 then return t end
  -- checked before the free, so a refusal still reads its own last_error
  local turned = new_tool(lib().cadaclysm_blacksmith_tool_with_ramp_angle(t._handle, ramp_angle), "tool_with_ramp_angle")
  free_tool(ffi.gc(t._handle, nil))
  t._handle = nil
  return turned
end

--- A flat end mill. `ramp_angle` defaults to 3.0. Raises `BuildError` for a `number`
--- outside 1..255, a size, feed or speed not positive and finite, or a `ramp_angle`
--- outside (0, 90].
function Tool.flat(number_, diameter, flute_length, feed, plunge, rpm, ramp_angle)
  if ramp_angle == nil then ramp_angle = 3.0 end
  local made = lib().cadaclysm_blacksmith_tool_flat(tool_number(number_), diameter, flute_length, feed, plunge, rpm)
  return ramped(made, ramp_angle, "tool_flat")
end

--- A ball end mill, as `Tool.flat` but its tip a half sphere of the diameter; in 2.5D it
--- cuts where a flat does, bottom being the tip.
function Tool.ball(number_, diameter, flute_length, feed, plunge, rpm, ramp_angle)
  if ramp_angle == nil then ramp_angle = 3.0 end
  local made = lib().cadaclysm_blacksmith_tool_ball(tool_number(number_), diameter, flute_length, feed, plunge, rpm)
  return ramped(made, ramp_angle, "tool_ball")
end

--- A drill, plunging at `feed`. A job takes it for `Job:drill` (and `Job:machine`'s
--- `drills`) only.
function Tool.drill(number_, diameter, flute_length, feed, rpm)
  return new_tool(lib().cadaclysm_blacksmith_tool_drill(tool_number(number_), diameter, flute_length, feed, rpm), "tool_drill")
end

--- The block of material a job cuts, an axis-aligned box. Immutable; a `Job` keeps its
--- own copy.
---@class Stock
local Stock = {}
class(Stock)
M.Stock = Stock

local function new_stock(handle, what)
  checked(handle, what or "stock")
  return setmetatable({ _handle = ffi.gc(handle, free_stock) }, Stock)
end

local function stock_handle(s, what)
  if type(s) ~= "table" or getmetatable(s) ~= Stock then raise((what or "stock") .. ": expected a Stock, got " .. repr(s)) end
  return s._handle
end

--- The box from `min` (x, y, z) to `max`. Raises `BuildError` unless every min is below
--- its max and all six are finite.
function Stock.box(min, max)
  local x0, y0, z0 = triple(min, "min")
  local x1, y1, z1 = triple(max, "max")
  return new_stock(lib().cadaclysm_blacksmith_stock_box(x0, y0, z0, x1, y1, z1), "stock_box")
end

--- `solid`'s bounds grown by `margin` in -X, +X, -Y, +Y and +Z; the bottom stays at the
--- solid's lowest Z. `margin` defaults to 0.0. Raises `BuildError` for a margin negative or
--- not finite.
function Stock.around(solid, margin)
  if margin == nil then margin = 0.0 end
  return new_stock(lib().cadaclysm_blacksmith_stock_around(solid_handle(solid, "stock_around"), margin), "stock_around")
end

--- One file a `Job` wrote: a Grbl program (`tool` its T number, `name` "<job
--- name>-T<n>", or "<job name>-<k>-T<n>" for a repeated tool) from `Job:gcode`, or one
--- of `Job:write_camotics`'s files (`tool` 0 for the simulation copies and the project).
--- Copied out; read-only.
---@class Program
---@field tool integer
---@field name string
---@field text string
local Program = {}
class(Program)
M.Program = Program

Program.__tostring = function(self)
  return ("Program(tool=%d, name=%s, %d characters)"):format(self.tool, self.name, #self.text)
end

--- One operation of a `Job`, read back by `Job:operations`: `kind` ("face", "contour",
--- "pocket" or "drill"), `tool` (its Grbl T number) and `params`, an unordered table of
--- the operation's own arguments, typed by name as the Python SDK does: `side` is "outside",
--- "inside" or "on" (a value that is none of 0, 1, 2 stays a number); `climb` and `open` are
--- booleans; `points` is an integer count; a none `peck` is absent (reads `nil`); every
--- other value is a number. Copied out; read-only.
---@class Operation
---@field kind string
---@field tool integer
---@field params table<string, number|string|boolean>
local Operation = {}
class(Operation)
M.Operation = Operation

Operation.__tostring = function(self)
  local parts = {}
  for k, v in pairs(self.params) do parts[#parts + 1] = k .. ": " .. tostring(v) end
  table.sort(parts)
  return ("Operation(kind=%s, tool=%d, params={%s})"):format(self.kind, self.tool, table.concat(parts, ", "))
end

--- One thing `Job:machine` left uncut: `kind` ("corner", "hole", "slope", "undercut" or
--- "too_deep"), `at` ({x, y, z}), `size` (its meaning per `kind`), `reason` (one sentence
--- naming the tool involved), and `region` (its XY area, as a table of `Profile`).
--- Copied out; read-only.
---@class ReportItem
---@field kind string
---@field at number[]
---@field size number
---@field reason string
---@field region Profile[]
local ReportItem = {}
class(ReportItem)
M.ReportItem = ReportItem

ReportItem.__tostring = function(self)
  return ("ReportItem(kind=%s, at=(%g, %g, %g), size=%g, reason=%s, region=%d profile(s))"):format(
    self.kind, self.at[1], self.at[2], self.at[3], self.size, self.reason, #self.region)
end

--- What `Job:machine` could not make: a read-only sequence of `ReportItem`, in order,
--- read eagerly when `machine` returns (`#report`, `ipairs(report)`, `report[i]`); `.text`
--- is the kernel's own report -- one line per item, or "nothing left uncut" -- and is
--- also `tostring(report)`.
---@class Report
---@field text string
local Report = {}
class(Report)
M.Report = Report

Report.__tostring = function(self) return self.text end

local function report_item_of(raw, i)
  local at = ffi.new("double[3]")
  if not lib().cadaclysm_blacksmith_report_at(raw, i, at) then fail("report_at") end
  local region = profile_list(lib().cadaclysm_blacksmith_report_region(raw, i), "report_region")
  return setmetatable({
    kind = text(lib().cadaclysm_blacksmith_report_kind(raw, i)),
    at = { tonumber(at[0]), tonumber(at[1]), tonumber(at[2]) },
    size = tonumber(lib().cadaclysm_blacksmith_report_size(raw, i)),
    reason = text(lib().cadaclysm_blacksmith_report_reason(raw, i)),
    region = region,
  }, ReportItem)
end

local function report_of(raw)
  local n = lib().cadaclysm_blacksmith_report_count(raw)
  local items = {}
  for i = 0, n - 1 do items[#items + 1] = report_item_of(raw, i) end
  items.text = text(lib().cadaclysm_blacksmith_report_text(raw))
  return setmetatable(items, Report)
end

local PARAM_SIDES = { [0] = "outside", [1] = "inside", [2] = "on" }

-- One `operations_param_value`, typed as the spec picks by its name: `side` 0/1/2 to
-- "outside"/"inside"/"on" (any other value stays a number), `climb`/`open` to a boolean
-- (non-zero true), `points` to an integer; every other value stays a number.
local function operation_param(name, value)
  if name == "side" then return PARAM_SIDES[value] or value end
  if name == "climb" or name == "open" then return value ~= 0 end
  if name == "points" then return value < 0 and math.ceil(value) or math.floor(value) end
  return value
end

local function operation_of(raw, i)
  local kind = text(lib().cadaclysm_blacksmith_operations_kind(raw, i))
  local op_tool = tonumber(lib().cadaclysm_blacksmith_operations_tool(raw, i))
  local pc = lib().cadaclysm_blacksmith_operations_param_count(raw, i)
  local params = {}
  for k = 0, pc - 1 do
    local name = text(lib().cadaclysm_blacksmith_operations_param_name(raw, i, k))
    local value = lib().cadaclysm_blacksmith_operations_param_value(raw, i, k)
    if value == value then params[name] = operation_param(name, tonumber(value)) end -- a NaN (peck: none) stays absent, read back as nil
  end
  return setmetatable({ kind = kind, tool = op_tool, params = params }, Operation)
end

-- The programs of a list the library handed back (nil: raise), each copied out, the
-- list freed.
local function programs_of(raw, what)
  if raw == nil then fail(what) end
  local ok, result = pcall(function()
    local n = lib().cadaclysm_blacksmith_programs_count(raw)
    local out = {}
    for i = 0, n - 1 do
      out[#out + 1] = setmetatable({
        tool = tonumber(lib().cadaclysm_blacksmith_programs_tool(raw, i)),
        name = text(lib().cadaclysm_blacksmith_programs_name(raw, i)),
        text = text(lib().cadaclysm_blacksmith_programs_text(raw, i)),
      }, Program)
    end
    return out
  end)
  lib().cadaclysm_blacksmith_programs_free(raw)
  if not ok then error(result, 0) end
  return result
end

local JOB_SIDES = { outside = 0, inside = 1, on = 2 }

-- `path`'s directory (nil for none) and file stem (its name without its last extension).
local function split_path(path)
  path = tostring(path):gsub("\\", "/")
  local dir, base = path:match("^(.*)/([^/]*)$")
  if not dir then dir, base = nil, path end
  local stem = base:match("^(.*)%.[^.]+$") or base
  if stem == "" then stem = base end
  return dir, stem
end

local mkdir_windows = package.config:sub(1, 1) == "\\"

-- One `mkdir` of a single path, via the C runtime -- no shell, so a name with a quote or a
-- space needs no escaping. `nil` if the runtime doesn't offer it (falls back to a shell).
local mkdir_one
do
  local ok = pcall(function()
    if mkdir_windows then
      ffi.cdef[[int _mkdir(const char *path);]]
      mkdir_one = function(path) return ffi.C._mkdir(path) end
    else
      ffi.cdef[[int mkdir(const char *path, unsigned int mode);]]
      mkdir_one = function(path) return ffi.C.mkdir(path, 0x1FF) end
    end
  end)
  if not ok then mkdir_one = nil end
end

-- Creates dir and every missing ancestor, one path component at a time. Best-effort: an
-- existing directory, or one a component can't make, is left for the caller's own write to
-- fail against.
local function mkdir_p(dir)
  if not dir or dir == "" then return end
  local norm = tostring(dir):gsub("\\", "/")
  local prefix = norm:match("^(/)") or ""
  local acc = prefix
  for part in norm:gmatch("[^/]+") do
    if acc == "" or acc:sub(-1) == "/" then
      acc = acc .. part
    else
      acc = acc .. "/" .. part
    end
    if not acc:match("^%a:$") then -- a bare Windows drive letter always exists
      local native = mkdir_windows and acc:gsub("/", "\\") or acc
      if mkdir_one then
        mkdir_one(native)
      elseif mkdir_windows then
        if not native:find('"') then os.execute(('mkdir "%s" 2>nul'):format(native)) end
      else
        os.execute(("mkdir -p '%s'"):format(native:gsub("'", "'\\''")))
      end
    end
  end
end

--- A machining job on a `Stock`: operations kept in the order they are added, written as
--- one Grbl 1.1 program per run of operations sharing a tool. Mutable -- each operation is
--- added in place, and a refused one leaves the job as it was. `safe_z` is the absolute Z
--- of rapids between operations and at a program's start and end, above the stock's top;
--- `clearance` (default 1.0) is how far above an operation's top it enters and leaves its
--- passes; `tolerance` (default 0.01) fits free-form sides and offsets; `name` (default
--- "job") names the programs ("<name>-T<n>"); `spindle_dwell` (default 2.0) is how long
--- every program waits after starting the spindle; `resolution` (default 0.1) is the
--- CAMotics project's voxel size in mm. Raises `BuildError` for a `safe_z` not above the
--- stock's top, a `name` with a control character in it, or a setting the job refuses.
--- `Job.new(stock, safe_z, ...)` or `Job(stock, safe_z, ...)`.
---@class Job
local Job = {}
class(Job)
callable(Job)
M.Job = Job

-- A NUL truncates silently going through the native call, so a name or a CAMotics stem with
-- one in it is refused here, in the kernel's own words for a name with a control character
-- in it, as the Python SDK does.
local NUL_NAME_ERROR = "job: a name must be non-empty and without brackets, slashes, quotes, control characters, or : * ? < > |"

local function reject_nul(s)
  if tostring(s):find("\0", 1, true) then raise(NUL_NAME_ERROR) end
end

function Job.new(stock, safe_z, clearance, tolerance, name, spindle_dwell, resolution)
  if clearance == nil then clearance = 1.0 end
  if tolerance == nil then tolerance = 0.01 end
  if name == nil then name = "job" end
  if spindle_dwell == nil then spindle_dwell = 2.0 end
  if resolution == nil then resolution = 0.1 end
  reject_nul(name)
  local sh = stock_handle(stock, "job_new")
  local raw = checked(lib().cadaclysm_blacksmith_job_new(sh, safe_z), "job_new")
  local h = ffi.gc(raw, free_job)
  if clearance ~= 1.0 and not lib().cadaclysm_blacksmith_job_set_clearance(h, clearance) then fail("job_set_clearance") end
  if tolerance ~= 0.01 and not lib().cadaclysm_blacksmith_job_set_tolerance(h, tolerance) then fail("job_set_tolerance") end
  if spindle_dwell ~= 2.0 and not lib().cadaclysm_blacksmith_job_set_spindle_dwell(h, spindle_dwell) then
    fail("job_set_spindle_dwell")
  end
  if resolution ~= 0.1 and not lib().cadaclysm_blacksmith_job_set_resolution(h, resolution) then fail("job_set_resolution") end
  if name ~= "job" and not lib().cadaclysm_blacksmith_job_set_name(h, tostring(name)) then fail("job_set_name") end
  return setmetatable({ _ptr = h }, Job)
end

function Job:_h()
  local h = rawget(self, "_ptr")
  if h == nil then raise("job: closed") end
  return h
end

--- Free the job. Idempotent. The lists it wrote (`operations`, `gcode`, `machine`'s
--- `Report`) are copies and outlive it.
function Job:close()
  local h = rawget(self, "_ptr")
  if h ~= nil then
    self._ptr = nil
    ffi.gc(h, nil)
    lib().cadaclysm_blacksmith_job_free(h)
  end
end

--- Face the stock's top down to `z`, in zigzag rows along X `stepover` apart and passes
--- at most `stepdown` deep, with `tool`. Raises `BuildError` for a drill, a `z` above the
--- stock's top, a stepover past the tool's diameter, ...
function Job:face(tool, z, stepover, stepdown)
  local h = self:_h()
  if not lib().cadaclysm_blacksmith_job_face(h, tool_handle(tool, "face"), z, stepover, stepdown) then
    fail("job_face")
  end
end

--- Cut along `profile` from `top` to `bottom` in passes at most `stepdown` deep, with
--- `tool`: `side` "outside" the profile (default), "inside" it, or "on" its line; `climb`
--- (default true) for climb milling, else conventional; `open` (default false) to cut the
--- outline as an open chain (only "on" its line, and with no holes). Raises `BuildError`
--- for any other `side`, without asking the library, and for what the job refuses.
function Job:contour(tool, profile, top, bottom, side, stepdown, climb, open)
  if side == nil then side = "outside" end
  if stepdown == nil then stepdown = 1.0 end
  if climb == nil then climb = true end
  if open == nil then open = false end
  local code = JOB_SIDES[side]
  if code == nil then raise("side must be 'outside', 'inside' or 'on'") end
  local h = self:_h()
  local th, ph = tool_handle(tool, "contour"), profile_handle(profile, "contour")
  if not lib().cadaclysm_blacksmith_job_contour(h, th, ph, top, bottom, code, stepdown, climb and true or false,
      open and true or false) then
    fail("job_contour")
  end
end

--- Clear `profile` -- its holes left standing as islands -- from `top` to `bottom`, in
--- rings `stepover` apart (at most the tool's radius) and passes at most `stepdown` deep,
--- with `tool`. Raises `BuildError` for what the job refuses; a pocket too small for the
--- tool is refused by `gcode`, naming the operation.
function Job:pocket(tool, profile, top, bottom, stepover, stepdown)
  local h = self:_h()
  local th, ph = tool_handle(tool, "pocket"), profile_handle(profile, "pocket")
  if not lib().cadaclysm_blacksmith_job_pocket(h, th, ph, top, bottom, stepover, stepdown) then fail("job_pocket") end
end

--- Drill a hole at each (x, y) of `points` from `top` to `bottom`, with `tool`, pecking
--- `peck` deep at a time (retracting between pecks), or straight to depth for `nil`
--- (default). Raises `BuildError` for what the job refuses (a tool that is not a drill, no
--- points, ...).
function Job:drill(tool, points, top, bottom, peck)
  local h = self:_h()
  local th = tool_handle(tool, "drill")
  local xy, n = pairs_arg(points, "drill")
  if not lib().cadaclysm_blacksmith_job_drill(h, th, xy, n, top, bottom, or_nan(peck)) then fail("job_drill") end
end

--- Recognise `part` and append the operations that make it: faced, contoured and pocketed
--- with `end_mill`, its holes drilled with whichever of `drills` fits each -- a tool per
--- required diameter; `drills` may be one `Tool` or a table of them (default none).
--- `stepover` and `stepdown` default to the kernel's own (nil asks for that); `skin` (at
--- least 0, default 0.3) is how far above the part's lowest point the outline stops, so
--- the part stays attached to the stock -- 0 cuts through; `peck` defaults to none (a
--- drill straight to depth). Returns a `Report` of what could not be cut. Raises
--- `BuildError` for what the kernel refuses (a drill as `end_mill`, ...); the job changes
--- only on success -- a refusal leaves it exactly as it was.
function Job:machine(part, end_mill, drills, stepover, stepdown, skin, peck)
  if drills == nil then drills = {} end
  if skin == nil then skin = 0.3 end
  local list = drills
  if type(drills) == "table" and getmetatable(drills) == Tool then list = { drills } end
  local h = self:_h()
  local ph = solid_handle(part, "machine")
  local eh = tool_handle(end_mill, "machine")
  local n = #list
  local handles = ffi.new("const struct CadaclysmBlacksmithTool *[?]", math.max(n, 1))
  for i = 1, n do handles[i - 1] = tool_handle(list[i], "machine") end
  local raw = lib().cadaclysm_blacksmith_job_machine(h, ph, eh, handles, n, or_nan(stepover), or_nan(stepdown), skin,
    or_nan(peck))
  if raw == nil then fail("job_machine") end
  local ok, result = pcall(report_of, raw)
  lib().cadaclysm_blacksmith_report_free(raw)
  if not ok then error(result, 0) end
  return result
end

--- Every operation added to this job so far, in order -- whether added by
--- `face`/`contour`/`pocket`/`drill` or by `machine`.
function Job:operations()
  local h = self:_h()
  local raw = lib().cadaclysm_blacksmith_job_operations(h)
  if raw == nil then fail("job_operations") end
  local ok, result = pcall(function()
    local n = lib().cadaclysm_blacksmith_operations_count(raw)
    local out = {}
    for i = 0, n - 1 do out[#out + 1] = operation_of(raw, i) end
    return out
  end)
  lib().cadaclysm_blacksmith_operations_free(raw)
  if not ok then error(result, 0) end
  return result
end

--- The job as Grbl 1.1 programs, one per run of consecutive operations sharing a tool (T1,
--- T2, T1 gives three), each named "<name>-T<n>" (or "<name>-<k>-T<n>" for run `k` of a
--- repeated tool); an empty table for a job with no operations. Raises `BuildError` for an
--- operation whose geometry the tool cannot cut (named by its index and kind).
function Job:gcode()
  return programs_of(lib().cadaclysm_blacksmith_job_gcode(self:_h()), "job_gcode")
end

--- A CAMotics project at `path` and its files beside it, named after the project's file
--- stem ("out/part.camotics" writes "out/part-T1.nc"), not the job's name: each program, a
--- simulation copy of it (".sim.nc", which the project lists), and the project last.
--- Creates the directory. Returns the paths written, the project last, written here (not
--- by the library) byte for byte. Raises `BuildError` for a path with no file stem, what
--- `gcode` refuses, or a file that cannot be written.
function Job:write_camotics(path)
  local h = self:_h()
  local dir, stem = split_path(path)
  reject_nul(stem)
  local files = programs_of(lib().cadaclysm_blacksmith_job_camotics(h, stem), "job_camotics")
  mkdir_p(dir)
  local written = {}
  for i, f in ipairs(files) do
    local at = tostring(path)
    if i ~= #files then at = (dir and (dir .. "/") or "") .. f.name end
    local out, err = io.open(at, "wb")
    if not out then raise(("job_camotics: %s: %s"):format(tostring(path), tostring(err))) end
    out:write(f.text)
    out:close()
    written[#written + 1] = at
  end
  return written
end


return M
