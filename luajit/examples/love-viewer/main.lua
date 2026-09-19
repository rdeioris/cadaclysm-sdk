--[[
A CAD file in LÖVE: the shaded model in 3D, or its edges as a 2D drawing.

    love examples/love-viewer [MODEL]      -- from the luajit/ directory
    drop a file on the window to open another

    drag         orbit (3D) / pan (2D)
    wheel        zoom
    tab          3D model <-> 2D drawing
    1 2 3        drawing: front, top, right
    t            the node tree
    f            frame the model

`--shot out.png` draws a few frames, writes a screenshot and quits; `--mode 2d`
and `--view top|front|right` pick what it shows. The library is found as
cadaclysm.lua documents it: CADACLYSM_LIBRARY, beside the files, lib/ or
target/release in an ancestor.
]]

local base = love.filesystem.getSource():gsub("\\", "/")
-- The wrapper and its engine helpers are two directories up (luajit/).
package.path = base .. "/../../?.lua;" .. base .. "/?.lua;" .. package.path

local cadaclysm = require("cadaclysm")
local CL = require("cadaclysm_love")

local DEFAULT_MODEL = base .. "/../../../../../cadaclysm-acis/tests/fixtures/fusion/assembly.stp"
local GREY = { 0.72, 0.74, 0.78, 1 }

local scene, model_name
local draws, tree, stats = {}, {}, {}
local drawing, drawing_view = nil, "front"
local mode, show_tree, message = "3d", true, nil
local centre, radius = { 0, 0, 0 }, 1
local yaw, pitch, distance = 0.8, 0.45, 3
local pan2d = { x = 0, y = 0, scale = 1 }
local shot, bench

local line_shader = love.graphics.newShader(CL.LINE_SHADER)
local shader = love.graphics.newShader([[
varying vec3 v_normal;

#ifdef VERTEX
attribute vec3 VertexNormal;
uniform mat4 u_viewproj;
uniform mat4 u_model;
vec4 position(mat4 transform_projection, vec4 vertex_position) {
  v_normal = mat3(u_model) * VertexNormal;
  return u_viewproj * u_model * vertex_position;
}
#endif

#ifdef PIXEL
uniform vec3 u_light;
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen) {
  vec3 n = normalize(v_normal);
  if (!gl_FrontFacing) n = -n;
  float key = max(dot(n, u_light), 0.0);
  float sky = 0.5 + 0.5 * n.y;
  return vec4(color.rgb * (0.18 + 0.62 * key + 0.25 * sky), color.a);
}
#endif
]])

-- ---- column-major 4x4s, as the ABI hands them over ----------------------------

local function mul(a, b)
  local r = {}
  for c = 0, 3 do
    for row = 0, 3 do
      local s = 0
      for k = 0, 3 do s = s + a[k * 4 + row + 1] * b[c * 4 + k + 1] end
      r[c * 4 + row + 1] = s
    end
  end
  return r
end

local function perspective(fovy, aspect, near, far)
  local f = 1 / math.tan(fovy / 2)
  return { f / aspect, 0, 0, 0, 0, f, 0, 0, 0, 0, (far + near) / (near - far), -1,
           0, 0, 2 * far * near / (near - far), 0 }
end

local function normalize(x, y, z)
  local l = math.sqrt(x * x + y * y + z * z)
  return x / l, y / l, z / l
end

local function look_at(ex, ey, ez, tx, ty, tz)
  local fx, fy, fz = normalize(tx - ex, ty - ey, tz - ez)
  local sx, sy, sz = normalize(fy * 0 - fz * 1, fz * 0 - fx * 0, fx * 1 - fy * 0) -- f x up(0,1,0)
  local ux, uy, uz = sy * fz - sz * fy, sz * fx - sx * fz, sx * fy - sy * fx
  return { sx, ux, -fx, 0, sy, uy, -fy, 0, sz, uz, -fz, 0,
           -(sx * ex + sy * ey + sz * ez), -(ux * ex + uy * ey + uz * ez), fx * ex + fy * ey + fz * ez, 1 }
end

local function columns(m)
  return { { m[1], m[2], m[3], m[4] }, { m[5], m[6], m[7], m[8] },
           { m[9], m[10], m[11], m[12] }, { m[13], m[14], m[15], m[16] } }
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
  distance = radius / math.sin(math.rad(22.5)) * 1.05
end

local VIEWS = {
  front = function(x, y, z) return x, -y end,
  top = function(x, y, z) return x, z end,
  right = function(x, y, z) return -z, -y end,
}

