--[[
cadaclysm in LÖVE: meshes as LÖVE meshes, a lit 3D pass, and 2D line work.

    local CL = require("cadaclysm_love")
    local mesh = CL.mesh(node.mesh)             -- a LÖVE Mesh, no Lua tables between
    local view = CL.frame(scene.bounds)         -- a camera that fits the model
    CL.begin3d(view, yaw)                       -- depth test on, lit shader on
    CL.draw(mesh, placement.raw_transform, colour)
    CL.end3d()                                  -- back to plain 2D

The scene's own float and uint32 arrays are copied straight into LÖVE ByteData
through the FFI (`getFFIPointer`) and handed to `Mesh:setVertices` /
`Mesh:setVertexMap`. A Lua table per vertex -- what `love.graphics.newMesh(format,
{{...}, ...})` wants -- would cost more than reading the file did on anything the
size of a real assembly.

LÖVE has no line meshes, and one `love.graphics.line` per polyline is far too slow
for a real drawing, so `line_mesh` bakes every segment of every run into one mesh
of quads that `LINE_SHADER` widens to a fixed width in pixels: one draw call.

3D needs a depth buffer: `t.window.depth = 24` in conf.lua. LÖVE 11.3 or newer.
Works with meshes from the reader (`node.mesh`) and from the blacksmith
(`solid.mesh`) alike: both carry `positions`, `normals`, `indices` and counts.
]]

local ffi = require("ffi")

local M = {}

-- ---- meshes ---------------------------------------------------------------------------

--- The vertex format `mesh` builds: position and normal, three floats each.
M.FORMAT = {
  { "VertexPosition", "float", 3 },
  { "VertexNormal", "float", 3 },
}

--- A cadaclysm mesh as a LÖVE Mesh, or nil for an empty one.
function M.mesh(m)
  if m.is_empty or m.vertex_count == 0 then return nil end
  local n = m.vertex_count
  local vertices = love.data.newByteData(n * 6 * 4)
  local out = ffi.cast("float *", vertices:getFFIPointer())
  local p, nrm = m.positions, m.normals
  for i = 0, n - 1 do
    local o, s = 6 * i, 3 * i
    out[o], out[o + 1], out[o + 2] = p[s], p[s + 1], p[s + 2]
    if nrm ~= nil then
      out[o + 3], out[o + 4], out[o + 5] = nrm[s], nrm[s + 1], nrm[s + 2]
    else
      out[o + 3], out[o + 4], out[o + 5] = 0, 0, 1
    end
  end
  -- The indices go over as they are: uint32, from zero, is what setVertexMap takes.
  local indices = love.data.newByteData(m.index_count * 4)
  ffi.copy(indices:getFFIPointer(), m.indices, m.index_count * 4)

  local mesh = love.graphics.newMesh(M.FORMAT, n, "triangles", "static")
  mesh:setVertices(vertices)
  mesh:setVertexMap(indices, "uint32")
  return mesh
end

--- A blacksmith Solid's triangles at `tolerance` (default 0.05) as a LÖVE Mesh.
function M.solid(solid, tolerance)
  local positions, normals, indices = solid:mesh(tolerance)
  return M.mesh({ positions = positions.pointer, normals = normals.pointer, indices = indices.pointer,
                  vertex_count = positions.shape[1], index_count = indices.size })
end

-- ---- column-major 4x4s, as the ABI's `raw_transform` hands them over -----------------

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
M.mul = mul

local function normalize(x, y, z)
  local l = math.sqrt(x * x + y * y + z * z)
  return x / l, y / l, z / l
end

local function perspective(fovy, aspect, near, far)
  local f = 1 / math.tan(fovy / 2)
  return { f / aspect, 0, 0, 0, 0, f, 0, 0, 0, 0, (far + near) / (near - far), -1,
           0, 0, 2 * far * near / (near - far), 0 }
end

-- A view matrix looking from e at t, Y up.
local function look_at(ex, ey, ez, tx, ty, tz)
  local fx, fy, fz = normalize(tx - ex, ty - ey, tz - ez)
  local sx, sy, sz = normalize(-fz, 0, fx) -- f x (0, 1, 0)
  local ux, uy, uz = sy * fz - sz * fy, sz * fx - sx * fz, sx * fy - sy * fx
  return { sx, ux, -fx, 0, sy, uy, -fy, 0, sz, uz, -fz, 0,
           -(sx * ex + sy * ey + sz * ez), -(ux * ex + uy * ey + uz * ez), fx * ex + fy * ey + fz * ez, 1 }
end

local function columns(m)
  return { { m[1], m[2], m[3], m[4] }, { m[5], m[6], m[7], m[8] },
           { m[9], m[10], m[11], m[12] }, { m[13], m[14], m[15], m[16] } }
end

-- ---- a lit 3D pass --------------------------------------------------------------------

