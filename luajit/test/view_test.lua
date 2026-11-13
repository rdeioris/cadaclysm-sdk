-- The view over a real library, offscreen: a solid by handle, pixels inside its silhouette,
-- an item removed, a closed view refused; a scene, a node and a pose by handle; the argument
-- checks and the pump with a library of fakes. Without the wgpu library or an adapter a case
-- says "skip" and returns -- unless CADACLYSM_REQUIRE_WGPU=1, where that is a failure (as is
-- a missing sample, so a case never passes having checked nothing).
local bs = require("cadaclysm_blacksmith")
local view = require("cadaclysm_view")
local ffi = require("ffi")

local required = os.getenv("CADACLYSM_REQUIRE_WGPU") == "1"

local function offscreen(w, h, opts)
  local ok, err = pcall(view.use_wgpu)
  if not ok then
    if required then error(err, 0) end
    print("  skip: " .. tostring(err):match("^[^\n]*"))
    return nil
  end
  local made, v = pcall(view.View.offscreen, w, h, opts)
  if not made then
    if not required and tostring(v):find("adapter") then print("  skip: " .. tostring(v)) return nil end
    error(v, 0)
  end
  return v
end

local function pixel(img, x, y)
  local i = (y * img.width + x) * 4
  return img.rgba[i], img.rgba[i + 1], img.rgba[i + 2], img.rgba[i + 3]
end

local function same(a, b, x, y)
  local r1, g1, b1, a1 = pixel(a, x, y)
  local r2, g2, b2, a2 = pixel(b, x, y)
  return r1 == r2 and g1 == g2 and b1 == b2 and a1 == a2
end

-- How many pixels of `a` differ from `b` (same size).
local function changed(a, b)
  local n = 0
  for i = 0, a.width * a.height * 4 - 4, 4 do
    if a.rgba[i] ~= b.rgba[i] or a.rgba[i + 1] ~= b.rgba[i + 1] or a.rgba[i + 2] ~= b.rgba[i + 2] then n = n + 1 end
  end
  return n
end

local function is_view_error(err) return getmetatable(err) == view.ViewError end

