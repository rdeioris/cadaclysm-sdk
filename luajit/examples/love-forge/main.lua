-- A parametric flange, built by the blacksmith kernel while you watch, in LÖVE:
-- `love love-forge`. Up and down change the bolt holes, left and right the boss;
-- S writes the exact solid to flange.stp.
-- The wrapper sits two folders up here; in your own game, keep its files beside
-- main.lua and leave this line out.
package.path = love.filesystem.getSource() .. "/../../?.lua;" .. package.path
local bs = require("cadaclysm_blacksmith")
local CL = require("cadaclysm_love")
local Profile, Solid, Frame = bs.Profile, bs.Solid, bs.Frame

local holes, boss = 6, 14                 -- the two parameters, in millimetres
local part, mesh, view, took, angle

local function flange()
  -- A disc with a ring of bolt holes: one outline, extruded once.
  local outline = Profile.circle(40)
  for i = 0, holes - 1 do
    local a = 2 * math.pi * i / holes
    outline = outline:with_hole(Profile.circle(4):translate(30 * math.cos(a), 30 * math.sin(a)))
  end
  local disc = Solid.extrude(outline, Frame.xy(), 8)
  -- A boss on top, and a bore through both.
  local body = disc:join(Solid.cylinder(16, boss):translate(0, 0, 8))
    :cut(Solid.cylinder(9, boss + 40):translate(0, 0, -20))
  -- Round the circle where the boss meets the disc: the one curved edge at z = 8, r = 16.
  local joint = {}
  for _, edge in ipairs(body.edges) do
    local p = edge.segments[1][1]
    if not edge.is_line and math.abs(p[3] - 8) < 1e-6 and math.abs(math.sqrt(p[1] ^ 2 + p[2] ^ 2) - 16) < 1e-6 then
      joint[#joint + 1] = edge
    end
  end
  return body:fillet(joint, 3)
end

local function rebuild()
  local start = love.timer.getTime()
  if part then part:close() end
  part = flange()
  took = love.timer.getTime() - start
  local upright = part:rotate({ { 0, 0, 0 }, { 1, 0, 0 } }, -math.pi / 2)   -- Z up to Y up
  mesh = CL.solid(upright, 0.02)
  view = view or CL.frame(upright.bounds)
  upright:close()
end

function love.load()
  love.graphics.setFont(love.graphics.newFont(16))
  angle = 0.6
  rebuild()
end

function love.update(dt) angle = angle + dt * 0.4 end

function love.keypressed(key)
  if key == "up" then holes = math.min(holes + 1, 16)
  elseif key == "down" then holes = math.max(holes - 1, 3)
  elseif key == "right" then boss = math.min(boss + 2, 40)
  elseif key == "left" then boss = math.max(boss - 2, 4)
  elseif key == "s" then part:step("flange.stp") return
  else return end
  rebuild()
end

function love.draw()
  love.graphics.clear(0.11, 0.105, 0.10)
  CL.begin3d(view, angle)
  CL.draw(mesh, nil, { 0.74, 0.70, 0.64 })
  CL.end3d()
  love.graphics.setColor(0.94, 0.93, 0.91)
  love.graphics.print(("%d holes, a %d mm boss: %d faces, built in %.0f ms"):format(holes, boss, part.faces,
    took * 1000), 24, 20)
  love.graphics.setColor(0.6, 0.59, 0.56)
  love.graphics.print("up/down holes   left/right boss   S writes flange.stp", 24, 46)
end
