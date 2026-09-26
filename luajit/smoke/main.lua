--[[
The smallest complete use of both modules, and the verdict on a shipped library:
the release pipeline runs this against every library it ships, as it runs the other
wrappers' smokes. The exit code is the result -- anything raised, from either
library, exits 1.

    luajit smoke/main.lua [sample] [license]    -- a plain LuaJIT
    lovec smoke [sample] [license]               -- headless LÖVE
    lovr smoke [sample] [license]                -- headless LÖVR (CADACLYSM_SMOKE_LOG=file to read it)

`sample` defaults to `samples/cube.scad`, relative to the working directory, as the
other smokes' do. `license` -- CADACLYSM_LICENSE / cadaclysm.lic as the libraries
look for it otherwise -- is loaded into both modules.
]]

-- The working directory as the host sees it. On Windows, `cmd`'s own `cd`: a shell's
-- PWD there can be an MSYS path (/d/a/...) that a native luajit.exe cannot open.
local function cwd()
  if lovr then return lovr.filesystem.getWorkingDirectory() end
  if package.config:sub(1, 1) == "\\" and io.popen then
    local pipe = io.popen("cd")
    if pipe then
      local dir = pipe:read("*l")
      pipe:close()
      if dir and dir ~= "" then return dir end
    end
  end
  return os.getenv("PWD") or "."
end

local function absolute(p)
  p = p:gsub("\\", "/")
  if p:match("^%a:/") or p:match("^/") then return p end
  return cwd():gsub("\\", "/") .. "/" .. p
end

local here
if love then
  here = absolute(love.filesystem.getSource())
elseif lovr then
  here = absolute(lovr.filesystem.getSource())
else
  here = absolute(arg[0]):match("^(.*)/[^/]*$")
end
package.path = here:match("^(.*)/[^/]*$") .. "/?.lua;" .. package.path

-- LÖVR on Windows prints to a console of its own, so a log file is the portable way
-- to read the result.
local log = os.getenv("CADACLYSM_SMOKE_LOG") and assert(io.open(os.getenv("CADACLYSM_SMOKE_LOG"), "w"))
local function say(line)
  print(line)
  if log then
    log:write(line, "\n")
    log:flush()
  end
end

