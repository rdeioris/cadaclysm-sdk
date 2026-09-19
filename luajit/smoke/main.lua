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
  box:close()

  -- The reader, on the text the builder just wrote, against its built-in AP203 too.
  local built = cad.open_memory(text, "stp", nil, "cuboid.stp")
  local bb = built.bounds
  say(("scene: %d nodes, bounds min=(%s) max=(%s)"):format(built.node_count, fmt(bb.min), fmt(bb.max)))
  local size = bb.size
  local got = ("%d,%d,%d"):format(math.floor(size[1] + 0.5), math.floor(size[2] + 0.5), math.floor(size[3] + 0.5))
  built:close()
  if got ~= "10,20,30" then error("the cuboid did not come back 10 x 20 x 30, but " .. got) end
end

local ok, err = pcall(main)
if not ok then say(tostring(err)) end
-- os.exit rather than love/lovr.event.quit: LÖVR 0.19 exits 0 whatever code it is given.
os.exit(ok and 0 or 1)
