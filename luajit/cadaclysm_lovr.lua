--[[
cadaclysm in LÖVR: meshes and edges as LÖVR meshes, a lit shader, a camera.

    local CL = require("cadaclysm_lovr")
    local mesh = CL.mesh(node.mesh)            -- triangles, no Lua tables between
    local lines = CL.edges(node.edges)         -- a `lines` mesh LÖVR draws natively
    local view = CL.frame(scene.bounds)        -- a desktop camera that fits the model
    function lovr.draw(pass)
      CL.camera(pass, view, yaw)               -- on the desktop; a headset brings its own
      pass:setShader(CL.shader())
      pass:draw(mesh, lovr.math.mat4(unpack(placement.raw_transform)))
    end

The scene's own arrays are copied into LÖVR Blobs through the FFI
(`Blob:getPointer`) and handed to `lovr.graphics.newMesh` / `Mesh:setIndices`.
Edges need no conversion at all: LÖVR draws `lines` meshes natively, so a
Polylines' points go over as they are and only the pair indices are built.
Works with meshes from the reader (`node.mesh`) and the blacksmith (`solid.mesh`).
]]

local ffi = require("ffi")

local M = {}

--- The vertex format `mesh` builds: position and normal.
M.FORMAT = { { "VertexPosition", "vec3" }, { "VertexNormal", "vec3" } }
--- The vertex format `edges` builds: position only.
M.LINE_FORMAT = { { "VertexPosition", "vec3" } }

local function blob(bytes)
  local b = lovr.data.newBlob(bytes)
  return b, b:getPointer()
end

--- A cadaclysm mesh as a LÖVR Mesh, or nil for an empty one.
function M.mesh(m)
  if m.is_empty or m.vertex_count == 0 then return nil end
  local n = m.vertex_count
  local vertices, vp = blob(n * 6 * 4)
  local out = ffi.cast("float *", vp)
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
  local indices, ip = blob(m.index_count * 4)
  ffi.copy(ip, m.indices, m.index_count * 4)

  local mesh = lovr.graphics.newMesh(M.FORMAT, vertices, { storage = "gpu" })
  mesh:setIndices(indices, "u32")
  return mesh
end

--- A cadaclysm Polylines as a LÖVR `lines` Mesh, or nil for an empty one. The points
--- are copied as they are; each run of n points adds n - 1 index pairs. Returns the
--- mesh and its segment count.
function M.edges(lines)
  if lines.is_empty then return nil, 0 end
  local segments = 0
  for _, count in lines:runs() do
    if count >= 2 then segments = segments + count - 1 end
  end
  if segments == 0 then return nil, 0 end

  local vertices, vp = blob(lines.vertex_count * 3 * 4)
  ffi.copy(vp, lines.positions, lines.vertex_count * 3 * 4)
  local indices, ip = blob(segments * 2 * 4)
  local ix, k = ffi.cast("uint32_t *", ip), 0
  for start, count in lines:runs() do
    for i = start, start + count - 2 do
      ix[k], ix[k + 1] = i, i + 1
      k = k + 2
    end
  end

  local mesh = lovr.graphics.newMesh(M.LINE_FORMAT, vertices, { storage = "gpu" })
  mesh:setIndices(indices, "u32")
  mesh:setDrawMode("lines")
  return mesh, segments
end

--- A blacksmith Solid's triangles at `tolerance` (default 0.05) as a LÖVR Mesh.
function M.solid(solid, tolerance)
  local positions, normals, indices = solid:mesh(tolerance)
  return M.mesh({ positions = positions.pointer, normals = normals.pointer, indices = indices.pointer,
                  vertex_count = positions.shape[1], index_count = indices.size })
end

