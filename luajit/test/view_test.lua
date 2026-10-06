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
  t.test("an offscreen view draws a solid by handle, removes it, and refuses once closed", function()
    local v = offscreen(160, 120)
    if not v then return end
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
end
