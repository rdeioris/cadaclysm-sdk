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

local function main()
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
  local triangles = 0
  for _, n in ipairs(scene.nodes) do
    if n.can_mesh then triangles = triangles + n.mesh.triangle_count end
  end
  say("triangles=" .. triangles)

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

  scene:close()
  if sample:match("cube%.scad$") then
    for i = 1, 3 do
      if b.min[i] ~= 0 or b.max[i] ~= 20 or triangles ~= 12 then
        error("the cube did not come back as a 20-unit cube of 12 triangles")
      end
    end
  end

  -- The builder: an exact B-rep solid, its faces and its box.
  local box = bs.Solid.cuboid(10, 20, 30)
  local lo, hi = box.bounds[1], box.bounds[2]
  say(("cuboid: %d faces, bounds min=(%s) max=(%s)"):format(box.faces, fmt(lo), fmt(hi)))
  if box.faces ~= 6 then error("a cuboid has 6 faces, not " .. box.faces) end

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

  box:close()

  -- The reader, on the text the builder just wrote, against its built-in AP203 too.
  local built = cad.open_memory(text, "stp", nil, "cuboid.stp")
  local bb = built.bounds
  say(("scene: %d nodes, bounds min=(%s) max=(%s)"):format(built.node_count, fmt(bb.min), fmt(bb.max)))
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
end

local ok, err = pcall(main)
if not ok then say(tostring(err)) end
-- os.exit rather than love/lovr.event.quit: LÖVR 0.19 exits 0 whatever code it is given.
os.exit(ok and 0 or 1)
