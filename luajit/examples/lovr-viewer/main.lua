--[[
A CAD file in LÖVR: the shaded model with its edges, in 3D.

    lovr examples/lovr-viewer [MODEL]      -- from the luajit/ directory

    drag    orbit           wheel   zoom
    e       edges on/off    t       the node tree
    f       frame the model

Desktop by default; `CADACLYSM_LOVR_VR=1` runs it in a headset, where the model
sits at table-top size in front of you (see conf.lua).

`--shot out.png` renders one frame offscreen, writes it and quits. `--bench N`
spins the camera for N seconds and reports the frame rate (run it with
CADACLYSM_LOVR_BENCH=1 so vsync is off). `--log file` writes those reports to a
file, since LÖVR on Windows prints to a console of its own. `--yaw`/`--pitch`
set the camera.
]]

-- LÖVR 0.19 hands back the project path as typed; make it absolute.
local base = lovr.filesystem.getSource():gsub("\\", "/")
if not base:match("^%a:/") and not base:match("^/") then
  base = lovr.filesystem.getWorkingDirectory():gsub("\\", "/") .. "/" .. base
end
-- The wrapper and its engine helpers are two directories up (luajit/).
package.path = base .. "/../../?.lua;" .. base .. "/?.lua;" .. package.path

local cadaclysm = require("cadaclysm")
local CL = require("cadaclysm_lovr")

local DEFAULT_MODEL = base .. "/../../../../../cadaclysm-acis/tests/fixtures/fusion/assembly.stp"
local GREY = { 0.72, 0.74, 0.78, 1 }
local FOV = math.rad(45)

local scene, model_name, stats, tree = nil, "", {}, {}
local draws, edges = {}, {}
local show_edges, show_tree = true, true
local centre, radius = { 0, 0, 0 }, 1
local yaw, pitch, distance = 0.8, 0.45, 3
local shot, bench, log
local vr = lovr.headset ~= nil
local root -- VR only: carries the model to the table-top

local shader = lovr.graphics.newShader("unlit", [[
Constants {
  vec3 light;
};
vec4 lovrmain() {
  vec3 n = normalize(Normal);
  if (!gl_FrontFacing) n = -n;
  float key = max(dot(n, light), 0.0);
  float sky = 0.5 + 0.5 * n.y;
  return vec4(Color.rgb * (0.18 + 0.62 * key + 0.25 * sky), Color.a);
}
]])

local function report(line)
  print(line)
  if log then
    log:write(line, "\n")
    log:flush()
  end
end

-- ---- the model ------------------------------------------------------------------

local function frame()
  local b = scene.bounds
  if b.is_empty then
    centre, radius = { 0, 0, 0 }, 1
  else
    local sx, sy, sz = unpack(b.size)
    centre = b.centre
    radius = math.max(0.5 * math.sqrt(sx * sx + sy * sy + sz * sz), 1e-6)
  end
  distance = radius / math.sin(FOV / 2) * 1.05
  -- In a headset, half a metre across, a metre up and half a metre ahead.
  local s = 0.25 / radius
  root = lovr.math.newMat4():translate(0, 1.0, -0.6):scale(s):translate(-centre[1], -centre[2], -centre[3])
end

