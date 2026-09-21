-- The kernel wrapper's tests: the Node.js suite (node/test/blacksmith.test.js)
-- ported, plus what only a borrowing binding has to prove -- the stale-view rule,
-- views keeping their solid alive, and callbacks that raise.
local bs = require("cadaclysm_blacksmith")

local XY = { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 }
local pi = math.pi

local function plate_outline()
  return bs.Profile.rect(80, 40):with_hole(bs.Profile.circle(4)):with_hole(bs.Profile.slot({ 25, 0 }, 24, 5))
end

local function all_near(a, b, tolerance)
  if #a ~= #b then return false end
  for i = 1, #a do
    if math.abs(a[i] - b[i]) > (tolerance or 1e-9) then return false end
  end
  return true
end

local function same(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

local function count_faces(solid, kind)
  local out = {}
  for i = 0, solid.faces - 1 do
    if solid:face_kind(i) == kind then out[#out + 1] = i end
  end
  return out
end

local function is_build_error(e)
  return type(e) == "table" and getmetatable(e) == bs.BuildError
end

return function(t)
  local SCHEMA_AP203 = t.fixture("schemas/ap203.exp")

  t.test("the library loads, and every entry point resolves", function()
    local path = bs.library_path()
    t.ok(io.open(path, "rb"), "library_path names a file: " .. path)
    t.ok(bs.version():match("^%d+%.%d+%.%d+"), "version " .. bs.version())
    t.ok(bs.build_date():match("^%d%d%d%d%-%d%d%-%d%d$"), "build date " .. bs.build_date())
    t.eq(type(bs.license_info()), "string")
    t.ok(bs.license_info() ~= "")
    t.ok(bs.license_notice_count() >= 0)
    t.eq(bs.load(path), bs)
    t.ok(bs.brep_layout_id() ~= "")
    local e = t.raises(function() bs.license("garbage") end)
    t.ok(is_build_error(e), "license refuses with a BuildError")
    if SCHEMA_AP203 then t.eq(bs.default_schema(), SCHEMA_AP203) end
    t.eq(bs.NONE, 0xFFFFFFFF)
    t.eq(bs.UNITS.mm, 1)
    t.eq(bs.Axis.Z, 2)
  end)

  t.test("a BuildError is a table carrying the library's own text", function()
    local e = t.raises(function() bs.Profile.rect(0, 1) end)
    t.ok(is_build_error(e))
    t.ok(e.message:find("profile_rect: width and height must be positive", 1, true), e.message)
    t.eq(tostring(e), e.message)
  end)

  t.test("profiles and paths build, and a bad one raises the library reason", function()
    t.eq(getmetatable(plate_outline()), bs.Profile)
    t.eq(getmetatable(bs.Profile.polygon({ { 0, 0 }, { 10, 0 }, { 0, 10 } })), bs.Profile)
    local rounded = bs.Profile.path({ 0, 0 }):line_to(10, 0):line_to(10, 8):arc_to(8, 10, { 8, 8 }, true)
      :line_to(0, 10):line_to(0, 0):end_()
    t.eq(getmetatable(rounded), bs.Profile)
    local p = bs.Profile.path({ 0, 0 }):line_to(5, 0)
    p:end_open()
    t.raises(function() p:line_to(1, 1) end, "path: already ended")
    local builder = bs.Profile.path({ 0, 0 }):line_to(10, 0):bezier_to({ 12, 2 }, { 12, 8 }, { 10, 10 })
      :line_to(0, 10):line_to(0, 0)
    local curvy = builder["end"](builder)   -- `end` is a keyword: the method by its name
    t.eq(getmetatable(curvy), bs.Profile)
    t.raises(function() builder:end_() end, "path: already ended")
    t.eq(getmetatable(bs.Profile.circle(3):translate(5, 5)), bs.Profile)
    t.eq(getmetatable(bs.Path({ 0, 0 })), bs.Path, "Path(start) constructs")
    -- A NURBS segment: a quadratic arc-like piece, then closed.
    local nurbs = bs.Profile.path({ 0, 0 }):nurbs_to({ { 5, 5 }, { 10, 0 } }, { 0, 0, 0, 1, 1, 1 }, 2, { 1, 0.7, 1 })
      :line_to(0, 0):end_()
    t.eq(bs.Solid.extrude(nurbs, XY, 1).faces, 4)
  end)

  t.test("an abandoned Path does not wedge the library, and end/end_open are one-shot", function()
    bs.Profile.path({ 0, 0 }):line_to(1, 1)   -- dropped: only the collector frees it
    local closed = bs.Profile.path({ 0, 0 }):line_to(1, 0):line_to(1, 1):line_to(0, 1):line_to(0, 0):end_()
    t.eq(getmetatable(closed), bs.Profile)
    local open = bs.Profile.path({ 0, 0 }):line_to(5, 0)
    open:end_open()
    t.raises(function() open:end_() end, "path: already ended")
    for _ = 1, 1000 do
      bs.Profile.path({ 0, 0 }):line_to(1, 0):line_to(1, 1):line_to(0, 1):line_to(0, 0):end_()
    end
    collectgarbage()
    collectgarbage()
    t.eq(getmetatable(bs.Profile.rect(1, 1)), bs.Profile)
  end)

  t.test("solids build, transform, combine, mesh, bound and write STEP", function()
    local plate = bs.Solid.extrude(plate_outline(), XY, 6)
    t.eq(plate.faces, 12)
    t.eq(plate:face_kind(0), "plane")
    local lo, hi = plate.bounds[1], plate.bounds[2]
    t.near(hi[1] - lo[1], 80, 1e-6)
    t.near(hi[3] - lo[3], 6, 1e-6)
    local positions, normals, indices = plate:mesh(0.05)
    t.eq(positions.dtype, "float32")
    t.eq(indices.dtype, "uint32")
    t.eq(positions.shape[2], 3)
    t.eq(normals.shape[1], positions.shape[1])
    t.eq(indices.size % 3, 0)
    t.ok(indices.size > 0)
    local runs = plate:edge_polylines(0.05)
    t.ok(#runs > 0)
    for _, r in ipairs(runs) do
      t.eq(r.shape[2], 3)
      t.eq(r.size % 3, 0)
    end
    for _, s in ipairs({ bs.Solid.cuboid(1, 2, 3), bs.Solid.cylinder(1, 2), bs.Solid.cone(1, 2), bs.Solid.sphere(1),
      bs.Solid.torus(3, 1), bs.Solid.wedge(2, 2, 2, 1) }) do
      t.ok(s.faces > 0)
      s:close()
    end
    t.ok(is_build_error(t.raises(function() bs.Solid.cuboid(-1, 1, 1) end)))
    local pin = bs.Solid.cylinder(4, 10):translate(0, 0, 6):rotate({ { 0, 0, 0 }, { 0, 0, 1 } }, 0.1):place(XY):mirror(XY)
    t.ok(pin.faces > 0)
    local phases = {}
    local part = plate:join(bs.Solid.cuboid(6, 6, 20):translate(30, 10, -5), 0.05,
      function(phase, done, total) phases[#phases + 1] = { phase, done, total } end)
    t.ok(part.faces > plate.faces)
    t.ok(#phases > 0 and type(phases[1][1]) == "string" and type(phases[1][2]) == "number")
    t.ok(plate:join(bs.Solid.cylinder(3, 20):translate(30, 10, -5), 0.05).faces > plate.faces)
    t.ok(plate:cut(bs.Solid.cylinder(3, 20):translate(30, 10, -5)).faces > 0)
    t.ok(plate:common(bs.Solid.cuboid(20, 20, 20)).faces > 0)
    local text = part:step_text(SCHEMA_AP203, "mm")
    t.ok(text:match("^ISO%-10303%-21;"), "STEP text")
    t.raises(function() part:step_text(SCHEMA_AP203, "furlong") end, "unit must be one of")
    local stp = t.tmp("part.stp")
    part:step(stp, SCHEMA_AP203)
    local f = assert(io.open(stp, "rb"))
    t.ok(f:read("*a"):match("^ISO%-10303%-21;"))
    f:close()
    local two = t.tmp("two.stp")
    -- The mirrored pin sits on a left-handed frame; the writer bakes the mirror into
    -- the geometry instead of refusing it (faec26ef), so it writes like the upright one.
    bs.write_step(two, { plate, pin }, SCHEMA_AP203)
    f = assert(io.open(two, "rb"))
    t.ok(f:read("*a"):match("^ISO%-10303%-21;"), "a mirrored solid writes STEP")
    f:close()
    local upright = bs.Solid.cylinder(4, 10):translate(0, 0, 6):rotate({ { 0, 0, 0 }, { 0, 0, 1 } }, 0.1):place(XY)
    bs.write_step(two, { plate, upright }, SCHEMA_AP203)
    f = assert(io.open(two, "rb"))
    t.ok(#f:read("*a") > 0)
    f:close()
    -- SAT, the same two ways; the file is the library's own writing.
    local sat = plate:sat_text("mm")
    t.ok(sat:match("^400 0 1 0"), "SAT text")
    t.ok(sat:find(" cone%-surface %$%-1 "), "the bore is written exactly")
    t.raises(function() plate:sat_text("furlong") end, "unit must be one of")
    local sat_path = t.tmp("plate.sat")
    plate:sat(sat_path)
    f = assert(io.open(sat_path, "rb"))
    t.ok(f:read("*a"):match("^400 0 1 0"), "a SAT file is written")
    f:close()
    local two_sat = t.tmp("two.sat")
    bs.write_sat(two_sat, { plate, upright }, "in")
    f = assert(io.open(two_sat, "rb"))
    t.ok(f:read("*a"):find("\n25.4 1e%-06 1e%-10", 1), "the unit line")
    f:close()
    t.raises(function() plate:sat(t.tmp("no/such/dir/plate.sat")) end, "sat: ")
    part:close()
    t.raises(function() return part.faces end, "solid: closed")
    part:close()   -- idempotent
  end)

  t.test("svg: solid text, a file, several solids' groups, up defaults to z, fov=200 refused", function()
    local plate = bs.Solid.extrude(plate_outline(), XY, 6)
    local text = plate:svg_text()
    t.ok(text:sub(1, 4) == "<svg", text:sub(1, 40))
    t.ok(text:find("<path", 1, true), "no <path in the solid's svg text")

    local path = t.tmp("plate.svg")
    plate:svg(path)
    local f = assert(io.open(path, "rb"))
    t.eq(f:read("*a"):sub(1, 4), "<svg")
    f:close()

    -- No scene over the kernel: up left out is z, not a scene's convention, so an
    -- explicit y-up still reads differently from the default.
    local z_up, y_up = plate:svg_text({ up = "z" }), plate:svg_text({ up = "y" })
    t.ok(z_up ~= y_up, "z-up and y-up read the same")

    -- Several solids, each its own group.
    local both = bs.write_svg_text({ plate, bs.Solid.cuboid(1, 1, 1) })
    local _, groups = both:gsub('<g id="', "")
    t.eq(groups, 2)

    t.raises(function() plate:svg_text({ fov = 200 }) end, "fov")
    t.raises(function() plate:svg(t.tmp("no/such/dir/plate.svg"), { fov = 200 }) end, "fov")
  end)

  t.test("step_text resolves schema as none, a built-in name, a path or text", function()
    local solid = bs.Solid.cuboid(1, 2, 3)
    t.ok(solid:step_text():find("CONFIG_CONTROL_DESIGN", 1, true), "no schema is the built-in AP203")
    t.ok(solid:step_text("AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF"):match("^ISO%-10303%-21;"))
    t.raises(function() solid:step_text("NO_SUCH_SCHEMA") end, "no built%-in schema named")
    if SCHEMA_AP203 then t.ok(solid:step_text(SCHEMA_AP203):match("^ISO%-10303%-21;")) end
    -- A long one-line string names no file: it is sent as EXPRESS text, which parses and
    -- is then refused for lacking an entity the writer needs.
    local schema = "SCHEMA x; ENTITY a; s : STRING; END_ENTITY; END_SCHEMA; -- " .. ("x"):rep(300)
    local e = t.raises(function() solid:step_text(schema) end, "^step: the schema has no entity ")
    t.ok(is_build_error(e))
    t.eq(bs.write_step_text({ solid }), solid:step_text())
    solid:close()
  end)

  t.test("faces and edges are queried, selected, filleted, chamfered and shelled", function()
    local box = bs.Solid.cuboid(20, 20, 10)
    local top = box:select_face(bs.Selector.max(bs.Axis.Z))
    t.eq(box:face_kind(top), "plane")
    local frame = box:face_frame(top)
    t.eq(#frame, 12)
    t.near(frame[12], 1, 1e-9)
    t.eq(box:select_face(bs.Selector.normal({ 0, 0, -1 })), box:select_face(bs.Selector.min(bs.Axis.Z)))
    t.eq(box:select_face(bs.Selector.index(2)), 2)
    t.ok(is_build_error(t.raises(function() box:select_face(bs.Selector.index(99)) end)))
    local edges = box.edges
    t.eq(#edges, 12)
    local vertical = {}
    for _, e in ipairs(edges) do
      if e.is_line and math.abs(e.direction[3]) > 0.99 then vertical[#vertical + 1] = e end
    end
    t.eq(#vertical, 4)
    for _, e in ipairs(vertical) do
      t.eq(#e.faces, 2)
      t.ok(#e.segments >= 1)
      t.eq(getmetatable(e), bs.Edge)
      t.ok(tostring(e):match("^Edge%(%d+, 'line', faces=%(%d+, %d+%)%)$"), tostring(e))
    end
    t.ok(box:fillet(vertical, 2).faces > box.faces)
    local indices = {}
    for i, e in ipairs(vertical) do indices[i] = e.index end
    t.ok(box:chamfer(indices, 1).faces > box.faces)
    t.ok(box:shell(1, { top }).faces > box.faces)
    t.ok(is_build_error(t.raises(function() box:fillet(vertical, -1) end)))
  end)

  t.test("a profile becomes a sheet, and the sheet a solid", function()
    local outline = bs.Profile.rect(80, 40):with_hole(bs.Profile.circle(4))
    local sheet = bs.Solid.face(outline, XY)
    t.eq(sheet.faces, 1)
    t.eq(sheet:face_kind(0), "plane")
    local f = sheet:face_frame(0)
    t.ok(same({ f[10], f[11], f[12] }, { 0, 0, 1 }))
    t.eq(sheet:extrude_faces(6).faces, bs.Solid.extrude(outline, XY, 6).faces)
    t.eq(bs.Workplane.xz():face(outline):solid().faces, 1)
  end)

  t.test("a face is pushed and pulled, solids split, rounds and bevels remade", function()
    local box = bs.Solid.cuboid(40, 20, 10)
    local top = box:select_face(bs.Selector.max(bs.Axis.Z))
    local taller = box:push_pull(top, 6)
    t.eq(taller.faces, 6)
    t.ok(taller:is_watertight())
    t.eq(box:push_pull(top, -4).faces, 6)
    local spring = bs.Solid.coil(bs.Profile.circle(1):translate(10, 0), { { 0, 0, 0 }, { 0, 0, 1 } }, 4, 2)
    t.ok(spring:is_watertight())
    local pipe = bs.Solid.pipe(bs.SweepPath.at({ 0, 0, 0 }):line_to({ 0, 0, 10 }), 2, 0.5)
    t.ok(pipe:is_watertight())
    t.eq(pipe.faces, 6, "two walls outside, two in the bore, two ends")
    local halves = box:split_by_plane({ { 10, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 }, { 1, 0, 0 } })
    t.eq(#halves, 2)
    t.eq(halves[1].faces, 6)
    t.eq(halves[2].faces, 6)
    t.eq(#box:lumps(), 1)
    t.raises(function() box:split_by_plane({ { 0, 0, 50 }, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }) end,
      "split_by_plane: the plane does not cross")
    local slab = bs.Solid.cuboid(40, 20, 2)
    local parts = box:split(slab)
    t.ok(#parts >= 2, "a box split by a slab through it is at least two bodies, got " .. #parts)
    local can = bs.Solid.cylinder(5, 10)
    local caps = { [can:select_face(bs.Selector.max(bs.Axis.Z))] = true, [can:select_face(bs.Selector.min(bs.Axis.Z))] = true }
    local wall
    for i = 0, 2 do if not caps[i] then wall = i end end
    local fatter = can:push_pull(wall, 2)
    t.ok(fatter:is_watertight())
    t.eq(fatter.faces, 3)
    local block = bs.Solid.cuboid(30, 20, 12)
    local edge
    for _, e in ipairs(block.edges) do
      if edge == nil and e.is_line and math.abs(e.direction[1]) > 0.99 then edge = e.index end
    end
    local rounded = block:fillet({ edge }, 2)
    local band = count_faces(rounded, "cylinder")[1]
    t.eq(rounded:refillet(band, 3).faces, 7)
    t.eq(rounded:unfillet(band).faces, 6)
    local walls = bs.Solid.extrude_open(bs.Profile.rect(20, 10), XY, 8)
    local thick = walls:thicken(1)
    t.ok(thick:is_watertight())
    t.eq(thick.faces, 16)
    t.raises(function() walls:thicken(0) end, "^thicken: ")
    local bevelled = block:chamfer({ edge }, 2)
    local bevel
    for i = 0, bevelled.faces - 1 do
      local nz = math.floor(bevelled:face_frame(i)[12] * 1e6 + 0.5) / 1e6
      if bevel == nil and bevelled:face_kind(i) == "plane" and nz ~= 0 and nz ~= 1 and nz ~= -1 then bevel = i end
    end
    t.ok(bevel, "a bevel face")
    t.eq(bevelled:rechamfer(bevel, 3).faces, 7)
    t.eq(bevelled:unchamfer(bevel).faces, 6)
    local joined = box:join(box:face_sheet(top):extrude_faces(6))
    t.eq(joined.faces, 10)
    t.eq(joined:merge_flush().faces, 6)
    t.eq(box:join(box:face_sheet(top):extrude_faces(6), 0.05, nil, true).faces, 6, "merged as it joins")
  end)

  t.test("an open profile closes with a line back to its start", function()
    local ell = bs.Profile.path({ 0, 0 }):line_to(10, 0):line_to(10, 5):end_open()
    t.eq(bs.Solid.extrude_open(ell, XY, 2).faces, 2)
    t.eq(bs.Solid.extrude_open(ell:close_loop(), XY, 2).faces, 3)
  end)

  t.test("open profiles chain into one, in any order and either way round", function()
    local function side(a, b) return bs.Profile.path(a):line_to(b[1], b[2]):end_open() end
    local rect = bs.Profile.chain({ side({ 0, 0 }, { 10, 0 }), side({ 10, 5 }, { 0, 5 }), side({ 0, 0 }, { 0, 5 }),
      side({ 10, 0 }, { 10, 5 }) })
    t.eq(bs.Solid.extrude(rect, XY, 2).faces, 6)
    t.eq(bs.Solid.extrude_open(bs.Profile.chain({ side({ 0, 0 }, { 10, 0 }), side({ 10, 5 }, { 10, 0 }) }), XY, 2).faces, 2)
    local e = t.raises(function() bs.Profile.chain({ side({ 0, 0 }, { 1, 0 }), side({ 5, 5 }, { 6, 5 }) }) end)
    t.eq(e.message, "chain: piece 1 does not meet the others")
  end)

  t.test("colours are set, read back and inherited", function()
    local block = bs.Solid.cuboid(10, 10, 10)
    t.eq(block.colour, nil)
    local top = block:select_face(bs.Selector.max(bs.Axis.Z))
    local painted = block:coloured("#cc9966"):coloured({ 0.2, 0.4, 1 }, top)
    t.ok(all_near(painted.colour, { 0.8, 0.6, 0.4 }, 1e-12))
    t.ok(all_near(painted:face_colour(top), { 0.2, 0.4, 1 }, 1e-12))
    t.ok(all_near(painted:translate(5, 0, 0):face_colour(top), { 0.2, 0.4, 1 }, 1e-12))
    t.ok(all_near(block:coloured("#fff").colour, { 1, 1, 1 }, 1e-12))
    local cut = painted:cut(bs.Solid.cylinder(2, 20):translate(0, 0, -10):coloured({ 1, 0, 0 }))
    local bore = count_faces(cut, "cylinder")
    t.ok(#bore > 0)
    for _, f in ipairs(bore) do t.ok(all_near(cut:face_colour(f), { 1, 0, 0 }, 1e-12)) end
    t.raises(function() block:coloured({ 1.5, 0, 0 }) end, "coloured: r, g and b must be in 0%.%.1")
    t.raises(function() block:coloured("#fff", -1) end, "coloured: face %-1 is not one of the solid's 6")
    t.raises(function() block:face_colour(6) end, "colour: face 6 is not one of the solid's 6")
    t.raises(function() block:coloured("red") end, "coloured: a colour is")
  end)

  t.test("the Workplane chain mirrors the Rust one", function()
    local plate = bs.Workplane.xy():extrude(plate_outline(), 6):solid()
    local pin = bs.Workplane.from_solid(plate):faces(bs.Selector.max(bs.Axis.Z)):workplane():cylinder(4, 10):solid()
    t.near(pin.bounds[1][3], 6, 1e-6, "the pin sits on the top face")
    t.raises(function() bs.Workplane.xz():solid() end, "nothing was built")
    t.raises(function() bs.Workplane.yz():translate(1, 0, 0) end, "holds no solid")
    t.raises(function() bs.Workplane.xy():faces(bs.Selector.max(bs.Axis.Z)) end, "holds no solid")
    t.eq(bs.Workplane.on(XY):cuboid(1, 1, 1):translate(1, 2, 3):solid().faces, 6)
    t.ok(bs.Workplane.xy():revolve(bs.Profile.rect(2, 2):translate(5, 0), pi * 2):solid().faces > 0)
    t.eq(bs.Workplane.xy():workplane().frame[1], 0, "workplane() with nothing picked is a no-op")
    t.eq(getmetatable(bs.Workplane(XY)), bs.Workplane)
  end)

  t.test("a Frame is built, checked and passed where twelve numbers go", function()
    t.ok(same(bs.Frame.xy():values(), XY))
    t.ok(same(bs.Frame.xz():values(), bs.Workplane.xz().frame))
    t.ok(same(bs.Frame.yz():values(), bs.Workplane.yz().frame))
    t.eq(bs.Frame.xy()[12], 1, "frame[i] reads the twelve numbers")
    t.ok(bs.Frame.at({ 1, 2, 3 }, { 0, 0, 7 }) == bs.Frame.xy({ 1, 2, 3 }))
    t.ok(bs.Frame.at({ 0, 0, 0 }, { 0, -1, 0 }) == bs.Frame.xz())
    t.ok(bs.Frame.at({ 0, 0, 0 }, { 2, 0, 0 }) == bs.Frame.yz())
    local f = bs.Frame.at({ 0, 0, 0 }, { 0, 0, -1 }, { 1, 1, 5 })
    local h = math.sqrt(0.5)
    t.ok(all_near(f.x, { h, h, 0 }) and all_near(f.y, { h, -h, 0 }))
    t.ok(same(f.z, { 0, 0, -1 }))
    t.ok(bs.Frame.xy():offset(5) == bs.Frame.xy({ 0, 0, 5 }))
    t.ok(all_near(bs.Frame.xz():offset(2).origin, { 0, -2, 0 }))
    t.ok(same(bs.Frame.xy():translate(1, 2, 3).origin, { 1, 2, 3 }))
    t.ok(bs.Frame({ 0, 0, 0 }, { 3, 0, 0 }, { 0, 2, 0 }, { 0, 0, 9 }) == bs.Frame.xy(), "normalised")
    t.ok(is_build_error(t.raises(function() bs.Frame.new({ 0, 0, 0 }, { 1, 0, 0 }, { 1, 1, 0 }, { 0, 0, 1 }) end, "not square")))
    t.raises(function() bs.Frame.new({ 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, -1 }) end, "left%-handed")
    t.raises(function() bs.Frame.at({ 0, 0, 0 }, { 0, 0, 0 }) end, "no direction")
    t.raises(function() bs.Frame.at({ 0, 0, 0 }, { 0, 0, 1 }, { 0, 0, -2 }) end, "along the normal")
    t.ok(tostring(bs.Frame.xy()):match("^Frame%(origin="))
    local lid = bs.Solid.extrude(bs.Profile.rect(10, 4), bs.Frame.xy({ 0, 0, 5 }), 2)
    t.ok(all_near(lid.bounds[1], { -5, -2, 5 }) and all_near(lid.bounds[2], { 5, 2, 7 }))
    local wall = bs.Workplane.on(bs.Frame.xz({ 0, 3, 0 })):extrude(bs.Profile.rect(10, 4), 1):solid()
    t.near(wall.bounds[1][2], 2, 1e-9)
    t.near(wall.bounds[2][2], 3, 1e-9)
    local top = bs.Frame.of(lid:face_frame(lid:select_face(bs.Selector.max(bs.Axis.Z))))
    t.near(top.origin[3], 7, 1e-9)
    t.ok(all_near(top.z, { 0, 0, 1 }))
    -- Four triples go wherever twelve numbers do.
    t.eq(bs.Solid.extrude(bs.Profile.rect(1, 1), { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }, 1).faces, 6)
    t.raises(function() bs.Solid.extrude(bs.Profile.rect(1, 1), { 0, 0, 0 }, 1) end, "frame: expected 12 numbers, got 3")
  end)

  t.test("sweep, loft, taper and open sheets", function()
    local sp = bs.SweepPath.at({ 0, 0, 0 }):line_to({ 0, 0, 20 }):arc({ 10, 0, 20 }, { 0, 1, 0 }, pi / 2)
    t.ok(bs.Solid.sweep(bs.Profile.circle(2), XY, sp).faces > 0)
    t.ok(bs.Solid.sweep_open(bs.Profile.path({ -2, 0 }):line_to(2, 0):end_open(), XY, sp).faces > 0)
    sp:close()
    sp:close()
    t.raises(function() sp:line_to({ 1, 1, 1 }) end, "sweep_path: closed")
    t.raises(function() bs.Solid.sweep(bs.Profile.circle(2), XY, sp) end, "sweep_path: closed")
    local up = { 0, 0, 10, 1, 0, 0, 0, 1, 0, 0, 0, 1 }
    t.ok(bs.Solid.loft(bs.Profile.rect(10, 10), XY, bs.Profile.polygon({ { -2, -3 }, { 3, -2 }, { 2, 3 }, { -3, 2 } }), up).faces > 0)
    t.ok(bs.Solid.loft_open(bs.Profile.path({ 0, 0 }):line_to(10, 0):end_open(), XY,
      bs.Profile.path({ 0, 0 }):line_to(10, 0):end_open(), up).faces > 0)
    t.eq(bs.Solid.extrude_tapered(bs.Profile.rect(10, 10), XY, 5, 0.1).faces, 6)
    local sheet = bs.Solid.extrude_open(bs.Profile.path({ 0, 0 }):line_to(10, 0):end_open(), XY, 5)
    t.ok(sheet.faces >= 1)
    t.ok(bs.Solid.extrude_open_tapered(bs.Profile.path({ 0, 0 }):line_to(10, 0):end_open(), XY, 5, 0.1).faces >= 1)
    t.ok(sheet:extrude_faces(2).faces > sheet.faces)
    t.ok(bs.Solid.revolve_open(bs.Profile.path({ 5, 0 }):line_to(6, 0):end_open(), { { 0, 0, 0 }, { 0, 1, 0 } }, pi).faces >= 1)
    t.ok(bs.Solid.revolve(bs.Profile.rect(2, 2):translate(5, 0), { 0, 0, 0, 0, 1, 0 }, pi).faces > 0)
    t.eq(getmetatable(bs.SweepPath({ 0, 0, 0 })), bs.SweepPath)
  end)

  t.test("watertightness is checked, and a bad tolerance raises the library reason", function()
    local cube = bs.Solid.cuboid(2, 2, 2)
    t.eq(cube:is_watertight(), true)
    t.eq(cube:leaked_edges(), 0)
    t.eq(cube:unpaired_edges(), 0)
    local sheet = bs.Solid.extrude_open(bs.Profile.rect(4, 4), XY, 2)
    t.eq(sheet:is_watertight(), false)
    t.ok(sheet:leaked_edges(0.05) > 0)
    t.ok(sheet:unpaired_edges(0.05) > 0)
    t.raises(function() cube:leaked_edges(0) end, "^leaked_edges: tolerance must be positive and finite")
    t.raises(function() cube:unpaired_edges(-1) end, "^unpaired_edges: ")
  end)

  t.test("two circles hit twice, a tangent touches, an overlap runs", function()
    local crossing = bs.Profile.circle(5):hits(bs.Profile.circle(5):translate(6, 0))
    t.eq(#crossing, 2)
    local ys = { crossing[1].start[2], crossing[2].start[2] }
    table.sort(ys)
    t.near(ys[1], -4, 1e-12)
    t.near(ys[2], 4, 1e-12)
    for _, h in ipairs(crossing) do
      t.eq(getmetatable(h), bs.Hit)
      t.eq(getmetatable(h.a_start), bs.Spot)
      t.eq(h.run, false)
      t.eq(h.touch, false)
      t.near(h.start[1], 3, 1e-12)
      t.eq(h.start[3], 0)
      t.eq(h["end"][2], h.start[2])
      t.eq(h.a_start.loop_index, 0)
      t.eq(h.a_start.face, bs.NONE)
      -- (3, 4) is t 0.2952 on the first circle's upper arc, 0.7048 on the moved one's
      local ta, tb = 0.7048, 0.2952
      if h.start[2] > 0 then ta, tb = tb, ta end
      t.near(h.a_start.t, ta, 1e-3)
      t.near(h.b_start.t, tb, 1e-3)
    end
    local touched = bs.Profile.circle(5):hits(bs.Profile.path({ -10, 5 }):line_to(10, 5):end_open())
    t.eq(#touched, 1)
    t.eq(touched[1].touch, true)
    t.eq(touched[1].run, false)
    local runs = 0
    for _, h in ipairs(bs.Profile.rect(10, 10):hits(bs.Profile.rect(10, 10):translate(5, 0))) do
      if h.run then runs = runs + 1 end
    end
    t.eq(runs, 2)
    t.raises(function() bs.Profile.circle(1):hits(bs.Profile.circle(2), 0) end,
      "profile_hits: tolerance must be positive and finite")
    t.eq(#bs.Profile.circle(1):hits(bs.Profile.circle(2):translate(10, 0)), 0)
  end)

  t.test("every edge carries its exact curve", function()
    local function norm(v) return math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3]) end
    local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
    -- A cylinder's rims are circles of its radius about a cap centre, in a unit frame, a whole turn each.
    local cyl = bs.Solid.cylinder(5, 3)
    local rims = {}
    for _, e in ipairs(cyl.edges) do if e.kind == "circle" then rims[#rims + 1] = e.curve end end
    t.ok(#rims >= 2)
    for _, c in ipairs(rims) do
      t.ok(getmetatable(c) == bs.Curve)
      t.eq(c.kind, "circle")
      t.near(c.radius, 5, 1e-9)
      t.near(c.radius2, 5, 1e-9)
      t.near(c.origin[1], 0, 1e-9)
      t.near(c.origin[2], 0, 1e-9)
      t.ok(math.min(math.abs(c.origin[3]), math.abs(c.origin[3] - 3)) < 1e-9)
      t.near(norm(c.x), 1, 1e-9)
      t.near(norm(c.y), 1, 1e-9)
      t.near(dot(c.x, c.y), 0, 1e-9)
      t.near(math.abs(c.t1 - c.t0), 2 * math.pi, 1e-9)
      t.eq(c.degree, 0)
      t.eq(#c.knots, 0)
      t.eq(#c.poles, 0)
      t.eq(c.weights, nil)
      t.ok(tostring(c):find("^Curve%('circle', origin=%(") ~= nil)
    end
    -- A cuboid's edges are lines: `origin + x` is the far end, both ends its own vertices.
    for _, e in ipairs(bs.Solid.cuboid(2, 4, 6).edges) do
      local c = e.curve
      t.eq(c.kind, "line")
      t.eq(c.t0, 0)
      t.eq(c.t1, 1)
      local far = { c.origin[1] + c.x[1], c.origin[2] + c.x[2], c.origin[3] + c.x[3] }
      local at_origin, at_far = false, false
      for _, s in ipairs(e.segments) do
        for _, p in ipairs(s) do
          local d0 = { p[1] - c.origin[1], p[2] - c.origin[2], p[3] - c.origin[3] }
          local d1 = { p[1] - far[1], p[2] - far[2], p[3] - far[3] }
          if norm(d0) < 1e-9 then at_origin = true end
          if norm(d1) < 1e-9 then at_far = true end
        end
      end
      t.ok(at_origin and at_far)
      t.eq(c.radius, 0)
      t.ok(norm(c.y) == 0 and norm(c.z) == 0)
    end
    -- A closed spline extruded: its wall's seam edge is the NURBS itself.
    local square = { { 0, 0 }, { 10, 0 }, { 10, 10 }, { 0, 10 } }
    local loop = bs.Solid.extrude(bs.Profile.spline(square, 3, nil, true), XY, 2)
    local splines = {}
    for _, e in ipairs(loop.edges) do if e.kind == "nurbs" then splines[#splines + 1] = e.curve end end
    t.ok(#splines > 0)
    for _, c in ipairs(splines) do
      t.eq(c.kind, "nurbs")
      t.eq(c.degree, 3)
      t.eq(#c.knots, #c.poles + c.degree + 1)
      t.eq(#c.poles[1], 3)
      t.eq(c.weights, nil)
      t.ok(c.knots[c.degree + 1] <= c.t0 and c.t0 < c.t1 and c.t1 <= c.knots[#c.poles + 1])
    end
    -- A kernel shape's edges all have an exact curve.
    for _, solid in ipairs({ cyl, loop, bs.Solid.sphere(2) }) do
      for _, e in ipairs(solid.edges) do t.ok(e.curve ~= nil) end
    end
  end)

  t.test("two circles share one lens of arcs", function()
    local a = bs.Profile.circle(5)
    local b = bs.Profile.circle(5):translate(6, 0)
    local lenses = a:common(b)
    t.eq(#lenses, 1)
    t.eq(getmetatable(lenses[1]), bs.Profile)
    -- Four arcs (each circle's own seam stays a join) between two caps.
    t.eq(bs.Solid.extrude(lenses[1], XY, 1).faces, 6)
    t.eq(#a:common(b:translate(100, 0)), 0)
    t.raises(function() a:common(b, 0) end, "profile_common: tolerance must be positive and finite")
  end)

  t.test("manifold is read off the topology of a solid and a sheet", function()
    local m = bs.Solid.cuboid(2, 2, 2).manifold
    t.eq(getmetatable(m), bs.Manifold)
    t.eq(m.faces, 6)
    t.eq(m.edges, 12)
    t.eq(m.vertices, 8)
    t.eq(m.boundary_edges, 0)
    t.eq(m.non_manifold_edges, 0)
    t.eq(m.non_manifold_vertices, 0)
    t.eq(m.is_manifold, true)
    t.eq(m.is_closed, true)
    local sheet = bs.Solid.extrude_open(bs.Profile.rect(4, 4), XY, 2).manifold
    t.eq(sheet.is_manifold, true)
    t.eq(sheet.is_closed, false)
    t.eq(sheet.boundary_edges, 8)
    t.ok(tostring(sheet):match("^Manifold%(faces=4, "), tostring(sheet))
  end)

  t.test("split_sheet cuts a sheet along a solid's boundary", function()
    local sheet = bs.Solid.extrude_open(bs.Profile.rect(40, 40), XY, 20)
    t.eq(sheet.faces, 4)
    local tool = bs.Solid.cuboid(10, 10, 10):translate(20, 0, 10)
    t.ok(sheet:split_sheet(tool).faces > sheet.faces, "the straddled wall comes out in more than one piece")
    local reported = {}
    sheet:split_sheet(tool, 0.05, function(phase, done, total) reported[#reported + 1] = { phase, done, total } end)
    t.ok(#reported > 0)
    for _, r in ipairs(reported) do t.ok(type(r[1]) == "string" and r[2] <= r[3]) end
    t.raises(function() sheet:split_sheet(tool, 0) end, "^split_sheet: ")
  end)

  t.test("extrude_between takes Slants or bare numbers, and Slant.of_plane reads a plane", function()
    local rect = bs.Profile.rect(80, 40)
    local between = bs.Solid.extrude_between(rect, XY, 0, bs.Slant.flat(6))
    local plain = bs.Solid.extrude(rect, XY, 6)
    t.eq(between.faces, plain.faces)
    t.ok(same(between.bounds[1], plain.bounds[1]) and same(between.bounds[2], plain.bounds[2]))
    local flat = bs.Slant.of_plane(XY, { 0, 0, 6 }, { 0, 0, 1 })
    t.eq(getmetatable(flat), bs.Slant)
    t.near(flat.at, 6, 1e-9)
    t.near(flat.grad[1], 0, 1e-9)
    t.near(flat.grad[2], 0, 1e-9)
    local e = t.raises(function() bs.Slant.of_plane(XY, { 0, 0, 6 }, { 1, 0, 0 }) end)
    t.eq(e.message, "slant_of_plane: the plane holds the sweep direction")
    t.raises(function() bs.Slant.of_plane(XY, { 0, 0 }, { 0, 0, 1 }) end, "point: expected 3 numbers")
    local shifted = rect:translate(40, 0)
    local sloped = bs.Solid.extrude_between(shifted, XY, bs.Slant.flat(0), bs.Slant(6, { 0.25, 0 }))
    t.near(sloped.bounds[1][3], 0, 1e-6)
    t.near(sloped.bounds[2][3], 26, 1e-6)
    t.eq(sloped:is_watertight(), true)
    t.raises(function() bs.Solid.extrude_between(rect, XY, 0, bs.Slant.new(6, { 0.25, 0 })) end, "^extrude_between: ")
    local walls = bs.Solid.extrude_open_between(shifted, XY, 0, bs.Slant.new(6, { 0.25, 0 }))
    t.eq(walls.faces, bs.Solid.extrude_open(shifted, XY, 6).faces)
    t.eq(walls:is_watertight(), false)
    t.eq(tostring(bs.Slant.new(6, { 0.25, 0 })), "Slant(6, (0.25, 0))")
  end)

  t.test("faces are made, taken, dropped and trimmed; profiles rounded and followed", function()
    local square = bs.Profile.rect(20, 20)
    local sheet = bs.Solid.face(square, XY)
    t.eq(sheet.faces, 1)
    t.eq(bs.Workplane.xy():face(square):solid().faces, 1)
    local peg = bs.Solid.extrude(bs.Profile.circle(4), { 0, 0, -6, 1, 0, 0, 0, 1, 0, 0, 0, 1 }, 12)
    local holed = sheet:trim(peg)
    local disc = sheet:trim(peg, "inside")
    t.eq(holed.faces + disc.faces, sheet.faces * 2)
    t.ok(holed.bounds[2][1] > 9.9 and disc.bounds[2][1] < 4.1, "outside keeps the square, inside the disc")
    local reported = {}
    t.eq(sheet:trim(peg, "inside", 0.05, function(phase) reported[#reported + 1] = phase end).faces, disc.faces)
    t.ok(#reported > 0)
    t.raises(function() sheet:trim(peg:translate(100, 0, 0), "inside") end, "trim: nothing of the sheet lies inside the tool")
    t.raises(function() sheet:trim(peg, "both") end, "keep must be 'outside' or 'inside', not 'both'")
    local plate = bs.Solid.extrude(square, XY, 6)
    local top = plate:select_face(bs.Selector.max(bs.Axis.Z))
    t.eq(plate:face_sheet(top).faces, 1)
    t.eq(plate:drop_faces({ 0, 1 }).faces, plate.faces - 2)
    t.raises(function() plate:face_sheet(6) end, "face_sheet: no face 6 %-%- the solid has 6 %(0 to 5%)")
    t.eq(bs.Solid.extrude(square:round(2), XY, 1).faces, 10)
    t.eq(bs.Solid.extrude(square:round(2, { 1 }), XY, 1).faces, 7)
    t.eq(bs.Solid.extrude(square:round(2, {}), XY, 1).faces, 6, "nothing picked, nothing rounded")
    t.raises(function() square:round(30) end, "round: the radius 30 does not fit corner 0")
    local wave = bs.Profile.path({ 0, 0 }):bezier_to({ 20, 0 }, { 20, 20 }, { 40, 10 }):end_open()
    local along = bs.SweepPath.along(wave, XY, 0.01)
    local tube = bs.Solid.sweep(bs.Profile.circle(1), { 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0 }, along)
    t.ok(tube.faces > 2 and tube.bounds[2][1] > 40 and tube.bounds[2][1] < 41, "a tube to the end of the curve")
    along:close()
    t.raises(function() bs.SweepPath.along(wave, XY, 0) end, "along: the tolerance must be positive and finite")
  end)

  t.test("a profile turns about an axis drawn beside it, and loose loops make a plate", function()
    local plate = bs.Profile.polygon({ { -8, 0 }, { -5, 0 }, { -5, 10 }, { -8, 10 } })
    local quarter = bs.Solid.revolve_in_plane(plate, XY, { 0, 0 }, { 0, 1 }, pi / 2)
    local lo, hi = quarter.bounds[1], quarter.bounds[2]
    t.near(lo[1], -8, 1e-6)
    t.near(hi[1], 0, 1e-6)
    t.near(lo[3], 0, 1e-6)
    t.near(hi[3], 8, 1e-6)
    local e = t.raises(function() bs.Solid.revolve_in_plane(plate, XY, { -6, 0 }, { -6, 1 }, 1) end)
    t.eq(e.message, "revolve_in_plane: the profile crosses the axis")
    t.eq(bs.Solid.revolve_open_in_plane(bs.Profile.path({ 5, 0 }):line_to(5, 10):end_open(), XY, { 0, 0 }, { 0, 1 }, pi).faces, 1)
    t.eq(bs.Solid.extrude(bs.Profile.from_loops({ bs.Profile.circle(4), bs.Profile.rect(30, 30) }), XY, 2).faces, 8)
    e = t.raises(function() bs.Profile.from_loops({ bs.Profile.rect(30, 30), bs.Profile.circle(4):translate(100, 0) }) end)
    t.eq(e.message, "from_loops: loop 1 lies outside loop 0")
  end)

  t.test("a regular polygon and a spline, open and closed", function()
    t.eq(bs.Solid.extrude(bs.Profile.regular_polygon({ 0, 0 }, 10, 6), XY, 2).faces, 8)
    local square = { { 0, 0 }, { 10, 0 }, { 10, 10 }, { 0, 10 } }
    local loop = bs.Solid.extrude(bs.Profile.spline(square, 3, nil, true), XY, 2)
    t.eq(loop.faces, 3)
    t.ok(loop:is_watertight())
    t.eq(bs.Solid.extrude_open(bs.Profile.spline(square, 3, { 1, 2, 2, 1 }), XY, 2).faces, 1)
    local e = t.raises(function() bs.Profile.regular_polygon({ 0, 0 }, 10, 2) end)
    t.eq(e.message, "profile_regular_polygon: a polygon has at least 3 sides, not 2")
  end)

  t.test("mesh and edge views borrow the cache and refuse to read once stale", function()
    local ball = bs.Solid.sphere(5)
    local positions, normals, indices = ball:mesh(0.05)
    t.ok(positions.pointer ~= nil)
    local x, y, z = positions:row(0)
    t.near(math.sqrt(x * x + y * y + z * z), 5, 0.06, "a vertex on the sphere")
    local nx, ny, nz = normals:row(0)
    t.near(nx * nx + ny * ny + nz * nz, 1, 1e-4, "a unit normal")
    local last = indices:get(indices.size - 1)
    t.ok(last < positions.shape[1], "indices count from zero into the vertices")
    t.eq(positions.pointer[3], positions:get(3), "the raw pointer reads what get does")
    local kept = indices:copy()
    t.eq(#kept, indices.size)
    -- The same tolerance again is the same cache: the first views still read.
    local again = ball:mesh(0.05)
    t.eq(again.size, positions.size)
    t.eq(positions:get(0), again:get(0))
    t.eq(positions.valid, true)
    -- Another tolerance replaces the cache: the old views refuse.
    local coarse = ball:mesh(0.5)
    t.ok(coarse.size < positions.size, "coarser is fewer vertices")
    t.eq(positions.valid, false)
    local e = t.raises(function() return positions.pointer end, "the view is stale")
    t.ok(is_build_error(e))
    t.raises(function() indices:get(0) end, "stale")
    t.raises(function() normals:copy() end, "stale")
    -- Back at 0.05 is a new filling: the first views stay stale, the new one reads.
    local back = ball:mesh(0.05)
    t.raises(function() positions:get(0) end, "stale")
    t.raises(function() coarse:get(0) end, "stale")
    t.eq(back.size, again.size)
    -- bounds and edge polylines share the cache.
    local runs = ball:edge_polylines(0.05)
    t.eq(back.valid, true, "the same tolerance keeps the mesh")
    ball:bounds_at(0.2)
    t.eq(back.valid, false, "bounds at another tolerance re-meshes")
    for _, r in ipairs(runs) do t.eq(r.valid, false) end
    local box = bs.Solid.cuboid(10, 10, 10)
    local edges = box:edge_polylines(0.05)
    t.eq(#edges, 12)
    local points = 0
    for _, r in ipairs(edges) do
      t.ok(r.shape[1] >= 2)
      local ax = r:row(0)
      t.near(math.abs(ax), 5, 1e-6, "an edge of the box runs along its surface")
      points = points + r.shape[1]
    end
    t.ok(#edges[1]:copy() == edges[1].size)
    -- Closing the solid invalidates every view; a copy lives on.
    box:close()
    t.raises(function() edges[1]:get(0) end, "closed")
    t.eq(#kept, indices.size)
    t.raises(function() box:mesh() end, "solid: closed")
  end)

  t.test("a view keeps its solid alive under collection pressure", function()
    local positions, _, indices = bs.Solid.sphere(3):mesh(0.1)   -- the solid itself is dropped
    local views = {}
    for i = 1, 300 do
      local s = bs.Solid.cuboid(1, 1, 1):translate(i, 0, 0)
      if i % 50 == 0 then views[#views + 1] = { s:mesh(0.1) } end
      bs.Profile.rect(1, 1)
      bs.SweepPath.at({ 0, 0, 0 }):line_to({ 0, 0, 1 })
    end
    for _ = 1, 3 do collectgarbage() end
    t.eq(positions.valid, true)
    local x, y, z = positions:row(0)
    t.near(math.sqrt(x * x + y * y + z * z), 3, 0.11)
    t.eq(#indices:copy(), indices.size)
    for i, v in ipairs(views) do
      local vx = v[1]:row(0)
      t.near(vx, 50 * i, 0.5 + 1e-6, "the moved cube's first vertex")
    end
    views = nil
    positions, indices = nil, nil
    for _ = 1, 3 do collectgarbage() end
    t.eq(bs.Solid.cuboid(1, 1, 1).faces, 6, "the library is fine after the collector freed everything")
  end)

  t.test("a progress callback that raises fails the call, not the process", function()
    local box = bs.Solid.cuboid(10, 10, 10)
    local calls = 0
    local e = t.raises(function()
      box:join(bs.Solid.cuboid(5, 5, 5):translate(5, 0, 0), 0.05, function()
        calls = calls + 1
        error("stop here")
      end)
    end, "stop here")
    t.eq(calls, 1, "the callback is not called again once it raised")
    t.ok(not is_build_error(e), "the callback's own error, not a BuildError")
    t.eq(box:join(bs.Solid.cuboid(5, 5, 5):translate(5, 0, 0), 0.05).faces > 0, true)
    -- Many calls with a callback: every callback slot is given back.
    for _ = 1, 50 do box:shell(1, { 0 }, 1e-6, function() end) end
    t.ok(box:fillet({ 0 }, 1, 1e-6, function() end).faces > 6)
    t.ok(bs.Solid.extrude_open(bs.Profile.rect(4, 4), XY, 2):thicken(1, 1e-6, function() end).faces > 0)
    t.eq(#box:split_by_plane(bs.Frame.yz(), 0.05, function() end), 2)
    t.eq(#box:split(bs.Solid.cuboid(20, 20, 2), 0.05, function() end) >= 2, true)
    t.eq(box:push_pull(0, 1, 0.05, function() end).faces, 6)
    t.ok(box:cut(bs.Solid.cylinder(2, 20):translate(0, 0, -10), 0.05, function() end).faces > 6)
    t.ok(box:common(bs.Solid.cuboid(5, 5, 5), 0.05, function() end).faces > 0)
  end)

  t.test("a placement moves a solid, rows or the flat column-major sixteen, and a scale is refused", function()
    local cube = bs.Solid.cuboid(2, 2, 2)
    local moved = bs.Solid.cuboid(2, 2, 2):_placed({ { 1, 0, 0, 10 }, { 0, 1, 0, 20 }, { 0, 0, 1, 30 }, { 0, 0, 0, 1 } }, "t")
    t.ok(all_near(moved.bounds[1], { 9, 19, 29 }, 1e-9))
    local flat = bs.Solid.cuboid(2, 2, 2):_placed({ 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 5, 0, 0, 1 }, "t")
    t.ok(all_near(flat.bounds[1], { 4, -1, -1 }, 1e-9) and all_near(flat.bounds[2], { 6, 1, 1 }, 1e-9))
    t.eq(cube:_placed({ { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } }, "t"), cube, "the identity is itself")
    t.raises(function()
      bs.Solid.cuboid(2, 2, 2):_placed({ { 2, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } }, "open: x")
    end, "open: x: the placement scales or shears, which a brep cannot follow")
  end)

  -- ---- through the reader ----------------------------------------------------------

  t.test("to_scene hands a solid to the reader", function()
    local cad = require("cadaclysm")
    local scene = bs.Solid.cuboid(10, 20, 30):to_scene()
    local meshed
    for _, n in ipairs(scene.nodes) do
      if meshed == nil and n.can_mesh then meshed = n end
    end
    t.ok(meshed, "a node that meshes")
    local size = meshed.bounds.size
    t.ok(all_near(size, { 10, 20, 30 }, 1e-3), "size " .. table.concat(size, ", "))
    scene:close()
    if SCHEMA_AP203 then
      local again = bs.Solid.cuboid(1, 1, 1):to_scene(SCHEMA_AP203)
      t.ok(again.node_count >= 1)
      again:close()
    end
    t.ok(cad)
  end)

  t.test("a read body is a solid sharing the reader brep, and a file opens as its solids", function()
    local cad = require("cadaclysm")
    local plate = bs.Solid.extrude(plate_outline(), XY, 6)
    local file = t.tmp("plate.stp")
    plate:step(file, SCHEMA_AP203)
    local scene = cad.open(file)
    local node
    for _, p in ipairs(scene.placements) do
      local g = p.geometry
      local b = g.brep
      if b ~= nil then
        b:release()
        if node == nil then node = g end
      end
    end
    t.ok(node, "a placement with a brep")
    t.eq(cad.Brep.layout_id(), bs.brep_layout_id(), "one release, one layout")
    local part = bs.Solid.from_node(scene, node)
    local again = bs.Solid.from_node(scene, node.index, false)
    scene:close()
    t.eq(part.faces, plate.faces)
    t.eq(again.faces, plate.faces, "the scene can close first")
    t.ok(part:cut(bs.Solid.cylinder(2, 20):translate(-30, 0, -5)).faces > part.faces)
    t.eq(bs.Solid.open(file).faces, plate.faces)
    local all = bs.Solid.open_all(file)
    t.eq(#all, 1)
    t.eq(all[1].faces, plate.faces)
    local e = t.raises(function() bs.Solid.open(t.tmp("missing.stp")) end, "^open: ")
    t.ok(is_build_error(e))
    -- Two bodies: body= picks one, from zero.
    local two = t.tmp("two-bodies.stp")
    bs.write_step(two, { bs.Solid.cuboid(1, 1, 1), bs.Solid.cylinder(1, 3):translate(10, 0, 0) })
    t.eq(#bs.Solid.open_all(two), 2)
    t.raises(function() bs.Solid.open(two) end, "holds 2 bodies: pass body= %(0 to 1%)")
    local picked = { bs.Solid.open(two, 0).faces, bs.Solid.open(two, 1).faces }
    table.sort(picked)
    t.eq(picked[1], 3)
    t.eq(picked[2], 6)
    t.raises(function() bs.Solid.open(two, 5) end, "has no body 5: it holds 2")
    -- A mesh-only document: no brep to hand across.
    local mesh = cad.open_memory("cube(10);", "scad")
    local cube
    for _, n in ipairs(mesh.nodes) do
      if cube == nil and n.brep == nil then cube = n end
    end
    t.ok(cube, "a node with no brep")
    t.raises(function() bs.Solid.from_node(mesh, cube) end, "from_node: node %d+ .*has no brep")
    mesh:close()
    local scad = t.tmp("cube.scad")
    local f = assert(io.open(scad, "w"))
    f:write("cube(10);\n")
    f:close()
    t.raises(function() bs.Solid.open(scad) end, "open: the %.scad file draws no B%-rep body")
  end)

  t.test("push_pull on several faces at once", function()
    -- The box's top and +x side pushed together: 5 taller and 5 longer, each face found
    -- again after the other's push; a can's top and wall, taller and fatter.
    local box = bs.Solid.cuboid(40, 20, 10)
    local top = box:select_face(bs.Selector.max(bs.Axis.Z))
    local side = box:select_face(bs.Selector.max(bs.Axis.X))
    local grown = box:push_pull({ top, side }, 5)
    t.ok(grown:is_watertight())
    t.eq(grown.faces, 6)
    local lo, hi = grown.bounds[1], grown.bounds[2]
    t.near(hi[1] - lo[1], 45, 1e-6)
    t.near(hi[2] - lo[2], 20, 1e-6)
    t.near(hi[3] - lo[3], 15, 1e-6)
    local can = bs.Solid.cylinder(5, 10)
    local cap, base = can:select_face(bs.Selector.max(bs.Axis.Z)), can:select_face(bs.Selector.min(bs.Axis.Z))
    local wall
    for i = 0, can.faces - 1 do
      if i ~= cap and i ~= base then wall = i end
    end
    local both = can:push_pull({ cap, wall }, 2)
    t.ok(both:is_watertight())
    t.eq(both.faces, 3)
    lo, hi = both.bounds[1], both.bounds[2]
    t.near(hi[3] - lo[3], 12, 1e-6)
    t.near(hi[1] - lo[1], 14, 0.05)
    t.raises(function() box:push_pull({}, 2) end, "^push_pull: no faces to push$")
  end)

  t.test("weights: one per point, refused otherwise", function()
    local square = { { 0, 0 }, { 10, 0 }, { 10, 10 }, { 0, 10 } }
    t.raises(function() bs.Profile.spline(square, 3, { 1, 1 }, true) end,
      "^spline: 2 weights for 4 points; give one per point$")
    t.ok(bs.Profile.spline(square, 3, { 1, 1, 1, 1 }, true) ~= nil)
    t.raises(function()
      bs.Profile.path({ 0, 0 }):nurbs_to({ { 5, 5 }, { 10, 0 } }, { 0, 0, 0, 1, 1, 1 }, 2, { 1, 1 })
    end, "^nurbs_to: 2 weights for 3 control points %(the current point and 2 given%); give one per point$")
  end)
end