--- The shader `begin3d` sets: a key light from over the camera's shoulder, a sky
--- term, both sides of a face lit.
M.SHADER = [[
varying vec3 v_normal;
#ifdef VERTEX
attribute vec3 VertexNormal;
uniform mat4 u_viewproj;
uniform mat4 u_model;
vec4 position(mat4 transform_projection, vec4 vertex_position) {
  v_normal = mat3(u_model) * VertexNormal;
  vec4 p = u_viewproj * u_model * vertex_position;
  // LÖVE flips its projection when drawing into a Canvas (its y scale turns
  // positive); this projection is our own, so it has to follow suit or the
  // picture lands upside down in the canvas.
  if (transform_projection[1][1] > 0.0) p.y = -p.y;
  return p;
}
#endif
#ifdef PIXEL
uniform vec3 u_light;
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen) {
  vec3 n = normalize(v_normal);
  if (!gl_FrontFacing) n = -n;
  float key = max(dot(n, u_light), 0.0);
  float sky = 0.5 + 0.5 * n.y;
  return vec4(color.rgb * (0.16 + 0.66 * key + 0.24 * sky), color.a);
}
#endif
]]

local shader

-- `lo, hi` of a reader Bounds (`min`/`max`, nil when empty) or a blacksmith
-- solid's `bounds` (`{lo, hi}`).
local function box(bounds)
  if bounds.min then
    if bounds.is_empty then return nil end
    return bounds.min, bounds.max
  end
  return bounds[1], bounds[2]
end

