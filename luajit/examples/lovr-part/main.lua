-- A CAD part with its edges, in LÖVR: `lovr lovr-part part.step`. In a headset (or
-- LÖVR's desktop simulator) it stands on a table in front of you; with the headset
-- module off in conf.lua, the window orbits it.
-- The wrapper sits two folders up here; in your own project, keep its files beside
-- main.lua and leave this line out.
package.path = lovr.filesystem.getSource() .. "/../../?.lua;" .. package.path
local cadaclysm = require("cadaclysm")
local CL = require("cadaclysm_lovr")

local parts, view, table_top, angle = {}, nil, nil, 0.6

function lovr.load(args)
  local scene = cadaclysm.open(args[1] or "part.step", nil, "y-up")   -- metres, Y up
  for _, placement in ipairs(scene.placements) do
    local body = placement.geometry
    parts[#parts + 1] = {
      mesh = CL.mesh(body.mesh),                         -- the faces
      edges = CL.edges(body.edges),                      -- the edges, as LÖVR lines
      place = lovr.math.newMat4(unpack(placement.raw_transform)),
      colour = body.colour or { 0.72, 0.70, 0.66 },
    }
  end
  view, table_top = CL.frame(scene.bounds), CL.table_top(scene.bounds)
  scene:close()
  lovr.graphics.setBackgroundColor(0.11, 0.105, 0.10)
end

function lovr.update(dt) angle = angle + dt * 0.4 end

function lovr.draw(pass)
  if lovr.headset then pass:transform(table_top) else CL.camera(pass, view, angle) end
  pass:setShader(CL.shader())
  pass:setDepthOffset(-2, -2)             -- faces a hair back, so the edges on them show
  for _, part in ipairs(parts) do
    pass:setColor(part.colour)
    pass:draw(part.mesh, part.place)
  end
  pass:setShader()
  pass:setDepthOffset(0, 0)
  pass:setColor(0.07, 0.07, 0.08)
  for _, part in ipairs(parts) do
    if part.edges then pass:draw(part.edges, part.place) end
  end
end
