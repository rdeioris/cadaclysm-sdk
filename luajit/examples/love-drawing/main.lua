-- A drawing sheet from a CAD file, in LÖVE: three views (ISO first angle), the
-- overall sizes in millimetres and a title block. `love love-drawing part.step`,
-- or drop a file on the window.
-- The wrapper sits two folders up here; in your own game, keep its files beside
-- main.lua and leave this line out.
package.path = love.filesystem.getSource() .. "/../../?.lua;" .. package.path
local cadaclysm = require("cadaclysm")
local CL = require("cadaclysm_love")

local INK, PAPER = { 0.11, 0.105, 0.10 }, { 0.955, 0.945, 0.915 }
local sheet

local function open(path)
  local scene = cadaclysm.open(path, nil, "y-up")   -- metres, Y up
  sheet = {
    name = path:gsub("\\", "/"):match("[^/]*$"),
    size = scene.bounds.size,                       -- {x, y, z} in metres
    front = CL.drawing(scene, "front"),             -- every edge, seen from the front
    top = CL.drawing(scene, "top"),
    left = CL.drawing(scene, "left"),
  }
  scene:close()
end

function love.load(args)
  love.graphics.setFont(love.graphics.newFont(15))
  open(args[1] or "part.step")
end
function love.filedropped(file) open(file:getFilename()) end

local function width(d) return d.hi[1] - d.lo[1] end
local function height(d) return d.hi[2] - d.lo[2] end

-- A dimension: a line with end ticks from (x1, y1) to (x2, y2), its text beside it.
local function dimension(x1, y1, x2, y2, metres)
  local vertical = x1 == x2
  local tx, ty = vertical and 6 or 0, vertical and 0 or 6
  love.graphics.line(x1, y1, x2, y2)
  love.graphics.line(x1 - tx, y1 - ty, x1 + tx, y1 + ty)
  love.graphics.line(x2 - tx, y2 - ty, x2 + tx, y2 + ty)
  local label = ("%.1f"):format(metres * 1000)
  local font = love.graphics.getFont()
  local w, h = font:getWidth(label), font:getHeight()
  if vertical then
    love.graphics.print(label, x1 - h - 4, (y1 + y2 + w) / 2, -math.pi / 2)   -- read from the right
  else
    love.graphics.print(label, (x1 + x2 - w) / 2, y1 - h - 4)
  end
end

function love.draw()
  local W, H = love.graphics.getDimensions()
  love.graphics.clear(PAPER)
  love.graphics.setColor(INK)
  love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", 24, 24, W - 48, H - 48)          -- the border
  local f, t, l = sheet.front, sheet.top, sheet.left
  if not f.mesh then return end

  -- One scale for all three views, the front view top left, the view from the left
  -- to its right and the view from above below it: ISO first angle.
  local gap = 0.18 * math.max(width(f), height(f))
  local s = math.min((W - 200) / (width(f) + gap + width(l)), (H - 260) / (height(f) + gap + height(t)))
  local x0 = 96 + (W - 200 - s * (width(f) + gap + width(l))) / 2
  local y0 = 88
  local fx, fy = x0 - f.lo[1] * s, y0 - f.lo[2] * s
  CL.draw_lines(f, fx, fy, s, 1.6)
  CL.draw_lines(l, x0 + (width(f) + gap) * s - l.lo[1] * s, fy, s, 1.6)
  CL.draw_lines(t, fx, y0 + (height(f) + gap) * s - t.lo[2] * s, s, 1.6)

  love.graphics.setLineWidth(1)
  dimension(x0, y0 - 28, x0 + width(f) * s, y0 - 28, sheet.size[1])                    -- width
  dimension(x0 - 32, y0, x0 - 32, y0 + height(f) * s, sheet.size[2])                    -- height
  local lx = x0 + (width(f) + gap) * s
  dimension(lx, y0 - 28, lx + width(l) * s, y0 - 28, sheet.size[3])                     -- depth

  -- The title block.
  local bw, bh = 380, 112
  local bx, by = W - 24 - bw, H - 24 - bh
  love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", bx, by, bw, bh)
  love.graphics.line(bx, by + 38, bx + bw, by + 38)
  love.graphics.line(bx, by + 75, bx + bw, by + 75)
  love.graphics.print(sheet.name, bx + 12, by + 10)
  love.graphics.print(("%.1f x %.1f x %.1f mm"):format(sheet.size[1] * 1000, sheet.size[2] * 1000,
    sheet.size[3] * 1000), bx + 12, by + 47)
  love.graphics.print("ISO first angle  ·  cadaclysm + LÖVE", bx + 12, by + 84)
end