--- A camera that fits `bounds` (a reader Bounds or a solid's
--- `bounds`, Y up): `{ centre, radius,
--- distance, pitch, fov }`. Change `distance` to zoom, `pitch` to tilt.
function M.frame(bounds, fov)
  fov = fov or math.rad(40)
  local centre, radius = { 0, 0, 0 }, 1
  local lo, hi = box(bounds)
  if lo then
    local s = { hi[1] - lo[1], hi[2] - lo[2], hi[3] - lo[3] }
    centre = { (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2, (lo[3] + hi[3]) / 2 }
    radius = math.max(0.5 * math.sqrt(s[1] * s[1] + s[2] * s[2] + s[3] * s[3]), 1e-9)
  end
  return { centre = centre, radius = radius, distance = radius / math.sin(fov / 2) * 1.05, pitch = 0.45, fov = fov }
end

--- Start drawing in 3D from `view` (see `frame`), orbiting at angle `yaw` (radians)
--- about the vertical: depth test on, the lit shader on. Draw with `draw`; end with
--- `end3d`. The picture fills the current canvas, or the window.
function M.begin3d(view, yaw)
  local w, h = love.graphics.getDimensions()
  local c, d, p = view.centre, view.distance, view.pitch
  local ex = c[1] + d * math.cos(p) * math.sin(yaw)
  local ey = c[2] + d * math.sin(p)
  local ez = c[3] + d * math.cos(p) * math.cos(yaw)
  local camera = look_at(ex, ey, ez, c[1], c[2], c[3])
  local project = perspective(view.fov, w / h, d * 0.02, d + view.radius * 4)
  local lx, ly, lz = normalize(ex - c[1] + view.radius, ey - c[2] + 2 * view.radius, ez - c[3])

  shader = shader or love.graphics.newShader(M.SHADER)
  -- The canvas flip is read off LÖVE's transform, so start that from the origin.
  love.graphics.push("all")
  love.graphics.origin()
  love.graphics.setDepthMode("lequal", true)
  love.graphics.setShader(shader)
  shader:send("u_viewproj", "column", columns(mul(project, camera)))
  shader:send("u_light", { lx, ly, lz })
end

--- Draw a LÖVE mesh placed by `transform` (16 numbers, column-major -- a
--- placement's `raw_transform`; nil for none) in `colour` (`{r, g, b[, a]}`).
function M.draw(mesh, transform, colour)
  if not mesh then return end
  shader:send("u_model", "column", columns(transform or { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }))
  love.graphics.setColor(colour or { 0.75, 0.76, 0.78, 1 })
  love.graphics.draw(mesh)
end

--- Back to LÖVE's own 2D drawing.
function M.end3d()
  love.graphics.pop()
end

-- A column-major 4x4 applied to a point.
local function apply(t, x, y, z)
  return t[1] * x + t[5] * y + t[9] * z + t[13],
         t[2] * x + t[6] * y + t[10] * z + t[14],
         t[3] * x + t[7] * y + t[11] * z + t[15]
end
M.apply = apply

-- ---- 2D line work as one mesh ---------------------------------------------------------

--- The vertex format `line_mesh` builds: this end, the other end, which side.
M.LINE_FORMAT = {
  { "VertexPosition", "float", 2 },
  { "a_other", "float", 2 },
  { "a_side", "float", 1 },
}

--- Draws a `line_mesh`: every segment a quad pushed sideways by half the line width
--- in pixels, so the width holds at any zoom.
M.LINE_SHADER = [[
#ifdef VERTEX
attribute vec2 a_other;
attribute float a_side;
uniform float u_scale;
uniform vec2 u_offset;
uniform float u_half_width;
vec4 position(mat4 transform_projection, vec4 vertex_position) {
  vec2 p = vertex_position.xy * u_scale + u_offset;
  vec2 d = a_other * u_scale + u_offset - p;
  float l = length(d);
  vec2 n = l > 0.0 ? vec2(-d.y, d.x) / l : vec2(0.0, 1.0);
  return transform_projection * vec4(p + n * a_side * u_half_width, 0.0, 1.0);
}
#endif
]]

--- The projections `line_mesh` and `drawing` take: (x, y, z) -> (u, v), v down the
--- screen, for a model read Y up.
M.VIEWS = {
  front = function(x, y, z) return x, -y end,
  top = function(x, y, z) return x, z end,
  right = function(x, y, z) return -z, -y end,
  left = function(x, y, z) return z, -y end,
}

--- Every run of every `{polylines, transform}` in `sources`, carried through its
--- transform (16 numbers, column-major) and flattened by `project` (x, y, z -> u, v),
--- as one LÖVE mesh. Returns the mesh (nil when there is nothing), the segment count,
--- and the bounds `lo_u, lo_v, hi_u, hi_v` of what it draws.
function M.line_mesh(sources, project)
  local segments = 0
  for _, s in ipairs(sources) do
    if not s[1].is_empty then
      for _, count in s[1]:runs() do
        if count >= 2 then segments = segments + count - 1 end
      end
    end
  end
  if segments == 0 then return nil, 0 end

  local vertices = love.data.newByteData(segments * 4 * 5 * 4)
  local v = ffi.cast("float *", vertices:getFFIPointer())
  local indices = love.data.newByteData(segments * 6 * 4)
  local ix = ffi.cast("uint32_t *", indices:getFFIPointer())
  local lo_u, lo_v, hi_u, hi_v = math.huge, math.huge, -math.huge, -math.huge
  local function grow(u, w)
    if u < lo_u then lo_u = u end
    if u > hi_u then hi_u = u end
    if w < lo_v then lo_v = w end
    if w > hi_v then hi_v = w end
  end

  local seg = 0
  for _, s in ipairs(sources) do
    local lines, t = s[1], s[2]
    if not lines.is_empty then
      local p = lines.positions
      for start, count in lines:runs() do
        if count >= 2 then
          local au, av = project(apply(t, p[3 * start], p[3 * start + 1], p[3 * start + 2]))
          grow(au, av)
          for i = start + 1, start + count - 1 do
            local bu, bv = project(apply(t, p[3 * i], p[3 * i + 1], p[3 * i + 2]))
            grow(bu, bv)
            -- A+, A-, then B's two with the side flipped: B's "other" is A, so its
            -- normal points the opposite way and the flip keeps the quad whole.
            local o = seg * 20
            v[o], v[o + 1], v[o + 2], v[o + 3], v[o + 4] = au, av, bu, bv, 1
            v[o + 5], v[o + 6], v[o + 7], v[o + 8], v[o + 9] = au, av, bu, bv, -1
            v[o + 10], v[o + 11], v[o + 12], v[o + 13], v[o + 14] = bu, bv, au, av, -1
            v[o + 15], v[o + 16], v[o + 17], v[o + 18], v[o + 19] = bu, bv, au, av, 1
            local b, k = seg * 4, seg * 6
            ix[k], ix[k + 1], ix[k + 2], ix[k + 3], ix[k + 4], ix[k + 5] = b, b + 1, b + 2, b + 1, b + 3, b + 2
            seg = seg + 1
            au, av = bu, bv
          end
        end
      end
    end
  end

  local mesh = love.graphics.newMesh(M.LINE_FORMAT, segments * 4, "triangles", "static")
  mesh:setVertices(vertices)
  mesh:setVertexMap(indices, "uint32")
  return mesh, segments, lo_u, lo_v, hi_u, hi_v
end

--- A scene's edges and free curves seen from `view` ("front", "top", "right",
--- "left", or a projection function) as a drawing: `{ mesh, segments, lo = {u, v},
--- hi = {u, v} }`. Draw it with `draw_lines`.
function M.drawing(scene, view)
  local sources = {}
  for _, p in ipairs(scene.placements) do
    local g, t = p.geometry, p.raw_transform
    sources[#sources + 1] = { g.edges, t }
    sources[#sources + 1] = { g.curves, t }
  end
  local mesh, segments, lo_u, lo_v, hi_u, hi_v = M.line_mesh(sources, type(view) == "function" and view or M.VIEWS[view])
  return { mesh = mesh, segments = segments, lo = { lo_u or 0, lo_v or 0 }, hi = { hi_u or 0, hi_v or 0 } }
end

local line_shader

--- Draw a `drawing` at `scale` pixels per unit with its (u, v) origin at pixel
--- (x, y), in the current colour, `width` pixels wide (default 1.5).
function M.draw_lines(drawing, x, y, scale, width)
  if not drawing.mesh then return end
  line_shader = line_shader or love.graphics.newShader(M.LINE_SHADER)
  love.graphics.setShader(line_shader)
  line_shader:send("u_scale", scale)
  line_shader:send("u_offset", { x, y })
  line_shader:send("u_half_width", (width or 1.5) / 2)
  love.graphics.draw(drawing.mesh)
  love.graphics.setShader()
end

return M
