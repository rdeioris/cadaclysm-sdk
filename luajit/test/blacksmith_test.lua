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

  t.test("tolerances: a built solid declares nothing, 0 is the effective tolerance and the defaults stay", function()
    local block = bs.Solid.cuboid(10, 10, 10)
    local pin = bs.Solid.cylinder(3, 20):translate(0, 0, -5)
    t.eq(block.tolerances.absolute, nil)
    t.eq(block.tolerances.angular, nil)
    local at = bs.effective_tolerance(block, pin)
    t.near(at, 1e-4 * 20, 1e-3)
    t.eq(bs.effective_tolerance(), 0)
    local unset, explicit = block:cut(pin, 0), block:cut(pin, at)
    local _, _, a = unset:mesh(0 / 0)
    local _, _, b = explicit:mesh(bs.effective_tolerance(explicit))
    t.eq(a.shape[1], b.shape[1], "a NaN mesh is the explicit-effective one")
    local _, _, c = block:cut(pin):mesh()
    local _, _, d = block:cut(pin, 0.05):mesh(0.05)
    t.eq(c.shape[1], d.shape[1], "nil is still the 0.05 default")
    local loose = block:with_tolerances(0.1, math.rad(1))
    t.eq(loose.tolerances.absolute, 0.1)
    t.eq(loose.tolerances.angular, math.rad(1))
    t.eq(getmetatable(loose.tolerances), bs.Tolerances)
    t.eq(bs.effective_tolerance(loose, pin), 0.1)
    t.eq(loose:cut(pin, 0).tolerances.absolute, 0.1, "a verb inherits the loosest declaration")
    t.eq(loose:with_tolerances(nil, math.rad(1)).tolerances.absolute, nil, "nil declares nothing")
    t.eq(block:vertex_tolerance({ 5, 5, 5 }), nil)
    t.raises(function() block:with_tolerances(-1) end, "^solid_with_tolerances: ")
    t.raises(function() block:vertex_tolerance({ 1, 2 }) end, "^vertex_tolerance: ")
  end)

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

  t.test("a .3dm is written as bytes and as a file, and reads back to its faces and volume", function()
    local box = bs.Solid.cuboid(10, 20, 30):named("brick"):coloured("#ff0000")
    local data = box:rhino3dm_bytes()
    t.eq(type(data), "string")
    t.eq(data:sub(1, 24), "3D Geometry File Format ")
    t.eq(bs.rhino3dm_bytes({ box, bs.Solid.sphere(3) }, "in"):sub(1, 24), "3D Geometry File Format ")
    t.raises(function() box:rhino3dm_bytes("furlong") end, "unit must be one of")
    t.raises(function() bs.rhino3dm_bytes({}) end, "3dm_bytes: no solids")
    local out = t.tmp("brick.3dm")
    box:write_3dm(out)
    local f = assert(io.open(out, "rb"))
    t.eq(f:read("*a"), data, "the file is the bytes")
    f:close()
    local back = bs.Solid.open_all(out)
    t.eq(#back, 1)
    t.eq(back[1].faces, 6)
    t.ok(math.abs(back[1]:mass().volume - 6000) <= 6e-6, "the volume reads back")
    local two = t.tmp("two.3dm")
    bs.write_3dm(two, { box, bs.Solid.cylinder(4, 10):translate(40, 0, 0) }, "m")
    local faces = {}
    for _, s in ipairs(bs.Solid.open_all(two)) do faces[#faces + 1] = s.faces end
    t.eq(table.concat(faces, ","), "6,3")
    t.raises(function() box:write_3dm(t.tmp("no/such/dir/nowhere.3dm")) end, "3dm: ")

    local bolt = bs.Solid.cuboid(1, 1, 1):named("bolt")
    local arm = bs.Assembly("arm")
    arm:place(bolt, XY)
    arm:place(bolt, { 2, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 })
    local rig = bs.Assembly("rig")
    rig:place(arm, XY)
    rig:place(bolt, { 10, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 })
    t.eq(rig:rhino3dm_bytes():sub(1, 24), "3D Geometry File Format ")
    local rig_path = t.tmp("rig.3dm")
    rig:write_3dm(rig_path)
    local placed = bs.Solid.open_all(rig_path)
    t.eq(#placed, 3, "one solid per placement: the arm's two bolts and the rig's own")
    local lows = {}
    for _, s in ipairs(placed) do
      t.eq(s.faces, 6)
      lows[#lows + 1] = s.bounds[1][1]
    end
    table.sort(lows)
    t.ok(math.abs(lows[2] - lows[1] - 2) < 1e-6 and math.abs(lows[3] - lows[1] - 10) < 1e-6, "placed where the rig places them")
    rig:place(bs.Assembly("empty"), XY)
    t.raises(function() rig:rhino3dm_bytes() end, "assembly_3dm_bytes: assembly 'empty' places nothing")
    t.raises(function() rig:write_3dm(t.tmp("never.3dm")) end, "assembly 'empty' places nothing")
  end)
  t.test("scaled multiplies every length", function()
    local big = bs.Solid.cuboid(1, 2, 3):scaled(2)
    local b = big:bounds_at(0.05)
    t.ok(math.abs(b[2][1] - b[1][1] - 2) < 1e-9 and math.abs(b[2][3] - b[1][3] - 6) < 1e-9, "scaled bounds")
    local e = t.raises(function() return big:scaled(0) end, "scaled:")
    t.ok(is_build_error(e))
    big:close()
  end)

  -- ---- transforms: Transform, Quaternion, Solid:transform / convert_to_nurbs, profile maps ----

  local function F(x, y, z) return bs.Frame.xy({ x, y, z }) end

  local function near3(actual, expected, tolerance, message)
    t.ok(type(actual) == "table" and #actual == #expected, (message or "") .. ": wrong shape")
    for i = 1, #expected do
      if math.abs(actual[i] - expected[i]) > (tolerance or 1e-12) then
        error(("%s: expected {%s}, got {%s}"):format(message or "near3", table.concat(expected, ", "),
          table.concat(actual, ", ")), 2)
      end
    end
  end

  local function det3(m)
    local r = m.rows
    return r[1] * (r[6] * r[11] - r[7] * r[10]) - r[2] * (r[5] * r[11] - r[7] * r[9])
      + r[3] * (r[5] * r[10] - r[6] * r[9])
  end

  t.test("a transform is sixteen numbers row-major and composes right to left", function()
    local T = bs.Transform
    local tr = T.translation({ 1, 2, 3 })
    t.ok(same(tr.rows, { 1, 0, 0, 1, 0, 1, 0, 2, 0, 0, 1, 3, 0, 0, 0, 1 }), "translation rows")
    t.eq(tr[4], 1, "a transform indexes as its sixteen numbers")
    local s = T.scale({ 0, 0, 0 }, 2)
    near3(tr:compose(s):point({ 1, 1, 1 }), { 3, 4, 5 }, 1e-12, "t after s, by compose")
    near3(s:compose(tr):point({ 1, 1, 1 }), { 4, 6, 8 }, 1e-12, "s after t, by compose")
    near3((tr * s):point({ 1, 1, 1 }), { 3, 4, 5 }, 1e-12, "t after s, by *")
    near3((s * tr):point({ 1, 1, 1 }), { 4, 6, 8 }, 1e-12, "s after t, by *")
    near3(((tr * s):inverse() * (tr * s)):point({ 3, -4, 5 }), { 3, -4, 5 }, 1e-12, "inverse undoes")
    t.ok(T.from_rows(tr.rows) == tr, "from_rows(t.rows) == t")
    t.ok(T() == T.identity(), "Transform() is the identity")
    local r = tr.rows
    t.ok(T({ { r[1], r[2], r[3], r[4] }, { r[5], r[6], r[7], r[8] }, { r[9], r[10], r[11], r[12] },
      { r[13], r[14], r[15], r[16] } }) == tr, "four rows of four")
    t.ok(not (tr == T.identity()), "different maps are not equal")
    local e = t.raises(function() T({ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1 }) end,
      "^Transform: the bottom row must be 0 0 0 1 %(a projective map is not affine%)")
    t.ok(is_build_error(e))
    t.raises(function() T({ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 }) end,
      "^Transform: a matrix is 16 numbers, got 15")
    t.raises(function() T({ 1, 0, 0, 1 }) end, "^Transform: a matrix is 16 numbers, got 4")
    t.raises(function() T({ 1, 0, 0, 0 / 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }) end, "^Transform: not finite")
    e = t.raises(function() T.scale_xyz(XY, 1, 1, 0):inverse() end, "^transform_inverse: the map is singular")
    t.ok(is_build_error(e))
  end)

  t.test("the transform constructors match their closed forms", function()
    local T, Fxy = bs.Transform, bs.Frame.xy()
    near3(T.rotation({ 1, 0, 0 }, { 0, 0, 1 }, pi / 2):point({ 2, 0, 0 }), { 1, 1, 0 }, 1e-12, "rotation")
    near3(T.mirror(F(0, 0, 5)):point({ 1, 2, 3 }), { 1, 2, 7 }, 1e-12, "mirror")
    near3(T.scale_xyz(Fxy, 2, 3, 4):point({ 1, 1, 1 }), { 2, 3, 4 }, 1e-12, "scale_xyz")
    near3(T.scale({ 1, 2, 3 }, 2):point({ 2, 2, 3 }), { 3, 2, 3 }, 1e-12, "scale")
    near3(T.scale({ 1, 2, 3 }, 2):point({ 1, 2, 3 }), { 1, 2, 3 }, 1e-12, "scale fixes its centre")
    near3(T.shear(Fxy, { 5, 0, 0 }, 0.5):point({ 0, 0, 2 }), { 1, 0, 2 }, 1e-12, "shear")
    near3(T.planar_projection(Fxy):point({ 1, 2, 3 }), { 1, 2, 0 }, 1e-12, "planar_projection")
    near3(T.project_along(Fxy, { 1, 0, 1 }):point({ 0, 0, 2 }), { -2, 0, 0 }, 1e-12, "project_along")
    near3(T.plane_to_plane(Fxy, F(1, 2, 3)):point({ 0, 0, 0 }), { 1, 2, 3 }, 1e-12, "plane_to_plane")
    near3(T.change_basis(F(1, 2, 3), Fxy):point({ 0, 0, 0 }), { 1, 2, 3 }, 1e-12, "change_basis")
    local e = t.raises(function() T.shear(Fxy, { 0, 0, 1 }, 0.5) end,
      "^transform_shear: the shear direction must lie in the plane")
    t.ok(is_build_error(e))
    -- The raw twelve numbers: Frame.new would square this one up (or refuse it) first.
    t.raises(function() T.mirror({ 0, 0, 0, 1, 1e-3, 0, 0, 1, 0, 0, 0, 1 }) end,
      "^transform_mirror: the frame is not right%-handed and orthonormal")
  end)

  t.test("maps are told and split", function()
    local T, Fxy = bs.Transform, bs.Frame.xy()
    local turn = T.rotation({ 1, 2, 3 }, { 1, 1, 0 }, 0.7)
    t.ok(turn:is_rigid(), "a turn is rigid")
    t.near(turn:is_similarity(), 1, 1e-9, "a turn's k")
    local big = T.scale({ 0, 0, 0 }, 2.5) * turn
    t.ok(not big:is_rigid(), "a scaled turn is not rigid")
    t.near(big:is_similarity(), 2.5, 1e-9, "a scaled turn's k")
    local split = big:decompose_similarity()
    t.near(split.k, 2.5, 1e-9)
    t.ok(split.orthogonal:is_rigid())
    split = T.scale({ 1, 2, 3 }, 2):decompose_similarity()
    near3(split.translation, { -1, -2, -3 }, 1e-12, "a scale's translation")
    t.near(split.k, 2, 1e-12)
    t.ok(split.orthogonal == T.identity(), "a scale's orthogonal part is the identity")
    local rigid = turn:decompose_rigid()
    local r = turn.rows
    near3(rigid.translation, { r[4], r[8], r[12] }, 1e-12, "a turn's translation")
    t.ok(rigid.orthogonal:is_rigid())
    local stretch = T.scale_xyz(Fxy, 1, 2, 3)
    t.eq(stretch:is_similarity(), nil)
    t.eq(stretch:decompose_rigid(), nil)
    t.eq(stretch:decompose_similarity(), nil)
    local affine = (T.mirror(Fxy) * stretch):decompose_affine()
    near3(affine.stretch, { 3, 2, 1 }, 1e-9, "stretch, largest first")
    t.ok(affine.rotation:is_rigid() and affine.axes:is_rigid())
    t.near(det3(affine.rotation), -1, 1e-9, "rotation carries the mirror")
    t.near(det3(affine.axes), 1, 1e-9, "axes are a proper rotation")
    t.eq(T.planar_projection(Fxy):decompose_affine(), nil)
    local e = t.raises(function() turn:is_rigid(-1) end,
      "^transform_is_rigid: the tolerance must be finite and not negative")
    t.ok(is_build_error(e))
    t.raises(function() turn:is_similarity(-1) end,
      "^transform_is_similarity: the tolerance must be finite and not negative")
  end)

  t.test("a quaternion turns as its transform does", function()
    local Q, T = bs.Quaternion, bs.Transform
    local q = Q.from_axis_angle({ 0, 0, 2 }, pi / 2)
    near3(q:values(), { math.cos(pi / 4), 0, 0, math.sin(pi / 4) }, 1e-12, "from_axis_angle")
    t.near(q.angle, pi / 2, 1e-12)
    near3(q.axis, { 0, 0, 1 }, 1e-12, "axis")
    near3(q:to_transform({ 1, 0, 0 }):point({ 2, 0, 0 }), { 1, 1, 0 }, 1e-12, "about a centre")
    near3(Q(2 * q.w, 2 * q.x, 2 * q.y, 2 * q.z):to_transform():point({ 1, 0, 0 }), { 0, 1, 0 }, 1e-12, "normalised")
    near3(Q.from_transform(q:to_transform()):values(), q:values(), 1e-12, "from_transform")
    t.near(Q.slerp(Q(), q, 0.25).angle, pi / 8, 1e-12, "slerp")
    near3((q * q:conjugate()):values(), { 1, 0, 0, 0 }, 1e-12, "q times its conjugate")
    t.ok(Q(0, 0, 0, 2):normalized() == Q(0, 0, 0, 1), "normalized")
    t.ok(same((Q(1, 2, 3, 4) * Q(5, 6, 7, 8)):values(), { -60, 12, 30, 24 }), "the product, exactly")
    local a = Q.from_axis_angle({ 1, 2, 3 }, 0.7)
    local b = Q.from_axis_angle({ -2, 1, 0.5 }, 1.9)
    t.ok(all_near((a * b):to_transform().rows, (a:to_transform() * b:to_transform()).rows, 1e-12),
      "a * b turns as a's transform after b's")
    near3((Q.from_axis_angle({ 1, 0, 0 }, pi / 2) * Q.from_axis_angle({ 0, 1, 0 }, pi / 2)):values(),
      { 0.5, 0.5, 0.5, 0.5 }, 1e-12, "the product's signs")
    local e = t.raises(function() Q(0, 0, 0, 0):to_transform() end, "^quaternion_to_transform: the quaternion is zero")
    t.ok(is_build_error(e))
    t.raises(function() Q.from_transform(T.mirror(bs.Frame.xy())) end, "^quaternion_from_transform: ")
    t.raises(function() Q(0 / 0, 0, 0, 0) end, "^Quaternion: not finite")
  end)

  t.test("a quaternion far from unit length normalises like the ABI", function()
    local Q = bs.Quaternion
    local h = math.sqrt(0.5)
    for _, k in ipairs({ 1e200, 1e-170 }) do
      t.ok(Q(k, 0, 0, 0):normalized() == Q(1, 0, 0, 0), "(k, 0, 0, 0) at " .. k)
      t.ok(Q(0, 0, 0, -k):normalized() == Q(0, 0, 0, -1), "(0, 0, 0, -k) at " .. k)
      near3(Q(k, k, 0, 0):normalized():values(), { h, h, 0, 0 }, 1e-12, "(k, k, 0, 0) at " .. k)
      local length = Q(k, k, 0, 0).length
      t.ok(math.abs(length - k * math.sqrt(2)) <= 1e-15 * k * math.sqrt(2), "length at " .. k .. ": " .. length)
      t.near(Q(k, k, 0, 0).angle, pi / 2, 1e-12, "angle at " .. k)
      near3(Q(0, k, k, 0).axis, { h, h, 0 }, 1e-12, "axis at " .. k)
    end
    t.eq(Q().axis, nil, "the identity has no axis")
    t.raises(function() Q(0, 0, 0, 0):normalized() end, "^Quaternion.normalized: the quaternion is zero")
  end)

  t.test("a solid takes any affine map", function()
    local T, Fxy = bs.Transform, bs.Frame.xy()
    local box = bs.Solid.cuboid(1, 2, 3)
    t.eq(box.inexact_trims, 0, "a solid no map made has lost nothing")
    local stretched = box:transform(T.scale_xyz(Fxy, 2, 3, 0.5))
    local b = stretched:bounds_at(0.05)
    near3({ b[2][1] - b[1][1], b[2][2] - b[1][2], b[2][3] - b[1][3] }, { 2, 6, 1.5 }, 1e-9, "stretched extents")
    t.eq(stretched.inexact_trims, 0)
    local moved = box:transform(T.translation({ 1, 0, 0 }).rows)
    t.eq(moved.inexact_trims, 0, "sixteen numbers do too")
    t.near(moved:bounds_at(0.05)[1][1], box:bounds_at(0.05)[1][1] + 1, 1e-9, "sixteen numbers move it")
    local sheared = bs.Solid.cylinder(1, 2):transform(T.shear(Fxy, { 1, 0, 0 }, 0.5))
    local volume = sheared:mass(1e-7).volume
    t.ok(math.abs(volume - 2 * pi) <= 1e-6 * 2 * pi, "sheared volume " .. volume)
    t.ok(#count_faces(sheared, "nurbs") > 0, "a shear turns the cylinder into a NURBS")
    local e = t.raises(function() box:transform(T.scale_xyz(Fxy, 1, 1, 0)) end,
      "^solid_transform: a singular map flattens the solid")
    t.ok(is_build_error(e))
  end)

  t.test("a mapped solid keeps its colours and name", function()
    local can = bs.Solid.cylinder(1, 2):coloured("#808080"):named("can")
    local side = count_faces(can, "cylinder")[1]
    can = can:coloured({ 0.2, 0.4, 1.0 }, side)
    local shear = bs.Transform.shear(bs.Frame.xy(), { 1, 0, 0 }, 0.5)
    for _, out in ipairs({ can:transform(shear), can:convert_to_nurbs() }) do
      t.eq(out.faces, can.faces)
      t.ok(same(out:face_colour(side), { 0.2, 0.4, 1.0 }), "the side keeps its colour")
      for i = 0, out.faces - 1 do
        if i ~= side then t.ok(same(out:face_colour(i), can.colour), "face " .. i .. " keeps the solid's colour") end
      end
      t.eq(out.name, "can")
    end
  end)

  t.test("a solid converts to NURBS at each level", function()
    local can = bs.Solid.cylinder(1, 2)
    local every = can:convert_to_nurbs()
    t.eq(#count_faces(every, "nurbs"), every.faces, "every face a NURBS")
    t.eq(every.inexact_trims, 0)
    local analytic = can:convert_to_nurbs("analytic")
    t.ok(#count_faces(analytic, "plane") > 0 and #count_faces(analytic, "nurbs") > 0, "analytic keeps the planes")
    local e = t.raises(function() can:convert_to_nurbs("some") end,
      "^convert_to_nurbs: level 'some' is not \"procedural\", \"analytic\" or \"all\"")
    t.ok(is_build_error(e))
  end)

  t.test("a profile turns, scales, mirrors and maps", function()
    local rect = bs.Profile.rect(80, 40)
    -- Spans and centres of the outline: a planar face's mesh keeps a straight-sided
    -- outline's corners exactly.
    local function box2(p)
      local b = bs.Solid.face(p, XY):bounds_at(0.01)
      return b[2][1] - b[1][1], b[2][2] - b[1][2], (b[2][1] + b[1][1]) / 2, (b[2][2] + b[1][2]) / 2
    end
    local sx, sy = box2(rect:rotate({ 0, 0 }, pi / 2))
    t.near(sx, 40, 1e-3) t.near(sy, 80, 1e-3)
    sx, sy = box2(rect:scale({ 0, 0 }, 0.5, 2))
    t.near(sx, 40, 1e-3) t.near(sy, 80, 1e-3)
    local _, _, rx, ry = box2(rect)
    local _, _, cx, cy = box2(rect:rotate({ 10, 20 }, pi / 2))
    t.near(cx, 10 - (ry - 20), 1e-3, "turned centre x") t.near(cy, 20 + (rx - 10), 1e-3, "turned centre y")
    _, _, cx, cy = box2(rect:scale({ 10, 0 }, 0.5, 2))
    t.near(cx, 10 + 0.5 * (rx - 10), 1e-3, "scaled centre x") t.near(cy, 2 * ry, 1e-3, "scaled centre y")
    _, _, cx = box2(rect:mirror({ 100, 0 }, { 0, 1 }))
    t.near(cx, 200, 1e-3, "mirrored centre x")
    sx = box2(rect:transform2d({ 1, 0.5, 0, 0, 1, 0 }))
    t.near(sx, 100, 1e-3, "sheared x span")
    local e = t.raises(function() rect:transform2d({ 1, 2, 0, 2, 4, 0 }) end, "^profile_transform2d: the 2D map is singular")
    t.ok(is_build_error(e))
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

  -- ---- identity: Python's TestIdentity, trimmed to the marshalling ----

  -- A 10-cube centred on the origin and a pin through it (radius 2, along z, z -10..10),
  -- both tracked.
  local function block_and_pin()
    return bs.Solid.cuboid(10, 10, 10):tracked(), bs.Solid.cylinder(2, 20):translate(0, 0, -10):tracked()
  end

  -- Face `f`'s outward normal's z, off its reference.
  local function nz(solid, f) return solid:face_ref(f)[7] end

  -- Nested tables compared by value.
  local function deq(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    if #a ~= #b then return false end
    for k, v in pairs(a) do
      if not deq(v, b[k]) then return false end
    end
    for k in pairs(b) do
      if a[k] == nil then return false end
    end
    return true
  end

  local function show(v)
    if type(v) ~= "table" then return tostring(v) end
    local parts = {}
    for i = 1, #v do parts[i] = show(v[i]) end
    return "{" .. table.concat(parts, ", ") .. "}"
  end

  local function deq_ok(actual, expected, message)
    t.ok(deq(actual, expected), (message and (message .. ": ") or "") .. "expected " .. show(expected) .. ", got " .. show(actual))
  end

  t.test("tracking numbers faces and edges, and an untracked solid has no ids", function()
    local plain = bs.Solid.cuboid(1, 2, 3)
    t.eq(plain.is_tracked, false)
    t.eq(plain:face_id(0), nil)
    t.eq(plain:edge_id(0), nil)
    deq_ok(plain:face_origins(0), {})
    local tr = plain:tracked()
    t.eq(tr.is_tracked, true)
    t.eq(tr:tracked():face_id(5), 6)
    local faces, edges = {}, {}
    for f = 0, 5 do faces[#faces + 1] = tr:face_id(f) end
    for e = 0, 11 do edges[#edges + 1] = tr:edge_id(e) end
    deq_ok(faces, { 1, 2, 3, 4, 5, 6 })
    deq_ok(edges, { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 })
    t.eq(type(tr:face_id(0)), "number", "ids are Lua numbers")
    t.eq(tr:face_with_id(4), 3)
    t.eq(tr:face_with_id(7), nil)
    t.eq(tr:face_with_id(0), nil)
    t.eq(tr:edge_with_id(12), 11)
    t.eq(tr:edge_with_id(13), nil)
    deq_ok(tr:face_origins(2), { { 0, 3 } })
    deq_ok(tr:edge_origins(11), { { 0, 12 } })
    t.raises(function() tr:face_id(6) end, "^face_id: face 6 of 6$")
    t.raises(function() tr:face_origins(6) end, "^face_origin_count: face 6 of 6$")
    t.raises(function() tr:edge_id(12) end, "^edge_id: edge 12 of 12$")
  end)

  t.test("a cut's origins and history", function()
    local block, pin = block_and_pin()
    local wall
    local caps = {}
    for f = 0, pin.faces - 1 do
      if pin:face_kind(f) == "cylinder" then wall = f end
    end
    local wall_id = pin:face_id(wall)
    for f = 0, pin.faces - 1 do
      if f ~= wall then caps[#caps + 1] = { 1, pin:face_id(f) } end
    end
    local cut = block:cut(pin)
    local bore
    for f = 0, cut.faces - 1 do
      if cut:face_kind(f) == "cylinder" then bore = f end
    end
    deq_ok(cut:face_origins(bore), { { 1, wall_id } }, "the bore came from the pin's wall")
    t.eq(cut:face_id(bore), 7, "renumbered: the wall's id is the box's")
    for f = 0, cut.faces - 1 do
      if f ~= bore then deq_ok(cut:face_origins(f), { { 0, cut:face_id(f) } }, "the box's own") end
    end
    local h = cut:history(block, pin)
    t.eq(getmetatable(h), bs.History)
    local kept = {}
    for k = 1, 6 do kept[k] = { { 0, k }, k } end
    deq_ok(h.kept, kept, "the box's six kept")
    deq_ok(h.modified, { { { 1, wall_id }, { 7 } } }, "the bore modified")
    deq_ok(h.generated, {})
    deq_ok(h.deleted, caps, "the pin's two caps deleted")
    t.eq(tostring(h), "History(kept=6, modified=1, generated=0, deleted=2)")
    local e = cut:edge_history(block, pin)
    t.eq(#e.kept, 12)
    deq_ok(e.deleted, { { 1, 1 }, { 1, 2 }, { 1, 3 } })
    t.eq(#e.generated, 3)
    deq_ok(e.modified, {})
    t.raises(function() cut:history(block, bs.Solid.cuboid(1, 1, 1)) end, "^history: input 1 is not tracked$")
    t.raises(function() cut:history(block) end, "^history: face %d+ names operand 1")
    t.raises(function() bs.Solid.cuboid(1, 1, 1):edge_history(block) end, "^edge_history: the result is not tracked$")
  end)

  t.test("a union renumbers the second operand's clashing ids", function()
    local a = bs.Solid.cuboid(10, 10, 10):tracked()
    local b = bs.Solid.cuboid(10, 10, 10):translate(5, 5, 5):tracked()
    local joined = a:join(b)
    t.eq(joined.faces, 12)
    local firsts, seconds, origins_of_seconds = {}, {}, {}
    for f = 0, joined.faces - 1 do
      local o = joined:face_origins(f)[1]
      if o[1] == 0 then
        t.eq(joined:face_id(f), o[2])
        firsts[#firsts + 1] = o[2]
      else
        seconds[#seconds + 1] = joined:face_id(f)
        origins_of_seconds[#origins_of_seconds + 1] = o[2]
      end
    end
    table.sort(firsts)
    table.sort(origins_of_seconds)
    deq_ok(firsts, { 1, 2, 3, 4, 5, 6 })
    deq_ok(seconds, { 7, 8, 9, 10, 11, 12 }, "renumbered in face order")
    deq_ok(origins_of_seconds, { 1, 2, 3, 4, 5, 6 }, "their origins name operand 1's own ids")
  end)

  t.test("a split halves the sides and its bodies keep the split's origins", function()
    local block = bs.Solid.cuboid(2, 4, 6):tracked()
    local pieces = block:split_by_plane(XY)
    t.eq(#pieces, 2)
    local halves, n_sides = {}, 0
    for f = 0, 5 do
      if math.abs(nz(block, f)) < 0.5 then
        halves[block:face_id(f)] = {}
        n_sides = n_sides + 1
      end
    end
    t.eq(n_sides, 4)
    local cut_faces, caps = 0, 0
    for _, piece in ipairs(pieces) do
      for f = 0, piece.faces - 1 do
        local o, id = piece:face_origins(f), piece:face_id(f)
        if #o == 0 then
          t.ok(id > 6, "a cut face is generated, with a fresh id")
          cut_faces = cut_faces + 1
        elseif halves[o[1][2]] then
          deq_ok(o, { { 0, o[1][2] } })
          local list = halves[o[1][2]]
          list[#list + 1] = id
        else
          deq_ok(o, { { 0, id } }, "a cap is kept")
          caps = caps + 1
        end
      end
    end
    t.eq(cut_faces, 2)
    t.eq(caps, 2)
    for s, ids in pairs(halves) do
      local keeping = 0
      for _, id in ipairs(ids) do if id == s then keeping = keeping + 1 end end
      t.ok(#ids == 2 and keeping == 1, "side " .. s .. " in two, one half keeping its id: " .. show(ids))
    end
    for _, piece in ipairs(pieces) do
      local h = piece:history(block)
      t.eq(#h.generated, 1)
      t.eq(#h.deleted, 1)
    end
  end)

  t.test("a fillet's round is generated", function()
    local block = bs.Solid.cuboid(10, 10, 10):tracked()
    local rounded = block:fillet({ 0 }, 1.0)
    t.eq(rounded.faces, 7)
    local round
    for f = 0, rounded.faces - 1 do
      if rounded:face_kind(f) ~= "plane" then round = f end
    end
    deq_ok(rounded:face_origins(round), {})
    t.eq(rounded:face_id(round), 7)
    local h = rounded:history(block)
    deq_ok(h.generated, { 7 })
    t.eq(#h.kept, 6)
    t.eq(rounded:edge_with_id(1), nil, "the rounded edge is gone")
  end)

  t.test("a flush join with merge names one origin per input", function()
    local a = bs.Solid.cuboid(10, 10, 10):tracked()
    local b = bs.Solid.cuboid(4, 10, 10):translate(7, 0, 0):tracked()
    local merged = a:join(b, nil, nil, true)
    t.eq(merged.faces, 6)
    local two = 0
    for f = 0, merged.faces - 1 do
      local o = merged:face_origins(f)
      if math.abs(merged:face_ref(f)[5]) < 0.5 then
        -- The four faces along x: one origin in each box, (0, id) and (1, id).
        t.ok(#o == 2 and o[1][1] == 0 and o[2][1] == 1, "face " .. f .. ": " .. show(o))
        t.ok(a:face_with_id(o[1][2]) ~= nil and b:face_with_id(o[2][2]) ~= nil)
        two = two + 1
      else
        t.eq(#o, 1, "face " .. f .. ": " .. show(o))
      end
    end
    t.eq(two, 4)
    local h = merged:history(a, b)
    deq_ok(h.generated, {})
    t.eq(#h.deleted, 2, "the two flush faces")
    local ones = 0
    for _, m in ipairs(h.modified) do
      if #m[2] == 1 and m[1][1] == 1 then ones = ones + 1 end
    end
    t.eq(ones, 4)
  end)

  t.test("the same chain twice numbers the same", function()
    local function run()
      local block, pin = block_and_pin()
      local cut = block:cut(pin)
      local line
      for _, e in ipairs(cut.edges) do
        if e.is_line then line = e.index break end
      end
      local r = cut:fillet({ line }, 1.0)
      local faces, edges = {}, {}
      for f = 0, r.faces - 1 do faces[#faces + 1] = r:face_id(f) end
      for e = 0, #r.edges - 1 do edges[#edges + 1] = r:edge_id(e) end
      return { faces, edges }
    end
    deq_ok(run(), run())
  end)

  t.test("attributes are set, read, listed and refused", function()
    local s = bs.Solid.cuboid(1, 2, 3):with_attribute("material", "steel")
    t.eq(s.is_tracked, true, "an attribute rides with the ids")
    t.eq(s:attribute("material"), "steel")
    t.eq(s:attribute("absent"), nil)
    deq_ok(s.attributes, { { "material", "steel" } })
    local both = s:with_attributes({ zeta = "1", alpha = "2" })
    deq_ok(both.attributes, { { "alpha", "2" }, { "material", "steel" }, { "zeta", "1" } })
    deq_ok(s:with_attributes({ { "zeta", "1" }, { "alpha", "2" } }).attributes, both.attributes, "pairs too")
    local text = "acciaio inossidabile \195\168 \226\152\131 \240\159\148\167"
    t.eq(s:with_attribute("m", text):attribute("m"), text)
    t.eq(s:with_attribute("empty", ""):attribute("empty"), "")
    t.raises(function() s:with_attribute("", "x") end, "^with_attribute: the key is empty$")
    deq_ok(s:without_attribute("absent").attributes, { { "material", "steel" } })
    deq_ok(s:without_attribute("material").attributes, {})
    deq_ok(bs.Solid.cuboid(1, 1, 1).attributes, {})
  end)

  t.test("face attributes survive a translate and a split", function()
    local block = bs.Solid.cuboid(10, 10, 10)
    local side
    for f = 0, 5 do
      if not side and math.abs(nz(block, f)) < 0.5 then side = f end
    end
    local s = block:with_face_attribute(side, "finish", "ground")
    t.eq(s:face_attribute(side, "finish"), "ground")
    local other = (side + 1) % 6
    t.eq(s:face_attribute(other, "finish"), nil)
    deq_ok(s:face_attributes(other), {})
    deq_ok(s:face_attributes(side), { { "finish", "ground" } })
    local two = s:with_face_attributes(side, { b = "1", a = "2" })
    deq_ok(two:face_attributes(side), { { "a", "2" }, { "b", "1" }, { "finish", "ground" } })
    deq_ok(s:without_face_attribute(side, "finish"):face_attributes(side), {})
    t.eq(s:translate(5, 0, 0):face_attribute(side, "finish"), "ground")
    t.raises(function() s:face_attribute(6, "finish") end, "^face_attribute: face 6 is not one of the solid's 6$")
    t.raises(function() s:with_face_attribute(side, "", "x") end, "^with_face_attribute: the key is empty$")
    -- A split face's pieces keep their parent's attributes.
    local side_id = s:face_id(side)
    local found = {}
    for _, p in ipairs(s:split_by_plane(XY)) do
      for f = 0, p.faces - 1 do
        for _, o in ipairs(p:face_origins(f)) do
          if o[1] == 0 and o[2] == side_id then found[#found + 1] = p:face_attribute(f, "finish") end
        end
      end
    end
    deq_ok(found, { "ground", "ground" })
  end)

  t.test("a solid's attributes reach STEP", function()
    local text = bs.Solid.cuboid(1, 2, 3):with_attribute("material", "steel"):step_text()
    local n = 0
    for _ in text:gmatch("PROPERTY_DEFINITION%('material','user defined attribute',") do n = n + 1 end
    t.eq(n, 1)
    t.ok(text:find("DESCRIPTIVE_REPRESENTATION_ITEM('material','steel')", 1, true))
    t.ok(text:sub(1, (text:find("ENDSEC;", 1, true))):find("AP242", 1, true), "the header names the AP242 schema")
  end)

  t.test("edges are found again after a stretch and vertices after a move", function()
    local box, long = bs.Solid.cuboid(10, 10, 10), bs.Solid.cuboid(11, 10, 10)
    local n = #box.edges
    local refs, found = {}, {}
    for e = 0, n - 1 do
      refs[e + 1] = box:edge_ref(e)
      t.eq(#refs[e + 1], 15)
      found[e + 1] = long:find_edge(refs[e + 1])
    end
    local sorted = {}
    for i, g in ipairs(found) do sorted[i] = g end
    table.sort(sorted)
    local all = {}
    for e = 0, n - 1 do all[e + 1] = e end
    deq_ok(sorted, all, "a permutation of every edge")
    for i, r in ipairs(refs) do
      local tangent = long:edge_ref(found[i])
      local dot = r[5] * tangent[5] + r[6] * tangent[6] + r[7] * tangent[7]
      t.ok(math.abs(dot) > 0.99, "tangents parallel")
    end
    local bad = {}
    for i = 1, 15 do bad[i] = refs[1][i] end
    bad[2] = 0 / 0
    t.raises(function() box:find_edge(bad) end, "^find_edge: an edge reference is fifteen finite numbers$")
    local short = {}
    for i = 1, 14 do short[i] = refs[1][i] end
    t.raises(function() box:find_edge(short) end, "^find_edge: an edge reference is fifteen finite numbers$")
    t.raises(function() box:edge_ref(12) end, "^edge_ref: edge 12 of 12$")
    t.eq(box.vertex_count, 8)
    local moved = box:translate(1e-4, 0, 0)
    for v = 0, 7 do
      local p = box:vertex_ref(v)
      t.eq(#p, 3)
      t.eq(moved:find_vertex(p), v)
    end
    t.eq(box:find_vertex({ 100, 0, 0 }), nil)
    t.raises(function() box:find_vertex({ 0, 0, 0 / 0 }) end, "^find_vertex: ")
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
    t.raises(function() cube:leaked_edges(-1) end, "^leaked_edges: tolerance must be positive and finite")
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
    t.raises(function() bs.Profile.circle(1):hits(bs.Profile.circle(2), -1) end,
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
    t.raises(function() a:intersect(b, -1.0) end, "intersect: tolerance must be positive and finite")
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

  -- ---- clash: test_cadaclysm_blacksmith.py's test_clash_* trimmed to the marshalling, plus the
  -- edge rows (an edge against an edge, and an edge against a face, so a swap of the two sides shows).

  -- The frame at (x, y, z), axes along the world's.
  local function at(x, y, z) return { x, y or 0, z or 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 } end

  local function near_point(p, q, tolerance)
    for i = 1, 3 do
      if math.abs(p[i] - q[i]) > tolerance then return false end
    end
    return true
  end

  t.test("clash: balls within the clearance are too close", function()
    local collider = bs.Collider({ bs.Solid.sphere(1), bs.Solid.sphere(1) }, 1e-3)
    local rows = collider:clash({ at(0), at(2.5) }, 1)
    t.eq(#rows, 1)
    local r = rows[1]
    t.ok(getmetatable(r) == bs.Clash)
    t.eq(r.a, 0)
    t.eq(r.b, 1)
    t.eq(r.kind, "too_close")
    t.ok(math.abs(r.distance - 0.5) <= 1e-3, "distance " .. r.distance)
    t.eq(r.kind_a, "face")
    t.eq(r.kind_b, "face")
    t.eq(type(r.index_a), "number")
    t.eq(type(r.index_b), "number")
    t.eq(r.edge_a, nil)
    t.eq(r.edge_b, nil)
    t.ok(math.abs(r.on_a[1] - 1) <= 2e-3, "on_a " .. table.concat(r.on_a, ", "))
    t.ok(math.abs(r.on_b[1] - 1.5) <= 2e-3, "on_b " .. table.concat(r.on_b, ", "))
    t.eq(r.text, "")
    t.eq(r.depth, 0)
    t.eq(type(r.refined), "boolean")
    t.eq(tostring(r), ("Clash(a=0, b=1, kind='too_close', distance=%.9g)"):format(r.distance))
    t.eq(#collider:clash({ at(0), at(2.5) }, 0.25), 0)
  end)

  t.test("clash: boxes face to face touch and intersect on the shared face", function()
    local collider = bs.Collider({ bs.Solid.cuboid(2, 2, 2), bs.Solid.cuboid(2, 2, 2) })
    local rows = collider:clash({ at(0), at(2) })
    t.eq(#rows, 1)
    local r = rows[1]
    t.eq(r.kind, "touching")
    t.ok(r.distance <= 1e-3, "distance " .. r.distance)
    t.raises(function() r:solid() end, "^clashes_solid: pair %(0, 1%) is not penetrating")
    local x = r:intersect()
    t.ok(getmetatable(x) == bs.Intersection)
    t.eq(#x.overlaps, 1)
    local ring = x.overlaps[1].loops[1]
    t.ok(#ring >= 3)
    local area = 0
    for i, p in ipairs(ring) do
      t.ok(math.abs(p[1] - 1) <= 1e-3, "x " .. p[1])
      local q = ring[i % #ring + 1]
      area = area + p[2] * q[3] - q[2] * p[3]
    end
    t.near(math.abs(area) / 2, 4, 1e-6, "the shared face's area")
  end)

  t.test("clash: interpenetrating boxes report the depth and outlive the collider", function()
    local collider = bs.Collider({ bs.Solid.cuboid(2, 2, 2), bs.Solid.cuboid(2, 2, 2) })
    local rows = collider:clash({ at(0), at(1.75) })
    collider:close()
    t.eq(#rows, 1)
    local r = rows[1]
    rows = nil
    collectgarbage()
    collectgarbage()
    t.eq(r.kind, "penetrating")
    t.ok(math.abs(r.depth - 0.25) < 1e-9, "depth " .. r.depth)
    t.eq(r.distance, 0)
    t.eq(r.kind_a, "none")
    t.eq(r.kind_b, "none")
    t.eq(r.index_a, nil)
    t.eq(r.index_b, nil)
    t.eq(r.edge_a, nil)
    t.eq(r.edge_b, nil)
    t.near(r:solid():mass().volume, 1, 1e-6, "the overlap's volume")
    t.ok(getmetatable(r:intersect()) == bs.Intersection)
  end)

  t.test("clash: the one-shot indexes the second set, and one set with allowed", function()
    local a0, a1 = bs.Solid.sphere(1), bs.Solid.sphere(1):translate(2.05, 0, 0)
    local b0, b1 = bs.Solid.sphere(1):translate(0, 2.5, 0), bs.Solid.sphere(1):translate(10, 0, 0)
    local two = bs.clash({ a0, a1 }, { b0, b1 }, 1, 1e-3)
    t.eq(#two, 1)
    t.eq(two[1].a, 0)
    t.eq(two[1].b, 0)
    t.eq(two[1].kind, "too_close")
    t.ok(math.abs(two[1].distance - 0.5) <= 1e-3, "distance " .. two[1].distance)
    local one = bs.clash({ a0, a1 }, nil, 1, 1e-3)
    t.eq(#one, 1)
    t.eq(one[1].a, 0)
    t.eq(one[1].b, 1)
    t.eq(#bs.clash({ a0, a1 }, nil, 1, 1e-3, { 0, 1 }), 0)
  end)

  t.test("clash: refusals carry the call's prefix", function()
    local a, b = bs.Solid.cuboid(2, 2, 2), bs.Solid.cuboid(2, 2, 2)
    local collider = bs.Collider({ a, b })
    t.raises(function() collider:clash({ at(0), at(1.75) }, -1) end, "^collider_clash: clearance %-1")
    t.raises(function() collider:clash({ at(0) }) end, "^collider_clash: 1 frames for 2 groups")
    t.raises(function() collider:clash({ at(0), at(1.75) }, 0, { 2, 2 }) end, "^collider_clash: share %(2, 2%)")
    t.eq(collider:clash({ at(0), at(1.75) })[1].kind, "penetrating")
    collider:close()
    t.raises(function() bs.clash({ a, b }, nil, -1) end, "^clash: clearance %-1")
    t.raises(function() bs.clash({ a, b }, nil, 0, 0.05, { 5, 0 }) end,
      "^clash: allowed pair %(5, 0%) names a part out of range")
    t.raises(function() bs.clash({ a, b }, nil, 0, 0.05, { 0, 1, 2 }) end, "^clash: allowed is 3 numbers, not pairs$")
    for _, bad in ipairs({ { -1, 0 }, { 0, 2 ^ 32 }, { 0, 0.5 }, { 0, "x" } }) do
      t.raises(function() bs.clash({ a, b }, nil, 0, 0.05, bad) end, "^clash: allowed pair %(.*%) is not two indices$")
    end
    t.raises(function() bs.clash({ a, b }, {}) end, "^clash: an empty set$")
  end)

  -- ---- swept clash: test_cadaclysm_blacksmith.py's test_swept_clash_* trimmed to the marshalling.
  -- A 2-cube moving along x from -5 to 5 through a 2-cube at the origin meets it at t = 0.3 and
  -- leaves at 0.7, at a relative speed of 10 a segment.

  local SWEPT_TOL, SWEPT_RES = 1e-3, 1e-3
  local function through() return { { at(-5), at(0) }, { at(5), at(0) } } end

  -- The time `got` within the first-time tolerance of `want`, and an end within the resolution.
  local function near_start(got, want) return math.abs(got - want) <= SWEPT_TOL / 10 + 1e-9 end
  local function near_end(got, want) return math.abs(got - want) <= SWEPT_RES + SWEPT_TOL / 10 end

  t.test("swept clash: a cube through a cube", function()
    local collider = bs.Collider({ bs.Solid.cuboid(2, 2, 2), bs.Solid.cuboid(2, 2, 2) }, SWEPT_TOL)
    local rows = collider:swept_clash(through())
    collider:close()
    collectgarbage()
    collectgarbage()
    t.eq(#rows, 1)
    local r = rows[1]
    t.ok(getmetatable(r) == bs.SweptClash)
    t.ok(getmetatable(r.first) == bs.Clash)
    t.eq(r.a, 0)
    t.eq(r.b, 1)
    t.ok(near_start(r.first_time, 0.3), "first_time " .. r.first_time)
    t.eq(#r.intervals, 1)
    local span = r.intervals[1]
    t.eq(span[1], r.first_time)
    t.ok(near_end(span[2], 0.7), "end " .. span[2])
    t.eq(r.first.a, 0)
    t.eq(r.first.b, 1)
    t.eq(r.first.kind, "touching")
    t.eq(tostring(r), ("SweptClash(a=0, b=1, first_time=%.9g, kind='touching', intervals={{%.9g, %.9g}})")
      :format(r.first_time, span[1], span[2]))
    -- the first row keeps its own handle: the collider is gone, the contact still rebuilds
    t.raises(function() r.first:solid() end, "^clashes_solid: pair %(0, 1%) is not penetrating")
    local x = r.first:intersect()
    t.eq(#x.overlaps, 1)
    for _, loop in ipairs(x.overlaps[1].loops) do
      for _, p in ipairs(loop) do t.ok(math.abs(p[1] + 1) <= 2 * SWEPT_TOL, "x " .. p[1]) end
    end
  end)

  t.test("swept clash: there and back is two intervals", function()
    local collider = bs.Collider({ bs.Solid.cuboid(2, 2, 2), bs.Solid.cuboid(2, 2, 2) }, SWEPT_TOL)
    local poses = through()
    poses[3] = { at(-5), at(0) }
    local rows = collider:swept_clash(poses)
    collider:close()
    t.eq(#rows, 1)
    local spans = rows[1].intervals
    t.eq(#spans, 2)
    for i, want in ipairs({ { 0.3, 0.7 }, { 1.3, 1.7 } }) do
      t.ok(near_start(spans[i][1], want[1]), ("interval %d starts at %.9g"):format(i, spans[i][1]))
      t.ok(near_end(spans[i][2], want[2]), ("interval %d ends at %.9g"):format(i, spans[i][2]))
    end
  end)

  t.test("swept clash: a miss is seen only within the clearance", function()
    local collider = bs.Collider({ bs.Solid.cuboid(2, 2, 2), bs.Solid.cuboid(2, 2, 2) }, SWEPT_TOL)
    local passing = { { at(-5, 2.5), at(0) }, { at(5, 2.5), at(0) } }
    t.eq(#collider:swept_clash(passing, 0.4), 0)
    local rows = collider:swept_clash(passing, 0.6)
    collider:close()
    t.eq(#rows, 1)
    t.eq(rows[1].first.kind, "too_close")
    local d = rows[1].first.distance
    t.ok(0.5 - SWEPT_TOL <= d and d <= 0.6, "distance " .. d)
    t.eq(#rows[1].intervals, 1)
  end)

  t.test("swept clash: a pair starting inside rebuilds the overlap at its first time", function()
    -- the cubes share a 0.25 slab at t = 0, then a moves clear
    local collider = bs.Collider({ bs.Solid.cuboid(2, 2, 2), bs.Solid.cuboid(2, 2, 2) }, SWEPT_TOL)
    local rows = collider:swept_clash({ { at(1.75), at(0) }, { at(5), at(0) } })
    collider:close()
    t.eq(#rows, 1)
    t.eq(rows[1].first_time, 0)
    t.eq(rows[1].first.kind, "penetrating")
    t.near(rows[1].first:solid():mass().volume, 1, 1e-6, "the overlap's volume")
  end)

  t.test("swept clash: the one-shot indexes the second set, and one set with allowed", function()
    -- set a still at the origin and at y = 20; set b carried along x through them
    local a0, a1 = bs.Solid.cuboid(2, 2, 2), bs.Solid.cuboid(2, 2, 2):translate(0, 20, 0)
    local b0, b1 = bs.Solid.cuboid(2, 2, 2), bs.Solid.cuboid(2, 2, 2)
    local still = { { at(0), at(0) }, { at(0), at(0) } }
    local moving = { { at(-5), at(-5, 20) }, { at(5), at(5, 20) } }
    local two = bs.swept_clash({ a0, a1 }, still, { b0, b1 }, moving, nil, SWEPT_TOL)
    t.eq(#two, 2)
    for i, r in ipairs(two) do
      t.eq(r.a, i - 1)
      t.eq(r.b, i - 1)
      t.eq(r.first.a, i - 1)
      t.eq(r.first.b, i - 1)
      t.ok(near_start(r.first_time, 0.3), "first_time " .. r.first_time)
    end
    local one_poses = { { at(0), at(-5) }, { at(0), at(5) } }
    local one = bs.swept_clash({ a0, b0 }, one_poses, nil, nil, nil, SWEPT_TOL)
    t.eq(#one, 1)
    t.eq(one[1].a, 0)
    t.eq(one[1].b, 1)
    t.eq(#bs.swept_clash({ a0, b0 }, one_poses, nil, nil, nil, SWEPT_TOL, nil, nil, { 0, 1 }), 0)
  end)

  t.test("swept clash: refusals carry the call's prefix", function()
    local a, b = bs.Solid.cuboid(2, 2, 2), bs.Solid.cuboid(2, 2, 2)
    local collider = bs.Collider({ a, b }, SWEPT_TOL)
    local first_only = { through()[1] }
    t.raises(function() collider:swept_clash(first_only) end, "^collider_swept_clash: 1 poses, at least 2 are needed")
    t.raises(function() collider:swept_clash({ { at(0) }, { at(0) } }) end, "^collider_swept_clash: 1 frames for 2 groups")
    t.raises(function() collider:swept_clash({ { at(0), at(0) }, { at(0) } }) end,
      "^collider_swept_clash: 1 frames for 2 groups$")
    t.raises(function() collider:swept_clash(through(), 0, 0) end, "^collider_swept_clash: resolution 0")
    t.raises(function() collider:swept_clash(through(), 0, 1e-3, 0) end,
      "^collider_swept_clash: max_steps must be at least 1")
    t.raises(function() collider:swept_clash(through(), -1) end, "^collider_swept_clash: clearance %-1")
    t.raises(function() collider:swept_clash(through(), 0, 1e-3, 100000, { 2, 2 }) end,
      "^collider_swept_clash: share %(2, 2%)")
    t.eq(#collider:swept_clash(through()), 1)
    collider:close()
    local still = { { at(0) }, { at(0) } }
    t.raises(function() bs.swept_clash({ a }, still, { b }) end, "^swept_clash: others and other_poses go together$")
    t.raises(function() bs.swept_clash({ a }, still, nil, still) end, "^swept_clash: others and other_poses go together$")
    t.raises(function() bs.swept_clash({ a }, still, { b }, { still[1] }) end, "^swept_clash: 2 poses for set a, 1 for set b$")
    t.raises(function() bs.swept_clash({ a }, still, { b }, { { at(0) }, { at(0), at(0) } }) end,
      "^swept_clash: pose 1 of set b has 2 frames for 1 parts$")
    t.raises(function() bs.swept_clash({ a }, still, {}, { {}, {} }) end, "^swept_clash: an empty set$")
    t.raises(function() bs.swept_clash({ a, b }, through(), nil, nil, 0, 0.05, 1e-3, 100000, { 5, 0 }) end,
      "^swept_clash: allowed pair %(5, 0%) names a part out of range")
    t.raises(function() bs.swept_clash({ a, b }, through(), nil, nil, 0, 0.05, 1e-3, 100000, { 0, 1, 2 }) end,
      "^swept_clash: allowed is 3 numbers, not pairs$")
    for _, bad in ipairs({ { -1, 0 }, { 0, 2 ^ 32 }, { 0, 0.5 }, { 0, "x" } }) do
      t.raises(function() bs.swept_clash({ a, b }, through(), nil, nil, 0, 0.05, 1e-3, 100000, bad) end,
        "^swept_clash: allowed pair %(.*%) is not two indices$")
    end
    t.raises(function() bs.swept_clash({ a, b }, through(), nil, nil, 0, 0.05, 1e-3, 0) end,
      "^swept_clash: max_steps must be at least 1")
    t.raises(function() bs.swept_clash({ a, b }, first_only) end, "^swept_clash: 1 poses, at least 2 are needed")
  end)

  -- ---- an assembly's swept clash: test_cadaclysm_blacksmith.py's test_assembly_* swept tests
  -- trimmed to the marshalling, on its rig: a `base` plate on link `ground`; an `arm`,
  -- cuboid(3, 0.2, 0.2) from the hinge out along x, on link `arm`, turning on `hinge` (revolute
  -- about z through the origin); a `carriage` far out on `slide` (cylindrical, two values); and
  -- two cubes in no link, held fixed: `chord` below the hinge, which the chord between the arm's
  -- end poses crosses and its arc never does, and `circle` on the arm's circle at 90 degrees.
  do
    local function rig_of(hand)
      local rig = bs.Assembly("rig")
      rig:place(bs.Solid.cuboid(1, 1, 0.4), at(0, 0, -1), "base")
      if hand == nil then
        rig:place(bs.Solid.cuboid(3, 0.2, 0.2), at(1.5), "arm")
      else
        rig:place(hand, at(1.5), "hand")
      end
      rig:place(bs.Solid.cuboid(0.4, 0.4, 0.4), at(0, -1.2), "chord")
      rig:place(bs.Solid.cuboid(0.4, 0.4, 0.4), at(0, 1.5), "circle")
      rig:place(bs.Solid.cuboid(0.4, 0.4, 0.4), at(20), "carriage")
      rig:link("ground", { "base" })
      rig:link("arm", { hand == nil and "arm" or "hand" })
      rig:link("carriage", { "carriage" })
      for _, j in ipairs({ { "hinge", "arm", "revolute" }, { "slide", "carriage", "cylindrical" } }) do
        rig:joint(j[1], "ground", j[2])
        rig:pair(j[1], j[3], at(0))
      end
      rig:base("ground")
      return rig
    end

    -- a `tip` cube on link `body`, and a `nub` well above it on `nubs`, turning on `turn`
    local function hand_of()
      local hand = bs.Assembly("hand")
      hand:place(bs.Solid.cuboid(0.4, 0.4, 0.4), at(0), "tip")
      hand:place(bs.Solid.cuboid(0.2, 0.2, 0.2), at(0, 0, 2), "nub")
      hand:link("body", { "tip" })
      hand:link("nubs", { "nub" })
      hand:joint("turn", "body", "nubs")
      hand:pair("turn", "revolute", at(0))
      return hand
    end

    -- the hinge at 0, 90 and 180 degrees, the carriage sliding 0, 0.5, 1 unturned; rows, so the
    -- hinge comes first
    local SWING = {
      { { "hinge", 0.0 }, { "slide", { 0.0, 0.0 } } },
      { { "hinge", math.pi / 2 }, { "slide", { 0.5, 0.0 } } },
      { { "hinge", math.pi }, { "slide", { 1.0, 0.0 } } },
    }

    -- The time the arm's leading face (y = 0.1 in its own frame) is `gap` from the circle cube's
    -- corner (0.2, 1.3), the first point it meets, in the first segment.
    local function circle_time(gap)
      local r, phi = math.sqrt(1.3 ^ 2 + 0.2 ^ 2), math.atan2(0.2, 1.3)
      return (math.acos((0.1 + gap) / r) - phi) / (math.pi / 2)
    end

    local function named_rows(names, rows)
      local out = {}
      for i, r in ipairs(rows) do out[i] = names[r.a + 1] .. " x " .. names[r.b + 1] end
      return table.concat(out, ", ")
    end

    t.test("assembly parts are listed depth first and escaped", function()
      local sub = bs.Assembly("pair")
      sub:place(bs.Solid.cuboid(1, 1, 1), at(0), "x")
      sub:place(bs.Solid.cuboid(1, 1, 1), at(2), "y")
      local top = bs.Assembly("top")
      top:place(bs.Solid.cuboid(1, 1, 1), at(0, 5), "p")
      top:place(sub, at(0), "a/b")
      top:place(bs.Solid.cuboid(1, 1, 1), at(0, 9), "q")
      t.eq(table.concat(top:parts(), "|"), "p|a\\/b/x|a\\/b/y|q")
      t.eq(#top:parts(), 4)
      t.eq(#bs.Assembly("empty"):parts(), 0)
    end)

    t.test("assembly swept clash sweeps the arc, not the chord", function()
      local rig = rig_of()
      local names = rig:parts()
      t.eq(table.concat(names, "|"), "base|arm|chord|circle|carriage")
      local rows = rig:swept_clash(SWING, { tolerance = SWEPT_TOL })
      t.eq(named_rows(names, rows), "arm x circle")
      local r = rows[1]
      t.ok(getmetatable(r) == bs.SweptClash)
      t.ok(getmetatable(r.first) == bs.Clash)
      local within, meets = circle_time(SWEPT_TOL), circle_time(0)
      t.ok(within - 1e-9 <= r.first_time and r.first_time <= meets + 1e-9,
        ("first_time %.9g outside [%.9g, %.9g]"):format(r.first_time, within, meets))
      -- a joint key as a list of names, a map, and a number as a one-value list read the same
      local again = {}
      for k, frame in ipairs(SWING) do
        again[k] = { { { "hinge" }, { frame[1][2] } }, { "slide", frame[2][2] } }
      end
      local same = rig:swept_clash(again, { tolerance = SWEPT_TOL })
      t.eq(#same, 1)
      t.eq(same[1].first_time, r.first_time)
      local maps = {}
      for k, frame in ipairs(SWING) do maps[k] = { hinge = frame[1][2], slide = frame[2][2] } end
      local mapped = rig:swept_clash(maps, { tolerance = SWEPT_TOL })
      t.eq(#mapped, 1)
      t.eq(mapped[1].first_time, r.first_time)
    end)

    t.test("assembly swept clash: first is at the posed frames", function()
      -- the arm starts at 1.5 rad, already through the circle cube: penetrating at time 0, and
      -- the overlap rebuilt from the first row lies inside the arm's box turned 1.5 about z
      local rig = rig_of()
      local rows = rig:swept_clash({
        { { "hinge", 1.5 }, { "slide", { 0, 0 } } }, { { "hinge", math.pi }, { "slide", { 0, 0 } } },
      }, { tolerance = SWEPT_TOL })
      t.eq(#rows, 1)
      t.eq(rows[1].a, 1)
      t.eq(rows[1].b, 3)
      t.eq(rows[1].first_time, 0)
      local got = rows[1].first:solid():bounds_box_at(SWEPT_TOL)
      local co, si = math.cos(1.5), math.sin(1.5)
      local want = bs.Solid.cuboid(3, 0.2, 0.2):translate(1.5, 0, 0):bounds_box_at(SWEPT_TOL)
        :moved({ 0, 0, 0, co, si, 0, -si, co, 0, 0, 0, 1 })
      for k = 1, 3 do
        t.ok(want.lo[k] - 1e-6 <= got.lo[k] and got.hi[k] <= want.hi[k] + 1e-6,
          ("axis %d: got [%.9g, %.9g], want within [%.9g, %.9g]"):format(k, got.lo[k], got.hi[k], want.lo[k], want.hi[k]))
      end
      t.ok(got.lo[2] >= 1.3 - 4 * SWEPT_TOL and got.hi[2] <= 1.7 + 4 * SWEPT_TOL and got.hi[1] > got.lo[1],
        ("y [%.9g, %.9g], x [%.9g, %.9g]"):format(got.lo[2], got.hi[2], got.lo[1], got.hi[1]))
    end)

    t.test("assembly swept clash tests joined links only when asked", function()
      -- a pin on the arm's link inside a bore on the ground link, the hinge joining them
      local pinned = bs.Assembly("pinned")
      pinned:place(bs.Solid.cuboid(0.6, 0.6, 0.6), at(0), "bore")
      pinned:place(bs.Solid.cuboid(0.2, 0.2, 0.2), at(0), "pin")
      pinned:link("ground", { "bore" })
      pinned:link("arm", { "pin" })
      pinned:joint("hinge", "ground", "arm")
      pinned:pair("hinge", "revolute", at(0))
      local keys = { { hinge = 0.0 }, { hinge = 1.0 } }
      t.eq(#pinned:swept_clash(keys, { tolerance = SWEPT_TOL }), 0)
      local rows = pinned:swept_clash(keys, { tolerance = SWEPT_TOL, joined = true })
      t.eq(#rows, 1)
      t.eq(rows[1].a, 0)
      t.eq(rows[1].b, 1)
      t.eq(rows[1].first_time, 0)
      t.eq(#pinned:swept_clash(keys, { tolerance = SWEPT_TOL, joined = true, allowed = { 0, 1 } }), 0)
    end)

    t.test("assembly swept clash: a sub-assembly rides its placement's link", function()
      local rig = rig_of(hand_of())
      local names = rig:parts()
      t.eq(table.concat(names, "|"), "base|hand/tip|hand/nub|chord|circle|carriage")
      t.eq(named_rows(names, rig:swept_clash(SWING, { tolerance = SWEPT_TOL })), "hand/tip x circle")
    end)

    t.test("assembly swept clash refuses in the kernel's words", function()
      local rig = rig_of(hand_of())
      local two = { { hinge = 0.0 }, { hinge = 1.0 } }
      -- keyframes naming different joints, refused before C is called
      t.raises(function()
        rig:swept_clash({ { hinge = 0.0, slide = { 0, 0 } }, { hinge = 1.0, slide = { 0, 0 } }, { hinge = 2.0 } })
      end, "^swept_clash: joint 'slide' is in keyframe 0 and not in keyframe 2$")
      t.raises(function() rig:swept_clash({ { hinge = 0.0 }, { hinge = 1.0, slide = { 0, 0 } } }) end,
        "^swept_clash: joint 'slide' is in keyframe 1 and not in keyframe 0$")
      t.raises(function() rig:swept_clash({ { hinge = 0.0 }, { { "hinge", 1.0 }, { "hinge", 2.0 } } }) end,
        "^swept_clash: joint 'hinge' is given twice$")
      t.raises(function() rig:swept_clash({ { slide = { 0, 0 } }, { slide = { 1 } } }) end,
        "^swept_clash: joint 'slide' has 2 values in keyframe 0 and 1 in keyframe 1$")
      -- and the kernel's own refusals, passed on
      t.raises(function() rig:swept_clash({ { { { "hand", "turn" }, 0.0 } }, { { { "hand", "turn" }, 1.0 } } }) end,
        "^swept_clash: joint 'hand/turn' is in a sub%-assembly; a sweep moves this assembly's own joints$")
      t.raises(function() rig:swept_clash({ { elbow = 0.0 }, { elbow = 1.0 } }) end,
        "^swept_clash: no joint named 'elbow' in assembly 'rig' or under it$")
      t.raises(function() rig:swept_clash({ { hinge = { 0.0, 0.0 } }, { hinge = { 1.0, 1.0 } } }) end,
        "^swept_clash: joint 'hinge' takes 1 values, but 2 were given$")
      t.raises(function() rig:swept_clash({ two[1] }) end, "^swept_clash: 1 poses, at least 2 are needed$")
      t.raises(function() rig:swept_clash(two, { resolution = 0 }) end, "^swept_clash: resolution 0")
      t.raises(function() rig:swept_clash(two, { max_steps = 0 }) end, "^swept_clash: max_steps must be at least 1$")
      t.raises(function() rig:swept_clash(two, { allowed = { 9, 0 } }) end,
        "^swept_clash: allowed pair %(9, 0%) names a part out of range$")
      t.raises(function() rig:swept_clash(two, { allowed = { 0, 1, 2 } }) end,
        "^swept_clash: allowed is 3 numbers, not pairs$")
      t.raises(function() rig:swept_clash(two, { allowed = { 0, 0.5 } }) end,
        "^swept_clash: allowed pair %(.*%) is not two indices$")
      t.raises(function() rig:swept_clash(two, { ground = "wheel" }) end,
        "^swept_clash: assembly 'rig' has no link named 'wheel'$")
    end)
  end

  -- ---- wall thickness: test_cadaclysm_blacksmith.py's test_thickness_* / test_mesh_thickness_* trimmed
  -- to the marshalling.

  -- The face of body `body` whose reading at `p` lies at `p`.
  local function thickness_face_holding(gauge, solid, body, p)
    for f = 0, solid.faces - 1 do
      local r = gauge:thickness_at(body, f, p, 100, 0.5)
      if r and near_point(r.point, p, 1e-9) then return f end
    end
    error("no face holds " .. table.concat(p, ", "))
  end

  local function thickness_tube()
    return bs.Solid.extrude(bs.Profile.circle(5):with_hole(bs.Profile.circle(4)), XY, 10)
  end

  t.test("thickness: a plate reads two at every cap vertex", function()
    local plate = bs.Solid.cuboid(10, 10, 2)
    local g = bs.ThicknessGauge({ plate })
    t.eq(getmetatable(g), bs.ThicknessGauge)
    t.eq(g.body_count, 1)
    t.eq(getmetatable(g).__len(g), 1)
    t.eq(g.tolerance, 0.01)
    local rows = g:thickness(10, 0.5)
    local mesh = g:mesh(0)
    local caps = 0
    for _, r in ipairs(rows) do
      t.eq(getmetatable(r), bs.Thickness)
      t.eq(r.body, 0)
      t.eq(type(r.vertex), "number")
      t.eq(#r.point, 3)
      local p = mesh.positions[r.vertex + 1]
      t.ok(p[1] == r.point[1] and p[2] == r.point[2] and p[3] == r.point[3], "the vertex indexes the mesh")
      t.ok(r.sphere == nil or type(r.sphere) == "number")
      if math.abs(math.abs(r.point[3]) - 1) < 1e-9 and math.abs(r.opposite[3] + r.point[3]) < 1e-9 then
        caps = caps + 1
        t.near(r.thickness, 2, 1e-9)
        t.near(r.exact_thickness, 2, 1e-9)
        t.near(r.exact_opposite[3], -r.point[3], 1e-9)
        t.eq(r.knife, false)
        t.eq(r.opposite_body, 0)
      end
    end
    t.ok(caps >= 8, "cap rows " .. caps)
    -- below the wall nothing reads; the sharp angle defaults to 0
    t.eq(#g:thickness(1), 0)
    t.eq(#g:thickness(10), #rows)
    t.ok(tostring(rows[1]):find("^Thickness%(") and tostring(g):find("^ThicknessGauge%(bodies=1"))
    g:close()
  end)

  t.test("thickness: the gauge mesh is a copy that matches the readings", function()
    local plate = bs.Solid.cuboid(10, 10, 2)
    local g = bs.ThicknessGauge({ plate })
    local m = g:mesh(0)
    t.eq(getmetatable(m), bs.ThicknessMesh)
    t.eq(#m.faces, #m.triangles)
    t.ok(#m.faces >= 12)
    t.eq(#m.normals, #m.positions)
    t.ok(#m.positions > 0)
    for _, n in ipairs(m.normals) do
      t.near(math.sqrt(n[1] * n[1] + n[2] * n[2] + n[3] * n[3]), 1, 1e-9)
    end
    for i, tri in ipairs(m.triangles) do
      t.eq(#tri, 3)
      for _, k in ipairs(tri) do t.ok(k >= 0 and k < #m.positions, "index in range") end
      t.ok(m.faces[i] >= 0 and m.faces[i] < plate.faces)
    end
    local rows = g:thickness(100, 0.5)
    t.eq(#rows, #m.positions)
    for _, r in ipairs(rows) do
      local face
      for i, tri in ipairs(m.triangles) do
        if tri[1] == r.vertex or tri[2] == r.vertex or tri[3] == r.vertex then face = m.faces[i] break end
      end
      t.eq(face, r.face)
    end
    t.raises(function() g:mesh(1) end, "^thickness_gauge_mesh: no body 1 %-%- there are 1$")
    g:close()
    t.eq(#m.positions, #rows) -- copied out: the mesh outlives the gauge, which refuses once closed
    t.raises(function() g:mesh(0) end, "^thickness_gauge: closed$")
    t.ok(tostring(m):find("^ThicknessMesh%(vertices="))
  end)

  t.test("thickness: at a point reads one row with no vertex", function()
    local plate = bs.Solid.cuboid(10, 10, 2)
    local probe = { 1, 2, 1 }
    local g = bs.ThicknessGauge({ plate })
    local top = thickness_face_holding(g, plate, 0, probe)
    local r = g:thickness_at(0, top, probe, 100, 0.5)
    t.eq(getmetatable(r), bs.Thickness)
    t.eq(r.vertex, nil)
    t.eq(r.body, 0)
    t.eq(r.face, top)
    t.eq(r.opposite_body, 0)
    t.ok(r.point[1] == 1 and r.point[2] == 2 and r.point[3] == 1)
    t.near(r.thickness, 2, 1e-9)
    t.near(r.exact_thickness, 2, 1e-9)
    t.near(r.opposite[3], -1, 1e-9)
    t.near(r.exact_opposite[3], -1, 1e-9)
    t.near(r.sphere, 2, 2 * 0.01)
    t.eq(g:thickness_at(0, top, probe, 1, 0.5), nil) -- thicker than the maximum
    t.eq(g:thickness_at(0, top, probe, 100).thickness, r.thickness)
  end)

  t.test("thickness: at a face reads the plate and nil where nothing is found", function()
    local plate = bs.Solid.cuboid(10, 10, 2)
    local g = bs.ThicknessGauge({ plate })
    local top = thickness_face_holding(g, plate, 0, { 1, 2, 1 })
    local f = g:thickness_at_face(0, top, nil, 100)
    t.eq(getmetatable(f), bs.FaceThickness)
    t.near(f.thickness, 2, 1e-9)
    t.eq(f.uniform, true)
    t.near(f.min, 2, 1e-9)
    t.near(f.max, 2, 1e-9)
    local a = g:thickness_at_face(0, top, { 1, 2, 5 }, 100)
    t.near(a.thickness, 2, 1e-9)
    t.ok(a.min == a.max and a.uniform == true)
    t.eq(g:thickness_at_face(0, top, nil, 1), nil)
    t.eq(g:thickness_at_face(0, top, { 50, 2, 5 }, 100), nil)
    t.raises(function() g:thickness_at_face(0, top) end, "^thickness_gauge_face: the maximum is required$")
    -- the one-solid convenience: a gauge of its own
    local s = plate:thickness_at_face(top, nil, 100)
    t.eq(getmetatable(s), bs.FaceThickness)
    t.near(s.thickness, 2, 1e-9)
    t.eq(s.uniform, true)
    t.near(plate:thickness_at_face(top, { 1, 2, 5 }, 100, 0.05).thickness, 2, 1e-9)
    t.eq(plate:thickness_at_face(top, nil, 1), nil)
    t.ok(tostring(f):find("^FaceThickness%("))
  end)

  t.test("thickness: a ball past the maximum is nil", function()
    local wedge = bs.Solid.extrude(bs.Profile.polygon({ { 0, 0 }, { 10, 0 }, { 0, 10 } }), XY, 20)
    local probe = { 5, 0, 10 }
    local g = bs.ThicknessGauge({ wedge })
    local f = thickness_face_holding(g, wedge, 0, probe)
    local wide = g:thickness_at(0, f, probe, 100, 0.5)
    t.near(wide.sphere, 2 * 5 / (1 + math.sqrt(2)), 0.01)
    local narrow = g:thickness_at(0, f, probe, 4, 0.5)
    t.near(narrow.thickness, 5 / math.sqrt(2), 1e-9)
    t.eq(narrow.sphere, nil)
  end)

  t.test("thickness: two bodies read each other and the one-shot agrees", function()
    local slab = bs.Solid.extrude(bs.Profile.polygon({ { 0, 0 }, { 10, 0 }, { 10, 3 }, { 0, 1 } }), XY, 4)
    local tube = thickness_tube()
    local g = bs.ThicknessGauge({ slab, tube })
    t.eq(g.body_count, 2)
    local via = g:thickness(100, 0.5)
    local one = bs.thickness({ slab, tube }, 100, 0.5)
    t.eq(#one, #via)
    local forward, backward = false, false
    for i, r in ipairs(one) do
      local v = via[i]
      t.ok(r.body == v.body and r.vertex == v.vertex and r.face == v.face and r.thickness == v.thickness
        and r.opposite_body == v.opposite_body, "row " .. i)
      forward = forward or (r.body == 0 and r.opposite_body == 1)
      backward = backward or (r.body == 1 and r.opposite_body == 0)
    end
    t.ok(forward, "the slab reads the tube somewhere")
    t.ok(backward, "the tube reads the slab somewhere")
    t.eq(#bs.thickness({ slab }, 0.001), 0)
    t.ok(#bs.thickness({ slab }, 100, nil, 0.05) > 0)
  end)

  t.test("thickness: a body or face that is not a uint32 is refused, not wrapped", function()
    local plate = bs.Solid.cuboid(10, 10, 2)
    local g = bs.ThicknessGauge({ plate })
    local p = { 1, 2, 1 }
    for _, bad in ipairs({ -1, 0.5, 2 ^ 32, "1" }) do
      t.raises(function() g:thickness_at(bad, 0, p, 10) end, "^thickness_gauge_at: body ")
      t.raises(function() g:thickness_at(0, bad, p, 10) end, "^thickness_gauge_at: face ")
      t.raises(function() g:thickness_at_face(bad, 0, nil, 10) end, "^thickness_gauge_face: body ")
      t.raises(function() g:thickness_at_face(0, bad, nil, 10) end, "^thickness_gauge_face: face ")
      t.raises(function() g:mesh(bad) end, "^thickness_gauge_mesh: body ")
      t.raises(function() plate:thickness_at_face(bad, nil, 10) end, "^thickness_gauge_face: face ")
    end
    t.raises(function() g:mesh(0 / 0) end, "^thickness_gauge_mesh: body must be a whole number")
    g:close()
  end)

  local thickness_lower = { { { 0, 0, 0 }, { 0, 1, 0 }, { 1, 0, 0 } }, { { 0, 1, 2 } } }
  local thickness_upper = { { { 0, 0, 1 }, { 1, 0, 1 }, { 0, 1, 1 } }, { { 0, 1, 2 } } }

  t.test("mesh_thickness: two triangles one apart read one across", function()
    local meshes = { thickness_lower, thickness_upper }
    local rows = bs.mesh_thickness(meshes, 10, 0.5)
    t.eq(#rows, 6)
    local order = {}
    for i, r in ipairs(rows) do
      t.eq(getmetatable(r), bs.MeshThickness)
      t.near(r.thickness, 1, 1e-12)
      t.eq(r.knife, false)
      t.eq(r.opposite_mesh, 1 - r.mesh)
      t.eq(r.opposite_triangle, 0)
      local p = meshes[r.mesh + 1][1][r.vertex + 1]
      t.ok(r.point[1] == p[1] and r.point[2] == p[2] and r.point[3] == p[3], "point")
      t.near(r.opposite[3], 1 - r.point[3], 1e-12)
      t.ok(r.opposite[1] == r.point[1] and r.opposite[2] == r.point[2])
      order[i] = r.mesh .. ":" .. r.vertex
    end
    t.eq(table.concat(order, " "), "0:0 0:1 0:2 1:0 1:1 1:2")
    t.eq(#bs.mesh_thickness(meshes, 0.5, 0.5), 0) -- under the gap nothing
    t.eq(#bs.mesh_thickness({}, 1), 0)
    t.eq(#bs.mesh_thickness(meshes, 10), 6)
    t.ok(tostring(rows[1]):find("^MeshThickness%("))
  end)

  t.test("thickness: refusals carry the call's prefix", function()
    local plate = bs.Solid.cuboid(10, 10, 2)
    t.raises(function() bs.ThicknessGauge({ plate }, -1) end, "^thickness_gauge_new: the tolerance must be positive and finite")
    t.raises(function() bs.ThicknessGauge({ 5 }) end, "^thickness_gauge: expected a Solid")
    local g = bs.ThicknessGauge({ plate })
    t.raises(function() g:thickness(0) end, "^thickness_gauge_measure: the maximum must be positive and finite")
    t.raises(function() g:thickness() end, "^thickness_gauge_measure: the maximum is required$")
    t.raises(function() g:thickness(10, -0.1) end,
      "^thickness_gauge_measure: the sharp angle must be zero or positive and finite")
    t.raises(function() g:thickness_at(3, 0, { 1, 2, 1 }, 10) end, "^thickness_gauge_at: no body 3 %-%- there are 1$")
    t.raises(function() g:thickness_at(0, 99, { 1, 2, 1 }, 10) end,
      "^thickness_gauge_at: no face 99 %-%- the solid has 6 %(0 to 5%)$")
    t.raises(function() g:thickness_at(0, 0, { 1, 0 / 0, 1 }, 10) end, "^thickness_gauge_at: the point must be finite")
    t.raises(function() g:thickness_at(0, 0, { 1, 2 }, 10) end, "^thickness_gauge_at: a point is 3 numbers, got 2$")
    t.raises(function() g:thickness_at(0, 0, { 1, 2, "x" }, 10) end, "^thickness_gauge_at: a point is 3 numbers, got 'x'$")
    t.raises(function() g:thickness_at(0, 0, 5, 10) end, "^thickness_gauge_at: a point is 3 numbers, got 5$")
    t.raises(function() g:thickness_at_face(2, 0, nil, 10) end, "^thickness_gauge_face: no body 2 %-%- there are 1$")
    t.raises(function() g:thickness_at_face(0, 99, nil, 10) end,
      "^thickness_gauge_face: no face 99 %-%- the solid has 6 %(0 to 5%)$")
    t.raises(function() g:thickness_at_face(0, 0, { math.huge, 0, 1 }, 10) end,
      "^thickness_gauge_face: the point must be finite")
    t.raises(function() g:thickness_at_face(0, 0, { 1, 2 }, 10) end, "^thickness_gauge_face: a point is 3 numbers, got 2$")
    t.raises(function() g:thickness_at_face(0, 0, nil, 0) end,
      "^thickness_gauge_face: the maximum must be positive and finite")
    g:close()
    g:close() -- twice is a no-op
    t.eq(tostring(g), "ThicknessGauge(closed)")
    t.raises(function() g:thickness(10) end, "^thickness_gauge: closed$")
    t.raises(function() return g.body_count end, "^thickness_gauge: closed$")
    -- the conveniences refuse with the gauge call's own prefix
    t.raises(function() bs.thickness({ plate }, -1) end, "^thickness_gauge_measure: the maximum must be positive and finite")
    t.raises(function() bs.thickness({ plate }, 10, nil, 1 / 0) end,   -- NaN is unset
      "^thickness_gauge_new: the tolerance must be positive and finite")
    t.raises(function() plate:thickness_at_face(99, nil, 10) end, "^thickness_gauge_face: no face 99")
    t.raises(function() plate:thickness_at_face(0, nil) end, "^thickness_gauge_face: the maximum is required$")
    -- mesh_thickness: the kernel's refusals and the module's own
    local meshes = { thickness_lower, thickness_upper }
    local tri = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } }
    t.raises(function() bs.mesh_thickness(meshes, 0) end, "^mesh_thickness: the maximum must be positive and finite")
    t.raises(function() bs.mesh_thickness(meshes, 10, -0.5) end,
      "^mesh_thickness: the sharp angle must be zero or positive and finite")
    t.raises(function() bs.mesh_thickness({ { { { 0, 0, 0 }, { 1, 0, 0 } }, { { 0, 1, 2 } } } }, 10) end,
      "^mesh_thickness: a triangle names a position past the mesh")
    t.raises(function() bs.mesh_thickness({ { { { 0, 0, 0 }, { 1, 0 / 0, 0 }, { 0, 1, 0 } }, { { 0, 1, 2 } } } }, 10) end,
      "^mesh_thickness: a mesh position is not finite")
    t.raises(function() bs.mesh_thickness({ thickness_lower, 5 }, 10) end,
      "^mesh_thickness: mesh 1 is not a %(positions, triangles%) pair$")
    t.raises(function() bs.mesh_thickness({ { tri } }, 10) end,
      "^mesh_thickness: mesh 0 is not a %(positions, triangles%) pair$")
    t.raises(function() bs.mesh_thickness({ { { { 0, 0, 0 }, { 1, 0 } }, { { 0, 1, 2 } } } }, 10) end,
      "^mesh_thickness: mesh 0 position 1 is not three numbers$")
    for _, bad in ipairs({ { 0, 1 }, { 0, 1, -2 }, { 0, 1, 2 ^ 32 }, { 0, 1, 0.5 }, { 0, 1, "x" } }) do
      t.raises(function() bs.mesh_thickness({ { tri, { bad } } }, 10) end,
        "^mesh_thickness: mesh 0 triangle 0 is not three indices$")
    end
    t.raises(function() bs.mesh_thickness(meshes) end, "^mesh_thickness: the maximum is required$")
  end)

  t.test("clash: an edge against an edge, and an edge against a face", function()
    local c = math.sqrt(0.5)
    local s = 0.1 * c
    local a, b = bs.Solid.cuboid(2, 2, 2), bs.Solid.cuboid(2, 2, 2)
    local collider = bs.Collider({ a, b }, 1e-3)
    local rows = collider:clash({ at(0), { 2 + s, 2 + s, 0, c, -c, 0, 0.5, 0.5, c, -0.5, -0.5, c } }, 0.5)
    t.eq(#rows, 1)
    local r = rows[1]
    t.eq(r.kind, "too_close")
    t.ok(math.abs(r.distance - 0.1) <= 1e-3, "distance " .. r.distance)
    t.ok(near_point(r.on_a, { 1, 1, 0 }, 2e-3), "on_a " .. table.concat(r.on_a, ", "))
    t.eq(r.kind_a, "edge")
    t.eq(r.kind_b, "edge")
    t.eq(type(r.edge_a), "number")
    for _, seg in ipairs(a.edges[r.edge_a + 1].segments) do
      for _, p in ipairs(seg) do
        t.ok(math.abs(p[1] - 1) <= 2e-3 and math.abs(p[2] - 1) <= 2e-3, "edge_a's point " .. table.concat(p, ", "))
      end
    end
    t.eq(type(r.edge_b), "number")
    t.ok(r.edge_b < #b.edges, "edge_b " .. r.edge_b)

    -- A ball whose surface sits 0.2 off the box's x = 1, y = 1 edge: side a an edge, side b a
    -- face, the row as `Solid:closest` names the same pair.
    local d = 1 + 1.2 * c
    local box, ball = bs.Solid.cuboid(2, 2, 2), bs.Solid.sphere(1)
    local mixed = bs.Collider({ box, ball }, 1e-3):clash({ at(0), at(d, d, 0) }, 0.5)
    t.eq(#mixed, 1)
    local m = mixed[1]
    local want = box:closest(ball:translate(d, d, 0), 1e-3)
    t.eq(m.kind, "too_close")
    t.ok(math.abs(m.distance - 0.2) <= 1e-3, "distance " .. m.distance)
    t.eq(m.kind_a, "edge")
    t.eq(m.kind_b, "face")
    t.eq(m.kind_a, want.kind_a)
    t.eq(m.kind_b, want.kind_b)
    t.eq(m.index_a, want.index_a)
    t.eq(m.edge_a, want.edge_a)
    t.eq(m.index_b, want.index_b)
    t.eq(m.edge_b, nil)
    t.ok(near_point(m.on_a, want.on_a, 2e-3), "on_a " .. table.concat(m.on_a, ", "))
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
    t.raises(function() box:hits(line, XY, -1.0) end, "solid_profile_hits: tolerance must be positive and finite")
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
    t.raises(function() a:common(b, -1) end, "profile_common: tolerance must be positive and finite")
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
    t.raises(function() sheet:split_sheet(tool, -1) end, "^split_sheet: ")
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
    t.raises(function() bs.SweepPath.along(wave, XY, -1) end, "along: the tolerance must be positive and finite")
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
    -- A count the C call's uint32_t cannot hold is refused before it, never wrapped
    -- (2^32 + 6 would be a hexagon); so is a count that is not whole.
    for _, n in ipairs({ -1, 2 ^ 32 + 6 }) do
      e = t.raises(function() bs.Profile.regular_polygon({ 0, 0 }, 10, n) end)
      t.eq(e.message, ("profile_regular_polygon: sides is out of range: %.14g"):format(n))
      e = t.raises(function() bs.Profile.star({ 0, 0 }, 10, 4, n) end)
      t.eq(e.message, ("profile_star: points is out of range: %.14g"):format(n))
    end
    e = t.raises(function() bs.Profile.regular_polygon({ 0, 0 }, 10, 6.5) end)
    t.eq(e.message, "profile_regular_polygon: sides must be a whole number, got 6.5")
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

  -- Solid:with_material and Solid:styled with their readers, at parity with the
  -- Python reference's test_a_material_and_an_outside_style_ride_operations_and_reach_step.
  t.test("a material and an outside style ride operations and reach STEP", function()
    local cube = bs.Solid.cuboid(1, 1, 1)
    t.eq(cube.material, nil)
    local steel = cube:with_material("Steel"):styled("materials/steel.mtlx", "BrushedSteel")
    t.eq(steel.material, "Steel")
    t.eq(steel.style_location, "materials/steel.mtlx")
    t.eq(steel.style_identification, "BrushedSteel")
    local cut = steel:cut(cube:with_material("Oak"):translate(0.5, 0.5, 0.5))
    t.eq(cut.material, "Steel")
    t.eq(cube:styled(nil, "BrushedSteel").style_location, nil)
    local text = steel:step_text()
    t.eq(text:find("MATERIAL_DESIGNATION('Steel'", 1, true) ~= nil, true)
    t.eq(text:find("EXTERNALLY_DEFINED_STYLE(IDENTIFIER('BrushedSteel')", 1, true) ~= nil, true)
    t.raises(function() cube:with_material(" ") end, "^with_material: a material's name cannot be blank$")
    t.raises(function() cube:styled() end, "^styled: a style needs a location or an identification$")
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

    local e = t.raises(function() bs.Profile.rect(5, 5):to_arcs(-1) end,
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

  -- Rest machining: a list of end mills, each pass at the first that fits; every item
  -- carries the Z range it covers.
  local function pocketed_block()
    local part = bs.Solid.cuboid(40, 30, 10):translate(0, 0, 5)
    return part:cut(bs.Solid.cuboid(20, 10, 8):translate(0, 0, 6))
  end

  t.test("one end mill's report items carry the Z range they cover", function()
    local part = pocketed_block()
    local job = bs.Job(bs.Stock.around(part, 2), 30)
    local report = job:machine(part, bs.Tool.flat(1, 6, 20, 800, 200, 12000))
    t.eq(#report, 4)
    for _, item in ipairs(report) do
      t.near(item.top, 10, 1e-6)
      t.near(item.bottom, 2, 1e-6)
    end
    job:close()
  end)

  t.test("a list of two end mills rests the corners on the second", function()
    local part = pocketed_block()
    local job = bs.Job(bs.Stock.around(part, 2), 30)
    local big = bs.Tool.flat(1, 6, 20, 800, 200, 12000)
    local small = bs.Tool.flat(2, 2, 20, 800, 200, 12000)
    local report = job:machine(part, { big, small })
    t.eq(#report, 4)
    for _, item in ipairs(report) do
      t.ok(item.reason:find("T2 (2 mm)", 1, true) ~= nil, item.reason)
      t.near(item.top, 10, 1e-6)
      t.near(item.bottom, 2, 1e-6)
    end
    local pocket_with_2 = false
    for _, op in ipairs(job:operations()) do
      if op.kind == "pocket" and op.tool == 2 then pocket_with_2 = true end
    end
    t.ok(pocket_with_2, "operations() has a pocket with tool 2")
    job:close()
  end)

  t.test("an empty list of end mills is refused and leaves the job as it was", function()
    local part = pocketed_block()
    local job = bs.Job(bs.Stock.around(part, 2), 30)
    local e = t.raises(function() job:machine(part, {}) end)
    t.ok(is_build_error(e))
    t.ok(e.message:find("machine: at least one end mill is needed", 1, true) ~= nil, e.message)
    t.eq(#job:operations(), 0)
    job:close()
  end)

  -- `{ big, nil }` has length 1 and reads as one tool; a list is counted by its keys, so
  -- a hole before the last key is a nil tool, refused at its place.
  t.test("a nil in the list of end mills is refused, not shortened", function()
    local part = pocketed_block()
    local job = bs.Job(bs.Stock.around(part, 2), 30)
    local big = bs.Tool.flat(1, 6, 20, 800, 200, 12000)
    local small = bs.Tool.flat(2, 2, 20, 800, 200, 12000)
    local e = t.raises(function() job:machine(part, { big, [3] = small }) end)
    t.ok(tostring(type(e) == "table" and e.message or e):find("machine: end_mill[2] must be a Tool", 1, true) ~= nil, tostring(e))
    t.eq(#job:operations(), 0)
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

  t.test("subd subdivide: whole, one face, a bad face", function()
    local keep = subd_scope()
    local kiln = keep(bs.Subd.cuboid({ 2, 2, 2 }, { 2, 2, 2 }))
    t.eq(#keep(kiln:subdivide()).faces, 96)
    t.eq(#keep(kiln:subdivide({})).faces, 96)
    local one = keep(kiln:subdivide({ 1 }))
    t.eq(#one.faces, 27)
    t.eq(one.selection.kind, "faces")
    t.eq(#one.selection.ids, 4)
    t.raises(function() kiln:subdivide({ 999 }) end, "subdivide: face 999 is not in the cage")
    t.raises(function() kiln:subdivide({ 1.5 }) end, "subdivide: faces%[1%] is not an index")
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

  -- -- oriented box, lengths, containment and closest: at parity with the Python reference's tests
  -- in test_cadaclysm_blacksmith.py ("oriented box, lengths, containment, closest"), trimmed to what
  -- proves the marshalling -- every field read, every error path's prefix, the classifier's lifetime.

  local function near3(a, b, tolerance)
    if #a ~= 3 then return false end
    for i = 1, 3 do
      if math.abs(a[i] - b[i]) > tolerance then return false end
    end
    return true
  end

  t.test("measure: the oriented box of a turned cuboid", function()   -- 1
    local box = bs.Solid.cuboid(2, 3, 4):rotate({ { 0, 0, 0 }, { 0, 0, 1 } }, pi / 6):oriented_box(1e-9)
    t.eq(getmetatable(box), bs.OrientedBox)
    local half = { box.half[1], box.half[2], box.half[3] }
    table.sort(half)
    for i, w in ipairs({ 1.0, 1.5, 2.0 }) do
      t.ok(half[i] >= w - 1e-9 and half[i] <= w + 1e-3, "half " .. table.concat(box.half, ", "))
    end
    t.eq(#box.centre, 3)
    for i = 1, 3 do t.ok(math.abs(box.centre[i]) <= 1e-3, "centre " .. table.concat(box.centre, ", ")) end
    t.eq(#box.axes, 3)
    for i = 1, 3 do
      t.eq(#box.axes[i], 3)
      for j = 1, 3 do
        local dot = box.axes[i][1] * box.axes[j][1] + box.axes[i][2] * box.axes[j][2] + box.axes[i][3] * box.axes[j][3]
        t.near(dot, i == j and 1 or 0, 1e-9, "axes " .. i .. "." .. j)
      end
    end
  end)

  t.test("measure: the oriented box defaults its accuracy and refuses NaN and an open body", function()   -- 2
    local cylinder = bs.Solid.cylinder(1, 2)
    local own = cylinder:oriented_box(1e-5)
    local function same_box(a, b, label)
      for i = 1, 3 do
        t.eq(a.centre[i], b.centre[i], label .. " centre")
        t.eq(a.half[i], b.half[i], label .. " half")
        for j = 1, 3 do t.eq(a.axes[i][j], b.axes[i][j], label .. " axes") end
      end
    end
    same_box(cylinder:oriented_box(0), own, "accuracy 0")
    same_box(cylinder:oriented_box(-1), own, "accuracy -1")
    same_box(cylinder:oriented_box(), own, "no accuracy")
    local grown = 1 + 3.125e-5 * math.sqrt(12)
    for i = 1, 3 do t.near(own.half[i], grown, 1e-12, "half " .. i) end
    t.raises(function() cylinder:oriented_box(0 / 0) end, "^oriented_box: .*is not an accuracy")
    t.raises(function() bs.Solid.cuboid(1, 2, 3):face_sheet(0):oriented_box() end, "^oriented_box: ")
  end)

  t.test("measure: a cylinder rim is 5 pi long, and an edge past the end is refused", function()   -- 3
    local cylinder = bs.Solid.cylinder(2.5, 4)
    local circles = 0
    for _, e in ipairs(cylinder.edges) do
      if e.curve ~= nil and e.curve.kind == "circle" then
        circles = circles + 1
        local l = cylinder:edge_length(e.index, 1e-9)
        t.eq(getmetatable(l), bs.Length)
        t.ok(math.abs(l.length - 5 * pi) <= math.max(l.error, 1e-9), ("edge %d: %.15g +- %g"):format(e.index, l.length, l.error))
        t.ok(l.error >= 0 and l.error <= 1e-6 * l.length, ("edge %d's error %g"):format(e.index, l.error))
        t.eq(l.accuracy_met, true)
        t.eq(l.from_polyline, false)
      end
    end
    t.ok(circles >= 1, "the cylinder has a circle edge")
    local cube = bs.Solid.cuboid(1, 1, 1)
    t.raises(function() cube:edge_length(#cube.edges) end, "^edge_length: ")
    t.raises(function() cube:edge_length(1.5) end, "^edge_length: edge must be an index")
  end)

  t.test("measure: a slot profile is 12 + 2 pi long, and a NaN accuracy is refused", function()   -- 4
    local slot = bs.Profile.slot({ 0, 0 }, 8, 1)
    local l = slot:length(1e-9)
    t.eq(getmetatable(l), bs.Length)
    t.ok(math.abs(l.length - (12 + 2 * pi)) <= math.max(l.error, 1e-9), ("slot %.15g +- %g"):format(l.length, l.error))
    t.ok(l.error >= 0 and l.error <= 1e-6 * l.length, "slot error " .. l.error)
    t.eq(l.accuracy_met, true)
    t.near(slot:length(0).length, 12 + 2 * pi, 1e-6)
    t.raises(function() slot:length(0 / 0) end, "^profile_length: ")
  end)

  t.test("measure: containment one-shot and through a classifier agree", function()   -- 5
    local box = bs.Solid.cuboid(2, 3, 4)
    t.eq(box:contains({ 0, 0, 0 }), "inside")
    t.eq(box:contains({ 5, 0, 0 }), "outside")
    t.eq(box:contains({ 0, 0, 2 }), "on")
    local c = box:classifier()
    t.eq(getmetatable(c), bs.Classifier)
    for _, p in ipairs({ { 0, 0, 0 }, { 0.99, 0, 0 }, { 1, 0, 0 }, { 1.2, 0, 0 }, { 0, 1.6, 0 }, { 0, 0, -2 } }) do
      t.eq(c:contains(p), box:contains(p), ("at (%g, %g, %g)"):format(p[1], p[2], p[3]))
    end
    c:close()
    local ball = bs.Solid.sphere(1.5):classifier(1e-3)
    local want = { "outside", "inside", "inside", "inside", "inside", "inside", "outside" }
    for i, x in ipairs({ -2, -1.4, -0.5, 0, 0.5, 1.4, 2 }) do t.eq(ball:contains({ x, 0, 0 }), want[i], "x = " .. x) end
    t.eq(ball:contains({ 1.5, 0, 0 }), "on")
    t.eq(ball:contains({ 0, 0, -1.5 }), "on")
    ball:close()
  end)

  t.test("measure: a classifier outlives its solid", function()   -- 6
    local sphere = bs.Solid.sphere(1.0)
    local c = sphere:classifier(1e-3)
    sphere:close()
    sphere = nil
    collectgarbage()
    collectgarbage()
    t.eq(c:contains({ 0, 0, 0 }), "inside")
    t.eq(c:contains({ 2, 0, 0 }), "outside")
    t.eq(c:contains({ 1, 0, 0 }), "on")
    c:close()
  end)

  t.test("measure: containment refuses a NaN point, a zero tolerance and a closed classifier", function()   -- 7
    local box = bs.Solid.cuboid(2, 3, 4)
    local c = box:classifier()
    t.raises(function() box:contains({ 0 / 0, 0, 0 }) end, "^contains: .*not finite")
    t.raises(function() c:contains({ 0 / 0, 0, 0 }) end, "^classifier_contains: .*not finite")
    t.raises(function() box:contains({ 0, 0, 0 }, -1) end, "^contains: .*positive and finite")
    t.raises(function() box:classifier(-1) end, "^classifier_new: .*positive and finite")
    t.raises(function() box:contains({ 0, 0 }) end, "^contains: ")
    t.raises(function() bs.Solid.cuboid(1, 2, 3):face_sheet(0):classifier() end, "^classifier_new: ")
    t.eq(c.closed, false)
    c:close()
    t.eq(c.closed, true)
    local e = t.raises(function() c:contains({ 0, 0, 0 }) end, "^classifier: closed$")
    t.ok(is_build_error(e), "a closed classifier refuses with a BuildError")
    c:close()   -- closing twice is a no-op
    t.eq(c.closed, true)
  end)

  t.test("measure: the closest points of two spheres", function()   -- 8
    local a = bs.Solid.sphere(1)
    local b = bs.Solid.sphere(1):translate(5, 0, 0)
    local c = a:closest(b, 1e-3)
    t.eq(getmetatable(c), bs.Closest)
    t.ok(math.abs(c.distance - 3) <= 6e-9, "distance " .. c.distance)
    t.eq(c.refined, true)
    t.eq(c.kind_a, "face")
    t.eq(c.kind_b, "face")
    t.eq(c.edge_a, nil)
    t.eq(c.edge_b, nil)
    t.eq(type(c.index_a), "number")
    t.eq(type(c.index_b), "number")
    t.ok(near3(c.on_a, { 1, 0, 0 }, 1e-6), "on_a " .. table.concat(c.on_a, ", "))
    t.ok(near3(c.on_b, { 4, 0, 0 }, 1e-6), "on_b " .. table.concat(c.on_b, ", "))
    local swapped = b:closest(a, 1e-3)
    t.ok(near3(swapped.on_a, c.on_b, 1e-9) and near3(swapped.on_b, c.on_a, 1e-9), "swapping swaps the points")
    t.near(swapped.distance, c.distance, 1e-12)
  end)

  t.test("measure: the closest point of a box names an edge fillet takes", function()   -- 9
    local box = bs.Solid.cuboid(2, 3, 4)
    local c = box:closest(bs.Solid.sphere(1):translate(3, 0, 4), 1e-3)
    t.ok(math.abs(c.distance - (2 * math.sqrt(2) - 1)) <= 2e-3, "distance " .. c.distance)
    t.eq(c.kind_a, "edge")
    t.eq(type(c.edge_a), "number", "edge_a " .. tostring(c.edge_a))
    t.eq(c.kind_b, "face")
    t.eq(c.edge_b, nil)
    t.eq(box:fillet({ c.edge_a }, 0.2).faces, box.faces + 1)
  end)

  t.test("measure: closest refuses a zero tolerance and reports its progress", function()   -- 10
    local a = bs.Solid.sphere(1)
    local b = bs.Solid.sphere(1):translate(5, 0, 0)
    t.raises(function() a:closest(b, -1) end, "^closest: ")
    local phases, heard = {}, 0
    local c = a:closest(b, 1e-3, function(phase) phases[phase] = true heard = heard + 1 end)
    t.ok(math.abs(c.distance - 3) <= 6e-9)
    t.ok(phases.meshing, "phases heard: " .. heard)
    -- A raise inside the callback surfaces after the call, not through the library's frames.
    t.raises(function() a:closest(b, 1e-3, function() error("stop") end) end, "stop")
    b:close()
    t.raises(function() a:closest(b) end, "solid: closed")
  end)

  -- ---- Sketch: the 2D constraint sketcher -- facts S1-S8 and S10-S12 of the sketch-constraints
  -- plan, the values of test_cadaclysm_blacksmith.py's test_a_sketch_* tests (S9 is finalize_test's).

  local function ids_text(list)
    local out = {}
    for i, v in ipairs(list) do out[i] = tostring(v) end
    return "{" .. table.concat(out, ", ") .. "}"
  end
  local function ids_eq(actual, expected, message)
    t.ok(type(actual) == "table", (message or "ids") .. ": not a table but " .. tostring(actual))
    t.eq(ids_text(actual), ids_text(expected), message)
  end
  local function sorted(list)
    local out = {}
    for i, v in ipairs(list) do out[i] = v end
    table.sort(out)
    return out
  end
  -- The BuildError `fn` raises (failing when it raises none, or anything else).
  local function refusal(fn, pattern)
    local e = t.raises(fn, pattern)
    t.ok(is_build_error(e), "not a BuildError: " .. tostring(e))
    return e
  end

  t.test("sketch: dimensions a plate and extrudes it", function()   -- S1
    local s = bs.Sketch.new()
    local corners, sides = s:add_rect({ 0, 0 }, { 40, 30 })
    t.eq(#corners, 4)
    t.eq(#sides, 4)
    s:fix(corners[1])
    local width = s:length(sides[1], 60)
    s:length(sides[2], 30)
    local hole = s:add_circle(s:add_point(30, 15), 5)
    s:radius_of(hole, 5)
    local report = s:solve()
    t.eq(getmetatable(report), bs.SolveReport)
    t.eq(report.converged, true)
    t.eq(report.status, "converged")
    ids_eq(report.ids, {})
    t.eq(type(report.iterations), "number")
    t.eq(type(report.max_residual), "number")
    local x, y = s:point(corners[2])
    t.near(x, 60, 1e-9)
    t.near(y, 0, 1e-9)
    t.eq(s:constraint_kind(width), "length")
    t.eq(s:constraint_value(width), 60)
    local dof = s:diagnose()
    t.eq(getmetatable(dof), bs.Dof)
    t.eq(dof.free, 2)
    t.eq(dof.state, "under")
    local profiles = s:profiles(1e-9)
    t.eq(#profiles, 1)
    t.ok(bs.Solid.extrude(profiles[1], XY, 10):mass().volume > 0)
    s:close()
  end)

  t.test("sketch: refuses a conflict, and the refusal carries the ids", function()   -- S2
    local s = bs.Sketch()
    local corners, sides = s:add_rect({ 0, 0 }, { 40, 30 })
    s:fix(corners[1])
    s:length(sides[1], 40)
    s:length(sides[2], 30)
    local over = refusal(function() s:distance(corners[1], corners[3], 10) end, "^sketch_constrain: over%-constrained")
    ids_eq(over.ids, { 0, 1, 5, 6 }, "the constraints the distance fights")
    t.eq(#s:constraints(), 7)
    local held = refusal(function() s:remove_entity(corners[1]) end, "^sketch_remove_entity: point")
    ids_eq(sorted(held.ids), sorted({ sides[1], sides[4] }), "the sides still on the corner")
    local unknown = refusal(function() s:kind(9999) end, "sketch_kind")
    ids_eq(unknown.ids, {}, "a refusal that names no ids carries none, not the last conflict's")
    ids_eq(refusal(function() bs.Profile.rect(0, 1) end).ids, {}, "an error outside a sketch")
    s:close()
    refusal(function() s:solve() end, "^sketch: closed$")
    s:close()   -- a second close is a no-op
  end)

  t.test("sketch: drag moves the point it holds", function()   -- S3
    local s = bs.Sketch.new()
    local corners = s:add_rect({ 0, 0 }, { 40, 30 })
    local r = s:drag({ [corners[1]] = { 5, 5 } })
    t.ok(r.converged, r.status)
    ids_eq(r.ids, {})
    local x, y = s:point(corners[1])
    t.near(x, 5, 1e-9)
    t.near(y, 5, 1e-9)
    local _, y1 = s:point(corners[2])
    t.near(y1, 5, 1e-9)
    t.ok(s:drag({}).converged, "no moves at all (a count of 0) is a plain solve")
    refusal(function() s:drag({ [corners[1]] = { 1, 2, 3 } }) end, "sketch_drag")
    refusal(function() s:drag(nil) end, "^sketch_drag: moves must be")
    refusal(function() s:drag({ [1.5] = { 1, 2 } }) end, "^sketch_drag: id must be an id")
    refusal(function() s:add_nurbs(corners[1], { { 1 } }, { 0, 0, 1, 1 }, 1) end, "sketch_add_nurbs")
  end)

  t.test("sketch: a reference follows its source", function()   -- S4
    local plate = bs.Sketch.new()
    local corners, sides = plate:add_rect({ 0, 0 }, { 40, 30 })
    plate:fix(corners[1])
    local width = plate:length(sides[1], 40)
    plate:length(sides[2], 30)
    local boss = bs.Sketch.new()
    local edge = boss:reference(plate, sides[2])
    t.ok(boss:is_reference(edge) and boss:is_construction(edge))
    local o = boss:add_point(130, 15)
    local hole = boss:add_circle(o, 12)
    boss:radius_of(hole, 12)
    boss:point_line_distance(o, edge, 100)
    t.near((boss:point(o)), 140, 1e-9)
    t.eq(#boss:profiles(1e-9), 1)
    t.ok(plate:set_value(width, 60).converged)
    local r = boss:update_reference(edge, plate)
    t.ok(r.converged, r.status)
    ids_eq(r.ids, {})
    t.near((boss:point(o)), 160, 1e-9)
    local not_one = refusal(function() boss:update_reference(o, plate) end, "^sketch_update_reference: entity")
    ids_eq(not_one.ids, {})
    refusal(function() boss:reference(boss, o) end, "cannot reference itself")
  end)

  t.test("sketch: comes from a profile and keeps its tangents", function()   -- S5
    local s = bs.Sketch.from_profile(bs.Profile.slot({ 0, 0 }, 60, 8), true, 1e-9)
    local tangents = {}
    for _, c in ipairs(s:constraints()) do
      if s:constraint_kind(c) == "tangent" then tangents[#tangents + 1] = c end
    end
    t.eq(#tangents, 4)
    for _, c in ipairs(tangents) do t.ok(s:is_joint_tangent(c), "joint tangent " .. c) end
    t.eq(s:diagnose().free, 4)
    t.ok(#bs.Sketch.from_profile(bs.Profile.rect(2, 2)):entities() > 0, "the defaults infer at 1e-6")
  end)

  t.test("sketch: reads back what it holds", function()   -- S6 and S7
    local s = bs.Sketch.new()
    local a = s:add_point(0, 0)
    local b = s:add_point(10, 0)
    local line = s:add_line(a, b)
    t.eq(s:kind(a), "point")
    t.eq(s:kind(line), "line")
    ids_eq(s:entities(), sorted({ a, b, line }))
    ids_eq(s:ends(line), { a, b })
    local c = s:add_circle(s:add_point(0, 20), 3)
    t.eq(s:kind(c), "circle")
    t.eq(s:radius(c), 3)
    t.eq(s:kind(s:centre(c)), "point")
    s:set_radius(c, 4)
    t.eq(s:radius(c), 4)
    s:set_point(b, 12, 0)
    local bx, by = s:point(b)
    t.eq(bx, 12)
    t.eq(by, 0)
    s:set_construction(c)
    t.ok(s:is_construction(c))
    t.ok(not s:is_reference(c))
    s:set_construction(c, false)
    t.ok(not s:is_construction(c))
    s:set_construction(c)
    t.ok(not s:is_construction(9999) and not s:is_reference(9999), "an unknown id is neither")
    local h = s:horizontal(a, b)
    t.eq(s:constraint_kind(h), "horizontal")
    ids_eq(s:constraint_refs(h), { a, b })
    t.eq(s:constraint_value(h), nil)
    t.eq(s:constraint_driving(h), false)
    t.eq(s:constraint_sense(h), "auto")
    local d = s:distance(a, b, 15, false)
    t.eq(s:constraint_value(d), 15)
    t.eq(s:constraint_driving(d), false)
    t.near(s:measure(d), 12, 1e-12)
    local driven = s:set_driving(d, true)
    t.ok(driven.converged, driven.status)
    t.eq(s:constraint_driving(d), true)
    t.eq(s:constraint_value(d), 12)
    t.ok(s:set_value(d, 20).converged)
    t.near(s:measure(d), 20, 1e-9)
    local dragged = s:drag({ [b] = { 25, 5 } })
    t.ok(dragged.status == "converged" or dragged.status == "conflicting" or dragged.status == "diverged", dragged.status)
    t.eq(type(dragged.ids), "table")
    ids_eq(s:constraints(), sorted({ h, d }))
    s:remove(h)
    ids_eq(s:constraints(), { d })
    ids_eq(s:remove_entity(line), { d })
    for _, e in ipairs(s:entities()) do t.ok(e ~= a, "a went with its line") end
    ids_eq(s:constraints(), {})
    local bez = s:add_bezier(s:add_point(0, 0), { 1, 1 }, { 2, 1 }, { 3, 0 })
    t.eq(s:kind(bez), "free_curve")
    t.eq(#s:ends(bez), 4)
    t.eq(#s:open_chains(1e-9), 1)
    refusal(function() s:kind(9999) end, "sketch_kind")
    local sideways = refusal(function() s:tangent(bez, c, "sideways") end)
    t.eq(sideways.message, "tangent: sense must be one of 'auto', 'positive', 'negative', not 'sideways'")
    local middle = refusal(function() s:tangent_at_end(bez, c, "middle") end)
    t.eq(middle.message, "tangent_at_end: end must be one of 'start', 'end', not 'middle'")

    -- S7: tangent_at_end reads back its end
    local p = s:add_point(0, 0)
    local q = s:add_point(4, 0)
    local seg = s:add_line(p, q)
    local curve = s:add_bezier(q, { 5, 0 }, { 6, 1 }, { 7, 1 })
    t.eq(s:constraint_end(s:tangent_at_end(curve, seg, "end")), "end")
    t.eq(s:constraint_end(s:tangent_at_end(curve, seg)), "start")
    t.eq(s:constraint_end(s:length(seg, 4)), "start")
    refusal(function() s:constraint_end(999) end, "^sketch_constraint_end: no constraint 999")
  end)

  t.test("sketch: nurbs weights are counted, and coordinates must be finite", function()   -- S8
    local s = bs.Sketch.new()
    local start = s:add_point(0, 0)
    local points = { { 1, 2 }, { 3, 2 }, { 4, 0 } }
    local knots = { 0, 0, 0, 0.5, 1, 1, 1 }
    local three = refusal(function() s:add_nurbs(start, points, knots, 2, { 1, 1, 1 }) end)
    t.eq(three.message, "sketch_add_nurbs: 3 weights for 4 control points (the start and 3 given); give one per point")
    local curve = s:add_nurbs(start, points, knots, 2, { 1, 0.5, 0.5, 1 })
    t.eq(s:kind(curve), "free_curve")
    local ends = s:ends(curve)
    t.eq(#ends, 4)
    t.eq(ends[1], start)
    t.eq(s:kind(s:add_nurbs(start, points, knots, 2)), "free_curve", "no weights is a plain B-spline")
    refusal(function() s:add_nurbs(start, points, knots, -1) end, "^sketch_add_nurbs: degree must not be negative")
    refusal(function() s:add_nurbs(start, points, knots, 2.5) end, "^sketch_add_nurbs: degree must be a whole number")
    local u = bs.Sketch.new()
    refusal(function() u:add_point(0 / 0, 0) end, "^sketch_add_point: the coordinates must be finite")
    ids_eq(u:entities(), {})
  end)

  t.test("sketch: a sense picks the side, and unknown dimensions are refused", function()   -- S10
    for _, case in ipairs({ { "positive", 3 }, { "negative", -3 } }) do
      local sense, side = case[1], case[2]
      local s = bs.Sketch.new()
      local a = s:add_point(0, 0)
      local b = s:add_point(10, 0)
      local line = s:add_line(a, b)
      s:fix(a)
      s:fix(b)
      local p = s:add_point(4, side > 0 and 1 or -1)
      local d = s:point_line_distance(p, line, 3, true, sense)
      t.ok(s:solve().converged, sense)
      local _, y = s:point(p)
      t.near(y, side, 1e-6, sense)
      t.eq(s:constraint_sense(d), sense)
    end
    local s = bs.Sketch.new()
    refusal(function() s:constraint_value(999) end, "999")
    refusal(function() s:constraint_driving(999) end, "999")
  end)

  t.test("sketch: the diagnosis names the redundant and the conflicting apart", function()   -- S11
    local s = bs.Sketch.new()
    local corners, sides = s:add_rect({ 0, 0 }, { 40, 30 })
    s:fix(corners[1])
    s:length(sides[1], 40)
    s:length(sides[2], 30)
    local h = s:horizontal(corners[4], corners[3])
    t.eq(h, 7)
    local dof = s:diagnose()
    t.eq(dof.free, 0)
    t.eq(dof.state, "full")
    ids_eq(dof.redundant, { 7 }, "redundant")
    ids_eq(dof.conflicting, {}, "conflicting")
    t.eq(type(dof.free_entities), "table")
    t.eq(#dof.parts, 1)
    local part = dof.parts[1]
    t.eq(getmetatable(part), bs.PartDof)
    t.eq(type(part.params), "number")
    t.eq(part.free, 0)
    t.eq(part.state, "full")
    ids_eq(part.redundant, { 7 }, "part redundant")
    ids_eq(part.conflicting, {}, "part conflicting")
    ids_eq(part.constraints, { 0, 1, 2, 3, 5, 6, 7 }, "part constraints")
    t.eq(type(part.free_entities), "table")
  end)

  t.test("sketch: set_value that cannot converge is refused with its ids", function()   -- S12
    local s = bs.Sketch.new()
    local a, b, c = s:add_point(0, 0), s:add_point(1, 0), s:add_point(0, 1)
    s:distance(a, b, 1)
    s:distance(b, c, 1)
    local d3 = s:distance(a, c, 1)
    local diverged = refusal(function() s:set_value(d3, 10) end, "^sketch_set_value: the solve did not converge")
    ids_eq(diverged.ids, { 2, 0, 1 }, "the diverged refusal's ids, in the library's order")
    t.ok(s:solve().converged, "the refused edit was reverted")
    s:close()
  end)

  t.test("sketch: drag sends its point ids in ascending order", function()
    -- built in a scrambled order and large enough that a hash walk has no reason to be sorted
    local moves = {}
    for _, id in ipairs({ 40, 7, 1000, 3, 21, 512, 0, 99, 64, 8 }) do moves[id] = { id, -id } end
    ids_eq(bs._sketch_drag_ids(moves), { 0, 3, 7, 8, 21, 40, 64, 99, 512, 1000 }, "the ids drag sends")
    refusal(function() bs._sketch_drag_ids({ [1.5] = { 0, 0 } }) end, "^sketch_drag: id must be an id")
    -- and the real call with such a table is a plain solve of its moves
    local s = bs.Sketch.new()
    local corners = s:add_rect({ 0, 0 }, { 40, 30 })
    local report = s:drag({ [corners[3]] = { 41, 31 }, [corners[1]] = { -1, -1 }, [corners[2]] = { 41, -1 } })
    t.ok(report.converged, "the drag converges")
    s:close()
  end)

  t.test("sketch: a hole in a list is refused, not read as a shorter list", function()
    local s = bs.Sketch.new()
    local start = s:add_point(0, 0)
    local knots = { 0, 0, 0, 0.5, 1, 1, 1 }
    refusal(function() s:add_nurbs(start, { { 1, 2 }, nil, { 4, 0 } }, knots, 2) end, "sketch_add_nurbs")
    refusal(function() s:add_nurbs(start, { { 1, 2 }, { 3, 2 }, { 4, 0 } }, { 0, 0, 0, nil, 1, 1, 1 }, 2) end, "sketch_add_nurbs")
    refusal(function() s:add_nurbs(start, { { 1, 2 }, { 3, 2 }, { 4, 0 } }, knots, 2, { 1, nil, 0.5, 1 }) end, "sketch_add_nurbs")
    ids_eq(s:entities(), { start }, "no refused call added anything")
    local curve = s:add_nurbs(start, { { 1, 2 }, { 3, 2 }, { 4, 0 } }, knots, 2)
    t.eq(s:kind(curve), "free_curve")
    s:close()
  end)

  t.test("sketch: every constraint method and entity adder reads back its kind and refs", function()
    local s = bs.Sketch.new()
    local ox = 0
    local function pt(x, y) return s:add_point(ox + x, y) end
    local function line(x0, y0, x1, y1) return s:add_line(pt(x0, y0), pt(x1, y1)) end
    local function circle(x, y, r) return s:add_circle(pt(x, y), r) end
    -- Each on geometry of its own (a fresh place along x): none fights another, so none is refused.
    local ffi = require("ffi")
    local raw = ffi.load(bs.library_path())
    -- The header's codes, when the repository is here (an SDK checkout has no header: the raw
    -- code check is skipped there, the kind and refs checks still run).
    local header_path = t.fixture("crates/cadaclysm-blacksmith-capi/include/cadaclysm_blacksmith.h")
    local codes
    if header_path then
      local file = assert(io.open(header_path, "rb"))
      local header = file:read("*a")
      file:close()
      local ncodes = 0
      codes = {}
      for name, code in header:gmatch("#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_(%w[%w_]*) (%d+)") do
        codes[name] = tonumber(code)
        ncodes = ncodes + 1
      end
      t.eq(ncodes, 27)
    end
    local function check(kind, refs, add, value, sense)
      local id = add((table.unpack or unpack)(refs))
      t.eq(s:constraint_kind(id), kind)
      -- the name round-trips through the wrapper's own table, so also ask the library for the raw code
      if codes then
        t.eq(tonumber(raw.cadaclysm_blacksmith_sketch_constraint_kind(s:_h(), id)), codes[kind:upper()], kind .. " raw code")
      end
      ids_eq(s:constraint_refs(id), refs, kind .. " refs")
      t.eq(s:constraint_value(id), value, kind .. " value")
      if sense then t.eq(s:constraint_sense(id), sense) end
      t.ok(s:solve().converged, kind .. " solves")
      return refs
    end
    local function place() ox = ox + 100 end
    place()
    check("coincident", { pt(0, 0), pt(1, 1) }, function(p, q) return s:coincident(p, q) end)
    place()
    check("point_on_line", { pt(3, 2), line(0, 0, 10, 0) }, function(p, l) return s:point_on_line(p, l) end)
    place()
    check("point_on_circle", { pt(6, 1), circle(0, 0, 5) }, function(p, c) return s:point_on_circle(p, c) end)
    place()
    local hr = check("horizontal", { pt(0, 0), pt(5, 1) }, function(p, q) return s:horizontal(p, q) end)
    t.ok(math.abs(select(2, s:point(hr[1])) - select(2, s:point(hr[2]))) < 1e-9, "the wire code really is horizontal")
    place()
    local vr = check("vertical", { pt(0, 0), pt(1, 5) }, function(p, q) return s:vertical(p, q) end)
    t.ok(math.abs(s:point(vr[1]) - s:point(vr[2])) < 1e-9, "the wire code really is vertical")
    place()
    check("parallel", { line(0, 0, 10, 0), line(0, 5, 10, 7) }, function(p, q) return s:parallel(p, q) end)
    place()
    check("perpendicular", { line(0, 0, 10, 0), line(3, 5, 4, 15) }, function(p, q) return s:perpendicular(p, q) end)
    place()
    check("collinear", { line(0, 0, 10, 0), line(12, 1, 20, 2) }, function(p, q) return s:collinear(p, q) end)
    place()
    check("tangent", { circle(0, 5, 3), line(-10, 0, 10, 0) }, function(p, q) return s:tangent(p, q) end)
    place()
    check("tangent", { circle(0, 0, 3), circle(7, 0, 3) }, function(p, q) return s:tangent(p, q, "positive") end, nil, "positive")
    place()
    local ln = line(0, 0, 4, 0)
    local bez = s:add_bezier(s:ends(ln)[2], { ox + 5, 0 }, { ox + 6, 1 }, { ox + 7, 1 })
    check("tangent_at_end", { bez, ln }, function(p, q) return s:tangent_at_end(p, q, "end") end)
    t.eq(s:constraint_end(s:constraints()[#s:constraints()]), "end")
    place()
    check("concentric", { circle(0, 0, 3), circle(1, 1, 5) }, function(p, q) return s:concentric(p, q) end)
    place()
    check("equal_length", { line(0, 0, 10, 0), line(0, 5, 7, 5) }, function(p, q) return s:equal_length(p, q) end)
    place()
    check("equal_radius", { circle(0, 0, 3), circle(9, 0, 5) }, function(p, q) return s:equal_radius(p, q) end)
    place()
    check("midpoint", { pt(4, 1), line(0, 0, 10, 0) }, function(p, q) return s:midpoint(p, q) end)
    place()
    check("symmetric", { pt(-3, 2), pt(4, 3), line(0, 0, 0, 10) }, function(p, q, r) return s:symmetric(p, q, r) end)
    place()
    check("fix", { pt(2, 2) }, function(p) return s:fix(p) end)
    place()
    check("distance", { pt(0, 0), pt(5, 1) }, function(p, q) return s:distance(p, q, 7) end, 7)
    place()
    check("point_line_distance", { pt(3, 2), line(0, 0, 10, 0) }, function(p, q) return s:point_line_distance(p, q, 3) end, 3)
    place()
    check("line_distance", { line(0, 0, 10, 0), line(0, 5, 10, 5) }, function(p, q) return s:line_distance(p, q, 4) end, 4)
    place()
    check("circle_line_distance", { circle(0, 10, 2), line(-10, 0, 10, 0) }, function(p, q) return s:circle_line_distance(p, q, 3) end, 3)
    place()
    check("circle_distance", { circle(0, 0, 2), circle(10, 0, 3) }, function(p, q) return s:circle_distance(p, q, 3) end, 3)
    place()
    check("horizontal_distance", { pt(0, 0), pt(5, 1) }, function(p, q) return s:horizontal_distance(p, q, 6) end, 6)
    place()
    check("vertical_distance", { pt(0, 0), pt(5, 1) }, function(p, q) return s:vertical_distance(p, q, 6) end, 6)
    place()
    check("length", { line(0, 0, 10, 0) }, function(p) return s:length(p, 12) end, 12)
    place()
    check("angle", { line(0, 0, 10, 0), line(0, 5, 10, 7) }, function(p, q) return s:angle(p, q, 0.5) end, 0.5)
    place()
    check("radius", { circle(0, 0, 3) }, function(p) return s:radius_of(p, 4) end, 4)
    place()
    check("diameter", { circle(0, 0, 3) }, function(p) return s:diameter(p, 9) end, 9)
    t.eq(#s:constraints(), 28)
    local arc = s:add_arc(s:add_point(0, -30), s:add_point(5, -30), s:add_point(0, -25))
    local conic = s:add_conic(s:add_point(0, -60), { 1, -58 }, { 3, -60 }, 0.7)
    t.eq(s:kind(arc), "arc")
    t.eq(s:kind(conic), "free_curve")
    refusal(function() s:add_line(-1, 0) end, "^sketch_add_line: a must be an id")
    local b = s:add_point(10, -90)
    refusal(function() s:add_line("1", b) end, "^sketch_add_line: a must be an id")
    refusal(function() s:fix(nil) end, "^fix: id must be an id")
    refusal(function() s:kind(2 ^ 32) end, "^sketch_kind: id must be an id")
  end)

  t.test("sketch: a closed sketch refuses every call", function()
    local s = bs.Sketch.new()
    s:add_point(1, 2)
    local other = bs.Sketch.new()
    s:close()
    for i, call in ipairs({
      function() s:add_point(0, 0) end, function() s:entities() end, function() s:diagnose() end,
      function() s:drag({}) end, function() other:reference(s, 0) end, function() other:update_reference(0, s) end,
    }) do
      local e = refusal(call)
      t.eq(e.message, "sketch: closed", "call " .. i)
    end
    other:close()
  end)

  -- ---- arc-length sampling: point at length, divide by count, divide by length ----

  local function dist(a, b)
    return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
  end

  t.test("arc length: a cylinder rim a quarter of the way round is a quarter turn", function()
    local cylinder = bs.Solid.cylinder(2.5, 4)
    local rims = 0
    for _, e in ipairs(cylinder.edges) do
      if e.curve ~= nil and e.curve.kind == "circle" then
        rims = rims + 1
        local c, i = e.curve, e.index
        local start = cylinder:edge_point_at_length(i, 0)
        t.eq(getmetatable(start), bs.At)
        t.near(start.parameter, c.t0, 1e-12)
        local a = cylinder:edge_point_at_length(i, 2.5 * pi / 2)
        t.near(a.parameter, c.t0 + pi / 2, 1e-9)
        t.near(dist(a.point, c.origin), 2.5, 1e-9)
        t.near(math.sqrt(a.tangent[1] ^ 2 + a.tangent[2] ^ 2 + a.tangent[3] ^ 2), 1, 1e-12)
        t.eq(a.segment, nil)
        t.eq(a.from_polyline, false)
        t.ok(a.error >= 0 and a.error < math.huge, "error " .. tostring(a.error))
        local four = cylinder:edge_divide_by_count(i, 4)
        t.eq(#four, 4)
        for k = 1, 4 do
          t.near(dist(four[k].point, four[k % 4 + 1].point), 2.5 * math.sqrt(2), 1e-9)
        end
        t.ok(all_near(four[1].point, start.point, 1e-9), "the first sample is the start")
        t.eq(#cylinder:edge_divide_by_length(i, 2.5 * pi / 2), 4)
      end
    end
    t.ok(rims >= 2, "the cylinder has two circle edges")
  end)

  t.test("arc length: an open edge has both its ends", function()
    local box = bs.Solid.cuboid(2, 3, 4)
    local checked = 0
    for _, e in ipairs(box.edges) do
      if e.kind == "line" and math.abs(box:edge_length(e.index).length - 4) <= 1e-9 and checked == 0 then
        checked = checked + 1
        local five = box:edge_divide_by_count(e.index, 4)
        t.eq(#five, 5)
        for k = 1, 5 do t.near(dist(five[k].point, five[1].point), k - 1, 1e-9) end
        t.near(five[1].parameter, e.curve.t0, 1e-12)
        t.near(five[5].parameter, e.curve.t1, 1e-12)
        local by = box:edge_divide_by_length(e.index, 1.5)
        t.eq(#by, 3)
        for k = 1, 3 do t.near(dist(by[k].point, by[1].point), 1.5 * (k - 1), 1e-9) end
      end
    end
    t.eq(checked, 1)
  end)

  t.test("arc length: a slot profile reports the side", function()
    local slot = bs.Profile.slot({ 0, 0 }, 8, 1)
    local at = slot:point_at_length(6 + pi / 2)
    t.eq(getmetatable(at), bs.At)
    t.ok(all_near(at.point, { 4, 0, 0 }, 1e-9), "point " .. at.point[1] .. ", " .. at.point[2])
    t.eq(at.segment, 1)
    local eight = slot:divide_by_count(8)
    t.eq(#eight, 8)
    for _, a in ipairs(eight) do t.ok(a.segment >= 0 and a.segment <= 4, "segment " .. tostring(a.segment)) end
    local by = slot:divide_by_length(3)
    t.eq(#by, math.floor((12 + 2 * pi) / 3) + 1)
    t.eq(#by, 7)
    for k = 1, #by do
      local own = slot:point_at_length(3 * (k - 1))
      t.ok(all_near(by[k].point, own.point, 1e-12), "sample " .. k)
      t.eq(by[k].segment, own.segment)
    end
    t.ok(dist(by[#by].point, by[1].point) > 0.1)
  end)

  t.test("arc length: refusals name the call", function()
    local cylinder = bs.Solid.cylinder(2.5, 4)
    local rim
    for _, e in ipairs(cylinder.edges) do
      if e.kind == "circle" then rim = e.index break end
    end
    local slot = bs.Profile.slot({ 0, 0 }, 8, 1)
    t.raises(function() cylinder:edge_point_at_length(rim, -1) end, "^edge_point_at_length: ")
    t.raises(function() cylinder:edge_point_at_length(rim, 100) end, "^edge_point_at_length: ")
    t.raises(function() cylinder:edge_point_at_length(#cylinder.edges, 1) end, "^edge_point_at_length: ")
    t.raises(function() cylinder:edge_divide_by_count(rim, 0) end, "^edge_divide_by_count: .*not at least 1")
    t.raises(function() cylinder:edge_divide_by_count(rim, 1000001) end, "^edge_divide_by_count: .*not at most 1000000")
    t.raises(function() cylinder:edge_divide_by_length(rim, 0) end, "^edge_divide_by_length: ")
    t.raises(function() slot:point_at_length(-1) end, "^profile_point_at_length: ")
    t.raises(function() slot:divide_by_count(0) end, "^profile_divide_by_count: ")
    t.raises(function() slot:divide_by_length(-1) end, "^profile_divide_by_length: ")
    t.raises(function() cylinder:edge_point_at_length(rim, 1, 0 / 0) end, "^edge_point_at_length: .*is not an accuracy")
    t.raises(function() cylinder:edge_divide_by_count(rim, -1) end, "^edge_divide_by_count: n is out of range: %-1$")
    t.raises(function() cylinder:edge_divide_by_count(rim, 2 ^ 32 + 4) end, "^edge_divide_by_count: n is out of range: 4294967300$")
    t.raises(function() cylinder:edge_divide_by_count(rim, 4.5) end, "^edge_divide_by_count: n must be a whole number")
    t.raises(function() slot:divide_by_count(-1) end, "^profile_divide_by_count: n is out of range: %-1$")
    t.raises(function() slot:divide_by_count(2 ^ 32 + 4) end, "^profile_divide_by_count: n is out of range: 4294967300$")
    t.raises(function() slot:divide_by_count(4.5) end, "^profile_divide_by_count: n must be a whole number")
  end)

  t.test("arc length: accuracy 0 or less is the default", function()
    local slot = bs.Profile.slot({ 0, 0 }, 8, 1)
    local own = slot:point_at_length(5)
    for _, accuracy in ipairs({ 0, -1 }) do
      local a = slot:point_at_length(5, accuracy)
      t.ok(all_near(a.point, own.point, 0) and all_near(a.tangent, own.tangent, 0), "accuracy " .. accuracy)
      t.eq(a.parameter, own.parameter)
      t.eq(a.segment, own.segment)
      t.eq(a.error, own.error)
      t.eq(a.from_polyline, own.from_polyline)
    end
  end)

  -- ---- NurbsCurve: curves in space (the Python reference's tests from
  -- test_a_nurbs_curve_reads_back_what_it_was_built_from to test_nurbs_curve_refusals_name_the_call,
  -- and test_a_curve_maps_by_its_control_points).

  local function quarter_circle(r)
    r = r or 2.0
    return bs.NurbsCurve({ { r, 0, 0 }, { r, r, 0 }, { 0, r, 0 } }, 2, { 1, math.sqrt(0.5), 1 })
  end

  local function whole_circle(r, z)
    z = z or 0
    local h = math.sqrt(0.5)
    local pts = { { r, 0, z }, { r, r, z }, { 0, r, z }, { -r, r, z }, { -r, 0, z }, { -r, -r, z }, { 0, -r, z },
      { r, -r, z }, { r, 0, z } }
    return bs.NurbsCurve(pts, 2, { 1, h, 1, h, 1, h, 1, h, 1 }, { 0, 0, 0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1, 1, 1 })
  end

  local function ends_of(c)
    local d = c.domain
    return c:point(d[1]), c:point(d[2])
  end

  local function ends_blended(a, b, tweens, tol)
    local a0, a1 = ends_of(a)
    local b0, b1 = ends_of(b)
    for i, tw in ipairs(tweens) do
      local f = i / (#tweens + 1)
      local function mix(p, q) return { p[1] + f * (q[1] - p[1]), p[2] + f * (q[2] - p[2]), p[3] + f * (q[3] - p[3]) } end
      local t0, t1 = ends_of(tw)
      t.ok(dist(t0, mix(a0, b0)) < tol and dist(t1, mix(a1, b1)) < tol, "tween " .. i .. " ends")
    end
  end

  t.test("nurbs curve: reads back what it was built from", function()
    local c = quarter_circle()
    t.eq(getmetatable(c), bs.NurbsCurve)
    t.eq(c.degree, 2)
    t.ok(c.is_rational, "rational")
    t.ok(not c.is_closed, "open")
    t.eq(c.fit_error, nil)
    local cp = c.control_points
    t.eq(#cp, 3)
    t.ok(same(cp[1], { 2, 0, 0 }) and same(cp[2], { 2, 2, 0 }) and same(cp[3], { 0, 2, 0 }), "control points")
    t.ok(same(c.weights, { 1, math.sqrt(0.5), 1 }), "weights")
    t.ok(same(c.knots, { 0, 0, 0, 1, 1, 1 }), "knots")
    t.ok(same(c.domain, { 0, 1 }), "domain")
    t.near(dist(c:point(0.37), { 0, 0, 0 }), 2, 1e-12)
    local k = c:curvature(0.5)
    t.eq(getmetatable(k), bs.Curvature)
    t.near(k.kappa, 0.5, 1e-12)
    t.near(dist(k.centre, { 0, 0, 0 }), 0, 1e-12)
    local len = c:length()
    t.eq(getmetatable(len), bs.Length)
    t.near(len.length, pi, 1e-9)
    local at = c:point_at_length(pi / 2)
    t.eq(getmetatable(at), bs.At)
    t.near(dist(at.point, { math.sqrt(2), math.sqrt(2), 0 }), 0, 1e-9)
    t.eq(at.segment, nil)
    t.eq(#c:divide_by_count(4), 5)
    t.eq(#c:divide_by_length(1.0), 4)
    local d = c:derivatives(0.0, 2)
    t.eq(#d, 3)
    t.ok(same(d[1], { 2, 0, 0 }), "C(0)")
    t.ok(math.abs(d[2][1]) < 1e-12 and d[2][2] > 0, "C'(0)")
    t.ok(tostring(c):find("NurbsCurve(degree=2", 1, true) ~= nil, tostring(c))
    local line = bs.NurbsCurve({ { 0, 0, 0 }, { 1, 0, 0 } }, 1)
    local flat = line:curvature(0.5)
    t.eq(flat.centre, nil)
    t.eq(flat.kappa, 0)
  end)

  t.test("nurbs curve: through points and its edits", function()
    local ring = {}
    for i = 0, 9 do
      local a = 2 * pi * i / 10
      ring[#ring + 1] = { math.cos(a), math.sin(a), 0.2 * math.sin(3 * a) }
    end
    local closed = bs.NurbsCurve.through(ring, 3, true)
    t.ok(closed.is_closed, "closed ring")
    t.eq(#closed:divide_by_count(6), 6)
    local pts = { { 0, 0, 0 }, { 1, 2, 0.5 }, { 3, 1, -0.5 }, { 4, 3, 1 }, { 6, 2, 0 } }
    local c = bs.NurbsCurve.through(pts, 3, false, { 0, 0, 5 })
    local lo, hi = c.domain[1], c.domain[2]
    local d = c:derivatives(lo, 1)[2]
    t.ok(math.abs(d[1]) < 1e-9 and math.abs(d[2]) < 1e-9 and d[3] > 0, "start tangent")
    local samples = {}
    for i = 0, 199 do samples[#samples + 1] = { i / 50, math.sin(i / 50), 0 } end
    local fit = bs.NurbsCurve.fit(samples, 3, 1e-4)
    t.ok(fit.fit_error >= 0 and fit.fit_error <= 1e-4, "fit within 1e-4: " .. tostring(fit.fit_error))
    t.eq(c.fit_error, nil)
    t.ok(dist(c:reversed():point(lo), c:point(hi)) < 1e-12, "reversed")
    local mid = 0.5 * (lo + hi)
    local cut = c:trimmed(lo, mid).domain
    t.ok(cut[1] == lo and cut[2] == mid, "trimmed domain")
    local longer = c:extended(0.5)
    t.ok(longer.domain[2] > hi and dist(longer:point(hi), c:point(hi)) < 1e-9, "extended at the end")
    local before = c:extended(0.5, true)
    t.ok(before.domain[1] < lo and dist(before:point(lo), c:point(lo)) < 1e-9, "extended at the start")
    t.eq(c:elevated(2).degree, 5)
    t.eq(c:elevated().degree, 4)
    local copy = c:clone()
    t.ok(copy ~= c and dist(copy:point(mid), c:point(mid)) == 0, "clone")
  end)

  t.test("nurbs curve: curves join end to end", function()
    local lead = bs.NurbsCurve({ { 2, -3, 0 }, { 2, 0, 0 } }, 1)
    local arc = quarter_circle()
    local tail = bs.NurbsCurve({ { 0, 2, 0 }, { -1, 2.5, 0 }, { -2, 2, 1 }, { -3, 3, 0 }, { -4, 2, 0 }, { -5, 2, 2 } }, 5)
    local j = bs.NurbsCurve.joined({ lead, arc:reversed(), tail })
    t.eq(j.degree, 5)
    t.ok(same(j.domain, { 0, 3 }), "domain")
    for _, row in ipairs({ { 0, { 2, -3, 0 } }, { 1, { 2, 0, 0 } }, { 2, { 0, 2, 0 } }, { 3, { -5, 2, 2 } } }) do
      t.ok(dist(j:point(row[1]), row[2]) < 1e-12, "joint at " .. row[1])
    end
    for i = 0, 20 do
      t.ok(math.abs(dist(j:point(1 + i / 20), { 0, 0, 0 }) - 2) < 1e-12, "arc part " .. i)
      t.ok(dist(j:point(2 + i / 20), tail:point(i / 20)) < 1e-12, "tail part " .. i)
    end
    local one, want = bs.NurbsCurve.joined({ arc }).control_points, arc.control_points
    t.eq(#one, #want)
    for i = 1, #want do t.ok(same(one[i], want[i]), "one curve is a copy: " .. i) end
    t.raises(function() bs.NurbsCurve.joined({ lead, tail }) end, "^nurbs_curve_joined: curve 1 .* curve 0")
    t.raises(function() bs.NurbsCurve.joined({}) end, "^nurbs_curve_joined: ")
  end)

  t.test("nurbs curve: tweens blend from one curve to another", function()
    local a = bs.NurbsCurve({ { 0, 0, 0 }, { 3, 2, 0 }, { 6, -1, 0 }, { 10, 0, 0 } }, 3)
    local b = bs.NurbsCurve({ { 0, 1, 5 }, { 4, 4, 5 }, { 7, -3, 6 }, { 10, 1, 5 } }, 3)
    local plain = a:tween(b, 3, "plain")
    t.eq(#plain, 3)
    ends_blended(a, b, plain, 1e-12)
    t.ok(dist(plain[2].control_points[2], { 3.5, 3, 2.5 }) < 1e-12, "plain blends control points")
    local matching = a:tween(b, 2)
    t.eq(#matching, 2)
    ends_blended(a, b, matching, 1e-12)
    local sampled = a:tween(b, 4, "sampling", 20)
    t.eq(#sampled, 4)
    for _, s in ipairs(sampled) do t.eq(s.degree, 3) end
    ends_blended(a, b, sampled, 1e-9)
    t.eq(#a:tween(b, 1, nil, nil, nil, 0.0), 1)
    local q = bs.NurbsCurve({ { 0, 1, 5 }, { 5, 4, 5 }, { 10, 1, 5 } }, 2)
    t.raises(function() a:tween(q, 2, "plain") end, "^nurbs_curve_tween: .*compatible")
    local mixed = a:tween(q, 2)
    t.eq(mixed[1].degree, 3)
    ends_blended(a, q, mixed, 1e-12)
    t.raises(function() a:tween(b, 0) end, "^nurbs_curve_tween: ")
  end)

  t.test("nurbs curve: tween samples and method are checked", function()
    local a = bs.NurbsCurve({ { 0, 0, 0 }, { 3, 2, 0 }, { 6, -1, 0 }, { 10, 0, 0 } }, 3)
    local b = bs.NurbsCurve({ { 0, 1, 5 }, { 4, 4, 5 }, { 7, -3, 6 }, { 10, 1, 5 } }, 3)
    t.raises(function() a:tween(b, 2, "sampling") end, "^nurbs_curve_tween: sampling needs samples$")
    t.raises(function() a:tween(b, 2, "matching", 10) end, "^nurbs_curve_tween: samples is read only by sampling, not matching$")
    t.raises(function() a:tween(b, 2, "loft") end,
      "^nurbs_curve_tween: method must be one of plain, matching, sampling, not 'loft'$")
    t.raises(function() a:tween(b, 2, "sampling", 1) end, "^nurbs_curve_tween: sampling needs at least")
  end)

  t.test("nurbs curve: tweens of two circles are closed circles", function()
    local small, big = whole_circle(2), whole_circle(4, 6)
    for _, row in ipairs({ { "plain", nil, 1e-12 }, { "matching", nil, 1e-12 }, { "sampling", 40, 1e-4 } }) do
      local method, samples, tol = row[1], row[2], row[3]
      local tweens = small:tween(big, 3, method, samples)
      t.eq(#tweens, 3)
      for i, tw in ipairs(tweens) do
        local f = i / 4
        t.ok(tw.is_closed, method .. " " .. i .. " closed")
        local lo, hi = tw.domain[1], tw.domain[2]
        for k = 0, 23 do
          local p = tw:point(lo + (hi - lo) * k / 24)
          t.ok(math.abs(math.sqrt(p[1] ^ 2 + p[2] ^ 2) - (2 + 2 * f)) < tol and math.abs(p[3] - 6 * f) < tol,
            method .. " " .. i .. " " .. k)
        end
      end
    end
  end)

  t.test("nurbs curve: from an edge, a plane and a sphere", function()
    local cyl = bs.Solid.cylinder(2.5, 4)
    local rims = {}
    for _, e in ipairs(cyl.edges) do
      if e.kind == "circle" then rims[#rims + 1] = bs.NurbsCurve.from_edge(cyl, e) end
    end
    t.ok(#rims >= 2, "rims")
    for _, rim in ipairs(rims) do
      local lo, hi = rim.domain[1], rim.domain[2]
      for _, p in ipairs({ lo, 0.5 * (lo + hi), hi }) do
        local x = rim:point(p)
        t.ok(math.abs(math.sqrt(x[1] ^ 2 + x[2] ^ 2) - 2.5) < 1e-12, "rim radius")
      end
    end
    local by_index
    for _, e in ipairs(cyl.edges) do
      if e.kind == "circle" then by_index = bs.NurbsCurve.from_edge(cyl, e.index) break end
    end
    t.eq(by_index.degree, rims[1].degree)
    local sphere = bs.Solid.sphere(3)
    local line = bs.NurbsCurve({ { -2, 0.5, 10 }, { 2, -0.5, 10 } }, 1)
    local on = line:projected_to_face(sphere, 0, { 0, 0, -1 }, 1e-4)
    t.ok(on.fit_error <= 1e-4, "projection fit " .. tostring(on.fit_error))
    local lo, hi = on.domain[1], on.domain[2]
    t.ok(math.abs(dist(on:point(0.5 * (lo + hi)), { 0, 0, 0 }) - 3) < 1e-4, "on the sphere")
    local pulled = line:pulled_to_face(sphere, 0, 1e-4)
    t.ok(math.abs(dist(pulled:point(pulled.domain[1]), { 0, 0, 0 }) - 3) < 1e-4, "pulled onto the sphere")
    t.ok(pulled.fit_error ~= nil, "pulled has a fit error")
    local through = bs.NurbsCurve({ { -5, 1, 1 }, { 5, 1, 1 } }, 1)
    local hits = through:face_hits(sphere, 0, 1e-6)
    t.eq(#hits, 2)
    t.ok(math.abs(hits[1].point[1] + math.sqrt(7)) < 1e-6, "first hit")
    local crossing = through:plane_hits({ 0, 0, 0 }, { 1, 0, 0 })
    t.eq(#crossing, 1)
    t.ok(dist(crossing[1].point, { 0, 1, 1 }) < 1e-12, "plane hit")
    local flat = line:projected_to_plane({ 0, 0, 1 }, { 0, 0, 1 })
    t.ok(same(flat:point(0), { -2, 0.5, 1 }), "projected to the plane")
    local blend = bs.NurbsCurve.blend(quarter_circle(), true, through, false, 2)
    t.eq(blend.degree, 5)
    t.ok(math.abs(blend:curvature(0).kappa - 0.5) < 1e-9, "blend keeps the curvature")
    local teeth = quarter_circle():comb(8)
    t.eq(#teeth, 9)
    for _, tooth in ipairs(teeth) do t.ok(math.abs(dist(tooth[1], tooth[2]) - 0.5) < 1e-9, "tooth") end
  end)

  t.test("nurbs curve: refusals name the call", function()
    local q = quarter_circle()
    local cube = bs.Solid.cuboid(1, 1, 1)
    for _, row in ipairs({
      { function() bs.NurbsCurve({ { 0, 0, 0 }, { 1, 0, 0 } }, 9) end, "nurbs_curve_new" },
      { function() bs.NurbsCurve({ { 0, 0, 0 }, { 1, 0, 0 } }, 1, { 1, -1 }) end, "nurbs_curve_new" },
      { function() bs.NurbsCurve.through({ { 0, 0, 0 }, { 1, 0, 0 } }, 3) end, "nurbs_curve_through" },
      { function() bs.NurbsCurve.fit({ { 0, 0, 0 }, { 1, 0, 0 } }, 1, -1) end, "nurbs_curve_fit" },
      { function() bs.NurbsCurve.from_edge(cube, 999) end, "nurbs_curve_from_edge" },
      { function() bs.NurbsCurve.isocurve(cube, 0, true, 0.5) end, "nurbs_curve_from_face_isocurve" },
      { function() bs.NurbsCurve.blend(q, true, q, true, 3) end, "nurbs_curve_blend" },
      { function() q:projected_to_plane({ 0, 0, 0 }, { 0, 0, 1 }, { 1, 0, 0 }) end, "nurbs_curve_projected_to_plane" },
      { function() q:trimmed(0.5, 0.2) end, "nurbs_curve_trimmed" },
      { function() q:extended(0) end, "nurbs_curve_extended" },
      { function() q:point(2) end, "nurbs_curve_point" },
      { function() q:derivatives(0.5, 9) end, "nurbs_curve_derivatives" },
      { function() q:divide_by_count(0) end, "nurbs_curve_divide_by_count" },
      { function() q:plane_hits({ 0, 0, 0 }, { 0, 0, 1 }) end, "nurbs_curve_plane_hits" },
    }) do
      local err = t.raises(row[1], "^" .. row[2] .. ": ")
      t.ok(is_build_error(err), row[2] .. " raises a BuildError")
    end
    t.raises(function() bs.NurbsCurve({ { 0, 0, 0 }, { 1, 0, 0 }, { 2, 0, 0 } }, 1, { 1, 1 }) end,
      "^nurbs_curve_new: 2 weights for 3 points; give one per point$")
  end)

  t.test("nurbs curve: maps by its control points, and a curve value becomes one", function()
    local c = bs.NurbsCurve({ { 0, 0, 0 }, { 1, 1, 1 }, { 2, 0, 0 } }, 2, { 1, 0.5, 1 })
    local moved = c:transformed(bs.Transform.translation({ 1, 2, 3 }))
    local was, now = c:point(0.5), moved:point(0.5)
    t.ok(dist(now, { was[1] + 1, was[2] + 2, was[3] + 3 }) < 1e-12, "moved point")
    t.ok(all_near(moved.weights, c.weights, 1e-12), "weights kept")
    local line = bs.Line({ 0, 0, 0 }, { 2, 0, 0 }):to_nurbs()
    t.eq(getmetatable(line), bs.NurbsCurve)
    t.eq(line.degree, 1)
    local ld = line.domain
    t.ok(dist(line:point(0.5 * (ld[1] + ld[2])), { 1, 0, 0 }) < 1e-12, "line mid")
    local centre = { 1, 2, 3 }
    local circle = bs.Circle({ 1, 2, 3, 1, 0, 0, 0, 1, 0, 0, 0, 1 }, 3):to_nurbs()
    t.ok(circle.is_rational and circle.is_closed, "circle is rational and closed")
    local cd = circle.domain
    for k = 0, 15 do
      t.ok(math.abs(dist(circle:point(cd[1] + (cd[2] - cd[1]) * k / 16), centre) - 3) < 1e-12, "circle point " .. k)
    end
  end)

  t.test("nurbs curve: a tween list and an edge curve outlive what they came from", function()
    local a = bs.NurbsCurve({ { 0, 0, 0 }, { 3, 2, 0 }, { 6, -1, 0 }, { 10, 0, 0 } }, 3)
    local b = bs.NurbsCurve({ { 0, 1, 5 }, { 4, 4, 5 }, { 7, -3, 6 }, { 10, 1, 5 } }, 3)
    local tweens = a:tween(b, 3, "plain")
    local rim
    do
      local cyl = bs.Solid.cylinder(2.5, 4)
      for _, e in ipairs(cyl.edges) do
        if e.kind == "circle" then rim = bs.NurbsCurve.from_edge(cyl, e) break end
      end
      cyl:close()
    end
    a, b = nil, nil
    for _ = 1, 4 do collectgarbage("collect") end
    t.eq(#tweens, 3)
    for _, tw in ipairs(tweens) do
      t.ok(dist(tw:point(tw.domain[1]), { 0, 0, 0 }) < 6, "tween still reads")
    end
    local x = rim:point(rim.domain[1])
    t.ok(math.abs(math.sqrt(x[1] ^ 2 + x[2] ^ 2) - 2.5) < 1e-12, "edge curve still reads")
  end)

  -- ---- Sheets from curves (the Python reference's test_surfaces_from_curves_are_sheets,
  -- test_a_curve_trims_a_hole_and_an_island_and_they_join_back, test_an_open_curve_keeps_its_left_or_right,
  -- test_six_sheets_join_into_a_box_the_kernel_measures_cuts_and_writes, test_join_sheets_sews_a_t_junction,
  -- test_trim_by_curve_and_join_refuse_by_name, test_continuity_match_and_blend,
  -- test_n_sided_patch_fills_a_pentagon_of_strips, test_fillet_surfaces_rolls_a_ball_between_two_sheets,
  -- test_fillet_rounds_a_spline_edge_at_a_constant_and_a_varying_radius). The box's STEP write is read
  -- back as the text `step_text` makes, as Python's is.

  do
    local function line(a, b) return bs.NurbsCurve({ a, b }, 1) end

    -- The rectangle `w` by `h` centred at `origin` in the plane of `x`, `y`, facing `x cross y`.
    local function rect_sheet(origin, x, y, w, h)
      local z = { x[2] * y[3] - x[3] * y[2], x[3] * y[1] - x[1] * y[3], x[1] * y[2] - x[2] * y[1] }
      return bs.Solid.face(bs.Profile.rect(w, h), { origin, x, y, z })
    end

    -- The circle of radius `r` about `centre` in its z plane: nine rational quadratic points.
    local function exact_circle(centre, r)
      local cx, cy, cz = centre[1], centre[2], centre[3]
      local s = math.sqrt(0.5)
      local ab = { { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 }, { -1, 0 }, { -1, -1 }, { 0, -1 }, { 1, -1 }, { 1, 0 } }
      local pts = {}
      for i, p in ipairs(ab) do pts[i] = { cx + r * p[1], cy + r * p[2], cz } end
      return bs.NurbsCurve(pts, 2, { 1, s, 1, s, 1, s, 1, s, 1 }, { 0, 0, 0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1, 1, 1 })
    end

    local function coons_square(x0, y0, x1, y1)
      local c = { { x0, y0, 0 }, { x1, y0, 0 }, { x1, y1, 0 }, { x0, y1, 0 } }
      return bs.Solid.edge_surface({ line(c[1], c[2]), line(c[2], c[3]), line(c[3], c[4]), line(c[4], c[1]) })
    end

    t.test("sheets from curves: loft, sweeps, edge and network surfaces", function()
      local c = { { -1, -1, 1 }, { 1, -1, -1 }, { 1, 1, 1 }, { -1, 1, -1 } }
      local coons = bs.Solid.edge_surface({ line(c[1], c[2]), line(c[2], c[3]), line(c[3], c[4]), line(c[4], c[1]) }, 1e-9)
      t.eq(coons.faces, 1)
      t.eq(coons.sheet_error, 0.0)
      local loft = bs.Solid.loft_curves({ line({ 0, 0, 0 }, { 2, 0, 0 }), line({ 0, 1, 1 }, { 2, 1, -1 }) })
      t.eq(loft.faces, 1)
      t.eq(loft.sheet_error, nil)
      t.eq(loft.patch_report, nil)
      t.eq(bs.Solid.cuboid(1, 1, 1).sheet_error, nil)
      local ring = {}
      for i = 0, 7 do
        local a = 2 * pi * i / 8
        ring[#ring + 1] = { math.cos(a), math.sin(a), 0 }
      end
      local circle = bs.NurbsCurve.through(ring, 3, true)
      local rail = line({ 0, 0, 0 }, { 0, 0, 4 })
      local tube = bs.Solid.sweep_rail(rail, { circle }, nil, nil, 1e-5)
      t.eq(tube.faces, 1)
      t.ok(tube.sheet_error ~= nil and tube.sheet_error >= 0 and tube.sheet_error <= 1e-5, "tube error")
      t.eq(bs.Solid.sweep_rail(rail, { circle }, "rmf", nil, 1e-5).faces, 1)
      local upright = bs.Solid.sweep_rail(rail, { circle }, "fixed", { 0, 1, 0 }, 1e-5)
      t.eq(upright.faces, 1)
      t.ok(upright.sheet_error ~= nil, "fixed error")
      local band = bs.Solid.sweep_two_rails(line({ -1, 0, 0 }, { -1, 5, 0 }), line({ 1, 0, 0 }, { 1, 5, 0 }),
        { line({ -1, 0, 0 }, { 1, 0, 0 }) }, 1e-6)
      t.eq(band.faces, 1)
      t.ok(band.sheet_error ~= nil, "band error")
      local us, vs = {}, {}
      for _, y in ipairs({ -1, 0.2, 1 }) do us[#us + 1] = line({ -1, y, -y }, { 1, y, y }) end
      for _, x in ipairs({ -1, 0.3, 1 }) do vs[#vs + 1] = line({ x, -1, -x }, { x, 1, x }) end
      local net = bs.Solid.network_surface(us, vs, 1e-9)
      t.eq(net.faces, 1)
      t.ok(net.sheet_error ~= nil and net.sheet_error <= 1e-9, "net error")
      t.raises(function() bs.Solid.loft_curves({ circle }) end, "^loft_curves: ")
      t.raises(function() bs.Solid.edge_surface({ line({ 0, 0, 0 }, { 1, 0, 0 }) }) end, "^edge_surface: ")
      t.raises(function() bs.Solid.network_surface({ line({ 0, 0, 0 }, { 1, 0, 0 }) }, { line({ 0, 0, 0 }, { 0, 1, 0 }) }) end,
        "^network_surface: ")
      -- The wrapper's own refusals, in Python's words.
      local e = t.raises(function() bs.Solid.sweep_rail(rail, { circle }, "twisty") end,
        "^sweep_rail: frame is 'rmf' or 'fixed', not 'twisty'$")
      t.ok(is_build_error(e))
      t.raises(function() bs.Solid.loft_curves({ circle, 5 }) end, "expected a NurbsCurve")
    end)

    t.test("sheets from curves: a curve trims a hole and an island and they join back", function()
      local sheet = rect_sheet({ 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, 20, 20)
      local ring = exact_circle({ 1, -2, 0 }, 5)
      local holed = sheet:trim_by_curve(ring, "outside", { 0, 0, -1 }, 0.01)
      local island = sheet:trim_by_curve(ring, "inside", nil, 0.01)
      t.ok(math.abs(island:mass().area - 25 * pi) < 1e-6, "island area")
      t.ok(math.abs(holed:mass().area - (400 - 25 * pi)) < 1e-6, "holed area")
      t.eq(sheet:split_by_curve(ring, nil, 0.01).faces, 2)
      local back, report = bs.Solid.join_sheets({ holed, island })
      t.ok(report.sewn >= 1, "sewn")
      t.eq(report.naked_after, report.naked_before - 2 * report.sewn)
      t.eq(report.closed, false)
      t.eq(back.faces, 2)
      t.ok(tostring(report):find("JoinReport(sewn=", 1, true) ~= nil, tostring(report))
      t.eq(getmetatable(report), bs.JoinReport)
    end)

    t.test("sheets from curves: an open curve keeps its left or right", function()
      local sheet = rect_sheet({ 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, 20, 20)
      local ln = bs.NurbsCurve.through({ { -5, 1, 0 }, { 5, 1, 0 } }, 1)
      local left = sheet:trim_by_curve(ln, "left", { 0, 0, 1 }, 0.01)
      local right = sheet:trim_by_curve(ln, "right", { 0, 0, 1 }, 0.01)
      t.ok(math.abs(left:mass().area - 180) < 1e-9, "left")
      t.ok(math.abs(right:mass().area - 220) < 1e-9, "right")
      t.ok(math.abs(sheet:trim_by_curve(ln, "inside", { 0, 0, -1 }, 0.01):mass().area - 220) < 1e-9, "inside, flipped")
    end)

    t.test("sheets from curves: six sheets join into a box the kernel measures, cuts and writes", function()
      local x, y, z = { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 }
      local faces = { rect_sheet({ 5, 10, 0 }, x, y, 10, 20), rect_sheet({ 5, 10, 30 }, x, y, 10, 20),
        rect_sheet({ 0, 10, 15 }, y, z, 20, 30), rect_sheet({ 10, 10, 15 }, y, z, 20, 30),
        rect_sheet({ 5, 0, 15 }, z, x, 30, 10), rect_sheet({ 5, 20, 15 }, x, z, 10, 30) }
      local box, report = bs.Solid.join_sheets(faces)
      t.eq(report.sewn, 12)
      t.eq(report.naked_before, 24)
      t.eq(report.naked_after, 0)
      t.eq(report.turned, 4)
      t.eq(report.closed, true)
      local m = box:mass()
      t.ok(m.closed, "closed")
      t.ok(math.abs(m.volume - 6000) < 1e-6, "volume")
      local bored = box:cut(bs.Solid.cylinder(2, 50):translate(5, 10, -10), 0.01)
      t.ok(math.abs(bored:mass().volume - (6000 - pi * 4 * 30)) < 0.05, "bored")
      t.ok(box:step_text():find("CLOSED_SHELL", 1, true) ~= nil, "step text")
      -- Two of the faces, one moved a thousandth away: sewn only at a tolerance that covers it.
      local moved = faces[4]:translate(0, 0, 1e-3)
      local _, apart = bs.Solid.join_sheets({ faces[2], moved })
      local _, loose = bs.Solid.join_sheets({ faces[2], moved }, 2e-3)
      t.eq(apart.sewn, 0)
      t.eq(loose.sewn, 1)
      t.ok(math.abs(loose.worst_gap - 1e-3) < 1e-9, "worst gap")
    end)

    t.test("sheets from curves: join_sheets sews a T-junction", function()
      local big, a, b = coons_square(0, 0, 2, 1), coons_square(0, 1, 1, 2), coons_square(1, 1, 2, 2)
      local _, exact = bs.Solid.join_sheets({ big, a, b })
      t.eq(exact.sewn, 1)
      local shell, report = bs.Solid.join_sheets({ big, a, b }, 1e-3)
      t.eq(report.sewn, 3)
      t.eq(report.naked_before, 13)
      t.eq(report.naked_after, 7)
      t.eq(report.closed, false)
      t.eq(shell.faces, 3)
    end)

    t.test("sheets from curves: recess sets a square window into a flat sheet", function()
      local sheet = rect_sheet({ 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, 20, 20)
      local square = bs.NurbsCurve.through({ { -5, -5, 0 }, { 5, -5, 0 }, { 5, 5, 0 }, { -5, 5, 0 }, { -5, -5, 0 } }, 1)
      local window, faces = sheet:recess(square, 3, 0, 0, true, 0.01)
      t.eq(table.concat(faces, ","), "1,0,4,1")
      t.eq(window.faces, 6)
    end)

    t.test("sheets from curves: trim_by_curve and join refuse by name", function()
      local sheet = rect_sheet({ 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, 20, 20)
      local ring = exact_circle({ 0, 0, 0 }, 5)
      t.raises(function() sheet:trim_by_curve(ring, "middle") end,
        "^trim_by_curve: keep must be 'outside', 'inside', 'left' or 'right', not 'middle'$")
      t.raises(function() sheet:trim_by_curve(exact_circle({ 100, 0, 0 }, 5), "inside") end,
        "^trim_by_curve: .*nothing of the sheet lies inside")
      t.raises(function() sheet:split_by_curve(ring, { 0, 0, 0 }) end, "^split_by_curve: .*direction is zero")
      t.raises(function() bs.Solid.join_sheets({}) end, "^join_sheets: no sheets")
      t.raises(function() bs.Solid.join_sheets({ sheet }, -1) end, "^join_sheets: .*tolerance")
    end)

    t.test("sheets from curves: continuity, match and blend", function()
      local a = bs.Solid.loft_curves({ line({ -1, 0, 0 }, { 0, 0, 0 }), line({ -1, 1, 0 }, { 0, 1, 0 }) }, 1)
      local b = bs.Solid.loft_curves({ line({ 0, 0, 0 }, { 0, 0, 1 }), line({ 0, 1, 0 }, { 0, 1, 1 }) }, 1)
      local r = a:continuity("u1", b, "u0", nil, nil, 32)
      t.ok(r.gap <= 1e-12, "gap")
      t.ok(math.abs(r.angle - pi / 2) <= 1e-9, "angle")
      t.ok(r.samples >= 33, "samples")
      t.eq(#r.gap_at, 3)
      t.eq(#r.angle_at, 3)
      t.eq(#r.curvature_at, 3)
      t.eq(getmetatable(r), bs.Continuity)
      t.ok(tostring(r):find("Continuity(gap=", 1, true) ~= nil, tostring(r))
      -- Where each worst is found: a tilted, lifted b leaves the widest gap at one end of the seam
      -- (y = 1) and the widest angle at the other (y = 0, where it stands square to a).
      local tilted = bs.Solid.loft_curves({ line({ 0, 0, 0 }, { 0, 0, 1 }), line({ 0, 1, 0.5 }, { 0.5, 1, 1.5 }) }, 1)
      local k = a:continuity("u1", tilted, "u0")
      t.ok(k.gap > 0.3 and k.gap_at[2] > 0.9, "the gap is widest at y = 1: " .. tostring(k.gap_at[2]))
      t.ok(k.angle > 1.0 and k.angle_at[2] < 0.1, "the angle is widest at y = 0: " .. tostring(k.angle_at[2]))
      t.eq(#k.curvature_at, 3)
      local m = a:matched("u1", b, "u0", 1)
      r = m:continuity("u1", b, "u0")
      t.ok(r.gap <= 1e-10 and r.angle <= 1e-8, "matched")
      local blend = bs.Solid.blend_sides(a, "u0", b, "u1", 2)
      r = blend:continuity("v0", a, "u0")
      t.ok(r.gap <= 1e-10 and r.angle <= 1e-8 and r.curvature <= 1e-6, "blended")
      t.raises(function() a:continuity("w2", b, "u0") end, "^a side is 'u0', 'u1', 'v0' or 'v1', not 'w2'$")
      t.raises(function() a:matched("u1", b, "x") end, "^a side is 'u0'")
      t.raises(function() bs.Solid.blend_sides(a, "u0", b, nil) end, "^a side is 'u0'")
      t.raises(function() a:matched("u1", b, "u0", 3) end, "^match_side: ")
    end)

    t.test("sheets from curves: an n-sided patch fills a pentagon of strips", function()
      local corners = {}
      for k = 0, 4 do
        local a = 2 * pi * k / 5 + 0.1 * math.sin(3 * k)
        corners[k + 1] = { math.cos(a), math.sin(a), 0.0 }
      end
      local function out(p) return { 1.6 * p[1], 1.6 * p[2], 0.0 } end
      local strips = {}
      for i = 1, 5 do
        local j = i % 5 + 1
        strips[i] = bs.Solid.loft_curves({ line(corners[i], corners[j]), line(out(corners[i]), out(corners[j])) }, 1)
      end
      local edge = line(corners[4], corners[5])
      local boundaries = { { strips[1], "v0" }, { strips[2], "v0", 1 }, { sheet = strips[3], side = "v0", range = { 1.0, 0.0 } },
        edge, { sheet = strips[5], side = "v0", level = 2, face = 0 } }
      local fill = bs.Solid.n_sided_patch(boundaries, nil, 1e-6)
      local r = fill.patch_report
      t.eq(fill.faces, 5)
      t.eq(r.faces, 5)
      t.eq(getmetatable(r), bs.PatchReport)
      t.ok(r.boundary.gap <= 1e-9 and r.boundary.angle <= 1e-6 and r.internal.angle <= 1e-6 and r.corner_angle <= 1e-9,
        tostring(r))
      t.ok(r.boundary.samples > 0 and r.internal.samples > 0 and #r.boundary.gap_at == 3, tostring(r))
      -- Face 0 meets strip 0's second half along its v0 side, face 4 the first half along u1.
      for _, fs in ipairs({ { 0, "v0" }, { 4, "u1" } }) do
        local k = fill:continuity(fs[2], strips[1], "v0", fs[1])
        t.ok(k.gap <= 1e-9 and k.angle <= 1e-6, "face " .. fs[1] .. ": " .. tostring(k))
      end
      -- Into the ring: watertight round the hole but where the curve stood in for strip 3.
      local joined, report = bs.Solid.join_sheets({ strips[1], strips[2], strips[3], strips[5], fill }, 1e-6)
      t.eq(report.refused, 0)
      t.eq(report.naked_after, 4 + 2 + 2)
      t.eq(joined.patch_report, nil)
      -- Every boundary a sheet's side: the curve's place taken by strip 4.
      local whole = {}
      for i = 1, 5 do whole[i] = { strips[i], "v0" } end
      t.eq(bs.Solid.n_sided_patch(whole, nil, 1e-6).faces, 5)
      t.raises(function() bs.Solid.n_sided_patch({ boundaries[1], boundaries[2] }) end, "^n_sided_patch: ")
      t.raises(function() bs.Solid.n_sided_patch({ { strips[1], "v0", 3 }, { strips[1], "v0", 3 }, { strips[1], "v0", 3 } }) end,
        "^n_sided_patch: ")
      t.raises(function()
        local odd = { sheet = strips[1], side = "v0", bulge = 2 }
        bs.Solid.n_sided_patch({ odd, odd, odd })
      end, "unknown keys {bulge}")
      t.raises(function() bs.Solid.n_sided_patch({ { strips[1], "x" }, { strips[1], "v0" }, { strips[1], "v0" } }) end,
        "^a side is 'u0'")
    end)

    t.test("sheets from curves: each patch boundary's level reaches the library", function()
      -- Five strips rising off the hole's plane: the patch against them is free at G0, only tangent at
      -- G1 (a corner of the hole then leaves the neighbours at an angle) and curved at G2, so the
      -- report tells the three apart -- and the dict, the positional and the default forms apart.
      local corners = {}
      for k = 0, 4 do
        local a = 2 * pi * k / 5 + 0.1 * math.sin(3 * k)
        corners[k + 1] = { math.cos(a), math.sin(a), 0.0 }
      end
      local strips = {}
      for i = 1, 5 do
        local j = i % 5 + 1
        local function up(p) return { 1.6 * p[1], 1.6 * p[2], 0.8 } end
        strips[i] = bs.Solid.loft_curves({ line(corners[i], corners[j]), line(up(corners[i]), up(corners[j])) }, 1)
      end
      local function at(level, form)
        local b = {}
        for i = 1, 5 do
          if form == "positional" then b[i] = { strips[i], "v0", level }
          elseif form == "default" then b[i] = { strips[i], "v0" }
          else b[i] = { sheet = strips[i], side = "v0", level = level } end
        end
        return bs.Solid.n_sided_patch(b, nil, 1e-6).patch_report
      end
      local g0, g1, g2 = at(0, "dict"), at(1, "positional"), at(2, "default")
      t.ok(g0.boundary.angle == 0 and g0.boundary.curvature == 0 and g0.corner_angle == 0, "G0 asks for no tangent: " .. tostring(g0))
      t.ok(g1.boundary.angle > 0.5 and g1.boundary.curvature == 0 and g1.corner_angle > 0.5, "G1: " .. tostring(g1))
      t.ok(g2.boundary.curvature > 1, "G2: " .. tostring(g2))
      t.ok(at(2, "dict").boundary.curvature > 1, "G2 spelled out")
    end)

    t.test("sheets from curves: fillet_surfaces rolls a ball between two sheets", function()
      local floor = bs.Solid.loft_curves({ line({ 0, 0, 0 }, { 4, 0, 0 }), line({ 0, 3, 0 }, { 4, 3, 0 }) }, 1)
      local wall = bs.Solid.loft_curves({ line({ 0, 0, 0 }, { 0, 3, 0 }), line({ 0, 0, 4 }, { 0, 3, 4 }) }, 1)
      local found
      for _, flips in ipairs({ { false, false }, { true, false }, { false, true }, { true, true } }) do
        local ok, sheet, ra, rb = pcall(bs.Solid.fillet_surfaces, floor, wall, 1.0, nil, flips[1], flips[2], 1e-4)
        if ok then
          local p = ra:point(ra.domain[1])
          if p[1] > 0 and math.abs(p[3]) <= 1e-9 then
            found = { sheet, ra, rb }
            break
          end
        end
      end
      t.ok(found ~= nil, "a side with the ball in the corner")
      local sheet, ra, rb = found[1], found[2], found[3]
      t.eq(sheet.faces, 1)
      t.ok(sheet.sheet_error ~= nil and sheet.sheet_error >= 0 and sheet.sheet_error <= 1e-4, "error")
      t.ok(math.abs(ra:point(ra.domain[1])[1] - 1.0) <= 1e-4, "contact on the floor")
      t.ok(math.abs(rb:point(rb.domain[1])[3] - 1.0) <= 1e-4, "contact on the wall")
      t.raises(function() bs.Solid.fillet_surfaces(floor, wall, 0.0) end, "^fillet_surfaces: ")
    end)

    t.test("sheets from curves: the rails of a surface fillet outlive the sheets", function()
      local floor = bs.Solid.loft_curves({ line({ 0, 0, 0 }, { 4, 0, 0 }), line({ 0, 3, 0 }, { 4, 3, 0 }) }, 1)
      local wall = bs.Solid.loft_curves({ line({ 0, 0, 0 }, { 0, 3, 0 }), line({ 0, 0, 4 }, { 0, 3, 4 }) }, 1)
      local sheet, ra, rb
      for _, flips in ipairs({ { false, false }, { true, false }, { false, true }, { true, true } }) do
        local ok, s, a, b = pcall(bs.Solid.fillet_surfaces, floor, wall, 1.0, nil, flips[1], flips[2], 1e-4)
        if ok then sheet, ra, rb = s, a, b break end
      end
      t.ok(sheet ~= nil, "a fillet")
      local before_a, before_b = ra:point(ra.domain[1]), rb:point(rb.domain[1])
      sheet:close()
      floor:close()
      wall:close()
      sheet, floor, wall = nil, nil, nil
      for _ = 1, 4 do collectgarbage("collect") end
      t.ok(all_near(ra:point(ra.domain[1]), before_a, 1e-12), "rail a still reads")
      t.ok(all_near(rb:point(rb.domain[1]), before_b, 1e-12), "rail b still reads")
    end)

    t.test("sheets from curves: a spline edge rounds at a constant and a varying radius", function()
      local length = 400.0
      local a_rows, b_rows = {}, {}
      for _, y in ipairs({ 0.0, length / 3, 2 * length / 3, length }) do
        local s = math.sin(pi * y / length)
        local c = { 150.0 + 8.0 * s, y, 6.0 * s }
        a_rows[#a_rows + 1] = bs.NurbsCurve({ { 0.0, y, 10.0 }, { 50.0, y, 14.0 }, { 100.0, y, 12.0 }, c }, 3)
        b_rows[#b_rows + 1] = bs.NurbsCurve({ c, { c[1] + 14, y, c[3] - 60 }, { c[1] + 10, y, c[3] - 130 },
          { c[1] - 4, y, c[3] - 200 } }, 3)
      end
      local a = bs.Solid.loft_curves(a_rows, 3, true)
      local b = bs.Solid.loft_curves(b_rows, 3, true)
      local shell, report = bs.Solid.join_sheets({ a, b }, 1e-6)
      t.eq(report.sewn, 1)
      local crease = {}
      for _, e in ipairs(shell.edges) do
        if #e.faces == 2 then crease[#crease + 1] = e end
      end
      t.eq(#crease, 1)
      t.eq(crease[1].kind, "nurbs")
      local constant = shell:fillet(crease, 12.0, 1e-3)
      local varying = shell:fillet(crease, 8.0, 1e-3, nil, 20.0)
      t.eq(constant.faces, 3)
      t.eq(varying.faces, 3)
      local function area(s) return s:mass(1e-6).area end
      t.ok(area(varying) < area(constant) and area(constant) < area(shell), "the larger ball takes more")
      -- A radius_end equal to the radius is the constant fillet.
      t.eq(shell:fillet(crease, 12.0, 1e-3, nil, 12.0).faces, 3)
      t.raises(function() bs.Solid.cuboid(10, 10, 10):fillet({ 0 }, 1.0, nil, nil, 2.0) end,
        "a varying radius rounds only spline edges")
    end)

    -- ---- flange and extrude_to (the Python reference's _holed_sheet,
    -- test_a_flange_turns_a_hole_under_and_carries_it_inward,
    -- test_a_liner_runs_a_hole_down_to_a_tilted_floor, test_flange_and_extrude_to_refuse_by_name).

    -- Whether every segment end of `e` lies on the circle of radius 5 about (1, -2) within `tol`
    -- (and in z = 0 within `ztol` when given).
    local function on_hole(e, tol, ztol)
      for _, s in ipairs(e.segments) do
        local a = s[1]
        if math.abs(math.sqrt((a[1] - 1) ^ 2 + (a[2] + 2) ^ 2) - 5) >= tol then return false end
        if ztol and math.abs(a[3]) >= ztol then return false end
      end
      return true
    end

    -- The 20 x 20 square in z = 0 facing +z with a round hole of radius 5 about (1, -2), and the
    -- hole's rim edges.
    local function holed_sheet()
      local sheet = rect_sheet({ 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, 20, 20)
      local holed = sheet:trim_by_curve(exact_circle({ 1, -2, 0 }, 5), "outside", { 0, 0, -1 }, 0.01)
      local rim = {}
      for _, e in ipairs(holed.edges) do
        if #e.faces == 1 and on_hole(e, 1e-6) then rim[#rim + 1] = e end
      end
      t.ok(#rim > 0, "the hole has a rim")
      return holed, rim
    end

    t.test("sheets from curves: a flange turns a hole under and carries it inward", function()
      local holed, rim = holed_sheet()
      local under = bs.NurbsCurve({ { 0, 0, 0 }, { 0, -3, 0 } }, 1)
      -- Turned under 3 along the face's normal (+z): the hole's own cylinder, 3 deep, below the sheet.
      local wall = holed:flange(rim, under, 1e-3, false)
      t.eq(wall.faces, #rim)
      t.ok(wall.sheet_error <= 1e-3, "flange error " .. tostring(wall.sheet_error))
      t.ok(math.abs(wall:mass().area - 2 * pi * 5 * 3) < 0.05, "wall area " .. wall:mass().area)
      local lo, hi = wall.bounds[1], wall.bounds[2]
      t.ok(math.abs(lo[3] + 3) < 1e-3 and math.abs(hi[3]) < 1e-3, "wall depth")
      t.ok(math.abs(lo[1] - (1 - 5)) < 1e-2 and math.abs(hi[1] - (1 + 5)) < 1e-2, "wall width")
      -- Carried on outward from the face 2: into the hole, an annulus from radius 5 in to 3.
      local ids = {}
      for i, e in ipairs(rim) do ids[i] = e.index end
      local ring = holed:flange(ids, bs.NurbsCurve({ { 0, 0, 0 }, { 2, 0, 0 } }, 1), nil, false)
      t.ok(math.abs(ring:mass().area - pi * (25 - 9)) < 0.05, "annulus area " .. ring:mass().area)
      -- Joined, the sheet's faces come first and the flange is sewn on.
      local joined = holed:flange(rim, under)
      t.eq(joined.faces, holed.faces + #rim)
      t.ok(math.abs(joined:mass().area - (holed:mass().area + 2 * pi * 5 * 3)) < 0.05, "joined area")
      -- The rim is sewn all the way round: every edge on the hole's circle borders the sheet and the flange.
      local on_rim = 0
      for _, e in ipairs(joined.edges) do
        if on_hole(e, 1e-3, 1e-6) then
          on_rim = on_rim + 1
          local f = { e.faces[1], e.faces[2] }
          table.sort(f)
          t.ok(#e.faces == 2 and f[1] == 0 and f[2] == 1, "rim edge " .. e.index .. " borders faces 0 and 1")
        end
      end
      t.ok(on_rim > 0, "rim edges in the joined sheet")
    end)

    t.test("sheets from curves: a liner runs a hole down to a tilted floor", function()
      local holed, rim = holed_sheet()
      -- The floor z = -7 + 0.1 x, wide enough to catch every point: the wall is 7 - 0.1 x deep,
      -- 6.9 on average round a hole centred at x = 1.
      local floor = bs.Solid.edge_surface({ line({ -20, -20, -9 }, { 20, -20, -5 }), line({ 20, -20, -5 }, { 20, 20, -5 }),
        line({ 20, 20, -5 }, { -20, 20, -9 }), line({ -20, 20, -9 }, { -20, -20, -9 }) })
      local wall = holed:extrude_to(rim, { 0, 0, -1 }, floor, 1e-3, false)
      t.eq(wall.faces, #rim)
      t.ok(wall.sheet_error <= 1e-3, "liner error " .. tostring(wall.sheet_error))
      t.ok(math.abs(wall:mass().area - 2 * pi * 5 * 6.9) < 0.05, "liner area " .. wall:mass().area)
      local lo, hi = wall.bounds[1], wall.bounds[2]
      t.ok(math.abs(lo[3] - (-7 + 0.1 * (1 - 5))) < 1e-2 and math.abs(hi[3]) < 1e-6, "liner depth")
      local joined = holed:extrude_to(rim, { 0, 0, -1 }, floor)
      t.eq(joined.faces, holed.faces + #rim)
      t.ok(joined:step_text():find("SURFACE_OF_LINEAR_EXTRUSION", 1, true) ~= nil, "a linear extrusion in the STEP")
    end)

    t.test("sheets from curves: flange and extrude_to refuse by name", function()
      local holed, rim = holed_sheet()
      local under = bs.NurbsCurve({ { 0, 0, 0 }, { 0, -3, 0 } }, 1)
      local e = t.raises(function() holed:flange(rim, bs.NurbsCurve({ { 1, 0, 0 }, { 1, -3, 0 } }, 1)) end,
        "^flange: the section starts at")
      t.ok(is_build_error(e))
      t.raises(function() holed:flange({}, under) end, "^flange: no edges given")
      t.raises(function() holed:flange({ 999 }, under) end, "^flange: no edge 999")
      t.raises(function() holed:flange(rim[1], under) end, "^flange: edges must be a list")
      t.raises(function() bs.Solid.cuboid(10, 10, 10):flange({ 0 }, under) end, "^flange: edge 0 borders 2 faces")
      local floor = rect_sheet({ 0, 0, -7 }, { 1, 0, 0 }, { 0, 1, 0 }, 40, 40)
      t.raises(function() holed:extrude_to(rim, { 0, 0, 1 }, floor) end, "^extrude_to: edge .* misses the target")
      t.raises(function() holed:extrude_to(rim, { 0, 0, 0 }, floor) end, "^extrude_to: the direction has no length")
      t.raises(function() holed:extrude_to(rim, nil, floor) end, "^extrude_to: null direction")
    end)
  end

  -- ---- the R-tree (r-tree plan 3), at parity with the Python reference's test_rtree_*,
  -- test_closest_points_and_k_neighbors_match_brute_force and
  -- test_k_neighbors_reports_a_bad_point_before_a_bad_k, trimmed to what proves the marshalling:
  -- every field read, every refusal's prefix, the lists' length and order, the handle's lifetime.

  -- The 10 x 10 x 10 grid of unit boxes as {id, {min, max}}, id 100 i + 10 j + k, ascending.
  local function rtree_grid()
    local cells = {}
    for i = 0, 9 do
      for j = 0, 9 do
        for k = 0, 9 do
          cells[#cells + 1] = { 100 * i + 10 * j + k, { { i, j, k }, { i + 1, j + 1, k + 1 } } }
        end
      end
    end
    return cells
  end

  -- Two lists of rows (or of numbers) equal, element by element.
  local function rows_same(a, b)
    if #a ~= #b then return false end
    for n = 1, #a do
      if type(a[n]) == "table" then
        if type(b[n]) ~= "table" or not same(a[n], b[n]) then return false end
      elseif a[n] ~= b[n] then
        return false
      end
    end
    return true
  end

  local function pairs_ascending(list)
    for n = 2, #list do
      local p, q = list[n - 1], list[n]
      if not (p[1] < q[1] or (p[1] == q[1] and p[2] <= q[2])) then return false end
    end
    return true
  end

  local function refused(fn, pattern)
    local e = t.raises(fn, pattern)
    t.ok(is_build_error(e), "a BuildError: " .. tostring(e))
    return e
  end

  t.test("rtree: a grid packed or grown answers alike", function()
    local cells = rtree_grid()
    local packed = bs.RTree.from_boxes(cells)
    local grown = bs.RTree()
    t.eq(getmetatable(grown), bs.RTree)
    -- grown backwards, each box shape in turn: {min, max}, a Box, 6 numbers
    for n = #cells, 1, -1 do
      local id, lo, hi = cells[n][1], cells[n][2][1], cells[n][2][2]
      local shapes = { { lo, hi }, bs.Box(lo, hi), { lo[1], lo[2], lo[3], hi[1], hi[2], hi[3] } }
      grown:insert(id, shapes[n % 3 + 1])
    end
    local corner = {}
    for _, c in ipairs(cells) do
      local id = c[1]
      if math.floor(id / 100) <= 2 and math.floor(id / 10) % 10 <= 2 and id % 10 <= 2 then corner[#corner + 1] = id end
    end
    t.eq(#corner, 27)
    local answers = {}
    for _, named in ipairs({ { "from_boxes", packed }, { "insert", grown } }) do
      local name, tree = named[1], named[2]
      t.eq(tree:count(), 1000, name)
      local b = tree.bounds
      t.ok(same(b[1], { 0, 0, 0 }) and same(b[2], { 10, 10, 10 }), name .. ": bounds")
      t.ok(same(tree:search({ { 0, 0, 0 }, { 2, 2, 2 } }), corner), name .. ": search")
      local near = tree:nearest({ -1, -1, -1 }, 1)
      t.eq(#near, 1, name)
      t.eq(near[1][1], 0, name)
      t.near(near[1][2], math.sqrt(3), 1e-12, name)
      t.ok(rows_same(tree:within({ 0, 0, 0 }, 0), { { 0, 0 } }), name .. ": within 0")
      local ids = {}
      for _, h in ipairs(tree:within({ -1, -1, -1 }, 2.5)) do ids[#ids + 1] = h[1] end
      t.ok(same(ids, { 0, 1, 10, 100 }), name .. ": by distance then id")
      local list = tree:self_overlaps()
      t.eq(#list, (28 ^ 3 - 1000) / 2, name)
      for _, p in ipairs(list) do
        if not (p[1] < p[2]) then t.ok(false, name .. ": the smaller id first") end
      end
      t.ok(pairs_ascending(list), name .. ": pairs ascending")
      t.ok(rows_same(tree:self_overlaps(0.5), list), name .. ": unit gaps paired at slack 0.5")
      answers[#answers + 1] = list
    end
    t.ok(rows_same(answers[1], answers[2]), "both trees answer alike")
  end)

  t.test("rtree: two trees, and one tree against itself", function()
    local grid = bs.RTree.from_boxes(rtree_grid())
    local one = bs.RTree.from_boxes({ { 7, { { 4.5, 4.5, 4.5 }, { 5.5, 5.5, 5.5 } } } })
    local ids = { 444, 445, 454, 455, 544, 545, 554, 555 }
    local forward, backward = {}, {}
    for n, id in ipairs(ids) do
      forward[n] = { id, 7 }
      backward[n] = { 7, id }
    end
    t.ok(rows_same(grid:overlaps(one), forward), "grid against one")
    t.ok(rows_same(one:overlaps(grid, 0), backward), "one against grid")
    local twice = grid:overlaps(grid)
    t.eq(#twice, 1000 + 2 * 10476)
    t.ok(pairs_ascending(twice))
  end)

  t.test("rtree: points, insert and remove", function()
    local points = bs.RTree.from_points({ { 0, 0, 0 }, { 5, 0, 0 }, { 1, 0, 0 }, { 0, 3, 0 } })
    t.eq(points:count(), 4)
    t.ok(same(points:search({ { 0.9, -0.1, -0.1 }, { 1.1, 0.1, 0.1 } }), { 2 }))
    t.ok(rows_same(points:nearest({ 4, 0, 0 }, 2), { { 1, 1 }, { 2, 3 } }))

    local tree = bs.RTree()
    local unit = { { 3, 3, 3 }, { 4, 4, 4 } }
    tree:insert(7, unit)
    tree:insert(7, unit)
    t.ok(same(tree:search(unit), { 7, 7 }))
    t.eq(tree:remove(7, unit), true)
    t.eq(tree:remove(7, unit), true)
    t.eq(tree:remove(7, unit), false)
    tree:insert(7, unit)
    t.eq(tree:remove(8, unit), false, "another id")
    t.eq(tree:remove(7, { { 3, 3, 3 }, { 4, 4, 4.5 } }), false, "another box")
    tree:insert(9, { 1, 2, 3 })
    t.eq(tree:count(), 2)
    local b = tree.bounds
    t.ok(same(b[1], { 1, 2, 3 }) and same(b[2], { 4, 4, 4 }), "bounds")
    t.eq(tree:remove(9, { 1, 2, 3 }), true, "a point is removed by the same point")
    t.eq(tree:remove(7, bs.Box(unit[1], unit[2])), true)
    t.eq(tree:count(), 0)
    t.eq(tree.bounds, nil)
    local largest = 2 ^ 32 - 1
    tree:insert(largest, { 1, 2, 3 })
    t.ok(same(tree:search({ 0, 0, 0, 5, 5, 5 }), { largest }))
    t.eq(tree:remove(largest, { 1, 2, 3 }), true)
  end)

  t.test("rtree: closest_points and k_neighbors match a brute force", function()
    local state = 5
    local function next_number()
      state = (state * 1664525 + 1013904223) % 4294967296
      return state / 4294967296
    end
    local function points_of(n)
      local out = {}
      for i = 1, n do out[i] = { 10 * next_number(), 10 * next_number(), 10 * next_number() } end
      return out
    end
    local hay, needles = points_of(30), points_of(5)
    local function by_distance(q)
      local order = {}
      for i = 1, #hay do order[i] = i - 1 end
      table.sort(order, function(x, y)
        local dx, dy = dist(hay[x + 1], q), dist(hay[y + 1], q)
        if dx ~= dy then return dx < dy end
        return x < y
      end)
      return order
    end
    local closest = bs.closest_points(hay, needles, 3)
    local knn = bs.k_neighbors(hay, needles, 4)
    t.eq(#closest, 5)
    t.eq(#knn, 5)
    local some, all = false, true
    for n, q in ipairs(needles) do
      local order = by_distance(q)
      local in_limit, first = {}, {}
      for _, i in ipairs(order) do
        if dist(hay[i + 1], q) <= 3 then in_limit[#in_limit + 1] = i end
      end
      for m = 1, 4 do first[m] = order[m] end
      t.ok(same(closest[n], in_limit), "closest points, needle " .. (n - 1))
      t.ok(same(knn[n], first), "k neighbors, needle " .. (n - 1))
      some = some or #in_limit > 0
      all = all and #in_limit == #hay
    end
    t.ok(some and not all, "the limit chose nothing or everything")
    t.ok(same(bs.k_neighbors(hay, { needles[1], needles[2] }, 500)[2], by_distance(needles[2])),
      "k over the hay count is every point")
    local empty = bs.k_neighbors({}, { needles[1], needles[2] }, 3)
    t.eq(#empty, 2, "an empty hay")
    t.eq(#empty[1], 0)
    t.eq(#empty[2], 0)
  end)

  t.test("rtree: refusals name their call, and ids and k are checked before the call", function()
    local nan, inf = 0 / 0, math.huge
    local tree = bs.RTree()
    refused(function() tree:insert(1, { { 0, 0, 0 }, { nan, 1, 1 } }) end, "^rtree_insert: .*is not a box$")
    refused(function() tree:insert(1, { { 1, 0, 0 }, { 0, 1, 1 } }) end, "^rtree_insert: .*is not a box$")
    refused(function() tree:insert(1, { inf, 0, 0 }) end, "^rtree_insert_point: .*is not finite$")
    t.eq(tree:count(), 0, "a refused insert changed the tree")
    refused(function() tree:remove(1, { { 1, 0, 0 }, { 0, 1, 1 } }) end, "^rtree_remove: ")
    t.eq(tree:remove(1, { { 0, 0, 0 }, { 1, 1, 1 } }), false, "absent right after a refusal")
    refused(function() tree:search({ { 0, 0, 0 }, { nan, 1, 1 } }) end, "^rtree_search: ")
    refused(function() tree:within({ nan, 0, 0 }, 1) end, "^rtree_within: .*is not finite$")
    refused(function() tree:nearest({ nan, 0, 0 }, 1) end, "^rtree_nearest: .*is not finite$")
    refused(function() tree:within({ 0, 0, 0 }, -1) end, "^rtree_within: radius %-1 is not a distance$")
    refused(function() tree:self_overlaps(nan) end, "^rtree_self_overlaps: slack NaN is not a distance$")
    refused(function() tree:overlaps(tree, -0.5) end, "^rtree_overlaps: ")
    refused(function() tree:nearest({ 0, 0, 0 }, 1000001) end, "^rtree_nearest: k 1000001 is not at most 1000000$")
    refused(function() bs.RTree.from_boxes({ { 1, { { 0, 0, 0 }, { 1, 1, 1 } } }, { 2, { { 2, 0, 0 }, { 1, 1, 1 } } } }) end,
      "^rtree_from_boxes: entry 1")
    refused(function() bs.RTree.from_points({ { 0, 0, 0 }, { 0, nan, 0 } }) end, "^rtree_from_points: point 1 is not finite$")
    -- the shapes, refused here
    refused(function() tree:insert(1, "box") end, "^rtree_insert: a box is ")
    refused(function() tree:insert(1, { 0, 0 }) end, "^rtree_insert: a box is ")
    refused(function() tree:within({ 0, 0 }, 1) end, "^rtree_within: a point is 3 numbers")
    refused(function() tree:within({ 0, 0, 0 }, "1") end, "^rtree_within: radius .* is not a number$")
    refused(function() bs.RTree.from_boxes({ 7 }) end, "^rtree_from_boxes: entry 0 is not an {id, box} pair")
    refused(function() tree:overlaps({}) end, "^rtree_overlaps: other must be an RTree")

    local origin = { { 0, 0, 0 } }
    refused(function() bs.closest_points(origin, origin, -1) end, "^closest_points: limit %-1 is not a distance$")
    refused(function() bs.closest_points({ { 0, 0, 0 }, { nan, 0, 0 } }, { { inf, 0, 0 } }, -1) end,
      "^closest_points: limit %-1 is not a distance$")
    refused(function() bs.closest_points(origin, { { nan, 0, 0 } }, 1) end, "^closest_points: needle point 0 is not finite$")
    refused(function() bs.closest_points({ { 0, 0, 0 }, { 0, 0, nan } }, { { nan, 0, 0 } }, 1) end,
      "^closest_points: hay point 1 is not finite$")
    refused(function() bs.k_neighbors({ { 0, 0, 0 }, { inf, 0, 0 } }, origin, 1000001) end, "^k_neighbors: hay point 1 is not finite$")
    refused(function() bs.k_neighbors(origin, origin, 1000001) end, "^k_neighbors: k 1000001 is not at most 1000000$")
    -- the limit as Rust's {} prints an f64: the shortest round-trip digits, never an exponent
    for _, c in ipairs({
      { -1e-7, "-0.0000001" }, { -1e20, "-100000000000000000000" }, { -1.5, "-1.5" }, { -(0.1 + 0.2), "-0.30000000000000004" },
      { nan, "NaN" }, { -inf, "-inf" }, { -5e-324, "-0." .. ("0"):rep(323) .. "5" }, { -1e-323, "-0." .. ("0"):rep(322) .. "1" },
      { -1e16, "-10000000000000000" }, { -1.2345678901234568e17, "-123456789012345680" }, { -1e21, "-1000000000000000000000" },
      { -0.000123, "-0.000123" }, { -2.5e-5, "-0.000025" },
    }) do
      refused(function() bs.closest_points(origin, origin, c[1]) end,
        "^closest_points: limit " .. c[2]:gsub("[%-%.]", "%%%0") .. " is not a distance$")
    end

    -- a number is not a uint32_t: refused before the FFI could wrap it
    for _, id in ipairs({ -1, 2 ^ 32 }) do
      local shown = ("%.14g"):format(id):gsub("%-", "%%-")
      refused(function() tree:insert(id, { 0, 0, 0 }) end, "^rtree_insert: id is out of range: " .. shown .. "$")
      refused(function() tree:insert(id, { { 0, 0, 0 }, { 1, 1, 1 } }) end, "^rtree_insert: id is out of range: " .. shown .. "$")
      refused(function() tree:remove(id, { 0, 0, 0 }) end, "^rtree_remove: id is out of range: " .. shown .. "$")
      refused(function() bs.RTree.from_boxes({ { id, { 0, 0, 0 } } }) end,
        "^rtree_from_boxes: entry 0: id is out of range: " .. shown .. "$")
      refused(function() tree:nearest({ 0, 0, 0 }, id) end, "^rtree_nearest: k is out of range: " .. shown .. "$")
      refused(function() bs.k_neighbors(origin, origin, id) end, "^k_neighbors: k is out of range: " .. shown .. "$")
    end
    t.eq(tree:count(), 0, "an id out of range reached the tree")
    refused(function() tree:insert(1.5, { 0, 0, 0 }) end, "^rtree_insert: id must be a whole number")
    refused(function() tree:insert("1", { 0, 0, 0 }) end, "^rtree_insert: id must be a whole number")
    refused(function() tree:nearest({ 0, 0, 0 }, 1.5) end, "^rtree_nearest: k must be a whole number")
    refused(function() bs.k_neighbors(origin, origin, nan) end, "^k_neighbors: k must be a whole number")
    -- a NaN is no whole number; an infinity is one out of range
    refused(function() tree:insert(nan, { 1, 2, 3 }) end, "^rtree_insert: id must be a whole number, got nan$")
    refused(function() tree:insert(inf, { 1, 2, 3 }) end, "^rtree_insert: id is out of range: inf$")
    refused(function() tree:nearest({ 0, 0, 0 }, -inf) end, "^rtree_nearest: k is out of range: %-inf$")
    t.eq(tree:count(), 0, "a refused id reached the tree")
  end)

  t.test("rtree: an empty tree answers nothing, and a closed one refuses", function()
    local other = bs.RTree.from_boxes(rtree_grid())
    local empty = bs.RTree()
    t.eq(empty:count(), 0)
    t.eq(empty.bounds, nil)
    t.eq(#empty:search({ { 0, 0, 0 }, { 1, 1, 1 } }), 0)
    t.eq(#empty:within({ 0, 0, 0 }, 10), 0)
    t.eq(#empty:nearest({ 0, 0, 0 }, 3), 0)
    t.eq(#empty:self_overlaps(), 0)
    t.eq(#empty:overlaps(other), 0)
    t.eq(#other:overlaps(empty), 0)
    t.eq(#other:nearest({ 0, 0, 0 }, 0), 0)
    t.eq(bs.RTree.from_boxes({}):count(), 0)
    t.eq(bs.RTree.from_points({}):count(), 0)
    t.eq(empty.closed, false)
    empty:close()
    empty:close()
    t.eq(empty.closed, true)
    local closed = "^rtree: closed$"
    refused(function() return empty:count() end, closed)
    refused(function() return empty.bounds end, closed)
    refused(function() empty:insert(1, { 0, 0, 0 }) end, closed)
    refused(function() empty:remove(1, { 0, 0, 0 }) end, closed)
    refused(function() empty:search({ 0, 0, 0 }) end, closed)
    refused(function() empty:within({ 0, 0, 0 }, 1) end, closed)
    refused(function() empty:nearest({ 0, 0, 0 }, 1) end, closed)
    refused(function() empty:self_overlaps() end, closed)
    refused(function() other:overlaps(empty) end, closed)
    refused(function() empty:overlaps(other) end, closed)
    other:close()
    t.eq(other.closed, true)
  end)

  -- ---- the interpolator, the circumscribed polygon, merge and regions, at parity with the
  -- Python reference's test_interpolator_*, test_circumscribed_polygon_touches_its_circle,
  -- test_merge_* and test_a_merged_body_is_refused_*, trimmed to what proves the marshalling:
  -- every field read, every refusal's prefix, the lists' length and order, the handle's lifetime.

  local SQUARES = { 0, 1, 4, 9, 16 }
  local INTERPOLATOR_MODES = { "nearest", "linear", "cosine", "cubic", "catmull_rom" }
  local MERGE_TOL = 1e-6

  local function fails(fn, pattern)
    local e = t.raises(fn, pattern)
    t.ok(is_build_error(e), "a BuildError: " .. tostring(e))
    return e
  end

  -- Two answers of an interpolator equal exactly: numbers, or lists of numbers.
  local function values_same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) == "number" then return a == b end
    return same(a, b)
  end

  t.test("interpolator: closed forms on the squares", function()
    local sq = bs.Interpolator(SQUARES)
    t.eq(getmetatable(sq), bs.Interpolator)
    t.eq(sq:count(), 5)
    t.eq(sq.dimension, 1)
    t.eq(sq.cyclic, false)
    for _, mode in ipairs(INTERPOLATOR_MODES) do
      for k, y in ipairs(SQUARES) do
        local v = sq:at(k - 1, mode)
        t.eq(type(v), "number", mode)
        t.near(v, y, 1e-12, mode .. " at " .. (k - 1))
      end
      -- open: clamped to the end samples
      t.near(sq:at(-2, mode), 0, 1e-12, mode .. " at -2")
      t.near(sq:at(7, mode), 16, 1e-12, mode .. " at 7")
    end
    t.eq(sq:nearest(1.5), 4)
    t.eq(sq:nearest(1.49), 1)
    t.near(sq:linear(1.5), 2.5, 1e-12)
    t.near(sq:cosine(1.5), 2.5, 1e-12)
    t.near(sq:cosine(1.25), 1 + 3 * (1 - math.cos(pi / 4)) / 2, 1e-12)
    t.near(sq:cubic(1.5), 2.0, 1e-12)
    t.near(sq:catmull_rom(1.5), 2.25, 1e-12)
    t.eq(sq:at(1.5), sq:linear(1.5), "linear by default")
    local ring = bs.Interpolator(SQUARES, true)
    t.eq(ring.cyclic, true)
    t.near(ring:catmull_rom(5), ring:catmull_rom(0), 1e-12)
    t.near(ring:linear(-0.5), 8.0, 1e-12, "halfway from the last sample back to the first")
    ring:close()
  end)

  t.test("interpolator: points answer lists, and sample is a loop of at", function()
    local helix = {}
    for k = 0, 8 do helix[k + 1] = { math.cos(0.7 * k), math.sin(0.7 * k), 0.3 * k } end
    local h = bs.Interpolator(helix)
    t.eq(h:count(), 9)
    t.eq(h.dimension, 3)
    t.ok(all_near(h:at(2), helix[3], 1e-12), "at a whole t, the sample")
    local v = h:catmull_rom(2.5)
    t.eq(type(v), "table")
    t.eq(#v, 3)
    local ts = {}
    for k = 0, 49 do ts[k + 1] = -1.0 + 10.0 * k / 49 end
    for _, mode in ipairs(INTERPOLATOR_MODES) do
      local list = h:sample(ts, mode)
      t.eq(#list, #ts, mode)
      for k, x in ipairs(ts) do
        t.ok(values_same(list[k], h:at(x, mode)), mode .. ": sample " .. (k - 1) .. " is at's")
      end
    end
    local none = h:sample({})
    t.eq(type(none), "table")
    t.eq(#none, 0)
    local square = bs.Interpolator({ { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } }, true)
    t.ok(all_near(square:linear(-0.5), { 0, 0.5 }, 1e-12), "wraps")
    local two = square:sample({ 0.5, 1.5 })
    t.eq(#two, 2)
    t.ok(all_near(two[1], { 0.5, 0 }, 1e-12) and all_near(two[2], { 1, 0.5 }, 1e-12), "two 2D values in order")
    local scalars = bs.Interpolator(SQUARES):sample({ 0, 1.5, 4 }, "linear")
    t.ok(same(scalars, { 0, 2.5, 16 }), "numbers at dimension 1")
  end)

  t.test("interpolator: refusals, and a closed one refuses", function()
    local nan, inf = 0 / 0, math.huge
    fails(function() bs.Interpolator({}) end, "^interpolator_new: no samples")
    fails(function() bs.Interpolator({ 0, 1, nan }) end, "^interpolator_new: sample 2 is not finite")
    fails(function() bs.Interpolator({ { 0, 1 }, { 2, 3, 4 } }) end, "^interpolator: samples differ in length %(2, 3%)$")
    fails(function() bs.Interpolator({ 1, { 2 } }) end, "^interpolator: samples are all numbers or all lists of numbers")
    fails(function() bs.Interpolator({ { 1 }, 2 }) end, "^interpolator: samples are all numbers or all lists of numbers")
    local sq = bs.Interpolator(SQUARES)
    local names = "is not one of nearest, linear, cosine, cubic, catmull_rom$"
    fails(function() sq:at(1, "spline") end, "^interpolator: mode 'spline' " .. names)
    fails(function() sq:sample({ 1 }, "bezier") end, "^interpolator: mode 'bezier' " .. names)
    fails(function() sq:sample({}, "bezier") end, "^interpolator: mode 'bezier' " .. names)
    fails(function() sq:at(1, 3) end, "^interpolator: mode 3 " .. names)
    fails(function() sq:linear(nan) end, "^interpolator_at: t NaN is not finite")
    fails(function() sq:sample({ 0, inf }) end, "^interpolator_sample: t 1 %(inf%) is not finite")
    fails(function() sq:linear("1") end, "^interpolator_at: t '1' is not a number$")
    t.eq(sq.closed, false)
    sq:close()
    sq:close()
    t.eq(sq.closed, true)
    t.eq(tostring(sq), "Interpolator(closed)")
    local closed = "^interpolator: closed$"
    fails(function() sq:linear(1) end, closed)
    fails(function() sq:sample({ 1 }) end, closed)
    fails(function() return sq:count() end, closed)
    fails(function() return sq.dimension end, closed)
    fails(function() return sq.cyclic end, closed)
  end)

  t.test("circumscribed polygon: its sides touch its circle", function()
    local cx, cy, r, n = 2, -1, 5, 6
    local hex = bs.Profile.circumscribed_polygon({ cx, cy }, r, n, 0.3)
    t.eq(getmetatable(hex), bs.Profile)
    -- perimeter 2 n r tan(pi/n) through the library's own length (there is no area call)
    local perimeter = 2 * n * r * math.tan(pi / n)
    t.near(hex:length().length, perimeter, 1e-9 * perimeter)
    -- 2n points evenly round it by arc length, from the first corner: corners on the circle
    -- of r / cos(pi/n) alternating with the sides' midpoints on the circle of r
    local points = hex:divide_by_count(2 * n)
    t.ok(#points >= 2 * n, "points: " .. #points)
    for k = 1, 2 * n do
      local p = points[k].point
      local want = (k % 2 == 1) and r / math.cos(pi / n) or r
      t.near(math.sqrt((p[1] - cx) ^ 2 + (p[2] - cy) ^ 2), want, 1e-6 * r, "point " .. (k - 1))
    end
    local first = points[1].point
    t.near(math.atan2(first[2] - cy, first[1] - cx), 0.3, 1e-9, "the first corner at angle")
    local e = fails(function() bs.Profile.circumscribed_polygon({ 0, 0 }, 10, 2) end)
    t.eq(e.message, "profile_circumscribed_polygon: a polygon has at least 3 sides, not 2")
    -- a number is not a uint32_t: refused before the FFI could wrap it
    fails(function() bs.Profile.circumscribed_polygon({ 0, 0 }, 10, -1) end,
      "^profile_circumscribed_polygon: sides is out of range: %-1$")
    fails(function() bs.Profile.circumscribed_polygon({ 0, 0 }, 10, 2 ^ 32 + 6) end,
      "^profile_circumscribed_polygon: sides is out of range: 4294967302$")
    fails(function() bs.Profile.circumscribed_polygon({ 0, 0 }, 10, 6.5) end,
      "^profile_circumscribed_polygon: sides must be a whole number, got 6.5$")
  end)

  t.test("merge: two cubes at a corner are the outside and three cells", function()
    local a = bs.Solid.cuboid(1, 1, 1)
    local b = a:translate(0.5, 0.5, 0.5)
    local phases = {}
    local m = a:merge(b, MERGE_TOL, function(phase) phases[phase] = true end)
    t.eq(getmetatable(m), bs.Solid)
    t.ok(phases.imprint and phases.select and phases.check, "the merge's phases reach progress")
    t.eq(m.faces, 18)
    local regions = m:regions()
    t.eq(#regions, 4)
    local total, finite_faces = 0, {}
    for i, r in ipairs(regions) do
      t.eq(getmetatable(r), bs.Region)
      t.eq(r.index, i - 1, "indices from 0, in order")
      t.eq(r.finite, i > 1, "region " .. (i - 1) .. " finite")
      t.eq(r.shells, 1)
      t.eq(getmetatable(r.box), bs.Box)
      for k, s in ipairs(r.sides) do
        t.eq(getmetatable(s), bs.FaceSide)
        t.ok(s.sense == 1 or s.sense == -1, "a sense is +1 or -1, not " .. tostring(s.sense))
        if k > 1 then
          local p = r.sides[k - 1]
          t.ok(p.face < s.face or (p.face == s.face and p.sense < s.sense), "sides ascending by face then sense")
        end
        if r.finite then finite_faces[s.face] = true end
      end
      total = total + #r.sides
    end
    t.eq(total, 2 * m.faces, "each face's two sides")
    for f = 0, m.faces - 1 do t.ok(finite_faces[f], "face " .. f .. " bounds a cell") end
    local volumes, small = {}, nil
    for i = 2, 4 do
      local v = m:region_solid(i - 1):mass().volume
      volumes[#volumes + 1] = v
      if math.abs(v - 0.125) < 1e-6 then small = regions[i] end
    end
    table.sort(volumes)
    t.ok(all_near(volumes, { 0.125, 0.875, 0.875 }, 1e-6), "cell volumes")
    t.ok(small ~= nil, "the 1/8 cell")
    t.eq(#small.sides, 6)
    for _, s in ipairs(small.sides) do t.eq(s.sense, -1, "inside both, behind its walls") end
    t.ok(all_near(small.box.lo, { 0, 0, 0 }, 1e-6) and all_near(small.box.hi, { 0.5, 0.5, 0.5 }, 1e-6), "its box")
    -- value records: equal by value
    local again = m:regions()
    t.eq(#again, #regions)
    for i = 1, #regions do
      t.ok(again[i] == regions[i], "region " .. (i - 1) .. " equal by value")
      t.ok(rawequal(again[i], regions[i]) == false)
    end
    t.ok(not (again[2] == again[3]), "two cells differ")
    t.ok(regions[1].sides[1] == again[1].sides[1], "a face side equal by value")
    t.ok(not (regions[1].sides[1] == regions[1].sides[2]), "two face sides differ")
  end)

  t.test("merge: a ball in a box is a box cell with a void", function()
    local m = bs.Solid.cuboid(1, 1, 1):merge(bs.Solid.sphere(0.3), MERGE_TOL)
    local regions = m:regions()
    t.eq(#regions, 3)
    local ball = 4.0 / 3.0 * pi * 0.3 ^ 3
    local v1, v2 = m:region_solid(1):mass().volume, m:region_solid(2):mass().volume
    local box, inner = 2, 3
    if v2 > v1 then box, inner = 3, 2 end
    t.near(math.max(v1, v2), 1 - ball, 1e-6)
    t.near(math.min(v1, v2), ball, 1e-6)
    t.eq(regions[box].shells, 2)
    t.eq(regions[inner].shells, 1)
  end)

  t.test("merge: its body is refused by the manifold verbs, and its cells are not", function()
    local a = bs.Solid.cuboid(1, 1, 1)
    local m = a:merge(a:translate(0.5, 0.5, 0.5), MERGE_TOL)
    fails(function() m:join(a, MERGE_TOL) end,
      "^join: the join needs a manifold solid, and this one has edges of three or more faces")
    fails(function() m:mass() end, "^mass_properties: the mass needs a manifold solid")
    fails(function() m:region_solid(0) end, "^region_solid: region 0 is the infinite region$")
    fails(function() m:region_solid(4) end, "^region_solid: region 4 is not below 4$")
    fails(function() a:merge(a, -1.0) end, "^merge: tolerance must be positive and finite")
    fails(function() a:merge("a") end, "^merge: expected a Solid")
    -- a number is not a uint32_t: refused before the FFI could wrap it
    fails(function() m:region_solid(-1) end, "^region_solid: region is out of range: %-1$")
    fails(function() m:region_solid(2 ^ 32 + 1) end, "^region_solid: region is out of range: 4294967297$")
    fails(function() m:region_solid(1.5) end, "^region_solid: region must be a whole number, got 1.5$")
    -- a cell is an ordinary solid again
    t.ok(m:region_solid(1):join(a, MERGE_TOL).faces > 0)
    -- an ordinary solid has two regions: outside in front of every face, inside behind
    local regions = a:regions()
    t.eq(#regions, 2)
    t.eq(regions[1].finite, false)
    t.eq(regions[2].finite, true)
    t.eq(#regions[1].sides, 6)
    for _, s in ipairs(regions[1].sides) do t.eq(s.sense, 1, "outside") end
    for _, s in ipairs(regions[2].sides) do t.eq(s.sense, -1, "inside") end
    m:close()
    fails(function() m:regions() end, "^solid: closed$")
  end)

  -- ---- rays, triangle trees and a solid's face tree (r-tree plan 6): Python's
  -- test_rtree_ray_*, test_rtree_from_triangles_* and test_solid_face_tree_*, trimmed.

  t.test("rtree: a ray through a row", function()
    local cells = {}
    for i = 0, 9 do cells[i + 1] = { i, { { i, 0, 0 }, { i + 1, 1, 1 } } } end
    local row = bs.RTree.from_boxes(cells)
    local start = { -1, 0.5, 0.5 }
    local along = {}
    for i = 0, 9 do along[i + 1] = { i, i + 1 } end
    t.ok(rows_same(row:ray(start, { 1, 0, 0 }), along), "entry t per box")
    t.ok(rows_same(row:ray(start, { 2, 0, 0 }, 1), { { 0, 0.5 }, { 1, 1 } }), "t in units of the direction")
    t.ok(rows_same(row:ray(start, { 1, 0, 0 }, 3), { { 0, 1 }, { 1, 2 }, { 2, 3 } }), "max_t cuts the row")
    t.ok(rows_same(row:ray({ 2.5, 0.5, 0.5 }, { 1, 0, 0 }, 1), { { 2, 0 }, { 3, 0.5 } }), "from inside: 0")
    t.ok(rows_same(row:ray({ 11, 0.5, 0.5 }, { -1, 0, 0 }, 2), { { 9, 1 }, { 8, 2 } }), "backwards")
    t.eq(#row:ray({ -1, 1, 0.5 }, { 1, 0, 0 }), 10, "grazing the top face counts")
    t.eq(#row:ray({ -1, 1 + 1e-12, 0.5 }, { 1, 0, 0 }), 0)
    t.eq(#row:ray(start, { 1, 0, 0 }, math.huge), 10)
    t.eq(#row:ray(start, { 1, 0, 0 }, nil), 10, "nil max_t is infinity")
    t.eq(#bs.RTree():ray(start, { 1, 0, 0 }), 0, "an empty tree")
    local nan, inf = 0 / 0, math.huge
    refused(function() row:ray({ 0, 0, 0 }, { 0, 0, 0 }) end, "^rtree_ray: direction %(0, 0, 0%) is not a direction$")
    refused(function() row:ray({ 0, 0, 0 }, { 1, 0, 0 }, -1) end, "^rtree_ray: max_t %-1 is not a distance$")
    refused(function() row:ray({ 0, 0, 0 }, { 1, 0, 0 }, nan) end, "^rtree_ray: max_t NaN is not a distance$")
    refused(function() row:ray({ nan, 0, 0 }, { 1, 0, 0 }) end, "^rtree_ray: origin %(NaN, 0, 0%) is not finite$")
    refused(function() row:ray({ 0, 0, 0 }, { inf, 0, 0 }) end, "^rtree_ray: direction %(inf, 0, 0%) is not finite$")
    -- the shapes, refused here
    refused(function() row:ray({ 0, 0 }, { 1, 0, 0 }) end, "^rtree_ray: an origin is 3 numbers")
    refused(function() row:ray({ 0, 0, 0 }, "x") end, "^rtree_ray: a direction is 3 numbers")
    refused(function() row:ray({ 0, 0, 0 }, { 1, 0, 0 }, "1") end, "^rtree_ray: max_t .* is not a number$")
    row:close()
    refused(function() row:ray(start, { 1, 0, 0 }) end, "^rtree: closed$")
  end)

  t.test("rtree: from_triangles boxes each triangle", function()
    local nan, inf = 0 / 0, math.huge
    local positions = { { 0, 0, 0 }, { 2, 0, 0 }, { 0, 3, 0 }, { nan, 0, 0 }, { 5, 1, 4 } }
    local tree = bs.RTree.from_triangles(positions, { { 0, 1, 2 }, { 1, 4, 1 } })
    t.eq(tree:count(), 2)
    local b = tree.bounds
    t.ok(same(b[1], { 0, 0, 0 }) and same(b[2], { 5, 3, 4 }), "point 3 is used by no triangle")
    t.ok(same(tree:search({ 1, 1, 0 }), { 0 }), "ids are the triangle indices")
    t.ok(same(tree:search({ 4, 0.5, 2 }), { 1 }))
    t.ok(rows_same(tree:ray({ -1, 0.5, 0 }, { 1, 0, 0 }), { { 0, 1 }, { 1, 3 } }))
    t.eq(bs.RTree.from_triangles({}, {}):count(), 0)
    local four = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
    refused(function() bs.RTree.from_triangles(four, { { 0, 1, 2 }, { 0, 4, 1 } }) end,
      "^rtree_from_triangles: triangle 1 names point 4 of 4$")
    refused(function() bs.RTree.from_triangles({ { 0, 0, 0 }, { 0, inf, 0 } }, { { 0, 1, 0 } }) end,
      "^rtree_from_triangles: triangle 0 point 1 is not finite$")
    -- the shapes and the index range, refused here
    refused(function() bs.RTree.from_triangles({ { 0, 0, 0 }, { 1, 1 } }, { { 0, 0, 0 } }) end,
      "^rtree_from_triangles: point 1 is not 3 numbers")
    refused(function() bs.RTree.from_triangles(four, { { 0, 1, 2 }, { 0, 1 } }) end,
      "^rtree_from_triangles: triangle 1 is not 3 indices")
    refused(function() bs.RTree.from_triangles(four, "x") end, "^rtree_from_triangles: expected a list of triangles")
    for _, k in ipairs({ { -1, "%-1" }, { 2 ^ 32, "4294967296" } }) do
      refused(function() bs.RTree.from_triangles(four, { { 0, 1, 2 }, { 0, k[1], 1 } }) end,
        "^rtree_from_triangles: triangle 1's index is out of range: " .. k[2] .. "$")
    end
    refused(function() bs.RTree.from_triangles(four, { { 0, 1.5, 2 } }) end,
      "^rtree_from_triangles: triangle 0's index must be a whole number")
  end)

  t.test("rtree: a cuboid's face tree", function()
    local cuboid = bs.Solid.cuboid(3, 4, 5)
    local faces = cuboid:face_tree()
    t.eq(getmetatable(faces), bs.RTree)
    t.eq(faces:count(), 6)
    local grow = 5 * 1e-3
    local b = faces.bounds
    t.ok(all_near(b[1], { -1.5 - grow, -2 - grow, -2.5 - grow }) and all_near(b[2], { 1.5 + grow, 2 + grow, 2.5 + grow }),
      "bounds grown by a thousandth of the extent")
    t.eq(#faces:search({ { 1.4, 1.9, 2.4 }, { 1.6, 2.1, 2.6 } }), 3, "three faces at a corner")
    local shot = faces:ray({ 10, 0, 0 }, { -1, 0, 0 })
    t.eq(#shot, 2)
    t.near(shot[1][2], 8.5 - grow, 1e-9)
    t.near(shot[2][2], 11.5 - grow, 1e-9)
    -- The +x face is the one the ray met first: a face call by that index agrees.
    local frame = cuboid:face_frame(shot[1][1])
    t.ok(all_near({ frame[10], frame[11], frame[12] }, { 1, 0, 0 }), "the +x face first")
    -- The tree is its own: it outlives the solid.
    cuboid:close()
    t.eq(faces:count(), 6)
    refused(function() cuboid:face_tree() end, "^solid: closed$")
    faces:close()
  end)

  -- ---- health and healing (Python's test_health_* / test_healed_* and its two decoder tests)
  do
    local function rel(actual, expected, r, message)
      t.ok(math.abs(actual - expected) <= r * math.abs(expected),
        ("%sexpected %.17g (rel %g), got %.17g"):format(message and (message .. ": ") or "", expected, r, actual))
    end
    local function row_of(e)
      return ("%s,%s,%s,%s,%s,%s,%g,%g"):format(e.trim, tostring(e.edge), e.face, e.wire, tostring(e.partner),
        e.shared_ends, e.length, e.gap)
    end

    t.test("health of a closed cuboid has nothing free and cracks only on request", function()
      local box = bs.Solid.cuboid(10, 10, 10)
      local report = box:health()
      t.eq(getmetatable(report), bs.HealthReport)
      t.eq(#report.free_edges, 0)
      t.eq(#report.wires, 0)
      t.eq(#report.small, 0)
      t.eq(report.cracks, nil)
      rel(report.extent, 10 * math.sqrt(3), 1e-12, "extent")
      rel(report.rounding, 1e-7 * report.extent, 1e-12, "rounding")
      rel(report.tolerance, 1e-4 * report.extent, 1e-12, "tolerance")
      t.eq(report.loose_edges, 0)
      t.eq(report.worst_loose, 0)
      t.eq(report.sew_pairs, 0)
      t.eq(report.sew_refused, 0)
      t.eq(report.sew_worst_gap, 0)
      local cracks = box:health(nil, true).cracks
      t.eq(getmetatable(cracks), bs.Cracks)
      t.eq(cracks.watertight, true)
      t.eq(cracks.open, 0)
      t.eq(cracks.folded, 0)
      t.eq(cracks.crossings, 0)
      t.eq(#cracks.edges, 0)
      t.eq(box:health(0.5).tolerance, 0.5)
      t.eq(box:health(-1).tolerance, report.tolerance)
    end)

    t.test("health of a cuboid without a face is one open rim of four edges", function()
      local hole = bs.Solid.cuboid(10, 10, 10):drop_faces({ 0 })
      local report = hole:health()
      t.eq(#report.free_edges, 4)
      t.eq(#report.wires, 1)
      local wire = report.wires[1]
      t.eq(getmetatable(wire), bs.FreeWire)
      t.eq(wire.first, 0)
      t.eq(wire.count, 4)
      t.eq(wire.closed, true)
      t.near(wire.length, 40, 1e-9)
      -- (trim, edge, face, partner): the partner a row of this list, never a face or edge id
      local expected = { { 4, 3, 1, 2 }, { 16, 2, 4, 3 }, { 11, 1, 2, 0 }, { 15, 0, 3, 1 } }
      for i, e in ipairs(report.free_edges) do
        t.eq(getmetatable(e), bs.FreeEdge)
        t.eq(("%s %s %s %s"):format(e.trim, e.edge, e.face, e.partner), table.concat(expected[i], " "), "row " .. i)
        t.eq(e.wire, 0)
        t.eq(e.shared_ends, 0)
        t.near(e.length, 10, 1e-9)
        t.near(e.gap, 10, 1e-9)
        t.eq(report.free_edges[e.partner + 1].partner, i - 1, "partners pair up")
      end
      t.near(report.worst_gap, 10, 1e-9)
      local rows = report:wire_edges(0)
      t.eq(#rows, 4)
      for i = 1, 4 do t.eq(rows[i], report.free_edges[i]) end
      t.eq(report.sew_pairs, 0)
      t.eq(report.sew_refused, 0)
      t.eq(report.sew_worst_gap, 0)
      local cracks = hole:health(nil, true).cracks
      t.ok(cracks ~= nil and not cracks.watertight)
      t.eq(cracks.open + cracks.folded + cracks.crossings + #cracks.edges, 0)
    end)

    t.test("health lists a thin plate's small features by kind, index and size", function()
      local report = bs.Solid.cuboid(10, 10, 0.001):health(0.01)
      local got = {}
      for i, s in ipairs(report.small) do
        t.eq(getmetatable(s), bs.SmallFeature)
        got[i] = s.kind .. " " .. s.index
      end
      t.eq(table.concat(got, ", "), "short_edge 8, short_edge 9, short_edge 10, short_edge 11, "
        .. "sliver_face 2, sliver_face 3, sliver_face 4, sliver_face 5")
      for i = 1, 4 do t.near(report.small[i].size, 0.001, 1e-9) end
      for i = 5, 8 do rel(report.small[i].size, 0.0009999, 1e-3, "sliver width") end
    end)

    t.test("health reports a tiny body and its tiny faces", function()
      local report = bs.Solid.cuboid(0.0005, 0.0005, 0.0005):health(0.01)
      local kinds = {}
      for _, s in ipairs(report.small) do
        kinds[s.kind] = kinds[s.kind] or {}
        table.insert(kinds[s.kind], s)
      end
      t.eq(#kinds.short_edge, 12)
      t.eq(#kinds.tiny_face, 6)
      t.eq(#kinds.tiny_body, 1)
      t.eq(#report.small, 19)
      for i, s in ipairs(kinds.tiny_face) do
        t.eq(s.index, i - 1)
        t.near(s.size, 2.5e-7, 1e-12)
      end
      t.eq(kinds.tiny_body[1].index, 0)
      rel(kinds.tiny_body[1].size, 0.0005 * math.sqrt(3), 1e-9, "tiny body")
    end)

    t.test("healed cuboid heals to itself as a new solid", function()
      local box = bs.Solid.cuboid(10, 10, 10)
      local healed, report = box:healed()
      t.eq(getmetatable(healed), bs.Solid)
      t.eq(getmetatable(report), bs.HealReport)
      t.ok(healed:_h() ~= box:_h(), "a new solid")
      t.eq(#report.fixes, 0)
      t.eq(#report.refused, 0)
      t.eq(report.guarded, false)
      t.eq(("%d %d %d %d"):format(report.small_before, report.small_after, report.free_before, report.free_after), "0 0 0 0")
      t.eq(report.closed_before, true)
      t.eq(report.closed_after, true)
      t.eq(report.nonmanifold_before, 0)
      t.eq(report.nonmanifold_after, 0)
      rel(report.tolerance, box:health().tolerance, 1e-12, "tolerance")
      t.eq(report.moved, 0)
      t.eq(healed.faces, 6)
      t.near(healed:mass().volume, 1000, 1e-6)
      local _, half = box:healed(0.5)
      t.eq(half.tolerance, 0.5)
      for e = 0, 11 do t.eq(healed:edge_tolerance(e), 0, "edge " .. e) end
      t.eq(healed:edge_tolerance(0xFFFFFFF0), nil)
      refused(function() healed:edge_tolerance(-1) end, "^edge_tolerance: ")
      refused(function() healed:edge_tolerance(1.5) end, "^edge_tolerance: ")
    end)

    t.test("healed with every kind off refuses each small feature as toggled", function()
      local plate = bs.Solid.cuboid(10, 10, 0.001)
      local _, report = plate:healed(0.01, false, false, false)
      t.eq(#report.fixes, 0)
      t.eq(report.small_before, 8)
      t.eq(report.small_after, 8)
      local got = {}
      for i, r in ipairs(report.refused) do
        t.eq(getmetatable(r), bs.HealRefusal)
        got[i] = ("%s %d %s %g"):format(r.kind, r.index, r.why, r.figure)
      end
      t.eq(table.concat(got, ", "), "short_edge 8 toggled 0, short_edge 9 toggled 0, short_edge 10 toggled 0, "
        .. "short_edge 11 toggled 0, sliver_face 2 toggled 0, sliver_face 3 toggled 0, sliver_face 4 toggled 0, "
        .. "sliver_face 5 toggled 0")
      -- one kind off at a time: only that kind's features are toggled
      for _, off in ipairs({ { false, true, true, "short_edge" }, { true, false, true, "sliver_face" } }) do
        local _, one = plate:healed(0.01, off[1], off[2], off[3])
        local toggled = 0
        for _, r in ipairs(one.refused) do
          if r.why == "toggled" then
            t.eq(r.kind, off[4])
            toggled = toggled + 1
          end
        end
        t.eq(toggled, 4, off[4] .. " toggled")
      end
      local _, on = plate:healed(0.01)
      t.eq(on.small_before, 8)
      for _, r in ipairs(on.refused) do
        t.ok(r.why ~= "toggled")
        if on.guarded then t.eq(r.why, "body_guard") end
      end
    end)

    t.test("healed drops a sheet's pinhole unless holes is switched off", function()
      -- a 0.002-wide hole in a flat sheet: an inner loop whose edges are all free, below 0.01
      local sheet = bs.Solid.face(bs.Profile.rect(10, 10):with_hole(bs.Profile.circle(0.002)), XY)
      local holes = {}
      for _, s in ipairs(sheet:health(0.01).small) do
        if s.kind == "small_hole" then holes[#holes + 1] = s.index end
      end
      t.eq(table.concat(holes, " "), "1")
      local _, on = sheet:healed(0.01)
      t.eq(#on.fixes, 1)
      t.eq(on.fixes[1].kind .. " " .. on.fixes[1].index, "small_hole 1")
      t.eq(#on.refused, 0)
      t.eq(on.small_after, 0)
      local _, off = sheet:healed(0.01, true, true, false)
      t.eq(#off.fixes, 0)
      local got = {}
      for _, x in ipairs(off.refused) do
        if x.why == "toggled" then got[#got + 1] = x.kind .. " " .. x.index end
      end
      t.eq(table.concat(got, ", "), "small_hole 1")
    end)

    t.test("health, healed and edge_tolerance of a closed solid raise", function()
      local box = bs.Solid.cuboid(1, 1, 1)
      box:close()
      refused(function() box:health() end, "closed")
      refused(function() box:healed() end, "closed")
      refused(function() box:edge_tolerance(0) end, "closed")
    end)

    t.test("the health decoder reads every column of distinct rows", function()
      local none = 0xFFFFFFFF
      local counts = { 2, 1, 1, 2, 1, 0, 0, 1, 0, 3, 4, 5, 1, 0, 11, 12, 13, 2 }
      local sizes = { 0.5, 0.25, 9.0, 7.5, 6.5, 5.5, 4.5, 3.5 }
      local r = bs._health_report(counts, sizes, { 10, 20, 30, 40, 1, 2, 11, none, 31, 41, none, 0 },
        { 1.5, 2.5, 3.5, math.huge }, { 0, 2, 1 }, { 8.5, 2.5 }, { 1, 77, 4, 99 }, { 0.125, 0.0625 }, { 5, 6 })
      t.eq(("%g %g %g %g"):format(r.tolerance, r.rounding, r.extent, r.worst_gap), "0.5 0.25 9 7.5")
      t.eq(("%d %g %d %d %g"):format(r.loose_edges, r.worst_loose, r.sew_pairs, r.sew_refused, r.sew_worst_gap),
        "3 6.5 4 5 5.5")
      t.eq(#r.free_edges, 2)
      t.eq(row_of(r.free_edges[1]), "10,20,30,40,1,2,1.5,2.5")
      t.eq(row_of(r.free_edges[2]), "11,nil,31,41,nil,0,3.5,inf")
      t.eq(#r.wires, 1)
      local w = r.wires[1]
      t.eq(("%d %d %s %g %g"):format(w.first, w.count, tostring(w.closed), w.length, w.widest_gap), "0 2 true 8.5 2.5")
      t.eq(#r.small, 2)
      t.eq(("%s %d %g"):format(r.small[1].kind, r.small[1].index, r.small[1].size), "collapsed_edge 77 0.125")
      t.eq(("%s %d %g"):format(r.small[2].kind, r.small[2].index, r.small[2].size), "tiny_body 99 0.0625")
      local c = r.cracks
      t.eq(("%s %d %d %d %s"):format(tostring(c.watertight), c.open, c.folded, c.crossings, table.concat(c.edges, " ")),
        "false 11 12 13 5 6")
      -- counts[12] 0: not meshed, so no cracks however the other counts read
      counts[13] = 0
      local unmeshed = bs._health_report(counts, sizes, {}, {}, {}, {}, { 5, 1 }, { 1 }, {})
      t.eq(unmeshed.cracks, nil)
      t.eq(unmeshed.small[1].kind, "small_hole")
    end)

    t.test("the heal decoder reads every column of distinct rows", function()
      local r = bs._heal_report({ 2, 3, 1, 9, 8, 7, 6, 1, 0, 5, 4 }, { 0.5, 0.25 }, { 5, 11, 0, 12 },
        { 1.5, 0.125, 2.5, 0.0625 }, { 3, 21, 9, 4, 22, 3, 2, 23, 10 }, { 0.0, 7.5, 0.0 })
      t.eq(("%g %g %s"):format(r.tolerance, r.moved, tostring(r.guarded)), "0.5 0.25 true")
      t.eq(("%d %d %d %d"):format(r.small_before, r.small_after, r.free_before, r.free_after), "9 8 7 6")
      t.eq(("%s %s %d %d"):format(tostring(r.closed_before), tostring(r.closed_after), r.nonmanifold_before,
        r.nonmanifold_after), "true false 5 4")
      local fixes = {}
      for i, f in ipairs(r.fixes) do
        t.eq(getmetatable(f), bs.HealFix)
        fixes[i] = ("%s %d %g %g"):format(f.kind, f.index, f.size, f.moved)
      end
      t.eq(table.concat(fixes, ", "), "small_hole 11 1.5 0.125, short_edge 12 2.5 0.0625")
      local refusals = {}
      for i, x in ipairs(r.refused) do refusals[i] = ("%s %d %s %g"):format(x.kind, x.index, x.why, x.figure) end
      t.eq(table.concat(refusals, ", "), "tiny_face 21 toggled 0, tiny_body 22 chain 7.5, sliver_face 23 unsupported 0")
      local whys = {}
      for why = 0, 10 do
        local one = bs._heal_report({ 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, { 0, 0 }, {}, {}, { 0, 0, why }, { 0 })
        whys[#whys + 1] = one.refused[1].why
      end
      t.eq(table.concat(whys, " "), "would_empty_loop closed seam chain neighbours_part uneven non_manifold "
        .. "has_holes body_guard toggled unsupported")
    end)
  end

  -- ---- value geometry (plan B3): Interval, the frame verbs, the feet and the nine values ----------
  --
  -- Python's TestInterval, TestFrameVerbs, TestCurveValues, TestSurfaceValues and TestCuboidValue,
  -- figure for figure. The Rhino records are the file B1's crates/cadaclysm/tests/rhino_values.rs
  -- reads, found from this file's own path: in a checkout a missing file fails; the SDK ships this
  -- folder without it, so there the record tests say "skipped:" and the rest still run.
  do
    local V_XY = { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 }
    --- Right-handed and exact: x = world y, y = world z, z = world x, off the origin.
    local YZX = { 1, 2, 3, 0, 1, 0, 0, 0, 1, 1, 0, 0 }
    local EXACT, NURBS_FOOT = 1e-12, 1e-7

    -- The records file and whether this copy is the repository's (its crates/cadaclysm/Cargo.toml
    -- beside the resolved root), from this test file's own path, never the working directory.
    local function vectors_path()
      local source = debug.getinfo(1, "S").source
      local file = (source:sub(1, 1) == "@" and source:sub(2) or "blacksmith_test.lua"):gsub("\\", "/")
      local dir = file:match("^(.*)/[^/]*$") or "."
      local root = dir .. "/../../../../.."   -- test, luajit, examples, cadaclysm-capi, crates
      local cargo = io.open(root .. "/crates/cadaclysm/Cargo.toml", "rb")
      if cargo then cargo:close() end
      return root .. "/crates/cadaclysm/tests/fixtures/rhino/value_vectors.txt", cargo ~= nil
    end

    local records
    -- The records by (case, what), or nil (and a "skipped:" line) in an SDK layout without them.
    local function vectors(test)
      if records == nil then
        local path, in_repo = vectors_path()
        local f = io.open(path, "rb")
        if not f then
          if in_repo then error("the Rhino records are missing from the checkout: " .. path, 2) end
          records = false
        else
          local text = f:read("*a")
          f:close()
          records = {}
          for line in (text .. "\n"):gmatch("([^\n]*)\n") do
            line = line:gsub("\r", ""):match("^%s*(.-)%s*$")
            assert(not line:find("ERROR", 1, true), line)
            if line ~= "" and line:sub(1, 1) ~= "#" then
              local words = {}
              for w in line:gmatch("%S+") do words[#words + 1] = w end
              local key = words[1] .. " " .. words[2]
              assert(records[key] == nil, "a record twice: " .. key)
              records[key] = { unpack(words, 3) }
            end
          end
        end
      end
      if not records then
        print("skipped: " .. test .. ": no value_vectors.txt beside this copy (an SDK layout)")
        return nil
      end
      return records
    end

    local function words(r, case, what)
      local w = r[case .. " " .. what]
      if not w then error("no record " .. case .. " " .. what, 2) end
      return w
    end

    local function nums(r, case, what)
      local out = {}
      for i, w in ipairs(words(r, case, what)) do out[i] = assert(tonumber(w), w) end
      return out
    end

    local function sub(a, i, j)
      local out = {}
      for k = i, j do out[#out + 1] = a[k] end
      return out
    end

    local function close(got, want, tol, label)
      if #got ~= #want then error(("%s: %d numbers, want %d"):format(label, #got, #want), 2) end
      for i = 1, #want do
        if not (math.abs(got[i] - want[i]) <= tol) then
          error(("%s: got {%s}, want {%s}"):format(label, table.concat(got, ", "), table.concat(want, ", ")), 2)
        end
      end
    end

    local function dist(a, b)
      return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
    end

    local function queries(r, shape)
      local out = {}
      for i = 0, 11 do
        local case = ("%s_%02d"):format(shape, i)
        out[#out + 1] = { case, nums(r, case, "query") }
      end
      return out
    end

    -- A foot Rhino found by iteration on a NURBS form: the distance to 1e-12, never beaten by
    -- Rhino's, the point to 1e-7 -- as B1's `nurbs_foot`.
    local function nurbs_foot(label, q, ours, rhino)
      local d, dr = dist(q, ours), dist(q, rhino)
      t.ok(d <= dr + EXACT and math.abs(d - dr) <= EXACT, ("%s: %.17g vs %.17g"):format(label, d, dr))
      close(ours, rhino, NURBS_FOOT, label)
    end

    -- Raised with exactly the library's (or the wrapper's) sentence.
    local function refused(fn, text)
      local e = t.raises(fn)
      t.ok(is_build_error(e), "a BuildError: " .. tostring(e))
      t.eq(tostring(e), text)
    end

    local function is(v, cls) return type(v) == "table" and getmetatable(v) == cls end

    -- ---- Interval ----

    t.test("an Interval's measures keep the orientation", function()
      local I = bs.Interval
      local up, down = I(2, 6), I(6, 2)
      t.eq(up.length, 4.0)
      t.eq(down.length, -4.0)
      t.eq(up.mid, 4.0)
      t.eq(down.mid, 4.0)
      t.ok(up.min == 2 and up.max == 6 and down.min == 2 and down.max == 6)
      t.ok(up.is_increasing and not down.is_increasing and not I(3, 3).is_increasing)
      t.ok(I(3, 3).is_singleton and not up.is_singleton)
      t.ok(up:swapped() == down and down:swapped() == up)
      t.ok(down[1] == 6 and down[2] == 2 and down.t0 == 6 and down.t1 == 2)
      t.ok(same(down:values(), { 6, 2 }))
    end)

    t.test("an Interval's set operations answer increasing, and touching is a singleton", function()
      local i = bs.Interval
      local up, down = i(2, 6), i(6, 2)
      t.ok(up:grown(9) == i(2, 9) and down:grown(-1) == i(-1, 6) and down:grown(3) == up)
      t.ok(up:union(i(8, 7)) == i(2, 8) and down:union({ 1, 3 }) == i(1, 6))
      t.ok(down:intersect(i(9, 4)) == i(4, 6) and up:intersect(i(3, 5)) == i(3, 5))
      t.ok(up:intersect(i(7, 9)) == nil and down:intersect(i(1, 1.5)) == nil)
      t.ok(i(0, 1):intersect(i(1, 2)) == i(1, 1) and i(2, 1):intersect(i(0, 1)) == i(1, 1), "touching")
      for _, x in ipairs({ up, down }) do
        t.ok(x:contains(2) and x:contains(6) and x:contains(4.5))
        t.ok(not x:contains(1.999) and not x:contains(6.001))
      end
    end)

    t.test("an Interval's parameters round-trip", function()
      local i = bs.Interval
      t.eq(i(2, 6):parameter_at(0.25), 3.0)
      t.eq(i(6, 2):parameter_at(0.25), 5.0)
      for _, x in ipairs({ i(2, 6), i(6, 2), i(-1.5, 0.7) }) do
        for _, s in ipairs({ -0.5, 0.0, 0.3, 1.0, 2.0 }) do
          t.near(x:normalized_parameter_at(x:parameter_at(s)), s, 1e-15)
        end
      end
      t.eq(i(3, 3):normalized_parameter_at(3), nil)
    end)

    t.test("an Interval is a frozen value", function()
      local a = bs.Interval(1, 2)
      t.ok(a == bs.Interval(1.0, 2.0) and a ~= bs.Interval(2, 1))
      t.ok(a ~= { 1.0, 2.0 }, "not equal to a plain pair")
      t.eq(tostring(a), "Interval(1, 2)")
      t.raises(function() a.t0 = 5 end, "Interval is immutable: cannot set t0")
      t.raises(function() a.extra = 5 end, "Interval is immutable: cannot set extra")
      refused(function() bs.Interval(0 / 0, 1) end, "Interval: not finite")
      refused(function() bs.Interval(1, math.huge) end, "Interval: not finite")
      refused(function() bs.Interval.of({ 1, 2, 3 }) end, "Interval: an interval is 2 numbers, got 3")
      t.eq(bs.Interval.of(a), a)
      t.ok(bs.Interval.of({ 3, 4 }) == bs.Interval(3, 4))
    end)

    t.test("an Interval matches Rhino", function()
      local r = vectors("an Interval matches Rhino")
      if not r then return end
      for _, name in ipairs({ "apart", "dec_dec", "inc_dec", "inc_inc", "touch" }) do
        local case = "interval_" .. name
        local args = nums(r, case, "args")
        local a, b = bs.Interval(args[1], args[2]), bs.Interval(args[3], args[4])
        t.ok(same(a:union(b):values(), nums(r, case, "union")), case)
        local got = a:intersect(b)
        if words(r, case, "intersection")[1] == "none" then
          t.eq(got, nil, case)
        else
          t.ok(got ~= nil and same(got:values(), nums(r, case, "intersection")), case)
        end
      end
      for _, name in ipairs({ "inc_inside", "inc_out", "dec_low", "dec_inside" }) do
        local args = nums(r, "grow_" .. name, "args")
        t.ok(same(bs.Interval(args[1], args[2]):grown(args[3]):values(), nums(r, "grow_" .. name, "grown")), name)
      end
      for _, name in ipairs({ "inc", "dec" }) do
        for k = 0, 3 do
          local case = ("param_%s_%d"):format(name, k)
          local args = nums(r, case, "args")
          local x, s = bs.Interval(args[1], args[2]), args[3]
          close({ x:parameter_at(s) }, nums(r, case, "parameter_at"), EXACT, case)
          close({ x:normalized_parameter_at(2.5 + s) }, nums(r, case, "normalized_at"), EXACT, case)
        end
      end
    end)

    -- ---- the frame verbs ----

    t.test("the plane verbs match Rhino", function()
      local r = vectors("the plane verbs match Rhino")
      if not r then return end
      local p = bs.Frame.of(nums(r, "plane", "frame"))
      t.ok(is(p:flipped(), bs.Frame))
      close(p:flipped():values(), nums(r, "plane", "flip"), EXACT, "flip")
      close(p:rotated(0.6, { 1, -1, 0.5 }):values(), nums(r, "plane", "rotate"), EXACT, "rotate")
      for _, cq in ipairs(queries(r, "plane")) do
        local case, q = cq[1], cq[2]
        close(p:to_local(q), nums(r, case, "remap"), EXACT, case)
        close(p:closest_point(q), nums(r, case, "closest"), EXACT, case)
        close({ p:distance_to(q) }, nums(r, case, "distance"), EXACT, case)
      end
    end)

    t.test("Frame.fit matches Rhino and refuses in the library's words", function()
      refused(function() bs.Frame.fit({ { 0, 0, 0 }, { 1, 0, 0 } }) end, "frame_fit: needs three points")
      refused(function() bs.Frame.fit({ { 0, 0, 0 }, { 1, 1, 1 }, { 2, 2, 2 } }) end, "frame_fit: the points lie on one line")
      local r = vectors("Frame.fit matches Rhino")
      if not r then return end
      local flat = nums(r, "fit", "points")
      local pts = {}
      for k = 1, #flat, 3 do pts[#pts + 1] = { flat[k], flat[k + 1], flat[k + 2] } end
      local got, deviation = bs.Frame.fit(pts)
      t.ok(is(got, bs.Frame))
      local want = bs.Frame.of(nums(r, "fit", "frame"))
      local gz, wz = got.z, want.z
      local sign = (gz[1] * wz[1] + gz[2] * wz[2] + gz[3] * wz[3]) < 0 and -1.0 or 1.0
      close({ sign * gz[1], sign * gz[2], sign * gz[3] }, wz, EXACT, "normal")
      close({ want:distance_to(got.origin), got:distance_to(want.origin) }, { 0, 0 }, EXACT, "origins")
      close({ deviation }, nums(r, "fit", "deviation"), EXACT, "deviation")
      refused(function() bs.Frame.fit({ pts[1], pts[2] }) end, "frame_fit: needs three points")
    end)

    -- ---- curves ----

    t.test("a bad curve value is refused by value_check", function()
      refused(function() bs.Circle(V_XY, 0) end, "value_check: the radius must be positive")
      refused(function() bs.Line({ 1, 1, 1 }, { 1, 1, 1 }) end, "value_check: the line has no length")
      refused(function() bs.Arc(V_XY, 1, { 0, 7 }) end, "value_check: the angle must increase by at most a full turn")
      refused(function() bs.Arc(V_XY, 1, bs.Interval(1, 0)) end,
        "value_check: the angle must increase by at most a full turn")
      refused(function() bs.Ellipse(V_XY, 3, -1) end, "value_check: the second radius must be positive")
      refused(function() bs.Circle({ 0, 0, 0, 1, 1e-3, 0, 0, 1, 0, 0, 0, 1 }, 1) end,
        "value_check: the frame is not right-handed and orthonormal")
      -- A wrong count is refused before the call, in the library's sentence (value_size).
      refused(function() bs.Circle.from_array(sub(V_XY, 1, 12)) end, "value_check: a circle is 13 numbers, got 12")
      t.ok(bs.Circle.from_array({ 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 2 }) == bs.Circle(V_XY, 2))
      -- 1e-7 off square is squared up, not refused.
      local near = bs.Circle({ 0, 0, 0, 1, 1e-7, 0, 0, 1, 0, 0, 0, 1 }, 1)
      local x, y = near.frame.x, near.frame.y
      t.ok(math.abs(x[1] * y[1] + x[2] * y[2] + x[3] * y[3]) < 1e-15 and x[2] ~= 0)
    end)

    t.test("each curve call answers B1's figures", function()
      local unit = bs.Circle(V_XY, 1)
      near3(unit:point_at(pi / 2), { 0, 1, 0 }, 1e-15, "point_at")
      near3(unit:tangent_at(0), { 0, 1, 0 }, 1e-15, "tangent_at")
      local line = bs.Line({ 0, 0, 0 }, { 1, 2, 3 })
      t.ok(same(line:point_at(0.5), { 0.5, 1.0, 1.5 }))
      t.eq(line:length(), math.sqrt(14))
      t.ok(same(line.start, { 0, 0, 0 }) and same(line.end_, { 1, 2, 3 }) and same(line["end"], { 1, 2, 3 }))
      near3(line:tangent_at(0), { 1 / math.sqrt(14), 2 / math.sqrt(14), 3 / math.sqrt(14) }, 1e-15, "line tangent")
      local quarter = bs.Arc(V_XY, 2, { 0, pi / 2 })
      t.eq(quarter:length(), pi)
      t.ok(quarter.angle == bs.Interval(0, pi / 2))
      near3(quarter.start, { 2, 0, 0 }, 1e-15, "start")
      near3(quarter.end_, { 0, 2, 0 }, 1e-15, "end")
      near3(quarter.mid, { math.sqrt(2), math.sqrt(2), 0 }, 1e-15, "mid")
      -- On the axis the foot is a pick: t = 0, not unique.
      t.ok(unit:closest_point({ 2, 0, 5 }) == bs.CurveFoot(0.0, { 1.0, 0.0, 0.0 }, true), "off the axis")
      local pick = unit:closest_point({ 0, 0, 5 })
      t.ok(is(pick, bs.CurveFoot))
      t.ok(pick == bs.CurveFoot(0.0, { 1.0, 0.0, 0.0 }, false), "on the axis: " .. tostring(pick))
      t.near(unit:distance_to({ 2, 0, 5 }), math.sqrt(26), 1e-12)
      local lo, hi = bs.Line({ 1, 5, 0 }, { 0, 2, 3 }):bounds()
      t.ok(same(lo, { 0, 2, 0 }) and same(hi, { 1, 5, 3 }), "line bounds")
      t.near(bs.Ellipse(V_XY, 3, 1):length(), 13.364893220555258, 13.364893220555258 * 1e-12)
      refused(function() bs.Line({ 0, 0 }, { 1, 1, 1 }) end, "Line: a point is 3 numbers, got 2")
    end)

    t.test("curve constructors and transforms", function()
      local a, b, c = { 1, 0, 0 }, { 0, 1, 0 }, { -1, 0, 0 }
      local circle = bs.Circle.through(a, b, c)
      t.ok(is(circle, bs.Circle))
      local want = sub(V_XY, 1, 12)
      want[13] = 1
      near3(circle:values(), want, 1e-15, "circle through")
      want[14], want[15] = 0, pi
      near3(bs.Arc.through(a, b, c):values(), want, 1e-15, "arc through")
      local arc = bs.Arc.from_start_tangent_end(a, { 0, 1, 0 }, c)
      t.ok(is(arc, bs.Arc))
      near3(arc:values(), want, 1e-15, "arc from start, tangent, end")
      refused(function() bs.Circle.through(a, a, c) end, "circle_through: the points are coincident or collinear")
      refused(function() bs.Arc.from_start_tangent_end(a, { 0, 0, 0 }, c) end,
        "arc_from_start_tangent_end: the tangent is zero or the end lies on the tangent line")
      t.ok(bs.Ellipse.from_circle(bs.Circle(V_XY, 2)) == bs.Ellipse(V_XY, 2, 2))
      t.ok(bs.Circle(V_XY, 1):transform(bs.Transform.scale({ 0, 0, 0 }, 2)) == bs.Circle(V_XY, 2))
      local stretch = bs.Transform.scale_xyz(bs.Frame.xy(), 1, 3, 1)
      refused(function() bs.Circle(V_XY, 1):transform(stretch) end,
        "value_transform: a circle takes only a similarity (use ellipse_from_circle)")
      local e = bs.Ellipse.from_circle(bs.Circle(V_XY, 1)):transform(stretch.rows)
      t.ok(is(e, bs.Ellipse))
      near3({ e.r1, e.r2 }, { 3, 1 }, 1e-15, "stretched radii")
      local moved = bs.Line({ 0, 0, 0 }, { 1, 0, 0 }):transform(bs.Transform.translation({ 0, 0, 2 }))
      t.ok(moved == bs.Line({ 0, 0, 2 }, { 1, 0, 2 }))
    end)

    t.test("values are immutable, compare by kind and array, and index as their array", function()
      local c = bs.Circle(YZX, 2)
      local want = sub(YZX, 1, 12)
      want[13] = 2
      t.ok(same(c:values(), want) and c[13] == 2 and c.radius == 2.0 and c.frame == bs.Frame.of(YZX))
      t.eq(c.kind, "circle")
      t.ok(c == bs.Circle(bs.Frame.of(YZX), 2.0))
      t.ok(c ~= bs.Sphere(YZX, 2), "a circle is not the sphere of the same numbers")
      t.ok(bs.Sphere(YZX, 2) == bs.Sphere(YZX, 2))
      local s = tostring(c)
      t.ok(s:find("^Circle%(frame=Frame%(origin=%(1, 2, 3%)") and s:find("radius=2%)$"), s)
      t.raises(function() c.radius = 3 end, "Circle is immutable: cannot set radius")
      t.raises(function() c.extra = 3 end, "Circle is immutable: cannot set extra")
    end)

    t.test("lines, circles and arcs match Rhino", function()
      local r = vectors("lines, circles and arcs match Rhino")
      if not r then return end
      local ends = nums(r, "line", "ends")
      local line = bs.Line(sub(ends, 1, 3), sub(ends, 4, 6))
      close({ line:length() }, nums(r, "line", "length"), EXACT, "line length")
      close(line:tangent_at(0.5), nums(r, "line", "tangent"), EXACT, "line tangent")
      for k = 0, 4 do
        local n = nums(r, "line_at_" .. k, "point")
        close(line:point_at(n[1]), sub(n, 2, 4), EXACT, "line_at_" .. k)
      end
      for _, cq in ipairs(queries(r, "line")) do
        close(line:closest_point(cq[2]).point, nums(r, cq[1], "closest"), EXACT, cq[1])
      end

      local circle = bs.Circle(nums(r, "circle", "frame"), nums(r, "circle", "radius")[1])
      close({ circle:length() }, nums(r, "circle", "length"), EXACT, "circle length")
      for k = 0, 4 do
        local n = nums(r, "circle_at_" .. k, "point")
        close(circle:point_at(n[1]), sub(n, 2, 4), EXACT, "circle_at_" .. k)
        close(circle:tangent_at(n[1]), sub(n, 5, 7), EXACT, "circle_at_" .. k .. " tangent")
      end
      for _, cq in ipairs(queries(r, "circle")) do
        local case = cq[1]
        local want, foot = nums(r, case, "closest"), circle:closest_point(cq[2])
        t.ok(foot.unique, case)
        close({ foot.t }, { want[1] % (2 * pi) }, EXACT, case)
        close(foot.point, sub(want, 2, 4), EXACT, case)
      end

      local arc = bs.Arc(nums(r, "arc", "frame"), nums(r, "arc", "radius")[1], nums(r, "arc", "angle"))
      close({ arc:length() }, nums(r, "arc", "length"), EXACT, "arc length")
      for k = 0, 3 do
        local n = nums(r, "arc_at_" .. k, "point")
        close(arc:point_at(n[1]), sub(n, 2, 4), EXACT, "arc_at_" .. k)
        close(arc:tangent_at(n[1]), sub(n, 5, 7), EXACT, "arc_at_" .. k .. " tangent")
      end
      for _, cq in ipairs(queries(r, "arc")) do
        local case = cq[1]
        local want, foot = nums(r, case, "closest"), arc:closest_point(cq[2])
        close({ foot.t }, sub(want, 1, 1), EXACT, case)
        close(foot.point, sub(want, 2, 4), EXACT, case)
      end
    end)

    t.test("an edge's curve is its value", function()
      local function key(p)
        local parts = {}
        for i = 1, 3 do
          local s = ("%.9f"):format(p[i])
          if s:match("^%-0%.0+$") then s = s:sub(2) end
          parts[i] = s
        end
        return table.concat(parts, " ")
      end
      local rims = 0
      for _, rim in ipairs(bs.Solid.cylinder(5, 3).edges) do
        if rim.kind == "circle" then
          rims = rims + 1
          local v = rim.curve.value
          t.ok(is(v, bs.Circle), "a rim is a Circle: " .. tostring(v))
          t.near(v.radius, 5, 1e-9)
          local z = v.frame.origin[3]
          t.ok(math.abs(z) < 1e-9 or math.abs(z - 3) < 1e-9, "a rim's height")
        end
      end
      t.eq(rims, 2)
      for _, e in ipairs(bs.Solid.cuboid(2, 4, 6).edges) do
        local v = e.curve.value
        t.ok(is(v, bs.Line), "a box edge is a Line")
        local ends = {}
        for _, seg in ipairs(e.segments) do
          for _, p in ipairs(seg) do ends[key(p)] = true end
        end
        t.ok(ends[key(v.start)] and ends[key(v.end_)], "a line's ends are its edge's")
      end
      local cube = bs.Solid.cuboid(10, 10, 10)
      local upright = {}
      for _, e in ipairs(cube.edges) do
        local d = e.direction
        if d and math.abs(math.abs(d[3]) - 1) < 1e-9 then upright[#upright + 1] = e end
      end
      local rounded = cube:fillet({ upright[1] }, 2.0)
      local arcs = {}
      for _, e in ipairs(rounded.edges) do
        if e.kind == "circle" then arcs[#arcs + 1] = e end
      end
      t.eq(#arcs, 2)
      for _, e in ipairs(arcs) do
        local v = e.curve.value
        t.ok(is(v, bs.Arc), "a fillet's rim is an Arc: " .. tostring(v))
        t.near(v.radius, 2, 1e-9)
        t.near(v.angle.length, pi / 2, 1e-9)
        local vertices = { e.segments[1][1], e.segments[#e.segments][2] }
        local function on_a_vertex(p) return dist(p, vertices[1]) < 1e-9 or dist(p, vertices[2]) < 1e-9 end
        t.ok(on_a_vertex(v.start) and on_a_vertex(v.end_), "the arc ends on its edge's vertices")
      end
      local spline = bs.Solid.extrude(bs.Profile.spline({ { 0, 0 }, { 10, 0 }, { 10, 10 }, { 0, 10 } }, 3, nil, true),
        bs.Frame.xy(), 2)
      local nurbs = 0
      for _, e in ipairs(spline.edges) do
        if e.kind == "nurbs" then
          nurbs = nurbs + 1
          t.eq(e.curve.value, nil)
        end
      end
      t.ok(nurbs > 0, "the spline has nurbs edges")
    end)

    -- ---- surfaces ----

    t.test("a bad surface value is refused by value_check", function()
      refused(function() bs.Cylinder(V_XY, 1, { 2, 1 }) end, "value_check: the height must increase")
      refused(function() bs.Torus(V_XY, 1, 1) end, "value_check: the minor radius must be less than the major")
      refused(function() bs.Cone(V_XY, 1, 0) end, "value_check: the height must be positive")
      refused(function() bs.Sphere(V_XY, 0 / 0) end, "value_check: not finite")
    end)

    t.test("each surface call answers B1's figures", function()
      local sphere = bs.Sphere(V_XY, 2)
      near3(sphere:point_at(0, pi / 2), { 0, 0, 2 }, 1e-15, "sphere point")
      local cyl = bs.Cylinder(V_XY, 1, { -1, 2 })
      t.ok(cyl.height == bs.Interval(-1, 2))
      near3(cyl:normal_at(pi / 2, 0), { 0, 1, 0 }, 1e-15, "cylinder normal")
      near3(bs.Torus(V_XY, 3, 1):point_at(0, 0), { 4, 0, 0 }, 1e-15, "torus point")
      local foot = sphere:closest_point({ 0, 0, 5 })
      t.ok(is(foot, bs.SurfaceFoot) and foot.unique)
      near3({ foot.u, foot.v, foot.point[1], foot.point[2], foot.point[3] }, { 0, pi / 2, 0, 0, 2 }, 1e-15, "foot")
      t.ok(not sphere:closest_point({ 0, 0, 0 }).unique, "the centre is a pick")
      t.near(sphere:distance_to({ 0, 0, 5 }), 3, 1e-12)
      local u, v = cyl:domain()
      t.ok(u == bs.Interval(0, 2 * pi) and v == bs.Interval(-1, 2), "cylinder domain")
      u, v = bs.Cone(V_XY, 1, 2):domain()
      t.ok(u == bs.Interval(0, 2 * pi) and v == bs.Interval(0, 2), "cone domain")
      t.ok(math.abs(sphere:volume() - 32 * pi / 3) < 1e-13 and math.abs(sphere:area() - 16 * pi) < 1e-13)
      t.ok(bs.Torus(V_XY, 3, 1):contains({ 3, 0, 0.5 }) and not sphere:contains({ 0, 0, 2.5 }))
      t.ok(sphere:contains({ 0, 0, 2.5 }, 0.5))
      refused(function() sphere:contains({ 0, 0, 0 }, -1) end,
        "solid_value_contains: the tolerance must be finite and not negative")
      local lo, hi = sphere:bounds()
      t.ok(same(lo, { -2, -2, -2 }) and same(hi, { 2, 2, 2 }), "sphere bounds")
      refused(function() sphere:transform(bs.Transform.scale_xyz(bs.Frame.xy(), 1, 3, 1)) end,
        "value_transform: a sphere takes only a similarity")
      t.ok(sphere:transform(bs.Transform.translation({ 1, 0, 0 })) == bs.Sphere(bs.Frame.xy({ 1, 0, 0 }), 2))
      local sheet = cyl:to_nurbs_sheet()
      t.ok(is(sheet, bs.Solid))
      t.eq(sheet.faces, 1)
    end)

    t.test("each shape becomes a solid of its volume", function()
      for _, sv in ipairs({ { bs.Sphere(V_XY, 2), 32 * pi / 3 }, { bs.Cylinder(V_XY, 1, { -1, 2 }), 3 * pi },
        { bs.Cone(V_XY, 1, 2), 2 * pi / 3 }, { bs.Torus(V_XY, 3, 1), 6 * pi ^ 2 },
        { bs.Cuboid(YZX, { 0, 1 }, { 0, 2 }, { 0, 3 }), 6.0 } }) do
        local shape, volume = sv[1], sv[2]
        local solid = shape:to_solid()
        t.ok(is(solid, bs.Solid))
        t.near(solid:mass(1e-9).volume, volume, volume * 1e-6, tostring(shape))
        t.near(shape:volume(), volume, volume * 1e-12, tostring(shape))
      end
    end)

    t.test("spheres, tori, cylinders and cones match Rhino", function()
      local r = vectors("spheres, tori, cylinders and cones match Rhino")
      if not r then return end
      local sphere = bs.Sphere(nums(r, "sphere", "frame"), nums(r, "sphere", "radius")[1])
      for _, cq in ipairs(queries(r, "sphere")) do
        local case = cq[1]
        local want, foot = nums(r, case, "closest"), sphere:closest_point(cq[2])
        close({ foot.u, foot.v }, { want[1] % (2 * pi), want[2] }, EXACT, case)
        close(foot.point, sub(want, 3, 5), EXACT, case)
      end
      local radii = nums(r, "torus", "radii")
      local torus = bs.Torus(nums(r, "torus", "frame"), radii[1], radii[2])
      for _, cq in ipairs(queries(r, "torus")) do
        local foot = torus:closest_point(cq[2])
        t.ok(foot.unique, cq[1])
        nurbs_foot(cq[1], cq[2], foot.point, nums(r, cq[1], "closest"))
      end
      local cyl = bs.Cylinder(nums(r, "cylinder", "frame"), nums(r, "cylinder", "radius")[1],
        nums(r, "cylinder", "height"))
      for _, cq in ipairs(queries(r, "cylinder")) do
        nurbs_foot(cq[1], cq[2], cyl:closest_point(cq[2]).point, nums(r, cq[1], "closest"))
      end
      local size = nums(r, "cone", "size")
      local cone = bs.Cone(nums(r, "cone", "frame"), size[1], size[2])
      for _, cq in ipairs(queries(r, "cone")) do
        nurbs_foot(cq[1], cq[2], cone:closest_point(cq[2]).point, nums(r, cq[1], "closest"))
      end
    end)

    -- ---- the cuboid ----

    t.test("a cuboid's construction, bounds and around", function()
      local box = bs.Cuboid(YZX, { 0, 1 }, { 0, 2 }, bs.Interval(0, 3))
      t.ok(box.x == bs.Interval(0, 1) and box.y == bs.Interval(0, 2) and box.z == bs.Interval(0, 3))
      -- x along world y (0..1), y along world z (0..2), z along world x (0..3), from (1, 2, 3).
      local lo, hi = box:bounds()
      t.ok(same(lo, { 1, 2, 3 }) and same(hi, { 4, 3, 5 }), "tilted bounds")
      t.ok(bs.Cuboid.from_bounds({ 0, 0, 0 }, { 1, 2, 3 }) == bs.Cuboid(V_XY, { 0, 1 }, { 0, 2 }, { 0, 3 }))
      refused(function() bs.Cuboid.from_bounds({ 0, 0, 0 }, { 1, 0, 3 }) end,
        "cuboid_from_bounds: the bounds must increase along every axis")
      refused(function() bs.Cuboid(V_XY, { 0, 1 }, { 2, 2 }, { 0, 1 }) end, "value_check: the y range must increase")
      local pts = { { 0, 0, 0 }, { 1, 2, 3 }, { 0.5, -1, 0.25 } }
      t.ok(bs.Cuboid.around(bs.Frame.xy(), pts) == bs.Cuboid(V_XY, { 0, 1 }, { -1, 2 }, { 0, 3 }))
      refused(function() bs.Cuboid.around(V_XY, { { 0, 0, 0 }, { 1, 1, 0 } }) end,
        "cuboid_around: the points are flat along an axis of the frame")
      refused(function() bs.Cuboid.around(V_XY, {}) end, "cuboid_around: no points")
    end)

    t.test("each cuboid call answers B1's figures", function()
      local box = bs.Cuboid(V_XY, { 0, 1 }, { 0, 2 }, { 0, 3 })
      t.eq(box:area(), 22.0)
      t.eq(box:volume(), 6.0)
      t.ok(box:contains({ 0.5, 0.5, 0.5 }) and not box:contains({ 1.5, 0.5, 0.5 }, 0.4)
        and box:contains({ 1.5, 0.5, 0.5 }, 0.5))
      local tilted = bs.Cuboid(YZX, { 0, 1 }, { 0, 2 }, { 0, 3 })
      t.ok(same(tilted:closest_point({ 9, 9, 9 }), { 4, 3, 5 }))
      near3(tilted:point_at(0.5, 0.5, 0.5), { 2.5, 2.5, 4 }, 1e-15, "point_at")
      local corners = box:corners()
      t.eq(#corners, 8)
      t.ok(same(corners[1], { 0, 0, 0 }) and same(corners[3], { 1, 2, 0 }) and same(corners[7], { 1, 2, 3 }),
        "corners 0, 2 and 6")
      local moved = box:transform(bs.Transform.translation({ 0, 0, 1 }))
      t.ok(is(moved, bs.Cuboid))
      local lo, hi = moved:bounds()
      t.ok(same(lo, { 0, 0, 1 }) and same(hi, { 1, 2, 4 }), "moved bounds")
    end)

    t.test("boxes match Rhino", function()
      local r = vectors("boxes match Rhino")
      if not r then return end
      local ranges = nums(r, "box", "ranges")
      local box = bs.Cuboid(nums(r, "box", "frame"), sub(ranges, 1, 2), sub(ranges, 3, 4), sub(ranges, 5, 6))
      local corners = nums(r, "box", "corners")
      for k, c in ipairs(box:corners()) do
        close(c, sub(corners, 3 * k - 2, 3 * k), EXACT, "corner " .. (k - 1))
      end
      for k = 0, 3 do
        local n = nums(r, "box_at_" .. k, "point")
        close(box:point_at(n[1], n[2], n[3]), sub(n, 4, 6), EXACT, "box_at_" .. k)
      end
      for _, cq in ipairs(queries(r, "box")) do
        close(box:closest_point(cq[2]), nums(r, cq[1], "closest"), EXACT, cq[1])
      end
    end)

    -- ---- the rectangle, the triangle and the ray (plan B4): Python's TestPlanarValues ----

    local SHEAR = { 1, 0.5, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }

    t.test("a rectangle is a curve with calls of its own", function()
      local r = bs.Rectangle(V_XY, { 1, 4 }, bs.Interval(0, 4))
      t.ok(r.x == bs.Interval(1, 4) and r.y == bs.Interval(0, 4), "the ranges")
      t.ok(same(r.frame.origin, { 0, 0, 0 }) and same(r.frame.z, { 0, 0, 1 }), "the frame")
      t.eq(r.kind, "rectangle")
      t.ok(same(r:point_at(2.25), { 3.25, 4, 0 }) and same(r:point_at(9), { 1, 0, 0 }), "clamped to 4")
      t.ok(same(r:tangent_at(1.5), { 0, 1, 0 }))
      t.eq(r:length(), 14.0)
      t.ok(r:closest_point({ 2, -1, 7 }) == bs.CurveFoot(1 / 3, { 2.0, 0.0, 0.0 }, true), tostring(r:closest_point({ 2, -1, 7 })))
      t.eq(bs.Rectangle(V_XY, { 0, 2 }, { 0, 2 }):closest_point({ 1, 1, 0 }).unique, false, "the centre is a pick")
      local c = r:corners()
      t.ok(#c == 4 and same(c[1], { 1, 0, 0 }) and same(c[2], { 4, 0, 0 }) and same(c[3], { 4, 4, 0 }) and same(c[4], { 1, 4, 0 }),
        "the corners")
      t.eq(r:area(), 12.0)
      t.ok(same(r:closest_point_in({ 2, 1, 5 }), { 2, 1, 0 }) and same(r:closest_point_in({ 2, 1, 5 }, false), { 1, 1, 0 }))
      local lo, hi = r:bounds()
      t.ok(same(lo, { 1, 0, 0 }) and same(hi, { 4, 4, 0 }), "bounds")
      refused(function() bs.Rectangle(V_XY, { 1, 1 }, { 0, 4 }) end, "value_check: the x range must increase")
      local fifteen = { unpack(V_XY) }
      fifteen[13], fifteen[14], fifteen[15] = 1, 4, 0
      refused(function() bs.Rectangle.from_array(fifteen) end, "value_check: a rectangle is 16 numbers, got 15")
      refused(function() r:transform(SHEAR) end,
        "value_transform: a rectangle takes only a map that keeps its sides square (no shear in its plane)")
      t.ok(r:transform(bs.Transform.scale_xyz(V_XY, 2, 3, 1)) == bs.Rectangle(V_XY, { 2, 8 }, { 0, 12 }), "scaled")
      local sheet = r:to_sheet()
      t.eq(sheet.faces, 1)
      t.ok(math.abs(sheet:mass(1e-9).area - 12) <= 1e-9 * 12, "the sheet's area")
      local ring = r:to_nurbs()
      local rd = ring.domain
      t.ok(ring.degree == 1 and ring.is_closed and not ring.is_rational and rd[1] == 0 and rd[2] == 4, "the boundary's curve")
      local rp = ring:point(2.25)
      t.ok(math.abs(rp[1] - 3.25) + math.abs(rp[2] - 4) + math.abs(rp[3]) <= 1e-12, "its parameter is t")
    end)

    t.test("a rectangle's contains takes nil as its effective tolerance and zero as exact", function()
      local r = bs.Rectangle(V_XY, { 1, 4 }, { 0, 4 })   -- diagonal 5: effective 5e-4
      t.eq(r:contains({ 2, 2, 9 }, 0), "inside")
      t.eq(r:contains({ 0, 2, 0 }, 0), "outside")
      t.eq(r:contains({ 1, 2, 0 }, 0), "on")
      local near = { 1 - 4e-4, 2, 0 }
      t.eq(r:contains(near, 0), "outside")
      t.eq(r:contains(near, 1e-3), "on")
      t.eq(r:contains(near), "on")
      t.eq(r:contains(near, 0 / 0), "on")
      t.eq(r:contains({ 1 - 6e-4, 2, 0 }), "outside")
      refused(function() r:contains({ 0, 0, 0 }, -1) end, "rectangle_contains: the tolerance must be finite and not negative")
      local eff = 1e-4 * 4 * math.sqrt(3)
      local ball = bs.Sphere(V_XY, 2)
      t.ok(ball:contains({ 2 + 0.9 * eff, 0, 0 }, 0 / 0) and not ball:contains({ 2 + 0.9 * eff, 0, 0 })
        and not ball:contains({ 2 + 1.1 * eff, 0, 0 }, 0 / 0), "a sphere's contains takes NaN as unset")
    end)

    t.test("a triangle answers its closed forms", function()
      local tri = bs.Triangle({ 0, 0, 0 }, { 4, 0, 0 }, { 0, 3, 0 })
      t.ok(same(tri.a, { 0, 0, 0 }) and same(tri.b, { 4, 0, 0 }) and same(tri.c, { 0, 3, 0 }), "the vertices")
      t.eq(tri:area(), 6.0)
      t.eq(tri:perimeter(), 12.0)
      close(tri:centroid(), { 4 / 3, 1, 0 }, 1e-15, "centroid")
      local cc = tri:circumcircle()
      t.ok(is(cc, bs.Circle))
      close({ cc.frame.origin[1], cc.frame.origin[2], cc.frame.origin[3], cc.radius }, { 2, 1.5, 0, 2.5 }, 1e-15, "circumcircle")
      t.ok(same(tri:point_at(0.5, 0.25, 0.25), { 1, 0.75, 0 }))
      close(tri:barycentric({ 1, 0.75, 5 }), { 0.5, 0.25, 0.25 }, 1e-15, "barycentric")
      t.ok(same(tri:closest_point({ 2, -1, 0 }), { 2, 0, 0 }) and same(tri:closest_point({ 1, 1, 3 }), { 1, 1, 0 }))
      t.eq(tri:distance_to({ 1, 1, 3 }), 3.0)
      t.ok(tri:edge(1) == bs.Line({ 4, 0, 0 }, { 0, 3, 0 }), tostring(tri:edge(1)))
      refused(function() tri:edge(3) end, "triangle_edge: edge 3 is not 0, 1 or 2")
      refused(function() bs.Triangle({ 0, 0, 0 }, { 1, 1, 1 }, { 2, 2, 2 }) end,
        "value_check: the triangle is degenerate (its points are collinear or coincident)")
      refused(function() bs.Triangle.from_array({ 0, 0, 0, 4, 0, 0, 0, 3 }) end, "value_check: a triangle is 9 numbers, got 8")
      t.ok(tri:transform(SHEAR) == bs.Triangle({ 0, 0, 0 }, { 4, 0, 0 }, { 1.5, 3, 0 }), "any affine map")
      t.ok(math.abs(tri:to_sheet():mass(1e-9).area - 6) <= 1e-9 * 6, "the sheet's area")
      t.ok(tri ~= bs.Triangle({ 0, 0, 0 }, { 0, 3, 0 }, { 4, 0, 0 }), "a reordered triangle differs")
      t.ok(tostring(tri):match("^Triangle%(a=") ~= nil, tostring(tri))
      t.ok(not pcall(function() tri.a = { 1, 1, 1 } end), "immutable")
    end)

    t.test("a ray holds to its half-line only in closest_point", function()
      local ray = bs.Ray({ 1, 2, 3 }, { 0, 0, 2 })
      t.ok(same(ray:values(), { 1, 2, 3, 0, 0, 2 }) and same(ray.position, { 1, 2, 3 }) and same(ray.direction, { 0, 0, 2 }), "kept as given")
      t.ok(same(ray:point_at(1.5), { 1, 2, 6 }) and same(ray:point_at(-1), { 1, 2, 1 }))
      t.ok(ray:closest_point({ 5, 2, 7 }) == bs.CurveFoot(2.0, { 1.0, 2.0, 7.0 }, true), tostring(ray:closest_point({ 5, 2, 7 })))
      t.ok(ray:closest_point({ 5, 2, -7 }) == bs.CurveFoot(0.0, { 1.0, 2.0, 3.0 }, true), "behind: the start")
      t.ok(math.abs(ray:distance_to({ 5, 2, -7 }) - math.sqrt(116)) <= 1e-12)
      refused(function() ray:bounds() end, "value_bounds: a ray has no box (it is unbounded)")
      refused(function() bs.Ray({ 0, 0, 0 }, { 0, 0, 0 }) end, "value_check: the ray's direction is zero")
      refused(function() bs.Ray.from_array({ 0, 0, 0, 1, 0, 0, 0 }) end, "value_check: a ray is 6 numbers, got 7")
      t.ok(ray:transform(bs.Transform.scale_xyz(V_XY, 1, 1, 3)) == bs.Ray({ 1, 2, 9 }, { 0, 0, 6 }), "scaled")
    end)

    t.test("rectangles, triangles and rays match Rhino", function()
      local r = vectors("rectangles, triangles and rays match Rhino")
      if not r then return end
      local ranges = nums(r, "rectangle", "ranges")
      local rect = bs.Rectangle(nums(r, "rectangle", "frame"), sub(ranges, 1, 2), sub(ranges, 3, 4))
      local corners = nums(r, "rectangle", "corners")
      for k, c in ipairs(rect:corners()) do close(c, sub(corners, 3 * k - 2, 3 * k), EXACT, "corner " .. (k - 1)) end
      close({ rect:area(), rect:length() }, { nums(r, "rectangle", "area")[1], nums(r, "rectangle", "circumference")[1] }, EXACT, "area")
      for k = 0, 8 do
        local n = nums(r, "rectangle_at_" .. k, "point")
        close(rect:point_at(n[1]), sub(n, 2, 4), EXACT, "rectangle_at_" .. k)
      end
      local said = { Inside = "inside", Outside = "outside", Coincident = "on" }
      for _, shape in ipairs({ "rectangle", "rectangle_in" }) do
        for _, cq in ipairs(queries(r, shape)) do
          close(rect:closest_point(cq[2]).point, nums(r, cq[1], "boundary"), EXACT, cq[1])
          close(rect:closest_point_in(cq[2], true), nums(r, cq[1], "filled"), EXACT, cq[1])
          t.eq(rect:contains(cq[2], 0), said[words(r, cq[1], "contains")[1]], cq[1])
        end
      end
      local p = nums(r, "triangle", "points")
      local tri = bs.Triangle(sub(p, 1, 3), sub(p, 4, 6), sub(p, 7, 9))
      close({ tri:area(), tri:perimeter() }, { nums(r, "triangle", "area")[1], nums(r, "triangle", "perimeter")[1] }, EXACT, "triangle")
      close(tri:centroid(), nums(r, "triangle", "centroid"), EXACT, "centroid")
      close(tri:circumcircle():values(), nums(r, "triangle", "circumcircle"), EXACT, "circumcircle")
      for _, shape in ipairs({ "triangle", "triangle_in" }) do
        for _, cq in ipairs(queries(r, shape)) do
          local w = tri:barycentric(cq[2])
          close({ w[2], w[3] }, sub(nums(r, cq[1], "barycentric"), 1, 2), EXACT, cq[1])
          close(tri:point_at(w[1], w[2], w[3]), nums(r, cq[1], "projected"), EXACT, cq[1])
          if math.min(w[1], w[2], w[3]) < 0 then close(tri:closest_point(cq[2]), nums(r, cq[1], "boundary"), EXACT, cq[1]) end
        end
      end
      local rn = nums(r, "ray", "ray")
      local ray = bs.Ray(sub(rn, 1, 3), sub(rn, 4, 6))
      for k = 0, 3 do
        local n = nums(r, "ray_at_" .. k, "point")
        close(ray:point_at(n[1]), sub(n, 2, 4), EXACT, "ray_at_" .. k)
      end
    end)
  end
end