-- The edges of every placement, flattened for the current view. Built on
-- demand: a big assembly has millions of edge points and the 3D view needs none.
local function build_drawing()
  local sources = {}
  for _, p in ipairs(scene.placements) do
    local g, t = p.geometry, p.raw_transform
    sources[#sources + 1] = { g.edges, t }
    sources[#sources + 1] = { g.curves, t }
  end
  local mesh, segments, lo_u, lo_v, hi_u, hi_v = CL.line_mesh(sources, VIEWS[drawing_view])
  drawing = { mesh = mesh, segments = segments }
  local w, h = love.graphics.getDimensions()
  if mesh then
    local s = 0.85 * math.min(w / math.max(hi_u - lo_u, 1e-9), h / math.max(hi_v - lo_v, 1e-9))
    pan2d = { scale = s, x = w / 2 - s * (lo_u + hi_u) / 2, y = h / 2 - s * (lo_v + hi_v) / 2 }
  end
end

local function open_model(path)
  local ok, opened = pcall(cadaclysm.open, path, nil, "y-up")
  if not ok then
    message = tostring(opened)
    return
  end
  if scene then scene:close() end
  scene, model_name, message = opened, path:gsub("\\", "/"):match("[^/]*$"), nil
  drawing = nil

  local t0 = love.timer.getTime()
  scene:realize_all()
  local t1 = love.timer.getTime()

  -- One LÖVE mesh per distinct geometry node, drawn once per placement of it.
  draws = {}
  local uploaded, meshes, triangles = {}, 0, 0
  for _, p in ipairs(scene.placements) do
    local g = p.geometry
    local entry = uploaded[g.index]
    if entry == nil then
      local m = g.mesh
      entry = { mesh = CL.mesh(m), triangles = m.triangle_count }
      uploaded[g.index] = entry
      if entry.mesh then meshes = meshes + 1 end
    end
    if entry.mesh then
      draws[#draws + 1] = {
        mesh = entry.mesh,
        model = columns(p.raw_transform),
        colour = g.colour or p.select.colour or GREY,
      }
      triangles = triangles + entry.triangles
    end
  end

  tree = {}
  for n in scene:walk() do
    tree[#tree + 1] = ("  "):rep(n.depth) .. n.label .. (n.can_mesh and "  *" or "")
    if #tree >= 60 then
      tree[#tree + 1] = "  ..."
      break
    end
  end
  stats = {
    nodes = scene.node_count,
    placements = #scene.placements,
    meshes = meshes,
    triangles = triangles,
    realize = t1 - t0,
    upload = love.timer.getTime() - t1,
  }
  frame()
end

-- ---- LÖVE ---------------------------------------------------------------------

function love.load(args)
  local path
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--shot" then shot = { path = args[i + 1], frames = 0 }; i = i + 1
    elseif a == "--mode" then mode = args[i + 1]; i = i + 1
    elseif a == "--view" then drawing_view = args[i + 1]; i = i + 1
    elseif a == "--yaw" then yaw = tonumber(args[i + 1]); i = i + 1
    elseif a == "--pitch" then pitch = tonumber(args[i + 1]); i = i + 1
    elseif a == "--bench" then bench = { seconds = tonumber(args[i + 1]), frames = 0, time = 0 }; i = i + 1
    else path = a end
    i = i + 1
  end
  open_model(path or DEFAULT_MODEL)
  if bench then love.window.setVSync(0) end
end

-- `--bench SECONDS`: spin the camera without vsync and print the frame rate.
function love.update(dt)
  if not bench then return end
  yaw = yaw + dt * 0.5
  bench.frames, bench.time = bench.frames + 1, bench.time + dt
  if bench.time >= bench.seconds then
    print(("%s: %d frames in %.1f s, %.1f fps (%s)"):format(model_name, bench.frames, bench.time,
      bench.frames / bench.time, mode))
    love.event.quit()
  end
end

function love.filedropped(file)
  open_model(file:getFilename())
end

local function draw_3d()
  local w, h = love.graphics.getDimensions()
  local cp = math.cos(pitch)
  local ex = centre[1] + distance * cp * math.sin(yaw)
  local ey = centre[2] + distance * math.sin(pitch)
  local ez = centre[3] + distance * cp * math.cos(yaw)
  local view = look_at(ex, ey, ez, centre[1], centre[2], centre[3])
  local proj = perspective(math.rad(45), w / h, distance * 0.01, distance + radius * 4)
  local lx, ly, lz = normalize(ex - centre[1] + radius, ey - centre[2] + 2 * radius, ez - centre[3])

  love.graphics.clear(0.13, 0.14, 0.16, 1, true, 1)
  love.graphics.setDepthMode("lequal", true)
  love.graphics.setShader(shader)
  shader:send("u_viewproj", "column", columns(mul(proj, view)))
  shader:send("u_light", { lx, ly, lz })
  for _, d in ipairs(draws) do
    shader:send("u_model", "column", d.model)
    love.graphics.setColor(d.colour)
    love.graphics.draw(d.mesh)
  end
  love.graphics.setShader()
  love.graphics.setDepthMode("always", false)
end

local function draw_2d()
  love.graphics.clear(0.97, 0.96, 0.93, 1)
  if not drawing then
    local t0 = love.timer.getTime()
    build_drawing()
    drawing.build = love.timer.getTime() - t0
    if bench then print(("drawing built in %.2f s, %d segments"):format(drawing.build, drawing.segments)); bench.frames, bench.time = 0, 0 end
  end
  if not drawing.mesh then return end
  love.graphics.setColor(0.1, 0.12, 0.2, 1)
  love.graphics.setShader(line_shader)
  line_shader:send("u_scale", pan2d.scale)
  line_shader:send("u_offset", { pan2d.x, pan2d.y })
  line_shader:send("u_half_width", 0.75)
  love.graphics.draw(drawing.mesh)
  love.graphics.setShader()
end

function love.draw()
  if scene then
    if mode == "2d" then draw_2d() else draw_3d() end
  else
    love.graphics.clear(0.13, 0.14, 0.16, 1)
  end

  local dark = mode == "2d"
  love.graphics.setColor(dark and { 0.15, 0.15, 0.2, 1 } or { 0.9, 0.9, 0.92, 1 })
  local w, h = love.graphics.getDimensions()
  if scene then
    local line = ("%s   %d nodes, %d placements, %d meshes, %d triangles   meshed %.0f ms, uploaded %.0f ms   %d fps")
      :format(model_name, stats.nodes, stats.placements, stats.meshes, stats.triangles, stats.realize * 1000,
        stats.upload * 1000, love.timer.getFPS())
    if mode == "2d" and drawing then
      line = line .. ("   %s view, %d segments"):format(drawing_view, drawing.segments)
    end
    love.graphics.print(line, 12, 10)
    if show_tree and mode == "3d" then
      love.graphics.print(table.concat(tree, "\n"), 12, 34)
    end
  end
  if message then
    love.graphics.setColor(1, 0.45, 0.4, 1)
    love.graphics.printf(message, 12, h - 60, w - 24)
  end
  love.graphics.setColor(dark and { 0.4, 0.4, 0.45, 1 } or { 0.55, 0.57, 0.62, 1 })
  love.graphics.print("drag orbit/pan   wheel zoom   tab 3D/2D   1 2 3 views   t tree   f frame   drop a file to open",
    12, h - 24)

  if shot then
    shot.frames = shot.frames + 1
    if shot.frames == 4 then
      -- No error may escape this callback: LÖVE 11.5 does not catch one raised
      -- in it and the process dies (exit 127 or 139) instead of showing it.
      love.graphics.captureScreenshot(function(image)
        local f, err = io.open(shot.path, "wb")
        if f then
          f:write(image:encode("png"):getString())
          f:close()
        else
          io.stderr:write("screenshot not written: " .. tostring(err) .. "\n")
        end
        love.event.quit(f and 0 or 1)
      end)
    end
  end
end

function love.mousemoved(x, y, dx, dy)
  if not love.mouse.isDown(1) then return end
  if mode == "2d" then
    pan2d.x, pan2d.y = pan2d.x + dx, pan2d.y + dy
  else
    yaw = yaw - dx * 0.008
    pitch = math.max(-1.5, math.min(1.5, pitch + dy * 0.008))
  end
end

function love.wheelmoved(_, dy)
  local k = 0.9 ^ dy
  if mode == "2d" then
    local mx, my = love.mouse.getPosition()
    pan2d.x = mx - (mx - pan2d.x) / k
    pan2d.y = my - (my - pan2d.y) / k
    pan2d.scale = pan2d.scale / k
  else
    distance = distance * k
  end
end

function love.keypressed(key)
  if key == "escape" then love.event.quit()
  elseif key == "tab" then mode = mode == "3d" and "2d" or "3d"
  elseif key == "t" then show_tree = not show_tree
  elseif key == "f" then
    if scene then frame() end
    drawing = nil
  elseif key == "1" or key == "2" or key == "3" then
    drawing_view = ({ "front", "top", "right" })[tonumber(key)]
    drawing = nil
    mode = "2d"
  end
end

function love.quit()
  if scene then scene:close() end
end
