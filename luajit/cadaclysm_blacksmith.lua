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

**Errors.** Every step raises a `BuildError` (a table with a `message`, the `ids`
a `Sketch` refusal names -- empty for every other -- and a `__tostring`) at once,
with the library's own text. The text is per OS thread,
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
M.__version__ = "0.13.1"

--- What the ABI returns for "no such face" and uses for "the whole solid".
M.NONE = 0xFFFFFFFF

--- The units `step`/`write_step` write in, by name.
M.UNITS = { m = 0, mm = 1, ["in"] = 2 }

local NONE = M.NONE
local UNITS = M.UNITS

-- ---- errors -------------------------------------------------------------------

--- What the library refused, in its own words (`cadaclysm_blacksmith_last_error`):
--- a table `{ message = ..., ids = {...} }` whose `tostring` is the message. `ids` is
--- the sketch ids a `Sketch` refusal names -- the constraints a new constraint, value
--- or reference conflicts with, or the entities still using a point -- and an empty
--- table for every other refusal.
---@class BuildError
---@field message string
---@field ids integer[]
local BuildError = {}
BuildError.__index = BuildError
BuildError.__tostring = function(e) return e.message end
M.BuildError = BuildError

local function raise(message)
  error(setmetatable({ message = message, ids = {} }, BuildError), 2)
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
local C

-- In a block of its own (the main chunk's 200 live locals): only `bind` leaves it.
local bind
do
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
  "cadaclysm_blacksmith_health", "cadaclysm_blacksmith_health_free", "cadaclysm_blacksmith_health_summary", "cadaclysm_blacksmith_health_free_edges", "cadaclysm_blacksmith_health_wires", "cadaclysm_blacksmith_health_small", "cadaclysm_blacksmith_health_crack_edges",
  "cadaclysm_blacksmith_healed", "cadaclysm_blacksmith_heal_body", "cadaclysm_blacksmith_heal_free", "cadaclysm_blacksmith_heal_summary", "cadaclysm_blacksmith_heal_fixes", "cadaclysm_blacksmith_heal_refused", "cadaclysm_blacksmith_edge_tolerance",
  "cadaclysm_blacksmith_effective_tolerance", "cadaclysm_blacksmith_solid_tolerances",
  "cadaclysm_blacksmith_solid_with_tolerances", "cadaclysm_blacksmith_vertex_tolerance",
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
  "cadaclysm_blacksmith_oriented_box", "cadaclysm_blacksmith_edge_length", "cadaclysm_blacksmith_profile_length",
  "cadaclysm_blacksmith_classifier_new", "cadaclysm_blacksmith_classifier_contains", "cadaclysm_blacksmith_classifier_free",
  "cadaclysm_blacksmith_contains", "cadaclysm_blacksmith_closest",
  "cadaclysm_blacksmith_edge_point_at_length", "cadaclysm_blacksmith_edge_divide_by_count",
  "cadaclysm_blacksmith_edge_divide_by_length", "cadaclysm_blacksmith_profile_point_at_length",
  "cadaclysm_blacksmith_profile_divide_by_count", "cadaclysm_blacksmith_profile_divide_by_length",
  "cadaclysm_blacksmith_samples_count", "cadaclysm_blacksmith_samples_at", "cadaclysm_blacksmith_samples_free",
  "cadaclysm_blacksmith_rtree_new", "cadaclysm_blacksmith_rtree_from_boxes", "cadaclysm_blacksmith_rtree_from_points", "cadaclysm_blacksmith_rtree_insert",
  "cadaclysm_blacksmith_rtree_insert_point", "cadaclysm_blacksmith_rtree_remove", "cadaclysm_blacksmith_rtree_count", "cadaclysm_blacksmith_rtree_bounds",
  "cadaclysm_blacksmith_rtree_free", "cadaclysm_blacksmith_rtree_search", "cadaclysm_blacksmith_rtree_within", "cadaclysm_blacksmith_rtree_nearest",
  "cadaclysm_blacksmith_rtree_hits_count", "cadaclysm_blacksmith_rtree_hits_at", "cadaclysm_blacksmith_rtree_hits_free", "cadaclysm_blacksmith_rtree_overlaps",
  "cadaclysm_blacksmith_rtree_self_overlaps", "cadaclysm_blacksmith_rtree_pairs_count", "cadaclysm_blacksmith_rtree_pairs_at", "cadaclysm_blacksmith_rtree_pairs_free",
  "cadaclysm_blacksmith_interpolator_new", "cadaclysm_blacksmith_interpolator_count", "cadaclysm_blacksmith_interpolator_dimension",
  "cadaclysm_blacksmith_interpolator_cyclic", "cadaclysm_blacksmith_interpolator_at", "cadaclysm_blacksmith_interpolator_sample",
  "cadaclysm_blacksmith_interpolator_free", "cadaclysm_blacksmith_profile_circumscribed_polygon",
  "cadaclysm_blacksmith_merge", "cadaclysm_blacksmith_regions", "cadaclysm_blacksmith_regions_count", "cadaclysm_blacksmith_regions_at",
  "cadaclysm_blacksmith_regions_side_at", "cadaclysm_blacksmith_regions_free", "cadaclysm_blacksmith_region_solid",
  "cadaclysm_blacksmith_rtree_from_triangles", "cadaclysm_blacksmith_rtree_ray", "cadaclysm_blacksmith_solid_face_tree",
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
  "cadaclysm_blacksmith_3dm_bytes", "cadaclysm_blacksmith_3dm", "cadaclysm_blacksmith_assembly_3dm_bytes",
  "cadaclysm_blacksmith_assembly_3dm", "cadaclysm_blacksmith_bytes_free",
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
  "cadaclysm_blacksmith_with_material", "cadaclysm_blacksmith_solid_material", "cadaclysm_blacksmith_styled",
  "cadaclysm_blacksmith_solid_style_location", "cadaclysm_blacksmith_solid_style_identification",
  "cadaclysm_blacksmith_assembly_new", "cadaclysm_blacksmith_assembly_free", "cadaclysm_blacksmith_assembly_name",
  "cadaclysm_blacksmith_assembly_place_solid", "cadaclysm_blacksmith_assembly_place_assembly",
  "cadaclysm_blacksmith_assembly_step", "cadaclysm_blacksmith_assembly_link", "cadaclysm_blacksmith_assembly_joint",
  "cadaclysm_blacksmith_assembly_pair", "cadaclysm_blacksmith_assembly_pair_with",
  "cadaclysm_blacksmith_assembly_state", "cadaclysm_blacksmith_assembly_posed",
  "cadaclysm_blacksmith_assembly_sequence",
  "cadaclysm_blacksmith_assembly_base",
  "cadaclysm_blacksmith_assembly_part_count", "cadaclysm_blacksmith_assembly_part_path",
  "cadaclysm_blacksmith_assembly_swept_clash",
  "cadaclysm_blacksmith_pair_freedom_count",
  "cadaclysm_blacksmith_solid_bounds_box", "cadaclysm_blacksmith_box_moved", "cadaclysm_blacksmith_box_overlaps",
  "cadaclysm_blacksmith_boxes_apart", "cadaclysm_blacksmith_collider_new", "cadaclysm_blacksmith_collider_free",
  "cadaclysm_blacksmith_collider_group_count", "cadaclysm_blacksmith_collider_stats", "cadaclysm_blacksmith_collider_check",
  "cadaclysm_blacksmith_subd_cuboid", "cadaclysm_blacksmith_subd_cylinder", "cadaclysm_blacksmith_subd_sphere", "cadaclysm_blacksmith_subd_torus", "cadaclysm_blacksmith_subd_from_parts", "cadaclysm_blacksmith_subd_parts",
  "cadaclysm_blacksmith_subd_free", "cadaclysm_blacksmith_subd_transform", "cadaclysm_blacksmith_subd_set_crease", "cadaclysm_blacksmith_subd_set_pin", "cadaclysm_blacksmith_subd_extrude", "cadaclysm_blacksmith_subd_inset", "cadaclysm_blacksmith_subd_subdivide", "cadaclysm_blacksmith_subd_insert_loop",
  "cadaclysm_blacksmith_subd_mirror_on", "cadaclysm_blacksmith_subd_mirror_off", "cadaclysm_blacksmith_subd_full", "cadaclysm_blacksmith_subd_edge_loop", "cadaclysm_blacksmith_subd_smooth_mesh", "cadaclysm_blacksmith_subd_pick", "cadaclysm_blacksmith_subd_to_solid",
  "cadaclysm_blacksmith_collisions_free", "cadaclysm_blacksmith_collisions_count", "cadaclysm_blacksmith_collisions_hit",
  "cadaclysm_blacksmith_collisions_solid",
  "cadaclysm_blacksmith_collider_clash", "cadaclysm_blacksmith_clash", "cadaclysm_blacksmith_clashes_count",
  "cadaclysm_blacksmith_clashes_at", "cadaclysm_blacksmith_clashes_solid", "cadaclysm_blacksmith_clashes_intersect",
  "cadaclysm_blacksmith_clashes_free",
  "cadaclysm_blacksmith_collider_swept_clash", "cadaclysm_blacksmith_swept_clash", "cadaclysm_blacksmith_swept_clashes_count",
  "cadaclysm_blacksmith_swept_clashes_at", "cadaclysm_blacksmith_swept_clashes_interval",
  "cadaclysm_blacksmith_swept_clashes_firsts", "cadaclysm_blacksmith_swept_clashes_free",
  "cadaclysm_blacksmith_thickness_gauge_new", "cadaclysm_blacksmith_thickness_gauge_free", "cadaclysm_blacksmith_thickness_gauge_body_count", "cadaclysm_blacksmith_thickness_gauge_tolerance", "cadaclysm_blacksmith_thickness_gauge_mesh", "cadaclysm_blacksmith_thickness_gauge_measure", "cadaclysm_blacksmith_thickness_gauge_at", "cadaclysm_blacksmith_thickness_gauge_face", "cadaclysm_blacksmith_thicknesses_free", "cadaclysm_blacksmith_thicknesses_count", "cadaclysm_blacksmith_thicknesses_at", "cadaclysm_blacksmith_mesh_thickness", "cadaclysm_blacksmith_mesh_thicknesses_free", "cadaclysm_blacksmith_mesh_thicknesses_count", "cadaclysm_blacksmith_mesh_thicknesses_at",
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
  "cadaclysm_blacksmith_job_machine", "cadaclysm_blacksmith_job_machine_with",
  "cadaclysm_blacksmith_report_top", "cadaclysm_blacksmith_report_bottom", "cadaclysm_blacksmith_report_count", "cadaclysm_blacksmith_report_kind",
  "cadaclysm_blacksmith_report_at", "cadaclysm_blacksmith_report_size", "cadaclysm_blacksmith_report_reason",
  "cadaclysm_blacksmith_report_region", "cadaclysm_blacksmith_report_text", "cadaclysm_blacksmith_report_free",
  "cadaclysm_blacksmith_job_operations", "cadaclysm_blacksmith_operations_count", "cadaclysm_blacksmith_operations_kind",
  "cadaclysm_blacksmith_operations_tool", "cadaclysm_blacksmith_operations_param_count",
  "cadaclysm_blacksmith_operations_param_name", "cadaclysm_blacksmith_operations_param_value",
  "cadaclysm_blacksmith_operations_free",
  "cadaclysm_blacksmith_sketch_new", "cadaclysm_blacksmith_sketch_free", "cadaclysm_blacksmith_sketch_from_profile",
  "cadaclysm_blacksmith_sketch_add_point", "cadaclysm_blacksmith_sketch_add_line", "cadaclysm_blacksmith_sketch_add_circle",
  "cadaclysm_blacksmith_sketch_add_arc", "cadaclysm_blacksmith_sketch_add_bezier", "cadaclysm_blacksmith_sketch_add_conic",
  "cadaclysm_blacksmith_sketch_add_nurbs", "cadaclysm_blacksmith_sketch_add_rect", "cadaclysm_blacksmith_sketch_kind",
  "cadaclysm_blacksmith_sketch_entities", "cadaclysm_blacksmith_sketch_point", "cadaclysm_blacksmith_sketch_set_point",
  "cadaclysm_blacksmith_sketch_radius", "cadaclysm_blacksmith_sketch_set_radius", "cadaclysm_blacksmith_sketch_centre",
  "cadaclysm_blacksmith_sketch_ends", "cadaclysm_blacksmith_sketch_set_construction",
  "cadaclysm_blacksmith_sketch_is_construction", "cadaclysm_blacksmith_sketch_is_reference",
  "cadaclysm_blacksmith_sketch_remove_entity", "cadaclysm_blacksmith_sketch_reference",
  "cadaclysm_blacksmith_sketch_update_reference", "cadaclysm_blacksmith_sketch_constrain",
  "cadaclysm_blacksmith_sketch_constraints", "cadaclysm_blacksmith_sketch_constraint_kind",
  "cadaclysm_blacksmith_sketch_constraint_refs", "cadaclysm_blacksmith_sketch_constraint_value",
  "cadaclysm_blacksmith_sketch_constraint_driving", "cadaclysm_blacksmith_sketch_constraint_sense",
  "cadaclysm_blacksmith_sketch_constraint_end", "cadaclysm_blacksmith_sketch_is_joint_tangent",
  "cadaclysm_blacksmith_sketch_remove", "cadaclysm_blacksmith_sketch_set_value", "cadaclysm_blacksmith_sketch_set_driving",
  "cadaclysm_blacksmith_sketch_measure", "cadaclysm_blacksmith_sketch_solve", "cadaclysm_blacksmith_sketch_drag",
  "cadaclysm_blacksmith_sketch_report_ids", "cadaclysm_blacksmith_sketch_diagnose", "cadaclysm_blacksmith_sketch_dof_list",
  "cadaclysm_blacksmith_sketch_dof_part", "cadaclysm_blacksmith_sketch_dof_part_list",
  "cadaclysm_blacksmith_sketch_profiles", "cadaclysm_blacksmith_sketch_open_chains",
  "cadaclysm_blacksmith_transform_translation", "cadaclysm_blacksmith_transform_rotation", "cadaclysm_blacksmith_transform_mirror",
  "cadaclysm_blacksmith_transform_scale", "cadaclysm_blacksmith_transform_scale_xyz", "cadaclysm_blacksmith_transform_shear",
  "cadaclysm_blacksmith_transform_plane_to_plane", "cadaclysm_blacksmith_transform_change_basis", "cadaclysm_blacksmith_transform_planar_projection",
  "cadaclysm_blacksmith_transform_project_along", "cadaclysm_blacksmith_transform_compose", "cadaclysm_blacksmith_transform_inverse",
  "cadaclysm_blacksmith_transform_is_rigid", "cadaclysm_blacksmith_transform_is_similarity", "cadaclysm_blacksmith_transform_decompose_rigid",
  "cadaclysm_blacksmith_transform_decompose_similarity", "cadaclysm_blacksmith_transform_decompose_affine", "cadaclysm_blacksmith_quaternion_from_axis_angle",
  "cadaclysm_blacksmith_quaternion_from_transform", "cadaclysm_blacksmith_quaternion_to_transform", "cadaclysm_blacksmith_quaternion_slerp",
  "cadaclysm_blacksmith_solid_transform", "cadaclysm_blacksmith_solid_convert_to_nurbs", "cadaclysm_blacksmith_profile_rotate",
  "cadaclysm_blacksmith_profile_scale", "cadaclysm_blacksmith_profile_mirror", "cadaclysm_blacksmith_profile_transform2d",
  "cadaclysm_blacksmith_value_size", "cadaclysm_blacksmith_value_check", "cadaclysm_blacksmith_value_bounds",
  "cadaclysm_blacksmith_value_transform", "cadaclysm_blacksmith_curve_value_point_at", "cadaclysm_blacksmith_curve_value_tangent_at",
  "cadaclysm_blacksmith_curve_value_length", "cadaclysm_blacksmith_curve_value_closest_point", "cadaclysm_blacksmith_circle_through",
  "cadaclysm_blacksmith_arc_through", "cadaclysm_blacksmith_arc_from_start_tangent_end", "cadaclysm_blacksmith_ellipse_from_circle",
  "cadaclysm_blacksmith_surface_value_point_at", "cadaclysm_blacksmith_surface_value_normal_at", "cadaclysm_blacksmith_surface_value_closest_point",
  "cadaclysm_blacksmith_surface_value_domain", "cadaclysm_blacksmith_surface_value_nurbs_sheet", "cadaclysm_blacksmith_solid_value_contains",
  "cadaclysm_blacksmith_solid_value_area", "cadaclysm_blacksmith_solid_value_volume", "cadaclysm_blacksmith_solid_value_to_solid",
  "cadaclysm_blacksmith_cuboid_from_bounds", "cadaclysm_blacksmith_cuboid_around", "cadaclysm_blacksmith_cuboid_corners",
  "cadaclysm_blacksmith_cuboid_point_at", "cadaclysm_blacksmith_cuboid_closest_point", "cadaclysm_blacksmith_frame_fit",
  "cadaclysm_blacksmith_rectangle_corners", "cadaclysm_blacksmith_rectangle_area", "cadaclysm_blacksmith_rectangle_closest_point",
  "cadaclysm_blacksmith_rectangle_contains", "cadaclysm_blacksmith_rectangle_to_sheet", "cadaclysm_blacksmith_triangle_area",
  "cadaclysm_blacksmith_triangle_perimeter", "cadaclysm_blacksmith_triangle_centroid", "cadaclysm_blacksmith_triangle_circumcircle",
  "cadaclysm_blacksmith_triangle_point_at", "cadaclysm_blacksmith_triangle_barycentric", "cadaclysm_blacksmith_triangle_closest_point",
  "cadaclysm_blacksmith_triangle_edge", "cadaclysm_blacksmith_triangle_to_sheet", "cadaclysm_blacksmith_ray_point_at",
  "cadaclysm_blacksmith_ray_closest_point",
  "cadaclysm_blacksmith_solid_tracked", "cadaclysm_blacksmith_solid_is_tracked", "cadaclysm_blacksmith_face_id",
  "cadaclysm_blacksmith_face_with_id", "cadaclysm_blacksmith_face_origin_count", "cadaclysm_blacksmith_face_origin_at",
  "cadaclysm_blacksmith_edge_id", "cadaclysm_blacksmith_edge_with_id", "cadaclysm_blacksmith_edge_origin_count",
  "cadaclysm_blacksmith_edge_origin_at", "cadaclysm_blacksmith_origins_through",
  "cadaclysm_blacksmith_with_attribute", "cadaclysm_blacksmith_without_attribute", "cadaclysm_blacksmith_attribute",
  "cadaclysm_blacksmith_attribute_count", "cadaclysm_blacksmith_attribute_key_at", "cadaclysm_blacksmith_attribute_value_at",
  "cadaclysm_blacksmith_with_face_attribute", "cadaclysm_blacksmith_without_face_attribute", "cadaclysm_blacksmith_face_attribute",
  "cadaclysm_blacksmith_face_attribute_count", "cadaclysm_blacksmith_face_attribute_key_at",
  "cadaclysm_blacksmith_face_attribute_value_at",
  "cadaclysm_blacksmith_history", "cadaclysm_blacksmith_edge_history", "cadaclysm_blacksmith_history_free",
  "cadaclysm_blacksmith_history_kept_count", "cadaclysm_blacksmith_history_kept_at",
  "cadaclysm_blacksmith_history_modified_count", "cadaclysm_blacksmith_history_modified_at",
  "cadaclysm_blacksmith_history_modified_output_count", "cadaclysm_blacksmith_history_modified_output_at",
  "cadaclysm_blacksmith_history_generated_count", "cadaclysm_blacksmith_history_generated_at",
  "cadaclysm_blacksmith_history_deleted_count", "cadaclysm_blacksmith_history_deleted_at",
  "cadaclysm_blacksmith_edge_ref", "cadaclysm_blacksmith_find_edge", "cadaclysm_blacksmith_vertex_count",
  "cadaclysm_blacksmith_vertex_ref", "cadaclysm_blacksmith_find_vertex",
  "cadaclysm_blacksmith_curve_value_to_nurbs",
  "cadaclysm_blacksmith_nurbs_curve_blend",
  "cadaclysm_blacksmith_nurbs_curve_clone",
  "cadaclysm_blacksmith_nurbs_curve_control_count",
  "cadaclysm_blacksmith_nurbs_curve_control_points",
  "cadaclysm_blacksmith_nurbs_curve_curvature",
  "cadaclysm_blacksmith_nurbs_curve_degree",
  "cadaclysm_blacksmith_nurbs_curve_derivatives",
  "cadaclysm_blacksmith_nurbs_curve_divide_by_count",
  "cadaclysm_blacksmith_nurbs_curve_divide_by_length",
  "cadaclysm_blacksmith_nurbs_curve_domain",
  "cadaclysm_blacksmith_nurbs_curve_elevated",
  "cadaclysm_blacksmith_nurbs_curve_extended",
  "cadaclysm_blacksmith_nurbs_curve_face_hits",
  "cadaclysm_blacksmith_nurbs_curve_fit",
  "cadaclysm_blacksmith_nurbs_curve_free",
  "cadaclysm_blacksmith_nurbs_curve_from_edge",
  "cadaclysm_blacksmith_nurbs_curve_from_face_isocurve",
  "cadaclysm_blacksmith_nurbs_curve_is_closed",
  "cadaclysm_blacksmith_nurbs_curve_is_rational",
  "cadaclysm_blacksmith_nurbs_curve_joined",
  "cadaclysm_blacksmith_nurbs_curve_knot_count",
  "cadaclysm_blacksmith_nurbs_curve_knots",
  "cadaclysm_blacksmith_nurbs_curve_length",
  "cadaclysm_blacksmith_nurbs_curve_new",
  "cadaclysm_blacksmith_nurbs_curve_plane_hits",
  "cadaclysm_blacksmith_nurbs_curve_point",
  "cadaclysm_blacksmith_nurbs_curve_point_at_length",
  "cadaclysm_blacksmith_nurbs_curve_projected_to_face",
  "cadaclysm_blacksmith_nurbs_curve_projected_to_plane",
  "cadaclysm_blacksmith_nurbs_curve_pulled_to_face",
  "cadaclysm_blacksmith_nurbs_curve_reversed",
  "cadaclysm_blacksmith_nurbs_curve_through",
  "cadaclysm_blacksmith_nurbs_curve_transformed",
  "cadaclysm_blacksmith_nurbs_curve_trimmed",
  "cadaclysm_blacksmith_nurbs_curve_tween",
  "cadaclysm_blacksmith_nurbs_curve_weights",
  "cadaclysm_blacksmith_loft_curves",
  "cadaclysm_blacksmith_sweep_rail",
  "cadaclysm_blacksmith_sweep_two_rails",
  "cadaclysm_blacksmith_edge_surface",
  "cadaclysm_blacksmith_network_surface",
  "cadaclysm_blacksmith_continuity",
  "cadaclysm_blacksmith_match_side",
  "cadaclysm_blacksmith_blend_sides",
  "cadaclysm_blacksmith_n_sided_patch",
  "cadaclysm_blacksmith_fillet_surfaces",
  "cadaclysm_blacksmith_fillet_varying",
  "cadaclysm_blacksmith_split_by_curve",
  "cadaclysm_blacksmith_trim_by_curve",
  "cadaclysm_blacksmith_join_sheets",
  "cadaclysm_blacksmith_flange",
  "cadaclysm_blacksmith_extrude_to",
  "cadaclysm_blacksmith_recess",
  "cadaclysm_blacksmith_document_new", "cadaclysm_blacksmith_document_load", "cadaclysm_blacksmith_document_save",
  "cadaclysm_blacksmith_document_apply", "cadaclysm_blacksmith_document_preview",
  "cadaclysm_blacksmith_document_preview_begin", "cadaclysm_blacksmith_document_end_preview",
  "cadaclysm_blacksmith_document_batch_begin", "cadaclysm_blacksmith_document_batch_end",
  "cadaclysm_blacksmith_document_batch_abort", "cadaclysm_blacksmith_document_undo", "cadaclysm_blacksmith_document_redo",
  "cadaclysm_blacksmith_document_params", "cadaclysm_blacksmith_document_evaluate",
  "cadaclysm_blacksmith_document_result_kind", "cadaclysm_blacksmith_document_result_solid",
  "cadaclysm_blacksmith_document_result_profile", "cadaclysm_blacksmith_document_result_profile_count",
  "cadaclysm_blacksmith_document_result_profile_at", "cadaclysm_blacksmith_document_result_nurbs_curve",
  "cadaclysm_blacksmith_document_result_subd", "cadaclysm_blacksmith_document_value",
  "cadaclysm_blacksmith_document_errors", "cadaclysm_blacksmith_document_kinds",
  "cadaclysm_blacksmith_document_solid_body", "cadaclysm_blacksmith_document_profile_path",
  "cadaclysm_blacksmith_document_branch_new", "cadaclysm_blacksmith_document_branch_switch",
  "cadaclysm_blacksmith_document_tips", "cadaclysm_blacksmith_document_branch_rename",
  "cadaclysm_blacksmith_document_branch_delete", "cadaclysm_blacksmith_document_branch_list",
  "cadaclysm_blacksmith_document_log", "cadaclysm_blacksmith_document_free",
  "cadaclysm_bim_document_new", "cadaclysm_bim_document_load", "cadaclysm_bim_kinds",
  "cadaclysm_bim_document_export_ifc",
}

bind = function(path)
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
  error(setmetatable({ message = reason ~= "" and reason or what, ids = {} }, BuildError), 2)
end

-- `fail` for a sketch call that can be refused with ids (the constraint methods,
-- `remove_entity`, `set_value`, `set_driving`, `update_reference`, `drag`) on the sketch
-- handle `h`: the reason first -- any later call may clear it -- then a copy of the ids
-- `report_ids` holds. Every other sketch refusal is `fail`'s, ids empty: `report_ids`
-- still holds an earlier refusal's.
local function fail_ids(what, h)
  local reason = last_error()
  local n = ffi.new("size_t[1]")
  local p = lib().cadaclysm_blacksmith_sketch_report_ids(h, n)
  local ids = {}
  if p ~= nil then
    for i = 1, tonumber(n[0]) do ids[i] = tonumber(p[i - 1]) end
  end
  error(setmetatable({ message = reason ~= "" and reason or what, ids = ids }, BuildError), 2)
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
--- "boolean.mesh_budget", "boolean.finest_tolerance", "profile_boolean.point_budget",
--- "measure.default_accuracy", "step.validation_properties",
--- "step.validation_accuracy", "tolerance.relative" or
--- "tolerance.angular". Raises -- and changes nothing -- for a name that is not
--- an option or a value it does not take, saying which and what it takes. The last two
--- stamp a written STEP part file with each body's measured area, volume and centroid,
--- there for the kernel that reads the file to check the transfer against; off by
--- default, since it measures every body in the file at "step.validation_accuracy" (1e-5).
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

-- Tolerances. Every default stays what it is: `a:join(b)` still means 0.05. Passing 0 (or
-- NaN, `0/0`) as the `tolerance` of a verb that takes a distance tolerance -- a boolean,
-- fillet, shell, split, section, hit test, mesh, curve fit or profile verb -- opts into the
-- model's own: `effective_tolerance(...)`, the larger of the loosest absolute tolerance the
-- inputs declare and the option "tolerance.relative" (default 1e-4) times their size; nil is
-- still the verb's default. A solid declares what its file said (`Solid.tolerances`, nil for
-- what it did not say; the reader's `Scene.tolerances` is the file's), every verb's result
-- inherits the loosest of its inputs', and `Solid:with_tolerances` sets it.
-- "tolerance.angular" (default one degree) stands in where nothing declares an angle.

--- What a solid declares about its own precision: `absolute`, a length in the model's own
--- units, and `angular`, in radians -- each nil where nothing declared it. What
--- `Solid.tolerances` returns.
---@class Tolerances
---@field absolute number|nil
---@field angular number|nil
local Tolerances = {}
Tolerances.__index = Tolerances
M.Tolerances = Tolerances


--- The tolerance a verb given a tolerance of 0 (or NaN) works at over the solids given: the
--- larger of the loosest absolute tolerance they declare (`Solid.tolerances`) and
--- `option("tolerance.relative")` times the largest of their sizes, never finer than their
--- coordinates can represent. 0 for no solids, or solids with nothing to size by -- which a
--- verb refuses.
---@return number
function M.effective_tolerance(...)
  local solids = { ... }
  local out = ffi.new("const struct CadaclysmBlacksmithSolid *[?]", math.max(#solids, 1))
  for i, s in ipairs(solids) do
    if type(s) ~= "table" or s._h == nil then
      raise("effective_tolerance: expected a Solid, got " .. tostring(s))
    end
    out[i - 1] = s:_h()
  end
  local t = lib().cadaclysm_blacksmith_effective_tolerance(out, #solids)
  if t ~= t then fail("effective_tolerance") end
  return t
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
  error(setmetatable({ message = reason ~= "" and reason or what, ids = {} }, BuildError), 2)
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
    error(setmetatable({ message = reason ~= "" and reason or "fem_mesh_view", ids = {} }, BuildError), 3)
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

do
-- A count of sides or points: a whole number the C call's uint32_t holds, refused by the call's
-- name before it, as `whole_u32` refuses the circumscribed polygon's.
local function count(value, call, name)
  if type(value) ~= "number" or value ~= math.floor(value) then
    raise(("%s: %s must be a whole number, got %s"):format(call, name, repr(value)))
  end
  if value < 0 or value > 4294967295 then raise(("%s: %s is out of range: %.14g"):format(call, name, value)) end
  return value
end

--- A regular polygon of `sides` sides (at least 3) on the circle of `radius`
--- about `centre`, its first corner at `angle` radians (default 0) from the
--- sketch's x axis, the rest counter-clockwise.
function Profile.regular_polygon(centre, radius, sides, angle)
  if angle == nil then angle = 0.0 end
  local cx, cy = pair(centre, "centre")
  sides = count(sides, "profile_regular_polygon", "sides")
  return new_profile(lib().cadaclysm_blacksmith_profile_regular_polygon(cx, cy, radius, sides, angle))
end

--- A star of `points` tips (at least 3) on the circle of `outer` about
--- `centre`, its inner corners on the circle of `inner` (positive, under
--- `outer`), alternating: the first tip at `angle` radians (default 0) from the
--- sketch's x axis, the rest counter-clockwise.
function Profile.star(centre, outer, inner, points, angle)
  if angle == nil then angle = 0.0 end
  local cx, cy = pair(centre, "centre")
  points = count(points, "profile_star", "points")
  return new_profile(lib().cadaclysm_blacksmith_profile_star(cx, cy, outer, inner, points, angle))
end
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

--- This outline turned `radians` (counter-clockwise) about `centre` ({x, y}).
function Profile:rotate(centre, radians)
  local cx, cy = pair(centre, "profile_rotate")
  return new_profile(lib().cadaclysm_blacksmith_profile_rotate(self._handle, cx, cy, number(radians, "profile_rotate")),
    "profile_rotate")
end

--- This outline scaled by `sx`, `sy` about `centre` ({x, y}): an arc stays an arc where the
--- two are equal in size, and becomes exact conics otherwise. A negative factor mirrors; a
--- zero one is singular and raises `BuildError`.
function Profile:scale(centre, sx, sy)
  local cx, cy = pair(centre, "profile_scale")
  return new_profile(lib().cadaclysm_blacksmith_profile_scale(self._handle, cx, cy, number(sx, "profile_scale"),
    number(sy, "profile_scale")), "profile_scale")
end

--- This outline reflected across the line through `point` along `direction` (each {x, y}).
--- A zero `direction` raises `BuildError`.
function Profile:mirror(point, direction)
  local px, py = pair(point, "profile_mirror")
  local dx, dy = pair(direction, "profile_mirror")
  return new_profile(lib().cadaclysm_blacksmith_profile_mirror(self._handle, px, py, dx, dy), "profile_mirror")
end

--- This outline under the 2D affine map `m`, six numbers row-major (2x3):
--- `x' = m1 x + m2 y + m3`, `y' = m4 x + m5 y + m6`. A singular map raises `BuildError`.
function Profile:transform2d(m)
  return new_profile(lib().cadaclysm_blacksmith_profile_transform2d(self._handle, doubles(m, 6, "profile_transform2d")),
    "profile_transform2d")
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

--- This solid through the affine map `t` -- a `Transform`, or sixteen numbers row-major
--- (or four rows of four) -- exact, its colours and name kept. A rigid map or a
--- similarity keeps every surface's kind, and so does a map within 1e-6 of a similarity
--- (applied as the exact similarity nearest it); any other map (a non-uniform scale, a
--- shear) turns the curved surfaces into their exact NURBS and maps those. The result's
--- `inexact_trims` counts the trims lost by this call. Raises `BuildError` for a singular
--- map (it flattens the solid), a non-finite one, or a non-affine one.
function Solid:transform(t)
  local lost = ffi.new("uint32_t[1]")
  local out = new_solid(lib().cadaclysm_blacksmith_solid_transform(self:_h(), M.Transform._matrix(t, "solid_transform"), lost),
    "solid_transform")
  out._inexact = tonumber(lost[0])
  return out
end

-- In a block of its own (the main chunk's 200 live locals): `convert_to_nurbs`'s levels,
-- CADACLYSM_BLACKSMITH_NURBS_PROCEDURAL, _ANALYTIC and _ALL.
do
local NURBS_LEVELS = { procedural = 0, analytic = 1, all = 2 }

--- This solid with its surfaces rewritten as their exact NURBS: `"procedural"` the
--- revolutions, extrusions and sums; `"analytic"` those and the cylinders, cones, spheres
--- and tori; `"all"` (the default) everything, planes and edge curves too, a body made only
--- of NURBS. Colours and name kept; `inexact_trims` counts the trims this call lost.
function Solid:convert_to_nurbs(level)
  if level == nil then level = "all" end
  local code = type(level) == "string" and NURBS_LEVELS[level] or nil
  if code == nil then
    raise(('convert_to_nurbs: level %s is not "procedural", "analytic" or "all"'):format(repr(level)))
  end
  local lost = ffi.new("uint32_t[1]")
  local out = new_solid(lib().cadaclysm_blacksmith_solid_convert_to_nurbs(self:_h(), code, lost),
    "solid_convert_to_nurbs")
  out._inexact = tonumber(lost[0])
  return out
end
end

--- On a solid from `Solid:transform` or `Solid:convert_to_nurbs`, the trims **that call**
--- lost: face boundaries kept only as a polyline lifted through the old surface, where no
--- exact edge curve was left. Per call, not the solid's history; 0 for a rigid map or a
--- similarity, and on every other solid. Read-only.
function Solid_get.inexact_trims(self)
  return rawget(self, "_inexact") or 0
end

-- -- combining

-- One verb to the caller: a tracked result's merge reads its origins back through the
-- boolean's (`origins_through`), so it names this solid as operand 0 and `other` as 1,
-- not the faces between the two steps. Both intermediates are freed.
local function merged(out, merge)
  if not merge then return out end
  local ok, result = pcall(function()
    local flushed = out:merge_flush()
    if not out.is_tracked then return flushed end
    local through = new_solid(lib().cadaclysm_blacksmith_origins_through(flushed:_h(), out:_h()), "origins_through")
    flushed:close()
    return through
  end)
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
--- after), which may be empty for a partial overlap of curved faces whose outlines cross. Known
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
  return Intersection._read(L, h)
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

-- ---- health and healing ----------------------------------------------------------

-- In a block of its own: only the report classes, `Solid:health`, `Solid:healed` and
-- `Solid:edge_tolerance` (and the decoders, for the tests) leave it.
do

--- One free edge (`HealthReport.free_edges`): a side only one face bounds, with its
--- nearest partner. `trim` the face's side, `edge` the edge it lies on (nil for a side
--- with no edge), `face` the face it bounds, `wire` its free wire (a number from zero
--- into `wires`), `partner` the nearest free edge across the gap as a number from zero
--- into `free_edges` (nil if there is none), `shared_ends` how many of its two ends it
--- shares with the partner (2 is what `join_sheets` joins), its `length` and the `gap`
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

--- What a mesh of the body shows (`Solid:health(tolerance, true)`): whether it is
--- `watertight`, how many mesh edges are `open` (one triangle) or `folded` (more than
--- two), how many pairs of triangles pass through each other (`crossings`), and the
--- solid's `edges` the cracks lie along. Only a closed body is counted.
---@class Cracks
---@field watertight boolean
---@field open integer
---@field folded integer
---@field crossings integer
---@field edges integer[]
local Cracks = {}
Cracks.__index = Cracks
M.Cracks = Cracks

--- What is wrong with a body, as plain data (`Solid:health`): the `tolerance` and
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
  if w == nil then raise(("wire_edges: no wire %s (%d wires)"):format(tostring(wire), #self.wires)) end
  local out = {}
  for i = 1, w.count do out[i] = self.free_edges[w.first + i] end
  return out
end

--- One small feature `Solid:healed` removed: its `kind` (as `SmallFeature.kind`), its
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

--- One small feature `Solid:healed` left, and why: `kind` and `index` as in `HealFix`;
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

--- What `Solid:healed` did, as plain data: the `tolerance` it healed at, the furthest any
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
  if name == nil then raise(what .. ": the library sent an unknown code " .. tostring(code)) end
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

-- `tolerance` as the C ABI takes it: nil is NaN, the default.
local function tolerance_of(tolerance, what)
  if tolerance == nil then return 0 / 0 end
  if type(tolerance) ~= "number" then raise(what .. ": tolerance must be a number, got " .. tostring(tolerance)) end
  return tolerance
end

--- What is wrong with this solid, as a `HealthReport`: the free edges (the sides one face
--- bounds) and the wires they chain into, with each edge's nearest partner and the gap to
--- it; the features below `tolerance`; the loose edges; and what sewing (`join_sheets`) would
--- join and leave. `tolerance` is the length below which a feature is "small" and a gap closes --
--- nil, or a value that is not finite and positive, takes the default, `1e-4` times the
--- diagonal (the report shows what was used). `mesh` true also meshes the solid and reports
--- where the mesh cracks (`cracks`); without it `cracks` is nil. Nothing moves.
---@param tolerance number|nil
---@param mesh boolean|nil
---@return HealthReport
function Solid:health(tolerance, mesh)
  local pointer = self:_h()
  local L = lib()
  local h = L.cadaclysm_blacksmith_health(pointer, tolerance_of(tolerance, "health"), mesh and true or false)
  if h == nil then fail("health") end
  local ok, report = pcall(function()
    local counts, sizes = ffi.new("uint32_t[18]"), ffi.new("double[8]")
    if not L.cadaclysm_blacksmith_health_summary(h, counts, sizes) then fail("health") end
    local n = tonumber(L.cadaclysm_blacksmith_health_free_edges(h, nil, nil))
    local free_ids, free_sizes = ffi.new("uint32_t[?]", 6 * n + 1), ffi.new("double[?]", 2 * n + 1)
    if n > 0 then L.cadaclysm_blacksmith_health_free_edges(h, free_ids, free_sizes) end
    local w = tonumber(L.cadaclysm_blacksmith_health_wires(h, nil, nil))
    local wire_runs, wire_sizes = ffi.new("uint32_t[?]", 3 * w + 1), ffi.new("double[?]", 2 * w + 1)
    if w > 0 then L.cadaclysm_blacksmith_health_wires(h, wire_runs, wire_sizes) end
    local s = tonumber(L.cadaclysm_blacksmith_health_small(h, nil, nil))
    local small_items, small_sizes = ffi.new("uint32_t[?]", 2 * s + 1), ffi.new("double[?]", s + 1)
    if s > 0 then L.cadaclysm_blacksmith_health_small(h, small_items, small_sizes) end
    local c = tonumber(L.cadaclysm_blacksmith_health_crack_edges(h, nil))
    local crack_ids = ffi.new("uint32_t[?]", c + 1)
    if c > 0 then L.cadaclysm_blacksmith_health_crack_edges(h, crack_ids) end
    return health_report(listed(counts, 18), listed(sizes, 8), listed(free_ids, 6 * n), listed(free_sizes, 2 * n),
      listed(wire_runs, 3 * w), listed(wire_sizes, 2 * w), listed(small_items, 2 * s), listed(small_sizes, s),
      listed(crack_ids, c))
  end)
  L.cadaclysm_blacksmith_health_free(h)
  if not ok then error(report, 0) end
  return report
end

--- This solid with its small features removed, and what was done: a new `Solid` and a
--- `HealReport`; this one is left as it was. The features are the ones
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
---@return Solid, HealReport
function Solid:healed(tolerance, edges, faces, holes)
  local pointer = self:_h()
  local L = lib()
  local flags = (edges ~= false and 1 or 0) + (faces ~= false and 2 or 0) + (holes ~= false and 4 or 0)
  local h = L.cadaclysm_blacksmith_healed(pointer, tolerance_of(tolerance, "healed"), flags)
  if h == nil then fail("healed") end
  local ok, body, report = pcall(function()
    local counts, sizes = ffi.new("uint32_t[11]"), ffi.new("double[2]")
    if not L.cadaclysm_blacksmith_heal_summary(h, counts, sizes) then fail("healed") end
    local n = tonumber(L.cadaclysm_blacksmith_heal_fixes(h, nil, nil))
    local fix_items, fix_sizes = ffi.new("uint32_t[?]", 2 * n + 1), ffi.new("double[?]", 2 * n + 1)
    if n > 0 then L.cadaclysm_blacksmith_heal_fixes(h, fix_items, fix_sizes) end
    local r = tonumber(L.cadaclysm_blacksmith_heal_refused(h, nil, nil))
    local refused_items, refused_sizes = ffi.new("uint32_t[?]", 3 * r + 1), ffi.new("double[?]", r + 1)
    if r > 0 then L.cadaclysm_blacksmith_heal_refused(h, refused_items, refused_sizes) end
    local made = heal_report(listed(counts, 11), listed(sizes, 2), listed(fix_items, 2 * n), listed(fix_sizes, 2 * n),
      listed(refused_items, 3 * r), listed(refused_sizes, r))
    return new_solid(L.cadaclysm_blacksmith_heal_body(h), "healed"), made
  end)
  L.cadaclysm_blacksmith_heal_free(h)
  if not ok then error(body, 0) end
  return body, report
end

--- How far edge `edge` (as a `HealFix` or `FreeEdge` names one) may lie off its
--- curve: 0 for an exact edge, the distance healing (or sewing) moved it where that is
--- recorded, nil when no trim names the id (an edge healing removed). `edge` is a whole
--- number from 0 to 4294967295. A closed solid raises `BuildError`.
---@param edge integer
---@return number|nil
function Solid:edge_tolerance(edge)
  local pointer = self:_h()
  if type(edge) ~= "number" or edge ~= math.floor(edge) or edge < 0 or edge > 4294967295 then
    raise("edge_tolerance: edge must be a whole number from 0 to 4294967295, got " .. tostring(edge))
  end
  local t = lib().cadaclysm_blacksmith_edge_tolerance(pointer, edge)
  if t ~= t then
    -- NaN is "no such edge", unless the library refused the solid (a reason is set)
    if last_error() ~= "" then fail("edge_tolerance") end
    return nil
  end
  return t
end

--- What this solid declares about its own precision, as `Tolerances`: read from its file,
--- inherited through every verb from the loosest of its inputs, or set by `with_tolerances`;
--- nil in a field nothing declared. A verb given a tolerance of 0 works at
--- `effective_tolerance`, which takes it into account.
function Solid_get.tolerances(self)
  local absolute, angular = ffi.new("double[1]"), ffi.new("double[1]")
  if not lib().cadaclysm_blacksmith_solid_tolerances(self:_h(), absolute, angular) then fail("solid_tolerances") end
  local declared = function(v) if v ~= v then return nil end return v end
  return setmetatable({ absolute = declared(absolute[0]), angular = declared(angular[0]) }, M.Tolerances)
end

--- A new solid: this one declaring `absolute` (a length) and `angular` (radians) instead of
--- what it declared, its name, paint and marks kept. nil or 0 (or NaN) declares nothing for
--- that field; a negative or infinite value raises `BuildError`.
---@param absolute number|nil
---@param angular number|nil
---@return Solid
function Solid:with_tolerances(absolute, angular)
  local function given(v, field)
    if v == nil then return 0 / 0 end
    if type(v) ~= "number" then raise("solid_with_tolerances: " .. field .. " must be a number or nil, got " .. tostring(v)) end
    return v
  end
  return new_solid(lib().cadaclysm_blacksmith_solid_with_tolerances(self:_h(), given(absolute, "absolute"), given(angular, "angular")))
end

--- How loose this solid's vertex at `point` ({x, y, z}) is, where its producer said (an OCCT
--- `.brep` records one per vertex): the tolerance of the nearest recorded vertex within its
--- own tolerance of `point`. nil where none is recorded there.
---@param point number[]
---@return number|nil
function Solid:vertex_tolerance(point)
  if type(point) ~= "table" or type(point[1]) ~= "number" or type(point[2]) ~= "number" or type(point[3]) ~= "number" then
    raise("vertex_tolerance: a point is three numbers, got " .. tostring(point))
  end
  local t = lib().cadaclysm_blacksmith_vertex_tolerance(self:_h(), point[1], point[2], point[3])
  if t ~= t then
    if last_error() ~= "" then fail("vertex_tolerance") end
    return nil
  end
  return t
end

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

-- -- material and look defined outside the file

--- This solid made of `material` -- a name, written to STEP as the product's
--- `MATERIAL_DESIGNATION`. Kept by every operation as the solid's colour is: a
--- move keeps it, a boolean's result is made of its first solid's. Writing it
--- moves `step`'s default schema to AP242; a named schema without the entity
--- drops it, as it drops a colour. Raises `BuildError` when blank, or for
--- `material` not a string.
function Solid:with_material(material)
  if type(material) ~= "string" then raise("with_material: expected a string, got " .. repr(material)) end
  return new_solid(lib().cadaclysm_blacksmith_with_material(self:_h(), material))
end

--- This solid drawn in a style defined outside the file: `identification` the
--- style's name in the library at `location` -- a MaterialX or MDL file and a
--- material in it, say. Either may be nil, not both. Written to STEP as an
--- `EXTERNALLY_DEFINED_STYLE` beside the solid's colour, which a reader without
--- the library draws instead (AP242 or AP214: the default schema moves to
--- AP242). Kept as `with_material`'s material is.
function Solid:styled(location, identification)
  for _, t in ipairs({ { "location", location }, { "identification", identification } }) do
    if t[2] ~= nil and type(t[2]) ~= "string" then raise("styled: " .. t[1] .. ": expected a string or nil, got " .. repr(t[2])) end
  end
  return new_solid(lib().cadaclysm_blacksmith_styled(self:_h(), location, identification))
end

--- A string the library lends from this solid, or nil -- read as `name` is.
local function borrowed(raw)
  if raw == nil then return nil end
  return ffi.string(raw)
end

--- What this solid is made of, or nil -- see `with_material`.
function Solid_get.material(self)
  return borrowed(lib().cadaclysm_blacksmith_solid_material(self:_h()))
end

--- Where this solid's outside style lives (`styled`'s `location`), or nil.
function Solid_get.style_location(self)
  return borrowed(lib().cadaclysm_blacksmith_solid_style_location(self:_h()))
end

--- This solid's outside style's name in its library (`styled`'s
--- `identification`), or nil.
function Solid_get.style_identification(self)
  return borrowed(lib().cadaclysm_blacksmith_solid_style_identification(self:_h()))
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

--- This solid as a Rhino `.3dm`'s bytes (a Lua string): its exact brep, named and
--- coloured as the solid is; `unit` as `rhino3dm_bytes`.
function Solid:rhino3dm_bytes(unit)
  if unit == nil then unit = "mm" end
  return M.rhino3dm_bytes({ self }, unit)
end

--- Write this solid to a Rhino `.3dm` at `path`, by the library itself; `unit` as
--- `rhino3dm_bytes`.
function Solid:write_3dm(path, unit)
  if unit == nil then unit = "mm" end
  M.write_3dm(path, { self }, unit)
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

-- ---- measuring: the oriented box, lengths, containment and the closest points --------

-- In a block of its own: the main chunk is at LuaJIT's limit of 200 live locals, and this
-- section's helpers are its own business.
do

-- Three rows of three from nine row-major numbers of a C array (0-based).
local function rows_of_nine(a)
  return { { a[0], a[1], a[2] }, { a[3], a[4], a[5] }, { a[6], a[7], a[8] } }
end

--- A closed solid's box on its principal axes (`Solid:oriented_box`): `centre` (the box's
--- middle, not the centroid), `axes` (three unit rows, row `i` being axis `i`, orthonormal and
--- right-handed) and `half`, the half extent along each. Not the minimal box in general; where
--- two principal moments agree the axes in their plane are a free choice. Tables are 1-based.
---@class OrientedBox
---@field centre number[]  three
---@field axes number[][]  three rows of three
---@field half number[]    three, grown by the tolerance the measurement settled on
local OrientedBox = {}
class(OrientedBox)
callable(OrientedBox)
M.OrientedBox = OrientedBox

function OrientedBox.new(fields)
  return setmetatable(fields, OrientedBox)
end

OrientedBox.__tostring = function(self)
  return ("OrientedBox(centre=(%.6g, %.6g, %.6g), half=(%.6g, %.6g, %.6g))"):format(
    self.centre[1], self.centre[2], self.centre[3], self.half[1], self.half[2], self.half[3])
end

--- A measured length beside an estimate of its error (`Solid:edge_length`, `Profile:length`).
--- `error` estimates the distance from the true length; where `accuracy_met` is false the
--- refinement stopped at its depth limit, and `from_polyline` says the curve was a sampled
--- polyline rather than an exact one.
---@class Length
---@field length number
---@field error number           an estimate of the distance to the true length
---@field accuracy_met boolean   the error came under the accuracy asked for
---@field from_polyline boolean  measured on a sampled polyline
local Length = {}
class(Length)
callable(Length)
M.Length = Length

function Length.new(fields)
  return setmetatable(fields, Length)
end

Length.__tostring = function(self)
  return ("Length(%.12g+-%.3g)"):format(self.length, self.error)
end

local function length_of(raw)
  return Length.new({
    length = raw.length,
    error = raw.error,
    accuracy_met = raw.accuracy_met ~= 0,
    from_polyline = raw.from_polyline ~= 0,
  })
end

--- One place along a curve at an arc length (`Solid:edge_point_at_length`, `Profile:point_at_length`, and
--- the lists the divides return). `parameter` is the curve's own at that point (on a profile, the
--- side's own); `segment` is the profile's side (the segment count for the implicit closing side), nil
--- on a solid's edge; `error` estimates the distance to the true position along the curve, and
--- `from_polyline` says the curve was a sampled polyline rather than an exact one.
---@class At
---@field point number[]       three
---@field tangent number[]     three, unit
---@field parameter number
---@field segment integer|nil  the profile side, nil on a solid's edge
---@field error number
---@field from_polyline boolean
local At = {}
class(At)
callable(At)
M.At = At

function At.new(fields)
  return setmetatable(fields, At)
end

At.__tostring = function(self)
  return ("At(point=(%.6g, %.6g, %.6g), parameter=%.12g)"):format(self.point[1], self.point[2], self.point[3], self.parameter)
end

local function at_of(raw)
  return At.new({
    point = { raw.point[0], raw.point[1], raw.point[2] },
    tangent = { raw.tangent[0], raw.tangent[1], raw.tangent[2] },
    parameter = raw.parameter,
    segment = raw.segment ~= NONE and tonumber(raw.segment) or nil,
    error = raw.error,
    from_polyline = raw.from_polyline ~= 0,
  })
end

--- The closest points between two solids' boundaries (`Solid:closest`); side `a` is the solid
--- asked, side `b` the other. `kind_a`/`kind_b` are "face", "edge" or "vertex", `index_a`/
--- `index_b` the kernel's id for that feature, and `edge_a`/`edge_b` the index `Solid:fillet` and
--- `Solid.edges` use for an edge feature -- nil for a face, a vertex, or an edge the fillet table
--- does not hold. `refined` false is the mesh's answer, within the tolerance of the true minimum.
---@class Closest
---@field distance number
---@field on_a number[]      three: the nearest point on `a`
---@field on_b number[]      three: the nearest point on `b`
---@field kind_a string      "face", "edge" or "vertex"
---@field index_a integer
---@field edge_a integer|nil  the fillet-table edge, nil if none
---@field kind_b string
---@field index_b integer
---@field edge_b integer|nil
---@field refined boolean
local Closest = {}
class(Closest)
callable(Closest)
M.Closest = Closest

function Closest.new(fields)
  return setmetatable(fields, Closest)
end

Closest.__tostring = function(self)
  return ("Closest(distance=%.12g, %s/%s)"):format(self.distance, self.kind_a, self.kind_b)
end

-- The containment codes of the C ABI (OUTSIDE 0, INSIDE 1, ON 2) as Python's strings. Any other
-- code is a refusal naming the call, never a guess.
local containment
do
  local names = { [0] = "outside", "inside", "on" }
  containment = function(code, what)
    local name = names[code]
    if name == nil then raise(what .. ": the library answered " .. tostring(code) .. ", not a containment code") end
    return name
  end
end

-- An edge index: a whole number a uint32 holds. Refused, named, before the library is asked.
local function edge_index(edge, what)
  if type(edge) ~= "number" or edge < 0 or edge > 4294967295 or edge ~= math.floor(edge) then
    raise(what .. ": edge must be an index, got " .. repr(edge))
  end
  return edge
end

-- An accuracy: nil asks for the default, like 0. Only the library refuses NaN, an infinite one
-- or one of 1 or more; 0 or less is the default.
local function accuracy_arg(accuracy, what)
  if accuracy == nil then return 0 end
  return number(accuracy, what)
end

-- A divide's count: a whole number a uint32 holds. Refused, named, before the library is asked.
local function count_arg(n, what)
  if type(n) ~= "number" or n ~= math.floor(n) then
    raise(what .. ": n must be a whole number, not " .. repr(n))
  end
  if n < 0 or n > 4294967295 then raise(("%s: n is out of range: %.14g"):format(what, n)) end
  return n
end

-- Read a divide's list into `At`s and free it on every path; a null list raises the library's reason.
local function read_samples(list, what)
  local L = lib()
  if list == nil then fail(what) end
  local out, reason = {}, nil
  local count = L.cadaclysm_blacksmith_samples_count(list)
  local raw = ffi.new("CadaclysmBlacksmithAt[1]")
  for i = 0, count - 1 do
    if not L.cadaclysm_blacksmith_samples_at(list, i, raw) then
      reason = last_error()
      break
    end
    out[i + 1] = at_of(raw[0])
  end
  L.cadaclysm_blacksmith_samples_free(list)
  if reason ~= nil then
    error(setmetatable({ message = reason ~= "" and reason or "samples_at" }, BuildError), 2)
  end
  return out
end

--- This closed solid's box on its principal axes, an `OrientedBox`. `accuracy` is the relative
--- accuracy of the inertia the axes come from; 0 or less (or nil) asks for the box's own default,
--- 1e-5. Raises for an open body, or an `accuracy` that is NaN or infinite.
---@param accuracy number|nil
---@return OrientedBox
function Solid:oriented_box(accuracy)
  local out = ffi.new("CadaclysmBlacksmithOrientedBox[1]")
  if not lib().cadaclysm_blacksmith_oriented_box(self:_h(), accuracy_arg(accuracy, "oriented_box"), out) then
    fail("oriented_box")
  end
  local b = out[0]
  local function triple(a) return { a[0], a[1], a[2] } end
  return OrientedBox.new({ centre = triple(b.centre), axes = rows_of_nine(b.axes), half = triple(b.half) })
end

--- The length of edge `edge` (its index in `Solid.edges`, from zero, as `fillet` takes it) over
--- its own range, a `Length`, measured to the relative `accuracy` (0 or less, or nil, asks for the
--- default; the library refuses NaN, infinite or 1 or more). Raises for an edge past the end.
---@param edge integer
---@param accuracy number|nil
---@return Length
function Solid:edge_length(edge, accuracy)
  local out = ffi.new("CadaclysmBlacksmithLength[1]")
  edge = edge_index(edge, "edge_length")
  if not lib().cadaclysm_blacksmith_edge_length(self:_h(), edge, accuracy_arg(accuracy, "edge_length"), out) then
    fail("edge_length")
  end
  return length_of(out[0])
end

--- The length of this profile's outer loop (holes are not counted), a `Length`, measured to the
--- relative `accuracy` (0 or less, or nil, asks for the default; the library refuses NaN,
--- infinite or 1 or more).
---@param accuracy number|nil
---@return Length
function Profile:length(accuracy)
  local out = ffi.new("CadaclysmBlacksmithLength[1]")
  if not lib().cadaclysm_blacksmith_profile_length(profile_handle(self, "profile_length"),
      accuracy_arg(accuracy, "profile_length"), out) then
    fail("profile_length")
  end
  return length_of(out[0])
end

--- The point `s` along edge `edge` (index as `edge_length` takes it) from the start of its range, an
--- `At`, to the relative `accuracy` (0 or less, or nil, asks for the default). Raises for an `s` outside
--- the edge, an edge past the end, or an accuracy that is NaN or infinite.
---@param edge integer
---@param s number
---@param accuracy number|nil
---@return At
function Solid:edge_point_at_length(edge, s, accuracy)
  local out = ffi.new("CadaclysmBlacksmithAt[1]")
  edge = edge_index(edge, "edge_point_at_length")
  if not lib().cadaclysm_blacksmith_edge_point_at_length(self:_h(), edge, number(s, "edge_point_at_length"),
      accuracy_arg(accuracy, "edge_point_at_length"), out) then
    fail("edge_point_at_length")
  end
  return at_of(out[0])
end

--- `n` evenly spaced points along edge `edge` by arc length, a list of `At`: `n` of them on a closed
--- edge, `n + 1` on an open one (both ends). `n` is a whole number from 1 to 1,000,000.
---@param edge integer
---@param n integer
---@param accuracy number|nil
---@return At[]
function Solid:edge_divide_by_count(edge, n, accuracy)
  edge = edge_index(edge, "edge_divide_by_count")
  n = count_arg(n, "edge_divide_by_count")
  return read_samples(lib().cadaclysm_blacksmith_edge_divide_by_count(self:_h(), edge, n,
    accuracy_arg(accuracy, "edge_divide_by_count")), "edge_divide_by_count")
end

--- Points along edge `edge` every `step` of arc length from its start, a list of `At`; the short last
--- piece is kept and a closed edge's start is not repeated.
---@param edge integer
---@param step number
---@param accuracy number|nil
---@return At[]
function Solid:edge_divide_by_length(edge, step, accuracy)
  edge = edge_index(edge, "edge_divide_by_length")
  return read_samples(lib().cadaclysm_blacksmith_edge_divide_by_length(self:_h(), edge,
    number(step, "edge_divide_by_length"), accuracy_arg(accuracy, "edge_divide_by_length")), "edge_divide_by_length")
end

--- The point `s` along this profile's outer loop, an `At` whose `segment` is the side it lies on.
---@param s number
---@param accuracy number|nil
---@return At
function Profile:point_at_length(s, accuracy)
  local out = ffi.new("CadaclysmBlacksmithAt[1]")
  if not lib().cadaclysm_blacksmith_profile_point_at_length(profile_handle(self, "profile_point_at_length"),
      number(s, "profile_point_at_length"), accuracy_arg(accuracy, "profile_point_at_length"), out) then
    fail("profile_point_at_length")
  end
  return at_of(out[0])
end

--- `n` evenly spaced points round this profile's outer loop by arc length, a list of `At`.
---@param n integer
---@param accuracy number|nil
---@return At[]
function Profile:divide_by_count(n, accuracy)
  n = count_arg(n, "profile_divide_by_count")
  return read_samples(lib().cadaclysm_blacksmith_profile_divide_by_count(profile_handle(self, "profile_divide_by_count"),
    n, accuracy_arg(accuracy, "profile_divide_by_count")), "profile_divide_by_count")
end

--- Points round this profile's outer loop every `step` of arc length, a list of `At`; the short last
--- piece is kept.
---@param step number
---@param accuracy number|nil
---@return At[]
function Profile:divide_by_length(step, accuracy)
  return read_samples(lib().cadaclysm_blacksmith_profile_divide_by_length(profile_handle(self, "profile_divide_by_length"),
    number(step, "profile_divide_by_length"), accuracy_arg(accuracy, "profile_divide_by_length")), "profile_divide_by_length")
end

--- Where `point` ({x, y, z}) lies against this closed solid: "inside", "outside", or "on" within
--- `tolerance` of its boundary (absolute, in model units; nil is 0.05). Meshes the body on every
--- call; for more than a few points build a `classifier` once. Raises for an open body, a point
--- that is not finite, or a `tolerance` that is not positive and finite.
---@param point number[]
---@param tolerance number|nil
---@return string
function Solid:contains(point, tolerance)
  if tolerance == nil then tolerance = 0.05 end
  local pt = doubles(point, 3, "contains")
  local out = ffi.new("uint32_t[1]")
  if not lib().cadaclysm_blacksmith_contains(self:_h(), pt, number(tolerance, "contains"), out) then
    fail("contains")
  end
  return containment(tonumber(out[0]), "contains")
end

local function free_classifier(h) lib().cadaclysm_blacksmith_classifier_free(h) end

--- A closed solid meshed once and asked where point after point lies (`Solid:classifier`):
--- `contains(point)` is "inside", "outside", or "on" within `tolerance` of the boundary. It
--- keeps its own reference to the body, so it goes on answering after its `Solid` is closed.
--- `close()` frees this handle; so does the garbage collector.
---@class Classifier
local Classifier = {}
local Classifier_get = {}
class(Classifier, Classifier_get)
M.Classifier = Classifier

--- Whether `close()` has been called.
function Classifier_get.closed(self)
  return rawget(self, "_ptr") == nil
end

--- A classifier for this closed solid at `tolerance` (absolute, in model units; nil is 0.05).
--- Raises for an open body or a `tolerance` that is not positive and finite.
---@param tolerance number|nil
---@return Classifier
function Solid:classifier(tolerance)
  if tolerance == nil then tolerance = 0.05 end
  local h = lib().cadaclysm_blacksmith_classifier_new(self:_h(), number(tolerance, "classifier_new"))
  checked(h, "classifier_new")
  return setmetatable({ _ptr = ffi.gc(h, free_classifier) }, Classifier)
end

--- Free the classifier. Idempotent.
function Classifier:close()
  local h = rawget(self, "_ptr")
  if h ~= nil then
    self._ptr = nil
    ffi.gc(h, nil)
    free_classifier(h)
  end
end

function Classifier:_h()
  local h = rawget(self, "_ptr")
  if h == nil then raise("classifier: closed") end
  return h
end

--- "inside", "outside", or "on" within the classifier's tolerance of the boundary, for `point`
--- ({x, y, z}). Raises for a point that is not finite.
---@param point number[]
---@return string
function Classifier:contains(point)
  local h = self:_h()
  local pt = doubles(point, 3, "classifier_contains")
  local out = ffi.new("uint32_t[1]")
  if not lib().cadaclysm_blacksmith_classifier_contains(h, pt, out) then fail("classifier_contains") end
  return containment(tonumber(out[0]), "classifier_contains")
end

--- The closest points between this solid's boundary and `other`'s, to `tolerance` (absolute, in
--- model units; nil is 0.05), a `Closest`; this solid is side `a`. Boundaries are measured, not
--- volumes. `progress`, if given, is called as `progress(phase, done, total)` -- the phases
--- "meshing", "pruning" and "refining" -- as `join`'s is. Raises for a `tolerance` that is not
--- positive and finite, or a solid with no faces.
---@param other Solid
---@param tolerance number|nil
---@param progress fun(phase: string, done: number, total: number)|nil
---@return Closest
function Solid:closest(other, tolerance, progress)
  if tolerance == nil then tolerance = 0.05 end
  local a, b = self:_h(), solid_handle(other, "closest")
  local out = ffi.new("CadaclysmBlacksmithClosest[1]")
  -- The call answers a flag, not a handle: nothing for the callback's cleanup to free.
  local cb, done = progress_callback(progress, function() end)
  local ok = done(lib().cadaclysm_blacksmith_closest(a, b, number(tolerance, "closest"), cb, nil, out))
  if not ok then fail("closest") end
  local c = out[0]
  local function triple(p) return { p[0], p[1], p[2] } end
  -- `kind_*` are the library's static strings: copied here, never freed.
  return Closest.new({
    distance = c.distance,
    on_a = triple(c.on_a),
    on_b = triple(c.on_b),
    kind_a = text(c.kind_a),
    index_a = c.index_a,
    edge_a = c.edge_a ~= NONE and c.edge_a or nil,
    kind_b = text(c.kind_b),
    index_b = c.index_b,
    edge_b = c.edge_b ~= NONE and c.edge_b or nil,
    refined = c.refined ~= 0,
  })
end

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

--- Edge `edge` (an index into `edges`, from zero) by what it is, fifteen numbers:
--- its kind (line 0, circle 1, ellipse 2, B-spline 3, other 4), its midpoint
--- (x y z), its unit tangent there (x y z), its length, the outward normals there
--- of the two faces meeting on it (x y z each; an open sheet's rim gives the one
--- face's twice), and its span -- how far from the midpoint `find_edge` may find
--- it on a resized solid. `face_ref`'s twin. Raises `BuildError` for an edge past
--- the table or one with no length to measure.
function Solid:edge_ref(edge)
  local out = ffi.new("double[15]")
  if not lib().cadaclysm_blacksmith_edge_ref(self:_h(), edge, out) then fail("edge_ref") end
  local t = {}
  for i = 0, 14 do t[i + 1] = out[i] end
  return t
end

--- The edge `edge_ref` (from `edge_ref`) refers to: of the edges of that kind
--- passing within `tolerance` (default 1e-3) of its midpoint and running the same
--- way, the one of nearest length; where none does (the solid was resized), the
--- edge of that kind running the same way between faces facing the same two ways,
--- the only one or the one clearly nearest, no farther than the span. Nil where
--- the edge is gone. Raises `BuildError` for a malformed reference or a tolerance
--- not positive.
function Solid:find_edge(edge_ref, tolerance)
  if type(edge_ref) ~= "table" or #edge_ref ~= 15 then
    raise("find_edge: an edge reference is fifteen finite numbers")
  end
  local ref = ffi.new("double[15]", edge_ref)
  local found = lib().cadaclysm_blacksmith_find_edge(self:_h(), ref, tolerance or 1e-3)
  if found == -2 then fail("find_edge") end
  if found < 0 then return nil end
  return found
end

--- How many vertices this solid has: its edges' ends, welded, in the order
--- `vertex_ref` and `find_vertex` index.
function Solid_get.vertex_count(self)
  local n = lib().cadaclysm_blacksmith_vertex_count(self:_h())
  if n == 0 and last_error() ~= "" then fail("vertex_count") end
  return n
end

--- Vertex `vertex` (from zero) by where it is: `{x, y, z}`. Raises `BuildError`
--- for a vertex the solid does not have.
function Solid:vertex_ref(vertex)
  local out = ffi.new("double[3]")
  if not lib().cadaclysm_blacksmith_vertex_ref(self:_h(), vertex, out) then fail("vertex_ref") end
  return { out[0], out[1], out[2] }
end

--- The vertex nearest `vertex_ref` (any point `{x, y, z}`: a `vertex_ref`, or one
--- picked) within `tolerance` (default 1e-3); nil where no vertex is that near.
--- Raises `BuildError` for a point that is not three finite numbers or a
--- tolerance not positive.
function Solid:find_vertex(vertex_ref, tolerance)
  if type(vertex_ref) ~= "table" or #vertex_ref ~= 3 then
    raise("find_vertex: a vertex reference is three finite numbers")
  end
  local ref = ffi.new("double[3]", vertex_ref)
  local found = lib().cadaclysm_blacksmith_find_vertex(self:_h(), ref, tolerance or 1e-3)
  if found == -2 then fail("find_vertex") end
  if found < 0 then return nil end
  return found
end

-- -- identity: ids on faces and edges, where each came from, and a verb's history

--- What a verb did to its inputs' faces (or edges), read off the result's ids and
--- origins alone (`Solid:history`, `Solid:edge_history`): a table of four Lua
--- arrays. An input is named `{operand, id}`: the operand its index in the inputs
--- as passed (the verb's operand order: a boolean's target 0, its tool 1), the id
--- its `face_id`. Every list is in (operand, id) order, `generated` in id order.
--- Ids are Lua numbers (they count up from 1 per solid, far below 2^53).
---@class History
---@field kept table  `{ {operand, id}, out_id }` each: an input that became exactly one output, keeping its id
---@field modified table  `{ {operand, id}, {out_ids...} }` each: an input split, merged or renumbered
---@field generated table  the ids of the outputs with no origin (a fillet's round, a split's cut faces)
---@field deleted table  `{operand, id}` each: the inputs no output names (a cut tool's caps)
local History = {}
History.__index = History
History.__tostring = function(h)
  return ("History(kept=%d, modified=%d, generated=%d, deleted=%d)"):format(#h.kept, #h.modified, #h.generated, #h.deleted)
end
M.History = History

-- The four lists of history handle `h`, read whole; the caller frees it.
local function read_history(L, h)
  local operand, id, out = ffi.new("uint32_t[1]"), ffi.new("uint64_t[1]"), ffi.new("uint64_t[1]")
  local kept, modified, generated, deleted = {}, {}, {}, {}
  for i = 0, L.cadaclysm_blacksmith_history_kept_count(h) - 1 do
    if not L.cadaclysm_blacksmith_history_kept_at(h, i, operand, id, out) then fail("history_kept_at") end
    kept[#kept + 1] = { { tonumber(operand[0]), tonumber(id[0]) }, tonumber(out[0]) }
  end
  for i = 0, L.cadaclysm_blacksmith_history_modified_count(h) - 1 do
    if not L.cadaclysm_blacksmith_history_modified_at(h, i, operand, id) then fail("history_modified_at") end
    local n = L.cadaclysm_blacksmith_history_modified_output_count(h, i)
    if n == NONE then fail("history_modified_output_count") end
    local outs = {}
    for j = 0, n - 1 do outs[j + 1] = tonumber(L.cadaclysm_blacksmith_history_modified_output_at(h, i, j)) end
    modified[#modified + 1] = { { tonumber(operand[0]), tonumber(id[0]) }, outs }
  end
  for i = 0, L.cadaclysm_blacksmith_history_generated_count(h) - 1 do
    generated[i + 1] = tonumber(L.cadaclysm_blacksmith_history_generated_at(h, i))
  end
  for i = 0, L.cadaclysm_blacksmith_history_deleted_count(h) - 1 do
    if not L.cadaclysm_blacksmith_history_deleted_at(h, i, operand, id) then fail("history_deleted_at") end
    deleted[#deleted + 1] = { tonumber(operand[0]), tonumber(id[0]) }
  end
  return setmetatable({ kept = kept, modified = modified, generated = generated, deleted = deleted }, History)
end

-- An id argument: a whole Lua number from 0 up (ids count up from 1 and never reach 2^53).
local function id_arg(value, what)
  if type(value) ~= "number" or value ~= math.floor(value) or value < 0 or value >= 2 ^ 64 then
    raise(("%s: %s is not an id (a whole number from 0)"):format(what, repr(value)))
  end
  return value
end

local function text_arg(value, what, role)
  if type(value) ~= "string" then raise(("%s: a %s is a string, not %s"):format(what, role, type(value))) end
  return value
end

-- `pairs_or_map` (a table key -> value, or an array of `{key, value}`) in key order.
local function sorted_attributes(pairs_or_map, what)
  if type(pairs_or_map) ~= "table" then raise(what .. ": expected a table, got " .. repr(pairs_or_map)) end
  local list = {}
  for k, v in pairs(pairs_or_map) do
    if type(k) == "number" and type(v) == "table" then
      list[#list + 1] = { v[1], v[2] }
    else
      list[#list + 1] = { k, v }
    end
  end
  for _, kv in ipairs(list) do text_arg(kv[1], what, "key"); text_arg(kv[2], what, "value") end
  table.sort(list, function(a, b) return a[1] < b[1] end)
  return list
end

-- Apply `step(solid, key, value)` for each pair in key order, freeing each intermediate.
local function each_attribute(self, list, step)
  local out = self
  for _, kv in ipairs(list) do
    local ok, nxt = pcall(step, out, kv[1], kv[2])
    if out ~= self then out:close() end
    if not ok then error(nxt, 0) end
    out = nxt
  end
  return out
end

--- This solid tracked: its faces numbered 1..n in face order and its edges 1..m in
--- the edge table's order, each its own origin. Tracking is opt-in and rides on
--- from here: a verb on a tracked solid gives a tracked result, its faces keeping
--- the ids of the faces they lie on and naming those as their origins. A tracked
--- solid comes back as it is.
function Solid:tracked()
  return new_solid(lib().cadaclysm_blacksmith_solid_tracked(self:_h()), "solid_tracked")
end

--- Whether this solid carries face and edge ids (`tracked`, made from a tracked
--- solid, or given an attribute).
function Solid_get.is_tracked(self)
  local tracked = lib().cadaclysm_blacksmith_solid_is_tracked(self:_h())
  if not tracked and last_error() ~= "" then fail("solid_is_tracked") end
  return tracked
end

-- The helpers below take what the C call returned, not its name: each call is spelled out
-- where it is made, so the bindings parity check can see it. They hang off
-- `Solid`, not locals: the main chunk is at LuaJIT's 200-local limit.

function Solid._id_of(id, what)
  if id == 0 then
    if last_error() ~= "" then fail(what) end
    return nil
  end
  return tonumber(id)
end

function Solid._with_id(found, what)
  if found == NONE then
    if last_error() ~= "" then fail(what) end
    return nil
  end
  return found
end

-- `n` is the C origin count; `at(i, operand, id)` the C `_origin_at` for origin `i`.
function Solid._origins(n, at, kind)
  if n == NONE then fail(kind .. "_origin_count") end
  local operand, id = ffi.new("uint32_t[1]"), ffi.new("uint64_t[1]")
  local out = {}
  for i = 0, n - 1 do
    if not at(i, operand, id) then fail(kind .. "_origin_at") end
    out[i + 1] = { tonumber(operand[0]), tonumber(id[0]) }
  end
  return out
end

--- Face `face`'s id (a Lua number), nil where this solid is untracked. An id stays
--- with its face through every verb that keeps the face -- a move, a boolean, a
--- fillet of another edge -- so it names "the same face, through my edits" within
--- a session; a piece split off, a later operand's face whose id an earlier one
--- already has, and a face on no input get fresh ids, the same run after run. Ids
--- are not written to files: to find a face on a model rebuilt or read again, use
--- `face_ref`. Raises `BuildError` for a face the solid does not have.
function Solid:face_id(face)
  return Solid._id_of(lib().cadaclysm_blacksmith_face_id(self:_h(), face), "face_id")
end

--- The face whose id is `id`, nil where no face has it (an untracked solid, a face
--- a verb deleted).
function Solid:face_with_id(id)
  return Solid._with_id(lib().cadaclysm_blacksmith_face_with_id(self:_h(), id_arg(id, "face_with_id")), "face_with_id")
end

--- The input faces face `face` came from, an array of `{operand, id}`: the operand
--- its input's index in the verb's operand order (a boolean's target 0, its tool
--- 1), the id that input face's `face_id`. The face it lies on most first; empty
--- for a face the verb generated (a fillet's round, a split's cut face) or an
--- untracked solid; more than one for a face merged from several (`join` with
--- `merge`). Raises `BuildError` for a face the solid does not have.
function Solid:face_origins(face)
  local L, h = lib(), self:_h()
  return Solid._origins(L.cadaclysm_blacksmith_face_origin_count(h, face),
    function(i, operand, id) return L.cadaclysm_blacksmith_face_origin_at(h, face, i, operand, id) end, "face")
end

--- Edge `edge`'s id (an index into `edges`, from zero), as `face_id`.
function Solid:edge_id(edge)
  return Solid._id_of(lib().cadaclysm_blacksmith_edge_id(self:_h(), edge), "edge_id")
end

--- The edge whose id is `id`, nil where no edge has it.
function Solid:edge_with_id(id)
  return Solid._with_id(lib().cadaclysm_blacksmith_edge_with_id(self:_h(), id_arg(id, "edge_with_id")), "edge_with_id")
end

--- The input edge edge `edge` lies on, as `face_origins`: one `{operand, id}`, or
--- none for a new edge (edge merges are not seen).
function Solid:edge_origins(edge)
  local L, h = lib(), self:_h()
  return Solid._origins(L.cadaclysm_blacksmith_edge_origin_count(h, edge),
    function(i, operand, id) return L.cadaclysm_blacksmith_edge_origin_at(h, edge, i, operand, id) end, "edge")
end

-- `call(handles, n)` is the C `history` or `edge_history` on this solid.
function Solid:_history(what, call, ...)
  local L = lib()
  local n = select("#", ...)
  local handles = ffi.new("const struct CadaclysmBlacksmithSolid *[?]", math.max(n, 1))
  for i = 1, n do handles[i - 1] = solid_handle((select(i, ...)), what) end
  local h = call(handles, n)
  if h == nil then fail(what) end
  local ok, result = pcall(read_history, L, h)
  L.cadaclysm_blacksmith_history_free(h)
  if not ok then error(result, 0) end
  return result
end

--- What the verb that made this solid did to the faces of the solids given --
--- passed in its operand order (`a:cut(b):history(a, b)`) -- read off this
--- solid's ids and origins alone, as a `History`. Raises `BuildError` where this
--- solid or an input is untracked, or an origin names an operand past the inputs.
function Solid:history(...)
  return self:_history("history",
    function(handles, n) return lib().cadaclysm_blacksmith_history(self:_h(), handles, n) end, ...)
end

--- `history` for the edges, by edge id.
function Solid:edge_history(...)
  return self:_history("edge_history",
    function(handles, n) return lib().cadaclysm_blacksmith_edge_history(self:_h(), handles, n) end, ...)
end

-- -- attributes: text on a solid (written to STEP files) and on its faces (in memory)

--- This solid's attributes, an array of `{key, value}` in key order (a copy). A
--- solid's attributes go with it through every verb (a verb's result takes its
--- first operand's) and are written to STEP files as user-defined attributes.
function Solid_get.attributes(self)
  local L, h = lib(), self:_h()
  local n = L.cadaclysm_blacksmith_attribute_count(h)
  if n == 0 and last_error() ~= "" then fail("attribute_count") end
  local out = {}
  for i = 0, n - 1 do
    local k, v = L.cadaclysm_blacksmith_attribute_key_at(h, i), L.cadaclysm_blacksmith_attribute_value_at(h, i)
    if k == nil or v == nil then fail("attributes") end
    out[i + 1] = { ffi.string(k), ffi.string(v) }
  end
  return out
end

--- Attribute `key`, nil where this solid has none.
function Solid:attribute(key)
  local raw = lib().cadaclysm_blacksmith_attribute(self:_h(), text_arg(key, "attribute", "key"))
  if raw == nil then
    if last_error() ~= "" then fail("attribute") end
    return nil
  end
  return ffi.string(raw)
end

--- This solid with attribute `key` set to `value`, over any it had: a new solid,
--- tracked if this one was not. Keys and values are text (no NUL); an empty key is
--- refused.
function Solid:with_attribute(key, value)
  local what = "with_attribute"
  return new_solid(lib().cadaclysm_blacksmith_with_attribute(self:_h(), text_arg(key, what, "key"),
    text_arg(value, what, "value")), what)
end

--- This solid with every attribute given set, in key order: `attributes` a table
--- key -> value, or an array of `{key, value}`.
function Solid:with_attributes(attributes)
  return each_attribute(self, sorted_attributes(attributes, "with_attributes"),
    function(s, k, v) return s:with_attribute(k, v) end)
end

--- This solid without attribute `key`: a new solid, equal to this one where it
--- had none.
function Solid:without_attribute(key)
  local what = "without_attribute"
  return new_solid(lib().cadaclysm_blacksmith_without_attribute(self:_h(), text_arg(key, what, "key")), what)
end

--- Face `face`'s attributes, an array of `{key, value}` in key order (a copy). A
--- face's attributes follow its id: kept through a verb, and copied to every face
--- that names it as an origin (each piece of a split face has its parent's). They
--- stay in memory: no file carries them. Raises `BuildError` for a face the solid
--- does not have.
function Solid:face_attributes(face)
  local L, h = lib(), self:_h()
  local n = L.cadaclysm_blacksmith_face_attribute_count(h, face)
  if n == NONE then fail("face_attribute_count") end
  local out = {}
  for i = 0, n - 1 do
    local k = L.cadaclysm_blacksmith_face_attribute_key_at(h, face, i)
    local v = L.cadaclysm_blacksmith_face_attribute_value_at(h, face, i)
    if k == nil or v == nil then fail("face_attributes") end
    out[i + 1] = { ffi.string(k), ffi.string(v) }
  end
  return out
end

--- Face `face`'s attribute `key`, nil where it has none. Raises `BuildError` for a
--- face the solid does not have.
function Solid:face_attribute(face, key)
  local raw = lib().cadaclysm_blacksmith_face_attribute(self:_h(), face, text_arg(key, "face_attribute", "key"))
  if raw == nil then
    if last_error() ~= "" then fail("face_attribute") end
    return nil
  end
  return ffi.string(raw)
end

--- This solid with face `face`'s attribute `key` set to `value`: a new solid,
--- tracked if this one was not. Refused as `with_attribute`, and for a face the
--- solid does not have.
function Solid:with_face_attribute(face, key, value)
  local what = "with_face_attribute"
  return new_solid(lib().cadaclysm_blacksmith_with_face_attribute(self:_h(), face, text_arg(key, what, "key"),
    text_arg(value, what, "value")), what)
end

--- This solid with every attribute given set on face `face`, in key order:
--- `attributes` as `with_attributes` takes them.
function Solid:with_face_attributes(face, attributes)
  return each_attribute(self, sorted_attributes(attributes, "with_face_attributes"),
    function(s, k, v) return s:with_face_attribute(face, k, v) end)
end

--- This solid without face `face`'s attribute `key`: a new solid, equal to this
--- one where the face had none.
function Solid:without_face_attribute(face, key)
  local what = "without_face_attribute"
  return new_solid(lib().cadaclysm_blacksmith_without_face_attribute(self:_h(), face, text_arg(key, what, "key")), what)
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
--- `tolerance` defaults to 1e-6; `progress` as `join`'s. `radius_end` (spline edges only)
--- runs the radius linearly from `radius` to it in arc length along the edge, `radius` at the
--- end where the edge's curve starts; nil, or equal to `radius`, is the constant fillet.
function Solid:fillet(edges, radius, tolerance, progress, radius_end)
  if tolerance == nil then tolerance = 1e-6 end
  local arr, n = edge_indices(edges, "fillet")
  local a = self:_h()
  if radius_end ~= nil and radius_end ~= radius then
    return new_solid(lib().cadaclysm_blacksmith_fillet_varying(a, arr, n, number(radius, "fillet"),
      number(radius_end, "fillet"), tolerance))
  end
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

-- An intersection handle `h` (from `Solid:intersect` or `Clash:intersect`) copied out into an
-- `Intersection`, and freed on every path.
function Intersection._read(L, h)
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
--- ring closed without repeating its first point) -- empty for a partial overlap of curved faces
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

-- ---- clash detection ----------------------------------------------------------------------

-- In a block of its own, as the R-tree's: the main chunk is at LuaJIT's limit of 200 live
-- locals, so only `M.Clash`, `Collider:clash`, `M.clash` and swept clash's `M.SweptClash`,
-- `Collider:swept_clash` and `M.swept_clash` leave it (and, for `Assembly:swept_clash`, the
-- row reader and `allowed`'s check as `M._swept_clashes_of` and `M._allowed_pairs`).
do

--- One pair a clash call (`Collider:clash`, `clash`) found: `a`, `b` the part indices (for one
--- set or a collider `a < b`; for two sets `a` indexes the first and `b` the second), `kind` one
--- of "penetrating", "touching" (the boundaries within the tolerance of each other), "too_close"
--- (apart by more than the tolerance but less than the clearance) or "refused" (the pair could
--- not be decided; `text` says why).
---
--- `distance` is the gap between the two boundaries (0 for a penetrating or refused pair);
--- `on_a` and `on_b` are world points {x, y, z} -- the closest pair, or for a penetrating pair
--- the centre of the overlap's world box (the origin for a refused one). `kind_a`, `index_a`,
--- `edge_a` (and `_b`) say what each point lies on exactly as `Closest` does -- "face", "edge"
--- or "vertex", the kernel's id, and the fillet-table index (nil for a face, a vertex or an edge
--- the table does not hold) -- and for a penetrating or refused pair `kind_a`/`kind_b` are
--- "none" with `index_*` and `edge_*` nil. `refined` is true where the distance is measured on
--- the exact surfaces. `depth` is the thinnest side of a penetrating pair's overlap box (0
--- otherwise).
---
--- `solid()` rebuilds a penetrating pair's shared volume now; `intersect()` where the two parts
--- cross or coincide (any pair but a refused one). Both use the placement the pair was found
--- at. Every row of one call shares the clashes handle (`ffi.gc`'d cdata), so it lives until
--- the last of them is collected, and is freed only then.
---@class Clash
---@field a integer
---@field b integer
---@field kind string          "penetrating", "touching", "too_close" or "refused"
---@field distance number
---@field on_a number[]        three: the point on `a`
---@field on_b number[]        three: the point on `b`
---@field kind_a string        "face", "edge", "vertex" or "none"
---@field index_a integer|nil  nil for kind "none"
---@field edge_a integer|nil   the fillet-table edge, nil if none
---@field kind_b string
---@field index_b integer|nil
---@field edge_b integer|nil
---@field refined boolean
---@field depth number
---@field text string
local Clash = {}
class(Clash)
M.Clash = Clash

-- One `CadaclysmBlacksmithClash` copied out: its strings borrow from the handle, so they are
-- copied here; `clashes` is the shared owner every row holds.
function Clash.of(raw, clashes, index)
  local kind_a, kind_b = text(raw.kind_a), text(raw.kind_b)
  local index_a, edge_a, index_b, edge_b
  if kind_a ~= "none" then
    index_a = tonumber(raw.index_a)
    if raw.edge_a ~= NONE then edge_a = tonumber(raw.edge_a) end
  end
  if kind_b ~= "none" then
    index_b = tonumber(raw.index_b)
    if raw.edge_b ~= NONE then edge_b = tonumber(raw.edge_b) end
  end
  return setmetatable({
    a = tonumber(raw.a), b = tonumber(raw.b), kind = text(raw.kind), distance = tonumber(raw.distance),
    on_a = { raw.on_a[0], raw.on_a[1], raw.on_a[2] },
    on_b = { raw.on_b[0], raw.on_b[1], raw.on_b[2] },
    kind_a = kind_a, index_a = index_a, edge_a = edge_a,
    kind_b = kind_b, index_b = index_b, edge_b = edge_b,
    refined = raw.refined ~= 0, depth = tonumber(raw.depth), text = text(raw.text),
    _clashes = clashes, _index = index,
  }, Clash)
end

--- The exact shared volume of this penetrating pair at the placement it was found at, as a new
--- solid. Raises for a pair that is not penetrating.
---@return Solid
function Clash:solid()
  return new_solid(lib().cadaclysm_blacksmith_clashes_solid(self._clashes, self._index), "clashes_solid")
end

--- Where this pair's two parts cross or coincide at the placement it was found at, as
--- `Solid:intersect` reports it (a touching pair's shared face is an `Overlap`). Raises for a
--- refused pair.
---@return Intersection
function Clash:intersect()
  local L = lib()
  local h = L.cadaclysm_blacksmith_clashes_intersect(self._clashes, self._index)
  if h == nil then fail("clashes_intersect") end
  return Intersection._read(L, h)
end

Clash.__tostring = function(self)
  return ("Clash(a=%d, b=%d, kind=%s, distance=%.9g)"):format(self.a, self.b, repr(self.kind), self.distance)
end

-- A clashes handle read out into rows, each holding the one `ffi.gc`'d owner; freed at once if
-- there are none, and on a failing read.
local function clashes_of(h)
  local L = lib()
  local count = tonumber(L.cadaclysm_blacksmith_clashes_count(h))
  if count == 0 then
    L.cadaclysm_blacksmith_clashes_free(h)
    return {}
  end
  local kept = ffi.gc(h, function(hh) lib().cadaclysm_blacksmith_clashes_free(hh) end)
  local rows, raw = {}, ffi.new("CadaclysmBlacksmithClash")
  for i = 0, count - 1 do
    if not L.cadaclysm_blacksmith_clashes_at(kept, i, raw) then
      local reason = last_error()
      ffi.gc(kept, nil)
      L.cadaclysm_blacksmith_clashes_free(kept)
      error(setmetatable({ message = reason ~= "" and reason or "clashes_at", ids = {} }, BuildError), 2)
    end
    rows[#rows + 1] = Clash.of(raw, kept, i)
  end
  return rows
end

--- Every pair of parts that penetrates, touches or lies within `clearance` (nil is 0) of the
--- other, as `Clash` rows in pair order, with each group placed at its matching frame in
--- `frames` (as for `check`). `clearance` is zero or more, in model units: a pair apart by more
--- than the collider's tolerance but less than it is "too_close". `share` as for `check`. The
--- collider keeps each part's closest mesh (at a third of its tolerance) for its lifetime once a
--- pair needed one. Raises for a negative or non-finite `clearance`, the wrong number of frames
--- or a bad `share`.
---@param frames table[]
---@param clearance number|nil
---@param share integer[]|nil  {k, n}
---@return Clash[]
function Collider:clash(frames, clearance, share)
  local h = self:_h()
  if clearance == nil then clearance = 0 end
  clearance = number(clearance, "collider_clash")
  local n = #frames
  local flat = ffi.new("double[?]", math.max(n * 12, 1))
  for i, f in ipairs(frames) do
    local fv = frame_arg(f)
    for k = 0, 11 do flat[(i - 1) * 12 + k] = fv[k] end
  end
  local share_k, share_n = 0, 0
  if share ~= nil then share_k, share_n = share[1], share[2] end
  local found = lib().cadaclysm_blacksmith_collider_clash(h, flat, n, clearance, share_k, share_n)
  if found == nil then fail("collider_clash") end
  return clashes_of(found)
end

-- A list of solids as a `const Solid *` array and its count.
local function solid_array(solids)
  local out = ffi.new("const struct CadaclysmBlacksmithSolid *[?]", math.max(#solids, 1))
  for i, s in ipairs(solids) do out[i - 1] = solid_handle(s, "clash") end
  return out, #solids
end

-- `allowed`, flat {a0, b0, a1, b1, ...} as `Collider`'s, as a uint32_t array and its pair count:
-- an odd length, or an entry that is not a whole number from 0 to 4294967295, refused in the
-- library's words, with the call's prefix `what` (nil is "clash"), before it is asked.
local function allowed_pairs(allowed, what)
  what = what or "clash"
  if allowed == nil then allowed = {} end
  local n = #allowed
  if n % 2 ~= 0 then raise(("%s: allowed is %d numbers, not pairs"):format(what, n)) end
  local function index(v)
    return type(v) == "number" and v >= 0 and v <= 4294967295 and v == math.floor(v)
  end
  local out = ffi.new("uint32_t[?]", math.max(n, 1))
  for i = 1, n, 2 do
    local a, b = allowed[i], allowed[i + 1]
    if not (index(a) and index(b)) then
      raise(("%s: allowed pair (%s, %s) is not two indices"):format(what, repr(a), repr(b)))
    end
    out[i - 1], out[i] = a, b
  end
  return out, n / 2
end

--- Every pair of `parts` -- or, with `others`, every part of `parts` against every part of
--- `others` -- that penetrates, touches or lies within `clearance` (nil is 0) of the other, as
--- `Clash` rows, the solids as they stand. `tolerance` is the meshing tolerance, absolute (nil is
--- 0.05). `allowed` pairs of part indices never tested (designed contacts), flat as `Collider`'s:
--- {a0, b0, a1, b1, ...}; with `others` a pair is (index in `parts`, index in `others`). In a row
--- `a` indexes `parts` and `b` indexes `others` (or `parts` again). Raises for an empty `others`
--- (nil is one set), a negative or non-finite `clearance`, a `tolerance` not positive and finite,
--- an `allowed` of odd length, an entry not an index or out of range, or a part that is not a
--- closed solid.
---@param parts Solid[]
---@param others Solid[]|nil
---@param clearance number|nil
---@param tolerance number|nil
---@param allowed integer[]|nil
---@return Clash[]
function M.clash(parts, others, clearance, tolerance, allowed)
  if clearance == nil then clearance = 0 end
  if tolerance == nil then tolerance = 0.05 end
  clearance, tolerance = number(clearance, "clash"), number(tolerance, "clash")
  local a, a_count = solid_array(parts)
  local b, b_count = nil, 0
  if others ~= nil then
    if #others == 0 then raise("clash: an empty set") end
    b, b_count = solid_array(others)
  end
  local pairs_arr, pair_count = allowed_pairs(allowed)
  local found = lib().cadaclysm_blacksmith_clash(a, a_count, b, b_count, tolerance, clearance, pairs_arr, pair_count)
  if found == nil then fail("clash") end
  return clashes_of(found)
end

-- ---- swept clash --------------------------------------------------------------------------

--- One pair a swept clash call (`Collider:swept_clash`, `swept_clash`) found: `a`, `b` the part
--- indices (for one set or a collider `a < b`; for two sets `a` indexes the first and `b` the
--- second). `first_time` is the first time the pair came within the clearance, in pose units
--- (pose `k` at time `k`, from 0; for a refused pair the time it was refused at), and `first`
--- the `Clash` there -- its kind, distance, points, features and depth, at the frames the motion
--- places the parts at that time, so `first:solid()` and `first:intersect()` rebuild the contact
--- there. The rows of one call share one clashes handle, as `clash`'s do. `intervals` are the
--- time ranges the pair stays in clash, {start, end} pairs, ascending and disjoint (none for a
--- refused pair).
---@class SweptClash
---@field a integer
---@field b integer
---@field first_time number
---@field first Clash
---@field intervals number[][]  {start, end} pairs
local SweptClash = {}
class(SweptClash)
M.SweptClash = SweptClash

SweptClash.__tostring = function(self)
  local spans = {}
  for i, s in ipairs(self.intervals) do spans[i] = ("{%.9g, %.9g}"):format(s[1], s[2]) end
  return ("SweptClash(a=%d, b=%d, first_time=%.9g, kind=%s, intervals={%s})")
    :format(self.a, self.b, self.first_time, repr(self.first.kind), table.concat(spans, ", "))
end

-- A swept clashes handle read out into rows and freed at once; each row's `first` a `Clash` of
-- the handle's first rows, read by `clashes_of`, which own their own handle. A failing read
-- frees both handles.
local function swept_clashes_of(h)
  local L = lib()
  local count = tonumber(L.cadaclysm_blacksmith_swept_clashes_count(h))
  if count == 0 then
    L.cadaclysm_blacksmith_swept_clashes_free(h)
    return {}
  end
  local function refuse(what, firsts)
    local reason = last_error()
    if firsts then
      local owner = firsts[1]._clashes
      ffi.gc(owner, nil)
      L.cadaclysm_blacksmith_clashes_free(owner)
    end
    L.cadaclysm_blacksmith_swept_clashes_free(h)
    error(setmetatable({ message = reason ~= "" and reason or what, ids = {} }, BuildError), 3)
  end
  local f = L.cadaclysm_blacksmith_swept_clashes_firsts(h)
  if f == nil then refuse("swept_clashes_firsts") end
  local ok, firsts = pcall(clashes_of, f)
  if not ok then
    L.cadaclysm_blacksmith_swept_clashes_free(h)
    error(firsts, 2)
  end
  local rows, raw, span = {}, ffi.new("CadaclysmBlacksmithSweptClash"), ffi.new("double[2]")
  for i = 0, count - 1 do
    if not L.cadaclysm_blacksmith_swept_clashes_at(h, i, raw) then refuse("swept_clashes_at", firsts) end
    local intervals = {}
    for k = 0, tonumber(raw.interval_count) - 1 do
      if not L.cadaclysm_blacksmith_swept_clashes_interval(h, i, k, span) then
        refuse("swept_clashes_interval", firsts)
      end
      intervals[#intervals + 1] = { span[0], span[1] }
    end
    rows[#rows + 1] = setmetatable({
      a = tonumber(raw.a), b = tonumber(raw.b), first_time = tonumber(raw.first_time),
      first = firsts[i + 1], intervals = intervals,
    }, SweptClash)
  end
  L.cadaclysm_blacksmith_swept_clashes_free(h)
  return rows
end

-- `poses`, a list of poses each a list of frames (as `Collider:clash` takes them), flattened
-- pose by pose into one double array; with each pose's frame count.
local function poses_arg(poses)
  local counts, total = {}, 0
  for k, pose in ipairs(poses) do
    counts[k] = #pose
    total = total + #pose
  end
  local flat, at = ffi.new("double[?]", math.max(total * 12, 1)), 0
  for _, pose in ipairs(poses) do
    for _, f in ipairs(pose) do
      local fv = frame_arg(f)
      for k = 0, 11 do flat[at + k] = fv[k] end
      at = at + 12
    end
  end
  return flat, counts
end

--- Every pair of parts that penetrates, touches or comes within `clearance` (nil is 0) of the
--- other anywhere on the path through `poses` -- not only at the poses -- as `SweptClash` rows
--- in pair order. `poses` is two or more poses, each the `frames` `clash` takes (one frame per
--- group). Between two poses each group moves rigidly about the centre of its rest box: that
--- point on the straight line between its two places, the rotation turning at a steady rate the
--- shorter way round. Time runs in pose units, pose `k` (from 0) at time `k`.
---
--- No moment where the true gap is below `clearance` less the collider's tolerance (for
--- clearance 0: no penetration deeper than the tolerance) falls between two steps. `resolution`
--- (nil is 1e-3; in (0, 1], a fraction of a segment) is how closely an interval's end is found;
--- `max_steps` (nil is 100000) the pose-wise tests one pair may take -- a pair that needs more
--- is a "refused" row. `share` as for `check`, over the pairs whose swept boxes meet. The pose
--- caches `check` and `clash` keep are neither read nor filled. Raises for fewer than two
--- poses, the wrong number of frames in a pose, a bad frame, `clearance`, `resolution` or
--- `share`, or `max_steps` 0.
---@param poses table[][]
---@param clearance number|nil
---@param resolution number|nil
---@param max_steps integer|nil
---@param share integer[]|nil  {k, n}
---@return SweptClash[]
function Collider:swept_clash(poses, clearance, resolution, max_steps, share)
  local h = self:_h()
  if clearance == nil then clearance = 0 end
  if resolution == nil then resolution = 1e-3 end
  if max_steps == nil then max_steps = 100000 end
  clearance = number(clearance, "collider_swept_clash")
  resolution = number(resolution, "collider_swept_clash")
  max_steps = number(max_steps, "collider_swept_clash")
  local flat, counts = poses_arg(poses)
  local frame_count = counts[1] or 0
  local ragged = false
  for _, n in ipairs(counts) do ragged = ragged or n ~= frame_count end
  if ragged then
    -- C reads every pose at one frame count: say the first pose that is off, in the kernel's words
    local groups = self.group_count
    for _, n in ipairs(counts) do
      if n ~= groups then raise(("collider_swept_clash: %d frames for %d groups"):format(n, groups)) end
    end
  end
  local share_k, share_n = 0, 0
  if share ~= nil then share_k, share_n = share[1], share[2] end
  local found = lib().cadaclysm_blacksmith_collider_swept_clash(h, flat, #counts, frame_count, clearance, resolution,
    max_steps, share_k, share_n)
  if found == nil then fail("collider_swept_clash") end
  return swept_clashes_of(found)
end

--- Every pair of `parts` -- or, with `others`, every part of `parts` against every part of
--- `others` -- that penetrates, touches or comes within `clearance` (nil is 0) of the other
--- anywhere on a path, as `SweptClash` rows. Each part is its own group: pose `k` of `poses` is
--- one frame per part of `parts`, and pose `k` of `other_poses` one per part of `others` (the two
--- go together, nil together for one set, and have as many poses). The motion between poses,
--- the guarantee, `resolution` and `max_steps` are `Collider:swept_clash`'s. `tolerance` is the
--- meshing tolerance, absolute (nil is 0.05). `allowed` pairs of part indices never tested,
--- flat as `clash`'s: {a0, b0, a1, b1, ...}; with `others` a pair is (index in `parts`, index in
--- `others`). In a row `a` indexes `parts` and `b` indexes `others` (or `parts` again). Raises as
--- `Collider:swept_clash` does, and for `others` without `other_poses` (or the reverse), pose
--- counts that differ, a pose with the wrong number of frames, an empty `others`, an `allowed`
--- `clash` refuses, an index out of range or a part that is not a closed solid.
---@param parts Solid[]
---@param poses table[][]
---@param others Solid[]|nil
---@param other_poses table[][]|nil
---@param clearance number|nil
---@param tolerance number|nil
---@param resolution number|nil
---@param max_steps integer|nil
---@param allowed integer[]|nil
---@return SweptClash[]
function M.swept_clash(parts, poses, others, other_poses, clearance, tolerance, resolution, max_steps, allowed)
  if (others == nil) ~= (other_poses == nil) then raise("swept_clash: others and other_poses go together") end
  if clearance == nil then clearance = 0 end
  if tolerance == nil then tolerance = 0.05 end
  if resolution == nil then resolution = 1e-3 end
  if max_steps == nil then max_steps = 100000 end
  clearance, tolerance = number(clearance, "swept_clash"), number(tolerance, "swept_clash")
  resolution, max_steps = number(resolution, "swept_clash"), number(max_steps, "swept_clash")
  local a, a_count = solid_array(parts)
  local flat_a, counts_a = poses_arg(poses)
  local flat_b, counts_b, b_parts = nil, {}, 0
  if other_poses ~= nil then
    flat_b, counts_b = poses_arg(other_poses)
    b_parts = #others
    if #counts_b ~= #counts_a then
      raise(("swept_clash: %d poses for set a, %d for set b"):format(#counts_a, #counts_b))
    end
  end
  -- C reads each set's poses at its part count: the kernel's own checks, in its order
  for _, set in ipairs({ { "a", counts_a, a_count }, { "b", counts_b, b_parts } }) do
    for k, n in ipairs(set[2]) do
      if n ~= set[3] then
        raise(("swept_clash: pose %d of set %s has %d frames for %d parts"):format(k - 1, set[1], n, set[3]))
      end
    end
  end
  local b, b_count = nil, 0
  if others ~= nil then
    if #others == 0 then raise("swept_clash: an empty set") end
    b, b_count = solid_array(others)
  end
  local pairs_arr, pair_count = allowed_pairs(allowed, "swept_clash")
  local found = lib().cadaclysm_blacksmith_swept_clash(a, a_count, flat_a, b, b_count, flat_b, #counts_a, tolerance,
    clearance, resolution, max_steps, pairs_arr, pair_count)
  if found == nil then fail("swept_clash") end
  return swept_clashes_of(found)
end

-- For `Assembly:swept_clash`, defined with the assemblies, outside this block.
M._swept_clashes_of = swept_clashes_of
M._allowed_pairs = allowed_pairs

end

-- ---- wall thickness -----------------------------------------------------------------------

-- In a block of its own, as clash's: the main chunk is at LuaJIT's limit of 200 live locals,
-- so only `M.ThicknessGauge`, the four record classes, `M.thickness`, `M.mesh_thickness` and
-- `Solid:thickness_at_face` leave it.
do

--- One wall-thickness reading on a solid (`ThicknessGauge:thickness`, `:thickness_at`, `M.thickness`).
--- `point` lies on face `face` of body `body` (the body's index in the gauge): at vertex
--- `vertex` of that body's measuring mesh (`ThicknessGauge:mesh`, from zero), or `vertex` nil for
--- a reading at a point. `thickness` is the nearest-opposing-wall rule on the measuring mesh, to
--- `opposite` on face `opposite_face` of body `opposite_body`; `knife` marks a knife edge
--- (thickness 0, `opposite` equal to `point`). `exact_opposite` is `opposite` moved onto its
--- exact face where its foot lies within the tolerance and inside the face's trims,
--- `exact_thickness` the distance to it. `sphere` is the diameter of the largest ball tangent at
--- `point` that holds none of the surfaces, nil where none under the maximum does (0 on a knife
--- edge). Points are {x, y, z}.
---@class Thickness
---@field body integer
---@field vertex integer|nil
---@field face integer
---@field point number[]
---@field thickness number
---@field opposite number[]
---@field opposite_body integer
---@field opposite_face integer
---@field knife boolean
---@field exact_thickness number
---@field exact_opposite number[]
---@field sphere number|nil
local Thickness = {}
class(Thickness)
M.Thickness = Thickness

local function triple_of(p) return { p[0], p[1], p[2] } end

-- One `CadaclysmBlacksmithThickness` copied out.
function Thickness.of(raw)
  return setmetatable({
    body = tonumber(raw.body),
    vertex = raw.vertex ~= NONE and tonumber(raw.vertex) or nil,
    face = tonumber(raw.face),
    point = triple_of(raw.point),
    thickness = raw.thickness,
    opposite = triple_of(raw.opposite),
    opposite_body = tonumber(raw.opposite_body),
    opposite_face = tonumber(raw.opposite_face),
    knife = raw.knife == true,
    exact_thickness = raw.exact_thickness,
    exact_opposite = triple_of(raw.exact_opposite),
    sphere = raw.sphere == raw.sphere and raw.sphere or nil,
  }, Thickness)
end

Thickness.__tostring = function(self)
  return ("Thickness(body=%d, vertex=%s, face=%d, thickness=%.9g, opposite_body=%d, knife=%s)"):format(
    self.body, tostring(self.vertex), self.face, self.thickness, self.opposite_body, tostring(self.knife))
end

--- A face's thickness, found (`ThicknessGauge:thickness_at_face`, `Solid:thickness_at_face`; where
--- nothing is found those answer nil): `thickness` the median of the face's vertex readings (or
--- the reading at `at`), `min` and `max` their extremes, `uniform` whether `max - min` is within
--- the gauge's tolerance.
---@class FaceThickness
---@field thickness number
---@field min number
---@field max number
---@field uniform boolean
local FaceThickness = {}
class(FaceThickness)
M.FaceThickness = FaceThickness

FaceThickness.__tostring = function(self)
  return ("FaceThickness(thickness=%.9g, min=%.9g, max=%.9g, uniform=%s)"):format(
    self.thickness, self.min, self.max, tostring(self.uniform))
end

--- A body's measuring mesh (`ThicknessGauge:mesh`), copied out of the gauge: `positions` and
--- `normals` one {x, y, z} per vertex (unit, outward) -- a reading's `vertex` indexes them from
--- zero, so `positions[vertex + 1]`; no vertex is shared between two faces -- `triangles` three
--- vertex indices (from zero) each, and `faces` the B-rep face of each triangle.
---@class ThicknessMesh
---@field positions number[][]
---@field normals number[][]
---@field triangles integer[][]
---@field faces integer[]
local ThicknessMesh = {}
class(ThicknessMesh)
M.ThicknessMesh = ThicknessMesh

ThicknessMesh.__tostring = function(self)
  return ("ThicknessMesh(vertices=%d, triangles=%d)"):format(#self.positions, #self.triangles)
end

--- One reading on a plain mesh (`M.mesh_thickness`): vertex `vertex` of mesh `mesh` (both from
--- zero), at `point`, reads `thickness` to `opposite` on triangle `opposite_triangle` of mesh
--- `opposite_mesh`. `knife`: a knife edge, thickness 0 and `opposite` equal to `point`.
---@class MeshThickness
---@field mesh integer
---@field vertex integer
---@field thickness number
---@field point number[]
---@field opposite number[]
---@field opposite_mesh integer
---@field opposite_triangle integer
---@field knife boolean
local MeshThickness = {}
class(MeshThickness)
M.MeshThickness = MeshThickness

function MeshThickness.of(raw)
  return setmetatable({
    mesh = tonumber(raw.mesh), vertex = tonumber(raw.vertex), thickness = raw.thickness,
    point = triple_of(raw.point), opposite = triple_of(raw.opposite),
    opposite_mesh = tonumber(raw.opposite_mesh), opposite_triangle = tonumber(raw.opposite_triangle),
    knife = raw.knife == true,
  }, MeshThickness)
end

MeshThickness.__tostring = function(self)
  return ("MeshThickness(mesh=%d, vertex=%d, thickness=%.9g, opposite_mesh=%d, knife=%s)"):format(
    self.mesh, self.vertex, self.thickness, self.opposite_mesh, tostring(self.knife))
end

-- Rows read out of the list `h` by `count`/`at` into a scratch struct `ctype`, copied with `make`,
-- and the list `free`d on every path: a null `h` raises `what`'s refusal, a failing `at` raises
-- `at_what`'s.
local function read_rows(h, what, ctype, count, at, free, at_what, make)
  if h == nil then fail(what) end
  local ok, rows = pcall(function()
    local raw, out = ffi.new(ctype), {}
    for i = 0, tonumber(count(h)) - 1 do
      if not at(h, i, raw) then fail(at_what) end
      out[#out + 1] = make(raw)
    end
    return out
  end)
  free(h)
  if not ok then error(rows, 0) end
  return rows
end

local function thicknesses_of(h, what)
  return read_rows(h, what, "CadaclysmBlacksmithThickness",
    function(l) return lib().cadaclysm_blacksmith_thicknesses_count(l) end,
    function(l, i, raw) return lib().cadaclysm_blacksmith_thicknesses_at(l, i, raw) end,
    function(l) lib().cadaclysm_blacksmith_thicknesses_free(l) end, "thicknesses_at", Thickness.of)
end

-- A point as the C ABI takes it, three doubles -- refused by `what`'s name when it is not three
-- numbers (a NaN is the library's to refuse, and it does).
local function point3(point, what)
  if type(point) ~= "table" then raise(("%s: a point is 3 numbers, got %s"):format(what, repr(point))) end
  if #point ~= 3 then raise(("%s: a point is 3 numbers, got %d"):format(what, #point)) end
  local out = ffi.new("double[3]")
  for i = 1, 3 do
    if type(point[i]) ~= "number" then raise(("%s: a point is 3 numbers, got %s"):format(what, repr(point[i]))) end
    out[i - 1] = point[i]
  end
  return out
end

-- A body or face index as the C ABI's `uint32_t`: a whole number from 0 to 4294967295, refused
-- by `call`'s name before the library is asked -- never wrapped, truncated or coerced by the FFI.
local function index_u32(value, call, name)
  if type(value) ~= "number" or value ~= math.floor(value) then
    raise(("%s: %s must be a whole number, got %s"):format(call, name, repr(value)))
  end
  if value < 0 or value > 4294967295 then raise(("%s: %s is out of range: %.14g"):format(call, name, value)) end
  return value
end

-- A figure the call cannot do without: nil is refused in words, anything else as `number` does.
local function required(v, name, what)
  if v == nil then raise(("%s: the %s is required"):format(what, name)) end
  return number(v, what)
end

--- Wall thickness (the nearest-opposing-wall rule: each vertex reads to the nearest triangle that
--- faces against one of its own faces, with the vertex behind it) over `solids`, measured
--- against each other: each solid meshed once at `tolerance` -- absolute, in model units (nil is
--- 0.01) -- then asked as often as needed. A reading's `body` is the solid's index in `solids`
--- from zero. The gauge holds its own references to the bodies, so it answers on after they are
--- closed. `close()` frees this handle; so does the garbage collector. Raises for a `tolerance`
--- not positive and finite. `#gauge` is the body count where LuaJIT is built with Lua 5.2
--- compatibility; `gauge.body_count` always is.
---@class ThicknessGauge
local ThicknessGauge = {}
local ThicknessGauge_get = {}
class(ThicknessGauge, ThicknessGauge_get)
callable(ThicknessGauge)
M.ThicknessGauge = ThicknessGauge

local function free_thickness_gauge(h) lib().cadaclysm_blacksmith_thickness_gauge_free(h) end

---@param solids Solid[]
---@param tolerance number|nil
---@return ThicknessGauge
function ThicknessGauge.new(solids, tolerance)
  if tolerance == nil then tolerance = 0.01 end
  if type(solids) ~= "table" then raise("ThicknessGauge: expected a list of Solids, got " .. repr(solids)) end
  local n = #solids
  local parts = ffi.new("const struct CadaclysmBlacksmithSolid *[?]", math.max(n, 1))
  for i, s in ipairs(solids) do parts[i - 1] = solid_handle(s, "thickness_gauge") end
  local h = lib().cadaclysm_blacksmith_thickness_gauge_new(parts, n, number(tolerance, "thickness_gauge_new"))
  checked(h, "thickness_gauge_new")
  return setmetatable({ _ptr = ffi.gc(h, free_thickness_gauge) }, ThicknessGauge)
end

--- Free the gauge. Idempotent; a mesh already read out of it stays good.
function ThicknessGauge:close()
  local h = rawget(self, "_ptr")
  if h ~= nil then
    self._ptr = nil
    ffi.gc(h, nil)
    lib().cadaclysm_blacksmith_thickness_gauge_free(h)
  end
end

function ThicknessGauge:_h()
  local h = rawget(self, "_ptr")
  if h == nil then raise("thickness_gauge: closed") end
  return h
end

--- How many bodies the gauge measures: the length of the `solids` it was built from.
function ThicknessGauge_get.body_count(self)
  return tonumber(lib().cadaclysm_blacksmith_thickness_gauge_body_count(self:_h()))
end

ThicknessGauge.__len = function(self) return self.body_count end

--- The tolerance the gauge meshed its bodies at.
function ThicknessGauge_get.tolerance(self)
  local value = lib().cadaclysm_blacksmith_thickness_gauge_tolerance(self:_h())
  if value ~= value then fail("thickness_gauge_tolerance") end
  return value
end

ThicknessGauge.__tostring = function(self)
  if rawget(self, "_ptr") == nil then return "ThicknessGauge(closed)" end
  return ("ThicknessGauge(bodies=%d, tolerance=%g)"):format(self.body_count, self.tolerance)
end

--- One `Thickness` per measuring-mesh vertex that reads within `maximum` (positive and finite),
--- by body then vertex; vertices whose interior angle is under `sharp_angle` radians (nil is 0)
--- are knife edges. Raises for a bad limit.
---@param maximum number
---@param sharp_angle number|nil
---@return Thickness[]
function ThicknessGauge:thickness(maximum, sharp_angle)
  local h = self:_h()
  maximum = required(maximum, "maximum", "thickness_gauge_measure")
  local sharp = number(sharp_angle == nil and 0 or sharp_angle, "thickness_gauge_measure")
  return thicknesses_of(lib().cadaclysm_blacksmith_thickness_gauge_measure(h, maximum, sharp),
    "thickness_gauge_measure")
end

--- The reading at `point`'s foot on face `face` of body `body` (its `vertex` nil), or nil where
--- the foot lies off the face or the wall is thicker than `maximum`. Raises for a body or face
--- past the end, a point not finite or a bad limit.
---@param body integer
---@param face integer
---@param point number[]
---@param maximum number
---@param sharp_angle number|nil
---@return Thickness|nil
function ThicknessGauge:thickness_at(body, face, point, maximum, sharp_angle)
  local h = self:_h()
  body, face = index_u32(body, "thickness_gauge_at", "body"), index_u32(face, "thickness_gauge_at", "face")
  local p = point3(point, "thickness_gauge_at")
  maximum = required(maximum, "maximum", "thickness_gauge_at")
  local sharp = number(sharp_angle == nil and 0 or sharp_angle, "thickness_gauge_at")
  local rows = thicknesses_of(lib().cadaclysm_blacksmith_thickness_gauge_at(h, body, face, p, maximum, sharp),
    "thickness_gauge_at")
  return rows[1]
end

--- One thickness for face `face` of body `body`: measured at `at`'s foot on the face or, with `at`
--- nil, over the face's vertices; the other bodies are measured with it. nil where nothing is
--- found (nothing reads under `maximum`, or `at`'s foot lies off the face). `maximum` has no
--- default. Raises for a body or face past the end, an `at` not finite or a bad maximum.
---@param body integer
---@param face integer
---@param at number[]|nil
---@param maximum number
---@return FaceThickness|nil
function ThicknessGauge:thickness_at_face(body, face, at, maximum)
  local h = self:_h()
  body, face = index_u32(body, "thickness_gauge_face", "body"), index_u32(face, "thickness_gauge_face", "face")
  local at_arr = nil
  if at ~= nil then at_arr = point3(at, "thickness_gauge_face") end
  maximum = required(maximum, "maximum", "thickness_gauge_face")
  local out = ffi.new("CadaclysmBlacksmithFaceThickness")
  if not lib().cadaclysm_blacksmith_thickness_gauge_face(h, body, face, at_arr, maximum, out) then
    fail("thickness_gauge_face")
  end
  if out.found ~= true then return nil end
  return setmetatable({ thickness = out.thickness, min = out.min, max = out.max, uniform = out.uniform == true },
    FaceThickness)
end

--- Body `body`'s measuring mesh, copied out (it outlives the gauge). Raises for a body past the end.
---@param body integer
---@return ThicknessMesh
function ThicknessGauge:mesh(body)
  local h = self:_h()
  body = index_u32(body, "thickness_gauge_mesh", "body")
  local raw = ffi.new("CadaclysmBlacksmithThicknessMesh")
  if not lib().cadaclysm_blacksmith_thickness_gauge_mesh(h, body, raw) then fail("thickness_gauge_mesh") end
  local n, t = tonumber(raw.vertex_count), tonumber(raw.triangle_count)
  local positions, normals, triangles, faces = {}, {}, {}, {}
  for i = 0, n - 1 do
    positions[i + 1] = { raw.positions[3 * i], raw.positions[3 * i + 1], raw.positions[3 * i + 2] }
    normals[i + 1] = { raw.normals[3 * i], raw.normals[3 * i + 1], raw.normals[3 * i + 2] }
  end
  for i = 0, t - 1 do
    triangles[i + 1] = { tonumber(raw.indices[3 * i]), tonumber(raw.indices[3 * i + 1]), tonumber(raw.indices[3 * i + 2]) }
    faces[i + 1] = tonumber(raw.faces[i])
  end
  -- `raw` borrows from the gauge's memory: the copy loops allocate, so the gauge (and with it
  -- the finaliser) must stay reachable until they are done -- a real use of it, not a local.
  self:_h()
  return setmetatable({ positions = positions, normals = normals, triangles = triangles, faces = faces },
    ThicknessMesh)
end

-- `body` of a `ThicknessGauge` on `solids` used once and closed on every path.
local function with_gauge(solids, tolerance, use)
  local gauge = ThicknessGauge.new(solids, tolerance)
  local ok, result = pcall(use, gauge)
  gauge:close()
  if not ok then error(result, 0) end
  return result
end

--- `ThicknessGauge(solids, tolerance):thickness(maximum, sharp_angle)` on a gauge used once and
--- freed: every reading within `maximum` on the solids, measured against each other.
---@param solids Solid[]
---@param maximum number
---@param sharp_angle number|nil
---@param tolerance number|nil
---@return Thickness[]
function M.thickness(solids, maximum, sharp_angle, tolerance)
  return with_gauge(solids, tolerance, function(g) return g:thickness(maximum, sharp_angle) end)
end

--- One thickness for face `face` of this solid alone, on a `ThicknessGauge` meshed at `tolerance`
--- (nil is 0.01), used once and freed -- build the gauge yourself to ask more than once. `at` is
--- a point or nil; `maximum` has no default. nil where nothing is found; see
--- `ThicknessGauge:thickness_at_face`.
---@param face integer
---@param at number[]|nil
---@param maximum number
---@param tolerance number|nil
---@return FaceThickness|nil
function Solid:thickness_at_face(face, at, maximum, tolerance)
  return with_gauge({ self }, tolerance, function(g) return g:thickness_at_face(0, face, at, maximum) end)
end

--- The nearest-opposing-wall rule on plain meshes measured against each other: each mesh a
--- {positions, triangles} pair -- {x, y, z} points and {i, j, k} triples of indices from zero into
--- its own points. One reading per vertex that has one within `maximum` (positive and finite), by
--- mesh then vertex; `sharp_angle` (nil is 0) as for `ThicknessGauge:thickness`. Raises for a
--- mesh that is not such a pair, a triangle past its mesh, a position not finite or a bad limit.
---@param meshes table[]
---@param maximum number
---@param sharp_angle number|nil
---@return MeshThickness[]
function M.mesh_thickness(meshes, maximum, sharp_angle)
  if type(meshes) ~= "table" then raise("mesh_thickness: expected a list of meshes, got " .. repr(meshes)) end
  maximum = required(maximum, "maximum", "mesh_thickness")
  local sharp = number(sharp_angle == nil and 0 or sharp_angle, "mesh_thickness")
  local m_count = #meshes
  local positions, indices, np, ni = {}, {}, 0, 0
  local vertex_counts = ffi.new("uint32_t[?]", math.max(m_count, 1))
  local triangle_counts = ffi.new("uint32_t[?]", math.max(m_count, 1))
  for m = 0, m_count - 1 do
    local mesh = meshes[m + 1]
    local points, triangles
    if type(mesh) == "table" then
      points, triangles = mesh[1] or mesh.positions, mesh[2] or mesh.triangles
    end
    if type(points) ~= "table" or type(triangles) ~= "table" then
      raise(("mesh_thickness: mesh %d is not a (positions, triangles) pair"):format(m))
    end
    local nv, nt = 0, 0
    for i, p in ipairs(points) do
      local ok = type(p) == "table" and #p == 3
      for k = 1, ok and 3 or 0 do ok = ok and type(p[k]) == "number" end
      if not ok then raise(("mesh_thickness: mesh %d position %d is not three numbers"):format(m, i - 1)) end
      positions[np + 1], positions[np + 2], positions[np + 3] = p[1], p[2], p[3]
      np, nv = np + 3, nv + 1
    end
    vertex_counts[m] = nv
    for i, tri in ipairs(triangles) do
      local ok = type(tri) == "table" and #tri == 3
      for k = 1, ok and 3 or 0 do
        local v = tri[k]
        ok = ok and type(v) == "number" and v >= 0 and v <= 4294967295 and v == math.floor(v)
      end
      if not ok then raise(("mesh_thickness: mesh %d triangle %d is not three indices"):format(m, i - 1)) end
      indices[ni + 1], indices[ni + 2], indices[ni + 3] = tri[1], tri[2], tri[3]
      ni, nt = ni + 3, nt + 1
    end
    triangle_counts[m] = nt
  end
  local pos_arr = ffi.new("double[?]", math.max(np, 1))
  for i, v in ipairs(positions) do pos_arr[i - 1] = v end
  local idx_arr = ffi.new("uint32_t[?]", math.max(ni, 1))
  for i, v in ipairs(indices) do idx_arr[i - 1] = v end
  local h = lib().cadaclysm_blacksmith_mesh_thickness(pos_arr, vertex_counts, idx_arr, triangle_counts, m_count,
    maximum, sharp)
  return read_rows(h, "mesh_thickness", "CadaclysmBlacksmithMeshThickness",
    function(l) return lib().cadaclysm_blacksmith_mesh_thicknesses_count(l) end,
    function(l, i, raw) return lib().cadaclysm_blacksmith_mesh_thicknesses_at(l, i, raw) end,
    function(l) lib().cadaclysm_blacksmith_mesh_thicknesses_free(l) end, "mesh_thicknesses_at", MeshThickness.of)
end

end

-- ---- the R-tree -------------------------------------------------------------------------

-- In a block of its own: the main chunk is at LuaJIT's limit of 200 live locals, so the
-- R-tree's helpers live here and only `M.RTree`, `M.closest_points` and `M.k_neighbors`
-- leave it.
do

-- An id or a `k` as the C ABI's `uint32_t`: a whole number from 0 to 4294967295, refused by
-- `call`'s name before the library is asked -- never wrapped by the FFI.
local function rtree_u32(value, call, name)
  if type(value) ~= "number" or value ~= math.floor(value) then
    raise(("%s: %s must be a whole number, got %s"):format(call, name, repr(value)))
  end
  if value < 0 or value > 4294967295 then raise(("%s: %s is out of range: %.14g"):format(call, name, value)) end
  return value
end

-- A radius, slack or limit, refused by `call`'s name when it is not a number -- whether the
-- number is a distance is the library's to say.
local function rtree_real(value, call, name)
  if type(value) ~= "number" then raise(("%s: %s %s is not a number"):format(call, name, repr(value))) end
  return value
end

-- `p` as 3 numbers, or nil when it is not 3 numbers (a NaN is a number).
local function rtree_triple(p)
  if type(p) ~= "table" or getmetatable(p) == Box or #p ~= 3 then return nil end
  for i = 1, 3 do
    if type(p[i]) ~= "number" then return nil end
  end
  return { p[1], p[2], p[3] }
end

-- A query point as 3 doubles, refused by `call`'s name when it is not 3 numbers.
local function rtree_point(point, call)
  local v = rtree_triple(point)
  if v == nil then raise(("%s: a point is 3 numbers, not %s"):format(call, repr(point))) end
  local out = ffi.new("double[3]")
  out[0], out[1], out[2] = v[1], v[2], v[3]
  return out
end

-- A box as the C ABI's 6 doubles `[minx, miny, minz, maxx, maxy, maxz]`, and whether it was given
-- as a point: a `Box`, {min, max} (two triples), 6 numbers, or a point (3 numbers, a zero box).
-- The shape is refused here by `what`; a NaN or an inverted box is the library's.
local function rtree_box(box, what)
  local v
  if type(box) == "table" and getmetatable(box) == Box then
    v = { box.lo[1], box.lo[2], box.lo[3], box.hi[1], box.hi[2], box.hi[3] }
  elseif type(box) == "table" then
    local n = #box
    if n == 3 or n == 6 then
      local numbers = true
      for i = 1, n do
        if type(box[i]) ~= "number" then numbers = false end
      end
      if numbers then
        v = n == 3 and { box[1], box[2], box[3], box[1], box[2], box[3] }
          or { box[1], box[2], box[3], box[4], box[5], box[6] }
        if n == 3 then
          local out = ffi.new("double[6]", v)
          return out, true
        end
      end
    elseif n == 2 then
      local lo, hi = rtree_triple(box[1]), rtree_triple(box[2])
      if lo ~= nil and hi ~= nil then v = { lo[1], lo[2], lo[3], hi[1], hi[2], hi[3] } end
    end
  end
  if v == nil then
    raise(("%s: a box is {min, max} (two triples), a Box, 6 numbers or a point, not %s"):format(what, repr(box)))
  end
  return ffi.new("double[6]", v), false
end

-- Points (3 numbers each) as one flat double array and their count, the shape refused by index
-- under `what`.
local function rtree_points(points, what, name)
  if type(points) ~= "table" then raise(("%s: expected a list of points, got %s"):format(what, repr(points))) end
  local n = #points
  local out = ffi.new("double[?]", math.max(3 * n, 1))
  for i = 1, n do
    local v = rtree_triple(points[i])
    if v == nil then raise(("%s: %s %d is not 3 numbers: %s"):format(what, name or "point", i - 1, repr(points[i]))) end
    out[3 * i - 3], out[3 * i - 2], out[3 * i - 1] = v[1], v[2], v[3]
  end
  return out, n
end

-- A search/within/nearest answer as {id, distance} rows: the owned list read and freed before
-- returning or raising. A null list is the call's refusal.
local function rtree_hits(list, what)
  local L = lib()
  if list == nil then fail(what) end
  local out, reason = {}, nil
  local count = L.cadaclysm_blacksmith_rtree_hits_count(list)
  local raw = ffi.new("CadaclysmBlacksmithRTreeHit[1]")
  for i = 0, count - 1 do
    if not L.cadaclysm_blacksmith_rtree_hits_at(list, i, raw) then
      reason = last_error()
      break
    end
    out[i + 1] = { tonumber(raw[0].id), raw[0].distance }
  end
  L.cadaclysm_blacksmith_rtree_hits_free(list)
  if reason ~= nil then
    error(setmetatable({ message = reason ~= "" and reason or "rtree_hits_at" }, BuildError), 2)
  end
  return out
end

-- An overlaps answer as {a, b} rows, read and freed as `rtree_hits` reads hits.
local function rtree_pairs(list, what)
  local L = lib()
  if list == nil then fail(what) end
  local out, reason = {}, nil
  local count = L.cadaclysm_blacksmith_rtree_pairs_count(list)
  local raw = ffi.new("CadaclysmBlacksmithRTreePair[1]")
  for i = 0, count - 1 do
    if not L.cadaclysm_blacksmith_rtree_pairs_at(list, i, raw) then
      reason = last_error()
      break
    end
    out[i + 1] = { tonumber(raw[0].a), tonumber(raw[0].b) }
  end
  L.cadaclysm_blacksmith_rtree_pairs_free(list)
  if reason ~= nil then
    error(setmetatable({ message = reason ~= "" and reason or "rtree_pairs_at" }, BuildError), 2)
  end
  return out
end

local function free_rtree(h) lib().cadaclysm_blacksmith_rtree_free(h) end

--- A spatial index over boxes with ids (an R*-tree): `search` a box for the entries it meets,
--- `within` / `nearest` a point for the closest, `overlaps` / `self_overlaps` for every pair of
--- boxes that meet. Ids are the caller's own (whole numbers, 0 to 4294967295) and may repeat; an
--- entry is an id and its box, and the same {id, box} twice is two entries. Touching boxes meet.
---
--- A box is {min, max} -- two {x, y, z} triples -- a `Box`, or 6 numbers; a point {x, y, z}
--- stands for a zero box. Answers come in a fixed order: `search` ids ascending, `within` /
--- `nearest` by distance then id, as {id, distance} rows; pairs ascending, as {a, b} rows.
--- `slack` is the largest gap between two boxes that still pair. The tree changes in place
--- (`insert`, `remove`); calls on one tree must not overlap from two threads. `RTree()` is an
--- empty tree; `close()` frees it, and so does the garbage collector.
---@class RTree
local RTree = {}
local RTree_get = {}
class(RTree, RTree_get)
callable(RTree)
M.RTree = RTree

local function adopt_rtree(h, what)
  checked(h, what)
  return setmetatable({ _ptr = ffi.gc(h, free_rtree) }, RTree)
end

--- An empty tree.
---@return RTree
function RTree.new()
  return adopt_rtree(lib().cadaclysm_blacksmith_rtree_new(), "rtree_new")
end

--- A tree over {id, box} pairs at once, packed (sort-tile-recursive): fuller and faster to query
--- than the same entries inserted one by one. Raises for the first entry whose box is not a box
--- (a NaN, an infinity, `min > max`), by index (from 0).
---@param entries table[]  {{id, box}, ...}
---@return RTree
function RTree.from_boxes(entries)
  if type(entries) ~= "table" then raise("rtree_from_boxes: expected a list of {id, box} pairs, got " .. repr(entries)) end
  local n = #entries
  local ids = ffi.new("uint32_t[?]", math.max(n, 1))
  local boxes = ffi.new("double[?]", math.max(6 * n, 1))
  for i = 1, n do
    local entry = entries[i]
    if type(entry) ~= "table" or #entry ~= 2 then
      raise(("rtree_from_boxes: entry %d is not an {id, box} pair: %s"):format(i - 1, repr(entry)))
    end
    local what = ("rtree_from_boxes: entry %d"):format(i - 1)
    ids[i - 1] = rtree_u32(entry[1], what, "id")
    local words = rtree_box(entry[2], what)
    for k = 0, 5 do boxes[6 * (i - 1) + k] = words[k] end
  end
  return adopt_rtree(lib().cadaclysm_blacksmith_rtree_from_boxes(ids, boxes, n), "rtree_from_boxes")
end

--- A tree over `points`, each a zero box whose id is its index (from 0). Raises for the first
--- point with a NaN or infinite coordinate, by index.
---@param points number[][]
---@return RTree
function RTree.from_points(points)
  local flat, n = rtree_points(points, "rtree_from_points")
  return adopt_rtree(lib().cadaclysm_blacksmith_rtree_from_points(flat, n), "rtree_from_points")
end

--- A tree over a mesh's triangles -- RhinoCommon's `RTree.CreateMeshFaceTree`: one entry per
--- triangle of `triangles` (each {a, b, c}, three indices from 0 into `positions`, each {x, y, z}),
--- its id the triangle's index (from 0), its box its three corners' box. Raises for the first
--- corner past the points or at a point with a NaN or infinite coordinate, by triangle and point;
--- points no triangle uses are not checked.
---@param positions number[][]
---@param triangles integer[][]
---@return RTree
function RTree.from_triangles(positions, triangles)
  local flat, n = rtree_points(positions, "rtree_from_triangles")
  if type(triangles) ~= "table" then
    raise("rtree_from_triangles: expected a list of triangles, got " .. repr(triangles))
  end
  local m = #triangles
  local indices = ffi.new("uint32_t[?]", math.max(3 * m, 1))
  for i = 1, m do
    local tri = triangles[i]
    if type(tri) ~= "table" or getmetatable(tri) ~= nil or #tri ~= 3 then
      raise(("rtree_from_triangles: triangle %d is not 3 indices: %s"):format(i - 1, repr(tri)))
    end
    local what = ("triangle %d's index"):format(i - 1)
    for k = 1, 3 do indices[3 * (i - 1) + k - 1] = rtree_u32(tri[k], "rtree_from_triangles", what) end
  end
  return adopt_rtree(lib().cadaclysm_blacksmith_rtree_from_triangles(flat, n, indices, m), "rtree_from_triangles")
end

--- An `RTree` over this solid's faces: one entry per face, its id the face index the other face
--- calls take, its box holding the face (the box the boolean's broad phase pairs faces by, grown
--- by a thousandth of the solid's extent). No faces give an empty tree. The tree is its own and
--- outlives the solid.
---@return RTree
function Solid:face_tree()
  return adopt_rtree(lib().cadaclysm_blacksmith_solid_face_tree(self:_h()), "solid_face_tree")
end

--- Whether `close()` has been called.
function RTree_get.closed(self)
  return rawget(self, "_ptr") == nil
end

--- Free the tree. Idempotent.
function RTree:close()
  local h = rawget(self, "_ptr")
  if h ~= nil then
    self._ptr = nil
    ffi.gc(h, nil)
    free_rtree(h)
  end
end

function RTree:_h()
  local h = rawget(self, "_ptr")
  if h == nil then raise("rtree: closed") end
  return h
end

--- How many entries the tree holds.
---@return integer
function RTree:count()
  return tonumber(lib().cadaclysm_blacksmith_rtree_count(self:_h()))
end

--- The union of every entry's box as {min, max} (two {x, y, z} triples), or nil for an empty tree.
function RTree_get.bounds(self)
  local h = self:_h()
  local L = lib()
  if L.cadaclysm_blacksmith_rtree_count(h) == 0 then return nil end
  local out = ffi.new("double[6]")
  if not L.cadaclysm_blacksmith_rtree_bounds(h, out) then fail("rtree_bounds") end
  return { { out[0], out[1], out[2] }, { out[3], out[4], out[5] } }
end

--- Add the entry {id, box}, `box` a box or a point. Raises, leaving the tree as it was, for a box
--- that is not a box or a point that is not finite.
---@param id integer
---@param box table
function RTree:insert(id, box)
  local h = self:_h()
  local n = rtree_u32(id, "rtree_insert", "id")
  local words, point = rtree_box(box, "rtree_insert")
  local L = lib()
  if point then
    if not L.cadaclysm_blacksmith_rtree_insert_point(h, n, words) then fail("rtree_insert_point") end
  elseif not L.cadaclysm_blacksmith_rtree_insert(h, n, words) then
    fail("rtree_insert")
  end
end

--- Take out one entry equal to {id, box} -- the box it was inserted with, compared coordinate by
--- coordinate (a point's is its zero box) -- and say whether there was one: false, not an error,
--- when there is none. With duplicates, one goes per call. Raises for a box that is not a box.
---@param id integer
---@param box table
---@return boolean
function RTree:remove(id, box)
  local h = self:_h()
  local n = rtree_u32(id, "rtree_remove", "id")
  local words = rtree_box(box, "rtree_remove")
  if lib().cadaclysm_blacksmith_rtree_remove(h, n, words) then return true end
  if last_error() ~= "" then fail("rtree_remove") end
  return false
end

--- The ids of every entry whose box meets `box` (touching counts), ascending -- a repeated id as
--- often as it was inserted. Raises for a box that is not a box.
---@param box table
---@return integer[]
function RTree:search(box)
  local h = self:_h()
  local words = rtree_box(box, "rtree_search")
  local ids = {}
  for i, hit in ipairs(rtree_hits(lib().cadaclysm_blacksmith_rtree_search(h, words), "rtree_search")) do
    ids[i] = hit[1]
  end
  return ids
end

--- Every entry whose box is within `r` of `point` (0 inside the box; exactly `r` counts), as
--- {id, distance} rows by distance then id. Raises for a point not finite or an `r` negative or NaN.
---@param point number[]
---@param r number
---@return number[][]
function RTree:within(point, r)
  local h = self:_h()
  local p = rtree_point(point, "rtree_within")
  return rtree_hits(lib().cadaclysm_blacksmith_rtree_within(h, p, rtree_real(r, "rtree_within", "radius")), "rtree_within")
end

--- The `k` entries whose boxes are nearest `point`, as {id, distance} rows by distance then id (the
--- smaller ids win a tie); all of them when `k` is over the count. Raises for a point not finite or
--- a `k` above 1,000,000.
---@param point number[]
---@param k integer
---@return number[][]
function RTree:nearest(point, k)
  local h = self:_h()
  local p = rtree_point(point, "rtree_nearest")
  return rtree_hits(lib().cadaclysm_blacksmith_rtree_nearest(h, p, rtree_u32(k, "rtree_nearest", "k")), "rtree_nearest")
end

--- Every entry whose box the ray `origin + t * direction`, `0 <= t <= max_t`, meets, as {id, t}
--- rows by `t` then id, `t` where the ray enters the box (0 when `origin` is inside it). Touching
--- counts. `t` is in units of `direction`'s length, which is not normalised; `max_t` nil is
--- infinity. The boxes are what is tested: for a triangle or a face, test the hits' own geometry.
--- Raises for an origin or direction not finite, a zero direction, or a `max_t` negative or NaN.
---@param origin number[]
---@param direction number[]
---@param max_t number|nil
---@return number[][]
function RTree:ray(origin, direction, max_t)
  local h = self:_h()
  local o, d = rtree_triple(origin), rtree_triple(direction)
  if o == nil then raise("rtree_ray: an origin is 3 numbers, not " .. repr(origin)) end
  if d == nil then raise("rtree_ray: a direction is 3 numbers, not " .. repr(direction)) end
  if max_t == nil then max_t = math.huge end
  local t = rtree_real(max_t, "rtree_ray", "max_t")
  return rtree_hits(lib().cadaclysm_blacksmith_rtree_ray(h, ffi.new("double[3]", o), ffi.new("double[3]", d), t), "rtree_ray")
end

--- Every pair {a, b}, `a` an entry of this tree and `b` one of `other` (this tree too, if it is),
--- whose boxes are at most `slack` apart on every axis (nil is 0: touching), ascending. Raises for
--- a `slack` negative or NaN.
---@param other RTree
---@param slack number|nil
---@return integer[][]
function RTree:overlaps(other, slack)
  local h = self:_h()
  if type(other) ~= "table" or getmetatable(other) ~= RTree then
    raise("rtree_overlaps: other must be an RTree, not " .. repr(other))
  end
  local o = other:_h()
  if slack == nil then slack = 0 end
  return rtree_pairs(lib().cadaclysm_blacksmith_rtree_overlaps(h, o, rtree_real(slack, "rtree_overlaps", "slack")),
    "rtree_overlaps")
end

--- Every unordered pair of distinct entries at most `slack` apart (nil is 0), once each as
--- {smaller id, larger id}, ascending -- an id paired with itself only where two entries share it.
--- Raises for a `slack` negative or NaN.
---@param slack number|nil
---@return integer[][]
function RTree:self_overlaps(slack)
  local h = self:_h()
  if slack == nil then slack = 0 end
  return rtree_pairs(lib().cadaclysm_blacksmith_rtree_self_overlaps(h, rtree_real(slack, "rtree_self_overlaps", "slack")),
    "rtree_self_overlaps")
end

RTree.__tostring = function(self)
  if rawget(self, "_ptr") == nil then return "RTree(closed)" end
  return ("RTree(%d entries)"):format(self:count())
end

-- `x` as Rust's `{}` prints an f64 -- the kernel's refusals quote numbers that way.
local function rust_number(x)
  if x ~= x then return "NaN" end
  if x == math.huge then return "inf" end
  if x == -math.huge then return "-inf" end
  -- The shortest round-trip digits, as Rust's are (the first precision that reads back), laid out
  -- as Rust lays them out: without an exponent. 1/x keeps the sign of -0.
  local sign = (x < 0 or 1 / x < 0) and "-" or ""
  local a = math.abs(x)
  local body
  for precision = 0, 16 do
    body = ("%." .. precision .. "e"):format(a)
    if tonumber(body) == a then break end
  end
  local mantissa, exponent = body:match("^([^e]+)e([-+]%d+)$")
  local digits = mantissa:gsub("[^%d]", "")
  local shift = tonumber(exponent) - #digits + 1
  local stripped = digits:gsub("0+$", "")
  shift = shift + #digits - #stripped
  digits = stripped:gsub("^0+", "")
  if digits == "" then return sign .. "0" end
  if shift >= 0 then return sign .. digits .. ("0"):rep(shift) end
  local point = #digits + shift
  if point > 0 then return sign .. digits:sub(1, point) .. "." .. digits:sub(point + 1) end
  return sign .. "0." .. ("0"):rep(-point) .. digits
end

-- `hay` and `needles` as flat arrays, refused as the kernel's `closest_points` / `k_neighbors`
-- refuse: the first hay point, then needle, not finite (or not 3 numbers), by index.
local function point_triples(call, hay, needles)
  local out = {}
  for _, named in ipairs({ { "hay", hay }, { "needle", needles } }) do
    local name, points = named[1], named[2]
    local flat, n = rtree_points(points, call, name .. " point")
    for i = 0, n - 1 do
      for k = 0, 2 do
        local v = flat[3 * i + k]
        if v ~= v or v == math.huge or v == -math.huge then
          raise(("%s: %s point %d is not finite"):format(call, name, i))
        end
      end
    end
    out[#out + 1] = { flat, n }
  end
  return out[1], out[2]
end

-- One tree over the hay, asked once a needle; the ids kept and the tree freed on every path.
local function each_needle(hay, needles, ask)
  local tree = adopt_rtree(lib().cadaclysm_blacksmith_rtree_from_points(hay[1], hay[2]), "rtree_from_points")
  local ok, result = pcall(function()
    local out, p = {}, ffi.new("double[3]")
    for i = 0, needles[2] - 1 do
      p[0], p[1], p[2] = needles[1][3 * i], needles[1][3 * i + 1], needles[1][3 * i + 2]
      local ids = {}
      for n, hit in ipairs(ask(tree, p)) do ids[n] = hit[1] end
      out[i + 1] = ids
    end
    return out
  end)
  tree:close()
  if not ok then error(result, 0) end
  return result
end

--- For each of `needles`, the indices (from 0) of the `hay` points within `limit` of it, nearest
--- first and equal distances by index -- one `RTree` over `hay` answers every needle. Raises for a
--- `limit` negative or NaN, then the first hay point and the first needle not finite, by index.
---@param hay number[][]
---@param needles number[][]
---@param limit number
---@return integer[][]
function M.closest_points(hay, needles, limit)
  limit = rtree_real(limit, "closest_points", "limit")
  if not (limit >= 0) then raise(("closest_points: limit %s is not a distance"):format(rust_number(limit))) end
  local h, n = point_triples("closest_points", hay, needles)
  local L = lib()
  return each_needle(h, n, function(tree, p)
    return rtree_hits(L.cadaclysm_blacksmith_rtree_within(tree:_h(), p, limit), "rtree_within")
  end)
end

--- For each of `needles`, the indices (from 0) of the `k` nearest `hay` points, nearest first and
--- equal distances by index (the smaller indices win a tie at the `k`-th place); every hay point
--- when `k` is over their count. Raises for the first hay point and the first needle not finite, by
--- index, then a `k` that is not a whole number from 0 to 1,000,000.
---@param hay number[][]
---@param needles number[][]
---@param k integer
---@return integer[][]
function M.k_neighbors(hay, needles, k)
  local h, n = point_triples("k_neighbors", hay, needles)
  k = rtree_u32(k, "k_neighbors", "k")
  if k > 1000000 then raise(("k_neighbors: k %d is not at most 1000000"):format(k)) end
  local L = lib()
  return each_needle(h, n, function(tree, p)
    return rtree_hits(L.cadaclysm_blacksmith_rtree_nearest(tree:_h(), p, k), "rtree_nearest")
  end)
end

end

-- ---- the interpolator, the circumscribed polygon, merge and regions ------------------------

-- In a block of its own, as the R-tree's: the main chunk is at LuaJIT's limit of 200 live
-- locals, so only `M.Interpolator`, `Profile.circumscribed_polygon` and the `Solid` methods
-- leave it.
do

-- A count or index as the C ABI's `uint32_t`: a whole number from 0 to 4294967295, refused by
-- `call`'s name before the library is asked -- never wrapped by the FFI.
local function whole_u32(value, call, name)
  if type(value) ~= "number" or value ~= math.floor(value) then
    raise(("%s: %s must be a whole number, got %s"):format(call, name, repr(value)))
  end
  if value < 0 or value > 4294967295 then raise(("%s: %s is out of range: %.14g"):format(call, name, value)) end
  return value
end

--- A regular polygon of `sides` sides (at least 3) whose sides touch the circle of `radius`
--- about `centre` ({x, y}) -- the polygon across flats, a nut's hex: its corners on the circle
--- of `radius / cos(pi / sides)`, the first at `angle` radians (default 0) from the sketch's x
--- axis, the rest counter-clockwise, on the same rays as `regular_polygon`'s corners with the
--- same `angle`; each side's midpoint on the circle of `radius`. `sides` is a whole number from
--- 0 to 4294967295, refused here otherwise; under 3 is the library's to refuse.
---@param centre number[]
---@param radius number
---@param sides integer
---@param angle number|nil
---@return Profile
function Profile.circumscribed_polygon(centre, radius, sides, angle)
  if angle == nil then angle = 0.0 end
  local cx, cy = pair(centre, "centre")
  sides = whole_u32(sides, "profile_circumscribed_polygon", "sides")
  return new_profile(lib().cadaclysm_blacksmith_profile_circumscribed_polygon(cx, cy, radius, sides, angle),
    "profile_circumscribed_polygon")
end

-- -- merge and regions

--- One side of one face, as a `Region` lists its sides: `face` the face's index in the solid
--- (from 0), `sense` +1 for the side its normal points to, -1 for the other -- a solid's inside
--- is behind its faces, at -1. A plain table, equal (`==`) to another by value.
---@class FaceSide
---@field face integer
---@field sense integer
local FaceSide = {}
FaceSide.__index = FaceSide
FaceSide.__eq = function(a, b) return a.face == b.face and a.sense == b.sense end
FaceSide.__tostring = function(s) return ("FaceSide(face=%d, sense=%d)"):format(s.face, s.sense) end
M.FaceSide = FaceSide

--- One region of space a solid's faces bound, as `Solid:regions` returns it: its `index` (from 0;
--- 0 the infinite region, whose `finite` is false), the `Box` round the faces bounding it, its
--- `sides` (a list of `FaceSide`, ascending by face then sense) and its `shells` -- 1, plus one
--- per void inside it. A plain table, equal (`==`) to another by value. `Solid:region_solid`
--- takes a finite one as a solid of its own.
---@class Region
---@field index integer
---@field finite boolean
---@field box Box
---@field sides FaceSide[]
---@field shells integer
local Region = {}
Region.__index = Region
Region.__eq = function(a, b)
  if a.index ~= b.index or a.finite ~= b.finite or a.shells ~= b.shells or #a.sides ~= #b.sides then return false end
  for k = 1, 3 do
    if a.box.lo[k] ~= b.box.lo[k] or a.box.hi[k] ~= b.box.hi[k] then return false end
  end
  for k = 1, #a.sides do
    if a.sides[k] ~= b.sides[k] then return false end
  end
  return true
end
Region.__tostring = function(r)
  return ("Region(index=%d, finite=%s, %d sides, shells=%d)"):format(r.index, tostring(r.finite), #r.sides, r.shells)
end
M.Region = Region

-- A solid's regions: the owned `CadaclysmBlacksmithRegions *` read into `Region` tables and
-- freed before returning or raising. A null list is the call's refusal.
local function read_regions(list)
  local L = lib()
  if list == nil then fail("regions") end
  local out, reason = {}, nil
  local raw, side = ffi.new("CadaclysmBlacksmithRegion[1]"), ffi.new("CadaclysmBlacksmithFaceSide[1]")
  local count = L.cadaclysm_blacksmith_regions_count(list)
  for i = 0, count - 1 do
    if not L.cadaclysm_blacksmith_regions_at(list, i, raw) then
      reason = nonempty(last_error()) or "regions_at"
      break
    end
    local r = raw[0]
    local sides = {}
    for k = 0, r.sides - 1 do
      if not L.cadaclysm_blacksmith_regions_side_at(list, i, k, side) then
        reason = nonempty(last_error()) or "regions_side_at"
        break
      end
      sides[k + 1] = setmetatable({ face = tonumber(side[0].face), sense = tonumber(side[0].sense) }, FaceSide)
    end
    if reason ~= nil then break end
    out[i + 1] = setmetatable({
      index = i,
      finite = r.finite ~= 0,
      box = Box.new({ r.min[0], r.min[1], r.min[2] }, { r.max[0], r.max[1], r.max[2] }),
      sides = sides,
      shells = tonumber(r.shells),
    }, Region)
  end
  L.cadaclysm_blacksmith_regions_free(list)
  if reason ~= nil then error(setmetatable({ message = reason, ids = {} }, BuildError), 2) end
  return out
end

--- This solid and `other` as one body that keeps every piece -- a union that keeps the inside
--- pieces: its regions are this solid less `other`, the two together, and `other` less this one
--- (those that are not empty), and the walls between them are faces of both. The body is
--- non-manifold where a wall meets the outside, so the verbs that need a manifold solid -- the
--- booleans, fillet, chamfer, shell, thicken, the mass -- refuse it; take its cells with
--- `regions` and `region_solid`. Built exactly: both solids closed, every face a plane,
--- cylinder, cone, sphere or torus. `tolerance` defaults to 0.05; `progress` as `join`'s.
---@param other Solid
---@param tolerance number|nil
---@param progress function|nil
---@return Solid
function Solid:merge(other, tolerance, progress)
  if tolerance == nil then tolerance = 0.05 end
  local a, b = self:_h(), solid_handle(other, "merge")
  local cb, done = progress_callback(progress)
  return new_solid(done(lib().cadaclysm_blacksmith_merge(a, b, tolerance, cb, nil)), "merge")
end

--- The regions of space this solid's faces bound, a list of `Region` (region 0 the infinite one,
--- first): two for an ordinary solid (outside, inside), one per cell for a `merge`'s body, one
--- more per cavity.
---@return Region[]
function Solid:regions()
  return read_regions(lib().cadaclysm_blacksmith_regions(self:_h()))
end

--- Finite region `region` (an index into `regions()`, from 0) as a closed solid of its own: the
--- faces bounding it, each turned to point out of it, each keeping its colour. Region 0, the
--- infinite one, or one past the count raises; so does a `region` that is not a whole number
--- from 0 to 4294967295, before the call.
---@param region integer
---@return Solid
function Solid:region_solid(region)
  local h = self:_h()
  region = whole_u32(region, "region_solid", "region")
  return new_solid(lib().cadaclysm_blacksmith_region_solid(h, region), "region_solid")
end

-- -- the interpolator

-- The modes by name, at the C constants' values (`CADACLYSM_BLACKSMITH_INTERPOLATE_*`).
local INTERPOLATOR_MODES = { nearest = 0, linear = 1, cosine = 2, cubic = 3, catmull_rom = 4 }

-- A mode's C value (nil is "linear"), a name not among the five refused before any call.
local function interpolator_mode(mode)
  if mode == nil then mode = "linear" end
  local m = type(mode) == "string" and INTERPOLATOR_MODES[mode] or nil
  if m == nil then
    raise(("interpolator: mode %s is not one of nearest, linear, cosine, cubic, catmull_rom"):format(repr(mode)))
  end
  return m
end

local function interpolator_t(t, call)
  if type(t) ~= "number" then raise(("%s: t %s is not a number"):format(call, repr(t))) end
  return t
end

local function free_interpolator(h) lib().cadaclysm_blacksmith_interpolator_free(h) end

--- A list of samples read at a fractional index, as Rhino's `Interpolator`: `t = 2` is sample 2,
--- `t = 2.5` halfway between samples 2 and 3 (indices from 0, as the library's). Animation keys,
--- a value along a pattern, a smoothed profile of measurements.
---
--- `samples` are numbers (dimension 1, answered as numbers) or equal-length lists of numbers --
--- 2D, 3D or any dimension, answered as lists, each component read on its own; lists of unequal
--- length are refused before the call. An open list clamps `t` to `[0, count - 1]` and stops on
--- its end samples; a `cyclic` one wraps `t` with period `count`.
---
--- The five modes, by name: `"nearest"` the sample at `floor(t + 1/2)`; `"linear"` (the
--- default) straight between the samples either side; `"cosine"` linear on a cosine ease, flat
--- at every sample; `"cubic"` Bourke's cubic through every sample; `"catmull_rom"` through every
--- sample, C1. A name not among them is refused before the call. An interpolator never changes
--- after it is made. `Interpolator(samples, cyclic)`; `close()` frees it, and so does the
--- garbage collector.
---@class Interpolator
local Interpolator = {}
local Interpolator_get = {}
class(Interpolator, Interpolator_get)
callable(Interpolator)
M.Interpolator = Interpolator

--- An interpolator over `samples` (numbers, or lists of numbers of one length); `cyclic`
--- (default false) wraps `t` round the list. Raises for no samples or a sample that is NaN or
--- infinite (by index, from 0).
---@param samples number[]|number[][]
---@param cyclic boolean|nil
---@return Interpolator
function Interpolator.new(samples, cyclic)
  if type(samples) ~= "table" then
    raise("interpolator: samples are all numbers or all lists of numbers, not " .. repr(samples))
  end
  local count = #samples
  local flat, dimension = {}, 1
  if count > 0 and type(samples[1]) == "number" then
    for i = 1, count do
      if type(samples[i]) ~= "number" then raise("interpolator: samples are all numbers or all lists of numbers") end
      flat[i] = samples[i]
    end
  elseif count > 0 then
    dimension = type(samples[1]) == "table" and #samples[1] or 0
    local lengths = {}
    for i = 1, count do
      local row = samples[i]
      if type(row) ~= "table" then raise("interpolator: samples are all numbers or all lists of numbers") end
      lengths[#row] = true
      for k = 1, #row do
        if type(row[k]) ~= "number" then raise("interpolator: samples are all numbers or all lists of numbers") end
        flat[#flat + 1] = row[k]
      end
    end
    local seen = {}
    for n in pairs(lengths) do seen[#seen + 1] = n end
    if #seen > 1 then
      table.sort(seen)
      raise(("interpolator: samples differ in length (%s)"):format(table.concat(seen, ", ")))
    end
  end
  local words = ffi.new("double[?]", math.max(#flat, 1), flat)
  local h = checked(lib().cadaclysm_blacksmith_interpolator_new(words, count, dimension, cyclic and true or false),
    "interpolator_new")
  return setmetatable({ _ptr = ffi.gc(h, free_interpolator), _dimension = dimension }, Interpolator)
end

--- Whether `close()` has been called.
function Interpolator_get.closed(self)
  return rawget(self, "_ptr") == nil
end

--- Free the interpolator. Idempotent.
function Interpolator:close()
  local h = rawget(self, "_ptr")
  if h ~= nil then
    self._ptr = nil
    ffi.gc(h, nil)
    free_interpolator(h)
  end
end

function Interpolator:_h()
  local h = rawget(self, "_ptr")
  if h == nil then raise("interpolator: closed") end
  return h
end

--- How many samples.
---@return integer
function Interpolator:count()
  return tonumber(lib().cadaclysm_blacksmith_interpolator_count(self:_h()))
end

--- How many numbers per sample: 1 answers numbers, more answers lists.
function Interpolator_get.dimension(self)
  return tonumber(lib().cadaclysm_blacksmith_interpolator_dimension(self:_h()))
end

--- Whether `t` wraps round the list (else it is clamped to the ends).
function Interpolator_get.cyclic(self)
  return lib().cadaclysm_blacksmith_interpolator_cyclic(self:_h()) == true
end

-- `d` doubles from `out` at `k`: a number at dimension 1, else a list.
local function interpolator_value(out, k, d)
  if d == 1 then return out[k] end
  local v = {}
  for j = 1, d do v[j] = out[k + j - 1] end
  return v
end

--- The value at the fractional index `t` by `mode` (`"nearest"`, `"linear"` -- the default --
--- `"cosine"`, `"cubic"` or `"catmull_rom"`): a number at dimension 1, else a list of
--- `dimension` numbers. Raises for a `t` that is NaN or infinite.
---@param t number
---@param mode string|nil
---@return number|number[]
function Interpolator:at(t, mode)
  local m, h = interpolator_mode(mode), self:_h()
  t = interpolator_t(t, "interpolator_at")
  local d = self._dimension
  local out = ffi.new("double[?]", d)
  if not lib().cadaclysm_blacksmith_interpolator_at(h, t, m, out, d) then fail("interpolator_at") end
  return interpolator_value(out, 0, d)
end

--- The values at every `t` of `ts` by `mode`, as `at` reads each, in one call: a list, empty for
--- no `ts`. Raises for a value of `t` that is NaN or infinite (by its index, from 0) and more than
--- 1,000,000 values.
---@param ts number[]
---@param mode string|nil
---@return (number|number[])[]
function Interpolator:sample(ts, mode)
  local m, h = interpolator_mode(mode), self:_h()
  if type(ts) ~= "table" then raise("interpolator_sample: ts must be a list of numbers, not " .. repr(ts)) end
  local n = #ts
  if n == 0 then return {} end
  local values = ffi.new("double[?]", n)
  for i = 1, n do values[i - 1] = interpolator_t(ts[i], "interpolator_sample") end
  local d = self._dimension
  local out = ffi.new("double[?]", n * d)
  if not lib().cadaclysm_blacksmith_interpolator_sample(h, values, n, m, out, n * d) then fail("interpolator_sample") end
  local list = {}
  for i = 0, n - 1 do list[i + 1] = interpolator_value(out, i * d, d) end
  return list
end

--- The sample at `floor(t + 1/2)` (a half rounds up), after the clamp or wrap.
function Interpolator:nearest(t) return self:at(t, "nearest") end

--- Straight between the two samples either side of `t`.
function Interpolator:linear(t) return self:at(t, "linear") end

--- Between the two samples either side of `t` on a cosine ease, flat at every sample.
function Interpolator:cosine(t) return self:at(t, "cosine") end

--- Bourke's cubic over the four samples about `t`, through every sample.
function Interpolator:cubic(t) return self:at(t, "cubic") end

--- The Catmull-Rom spline over the four samples about `t`: through every sample, C1.
function Interpolator:catmull_rom(t) return self:at(t, "catmull_rom") end

Interpolator.__tostring = function(self)
  if rawget(self, "_ptr") == nil then return "Interpolator(closed)" end
  return ("Interpolator(%d samples of %d%s)"):format(self:count(), self._dimension, self.cyclic and ", cyclic" or "")
end

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

--- A new cage with `faces` subdivided once by the Catmull-Clark rules (the whole cage when
--- `faces` is nil or empty): each face becomes quads round a new point, and an unpicked face
--- beside them takes the new edge points as corners. The whole cage keeps its smooth surface
--- exactly. The new cage selects the new faces.
function Subd:subdivide(faces)
  local h = self:_h()
  local ids, count = uint32s(faces or {}, "subdivide", "faces")
  return new_subd(lib().cadaclysm_blacksmith_subd_subdivide(h, ids, count), "subd_subdivide")
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

-- ---- the 2D constraint sketcher -----------------------------------------------------------

-- A block of its own: this file's main chunk is near Lua's limit of 200 locals, and nothing
-- here is needed below it but what goes on `M`.
do

-- The C ABI's codes, by position, code 0 first; Lua speaks the names (Python's, snake_case).
local SKETCH_ENTITY_KINDS = { "point", "line", "circle", "arc", "free_curve" }
local SKETCH_CONSTRAINT_KINDS = {
  "coincident", "point_on_line", "point_on_circle", "horizontal", "vertical", "parallel", "perpendicular",
  "collinear", "tangent", "tangent_at_end", "concentric", "equal_length", "equal_radius", "midpoint",
  "symmetric", "fix", "distance", "point_line_distance", "line_distance", "circle_line_distance",
  "circle_distance", "horizontal_distance", "vertical_distance", "length", "angle", "radius", "diameter",
}
local SKETCH_SENSES = { "auto", "positive", "negative" }
local SKETCH_ENDS = { "start", "end" }
local SKETCH_STATUSES = { "converged", "conflicting", "diverged" }
local SKETCH_STATES = { "under", "full", "over" }
-- `sketch_dof_list`'s and `sketch_dof_part_list`'s `which`.
local DOF = { redundant = 0, conflicting = 1, free_entities = 2 }
local PART = { constraints = 0, redundant = 1, conflicting = 2, free_entities = 3 }

-- `value` as a uint32_t id for `call`'s `param`: a whole number from 0 to 4294967295, refused
-- here, named, otherwise (nil, "1", 1.5, -1 ...) rather than converted by the FFI.
local function sketch_arg(value, call, param)
  if type(value) ~= "number" or value < 0 or value > 4294967295 or value ~= math.floor(value) then
    raise(("%s: %s must be an id (a whole number from 0), not %s"):format(call, param, repr(value)))
  end
  return value
end

-- An id the library handed back (NONE: raise the library's reason).
local function sketch_id(value, what)
  if value == NONE then fail(what) end
  return value
end

-- A code the library handed back -- a uint32_t, or a double in a report -- as its name: NONE,
-- a fraction, a NaN or a code out of range raises the library's reason.
local function sketch_named(names, code, what)
  if code == NONE or code ~= math.floor(code) or code < 0 or code >= #names then fail(what) end
  return names[code + 1]
end

-- A name the caller gave, as its code; an unknown one is refused naming the call and the
-- parameter.
local function sketch_code(names, name, call, param)
  for i, n in ipairs(names) do
    if n == name then return i - 1 end
  end
  local quoted = {}
  for i, n in ipairs(names) do quoted[i] = "'" .. n .. "'" end
  raise(("%s: %s must be one of %s, not %s"):format(call, param, table.concat(quoted, ", "), repr(name)))
end

-- A count the library wrote as a double, exactly: a whole number in range, else refused
-- naming the call.
local function sketch_whole(value, what)
  if value ~= math.floor(value) or value < 0 or value > 0x7FFFFFFF then
    raise(("%s: the library answered %s, not a whole number in range"):format(what, tostring(value)))
  end
  return value
end

-- A uint32_t list the library lends until the next call on the same sketch, copied at once:
-- a Lua list (from 1) of ids (from 0). `count` is the `size_t[1]` the call filled; null is a
-- refusal.
local function sketch_lent(ptr, count, what)
  if ptr == nil then fail(what) end
  local out = {}
  for i = 1, tonumber(count[0]) do out[i] = tonumber(ptr[i - 1]) end
  return out
end

-- A list of `{x, y}` as flat doubles, and how many points.
local function sketch_points(points, call)
  local n = list_count(points)
  if n == nil then raise(("%s: points must be a list of {x, y}, not %s"):format(call, repr(points))) end
  local xy = ffi.new("double[?]", math.max(2 * n, 1))
  for i = 1, n do xy[2 * i - 2], xy[2 * i - 1] = pair(points[i], call) end
  return xy, n
end

-- A list of numbers as doubles, and how many.
local function sketch_numbers(values, call, param)
  local n = list_count(values)
  if n == nil then raise(("%s: %s must be a list of numbers, not %s"):format(call, param, repr(values))) end
  local out = ffi.new("double[?]", math.max(n, 1))
  for i = 1, n do out[i - 1] = number(values[i], call .. " " .. param) end
  return out, n
end

--- What a solve did: `status` ("converged", "conflicting" or "diverged") and `converged`
--- (whether it is "converged"), how many `iterations`, the largest constraint residual left
--- (`max_residual`), and `ids`: the constraints a conflict ran into, or the worst ones of a
--- diverged solve (empty when it converged). Plain data.
---@class SolveReport
---@field status string
---@field converged boolean
---@field iterations integer
---@field max_residual number
---@field ids integer[]
local SolveReport = {}
class(SolveReport)
M.SolveReport = SolveReport

SolveReport.__tostring = function(self)
  return ("SolveReport(status=%s, iterations=%d, max_residual=%g, ids={%s})"):format(self.status, self.iterations,
    self.max_residual, table.concat(self.ids, ", "))
end

--- One independent part of a diagnosed sketch: its `params` (unknowns), how many stay `free`,
--- its `state` ("under", "full" or "over"), its `constraints`, the `redundant` and
--- `conflicting` ones among them, and its `free_entities`. Plain data.
---@class PartDof
---@field params integer
---@field free integer
---@field state string
---@field constraints integer[]
---@field redundant integer[]
---@field conflicting integer[]
---@field free_entities integer[]
local PartDof = {}
class(PartDof)
M.PartDof = PartDof

PartDof.__tostring = function(self)
  return ("PartDof(params=%d, free=%d, state=%s)"):format(self.params, self.free, self.state)
end

--- A sketch's degrees of freedom (`Sketch:diagnose`): how many are `free`, its `state`
--- ("under", "full" or "over"), the `redundant` and `conflicting` constraint ids, the
--- `free_entities` (entities that can still move), and the independent `parts` it splits
--- into, `PartDof`s. Plain data.
---@class Dof
---@field free integer
---@field state string
---@field redundant integer[]
---@field conflicting integer[]
---@field free_entities integer[]
---@field parts PartDof[]
local Dof = {}
class(Dof)
M.Dof = Dof

Dof.__tostring = function(self)
  return ("Dof(free=%d, state=%s, parts=%d)"):format(self.free, self.state, #self.parts)
end

--- A 2D sketch of points, lines, circles, arcs and free curves held by geometric constraints
--- and dimensions, solved on request:
---
---     local s = bs.Sketch.new()
---     local corners, sides = s:add_rect({ 0, 0 }, { 40, 30 })
---     s:fix(corners[1])
---     s:length(sides[1], 60)
---     s:solve()
---     local plate = bs.Solid.extrude(s:profiles()[1], bs.Frame.xy(), 10)
---
--- Entities and constraints are named by integer ids, counting from zero (Lua's lists of them
--- count from one, as Lua does). Entity kinds are "point", "line", "circle", "arc" and
--- "free_curve"; constraint kinds the snake_case names of the methods that add them
--- ("point_line_distance", ...) -- but for `radius_of`, whose kind is "radius" (`radius(id)`
--- reads a circle's radius). Senses are "auto", "positive" or "negative"; ends "start" or
--- "end". A point is `{x, y}`; `point(id)` returns two numbers, `x, y`.
---
--- A refused call raises `BuildError` with the library's text and, as its `ids`, the ids the
--- refusal names: the constraints a new constraint, value or reference conflicts with, the
--- entities still using a point (empty when it names none). The `SolveReport`s of `solve`,
--- `drag`, `set_value`, `set_driving` and `update_reference` carry a returned report's ids
--- the same way. `Sketch.new()` or `Sketch()`; `close()` frees this handle, and so does the
--- garbage collector.
---@class Sketch
local Sketch = {}
class(Sketch)
callable(Sketch)
M.Sketch = Sketch

local function free_sketch(h)
  lib().cadaclysm_blacksmith_sketch_free(h)
end

local function new_sketch(handle, what)
  checked(handle, what)
  return setmetatable({ _ptr = ffi.gc(handle, free_sketch) }, Sketch)
end

--- An empty sketch.
function Sketch.new()
  return new_sketch(lib().cadaclysm_blacksmith_sketch_new(), "sketch_new")
end

--- A sketch of `profile`'s lines, arcs and curves joined end to end, holes included; with
--- `infer` (nil: true) the obvious constraints (horizontal, vertical, tangent joints, ...)
--- too. Ends within `tolerance` (nil: 1e-6) count as joined.
function Sketch.from_profile(profile, infer, tolerance)
  local p = profile_handle(profile, "sketch_from_profile")
  if infer == nil then infer = true end
  local within = number(tolerance == nil and 1e-6 or tolerance, "sketch_from_profile tolerance")
  return new_sketch(lib().cadaclysm_blacksmith_sketch_from_profile(p, infer and true or false, within),
    "sketch_from_profile")
end

--- Free the sketch. Idempotent; every call after it raises "sketch: closed".
function Sketch:close()
  local h = rawget(self, "_ptr")
  if h ~= nil then
    self._ptr = nil
    ffi.gc(h, nil)
    lib().cadaclysm_blacksmith_sketch_free(h)
  end
end

function Sketch:_h()
  local h = rawget(self, "_ptr")
  if h == nil then raise("sketch: closed") end
  return h
end

-- The SolveReport of a call that filled `report` (false: refused, with the ids `report_ids`
-- holds), its ids copied from `report_ids`.
local function sketch_solved(done, report, what, h)
  if not done then fail_ids(what, h) end
  local n = ffi.new("size_t[1]")
  local ids = sketch_lent(lib().cadaclysm_blacksmith_sketch_report_ids(h, n), n, "sketch_report_ids")
  local status = sketch_named(SKETCH_STATUSES, report[0], what)
  return setmetatable({
    status = status, converged = status == "converged", iterations = sketch_whole(report[1], what),
    max_residual = report[2], ids = ids,
  }, SolveReport)
end

-- -- entities

--- A free point at (`x`, `y`): its id. A coordinate that is not finite is refused.
function Sketch:add_point(x, y)
  local h = self:_h()
  return sketch_id(lib().cadaclysm_blacksmith_sketch_add_point(h, number(x, "sketch_add_point"),
    number(y, "sketch_add_point")), "sketch_add_point")
end

--- A line between the points `a` and `b`.
function Sketch:add_line(a, b)
  local h = self:_h()
  return sketch_id(lib().cadaclysm_blacksmith_sketch_add_line(h, sketch_arg(a, "sketch_add_line", "a"),
    sketch_arg(b, "sketch_add_line", "b")), "sketch_add_line")
end

--- A circle of radius `r` about the point `centre`.
function Sketch:add_circle(centre, r)
  local h = self:_h()
  return sketch_id(lib().cadaclysm_blacksmith_sketch_add_circle(h, sketch_arg(centre, "sketch_add_circle", "centre"),
    number(r, "sketch_add_circle")), "sketch_add_circle")
end

--- A counter-clockwise arc about the point `centre` from the point `start` to the point `end_`.
function Sketch:add_arc(centre, start, end_)
  local h = self:_h()
  return sketch_id(lib().cadaclysm_blacksmith_sketch_add_arc(h, sketch_arg(centre, "sketch_add_arc", "centre"),
    sketch_arg(start, "sketch_add_arc", "start"), sketch_arg(end_, "sketch_add_arc", "end")), "sketch_add_arc")
end

--- A cubic Bezier free curve from the point `start` through the controls `c1` and `c2`
--- (`{x, y}` each) to a new end point at `to`; the curve owns its control points.
function Sketch:add_bezier(start, c1, c2, to)
  local h = self:_h()
  local id = sketch_arg(start, "sketch_add_bezier", "start")
  local c1x, c1y = pair(c1, "sketch_add_bezier")
  local c2x, c2y = pair(c2, "sketch_add_bezier")
  local x, y = pair(to, "sketch_add_bezier")
  return sketch_id(lib().cadaclysm_blacksmith_sketch_add_bezier(h, id, c1x, c1y, c2x, c2y, x, y), "sketch_add_bezier")
end

--- A rational quadratic (conic) free curve from the point `start` with the control `control`
--- (`{x, y}`) of `weight` to a new end point at `to`.
function Sketch:add_conic(start, control, to, weight)
  local h = self:_h()
  local id = sketch_arg(start, "sketch_add_conic", "start")
  local cx, cy = pair(control, "sketch_add_conic")
  local x, y = pair(to, "sketch_add_conic")
  return sketch_id(lib().cadaclysm_blacksmith_sketch_add_conic(h, id, cx, cy, x, y, number(weight, "sketch_add_conic")),
    "sketch_add_conic")
end

--- A NURBS free curve of `degree` (nil: 3) from the point `start` through the control
--- `points` (`{x, y}` each) after it, on `knots`; `weights` nil for a plain B-spline, or one
--- per control point counting the start (`#points + 1`).
function Sketch:add_nurbs(start, points, knots, degree, weights)
  local h = self:_h()
  local id = sketch_arg(start, "sketch_add_nurbs", "start")
  local xy, n = sketch_points(points, "sketch_add_nurbs")
  local knot_arr, knot_count = sketch_numbers(knots, "sketch_add_nurbs", "knots")
  if degree == nil then degree = 3 end
  if type(degree) ~= "number" or degree ~= math.floor(degree) then
    raise(("sketch_add_nurbs: degree must be a whole number, not %s"):format(repr(degree)))
  end
  if degree < 0 then raise(("sketch_add_nurbs: degree must not be negative, not %d"):format(degree)) end
  if degree > 4294967295 then raise(("sketch_add_nurbs: degree must be at most 4294967295, not %s"):format(repr(degree))) end
  -- The library reads exactly `n + 1` weights whatever the list holds: check here.
  local w = nil
  if weights ~= nil then
    local weight_arr, m = sketch_numbers(weights, "sketch_add_nurbs", "weights")
    if m ~= n + 1 then
      raise(("sketch_add_nurbs: %d weights for %d control points (the start and %d given); give one per point")
        :format(m, n + 1, n))
    end
    w = weight_arr
  end
  return sketch_id(lib().cadaclysm_blacksmith_sketch_add_nurbs(h, id, degree, xy, n, w, knot_arr, knot_count),
    "sketch_add_nurbs")
end

--- The rectangle with opposite corners `a` and `b` (`{x, y}` each), as two lists: its four
--- corner points, counter-clockwise from `a`, and its four sides (side `i` from corner `i`).
function Sketch:add_rect(a, b)
  local h = self:_h()
  local x0, y0 = pair(a, "sketch_add_rect")
  local x1, y1 = pair(b, "sketch_add_rect")
  local n = ffi.new("size_t[1]")
  local ids = sketch_lent(lib().cadaclysm_blacksmith_sketch_add_rect(h, x0, y0, x1, y1, n), n, "sketch_add_rect")
  return { ids[1], ids[2], ids[3], ids[4] }, { ids[5], ids[6], ids[7], ids[8] }
end

--- The kind of entity `id`: "point", "line", "circle", "arc" or "free_curve".
function Sketch:kind(id)
  local h = self:_h()
  return sketch_named(SKETCH_ENTITY_KINDS, lib().cadaclysm_blacksmith_sketch_kind(h, sketch_arg(id, "sketch_kind", "id")),
    "sketch_kind")
end

--- The live entity ids, ascending.
function Sketch:entities()
  local h = self:_h()
  local n = ffi.new("size_t[1]")
  return sketch_lent(lib().cadaclysm_blacksmith_sketch_entities(h, n), n, "sketch_entities")
end

--- The point `id`'s position: two numbers, `x, y`.
function Sketch:point(id)
  local h = self:_h()
  local out = ffi.new("double[2]")
  if not lib().cadaclysm_blacksmith_sketch_point(h, sketch_arg(id, "sketch_point", "id"), out) then fail("sketch_point") end
  return out[0], out[1]
end

--- Moves the point `id` to (`x`, `y`) without solving.
function Sketch:set_point(id, x, y)
  local h = self:_h()
  if not lib().cadaclysm_blacksmith_sketch_set_point(h, sketch_arg(id, "sketch_set_point", "id"),
    number(x, "sketch_set_point"), number(y, "sketch_set_point")) then
    fail("sketch_set_point")
  end
end

--- The radius of the circle or arc `id` (the RADIUS constraint is `radius_of`).
function Sketch:radius(id)
  local h = self:_h()
  local r = lib().cadaclysm_blacksmith_sketch_radius(h, sketch_arg(id, "sketch_radius", "id"))
  if r ~= r then fail("sketch_radius") end
  return r
end

--- Sets the circle `id`'s radius to `r` without solving.
function Sketch:set_radius(id, r)
  local h = self:_h()
  if not lib().cadaclysm_blacksmith_sketch_set_radius(h, sketch_arg(id, "sketch_set_radius", "id"),
    number(r, "sketch_set_radius")) then
    fail("sketch_set_radius")
  end
end

--- The centre point of the circle or arc `id`.
function Sketch:centre(id)
  local h = self:_h()
  return sketch_id(lib().cadaclysm_blacksmith_sketch_centre(h, sketch_arg(id, "sketch_centre", "id")), "sketch_centre")
end

--- The points entity `id` runs between: a line's `{a, b}`, an arc's `{start, end}`, a free
--- curve's `{start, controls..., end}`.
function Sketch:ends(id)
  local h = self:_h()
  local n = ffi.new("size_t[1]")
  return sketch_lent(lib().cadaclysm_blacksmith_sketch_ends(h, sketch_arg(id, "sketch_ends", "id"), n), n, "sketch_ends")
end

--- Marks entity `id` as construction geometry (kept out of profiles) when `on` (nil: true),
--- or back.
function Sketch:set_construction(id, on)
  local h = self:_h()
  if on == nil then on = true end
  if not lib().cadaclysm_blacksmith_sketch_set_construction(h, sketch_arg(id, "sketch_set_construction", "id"),
    on and true or false) then
    fail("sketch_set_construction")
  end
end

--- Whether entity `id` is construction geometry (false for an unknown id).
function Sketch:is_construction(id)
  local h = self:_h()
  return lib().cadaclysm_blacksmith_sketch_is_construction(h, sketch_arg(id, "sketch_is_construction", "id")) == true
end

--- Whether entity `id` is a reference copy of another sketch's (false for an unknown id).
function Sketch:is_reference(id)
  local h = self:_h()
  return lib().cadaclysm_blacksmith_sketch_is_reference(h, sketch_arg(id, "sketch_is_reference", "id")) == true
end

--- Removes entity `id` and the constraints on it: the removed constraint ids. Refused for a
--- point that lines or circles still use, the error's `ids` naming them.
function Sketch:remove_entity(id)
  local h = self:_h()
  local n = ffi.new("size_t[1]")
  local p = lib().cadaclysm_blacksmith_sketch_remove_entity(h, sketch_arg(id, "sketch_remove_entity", "id"), n)
  if p == nil then fail_ids("sketch_remove_entity", h) end
  return sketch_lent(p, n, "sketch_remove_entity")
end

local function other_sketch(other, call)
  if type(other) ~= "table" or getmetatable(other) ~= Sketch then
    raise(("%s: other must be a Sketch, not %s"):format(call, repr(other)))
  end
  return other:_h()
end

--- A fixed construction copy of `other`'s entity `entity`, kept in step by
--- `update_reference`. `other` must be another sketch.
function Sketch:reference(other, entity)
  local h = self:_h()
  local o = other_sketch(other, "sketch_reference")
  return sketch_id(lib().cadaclysm_blacksmith_sketch_reference(h, o, sketch_arg(entity, "sketch_reference", "entity")),
    "sketch_reference")
end

--- Refreshes the reference `id` from `other` and re-solves: a `SolveReport`.
function Sketch:update_reference(id, other)
  local h = self:_h()
  local o = other_sketch(other, "sketch_update_reference")
  local report = ffi.new("double[3]")
  return sketch_solved(lib().cadaclysm_blacksmith_sketch_update_reference(h,
    sketch_arg(id, "sketch_update_reference", "id"), o, report), report, "sketch_update_reference", h)
end

-- -- constraints: each returns the new constraint's id

-- `n` refs (a nil among them is refused, not dropped); a geometric kind passes value 0 and
-- driving true; `sense` nil is "auto", `end_` nil "start".
function Sketch:_constrain(kind, n, refs, value, driving, sense, end_)
  local h = self:_h()
  local sense_code = sketch_code(SKETCH_SENSES, sense == nil and "auto" or sense, kind, "sense")
  local end_code = sketch_code(SKETCH_ENDS, end_ == nil and "start" or end_, kind, "end")
  local ids = ffi.new("uint32_t[?]", n)
  for i = 1, n do ids[i - 1] = sketch_arg(refs[i], kind, "id") end
  local code = sketch_code(SKETCH_CONSTRAINT_KINDS, kind, "sketch_constrain", "kind")
  if driving == nil then driving = true end
  local got = lib().cadaclysm_blacksmith_sketch_constrain(h, code, ids, n, number(value, kind .. " value"),
    driving and true or false, sense_code, end_code)
  if got == NONE then fail_ids("sketch_constrain", h) end
  return got
end

--- The points `a` and `b` at one place.
function Sketch:coincident(a, b) return self:_constrain("coincident", 2, { a, b }, 0) end
--- The point `point` on the line `line`, taken as infinite.
function Sketch:point_on_line(point, line) return self:_constrain("point_on_line", 2, { point, line }, 0) end
--- The point `point` on the circle (or arc) `circle`.
function Sketch:point_on_circle(point, circle) return self:_constrain("point_on_circle", 2, { point, circle }, 0) end
--- The points `a` and `b` level with each other.
function Sketch:horizontal(a, b) return self:_constrain("horizontal", 2, { a, b }, 0) end
--- The points `a` and `b` one above the other.
function Sketch:vertical(a, b) return self:_constrain("vertical", 2, { a, b }, 0) end
function Sketch:parallel(a, b) return self:_constrain("parallel", 2, { a, b }, 0) end
function Sketch:perpendicular(a, b) return self:_constrain("perpendicular", 2, { a, b }, 0) end
function Sketch:collinear(a, b) return self:_constrain("collinear", 2, { a, b }, 0) end
--- `a` and `b` tangent, on the side `sense` (nil: "auto") says.
function Sketch:tangent(a, b, sense) return self:_constrain("tangent", 2, { a, b }, 0, true, sense) end
--- The free curve `curve` tangent to `other` at its `end_` ("start", the default, or "end").
function Sketch:tangent_at_end(curve, other, end_)
  return self:_constrain("tangent_at_end", 2, { curve, other }, 0, true, "auto", end_)
end
function Sketch:concentric(a, b) return self:_constrain("concentric", 2, { a, b }, 0) end
function Sketch:equal_length(a, b) return self:_constrain("equal_length", 2, { a, b }, 0) end
function Sketch:equal_radius(a, b) return self:_constrain("equal_radius", 2, { a, b }, 0) end
function Sketch:midpoint(point, line) return self:_constrain("midpoint", 2, { point, line }, 0) end
--- The points `a` and `b` mirror images across the line `about`.
function Sketch:symmetric(a, b, about) return self:_constrain("symmetric", 3, { a, b, about }, 0) end
function Sketch:fix(entity) return self:_constrain("fix", 1, { entity }, 0) end
--- Every dimension takes `driving` (nil: true).
function Sketch:distance(a, b, value, driving) return self:_constrain("distance", 2, { a, b }, value, driving) end
function Sketch:point_line_distance(point, line, value, driving, sense)
  return self:_constrain("point_line_distance", 2, { point, line }, value, driving, sense)
end
function Sketch:line_distance(a, b, value, driving, sense)
  return self:_constrain("line_distance", 2, { a, b }, value, driving, sense)
end
function Sketch:circle_line_distance(circle, line, value, driving, sense)
  return self:_constrain("circle_line_distance", 2, { circle, line }, value, driving, sense)
end
function Sketch:circle_distance(a, b, value, driving)
  return self:_constrain("circle_distance", 2, { a, b }, value, driving)
end
function Sketch:horizontal_distance(a, b, value, driving)
  return self:_constrain("horizontal_distance", 2, { a, b }, value, driving)
end
function Sketch:vertical_distance(a, b, value, driving)
  return self:_constrain("vertical_distance", 2, { a, b }, value, driving)
end
function Sketch:length(line, value, driving) return self:_constrain("length", 1, { line }, value, driving) end
--- The angle from line `a` to line `b`, in radians.
function Sketch:angle(a, b, value, driving) return self:_constrain("angle", 2, { a, b }, value, driving) end
--- The RADIUS dimension (kind "radius") -- `radius(id)` reads a radius instead.
function Sketch:radius_of(circle, value, driving) return self:_constrain("radius", 1, { circle }, value, driving) end
function Sketch:diameter(circle, value, driving) return self:_constrain("diameter", 1, { circle }, value, driving) end

--- The live constraint ids, ascending.
function Sketch:constraints()
  local h = self:_h()
  local n = ffi.new("size_t[1]")
  return sketch_lent(lib().cadaclysm_blacksmith_sketch_constraints(h, n), n, "sketch_constraints")
end

--- The kind of constraint `id`, e.g. "point_line_distance".
function Sketch:constraint_kind(id)
  local h = self:_h()
  return sketch_named(SKETCH_CONSTRAINT_KINDS, lib().cadaclysm_blacksmith_sketch_constraint_kind(h,
    sketch_arg(id, "sketch_constraint_kind", "id")), "sketch_constraint_kind")
end

--- The entity ids constraint `id` was made on, in the order given.
function Sketch:constraint_refs(id)
  local h = self:_h()
  local n = ffi.new("size_t[1]")
  return sketch_lent(lib().cadaclysm_blacksmith_sketch_constraint_refs(h, sketch_arg(id, "sketch_constraint_refs", "id"),
    n), n, "sketch_constraint_refs")
end

--- The value of the dimension `id`: a number, or nil for a constraint that is not a dimension.
--- An unknown id raises.
function Sketch:constraint_value(id)
  local h = self:_h()
  local v = lib().cadaclysm_blacksmith_sketch_constraint_value(h, sketch_arg(id, "sketch_constraint_value", "id"))
  if v ~= v then
    if last_error() ~= "" then fail("sketch_constraint_value") end
    return nil
  end
  return v
end

--- Whether the dimension `id` drives the geometry (false for a constraint that is not a
--- dimension). An unknown id raises.
function Sketch:constraint_driving(id)
  local h = self:_h()
  local driving = lib().cadaclysm_blacksmith_sketch_constraint_driving(h, sketch_arg(id, "sketch_constraint_driving", "id"))
  if not driving and last_error() ~= "" then fail("sketch_constraint_driving") end
  return driving == true
end

--- The sense of constraint `id`; "auto" for a kind without one.
function Sketch:constraint_sense(id)
  local h = self:_h()
  return sketch_named(SKETCH_SENSES, lib().cadaclysm_blacksmith_sketch_constraint_sense(h,
    sketch_arg(id, "sketch_constraint_sense", "id")), "sketch_constraint_sense")
end

--- The end ("start" or "end") of the free curve a `tangent_at_end` constraint `id` holds;
--- "start" for a kind without one.
function Sketch:constraint_end(id)
  local h = self:_h()
  return sketch_named(SKETCH_ENDS, lib().cadaclysm_blacksmith_sketch_constraint_end(h,
    sketch_arg(id, "sketch_constraint_end", "id")), "sketch_constraint_end")
end

--- Whether the tangent constraint `id` joins two curves end to end.
function Sketch:is_joint_tangent(id)
  local h = self:_h()
  return lib().cadaclysm_blacksmith_sketch_is_joint_tangent(h, sketch_arg(id, "sketch_is_joint_tangent", "id")) == true
end

--- Removes the constraint `id`.
function Sketch:remove(id)
  local h = self:_h()
  if not lib().cadaclysm_blacksmith_sketch_remove(h, sketch_arg(id, "sketch_remove", "id")) then fail("sketch_remove") end
end

--- Sets the dimension `id` to `value` and re-solves: a `SolveReport`.
function Sketch:set_value(id, value)
  local h = self:_h()
  local report = ffi.new("double[3]")
  return sketch_solved(lib().cadaclysm_blacksmith_sketch_set_value(h, sketch_arg(id, "sketch_set_value", "id"),
    number(value, "sketch_set_value"), report), report, "sketch_set_value", h)
end

--- Makes the dimension `id` drive the geometry (true) or only report it, and re-solves: a
--- `SolveReport`.
function Sketch:set_driving(id, driving)
  local h = self:_h()
  local report = ffi.new("double[3]")
  return sketch_solved(lib().cadaclysm_blacksmith_sketch_set_driving(h, sketch_arg(id, "sketch_set_driving", "id"),
    driving and true or false, report), report, "sketch_set_driving", h)
end

--- What the geometry measures for the dimension `id` right now.
function Sketch:measure(id)
  local h = self:_h()
  local v = lib().cadaclysm_blacksmith_sketch_measure(h, sketch_arg(id, "sketch_measure", "id"))
  if v ~= v then fail("sketch_measure") end
  return v
end

-- -- solving and diagnosis

--- Solves the sketch: a `SolveReport`. A conflicting or diverged solve is reported, not raised.
function Sketch:solve()
  local h = self:_h()
  local report = ffi.new("double[3]")
  return sketch_solved(lib().cadaclysm_blacksmith_sketch_solve(h, report), report, "sketch_solve", h)
end

-- The point ids of a drag's `moves`, checked and in ascending order: `pairs` walks a table in
-- no order the solve may depend on. (Exported as `M._sketch_drag_ids` for the tests only.)
local function sketch_drag_ids(moves)
  local keys = {}
  for id in pairs(moves) do keys[#keys + 1] = sketch_arg(id, "sketch_drag", "id") end
  table.sort(keys)
  return keys
end
M._sketch_drag_ids = sketch_drag_ids

--- Drags each point id in `moves` (`{[id] = {x, y}, ...}`) towards its target while the
--- constraints hold, as a live gesture would: a `SolveReport`. The points go to the library
--- in ascending id order, so the same moves always solve the same way. Refused for an id
--- that is not a point.
function Sketch:drag(moves)
  local h = self:_h()
  if type(moves) ~= "table" then
    raise(("sketch_drag: moves must be a table of point id to {x, y}, not %s"):format(repr(moves)))
  end
  local keys = sketch_drag_ids(moves)
  local n = #keys
  local points = ffi.new("uint32_t[?]", math.max(n, 1))
  local xy = ffi.new("double[?]", math.max(2 * n, 1))
  for i, id in ipairs(keys) do
    points[i - 1] = id
    xy[2 * i - 2], xy[2 * i - 1] = pair(moves[id], "sketch_drag")
  end
  local report = ffi.new("double[3]")
  return sketch_solved(lib().cadaclysm_blacksmith_sketch_drag(h, points, xy, n, report), report, "sketch_drag", h)
end

--- The sketch's degrees of freedom, whole and per independent part: a `Dof`.
function Sketch:diagnose()
  local h = self:_h()
  local out = ffi.new("double[3]")
  if not lib().cadaclysm_blacksmith_sketch_diagnose(h, out) then fail("sketch_diagnose") end
  local free = sketch_whole(out[0], "sketch_diagnose")
  local state = sketch_named(SKETCH_STATES, out[1], "sketch_diagnose")
  local part_count = sketch_whole(out[2], "sketch_diagnose")
  local n = ffi.new("size_t[1]")
  local function dof_list(which)
    return sketch_lent(lib().cadaclysm_blacksmith_sketch_dof_list(h, which, n), n, "sketch_dof_list")
  end
  local function part_list(i, which)
    return sketch_lent(lib().cadaclysm_blacksmith_sketch_dof_part_list(h, i, which, n), n, "sketch_dof_part_list")
  end
  local redundant = dof_list(DOF.redundant)
  local conflicting = dof_list(DOF.conflicting)
  local free_entities = dof_list(DOF.free_entities)
  local parts, part = {}, ffi.new("double[3]")
  for i = 0, part_count - 1 do
    if not lib().cadaclysm_blacksmith_sketch_dof_part(h, i, part) then fail("sketch_dof_part") end
    local params = sketch_whole(part[0], "sketch_dof_part")
    local part_free = sketch_whole(part[1], "sketch_dof_part")
    local part_state = sketch_named(SKETCH_STATES, part[2], "sketch_dof_part")
    local constraints = part_list(i, PART.constraints)
    local part_redundant = part_list(i, PART.redundant)
    local part_conflicting = part_list(i, PART.conflicting)
    local part_free_entities = part_list(i, PART.free_entities)
    parts[i + 1] = setmetatable({
      params = params, free = part_free, state = part_state, constraints = constraints,
      redundant = part_redundant, conflicting = part_conflicting, free_entities = part_free_entities,
    }, PartDof)
  end
  return setmetatable({
    free = free, state = state, redundant = redundant, conflicting = conflicting,
    free_entities = free_entities, parts = parts,
  }, Dof)
end

--- The closed loops as profiles (nested loops become holes; construction geometry left
--- out); ends within `tolerance` (nil: 1e-6) join.
function Sketch:profiles(tolerance)
  local h = self:_h()
  return profile_list(lib().cadaclysm_blacksmith_sketch_profiles(h,
    number(tolerance == nil and 1e-6 or tolerance, "sketch_profiles tolerance")), "sketch_profiles")
end

--- The paths that do not close, as profiles; ends within `tolerance` (nil: 1e-6) join.
function Sketch:open_chains(tolerance)
  local h = self:_h()
  return profile_list(lib().cadaclysm_blacksmith_sketch_open_chains(h,
    number(tolerance == nil and 1e-6 or tolerance, "sketch_open_chains tolerance")), "sketch_open_chains")
end

Sketch.__tostring = function(self)
  return rawget(self, "_ptr") == nil and "Sketch(closed)" or "Sketch()"
end

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

-- ---- transforms and quaternions ------------------------------------------------------------

-- In a block of its own: the main chunk is at LuaJIT's limit of 200 live locals, so only
-- `M.Transform` (with `Transform._matrix`, which `Solid:transform` reads) and `M.Quaternion`
-- leave it.
do

local Transform, Quaternion

-- Python's `_flat16`: a Transform's numbers, four rows of four flattened, anything else as
-- it is -- four plain numbers are not four rows, and fall to the caller's count check.
local function flat16(rows, what)
  if type(rows) ~= "table" then raise(what .. ": expected 16 numbers, got " .. repr(rows)) end
  if getmetatable(rows) == Transform then return rawget(rows, "_r") end
  if #rows == 4 and type(rows[1]) == "table" and type(rows[2]) == "table" and type(rows[3]) == "table"
      and type(rows[4]) == "table" then
    local flat = {}
    for _, row in ipairs(rows) do
      for j = 1, #row do flat[#flat + 1] = row[j] end
    end
    return flat
  end
  return rows
end

-- A Transform, 16 numbers row-major or four rows of four, as the C array.
local function matrix_arg(m, what)
  return doubles(flat16(m, what), 16, what)
end

-- How far from rigid, or from a similarity, a map may be and still be told one, by default.
local MAP_TOLERANCE = 1e-9
local IDENTITY_ROWS = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }

local function finite(v) return v == v and v ~= math.huge and v ~= -math.huge end

-- out[i .. j] (a C array, from zero) as a fresh Lua array.
local function c_slice(out, i, j)
  local r = {}
  for k = i, j do r[#r + 1] = out[k] end
  return r
end

--- An affine map of space: a 4x4 matrix, row-major, its bottom row `0 0 0 1`.
--- Immutable, with nothing to free; `t[i]` reads its sixteen numbers (i = 1..16) as
--- Python's iteration does, so it goes wherever sixteen numbers do. `a * b` (or
--- `a:compose(b)`) is `a` after `b`. The constructors and the decompositions are the
--- library's own, so every wrapper computes them alike. A frame argument is a `Frame` or
--- twelve numbers; one within 1e-6 of right-handed and orthonormal is squared up, any
--- other raises `BuildError`. `Transform.new(rows)` or `Transform(rows)`: sixteen numbers
--- row-major or four rows of four (none: the identity), refused with a `BuildError` for a
--- wrong count, a number that is not finite, or a bottom row that is not `0 0 0 1`.
---@class Transform
Transform = {}
local Transform_get = {}
M.Transform = Transform
Transform.__index = function(self, key)
  if type(key) == "number" then return rawget(self, "_r")[key] end
  local get = Transform_get[key]
  if get then return get(self) end
  return Transform[key]
end
callable(Transform)

function Transform.new(rows)
  if rows == nil then rows = IDENTITY_ROWS end
  local flat = flat16(rows, "Transform")
  if #flat ~= 16 then raise(("Transform: a matrix is 16 numbers, got %d"):format(#flat)) end
  local r = {}
  for i = 1, 16 do r[i] = number(flat[i], "Transform") + 0.0 end   -- + 0.0: no -0.0 to print or compare
  for i = 1, 16 do
    if not finite(r[i]) then raise("Transform: not finite") end
  end
  if r[13] ~= 0 or r[14] ~= 0 or r[15] ~= 0 or r[16] ~= 1 then
    raise("Transform: the bottom row must be 0 0 0 1 (a projective map is not affine)")
  end
  return setmetatable({ _r = r }, Transform)
end

-- The map a library constructor wrote into `out`, or its refusal.
local function made_transform(what, ok, out)
  if not ok then fail(what) end
  return Transform.new(c_slice(out, 0, 15))
end

--- The map sixteen numbers state, row-major (or four rows of four).
function Transform.from_rows(rows)
  return Transform.new(rows)
end

--- The map that moves nothing.
function Transform.identity()
  return Transform.new()
end

--- `p + v`.
function Transform.translation(v)
  local out = ffi.new("double[16]")
  return made_transform("transform_translation",
    lib().cadaclysm_blacksmith_transform_translation(doubles(v, 3, "transform_translation"), out), out)
end

--- A turn of `radians` about the line through `point` along `direction`, right-handed.
function Transform.rotation(point, direction, radians)
  local px, py, pz = triple(point, "transform_rotation")
  local dx, dy, dz = triple(direction, "transform_rotation")
  local out = ffi.new("double[16]")
  return made_transform("transform_rotation", lib().cadaclysm_blacksmith_transform_rotation(
    doubles({ px, py, pz, dx, dy, dz }, 6, "transform_rotation"), number(radians, "transform_rotation"), out), out)
end

--- The reflection across `plane` (its z the normal).
function Transform.mirror(plane)
  local out = ffi.new("double[16]")
  return made_transform("transform_mirror", lib().cadaclysm_blacksmith_transform_mirror(frame_arg(plane), out), out)
end

--- A uniform scale by `k` about `centre`.
function Transform.scale(centre, k)
  local out = ffi.new("double[16]")
  return made_transform("transform_scale", lib().cadaclysm_blacksmith_transform_scale(
    doubles(centre, 3, "transform_scale"), number(k, "transform_scale"), out), out)
end

--- A scale by `sx`, `sy`, `sz` along `frame`'s axes, about its origin.
function Transform.scale_xyz(frame, sx, sy, sz)
  local out = ffi.new("double[16]")
  return made_transform("transform_scale_xyz", lib().cadaclysm_blacksmith_transform_scale_xyz(frame_arg(frame),
    number(sx, "transform_scale_xyz"), number(sy, "transform_scale_xyz"), number(sz, "transform_scale_xyz"), out), out)
end

--- Every point slid along `direction` by `factor` times its height above `plane`.
--- `direction` is normalised -- `factor` alone sets the slide -- and must lie in the plane.
function Transform.shear(plane, direction, factor)
  local out = ffi.new("double[16]")
  return made_transform("transform_shear", lib().cadaclysm_blacksmith_transform_shear(frame_arg(plane),
    doubles(direction, 3, "transform_shear"), number(factor, "transform_shear"), out), out)
end

--- The rigid map sending frame `a` onto frame `b`.
function Transform.plane_to_plane(a, b)
  local out = ffi.new("double[16]")
  return made_transform("transform_plane_to_plane",
    lib().cadaclysm_blacksmith_transform_plane_to_plane(frame_arg(a), frame_arg(b), out), out)
end

--- Coordinates in frame `from` to coordinates in frame `to`: a change of basis.
function Transform.change_basis(from, to)
  local out = ffi.new("double[16]")
  return made_transform("transform_change_basis",
    lib().cadaclysm_blacksmith_transform_change_basis(frame_arg(from), frame_arg(to), out), out)
end

--- The orthogonal projection onto `plane` -- singular by design.
function Transform.planar_projection(plane)
  local out = ffi.new("double[16]")
  return made_transform("transform_planar_projection",
    lib().cadaclysm_blacksmith_transform_planar_projection(frame_arg(plane), out), out)
end

--- The parallel projection onto `plane` along `direction`, which must not lie in it.
function Transform.project_along(plane, direction)
  local out = ffi.new("double[16]")
  return made_transform("transform_project_along", lib().cadaclysm_blacksmith_transform_project_along(frame_arg(plane),
    doubles(direction, 3, "transform_project_along"), out), out)
end

--- The sixteen numbers, row-major, as a fresh Lua array.
function Transform_get.rows(self) return slice(self._r, 1, 16) end

--- The sixteen numbers, row-major, as a fresh Lua array (`rows`, as `Frame:values`).
function Transform:values() return slice(self._r, 1, 16) end

--- Where the map takes the point `p` ({x, y, z}), a fresh {x, y, z}.
function Transform:point(p)
  local x, y, z = triple(p, "point")
  local r = self._r
  return { r[1] * x + r[2] * y + r[3] * z + r[4], r[5] * x + r[6] * y + r[7] * z + r[8],
    r[9] * x + r[10] * y + r[11] * z + r[12] }
end

--- This map after `other` (a Transform or sixteen numbers): `self * other`.
function Transform:compose(other)
  local out = ffi.new("double[16]")
  return made_transform("transform_compose", lib().cadaclysm_blacksmith_transform_compose(
    matrix_arg(self, "transform_compose"), matrix_arg(other, "transform_compose"), out), out)
end

Transform.__mul = function(a, b)
  if type(a) ~= "table" or getmetatable(a) ~= Transform then raise("transform_compose: expected a Transform, got " .. repr(a)) end
  return a:compose(b)
end

--- The map undoing this one; raises `BuildError` for a singular map.
function Transform:inverse()
  local out = ffi.new("double[16]")
  return made_transform("transform_inverse",
    lib().cadaclysm_blacksmith_transform_inverse(matrix_arg(self, "transform_inverse"), out), out)
end

--- Whether the linear part is orthogonal (`AᵀA = I` to `tolerance`, by default 1e-9): a
--- rotation or a mirror. `Solid:transform` is looser: it applies a map within 1e-6 of a
--- similarity as that similarity.
function Transform:is_rigid(tolerance)
  if tolerance == nil then tolerance = MAP_TOLERANCE end
  local r = lib().cadaclysm_blacksmith_transform_is_rigid(matrix_arg(self, "transform_is_rigid"),
    number(tolerance, "transform_is_rigid"))
  if r == NONE then fail("transform_is_rigid") end
  return r == 1
end

--- The scale `k` where the linear part is `k` times an orthogonal one (`AᵀA = k²I` to
--- `tolerance`, relative to `k²`; by default 1e-9), else nil.
function Transform:is_similarity(tolerance)
  if tolerance == nil then tolerance = MAP_TOLERANCE end
  local k = lib().cadaclysm_blacksmith_transform_is_similarity(matrix_arg(self, "transform_is_similarity"),
    number(tolerance, "transform_is_similarity"))
  if k ~= k then fail("transform_is_similarity") end
  if k > 0 then return k end
  return nil
end

--- `{ translation = {x, y, z}, orthogonal = Transform }` for a rigid map, else nil.
function Transform:decompose_rigid(tolerance)
  if tolerance == nil then tolerance = MAP_TOLERANCE end
  if not self:is_rigid(tolerance) then return nil end
  local out = ffi.new("double[19]")
  if not lib().cadaclysm_blacksmith_transform_decompose_rigid(matrix_arg(self, "transform_decompose_rigid"),
      number(tolerance, "transform_decompose_rigid"), out) then
    fail("transform_decompose_rigid")
  end
  return { translation = c_slice(out, 0, 2), orthogonal = Transform.new(c_slice(out, 3, 18)) }
end

--- `{ translation = {x, y, z}, orthogonal = Transform, k = number }` for a similarity, else nil.
function Transform:decompose_similarity(tolerance)
  if tolerance == nil then tolerance = MAP_TOLERANCE end
  if self:is_similarity(tolerance) == nil then return nil end
  local out = ffi.new("double[20]")
  if not lib().cadaclysm_blacksmith_transform_decompose_similarity(matrix_arg(self, "transform_decompose_similarity"),
      number(tolerance, "transform_decompose_similarity"), out) then
    fail("transform_decompose_similarity")
  end
  return { translation = c_slice(out, 0, 2), orthogonal = Transform.new(c_slice(out, 3, 18)), k = out[19] }
end

--- The polar split of the map: `{ translation, rotation, axes, stretch }` with the linear
--- part `rotation * axes * diag(stretch) * axesᵀ` -- `rotation` carrying the mirror, `axes`
--- a proper rotation whose columns are the stretch directions, the stretches largest first.
--- nil for a singular map or one stretched past 1e7:1, which has no unique split.
function Transform:decompose_affine()
  local out = ffi.new("double[38]")
  if not lib().cadaclysm_blacksmith_transform_decompose_affine(matrix_arg(self, "transform_decompose_affine"), out) then
    return nil
  end
  return { translation = c_slice(out, 0, 2), rotation = Transform.new(c_slice(out, 3, 18)),
    axes = Transform.new(c_slice(out, 19, 34)), stretch = c_slice(out, 35, 37) }
end

Transform.__eq = function(a, b)
  for i = 1, 16 do
    if a._r[i] ~= b._r[i] then return false end
  end
  return true
end

Transform.__tostring = function(self)
  return "Transform({" .. table.concat(self._r, ", ") .. "})"
end

--- A rotation as `w + xi + yj + zk`. Immutable; `q[i]` reads `w, x, y, z` (i = 1..4). `q`
--- and `-q` are the same rotation; a non-unit one is normalised wherever it becomes a
--- rotation, a zero one raises `BuildError` there. `a * b` turns by `b`, then `a`. `==` is
--- by components, so `q ~= -q` although the two are the same rotation.
--- `Quaternion.new(w, x, y, z)` or `Quaternion(w, x, y, z)` (default 1, 0, 0, 0); a number
--- that is not finite raises `BuildError`.
---@class Quaternion
Quaternion = {}
local Quaternion_get = {}
M.Quaternion = Quaternion
Quaternion.__index = function(self, key)
  if type(key) == "number" then return rawget(self, "_q")[key] end
  local get = Quaternion_get[key]
  if get then return get(self) end
  return Quaternion[key]
end
callable(Quaternion)

function Quaternion.new(w, x, y, z)
  if w == nil then w = 1.0 end
  local q = { number(w, "Quaternion") + 0.0, number(x or 0, "Quaternion") + 0.0,
    number(y or 0, "Quaternion") + 0.0, number(z or 0, "Quaternion") + 0.0 }
  for i = 1, 4 do
    if not finite(q[i]) then raise("Quaternion: not finite") end
  end
  return setmetatable({ _q = q }, Quaternion)
end

local function made_quaternion(what, ok, out)
  if not ok then fail(what) end
  return Quaternion.new(out[0], out[1], out[2], out[3])
end

-- A Quaternion or four numbers `w, x, y, z`, as the C array.
local function quaternion_arg(q, what)
  if type(q) == "table" and getmetatable(q) == Quaternion then return doubles(rawget(q, "_q"), 4, what) end
  return doubles(q, 4, what)
end

--- The turn of `radians` about `direction`, right-handed.
function Quaternion.from_axis_angle(direction, radians)
  local out = ffi.new("double[4]")
  return made_quaternion("quaternion_from_axis_angle", lib().cadaclysm_blacksmith_quaternion_from_axis_angle(
    doubles(direction, 3, "quaternion_from_axis_angle"), number(radians, "quaternion_from_axis_angle"), out), out)
end

--- The rotation in `t`'s linear part (its translation ignored); raises `BuildError` unless
--- that is a proper rotation, orthogonal to 1e-9. Take `t:decompose_affine().rotation`
--- first for a rotation rounded to float32.
function Quaternion.from_transform(t)
  local out = ffi.new("double[4]")
  return made_quaternion("quaternion_from_transform",
    lib().cadaclysm_blacksmith_quaternion_from_transform(matrix_arg(t, "quaternion_from_transform"), out), out)
end

--- From `a` (`s = 0`) to `b` (`s = 1`) the shorter way.
function Quaternion.slerp(a, b, s)
  local out = ffi.new("double[4]")
  return made_quaternion("quaternion_slerp", lib().cadaclysm_blacksmith_quaternion_slerp(
    quaternion_arg(a, "quaternion_slerp"), quaternion_arg(b, "quaternion_slerp"), number(s, "quaternion_slerp"), out), out)
end

--- This rotation as a `Transform` fixing `centre` (default {0, 0, 0}).
function Quaternion:to_transform(centre)
  if centre == nil then centre = { 0, 0, 0 } end
  local out = ffi.new("double[16]")
  return made_transform("quaternion_to_transform", lib().cadaclysm_blacksmith_quaternion_to_transform(
    quaternion_arg(self, "quaternion_to_transform"), doubles(centre, 3, "quaternion_to_transform"), out), out)
end

function Quaternion_get.w(self) return self._q[1] end
function Quaternion_get.x(self) return self._q[2] end
function Quaternion_get.y(self) return self._q[3] end
function Quaternion_get.z(self) return self._q[4] end

-- The length of `vs`, scaled by its largest component first, as the ABI's
-- `quaternion_from` does: squaring 1e200 overflows and 1e-170 underflows.
local function scaled_norm(vs)
  local big = 0
  for _, v in ipairs(vs) do big = math.max(big, math.abs(v)) end
  if big == 0 then return 0.0 end
  local sum = 0
  for _, v in ipairs(vs) do
    local c = v / big
    sum = sum + c * c
  end
  return big * math.sqrt(sum)
end

--- Its length; 1 for a rotation as made here.
function Quaternion_get.length(self) return scaled_norm(self._q) end

--- The turn, in `[0, 2π]`.
function Quaternion_get.angle(self)
  local q = self._q
  return 2.0 * math.atan2(scaled_norm({ q[2], q[3], q[4] }), q[1])
end

--- The turn's axis, a unit {x, y, z}; nil for the identity.
function Quaternion_get.axis(self)
  local q = self._q
  local big = math.max(math.abs(q[2]), math.abs(q[3]), math.abs(q[4]))
  if big == 0 then return nil end
  local x, y, z = q[2] / big, q[3] / big, q[4] / big
  local n = math.sqrt(x * x + y * y + z * z)
  return { x / n, y / n, z / n }
end

--- The opposite turn.
function Quaternion:conjugate()
  local q = self._q
  return Quaternion.new(q[1], -q[2], -q[3], -q[4])
end

--- The same rotation at unit length, scaled by its largest component before the square
--- root (as the ABI's `quaternion_from` does), so 1e200 and 1e-170 normalise. A zero
--- quaternion raises `BuildError`.
function Quaternion:normalized()
  local q = self._q
  local big = math.max(math.abs(q[1]), math.abs(q[2]), math.abs(q[3]), math.abs(q[4]))
  if big == 0 then raise("Quaternion.normalized: the quaternion is zero") end
  local w, x, y, z = q[1] / big, q[2] / big, q[3] / big, q[4] / big
  local n = math.sqrt(w * w + x * x + y * y + z * z)
  return Quaternion.new(w / n, x / n, y / n, z / n)
end

--- `w, x, y, z` as a fresh Lua array.
function Quaternion:values() return slice(self._q, 1, 4) end

Quaternion.__mul = function(p, o)
  if type(p) ~= "table" or getmetatable(p) ~= Quaternion or type(o) ~= "table" or getmetatable(o) ~= Quaternion then
    raise("Quaternion: a product is of two quaternions, got " .. repr(p) .. " and " .. repr(o))
  end
  local a, b = p._q, o._q
  return Quaternion.new(a[1] * b[1] - a[2] * b[2] - a[3] * b[3] - a[4] * b[4],
    a[1] * b[2] + a[2] * b[1] + a[3] * b[4] - a[4] * b[3],
    a[1] * b[3] - a[2] * b[4] + a[3] * b[1] + a[4] * b[2],
    a[1] * b[4] + a[2] * b[3] - a[3] * b[2] + a[4] * b[1])
end

Quaternion.__eq = function(a, b)
  for i = 1, 4 do
    if a._q[i] ~= b._q[i] then return false end
  end
  return true
end

Quaternion.__tostring = function(self)
  return "Quaternion(" .. table.concat(self._q, ", ") .. ")"
end

-- A Transform, 16 numbers row-major or four rows of four, as the C array: for `Solid:transform`,
-- outside this block.
Transform._matrix = matrix_arg

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

-- The `.3dm` writers' two helpers, one table: the main chunk is at LuaJIT's limit of 200
-- live locals.
local dm3 = {}

-- What a `.3dm` write did not write as itself -- `last_error` on a success, a line
-- each -- said on standard error, one line each.
function dm3.warn()
  for line in last_error():gmatch("[^\n]+") do
    io.stderr:write("3dm: ", line, "\n")
  end
end

-- The bytes a `.3dm` call handed over (`len` a `size_t[1]`), copied out as a Lua
-- string and released with `bytes_free` (never `string_free`), its notes warned; a
-- null is the failure `last_error` names.
function dm3.taken(raw, len, what)
  if raw == nil then fail(what) end
  dm3.warn()
  local n = tonumber(len[0])
  local result = ffi.string(raw, n)
  lib().cadaclysm_blacksmith_bytes_free(raw, n)
  return result
end

--- Several solids (a Lua array) as one Rhino `.3dm` (version 8, which Rhino 8
--- and 9 open), as a Lua string of its bytes: one object each, its exact brep,
--- or -- where a body has no exact form there -- its mesh, with a warning saying
--- so. Each object is named as its solid is, coloured with the solid's own colour
--- (a face's or an edge's own is left out) and carries the solid's attributes as
--- user text. `unit` "mm" (default), "m" or "in" is the file's: the numbers
--- written are the numbers held. The warnings -- one a line of what was not
--- written as itself -- go to `io.stderr`, each starting "3dm: ".
function M.rhino3dm_bytes(solids, unit)
  if unit == nil then unit = "mm" end
  if UNITS[unit] == nil then raise("unit must be one of ['in', 'm', 'mm']") end
  local n = #solids
  local handles = ffi.new("const struct CadaclysmBlacksmithSolid *[?]", math.max(n, 1))
  for i = 1, n do handles[i - 1] = solid_handle(solids[i], "rhino3dm_bytes") end
  local len = ffi.new("size_t[1]")
  return dm3.taken(lib().cadaclysm_blacksmith_3dm_bytes(handles, n, UNITS[unit], len), len, "3dm_bytes")
end

--- `rhino3dm_bytes` written to `path` by the library itself, which names the
--- file in its refusal when it cannot.
function M.write_3dm(path, solids, unit)
  if unit == nil then unit = "mm" end
  if UNITS[unit] == nil then raise("unit must be one of ['in', 'm', 'mm']") end
  local n = #solids
  local handles = ffi.new("const struct CadaclysmBlacksmithSolid *[?]", math.max(n, 1))
  for i = 1, n do handles[i - 1] = solid_handle(solids[i], "write_3dm") end
  if not lib().cadaclysm_blacksmith_3dm(handles, n, tostring(path), UNITS[unit]) then fail("3dm") end
  dm3.warn()
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

  -- the C ABI reads a NaN pitch as "not given", the same way Python's wrapper passes `float("nan")`
  local pitch_arg = 0 / 0
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

-- In a block of its own: the main chunk is at LuaJIT's limit of 200 live locals, so only
-- `Assembly:parts` and `Assembly:swept_clash` leave it.
do

local swept_clashes_of, allowed_pairs = M._swept_clashes_of, M._allowed_pairs

--- The placement path of every solid under this assembly, at any depth: depth first,
--- placements in order, names joined by "/" with a "/" or backslash inside a name escaped
--- with a backslash (as `posed`'s keys). The index `swept_clash`'s rows use.
---@return string[]
function Assembly:parts()
  local L, h = lib(), self:_h()
  local names = {}
  for i = 0, tonumber(L.cadaclysm_blacksmith_assembly_part_count(h)) - 1 do
    local raw = L.cadaclysm_blacksmith_assembly_part_path(h, i)
    if raw == nil then fail("assembly_part_path") end
    names[#names + 1] = ffi.string(raw)
    L.cadaclysm_blacksmith_string_free(raw)
  end
  return names
end

-- Keyframe `k` (from 0) as `posed` reads its values -- a list of {key, value} rows, or a map
-- with string keys taken in sorted order -- as {{path, {numbers}}, ...}.
local function keyframe_rows(frame, k)
  local what = ("swept_clash: keyframe %d"):format(k)
  local rows = {}
  local count = list_count(frame)
  if count ~= nil then
    for i = 1, count do
      local row = frame[i]
      if type(row) ~= "table" then
        raise(("%s: row %d must be a table {key, value}, not %s"):format(what, i, repr(row)))
      end
      rows[i] = { row[1], row[2] }
    end
  elseif type(frame) == "table" then
    local keys = {}
    for key in pairs(frame) do
      if type(key) ~= "string" then raise(what .. ": a map takes string keys, not " .. repr(key)) end
      keys[#keys + 1] = key
    end
    table.sort(keys)
    for i, key in ipairs(keys) do rows[i] = { key, frame[key] } end
  else
    raise(what .. " must be a list of {key, value} rows or a map, not " .. repr(frame))
  end
  for i, row in ipairs(rows) do
    local path = joint_path(row[1], ("%s: row %d's key"):format(what, i))
    local list = row[2]
    if type(list) == "number" then list = { list } end
    local n = list_count(list)
    if n == nil then
      raise(("%s: row %d's value must be a number or a list of numbers, not %s"):format(what, i, repr(row[2])))
    end
    local values = {}
    for j = 1, n do values[j] = number(list[j], ("%s: row %d's value %d"):format(what, i, j)) end
    rows[i] = { path, values }
  end
  return rows
end

--- Every pair of this assembly's solids (indexed as `parts()` lists them) that penetrates,
--- touches or comes within `opts.clearance` of the other anywhere while this assembly's own
--- mechanism moves through `keyframes`, as `SweptClash` rows. Each keyframe is the joints'
--- values as `posed` takes them -- a list of {key, value} rows, or a map with string keys
--- (taken in sorted order) -- and every keyframe names the same joints, the first fixing their
--- order; time runs in keyframe units, keyframe `k` (from 0) at time `k`. Between two keyframes
--- each joint value moves linearly and each link is posed from those values, so a link swinging
--- about a joint goes round its arc, not along its chord. Only this assembly's own joints move:
--- a sub-assembly rides the link its placement is in.
---
--- `opts` (nil for every default): `clearance` (0); `tolerance` (0.05), the meshing tolerance;
--- `resolution` (1e-3) and `max_steps` (100000) as `Collider:swept_clash`'s; `allowed`, pairs
--- of part indices never tested, flat as `clash`'s: {a0, b0, a1, b1, ...}; `ground`, one of
--- this assembly's links held fixed (nil for its default; solids in no link stay still);
--- `joined` (false), whether to test pairs on two links a joint joins. Raises `BuildError` in
--- the kernel's `swept_clash:` words: a later keyframe naming other joints than keyframe 0, a
--- joint given twice, or a joint with another number of values than in keyframe 0 is refused
--- before the kernel is asked.
---@param keyframes table[]
---@param opts? {clearance?: number, tolerance?: number, resolution?: number, max_steps?: integer, allowed?: integer[], ground?: string, joined?: boolean}
---@return SweptClash[]
function Assembly:swept_clash(keyframes, opts)
  local h = self:_h()
  if opts == nil then opts = {} end
  if type(opts) ~= "table" then raise("swept_clash: opts must be a table or nil, not " .. repr(opts)) end
  local key_count = list_count(keyframes)
  if key_count == nil then raise("swept_clash: keyframes must be a list of keyframes, not " .. repr(keyframes)) end
  local frames = {}
  for k = 1, key_count do frames[k] = keyframe_rows(keyframes[k], k - 1) end
  -- C takes one joint set for every keyframe, keyframe 0's, and the values key-major: a later
  -- keyframe naming other joints is refused here, in the kernel's words, before C is called
  local keys, counts, flat, in_first = {}, {}, {}, {}
  for i, row in ipairs(frames[1] or {}) do
    keys[i], counts[i], in_first[row[1]] = row[1], #row[2], true
    for _, v in ipairs(row[2]) do flat[#flat + 1] = v end
  end
  for k = 2, key_count do
    local values = {}
    for _, row in ipairs(frames[k]) do values[row[1]] = true end
    for _, key in ipairs(keys) do
      if not values[key] then
        raise(("swept_clash: joint '%s' is in keyframe 0 and not in keyframe %d"):format(key, k - 1))
      end
    end
    for _, row in ipairs(frames[k]) do
      if not in_first[row[1]] then
        raise(("swept_clash: joint '%s' is in keyframe %d and not in keyframe 0"):format(row[1], k - 1))
      end
    end
    values = {}
    for _, row in ipairs(frames[k]) do
      if values[row[1]] then raise(("swept_clash: joint '%s' is given twice"):format(row[1])) end
      values[row[1]] = row[2]
    end
    for i, key in ipairs(keys) do
      local got = values[key]
      if #got ~= counts[i] then
        raise(("swept_clash: joint '%s' has %d values in keyframe 0 and %d in keyframe %d")
          :format(key, counts[i], #got, k - 1))
      end
      for _, v in ipairs(got) do flat[#flat + 1] = v end
    end
  end
  local clearance = number(opts.clearance == nil and 0 or opts.clearance, "swept_clash: clearance")
  local tolerance = number(opts.tolerance == nil and 0.05 or opts.tolerance, "swept_clash: tolerance")
  local resolution = number(opts.resolution == nil and 1e-3 or opts.resolution, "swept_clash: resolution")
  local max_steps = number(opts.max_steps == nil and 100000 or opts.max_steps, "swept_clash: max_steps")
  local ground = opts.ground
  if ground ~= nil and type(ground) ~= "string" then
    raise("swept_clash: ground must be a string, got " .. repr(ground))
  end
  local pairs_arr, pair_count = allowed_pairs(opts.allowed, "swept_clash")
  -- `keys` stays referenced for the whole call below, so the Lua strings `joint_ptrs` points
  -- into cannot be collected
  local joint_ptrs = ffi.new("const char*[?]", math.max(#keys, 1))
  local counts_arr = ffi.new("uint32_t[?]", math.max(#keys, 1))
  for i, key in ipairs(keys) do joint_ptrs[i - 1], counts_arr[i - 1] = key, counts[i] end
  local values_arr = ffi.new("double[?]", math.max(#flat, 1))
  for i, v in ipairs(flat) do values_arr[i - 1] = v end
  local found = lib().cadaclysm_blacksmith_assembly_swept_clash(h, joint_ptrs, counts_arr, #keys, values_arr,
    key_count, ground, tolerance, clearance, resolution, max_steps, pairs_arr, pair_count, opts.joined and true or false)
  if found == nil then fail("assembly_swept_clash") end
  return swept_clashes_of(found)
end

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

--- This assembly, and everything placed under it, as one Rhino `.3dm` (a Lua
--- string of its bytes): each distinct part (as `step_text` counts them) a block
--- holding its body, each sub-assembly a block of references to what it places
--- -- nested assemblies are nested blocks -- and this assembly's own placements
--- references at the top of the file, on a layer named after it. Each reference
--- is named as its placement was. `unit` and the warnings as `rhino3dm_bytes`.
--- Raises `BuildError`, as `step_text` does, for an assembly reachable from this
--- one that places nothing.
function Assembly:rhino3dm_bytes(unit)
  if unit == nil then unit = "mm" end
  if UNITS[unit] == nil then raise("unit must be one of ['in', 'm', 'mm']") end
  local len = ffi.new("size_t[1]")
  return dm3.taken(lib().cadaclysm_blacksmith_assembly_3dm_bytes(self:_h(), UNITS[unit], len), len, "assembly_3dm_bytes")
end

--- Write this assembly to a Rhino `.3dm` at `path`, by the library itself, which
--- names the file in its refusal when it cannot; `unit` as `rhino3dm_bytes`.
function Assembly:write_3dm(path, unit)
  if unit == nil then unit = "mm" end
  if UNITS[unit] == nil then raise("unit must be one of ['in', 'm', 'mm']") end
  if not lib().cadaclysm_blacksmith_assembly_3dm(self:_h(), tostring(path), UNITS[unit]) then fail("assembly_3dm") end
  dm3.warn()
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
--- naming the tool involved), `top` and `bottom` (the Z range it stands over: a corner's
--- band, a hole's depth, a slope's span, or for `too_deep` the flutes' reach down to the
--- level), and `region` (its XY area, as a table of `Profile`). Copied out; read-only.
---@class ReportItem
---@field kind string
---@field at number[]
---@field size number
---@field top number
---@field bottom number
---@field reason string
---@field region Profile[]
local ReportItem = {}
class(ReportItem)
M.ReportItem = ReportItem

ReportItem.__tostring = function(self)
  return ("ReportItem(kind=%s, at=(%g, %g, %g), size=%g, reason=%s, top=%g, bottom=%g, region=%d profile(s))"):format(
    self.kind, self.at[1], self.at[2], self.at[3], self.size, self.reason, self.top, self.bottom, #self.region)
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
    top = tonumber(lib().cadaclysm_blacksmith_report_top(raw, i)),
    bottom = tonumber(lib().cadaclysm_blacksmith_report_bottom(raw, i)),
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
--- with `end_mill` -- one `Tool`, or a table of them, each corner the first cut left
--- uncut taken up by the next (rest machining) -- its holes drilled with whichever of `drills` fits each -- a tool per
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
  local n = #list
  local handles = ffi.new("const struct CadaclysmBlacksmithTool *[?]", math.max(n, 1))
  for i = 1, n do handles[i - 1] = tool_handle(list[i], "machine") end
  local raw
  if type(end_mill) == "table" and getmetatable(end_mill) ~= Tool then
    -- A table of end mills, counted by its keys (`#` stops at a hole, so `{ a, nil, c }`
    -- could read as one tool): a hole is a nil tool, refused at its place.
    local m = 0
    for k in pairs(end_mill) do
      if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
        raise("machine: end_mill must be a Tool or a list of Tools, not " .. repr(end_mill))
      end
      m = m + 1
    end
    local ends = ffi.new("const struct CadaclysmBlacksmithTool *[?]", math.max(m, 1))
    for i = 1, m do
      local e = end_mill[i]
      if type(e) ~= "table" or getmetatable(e) ~= Tool then raise(("machine: end_mill[%d] must be a Tool, got %s"):format(i, repr(e))) end
      ends[i - 1] = e._handle
    end
    raw = lib().cadaclysm_blacksmith_job_machine_with(h, ph, ends, m, handles, n, or_nan(stepover), or_nan(stepdown), skin,
      or_nan(peck))
    if raw == nil then fail("job_machine_with") end
  else
    local eh = tool_handle(end_mill, "machine")
    raw = lib().cadaclysm_blacksmith_job_machine(h, ph, eh, handles, n, or_nan(stepover), or_nan(stepdown), skin,
      or_nan(peck))
    if raw == nil then fail("job_machine") end
  end
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


-- ---- value geometry: Interval, the frame verbs, the feet and the nine values ----------------

-- In a function of its own: the main chunk is at LuaJIT's limit of 200 live locals, so only
-- what `M` (and `Frame`, `Curve`) carries leaves it.
do
local function value_geometry()

local Transform = M.Transform

local function finite(v) return v == v and v ~= math.huge and v ~= -math.huge end

-- out[i .. j] (a C array, from zero) as a fresh Lua array.
local function c_slice(out, i, j)
  local r = {}
  for k = i, j do r[#r + 1] = out[k] end
  return r
end

-- A Lua array of numbers as a C array.
local function c_array(v)
  local out = ffi.new("double[?]", math.max(#v, 1))
  for i = 1, #v do out[i - 1] = v[i] end
  return out
end

-- A point as the C ABI takes it, three doubles, refused by `what`'s name when it is not three
-- numbers (the thickness section's `point3`, which this block cannot see).
local function point3(point, what)
  if type(point) ~= "table" then raise(("%s: a point is 3 numbers, got %s"):format(what, repr(point))) end
  if #point ~= 3 then raise(("%s: a point is 3 numbers, got %d"):format(what, #point)) end
  local out = ffi.new("double[3]")
  for i = 1, 3 do
    if type(point[i]) ~= "number" then raise(("%s: a point is 3 numbers, got %s"):format(what, repr(point[i]))) end
    out[i - 1] = point[i]
  end
  return out
end

-- A point as a fresh Lua {x, y, z}, refused by `what`'s name when it is not three numbers.
local function point_of(p, what)
  local d = point3(p, what)
  return { d[0], d[1], d[2] }
end

-- Points ({x, y, z} each) as one flat C array and their count, each refused by `what`'s name.
local function flat_points(points, what)
  if type(points) ~= "table" then raise(("%s: expected a list of points, got %s"):format(what, repr(points))) end
  local flat = {}
  for _, p in ipairs(points) do
    local d = point3(p, what)
    flat[#flat + 1], flat[#flat + 2], flat[#flat + 3] = d[0], d[1], d[2]
  end
  return c_array(flat), #flat / 3
end

-- A frame (a `Frame`, twelve numbers or four triples) as twelve Lua numbers.
local function frame_numbers(frame)
  return c_slice(frame_arg(frame), 0, 11)
end

local function distance(a, b)
  local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- ---- Interval ---------------------------------------------------------------------------------

--- A parameter range `t0..t1`, in either order: `length` and `swapped` keep the order, the set
--- operations (`grown`, `union`, `intersect`) answer increasing. Immutable, with nothing to free;
--- `i[1]`, `i[2]` read `t0`, `t1`, and a pair `{t0, t1}` goes wherever an `Interval` does.
--- `Interval.new(t0, t1)` or `Interval(t0, t1)`; a number that is not finite raises `BuildError`
--- (`Interval: not finite`). The kernel's own `Interval` in plain Lua, checked against the same
--- records as the kernel's.
---@class Interval
local Interval = {}
local Interval_get = {}
M.Interval = Interval
Interval.__index = function(self, key)
  if type(key) == "number" then return rawget(self, "_t")[key] end
  local get = Interval_get[key]
  if get then return get(self) end
  return Interval[key]
end
Interval.__newindex = function(_, key) raise(("Interval is immutable: cannot set %s"):format(tostring(key))) end
callable(Interval)

function Interval.new(t0, t1)
  local a, b = number(t0, "Interval") + 0.0, number(t1, "Interval") + 0.0   -- + 0.0: no -0.0
  if not (finite(a) and finite(b)) then raise("Interval: not finite") end
  return setmetatable({ _t = { a, b } }, Interval)
end

--- An `Interval`, or two numbers `{t0, t1}`, as an `Interval`; any other count raises `BuildError`.
function Interval.of(value)
  if type(value) == "table" and getmetatable(value) == Interval then return value end
  if type(value) ~= "table" then raise("Interval: an interval is 2 numbers, got " .. repr(value)) end
  if #value ~= 2 then raise(("Interval: an interval is 2 numbers, got %d"):format(#value)) end
  return Interval.new(value[1], value[2])
end

--- The first end, as given.
function Interval_get.t0(self) return self._t[1] end
--- The second end, as given.
function Interval_get.t1(self) return self._t[2] end
--- `t1 - t0`: negative for a decreasing interval.
function Interval_get.length(self) return self._t[2] - self._t[1] end
--- The middle, `(t0 + t1) / 2`.
function Interval_get.mid(self) return 0.5 * (self._t[1] + self._t[2]) end
--- The smaller end.
function Interval_get.min(self) return math.min(self._t[1], self._t[2]) end
--- The larger end.
function Interval_get.max(self) return math.max(self._t[1], self._t[2]) end
--- Whether `t0 < t1`.
function Interval_get.is_increasing(self) return self._t[1] < self._t[2] end
--- Whether `t0 == t1`.
function Interval_get.is_singleton(self) return self._t[1] == self._t[2] end

--- The interval `t1..t0`.
function Interval:swapped() return Interval.new(self._t[2], self._t[1]) end

--- The increasing interval holding this one and `t`.
function Interval:grown(t)
  t = number(t, "Interval.grown")
  return Interval.new(math.min(self.min, t), math.max(self.max, t))
end

--- The increasing interval holding this one and `o` (an `Interval` or two numbers).
function Interval:union(o)
  o = Interval.of(o)
  return Interval.new(math.min(self.min, o.min), math.max(self.max, o.max))
end

--- The increasing overlap with `o` (an `Interval` or two numbers); nil where the two are apart.
--- Two that touch give a singleton.
function Interval:intersect(o)
  o = Interval.of(o)
  local t0, t1 = math.max(self.min, o.min), math.min(self.max, o.max)
  if t0 <= t1 then return Interval.new(t0, t1) end
  return nil
end

--- Whether `t` lies in the closed range, in either order.
function Interval:contains(t)
  return self.min <= t and t <= self.max
end

--- `t0 + s (t1 - t0)`: the fraction `s` of the way from `t0`; outside 0..1 extrapolates.
function Interval:parameter_at(s)
  local t = self._t
  return t[1] + s * (t[2] - t[1])
end

--- The fraction of the way `t` lies from `t0` toward `t1`; nil for a singleton.
function Interval:normalized_parameter_at(t)
  local length = self.length
  if length ~= 0.0 then return (t - self._t[1]) / length end
  return nil
end

--- `{t0, t1}` as a fresh Lua array.
function Interval:values() return { self._t[1], self._t[2] } end

Interval.__eq = function(a, b)
  return a._t[1] == b._t[1] and a._t[2] == b._t[2]
end

Interval.__tostring = function(self)
  return ("Interval(%s, %s)"):format(tostring(self._t[1]), tostring(self._t[2]))
end

-- ---- the frame verbs --------------------------------------------------------------------------

--- The same plane facing the other way: x and y swapped, z reversed.
function Frame:flipped()
  local z = self.z
  return Frame.new(self.origin, self.y, self.x, { -z[1], -z[2], -z[3] })
end

--- This frame turned `radians` about `axis` ({x, y, z}) through its origin, right-handed
--- (`Transform.rotation`).
function Frame:rotated(radians, axis)
  local r = Transform.rotation(self.origin, axis, radians).rows
  local function turn(d)
    local out = {}
    for i = 0, 2 do out[i + 1] = r[4 * i + 1] * d[1] + r[4 * i + 2] * d[2] + r[4 * i + 3] * d[3] end
    return out
  end
  return Frame.new(self.origin, turn(self.x), turn(self.y), turn(self.z))
end

--- The point `p` ({x, y, z}) in this frame's coordinates, a fresh {x, y, z}.
function Frame:to_local(p)
  local q, o = point_of(p, "Frame.to_local"), self.origin
  local d = { q[1] - o[1], q[2] - o[2], q[3] - o[3] }
  return { dot(d, self.x), dot(d, self.y), dot(d, self.z) }
end

--- How far `p` lies above the frame's plane, along its z: negative below.
function Frame:distance_to(p)
  local q, o = point_of(p, "Frame.distance_to"), self.origin
  return dot({ q[1] - o[1], q[2] - o[2], q[3] - o[3] }, self.z)
end

--- The point `p` dropped onto the frame's plane along its z, a fresh {x, y, z}.
function Frame:closest_point(p)
  local q = point_of(p, "Frame.closest_point")
  local d, z = self:distance_to(q), self.z
  return { q[1] - d * z[1], q[2] - d * z[2], q[3] - d * z[3] }
end

--- The least-squares plane through `points` (a list of {x, y, z}: three or more, not all on one
--- line) as a frame, and the largest distance any point lies off it: two values,
--- `frame, deviation`. Fewer points, or points on one line, raise `BuildError`.
function Frame.fit(points)
  local xyz, n = flat_points(points, "frame_fit")
  local out, deviation = ffi.new("double[12]"), ffi.new("double[1]")
  if not lib().cadaclysm_blacksmith_frame_fit(xyz, n, out, deviation) then fail("frame_fit") end
  return Frame.of(c_slice(out, 0, 11)), deviation[0]
end

-- ---- the feet -----------------------------------------------------------------------------------

--- The closest point of a curve value: its parameter `t`, the `point` ({x, y, z}) and `unique`
--- -- false where several points lie equally near and `point` is a fixed pick among them (a
--- point on a circle's axis, one equidistant from an arc's ends). A plain record:
--- `CurveFoot.new(t, point, unique)` or `CurveFoot(t, point, unique)`; `==` compares the three.
---@class CurveFoot
---@field t number
---@field point number[]  {x, y, z}
---@field unique boolean
local CurveFoot = {}
CurveFoot.__index = CurveFoot
M.CurveFoot = CurveFoot
callable(CurveFoot)

function CurveFoot.new(t, point, unique)
  return setmetatable({ t = t, point = point, unique = unique }, CurveFoot)
end

CurveFoot.__eq = function(a, b)
  return a.t == b.t and a.unique == b.unique and a.point[1] == b.point[1] and a.point[2] == b.point[2]
    and a.point[3] == b.point[3]
end

CurveFoot.__tostring = function(self)
  local p = self.point
  return ("CurveFoot(t=%s, point=(%s, %s, %s), unique=%s)"):format(tostring(self.t), tostring(p[1]), tostring(p[2]),
    tostring(p[3]), tostring(self.unique))
end

--- The closest point of a surface value: its parameters `u`, `v`, the `point` ({x, y, z}) and
--- `unique` -- false where several points lie equally near and `point` is a fixed pick among
--- them (a sphere's centre, a point on an axis). A plain record:
--- `SurfaceFoot.new(u, v, point, unique)` or `SurfaceFoot(u, v, point, unique)`.
---@class SurfaceFoot
---@field u number
---@field v number
---@field point number[]  {x, y, z}
---@field unique boolean
local SurfaceFoot = {}
SurfaceFoot.__index = SurfaceFoot
M.SurfaceFoot = SurfaceFoot
callable(SurfaceFoot)

function SurfaceFoot.new(u, v, point, unique)
  return setmetatable({ u = u, v = v, point = point, unique = unique }, SurfaceFoot)
end

SurfaceFoot.__eq = function(a, b)
  return a.u == b.u and a.v == b.v and a.unique == b.unique and a.point[1] == b.point[1]
    and a.point[2] == b.point[2] and a.point[3] == b.point[3]
end

SurfaceFoot.__tostring = function(self)
  local p = self.point
  return ("SurfaceFoot(u=%s, v=%s, point=(%s, %s, %s), unique=%s)"):format(tostring(self.u), tostring(self.v),
    tostring(p[1]), tostring(p[2]), tostring(p[3]), tostring(self.unique))
end

-- ---- the values ----------------------------------------------------------------------------------

-- CADACLYSM_BLACKSMITH_VALUE_*: the kind each value array is tagged with, and its name.
local VALUE_NAMES = { [0] = "line", "circle", "arc", "ellipse", "sphere", "cylinder", "cone", "torus", "cuboid",
  "rectangle", "triangle", "ray" }

-- `values` squared up by the library's `value_check`: the canonical array every value holds. A
-- count other than `value_size`'s is refused here, in the library's own sentence.
local function value_check(kind, values)
  local n = lib().cadaclysm_blacksmith_value_size(kind)
  if n == 0 then raise(("value_check: kind %d is not a value"):format(kind)) end
  if type(values) ~= "table" then raise(("value_check: a %s is %d numbers, got %s"):format(VALUE_NAMES[kind], n, repr(values))) end
  if #values ~= n then raise(("value_check: a %s is %d numbers, got %d"):format(VALUE_NAMES[kind], n, #values)) end
  local v = ffi.new("double[?]", n)
  for i = 1, n do v[i - 1] = number(values[i], "value_check") end
  local out = ffi.new("double[?]", n)
  if not lib().cadaclysm_blacksmith_value_check(kind, v, out) then fail("value_check") end
  return c_slice(out, 0, n - 1)
end

-- The `n` numbers a call wrote into `out`, or its refusal raised.
local function wrote(what, ok, out, n)
  if not ok then fail(what) end
  return c_slice(out, 0, n - 1)
end

-- Every value is a table `{ _v = canonical array }` whose metatable is its class. A class looks
-- a key up in its own getters, then its bases' getters, then its own methods, then its bases'.
local function shown(v)
  if type(v) == "table" and getmetatable(v) == nil then
    local parts = {}
    for i = 1, #v do parts[i] = tostring(v[i]) end
    return "(" .. table.concat(parts, ", ") .. ")"
  end
  return tostring(v)
end

local function value_eq(a, b)
  if getmetatable(a) ~= getmetatable(b) then return false end
  local x, y = rawget(a, "_v"), rawget(b, "_v")
  if #x ~= #y then return false end
  for i = 1, #x do
    if x[i] ~= y[i] then return false end
  end
  return true
end

local function value_class(name, kind, fields, bases)
  local cls, get = { _KIND = kind, _NAME = name }, {}
  cls.__index = function(self, key)
    if type(key) == "number" then return rawget(self, "_v")[key] end
    local g = get[key]
    if g then return g(self) end
    for _, base in ipairs(bases) do
      g = base[2][key]
      if g then return g(self) end
    end
    local m = cls[key]
    if m ~= nil then return m end
    for _, base in ipairs(bases) do
      m = base[1][key]
      if m ~= nil then return m end
    end
    return nil
  end
  cls.__newindex = function(_, key) raise(("%s is immutable: cannot set %s"):format(name, tostring(key))) end
  cls.__eq = value_eq
  cls.__tostring = function(self)
    local parts = {}
    for i, f in ipairs(fields) do parts[i] = f .. "=" .. shown(self[f]) end
    return name .. "(" .. table.concat(parts, ", ") .. ")"
  end
  callable(cls)
  M[name] = cls
  return cls, get
end

-- A value of `cls` from an array the library handed back, already canonical.
local function value_of(cls, v)
  return setmetatable({ _v = v }, cls)
end

-- A value of `cls` from its numbers, through `value_check`.
local function value_new(cls, values)
  return setmetatable({ _v = value_check(cls._KIND, values) }, cls)
end

local function kind_of(self) return getmetatable(self)._KIND end

--- What every value shares: its canonical array (squared up by the library's `value_check` at
--- construction, so a refusal is the library's: `value_check: the radius must be positive`),
--- immutability, equality by kind and array (`==`: a circle never equals a sphere of the same
--- numbers), `v[i]` reading the array, `bounds` and `transform`. Nothing to free.
---@class Value
local Value = {}
local Value_get = {}
M.Value = Value

--- The value's kind by name: "line", "circle", "arc", "ellipse", "sphere", "cylinder", "cone",
--- "torus", "cuboid", "rectangle", "triangle" or "ray".
function Value_get.kind(self) return VALUE_NAMES[kind_of(self)] end

--- The canonical array, as a fresh Lua array.
function Value:values()
  local v = rawget(self, "_v")
  local out = {}
  for i = 1, #v do out[i] = v[i] end
  return out
end

--- The exact world box from the closed form: two values, `min, max`, each {x, y, z}.
function Value:bounds()
  local out = ffi.new("double[6]")
  local b = wrote("value_bounds", lib().cadaclysm_blacksmith_value_bounds(kind_of(self), c_array(self._v), out), out, 6)
  return { b[1], b[2], b[3] }, { b[4], b[5], b[6] }
end

--- This value under `t` (a `Transform`, or sixteen numbers), a value of the same type. A line
--- takes any map keeping its ends apart and an ellipse any keeping it an ellipse; every other
--- value only a similarity (`Ellipse.from_circle` first for a circle). Any other map raises
--- `BuildError`.
function Value:transform(t)
  local v = rawget(self, "_v")
  local out = ffi.new("double[?]", #v)
  return value_of(getmetatable(self), wrote("value_transform", lib().cadaclysm_blacksmith_value_transform(
    kind_of(self), c_array(v), Transform._matrix(t, "value_transform"), out), out, #v))
end

--- What every curve value shares (`Line`, `Circle`, `Arc`, `Ellipse`, and a `Rectangle`'s boundary).
---@class CurveValue
local CurveValue = {}
M.CurveValue = CurveValue

--- The point at `t`, a fresh {x, y, z}: a line's `t` runs 0..1 from `start` to `end`, a circle's
--- and an arc's is the angle in radians from the frame's x toward its y, an ellipse's the
--- eccentric angle.
function CurveValue:point_at(t)
  local out = ffi.new("double[3]")
  return wrote("curve_value_point_at", lib().cadaclysm_blacksmith_curve_value_point_at(kind_of(self), c_array(self._v),
    number(t, "curve_value_point_at"), out), out, 3)
end

--- The unit tangent at `t`, the way `t` grows.
function CurveValue:tangent_at(t)
  local out = ffi.new("double[3]")
  return wrote("curve_value_tangent_at", lib().cadaclysm_blacksmith_curve_value_tangent_at(kind_of(self), c_array(self._v),
    number(t, "curve_value_tangent_at"), out), out, 3)
end

--- The length (an ellipse's perimeter, in closed form).
function CurveValue:length()
  local out = ffi.new("double[1]")
  return wrote("curve_value_length", lib().cadaclysm_blacksmith_curve_value_length(kind_of(self), c_array(self._v), out),
    out, 1)[1]
end

--- The `CurveFoot` nearest `p`: its parameter `t`, the `point` and `unique` (false where the
--- answer is a fixed pick among equals: a point on a circle's axis, one equidistant from an
--- arc's ends). Exact for every kind, in closed form.
function CurveValue:closest_point(p)
  local out = ffi.new("double[5]")
  local f = wrote("curve_value_closest_point", lib().cadaclysm_blacksmith_curve_value_closest_point(kind_of(self),
    c_array(self._v), point3(p, "curve_value_closest_point"), out), out, 5)
  return CurveFoot.new(f[1], { f[2], f[3], f[4] }, f[5] ~= 0)
end

--- How far `p` lies from the curve: the distance to its `closest_point`.
function CurveValue:distance_to(p)
  return distance(self:closest_point(p).point, point_of(p, "curve_value_closest_point"))
end

--- What every shape with a volume shares (`Sphere`, `Cylinder`, `Cone`, `Torus`, `Cuboid`).
---@class SolidValue
local SolidValue = {}
local SolidValue_get = {}
M.SolidValue = SolidValue

--- The `Frame` the shape is placed on.
function SolidValue_get.frame(self) return Frame.of(slice(self._v, 1, 12)) end

--- Whether `p` lies inside the closed shape or within `tolerance` of it (default 1e-9). NaN is
--- unset, the shape's own effective tolerance (`tolerance.relative` times its diagonal); 0 is
--- exact. A negative or infinite tolerance raises `BuildError`.
function SolidValue:contains(p, tolerance)
  if tolerance == nil then tolerance = 1e-9 end
  local r = lib().cadaclysm_blacksmith_solid_value_contains(kind_of(self), c_array(self._v),
    point3(p, "solid_value_contains"), number(tolerance, "solid_value_contains"))
  if r == NONE then fail("solid_value_contains") end
  return r == 1
end

--- The boundary's area, in closed form: a cylinder's and a cone's caps included.
function SolidValue:area()
  local out = ffi.new("double[1]")
  return wrote("solid_value_area", lib().cadaclysm_blacksmith_solid_value_area(kind_of(self), c_array(self._v), out),
    out, 1)[1]
end

--- The volume enclosed, in closed form.
function SolidValue:volume()
  local out = ffi.new("double[1]")
  return wrote("solid_value_volume", lib().cadaclysm_blacksmith_solid_value_volume(kind_of(self), c_array(self._v), out),
    out, 1)[1]
end

--- The shape as a closed exact B-rep `Solid`.
function SolidValue:to_solid()
  return new_solid(lib().cadaclysm_blacksmith_solid_value_to_solid(kind_of(self), c_array(self._v)), "solid_value_to_solid")
end

--- What every surface value shares (`Sphere`, `Cylinder`, `Cone`, `Torus`), beside
--- `SolidValue`'s members.
---@class SurfaceValue
local SurfaceValue = {}
M.SurfaceValue = SurfaceValue

--- The point at `(u, v)`, in the ranges `domain` gives, a fresh {x, y, z}.
function SurfaceValue:point_at(u, v)
  local out = ffi.new("double[3]")
  return wrote("surface_value_point_at", lib().cadaclysm_blacksmith_surface_value_point_at(kind_of(self),
    c_array(self._v), number(u, "surface_value_point_at"), number(v, "surface_value_point_at"), out), out, 3)
end

--- The outward unit normal at `(u, v)`.
function SurfaceValue:normal_at(u, v)
  local out = ffi.new("double[3]")
  return wrote("surface_value_normal_at", lib().cadaclysm_blacksmith_surface_value_normal_at(kind_of(self),
    c_array(self._v), number(u, "surface_value_normal_at"), number(v, "surface_value_normal_at"), out), out, 3)
end

--- The `SurfaceFoot` nearest `p` on the surface (a cylinder's and a cone's side, not their
--- caps): its `u`, `v`, the `point` and `unique` (false where the answer is a pick among
--- equals: a sphere's centre, a point on an axis). Exact for every kind, in closed form.
function SurfaceValue:closest_point(p)
  local out = ffi.new("double[6]")
  local f = wrote("surface_value_closest_point", lib().cadaclysm_blacksmith_surface_value_closest_point(kind_of(self),
    c_array(self._v), point3(p, "surface_value_closest_point"), out), out, 6)
  return SurfaceFoot.new(f[1], f[2], { f[3], f[4], f[5] }, f[6] ~= 0)
end

--- How far `p` lies from the surface: the distance to its `closest_point`.
function SurfaceValue:distance_to(p)
  return distance(self:closest_point(p).point, point_of(p, "surface_value_closest_point"))
end

--- The `u` and `v` ranges: two values, each an `Interval`.
function SurfaceValue:domain()
  local out = ffi.new("double[4]")
  local d = wrote("surface_value_domain", lib().cadaclysm_blacksmith_surface_value_domain(kind_of(self), c_array(self._v),
    out), out, 4)
  return Interval.new(d[1], d[2]), Interval.new(d[3], d[4])
end

--- The surface alone, as an open sheet `Solid` on its exact NURBS form.
function SurfaceValue:to_nurbs_sheet()
  return new_solid(lib().cadaclysm_blacksmith_surface_value_nurbs_sheet(kind_of(self), c_array(self._v)),
    "surface_value_nurbs_sheet")
end

local CURVE = { { CurveValue, {} }, { Value, Value_get } }
local SURFACE = { { SurfaceValue, {} }, { SolidValue, SolidValue_get }, { Value, Value_get } }
local BOX = { { SolidValue, SolidValue_get }, { Value, Value_get } }

-- A conic's frame: its first twelve numbers.
local function conic_frame(self) return Frame.of(slice(self._v, 1, 12)) end

-- The numbers of a frame followed by `rest`.
local function on_frame(frame, rest)
  local v = frame_numbers(frame)
  for _, x in ipairs(rest) do v[#v + 1] = x end
  return v
end

--- The segment from `start` to `end`, as a value: a piece of construction geometry to measure,
--- to project onto and to map, without building a solid. Its parameter runs 0..1.
--- `Line.new(start, end_)` or `Line(start, end_)`, each end {x, y, z}; `Line.from_array(v)`
--- takes the six numbers. `end` is a Lua keyword: the end is `line.end_` (or `line["end"]`).
---@class Line
local Line, Line_get = value_class("Line", 0, { "start", "end_" }, CURVE)

function Line.new(start, end_)
  local a, b = point_of(start, "Line"), point_of(end_, "Line")
  return value_new(Line, { a[1], a[2], a[3], b[1], b[2], b[3] })
end

--- A line from its six numbers, `from[3] to[3]`, through `value_check`.
function Line.from_array(values) return value_new(Line, values) end

--- The start, {x, y, z}.
function Line_get.start(self) return slice(self._v, 1, 3) end
--- The end, {x, y, z}.
function Line_get.end_(self) return slice(self._v, 4, 6) end
Line_get["end"] = Line_get.end_

--- The circle of `radius` about the frame's origin in its x-y plane, running counter-clockwise
--- about its z from its x, as a value. `Circle.new(frame, radius)` or `Circle(frame, radius)`;
--- `Circle.from_array(v)` takes the thirteen numbers. `Curve.value` gives an edge's circle.
---@class Circle
local Circle, Circle_get = value_class("Circle", 1, { "frame", "radius" }, CURVE)

function Circle.new(frame, radius)
  return value_new(Circle, on_frame(frame, { number(radius, "Circle") }))
end

--- A circle from its thirteen numbers, `frame[12] radius`, through `value_check`.
function Circle.from_array(values) return value_new(Circle, values) end

--- The circle through the points `a`, `b` and `c`: its x toward `a`, turning `a`, `b`, `c`
--- counter-clockwise. Three points on one line raise `BuildError`.
function Circle.through(a, b, c)
  local what = "circle_through"
  local out = ffi.new("double[13]")
  return value_of(Circle, wrote(what, lib().cadaclysm_blacksmith_circle_through(point3(a, what), point3(b, what),
    point3(c, what), out), out, 13))
end

--- The `Frame` the circle lies on: its centre, the x its angles start from, its normal.
function Circle_get.frame(self) return conic_frame(self) end
--- The radius.
function Circle_get.radius(self) return self._v[13] end

--- The part of a circle over `angle` (an `Interval` or two numbers, increasing, by at most a
--- full turn), as a value: the circle's frame and radius, its angles measured from the frame's x
--- toward its y. `Arc.new(frame, radius, angle)` or `Arc(frame, radius, angle)`;
--- `Arc.from_array(v)` takes the fifteen numbers. `end` is a Lua keyword: the end point is
--- `arc.end_` (or `arc["end"]`).
---@class Arc
local Arc, Arc_get = value_class("Arc", 2, { "frame", "radius", "angle" }, CURVE)

function Arc.new(frame, radius, angle)
  local a = Interval.of(angle)
  return value_new(Arc, on_frame(frame, { number(radius, "Arc"), a.t0, a.t1 }))
end

--- An arc from its fifteen numbers, `frame[12] radius t0 t1`, through `value_check`.
function Arc.from_array(values) return value_new(Arc, values) end

--- The arc from `a` through `b` to `c`. Three points on one line raise `BuildError`.
function Arc.through(a, b, c)
  local what = "arc_through"
  local out = ffi.new("double[15]")
  return value_of(Arc, wrote(what, lib().cadaclysm_blacksmith_arc_through(point3(a, what), point3(b, what),
    point3(c, what), out), out, 15))
end

--- The arc leaving `a` along `tangent` and ending at `c`. A zero tangent, or a `c` on the
--- tangent's line, raises `BuildError`.
function Arc.from_start_tangent_end(a, tangent, c)
  local what = "arc_from_start_tangent_end"
  local out = ffi.new("double[15]")
  return value_of(Arc, wrote(what, lib().cadaclysm_blacksmith_arc_from_start_tangent_end(point3(a, what),
    point3(tangent, what), point3(c, what), out), out, 15))
end

--- The `Frame` the arc lies on: its centre, the x its angles start from, its normal.
function Arc_get.frame(self) return conic_frame(self) end
--- The radius.
function Arc_get.radius(self) return self._v[13] end
--- The angle range, an `Interval`.
function Arc_get.angle(self) return Interval.new(self._v[14], self._v[15]) end
--- The point at the start, {x, y, z}.
function Arc_get.start(self) return self:point_at(self._v[14]) end
--- The point at the end, {x, y, z}.
function Arc_get.end_(self) return self:point_at(self._v[15]) end
Arc_get["end"] = Arc_get.end_
--- The point halfway along, {x, y, z}.
function Arc_get.mid(self) return self:point_at(0.5 * (self._v[14] + self._v[15])) end

--- The ellipse of radius `r1` along the frame's x and `r2` along its y, as a value. Unlike a
--- circle it takes any affine map that keeps it an ellipse. `Ellipse.new(frame, r1, r2)` or
--- `Ellipse(frame, r1, r2)`; `Ellipse.from_array(v)` takes the fourteen numbers.
---@class Ellipse
local Ellipse, Ellipse_get = value_class("Ellipse", 3, { "frame", "r1", "r2" }, CURVE)

function Ellipse.new(frame, r1, r2)
  return value_new(Ellipse, on_frame(frame, { number(r1, "Ellipse"), number(r2, "Ellipse") }))
end

--- An ellipse from its fourteen numbers, `frame[12] r1 r2`, through `value_check`.
function Ellipse.from_array(values) return value_new(Ellipse, values) end

--- `circle` as an ellipse of two equal radii, to map by a non-uniform scale or a shear.
function Ellipse.from_circle(circle)
  if type(circle) ~= "table" or getmetatable(circle) ~= Circle then
    raise("ellipse_from_circle: a Circle, not " .. repr(circle))
  end
  local out = ffi.new("double[14]")
  return value_of(Ellipse, wrote("ellipse_from_circle", lib().cadaclysm_blacksmith_ellipse_from_circle(
    c_array(circle._v), out), out, 14))
end

--- The `Frame` the ellipse lies on.
function Ellipse_get.frame(self) return conic_frame(self) end
--- The radius along the frame's x.
function Ellipse_get.r1(self) return self._v[13] end
--- The radius along the frame's y.
function Ellipse_get.r2(self) return self._v[14] end

--- The sphere of `radius` about the frame's origin, as a value: `u` the longitude from the
--- frame's x, `v` the latitude toward its z. `Sphere.new(frame, radius)` or
--- `Sphere(frame, radius)`; `Sphere.from_array(v)` takes the thirteen numbers.
---@class Sphere
local Sphere, Sphere_get = value_class("Sphere", 4, { "frame", "radius" }, SURFACE)

function Sphere.new(frame, radius)
  return value_new(Sphere, on_frame(frame, { number(radius, "Sphere") }))
end

--- A sphere from its thirteen numbers, `frame[12] radius`, through `value_check`.
function Sphere.from_array(values) return value_new(Sphere, values) end

--- The radius.
function Sphere_get.radius(self) return self._v[13] end

--- The capped cylinder of `radius` about the frame's z over `height` (an increasing `Interval`
--- along z, or two numbers), as a value: `u` the angle from the frame's x, `v` the height.
--- `Cylinder.new(frame, radius, height)` or `Cylinder(frame, radius, height)`;
--- `Cylinder.from_array(v)` takes the fifteen numbers.
---@class Cylinder
local Cylinder, Cylinder_get = value_class("Cylinder", 5, { "frame", "radius", "height" }, SURFACE)

function Cylinder.new(frame, radius, height)
  local h = Interval.of(height)
  return value_new(Cylinder, on_frame(frame, { number(radius, "Cylinder"), h.t0, h.t1 }))
end

--- A cylinder from its fifteen numbers, `frame[12] radius h0 h1`, through `value_check`.
function Cylinder.from_array(values) return value_new(Cylinder, values) end

--- The radius.
function Cylinder_get.radius(self) return self._v[13] end
--- The range along the frame's z, an `Interval`.
function Cylinder_get.height(self) return Interval.new(self._v[14], self._v[15]) end

--- The capped cone of base `radius` on the frame's x-y plane, its apex `height` up its z, as a
--- value: `u` the angle from the frame's x, `v` the height. `Cone.new(frame, radius, height)` or
--- `Cone(frame, radius, height)`; `Cone.from_array(v)` takes the fourteen numbers.
---@class Cone
local Cone, Cone_get = value_class("Cone", 6, { "frame", "radius", "height" }, SURFACE)

function Cone.new(frame, radius, height)
  return value_new(Cone, on_frame(frame, { number(radius, "Cone"), number(height, "Cone") }))
end

--- A cone from its fourteen numbers, `frame[12] radius height`, through `value_check`.
function Cone.from_array(values) return value_new(Cone, values) end

--- The base radius.
function Cone_get.radius(self) return self._v[13] end
--- How far up the frame's z the apex lies.
function Cone_get.height(self) return self._v[14] end

--- The torus of `major` radius about the frame's z and `minor` radius about that circle, as a
--- value: `u` the angle about the z from the frame's x, `v` the angle about the tube.
--- `Torus.new(frame, major, minor)` or `Torus(frame, major, minor)`; `Torus.from_array(v)` takes
--- the fourteen numbers.
---@class Torus
local Torus, Torus_get = value_class("Torus", 7, { "frame", "major", "minor" }, SURFACE)

function Torus.new(frame, major, minor)
  return value_new(Torus, on_frame(frame, { number(major, "Torus"), number(minor, "Torus") }))
end

--- A torus from its fourteen numbers, `frame[12] major minor`, through `value_check`.
function Torus.from_array(values) return value_new(Torus, values) end

--- The radius of the tube's centre circle.
function Torus_get.major(self) return self._v[13] end
--- The tube's own radius.
function Torus_get.minor(self) return self._v[14] end

--- The box over `x`, `y`, `z` (increasing `Interval`s, or pairs) along its frame's axes, as a
--- value: an oriented bounding box, a region to test points against, a block to make a solid
--- of. `Cuboid.new(frame, x, y, z)` or `Cuboid(frame, x, y, z)`; `Cuboid.from_array(v)` takes
--- the eighteen numbers.
---@class Cuboid
local Cuboid, Cuboid_get = value_class("Cuboid", 8, { "frame", "x", "y", "z" }, BOX)

function Cuboid.new(frame, x, y, z)
  x, y, z = Interval.of(x), Interval.of(y), Interval.of(z)
  return value_new(Cuboid, on_frame(frame, { x.t0, x.t1, y.t0, y.t1, z.t0, z.t1 }))
end

--- A cuboid from its eighteen numbers, `frame[12] x0 x1 y0 y1 z0 z1`, through `value_check`.
function Cuboid.from_array(values) return value_new(Cuboid, values) end

--- The world-aligned box from `min` to `max`; an empty or flat one raises `BuildError`.
function Cuboid.from_bounds(min, max)
  local what = "cuboid_from_bounds"
  local out = ffi.new("double[18]")
  return value_of(Cuboid, wrote(what, lib().cadaclysm_blacksmith_cuboid_from_bounds(point3(min, what),
    point3(max, what), out), out, 18))
end

--- The tightest box holding `points` (a list of {x, y, z}), aligned to `frame`. No points, or
--- points flat along one of the frame's axes (a sheet, not a box), raise `BuildError`.
function Cuboid.around(frame, points)
  local what = "cuboid_around"
  local xyz, n = flat_points(points, what)
  local out = ffi.new("double[18]")
  return value_of(Cuboid, wrote(what, lib().cadaclysm_blacksmith_cuboid_around(frame_arg(frame), xyz, n, out),
    out, 18))
end

--- The range along the frame's x, an `Interval`.
function Cuboid_get.x(self) return Interval.new(self._v[13], self._v[14]) end
--- The range along the frame's y, an `Interval`.
function Cuboid_get.y(self) return Interval.new(self._v[15], self._v[16]) end
--- The range along the frame's z, an `Interval`.
function Cuboid_get.z(self) return Interval.new(self._v[17], self._v[18]) end

--- The eight corners, a list of {x, y, z}: the `z0` face counter-clockwise about the frame's z
--- from `(x0, y0)`, then the `z1` face in the same order.
function Cuboid:corners()
  local out = ffi.new("double[24]")
  local c = wrote("cuboid_corners", lib().cadaclysm_blacksmith_cuboid_corners(c_array(self._v), out), out, 24)
  local corners = {}
  for k = 0, 7 do corners[k + 1] = { c[3 * k + 1], c[3 * k + 2], c[3 * k + 3] } end
  return corners
end

--- The point the fractions `sx`, `sy`, `sz` of the way along each range, a fresh {x, y, z}.
function Cuboid:point_at(sx, sy, sz)
  local what = "cuboid_point_at"
  local out = ffi.new("double[3]")
  return wrote(what, lib().cadaclysm_blacksmith_cuboid_point_at(c_array(self._v), number(sx, what), number(sy, what),
    number(sz, what), out), out, 3)
end

--- The closest point of the solid box to `p`: `p` itself inside, a fresh {x, y, z}.
function Cuboid:closest_point(p)
  local what = "cuboid_closest_point"
  local out = ffi.new("double[3]")
  return wrote(what, lib().cadaclysm_blacksmith_cuboid_closest_point(c_array(self._v), point3(p, what), out), out, 3)
end

-- ---- the rectangle, the triangle and the ray (plan B4) ----------------------------------------
-- In a block of its own, as the other sections': LuaJIT's 200 live locals.
do
-- The containment codes of the C ABI (OUTSIDE 0, INSIDE 1, ON 2) as Python's strings.
local WORDS = { [0] = "outside", "inside", "on" }

--- The rectangle over `x` and `y` (increasing `Interval`s, or pairs) in its frame's x-y plane,
--- as a value. As a curve it is its boundary: `t` runs 0..4, one unit a side from corner
--- `(x0, y0)` counter-clockwise about the frame's z, clamped outside that range;
--- `closest_point` is the boundary's, not unique on a tie (the centre). `Rectangle.new(frame,
--- x, y)` or `Rectangle(frame, x, y)`; `Rectangle.from_array(v)` takes the sixteen numbers.
---@class Rectangle
local Rectangle, Rectangle_get = value_class("Rectangle", 9, { "frame", "x", "y" }, CURVE)

function Rectangle.new(frame, x, y)
  x, y = Interval.of(x), Interval.of(y)
  return value_new(Rectangle, on_frame(frame, { x.t0, x.t1, y.t0, y.t1 }))
end

--- A rectangle from its sixteen numbers, `frame[12] x0 x1 y0 y1`, through `value_check`.
function Rectangle.from_array(values) return value_new(Rectangle, values) end

--- The `Frame` the rectangle lies on: its ranges run along the frame's x and y.
function Rectangle_get.frame(self) return conic_frame(self) end
--- The range along the frame's x, an `Interval`.
function Rectangle_get.x(self) return Interval.new(self._v[13], self._v[14]) end
--- The range along the frame's y, an `Interval`.
function Rectangle_get.y(self) return Interval.new(self._v[15], self._v[16]) end

--- The four corners, a list of {x, y, z}: `(x0, y0)`, `(x1, y0)`, `(x1, y1)`, `(x0, y1)`.
function Rectangle:corners()
  local out = ffi.new("double[12]")
  local c = wrote("rectangle_corners", lib().cadaclysm_blacksmith_rectangle_corners(c_array(self._v), out), out, 12)
  local corners = {}
  for k = 0, 3 do corners[k + 1] = { c[3 * k + 1], c[3 * k + 2], c[3 * k + 3] } end
  return corners
end

--- The filled rectangle's area.
function Rectangle:area()
  local out = ffi.new("double[1]")
  return wrote("rectangle_area", lib().cadaclysm_blacksmith_rectangle_area(c_array(self._v), out), out, 1)[1]
end

--- `p` projected onto the plane and clamped into the filled rectangle when `include_interior`
--- (the default), else the boundary's closest point, a fresh {x, y, z}.
function Rectangle:closest_point_in(p, include_interior)
  local what = "rectangle_closest_point"
  local out = ffi.new("double[3]")
  return wrote(what, lib().cadaclysm_blacksmith_rectangle_closest_point(c_array(self._v), point3(p, what),
    include_interior ~= false, out), out, 3)
end

--- Where `p`, projected onto the plane, lies: "inside", "outside", or "on" within `tolerance`
--- of the boundary. Nil (the default) or NaN is unset: the rectangle's own effective tolerance
--- (`tolerance.relative` times its diagonal); 0 is exact. A negative or infinite one raises
--- `BuildError`.
function Rectangle:contains(p, tolerance)
  local what = "rectangle_contains"
  local tol = 0 / 0
  if tolerance ~= nil then tol = number(tolerance, what) end
  local r = lib().cadaclysm_blacksmith_rectangle_contains(c_array(self._v), point3(p, what), tol)
  if r == NONE then fail(what) end
  if WORDS[r] == nil then raise(what .. ": the library answered " .. tostring(r) .. ", not a containment code") end
  return WORDS[r]
end

--- The filled rectangle as a one-face planar sheet `Solid` facing the frame's z.
function Rectangle:to_sheet()
  return new_solid(lib().cadaclysm_blacksmith_rectangle_to_sheet(c_array(self._v)), "rectangle_to_sheet")
end

local SHAPE = { { Value, Value_get } }

--- The triangle `a`, `b`, `c`, as a value; a degenerate one (collinear or coincident points)
--- raises `BuildError`. `Triangle.new(a, b, c)` or `Triangle(a, b, c)`, each {x, y, z};
--- `Triangle.from_array(v)` takes the nine numbers.
---@class Triangle
local Triangle, Triangle_get = value_class("Triangle", 10, { "a", "b", "c" }, SHAPE)

function Triangle.new(a, b, c)
  a, b, c = point_of(a, "Triangle"), point_of(b, "Triangle"), point_of(c, "Triangle")
  return value_new(Triangle, { a[1], a[2], a[3], b[1], b[2], b[3], c[1], c[2], c[3] })
end

--- A triangle from its nine numbers, `a[3] b[3] c[3]`, through `value_check`.
function Triangle.from_array(values) return value_new(Triangle, values) end

--- The first vertex, {x, y, z}.
function Triangle_get.a(self) return slice(self._v, 1, 3) end
--- The second vertex, {x, y, z}.
function Triangle_get.b(self) return slice(self._v, 4, 6) end
--- The third vertex, {x, y, z}.
function Triangle_get.c(self) return slice(self._v, 7, 9) end

--- The area.
function Triangle:area()
  local out = ffi.new("double[1]")
  return wrote("triangle_area", lib().cadaclysm_blacksmith_triangle_area(c_array(self._v), out), out, 1)[1]
end

--- The sum of the three sides.
function Triangle:perimeter()
  local out = ffi.new("double[1]")
  return wrote("triangle_perimeter", lib().cadaclysm_blacksmith_triangle_perimeter(c_array(self._v), out), out, 1)[1]
end

--- The area centroid, the vertices' mean, a fresh {x, y, z}.
function Triangle:centroid()
  local out = ffi.new("double[3]")
  return wrote("triangle_centroid", lib().cadaclysm_blacksmith_triangle_centroid(c_array(self._v), out), out, 3)
end

--- The `Circle` through `a`, `b` and `c`: its x toward `a`, turning them counter-clockwise.
function Triangle:circumcircle()
  local out = ffi.new("double[13]")
  return value_of(M.Circle, wrote("triangle_circumcircle", lib().cadaclysm_blacksmith_triangle_circumcircle(
    c_array(self._v), out), out, 13))
end

--- The point of barycentric weights `wa`, `wb`, `wc`, used as given, a fresh {x, y, z}.
function Triangle:point_at(wa, wb, wc)
  local what = "triangle_point_at"
  local out = ffi.new("double[3]")
  return wrote(what, lib().cadaclysm_blacksmith_triangle_point_at(c_array(self._v), number(wa, what), number(wb, what),
    number(wc, what), out), out, 3)
end

--- The weights {wa, wb, wc}, summing to 1, of `p` projected onto the plane.
function Triangle:barycentric(p)
  local what = "triangle_barycentric"
  local out = ffi.new("double[3]")
  return wrote(what, lib().cadaclysm_blacksmith_triangle_barycentric(c_array(self._v), point3(p, what), out), out, 3)
end

--- The closest point of the filled triangle to `p`, exact, a fresh {x, y, z}.
function Triangle:closest_point(p)
  local what = "triangle_closest_point"
  local out = ffi.new("double[3]")
  return wrote(what, lib().cadaclysm_blacksmith_triangle_closest_point(c_array(self._v), point3(p, what), out), out, 3)
end

--- How far `p` lies from the filled triangle.
function Triangle:distance_to(p)
  return distance(self:closest_point(p), point_of(p, "triangle_closest_point"))
end

--- Edge `i` as a `Line`: 0 `a` to `b`, 1 `b` to `c`, 2 `c` to `a`.
function Triangle:edge(i)
  local what = "triangle_edge"
  if type(i) ~= "number" or i < 0 or i > 4294967295 or i ~= math.floor(i) then
    raise(what .. ": edge must be an index, got " .. repr(i))
  end
  local out = ffi.new("double[6]")
  return value_of(M.Line, wrote(what, lib().cadaclysm_blacksmith_triangle_edge(c_array(self._v), i, out),
    out, 6))
end

--- The filled triangle as a one-face planar sheet `Solid`, its normal turning `a`, `b`, `c`
--- counter-clockwise.
function Triangle:to_sheet()
  return new_solid(lib().cadaclysm_blacksmith_triangle_to_sheet(c_array(self._v)), "triangle_to_sheet")
end

--- The half-line from `position` along `direction`, as a value. The direction is kept as
--- given, not unitised, so `t` counts lengths of it; a zero one raises `BuildError`, and so
--- does `bounds` (a ray has no box). `Ray.new(position, direction)` or `Ray(position,
--- direction)`; `Ray.from_array(v)` takes the six numbers.
---@class Ray
local Ray, Ray_get = value_class("Ray", 11, { "position", "direction" }, SHAPE)

function Ray.new(position, direction)
  local o, d = point_of(position, "Ray"), point_of(direction, "Ray")
  return value_new(Ray, { o[1], o[2], o[3], d[1], d[2], d[3] })
end

--- A ray from its six numbers, `position[3] direction[3]`, through `value_check`.
function Ray.from_array(values) return value_new(Ray, values) end

--- The start, {x, y, z}.
function Ray_get.position(self) return slice(self._v, 1, 3) end
--- The direction as given, {x, y, z}.
function Ray_get.direction(self) return slice(self._v, 4, 6) end

--- `position + t * direction`, any `t` (behind the start too), a fresh {x, y, z}.
function Ray:point_at(t)
  local what = "ray_point_at"
  local out = ffi.new("double[3]")
  return wrote(what, lib().cadaclysm_blacksmith_ray_point_at(c_array(self._v), number(t, what), out), out, 3)
end

--- The `CurveFoot` on the ray nearest `p`: `t` clamped at 0, so a point behind the start
--- answers the start. Always unique.
function Ray:closest_point(p)
  local what = "ray_closest_point"
  local out = ffi.new("double[4]")
  local f = wrote(what, lib().cadaclysm_blacksmith_ray_closest_point(c_array(self._v), point3(p, what), out), out, 4)
  return CurveFoot.new(f[1], { f[2], f[3], f[4] }, true)
end

--- How far `p` lies from the ray.
function Ray:distance_to(p)
  return distance(self:closest_point(p).point, point_of(p, "ray_closest_point"))
end
end

-- ---- an edge's curve as its value -----------------------------------------------------------

local Curve_get = {}
Curve.__index = function(self, key)
  local get = Curve_get[key]
  if get then return get(self) end
  return Curve[key]
end

--- This curve as a value (a table whose `kind` names it): a line a `Line` from `origin` to
--- `origin + x`; a circle a `Circle` over a full turn, else the `Arc` over `t0..t1`; an ellipse
--- its whole `Ellipse` (the range stays here: there is no elliptical-arc value); any other kind
--- nil.
function Curve_get.value(self)
  local o = self.origin
  local frame = { o, self.x, self.y, self.z }
  if self.kind == "line" then
    local x = self.x
    return Line.new(o, { o[1] + x[1], o[2] + x[2], o[3] + x[3] })
  end
  if self.kind == "circle" then
    if self.t1 - self.t0 >= 2 * math.pi - 1e-12 then return Circle.new(frame, self.radius) end
    return Arc.new(frame, self.radius, { self.t0, self.t1 })
  end
  if self.kind == "ellipse" then return Ellipse.new(frame, self.radius, self.radius2) end
  return nil
end

end
value_geometry()
end

-- ---- NurbsCurve: curves in space -------------------------------------------------------------

-- In a function of its own, as the value geometry above: the main chunk is at LuaJIT's limit of
-- 200 live locals, so only `M.NurbsCurve` and `M.Curvature` leave it.
do
local function nurbs_curves()

local CurveValue = M.CurveValue
local Transform = M.Transform

--- A curve's bending at a parameter (`NurbsCurve:curvature`): `kappa` (1 / radius), the unit
--- `tangent`, the unit `normal` toward the centre and the `binormal` (`tangent x normal`), and
--- the `centre` of the osculating circle -- nil on a straight piece, where `kappa` is 0 and
--- `normal`, `binormal` are zero.
---@class Curvature
---@field kappa number
---@field tangent number[]    three, unit
---@field normal number[]     three, unit toward the centre
---@field binormal number[]   three
---@field centre number[]|nil three, nil on a straight piece
local Curvature = {}
class(Curvature)
callable(Curvature)
M.Curvature = Curvature

function Curvature.new(fields)
  return setmetatable(fields, Curvature)
end

Curvature.__tostring = function(self)
  return ("Curvature(kappa=%.9g, centre=%s)"):format(self.kappa, self.centre and
    ("(%.6g, %.6g, %.6g)"):format(self.centre[1], self.centre[2], self.centre[3]) or "nil")
end

local function c_slice(out, i, j)
  local r = {}
  for k = i, j do r[#r + 1] = out[k] end
  return r
end

-- A point as the C ABI takes it, three doubles, refused by `what`'s name when it is not three numbers.
local function point3(point, what)
  if type(point) ~= "table" then raise(("%s: a point is 3 numbers, got %s"):format(what, repr(point))) end
  if #point ~= 3 then raise(("%s: a point is 3 numbers, got %d"):format(what, #point)) end
  local out = ffi.new("double[3]")
  for i = 1, 3 do
    if type(point[i]) ~= "number" then raise(("%s: a point is 3 numbers, got %s"):format(what, repr(point[i]))) end
    out[i - 1] = point[i]
  end
  return out
end

local function index_u32(value, call, name)
  if type(value) ~= "number" or value ~= math.floor(value) then
    raise(("%s: %s must be a whole number, got %s"):format(call, name, repr(value)))
  end
  if value < 0 or value > 4294967295 then raise(("%s: %s is out of range: %.14g"):format(call, name, value)) end
  return value
end

-- The arc-length readers, as the sections above hold them out of this block's sight.
local function tolerance_of(tolerance, what)
  if tolerance == nil then return 0 / 0 end
  if type(tolerance) ~= "number" then raise(what .. ": tolerance must be a number, got " .. tostring(tolerance)) end
  return tolerance
end

local function accuracy_arg(accuracy, what)
  if accuracy == nil then return 0 end
  return number(accuracy, what)
end

local function length_of(raw)
  return M.Length.new({
    length = raw.length,
    error = raw.error,
    accuracy_met = raw.accuracy_met ~= 0,
    from_polyline = raw.from_polyline ~= 0,
  })
end

local function at_of(raw)
  return M.At.new({
    point = { raw.point[0], raw.point[1], raw.point[2] },
    tangent = { raw.tangent[0], raw.tangent[1], raw.tangent[2] },
    parameter = raw.parameter,
    segment = raw.segment ~= NONE and tonumber(raw.segment) or nil,
    error = raw.error,
    from_polyline = raw.from_polyline ~= 0,
  })
end

-- A divide's list read into `At`s and freed on every path; a null list raises the library's reason.
local function read_samples(list, what)
  local L = lib()
  if list == nil then fail(what) end
  local out, reason = {}, nil
  local count = L.cadaclysm_blacksmith_samples_count(list)
  local raw = ffi.new("CadaclysmBlacksmithAt[1]")
  for i = 0, count - 1 do
    if not L.cadaclysm_blacksmith_samples_at(list, i, raw) then
      reason = last_error()
      break
    end
    out[i + 1] = at_of(raw[0])
  end
  L.cadaclysm_blacksmith_samples_free(list)
  if reason ~= nil then
    error(setmetatable({ message = reason ~= "" and reason or "samples_at", ids = {} }, BuildError), 2)
  end
  return out
end

local function triple_of(a) return { a[0], a[1], a[2] } end

local function curvature_of(raw)
  return Curvature.new({
    kappa = raw.kappa,
    tangent = triple_of(raw.tangent),
    normal = triple_of(raw.normal),
    binormal = triple_of(raw.binormal),
    centre = raw.has_centre ~= 0 and triple_of(raw.centre) or nil,
  })
end

local function free_curve(h) lib().cadaclysm_blacksmith_nurbs_curve_free(h) end

--- A curve in space -- always a NURBS, so a line, an arc or a conic is an exact rational one --
--- to model with: built through points, read off an edge or a face, projected onto a plane or a
--- face, trimmed, extended and blended; asked for its points, derivatives, curvature, length
--- and crossings. Immutable; every edit returns a new curve, and the garbage collector frees it.
--- Not `Curve`, which is the plain data an edge's curve is copied out as; `NurbsCurve.from_edge`
--- turns an edge into one of these.
---
--- A face here is its whole surface: projecting onto, pulling to and crossing a face ignore its
--- trims. `NurbsCurve.new(points, degree, weights, knots)` or `NurbsCurve(...)`: `degree` (1 to
--- 7, default 3), `weights` one per point (positive) or nil, and the full knot vector `knots`
--- (`#points + degree + 1` values, non-decreasing) or nil for clamped and uniform. Points are
--- `{x, y, z}` each; `degree`, `control_points`, `weights`, `knots`, `domain`, `is_rational`
--- and `is_closed` read like fields.
---@class NurbsCurve
---@field degree integer
---@field control_points number[][]  {x, y, z} each
---@field weights number[]           one per control point
---@field knots number[]
---@field domain number[]            {first, last}
---@field is_rational boolean
---@field is_closed boolean          the answer, not a flag
---@field fit_error number|nil       set only on curves from `fit`, `projected_to_face`, `pulled_to_face`
local NurbsCurve = {}
local NurbsCurve_get = {}
class(NurbsCurve, NurbsCurve_get)
callable(NurbsCurve)
M.NurbsCurve = NurbsCurve

NurbsCurve.__newindex = function(_, key) raise("NurbsCurve is immutable: cannot set " .. tostring(key)) end

-- The handle of a NurbsCurve argument, refused by `what`'s name when it is anything else.
local function curve_handle(c, what)
  if type(c) ~= "table" or getmetatable(c) ~= NurbsCurve then
    raise(what .. ": expected a NurbsCurve, got " .. repr(c))
  end
  return rawget(c, "_ptr")
end

-- A new curve around a handle the library gave, or its refusal raised.
local function curve_of(handle, what, fit_error)
  checked(handle, what)
  return setmetatable({ _ptr = ffi.gc(handle, free_curve), fit_error = fit_error }, NurbsCurve)
end

-- Points ({x, y, z} each) as one flat C array and their count, each refused by `what`'s name.
local function xyz_of(points, what)
  if type(points) ~= "table" then raise(("%s: expected a list of points, got %s"):format(what, repr(points))) end
  local n = #points
  local out = ffi.new("double[?]", math.max(3 * n, 1))
  for i = 1, n do
    local d = point3(points[i], what)
    out[3 * i - 3], out[3 * i - 2], out[3 * i - 1] = d[0], d[1], d[2]
  end
  return out, n
end

-- A direction as three doubles, or nil for the C ABI's NULL.
local function optional3(v, what)
  if v == nil then return nil end
  return point3(v, what)
end

-- A list of numbers as a C array and its length, or nil and 0 for none.
local function optional_numbers(list, what)
  if list == nil then return nil, 0 end
  if type(list) ~= "table" then raise(("%s: expected a list of numbers, got %s"):format(what, repr(list))) end
  local out = ffi.new("double[?]", math.max(#list, 1))
  for i = 1, #list do out[i - 1] = number(list[i], what) end
  return out, #list
end

local function default(v, fallback)
  if v == nil then return fallback end
  return v
end

-- `tolerance` as the C ABI takes it: nil is NaN (the effective one), 0 the same.
local function tol(tolerance, what)
  return tolerance_of(tolerance, what)
end

-- An edge argument: an `Edge` or its index.
local function edge_arg(edge, what)
  if type(edge) == "table" and getmetatable(edge) == M.Edge then return edge.index end
  return index_u32(edge, what, "edge")
end

-- ---- building ------------------------------------------------------------------------------

function NurbsCurve.new(points, degree, weights, knots)
  local xyz, n = xyz_of(points, "nurbs_curve_new")
  if weights ~= nil and (type(weights) ~= "table" or #weights ~= n) then
    raise(("nurbs_curve_new: %s weights for %d points; give one per point"):format(
      type(weights) == "table" and tostring(#weights) or repr(weights), n))
  end
  local w = optional_numbers(weights, "nurbs_curve_new")
  local k, kn = optional_numbers(knots, "nurbs_curve_new")
  return curve_of(lib().cadaclysm_blacksmith_nurbs_curve_new(xyz, n, w,
    index_u32(default(degree, 3), "nurbs_curve_new", "degree"), k, kn), "nurbs_curve_new")
end

--- The curve of `degree` (1 to 7, default 3) through `points` in order, chord-length
--- parametrised. `closed` true closes it back to the first point, smooth across the seam; an
--- open curve may leave along `start_tangent` and arrive along `end_tangent` (directions; their
--- length does not matter).
---@param points number[][]
---@param degree integer|nil
---@param closed boolean|nil
---@param start_tangent number[]|nil
---@param end_tangent number[]|nil
---@return NurbsCurve
function NurbsCurve.through(points, degree, closed, start_tangent, end_tangent)
  local xyz, n = xyz_of(points, "nurbs_curve_through")
  return curve_of(lib().cadaclysm_blacksmith_nurbs_curve_through(xyz, n,
    index_u32(default(degree, 3), "nurbs_curve_through", "degree"), closed and true or false,
    optional3(start_tangent, "nurbs_curve_through"), optional3(end_tangent, "nurbs_curve_through")),
    "nurbs_curve_through")
end

--- A curve of `degree` (default 3) within `tolerance` (default 1e-3; 0 asks for the effective
--- one) of every point, through the first and the last (least squares); its `fit_error` is the
--- largest distance from a point to it.
---@param points number[][]
---@param degree integer|nil
---@param tolerance number|nil
---@return NurbsCurve
function NurbsCurve.fit(points, degree, tolerance)
  local xyz, n = xyz_of(points, "nurbs_curve_fit")
  local err = ffi.new("double[1]")
  local h = lib().cadaclysm_blacksmith_nurbs_curve_fit(xyz, n, index_u32(default(degree, 3), "nurbs_curve_fit", "degree"),
    tol(default(tolerance, 1e-3), "nurbs_curve_fit"), err)
  return curve_of(h, "nurbs_curve_fit", err[0])
end

--- Edge `edge` (an `Edge` or its index) of `solid` as an exact NURBS over the edge's own span
--- of its curve, running the way the edge runs.
---@param solid Solid
---@param edge Edge|integer
---@return NurbsCurve
function NurbsCurve.from_edge(solid, edge)
  local s = solid_handle(solid, "nurbs_curve_from_edge")
  return curve_of(lib().cadaclysm_blacksmith_nurbs_curve_from_edge(s, edge_arg(edge, "nurbs_curve_from_edge")),
    "nurbs_curve_from_edge")
end

--- The isocurve of face `face` of `solid`'s surface: along `u` at `v = at` when `along_u`, else
--- along `v` at `u = at`. NURBS faces only.
---@param solid Solid
---@param face integer
---@param along_u boolean
---@param at number
---@return NurbsCurve
function NurbsCurve.isocurve(solid, face, along_u, at)
  local s = solid_handle(solid, "nurbs_curve_from_face_isocurve")
  return curve_of(lib().cadaclysm_blacksmith_nurbs_curve_from_face_isocurve(s,
    index_u32(face, "nurbs_curve_from_face_isocurve", "face"), along_u and true or false,
    number(at, "nurbs_curve_from_face_isocurve")), "nurbs_curve_from_face_isocurve")
end

--- The curve bridging `a` (at its end when `a_end`, else its start) to `b` (at its end when
--- `b_end`, else its start): `continuity` (default 2) 1 matches position and tangent (a cubic),
--- 2 also the curvature (a quintic); `bulge` (positive, default 1) scales how far the tangents
--- reach.
---@param a NurbsCurve
---@param a_end boolean
---@param b NurbsCurve
---@param b_end boolean
---@param continuity integer|nil
---@param bulge number|nil
---@return NurbsCurve
function NurbsCurve.blend(a, a_end, b, b_end, continuity, bulge)
  return curve_of(lib().cadaclysm_blacksmith_nurbs_curve_blend(curve_handle(a, "nurbs_curve_blend"), a_end and true or false,
    curve_handle(b, "nurbs_curve_blend"), b_end and true or false,
    index_u32(default(continuity, 2), "nurbs_curve_blend", "continuity"),
    number(default(bulge, 1), "nurbs_curve_blend")), "nurbs_curve_blend")
end

--- `curves` joined end to end into one curve (Rhino's JoinCurves): in the order given, each
--- turned where needed so its start meets the previous one's end within `tolerance` (default
--- 1e-6; the joint placed at the midpoint of the two ends). All are raised to the highest degree
--- among them and each runs over `k..k + 1`, joined C0 -- a corner stays a corner; a rational
--- curve keeps its points. One curve gives a copy; none, or a gap past `tolerance`, raises
--- `BuildError` naming the two curves.
---@param curves NurbsCurve[]
---@param tolerance number|nil
---@return NurbsCurve
function NurbsCurve.joined(curves, tolerance)
  if type(curves) ~= "table" then raise("nurbs_curve_joined: expected a list of curves, got " .. repr(curves)) end
  local n = #curves
  local arr = ffi.new("const struct CadaclysmBlacksmithNurbsCurve *[?]", math.max(n, 1))
  for i = 1, n do arr[i - 1] = curve_handle(curves[i], "nurbs_curve_joined") end
  local h = lib().cadaclysm_blacksmith_nurbs_curve_joined(arr, n, number(default(tolerance, 1e-6), "nurbs_curve_joined"))
  return curve_of(h, "nurbs_curve_joined")
end

local TWEEN_METHODS = { plain = 0, matching = 1, sampling = 2 }

--- `count` curves blending evenly from this curve to `other` (Rhino's CreateTweenCurves
--- family), tween `i` at the fraction `i / (count + 1)`, as a list. `method` is a string:
---
--- - `"plain"`: control point by control point; the curves must already share one structure
---   (degree, control-point count, knots).
--- - `"matching"` (the default): the curves made compatible exactly (degree elevation, knot
---   merging), then blended in homogeneous coordinates -- rational curves stay rational.
--- - `"sampling"`: both divided by arc length into `samples` pieces (required here, refused
---   otherwise), and a cubic interpolated through the blended samples.
---
--- `align` (default true) turns `other`, and moves a closed curve's seam, to line it up with
--- this one first. `tolerance` nil: the inputs' effective tolerance. A count of 0, one curve
--- closed and the other open, plain on curves that are not compatible, or too few samples
--- raises `BuildError`.
---@param other NurbsCurve
---@param count integer
---@param method string|nil
---@param samples integer|nil
---@param align boolean|nil
---@param tolerance number|nil
---@return NurbsCurve[]
function NurbsCurve:tween(other, count, method, samples, align, tolerance)
  method = default(method, "matching")
  if TWEEN_METHODS[method] == nil then
    raise(("nurbs_curve_tween: method must be one of plain, matching, sampling, not %s"):format(repr(method)))
  end
  if method == "sampling" then
    if samples == nil then raise("nurbs_curve_tween: sampling needs samples") end
  elseif samples ~= nil then
    raise(("nurbs_curve_tween: samples is read only by sampling, not %s"):format(method))
  end
  local a, b = curve_handle(self, "nurbs_curve_tween"), curve_handle(other, "nurbs_curve_tween")
  local n = index_u32(count, "nurbs_curve_tween", "count")
  local s = index_u32(default(samples, 0), "nurbs_curve_tween", "samples")
  local out = ffi.new("struct CadaclysmBlacksmithNurbsCurve *[?]", math.max(n, 1))
  if not lib().cadaclysm_blacksmith_nurbs_curve_tween(a, b, n, TWEEN_METHODS[method], s,
      align == nil or align and true or false, tol(tolerance, "nurbs_curve_tween"), out) then
    fail("nurbs_curve_tween")
  end
  local curves = {}
  for i = 1, n do curves[i] = curve_of(out[i - 1], "nurbs_curve_tween") end
  return curves
end

-- ---- edits ---------------------------------------------------------------------------------

--- This curve projected onto the plane through `origin` with `normal`, along `direction` (nil:
--- the normal). Exact.
---@param origin number[]
---@param normal number[]
---@param direction number[]|nil
---@return NurbsCurve
function NurbsCurve:projected_to_plane(origin, normal, direction)
  local w = "nurbs_curve_projected_to_plane"
  return curve_of(lib().cadaclysm_blacksmith_nurbs_curve_projected_to_plane(curve_handle(self, w),
    point3(origin, w), point3(normal, w), optional3(direction, w)), w)
end

--- This curve projected along `direction` onto face `face` of `solid` (its whole surface),
--- fitted within `tolerance` (default 1e-3); the result's `fit_error` is the largest distance
--- between it and the surface. Raises `BuildError` where a point's ray misses.
---@param solid Solid
---@param face integer
---@param direction number[]
---@param tolerance number|nil
---@return NurbsCurve
function NurbsCurve:projected_to_face(solid, face, direction, tolerance)
  local w = "nurbs_curve_projected_to_face"
  local err = ffi.new("double[1]")
  local h = lib().cadaclysm_blacksmith_nurbs_curve_projected_to_face(curve_handle(self, w), solid_handle(solid, w),
    index_u32(face, w, "face"), point3(direction, w), tol(default(tolerance, 1e-3), w), err)
  return curve_of(h, w, err[0])
end

--- This curve pulled onto face `face` of `solid` (its whole surface): every point to its
--- nearest surface point, fitted within `tolerance` (default 1e-3; `fit_error` as for the
--- projection).
---@param solid Solid
---@param face integer
---@param tolerance number|nil
---@return NurbsCurve
function NurbsCurve:pulled_to_face(solid, face, tolerance)
  local w = "nurbs_curve_pulled_to_face"
  local err = ffi.new("double[1]")
  local h = lib().cadaclysm_blacksmith_nurbs_curve_pulled_to_face(curve_handle(self, w), solid_handle(solid, w),
    index_u32(face, w, "face"), tol(default(tolerance, 1e-3), w), err)
  return curve_of(h, w, err[0])
end

--- The same curve run the other way over the same domain.
---@return NurbsCurve
function NurbsCurve:reversed()
  local w = "nurbs_curve_reversed"
  return curve_of(lib().cadaclysm_blacksmith_nurbs_curve_reversed(curve_handle(self, w)), w)
end

--- The part from `t0` to `t1` (`t0 < t1`, inside the domain), over `t0..t1`.
---@param t0 number
---@param t1 number
---@return NurbsCurve
function NurbsCurve:trimmed(t0, t1)
  local w = "nurbs_curve_trimmed"
  return curve_of(lib().cadaclysm_blacksmith_nurbs_curve_trimmed(curve_handle(self, w), number(t0, w), number(t1, w)), w)
end

--- This curve continued `length` past its end (or its start when `at_start`) along its own end
--- polynomial -- position, tangent and curvature there unchanged, every old parameter its old
--- point.
---@param length number
---@param at_start boolean|nil
---@return NurbsCurve
function NurbsCurve:extended(length, at_start)
  local w = "nurbs_curve_extended"
  return curve_of(lib().cadaclysm_blacksmith_nurbs_curve_extended(curve_handle(self, w), at_start and true or false,
    number(length, w)), w)
end

--- The same curve at degree `degree + by` (`by` default 1; at most 12).
---@param by integer|nil
---@return NurbsCurve
function NurbsCurve:elevated(by)
  local w = "nurbs_curve_elevated"
  return curve_of(lib().cadaclysm_blacksmith_nurbs_curve_elevated(curve_handle(self, w),
    index_u32(default(by, 1), w, "by")), w)
end

--- This curve through the affine map `t` (a `Transform`, or sixteen numbers): its control points
--- mapped, weights and knots kept -- exact. A singular map (a projection) is allowed.
---@param t Transform|number[]
---@return NurbsCurve
function NurbsCurve:transformed(t)
  local w = "nurbs_curve_transformed"
  return curve_of(lib().cadaclysm_blacksmith_nurbs_curve_transformed(curve_handle(self, w), Transform._matrix(t, w)), w)
end

--- A second curve with the same shape, owning its own handle.
---@return NurbsCurve
function NurbsCurve:clone()
  local w = "nurbs_curve_clone"
  return curve_of(lib().cadaclysm_blacksmith_nurbs_curve_clone(curve_handle(self, w)), w)
end

-- ---- reading -------------------------------------------------------------------------------

function NurbsCurve_get.degree(self)
  return tonumber(lib().cadaclysm_blacksmith_nurbs_curve_degree(curve_handle(self, "nurbs_curve_degree")))
end

function NurbsCurve_get.control_points(self)
  local w = "nurbs_curve_control_points"
  local h = curve_handle(self, w)
  local n = tonumber(lib().cadaclysm_blacksmith_nurbs_curve_control_count(h))
  local out = ffi.new("double[?]", math.max(3 * n, 1))
  if not lib().cadaclysm_blacksmith_nurbs_curve_control_points(h, out) then fail(w) end
  local points = {}
  for i = 1, n do points[i] = { out[3 * i - 3], out[3 * i - 2], out[3 * i - 1] } end
  return points
end

function NurbsCurve_get.weights(self)
  local w = "nurbs_curve_weights"
  local h = curve_handle(self, w)
  local n = tonumber(lib().cadaclysm_blacksmith_nurbs_curve_control_count(h))
  local out = ffi.new("double[?]", math.max(n, 1))
  if not lib().cadaclysm_blacksmith_nurbs_curve_weights(h, out) then fail(w) end
  return c_slice(out, 0, n - 1)
end

function NurbsCurve_get.knots(self)
  local w = "nurbs_curve_knots"
  local h = curve_handle(self, w)
  local n = tonumber(lib().cadaclysm_blacksmith_nurbs_curve_knot_count(h))
  local out = ffi.new("double[?]", math.max(n, 1))
  if not lib().cadaclysm_blacksmith_nurbs_curve_knots(h, out) then fail(w) end
  return c_slice(out, 0, n - 1)
end

function NurbsCurve_get.domain(self)
  local w = "nurbs_curve_domain"
  local out = ffi.new("double[2]")
  if not lib().cadaclysm_blacksmith_nurbs_curve_domain(curve_handle(self, w), out) then fail(w) end
  return { out[0], out[1] }
end

function NurbsCurve_get.is_rational(self)
  return lib().cadaclysm_blacksmith_nurbs_curve_is_rational(curve_handle(self, "nurbs_curve_is_rational")) and true or false
end

function NurbsCurve_get.is_closed(self)
  return lib().cadaclysm_blacksmith_nurbs_curve_is_closed(curve_handle(self, "nurbs_curve_is_closed")) and true or false
end

--- The point at parameter `t`, inside the domain, a fresh {x, y, z}.
---@param t number
---@return number[]
function NurbsCurve:point(t)
  local w = "nurbs_curve_point"
  local out = ffi.new("double[3]")
  if not lib().cadaclysm_blacksmith_nurbs_curve_point(curve_handle(self, w), number(t, w), out) then fail(w) end
  return { out[0], out[1], out[2] }
end

--- The point and its derivatives at `t` up to `order` (default 2, at most 8): a list of
--- `order + 1` {x, y, z}, `{C, C', C'', ...}`.
---@param t number
---@param order integer|nil
---@return number[][]
function NurbsCurve:derivatives(t, order)
  local w = "nurbs_curve_derivatives"
  local k = index_u32(default(order, 2), w, "order")
  local out = ffi.new("double[?]", 3 * (math.min(k, 8) + 1))
  if not lib().cadaclysm_blacksmith_nurbs_curve_derivatives(curve_handle(self, w), number(t, w), k, out) then fail(w) end
  local list = {}
  for i = 1, k + 1 do list[i] = { out[3 * i - 3], out[3 * i - 2], out[3 * i - 1] } end
  return list
end

--- The curvature and Frenet frame at `t`, a `Curvature`.
---@param t number
---@return Curvature
function NurbsCurve:curvature(t)
  local w = "nurbs_curve_curvature"
  local out = ffi.new("CadaclysmBlacksmithCurvature[1]")
  if not lib().cadaclysm_blacksmith_nurbs_curve_curvature(curve_handle(self, w), number(t, w), out) then fail(w) end
  return curvature_of(out[0])
end

--- The curve's length, a `Length`, to the relative `accuracy` (0 or nil asks for the default).
---@param accuracy number|nil
---@return Length
function NurbsCurve:length(accuracy)
  local w = "nurbs_curve_length"
  local out = ffi.new("CadaclysmBlacksmithLength[1]")
  if not lib().cadaclysm_blacksmith_nurbs_curve_length(curve_handle(self, w), accuracy_arg(accuracy, w), out) then fail(w) end
  return length_of(out[0])
end

--- The point at arc length `s` from the curve's start, an `At` (its `segment` nil).
---@param s number
---@param accuracy number|nil
---@return At
function NurbsCurve:point_at_length(s, accuracy)
  local w = "nurbs_curve_point_at_length"
  local out = ffi.new("CadaclysmBlacksmithAt[1]")
  if not lib().cadaclysm_blacksmith_nurbs_curve_point_at_length(curve_handle(self, w), number(s, w),
      accuracy_arg(accuracy, w), out) then
    fail(w)
  end
  return at_of(out[0])
end

--- The curve in `n` pieces of equal arc length, a list of `At`: `n + 1` samples, `n` for a
--- closed curve.
---@param n integer
---@param accuracy number|nil
---@return At[]
function NurbsCurve:divide_by_count(n, accuracy)
  local w = "nurbs_curve_divide_by_count"
  return read_samples(lib().cadaclysm_blacksmith_nurbs_curve_divide_by_count(curve_handle(self, w),
    index_u32(n, w, "n"), accuracy_arg(accuracy, w)), w)
end

--- Samples every `step` of arc length from the start, a list of `At`; a closed curve never
--- repeats its start.
---@param step number
---@param accuracy number|nil
---@return At[]
function NurbsCurve:divide_by_length(step, accuracy)
  local w = "nurbs_curve_divide_by_length"
  return read_samples(lib().cadaclysm_blacksmith_nurbs_curve_divide_by_length(curve_handle(self, w),
    number(step, w), accuracy_arg(accuracy, w)), w)
end

--- Where the curve crosses the plane through `origin` with `normal`, a list of `At` in
--- parameter order (`error` each point's distance from the plane). Raises `BuildError` for a
--- curve lying in the plane; a touch that does not cross is not listed.
---@param origin number[]
---@param normal number[]
---@return At[]
function NurbsCurve:plane_hits(origin, normal)
  local w = "nurbs_curve_plane_hits"
  return read_samples(lib().cadaclysm_blacksmith_nurbs_curve_plane_hits(curve_handle(self, w),
    point3(origin, w), point3(normal, w)), w)
end

--- Where the curve crosses face `face` of `solid` (its whole surface), within `tolerance`
--- (default 1e-3) of it, a list of `At` in parameter order (`error` each point's distance from
--- the surface).
---@param solid Solid
---@param face integer
---@param tolerance number|nil
---@return At[]
function NurbsCurve:face_hits(solid, face, tolerance)
  local w = "nurbs_curve_face_hits"
  return read_samples(lib().cadaclysm_blacksmith_nurbs_curve_face_hits(curve_handle(self, w), solid_handle(solid, w),
    index_u32(face, w, "face"), tol(default(tolerance, 1e-3), w)), w)
end

--- A curvature comb to draw: at `n + 1` even parameters (`n` default 64, at least 1 step), a
--- list of `{ p, q }` pairs, the curve point `p` and that point moved by
--- `-scale * kappa * normal` (`scale` default 1; out of the bend), `q`. Straight stretches give
--- zero teeth.
---@param n integer|nil
---@param scale number|nil
---@return number[][][]
function NurbsCurve:comb(n, scale)
  n = default(n, 64)
  scale = default(scale, 1)
  local d = self.domain
  local lo, hi = d[1], d[2]
  local steps = math.max(math.floor(n), 1)
  local teeth = {}
  for i = 0, steps do
    local t = lo + (hi - lo) * i / steps
    local k = self:curvature(t)
    local p = self:point(t)
    teeth[i + 1] = { p, { p[1] - scale * k.kappa * k.normal[1], p[2] - scale * k.kappa * k.normal[2],
      p[3] - scale * k.kappa * k.normal[3] } }
  end
  return teeth
end

NurbsCurve.__tostring = function(self)
  local d = self.domain
  return ("NurbsCurve(degree=%d, controls=%d, rational=%s, domain=(%.9g, %.9g))"):format(self.degree,
    #self.control_points, tostring(self.is_rational), d[1], d[2])
end

--- The exact NURBS form of this curve value, a `NurbsCurve`: a line is degree 1, a circle, an
--- arc or an ellipse an exact rational curve.
---@return NurbsCurve
function CurveValue:to_nurbs()
  local w = "curve_value_to_nurbs"
  local v = rawget(self, "_v")
  local arr = ffi.new("double[?]", math.max(#v, 1))
  for i = 1, #v do arr[i - 1] = v[i] end
  return curve_of(lib().cadaclysm_blacksmith_curve_value_to_nurbs(getmetatable(self)._KIND, arr), w)
end

end
nurbs_curves()
end

-- ---- Sheets from curves ----------------------------------------------------------------------

-- In a function of its own, as the curves above: the main chunk is at LuaJIT's limit of 200
-- live locals, so only `M.Continuity`, `M.PatchReport` and `M.JoinReport` leave it.
do
local function curve_sheets()

local Solid = M.Solid

--- How well two faces meet along their sides (`Solid:continuity`): the largest `gap` between
--- the sides (G0), the largest `angle` between their normals in radians (G1), the largest
--- difference of normal `curvature` across the edge (G2), each with where it was found
--- (`gap_at`, `angle_at`, `curvature_at`: three numbers), and how many points were asked
--- (`samples`).
---@class Continuity
---@field gap number
---@field gap_at number[]       three
---@field angle number
---@field angle_at number[]     three
---@field curvature number
---@field curvature_at number[] three
---@field samples integer
local Continuity = {}
class(Continuity)
callable(Continuity)
M.Continuity = Continuity

function Continuity.new(fields)
  return setmetatable(fields, Continuity)
end

Continuity.__tostring = function(self)
  return ("Continuity(gap=%.3g, angle=%.3g, curvature=%.3g)"):format(self.gap, self.angle, self.curvature)
end

local function continuity_of(raw)
  return Continuity.new({
    gap = raw.gap, gap_at = { raw.gap_at[0], raw.gap_at[1], raw.gap_at[2] },
    angle = raw.angle, angle_at = { raw.angle_at[0], raw.angle_at[1], raw.angle_at[2] },
    curvature = raw.curvature, curvature_at = { raw.curvature_at[0], raw.curvature_at[1], raw.curvature_at[2] },
    samples = tonumber(raw.samples),
  })
end

--- How well an N-sided patch (`Solid.n_sided_patch`) meets: `faces` sub-patches, the worst
--- `boundary` `Continuity` against the neighbours (the gap over every side, the angle over
--- those met at G1 or G2, the curvature jump over those at G2), the worst `internal` one
--- across the patch's own spokes, and `corner_angle` (radians), the most a corner of the hole
--- leaves no patch able to meet: zero where the neighbours meet each other at G1.
---@class PatchReport
---@field faces integer
---@field boundary Continuity
---@field internal Continuity
---@field corner_angle number
local PatchReport = {}
class(PatchReport)
callable(PatchReport)
M.PatchReport = PatchReport

function PatchReport.new(fields)
  return setmetatable(fields, PatchReport)
end

PatchReport.__tostring = function(self)
  return ("PatchReport(faces=%d, boundary=%s, internal=%s, corner_angle=%.3g)"):format(self.faces,
    tostring(self.boundary), tostring(self.internal), self.corner_angle)
end

--- What `Solid.join_sheets` did: `sewn` edges (each two naked edges become one shared edge),
--- the widest `worst_gap` between two sewn edges (0 where all met exactly), the naked edges
--- -- bordered by one face -- `naked_before` (once the T-junctions are cut) and
--- `naked_after`, `refused` groups of naked edges that share both ends but were left apart
--- (too far apart, or three or more), faces `turned`, and whether the result is `closed`: a
--- solid.
---@class JoinReport
---@field sewn integer
---@field worst_gap number
---@field naked_before integer
---@field naked_after integer
---@field refused integer
---@field turned integer
---@field closed boolean
local JoinReport = {}
class(JoinReport)
callable(JoinReport)
M.JoinReport = JoinReport

function JoinReport.new(fields)
  return setmetatable(fields, JoinReport)
end

JoinReport.__tostring = function(self)
  return ("JoinReport(sewn=%d, naked %d -> %d, refused=%d, turned=%d, worst_gap=%.3g, closed=%s)"):format(
    self.sewn, self.naked_before, self.naked_after, self.refused, self.turned, self.worst_gap, tostring(self.closed))
end

-- ---- the arguments -------------------------------------------------------------------------

local SIDES = { u0 = 0, u1 = 1, v0 = 2, v1 = 3 }

local function side_code(side)
  local code = type(side) == "string" and SIDES[side] or nil
  if code == nil then raise(("a side is 'u0', 'u1', 'v0' or 'v1', not %s"):format(repr(side))) end
  return code
end

-- A whole number from 0 to 4294967295 for a `uint32_t`, refused by `call`'s name.
local function whole(value, call, name)
  if type(value) ~= "number" or value ~= math.floor(value) then
    raise(("%s: %s must be a whole number, got %s"):format(call, name, repr(value)))
  end
  if value < 0 or value > 4294967295 then raise(("%s: %s is out of range: %.14g"):format(call, name, value)) end
  return value
end

local function or_default(v, fallback)
  if v == nil then return fallback end
  return v
end

-- A distance tolerance: nil is NaN, which the library works at the inputs' effective tolerance.
local function tolerance_arg(v, call)
  if v == nil then return 0 / 0 end
  if type(v) ~= "number" then raise(("%s: tolerance must be a number, got %s"):format(call, repr(v))) end
  return v
end

local function handle_of_curve(c, call)
  if type(c) ~= "table" or getmetatable(c) ~= M.NurbsCurve then
    raise(call .. ": expected a NurbsCurve, got " .. repr(c))
  end
  return rawget(c, "_ptr")
end

-- A list of curves as a `const NurbsCurve *` array (never read past `n`) and its count.
local function curve_array(curves, call)
  if type(curves) ~= "table" then raise(("%s: expected a list of curves, got %s"):format(call, repr(curves))) end
  local n = #curves
  local arr = ffi.new("const struct CadaclysmBlacksmithNurbsCurve *[?]", math.max(n, 1))
  for i = 1, n do arr[i - 1] = handle_of_curve(curves[i], call) end
  return arr, n
end

-- A direction as three doubles, or nil for the C ABI's NULL.
local function direction_arg(v, call)
  if v == nil then return nil end
  if type(v) ~= "table" or #v ~= 3 then raise(("%s: a direction is 3 numbers, got %s"):format(call, repr(v))) end
  local out = ffi.new("double[3]")
  for i = 1, 3 do out[i - 1] = number(v[i], call) end
  return out
end

local function free_rail(h) lib().cadaclysm_blacksmith_nurbs_curve_free(h) end

-- A new curve around a handle the library gave (a rail), or its refusal raised.
local function curve_of(handle, call)
  checked(handle, call)
  return setmetatable({ _ptr = ffi.gc(handle, free_rail) }, M.NurbsCurve)
end

-- A solid, with `sheet_error` set from `err` where the call fitted it.
local function fitted(handle, err, call)
  local out = new_solid(handle, call)
  if err ~= nil then out._sheet_error = tonumber(err[0]) end
  return out
end

--- Set on the sheets `Solid.sweep_rail`, `sweep_two_rails`, `edge_surface`, `network_surface`,
--- `fillet_surfaces`, `Solid:flange` and `Solid:extrude_to` fit: the largest distance from the
--- sheet to what it was fitted to.
--- nil on every other solid. Read-only.
---@return number|nil
function Solid_get.sheet_error(self)
  return rawget(self, "_sheet_error")
end

--- Set by `Solid.n_sided_patch`: a `PatchReport`. nil on every other solid. Read-only.
---@return PatchReport|nil
function Solid_get.patch_report(self)
  return rawget(self, "_patch_report")
end

-- ---- sheets from curves --------------------------------------------------------------------

--- The sheet lofted through `sections` (`NurbsCurve`s), `degree` (default 3) across them
--- (lowered to fit); `loose` shapes it by them instead, through the first and last only;
--- `closed` makes it periodic across them, the last section back to the first.
---@param sections NurbsCurve[]
---@param degree integer|nil
---@param loose boolean|nil
---@param closed boolean|nil
---@return Solid
function Solid.loft_curves(sections, degree, loose, closed)
  local w = "loft_curves"
  local arr, n = curve_array(sections, w)
  local d = whole(or_default(degree, 3), w, "degree")
  return new_solid(lib().cadaclysm_blacksmith_loft_curves(arr, n, d, loose and true or false, closed and true or false), w)
end

local FRAMES = { rmf = 0, fixed = 1 }

--- `sections` swept along `rail`, each carried by the rail's frame from the rail point
--- nearest its centre and blended between: `frame` `"rmf"` (the default) rotation-minimising,
--- `"fixed"` keeping `up` (three numbers) upright. Fitted within `tolerance` (default 1e-3;
--- the sheet's `sheet_error` says how close).
---@param rail NurbsCurve
---@param sections NurbsCurve[]
---@param frame string|nil
---@param up number[]|nil
---@param tolerance number|nil
---@return Solid
function Solid.sweep_rail(rail, sections, frame, up, tolerance)
  local w = "sweep_rail"
  frame = or_default(frame, "rmf")
  local kind = type(frame) == "string" and FRAMES[frame] or nil
  if kind == nil then raise(("sweep_rail: frame is 'rmf' or 'fixed', not %s"):format(repr(frame))) end
  local r = handle_of_curve(rail, w)
  local arr, n = curve_array(sections, w)
  local err = ffi.new("double[1]")
  return fitted(lib().cadaclysm_blacksmith_sweep_rail(r, arr, n, kind, direction_arg(up, w),
    tolerance_arg(or_default(tolerance, 1e-3), w), err), err, w)
end

--- `sections` swept between two rails: each section's first end on `rail_a` and last on
--- `rail_b`, carried by the rotation and uniform scale that keep them there, the rails
--- matched by arc length. Fitted within `tolerance` (default 1e-3; `sheet_error`).
---@param rail_a NurbsCurve
---@param rail_b NurbsCurve
---@param sections NurbsCurve[]
---@param tolerance number|nil
---@return Solid
function Solid.sweep_two_rails(rail_a, rail_b, sections, tolerance)
  local w = "sweep_two_rails"
  local a, b = handle_of_curve(rail_a, w), handle_of_curve(rail_b, w)
  local arr, n = curve_array(sections, w)
  local err = ffi.new("double[1]")
  return fitted(lib().cadaclysm_blacksmith_sweep_two_rails(a, b, arr, n, tolerance_arg(or_default(tolerance, 1e-3), w), err),
    err, w)
end

--- The Coons sheet of 2, 3 or 4 boundary curves meeting end to end within `tolerance`
--- (default 1e-3; in order round the boundary, each either way round): exact for
--- non-rational boundaries, rational ones fitted first (`sheet_error`).
---@param curves NurbsCurve[]
---@param tolerance number|nil
---@return Solid
function Solid.edge_surface(curves, tolerance)
  local w = "edge_surface"
  local arr, n = curve_array(curves, w)
  local err = ffi.new("double[1]")
  return fitted(lib().cadaclysm_blacksmith_edge_surface(arr, n, tolerance_arg(or_default(tolerance, 1e-3), w), err), err, w)
end

--- The Gordon sheet of a curve network: `u_curves` (in order across the other way) and
--- `v_curves`, every one of the first crossing every one of the second within `tolerance`
--- (default 1e-3). `sheet_error` is the largest distance from the sheet to the curves given.
---@param u_curves NurbsCurve[]
---@param v_curves NurbsCurve[]
---@param tolerance number|nil
---@return Solid
function Solid.network_surface(u_curves, v_curves, tolerance)
  local w = "network_surface"
  local ua, un = curve_array(u_curves, w)
  local va, vn = curve_array(v_curves, w)
  local err = ffi.new("double[1]")
  return fitted(lib().cadaclysm_blacksmith_network_surface(ua, un, va, vn, tolerance_arg(or_default(tolerance, 1e-3), w), err),
    err, w)
end

-- ---- continuity ----------------------------------------------------------------------------

--- How well face `face` (default 0)'s side `side` (`"u0"`, `"u1"`, `"v0"`, `"v1"`: a boundary
--- isocurve of its NURBS surface) meets `other`'s face `other_face` (default 0) along
--- `other_side`: the largest gap, angle between the normals and difference of curvature
--- across the edge, with where each is, a `Continuity`. `samples` defaults to 64.
---@param side string
---@param other Solid
---@param other_side string
---@param face integer|nil
---@param other_face integer|nil
---@param samples integer|nil
---@return Continuity
function Solid:continuity(side, other, other_side, face, other_face, samples)
  local w = "continuity"
  local sa, sb = side_code(side), side_code(other_side)
  local fa, fb = whole(or_default(face, 0), w, "face"), whole(or_default(other_face, 0), w, "other_face")
  local ns = whole(or_default(samples, 64), w, "samples")
  local b = solid_handle(other, w)
  local out = ffi.new("struct CadaclysmBlacksmithContinuity[1]")
  if not lib().cadaclysm_blacksmith_continuity(self:_h(), fa, sa, b, fb, sb, ns, out) then fail(w) end
  return continuity_of(out[0])
end

--- Face `face` as a sheet of its own, its side `side` bent to meet `other`'s `other_side` at
--- G`level` (default 2): 0 position, 1 tangent plane, 2 curvature. The opposite side stays
--- where it was.
---@param side string
---@param other Solid
---@param other_side string
---@param level integer|nil
---@param face integer|nil
---@param other_face integer|nil
---@return Solid
function Solid:matched(side, other, other_side, level, face, other_face)
  local w = "match_side"
  local sa, sb = side_code(side), side_code(other_side)
  local fa, fb = whole(or_default(face, 0), w, "face"), whole(or_default(other_face, 0), w, "other_face")
  local lv = whole(or_default(level, 2), w, "level")
  local b = solid_handle(other, w)
  return new_solid(lib().cadaclysm_blacksmith_match_side(self:_h(), fa, sa, b, fb, sb, lv), w)
end

--- A sheet spanning from `a`'s side to `b`'s, meeting each at G`level` (1 or 2; default 2);
--- `bulge` (default 1) scales how far it leaves each edge along its neighbour's tangent.
---@param a Solid
---@param side_a string
---@param b Solid
---@param side_b string
---@param level integer|nil
---@param bulge number|nil
---@param face_a integer|nil
---@param face_b integer|nil
---@return Solid
function Solid.blend_sides(a, side_a, b, side_b, level, bulge, face_a, face_b)
  local w = "blend_sides"
  local sa, sb = side_code(side_a), side_code(side_b)
  local fa, fb = whole(or_default(face_a, 0), w, "face_a"), whole(or_default(face_b, 0), w, "face_b")
  local lv = whole(or_default(level, 2), w, "level")
  local ha, hb = solid_handle(a, w), solid_handle(b, w)
  return new_solid(lib().cadaclysm_blacksmith_blend_sides(ha, fa, sa, hb, fb, sb, lv, number(or_default(bulge, 1), w)), w)
end

local BOUNDARY_KEYS = { sheet = true, side = true, level = true, face = true, range = true }

-- One `n_sided_patch` boundary written into row `row` of the C array.
local function patch_row(row, b, i)
  local w = "n_sided_patch"
  row.sheet, row.curve, row.face, row.side, row.from, row.to, row.level = nil, nil, 0, 0, 0, 1, 0
  if type(b) == "table" and getmetatable(b) == M.NurbsCurve then
    row.curve = rawget(b, "_ptr")
    return
  end
  if type(b) ~= "table" or getmetatable(b) == Solid then
    raise(("%s: boundary %d is a sheet side or a NurbsCurve, got %s"):format(w, i, repr(b)))
  end
  local sheet, side, level, face, range
  if b[1] ~= nil then
    if #b > 3 then raise(("%s: boundary %d is {sheet, side} or {sheet, side, level}"):format(w, i)) end
    sheet, side, level, face, range = b[1], b[2], or_default(b[3], 2), 0, { 0, 1 }
  else
    local unknown = {}
    for k in pairs(b) do
      if not BOUNDARY_KEYS[k] then unknown[#unknown + 1] = tostring(k) end
    end
    if #unknown > 0 then
      table.sort(unknown)
      raise(("%s: boundary %d: unknown keys {%s}"):format(w, i, table.concat(unknown, ", ")))
    end
    sheet, side, level, face, range = b.sheet, b.side, or_default(b.level, 2), or_default(b.face, 0),
      or_default(b.range, { 0, 1 })
  end
  row.sheet = solid_handle(sheet, w)
  row.face = whole(face, w, "face")
  row.side = side_code(side)
  if type(range) ~= "table" then raise(("%s: boundary %d: range is {from, to}, got %s"):format(w, i, repr(range))) end
  row.from, row.to = number(range[1], w), number(range[2], w)
  row.level = whole(level, w, "level")
end

--- The sheet filling a hole of 3 or more sides (Rhino's Patch, OCCT's MakeFilling, on
--- sheets' sides): N four-sided NURBS faces round a central point, G1 or G2 to each other.
--- Each of `boundaries`, in order round the hole and either way round, is a sheet's side met
--- at G2, `{sheet, side}`; `{sheet, side, level}` with `level` 0, 1 or 2; a table with
--- `sheet`, `side` and any of `level`, `face` and `range` (`{from, to}` of the side's
--- parameter, the whole side `{0, 1}`, backwards `{1, 0}`); or a `NurbsCurve`, met at G0. A
--- side is `"u0"`, `"u1"`, `"v0"` or `"v1"`. The boundaries must meet end to end within
--- `tolerance` (default 0.01); `bulge` (default 1) scales how far the patch leaves each
--- neighbour along its tangent.
---
--- Face `i` meets boundary `i`'s second half along its `"v0"` side and boundary `i + 1`'s
--- first half along its `"u1"`, so `Solid:continuity` measures each neighbour; the result's
--- `patch_report` holds the worst of them, measured the same way.
---@param boundaries table[]
---@param bulge number|nil
---@param tolerance number|nil
---@return Solid
function Solid.n_sided_patch(boundaries, bulge, tolerance)
  local w = "n_sided_patch"
  if type(boundaries) ~= "table" then raise(("%s: expected a list of boundaries, got %s"):format(w, repr(boundaries))) end
  local n = #boundaries
  local rows = ffi.new("struct CadaclysmBlacksmithPatchBoundary[?]", math.max(n, 1))
  for i = 1, n do patch_row(rows[i - 1], boundaries[i], i - 1) end
  local report = ffi.new("struct CadaclysmBlacksmithPatchReport[1]")
  local out = new_solid(lib().cadaclysm_blacksmith_n_sided_patch(rows, n, number(or_default(bulge, 1), w),
    tolerance_arg(or_default(tolerance, 0.01), w), report), w)
  local r = report[0]
  out._patch_report = PatchReport.new({
    faces = tonumber(r.faces), boundary = continuity_of(r.boundary), internal = continuity_of(r.internal),
    corner_angle = r.corner_angle,
  })
  return out
end

--- The rolling-ball fillet between `a`'s face `face_a` and `b`'s face `face_b` (default 0;
--- their whole NURBS surfaces): the ball on the side each face's normal points to (`flip_a`
--- / `flip_b`: the other side), of `radius`, or running linearly from `radius` to
--- `radius_end` along the fillet. `tolerance` defaults to 1e-3. Returns the fillet sheet (its
--- `sheet_error` set) and the contact curves on `a` and `b`, to trim them back with
--- `Solid:trim_by_curve` and join with `Solid.join_sheets`. The curves are `NurbsCurve`s of
--- their own, valid after the sheets are closed.
---@param a Solid
---@param b Solid
---@param radius number
---@param radius_end number|nil
---@param flip_a boolean|nil
---@param flip_b boolean|nil
---@param tolerance number|nil
---@param face_a integer|nil
---@param face_b integer|nil
---@return Solid sheet
---@return NurbsCurve rail_a
---@return NurbsCurve rail_b
function Solid.fillet_surfaces(a, b, radius, radius_end, flip_a, flip_b, tolerance, face_a, face_b)
  local w = "fillet_surfaces"
  local fa, fb = whole(or_default(face_a, 0), w, "face_a"), whole(or_default(face_b, 0), w, "face_b")
  local r0 = number(radius, w)
  local r1 = radius_end == nil and r0 or number(radius_end, w)
  local ha, hb = solid_handle(a, w), solid_handle(b, w)
  local ra, rb = ffi.new("struct CadaclysmBlacksmithNurbsCurve *[1]"), ffi.new("struct CadaclysmBlacksmithNurbsCurve *[1]")
  local err = ffi.new("double[1]")
  local sheet = fitted(lib().cadaclysm_blacksmith_fillet_surfaces(ha, fa, hb, fb, r0, r1, flip_a and true or false,
    flip_b and true or false, tolerance_arg(or_default(tolerance, 1e-3), w), ra, rb, err), err, w)
  local rail_a = curve_of(ra[0], w)
  local rail_b = curve_of(rb[0], w)
  return sheet, rail_a, rail_b
end

-- ---- trimming and joining ------------------------------------------------------------------

--- This sheet cut along `curve` -- one lying on it, say projected or pulled onto it -- and
--- nothing removed: every face comes back in its pieces outside the cutter, then its pieces
--- inside, each a face, as `split_sheet` orders them. The cutter is `curve` run along
--- `direction` (three numbers; nil: the mean of the sheet's normals along the curve) through
--- the whole sheet. A closed curve's inside is the island it bounds; an open curve's is the
--- side left of its run, seen from where `direction` points, and an open curve is run on
--- straight past both ends, so it should cross the sheet's boundary. Where the cut lies on the
--- curve the rim is one edge carrying the curve's own span exactly, which another sheet's edge
--- along the curve sews to. `tolerance` defaults to 0.05.
---@param curve NurbsCurve
---@param direction number[]|nil
---@param tolerance number|nil
---@return Solid
function Solid:split_by_curve(curve, direction, tolerance)
  local w = "split_by_curve"
  local c = handle_of_curve(curve, w)
  return new_solid(lib().cadaclysm_blacksmith_split_by_curve(self:_h(), c, direction_arg(direction, w),
    tolerance_arg(or_default(tolerance, 0.05), w)), w)
end

local KEEPS = { outside = false, inside = true, left = true, right = false }

--- This sheet cut along `curve` and one side thrown away (see `split_by_curve`): `keep`
--- `"inside"` keeps the island a closed curve bounds, `"outside"` (the default) the sheet
--- with the hole; for an open curve `"left"` (the same as `"inside"`) keeps the side left of
--- its run seen from where `direction` points, `"right"` the other. Raises `BuildError` where
--- nothing of the sheet lies on the kept side.
---@param curve NurbsCurve
---@param keep string|nil
---@param direction number[]|nil
---@param tolerance number|nil
---@return Solid
function Solid:trim_by_curve(curve, keep, direction, tolerance)
  local w = "trim_by_curve"
  keep = or_default(keep, "outside")
  if type(keep) ~= "string" or KEEPS[keep] == nil then
    raise(("trim_by_curve: keep must be 'outside', 'inside', 'left' or 'right', not %s"):format(repr(keep)))
  end
  local c = handle_of_curve(curve, w)
  return new_solid(lib().cadaclysm_blacksmith_trim_by_curve(self:_h(), c, direction_arg(direction, w), KEEPS[keep],
    tolerance_arg(or_default(tolerance, 0.05), w)), w)
end

--- `section` swept along each of `edges` (naked edges of this sheet: `Edge` records or their
--- indices) on the face's own frame: at every point of the edge the section's `x` runs outward
--- from the face -- square to the edge, in the face's tangent plane -- and its `y` along the
--- face's normal, so a section from `(0, 0)` to `(0, -10)` turns the edge under by 10 all along
--- it however the panel curves, `(0, 0)` to `(10, 0)` carries the face on, and a lip stands
--- proud with `y > 0`. `section` is a `NurbsCurve` in the plane `z = 0` starting at the
--- origin. With `join` (the default) the sweeps come back sewn to this sheet (its faces first,
--- then one per edge), else alone, sewn to each other. Each sweep is fitted within `tolerance`
--- (default 1e-3; `sheet_error` says how close). Raises `BuildError` for an edge bordered by
--- two faces, a section not starting at the origin, and sweeps that did not sew on.
---@param edges (Edge|integer)[]
---@param section NurbsCurve
---@param tolerance number|nil
---@param join boolean|nil
---@return Solid
function Solid:flange(edges, section, tolerance, join)
  local w = "flange"
  local arr, n = edge_indices(edges, w)
  local c = handle_of_curve(section, w)
  local err = ffi.new("double[1]")
  return fitted(lib().cadaclysm_blacksmith_flange(self:_h(), arr, n, c, tolerance_arg(or_default(tolerance, 1e-3), w),
    join == nil or (join and true or false), err), err, w)
end

--- Each of `edges` (naked edges of this sheet: `Edge` records or their indices) slid along
--- `direction` (three numbers) until it meets `target`: every point of the edge travels along
--- the direction to its first hit on `target`'s faces (trimmed, not their whole surfaces). One
--- wall per edge -- the edge's own curve swept straight, bounded by the curve through the hits,
--- fitted within `tolerance` (default 1e-3) of every hit (`sheet_error`) -- so a wheel arch cut
--- in a panel runs in to the well's inner wall as its liner. With `join` (the default) the
--- walls come back sewn to this sheet (its faces first, then one per edge), else alone, sewn to
--- each other. Raises `BuildError` naming the point whose line misses the target.
---@param edges (Edge|integer)[]
---@param direction number[]
---@param target Solid
---@param tolerance number|nil
---@param join boolean|nil
---@return Solid
function Solid:extrude_to(edges, direction, target, tolerance, join)
  local w = "extrude_to"
  local arr, n = edge_indices(edges, w)
  local d = direction_arg(direction, w)
  local err = ffi.new("double[1]")
  return fitted(lib().cadaclysm_blacksmith_extrude_to(self:_h(), arr, n, d, solid_handle(target, w),
    tolerance_arg(or_default(tolerance, 1e-3), w), join == nil or (join and true or false), err), err, w)
end

--- `sheets` joined into one body, their faces in order, and a `JoinReport` of what was done:
--- every two naked edges whose ends and curves agree within `tolerance` (default 0: a
--- rounding of the body's size) sewn into one -- a gap closed is kept as that edge's own
--- tolerance -- the faces turned to agree, and a closed result turned to face out, a solid
--- the booleans, `mass` and the writers take. Edges with exact curves are compared to the
--- tolerance however coarsely each was sampled. At a tolerance above 0 a T-junction is sewn
--- too: one sheet's edge along part of another's is first cut where the other's corner lies on
--- it. Returns the solid and the report.
---@param sheets Solid[]
---@param tolerance number|nil
---@return Solid
---@return JoinReport
function Solid.join_sheets(sheets, tolerance)
  local w = "join_sheets"
  if type(sheets) ~= "table" then raise(("%s: expected a list of sheets, got %s"):format(w, repr(sheets))) end
  local n = #sheets
  local arr = ffi.new("const struct CadaclysmBlacksmithSolid *[?]", math.max(n, 1))
  for i = 1, n do arr[i - 1] = solid_handle(sheets[i], w) end
  local report = ffi.new("struct CadaclysmBlacksmithJoinReport[1]")
  local out = new_solid(lib().cadaclysm_blacksmith_join_sheets(arr, n, tolerance_arg(or_default(tolerance, 0), w), report), w)
  local r = report[0]
  return out, JoinReport.new({
    sewn = tonumber(r.sewn), worst_gap = r.worst_gap, naked_before = tonumber(r.naked_before),
    naked_after = tonumber(r.naked_after), refused = tonumber(r.refused), turned = tonumber(r.turned),
    closed = r.closed ~= 0,
  })
end

--- This sheet with an opening recessed into it along `outline` -- a window, a lamp, a grille or
--- an air intake set into a panel -- and how many of the result's faces are each part's:
--- `{ sheet, fillet, walls, pane }`, the faces in that order. `outline` is a closed curve on the
--- sheet (one face or several joined); each of its points is found on the sheet, so it may
--- stand a little off it. The walls run back `depth` along the sheet's own normal at every
--- point of the rim -- not along one view -- behind the face (against its normal; negative: in
--- front), leaning in toward the opening by `draft` radians (default 0; negative: out) and
--- meeting on the mitre at the outline's corners. `fillet` above 0 (default 0) rounds the rim
--- between the sheet and the walls (the outline must then be smooth). `pane` (default true)
--- closes the back with one patch whose four sides end where the outline turns most, so it
--- does not twist. Every piece is sewn to the next: only the sheet's own boundary is left
--- naked, and the walls' foot without a pane. Raises `BuildError` for an outline that is not
--- closed, a corner with a fillet, or a fillet deeper than the walls.
---@param outline NurbsCurve
---@param depth number
---@param draft number|nil
---@param fillet number|nil
---@param pane boolean|nil
---@param tolerance number|nil
---@return Solid
---@return integer[]
function Solid:recess(outline, depth, draft, fillet, pane, tolerance)
  local w = "recess"
  local c = handle_of_curve(outline, w)
  local faces = ffi.new("uint32_t[4]")
  local out = new_solid(lib().cadaclysm_blacksmith_recess(self:_h(), c, number(depth, w), number(or_default(draft, 0), w),
    number(or_default(fillet, 0), w), pane ~= false, tolerance_arg(or_default(tolerance, 0.05), w), faces), w)
  return out, { tonumber(faces[0]), tonumber(faces[1]), tonumber(faces[2]), tonumber(faces[3]) }
end

end
curve_sheets()
end

-- ---- documents ---------------------------------------------------------------------------------

-- In a function of its own, as the curves above: the main chunk is at LuaJIT's limit of 200 live
-- locals (a `do` block's count too), so only `M.Document`, `Solid:document_body` and
-- `Profile:document_path` leave it.
do
local function documents()

-- Owned text a document call returned, read and freed; nil raises the library's reason.
local function owned_text(raw, what)
  if raw == nil then fail(what) end
  local out = ffi.string(raw)
  lib().cadaclysm_blacksmith_string_free(raw)
  return out
end

local function text_arg(value, what, name)
  if type(value) ~= "string" then raise(("%s: %s must be text, got %s"):format(what, name, repr(value))) end
  return value
end

-- An optional text argument: nil or empty is C's null.
local function optional_text(value, what, name)
  if value == nil or value == "" then return nil end
  return text_arg(value, what, name)
end

local function read_text(path, what)
  local f, err = io.open(tostring(path), "rb")
  if not f then raise(what .. ": " .. tostring(err)) end
  local data = f:read("*a")
  f:close()
  return data
end

-- The first id of a changed set's `"added"` list, `{"added": ["n1"], ...}`, or nil.
local function first_added(changed)
  local at = changed:find('"added"', 1, true)
  if not at then return nil end
  local i = changed:match('^%s*:%s*%[%s*"()', at + 7)
  if not i then return nil end
  local id = {}
  while i <= #changed do
    local c = changed:sub(i, i)
    if c == '"' then return table.concat(id) end
    if c == "\\" then
      i = i + 1
      c = changed:sub(i, i)
    end
    id[#id + 1] = c
    i = i + 1
  end
  return nil
end

local function free_document(h) lib().cadaclysm_blacksmith_document_free(h) end
local function free_nurbs_curve(h) lib().cadaclysm_blacksmith_nurbs_curve_free(h) end
local function free_cage(h) lib().cadaclysm_blacksmith_subd_free(h) end

--- A model as data: a graph of nodes (`profile.rect`, `solid.extrude`, `measure.mass`, ...),
--- each a blacksmith verb reading other nodes by id, with named parameters any number can be an
--- `"=expression"` of, evaluated incrementally, and edited by ops that are undoable and branch.
--- Every edit is one commit; the whole thing -- nodes, parameters, history, branches -- saves as
--- JSON text and loads back to the same document. `Document.kinds()` lists the node kinds.
---
---     local doc = bs.Document.new("mm")
---     doc:apply('{"op": "add", "node": {"id": "r1", "kind": "profile.rect", "w": 10, "h": 10}}')
---     doc:apply('{"op": "add", "node": {"id": "x1", "kind": "solid.extrude", "profile": "r1", "frame": "xy", "distance": 10}}')
---     local solid = doc:result_solid("x1")   -- an ordinary Solid of the caller's own
---
--- Ops, the changed sets, the statuses, the parameters, `errors`, `value`, the kinds, the branch
--- list, the log and the tips are JSON text, as the C ABI has them: this module reads no JSON.
--- A refused op raises `BuildError` with the library's reason (`document_apply: ...`), and the
--- document is unchanged. `result_*`, `value`, `errors` bring the nodes up to date first; each
--- `Solid`, `Profile`, `NurbsCurve` and `Subd` a result gives is the caller's own and outlives
--- later edits and the document. `close()` frees it; so does the garbage collector. A closed
--- document raises `document: closed`. One thread at a time.
---@class Document
local Document = {}
class(Document)
callable(Document)
M.Document = Document

local function new_document(handle, what)
  checked(handle, what)
  return setmetatable({ _ptr = ffi.gc(handle, free_document) }, Document)
end

Document.__tostring = function(self)
  local h = rawget(self, "_ptr")
  if h == nil then return "Document(closed)" end
  return ("Document(%s)"):format(tostring(h):match("0x%x+") or "?")
end

--- An empty document counting lengths in `units` (`mm`, `cm`, `m`, `in` or `ft`; nil is `mm`).
--- `Document(units)` is the same.
---@param units string|nil
---@return Document
function Document.new(units)
  local u = optional_text(units, "document_new", "units")
  return new_document(lib().cadaclysm_blacksmith_document_new(u), "document_new")
end

--- The document `save` wrote as `text`: its nodes, parameters, history and branches.
---@param text string
---@return Document
function Document.load(text)
  local t = text_arg(text, "document_load", "text")
  return new_document(lib().cadaclysm_blacksmith_document_load(t), "document_load")
end

--- The document saved in the file `path`.
---@param path string
---@return Document
function Document.open(path)
  return Document.load(read_text(path, "document_open"))
end

--- Every node kind the library knows, as the JSON text of an array of rows (`name`, `inputs`,
--- `output`, `cost`, `help`). Needs no document.
---@return string
function Document.kinds()
  return owned_text(lib().cadaclysm_blacksmith_document_kinds(), "document_kinds")
end

--- An empty building document: the blacksmith kinds and the `bim.*` ones, with a hidden
--- `bim.project` node whose random guid seeds every IFC GlobalId it exports.
---@param units string|nil
---@return Document
function Document.new_bim(units)
  local u = optional_text(units, "bim_document_new", "units")
  return new_document(lib().cadaclysm_bim_document_new(u), "bim_document_new")
end

--- A building document `save` wrote as `text`, opened with the `bim.*` kinds.
---@param text string
---@return Document
function Document.load_bim(text)
  local t = text_arg(text, "bim_document_load", "text")
  return new_document(lib().cadaclysm_bim_document_load(t), "bim_document_load")
end

--- The building document saved in the file `path`.
---@param path string
---@return Document
function Document.open_bim(path)
  return Document.load_bim(read_text(path, "bim_document_open"))
end

--- Every node kind a building document knows, the blacksmith's and the `bim.*` ones, as the
--- JSON text `kinds` gives. Needs no document.
---@return string
function Document.bim_kinds()
  return owned_text(lib().cadaclysm_bim_kinds(), "bim_kinds")
end

--- Free the document now. Idempotent; a result taken out earlier stays the caller's own.
function Document:close()
  local h = rawget(self, "_ptr")
  if h ~= nil then
    self._ptr = nil
    ffi.gc(h, nil)
    lib().cadaclysm_blacksmith_document_free(h)
  end
end

function Document:_h()
  local h = rawget(self, "_ptr")
  if h == nil then raise("document: closed") end
  return h
end

-- -- saving and editing

--- The document as JSON text (write it to a file yourself).
---@return string
function Document:save()
  return owned_text(lib().cadaclysm_blacksmith_document_save(self:_h()), "document_save")
end

--- Applies one op, as JSON text (`{"op": "add", "node": {...}}`, `set`, `remove`, `rename`,
--- `param`), recorded as one commit with `message` (nil: none). The changed set's JSON text,
--- `{"added": [ids], "changed": [ids], "removed": [ids], "params": [names]}`.
---@param op string
---@param message string|nil
---@return string
function Document:apply(op, message)
  local h = self:_h()
  local o = text_arg(op, "document_apply", "op")
  local m = optional_text(message, "document_apply", "message")
  return owned_text(lib().cadaclysm_blacksmith_document_apply(h, o, m), "document_apply")
end

local function add_holding(doc, op)
  local changed = doc:apply(op)
  local id = first_added(changed)
  if id == nil then raise("document_apply: no node was added (" .. changed .. ")") end
  return id
end

--- A node holding `solid` exactly as it is -- one made in code or read from a file -- for other
--- nodes to read like any built one: a `solid.body` (a `sheet.body` with `sheet` true) carrying
--- the kernel's own B-rep (`Solid:document_body`), its colours kept. Its id is returned.
---@param solid Solid
---@param sheet boolean|nil
---@return string
function Document:add_solid(solid, sheet)
  self:_h()
  solid_handle(solid, "add_solid")
  local kind = sheet and "sheet.body" or "solid.body"
  return add_holding(self, '{"op": "add", "node": {"kind": "' .. kind .. '", "body": ' .. solid:document_body() .. '}}')
end

--- A `profile.path` node holding `profile` exactly (`Profile:document_path`: arcs and NURBS as
--- they are, holes included, its colour kept). Its id is returned.
---@param profile Profile
---@return string
function Document:add_profile(profile)
  self:_h()
  profile_handle(profile, "add_profile")
  return add_holding(self, '{"op": "add", "node": {"kind": "profile.path", "path": ' .. profile:document_path() .. '}}')
end

--- The parameters' JSON text, name to value (a number, or an `"=expression"`). Read-only: set
--- one with a `param` op through `apply`.
---@return string
function Document:params()
  return owned_text(lib().cadaclysm_blacksmith_document_params(self:_h()), "document_params")
end

-- Python's `with` block as a call: `body`'s results, or its error passed on after `clean_up`
-- (whose own refusal is swallowed: the body's error is the one to report).
local function scoped(body, finish, clean_up)
  local results = { n = 0 }
  local function keep(ok, ...)
    results.n = select("#", ...)
    for i = 1, results.n do results[i] = select(i, ...) end
    return ok
  end
  if not keep(pcall(body)) then
    pcall(clean_up)
    error(results[1], 0)
  end
  finish()
  return unpack(results, 1, results.n)
end

local function body_arg(body, what)
  if type(body) ~= "function" then raise(what .. ": expected a function, got " .. repr(body)) end
  return body
end

--- `doc:batch(message, function() ... end)` (or `doc:batch(function() ... end)`): the ops `body`
--- applies go in live and are recorded as one commit with `message`; an empty batch records
--- nothing. An error inside rolls every op of the batch back and is raised again, the body's
--- own even when the roll-back is refused. A batch or preview already open raises
--- `document_batch_begin: ...`. Returns what `body` returns.
---@param message string|nil
---@param body function
function Document:batch(message, body)
  if body == nil and type(message) == "function" then message, body = nil, message end
  body_arg(body, "document_batch")
  local m = optional_text(message, "document_batch_begin", "message")
  if not lib().cadaclysm_blacksmith_document_batch_begin(self:_h(), m) then fail("document_batch_begin") end
  return scoped(body, function()
    owned_text(lib().cadaclysm_blacksmith_document_batch_end(self:_h()), "document_batch_end")
  end, function()
    owned_text(lib().cadaclysm_blacksmith_document_batch_abort(self:_h()), "document_batch_abort")
  end)
end

--- `doc:preview(function() ... end)`: the ops `body` applies evaluate but are never recorded,
--- and are taken back on leaving, normally or by an error (raised again, the body's own even
--- when the take-back is refused): a what-if. A batch or preview already open raises
--- `document_preview_begin: ...`. Returns what `body` returns.
---@param body function
function Document:preview(body)
  body_arg(body, "document_preview")
  if not lib().cadaclysm_blacksmith_document_preview_begin(self:_h()) then fail("document_preview_begin") end
  local function take_back() self:end_preview() end
  return scoped(body, take_back, take_back)
end

--- One frame of a drag: applies `op` (JSON text) unrecorded, after taking back the last frame,
--- so frames replace each other rather than stack. The changed set's JSON text, relative to the
--- state before the drag. `end_preview` takes the drag back.
---@param op string
---@return string
function Document:preview_frame(op)
  local h = self:_h()
  local o = text_arg(op, "document_preview", "op")
  return owned_text(lib().cadaclysm_blacksmith_document_preview(h, o), "document_preview")
end

--- Takes back an open preview or drag; the changed set's JSON text.
---@return string
function Document:end_preview()
  return owned_text(lib().cadaclysm_blacksmith_document_end_preview(self:_h()), "document_end_preview")
end

-- -- history

local function did_something(text) return text:match("^%s*(.-)%s*$") ~= "null" end

--- Takes back the head commit. False when there was nothing to take back.
---@return boolean
function Document:undo()
  return did_something(owned_text(lib().cadaclysm_blacksmith_document_undo(self:_h()), "document_undo"))
end

--- Puts back the commit `undo` took back. False when there was nothing to put back.
---@return boolean
function Document:redo()
  return did_something(owned_text(lib().cadaclysm_blacksmith_document_redo(self:_h()), "document_redo"))
end

--- The branch list's JSON text: `{"branches": {name: commit}, "branch": name|null, "head":
--- commit, "unnamed": [commit], "can_undo": bool, "can_redo": bool}`.
---@return string
function Document:branches()
  return owned_text(lib().cadaclysm_blacksmith_document_branch_list(self:_h()), "document_branch_list")
end

--- A new branch `name`. Without `at` it starts at the head and the document switches onto it;
--- with `at` (a commit id) it starts there and the head stays.
---@param name string
---@param at string|nil
function Document:branch_new(name, at)
  local h = self:_h()
  local n = text_arg(name, "document_branch_new", "name")
  local a = optional_text(at, "document_branch_new", "at")
  owned_text(lib().cadaclysm_blacksmith_document_branch_new(h, n, a), "document_branch_new")
end

--- Moves the head to the branch of that name, else to the commit of that id (which detaches the
--- head: the branch list's `branch` is then null). The nodes follow.
---@param name_or_commit_id string
function Document:switch(name_or_commit_id)
  local h = self:_h()
  local n = text_arg(name_or_commit_id, "document_branch_switch", "name")
  owned_text(lib().cadaclysm_blacksmith_document_branch_switch(h, n), "document_branch_switch")
end

--- Renames branch `old` to `new`; refused when `old` is missing or `new` is taken.
---@param old string
---@param new string
function Document:branch_rename(old, new)
  local h = self:_h()
  local o, n = text_arg(old, "document_branch_rename", "old"), text_arg(new, "document_branch_rename", "new")
  if not lib().cadaclysm_blacksmith_document_branch_rename(h, o, n) then fail("document_branch_rename") end
end

--- Deletes branch `name`; the current branch is refused. Its commits stay, as tips.
---@param name string
function Document:branch_delete(name)
  local h = self:_h()
  local n = text_arg(name, "document_branch_delete", "name")
  if not lib().cadaclysm_blacksmith_document_branch_delete(h, n) then fail("document_branch_delete") end
end

--- The tips of the lines no branch names -- what an undo followed by an edit leaves behind --
--- as the JSON text of whole commits, `[{"id", "parents", "message"?, "ops"}]`.
---@return string
function Document:tips()
  return owned_text(lib().cadaclysm_blacksmith_document_tips(self:_h()), "document_tips")
end

--- The commits of `branch`'s line as JSON text, newest first, the root `c0` last; nil is the
--- line from the head back to the root.
---@param branch string|nil
---@return string
function Document:log(branch)
  local h = self:_h()
  local b = optional_text(branch, "document_log", "branch")
  return owned_text(lib().cadaclysm_blacksmith_document_log(h, b), "document_log")
end

-- -- evaluating and reading back

--- Evaluates the nodes that are stale (only the cheap kinds with `cheap_only`); the JSON text of
--- every node's status, `[{"id", "state": "ok"|"error"|"blocked"|"pending", ...}]`.
---@param cheap_only boolean|nil
---@return string
function Document:evaluate(cheap_only)
  return owned_text(lib().cadaclysm_blacksmith_document_evaluate(self:_h(), cheap_only and true or false), "document_evaluate")
end

-- The document brought up to date, its handle and `id` as C takes it.
local function evaluated(doc, id, what)
  doc:evaluate(false)
  return doc:_h(), text_arg(id, what, "node id")
end

--- The JSON text of the nodes the evaluation left in error or blocked, `[{"id", "state", "message"}]`.
---@return string
function Document:errors()
  self:evaluate(false)
  return owned_text(lib().cadaclysm_blacksmith_document_errors(self:_h()), "document_errors")
end

--- Node `id`'s value as JSON text: a number, a point or list, a record, text. Raises for a node
--- with none (missing, or in error).
---@param id string
---@return string
function Document:value(id)
  local h, key = evaluated(self, id, "document_value")
  return owned_text(lib().cadaclysm_blacksmith_document_value(h, key), "document_value")
end

--- What node `id` evaluated to: `solid`, `sheet`, `profile`, `profiles`, `nurbs`, `subd`,
--- `curve`, `list` (its items are `id#0`, `id#1`, ...), `value` or `none` (no such node, or one
--- that failed). Read it with the `result_*` call of its kind, anything else with `value`.
---@param id string
---@return string
function Document:result_kind(id)
  local h, key = evaluated(self, id, "document_result_kind")
  return owned_text(lib().cadaclysm_blacksmith_document_result_kind(h, key), "document_result_kind")
end

--- Node `id`'s solid or sheet, a `Solid` of the caller's own.
---@param id string
---@return Solid
function Document:result_solid(id)
  local h, key = evaluated(self, id, "document_result_solid")
  return new_solid(lib().cadaclysm_blacksmith_document_result_solid(h, key), "document_result_solid")
end

--- Node `id`'s profile, a `Profile` of the caller's own.
---@param id string
---@return Profile
function Document:result_profile(id)
  local h, key = evaluated(self, id, "document_result_profile")
  return new_profile(lib().cadaclysm_blacksmith_document_result_profile(h, key), "document_result_profile")
end

--- Node `id`'s profiles, when it is a list of profiles (or a sketch): `Profile`s of the caller's own.
---@param id string
---@return Profile[]
function Document:result_profiles(id)
  local h, key = evaluated(self, id, "document_result_profile_count")
  local L = lib()
  local count = L.cadaclysm_blacksmith_document_result_profile_count(h, key)
  if count == NONE then fail("document_result_profile_count") end
  local out = {}
  for i = 0, count - 1 do
    out[i + 1] = new_profile(L.cadaclysm_blacksmith_document_result_profile_at(h, key, i), "document_result_profile_at")
  end
  return out
end

--- Node `id`'s curve in space, a `NurbsCurve` of the caller's own.
---@param id string
---@return NurbsCurve
function Document:result_nurbs_curve(id)
  local h, key = evaluated(self, id, "document_result_nurbs_curve")
  local c = checked(lib().cadaclysm_blacksmith_document_result_nurbs_curve(h, key), "document_result_nurbs_curve")
  return setmetatable({ _ptr = ffi.gc(c, free_nurbs_curve) }, M.NurbsCurve)
end

--- Node `id`'s subdivision cage, a `Subd` of the caller's own.
---@param id string
---@return Subd
function Document:result_subd(id)
  local h, key = evaluated(self, id, "document_result_subd")
  local c = checked(lib().cadaclysm_blacksmith_document_result_subd(h, key), "document_result_subd")
  return setmetatable({ _ptr = ffi.gc(c, free_cage) }, M.Subd)
end

--- The building as IFC text. `options` is C's JSON text, `{"schema": "IFC4" | "IFC2X3",
--- "geometry": "parametric" | "exact", "timestamp": <Unix seconds>, "name": <project name>}`,
--- every key optional; nil is every default (IFC4, parametric, now, no name). A refused export
--- raises the library's text verbatim: `bim_document_export_ifc: {"refusals": [{"node", "reason"}]}`.
---@param options string|nil
---@return string
function Document:export_ifc(options)
  local h = self:_h()
  local o = optional_text(options, "bim_document_export_ifc", "options")
  return owned_text(lib().cadaclysm_bim_document_export_ifc(h, o), "bim_document_export_ifc")
end

--- This solid as a `Document`'s `solid.body` node holds it, as JSON text: the kernel's own
--- B-rep, every number as it is, and its colours. What `Document:add_solid` puts in a document.
---@return string
function Solid:document_body()
  return owned_text(lib().cadaclysm_blacksmith_document_solid_body(self:_h()), "document_solid_body")
end

--- This profile as its exact segments, as a `Document`'s `profile.path` node holds it, as JSON
--- text: `{"start", "segments", "holes", "colour"}`. What `Document:add_profile` puts in a document.
---@return string
function Profile:document_path()
  return owned_text(lib().cadaclysm_blacksmith_document_profile_path(profile_handle(self, "document_path")), "document_profile_path")
end

end
documents()
end

return M