-- A view library of fakes: every call is recorded; `state.error` is what last_error answers and
-- `state.pump` what pump answers (1 open, 2 closed, anything else a failure).
local function fake(state)
  state.calls, state.waits, state.pick = {}, {}, {}
  local keep, next_id = {}, 0
  local function text(s)
    local c = ffi.new("char[?]", #s + 1, s)
    keep[#keep + 1] = c
    return ffi.cast("const char *", c)
  end
  local function rec(name, answer)
    return function(...)
      state.calls[#state.calls + 1] = name
      if type(answer) == "function" then return answer(...) end
      return answer
    end
  end
  local C = {
    cadaclysm_view_last_error = function() return text(state.error or "") end,
    cadaclysm_view_name = function() return text("cadaclysm-view fake") end,
    cadaclysm_view_create = rec("create", function() next_id = next_id + 1 return ffi.cast("void *", next_id * 16) end),
    cadaclysm_view_destroy = rec("destroy"),
    cadaclysm_view_pump = rec("pump", function(_, ms) state.waits[#state.waits + 1] = ms return state.pump or 1 end),
    cadaclysm_view_draw = rec("draw", true),
    cadaclysm_view_request_pick = rec("request_pick", function(_, x, y) state.pick[#state.pick + 1] = { "request_pick", x, y } end),
    cadaclysm_view_request_pick_in = rec("request_pick_in", function(_, v, x, y) state.pick[#state.pick + 1] = { "request_pick_in", v, x, y } end),
    cadaclysm_view_pick_result = rec("pick_result", function(_, out) out.item, out.node, out.face = 7, 1, 2 return true end),
  }
  return { C = C, name = "cadaclysm-view fake" }
end

-- Runs `fn` with View.new replaced by an offscreen view whose run() answers at once, handing
-- back what it saw: the options, the title, and the frame at the moment the window would open.
local function capture(fn)
  local original = view.View.new
  local seen = { runs = 0 }
  view.View.new = function(opts)
    seen.opts = opts
    local v = view.View.offscreen(opts.width > 0 and opts.width or 96, opts.height > 0 and opts.height or 96,
      { title = opts.title, up = opts.up })
    seen.view = v
    v.run = function(self)
      seen.runs = seen.runs + 1
      seen.image = self:image()
      return { stand_in = true }
    end
    return v
  end
  local ok, err = pcall(fn, seen)
  view.View.new = original
  if not ok then error(err, 0) end
  return seen
end

-- A leaf below a root with geometry, in a real assembly: a case that finds none fails.
local function nested_leaf(t, scene)
  local leaf
  for node in scene:walk() do
    if node.parent ~= nil and #node.children == 0 and node.can_mesh then leaf = leaf or node end
  end
  t.ok(leaf, "mechanism-solid.stp has no leaf below a root with geometry: the node cases would prove nothing")
  return leaf
end

return function(t)
  t.test("a missing view library is worded as Python words it", function()
    local function file(b)
      if ffi.os == "Windows" then return b .. ".dll" end
      return ffi.os == "OSX" and ("lib" .. b .. ".dylib") or ("lib" .. b .. ".so")
    end
    local function words(...)
      local ok, err = pcall(view._find, ...)
      t.ok(not ok, "found a library: " .. tostring(err))
      t.ok(is_view_error(err), "not a ViewError: " .. tostring(err))
      return err.message
    end
    local empty = t.tmp("view-missing-library")
    local windows = package.config:sub(1, 1) == "\\"
    os.execute((windows and 'mkdir "%s"' or 'mkdir -p "%s"'):format(windows and empty:gsub("/", "\\") or empty))
    local nowhere = empty .. "/nowhere"
    t.eq(words("cadaclysm_view", "CADACLYSM_VIEW_LIBRARY", nowhere, empty),
      "CADACLYSM_VIEW_LIBRARY=" .. nowhere .. " names nothing that exists")
    t.eq(words("cadaclysm_terminal", "CADACLYSM_TERMINAL_LIBRARY", nowhere, empty),
      "CADACLYSM_TERMINAL_LIBRARY=" .. nowhere .. " names nothing that exists")
    t.eq(words("cadaclysm_terminal", "CADACLYSM_TERMINAL_LIBRARY", empty, empty),
      "CADACLYSM_TERMINAL_LIBRARY=" .. empty .. " names nothing that exists (no "
        .. file("cadaclysm_terminal") .. " in that directory)")
    for _, c in ipairs({
      { "cadaclysm_terminal", "CADACLYSM_TERMINAL_LIBRARY", "no view library: the terminal library was not found (searched: ",
        ") -- reinstall cadaclysm, set CADACLYSM_TERMINAL_LIBRARY to the library, or set CADACLYSM_VIEW" },
      { "cadaclysm_view", "CADACLYSM_VIEW_LIBRARY", "no view library: " .. file("cadaclysm_view") .. " was not found (searched: ",
        ") -- reinstall cadaclysm, set CADACLYSM_VIEW_LIBRARY to it, or use_terminal()" },
    }) do
      local got = words(c[1], c[2], "", empty)
      local head = c[3] .. empty .. "/" .. file(c[1]) .. ", " .. empty .. "/lib/" .. file(c[1]) .. ", "
      t.eq(got:sub(1, #head), head, "the search's start")
      t.eq(got:sub(-#c[4]), c[4], "the search's advice")
      t.ok(not got:find("\n", 1, true), "one line: " .. got)
    end
    os.remove(empty)
  end)

  t.test("an offscreen view draws a solid by handle, removes it, and refuses once closed", function()
    local v = offscreen(160, 120)
    if not v then return end
    -- Off: the grid lies across the empty view's centre and moves with the camera, so the centre
    -- and corner compare the cube against the background alone.
    v:layer("grid", false)
    local empty = v:image()
    t.eq(empty.width * empty.height * 4, 160 * 120 * 4, "image size")
    local solid = bs.Solid.cuboid(20, 20, 20)
    local item = v:show_solid(solid, 0.05, { 0.9, 0.2, 0.1 })
    t.ok(item.id > 0, "item id")
    t.ok(item.shown == solid, "the item holds the solid it shows")
    solid = nil
    collectgarbage()
    collectgarbage()
    v:standard("iso")
    v:frame()
    local drawn = v:image()
    t.ok(not same(drawn, empty, 80, 60), "the centre pixel is still the background")
    t.ok(same(drawn, empty, 0, 0), "a corner outside the cube changed")
    item:remove()
    t.ok(same(v:image(), empty, 80, 60), "a removed item still draws")
    -- Two points on the real library: an item.
    local points = v:show_points({ 0, 0, 0, 1, 1, 1 }, "red")
    t.ok(points.id > 0, "two points: no item")
    points:remove()
    v:close()
    t.raises(function() v:draw() end, "closed")
    t.raises(function() item:colour({ 1, 0, 0 }) end, "closed")
  end)

  t.test("pick on a never-drawn view, size, lod and wake_ms answer as Python does", function()
    local v = offscreen(96, 96)
    if not v then return end
    local cube = v:show_solid(bs.Solid.cuboid(20, 20, 20))
    v:standard("front")
    v:frame()
    local hit = v:pick(48, 48)   -- no draw() before: pick must draw first
    t.ok(hit and hit.item == cube.id, "pick on a never-drawn view missed the cube")
    t.eq(v:pick(1, 1), nil, "a corner picked something")
    -- 1.16's user layers: the cube on layer 3, the layer off (nothing to pick) and on again;
    -- layer 32 refused, for an item and for the view.
    cube:user_layer(3)
    v:user_layer(3, false)
    t.eq(v:pick(48, 48), nil, "an item on a layer switched off was picked")
    v:user_layer(3, true)
    local back = v:pick(48, 48)
    t.ok(back and back.item == cube.id, "an item on a layer switched on again was not picked")
    t.raises(function() cube:user_layer(32) end, "past 31")
    t.raises(function() v:user_layer(32, false) end, "past 31")
    local w, h = v:size()
    t.eq(w * 1000 + h, 96096, "size")
    v:lod("smooth")
    local wake = v:wake_ms()
    t.ok(wake == nil or wake >= 0, "wake_ms")
    v:lod(false)
    v:close()
  end)

  t.test("closing a scene releases its items; a node shows its path with the siblings hidden", function()
    local cad = require("cadaclysm")
    local file = t.fixture("samples/mechanism-solid.stp")
    if not file then return end
    local v = offscreen(96, 96)
    if not v then return end
    local scene = cad.open(file)
    local item = v:show_scene(scene)
    v:standard("iso")
    v:frame()
    local whole = v:image()
    local leaf = nested_leaf(t, scene)
    -- The siblings along the path, found from the tree itself: the other roots, and at every
    -- ancestor the children not on the path.
    local chain, at = {}, leaf
    while at do table.insert(chain, 1, at); at = at.parent end
    local expected, level = {}, scene.roots
    for _, on in ipairs(chain) do
      for _, other in ipairs(level) do if other.index ~= on.index then expected[#expected + 1] = other.index end end
      level = on.children
    end
    t.ok(#expected > 0, "the leaf has no siblings to hide: the case would prove nothing")
    local hidden, original = {}, view.Item.node_visible
    view.Item.node_visible = function(self, node, on)
      if on == false then hidden[#hidden + 1] = type(node) == "table" and node.index or node end
      return original(self, node, on)
    end
    local shown
    local ok, err = pcall(function() shown = v:show_node(leaf) end)
    view.Item.node_visible = original
    if not ok then error(err, 0) end
    table.sort(hidden)
    table.sort(expected)
    t.eq(table.concat(hidden, ","), table.concat(expected, ","), "the nodes hidden are not the siblings along the path")
    t.ok(shown.shown == leaf, "the node item holds the node")
    item:remove()
    v:frame()
    local one = v:image()
    t.ok(changed(whole, one) > 0, "the node alone looks like the whole scene")
    scene:close()
    t.eq(next(v._items), nil, "an item still shows a closed scene")
    v:draw()
    v:close()
  end)

  t.test("a pose moves the picture, the rest pose puts it back, and a wrong count is the library's refusal", function()
    local cad = require("cadaclysm")
    local file = t.fixture("samples/mechanism-solid.stp")
    if not file then return end
    local v = offscreen(160, 160)
    if not v then return end
    local scene = cad.open(file)
    t.ok(#scene.states > 0, "mechanism-solid.stp records no state: the pose case would prove nothing")
    local pose = scene:pose_state(scene.states[1])
    local transforms = {}
    for i, n in ipairs(scene.nodes) do transforms[i] = pose:raw_transform(n) end
    local item = v:show_scene(scene)
    v:standard("iso")
    v:frame()
    local rest = v:image()
    item:node_transforms(transforms)
    t.ok(changed(rest, v:image()) > 0, "the pose moved nothing on screen")
    item:node_transforms(nil)
    t.ok(changed(rest, v:image()) < 160 * 160 / 1000, "nil did not restore the rest pose")
    local wrong = t.raises(function() item:node_transforms({ transforms[1] }) end)
    t.ok(is_view_error(wrong) and tostring(wrong):find("1 transforms were given", 1, true), "a wrong count: " .. tostring(wrong))
    -- An empty list is a count of zero, refused on it -- not the NULL that restores the rest pose.
    item:node_transforms(transforms)
    local posed = v:image()
    local empty = t.raises(function() item:node_transforms({}) end)
    t.ok(is_view_error(empty), "an empty transforms list: " .. tostring(empty))
    t.eq(changed(posed, v:image()), 0, "an empty list restored the rest pose")
    scene:close()
    v:close()
  end)

  t.test("Scene:show, Node:show and Pose:show draw by handle; Pose:show moves what Scene:show draws", function()
    local cad = require("cadaclysm")
    local file = t.fixture("samples/mechanism-solid.stp")
    if not file then return end
    if not offscreen(8, 8) then return end
    local scene = cad.open(file)
    local rest = capture(function() t.eq(scene:show({ width = 96, height = 96 }), nil, "show returns nothing") end)
    t.eq(rest.runs, 1, "Scene:show did not run the view")
    t.eq(rest.opts.title, "mechanism-solid.stp", "the scene's file name titles the window")
    t.eq(rest.opts.up, scene:_default_up(), "up defaults from the convention")
    t.eq(scene:_default_up(), "z", "a native-convention scene is z up")
    t.eq(rest.image.width, 96, "no frame was read")
    local pose = scene:pose_state(scene.states[1])
    local posed = capture(function() pose:show({ width = 96, height = 96 }) end)
    t.ok(changed(rest.image, posed.image) > 0, "Pose:show drew what Scene:show draws")
    local unposed = capture(function() scene:pose({}):show({ width = 96, height = 96 }) end)
    t.eq(changed(rest.image, unposed.image), 0, "an unposed pose differs from the scene")
    local camera = capture(function(seen) seen.returned = pose:view({ width = 96, height = 96 }) end)
    t.ok(camera.returned and camera.returned.stand_in, "Pose:view did not return what the view ran to")
    local leaf = nested_leaf(t, scene)
    local node = capture(function() leaf:show({ width = 96, height = 96 }) end)
    t.eq(node.opts.title, "mechanism-solid.stp", "a node is titled by its scene's file, not its own label")
    t.ok(changed(rest.image, node.image) > 0, "Node:show drew the whole scene")
    for _, bad in ipairs({ function() scene:show({ tolerance = 0.1 }) end, function() leaf:view({ tolerance = 0.1 }) end,
        function() pose:show({ tolerance = 0.1 }) end }) do
      local e = t.raises(bad, "takes no tolerance")
      t.ok(is_view_error(e), "a tolerance on a document: " .. tostring(e))
    end
    scene:close()
  end)

  t.test("a scene opened from memory is titled without reading a path, and its up follows its convention", function()
    local cad = require("cadaclysm")
    local file = t.fixture("samples/cube.scad")
    if not file then return end
    if not offscreen(8, 8) then return end
    local f = assert(io.open(file, "rb"))
    local data = f:read("*a")
    f:close()
    local scene = cad.open_memory(data, "scad", nil, nil, cad.Convention.Y_UP)
    local seen = capture(function() scene:show({ width = 64, height = 64 }) end)
    t.ok(type(seen.opts.title) == "string" and seen.opts.title ~= "", "a memory scene has no title")
    t.eq(seen.opts.up, "y", "a y-up scene drew z up")
    -- No options at all (the commonest call) still defaults up from the convention.
    local bare = capture(function() scene:show() end)
    t.eq(bare.opts.up, "y", "scene:show() with no options drew z up")
    local bare_view = capture(function() scene:view() end)
    t.eq(bare_view.opts.up, "y", "scene:view() with no options drew z up")
    local explicit = capture(function() scene:show({ width = 64, height = 64, up = "z", title = "mine" }) end)
    t.eq(explicit.opts.up, "z")
    t.eq(explicit.opts.title, "mine")
    scene:close()
  end)

  t.test("Node:show and Pose:show with no options default up from the convention", function()
    local cad = require("cadaclysm")
    local file = t.fixture("samples/mechanism-solid.stp")
    if not file then return end
    if not offscreen(8, 8) then return end
    local scene = cad.open_memory(assert(io.open(file, "rb")):read("*a"), "step", nil, nil, cad.Convention.Y_UP)
    t.eq(scene:_default_up(), "y")
    local leaf = nested_leaf(t, scene)
    t.eq(capture(function() leaf:show() end).opts.up, "y", "node:show() drew z up")
    t.eq(capture(function() leaf:view() end).opts.up, "y", "node:view() drew z up")
    local pose = scene:pose_state(scene.states[1])
    t.eq(capture(function() pose:show() end).opts.up, "y", "pose:show() drew z up")
    t.eq(capture(function() pose:view() end).opts.up, "y", "pose:view() drew z up")
    scene:close()
  end)

  t.test("Solid:show runs the view on the wgpu library and prints a still elsewhere", function()
    if not offscreen(8, 8) then return end
    local solid = bs.Solid.cuboid(10, 10, 10)
    local seen = capture(function() solid:show({ width = 80, height = 60, zoom = 0.5 }) end)
    t.eq(seen.opts.title, "Solid")
    t.eq(seen.runs, 1, "show did not run the wgpu window")
    local full = capture(function() solid:show({ width = 80, height = 60 }) end)
    t.ok(changed(seen.image, full.image) > 0, "zoom changed nothing")
    local orbit = capture(function(s) s.returned = solid:view({ width = 80, height = 60 }) end)
    t.ok(orbit.returned and orbit.returned.stand_in, "view returned nothing")
    for _, bad in ipairs({ { view = "sideways" }, { up = "x" }, { width = -1 }, "iso", { azimuth = "north" } }) do
      local e = t.raises(function() solid:show(bad) end)
      t.ok(is_view_error(e), "a bad option raised a raw error: " .. tostring(e))
    end
    -- The terminal library draws one frame and does not run.
    local state = {}
    local ok, err = pcall(view.use_terminal)
    if not ok then
      if os.getenv("CADACLYSM_REQUIRE_TERMINAL") == "1" then error(err, 0) end
      print("  skip: " .. tostring(err):match("^[^\n]*"))
      return
    end
    local original = view.View.new
    view.View.new = function(opts)
      local v = original({ title = opts.title, width = 64, height = 48 })
      state.v = v
      v.draw = function() state.drew = true end
      v.run = function() error("show ran a terminal view") end
      return v
    end
    local good, why = pcall(function() solid:show({ width = 64, height = 48 }) end)
    view.View.new = original
    if not good then error(why, 0) end
    t.ok(state.drew, "show drew nothing on the terminal")
    t.ok(state.v:closed(), "the view was left open")
  end)

  t.test("the terminal library shows a solid by handle", function()
    local ok, err = pcall(view.use_terminal)
    if not ok then
      if os.getenv("CADACLYSM_REQUIRE_TERMINAL") == "1" then error(err, 0) end
      print("  skip: " .. tostring(err):match("^[^\n]*"))
      return
    end
    local v = view.View.new({ title = "terminal", width = 64, height = 48 })
    local before = v:image()
    v:show_solid(bs.Solid.cuboid(20, 20, 20))
    v:frame()
    t.ok(not same(v:image(), before, 32, 24), "the terminal drew nothing inside the silhouette")
    v:close()
  end)

  t.test("save writes a PNG of the view", function()
    local v = offscreen(40, 30)
    if not v then return end
    v:show_solid(bs.Solid.sphere(5))
    v:frame()
    local file = t.tmp("view.png")
    v:save(file)
    local f = assert(io.open(file, "rb"))
    local png = f:read("*a")
    f:close()
    t.eq(png:sub(1, 8), "\137PNG\r\n\26\n", "signature")
    t.eq(png:byte(19) * 256 + png:byte(20), 40, "width")
    t.eq(png:byte(23) * 256 + png:byte(24), 30, "height")
    -- The stream is the image, whole: every row after its filter byte, stored.
    local img = v:image()
    local rows = {}
    for y = 0, img.height - 1 do rows[#rows + 1] = "\0" .. ffi.string(img.rgba + y * img.width * 4, img.width * 4) end
    local raw = table.concat(rows)
    t.ok(png:find(raw:sub(1, 65535), 1, true), "the first stored block is not the image's rows")
    v:close()
  end)

  -- 1.10: a viewport given an ortho top camera reads back as one, a viewport-0 orbit pans it,
  -- camera() round-trips through set_camera(), the rects must match the count, a negative tap
  -- is refused.
  t.test("1.10: a viewport's camera is set, read back, moved, aimed and pivoted", function()
    local v = offscreen(64, 48)
    if not v then return end
    local id = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
    v:viewports({ { rect = { 0, 0, 64, 48 }, view = id, projection = id, eye = { 0, 0, 1 } } })
    v:set_camera(0, { kind = "ortho", axis_view = { 0, 0, -1 }, axis_right = { 1, 0, 0 }, axis_up = { 0, 1, 0 }, height = 3, radius = 1 })
    local c = v:camera(0)
    t.eq(c.kind, "ortho"); t.eq(c.height, 3)
    t.eq(c.axis_view[3], -1, "the basis reads back as given")
    t.eq(c.axis_right[1], 1); t.eq(c.axis_up[2], 1)
    local x0 = c.target[1]
    v:orbit(10, 0, 0)
    local moved = v:camera(0)
    t.ok(moved.target[1] < x0, "an ortho orbit pans: the centre moved left")
    v:set_camera(0, moved)
    local again = v:camera(0)
    t.eq(again.kind, "ortho")
    for k = 1, 3 do
      t.near(again.target[k], moved.target[k], 1e-6, "camera() -> set_camera() keeps the target")
      t.near(again.axis_up[k], moved.axis_up[k], 1e-6, "camera() -> set_camera() keeps the basis")
    end
    t.eq(again.height, moved.height)
    t.raises(function() v:viewport_rects({ { 0, 0, 64, 48 }, { 0, 0, 1, 1 } }) end, "cadaclysm_view_set_viewport_rects")
    v:viewport_rects({ { 0, 0, 64, 48 } })
    t.raises(function() v:viewport_rects({ { 0, 0, 64, -1 } }) end, "viewport_rects: rect 1's h")
    t.raises(function() v:orbit(1, 1, -2) end, "orbit viewport")
    v:tap(3, 0)
    t.raises(function() v:tap(-1, 0) end, "cadaclysm_view_set_tap")
    t.ok(v:aim(0, { 0, 1, 0 }, { 0, 0, 1 }))
    v:pivot(0, { 1, 2, 3 }); v:pivot(0, nil)
    v:standard("top", 0)   -- (frame needs something shown: the file's solid cases cover framing)
    -- Another viewport's moves are its own (the `_in` calls): viewport 1's centre moves, 0's stays.
    v:viewports({ { rect = { 0, 0, 32, 48 }, view = id, projection = id, eye = { 0, 0, 1 } },
                  { rect = { 32, 0, 32, 48 }, view = id, projection = id, eye = { 0, 0, 1 } } })
    local ortho = { kind = "ortho", axis_view = { 0, 0, -1 }, axis_right = { 1, 0, 0 }, axis_up = { 0, 1, 0 }, height = 3, radius = 1 }
    v:set_camera(0, ortho); v:set_camera(1, ortho)
    local a0, b0 = v:camera(0).target[1], v:camera(1).target[1]
    v:orbit(10, 0, 1)
    t.ok(v:camera(1).target[1] < b0, "orbit(dx, dy, 1) pans viewport 1")
    t.eq(v:camera(0).target[1], a0, "orbit(dx, dy, 1) leaves viewport 0 alone")
    v:close()
  end)

  t.test("a bad argument is the module's own error, never a raw Lua one", function()
    local v = offscreen(32, 32)
    if not v then return end
    local item = v:show_solid(bs.Solid.cuboid(5, 5, 5))
    local cases = {
      function() v:show_solid(nil) end,
      function() v:show_solid({}) end,
      function() v:show(nil) end,
      function() v:show("solid") end,
      function() v:show_scene(nil) end,
      function() v:show_node(nil) end,
      function() v:orbit(nil, 1) end,
      function() v:zoom("a") end,
      function() v:standard(nil) end,
      function() v:layer("sky", true) end,
      function() v:background(nil) end,
      function() v:background({ 1, 2 }) end,
      function() v:pick(nil, 3) end,
      function() v:pick(-1, 3) end,
      function() v:lod("fast") end,
      function() v:lod("smooth", -1) end,
      function() v:resize(nil, 4) end,
      function() v:input(nil) end,
      function() v:input({ type = "flick" }) end,
      function() v:show_mesh({}) end,
      function() v:show_mesh({ positions = { 0, 0 }, indices = { 0 }, normals = { 0, 0, 0 } }) end,
      function() v:show_mesh({ positions = { 0, 0, 0 }, indices = { 0 }, edges = { 1, 2, 3 } }) end,
      function() v:show_lines({ 1, 2, 3 }) end,
      function() v:show_lines(nil) end,
      function() v:show_curves({ 1, 2, 3 }) end,
      function() v:show_image({ 1, 2 }, "", 0, 0) end,
      function() v:show_image({ 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0 }, "abc", 1, 1) end,
      function() v:viewports({ 5 }) end,
      function() v:viewports({ { rect = { 0, 0, 1 }, view = {}, projection = {}, eye = {} } }) end,
      function() item:colour(nil) end,
      function() item:colour({ 1, 2 }) end,
      function() item:placement({ 1, 2, 3 }) end,
      function() item:node_colour(nil, { 1, 1, 1 }) end,
      function() item:node_highlight(0, { 1, 1 }) end,
      function() item:node_visible("a", true) end,
      function() item:node_visible({}, true) end,
      function() v:show_image({ 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 9 }, "abcd", 1, 1) end,
      function() v:show_mesh({ positions = { 0, 0, 0, 1 }, indices = { 0 } }) end,
      function() item:frame_node(nil) end,
      function() item:node_transforms({ { 1, 2, 3 } }) end,
      function() item:node_transforms(5) end,
      function() item:face_colours({ 0, 1 }, { { 1, 0, 0, 1 } }) end,
      function() item:face_colours({ 0 }, {}) end,
      function() view.pump("soon") end,
      function() view.use(5) end,
      function() view.View.offscreen(nil, 5) end,
      function() view.View.offscreen(8, 8, { up = "x" }) end,
      function() view.View.offscreen(8, 8, { surfaces = "mesh" }) end,
      function() view.View.in_window({ kind = "win32" }) end,
      function() view.View.in_window({ kind = "xlib", width = 1, height = 1 }) end,
      function() view.View.in_window({ kind = "gdi", width = 1, height = 1 }) end,
      function() v:save(nil) end,
    }
    for i, fn in ipairs(cases) do
      local ok, err = pcall(fn)
      t.ok(not ok, "case " .. i .. " raised nothing")
      t.ok(is_view_error(err), "case " .. i .. " raised a raw error: " .. tostring(err))
    end
    v:close()
  end)

  t.test("empty arrays reach the library as empty arrays, never the NULL that means none", function()
    local v = offscreen(32, 32)
    if not v then return end
    local item = v:show_solid(bs.Solid.cuboid(5, 5, 5))
    -- Face colours: nil clears every face; an empty list colours none and is accepted (Python's).
    item:face_colours({ 0, 1, 2, 3, 4, 5 }, { { 1, 0, 0, 1 }, { 1, 0, 0, 1 }, { 1, 0, 0, 1 }, { 1, 0, 0, 1 }, { 1, 0, 0, 1 }, { 1, 0, 0, 1 } })
    v:standard("iso")
    v:frame()
    local red = v:image()
    item:face_colours({}, {})
    t.eq(changed(red, v:image()) > 0, true, "an empty face list changed nothing (the red faces stayed)")
    item:face_colours(nil)
    -- An empty mesh is the library's refusal (or an empty item), never a crash on a NULL.
    local ok, err = pcall(function() v:show_mesh({ positions = {}, indices = {} }) end)
    t.ok(ok or is_view_error(err), "an empty mesh: " .. tostring(err))
    ok, err = pcall(function() v:show_lines({}) end)
    t.ok(ok or is_view_error(err), "no lines: " .. tostring(err))
    -- An empty viewport list clears them, as Python's does.
    v:viewports({})
    v:close()
  end)

  -- A fake library that also parses colour text as the real one does (enough of its forms) and
  -- records every colour a call was handed, rounded (Python's `_seen`).
  local function colour_fake(state)
    local lib = fake(state)
    local C, seen = lib.C, {}
    state.seen = seen
    local names = { red = { 255, 0, 0 }, white = { 255, 255, 255 }, steelblue = { 70, 130, 180 }, lime = { 0, 255, 0 }, blue = { 0, 0, 255 } }
    C.cadaclysm_view_parse_colour = function(text, out)
      local s = ffi.string(text)
      local low = s:lower():match("^%s*(.-)%s*$")
      local hex = low:gsub("^#", "")
      local rgb
      if (#hex == 3 or #hex == 6) and not hex:find("[^0-9a-f]") then
        if #hex == 3 then hex = hex:gsub(".", "%0%0") end
        rgb = { tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16) }
      else
        rgb = names[low]
      end
      if not rgb then
        state.error = ("cadaclysm_view_parse_colour: colour: \"#rgb\", \"#rrggbb\" or a CSS colour name, not '%s'"):format(s)
        return false
      end
      for k = 1, 3 do out[k - 1] = rgb[k] / 255 end
      state.error = ""
      return true
    end
    local function note(what, c, n)
      if c == nil then seen[#seen + 1] = what .. " nil" return end
      local parts = {}
      for k = 0, n - 1 do parts[#parts + 1] = ("%.3f"):format(c[k]) end
      seen[#seen + 1] = what .. " " .. table.concat(parts, ",")
    end
    local id = 0
    local function item() id = id + 1 return id end
    C.cadaclysm_view_show_mesh = function(_, m) note("mesh", m.rgb, 3) return item() end
    C.cadaclysm_view_show_lines = function(_, _, _, c) note("lines", c, 3) return item() end
    C.cadaclysm_view_show_curves = function(_, _, _, c) note("curves", c, 3) return item() end
    C.cadaclysm_view_set_colour = function(_, _, c) note("colour", c, 3) return true end
    C.cadaclysm_view_set_background = function(_, c) note("background", c, 3) end
    C.cadaclysm_view_set_node_color = function(_, _, _, c) note("node_colour", c, 4) return true end
    C.cadaclysm_view_set_node_highlight = function(_, _, _, c) note("node_highlight", c, 4) return true end
    C.cadaclysm_view_set_face_colours = function(_, _, _, c, n) note("faces", c, 4 * n) return true end
    return lib
  end

  t.test("show_text fills CadaclysmViewText with the defaults and the options", function()
    local state = { calls = {} }
    local lib = colour_fake(state)
    local seen = {}
    lib.C.cadaclysm_view_show_text = function(v, txt)
      seen.size, seen.text, seen.mode = txt.size, ffi.string(txt.text), txt.mode
      seen.at = { txt.at[0], txt.at[1], txt.at[2] }
      seen.height, seen.align, seen.on_top, seen.font = txt.height, txt.align, txt.on_top, txt.font
      seen.rgb = { txt.rgb[0], txt.rgb[1], txt.rgb[2] }
      seen.box = { txt.box_rgba[0], txt.box_rgba[1], txt.box_rgba[2], txt.box_rgba[3] }
      seen.padding, seen.offset = txt.box_padding, { txt.offset[0], txt.offset[1] }
      seen.right, seen.up = { txt.right[0], txt.right[1], txt.right[2] }, { txt.up[0], txt.up[1], txt.up[2] }
      return 9
    end
    lib.C.cadaclysm_view_set_text = function(v, id, text) seen.set = { id, ffi.string(text) }; return true end
    view.use(lib)
    local v = view.View.new({ width = 8, height = 8 })
    local label = v:show_text("PART-7", { 1, 2, 3 })
    t.eq(label.id, 9)
    t.eq(seen.size, ffi.sizeof("CadaclysmViewText"))
    t.eq(seen.text, "PART-7"); t.eq(seen.mode, 0); t.eq(seen.align, 6)
    t.eq(seen.at[1], 1); t.eq(seen.at[3], 3); t.eq(seen.height, 12)
    t.eq(seen.rgb[1], 1); t.eq(seen.rgb[3], 1); t.eq(seen.box[4], 0); t.eq(seen.padding, 4)
    t.eq(seen.on_top, 0); t.eq(seen.font, 0); t.eq(seen.right[1], 0); t.eq(seen.up[2], 0)
    v:show_text("T", { 0, 0, 0 }, { mode = "world", size = 2, colour = "red", align = "center", offset = { 3, 4 },
      box = "blue", padding = 6, on_top = true, font = 2, right = { 0, 1, 0 }, up = { 0, 0, 1 } })
    t.eq(seen.mode, 1); t.eq(seen.height, 2); t.eq(seen.align, 4)
    t.eq(seen.rgb[1], 1); t.eq(seen.rgb[2], 0); t.eq(seen.box[3], 1); t.eq(seen.box[4], 1)
    t.eq(seen.offset[2], 4); t.eq(seen.padding, 6); t.eq(seen.on_top, 1); t.eq(seen.font, 2)
    t.eq(seen.right[2], 1); t.eq(seen.up[3], 1)
    label:set_text("PART-8")
    t.eq(seen.set[1], 9); t.eq(seen.set[2], "PART-8")
    t.raises(function() v:show_text("x", { 0, 0, 0 }, { mode = "screen" }) end, 'mode "screen": one of')
    t.raises(function() v:show_text("x", { 0, 0, 0 }, { align = "middle" }) end, 'align "middle": one of')
    t.raises(function() v:show_text("a\0b", { 0, 0, 0 }) end, "a NUL character cannot be shown")
    t.raises(function() v:show_text(nil, { 0, 0, 0 }) end, "text: a string, not nil")
    t.raises(function() label:set_text("a\0b") end, "a NUL character cannot be shown")
    t.raises(function() label:set_text(5) end, "text: a string, not number")
    view._reset()
  end)

  t.test("show_text refuses what is not a vector or a number, and nothing reaches the library", function()
    local state = {}
    local lib = colour_fake(state)
    local reached = 0
    lib.C.cadaclysm_view_show_text = function() reached = reached + 1; return 9 end
    view.use(lib)
    local v = view.View.new({ width = 8, height = 8 })
    local function refused(at, opts, pattern)
      local err = t.raises(function() v:show_text("x", at, opts) end, pattern)
      t.ok(is_view_error(err), "a ViewError: " .. tostring(err))
    end
    refused("red", nil, "show_text at")
    refused(nil, nil, "show_text at: 3 numbers, not nil")
    refused({ 1, 2 }, nil, "show_text at")
    refused({ 0, 0, 0 }, { right = "red" }, "show_text right")
    refused({ 0, 0, 0 }, { up = 5 }, "show_text up")
    refused({ 0, 0, 0 }, { offset = 5 }, "show_text offset")
    refused({ 0, 0, 0 }, { offset = { 1 } }, "show_text offset")
    refused({ 0, 0, 0 }, { size = "big" }, "show_text size")
    refused({ 0, 0, 0 }, { padding = {} }, "show_text padding")
    refused({ 0, 0, 0 }, { font = -1 }, "show_text font")
    refused({ 0, 0, 0 }, { font = 1.5 }, "show_text font")
    refused({ 0, 0, 0 }, { font = "a" }, "show_text font")
    t.eq(reached, 0)
    view._reset()
  end)

  t.test("the text layer is layer 5", function()
    local state = {}
    local lib = colour_fake(state)
    local got
    lib.C.cadaclysm_view_set_layer = function(_, which, on) got = { which, on }; return true end
    view.use(lib)
    local v = view.View.new({ width = 8, height = 8 })
    v:layer("text", false)
    t.eq(got[1], 5); t.eq(got[2], false)
    view._reset()
  end)

  t.test("load_font reads an existing file, takes any other string as bytes, refuses a non-string", function()
    local state = {}
    local lib = colour_fake(state)
    local got = {}
    lib.C.cadaclysm_view_load_font = function(bytes, n) got[#got + 1] = ffi.string(bytes, n); return state.font or 3 end
    view.use(lib)
    local path = t.tmp("font.bin")
    local f = assert(io.open(path, "wb")); f:write("FILE\0BYTES"); f:close()
    t.eq(view.load_font(path), 3)
    t.eq(got[1], "FILE\0BYTES")
    t.eq(view.load_font("not a file, just bytes"), 3)
    -- io.open stops at a NUL, so a path with one would open the file: it must be bytes instead.
    t.eq(view.load_font(path .. string.char(0) .. "x"), 3)
    t.eq(got[3], path .. string.char(0) .. "x")
    t.eq(got[2], "not a file, just bytes")
    os.remove(path)
    t.raises(function() view.load_font(nil) end, "load_font: a path or the font's bytes, not nil")
    t.raises(function() view.load_font(12) end, "load_font: a path or the font's bytes, not number")
    state.font, state.error = 0, "cadaclysm_view_load_font: not a font"
    t.raises(function() view.load_font("\1\2\3") end, "cadaclysm_view_load_font")
    view._reset()
  end)

  t.test("a label draws and picks on the real library", function()
    local v = offscreen(64, 64)
    if not v then return end
    v:background("black")
    -- Lime glyphs on a red box: a swapped colour/box pair would still show both colours,
    -- so the counts tell them apart (the box is bigger than the glyphs).
    local label = v:show_text("HH", { 0, 0, 0 }, { colour = "lime", size = 24, align = "centre", box = "red", on_top = true })
    local img = v:image()
    local red, lime = 0, 0
    for y = 0, 63 do for x = 0, 63 do
      local r, g, b = pixel(img, x, y)
      if r > 200 and g < 60 and b < 60 then red = red + 1 end
      if g > 200 and r < 60 and b < 60 then lime = lime + 1 end
    end end
    t.ok(lime > 20, ("the glyphs are drawn: %d lime pixels"):format(lime))
    t.ok(red > 50, ("the box is drawn: %d red pixels"):format(red))
    t.ok(red > lime, ("the box (%d red) covers more than the glyphs (%d lime)"):format(red, lime))
    local hit = v:pick(32, 32)
    t.ok(hit and hit.item == label.id and hit.face == 0, "the label picks at its anchor, line 0")
    label:set_text("H")
    t.ok(changed(img, v:image()) > 0, "set_text changed the picture")
    label:remove()
    -- A label with no box has no red in it at all.
    v:show_text("HH", { 0, 0, 0 }, { colour = "lime", size = 24, align = "centre", on_top = true })
    local bare = v:image()
    local bare_red, bare_lime = 0, 0
    for y = 0, 63 do for x = 0, 63 do
      local r, g, b = pixel(bare, x, y)
      if r > 60 and g < 60 and b < 60 then bare_red = bare_red + 1 end
      if g > 200 and r < 60 and b < 60 then bare_lime = bare_lime + 1 end
    end end
    t.eq(bare_red, 0)
    t.ok(bare_lime > 20, "the box-less label still draws its glyphs")
    t.raises(function() view.load_font("\1\2\3") end, "cadaclysm_view_load_font")
    -- Spec 5: the bundled font's bytes load and draw (the runner's cwd is the repository root).
    local font = view.load_font("crates/cadaclysm-text/fonts/LiberationSans-Regular.ttf")
    t.ok(font > 0, "the bundled font loads from its path")
    local before = v:image()
    v:show_text("W", { 0, 0, 0 }, { colour = "red", size = 24, on_top = true, font = font })
    t.ok(changed(before, v:image()) > 0, "text in the loaded font draws")
    v:close()
  end)

  t.test("every colour takes text through the library's cadaclysm_view_parse_colour; text where an alpha is taken means 1", function()
    local state = {}
    view.use(colour_fake(state))
    local v = view.View.new({ width = 8, height = 8 })
    local item = v:show_mesh({ positions = { 0, 0, 0, 1, 0, 0, 0, 1, 0 }, indices = { 0, 1, 2 }, rgb = "red" })
    item:colour("#00f")
    v:background("SteelBlue")
    item:node_colour(0, "white")
    item:node_highlight(0, "#f00")
    item:face_colours({ 0, 1 }, { "00ff00", { 0, 0, 1, 0.5 } })
    v:show_lines({ 0, 0, 0, 1, 1, 1 }, "#ffffff")
    v:show_curves({ 0, 0, 0, 1, 1, 0, 0, 1, 2, 0, 0, 1, 3, 0, 0, 1 }, "LIME")
    item:colour({ 0.5, 0.5, 0.5 })   -- numbers never reach the parser
    t.eq(table.concat(state.seen, " | "), table.concat({
      "mesh 1.000,0.000,0.000", "colour 0.000,0.000,1.000", "background 0.275,0.510,0.706",
      "node_colour 1.000,1.000,1.000,1.000", "node_highlight 1.000,0.000,0.000,1.000",
      "faces 0.000,1.000,0.000,1.000,0.000,0.000,1.000,0.500", "lines 1.000,1.000,1.000", "curves 0.000,1.000,0.000",
      "colour 0.500,0.500,0.500" }, " | "))
    v:close()
    view._reset()
  end)

  -- 1.11's points: what show_points hands the library, and what it refuses before it.
  t.test("show_points reaches the contract and returns an item", function()
    local state = {}
    local lib = colour_fake(state)
    local got = {}
    lib.C.cadaclysm_view_show_points = function(_, p, n, rgb, size)
      got.calls = (got.calls or 0) + 1
      got.positions = {}
      for k = 0, 3 * n - 1 do got.positions[#got.positions + 1] = p[k] end
      got.count = n
      got.rgb = rgb ~= nil and { rgb[0], rgb[1], rgb[2] } or nil
      got.size = size
      return 17
    end
    view.use(lib)
    local v = view.View.new({ width = 8, height = 8 })
    local item = v:show_points({ 0, 0, 0, 1, 2, 3 }, "red", 12)
    t.eq(item.id, 17, "the item")
    t.eq(got.calls, 1, "calls")
    t.eq(table.concat(got.positions, ","), "0,0,0,1,2,3", "the positions")
    t.eq(got.count, 2, "the count")
    t.eq(got.rgb and table.concat(got.rgb, ",") or "NULL", "1,0,0", "red reached the library as (1, 0, 0)")
    t.eq(got.size, 12, "the size")
    item = v:show_points({ 1, 2, 3 })
    t.eq(item.id, 17, "one point's item")
    t.eq(got.calls, 2, "calls")
    t.eq(table.concat(got.positions, ","), "1,2,3", "one point")
    t.eq(got.rgb, nil, "no colour is rgb NULL")
    t.eq(got.size, 8, "no size is 8")
    local ok, err = pcall(function() v:show_points({ 1, 2, 3, 4 }) end)
    t.ok(not ok and is_view_error(err), "four numbers: not a ViewError: " .. tostring(err))
    t.eq(tostring(err), "show_points: three numbers a point, not 4")
    ok, err = pcall(function() v:show_points({ 1, 2, 3 }, { 1, 0 }) end)
    t.ok(not ok and is_view_error(err), "a two-number rgb: not a ViewError: " .. tostring(err))
    t.eq(tostring(err), "show_points rgb: 3 numbers, not 2")
    t.eq(got.calls, 2, "a refused show_points reached the library")
    v:close()
    view._reset()
  end)

  t.test("colour text the library refuses raises its message, and nothing reaches the view", function()
    local state = {}
    view.use(colour_fake(state))
    local v = view.View.new({ width = 8, height = 8 })
    local item = v:show_mesh({ positions = { 0, 0, 0, 1, 0, 0, 0, 1, 0 }, indices = { 0, 1, 2 } })
    local before = #state.seen
    for _, case in ipairs({
      { "blurple", function() item:colour("blurple") end },
      { "transparent", function() v:background("transparent") end },
      { "nope", function() item:node_highlight(0, "nope") end },
      { "rgb(1, 2, 3)", function() item:face_colours({ 0 }, { "rgb(1, 2, 3)" }) end },
      { "#f00a", function() v:show_lines({ 0, 0, 0, 1, 1, 1 }, "#f00a") end },
    }) do
      local ok, err = pcall(case[2])
      t.ok(not ok and is_view_error(err), case[1] .. ": not a ViewError: " .. tostring(err))
      t.eq(tostring(err), ("cadaclysm_view_parse_colour: colour: \"#rgb\", \"#rrggbb\" or a CSS colour name, not '%s'"):format(case[1]))
    end
    t.eq(#state.seen, before, "a refused colour reached the view")
    v:close()
    view._reset()
  end)

  t.test("colour text draws on the real library; text it refuses raises its own words", function()
    local v = offscreen(64, 48)
    if not v then return end
    v:layer("grid", false)
    v:background("#ff0")
    local item = v:show_mesh({ positions = { -1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0 }, indices = { 0, 1, 2, 0, 2, 3 }, rgb = "Blue" })
    v:standard("top")
    v:frame()
    local img = v:image()
    local r, g, b = pixel(img, 32, 24)
    t.ok(b > 150 and r < 80 and g < 80, ("the centre is not blue: %d %d %d"):format(r, g, b))
    r, g, b = pixel(img, 1, 1)
    t.ok(r > 150 and g > 150 and b < 80, ("the corner is not the yellow background: %d %d %d"):format(r, g, b))
    item:colour("lime")
    r, g, b = pixel(v:image(), 32, 24)
    t.ok(g > 150 and r < 80 and b < 80, ("the centre is not lime: %d %d %d"):format(r, g, b))
    local ok, err = pcall(function() item:colour("blurple") end)
    t.ok(not ok and is_view_error(err) and tostring(err):find("^cadaclysm_view_parse_colour: .*not 'blurple'$") ~= nil, tostring(err))
    v:close()
  end)

  t.test("occluded takes the three names on the real library; no mode and another name are refused", function()
    local v = offscreen(64, 48)
    if not v then return end
    local item = v:show_mesh({ positions = { -1, -1, 0, 1, -1, 0, 1, 1, 0 }, indices = { 0, 1, 2 } })
    for _, name in ipairs({ "off", "solid", "dashed" }) do item:occluded(name) end
    t.raises(function() item:occluded() end, "occluded: 'nil' is not 'off', 'solid' or 'dashed'")
    t.raises(function() item:occluded("_list") end, "occluded: '_list' is not 'off', 'solid' or 'dashed'")
    v:close()
  end)

  t.test("finish takes the three names on the real library; no finish and another name are refused", function()
    local v = offscreen(64, 48)
    if not v then return end
    local item = v:show_mesh({ positions = { -1, -1, 0, 1, -1, 0, 1, 1, 0 }, indices = { 0, 1, 2 } })
    for _, name in ipairs({ "gloss", "satin", "matte" }) do item:finish(name) end
    t.raises(function() item:finish() end, "finish: 'nil' is not 'gloss', 'satin' or 'matte'")
    t.raises(function() item:finish("_list") end, "finish: '_list' is not 'gloss', 'satin' or 'matte'")
    v:close()
  end)

  t.test("show_solid takes a material, an opacity and faces on the real library; a bad one is refused, named", function()
    local v = offscreen(64, 48)
    if not v then return end
    local cube = bs.Solid.cuboid(1, 1, 1)
    local ghost = v:show_solid(cube, 0.05, nil, { material = "glass", opacity = 0.5, faces = { 0, 1 } })
    t.ok(ghost.id > 0, "a ghost of two faces was not shown")
    ghost:remove()
    t.ok(v:show_solid(cube, nil, nil, { material = "metal" }).id > 0, "a metal cube was not shown")
    t.raises(function() v:show_solid(cube, nil, nil, { material = "chrome" }) end, "material: 'chrome' is not 'default'")
    t.raises(function() v:show_solid(cube, nil, nil, { material = "_list" }) end, "material: '_list' is not")
    t.raises(function() v:show_solid(cube, nil, nil, { faces = { 99 } }) end, "face 99 is not one of the solid's 6 faces")
    v:close()
  end)

  t.test("pick uses request_pick for viewport 0 and request_pick_in for another, and a refusal raises", function()
    local state = {}
    view.use(fake(state))
    local v = view.View.new({ width = 8, height = 8 })
    local hit = v:pick(3, 4)
    t.ok(hit and hit.item == 7 and hit.node == 1 and hit.face == 2, "the answer was not read")
    v:pick(5, 6, 0)
    v:pick(7, 8, 2)
    local names = {}
    for _, p in ipairs(state.pick) do names[#names + 1] = p[1] .. ":" .. table.concat(p, ",", 2) end
    t.eq(table.concat(names, " "), "request_pick:3,4 request_pick:5,6 request_pick_in:2,7,8")
    state.error = "view: no such viewport"
    local e = t.raises(function() v:pick(1, 1, 3) end, "no such viewport")
    t.ok(is_view_error(e))
    t.eq(tostring(e), "view: no such viewport", "the library's own reason, bare")
    state.error = ""
    v:close()
    view._reset()
  end)

  t.test("pump: a negative wait is none, a failing window stays open (Python), and a closed one is let go", function()
    local state = { pump = 1 }
    view.use(fake(state))
    local a = view.View.new({ width = 8, height = 8 })
    local b = view.View.new({ width = 8, height = 8 })
    t.eq(view.pump(-5), 2, "two windows are open")
    t.eq(state.waits[1], 0, "a negative wait reached the library")
    t.eq(state.waits[2], 0, "the second window waits at all")
    t.eq(view.pump(30), 2)
    t.eq(state.waits[3], 30, "the first window carries the wait")
    state.pump = 2
    t.eq(view.pump(0), 0, "closed windows are counted open")
    t.ok(a:closed() and b:closed(), "a closed window is not marked")
    local calls = #state.waits
    t.eq(view.pump(0), 0)
    t.eq(#state.waits, calls, "a closed window was pumped again")
    t.raises(function() a:draw() end, "the window is closed")
    a:close()
    b:close()
    -- A failing pump: the refusal raises, and the window stays open and is pumped again (Python's).
    state.pump = 9
    state.error = "view: the surface was lost"
    local c = view.View.new({ width = 8, height = 8 })
    local e = t.raises(function() view.pump(0) end, "the surface was lost")
    t.ok(is_view_error(e))
    t.eq(tostring(e), "view: the surface was lost", "bare, as Python's")
    t.ok(not c:closed(), "a window whose pump failed was marked closed")
    local before = #state.waits
    t.raises(function() view.pump(0) end, "the surface was lost")
    t.eq(#state.waits, before + 1, "a window whose pump failed was not pumped again")
    state.error = ""
    state.pump = 1
    t.eq(view.pump(0), 1, "the window whose pump recovered is not counted as the one window open")
    c:close()
    -- No window: it waits and answers zero.
    t.eq(view.pump(0), 0)
    view._reset()
  end)

  t.test("a library chosen away from stays loaded (a LOD thread may still run in it)", function()
    local ok = pcall(view.use_wgpu)
    if not ok then ok = pcall(view.use_terminal) end
    if not ok then return end
    local held = setmetatable({ view.current().C }, { __mode = "v" })
    view.use(fake({}))
    collectgarbage()
    collectgarbage()
    t.ok(held[1] ~= nil, "the clib of the library chosen away from was collected (and its library unloaded)")
    view._reset()
  end)

  t.test("closing a scene opens no library, and without the view module loaded it loads none", function()
    local cad = require("cadaclysm")
    local file = t.fixture("samples/cube.scad")
    if not file then return end
    view._reset()
    local scene = cad.open(file)
    scene:close()
    t.eq(view._loaded(), nil, "closing a scene loaded a view library")
    local loaded = package.loaded["cadaclysm_view"]
    package.loaded["cadaclysm_view"] = nil
    local other = cad.open(file)
    local ok, err = pcall(function() other:close() end)
    local after = package.loaded["cadaclysm_view"]
    package.loaded["cadaclysm_view"] = loaded
    if not ok then error(err, 0) end
    t.eq(after, nil, "closing a scene loaded the view module")
  end)

  -- ---- view ABI 1.8: the pick's clicks and point, the double-click opt-in, focus, navigation ----

  t.test("CadaclysmViewPick is the header 1.24 layout: clicks 16, has_point 20, point 24, overlay 36, 40 bytes", function()
    t.eq(ffi.sizeof("CadaclysmViewPick"), 40)
    local at = {}
    for _, f in ipairs({ "size", "item", "node", "face", "clicks", "has_point", "point", "overlay" }) do at[#at + 1] = ffi.offsetof("CadaclysmViewPick", f) end
    t.eq(table.concat(at, ","), "0,4,8,12,16,20,24,36")
  end)

  t.test("a pick answer and run's pick carry clicks, and the point only where the library set one", function()
    local state = {}
    local f = fake(state)
    local answers = { { 3, 4, 5, 2, 1, { 1.5, -2, 0.25 } }, { 3, 4, 5, 1, 0, { 9, 9, 9 } } }
    local function fill(out, a)
      out.item, out.node, out.face, out.clicks, out.has_point = a[1], a[2], a[3], a[4], a[5]
      out.point[0], out.point[1], out.point[2] = a[6][1], a[6][2], a[6][3]
    end
    f.C.cadaclysm_view_pick_result = function(_, out) fill(out, table.remove(answers, 1)) return true end
    f.C.cadaclysm_view_run = function(_, cam, pick)
      cam.eye[2] = 1
      cam.up[1] = 1
      fill(pick, { 7, 0, 0, 2, 0, { 1, 2, 3 } })
      return true
    end
    view.use(f)
    local v = view.View.new({ width = 8, height = 8 })
    local hit = v:pick(1, 1)
    t.ok(hit and hit.item == 3 and hit.node == 4 and hit.face == 5 and hit.clicks == 2, "a double click's hit")
    t.ok(hit.point and hit.point[1] == 1.5 and hit.point[2] == -2 and hit.point[3] == 0.25, "the point it hit")
    local flat = v:pick(1, 1)
    t.ok(flat and flat.clicks == 1, "a click's hit")
    t.eq(flat.point, nil, "has_point 0: the point bytes mean nothing")
    local cam = v:run()
    t.ok(cam.pick and cam.pick.item == 7 and cam.pick.clicks == 2, "run's pick carries clicks")
    t.eq(cam.pick.point, nil, "run's pick: no point without has_point")
    view._reset()
  end)

  t.test("a library answering view ABI 1.8 (1.24 or 2.25) is refused with its version", function()
    local function answering(version)
      return { cadaclysm_view_abi_version = function() return version end }
    end
    local e = t.raises(function() view._bound("stand-in", answering(1 * 65536 + 8)) end, "view ABI 1.8")
    t.eq(tostring(e), "stand-in: view ABI 1.8, this wrapper needs 1.25 or a later 1.x")
    e = t.raises(function() view._bound("stand-in", answering(2 * 65536 + 25)) end, "view ABI 2.25")
    t.eq(tostring(e), "stand-in: view ABI 2.25, this wrapper needs 1.25 or a later 1.x")
    e = t.raises(function() view._bound("stand-in", answering(1 * 65536 + 24)) end, "view ABI 1.24")
    t.eq(tostring(e), "stand-in: view ABI 1.24, this wrapper needs 1.25 or a later 1.x")
    -- 1.25 passes the gate (this stand-in then fails a later check, never the version's).
    local taken, why = pcall(view._bound, "stand-in", answering(1 * 65536 + 25))
    t.ok(not taken and not tostring(why):find("view ABI", 1, true), "1.25 passes the version gate: " .. tostring(why))
  end)

  t.test("stats: the 1.25 layout; an offscreen view's frames are its images, each with its cost", function()
    t.eq(ffi.sizeof("CadaclysmViewStats"), 40, "sizeof CadaclysmViewStats")
    t.eq(ffi.offsetof("CadaclysmViewStats", "frames_drawn"), 8, "frames_drawn")
    t.eq(ffi.offsetof("CadaclysmViewStats", "last_frame_ms"), 16, "last_frame_ms")
    t.eq(ffi.offsetof("CadaclysmViewStats", "last_gpu_ms"), 20, "last_gpu_ms")
    t.eq(ffi.offsetof("CadaclysmViewStats", "triangles"), 24, "triangles")
    t.eq(ffi.offsetof("CadaclysmViewStats", "draw_calls"), 32, "draw_calls")
    local v = offscreen(64, 48)
    if not v then return end
    local s = v:stats()
    t.eq(s.frames_drawn, 0, "a new view drew nothing")
    t.eq(s.triangles, 0, "no triangles yet")
    v:show_solid(bs.Solid.cuboid(20, 20, 20))
    v:draw()
    t.eq(v:stats().frames_drawn, 0, "an offscreen draw renders nothing")
    v:image()
    s = v:stats()
    t.eq(s.frames_drawn, 1, "one frame")
    t.ok(s.last_frame_ms > 0 and s.triangles >= 12 and s.draw_calls >= 1,
      ("its cost: %g ms, %d triangles, %d draw calls"):format(s.last_frame_ms, s.triangles, s.draw_calls))
    t.ok(s.last_gpu_ms == -1 or (s.last_gpu_ms >= 0 and s.last_gpu_ms < 1000), "the GPU time: " .. s.last_gpu_ms)
    v:image()
    t.eq(v:stats().frames_drawn, 2, "each image counts")
    v:close()
  end)

  t.test("overlays: a holed panel, a crosshair, text and an image over the window, picked before the scene", function()
    t.eq(ffi.sizeof("CadaclysmViewOverlay"), 80, "sizeof CadaclysmViewOverlay")
    t.eq(ffi.sizeof("CadaclysmViewOverlayImage"), 48, "sizeof CadaclysmViewOverlayImage")
    t.eq(ffi.offsetof("CadaclysmViewText", "order"), 112, "CadaclysmViewText.order")
    t.eq(ffi.offsetof("CadaclysmViewPick", "overlay"), 36, "CadaclysmViewPick.overlay")
    local v = offscreen(200, 120)
    if not v then return end
    v:background("black")
    local under = v:show_solid(bs.Solid.cuboid(80, 80, 20), 0.05, "#808080")
    v:standard("top")
    v:frame()
    local function near(img, x, y, r, g, b)
      local pr, pg, pb = pixel(img, x, y)
      return math.abs(pr - r) < 40 and math.abs(pg - g) < 40 and math.abs(pb - b) < 40
    end
    -- A rounded red panel with a round hole, by its own colour, at the window's centre.
    local shape = bs.Profile.rect(60, 40):round(6):with_hole(bs.Profile.circle(8)):coloured("red")
    local panel = v:show_overlay(shape, "centre", 0, 0)
    t.ok(getmetatable(panel) == view.Overlay and panel.anchor == "centre", "an Overlay at the centre")
    local img = v:image()
    t.ok(near(img, 120, 60, 255, 0, 0), "the panel red right of its hole")
    t.ok(not near(img, 100, 60, 255, 0, 0), "the hole is not filled")
    local hit = v:pick(120, 60)
    t.ok(hit and hit.overlay == true and hit.item == panel.id and hit.point == nil, "a pick on the panel is the overlay")
    hit = v:pick(100, 60)
    t.ok(hit and hit.overlay == false and hit.item == under.id, "a pick in the hole reaches the part")
    -- Moved 30 px right of the centre: the panel and its hole follow.
    panel:move_to(30, 0)
    img = v:image()
    t.ok(near(img, 155, 60, 255, 0, 0) and not near(img, 85, 60, 255, 0, 0), "the panel moved right")
    t.ok(not near(img, 130, 60, 255, 0, 0), "its hole moved with it")
    panel:move_to(0, 0, "centre")
    -- A stroked crosshair of two open profiles, 20 px in from the top left.
    local across = bs.Profile.polyline({ { -8, 0 }, { 8, 0 } })
    local down = bs.Profile.polyline({ { 0, -8 }, { 0, 8 } })
    local cross = v:show_overlay({ across, down }, "top_left", 20, 20, { stroke = "lime", stroke_width = 2 })
    img = v:image()
    t.ok(near(img, 20, 20, 0, 255, 0) and near(img, 26, 20, 0, 255, 0) and near(img, 20, 14, 0, 255, 0), "the crosshair's arms")
    t.ok(not near(img, 25, 25, 0, 255, 0), "between the arms")
    hit = v:pick(26, 21)
    t.ok(hit and hit.overlay and hit.item == cross.id, "a pick on the crosshair")
    -- Text at the top right, its box's corner 4 px in.
    local fps = v:show_overlay_text("FPS 60", "top-right", 4, 4, { size = 14, colour = "white", box = "blue" })
    img = v:image()
    t.ok(near(img, 194, 6, 0, 0, 255) and not near(img, 197, 2, 0, 0, 255), "the text's box hangs from the top-right corner")
    fps:set_text("FPS 120")
    hit = v:pick(194, 6)
    t.ok(hit and hit.overlay and hit.item == fps.id, "a pick on the text")
    -- An image, 2 x 2 yellow pixels drawn 10 x 10, at the bottom left; moved to the bottom right.
    local yellow = string.rep(string.char(255, 255, 0, 255), 4)
    local pic = v:show_overlay_image(yellow, 2, 2, "bottom-left", 4, 4, { draw_width = 10, draw_height = 10 })
    t.ok(near(v:image(), 8, 110, 255, 255, 0), "the image at the bottom left")
    pic:move_to(4, 4, "bottom-right")
    img = v:image()
    t.ok(pic.anchor == "bottom-right" and near(img, 190, 110, 255, 255, 0) and not near(img, 8, 110, 255, 255, 0), "moved to the bottom right")
    pic:move_to(6, 6)
    t.ok(near(v:image(), 188, 108, 255, 255, 0), "moved, the anchor kept")
    -- Order: a green square of order 1 shown first stays over a later blue one of order 0.
    local sq = bs.Profile.rect(20, 20)
    v:show_overlay(sq, "bottom-left", 60, 30, { fill = "lime", order = 1 })
    v:show_overlay(sq, "bottom-left", 65, 30, { fill = "blue" })
    t.ok(near(v:image(), 63, 90, 0, 255, 0), "order 1 over order 0")
    -- An outline only: "none" fills nothing.
    local outline = v:show_overlay(sq, "top", 0, 30, { fill = "none", stroke = "white", stroke_width = 2 })
    img = v:image()
    t.ok(near(img, 110, 30, 255, 255, 255) and not near(img, 100, 30, 255, 255, 255), "an outline, its inside not filled")
    -- Removed: gone, and the part picked there again.
    panel:remove()
    t.ok(not near(v:image(), 120, 60, 255, 0, 0), "a removed overlay draws nothing")
    hit = v:pick(120, 60)
    t.ok(hit and hit.overlay == false, "a removed overlay is not picked")
    outline:remove()
    local fifteen = {}
    for i = 1, 15 do fifteen[i] = 0 end
    t.raises(function() v:show_overlay(fifteen, "top-left", 0, 0) end, "show_overlay: 16 numbers a curve")
    t.raises(function() v:show_overlay(sq, "middle", 0, 0) end, "show_overlay anchor \"middle\"")
    t.raises(function() v:show_overlay(sq, "top-left", 0, 0, { fill = { 1, 0 } }) end, "show_overlay fill: 3 or 4 numbers")
    t.raises(function() cross:move_to(1 / 0, 0) end, "finite")
    t.raises(function() v:show_overlay_image(yellow, 3, 2, "top-left", 0, 0) end, "show_overlay_image: 3 x 2 pixels need 24 bytes")
    v:close()
  end)

  t.test("line colours: a colour read back, an item's curve colour drawn and cleared", function()
    local v = offscreen(64, 48)
    if not v then return end
    v:set_isocurve_colour("#00ff00", true)
    local s = v:isocurve_colour()
    t.ok(s.from_part and s.colour[1] == 0 and s.colour[2] == 1 and s.colour[3] == 0, "isocurve colour round trip")
    t.ok(v:curve_colour().from_part, "curves follow their part by default")
    v:set_edge_colour("#202020")
    t.ok(not v:edge_colour().from_part, "edge colour round trip")
    t.raises(function() v:set_edge_colour(nil) end, "set_edge_colour: a colour")
    local line = v:show_lines({ -0.8, 0, 0, 0.8, 0, 0 }, "red")
    v:standard("top")
    line:frame()
    local function greens()
      local img = v:image()
      local n = 0
      for k = 0, img.width * img.height - 1 do
        local r, g, b = img.rgba[4 * k], img.rgba[4 * k + 1], img.rgba[4 * k + 2]
        if g > 150 and r < 100 and b < 100 then n = n + 1 end
      end
      return n
    end
    t.eq(greens(), 0, "red first")
    line:set_curve_colour("lime")
    t.ok(greens() > 0, "the segment green")
    line:set_curve_colour(nil)
    t.eq(greens(), 0, "nil: the view's colour again")
    v:close()
  end)

  t.test("occluded style: set, read back, a bad dim refused by the library, false restores the default", function()
    local v = offscreen(64, 64)
    if not v then return end
    v:occluded_style{ dash = 10, gap = 5, dim = 0.25, colour = { 0.5, 0.5, 0.5 } }
    local s = v:occluded_style()
    t.ok(s.dash == 10 and s.gap == 5 and math.abs(s.dim - 0.25) < 1e-6 and s.colour[3] == 0.5, "occluded style round trip")
    t.ok(not pcall(function() v:occluded_style{ dim = 1.5 } end), "dim 1.5 refused")
    t.eq(v:occluded_style().dash, 10, "a refused style leaves the last one")
    v:occluded_style{ colour = "#ff0000" }
    t.eq(v:occluded_style().colour[1], 1, "colour text")
    v:occluded_style(false)
    local d = v:occluded_style()
    t.ok(d.colour == nil and d.dash == 6 and d.gap == 4 and math.abs(d.dim - 0.5) < 1e-6, "default")
    v:close()
  end)

  -- ---- view ABI 1.9: the lighting ----

  t.test("lighting is set, read back, and another name is refused before the library", function()
    local state = { lighting = 0 }
    local f = fake(state)
    f.C.cadaclysm_view_set_lighting = function(_, which)
      state.calls[#state.calls + 1] = "set_lighting " .. tonumber(which)
      state.lighting = tonumber(which)
      return true
    end
    f.C.cadaclysm_view_lighting = function()
      state.calls[#state.calls + 1] = "lighting"
      return state.lighting
    end
    view.use(f)
    local v = view.View.new({ width = 8, height = 8 })
    state.calls = {}
    t.eq(v:lighting(), "headlight")
    v:lighting("studio")
    t.eq(v:lighting(), "studio")
    local e = t.raises(function() v:lighting("noon") end, "lighting")
    t.ok(tostring(e):find('lighting "noon": one of headlight, studio', 1, true), tostring(e))
    t.eq(v:lighting(), "studio")
    v:lighting("headlight")
    t.eq(v:lighting(), "headlight")
    t.eq(table.concat(state.calls, ","), "lighting,set_lighting 1,lighting,lighting,set_lighting 0,lighting")
    view._reset()
  end)

  t.test("last_pick reads a landed answer once without waiting: nil, false for nothing hit, the library error", function()
    local state = {}
    local f = fake(state)
    local answers = { "none", { 3, 4, 5, 2, 1 }, { 0, 0, 0, 1, 0 } }
    f.C.cadaclysm_view_pick_result = function(_, out)
      local a = table.remove(answers, 1)
      if a == nil or a == "none" then state.error = "cadaclysm_view_pick_result: no pick result" return false end
      out.item, out.node, out.face, out.clicks, out.has_point = a[1], a[2], a[3], a[4], a[5]
      out.point[0], out.point[1], out.point[2] = 1, 2, 3
      return true
    end
    view.use(f)
    local v = view.View.new({ width = 8, height = 8 })
    local calls = #state.calls
    t.eq(v:last_pick(), nil, "nothing landed yet")
    local hit = v:last_pick()
    t.ok(hit and hit.item == 3 and hit.node == 4 and hit.face == 5 and hit.clicks == 2, "a landed double click")
    t.ok(hit.point and hit.point[1] == 1 and hit.point[2] == 2 and hit.point[3] == 3, "its point")
    t.eq(v:last_pick(), false, "a click on nothing")
    t.eq(v:last_pick(), nil, "each answer is read once")
    state.error = ""
    t.eq(v:last_pick(), nil, "nothing landed, nothing said")
    f.C.cadaclysm_view_pick_result = function() state.error = "boom from pick_result" return false end
    local e = t.raises(function() v:last_pick() end, "boom")
    t.eq(tostring(e), "boom from pick_result", "the library's own message, bare")
    t.eq(#state.calls, calls, "last_pick never asks or draws")
    view._reset()
  end)

  t.test("set_double_click_frames, focus and navigation reach the library with their arguments", function()
    local state = {}
    local f = fake(state)
    local seen, nav = {}, 0
    f.C.cadaclysm_view_set_double_click_frames = function(_, on) seen[#seen + 1] = "dc " .. tostring(on) end
    f.C.cadaclysm_view_focus = function(_, p)
      seen[#seen + 1] = ("focus %g %g %g"):format(p[0], p[1], p[2])
      if p[0] ~= p[0] then state.error = "cadaclysm_view_focus: the point is not finite" return false end
      return true
    end
    f.C.cadaclysm_view_navigation = function() seen[#seen + 1] = "navigation" return nav end
    view.use(f)
    local v = view.View.new({ width = 8, height = 8 })
    v:set_double_click_frames(true)
    v:set_double_click_frames(false)
    v:focus({ 1, -2, 3.5 })
    t.eq(v:navigation(), "orbit")
    nav = 1
    t.eq(v:navigation(), "fly")
    t.eq(table.concat(seen, "; "), "dc true; dc false; focus 1 -2 3.5; navigation; navigation")
    local e = t.raises(function() v:focus({ 0 / 0, 0, 0 }) end, "not finite")
    t.eq(tostring(e), "cadaclysm_view_focus: the point is not finite", "the library's own reason, bare")
    state.error = ""
    local before = #seen
    t.raises(function() v:focus({ 1, 2 }) end, "focus: 3 numbers, not 2")
    t.raises(function() v:focus(nil) end, "focus: 3 numbers, not nil")
    t.raises(function() v:focus("123") end, "focus")
    t.eq(#seen, before, "a refused point reached the library")
    view._reset()
  end)

  local SQUARE = { positions = { -1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0 }, indices = { 0, 1, 2, 0, 2, 3 }, rgb = { 1, 0, 0 } }

  -- The square from the top, zoomed out so a framing visibly changes the picture.
  local function framed_square()
    local v = offscreen(64, 48)
    if not v then return nil end
    v:layer("grid", false)
    local item = v:show_mesh(SQUARE)
    v:standard("top")
    v:frame()
    v:zoom(-3)
    v:draw()
    return v, item
  end

  -- Down, up, down, up at one pixel within the double-click time.
  local function double_click(v, x, y)
    for _, e in ipairs({ { 0, "pointer_down" }, { 10, "pointer_up" }, { 60, "pointer_down" }, { 70, "pointer_up" } }) do
      v:input({ type = e[2], x = x, y = y, time_ms = 1000 + e[1] })
    end
  end

  -- The answer an input asked for, read through last_pick as the view's draws land it: drawn
  -- for up to ten seconds of wall time (a loaded machine lands it late; a count of draws alone
  -- can run out in milliseconds). false for a click on nothing.
  local function land(v)
    local deadline = os.time() + 10
    while os.time() <= deadline do
      v:draw()
      local answer = v:last_pick()
      if answer ~= nil then return answer end
    end
    error("the pick never landed", 0)
  end

  t.test("a double click answers clicks 2 with its point and leaves the picture (real library)", function()
    local v, item = framed_square()
    if not v then return end
    local before = v:image()
    t.eq(v:last_pick(), nil, "nothing clicked yet")
    double_click(v, 32, 24)
    local hit = land(v)
    t.ok(hit and hit.item == item.id and hit.clicks == 2, "a double click's answer")
    t.ok(hit.point and math.abs(hit.point[3]) < 1e-3 and math.abs(hit.point[1]) < 0.2, "the square's centre, z 0")
    t.eq(changed(before, v:image()), 0, "a double click moves nothing by default")
    t.eq(v:last_pick(), nil, "each answer is read once")
    -- One click on the background, well after: landed, with nothing hit.
    v:input({ type = "pointer_down", x = 1, y = 1, time_ms = 5000 })
    v:input({ type = "pointer_up", x = 1, y = 1, time_ms = 5010 })
    t.eq(land(v), false, "a click on the background")
    v:close()
  end)

  t.test("set_double_click_frames(true) makes the same double click frame (real library)", function()
    local v = framed_square()
    if not v then return end
    local before = v:image()
    v:set_double_click_frames(true)
    double_click(v, 32, 24)
    local hit = land(v)
    t.ok(hit and hit.clicks == 2, "opted in: still a pick of clicks 2")
    t.ok(changed(before, v:image()) > 0, "opted in, the double click framed what it hit")
    v:close()
  end)

  t.test("navigation is fly after a fly key, Tab toggles it, focus leaves it (real library)", function()
    local v = offscreen(64, 48)
    if not v then return end
    local function key(k) v:input({ type = "key", key = k, key_down = true }) v:input({ type = "key", key = k, key_down = false }) end
    t.eq(v:navigation(), "orbit")
    key("KeyW")
    t.eq(v:navigation(), "fly", "the mode outlives the key")
    key("Tab")
    t.eq(v:navigation(), "orbit")
    key("KeyW")
    v:focus({ 1, 2, 3 })
    t.eq(v:navigation(), "orbit", "focus leaves fly mode")
    v:close()
  end)

  t.test("focus moves the orbit point and focus back restores the picture (real library)", function()
    local v = framed_square()
    if not v then return end
    local before = v:image()
    t.ok(math.abs(v:pick(32, 24).point[1]) < 0.2, "the centre looks at the middle of the square")
    v:focus({ 0.5, 0, 0 })
    local hit = v:pick(32, 24)
    t.ok(hit and hit.point and math.abs(hit.point[1] - 0.5) < 0.1, "the centre now looks at x = 0.5")
    t.ok(changed(before, v:image()) > 0, "the picture moved")
    v:focus({ 0, 0, 0 })
    t.eq(changed(before, v:image()), 0, "focus back restores it")
    t.raises(function() v:focus({ 0 / 0, 0, 0 }) end, "cadaclysm_view_focus")
    v:close()
  end)

  -- ---- view ABI 1.22: snapping ---------------------------------------------------------------

  t.test("set_snap hands the library the kinds' bits and refuses an unknown name before it; snap, last_snap, clear_snap and set_work_plane reach it", function()
    local state = {}
    local f = fake(state)
    local seen, answers = {}, {}
    local function draws()
      local n = 0
      for _, c in ipairs(state.calls) do if c == "draw" then n = n + 1 end end
      return n
    end
    f.C.cadaclysm_view_set_snap = function(_, s)
      seen[#seen + 1] = ("settings %d %d %g %d"):format(s.size, s.kinds, s.aperture_px, s.marker)
      return true
    end
    -- A call that succeeds clears the last error, as the real library's do.
    f.C.cadaclysm_view_request_snap_in = function(_, vp, x, y) state.error = "" seen[#seen + 1] = ("request %d %d %d"):format(vp, x, y) end
    f.C.cadaclysm_view_snap_result = function(_, out)
      local a = table.remove(answers, 1)
      if a == nil or a == "none" then state.error = "cadaclysm_view_snap_result: no snap result" return false end
      state.error = ""
      out.kind, out.item, out.node, out.face, out.edge, out.clicks = a[1], a[2] or 0, 0, 4, a[3], a[4] or 0
      out.point[0], out.point[1], out.point[2] = 1, 2, 3
      out.radius, out.distance_px = 0.5, 2.5
      return true
    end
    f.C.cadaclysm_view_clear_snap = function() state.error = "" seen[#seen + 1] = "clear" end
    f.C.cadaclysm_view_set_work_plane = function(_, o, x, n, step)
      seen[#seen + 1] = ("plane %g %g %g / %g %g %g / %g %g %g / %g"):format(o[0], o[1], o[2], x[0], x[1], x[2], n[0], n[1], n[2], step)
      return true
    end
    f.C.cadaclysm_view_clear_work_plane = function() seen[#seen + 1] = "no plane" return true end
    view.use(f)
    local v = view.View.new({ width = 8, height = 8 })

    v:set_snap()
    v:set_snap({ "vertex", "edge" }, { aperture_px = 6, marker = false })
    v:set_snap("face")
    v:set_snap(false)
    t.eq(table.concat(seen, "; "), "settings 16 255 0 1; settings 16 17 6 0; settings 16 32 0 1; settings 16 0 0 1")
    local before = #seen
    local e = t.raises(function() v:set_snap({ "vertex", "corner" }) end, "snap kind")
    t.ok(is_view_error(e))
    t.eq(tostring(e), 'snap kind "corner": one of vertex, midpoint, centre, quadrant, edge, face, grid, plane')
    t.eq(#seen, before, "refused before the library")

    answers = { "none", "none", { 1, 3, 7 } }
    local s = v:snap(10, 20)
    t.ok(s and s.kind == "vertex" and s.item == 3 and s.face == 4 and s.edge == 7 and s.clicks == 0, "the answer was not read")
    t.ok(s.point[1] == 1 and s.point[2] == 2 and s.point[3] == 3 and s.radius == 0.5 and s.distance_px == 2.5, "its point, radius, distance")
    t.eq(seen[#seen], "request 0 10 20")
    t.eq(draws(), 4, "drawn first (never drawn), then once a wait")
    answers = { { 32, 3, 0xFFFFFFFF } }
    t.eq(v:snap(1, 1, 2).edge, nil, "a face snap has no edge")
    t.eq(seen[#seen], "request 2 1 1")
    answers = { { 0, 0, 0xFFFFFFFF } }
    t.eq(v:snap(0, 0), nil, "kind 0: nothing snapped")

    local calls, asked = draws(), #seen
    answers = { "none", { 2, 5, 1, 1 }, { 0, 0, 0xFFFFFFFF } }
    t.eq(v:last_snap(), nil, "nothing landed yet")
    local m = v:last_snap()
    t.ok(m and m.kind == "midpoint" and m.item == 5 and m.edge == 1 and m.clicks == 1, "a landed click's snap")
    t.eq(v:last_snap(), false, "a snap that found nothing")
    t.eq(v:last_snap(), nil, "each answer is read once")
    t.eq(draws(), calls, "last_snap never draws")
    t.eq(#seen, asked, "last_snap never asks")

    f.C.cadaclysm_view_snap_result = function() state.error = "cadaclysm_view_snap_result: the device was lost" return false end
    e = t.raises(function() v:snap(1, 1) end, "device was lost")
    t.eq(tostring(e), "cadaclysm_view_snap_result: the device was lost", "the library's own reason, bare, at once")
    t.raises(function() v:last_snap() end, "device was lost")
    state.error = ""

    v:clear_snap()
    v:set_work_plane({ 1, 2, 3 }, { 1, 0, 0 }, { 0, 0, 1 }, 0.5)
    v:set_work_plane({ 0, 0, 0 })
    v:set_work_plane(nil)
    t.eq(table.concat(seen, "; ", #seen - 3), "clear; plane 1 2 3 / 1 0 0 / 0 0 1 / 0.5; plane 0 0 0 / 1 0 0 / 0 0 1 / 0; no plane")
    t.raises(function() v:set_work_plane({ 1, 2 }) end, "set_work_plane origin: 3 numbers, not 2")
    v:close()
    view._reset()
  end)

  -- The square with its four edges, framed from the top. Not zoomed out: the test aims a few
  -- pixels inside a corner.
  local SQUARE_EDGES = { -1, -1, 0, 1, -1, 0, 1, -1, 0, 1, 1, 0, 1, 1, 0, -1, 1, 0, -1, 1, 0, -1, -1, 0 }
  local function edged_square()
    local v = offscreen(64, 48)
    if not v then return nil end
    v:layer("grid", false)
    local item = v:show_mesh({ positions = SQUARE.positions, indices = SQUARE.indices, rgb = { 1, 0, 0 }, edges = SQUARE_EDGES })
    v:standard("top")
    v:frame()
    return v, item
  end

  t.test("a snap on the real library finds the square's corner", function()
    local v, item = edged_square()
    if not v then return end
    v:set_snap()
    local img = v:image()
    -- The topmost pixel that is not the background, the leftmost of its row: the top left corner.
    local r0, g0, b0 = pixel(img, 0, 0)
    local cx, cy
    for y = 0, img.height - 1 do
      for x = 0, img.width - 1 do
        local r, g, b = pixel(img, x, y)
        if r ~= r0 or g ~= g0 or b ~= b0 then cx, cy = x, y break end
      end
      if cx then break end
    end
    t.ok(cx, "the square drew nothing")
    local s = v:snap(cx + 3, cy + 3)
    t.ok(s and s.kind == "vertex" and s.item == item.id, "a snap inside the corner: " .. tostring(s and s.kind))
    t.ok(math.abs(s.point[1] + 1) < 1e-6 and math.abs(s.point[2] - 1) < 1e-6 and math.abs(s.point[3]) < 1e-6,
      ("the corner (-1, 1, 0), in the shown coordinates: %g %g %g"):format(s.point[1], s.point[2], s.point[3]))
    t.ok(s.edge ~= nil and s.clicks == 0, "a vertex lies on an edge; snap's own answer is clicks 0")
    v:clear_snap()
    v:close()
  end)

  t.test("snapping is off until set_snap on the real library; false switches it off; an unknown kind is refused", function()
    local v = edged_square()
    if not v then return end
    t.eq(v:snap(32, 24), nil, "a view starts with snapping off")
    v:set_snap("face")
    local s = v:snap(32, 24)
    t.ok(s and s.kind == "face", "a face snap at the centre")
    v:set_snap(false)
    t.eq(v:snap(32, 24), nil, "false switches snapping off")
    local e = t.raises(function() v:set_snap({ "vertex", "corner" }) end, "snap kind")
    t.ok(tostring(e):find('snap kind "corner": one of vertex, midpoint', 1, true), tostring(e))
    v:close()
  end)

  -- ---- the machining view and the timeline (1.7) ---------------------------------------------

  -- A fake that answers the fourteen machining and timeline calls and notes what it was handed.
  -- `state`: machining_id (default 7), ok (default true), error, status_lines (default one line).
  local function machining_fake(state)
    local lib = fake(state)
    local C = lib.C
    local seen = { calls = {}, shows = 0, asked = 0, heights_capacity = nil }
    state.seen = seen
    local function ok_(name, f)
      C[name] = function(...)
        seen.calls[#seen.calls + 1] = name
        if f then f(...) end
        return state.ok ~= false
      end
    end
    C.cadaclysm_view_show_machining = function(_, m)
      seen.shows = seen.shows + 1
      seen.size, seen.program_count = m.size, m.program_count
      seen.programs = {}
      for k = 0, tonumber(m.program_count) - 1 do
        local p = m.programs[k]
        seen.programs[k + 1] = { p.size, p.tool_number, p.tool_shape, p.tool_diameter, p.tool_flute_length,
          p.tool_angle, p.tool_corner_radius, ffi.string(p.gcode) }
      end
      seen.stock = { m.stock_min[0], m.stock_min[1], m.stock_min[2], m.stock_max[0], m.stock_max[1], m.stock_max[2] }
      seen.part = { tonumber(m.part_vertex_count), tonumber(m.part_index_count) }
      seen.cell, seen.tolerance, seen.skin, seen.skin_set, seen.rapid_rate = m.cell, m.tolerance, m.skin, m.skin_set, m.rapid_rate
      if state.machining_id == 0 then return 0 end
      return state.machining_id or 7
    end
    ok_("cadaclysm_view_machining_seek", function(_, id, to) seen.seek = { id, to } end)
    ok_("cadaclysm_view_machining_colour_by", function(_, id, mode) seen.colour_by = { id, mode } end)
    ok_("cadaclysm_view_machining_overlays", function(_, id, path, tool) seen.overlays = { id, path, tool } end)
    ok_("cadaclysm_view_machining_info", function(_, id, out)
      seen.info_size = out.size
      out.moves, out.move, out.nx, out.ny, out.cell = 9, 3, 4, 2, 0.5
      out.min[0], out.min[1], out.cycle_time = -1, -2, 12.5
    end)
    ok_("cadaclysm_view_machining_heights", function(_, id, z, capacity)
      seen.heights_capacity = tonumber(capacity)
      for k = 0, tonumber(capacity) - 1 do z[k] = k end
    end)
    ok_("cadaclysm_view_timeline_play", function(_, speed) seen.play = speed end)
    ok_("cadaclysm_view_timeline_pause")
    ok_("cadaclysm_view_timeline_seek", function(_, s) seen.seek_time = s end)
    ok_("cadaclysm_view_timeline_set_loop", function(_, on) seen.loop = on end)
    ok_("cadaclysm_view_remove")
    ok_("cadaclysm_view_set_colour", function(_, id, c) seen.colour = { id, c[0], c[1], c[2] } end)
    C.cadaclysm_view_timeline_time = function() return 1.5 end
    C.cadaclysm_view_timeline_duration = function() return 12.5 end
    C.cadaclysm_view_timeline_playing = function() return true end
    C.cadaclysm_view_timeline_status = function(_, buf, capacity)
      local lines = state.status_lines or { "move 3 of 9 \xC2\xB7 T1 flat 6 mm" }
      seen.asked = seen.asked + 1
      local line = lines[math.min(seen.asked, #lines)]
      capacity = tonumber(capacity)
      if buf ~= nil and capacity > 0 then
        local room = math.min(#line, capacity - 1)
        ffi.copy(buf, line, room)
        buf[room] = 0
      end
      return #line
    end
    return lib
  end

  local function machining_view(state)
    local lib = machining_fake(state or {})
    view.use(lib)
    local v = view.View.new({ width = 8, height = 8 })
    return v, lib
  end

  local FLAT = { number = 1, shape = "flat", diameter = 6, flute_length = 20 }
  local VBIT = { number = 3, shape = "vbit", diameter = 6, angle = 60 }
  local BOX = { { -1, -2, 0 }, { 1, 2, 3 } }

  t.test("show_machining hands the library the programs, the stock, the part and the options (F1)", function()
    local state = {}
    local v = machining_view(state)
    local m = v:show_machining({ { FLAT, "G0 X0\n" }, { VBIT, "G0 X1\n" } }, BOX,
      { positions = { 0, 0, 0, 1, 0, 0, 0, 1, 0 }, indices = { 0, 1, 2 } }, { cell = 0.25, skin = 0 })
    local s = state.seen
    t.eq(s.program_count, 2)
    t.eq(s.size, 128)
    local want = { { 56, 1, 0, 6, 20, 0, 0, "G0 X0\n" }, { 56, 3, 3, 6, 0, 60, 0, "G0 X1\n" } }
    for k = 1, 2 do for f = 1, 8 do t.eq(s.programs[k][f], want[k][f], ("program %d field %d"):format(k, f)) end end
    for k, x in ipairs({ -1, -2, 0, 1, 2, 3 }) do t.eq(s.stock[k], x) end
    t.eq(s.part[1], 3); t.eq(s.part[2], 3)
    t.eq(s.cell, 0.25); t.eq(s.tolerance, 0); t.eq(s.skin_set, 1); t.eq(s.skin, 0); t.eq(s.rapid_rate, 0)
    t.eq(m.id, 7)
    t.eq(v._items[7], m, "the view's item table holds the Machining")
    t.eq(getmetatable(m), view.Machining)
    m:remove()
    t.eq(v._items[7], nil)
    v:close()
  end)

  t.test("show_machining with no part and no options leaves every default to the library (F2)", function()
    local state = {}
    local v = machining_view(state)
    v:show_machining({ { FLAT, "G0 X0\n" } }, BOX)
    local s = state.seen
    t.eq(s.skin_set, 0); t.eq(s.part[1], 0); t.eq(s.part[2], 0)
    t.eq(s.cell, 0); t.eq(s.tolerance, 0); t.eq(s.rapid_rate, 0)
    v:close()
  end)

  t.test("show_machining and colour_by refuse what Python refuses, before the library (F3)", function()
    local state = {}
    local v = machining_view(state)
    local function bad(what, fn, message)
      local err = t.raises(fn, message)
      t.ok(is_view_error(err), what .. ": not a ViewError: " .. tostring(err))
    end
    local function show(tool, part, options, gcode, box)
      return function() v:show_machining({ { tool, gcode or "G0" } }, box or BOX, part, options) end
    end
    bad("missing fields", show({ number = 1, shape = "flat" }), "tool needs number, shape and diameter")
    bad("negative", show({ number = -1, shape = "flat", diameter = 6 }), "tool number %-1 is negative")
    bad("fractional", show({ number = 1.5, shape = "flat", diameter = 6 }), "whole number")
    bad("shape", show({ number = 1, shape = "spade", diameter = 6 }), "shape 'spade': one of flat, ball, drill, vbit, bullnose")
    bad("shape _list", show({ number = 1, shape = "_list", diameter = 6 }), "one of flat, ball")
    bad("nan diameter", show({ number = 1, shape = "flat", diameter = 0 / 0 }), "finite")
    bad("positions", show(FLAT, { positions = { 0, 0, 0, 1 }, indices = {} }), "part positions: 4 numbers is not a whole number of x y z triples")
    bad("indices", show(FLAT, { positions = { 0, 0, 0 }, indices = { 0, 0 } }), "part indices: 2 is not a whole number of triangles")
    bad("negative index", show(FLAT, { positions = { 0, 0, 0 }, indices = { 0, 0, -1 } }), "part indices must not be negative")
    bad("fractional index", show(FLAT, { positions = { 0, 0, 0 }, indices = { 0, 0, 0.5 } }), "part indices must be whole numbers")
    bad("past", show(FLAT, { positions = { 0, 0, 0, 1, 0, 0, 0, 1, 0 }, indices = { 0, 1, 3 } }), "part indices: 3 is past the last of 3 vertices")
    bad("nan position", show(FLAT, { positions = { 0, 0, 0 / 0 }, indices = {} }), "finite")
    bad("nan cell", show(FLAT, nil, { cell = 0 / 0 }), "finite")
    bad("nan stock", show(FLAT, nil, nil, "G0", { { 0, 0, 0 / 0 }, { 1, 1, 1 } }), "finite")
    bad("stock", show(FLAT, nil, nil, "G0", { { 0, 0 }, { 1, 1, 1 } }), "three numbers")
    t.eq(state.seen.shows, 0, "the library was never asked")
    local m = v:show_machining({ { FLAT, "G0" } }, BOX)
    bad("mode", function() m:colour_by("rainbow") end, "mode 'rainbow': one of height, tool, deviation")
    bad("mode _list", function() m:colour_by("_list") end, "one of height, tool, deviation")
    bad("seek_move negative", function() m:seek_move(-1) end, "seek_move")
    bad("seek_move fractional", function() m:seek_move(1.5) end, "seek_move")
    bad("seek nan", function() v:seek(0 / 0) end, "finite")
    bad("play inf", function() v:play(math.huge) end, "finite")
    v:close()
    bad("closed", function() m:colour_by("tool") end, "the view is closed")
  end)

  t.test("the transport and the machining's own calls reach the library as typed (F4)", function()
    local state = {}
    local v = machining_view(state)
    local s = state.seen
    local m = v:show_machining({ { FLAT, "G0" } }, BOX)
    v:play(4); t.eq(s.play, 4)
    v:play(); t.eq(s.play, 1)
    v:pause(); t.eq(s.calls[#s.calls], "cadaclysm_view_timeline_pause")
    v:seek(2.0); t.eq(s.seek_time, 2.0)
    v:loop(); t.eq(s.loop, true)
    v:loop(false); t.eq(s.loop, false)
    m:seek_move(3); t.eq(s.seek[1], 7); t.eq(s.seek[2], 3)
    m:colour_by("tool"); t.eq(s.colour_by[2], 1)
    m:colour_by("height"); t.eq(s.colour_by[2], 0)
    m:colour_by("deviation"); t.eq(s.colour_by[2], 2)
    m:overlays(false); t.eq(s.overlays[1], 7); t.eq(s.overlays[2], false); t.eq(s.overlays[3], true)
    m:overlays(); t.eq(s.overlays[2], true); t.eq(s.overlays[3], true)
    t.eq(v:time(), 1.5); t.eq(v:duration(), 12.5); t.eq(v:playing(), true)
    local lines = v:status()
    t.eq(#lines, 1); t.eq(lines[1], "move 3 of 9 \xC2\xB7 T1 flat 6 mm")
    local info = m:info()
    t.eq(s.info_size, ffi.sizeof("CadaclysmViewMachiningInfo"))
    t.eq(info.moves, 9); t.eq(info.move, 3); t.eq(info.nx, 4); t.eq(info.ny, 2); t.eq(info.cell, 0.5)
    t.eq(info.min[1], -1); t.eq(info.min[2], -2); t.eq(info.cycle_time, 12.5)
    local z = m:heights()
    t.eq(s.heights_capacity, 8); t.eq(#z, 8); t.eq(z[1 * 4 + 0 + 1], 4)
    -- Item members still work on a Machining
    m:colour({ 1, 0, 0 }); t.eq(s.colour[1], 7); t.eq(s.colour[2], 1)
    m:remove()
    v:close()
  end)

  t.test("status asks again when the line grew, and is empty with no tracks (F5)", function()
    local state = { status_lines = { "move 9 of 9", "move 10 of 10 \xC2\xB7 longer" } }
    local v = machining_view(state)
    local lines = v:status()
    t.eq(#lines, 1); t.eq(lines[1], "move 10 of 10 \xC2\xB7 longer")
    t.eq(state.seen.asked, 3)
    v:close()
    local empty = {}
    empty.status_lines = { "" }
    local w = machining_view(empty)
    t.eq(#w:status(), 0)
    w:close()
    local emptied = { status_lines = { "move 9 of 9", "" } }   -- the line emptied between the two calls
    local e = machining_view(emptied)
    t.eq(#e:status(), 0); t.eq(emptied.seen.asked, 2)
    e:close()
  end)

  t.test("a library refusal is the library's words (F6)", function()
    local state = { machining_id = 0, error = "cadaclysm_view_show_machining: a machining needs at least one program (program_count is 0)" }
    local v = machining_view(state)
    local err = t.raises(function() v:show_machining({ { FLAT, "G0" } }, BOX) end, "a machining needs at least one program %(program_count is 0%)")
    t.eq(err.message, state.error)
    v:close()
    local state2 = {}
    local w = machining_view(state2)
    local m = w:show_machining({ { FLAT, "G0" } }, BOX)
    state2.ok, state2.error = false, "cadaclysm_view_machining_seek: no machining 9 is shown"
    local err2 = t.raises(function() m:seek_move(3) end, "no machining 9 is shown")
    t.eq(err2.message, state2.error)
    w:close()
  end)

  -- web/test/machining-selftest.js's rule, as Python's _compare_at_walls: failed, excused, walls.
  local function compare_at_walls(gpu, oracle, nx, ny)   -- gpu: 1-based table; oracle: 0-based float*
    local failed, excused, walls = 0, 0, 0
    for j = 0, ny - 1 do
      for i = 0, nx - 1 do
        local lo, hi = math.huge, -math.huge
        for b = math.max(0, j - 1), math.min(ny - 1, j + 1) do
          for a = math.max(0, i - 1), math.min(nx - 1, i + 1) do
            local o = oracle[b * nx + a]
            if o < lo then lo = o end
            if o > hi then hi = o end
          end
        end
        local wall = hi - lo > 0.5
        if wall then walls = walls + 1 end
        local g = gpu[j * nx + i + 1]
        if math.abs(g - oracle[j * nx + i]) > 2e-3 then
          local near = false
          if wall then
            for b = math.max(0, j - 1), math.min(ny - 1, j + 1) do
              for a = math.max(0, i - 1), math.min(nx - 1, i + 1) do
                if math.abs(oracle[b * nx + a] - g) <= 2e-3 then near = true end
              end
            end
          end
          if near then excused = excused + 1 else failed = failed + 1 end
        end
      end
    end
    return failed, excused, walls
  end

  local function read_all(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    return data
  end

  -- The plate job of web/test/fixtures/machining-plate/job.json: programs program-0.gcode (T1 flat 6 mm,
  -- flute 20) and program-1.gcode (T2 drill 6 mm, flute 30), stock (-42, -27, 0)-(42, 27, 14), cell 0.5,
  -- rapid_rate 5000. Nil in an SDK checkout without the fixture (a case then says "skip").
  local function plate()
    local first = t.fixture("web/test/fixtures/machining-plate/program-0.gcode")
    if first == nil then
      print("  skip: no machining-plate fixture")
      return nil
    end
    local dir = first:match("^(.*)/[^/]+$")
    return {
      dir = dir,
      programs = {
        { { number = 1, shape = "flat", diameter = 6, flute_length = 20 }, read_all(first) },
        { { number = 2, shape = "drill", diameter = 6, flute_length = 30 }, read_all(dir .. "/program-1.gcode") },
      },
      box = { { -42, -27, 0 }, { 42, 27, 14 } },
      options = { cell = 0.5, rapid_rate = 5000 },
    }
  end

  t.test("the plate plays to the fixture's heights offscreen (F7, real library)", function()
    local job = plate()
    if not job then return end
    local v = offscreen(64, 48)
    if not v then return end
    local m = v:show_machining(job.programs, job.box, nil, job.options)
    t.ok(math.abs(v:duration() - 893.247024) < 1e-3, "duration " .. v:duration())
    local info = m:info()
    t.ok(info.moves > 0)
    m:seek_move(info.moves)
    local gpu = m:heights()
    local data = read_all(job.dir .. "/heights.bin")
    local header = ffi.cast("const uint32_t *", data)
    local nx, ny = tonumber(header[2]), tonumber(header[3])
    t.eq(info.nx, nx); t.eq(info.ny, ny); t.eq(#gpu, nx * ny)
    local oracle = ffi.cast("const float *", ffi.cast("const char *", data) + 28)
    local failed, excused, walls = compare_at_walls(gpu, oracle, nx, ny)
    t.ok(failed == 0 and excused <= math.max(4, math.floor(walls / 100)),
      ("failed %d, excused %d, walls %d"):format(failed, excused, walls))
    v:draw()
    t.ok(v:status()[1]:find("^move " .. info.moves .. " of " .. info.moves) ~= nil, v:status()[1])
    m:remove()
    v:close()
  end)

  t.test("every transport and machining call runs on the real library (F7b)", function()
    local job = plate()
    if not job then return end
    local v = offscreen(64, 48)
    if not v then return end
    local m = v:show_machining(job.programs, job.box, nil, job.options)
    local duration = v:duration()
    t.eq(v:playing(), false)
    v:play(2); t.eq(v:playing(), true)
    v:pause(); t.eq(v:playing(), false)
    v:seek(10); v:draw(); t.ok(math.abs(v:time() - 10) < 1e-6, "time " .. v:time())
    v:seek(duration + 100); v:draw(); t.ok(math.abs(v:time() - duration) < 1e-6, "clamped " .. v:time())
    v:loop(); v:loop(false)
    t.eq(#v:status() > 0, true)
    m:colour_by("tool"); m:colour_by("height")
    local err = t.raises(function() m:colour_by("deviation") end, "cadaclysm_view_machining_colour_by")
    t.ok(is_view_error(err), "deviation needs a part")
    m:overlays(false, false); m:overlays()
    v:draw()
    m:remove()
    local part = { positions = { -42, -27, 14, 42, -27, 14, 0, 27, 14 }, indices = { 0, 1, 2 } }
    local with_part = v:show_machining(job.programs, job.box, part, job.options)
    with_part:colour_by("deviation")
    v:draw()
    with_part:remove()
    v:close()
  end)
end