local function open_model(path)
  scene = cadaclysm.open(path, nil, "y-up")
  model_name = path:gsub("\\", "/"):match("[^/]*$")

  local t0 = lovr.timer.getTime()
  scene:realize_all()
  local t1 = lovr.timer.getTime()

  -- One LÖVR mesh per distinct geometry node (and one edge mesh), drawn once
  -- per placement of it.
  draws, edges = {}, {}
  local uploaded, meshes, triangles, segments = {}, 0, 0, 0
  for _, p in ipairs(scene.placements) do
    local g = p.geometry
    local entry = uploaded[g.index]
    if entry == nil then
      local m = g.mesh
      local lines, n = CL.edges(g.edges)
      entry = { mesh = CL.mesh(m), triangles = m.triangle_count, lines = lines, segments = n or 0 }
      uploaded[g.index] = entry
      if entry.mesh then meshes = meshes + 1 end
    end
    local t = p.raw_transform
    local transform = lovr.math.newMat4(unpack(t))
    if entry.mesh then
      draws[#draws + 1] = { mesh = entry.mesh, transform = transform, colour = g.colour or p.select.colour or GREY }
      triangles = triangles + entry.triangles
    end
    if entry.lines then
      edges[#edges + 1] = { mesh = entry.lines, transform = transform }
      segments = segments + entry.segments
    end
  end

  tree = {}
  for n in scene:walk() do
    tree[#tree + 1] = ("  "):rep(n.depth) .. n.label .. (n.can_mesh and "  *" or "")
    if #tree >= 24 then
      tree[#tree + 1] = "  ..."
      break
    end
  end
  stats = {
    nodes = scene.node_count, placements = #scene.placements, meshes = meshes,
    triangles = triangles, segments = segments, realize = t1 - t0, upload = lovr.timer.getTime() - t1,
  }
  frame()
end

-- ---- drawing --------------------------------------------------------------------

local function eye()
  local cp = math.cos(pitch)
  return centre[1] + distance * cp * math.sin(yaw), centre[2] + distance * math.sin(pitch),
    centre[3] + distance * cp * math.cos(yaw)
end

local function draw_scene(pass, width, height)
  local ex, ey, ez = eye()
  if not vr then
    pass:setViewPose(1, lovr.math.mat4():lookAt(vec3(ex, ey, ez), vec3(centre[1], centre[2], centre[3]), vec3(0, 1, 0)), true)
    -- Far plane 0: LÖVR's infinite reverse-Z, which its default depth test expects.
    pass:setProjection(1, lovr.math.mat4():perspective(FOV, width / height, distance * 0.001, 0))
  end
  local lx, ly, lz = ex - centre[1] + radius, ey - centre[2] + 2 * radius, ez - centre[3]
  local ll = math.sqrt(lx * lx + ly * ly + lz * lz)

  if vr then
    pass:push()
    pass:transform(root)
  end
  pass:setShader(shader)
  pass:send("light", vec3(lx / ll, ly / ll, lz / ll))
  -- Faces pushed back a little so the edges drawn on them win the depth test.
  -- Lines take no depth offset of their own, so it has to be this way round.
  pass:setDepthOffset(-2, -2)
  for _, d in ipairs(draws) do
    pass:setColor(d.colour)
    pass:draw(d.mesh, d.transform)
  end
  pass:setDepthOffset(0, 0)
  pass:setShader()
  if show_edges then
    pass:setColor(0.06, 0.07, 0.09, 1)
    for _, e in ipairs(edges) do
      pass:draw(e.mesh, e.transform)
    end
  end
  if vr then pass:pop() end

  -- The HUD, a metre in front of the camera, sized from the field of view.
  if not vr then
    local hud = lovr.math.mat4():target(vec3(ex, ey, ez), vec3(centre[1], centre[2], centre[3]), vec3(0, 1, 0))
    local half_h = math.tan(FOV / 2)
    local half_w = half_h * width / height
    local px = 2 * half_h / height -- one pixel at a metre
    hud:translate(-half_w + 12 * px, half_h - 10 * px, -1):scale(15 * px)
    pass:setDepthTest()
    pass:setColor(0.9, 0.9, 0.92, 1)
    local lines = {
      ("%s   %d nodes, %d placements, %d meshes, %d triangles, %d edge segments"):format(model_name, stats.nodes,
        stats.placements, stats.meshes, stats.triangles, stats.segments),
      ("meshed %.0f ms, uploaded %.0f ms   %d fps   LÖVR %d.%d.%d"):format(stats.realize * 1000, stats.upload * 1000,
        lovr.timer.getFPS(), lovr.getVersion()),
    }
    if show_tree then
      lines[#lines + 1] = ""
      for _, row in ipairs(tree) do lines[#lines + 1] = row end
    end
    pass:text(table.concat(lines, "\n"), hud, 0, "left", "top")
    pass:setDepthTest("gequal")
  end
end

-- ---- LÖVR -----------------------------------------------------------------------

function lovr.load()
  local path
  local i = 1
  while arg[i] do
    local a = arg[i]
    if a == "--shot" then shot = arg[i + 1]; i = i + 1
    elseif a == "--bench" then bench = { seconds = tonumber(arg[i + 1]), frames = 0, time = 0 }; i = i + 1
    elseif a == "--log" then log = assert(io.open(arg[i + 1], "w")); i = i + 1
    elseif a == "--yaw" then yaw = tonumber(arg[i + 1]); i = i + 1
    elseif a == "--pitch" then pitch = tonumber(arg[i + 1]); i = i + 1
    else path = a end
    i = i + 1
  end
  lovr.graphics.setBackgroundColor(0.13, 0.14, 0.16)
  local ok, err = pcall(open_model, path or DEFAULT_MODEL)
  if not ok then
    report("could not open: " .. tostring(err))
    os.exit(1)
  end
  report(("%s: %d triangles, %d edge segments, meshed %.2f s, uploaded %.2f s"):format(model_name, stats.triangles,
    stats.segments, stats.realize, stats.upload))

  if shot then
    -- Offscreen, one frame, read back: no window timing involved.
    local w, h = 1280, 800
    local texture = lovr.graphics.newTexture(w, h, { usage = { "render", "transfer" }, mipmaps = false })
    local pass = lovr.graphics.newPass(texture)
    pass:setClear(0.13, 0.14, 0.16, 1)
    draw_scene(pass, w, h)
    lovr.graphics.submit(pass)
    local png = texture:getPixels():encode()
    local f, why = io.open(shot, "wb")
    if f then
      f:write(png:getString())
      f:close()
      report("wrote " .. shot)
    else
      report("screenshot not written: " .. tostring(why))
    end
    -- os.exit, not lovr.event.quit: LÖVR 0.19 on Windows exits 0 whatever code it is given.
    os.exit(f and 0 or 1)
  end
end

function lovr.update(dt)
  if not bench then return end
  -- LÖVR's first dt spans the whole load (seconds on a big model): skip it.
  if not bench.started then
    bench.started = true
    return
  end
  yaw = yaw + dt * 0.5
  bench.frames, bench.time = bench.frames + 1, bench.time + dt
  if bench.time >= bench.seconds then
    report(("%s: %d frames in %.1f s, %.1f fps"):format(model_name, bench.frames, bench.time, bench.frames / bench.time))
    os.exit(0)
  end
end

function lovr.draw(pass)
  local w, h = pass:getDimensions()
  draw_scene(pass, w, h)
end

function lovr.mousemoved(x, y, dx, dy)
  if lovr.system.isMouseDown(1) then
    yaw = yaw - dx * 0.008
    pitch = math.max(-1.5, math.min(1.5, pitch + dy * 0.008))
  end
end

function lovr.wheelmoved(_, dy)
  distance = distance * 0.9 ^ dy
end

function lovr.keypressed(key)
  if key == "escape" then lovr.event.quit()
  elseif key == "e" then show_edges = not show_edges
  elseif key == "t" then show_tree = not show_tree
  elseif key == "f" then frame()
  end
end

function lovr.quit()
  if scene then scene:close() end
end
