-- The kernel wrapper's tests: the Node.js suite (node/test/blacksmith.test.js)
-- ported, plus what only a borrowing binding has to prove -- the stale-view rule,
-- views keeping their solid alive, and callbacks that raise.
local bs = require("cadaclysm_blacksmith")
local ffi = require("ffi")

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
      bs.Solid.torus(3, 1), bs.Solid.wedge(2, 2, 2, 1), bs.Solid.pyramid(4, 1, 2) }) do
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

  t.test("scaled multiplies every length", function()
    local big = bs.Solid.cuboid(1, 2, 3):scaled(2)
    local b = big:bounds_at(0.05)
    t.ok(math.abs(b[2][1] - b[1][1] - 2) < 1e-9 and math.abs(b[2][3] - b[1][3] - 6) < 1e-9, "scaled bounds")
    local e = t.raises(function() return big:scaled(0) end, "scaled:")
    t.ok(is_build_error(e))
    big:close()
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

    -- Several solids, each its own group -- three, not two: the drawing carries each body's
    -- outline by default, so the curved plate adds a `-silhouettes` group; a cuboid adds none.
    local both = bs.write_svg_text({ plate, bs.Solid.cuboid(1, 1, 1) })
    local _, groups = both:gsub('<g id="', "")
    t.eq(groups, 3)
    local _, outlines = both:gsub('<g id="[^"]*%-silhouettes"', "")
    t.eq(outlines, 1)

    t.raises(function() plate:svg_text({ fov = 200 }) end, "fov")
    t.raises(function() plate:svg(t.tmp("no/such/dir/plate.svg"), { fov = 200 }) end, "fov")
  end)

  t.test("svg: a profile's own plane, top by default, and a drawing of both kinds", function()
    local outline = plate_outline()
    local top_text = outline:svg_text()
    t.ok(top_text:sub(1, 4) == "<svg", top_text:sub(1, 40))
    t.ok(top_text:find("<path", 1, true), "no <path in the profile's svg text")

    local path = t.tmp("outline.svg")
    outline:svg(path)
    local f = assert(io.open(path, "rb"))
    t.eq(f:read("*a"):sub(1, 4), "<svg")
    f:close()

    -- Pinned against an explicit iso call, not just checked non-empty -- a silently-iso
    -- default would make this equal and the assertion below would fail.
    local iso_text = outline:svg_text({ view = "iso" })
    t.ok(top_text ~= iso_text, "profile svg_text did not default to the top view")

    -- The widened writer: any mix of solids and profiles, each its own group id --
    -- a solids-only call (the test above) still reads exactly as it always did.
    local plate = bs.Solid.extrude(plate_outline(), XY, 6)
    local mixed = bs.write_svg_text({ plate, outline })
    t.ok(mixed:find("<path", 1, true), "no <path in the mixed drawing")
    t.ok(mixed:find('id="solid-0"', 1, true), "no solid-0 group in the mixed drawing")
    t.ok(mixed:find('id="profile-0"', 1, true), "no profile-0 group in the mixed drawing")

    local mixed_path = t.tmp("mixed.svg")
    bs.write_svg(mixed_path, { plate, outline })
    local mf = assert(io.open(mixed_path, "rb"))
    t.eq(mf:read("*a"):sub(1, 4), "<svg")
    mf:close()

    t.raises(function() bs.write_svg_text({ plate, 5 }) end, "svg: only solids and profiles can be drawn")
    plate:close()
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
    -- A rectangle drawn above a sphere cores it: the ball with a square hole, then the core.
    local ball = bs.Solid.sphere(10)
    local cored = ball:split_by_profile(bs.Profile.rect(6, 6), { { 0, 0, 40 }, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } })
    t.eq(#cored, 2)
    local outside, inside, whole = cored[1]:mass().volume, cored[2]:mass().volume, ball:mass().volume
    t.ok(inside > 0 and inside < outside, "the core is the smaller body: " .. outside .. " " .. inside)
    t.ok(math.abs(outside + inside - whole) < 0.01 * whole, "the hole and the core add up to the ball")
    t.raises(function() ball:split_by_profile(bs.Profile.circle(4), { { 30, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }) end,
      "split_by_profile: ")
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
    local red = block:coloured("red").colour
    t.eq(red[1], 1); t.eq(red[2], 0); t.eq(red[3], 0)
    local lime = block:coloured("#0f0").colour
    t.eq(lime[2], 1)
    local ok, err = pcall(function() return block:coloured("notacolour") end)
    t.eq(ok, false)
    t.eq(tostring(err):find("a CSS colour name", 1, true) ~= nil, true)
    local svg = block:svg_text({ stroke = "red", background = "navy" })
    t.eq(svg:lower():find("#ff0000", 1, true) ~= nil, true)
  end)

  t.test("profile and edge colours", function()
    local rect = bs.Profile.rect(10, 4)
    t.eq(rect.colour, nil)
    local gold = rect:coloured("#cc9966")
    t.ok(all_near(gold.colour, { 0.8, 0.6, 0.4 }, 1e-12))
    t.eq(rect.colour, nil, "the original is untouched")
    t.ok(all_near(gold:translate(1, 1).colour, { 0.8, 0.6, 0.4 }, 1e-12), "carried by a move")
    t.raises(function() rect:coloured({ 2, 0, 0 }) end, "profile_coloured: r, g and b must be in 0%.%.1")
    t.eq(bs.Solid.extrude(gold, XY, 3).colour, nil, "a profile's colour stays 2D")

    local cube = bs.Solid.cuboid(10, 10, 10)
    t.eq(cube:edge_colour(0), nil)
    t.eq(#cube:edge_polyline_colours(), 0, "no edge paint: nothing to colour")
    local all_gold = cube:edges_coloured("#cc9966")
    local two = all_gold:edges_coloured({ 0.2, 0.4, 1 }, { cube.edges[1], 5 })
    t.ok(all_near(two:edge_colour(5), { 0.2, 0.4, 1 }, 1e-12), "the edge's own")
    t.ok(all_near(two:edge_colour(1), { 0.8, 0.6, 0.4 }, 1e-12), "the all-edges colour")
    t.ok(all_near(two:translate(1, 0, 0):edge_colour(5), { 0.2, 0.4, 1 }, 1e-12))
    -- An empty list colours no edge: it must not become null and colour everything.
    t.ok(all_near(all_gold:edges_coloured({ 1, 0, 0 }, {}):edge_colour(0), { 0.8, 0.6, 0.4 }, 1e-12),
      "an empty list coloured an edge")
    t.raises(function() cube:edges_coloured("#f00", { 12 }) end,
      "edges_coloured: edge 12 is not one of the solid's 12")
    t.raises(function() cube:edge_colour(12) end, "edge_colour: edge 12 is not one of the solid's 12")
    local colours = two:edge_polyline_colours()
    t.eq(#colours, #two:edge_polylines())
    local any_blue = false
    for _, c in ipairs(colours) do
      t.ok(c == false or all_near(c, { 0.8, 0.6, 0.4 }, 1e-12) or all_near(c, { 0.2, 0.4, 1 }, 1e-12))
      if c ~= false and all_near(c, { 0.2, 0.4, 1 }, 1e-12) then any_blue = true end
    end
    t.ok(any_blue, "no polyline read back the edge-specific colour")
    -- One edge painted, no all-edges colour: every other polyline is on no coloured edge.
    local one = cube:edges_coloured({ 0.2, 0.4, 1 }, { 5 })
    local painted, unpainted = 0, 0
    for _, c in ipairs(one:edge_polyline_colours()) do
      if c == false then
        unpainted = unpainted + 1
      else
        t.ok(all_near(c, { 0.2, 0.4, 1 }, 1e-12), "a painted polyline read back another colour")
        painted = painted + 1
      end
    end
    t.ok(painted >= 1, "the painted edge's polyline came back unpainted")
    t.ok(unpainted >= 1, "an unpainted polyline came back as a colour, not false")
    t.raises(function() two:edge_polyline_colours(-1) end,
      "edge_polyline_colours: tolerance must be positive and finite")
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

  t.test("two crossed pipes intersect on ellipse chains, coaxial pipes overlap on their wall", function()
    local tol = 1e-3
    local function off_a(p) return math.abs(math.sqrt(p[1] * p[1] + p[2] * p[2]) - 1) end
    local function off_b(p) return math.abs(math.sqrt(p[1] * p[1] + (p[3] - 3) * (p[3] - 3)) - 1) end
    -- Two equal pipes crossing at right angles: `a` up z, `b` along y through a's middle.
    local a = bs.Solid.cylinder(1, 6)
    local b = bs.Solid.cylinder(1, 6):rotate({ 0, 0, 3, 1, 0, 0 }, math.pi / 2)
    local phases = {}
    local found = a:intersect(b, tol, function(phase) phases[phase] = true end)
    t.ok(getmetatable(found) == bs.Intersection)
    -- Two analytic pipes must take the exact route, which reports only "meet" (a
    -- fallback would add the mesh route's "mesh" .. "curve").
    t.ok(phases.meet)
    t.ok(not phases.mesh and not phases.cull and not phases.cross and not phases.snap and not phases.curve)
    t.ok(#found.chains >= 2)
    t.eq(#found.overlaps, 0)
    local ellipses = 0
    for _, c in ipairs(found.chains) do
      t.ok(getmetatable(c) == bs.Chain)
      t.ok(type(c.closed) == "boolean" and type(c.tangent) == "boolean")
      t.ok(c.faces[1] >= 0 and c.faces[1] < a.faces and c.faces[2] >= 0 and c.faces[2] < b.faces)
      t.ok(#c.points >= 2 and #c.points[1] == 3)
      for _, p in ipairs(c.points) do t.ok(off_a(p) < 50 * tol and off_b(p) < 50 * tol) end
      if c.curve ~= nil then
        t.ok(getmetatable(c.curve) == bs.Curve)
        t.ok(c.curve.kind == "ellipse" or c.curve.kind == "nurbs")
        if c.curve.kind == "ellipse" then
          ellipses = ellipses + 1
          local cv, tt = c.curve, (c.curve.t0 + c.curve.t1) / 2   -- the curve's own point, mid-chain
          local q = {}
          for k = 1, 3 do q[k] = cv.origin[k] + cv.x[k] * cv.radius * math.cos(tt) + cv.y[k] * cv.radius2 * math.sin(tt) end
          t.ok(off_a(q) < 50 * tol and off_b(q) < 50 * tol)
        end
      end
      t.ok(tostring(c):find("^Chain%(points=") ~= nil)
    end
    t.ok(ellipses > 0)
    -- Apart: nothing, and not an error. A bad tolerance is refused in the kernel's words.
    local apart = a:intersect(b:translate(10, 0, 0))
    t.eq(#apart.chains, 0)
    t.eq(#apart.overlaps, 0)
    t.raises(function() a:intersect(b, 0.0) end, "intersect: tolerance must be positive and finite")
    -- Two coaxial pipes overlapping in height share a wall band: rings on that wall.
    local lower = bs.Solid.cylinder(1, 4)
    local upper = bs.Solid.cylinder(1, 4):translate(0, 0, 2)
    local shared = lower:intersect(upper, tol)
    t.ok(#shared.overlaps >= 1)
    local o = shared.overlaps[1]
    t.ok(getmetatable(o) == bs.Overlap)
    t.ok(o.faces[1] >= 0 and o.faces[1] < lower.faces and o.faces[2] >= 0 and o.faces[2] < upper.faces)
    t.ok(#o.loops >= 1)
    for _, ring in ipairs(o.loops) do
      t.ok(#ring >= 3)
      for _, p in ipairs(ring) do t.ok(off_a(p) < 50 * tol and p[3] >= 2 - 50 * tol and p[3] <= 4 + 50 * tol) end
    end
    t.eq(tostring(o), ("Overlap(faces=(%d, %d), loops=%d)"):format(o.faces[1], o.faces[2], #o.loops))
  end)

  t.test("boxes_apart on the 45 degree case", function()
    -- Two unit boxes (bounds_box.rs's own fixture), the second turned 45 degrees about
    -- z: corner to face apart along x by more than sqrt(2) + 1 -> apart; closer -> not
    -- apart, even though their world AABBs already overlap there.
    local unit = bs.Box({ -1, -1, -1 }, { 1, 1, 1 })
    local identity = { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 }
    local function rot_z(degrees, origin)
      local r = math.rad(degrees)
      return { origin[1], origin[2], origin[3], math.cos(r), math.sin(r), 0, -math.sin(r), math.cos(r), 0, 0, 0, 1 }
    end
    t.ok(bs.boxes_apart(unit, identity, unit, rot_z(45, { 2.5, 0, 0 })))
    t.ok(not bs.boxes_apart(unit, identity, unit, rot_z(45, { 2.3, 0, 0 })))
    t.ok(unit:moved(identity):overlaps(unit:moved(rot_z(45, { 2.3, 0, 0 }))))
    t.ok(not bs.boxes_apart(unit, identity, unit, { 2, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 }))
  end)

  t.test("the collider finds overlapping parts and rebuilds the overlap", function()
    local xy0 = { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 }
    local a = bs.Solid.cuboid(2, 2, 2)
    local b = bs.Solid.cuboid(2, 2, 2):translate(1, 0, 0)
    local collider = bs.Collider({ a, b }, 0.05)
    t.eq(collider.group_count, 2)
    local stats0 = collider.stats
    t.eq(stats0.considered, 0)
    local hits = collider:check({ xy0, xy0 })
    t.eq(#hits, 1)
    local hit = hits[1]
    t.ok(getmetatable(hit) == bs.CollisionHit)
    t.ok(hit.overlap and hit.kind == "overlap" and hit.text == "")
    t.eq(hit.a, 0)
    t.eq(hit.b, 1)
    t.ok(hit.depth > 0)
    t.ok(#hit.positions > 0 and #hit.positions[1] == 3)
    t.ok(#hit.normals == #hit.positions)
    local overlap = hit:solid()
    t.ok(getmetatable(overlap) == bs.Solid and overlap.faces > 0)
    local stats1 = collider.stats
    t.eq(stats1.considered, 1)
    t.ok(stats1.confirmed + stats1.closed_form + stats1.meshed >= 1)
    -- apart: no hits, sharing the group's own frame count
    local far = collider:check({ xy0, { 100, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 } })
    t.eq(#far, 0)
    collider:close()
    t.raises(function() collider:check({ xy0, xy0 }) end, "collider: closed")
  end)

  t.test("a collision hit's solid survives the collider closing", function()
    -- solid() keeps the collisions handle (not the collider) alive: closing the
    -- collider itself must not take the hit's own rebuild with it.
    local xy0 = { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 }
    local a = bs.Solid.cuboid(2, 2, 2)
    local b = bs.Solid.cuboid(2, 2, 2):translate(1, 0, 0)
    local collider = bs.Collider({ a, b })
    local hits = collider:check({ xy0, xy0 })
    collider:close()
    t.eq(#hits, 1)
    local overlap = hits[1]:solid()
    t.ok(overlap.faces > 0)
  end)

  t.test("the collider refuses a part that is not a closed solid", function()
    local sheet = bs.Solid.cuboid(2, 2, 2):face_sheet(0)
    t.raises(function() bs.Collider({ sheet }) end, "collider_new: part 0 is not a closed solid")
  end)

  t.test("the collider refuses a short groups list", function()
    local a = bs.Solid.cuboid(2, 2, 2)
    local b = bs.Solid.cuboid(2, 2, 2):translate(1, 0, 0)
    t.raises(function() bs.Collider({ a, b }, 0.05, { 0 }) end,
      "Collider: groups must have one entry per solid %(2 solids, 1 groups%)")
  end)

  t.test("a line through a cuboid hits twice and cuts three pieces", function()
    local box = bs.Solid.cuboid(10, 20, 30)
    local line = bs.Profile.path({ -20, 0 }):line_to(20, 0):end_open()
    local phases = {}
    local found = box:hits(line, XY, 0.05, function(phase) phases[phase] = true end)
    t.eq(getmetatable(found), bs.SolidHits)
    t.eq(tostring(found), "SolidHits(hits=2, pieces=3)")
    t.ok(phases.mesh and phases.pieces)
    for k, h in ipairs(found.hits) do
      t.eq(h.run, false)
      t.eq(h.touch, false)
      t.near(h.start[1], ({ -5, 5 })[k], 0.05)
      t.eq(h.a_start.segment, 0)
      t.eq(h.a_start.face, bs.NONE)
      t.ok(h.b_start.face ~= bs.NONE and h.b_start.u == h.b_start.u and h.b_start.v == h.b_start.v)
    end
    local p = found.pieces
    t.eq(getmetatable(p[2]), bs.Piece)
    t.eq(getmetatable(p[2].profile), bs.Profile)
    t.eq(p[1].inside, false)
    t.eq(p[2].inside, true)
    t.eq(p[3].inside, false)
    t.eq(p[1].start.t, 0)
    t.eq(p[3]["end"].t, 1)
    t.eq(p[1]["end"].t, p[2].start.t, "the pieces run head to tail")
    t.eq(p[2]["end"].t, p[3].start.t, "the pieces run head to tail")
    local b = bs.Solid.extrude_open(p[2].profile, XY, 1).bounds
    t.near(b[1][1], -5, 0.05, "the middle piece starts on the box")
    t.near(b[2][1], 5, 0.05, "the middle piece ends on the box")
    t.ok(bs.SweepPath.along(p[2].profile, XY, 0.05, true))
    -- A loop no hit cuts is one piece, outside here; an open sheet has no pieces.
    local far = box:hits(bs.Profile.circle(1), { 100, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 })
    t.eq(#far.hits, 0)
    t.eq(#far.pieces, 1)
    t.eq(far.pieces[1].inside, false)
    local sheet = bs.Solid.face(bs.Profile.rect(20, 20), XY)
    local across = sheet:hits(bs.Profile.path({ 0, -20 }):line_to(0, 20):end_open(), { 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0 })
    t.ok(#across.hits >= 1)
    t.eq(#across.pieces, 0)
    t.raises(function() box:hits(line, XY, 0.0) end, "solid_profile_hits: tolerance must be positive and finite")
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
    -- A five-pointed star: ten walls and two caps.
    local star = bs.Solid.extrude(bs.Profile.star({ 0, 0 }, 10, 4, 5), XY, 2)
    t.eq(star.faces, 12)
    t.ok(star:is_watertight())
    e = t.raises(function() bs.Profile.star({ 0, 0 }, 10, 10, 5) end)
    t.eq(e.message, "profile_star: the inner radius must be under the outer")
  end)

  t.test("text is set as profiles with curved walls", function()
    -- An `i` is two shapes and an `o` one; the `o` extrudes to a watertight ring
    -- whose walls meet the caps on splines: the font's curves are kept.
    local word = bs.Profile.text("io", 10)
    t.eq(#word, 3)
    local ring = bs.Solid.extrude(word[3], XY, 2)
    t.ok(ring:is_watertight())
    local spline = false
    for _, edge in ipairs(ring.edges) do
      if edge.kind == "nurbs" then spline = true end
    end
    t.ok(spline)
    -- An unknown family sets in the bundled face; the same face as bytes sets the same letter.
    local unknown = bs.Profile.text("g", 10, "No Such Family Anywhere")
    t.eq(#unknown, 1)
    local font = t.fixture("crates/cadaclysm-text/fonts/LiberationSans-Regular.ttf")
    if font then
      local file = assert(io.open(font, "rb"))
      local bytes = file:read("*a")
      file:close()
      local by_bytes = bs.Profile.text("g", 10, nil, nil, nil, nil, nil, bytes)
      t.eq(bs.Solid.extrude(by_bytes[1], XY, 1).faces, bs.Solid.extrude(unknown[1], XY, 1).faces)
    end
    t.eq(#bs.Profile.text("", 10), 0)
    local e = t.raises(function() bs.Profile.text("x", 0) end)
    t.eq(e.message, "profile_text: the size must be positive and finite")
    e = t.raises(function() bs.Profile.text("x", 10, nil, nil, nil, nil, nil, "not a font") end)
    t.eq(e.message, "profile_text: the font bytes are not a font")
  end)

  t.test("mesh and edge views own their tessellation: a re-mesh, bounds_at, edge_polyline_colours and the solid's close leave them reading the same numbers", function()
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
    local kept_p0, kept_n0, kept_i0 = positions:get(0), normals:get(0), indices:get(0)
    -- The same tolerance again is a fresh held tessellation of its own.
    local again = ball:mesh(0.05)
    t.eq(again.size, positions.size)
    t.eq(positions:get(0), again:get(0))
    t.ok(positions.valid)
    -- Another tolerance re-meshes the solid's own cache; the views held above own their
    -- tessellation, so nothing about them changes.
    local coarse = ball:mesh(0.5)
    t.ok(coarse.size < positions.size, "coarser is fewer vertices")
    t.ok(positions.valid)
    t.eq(positions:get(0), kept_p0)
    t.eq(indices:get(0), kept_i0)
    t.eq(normals:get(0), kept_n0)
    -- Back at 0.05 is yet another held tessellation of its own: the earlier ones read on.
    local back = ball:mesh(0.05)
    t.eq(positions:get(0), kept_p0)
    t.ok(coarse.valid)
    t.eq(back.size, again.size)
    -- bounds_at and edge_polylines mesh the solid's own cache too; views already held
    -- ignore it.
    local runs = ball:edge_polylines(0.05)
    t.ok(back.valid, "the same tolerance keeps reading fine")
    ball:bounds_at(0.2)
    t.ok(back.valid, "bounds_at at another tolerance does not touch a view already held")
    for _, r in ipairs(runs) do t.ok(r.valid) end
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
    -- edge_polyline_colours reads the solid's own cache too, at another tolerance, even
    -- where the solid has no edge paint at all (the branch that copies out an empty
    -- colour list): the view held from edge_polylines above owns its own tessellation and
    -- keeps reading regardless.
    local edge0_first = edges[1]:get(0)
    t.ok(edges[1].valid)
    box:edge_polyline_colours(0.5)
    t.ok(edges[1].valid,
      "edge_polyline_colours at a new tolerance touched the earlier edge_polylines view")
    t.eq(edges[1]:get(0), edge0_first)
    -- Closing the solid does not touch a view already held: it owns its tessellation, not
    -- the solid's.
    box:close()
    t.eq(edges[1]:get(0), edge0_first)
    t.ok(edges[1].valid)
    t.eq(#kept, indices.size)
    t.raises(function() box:mesh() end, "solid: closed")
  end)

  t.test("mesh64/bounds_at64 agree with their float twins, from the same cache and generation", function()
    local ball = bs.Solid.sphere(5)
    local p32, n32, i32 = ball:mesh(0.05)
    local p64, n64, i64 = ball:mesh64(0.05)
    t.eq(p64.dtype, "float64")
    t.eq(n64.dtype, "float64")
    t.eq(i64.dtype, "uint32")
    t.eq(p64.shape[1], p32.shape[1])
    t.eq(i64.size, i32.size)
    -- mesh64's index view is the very same tessellation's, so the same generation.
    t.eq(i64:get(0), i32:get(0))
    local x64, y64, z64 = p64:row(0)
    local x32, y32, z32 = p32:row(0)
    t.eq(tonumber(ffi.cast("float", x64)), x32)
    t.eq(tonumber(ffi.cast("float", y64)), y32)
    t.eq(tonumber(ffi.cast("float", z64)), z32)
    local lo64, hi64 = ball:bounds_at64(0.05)[1], ball:bounds_at64(0.05)[2]
    local lo32, hi32 = ball:bounds_at(0.05)[1], ball:bounds_at(0.05)[2]
    for k = 1, 3 do
      t.near(lo64[k], lo32[k], 1e-6)
      t.near(hi64[k], hi32[k], 1e-6)
    end
    -- Another tolerance re-meshes the solid's own cache; mesh64's held tessellation is its
    -- own and keeps reading.
    local kept_p64_0 = p64:get(0)
    ball:mesh(0.5)
    t.eq(p64:get(0), kept_p64_0)
    t.ok(p64.valid)
    ball:close()
    t.raises(function() ball:mesh64() end, "solid: closed")
  end)

  t.test("mesh64/bounds_at64 keep coordinates far from the origin that mesh()/bounds_at cannot", function()
    local far = bs.Solid.cuboid(2, 2, 2):translate(1000000.123456789, -2600000.987654321, 450.5)
    local p64, _, i64 = far:mesh64(0.05)
    local p32, _, i32 = far:mesh(0.05)
    t.eq(i64.size, i32.size)
    t.eq(p64.shape[1], p32.shape[1])
    local kept_y, saw_unfloatable = nil, false
    for i = 0, p64.shape[1] - 1 do
      local _, y = p64:row(i)
      if math.abs(y - (-2600000.987654321 - 1)) < 1e-6 then kept_y = y end
      if math.abs(tonumber(ffi.cast("float", y)) - y) > 1e-3 then saw_unfloatable = true end
    end
    t.ok(kept_y ~= nil, "mesh64 lost the far low-y corner")
    t.ok(saw_unfloatable, "mesh64 carries no coordinate float cannot hold, so this test cannot tell mesh64 from mesh widened")
    local lo64 = far:bounds_at64(0.05)[1]
    local lo32 = far:bounds_at(0.05)[1]
    t.near(lo64[2], -2600001.987654321, 1e-6, "bounds_at64 lost the far corner")
    t.ok(math.abs(lo64[2] - lo32[2]) > 1e-3, "bounds_at64 agrees with bounds_at narrowed to the bit, so it is not exact where float is not")
    far:close()
  end)

  t.test("a view keeps its tessellation alive under collection pressure", function()
    local positions, _, indices = bs.Solid.sphere(3):mesh(0.1)   -- the solid itself is dropped
    local views = {}
    for i = 1, 300 do
      local s = bs.Solid.cuboid(1, 1, 1):translate(i, 0, 0)
      if i % 50 == 0 then views[#views + 1] = { s:mesh(0.1) } end
      bs.Profile.rect(1, 1)
      bs.SweepPath.at({ 0, 0, 0 }):line_to({ 0, 0, 1 })
    end
    for _ = 1, 3 do collectgarbage() end
    t.ok(positions.valid)
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

  -- A quarter turn about z then 100 along x, as the twelve numbers a Frame is here
  -- (origin, x, y, z) rather than the reader's sixteen: (x, y, z) -> (100 - y, x, z).
  local TURNED = bs.Frame({ 100, 0, 0 }, { 0, 1, 0 }, { -1, 0, 0 }, { 0, 0, 1 })
  local function turned(x, y, z) return 100 - y, x, z end

  t.test("a solid's FEM mesh: the plate's arrays, its census, its quality and its owned .msh text", function()
    local plate = bs.Solid.extrude(plate_outline(), XY, 6)
    local mesh = plate:fem_mesh(0.05)
    t.eq(getmetatable(mesh), bs.FemMesh)
    t.eq(mesh.face_count, 12)
    -- 2026-09-26, d2f866b6 (filler interior at six rows, 15-degree turn bound): 864 -> 504 nodes, 1732 -> 1012 triangles.
    t.eq(mesh.node_count, 504)
    t.eq(mesh.triangle_count, 1012)
    t.eq(#mesh.edges, 30)
    t.eq(#mesh.vertices, 20)
    t.eq(mesh.watertight, true)
    t.eq(mesh.from_mesh, false, "every solid here has a brep behind it")
    t.eq(#mesh.open_edges, 0)
    t.eq(#mesh.folded_edges, 0)
    t.eq(#mesh.crossings, 0)
    t.ok(mesh.min_angle > 0 and mesh.min_angle < 60, tostring(mesh.min_angle))
    t.near(mesh.longest_edge, 80.22468448052632, 1e-9)
    t.ok(mesh.worst_triangle < mesh.triangle_count)
    for i = 0, mesh.triangle_count * 3 - 1 do
      t.ok(mesh.triangles[i] < mesh.node_count, "a triangle index past the nodes")
    end
    for i = 0, mesh.triangle_count - 1 do
      t.ok(mesh.triangle_face[i] < mesh.face_count, "a triangle_face past the faces")
    end
    -- Read once: `edges` and `vertices` are fields computed when read, one ABI call a row.
    local edges, vertices = mesh.edges, mesh.vertices
    local kinds = {}
    for i = 0, mesh.node_count - 1 do
      local kind, entity = mesh.node_kind[i], mesh.node_entity[i]
      kinds[kind] = true
      local bound = (kind == 0 and #vertices) or (kind == 1 and #edges) or (kind == 2 and mesh.face_count)
      t.ok(bound and entity < bound, ("node %d: kind %d entity %d"):format(i, kind, entity))
    end
    t.ok(kinds[0] and kinds[1] and kinds[2], "a solid's nodes lie on vertices, edges and faces")
    -- This library's text is **owned** and released here, where the reader's is a
    -- borrowed slot on its own handle: two asks are two independent strings, so the
    -- second must read the same length and neither may have been freed under the other.
    local msh = mesh:msh_text()
    t.eq(msh:sub(1, 11), "$MeshFormat")
    local again = mesh:msh_text()
    t.eq(#again, #msh, "a second msh_text read a different length: the first was freed under it")
    t.eq(again:sub(1, 11), "$MeshFormat")
    local path = t.tmp("plate-fem.msh")
    mesh:save_msh(path)
    local f = assert(io.open(path, "rb"))
    local written = f:read("*a")
    f:close()
    t.ok(#written >= #msh / 2, ("save_msh wrote %d bytes where msh_text is %d"):format(#written, #msh))
    t.eq(mesh.freed, false)
    mesh:free()
    mesh:free()
    t.eq(mesh.freed, true)
    t.ok(tostring(mesh):match("freed"), tostring(mesh))
    local calls = {
      function() return mesh:msh_text() end,
      function() return mesh:save_msh(t.tmp("never-written.msh")) end,
      function() return mesh.edges end,
      function() return mesh.vertices end,
      function() return mesh.open_edges end,
      function() return mesh.folded_edges end,
      function() return mesh.crossings end,
    }
    t.eq(#calls, 7, "a call that takes the handle was added without being swept here")
    for _, call in ipairs(calls) do
      local err = t.raises(call, "fem mesh: freed")
      t.ok(is_build_error(err), tostring(err))
    end
    -- Not refused, and documented rather than enforced: the arrays and the summary are
    -- plain fields filled when the mesh was built. Nothing here dereferences one.
    -- 864 -> 504 on 2026-09-26, d2f866b6 (filler interior at six rows, 15-degree turn bound).
    t.eq(mesh.node_count, 504, "the counts are Lua numbers of our own and outlive the handle")
    t.ok(mesh.nodes ~= nil, "the pointer field is still there, and now points at freed memory")
    plate:close()
  end)

  t.test("fem crossings through the kernel's own open of a file", function()
    -- `samples/dented-box.stp` is a closed B-rep box whose top dips through its own
    -- floor, 296 pairs measured 2026-09-26 -- the same number the reader test "a FEM
    -- census reads its own count through its own entry point" reads over the same file,
    -- which must agree with it.
    local solid = bs.Solid.open(t.fixture("samples/dented-box.stp"))
    local mesh = solid:fem_mesh()
    t.eq(mesh.watertight, true)
    local crossings = mesh.crossings
    t.eq(#crossings, 296)
    t.ok(crossings[1][1] < crossings[1][2], "the first pair is not a < b")
    mesh:free()
    solid:close()
  end)

  t.test("max_size bounds the boundary and only targets the interior", function()
    local plate = bs.Solid.extrude(plate_outline(), XY, 6)
    local plain = plate:fem_mesh(0.05)
    local capped = plate:fem_mesh(0.05, 3.0)
    t.ok(capped.node_count > plain.node_count,
      ("max_size 3 gave %d nodes against %d"):format(capped.node_count, plain.node_count))
    t.ok(capped.longest_edge < plain.longest_edge)
    -- Loose on purpose: max_size bounds the boundary segments and merely *targets* the
    -- interior (measured at 1.03x on an unevenly parameterised face), so a tighter pin
    -- would assert what the ABI does not promise.
    t.ok(capped.longest_edge <= 3.0 * 1.05, tostring(capped.longest_edge))
    plain:free(); capped:free()
    plate:close()
  end)

  t.test("a cylinder's seam edge, and an open sheet's rim: both faces, and the census not asked", function()
    local cyl = bs.Solid.cylinder(5, 10)
    local mesh = cyl:fem_mesh(0.05)
    t.eq(mesh.face_count, 3)
    t.eq(#mesh.edges, 5)
    t.eq(#mesh.vertices, 4)
    t.eq(mesh.watertight, true)
    local seams = 0
    for i, e in ipairs(mesh.edges) do
      t.ok(e.faces[1] ~= bs.NONE and e.faces[2] ~= bs.NONE,
        ("edge %d of a closed solid bounds only one face"):format(i - 1))
      if e.seam then
        seams = seams + 1
        t.eq(e.faces[1], e.faces[2], "a seam is one face bounding its edge twice")
      end
    end
    t.eq(seams, 1, "a cylinder's wall has one seam")
    for _, v in ipairs(mesh.vertices) do
      t.eq(v.has_position, true)
      t.near(math.sqrt(v.point[1] * v.point[1] + v.point[2] * v.point[2]), 5, 1e-9, "a rim vertex off the cylinder")
    end
    mesh:free()
    cyl:close()
    -- An open sheet: watertight false with **both** censuses empty, which is the trio
    -- that says "not asked", and every rim edge with one real face and NONE beside it.
    local sheet = bs.Solid.face(bs.Profile.rect(40, 20):with_hole(bs.Profile.circle(4)), XY)
    local rim = sheet:fem_mesh(0.05)
    t.eq(rim.face_count, 1)
    t.eq(rim.watertight, false)
    t.eq(#rim.open_edges, 0, "an open body's rim is not a crack, so the census is not run")
    t.eq(#rim.folded_edges, 0)
    t.eq(#rim.edges, 6)
    for i, e in ipairs(rim.edges) do
      t.eq(e.faces[1], 0, ("rim edge %d does not lie on face 0"):format(i - 1))
      t.eq(e.faces[2], bs.NONE, ("rim edge %d reads a second face: 0 is a real face, NONE is the sentinel"):format(i - 1))
    end
    rim:free()
    sheet:close()
  end)

  t.test("a Frame places a solid's FEM mesh, twelve numbers or four triples, and a bad tolerance raises", function()
    -- 20 x 10 x 4, **translated off the axis of the turn in the plane it acts in**: a
    -- cuboid is centred on the origin, and for a quarter turn about z a transposed 3x3
    -- block is then the correct map composed with a 180-degree turn about the frame's
    -- own origin -- a symmetry of a centred, axis-aligned corner set, so the check goes
    -- blind. An offset along z alone does not fix it: it must be in x or y.
    local box = bs.Solid.cuboid(20, 10, 4):translate(30, 7, 5)
    local plain = box:fem_mesh(0.05)
    local function span(mesh)
      local min, max = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
      for i = 0, mesh.node_count - 1 do
        for k = 1, 3 do
          local v = mesh.nodes[3 * i + k - 1]
          min[k], max[k] = math.min(min[k], v), math.max(max[k], v)
        end
      end
      return ("%g %g %g %g %g %g"):format(min[1], min[2], min[3], max[1], max[2], max[3])
    end
    t.eq(plain.node_count, 8)
    t.eq(span(plain), "20 2 3 40 12 7", "the unplaced cuboid is not where translate put it")
    local placed = box:fem_mesh(0.05, 0, TURNED)
    t.eq(placed.node_count, 8)
    -- Every corner at its image. Transposed, the spans are disjoint in x
    -- (102..112 against 88..98), so any one corner catches it; the loop is depth.
    for i = 0, plain.node_count - 1 do
      local x, y, z = plain.nodes[3 * i], plain.nodes[3 * i + 1], plain.nodes[3 * i + 2]
      local ex, ey, ez = turned(x, y, z)
      local found = false
      for k = 0, placed.node_count - 1 do
        if math.abs(placed.nodes[3 * k] - ex) < 1e-9 and math.abs(placed.nodes[3 * k + 1] - ey) < 1e-9
          and math.abs(placed.nodes[3 * k + 2] - ez) < 1e-9 then
          found = true
          break
        end
      end
      t.ok(found, ("the frame did not send (%g, %g, %g) to (%g, %g, %g) -- the placed nodes span %s")
        :format(x, y, z, ex, ey, ez, span(placed)))
    end
    t.eq(span(placed), "88 20 3 98 40 7", "the placed nodes do not span the turn of the box")
    -- The same frame as twelve bare numbers and as four triples: `frame_arg`'s three forms.
    local flat = box:fem_mesh(0.05, 0, { 100, 0, 0, 0, 1, 0, -1, 0, 0, 0, 0, 1 })
    local triples = box:fem_mesh(0.05, 0, { { 100, 0, 0 }, { 0, 1, 0 }, { -1, 0, 0 }, { 0, 0, 1 } })
    t.eq(span(flat), span(placed))
    t.eq(span(triples), span(placed))
    t.raises(function() box:fem_mesh(0.05, 0, { 1, 2, 3 }) end, "frame: expected 12 numbers, got 3")
    plain:free(); placed:free(); flat:free(); triples:free()
    -- Every solid here has a brep, so this side refuses what the reader's mesh-only
    -- path passes through -- in the library's own words.
    t.raises(function() box:fem_mesh(0) end, "tolerance must be finite and > 0")
    t.raises(function() box:fem_mesh(0.05, -1) end, "max_size must be finite and >= 0")
    box:close()
    t.raises(function() box:fem_mesh(0.05) end, "solid: closed")
  end)

  t.test("a FEM mesh progress callback hears meshing and welding, and one that raises fails the call", function()
    local plate = bs.Solid.extrude(plate_outline(), XY, 6)
    local phases = {}
    local mesh = plate:fem_mesh(0.05, 0, nil, function(phase, done, total)
      phases[phase] = true
      t.ok(done <= total, ("%s: %s of %s"):format(phase, tostring(done), tostring(total)))
    end)
    t.ok(phases.meshing, "no meshing phase was reported")
    t.ok(phases.welding, "no welding phase was reported")
    mesh:free()
    local err = t.raises(function()
      plate:fem_mesh(0.05, 0, nil, function() error("stop here") end)
    end, "stop here")
    t.ok(err ~= nil)
    t.eq(plate.faces, 12, "the library is fine after a callback raised")
    plate:close()
  end)

  t.test("a FEM mesh is its own handle: re-meshing and closing its solid leave it alone", function()
    local plate = bs.Solid.extrude(plate_outline(), XY, 6)
    local positions = plate:mesh(0.05)
    local kept_p0 = positions:get(0)
    local mesh = plate:fem_mesh(0.05)
    local first = mesh.nodes[0]
    -- Meshing again at another tolerance re-meshes the solid's own cache -- asserted here
    -- in the same breath, so the next lines mean something. The tessellation view owns
    -- its tessellation and is untouched by it, exactly as a FEM mesh -- its own handle,
    -- not in that cache -- always was.
    plate:mesh(0.5)
    t.eq(positions:get(0), kept_p0, "the tessellation view should still read")
    t.ok(positions.valid)
    t.eq(mesh.nodes[0], first)
    t.eq(mesh.node_count, 504)  -- 864 -> 504 on 2026-09-26, d2f866b6 (filler interior at six rows, 15-degree turn bound)
    t.ok(#mesh:msh_text() > 0)
    t.eq(#mesh.edges, 30)
    plate:close()
    -- And the solid does not own it: closing the solid neither frees nor stales it.
    t.eq(mesh.nodes[0], first)
    t.eq(mesh.node_count, 504)  -- 864 -> 504 on 2026-09-26, d2f866b6 (filler interior at six rows, 15-degree turn bound)
    t.ok(#mesh:msh_text() > 0, "the mesh stopped writing once its solid closed")
    t.eq(#mesh.vertices, 20)
    mesh:free()
  end)

  t.test("a FEM mesh held keeps its own arrays alive under collection pressure", function()
    local box = bs.Solid.cuboid(10, 10, 10)
    local kept = box:fem_mesh(0.05)
    local first = kept.nodes[0]
    for i = 1, 40 do
      local other = bs.Solid.cuboid(1, 1, 1):translate(i, 0, 0):fem_mesh(0.05)
      if i % 2 == 0 then other:free() end       -- the rest are left to the collector
      bs.Profile.rect(1, 1)
    end
    for _ = 1, 3 do collectgarbage() end
    t.eq(kept.freed, false)
    t.eq(kept.nodes[0], first, "the arrays moved or were freed under a mesh still held")
    t.ok(#kept:msh_text() > 0)
    kept:free()
    box:close()
    t.eq(bs.Solid.cuboid(1, 1, 1).faces, 6, "the library is fine after the collector freed everything")
  end)

  t.test("FemEdge:chains cuts the chain where runs says, turning the ABI's zero-based offsets into Lua's own slices", function()
    -- Directly, because no fixture here has a broken chain: an edge's `runs` are the
    -- ABI's offsets **from zero** into a Lua array that counts **from one**, and a
    -- single-run edge cannot tell a wrong conversion from a right one (index 0 of a Lua
    -- array is nil, and appending nil appends nothing). Two runs can.
    local function chains(nodes, runs)
      local out = {}
      for _, chain in ipairs(setmetatable({ nodes = nodes, runs = runs }, bs.FemEdge):chains()) do
        out[#out + 1] = table.concat(chain, ",")
      end
      return table.concat(out, " | ")
    end
    t.eq(chains({ 5, 6, 7, 8, 9 }, { 0 }), "5,6,7,8,9", "one run is the whole chain")
    t.eq(chains({ 5, 6, 7, 8, 9 }, { 0, 2 }), "5,6 | 7,8,9", "a break at offset 2 cuts after the second node")
    t.eq(chains({ 5, 6, 7, 8, 9 }, { 0, 1, 4 }), "5 | 6,7,8 | 9")
    t.eq(chains({ 5, 6 }, { 0, 1 }), "5 | 6")
  end)

  t.test("a reflector is drawn and revolved from a parabola", function()
    -- A dish 100 wide, focal length 20, opening up: from rim to rim on the parabola,
    -- closed by the rim line, revolved about the axis -- one NURBS wall, watertight.
    local dish = bs.Profile.parabola({ 0, 0 }, { 0, 1 }, 20, 0, 50):line_to(0, 31.25):line_to(0, 0):end_()
    local bowl = bs.Solid.revolve(dish, { { 0, 0, 0 }, { 0, 1, 0 } }, 2 * pi)
    t.ok(bowl:is_watertight())
    t.eq(#count_faces(bowl, "revolution") > 0, true)
    -- The dish's own arc by vertex, closed by a second parabola through the same rim
    -- points with a focus beyond the chord -- the arch over the top, not the dish again
    -- (a focus at (0, 20) would rebuild the identical arc and retrace it, per
    -- parabola_by_focus's own doc comment on this reflector).
    local p = bs.Profile.path({ -50, 31.25 }):parabola_by_vertex(50, 31.25, { 0, 0 })
      :parabola_by_focus(-50, 31.25, { 0, 40 }):end_()
    t.ok(bs.Solid.extrude(p, XY, 2):is_watertight())
    -- A conic with a quarter circle's weight.
    local q = bs.Profile.path({ 10, 0 }):conic_to(0, 10, { 10, 10 }, math.cos(pi / 4)):line_to(0, 0):line_to(10, 0):end_()
    t.eq(bs.Solid.extrude(q, XY, 2).faces, 5)
    t.raises(function() bs.Profile.path({ 0, 0 }):conic_to(2, 0, { 1, 0 }, 1) end,
      "^path_conic_to: the control point lies on the chord$")
    t.raises(function() bs.Profile.path({ 0, 0 }):hyperbola_to(2, 0, { 1, 1 }, 1) end,
      "^hyperbola_to: the weight must be over 1 %(1 is a parabola, under 1 an ellipse%)$")
    t.raises(function() bs.Profile.parabola({ 0, 0 }, { 0, 0 }, 1, -1, 1) end,
      "^path_parabola: the axis direction is zero$")
  end)

  -- Assemblies: Assembly, Solid:named and Solid.name, at parity with the Python
  -- reference's _shared_assembly() and the tests built on it.
  t.test("an assembly places parts and sub-assemblies, numbers duplicate names, "
    .. "writes STEP once per part, and refuses a cycle, a duplicate name, a mirrored frame and an empty assembly", function()
    local bolt = bs.Solid.cylinder(1, 6):named("bolt")
    local plate = bs.Solid.cuboid(20, 10, 2):named("plate"):coloured({ 1, 0.5, 0 })
    local bracket = bs.Assembly("bracket")
    local plate_placement = bracket:place(plate, XY)
    local bolt1_placement = bracket:place(bolt, { 5, 5, 2, 1, 0, 0, 0, 1, 0, 0, 0, 1 })
    local bolt2_placement = bracket:place(bolt, { 15, 5, 2, 1, 0, 0, 0, 1, 0, 0, 0, 1 })
    t.eq(plate_placement, "plate")
    t.eq(bolt1_placement, "bolt")
    t.eq(bolt2_placement, "bolt 2")   -- fact 1

    local frame = bs.Assembly("frame")
    local left_placement = frame:place(bracket, { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 }, "left")
    local right_placement = frame:place(bracket, { 100, 0, 0, 0, 1, 0, -1, 0, 0, 0, 0, 1 }, "right")
    local root_bolt_placement = frame:place(bolt, { 50, 50, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 })
    t.eq(left_placement, "left")
    t.eq(right_placement, "right")
    t.eq(root_bolt_placement, "bolt")   -- fact 1

    local frame_step_text = frame:step_text()
    local function count_of(haystack, needle)
      local n, start = 0, 1
      while true do
        local from = haystack:find(needle, start, true)
        if not from then return n end
        n, start = n + 1, from + #needle
      end
    end
    t.eq(count_of(frame_step_text, "=MANIFOLD_SOLID_BREP("), 2)
    t.eq(count_of(frame_step_text, "=PRODUCT("), 4)
    t.eq(count_of(frame_step_text, "=NEXT_ASSEMBLY_USAGE_OCCURRENCE("), 6)   -- fact 2
    t.ok(frame_step_text:find("'left'", 1, true) and frame_step_text:find("'right'", 1, true)
      and frame_step_text:find("'bolt 2'", 1, true))   -- fact 3

    -- Read-back, through the same reader door as Solid:to_scene -- structure only, at this
    -- (pre-late-placement) text: one root "frame", two "bracket" containers each holding
    -- plate/bolt/bolt, and one root-level "bolt". The world origins are Python's to check.
    local cad = require("cadaclysm")
    local read_scene = cad.open_memory(frame_step_text, "stp", nil, "frame.stp")
    local roots = read_scene.roots
    t.eq(#roots, 1)
    t.eq(roots[1].name, "frame")
    local root_children = roots[1].children
    t.eq(#root_children, 3)   -- fact 11
    local containers, root_bolts = {}, {}
    for _, c in ipairs(root_children) do
      if c.name == "bracket" then containers[#containers + 1] = c end
      if c.name == "bolt" then root_bolts[#root_bolts + 1] = c end
    end
    t.eq(#containers, 2)
    t.eq(#root_bolts, 1)
    for _, container in ipairs(containers) do
      local names = {}
      for _, c in ipairs(container.children) do names[#names + 1] = c.name end
      table.sort(names)
      t.eq(table.concat(names, ","), "bolt,bolt,plate")
    end

    -- A late placement into bracket shows up wherever bracket is placed (left and right both).
    bracket:place(bolt, { 10, 8, 2, 1, 0, 0, 0, 1, 0, 0, 0, 1 })
    t.eq(count_of(frame:step_text(), "=NEXT_ASSEMBLY_USAGE_OCCURRENCE("), 7)   -- fact 4

    -- A cycle, a duplicate placement name, a mirrored raw frame, and an assembly (or one
    -- reachable from it) that places nothing are all refused.
    local e = t.raises(function() bracket:place(frame, XY) end)
    t.ok(is_build_error(e) and e.message:find("bracket → frame → bracket", 1, true), e.message)   -- fact 5
    e = t.raises(function() frame:place(bracket, XY, "left") end)
    t.ok(is_build_error(e) and e.message:find("left", 1, true), e.message)   -- fact 6
    -- A raw twelve-number mirrored frame, not `Frame`, which refuses a left-handed frame
    -- first -- the one way to drive a mirrored frame into the ABI's own check.
    e = t.raises(function() frame:place(bracket, { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, -1 }) end)
    t.ok(is_build_error(e) and e.message:find("right-handed and orthonormal", 1, true), e.message)   -- fact 7
    local x = bs.Assembly("x")
    e = t.raises(function() x:step_text() end)
    t.ok(is_build_error(e))   -- fact 8
    x:close()
    local outer = bs.Assembly("outer")
    local hollow = bs.Assembly("hollow")
    outer:place(hollow, XY)
    e = t.raises(function() outer:step_text() end)
    t.ok(is_build_error(e) and e.message:find("hollow", 1, true), e.message)   -- fact 9
    outer:close()
    hollow:close()

    -- Solid:named/Solid.name: the name rides through a one-source operation (place,
    -- coloured) and is dropped by a two-source one (join) or a fresh primitive.
    t.eq(bolt.name, "bolt")
    local placed_bolt = bolt:place(XY)
    t.eq(placed_bolt.name, "bolt")
    placed_bolt:close()
    local coloured_bolt = bolt:coloured({ 1, 0, 0 })
    t.eq(coloured_bolt.name, "bolt")
    coloured_bolt:close()
    local cube = bs.Solid.cuboid(1, 1, 1)
    local joined_bolt = bolt:join(cube)
    t.eq(joined_bolt.name, nil)
    joined_bolt:close()
    cube:close()
    t.eq(bs.Solid.cuboid(1, 1, 1).name, nil)   -- fact 10

    -- Solid:named, Assembly.new and Assembly:place all require a string name (or, for
    -- place, nil) -- a non-string used to be silently coerced through `tostring` (named,
    -- Assembly.new) or passed raw to the FFI (place).
    e = t.raises(function() bolt:named(nil) end)
    t.ok(is_build_error(e) and e.message:find("expected a string", 1, true), e.message)
    e = t.raises(function() bolt:named(42) end)
    t.ok(is_build_error(e) and e.message:find("expected a string", 1, true), e.message)
    e = t.raises(function() bs.Assembly(nil) end)
    t.ok(is_build_error(e) and e.message:find("expected a string", 1, true), e.message)
    e = t.raises(function() bs.Assembly(42) end)
    t.ok(is_build_error(e) and e.message:find("expected a string", 1, true), e.message)
    e = t.raises(function() bracket:place(bolt, XY, 42) end)
    t.ok(is_build_error(e) and e.message:find("nil or a string", 1, true), e.message)

    frame:close()
    bracket:close()
    bolt:close()
    plate:close()
  end)

  -- Mechanisms: Assembly:link and Assembly:joint, at parity with the Python
  -- reference's _mechanism() and its two mechanism tests in test_cadaclysm_blacksmith.py
  -- (also ported at node/test/blacksmith.test.js).
  local function mechanism()
    local bolt = bs.Solid.cylinder(1, 6):named("bolt")
    local plate = bs.Solid.cuboid(20, 10, 2):named("plate")
    local bracket = bs.Assembly("bracket")
    bracket:place(plate, XY)
    bracket:place(bolt, { 5, 5, 2, 1, 0, 0, 0, 1, 0, 0, 0, 1 })
    bracket:place(bolt, { 15, 5, 2, 1, 0, 0, 0, 1, 0, 0, 0, 1 })
    bracket:link("fixed", { "plate" })
    bracket:link("bolts", { "bolt", "bolt 2" })
    bracket:joint("screw", "fixed", "bolts")
    local arm = bs.Assembly("arm")
    arm:place(plate, XY, "base")
    arm:place(bracket, { 0, 0, 10, 1, 0, 0, 0, 1, 0, 0, 0, 1 }, "upper")
    arm:place(bolt, { 5, 5, 2, 1, 0, 0, 0, 1, 0, 0, 0, 1 }, "pin")
    arm:link("ground", { "base" })
    arm:link("upper arm", { "upper", "pin" })
    arm:joint("shoulder", "ground", "upper arm")
    return bolt, plate, bracket, arm
  end

  -- `text` with every `FILE_NAME(` line dropped, so the FILE_NAME timestamp does not
  -- make two writes of the same assembly look different.
  local function no_stamp(text)
    local out = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
      if line:sub(1, 10) ~= "FILE_NAME(" then out[#out + 1] = line end
    end
    return table.concat(out, "\n")
  end

  t.test("a mechanism is written as AP242 kinematic topology, its eleven bad links and "
    .. "joints are refused with their exact message and change nothing, and a bare "
    .. "string is refused before any call", function()
    local bolt, plate, bracket, arm = mechanism()

    local function count_of(haystack, needle)
      local n, start = 0, 1
      while true do
        local from = haystack:find(needle, start, true)
        if not from then return n end
        n, start = n + 1, from + #needle
      end
    end

    -- Fact 1: the default schema (no explicit schema) carries the kinematic entities.
    local arm_step_text = arm:step_text()
    t.ok(arm_step_text:find("AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF", 1, true))
    t.eq(count_of(arm_step_text, "=KINEMATIC_LINK("), 4)
    t.eq(count_of(arm_step_text, "=RIGID_LINK_REPRESENTATION("), 6)
    t.eq(count_of(arm_step_text, "=CONTEXT_DEPENDENT_KINEMATIC_LINK_REPRESENTATION("), 6)
    t.eq(count_of(arm_step_text, "=KINEMATIC_JOINT("), 2)
    t.eq(count_of(arm_step_text, "=KINEMATIC_TOPOLOGY_STRUCTURE("), 2)

    -- Fact 2: an explicit schema without kinematic entities is refused.
    local e = t.raises(function() arm:step_text("config_control_design") end)
    t.ok(is_build_error(e) and e.message:find("no kinematic entities", 1, true), e.message)

    -- Fact 3: each of the eleven refusals raises with exactly its message, and
    -- afterwards the STEP text (with FILE_NAME( lines stripped) is unchanged.
    local before = no_stamp(arm:step_text())
    local refusals = {
      { function() arm:link("", { "base" }) end, "link: a name cannot be empty" },
      { function() arm:link("ground", { "base" }) end, "link: assembly 'arm' already has a link named 'ground'" },
      { function() arm:link("free", {}) end, "link: link 'free' names no placements" },
      { function() arm:link("free", { "base", "base" }) end, "link: link 'free' names placement 'base' twice" },
      { function() arm:link("free", { "bolt" }) end, "link: assembly 'arm' has no placement named 'bolt'" },
      { function() arm:link("free", { "pin" }) end,
        "link: placement 'pin' of assembly 'arm' is already in link 'upper arm'" },
      { function() arm:joint("", "ground", "upper arm") end, "joint: a name cannot be empty" },
      { function() arm:joint("shoulder", "upper arm", "ground") end,
        "joint: assembly 'arm' already has a joint named 'shoulder'" },
      { function() arm:joint("wrist", "ground", "hand") end, "joint: assembly 'arm' has no link named 'hand'" },
      { function() arm:joint("wrist", "ground", "ground") end, "joint: joint 'wrist' joins link 'ground' to itself" },
      { function() arm:joint("wrist", "ground", "upper arm") end,
        "joint: assembly 'arm' already joins 'ground' to 'upper arm'" },
    }
    for _, pair in ipairs(refusals) do
      local call, message = pair[1], pair[2]
      local err = t.raises(call)
      t.ok(is_build_error(err) and err.message == message, err.message)
    end
    t.eq(no_stamp(arm:step_text()), before)

    -- A bare string, not a table, is refused with BuildError before any call -- `link("free",
    -- "base")` would otherwise walk the string's own bytes as if it were `{"b", "a", "s", "e"}`.
    e = t.raises(function() arm:link("free", "base") end)
    t.ok(is_build_error(e) and e.message == "link: placements must be a list of names, not 'base'", e.message)
    -- A bad item is refused by position (1-based, as Lua counts).
    e = t.raises(function() arm:link("free", { "base", 5 }) end)
    t.ok(is_build_error(e) and e.message == "link: placements[2] is not a name: 5", e.message)

    -- Fact 5: read-back through to_scene, once the reader's Scene exposes links and joints
    -- (the reader's kinematics ABI, claude/kinematic-abi, now on this branch). Checked
    -- before fact 4's "back" joint, still on this same arm, so the read-back sees exactly
    -- the two joints the fixture built ("screw", "shoulder"), not a third.
    local scene = arm:to_scene()
    local link_names, node_counts = {}, {}
    for i, l in ipairs(scene.links) do
      link_names[i] = l.name
      node_counts[i] = #l.nodes
    end
    t.eq(table.concat(link_names, ","), "fixed,bolts,ground,upper arm")
    t.eq(table.concat(node_counts, ","), "1,2,1,2")
    local joint_rows = {}
    for i, j in ipairs(scene.joints) do
      joint_rows[i] = j.name .. "," .. j.start.index .. "," .. j.end_.index
    end
    t.eq(table.concat(joint_rows, ";"), "screw,0,1;shoulder,2,3")
    for _, d in ipairs(scene.diagnostics) do
      t.ok(d:sub(1, 11) ~= "kinematics:", d)
    end
    scene:close()

    -- Fact 4: the reverse pair is a new joint.
    arm:joint("back", "upper arm", "ground")

    arm:close()
    bracket:close()
    bolt:close()
    plate:close()
  end)

  -- Assembly:pair, state and base, and M.pair_freedom_count, at parity with the Python
  -- reference's _paired() and its tests in test_cadaclysm_blacksmith.py (spec
  -- 2026-09-28). See Node's test/blacksmith.test.js, Rust's mod tests and Swift's
  -- KernelTests.swift for the same facts worked out.
  t.test("a paired mechanism is written as AP242 kinematic pairs and states, reads back "
    .. "through to_scene, every bad pair/state/base is refused with its exact message "
    .. "and changes nothing, and pair_freedom_count reports kind sizes", function()
    local bolt, plate, bracket, arm = mechanism()
    bracket:pair("screw", "prismatic", bs.Frame.xy({ 1, 2, 3 }), { end_frame = bs.Frame.xy({ 4, 2, 3 }) })
    arm:pair("shoulder", "revolute", bs.Frame.xy({ 0, 0, 10 }), { ranges = { { -1.5, 1.5 } } })
    arm:state("reach", { { "shoulder", { 0.5 } } })
    arm:base("ground")

    local function count_of(haystack, needle)
      local n, start = 0, 1
      while true do
        local from = haystack:find(needle, start, true)
        if not from then return n end
        n, start = n + 1, from + #needle
      end
    end

    -- Fact 1: the written STEP text carries the pairs and the state.
    local step = arm:step_text()
    t.eq(count_of(step, "=MECHANISM_REPRESENTATION("), 2)
    t.eq(count_of(step, "=PAIR_REPRESENTATION_RELATIONSHIP("), 2)
    t.eq(count_of(step, "REVOLUTE_PAIR_WITH_RANGE"), 1)
    t.eq(count_of(step, "PRISMATIC_PAIR"), 1)
    t.eq(count_of(step, "=KINEMATIC_PROPERTY_MECHANISM_REPRESENTATION("), 1)
    t.eq(count_of(step, "=MECHANISM_STATE_REPRESENTATION("), 1)

    -- Facts 2-6, 9: read back through to_scene.
    local scene = arm:to_scene()
    local shoulder, screw
    for _, j in ipairs(scene.joints) do
      if j.name == "shoulder" then shoulder = j end
      if j.name == "screw" then screw = j end
    end
    local shoulder_pair = shoulder.pair
    t.eq(shoulder_pair.kind, "revolute")
    for _, frame in ipairs({ shoulder_pair.frame_start, shoulder_pair.frame_end }) do
      t.ok(all_near({ frame[1][4], frame[2][4], frame[3][4] }, { 0, 0, 10 }, 1e-9))
      t.ok(all_near({ frame[1][3], frame[2][3], frame[3][3] }, { 0, 0, 1 }, 1e-9))
    end
    local shoulder_freedoms = shoulder_pair.freedoms
    t.eq(#shoulder_freedoms, 1)
    t.eq(shoulder_freedoms[1].motion, "rotation")
    t.eq(shoulder_freedoms[1].axis, "z")
    t.near(shoulder_freedoms[1].lower, -1.5, 1e-9)
    t.near(shoulder_freedoms[1].upper, 1.5, 1e-9)

    local screw_pair = screw.pair
    t.eq(screw_pair.kind, "prismatic")
    for _, f in ipairs(screw_pair.freedoms) do
      t.eq(f.lower, nil)
      t.eq(f.upper, nil)
    end
    t.ok(all_near({ screw_pair.frame_start[1][4], screw_pair.frame_start[2][4], screw_pair.frame_start[3][4] },
      { 1, 2, 13 }, 1e-9))
    t.ok(all_near({ screw_pair.frame_end[1][4], screw_pair.frame_end[2][4], screw_pair.frame_end[3][4] },
      { 4, 2, 13 }, 1e-9))

    t.ok(scene.base ~= nil and scene.base.name == "ground")
    local state_names = {}
    for i, s in ipairs(scene.states) do state_names[i] = s.name end
    t.eq(table.concat(state_names, ","), "reach")
    local reach = scene.states[1]
    t.eq(#reach.values, 1)
    t.eq(reach.values[1].joint.name, "shoulder")
    t.ok(all_near(reach.values[1].values, { 0.5 }, 1e-9))

    -- Fact 5: pose_state(reach) carries the pin node (the upper arm node at (5, 5, 2))
    -- to (5cos0.5 - 5sin0.5, 5sin0.5 + 5cos0.5, 2).
    local pose = scene:pose_state(reach)
    local upper_arm
    for _, l in ipairs(scene.links) do if l.name == "upper arm" then upper_arm = l end end
    local pin_node
    for _, n in ipairs(upper_arm.nodes) do
      local tr = n.transform
      if all_near({ tr[1][4], tr[2][4], tr[3][4] }, { 5, 5, 2 }, 1e-9) then pin_node = n end
    end
    t.ok(pin_node ~= nil, "the upper arm node at (5, 5, 2) exists")
    local posed = pose:transform(pin_node)
    t.ok(all_near({ posed[1][4], posed[2][4], posed[3][4] },
      { 5 * math.cos(0.5) - 5 * math.sin(0.5), 5 * math.sin(0.5) + 5 * math.cos(0.5), 2.0 }, 1e-9))

    -- Fact 6: pose([(screw, [3.0])]) leaves every 'bolts' node at rest; [5.0] moves each
    -- by (2, 0, 0).
    local pose3 = scene:pose({ { joint = screw, values = { 3.0 } } })
    local pose5 = scene:pose({ { joint = screw, values = { 5.0 } } })
    local bolts
    for _, l in ipairs(scene.links) do if l.name == "bolts" then bolts = l end end
    for _, node in ipairs(bolts.nodes) do
      local rest = node.transform
      local at3 = pose3:transform(node)
      local at5 = pose5:transform(node)
      for row = 1, 3 do t.near(at3[row][4], rest[row][4], 1e-9) end
      t.near(at5[1][4], rest[1][4] + 2.0, 1e-9)
      t.near(at5[2][4], rest[2][4], 1e-9)
      t.near(at5[3][4], rest[3][4], 1e-9)
    end

    -- Fact 9: no diagnostic names kinematics.
    for _, d in ipairs(scene.diagnostics) do t.ok(d:sub(1, 11) ~= "kinematics:", d) end
    scene:close()

    -- Fact 7: the eight refusals of test_every_bad_pair_state_or_base_is_refused_and_
    -- changes_nothing, each with exactly its message, and the unpaired-'back' trick:
    -- step_text()'s refusal text is identical before and after the batch.
    arm:joint("back", "upper arm", "ground")
    local function unpaired_message()
      local e = t.raises(function() arm:step_text() end)
      return e.message
    end
    local before = unpaired_message()
    local refusals = {
      { function() arm:pair("shoulder", "revolute", bs.Frame.xy({ 0, 0, 10 })) end,
        "pair: joint 'shoulder' already has a pair" },
      { function() arm:pair("back", "orbital", bs.Frame.xy()) end,
        "pair: 'orbital' is not a pair kind (revolute, prismatic, cylindrical, screw, gear, rack_and_pinion, spherical, "
        .. "spherical_with_pin, planar, universal, homokinetic, fully_constrained, unconstrained)" },
      { function() arm:pair("back", "screw", bs.Frame.xy()) end, "pair: a screw needs a non-zero pitch" },
      { function() arm:pair("back", "revolute", bs.Frame.xy(), { ranges = { { -1, 1 }, { -1, 1 } } }) end,
        "pair: 'revolute' has 1 freedoms, but 2 ranges were given" },
      { function() arm:pair("back", "revolute", bs.Frame.xy(), { ranges = { { 1, -1 } } }) end,
        "pair: range 0 of joint 'back' has lower >= upper" },
      { function()
          arm:pair("back", "prismatic", bs.Frame.at({ 0, 0, 0 }, { 0, 0, 1 }, { 0, 1, 0 }), { end_frame = bs.Frame.xy() })
        end,
        "pair: joint 'back' is prismatic, but its end frame is turned 90\xC2\xB0 about -z, "
        .. "which prismatic (does not turn) cannot make" },
      { function() arm:state("overreach", { { "shoulder", { 5.0 } } }) end,
        "state: value 0 of joint 'shoulder' is outside its range" },
      { function() arm:base("upper arm") end, "base: assembly 'arm' already has base 'ground'" },
    }
    for _, r in ipairs(refusals) do
      local call, message = r[1], r[2]
      local e = t.raises(call)
      t.ok(is_build_error(e) and e.message == message, e.message)
    end
    t.eq(unpaired_message(), before)

    -- Fact 8: a joint with no pair is refused at write time.
    local e = t.raises(function() arm:step_text() end)
    t.ok(is_build_error(e) and e.message ==
      "assembly_step: assembly 'arm': joint 'back' has no pair; a mechanism with pairs needs one on every joint (AP242)",
      e.message)

    -- Fact 9: pair_freedom_count.
    t.eq(bs.pair_freedom_count("spherical"), 3)
    t.eq(bs.pair_freedom_count("revolute"), 1)
    t.eq(bs.pair_freedom_count("fully_constrained"), 0)
    t.eq(bs.pair_freedom_count("not_a_kind"), 0)

    -- A rows/ranges argument of the wrong shape is refused with a BuildError before any
    -- C call.
    e = t.raises(function() arm:pair("free", "revolute", bs.Frame.xy(), { ranges = "not a list" }) end)
    t.ok(is_build_error(e) and e.message:find("ranges must be a list", 1, true), e.message)
    e = t.raises(function() arm:state("free", "not a list") end)
    t.ok(is_build_error(e) and e.message:find("rows must be a list", 1, true), e.message)

    arm:close()
    bracket:close()
    bolt:close()
    plate:close()
  end)

  -- Drives plan 4's round trip, as Python's _geared(): a pinion turning on `drive` meshes,
  -- by the gear pair `mesh` (radii 10 and 20, ratio -0.5, bevel 0.25, helical 0.125), with
  -- a wheel turning on `driven` about (30, 0).
  local function geared(mesh)
    local plate = bs.Solid.cuboid(40, 10, 2):named("plate")
    local pin = bs.Solid.cylinder(1, 6):named("pin")
    local hub = bs.Solid.cylinder(2, 4):named("hub")
    local gears = bs.Assembly("gears")
    gears:place(plate, bs.Frame.xy(), "frame")
    gears:place(pin, bs.Frame.xy({ 0, 0, 2 }), "pinion")
    gears:place(hub, bs.Frame.xy({ 35, 0, 2 }), "wheel")
    gears:link("base", { "frame" })
    gears:link("driver", { "pinion" })
    gears:link("follower", { "wheel" })
    gears:joint("drive", "base", "driver")
    gears:joint("driven", "base", "follower")
    gears:joint("mesh", "driver", "follower")
    gears:pair("drive", "revolute", bs.Frame.xy({ 0, 0, 2 }))
    gears:pair("driven", "revolute", bs.Frame.xy({ 30, 0, 2 }))
    if mesh then
      gears:pair_with("mesh", "gear", bs.Frame.xy({ 0, 0, 2 }), nil, { 10, 20, -0.5, 0.25, 0.125 })
    end
    return gears, { plate, pin, hub }
  end

  t.test("a gear pair round trips and poses from its driver", function()
    local gears, parts = geared(true)
    local scene = gears:to_scene()
    local joints = {}
    for _, j in ipairs(scene.joints) do joints[j.name] = j end
    local mesh = joints.mesh.pair
    t.eq(mesh.kind, "other")
    t.eq(mesh.kind_name, "gear")
    local want_params = { 10, 20, -0.5, 0.25, 0.125 }
    t.eq(#mesh.parameters, 5)
    for i = 1, 5 do t.near(mesh.parameters[i], want_params[i], 1e-12) end
    t.eq(joints.drive.pair.kind_name, "revolute")
    t.eq(#joints.drive.pair.parameters, 0)

    -- the driver alone turns the wheel by ratio x 0.4 about (30, 0): nothing to report
    local pose = scene:pose({ { joint = joints.drive, values = { 0.4 } } })
    t.eq(#pose.diagnostics, 0)
    t.eq(#pose.unsolved, 0)
    local wheel = scene.links[3].nodes[1]
    local m = pose:transform(wheel)
    t.near(m[1][4], 30 + 5 * math.cos(-0.2), 1e-9)
    t.near(m[2][4], 5 * math.sin(-0.2), 1e-9)
    t.near(m[3][4], 2.0, 1e-9)

    -- both sides given, against the law: one diagnostic, in the kernel's words
    pose = scene:pose({ { joint = joints.drive, values = { 0.4 } }, { joint = joints.driven, values = { 0.4 } } })
    t.eq(#pose.diagnostics, 1)
    local prefix = "coupling 'mesh': both 'drive' and 'driven' are given and disagree by"
    t.eq(pose.diagnostics[1]:sub(1, #prefix), prefix)
    scene:close()
    gears:close()
    for _, p in ipairs(parts) do p:close() end
  end)

  t.test("pair_with refuses a wrong parameter count", function()
    local gears, parts = geared(false)
    local e = t.raises(function() gears:pair_with("mesh", "gear", bs.Frame.xy(), nil, { 10, 20 }) end)
    t.ok(is_build_error(e), e.message)
    t.eq(e.message, "pair: a gear takes 3 or 5 parameters, not 2")
    gears:pair_with("mesh", "gear", bs.Frame.xy(), nil, { 10, 20, -0.5 })   -- unchanged: it takes one now
    gears:close()
    for _, p in ipairs(parts) do p:close() end
  end)

  -- Python's _paired(): the mechanism's pairs, a state `reach` and a base.
  local function paired()
    local bolt, plate, bracket, arm = mechanism()
    bracket:pair("screw", "prismatic", bs.Frame.xy({ 1, 2, 3 }), { end_frame = bs.Frame.xy({ 4, 2, 3 }) })
    arm:pair("shoulder", "revolute", bs.Frame.xy({ 0, 0, 10 }), { ranges = { { -1.5, 1.5 } } })
    arm:state("reach", { { "shoulder", { 0.5 } } })
    arm:base("ground")
    return arm, { bolt, plate, bracket }
  end

  -- Python's _posed_frame(): two copies of a bracket whose bolt turns on `turn`, placed as
  -- `left` and `right/rear`.
  local function posed_frame()
    local bolt = bs.Solid.cuboid(1, 1, 6):named("bolt")
    local plate = bs.Solid.cuboid(20, 10, 2):named("plate")
    local bracket = bs.Assembly("bracket")
    bracket:place(plate, bs.Frame.xy())
    bracket:place(bolt, bs.Frame.xy({ 5, 5, 2 }))
    bracket:link("fixed", { "plate" })
    bracket:link("bolts", { "bolt" })
    bracket:joint("turn", "fixed", "bolts")
    bracket:pair("turn", "revolute", bs.Frame.xy({ 10, 5, 2 }))
    local frame = bs.Assembly("frame")
    frame:place(bracket, bs.Frame.xy(), "left")
    frame:place(bracket, bs.Frame.xy({ 100, 0, 0 }), "right/rear")
    return frame, { bolt, plate, bracket }
  end

  t.test("posed moves the shoulder and the screw, read back through to_scene", function()
    local arm, keep = paired()
    local rest_scene = arm:to_scene()
    local function link_named(scene, name)
      for _, l in ipairs(scene.links) do if l.name == name then return l end end
    end
    local upper = link_named(rest_scene, "upper arm")
    local pin_i
    for i, n in ipairs(upper.nodes) do
      local tr = n.transform
      if all_near({ tr[1][4], tr[2][4], tr[3][4] }, { 5, 5, 2 }, 1e-9) then pin_i = i end
    end
    t.ok(pin_i ~= nil, "the upper arm node at (5, 5, 2) exists")
    local turned = arm:posed({ shoulder = 0.5 })
    t.eq(turned.name, "arm")
    local scene = turned:to_scene()
    local tr = link_named(scene, "upper arm").nodes[pin_i].transform
    t.ok(all_near({ tr[1][4], tr[2][4], tr[3][4] },
      { 5 * math.cos(0.5) - 5 * math.sin(0.5), 5 * math.sin(0.5) + 5 * math.cos(0.5), 2.0 }, 1e-9))
    -- a key given as a list of names, a row list, and a value as a list
    local slid = arm:posed({ { { "upper", "screw" }, { 5.0 } } }):to_scene()
    local rest_bolts, slid_bolts = link_named(rest_scene, "bolts").nodes, link_named(slid, "bolts").nodes
    t.eq(#slid_bolts, #rest_bolts)
    for i, n in ipairs(slid_bolts) do
      local a, b = n.transform, rest_bolts[i].transform
      t.ok(all_near({ a[1][4], a[2][4], a[3][4] }, { b[1][4] + 2, b[2][4], b[3][4] }, 1e-9))
    end
    slid:close()
    scene:close()
    rest_scene:close()
    turned:close()
    arm:close()
    for _, p in ipairs(keep) do p:close() end
  end)

  t.test("posed refuses an ambiguous name and takes a path with a slash", function()
    local frame, keep = posed_frame()
    local before = no_stamp(frame:step_text())
    local e = t.raises(function() frame:posed({ turn = 0.3 }) end)
    t.ok(is_build_error(e), e.message)
    t.eq(e.message, "posed: 'turn' names 2 joints: left/turn, right\\/rear/turn; give one by its path")
    local posed = frame:posed({ { "right\\/rear/turn", 0.3 } })
    t.eq(posed.name, "frame")
    t.ok(no_stamp(posed:step_text()) ~= before)
    local again = frame:posed({ { { "right/rear", "turn" }, 0.3 } })   -- the list form escapes for us
    t.eq(no_stamp(again:step_text()), no_stamp(posed:step_text()))
    local zero = frame:posed({ ["right\\/rear/turn"] = 0.0 })
    t.eq(no_stamp(zero:step_text()), before)
    t.eq(no_stamp(frame:posed():step_text()), before)   -- no rows at all
    t.eq(no_stamp(frame:step_text()), before)
    zero:close(); again:close(); posed:close(); frame:close()
    for _, p in ipairs(keep) do p:close() end
  end)

  t.test("posed takes a state and a ground and refuses with the kernel's words", function()
    local arm, keep = paired()
    local before = no_stamp(arm:step_text())
    local by_state = arm:posed(nil, "reach")
    local by_row = arm:posed({ shoulder = { 0.5 } })
    t.eq(no_stamp(by_state:step_text()), no_stamp(by_row:step_text()))
    local held = arm:posed({ shoulder = 0.5 }, nil, "upper arm")
    t.ok(no_stamp(held:step_text()) ~= no_stamp(by_row:step_text()))
    local e = t.raises(function() arm:posed({ shoulder = 2.0 }) end)
    t.ok(is_build_error(e), e.message)
    t.eq(e.message, "posed: value 0 of joint 'shoulder' is 2, outside its range")
    e = t.raises(function() arm:posed(nil, "fold") end)
    t.ok(is_build_error(e), e.message)
    t.eq(e.message, "posed: assembly 'arm' has no state named 'fold'")
    t.eq(no_stamp(arm:step_text()), before)
    held:close(); by_row:close(); by_state:close(); arm:close()
    for _, p in ipairs(keep) do p:close() end
  end)

  t.test("posed refuses a gear coupling given on both sides and takes the driver alone", function()
    local gears, parts = geared(true)
    local before = no_stamp(gears:step_text())
    local ok = gears:posed({ drive = 0.4 })
    t.eq(ok.name, "gears")
    local e = t.raises(function() gears:posed({ drive = 0.4, driven = 0.4 }) end)
    t.ok(is_build_error(e), e.message)
    local prefix = "posed: assembly 'gears': coupling 'mesh': both 'drive' and 'driven' are given and disagree by"
    t.eq(e.message:sub(1, #prefix), prefix)
    t.eq(no_stamp(gears:step_text()), before)
    ok:close()
    gears:close()
    for _, p in ipairs(parts) do p:close() end
  end)

  t.test("a sequence is written and reads back, and a bad one is refused exactly", function()
    local bolt, plate, bracket, arm = mechanism()
    arm:pair("shoulder", "revolute", bs.Frame.xy({ 0, 0, 10 }), { ranges = { { -1.5, 1.5 } } })
    bracket:pair("screw", "prismatic", bs.Frame.xy({ 1, 2, 3 }), { end_frame = bs.Frame.xy({ 4, 2, 3 }) })
    arm:state("reach", { { "shoulder", { 0.5 } } })
    arm:state("rest", { { "shoulder", { 0.0 } } })
    arm:sequence("swing", { { "rest", 0.0, "linear" }, { "reach", 1.0, "linear" } }, true)
    local scene = arm:to_scene()
    local sequences = scene.sequences
    t.eq(#sequences, 1)
    local swing = sequences[1]
    t.eq(swing.name, "swing")
    t.eq(swing.closed, true)
    t.eq(swing.seconds_per_unit, 1)
    t.eq(#swing.segments, 2)
    t.eq(swing.segments[1].state.name, "rest")
    t.eq(swing.segments[1].t, 0)
    t.eq(swing.segments[1].interpolation, "linear")
    t.eq(swing.segments[2].state.name, "reach")
    t.eq(swing.segments[2].t, 1)
    t.eq(swing.segments[2].interpolation, "linear")
    scene:close()
    local e = t.raises(function()
      arm:sequence("bad", { { "rest", 0.0, "linear" }, { "nowhere", 1.0, "linear" } })
    end)
    t.ok(is_build_error(e), e.message)
    t.eq(e.message, "sequence: assembly 'arm' has no state named 'nowhere'")
    arm:close()
    bracket:close()
    bolt:close()
    plate:close()
  end)

  -- Controller ruling: fact 10 -- a one-sided range survives the round trip. Without
  -- this, an implementation that sends has_lower/has_upper as always-true would pass
  -- every other fact.
  t.test("a pair's one-sided range survives the round trip", function()
    local plate = bs.Solid.cuboid(20, 10, 2):named("plate")
    local bolt = bs.Solid.cylinder(1, 6):named("bolt")

    local hinge = bs.Assembly("hinge")
    hinge:place(plate, XY, "base")
    hinge:place(bolt, { 0, 0, 2, 1, 0, 0, 0, 1, 0, 0, 0, 1 }, "arm")
    hinge:link("base", { "base" })
    hinge:link("arm", { "arm" })
    hinge:joint("j", "base", "arm")
    hinge:pair("j", "revolute", bs.Frame.xy(), { ranges = { { nil, 1.0 } } })

    local scene = hinge:to_scene()
    local j
    for _, joint in ipairs(scene.joints) do if joint.name == "j" then j = joint end end
    local freedoms = j.pair.freedoms
    t.eq(#freedoms, 1)
    t.eq(freedoms[1].lower, nil)
    t.near(freedoms[1].upper, 1.0, 1e-9)
    scene:close()

    hinge:close()
    bolt:close()
    plate:close()
  end)

  -- One edge, face or corner where a list is taken is refused, named, before the kernel is
  -- asked: this wrapper once read `fillet(edge, 1)` as no edges.
  t.test("a list argument refuses one edge, face or corner, or a bad item, by name", function()
    local cube = bs.Solid.cuboid(10, 10, 10)
    local edge = cube.edges[1]
    local cases = {
      { "fillet", "edges", true, function(x) return cube:fillet(x, 0.5) end },
      { "chamfer", "edges", true, function(x) return cube:chamfer(x, 0.5) end },
      { "edges_coloured", "edges", true, function(x) return cube:edges_coloured("#f00", x) end },
      { "drop_faces", "faces", false, function(x) return cube:drop_faces(x) end },
      { "shell", "open", false, function(x) return cube:shell(1, x) end },
      { "push_pull", "face", false, function(x) return cube:push_pull(x, 1) end },
      { "round", "corners", false, function(x) return bs.Profile.rect(10, 10):round(1, x) end },
    }
    local function says(err, text)
      local message = type(err) == "table" and err.message or tostring(err)
      if message ~= text then error(("expected %q, got %q"):format(text, message), 2) end
    end
    for _, c in ipairs(cases) do
      local call, param, edges, run = c[1], c[2], c[3], c[4]
      local items = edges and "Edge objects or indices" or "indices"
      local item = edges and "an Edge or an index" or "an index"
      -- push_pull's own single form refuses a non-index by its own message (see
      -- "push_pull's single face is a face index, or refused by name" below), not the
      -- list checker's wording.
      if call == "push_pull" then
        says(t.raises(function() run(edge) end), "push_pull: face must be a face index or a list of indices, not an Edge")
      else
        says(t.raises(function() run(edge) end), ("%s: %s must be a list of %s, not an Edge"):format(call, param, items))
      end
      if call ~= "push_pull" then   -- one face index is push_pull's own single form
        says(t.raises(function() run(5) end), ("%s: %s must be a list of %s, not 5"):format(call, param, items))
      end
      if call == "push_pull" then
        says(t.raises(function() run("abc") end), "push_pull: face must be a face index or a list of indices, not 'abc'")
      else
        says(t.raises(function() run("abc") end), ("%s: %s must be a list of %s, not 'abc'"):format(call, param, items))
      end
      says(t.raises(function() run({ "abc" }) end), ("%s: %s[1] is not %s: 'abc'"):format(call, param, item))
      says(t.raises(function() run({ 0, 2.5 }) end), ("%s: %s[2] is not %s: 2.5"):format(call, param, item))
      says(t.raises(function() run({ -1 }) end), ("%s: %s[1] is not %s: -1"):format(call, param, item))
      says(t.raises(function() run({ 2 ^ 32 }) end), ("%s: %s[1] is not %s: 4294967296"):format(call, param, item))
    end
    if cube:drop_faces({ 0, 1 }).faces ~= 4 then error("drop_faces({0, 1}) should leave 4 faces") end
    if not (cube:fillet({ edge, 1 }, 0.5).faces > 6) then error("fillet({edge, 1}) should round two edges") end
    -- An Edge inside a non-edge list names itself "an Edge", not its table repr.
    says(t.raises(function() cube:drop_faces({ edge }) end), "drop_faces: faces[1] is not an index: an Edge")
  end)

  -- push_pull's face is one face index or a list of them; anything else -- a
  -- non-integral number, an out-of-range whole number, a string, an Edge or nil -- is
  -- refused by push_pull's own name, not the list checker's wording.
  t.test("push_pull's single face is a face index, or refused by name", function()
    local cube = bs.Solid.cuboid(10, 10, 10)
    local edge = cube.edges[1]
    local function says(err, text)
      local message = type(err) == "table" and err.message or tostring(err)
      if message ~= text then error(("expected %q, got %q"):format(text, message), 2) end
    end
    local function message(thing)
      return ("push_pull: face must be a face index or a list of indices, not %s"):format(thing)
    end
    says(t.raises(function() cube:push_pull(2.5, 1) end), message("2.5"))
    says(t.raises(function() cube:push_pull(-1, 1) end), message("-1"))
    says(t.raises(function() cube:push_pull(2 ^ 32, 1) end), message("4294967296"))
    says(t.raises(function() cube:push_pull("abc", 1) end), message("'abc'"))
    says(t.raises(function() cube:push_pull(edge, 1) end), message("an Edge"))
    says(t.raises(function() cube:push_pull(nil, 1) end), message("nil"))
    t.eq(cube:push_pull(0, 1).faces, 6)
    t.eq(cube:push_pull({ 0 }, 1).faces, 6)
  end)

  -- Lua's `#` stops at a border, so `{ 5, nil, 7 }` can read as one item and the 7 go
  -- missing without a word; and a list's named keys were ignored. A hole is refused at
  -- its first missing place, a named key as not a list.
  t.test("a list argument with a hole or a named key is refused, not shortened", function()
    local cube = bs.Solid.cuboid(10, 10, 10)
    local function says(err, text)
      local message = type(err) == "table" and err.message or tostring(err)
      if message ~= text then error(("expected %q, got %q"):format(text, message), 2) end
    end
    for _, c in ipairs({
      { "drop_faces", "faces", "indices", "an index", function(x) return cube:drop_faces(x) end },
      { "fillet", "edges", "Edge objects or indices", "an Edge or an index", function(x) return cube:fillet(x, 0.5) end },
      { "shell", "open", "indices", "an index", function(x) return cube:shell(1, x) end },
      { "round", "corners", "indices", "an index", function(x) return bs.Profile.rect(10, 10):round(1, x) end },
    }) do
      local call, param, items, item, run = c[1], c[2], c[3], c[4], c[5]
      says(t.raises(function() run({ 5, nil, 1 }) end), ("%s: %s[2] is not %s: nil"):format(call, param, item))
      says(t.raises(function() run({ [1] = 0, [3] = 1 }) end), ("%s: %s[2] is not %s: nil"):format(call, param, item))
      -- One stray huge index is a hole at its first missing place, found without walking
      -- to it (or sizing an array by it: a billion would be gigabytes, and a plain Lua error).
      says(t.raises(function() run({ [1] = 0, [1000000000] = 1 }) end), ("%s: %s[2] is not %s: nil"):format(call, param, item))
      local keyed = { 0, 1, foo = "bar" }
      says(t.raises(function() run(keyed) end), ("%s: %s must be a list of %s, not %s"):format(call, param, items, tostring(keyed)))
    end
  end)

  -- ---- machining: to_arcs, offset, section, and a CAM job -----------------------------

  -- The XY footprint of `profile`: extrude it by 1 and read the solid's bounds, as the
  -- shared recipe suggests for a wrapper with no dedicated outline reader for this.
  local function footprint(profile)
    local b = bs.Solid.extrude(profile, XY, 1).bounds
    return b[1][1], b[2][1], b[1][2], b[2][2]
  end

  t.test("offset grows and shrinks a rectangle, an empty table past its own width", function()
    local grown = bs.Profile.rect(20, 10):offset(2)
    t.eq(#grown, 1)
    local x0, x1, y0, y1 = footprint(grown[1])
    t.near(x0, -12, 1e-6) t.near(x1, 12, 1e-6) t.near(y0, -7, 1e-6) t.near(y1, 7, 1e-6)

    local shrunk = bs.Profile.rect(20, 10):offset(-2)
    t.eq(#shrunk, 1)
    x0, x1, y0, y1 = footprint(shrunk[1])
    t.near(x0, -8, 1e-6) t.near(x1, 8, 1e-6) t.near(y0, -3, 1e-6) t.near(y1, 3, 1e-6)

    t.eq(#bs.Profile.rect(20, 10):offset(-6), 0)

    local e = t.raises(function() bs.Profile.rect(20, 10):offset(0 / 0) end, "profile_offset: distance must be finite")
    t.ok(is_build_error(e))
  end)

  t.test("to_arcs fits a closed spline's free-form sides within tolerance", function()
    local spline = bs.Profile.spline({ { 0, 0 }, { 10, 0 }, { 10, 10 }, { 0, 10 } }, 3, nil, true)
    local sx0, sx1, sy0, sy1 = footprint(spline)
    local arcs = spline:to_arcs(0.01)
    local ax0, ax1, ay0, ay1 = footprint(arcs)
    t.ok(math.abs(ax0 - sx0) < 0.011 and math.abs(ax1 - sx1) < 0.011, "to_arcs footprint stays within tolerance")
    t.ok(math.abs(ay0 - sy0) < 0.011 and math.abs(ay1 - sy1) < 0.011, "to_arcs footprint stays within tolerance")

    local e = t.raises(function() bs.Profile.rect(5, 5):to_arcs(0) end,
      "profile_to_arcs: tolerance must be positive and finite")
    t.ok(is_build_error(e))
  end)

  t.test("section cuts a cuboid at Z, empty past it, refused inside a face", function()
    local cub = bs.Solid.cuboid(20, 10, 5)
    local secs = cub:section(0)
    t.eq(#secs, 1)
    local x0, x1, y0, y1 = footprint(secs[1])
    t.near(x0, -10, 1e-6) t.near(x1, 10, 1e-6) t.near(y0, -5, 1e-6) t.near(y1, 5, 1e-6)

    t.eq(#cub:section(50), 0)

    local e = t.raises(function() cub:section(2.5) end)
    t.ok(is_build_error(e))
    t.ok(e.message:find("solid_section: a face lies in the plane", 1, true) ~= nil, e.message)
  end)

  t.test("a pocketed block reports its four uncut corners, and lists operations", function()
    local part = bs.Solid.cuboid(40, 30, 10):translate(0, 0, 5)
    local cutter = bs.Solid.cuboid(20, 10, 8):translate(0, 0, 6)
    part = part:cut(cutter)

    local flat = bs.Tool.flat(1, 6, 20, 800, 200, 12000)
    local job = bs.Job(bs.Stock.around(part, 2), 30)
    local report = job:machine(part, flat)
    t.eq(#report, 4)
    local lines = 0
    for _ in report.text:gmatch("[^\n]+") do lines = lines + 1 end
    t.eq(lines, 4)
    for _, item in ipairs(report) do
      t.eq(item.kind, "corner")
      t.eq(#item.at, 3)
      t.ok(item.size > 0)
      t.ok(#item.region > 0)
    end
    local ops = job:operations()
    t.ok(#ops > 0)
    for _, op in ipairs(ops) do
      t.eq(type(op.kind), "string")
      t.eq(type(op.tool), "number")
      t.eq(type(op.params), "table")
    end
    job:close()
  end)

  t.test("the plate: faced, pocketed and drilled, an empty report, gcode and camotics files", function()
    local base = bs.Profile.rect(80, 50):round(6)
    local part = bs.Solid.extrude(base, XY, 12)
    local pocket_profile = bs.Profile.rect(40, 24):round(4):with_hole(bs.Profile.circle(5))
    local pocket_frame = { 0, 0, 7, 1, 0, 0, 0, 1, 0, 0, 0, 1 }
    part = part:cut(bs.Solid.extrude(pocket_profile, pocket_frame, 5))
    for _, xy in ipairs({ { 32, 17 }, { 32, -17 }, { -32, 17 }, { -32, -17 } }) do
      part = part:cut(bs.Solid.cylinder(3, 12):translate(xy[1], xy[2], 0))
    end

    local flat = bs.Tool.flat(1, 6, 20, 800, 200, 12000)
    local drill_tool = bs.Tool.drill(2, 6, 30, 150, 3000)
    local job = bs.Job(bs.Stock.around(part, 3), 25, 1.0, 0.01, "plate")
    local report = job:machine(part, flat, { drill_tool })
    t.eq(#report, 0)
    t.eq(report.text, "nothing left uncut")

    local ops = job:operations()
    t.ok(#ops > 0)
    t.eq(ops[1].kind, "face")
    local has_pocket = false
    for _, op in ipairs(ops) do if op.kind == "pocket" then has_pocket = true end end
    t.ok(has_pocket, "operations() contains a pocket")
    local last = ops[#ops]
    t.eq(last.kind, "drill")
    t.eq(last.params.points, 4)
    t.eq(last.params.peck, nil)

    local progs = job:gcode()
    t.eq(#progs, 2)
    for _, p in ipairs(progs) do
      t.eq(type(p.tool), "number")
      t.ok(p.name ~= "")
      t.ok(#p.text > 0)
    end

    local out = t.tmp("plate-camotics/plate.camotics")
    local written = job:write_camotics(out)
    t.ok(#written > 0)
    for _, w in ipairs(written) do
      local f = io.open(w, "rb")
      t.ok(f ~= nil, "write_camotics wrote " .. w)
      if f then f:close() end
    end
    job:close()
  end)

  t.test("write_camotics makes a directory whose name has a single quote and a space", function()
    local part = bs.Solid.cuboid(40, 30, 10)
    local flat = bs.Tool.flat(1, 6, 20, 800, 200, 12000)
    local job = bs.Job(bs.Stock.around(part, 2), 20)
    job:face(flat, 2, 2, 2)

    local out = t.tmp("o'brien's plate/plate.camotics")
    local written = job:write_camotics(out)
    t.ok(#written > 0)
    for _, w in ipairs(written) do
      local f = io.open(w, "rb")
      t.ok(f ~= nil, "write_camotics wrote " .. w)
      if f then f:close() end
    end
    job:close()
  end)

  t.test("a drill as the end mill is refused, and leaves operations() empty", function()
    local part = bs.Solid.cuboid(40, 30, 10)
    local drill_tool = bs.Tool.drill(2, 6, 30, 150, 3000)
    local job = bs.Job(bs.Stock.around(part, 2), 30)
    local e = t.raises(function() job:machine(part, drill_tool) end)
    t.ok(is_build_error(e))
    t.ok(e.message:find("end mill must not be a drill", 1, true) ~= nil, e.message)
    t.eq(#job:operations(), 0)
    job:close()
  end)

  t.test("a NUL in a job name or a CAMotics stem is refused in the kernel's words", function()
    local part = bs.Solid.cuboid(40, 30, 10)
    local nul_name = "job: a name must be non-empty and without brackets, slashes, quotes, control characters, or : * ? < > |"
    local e = t.raises(function() bs.Job(bs.Stock.around(part, 2), 30, 1.0, 0.01, "a\0b") end)
    t.ok(is_build_error(e))
    t.eq(e.message, nul_name)
    local job = bs.Job(bs.Stock.around(part, 2), 30)
    e = t.raises(function() job:write_camotics(t.tmp("nul-stem/a\0b.camotics")) end)
    t.ok(is_build_error(e))
    t.eq(e.message, nul_name)
    job:close()
  end)

  t.test("a closed Job refuses a later call", function()
    local part = bs.Solid.cuboid(40, 30, 10)
    local job = bs.Job(bs.Stock.around(part, 2), 30)
    job:close()
    job:close() -- idempotent
    local e = t.raises(function() job:operations() end, "job: closed")
    t.ok(is_build_error(e))
  end)

  t.test("job-T1/job-T2: face, contour, pocket and drill driven by hand, side mapping and refusals", function()
    local part = bs.Solid.cuboid(40, 30, 10)
    local flat = bs.Tool.flat(1, 6, 20, 800, 200, 12000)
    local drill_tool = bs.Tool.drill(2, 5, 30, 150, 3000)
    local outline = bs.Profile.rect(20, 10)
    local job = bs.Job(bs.Stock.around(part, 2), 30, 1.0, 0.01, "job", 2.0, 0.1)

    job:face(flat, 4, 4, 2)
    job:contour(flat, outline, 4, 0, "outside", 1.0, true, false)
    job:pocket(flat, outline, 4, 1, 3, 1.0)

    local contour_op
    for _, op in ipairs(job:operations()) do if op.kind == "contour" then contour_op = op end end
    t.ok(contour_op ~= nil)
    t.eq(contour_op.params.side, "outside") -- the library's own 0, read as Python reads it
    t.eq(contour_op.params.climb, true)
    t.eq(contour_op.params.open, false)

    -- a bad side is refused before the job changes, and leaves it unchanged
    local before = #job:operations()
    local e = t.raises(function() job:contour(flat, outline, 4, 0, "left") end)
    t.ok(is_build_error(e))
    t.eq(e.message, "side must be 'outside', 'inside' or 'on'")
    t.eq(#job:operations(), before)

    job:drill(drill_tool, { { 5, 5 }, { -5, -5 } }, 4, -2, 3)

    local ops = job:operations()
    local drill_op
    for _, op in ipairs(ops) do if op.kind == "drill" then drill_op = op end end
    t.ok(drill_op ~= nil)
    t.eq(drill_op.params.points, 2)
    t.eq(drill_op.params.peck, 3)

    local progs = job:gcode()
    t.eq(#progs, 2)
    t.eq(progs[1].text:sub(1, #"(cadaclysm: job-T1, T1 flat D6)\n"), "(cadaclysm: job-T1, T1 flat D6)\n")
    t.eq(progs[2].text:sub(1, #"(cadaclysm: job-T2, T2 drill D5)\n"), "(cadaclysm: job-T2, T2 drill D5)\n")
    job:close()
  end)

  -- ---- Solid:silhouette_beziers ---------------------------------------------------------
  -- The curves where a body's surfaces turn away from the eye. The assertions are on values
  -- that pin the layout, not only on lengths: a stride-16 unpack that reads a weight as a
  -- coordinate, or points shifted by one slice, still gives tables of the right length.

  t.test("a sphere's rim has its end points on it to 1e-9 and its end weights exactly one", function()
    local rim = bs.Solid.sphere(2):silhouette_beziers()
    t.ok(rim.count > 0, "a sphere gave no rim")
    t.eq(#rim.points, rim.count * 12, "three numbers a control point, four a curve")
    t.eq(#rim.weights, rim.count * 4, "four weights a curve")
    for c = 0, rim.count - 1 do
      -- Control points 0 and 3 are the arc's ends: on the sphere to 1e-9, with the end
      -- weights exactly 1. The interior control points are not checked, and the interior weights
      -- only to lie in (0, 1): both move with how the rim is subdivided.
      local o = c * 12
      local first = math.sqrt(rim.points[o + 1] ^ 2 + rim.points[o + 2] ^ 2 + rim.points[o + 3] ^ 2)
      local last = math.sqrt(rim.points[o + 10] ^ 2 + rim.points[o + 11] ^ 2 + rim.points[o + 12] ^ 2)
      t.near(first, 2, 1e-9, "arc " .. c .. ": first control point's radius")
      t.near(last, 2, 1e-9, "arc " .. c .. ": last control point's radius")
      local w = c * 4
      t.eq(rim.weights[w + 1], 1, "arc " .. c .. ": first weight")
      t.eq(rim.weights[w + 4], 1, "arc " .. c .. ": last weight")
      for k = 2, 3 do
        local weight = rim.weights[w + k]
        t.ok(weight > 0 and weight < 1, "arc " .. c .. ": interior weight " .. weight .. " is not in (0, 1)")
      end
    end
  end)

  t.test("a cylinder's rulings are polynomial, on its wall at y = 0, and span its height", function()
    local r, height = 1, 3
    local rulings = bs.Solid.cylinder(r, height):silhouette_beziers({ view = "front" })
    t.ok(rulings.count > 0, "a cylinder gave no rulings")
    t.eq(#rulings.points, rulings.count * 12)
    t.eq(#rulings.weights, rulings.count * 4)
    for k, w in ipairs(rulings.weights) do t.eq(w, 1, "weight " .. k .. " of a ruling is not 1") end
    local low, high = math.huge, -math.huge
    for k = 0, rulings.count * 4 - 1 do
      local x, y, z = rulings.points[k * 3 + 1], rulings.points[k * 3 + 2], rulings.points[k * 3 + 3]
      local where = "control point " .. k .. " (" .. x .. ", " .. y .. ", " .. z .. ")"
      t.near(math.sqrt(x * x + y * y), r, 1e-6, where .. " is off the cylinder's wall")
      -- hypot(x, y) is symmetric in x and y, so it cannot tell them apart. The front view looks
      -- along y and the silhouette of the cylinder sits on the x axis, at y = 0: that is what
      -- pins x against y. Only |x| and |y| are asserted, not the sign of x and not how many
      -- rulings there are.
      t.near(math.abs(x), r, 1e-6, where .. " is not at |x| = " .. r)
      t.ok(math.abs(y) <= 1e-6, where .. " is not at y = 0")
      low, high = math.min(low, z), math.max(high, z)
    end
    -- The rulings run cap to cap, so their z extent is the height: that pins z against x and y.
    t.near(high - low, height, 1e-6, "the rulings span z " .. low .. ".." .. high)
  end)

  t.test("an infinite tolerance is refused, and an all-planar body is the empty answer after it", function()
    local sphere = bs.Solid.sphere(2)
    -- Built BEFORE the refusal, not between it and the empty answer: every call that builds, reads or writes
    -- geometry in the library runs under its `guard` and clears the thread's error as its first act, so
    -- building the cuboid in between would have wiped the reason this test exists to leave behind. The frees
    -- do not clear (they only drop a box, outside the library's guard) and neither does reading the error, so
    -- a finalizer or destructor running between the refusal and the empty answer cannot wipe the slot either:
    -- the ordering holds even under a collection at the worst moment.
    local cuboid = bs.Solid.cuboid(10, 10, 10)
    local e = t.raises(function() sphere:silhouette_beziers({ tolerance = math.huge }) end, "silhouette: ")
    t.ok(is_build_error(e), "a refusal is a BuildError")
    -- The refusal above left its reason in the thread's error slot; the empty answer must not
    -- read it as its own. Nothing clears the slot between the refusal and the native call: this
    -- wrapper's default stroke is the literal 0x000000 (a string stroke would go through
    -- `colour_text` and `cadaclysm_blacksmith_parse_colour`, a `guard`, which would clear it), and
    -- `cadaclysm_blacksmith_svg_options_init` is a bare struct fill. So this pins the library's own
    -- clearing at the call's entry as well as the wrapper's not reading the slot early. Do not
    -- narrow it to the wording of the wrappers whose default stroke is colour text, where packing
    -- does clear the slot: that is not true here.
    local none
    t.ok(pcall(function() none = cuboid:silhouette_beziers() end),
      "an empty silhouette is an answer, not an error")
    t.eq(none.count, 0)
    t.eq(#none.points, 0)
    t.eq(#none.weights, 0)
  end)

  t.test("a silhouette is the caller's own: asking again for another eye leaves it alone", function()
    local sphere = bs.Solid.sphere(2)
    local first = sphere:silhouette_beziers({ view = "front" })
    local kept_points, kept_weights = {}, {}
    for i, v in ipairs(first.points) do kept_points[i] = v end
    for i, v in ipairs(first.weights) do kept_weights[i] = v end
    local second = sphere:silhouette_beziers({ view = "iso" })
    t.ok(second.count > 0, "the second view gave no rim")
    t.ok(second ~= first, "the second answer is the first table again")
    t.ok(not same(second.points, kept_points), "the two views gave the same silhouette, so this cannot tell a copy from a reused table")
    t.eq(first.count * 12, #kept_points)
    t.ok(same(first.points, kept_points), "the first answer's points changed under the second ask")
    t.ok(same(first.weights, kept_weights), "the first answer's weights changed under the second ask")
  end)
  -- ---- The Kiln: the SubD cage ----------------------------------------------------------
  -- Python's test_subd_* one for one (the plan's cage facts 1-16), with Lua's spellings: an
  -- edge is `{a, b}`, a selection `{kind = ..., ids = ...}`, positions a list of `{x, y, z}`.

  -- A list of the cages a test makes, every one closed by `keep.close()` (fact 16).
  local function subd_scope()
    local made = {}
    local keep = {}
    setmetatable(keep, { __call = function(_, cage) made[#made + 1] = cage return cage end })
    function keep.close() for _, cage in ipairs(made) do cage:close() end made = {} end
    return keep
  end

  -- A value as text, nested tables included, so two read-backs compare by equality.
  local function show(v)
    if type(v) ~= "table" then return tostring(v) end
    local parts = {}
    for i = 1, #v do parts[i] = show(v[i]) end
    local keys = {}
    for k in pairs(v) do if type(k) ~= "number" then keys[#keys + 1] = k end end
    table.sort(keys)
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. show(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
  end

  local function flat_of(points)
    local out = {}
    for _, p in ipairs(points) do out[#out + 1] = p[1] out[#out + 1] = p[2] out[#out + 1] = p[3] end
    return out
  end

  t.test("subd: a cuboid round-trips through its parts, and every read is a copy", function()   -- fact 1
    local keep = subd_scope()
    local cube = keep(bs.Subd.cuboid())
    local positions = cube.positions
    t.eq(#positions, 8)
    t.eq(#positions[1], 3)
    local sizes = {}
    for i, f in ipairs(cube.faces) do sizes[i] = #f end
    t.eq(show(sizes), show({ 4, 4, 4, 4, 4, 4 }))
    t.eq(#cube.creases, 0)
    t.eq(#cube.pins, 0)
    t.eq(cube.symmetry, nil)
    t.eq(cube.selection, nil)
    local was = positions[1][1]
    positions[1][1] = 99   -- a copy: writing to it changes nothing
    t.eq(cube.positions[1][1], was)
    local again = keep(bs.Subd.from_parts(cube.positions, cube.faces))
    t.eq(show(again.positions), show(cube.positions))
    t.eq(show(again.faces), show(cube.faces))
    -- a flat run of three a vertex is the same cage as `{x, y, z}` each
    t.eq(show(keep(bs.Subd.from_parts(flat_of(cube.positions), cube.faces)).positions), show(cube.positions))
    keep.close()
  end)

  t.test("subd: an edit returns a new cage with its selection and leaves the input alone", function()   -- fact 2
    local keep = subd_scope()
    local cube = keep(bs.Subd.cuboid())
    local out = keep(cube:extrude({ 1 }, 1))
    t.eq(#out.positions, 12)
    t.eq(show(out.selection), show({ kind = "faces", ids = { 1 } }))
    t.eq(#cube.positions, 8, "the input is untouched")
    keep.close()
  end)

  t.test("subd: creases and pins round-trip", function()   -- fact 3
    local keep = subd_scope()
    local cube = keep(bs.Subd.cuboid())
    local creased = keep(cube:crease({ { 0, 1 } }))
    local pinned = keep(creased:pin({ 6 }))
    t.eq(show(creased.selection), show({ kind = "edges", ids = { { 0, 1 } } }))
    t.eq(show(pinned.creases), show({ { 0, 1 } }))
    t.eq(show(pinned.pins), show({ 6 }))
    t.eq(show(pinned.selection), show({ kind = "vertices", ids = { 6 } }))
    local again = keep(bs.Subd.from_parts(pinned.positions, pinned.faces, pinned.creases, pinned.pins))
    t.eq(show({ again.creases, again.pins }), show({ { { 0, 1 } }, { 6 } }))
    t.eq(#keep(pinned:crease({ { 0, 1 } }, false)).creases, 0)
    t.eq(#keep(pinned:pin({ 6 }, false)).pins, 0)
    keep.close()
  end)

  t.test("subd: a mirrored half round-trips, and full/mirror_off bake it", function()   -- fact 4
    local keep = subd_scope()
    local whole = keep(bs.Subd.cuboid({ 2, 2, 2 }, { 2, 1, 1 }))
    local half = keep(whole:mirror_on("x"))
    t.eq(half.symmetry.axis, "x")
    t.ok(half.symmetry.tolerance > 0)
    t.eq(half.selection, nil)
    t.ok(#half.positions < #whole.positions)
    local again = keep(bs.Subd.from_parts(half.positions, half.faces, half.creases, half.pins, half.symmetry))
    t.eq(show(again.positions), show(half.positions))
    t.eq(show(again.symmetry), show(half.symmetry))
    t.eq(#keep(half:full()).positions, #whole.positions)
    t.eq(keep(half:mirror_off()).symmetry, nil)
    t.raises(function() whole:mirror_on("w") end, "axis")
    keep.close()
  end)

  t.test("subd: edge_loop lists the loop, the picked edge first", function()   -- fact 5
    local keep = subd_scope()
    local cube = keep(bs.Subd.cuboid({ 2, 2, 2 }, { 2, 2, 2 }))
    local a, b = cube.faces[1][1], cube.faces[1][2]
    local loop = cube:edge_loop({ a, b })
    t.ok(#loop >= 4)
    for _, e in ipairs(loop) do t.eq(#e, 2) end
    t.eq(show(loop[1]), show({ math.min(a, b), math.max(a, b) }), "the picked edge first")
    keep.close()
  end)

  t.test("subd: edge_loop of a pair that is not an edge is empty, not a refusal", function()   -- fact 5
    local keep = subd_scope()
    local cube = keep(bs.Subd.cuboid())
    local f = cube.faces[1]
    t.eq(#cube:edge_loop({ f[1], f[3] }), 0, "a face's diagonal is no edge")
    t.eq(#cube:edge_loop({ 0, 99 }), 0, "nor is a pair naming no vertex")
    keep.close()
  end)

  t.test("subd: transform rotates every vertex, or only the selected one", function()   -- fact 6
    -- 90 degrees about Z: (x, y, z) -> (-y, x, z), every corner of the cube; column-major.
    local flat = { 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
    local nested = { { 0, -1, 0, 0 }, { 1, 0, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } }   -- row-major
    local keep = subd_scope()
    local cube = keep(bs.Subd.cuboid())
    local before = cube.positions
    local everything = { kind = "vertices", ids = { 0, 1, 2, 3, 4, 5, 6, 7 } }
    for _, matrix in ipairs({ flat, nested }) do
      local turned = keep(cube:transform(everything, matrix)).positions
      for i = 1, 8 do
        local x, y, z = before[i][1], before[i][2], before[i][3]
        t.near(turned[i][1], -y, 1e-12, "vertex " .. i .. " x")
        t.near(turned[i][2], x, 1e-12, "vertex " .. i .. " y")
        t.near(turned[i][3], z, 1e-12, "vertex " .. i .. " z")
      end
    end
    local one = keep(cube:transform({ kind = "vertices", ids = { 0 } }, flat)).positions
    t.near(one[1][1], -before[1][2], 1e-12)
    t.near(one[1][2], before[1][1], 1e-12)
    t.near(one[1][3], before[1][3], 1e-12)
    for i = 2, 8 do t.eq(show(one[i]), show(before[i]), "only vertex 0 moved") end
    keep.close()
  end)

  t.test("subd: transform translates an edge, inset and insert_loop edit, and bad ones are refused", function()   -- facts 6, 7
    local translate = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 3, 0, 0, 1 }   -- column-major
    local keep = subd_scope()
    local cube = keep(bs.Subd.cuboid())
    local moved = keep(cube:transform({ kind = "edges", ids = { { 0, 1 } } }, translate))
    t.eq(moved.positions[1][1], cube.positions[1][1] + 3)
    t.eq(show(moved.selection), show({ kind = "edges", ids = { { 0, 1 } } }))
    t.eq(#keep(cube:inset({ 1 }, 0.25)).faces, 6 + 4)
    local looped = keep(cube:insert_loop({ 0, 1 }))
    t.eq(#looped.positions, 8 + 4)
    t.eq(looped.selection.kind, "edges")
    t.raises(function() cube:insert_loop({ 0, 1 }, 1.5) end, "^bad selection: ")
    t.raises(function() cube:transform({ kind = "bodies", ids = { 0 } }, translate) end, "kind")
    t.raises(function() cube:transform({ kind = "vertices", ids = { 0 } }, { 1, 2, 3 }) end, "matrix")
    keep.close()
  end)

  t.test("subd: smooth_mesh is consistent, kept per level, and outlives its cage", function()   -- fact 8
    local cube = bs.Subd.cuboid()
    local mesh = cube:smooth_mesh(2)
    t.ok(getmetatable(mesh) == bs.SubdMesh)
    local n = #mesh.positions
    t.ok(n > 8)
    t.eq(#mesh.normals, n)
    for i = 1, n do
      local v = mesh.normals[i]
      t.near(math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3]), 1, 1e-9, "normal " .. i)
    end
    t.eq(#mesh.indices % 3, 0)
    for _, k in ipairs(mesh.indices) do t.ok(k < n) end
    t.eq(#mesh.triangle_face, #mesh.indices / 3)
    for _, f in ipairs(mesh.triangle_face) do t.ok(f < 6) end
    t.ok(#cube:smooth_mesh(1).positions < n)
    t.eq(show(cube:smooth_mesh(2).positions), show(mesh.positions))
    t.eq(#cube:smooth_mesh().positions, #cube:smooth_mesh(3).positions, "levels defaults to 3")
    t.raises(function() cube:smooth_mesh(7) end, "levels")
    cube:close()
    collectgarbage("collect")
    t.eq(#mesh.positions, n, "a mesh is a copy: it outlives its cage")
    t.eq(#mesh.normals, n)
    for _, k in ipairs(mesh.indices) do t.ok(k < n) end
    local v = mesh.normals[n]
    t.near(math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3]), 1, 1e-9)
  end)

  t.test("subd: pick finds the element, nil when nothing is near, and refuses a point not finite", function()   -- fact 9
    local keep = subd_scope()
    local cube = keep(bs.Subd.cuboid())
    local corner = cube.positions[7]
    local mesh = cube:smooth_mesh(3)
    local best, best_d = 1, math.huge
    for i, p in ipairs(mesh.positions) do
      local d = (p[1] - corner[1]) ^ 2 + (p[2] - corner[2]) ^ 2 + (p[3] - corner[3]) ^ 2
      if d < best_d then best, best_d = i, d end
    end
    local point = mesh.positions[best]
    t.eq(cube:pick(point, "vertex"), 6)
    local edge = cube:pick(point, "edge")
    t.eq(type(edge), "table")
    t.eq(#edge, 2)
    t.ok(edge[1] == 6 or edge[2] == 6, show(edge))
    t.eq(type(cube:pick(point, "face")), "number")
    t.eq(cube:pick({ 100, 100, 100 }, "vertex"), nil, "nothing near is nil, not an error")
    t.raises(function() cube:pick(point, "body") end, "kind")
    t.raises(function() cube:pick({ 0 / 0, 0, 0 }, "face") end, "^bad selection: pick: point is not finite$")
    t.eq(cube:pick({ 100, 100, 100 }, "vertex"), nil, "a refusal before leaves no stale error behind")
    keep.close()
  end)

  t.test("subd: to_solid converts a cube and reports what it did", function()   -- fact 10
    local keep = subd_scope()
    local cube = keep(bs.Subd.cuboid())
    local solid, report = cube:to_solid()
    t.ok(getmetatable(solid) == bs.Solid)
    t.ok(getmetatable(report) == bs.SubdReport)
    t.eq(report.regular, 0)
    t.eq(report.refined, 24)
    t.ok(report.levels >= 2 and report.steps >= 1)
    t.ok(report.deviation <= 1e-4 and report.g1_angle_deg <= 0.1, show({ report.deviation, report.g1_angle_deg }))
    t.eq(#report.deviation_at, 3)
    t.eq(#report.g1_at, 3)
    t.ok(solid.manifold.is_closed)
    t.ok(solid:mass().volume > 0)
    solid:close()
    local again = cube:to_solid(1e-4, 0.1, 6)
    t.ok(getmetatable(again) == bs.Solid)
    again:close()
    keep.close()
  end)

  t.test("subd: an uncreased cylinder is refused with the figures", function()   -- fact 11
    local cylinder = bs.Subd.cylinder(1, 2, 8, 1, false)
    t.raises(function() cylinder:to_solid() end, "subd:.*tangent break")
    cylinder:close()
  end)

  t.test("subd: the default cylinder has creased rims and converts", function()   -- fact 12
    local cylinder = bs.Subd.cylinder()
    local solid, report = cylinder:to_solid()
    t.ok(report.deviation <= 1e-4 and report.g1_angle_deg <= 0.1)
    t.ok(solid.manifold.is_closed and solid:mass().volume > 0)
    solid:close()
    cylinder:close()
  end)

  t.test("subd: the other primitives build and bad ones are refused", function()   -- fact 13
    for _, make in ipairs({
      function() return bs.Subd.cylinder(1, 2, 8, 2, true) end,
      function() return bs.Subd.sphere(1, 2) end,
      function() return bs.Subd.torus(3, 1, 12, 8) end,
    }) do
      local cage = make()
      t.ok(#cage.faces > 0)
      cage:close()
    end
    t.raises(function() bs.Subd.cuboid({ 2, 2, 2 }, { 0, 1, 1 }) end, "^bad selection: cuboid: segments >= 1$")
    t.raises(function() bs.Subd.sphere(1, 2000) end, "1024")
  end)

  t.test("subd: bad parts are refused", function()   -- fact 14
    local cube = bs.Subd.cuboid()
    local positions, faces = cube.positions, cube.faces
    cube:close()
    t.raises(function() bs.Subd.from_parts(positions, faces, { { 0, 6 } }) end, "^bad selection: ")
    t.raises(function() bs.Subd.from_parts({}, faces) end, "vertex_count")
    t.raises(function() bs.Subd.from_parts(positions, faces, {}, {}, { axis = "w", tolerance = 1e-6 }) end, "symmetry")
    local sixteen = {}
    for i = 1, 16 do sixteen[i] = 0 end
    t.raises(function() bs.Subd.from_parts(sixteen, faces) end, "positions")
  end)

  t.test("subd: the pipeline writes STEP the reader opens as one body", function()   -- fact 15
    local keep = subd_scope()
    local inset = keep(keep(keep(bs.Subd.cuboid()):extrude({ 1 }, 0.5)):inset({ 1 }, 0.25))
    local solid, report = inset:to_solid()
    t.ok(solid.manifold.is_closed and report.deviation <= 1e-4)
    local step = solid:step_text()
    solid:close()
    keep.close()
    t.eq(step:sub(1, 13), "ISO-10303-21;")
    t.ok(step:find("ADVANCED_FACE", 1, true))
    local scene = require("cadaclysm").open_memory(step, "stp")
    local meshable = 0
    for _, n in ipairs(scene.nodes) do if n.can_mesh then meshable = meshable + 1 end end
    t.eq(meshable, 1, "the STEP the SubD cage wrote is one body")
    scene:close()
  end)

  t.test("subd: a nil edge or a pair with a hole is refused by name", function()
    local cube = bs.Subd.cuboid()
    t.raises(function() cube:insert_loop(nil) end, "insert_loop: edge%[1%] is not an {a, b} vertex pair: nil")
    t.raises(function() cube:edge_loop(nil) end, "edge_loop: edge%[1%] is not an {a, b} vertex pair: nil")
    t.raises(function() cube:crease({ { nil, 2 } }) end, "crease: .*%[1%] is not an {a, b} vertex pair")
    cube:close()
  end)

  t.test("subd: a closed cage refuses every call, and closing twice is harmless", function()   -- fact 16
    local cube = bs.Subd.cuboid()
    cube:close()
    cube:close()
    t.raises(function() return cube.positions end, "^subd: closed$")
    t.raises(function() cube:extrude({ 1 }, 1) end, "^subd: closed$")
    t.raises(function() cube:smooth_mesh(1) end, "^subd: closed$")
    t.raises(function() cube:pick({ 0, 0, 0 }, "face") end, "^subd: closed$")
    t.raises(function() cube:to_solid() end, "^subd: closed$")
  end)
end