-- The arguments after the script or game directory, whichever host passed them.
local args = {}
for _, a in ipairs(arg or {}) do
  local plain = a:gsub("\\", "/")
  if not (plain == here or absolute(plain) == here or plain:match("/?smoke/?$") or plain:match("main%.lua$")) then
    args[#args + 1] = a
  end
end

-- A path for a file this smoke writes, under the system's temp directory.
local function tmp(name)
  return (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/") .. "/" .. name
end

local function fmt(v)
  local out = {}
  for i = 1, 3 do out[i] = ("%.4f"):format(v[i]):gsub("0+$", ""):gsub("%.$", "") end
  return table.concat(out, ", ")
end

-- A quarter turn about z then 100 along x: the reader takes it as sixteen
-- column-major numbers, the kernel as twelve (origin, x, y, z). (x, y, z) -> (100 - y, x, z).
local TURNED_16 = { 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 100, 0, 0, 1 }
local TURNED_12 = { 100, 0, 0, 0, 1, 0, -1, 0, 0, 0, 0, 1 }
local function turned(x, y, z) return 100 - y, x, z end

-- The box of a FEM mesh's nodes, as one printable line.
local function fem_span(mesh)
  local min, max = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
  for i = 0, mesh.node_count - 1 do
    for k = 1, 3 do
      local v = mesh.nodes[3 * i + k - 1]
      min[k], max[k] = math.min(min[k], v), math.max(max[k], v)
    end
  end
  return ("(%s)..(%s)"):format(fmt(min), fmt(max))
end

-- Every node of `plain` must reappear in `placed` at `turned(node)`. What catches a
-- placement dropped, doubled or transposed: the bodies here sit off the axis of the
-- turn in the plane it acts in, which is what makes a transpose visible at all.
local function fem_placement_reached(what, plain, placed)
  if placed.node_count ~= plain.node_count then
    error(("%s: the placement changed the node count, %d against %d"):format(what, placed.node_count, plain.node_count))
  end
  for i = 0, plain.node_count - 1 do
    local x, y, z = plain.nodes[3 * i], plain.nodes[3 * i + 1], plain.nodes[3 * i + 2]
    local ex, ey, ez = turned(x, y, z)
    local found = false
    for k = 0, placed.node_count - 1 do
      if math.abs(placed.nodes[3 * k] - ex) < 1e-9 and math.abs(placed.nodes[3 * k + 1] - ey) < 1e-9
        and math.abs(placed.nodes[3 * k + 2] - ez) < 1e-9 then
        found = true
        break
      end
    end
    if not found then
      error(("%s: the placement did not send (%g, %g, %g) to (%g, %g, %g) -- the placed nodes span %s")
        :format(what, x, y, z, ex, ey, ez, fem_span(placed)))
    end
  end
end

-- What every FEM mesh must say about itself, whichever ABI built it.
local function fem_sound(what, mesh)
  if mesh.nodes == nil or mesh.triangles == nil or mesh.node_count == 0 or mesh.triangle_count == 0 then
    error(what .. ": a FEM mesh with no nodes or no triangles is a refusal, not a mesh")
  end
  for i = 0, mesh.triangle_count * 3 - 1 do
    if mesh.triangles[i] >= mesh.node_count then error(what .. ": a triangle index past the nodes") end
  end
  for i = 0, mesh.triangle_count - 1 do
    if mesh.triangle_face[i] >= mesh.face_count then error(what .. ": a triangle_face past the faces") end
  end
  -- Read once: `edges` and `vertices` are fields computed when read, one ABI call a row.
  local edges, vertices = mesh.edges, mesh.vertices
  for i = 0, mesh.node_count - 1 do
    local kind, entity = mesh.node_kind[i], mesh.node_entity[i]
    local bound = (kind == 0 and #vertices) or (kind == 1 and #edges) or (kind == 2 and mesh.face_count)
    if not bound or entity >= bound then
      error(("%s: node %d has kind %s entity %s, which its own kind cannot index")
        :format(what, i, tostring(kind), tostring(entity)))
    end
  end
  if not (mesh.min_angle > 0 and mesh.min_angle <= 60) then
    error(what .. ": min_angle " .. tostring(mesh.min_angle))
  end
  if not (mesh.longest_edge > 0) or mesh.worst_triangle >= mesh.triangle_count then
    error(what .. ": longest_edge " .. tostring(mesh.longest_edge) .. " worst " .. tostring(mesh.worst_triangle))
  end
  for i, e in ipairs(edges) do
    if #e.runs < 1 or e.runs[1] ~= 0 or #e.nodes < 2 then
      error(("%s: edge %d's chain does not start at 0"):format(what, i - 1))
    end
    for _, n in ipairs(e.nodes) do
      if n >= mesh.node_count then error(("%s: edge %d names node %d"):format(what, i - 1, n)) end
    end
    local rebuilt = {}
    for _, chain in ipairs(e:chains()) do
      for _, n in ipairs(chain) do rebuilt[#rebuilt + 1] = n end
    end
    if table.concat(rebuilt, ",") ~= table.concat(e.nodes, ",") then
      error(("%s: edge %d's chains do not rebuild its nodes"):format(what, i - 1))
    end
  end
  for _, row in ipairs(mesh.open_edges) do
    if row[1] >= mesh.node_count or row[2] >= mesh.node_count then
      error(what .. ": an open_edges row names a node past the mesh")
    end
  end
  for _, row in ipairs(mesh.folded_edges) do
    if row[1] >= mesh.node_count or row[2] >= mesh.node_count then
      error(what .. ": a folded_edges row names a node past the mesh")
    end
  end
  local msh = mesh:msh_text()
  if msh:sub(1, 11) ~= "$MeshFormat" or not msh:find("4.1 0 8", 1, true) then
    error(what .. ": msh_text is not Gmsh 4.1 ASCII: " .. msh:sub(1, 40))
  end
  -- Asked twice: the reader's text is a borrowed slot on the handle and the kernel's an
  -- owned string this wrapper frees, and the only way to tell either convention went
  -- wrong at run time is to ask the same handle again and compare.
  if #mesh:msh_text() ~= #msh then error(what .. ": a second msh_text read a different length") end
  local path = tmp("cadaclysm-smoke-luajit-fem.msh")
  mesh:save_msh(path)
  local f = assert(io.open(path, "rb"))
  local written = f:read("*a")
  f:close()
  if #written < #msh / 2 then
    error(("%s: save_msh wrote %d bytes where msh_text is %d"):format(what, #written, #msh))
  end
  return msh
end

-- A freed handle refuses every call that takes it, and nothing below reads a field of one.
local function fem_freed_refuses(what, mesh)
  mesh:free()
  mesh:free()
  if not mesh.freed then error(what .. ": freed is false after free()") end
  local calls = {
    function() return mesh:msh_text() end,
    function() return mesh:save_msh(tmp("cadaclysm-smoke-luajit-never.msh")) end,
    function() return mesh.edges end,
    function() return mesh.vertices end,
    function() return mesh.open_edges end,
    function() return mesh.folded_edges end,
  }
  for i, call in ipairs(calls) do
    local ok, err = pcall(call)
    if ok or not tostring(err):find("fem mesh: freed", 1, true) then
      error(("%s: call %d on a freed mesh gave %s"):format(what, i, tostring(err)))
    end
  end
end

-- The reader's FEM mesh: this node's body meshed for a solver. `telling` says whether
-- this body can tell a transposed placement from the right one: only a body sitting off
-- the axis the turn acts about, **in the plane it turns in**, can. cube.scad spans 0..20
-- in x and y and can; a cuboid centred on the origin cannot, because for a quarter turn
-- about z the transpose is then the correct map composed with a 180-degree turn, which an
-- axis-aligned corner set is invariant under.
local function fem_reader(cad, node, telling)
  local mesh = node:fem_mesh()
  local msh = fem_sound("fem", mesh)
  say(("fem: %s, %d faces, watertight=%s from_mesh=%s longest=%.4f, %d bytes of .msh")
    :format(tostring(mesh), mesh.face_count, tostring(mesh.watertight), tostring(mesh.from_mesh),
      mesh.longest_edge, #msh))
  if mesh.from_mesh then
    if #mesh.edges ~= 0 or #mesh.vertices ~= 0 then error("fem: a from_mesh body has no brep edges or vertices") end
    -- `fem_mesh_of_mesh` takes no options at all, so on this path neither field is
    -- read: a wrapper that checked either itself passes every other check here.
    local nan, inf = 0 / 0, math.huge
    for _, pair in ipairs({ { 0, 0 }, { -1, 0 }, { nan, 0 }, { 0.01, -1 }, { 0.01, nan }, { 0.01, inf } }) do
      local ok, other = pcall(function() return node:fem_mesh(pair[1], pair[2]) end)
      if not ok then
        error(("fem: tolerance %s max_size %s was refused on the mesh-only path: %s")
          :format(tostring(pair[1]), tostring(pair[2]), tostring(other)))
      end
      other:free()
    end
  else
    local ok, err = pcall(function() return node:fem_mesh(0) end)
    if ok or not tostring(err):find("tolerance must be finite and > 0", 1, true) then
      error("fem: a zero tolerance on a brep body was accepted or refused in other words: " .. tostring(err))
    end
  end
  -- A placement of sixteen numbers, and its length checked here because the ABI sees
  -- only a pointer. Twelve is the mistake a caller moving between the two ABIs makes.
  if telling then
    local short_ok, short_err = pcall(function() return node:fem_mesh(0.01, 0, { 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0 }) end)
    if short_ok or not tostring(short_err):find("a placement is 16 numbers, not 12", 1, true) then
      error("fem: the kernel's twelve numbers were taken as a placement: " .. tostring(short_err))
    end
    local placed = node:fem_mesh(0.01, 0, TURNED_16)
    fem_placement_reached("fem", mesh, placed)
    say("fem: the placement turned the nodes to " .. fem_span(placed))
    placed:free()
  end
  -- A FEM mesh is its own handle, not part of the scene's mesh cache: forgetting the
  -- meshes leaves it alone, where it stales a Mesh64.
  node.scene:forget_meshes()
  if mesh.node_count == 0 or #mesh:msh_text() == 0 then error("fem: forget_meshes touched the FEM mesh") end
  fem_freed_refuses("fem", mesh)
end

-- The kernel's FEM mesh: a solid meshed for a solver, and an open sheet's rim.
local function fem_kernel(bs)
  local box = bs.Solid.cuboid(20, 10, 4):translate(30, 7, 5)
  local phases = {}
  local mesh = box:fem_mesh(0.05, 0, nil, function(phase) phases[phase] = true end)
  fem_sound("kernel fem", mesh)
  if not (phases.meshing and phases.welding) then error("kernel fem: progress heard neither meshing nor welding") end
  if not mesh.watertight or #mesh.open_edges ~= 0 or #mesh.folded_edges ~= 0 then
    error("kernel fem: a cuboid is watertight with no cracks, but reads " .. tostring(mesh))
  end
  if mesh.from_mesh then error("kernel fem: every solid here has a brep, so from_mesh is always false") end
  for i, e in ipairs(mesh.edges) do
    if e.faces[1] == bs.NONE or e.faces[2] == bs.NONE then
      error(("kernel fem: edge %d of a closed solid bounds only one face"):format(i - 1))
    end
  end
  -- The frame is **twelve** numbers here, and the body sits off the axis of the turn in
  -- the plane it acts in: a cuboid is centred on its own origin, and for a quarter turn
  -- about z a transposed 3x3 block is then the correct map composed with a 180-degree
  -- turn, which an axis-aligned corner set is invariant under. Moved by (30, 7, 5) the
  -- two image boxes are disjoint in x: 88..98 correct against 102..112 transposed.
  local placed = box:fem_mesh(0.05, 0, TURNED_12)
  fem_placement_reached("kernel fem", mesh, placed)
  say(("kernel fem: %s, span %s -> %s"):format(tostring(mesh), fem_span(mesh), fem_span(placed)))
  placed:free()
  local capped = box:fem_mesh(0.05, 3.0)
  if capped.node_count <= mesh.node_count or capped.longest_edge > 3.0 * 1.05 then
    error(("kernel fem: max_size 3 gave %d nodes and longest_edge %s")
      :format(capped.node_count, tostring(capped.longest_edge)))
  end
  say(("kernel fem: max_size 3 -> %d nodes, longest_edge %.4f"):format(capped.node_count, capped.longest_edge))
  capped:free()
  -- Every solid here has a brep, so this side refuses what the reader's mesh-only path
  -- passes through, in the library's own words.
  local ok, err = pcall(function() return box:fem_mesh(0) end)
  if ok or not tostring(err):find("tolerance must be finite and > 0", 1, true) then
    error("kernel fem: a zero tolerance was accepted or refused in other words: " .. tostring(err))
  end
  -- An open sheet: watertight false with **both** censuses empty -- the trio that says
  -- "not asked" -- and every rim edge with one real face and NONE beside it.
  local sheet = bs.Solid.face(bs.Profile.rect(40, 20):with_hole(bs.Profile.circle(4)), { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 })
  local rim = sheet:fem_mesh(0.05)
  if rim.watertight or #rim.open_edges ~= 0 or #rim.folded_edges ~= 0 then
    error("kernel fem: the sheet reads " .. tostring(rim) .. ", not watertight=false with both censuses empty")
  end
  for i, e in ipairs(rim.edges) do
    if e.faces[1] ~= 0 or e.faces[2] ~= bs.NONE then
      error(("kernel fem: the sheet's rim edge %d reads faces %s/%s -- 0 is a real face, NONE is the sentinel")
        :format(i - 1, tostring(e.faces[1]), tostring(e.faces[2])))
    end
  end
  say(("kernel fem: the sheet's %d rim edges each bound one face"):format(#rim.edges))
  rim:free()
  sheet:close()
  -- A FEM mesh is its own handle: re-meshing the solid at another tolerance stales
  -- every view of its tessellation and leaves this untouched.
  box:mesh(0.5)
  if mesh.node_count == 0 or #mesh.edges == 0 or #mesh:msh_text() == 0 then
    error("kernel fem: re-meshing the solid staled the FEM mesh")
  end
  box:close()
  if mesh.node_count == 0 or #mesh:msh_text() == 0 then error("kernel fem: closing the solid staled the FEM mesh") end
  fem_freed_refuses("kernel fem", mesh)
end

local function main()
  local ffi = require("ffi")
  local cad = require("cadaclysm")
  local bs = require("cadaclysm_blacksmith")
  local sample = args[1] or "samples/cube.scad"
  if args[2] then
    cad.license(args[2])
    bs.license(args[2])
  end
  say(("cadaclysm %s built %s"):format(cad.version(), cad.build_date()))
  say("license: " .. cad.license_info())

  -- The reader: open the sample, print its bounds and the meshed triangle count,
  -- and -- for the shared cube.scad fixture -- check both exactly.
  local scene = cad.open(sample)
  local b = scene.bounds
  say(("bounds min=(%s) max=(%s)"):format(fmt(b.min), fmt(b.max)))
  local triangles, first_meshed = 0, nil
  for _, n in ipairs(scene.nodes) do
    if n.can_mesh then
      triangles = triangles + n.mesh.triangle_count
      if not first_meshed and not n.mesh.is_empty then first_meshed = n end
    end
  end
  say("triangles=" .. triangles)

  -- f64 twins: mesh64's counts and (narrowed) first position match mesh's; bounds64's
  -- max widens bounds' exactly, the cube being at small coordinates.
  if first_meshed then
    local m, m64 = first_meshed.mesh, first_meshed.mesh64
    if m64.vertex_count ~= m.vertex_count or m64.index_count ~= m.index_count then
      error(("mesh64: counts %d/%d do not match mesh's %d/%d"):format(m64.vertex_count, m64.index_count, m.vertex_count, m.index_count))
    end
    local narrowed = tonumber(ffi.cast("float", m64.positions[0]))
    if narrowed ~= m.positions[0] then
      error(("mesh64: first position narrowed to float (%s) does not equal mesh's (%s)"):format(narrowed, m.positions[0]))
    end
  end
  local b64 = scene.bounds64
  for i = 1, 3 do
    if b64.max[i] ~= b.max[i] then
      error(("bounds64: max[%d] %s does not equal bounds' max widened (%s)"):format(i, b64.max[i], b.max[i]))
    end
  end

  -- The scene's and a node's wireframe as SVG: the library's own camera, no viewer.
  local svg_text = scene:svg_text()
  if svg_text:sub(1, 4) ~= "<svg" or not svg_text:find("<path", 1, true) then
    error("scene svg_text did not look like an SVG wireframe")
  end
  local svg_path = tmp("cadaclysm-smoke-luajit.svg")
  scene:svg(svg_path)
  local f = assert(io.open(svg_path, "rb"))
  local written = f:read("*a")
  f:close()
  if #written == 0 then error("scene svg wrote an empty file") end
  local node_text = scene.roots[1]:svg_text()
  if node_text:sub(1, 4) ~= "<svg" or not node_text:find("<path", 1, true) then
    error("node svg_text did not look like an SVG wireframe")
  end
  local fov_ok = pcall(function() return scene:svg_text({ fov = 200 }) end)
  if fov_ok then error("scene svg: fov=200 was accepted") end
  say("svg: scene and node text, file written, fov=200 refused")

  -- Links and joints: the cube names neither; mechanism.stp, beside it, has the shared
  -- mechanism facts (two links, one joint, read the same way in every wrapper).
  if sample:match("cube%.scad$") and (#scene.links ~= 0 or #scene.joints ~= 0) then
    error("the cube's links and joints are not empty")
  end

  -- The FEM surface mesh: this node's body meshed for a solver.
  if first_meshed then fem_reader(cad, first_meshed, true) end

  scene:close()
  if sample:match("cube%.scad$") then
    for i = 1, 3 do
      if b.min[i] ~= 0 or b.max[i] ~= 20 or triangles ~= 12 then
        error("the cube did not come back as a 20-unit cube of 12 triangles")
      end
    end
    local dir = absolute(sample):match("^(.*)/[^/]*$")
    local mechanism = cad.open(dir .. "/mechanism.stp")
    local links, joints = mechanism.links, mechanism.joints
    if #links ~= 2 or links[1].name ~= "base" or links[2].name ~= "arm" then
      error("mechanism.stp: links are not [base, arm]")
    end
    for _, l in ipairs(links) do
      if #l.nodes ~= 1 or l.nodes[1].name ~= l.name then
        error("mechanism.stp: link " .. l.name .. " does not name one node of its own name")
      end
    end
    if #joints ~= 1 or joints[1].name ~= "hinge" or joints[1].start.name ~= "arm"
      or joints[1].start.index ~= 1 or joints[1].end_.name ~= "base" or joints[1].end_.index ~= 0 then
      error("mechanism.stp: the hinge joint did not read as arm(1) -> base(0)")
    end
    mechanism:close()
    say("links and joints: mechanism.stp read as base/arm/hinge, cube empty")
  end

  -- The builder: an exact B-rep solid, its faces and its box.
  local box = bs.Solid.cuboid(10, 20, 30)
  local lo, hi = box.bounds[1], box.bounds[2]
  say(("cuboid: %d faces, bounds min=(%s) max=(%s)"):format(box.faces, fmt(lo), fmt(hi)))
  if box.faces ~= 6 then error("a cuboid has 6 faces, not " .. box.faces) end

  -- f64 twins: mesh64(0.05) has mesh(0.05)'s counts; bounds_at64(0.05) equals bounds_at(0.05).
  local p32, _, i32 = box:mesh(0.05)
  local p64, _, i64 = box:mesh64(0.05)
  if p64.shape[1] ~= p32.shape[1] or i64.size ~= i32.size then
    error(("mesh64(0.05): counts %d/%d do not match mesh(0.05)'s %d/%d"):format(p64.shape[1], i64.size, p32.shape[1], i32.size))
  end
  local lo64, hi64 = box:bounds_at64(0.05)[1], box:bounds_at64(0.05)[2]
  for k = 1, 3 do
    if math.abs(lo64[k] - lo[k]) > 1e-9 or math.abs(hi64[k] - hi[k]) > 1e-9 then
      error("bounds_at64(0.05) does not equal bounds_at(0.05) (which box.bounds already is)")
    end
  end

  -- STEP out, with no schema: the kernel writes against its own built-in AP203.
  local text = box:step_text()
  say(("STEP: %d bytes with the built-in AP203"):format(#text))

  -- The solid's own wireframe as SVG, over the kernel ABI rather than the reader's.
  local solid_svg_text = box:svg_text()
  if solid_svg_text:sub(1, 4) ~= "<svg" or not solid_svg_text:find("<path", 1, true) then
    error("solid svg_text did not look like an SVG wireframe")
  end
  local solid_svg_path = tmp("cadaclysm-smoke-luajit-box.svg")
  box:svg(solid_svg_path)
  local sf = assert(io.open(solid_svg_path, "rb"))
  local solid_written = sf:read("*a")
  sf:close()
  if #solid_written == 0 then error("solid svg wrote an empty file") end
  local solid_fov_ok = pcall(function() return box:svg_text({ fov = 200 }) end)
  if solid_fov_ok then error("blacksmith svg: fov=200 was accepted") end
  say("blacksmith svg: solid text, file written, fov=200 refused")

  -- A profile's own plane, top by default -- pinned against an explicit iso call, not
  -- just checked non-empty, so a silently-iso default would fail this.
  local outline = bs.Profile.rect(80, 40):with_hole(bs.Profile.circle(4))
  local profile_svg_top = outline:svg_text()
  if profile_svg_top:sub(1, 4) ~= "<svg" or not profile_svg_top:find("<path", 1, true) then
    error("profile svg_text did not look like an SVG wireframe")
  end
  local profile_svg_path = tmp("cadaclysm-smoke-luajit-profile.svg")
  outline:svg(profile_svg_path)
  local pf = assert(io.open(profile_svg_path, "rb"))
  local profile_written = pf:read("*a")
  pf:close()
  if #profile_written == 0 then error("profile svg wrote an empty file") end
  local profile_svg_iso = outline:svg_text({ view = "iso" })
  if profile_svg_top == profile_svg_iso then error("Profile:svg_text did not default to the top view") end
  say("blacksmith svg: profile text, file written, top default confirmed against iso")

  -- The widened writer: a solid and a profile, any mix, drawn together in one call.
  local mixed = bs.write_svg_text({ box, outline })
  if not mixed:find("<path", 1, true) or not mixed:find('id="solid-0"', 1, true) or not mixed:find('id="profile-0"', 1, true) then
    error("the mixed drawing did not contain both group ids")
  end
  local mixed_path = tmp("cadaclysm-smoke-luajit-mixed.svg")
  bs.write_svg(mixed_path, { box, outline })
  local mxf = assert(io.open(mixed_path, "rb"))
  local mixed_written = mxf:read("*a")
  mxf:close()
  if #mixed_written == 0 then error("write_svg wrote an empty mixed file") end
  say("blacksmith svg: solid and profile drawn together, both group ids present")

  box:close()

  -- The reader, on the text the builder just wrote, against its built-in AP203 too.
  local built = cad.open_memory(text, "stp", nil, "cuboid.stp")
  local bb = built.bounds
  say(("scene: %d nodes, bounds min=(%s) max=(%s)"):format(built.node_count, fmt(bb.min), fmt(bb.max)))
  -- The same again on a real B-rep body -- this run's own STEP, read back -- which is the
  -- half that takes the brep path and so refuses a bad tolerance rather than ignoring it.
  fem_reader(cad, built.nodes[1], false)
  local size = bb.size
  local got = ("%d,%d,%d"):format(math.floor(size[1] + 0.5), math.floor(size[2] + 0.5), math.floor(size[3] + 0.5))
  built:close()
  if got ~= "10,20,30" then error("the cuboid did not come back 10 x 20 x 30, but " .. got) end

  -- Hits: two radius-5 circles six apart cross at two points, (3, -4) and (3, 4). At
  -- (3, 4) the first circle's upper arc is at t 0.2952 and the moved one's at 0.7048;
  -- at (3, -4) the other way round -- which catches the two sides read swapped.
  local crossing = bs.Profile.circle(5):hits(bs.Profile.circle(5):translate(6, 0))
  if #crossing ~= 2 then error("hits: two circles hit " .. #crossing .. " times, not 2") end
  local ys = { crossing[1].start[2], crossing[2].start[2] }
  table.sort(ys)
  if math.abs(ys[1] + 4) > 1e-9 or math.abs(ys[2] - 4) > 1e-9 then
    error(("hits: y %s, %s, not -4 and 4"):format(ys[1], ys[2]))
  end
  for _, h in ipairs(crossing) do
    local ta, tb = 0.7048, 0.2952
    if h.start[2] > 0 then ta, tb = tb, ta end
    if h.run or h.touch or h.a_start.loop_index ~= 0 or math.abs(h.start[1] - 3) > 1e-9
      or math.abs(h.a_start.t - ta) > 1e-3 or math.abs(h.b_start.t - tb) > 1e-3 then
      error(("hits: %s is not a crossing at (3, +-4) at t %s on a and %s on b"):format(tostring(h), ta, tb))
    end
  end
  say(("hits: %s, %s"):format(tostring(crossing[1]), tostring(crossing[2])))
  -- Common: the same two circles share one lens, four arcs (each circle's own seam stays
  -- a join) between two caps once extruded; moved apart they share nothing.
  local left, right = bs.Profile.circle(5), bs.Profile.circle(5):translate(6, 0)
  local lenses = left:common(right)
  if #lenses ~= 1 then error("common: two circles share " .. #lenses .. " regions, not 1") end
  local lens_faces = bs.Solid.extrude(lenses[1], { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 }, 1).faces
  if lens_faces ~= 6 then error("common: the lens extrudes to " .. lens_faces .. " faces, not 6") end
  if #left:common(right:translate(100, 0)) ~= 0 then error("common: circles 100 apart share a region") end
  local ok, err = pcall(function() left:common(right, 0) end)
  if ok or not tostring(err):find("profile_common: tolerance must be positive and finite", 1, true) then
    error("common: a zero tolerance was accepted or refused in other words: " .. tostring(err))
  end
  say(("common: one lens, %d faces extruded"):format(lens_faces))
  -- Edge curves: a cylinder's rims are circles of its radius about a cap centre, a whole turn
  -- each; a cuboid's edges are lines whose origin + x is the far end.
  local function norm(v) return math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3]) end
  local rims = {}
  for _, e in ipairs(bs.Solid.cylinder(5, 3).edges) do if e.kind == "circle" then rims[#rims + 1] = e.curve end end
  if #rims < 2 then error("edge_curve: the cylinder's rims have no curve") end
  for _, c in ipairs(rims) do
    local unit = math.abs(norm(c.x) - 1) < 1e-9 and math.abs(norm(c.y) - 1) < 1e-9
      and math.abs(c.x[1] * c.y[1] + c.x[2] * c.y[2] + c.x[3] * c.y[3]) < 1e-9
    local centred = math.abs(c.origin[1]) < 1e-9 and math.abs(c.origin[2]) < 1e-9
      and math.min(math.abs(c.origin[3]), math.abs(c.origin[3] - 3)) < 1e-9
    if c.kind ~= "circle" or math.abs(c.radius - 5) > 1e-9 or not unit or not centred
      or math.abs(math.abs(c.t1 - c.t0) - 2 * math.pi) > 1e-9 or c.degree ~= 0 or #c.knots ~= 0 or c.weights ~= nil then
      error("edge_curve: a rim reads " .. tostring(c))
    end
  end
  for _, e in ipairs(bs.Solid.cuboid(2, 4, 6).edges) do
    local c = e.curve
    if c == nil or c.kind ~= "line" or c.t0 ~= 0 or c.t1 ~= 1 then error("edge_curve: a cuboid edge reads " .. tostring(c)) end
    local far = { c.origin[1] + c.x[1], c.origin[2] + c.x[2], c.origin[3] + c.x[3] }
    local at_origin, at_far = false, false
    for _, s in ipairs(e.segments) do
      for _, p in ipairs(s) do
        if norm({ p[1] - c.origin[1], p[2] - c.origin[2], p[3] - c.origin[3] }) < 1e-9 then at_origin = true end
        if norm({ p[1] - far[1], p[2] - far[2], p[3] - far[3] }) < 1e-9 then at_far = true end
      end
    end
    if not (at_origin and at_far) then error("edge_curve: a cuboid line's ends are not its own vertices: " .. tostring(c)) end
  end
  say("edge_curve: " .. tostring(rims[1]))
  -- Intersect: two equal pipes crossing at right angles meet on ellipse chains whose points
  -- lie on both pipes; apart, nothing; two coaxial pipes overlapping in height share a wall band.
  local tol = 1e-3
  local function off_a(p) return math.abs(math.sqrt(p[1] * p[1] + p[2] * p[2]) - 1) end
  local function off_b(p) return math.abs(math.sqrt(p[1] * p[1] + (p[3] - 3) * (p[3] - 3)) - 1) end
  local pipe_a = bs.Solid.cylinder(1, 6)
  local pipe_b = bs.Solid.cylinder(1, 6):rotate({ 0, 0, 3, 1, 0, 0 }, math.pi / 2)
  local found = pipe_a:intersect(pipe_b, tol)
  if #found.chains < 2 or #found.overlaps ~= 0 then error("intersect: the crossed pipes read " .. tostring(found)) end
  local ellipses = 0
  for _, c in ipairs(found.chains) do
    if #c.points < 2 then error("intersect: a chain reads " .. tostring(c)) end
    for _, p in ipairs(c.points) do
      if off_a(p) > 50 * tol or off_b(p) > 50 * tol then error("intersect: a chain leaves the pipes: " .. tostring(c)) end
    end
    if c.curve ~= nil then
      if c.curve.kind ~= "ellipse" and c.curve.kind ~= "nurbs" then error("intersect: a chain's curve reads " .. tostring(c.curve)) end
      if c.curve.kind == "ellipse" then
        ellipses = ellipses + 1
        local cv, t = c.curve, (c.curve.t0 + c.curve.t1) / 2
        local q = {}
        for k = 1, 3 do q[k] = cv.origin[k] + cv.x[k] * cv.radius * math.cos(t) + cv.y[k] * cv.radius2 * math.sin(t) end
        if off_a(q) > 50 * tol or off_b(q) > 50 * tol then error("intersect: the ellipse leaves the pipes at " .. tostring(cv)) end
      end
    end
  end
  if ellipses == 0 then error("intersect: two equal pipes cross on ellipses") end
  local apart = pipe_a:intersect(pipe_b:translate(10, 0, 0))
  if #apart.chains ~= 0 or #apart.overlaps ~= 0 then error("intersect: pipes apart read " .. tostring(apart)) end
  local ok_tol, err_tol = pcall(function() return pipe_a:intersect(pipe_b, 0.0) end)
  if ok_tol or not tostring(err_tol):find("intersect: tolerance must be positive and finite", 1, true) then
    error("intersect: a zero tolerance was accepted or refused in other words: " .. tostring(err_tol))
  end
  local shared = bs.Solid.cylinder(1, 4):intersect(bs.Solid.cylinder(1, 4):translate(0, 0, 2), tol)
  if #shared.overlaps < 1 or #shared.overlaps[1].loops < 1 then error("intersect: the coaxial pipes read " .. tostring(shared)) end
  for _, ring in ipairs(shared.overlaps[1].loops) do
    if #ring < 3 then error("intersect: an overlap ring is not a polygon: " .. tostring(shared.overlaps[1])) end
    for _, p in ipairs(ring) do
      if off_a(p) > 50 * tol or p[3] < 2 - 50 * tol or p[3] > 4 + 50 * tol then
        error("intersect: an overlap ring leaves the shared band: " .. tostring(shared.overlaps[1]))
      end
    end
  end
  say(("intersect: %s (%d ellipses); %s"):format(tostring(found), ellipses, tostring(shared.overlaps[1])))
  -- Solid x profile hits: a line through a cuboid pierces two faces and is cut into three
  -- pieces, outside/inside/outside, the middle one spanning the box.
  local xy = { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 }
  local pierced = bs.Solid.cuboid(10, 20, 30):hits(bs.Profile.path({ -20, 0 }):line_to(20, 0):end_open(), xy)
  local pieces = pierced.pieces
  if #pierced.hits ~= 2 or #pieces ~= 3 or pieces[1].inside or not pieces[2].inside or pieces[3].inside then
    error("solid hits: a line through a cuboid reads " .. tostring(pierced))
  end
  local span = bs.Solid.extrude_open(pieces[2].profile, xy, 1).bounds
  if math.abs(span[1][1] + 5) > 0.05 or math.abs(span[2][1] - 5) > 0.05 then
    error(("solid hits: the middle piece spans x %s .. %s"):format(span[1][1], span[2][1]))
  end
  say(("solid hits: %s; %s"):format(tostring(pierced), tostring(pieces[2])))

  -- The kernel's FEM mesh: a solid meshed for a solver, and an open sheet's rim.
  fem_kernel(bs)
end

local ok, err = pcall(main)
if not ok then say(tostring(err)) end
-- os.exit rather than love/lovr.event.quit: LÖVR 0.19 exits 0 whatever code it is given.
os.exit(ok and 0 or 1)
