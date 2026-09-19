-- A CAD part turning on its stand, in LÖVE: `love love-part part.step`,
-- or drop a STEP, IGES, SAT, 3DM, BREP or IFC file on the window.
-- The wrapper sits two folders up here; in your own game, keep its files beside
-- main.lua and leave this line out.
package.path = love.filesystem.getSource() .. "/../../?.lua;" .. package.path
local cadaclysm = require("cadaclysm")
local CL = require("cadaclysm_love")

local parts, view, angle = {}, nil, 0.6

local function open(path)
  local scene = cadaclysm.open(path, nil, "y-up")   -- metres, Y up
  parts = {}
  for _, placement in ipairs(scene.placements) do  -- every drawing of every body
    local body = placement.geometry
    parts[#parts + 1] = {
      mesh = CL.mesh(body.mesh),                    -- the triangles, copied once
      place = placement.raw_transform,              -- where this copy sits
      colour = body.colour or { 0.72, 0.70, 0.66 }, -- the file's own paint
    }
  end
  view = CL.frame(scene.bounds)
  scene:close()                                     -- the LÖVE meshes are ours now
end

function love.load(args) open(args[1] or "part.step") end
function love.filedropped(file) open(file:getFilename()) end
function love.update(dt) angle = angle + dt * 0.4 end

function love.draw()
  love.graphics.clear(0.11, 0.105, 0.10)
  CL.begin3d(view, angle)
  for _, part in ipairs(parts) do CL.draw(part.mesh, part.place, part.colour) end
  CL.end3d()
end