--- A blacksmith Solid's edges at `tolerance` (default 0.05) as a LÖVR `lines` Mesh,
--- and its segment count.
function M.solid_edges(solid, tolerance)
  local runs, points, counts = solid:edge_polylines(tolerance), 0, {}
  for i, r in ipairs(runs) do
    counts[i] = r.shape[1]
    points = points + counts[i]
  end
  local flat = ffi.new("float[?]", math.max(points * 3, 1))
  local counts_c = ffi.new("uint32_t[?]", math.max(#runs, 1))
  local at = 0
  for i, r in ipairs(runs) do
    ffi.copy(flat + at * 3, r.pointer, counts[i] * 3 * 4)
    counts_c[i - 1] = counts[i]
    at = at + counts[i]
  end
  -- The same shape as a reader Polylines, so `edges` takes it as it is.
  return M.edges({
    positions = flat, counts = counts_c, polyline_count = #runs, vertex_count = points, is_empty = points == 0,
    runs = function(self)
      local i, start = -1, 0
      return function()
        i = i + 1
        if i >= self.polyline_count then return nil end
        local s, n = start, self.counts[i]
        start = start + n
        return s, n
      end
    end,
  })
end

local shader

--- A lit shader for `mesh`es: a key light from above and behind the viewer, a sky
--- term, both sides of a face lit. Built once.
function M.shader()
  shader = shader or lovr.graphics.newShader("unlit", [[
vec4 lovrmain() {
  vec3 n = normalize(Normal);
  if (!gl_FrontFacing) n = -n;
  vec3 l = normalize(CameraPositionWorld - PositionWorld + vec3(0.0, length(CameraPositionWorld - PositionWorld), 0.0));
  float key = max(dot(n, l), 0.0);
  float sky = 0.5 + 0.5 * n.y;
  return vec4(Color.rgb * (0.16 + 0.66 * key + 0.24 * sky), Color.a);
}
]])
  return shader
end

-- `lo, hi` of a reader Bounds (`min`/`max`, nil when empty) or a blacksmith
-- solid's `bounds` (`{lo, hi}`).
local function box(bounds)
  if bounds.min then
    if bounds.is_empty then return nil end
    return bounds.min, bounds.max
  end
  return bounds[1], bounds[2]
end

--- A desktop camera that fits `bounds` (a reader Bounds or a solid's
--- `bounds`, Y up): `{ centre,
--- radius, distance, pitch, fov }`. Change `distance` to zoom, `pitch` to tilt.
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

--- Point `pass` from `view` (see `frame`), orbiting at angle `yaw` about the vertical.
--- For the desktop window or an offscreen pass; a headset pass brings its own views.
function M.camera(pass, view, yaw)
  local c, d, p = view.centre, view.distance, view.pitch
  local eye = vec3(c[1] + d * math.cos(p) * math.sin(yaw), c[2] + d * math.sin(p), c[3] + d * math.cos(p) * math.cos(yaw))
  local w, h = pass:getDimensions()
  pass:setViewPose(1, lovr.math.mat4():lookAt(eye, vec3(c[1], c[2], c[3]), vec3(0, 1, 0)), true)
  -- Far plane 0: LÖVR's infinite reverse-Z, which its default depth test expects.
  pass:setProjection(1, lovr.math.mat4():perspective(view.fov, w / h, d * 0.01, 0))
end

--- Where a model of `bounds` goes in a headset: `size` metres across (default 0.4),
--- its base at `height` (default 1 m) and `ahead` metres in front (default 0.6). A
--- Mat4 to `pass:transform` before drawing the model.
function M.table_top(bounds, size, height, ahead)
  local lo, hi = box(bounds)
  lo, hi = lo or { 0, 0, 0 }, hi or { 0, 0, 0 }
  local s = { hi[1] - lo[1], hi[2] - lo[2], hi[3] - lo[3] }
  local c = { (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2, (lo[3] + hi[3]) / 2 }
  local k = (size or 0.4) / math.max(s[1], s[2], s[3], 1e-9)
  return lovr.math.newMat4():translate(0, (height or 1.0) + s[2] * k / 2, -(ahead or 0.6)):scale(k)
    :translate(-c[1], -c[2], -c[3])
end

return M
