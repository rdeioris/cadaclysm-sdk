-- A wrapper dropped without close() is freed by `ffi.gc`: every owning type, made and
-- dropped, must leave its handle collectable. LuaJIT's finalizer table is weak in its
-- keys only and has no ephemerons, so a finalizer that reaches back to its own cdata
-- (or to the table holding it) keeps both alive for good -- the leak this guards.
local ffi = require("ffi")
local bs = require("cadaclysm_blacksmith")
local cadaclysm = require("cadaclysm")

local DROPPED = 10
local IDENTITY = { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 }

local function handle_of(o) return o._ptr or o._handle end

-- Calls `make` DROPPED times, each returning a handle cdata it leaves unreachable, and
-- requires every one collected. A cdata with a finalizer is finalized in the first full
-- cycle that finds it unreachable and freed in the next; a weak-valued table loses it
-- then.
local function dropped_are_freed(t, what, make)
  local seen = setmetatable({}, { __mode = "v" })
  for i = 1, DROPPED do
    local h = make()
    t.ok(type(h) == "cdata" and h ~= nil, what .. ": make() returns its handle")
    seen[i] = h
  end
  for _ = 1, 4 do collectgarbage("collect") end
  local left = 0
  for _ in pairs(seen) do left = left + 1 end
  t.eq(left, 0, what .. ": dropped handles still reachable")
end

return function(t)
  t.test("every blacksmith owner dropped unclosed is freed", function()
    local a = bs.Solid.cuboid(2, 2, 2)
    local b = bs.Solid.cuboid(2, 2, 2):translate(1, 0, 0)
    local stock = bs.Stock.box({ 0, 0, 0 }, { 10, 10, 10 })
    local collider = bs.Collider.new({ a, b }, 0.05)
    local cases = {
      { "profile", function() return handle_of(bs.Profile.rect(1, 1)) end },
      { "path", function() return handle_of(bs.Profile.path({ 0, 0 }):line_to(1, 0)) end },
      { "sweep_path", function() return handle_of(bs.SweepPath.at({ 0, 0, 0 })) end },
      { "solid", function() return handle_of(bs.Solid.sphere(1)) end },
      { "tool", function() return handle_of(bs.Tool.flat(1, 6, 20, 800, 300, 12000)) end },
      { "stock", function() return handle_of(bs.Stock.box({ 0, 0, 0 }, { 1, 1, 1 })) end },
      { "job", function() return handle_of(bs.Job.new(stock, 20)) end },
      { "assembly", function() return handle_of(bs.Assembly.new("dropped")) end },
      { "subd", function() return handle_of(bs.Subd.cuboid()) end },
      { "nurbs_curve", function() return handle_of(bs.NurbsCurve({ { 0, 0, 0 }, { 1, 1, 0 } }, 1)) end },
      { "sketch", function() return handle_of(bs.Sketch.new()) end },
      { "collider", function() return handle_of(bs.Collider.new({ a, b }, 0.05)) end },
      { "thickness_gauge", function() return handle_of(bs.ThicknessGauge.new({ a }, 0.05)) end },
      { "collisions", function() return collider:check({ IDENTITY, IDENTITY })[1]._collisions end },
      { "fem_mesh", function() return handle_of(a:fem_mesh(0.5)) end },
      { "tessellation", function() return (a:mesh(0.5))._held._ptr end },
      { "document", function() return handle_of(bs.Document.new()) end },
    }
    for _, case in ipairs(cases) do dropped_are_freed(t, case[1], case[2]) end
    collider:close()
  end)

  t.test("every reader owner dropped unclosed is freed", function()
    local step = t.tmp("cube.stp")
    bs.write_step(step, { bs.Solid.cuboid(2, 2, 2) })
    local scene = cadaclysm.open(step)
    local solid
    for _, n in ipairs(scene.nodes) do
      if n.brep ~= nil then solid = n break end
    end
    t.ok(solid ~= nil, "the written cube has a node with a brep")
    local cases = {
      { "scene", function() return handle_of(cadaclysm.open(step)) end },
      { "brep", function() return handle_of(solid.brep) end },
      { "meshlets", function()
        return handle_of(cadaclysm.Meshlets.build({ 0, 0, 0, 1, 0, 0, 0, 1, 0 }, nil, { 0, 1, 2 }, 3, 3, 128, 256))
      end },
      { "fem_mesh", function() return handle_of(solid:fem_mesh(0.5)) end },
    }
    for _, case in ipairs(cases) do dropped_are_freed(t, case[1], case[2]) end
    scene:close()
  end)
end
