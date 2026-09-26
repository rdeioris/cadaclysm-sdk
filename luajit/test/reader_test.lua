-- The reader wrapper, against the ACIS crate's Fusion assembly fixture (three coloured
-- bodies placed in one assembly) and a Rhino fixture, when the repository has them.
return function(t)
  local cadaclysm = require("cadaclysm")
  local ffi = require("ffi")

  local ASSEMBLY = "crates/cadaclysm-acis/tests/fixtures/fusion/assembly.stp"
  local function assembly() return t.fixture(ASSEMBLY) end

  t.test("version and licence text", function()
    t.ok(cadaclysm.version():match("^%d+%.%d+%.%d+"), cadaclysm.version())
    t.ok(cadaclysm.build_date():match("^%d%d%d%d%-%d%d%-%d%d$"), cadaclysm.build_date())
    t.ok(cadaclysm.license_info() ~= "")
    t.ok(type(cadaclysm.license_notice_count()) == "number")
    t.ok(cadaclysm.library_path():match("cadaclysm_capi"), cadaclysm.library_path())
  end)

  t.test("mesh formats include stl and glb, with labels", function()
    local names, labels = {}, {}
    for _, f in ipairs(cadaclysm.mesh_formats()) do names[f[1]] = f[2]; labels[f[1]] = f[3] end
    t.eq(names.stl, "stl")
    t.eq(names.glb, "glb")
    t.eq(names["stl-ascii"], "stl")
    t.eq(labels.stl, "STL (binary)")
    t.eq(labels["stl-ascii"], "STL (ASCII)")
  end)

  t.test("formats list every reader with its extensions", function()
    local found = {}
    for _, f in ipairs(cadaclysm.formats()) do found[f[1]] = f[2] end
    t.eq(found.IGES[1], "iges")
    t.eq(found.IGES[2], "igs")
    t.eq(found.IFC[1], "ifc")
    t.ok(type(cadaclysm.pick_save) == "function")
  end)

  t.test("geometry diagnostics and forget_meshes", function()
    local scene = cadaclysm.open(t.fixture("samples/cube.scad"))
    t.eq(#scene.geometry_diagnostics, 0)
    t.eq(scene.nodes[1].mesh.index_count, 36)
    scene:forget_meshes()
    t.eq(scene.nodes[1].mesh.index_count, 36)
    scene:close()
    t.raises(function() scene:forget_meshes() end, "closed")
  end)

  t.test("LOD levels and Béziers", function()
    t.eq(cadaclysm.lod_levels(), 3)
    local scene = cadaclysm.open(t.fixture("samples/cube.scad"))
    local node = scene.nodes[1]
    t.eq(node:mesh_lod(0).index_count, node.mesh.index_count)
    t.eq(node:mesh_lod(1).index_count, 9)
    t.eq(node:mesh_lod(1).vertex_count, node.mesh.vertex_count)
    t.eq(node:mesh_lod(4).index_count, 0)
    t.eq(node:lod_error(0), 0)
    t.ok(node:lod_error(1) > 0)
    local b = node.edge_beziers
    t.eq(b.count, 12)
    t.ok(b.points ~= nil and b.weights ~= nil)
    t.eq(node.curve_beziers.count, 0)
    t.eq(node.isocurve_beziers.count, 12)
    local kept = b:copy()
    t.eq(#kept.points, 12 * 12)
    t.eq(#kept.weights, 12 * 4)
    scene:close()
  end)

  t.test("mesh64/bounds64/beziers64 agree with their f32 twins on small coordinates, and a forget frees mesh64's pointers but not mesh's", function()
    local scene = cadaclysm.open(t.fixture("samples/cube.scad"))
    local node = scene.nodes[1]
    local mesh, mesh64 = node.mesh, node.mesh64
    t.eq(getmetatable(mesh64), cadaclysm.Mesh64)
    t.eq(mesh64.vertex_count, mesh.vertex_count)
    t.eq(mesh64.index_count, mesh.index_count)
    t.eq(tonumber(ffi.cast("float", mesh64.positions[0])), mesh.positions[0])
    for i = 0, mesh.index_count - 1 do t.eq(mesh64.indices[i], mesh.indices[i]) end
    t.eq(mesh64.triangle_count, 12)
    t.ok(not mesh64.is_empty)
    local b, b64 = scene.bounds, scene.bounds64
    for i = 1, 3 do t.eq(b64.max[i], b.max[i]) end
    local nb, nb64 = node.bounds, node.bounds64
    for i = 1, 3 do t.eq(nb64.max[i], nb.max[i]) end
    local bz, bz64 = node.edge_beziers, node.edge_beziers64
    t.eq(getmetatable(bz64), cadaclysm.Beziers64)
    t.eq(bz64.count, bz.count)
    t.eq(tonumber(ffi.cast("float", bz64.points[0])), bz.points[0])
    t.eq(node.curve_beziers64.count, node.curve_beziers.count)
    t.eq(node.isocurve_beziers64.count, node.isocurve_beziers.count)
    local kept64 = bz64:copy()
    t.eq(#kept64.points, bz64.count * 12)
    t.eq(#kept64.weights, bz64.count * 4)
    -- mesh64's pointers borrow the document's own mesh, which a forget frees;
    -- mesh's positions are the library's own narrowed copy and survive it.
    scene:forget_meshes()
    t.eq(mesh.index_count, 36)
    local again = node.mesh64
    t.eq(again.vertex_count, mesh64.vertex_count)
    scene:close()
  end)

  t.test("mesh64/bounds64 keep a coordinate far from the origin that mesh()/bounds cannot", function()
    local scad = t.tmp("far64.scad")
    local f = assert(io.open(scad, "w"))
    f:write("translate([1000000.123456789, -2600000.987654321, 450.5]) cube(1);")
    f:close()
    local scene = cadaclysm.open(scad)
    local node = scene.nodes[1]
    local mesh64 = node.mesh64
    t.ok(not mesh64.is_empty)
    local kept_y, saw_unfloatable = nil, false
    for i = 0, mesh64.vertex_count - 1 do
      local y = mesh64.positions[3 * i + 1]
      if math.abs(y - -2600000.987654321) < 1e-6 then kept_y = y end
      if math.abs(tonumber(ffi.cast("float", y)) - y) > 1e-3 then saw_unfloatable = true end
    end
    t.ok(kept_y ~= nil, "mesh64 lost the far low-y corner")
    t.ok(saw_unfloatable, "mesh64 carries no coordinate float cannot hold, so this test cannot tell mesh64 from mesh widened")
    local b64, b32 = node.bounds64, node.bounds
    t.near(b64.min[2], -2600000.987654321, 1e-6, "bounds64 lost the far corner")
    t.ok(math.abs(b64.min[2] - b32.min[2]) > 1e-3, "bounds64 agrees with bounds narrowed to the bit, so it is not exact where float is not")
    t.near(scene.bounds64.min[2], -2600000.987654321, 1e-6, "the scene's bounds64 lost the far corner")
    scene:close()
  end)

  t.test("Convention.parse", function()
    local C = cadaclysm.Convention
    t.eq(C.parse("native"), C.NATIVE)
    t.eq(C.parse("Y-UP"), C.Y_UP)
    t.eq(C.parse("unreal+file-units"), bit.bor(C.UNREAL, cadaclysm.FILE_UNITS))
    local err = t.raises(function() C.parse("sideways") end, "no convention called 'sideways'")
    t.eq(getmetatable(err), cadaclysm.CadaclysmError)
    t.raises(function() C.parse("unity+inches") end, "no convention flag")
  end)

  t.test("decimal text as Rust Display", function()
    local d = cadaclysm._decimal_text
    t.eq(d(1), "1")
    t.eq(d(0.1), "0.1")
    t.eq(d(1e-05), "0.00001")
    t.eq(d(1e16), "10000000000000000")
    t.eq(d(-2.5), "-2.5")
    t.eq(d(1 / 0), "inf")
    t.eq(d(-1 / 0), "-inf")
    t.eq(d(0 / 0), "NaN")
    t.eq(d(123.456), "123.456")
  end)

  t.test("open refuses what is not there", function()
    local err = t.raises(function() cadaclysm.open("no/such/file.stp") end, "no such file")
    t.eq(getmetatable(err), cadaclysm.CadaclysmError)
    t.raises(function() cadaclysm.open_memory("not a step file", "step") end, "<memory>")
    t.raises(function() cadaclysm.open_memory("not a step file", "step", nil, "bytes.stp") end, "bytes.stp")
  end)

  t.test("tree, labels and depth", function()
    local path = assembly()
    if not path then return end
    local scene = cadaclysm.open(path)
    t.eq(scene.node_count, 4)
    t.eq(#scene.nodes, 4)
    t.eq(#scene.roots, 1)
    t.eq(scene.path, path)
    t.eq(scene.convention, cadaclysm.Convention.NATIVE)
    t.eq(scene.schema_path, nil)
    t.ok(scene.schema:match("AUTOMOTIVE_DESIGN"), scene.schema)
    t.eq(scene.substituted, false)
    t.near(scene.metres_per_unit, 0.01, 1e-12)
    local labels = {}
    for n in scene:walk() do labels[#labels + 1] = ("  "):rep(n.depth) .. n.label end
    t.eq(table.concat(labels, "|"), "(Unsaved)|  Bracket body|  Pin body|  Cap body")
    local root = scene.roots[1]
    t.eq(root.parent, nil)
    t.eq(#root.children, 3)
    t.eq(root.children[1].parent, root)
    t.eq(root.can_mesh, false)
    t.eq(root.children[1].can_mesh, true)
    t.eq(root.children[1].generator, "brep")
    t.eq(root.children[1].select_as, root.children[1])
    t.eq(root.children[1].instance_of, nil)
    t.eq(root.visible_now, true)
    t.eq(root.locked, false)
    t.raises(function() scene:node(99) end, "node 99 of 4")
    scene:close()
  end)

  t.test("placements, transforms and meshes", function()
    local path = assembly()
    if not path then return end
    local scene = cadaclysm.open(path)
    local placements = scene.placements
    t.eq(#placements, 3)
    local triangles = 0
    for _, p in ipairs(placements) do
      local m = p.geometry.mesh
      t.ok(not m.is_empty)
      t.ok(m.normals ~= nil)
      triangles = triangles + m.triangle_count
      local top = 0
      for i = 0, m.index_count - 1 do top = math.max(top, m.indices[i]) end
      t.ok(top < m.vertex_count, "indices in range")
      local raw, rows = p.raw_transform, p.transform
      t.eq(#raw, 16)
      t.eq(raw[16], 1)
      for r = 1, 4 do
        for c = 1, 4 do t.eq(rows[r][c], raw[(c - 1) * 4 + r], "row-major transform") end
      end
      t.eq(p.select, p.geometry)
    end
    t.eq(triangles, 542)
    -- The second body sits 8 along x, the third 8 along y (column-major offset).
    t.eq(placements[2].raw_transform[13], 8)
    t.eq(placements[2].transform[1][4], 8)
    t.eq(placements[3].transform[2][4], 8)
    local b = scene.bounds
    t.ok(not b.is_empty)
    t.near(b.size[1], 9.366, 1e-3)
    t.near(b.size[3], 5, 1e-6)
    t.eq(#b.centre, 3)
    scene:close()
  end)

  t.test("colour, attributes and their text", function()
    local path = assembly()
    if not path then return end
    local scene = cadaclysm.open(path)
    local bracket = scene.roots[1].children[1]
    local rgba = bracket.colour
    t.ok(rgba and #rgba == 4, "the bracket is painted")
    t.eq(scene.roots[1].colour, nil)
    local total = 0
    for _, n in ipairs(scene.nodes) do
      for _, a in ipairs(n.attributes) do
        total = total + 1
        t.ok(type(a.name) == "string")
        t.ok(a.kind >= cadaclysm.ValueKind.NONE and a.kind <= cadaclysm.ValueKind.REFERENCE)
        t.ok(type(a.text) == "string")
      end
    end
    t.eq(total, 8)
    scene:close()
  end)

  t.test("edges, segments and copies", function()
    local path = assembly()
    if not path then return end
    local scene = cadaclysm.open(path)
    local pin = scene.roots[1].children[2]
    local edges = pin.edges
    t.ok(not edges.is_empty)
    local idx, n = edges:segment_indices()
    local expected = 0
    for _, count in edges:runs() do expected = expected + 2 * (count - 1) end
    t.eq(n, expected)
    local pts, m = edges:segments()
    t.eq(m, n)
    t.eq(pts[0], edges.positions[idx[0] * 3])
    local copy = pin.mesh:copy()
    scene:close()
    -- The copy is the caller's own memory: still readable after the scene is gone.
    t.ok(copy.positions[0] == copy.positions[0])
    t.ok(copy.triangle_count > 0)
  end)

  t.test("surfaces and the brep", function()
    local path = assembly()
    if not path then return end
    local scene = cadaclysm.open(path)
    local bracket = scene.roots[1].children[1]
    local s = bracket.surfaces
    t.ok(#s.faces >= 6, tostring(s))
    local planes = 0
    for _, f in ipairs(s.faces) do
      if f.kind == 0 then planes = planes + 1 end
      t.ok(#f.loops >= 1)
      t.ok(f.loops[1].count >= 3)
      t.eq(#f.domain, 4)
    end
    t.ok(planes >= 6)
    t.eq(#scene.surface_matrix, 4)
    local brep = bracket.brep
    t.ok(brep ~= nil)
    t.ok(cadaclysm.Brep.layout_id() ~= "")
    local man = brep.manifold
    t.eq(man.is_manifold, true)
    t.eq(man.is_closed, true)
    t.eq(man.boundary_edges, 0)
    scene:close()
    -- The brep outlives the scene; releasing is idempotent and then refused.
    t.eq(brep.manifold.faces, man.faces)
    brep:release()
    brep:release()
    t.raises(function() return brep.pointer end, "released")
  end)

  t.test("query", function()
    local path = assembly()
    if not path then return end
    local scene = cadaclysm.open(path)
    t.eq(#scene:query('name != "" or name == ""'), 4)
    t.eq(#scene:query('name == "Pin body"'), 1)
    t.eq(#scene:query('name == "nothing"'), 0)
    t.raises(function() scene:query("name ==") end)
    scene:close()
  end)

  t.test("conventions change the space", function()
    local path = assembly()
    if not path then return end
    local native = cadaclysm.open(path)
    local yup = cadaclysm.open(path, nil, "y-up")
    t.eq(yup.convention, cadaclysm.Convention.Y_UP)
    -- Metres and Y up: the assembly's 5-unit (cm) height becomes 0.05 along y.
    t.near(yup.bounds.size[2], native.bounds.size[3] * 0.01, 1e-6)
    local kept = cadaclysm.open(path, nil, bit.bor(cadaclysm.Convention.Y_UP, cadaclysm.FILE_UNITS))
    t.near(kept.bounds.size[2], native.bounds.size[3], 1e-4)
    native:close(); yup:close(); kept:close()
  end)

  t.test("realize_all and its counters", function()
    local path = assembly()
    if not path then return end
    local scene = cadaclysm.open(path)
    t.eq(scene.realize_total, 0)
    local built = scene:realize_all()
    t.ok(built >= 3, "built " .. built)
    t.eq(scene.realized, scene.realize_total)
    scene:cancel()
    t.eq(scene:realize_all(), 0)
    scene:close()
  end)

  t.test("save_mesh and save", function()
    local path = assembly()
    if not path then return end
    local scene = cadaclysm.open(path)
    local stl, glb = t.tmp("pin.stl"), t.tmp("assembly.glb")
    scene.roots[1].children[2]:save_mesh(stl)
    scene:save(glb)
    for _, p in ipairs({ stl, glb }) do
      local f = assert(io.open(p, "rb"))
      t.ok(#f:read("*a") > 100, p)
      f:close()
    end
    t.raises(function() scene.roots[1]:save_mesh(t.tmp("root.stl")) end)
    scene:close()
  end)

  t.test("svg: scene and node text, a file, options reaching the camera and page, fov=200 refused", function()
    local scene = cadaclysm.open(t.fixture("samples/cube.scad"))
    local text = scene:svg_text()
    t.ok(text:sub(1, 4) == "<svg", text:sub(1, 40))
    t.ok(text:find("<path", 1, true), "no <path in the scene's svg text")

    local path = t.tmp("cube.svg")
    scene:svg(path)
    local f = assert(io.open(path, "rb"))
    local written = f:read("*a")
    f:close()
    t.ok(#written > 0, "svg wrote an empty file")
    t.eq(written:sub(1, 4), "<svg")

    local node_text = scene.roots[1]:svg_text()
    t.ok(node_text:sub(1, 4) == "<svg" and node_text:find("<path", 1, true), "node svg_text")

    -- A view, an explicit up and a coloured background all reach the camera and page.
    local front, top = scene:svg_text({ view = "front" }), scene:svg_text({ view = "top" })
    t.ok(front ~= top, "front and top read the same")
    local z_up, y_up = scene:svg_text({ up = "z" }), scene:svg_text({ up = "y" })
    t.ok(z_up ~= y_up, "z-up and y-up read the same")
    local painted = scene:svg_text({ background = "#ff0000" })
    t.ok(painted:find('fill="#ff0000"', 1, true), painted:sub(1, 300))

    t.raises(function() scene:svg_text({ fov = 200 }) end, "fov")
    t.raises(function() scene.roots[1]:svg_text({ fov = 200 }) end, "fov")
    t.raises(function() scene:svg_text({ margin = -1 }) end)
    scene:close()
  end)

  t.test("open_memory reads the same tree", function()
    local path = assembly()
    if not path then return end
    local f = assert(io.open(path, "rb"))
    local bytes = f:read("*a")
    f:close()
    local scene = cadaclysm.open_memory(bytes, ".stp", nil, "assembly.stp")
    t.eq(scene.path, "assembly.stp")
    t.eq(scene.node_count, 4)
    scene:close()
  end)

  t.test("declared schema", function()
    local path = assembly()
    if not path then return end
    t.ok(cadaclysm.declared_schema(path):match("^AUTOMOTIVE_DESIGN"), cadaclysm.declared_schema(path))
    t.eq(cadaclysm.declared_schema("no/such/file"), "")
    t.eq(select(1, cadaclysm.resolve_schema(path, nil)), nil)
  end)

  t.test("a closed scene refuses, and the collector frees what is dropped", function()
    local path = assembly()
    if not path then return end
    local scene = cadaclysm.open(path)
    local keep = scene.nodes[1]
    t.eq(scene.closed, false)
    scene:close()
    scene:close()
    t.eq(scene.closed, true)
    t.raises(function() return keep.name end, "closed")
    t.ok(tostring(scene):match("closed"))
    for _ = 1, 25 do
      local s = cadaclysm.open(path)
      local _ = s.nodes[2].mesh
    end
    collectgarbage()
    collectgarbage()
  end)

  t.test("a Rhino block: one geometry, several placements", function()
    local path = t.fixture("crates/cadaclysm-acis/tests/fixtures/rhino/block-instances.3dm")
    if not path then return end
    local scene = cadaclysm.open(path)
    local placements, shared = scene.placements, {}
    for _, p in ipairs(placements) do
      local g = p.geometry.index
      shared[g] = (shared[g] or 0) + 1
    end
    local most = 0
    for _, n in pairs(shared) do most = math.max(most, n) end
    t.ok(most >= 2, "a block drawn more than once: " .. #placements .. " placements")
    scene:close()
  end)

  t.test("collision body and hull", function()
    local scene = cadaclysm.open(t.fixture("samples/cube.scad"))
    local fit = scene.nodes[1]:collision()
    t.ok(fit ~= nil)
    t.eq(fit.error, 0)
    t.eq(#fit.frame, 16)
    t.eq(#fit.half_extent, 3)
    t.eq(fit.hull_vertex_count, 8)
    t.ok(fit.shape_name == "box" or fit.shape_name == "hull", fit.shape_name)
    local hull = scene.nodes[1]:collision_hull()
    t.eq(hull.vertex_count, 8)
    t.eq(hull.index_count, 36)
    t.ok(hull.positions ~= nil)
    scene:close()
  end)

  t.test("meshlets", function()
    local scene = cadaclysm.open(t.fixture("samples/cube.scad"))
    local mesh = scene.nodes[1].mesh
    local m = cadaclysm.Meshlets.build(mesh.positions, mesh.normals, mesh.indices, mesh.vertex_count, mesh.index_count, 124, 64)
    t.eq(m.count, 1)
    t.eq(m:triangle_count(0), 12)
    t.eq(m:vertex_count(0), 36)
    t.eq(m:level(0), 0)
    local one = m:meshlet(0)
    t.eq(one.triangle_count, 12)
    t.eq(#one.positions, 36 * 3)
    t.eq(#one.indices, 36)
    t.eq(#one.children, 0)
    m:free()
    t.eq(m.freed, true)
    m:free()
    t.raises(function() return m.count end, "freed")
    t.raises(function() cadaclysm.Meshlets.build(mesh.positions, nil, mesh.indices, mesh.vertex_count, mesh.index_count, 0, 64) end, "max_triangles")
    t.raises(function() cadaclysm.Meshlets.build({ 0, 0, 0 }, nil, { 0, 0, 0 }, 2, 3, 124, 64) end, "vertex_count")
    scene:close()
  end)

  t.test("the surface path: outlines, picks and a proxy without meshing", function()
    local path = assembly()
    if not path then return end
    local scene = cadaclysm.open(path)
    local bracket, pin = scene.nodes[2], scene.nodes[3]
    t.eq(bracket.is_meshed, false)
    t.eq(bracket.triangle_estimate, 18)
    t.eq(pin.triangle_estimate, 480)
    t.eq(bracket.surface_edges.polyline_count, 12)
    t.eq(bracket.surface_edges.vertex_count, 24)
    t.eq(bracket.surface_isocurves.polyline_count, 0)
    t.eq(pin.surface_isocurves.polyline_count, 3)
    local proxy = bracket:surface_proxy_mesh(4)
    t.eq(proxy.vertex_count, 150)
    t.eq(proxy.index_count, 576)
    local hit = bracket:surface_pick({ 2, 1.5, 1002 }, { 2, 1.5, -998 })
    t.near(hit[1], 2, 1e-9); t.near(hit[2], 1.5, 1e-9); t.near(hit[3], 2, 1e-9)
    t.eq(bracket:surface_pick({ 1e6, 1.5, 1002 }, { 1e6, 1.5, -998 }), nil)
    t.eq(bracket.is_meshed, false)
    t.eq(bracket:bounds_placed().max[1], 4)
    t.eq(bracket:bounds_placed({ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }).max[3], 2)
    -- bounds_placed64: the same identity placement agrees with bounds_placed exactly
    -- (the bracket's corners are small coordinates).
    t.eq(bracket:bounds_placed64().max[1], bracket:bounds_placed().max[1])
    t.eq(bracket:bounds_placed64({ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }).max[3],
      bracket:bounds_placed({ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }).max[3])
    t.raises(function() bracket:bounds_placed64({ 1, 2, 3 }) end, "bounds_placed64: a placement is 16 numbers")
    t.eq(scene:realize_meshes(), 0)
    t.eq(bracket.is_meshed, false)
    t.eq(scene:realize_meshes(false), 3)
    t.eq(bracket.is_meshed, true)
    scene:close()
  end)

  t.test("surface_edge_beziers: an extrusion's exact edges, a B-rep's none", function()
    local path = t.fixture("crates/cadaclysm-acis/tests/fixtures/rhino/extrusion-objects.3dm")
    local brep = assembly()
    if not path or not brep then return end
    -- Both conventions: UNREAL goes through the decorator that maps every getter into the
    -- caller's space, which must forward this answer rather than fall back to the trims.
    for _, convention in ipairs({ cadaclysm.Convention.NATIVE, cadaclysm.Convention.UNREAL }) do
      local scene = cadaclysm.open(path, nil, convention)
      local extrusions = 0
      for node in scene:walk() do
        if node.can_mesh and node.surface_edges.polyline_count > 0 then
          extrusions = extrusions + 1
          local exact = node.surface_edge_beziers
          t.ok(exact.count > 0, convention .. ": an extrusion's exact edges are free")
          t.eq(node.is_meshed, false)
          t.eq(exact.count, node.edge_beziers.count)
        end
      end
      t.ok(extrusions > 0, "the fixture is here for its extrusion objects")
      scene:close()
    end
    -- A B-rep's exact edges come out of the mesher, so it offers none and stays unmeshed.
    local scene = cadaclysm.open(brep)
    local bracket = scene.nodes[2]
    t.eq(bracket.surface_edge_beziers.count, 0)
    t.eq(bracket.is_meshed, false)
    scene:close()
  end)

  -- A quarter turn about z then 100 along x, as the sixteen column-major doubles
  -- `fem_mesh` takes (the order `bounds_placed` takes too): (x, y, z) -> (100 - y, x, z).
  local TURNED = { 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 100, 0, 0, 1 }
  local function turned(x, y, z) return 100 - y, x, z end

  -- Which count feeds which entry point -- the census *wiring*, which nothing else pins. Every
  -- other FEM test proves a row is extracted correctly; none proves `open_edges` reads
  -- `_open_edge_count` rows through `cadaclysm_fem_mesh_open_edge` rather than the folded count
  -- or the folded call.
  --
  -- `samples/open-sheet.scad` is the only body in this repository where both censuses are
  -- non-empty and of different lengths: the B-rep path computes no census unless the topology is
  -- closed (the documented "not asked" pair) and every closed body has none, while the mesh path
  -- always computes one -- so a `polyhedron` with a flap over one of its own directed edges is
  -- the way in. Six cracks, one fold, and the fold is not the first crack.
  --
  -- Catches: `open_edges` wired to the folded count (1 row where 6 belong), to the folded call
  -- (row 1 of a one-row table cannot be read at all, so it raises), or both consistently (the
  -- contents then disagree).
  t.test("a FEM census reads its own count through its own entry point", function()
    local scene = cadaclysm.open(t.fixture("samples/open-sheet.scad"))
    local mesh = scene.nodes[1]:fem_mesh()
    t.eq(mesh.node_count, 5)
    t.eq(mesh.triangle_count, 3)
    t.eq(mesh.from_mesh, true)
    t.eq(mesh.watertight, false)
    local cracks, folds = mesh.open_edges, mesh.folded_edges
    t.eq(#cracks, 6, "the sheet and its flap leave six boundary edges")
    t.eq(#folds, 1, "the flap shares one directed edge with the sheet")
    t.eq(folds[1][1], 2)
    t.eq(folds[1][2], 0)
    t.eq(folds[1][3], cadaclysm.NONE, "a mesh-only body's rows name no brep edge")
    t.eq(cracks[1][1], 1)
    t.eq(cracks[1][2], 2)
    mesh:free()
    scene:close()
  end)

  t.test("a node's FEM mesh: the mesh-only cube's arrays, census, quality and .msh text", function()
    local scene = cadaclysm.open(t.fixture("samples/cube.scad"))
    local mesh = scene.nodes[1]:fem_mesh()
    t.eq(getmetatable(mesh), cadaclysm.FemMesh)
    t.eq(mesh.node_count, 8)
    t.eq(mesh.triangle_count, 12)
    t.eq(mesh.face_count, 1)
    t.eq(mesh.from_mesh, true, "cube.scad is a CSG body with no brep, so the mesh is the scene's own")
    t.eq(mesh.watertight, true)
    t.eq(#mesh.edges, 0, "a from_mesh body has no brep edges at all")
    t.eq(#mesh.vertices, 0)
    t.eq(#mesh.open_edges, 0)
    t.eq(#mesh.folded_edges, 0)
    t.near(mesh.min_angle, 45, 1e-9)
    t.near(mesh.longest_edge, 28.284271247461902, 1e-9)
    t.eq(mesh.worst_triangle, 0)
    -- The five arrays are the library's own memory, lent as pointers with their counts
    -- beside them -- as a Mesh's are, and 0-based for the same reason.
    t.ok(mesh.nodes ~= nil and mesh.triangles ~= nil)
    local lo, hi = math.huge, -math.huge
    for i = 0, mesh.node_count * 3 - 1 do
      lo, hi = math.min(lo, mesh.nodes[i]), math.max(hi, mesh.nodes[i])
    end
    t.eq(lo, 0); t.eq(hi, 20)
    for i = 0, mesh.triangle_count * 3 - 1 do
      t.ok(mesh.triangles[i] < mesh.node_count, "a triangle index past the nodes")
    end
    for i = 0, mesh.triangle_count - 1 do
      t.ok(mesh.triangle_face[i] < mesh.face_count, "a triangle_face past the faces")
    end
    for i = 0, mesh.node_count - 1 do
      -- One face and every node on it: this is what tells node_kind from node_entity
      -- if the two were ever lent from one pointer.
      t.eq(mesh.node_kind[i], 2, "every node of a from_mesh body lies on a face")
      t.eq(mesh.node_entity[i], 0, "and on face 0, the only one")
    end
    -- Gmsh 4.1 ASCII. The library's text is a borrowed slot on this handle, copied out
    -- on the way, so a second ask reads the same bytes rather than a freed pointer.
    local msh = mesh:msh_text()
    t.eq(msh:sub(1, 11), "$MeshFormat")
    t.ok(msh:find("4.1 0 8", 1, true), msh:sub(1, 40))
    t.eq(#mesh:msh_text(), #msh, "a second msh_text read a different length")
    local path = t.tmp("cube-fem.msh")
    mesh:save_msh(path)
    local f = assert(io.open(path, "rb"))
    local written = f:read("*a")
    f:close()
    t.ok(#written >= #msh / 2, ("save_msh wrote %d bytes where msh_text is %d"):format(#written, #msh))
    -- Freeing is idempotent, and every call that takes the handle refuses afterwards.
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
    }
    t.eq(#calls, 6, "a call that takes the handle was added without being swept here")
    for _, call in ipairs(calls) do
      local err = t.raises(call, "fem mesh: freed")
      t.eq(getmetatable(err), cadaclysm.CadaclysmError)
    end
    -- And what is *not* refused, which this wrapper documents rather than enforces: the
    -- arrays and the summary are plain fields filled when the mesh was built, so they
    -- read on after the free -- the numbers still true, the pointers dangling. Nothing
    -- here dereferences one; that read was measured outside the suite.
    t.eq(mesh.node_count, 8, "the counts are Lua numbers of our own and outlive the handle")
    t.ok(mesh.nodes ~= nil, "the pointer field is still there, and now points at freed memory")
    scene:close()
  end)

  t.test("fem_mesh validates neither tolerance nor max_size on the mesh-only path", function()
    local scene = cadaclysm.open(t.fixture("samples/cube.scad"))
    local node = scene.nodes[1]
    local nan, inf = 0 / 0, math.huge
    -- `fem_mesh_of_mesh` takes no FemOptions at all, so a body with no brep comes back
    -- whatever these say, where the brep path refuses each. A wrapper that checked
    -- either field itself would pass every other test here and be wrong.
    for _, pair in ipairs({ { 0, 0 }, { -1, 0 }, { nan, 0 }, { 0.01, -1 }, { 0.01, nan }, { 0.01, inf } }) do
      local mesh = node:fem_mesh(pair[1], pair[2])
      t.eq(mesh.node_count, 8, ("tolerance %s, max_size %s"):format(tostring(pair[1]), tostring(pair[2])))
      mesh:free()
    end
    scene:close()
  end)

  t.test("a FEM mesh placement is sixteen numbers, and it reaches the library", function()
    local scene = cadaclysm.open(t.fixture("samples/cube.scad"))
    local node = scene.nodes[1]
    t.raises(function() node:fem_mesh(0.01, 0, { 1, 2, 3 }) end, "fem_mesh: a placement is 16 numbers, not 3")
    -- The mistake a caller moving between the two ABIs makes: the kernel's twelve.
    t.raises(function() node:fem_mesh(0.01, 0, { 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0 }) end,
      "fem_mesh: a placement is 16 numbers, not 12")
    local plain, placed = node:fem_mesh(), node:fem_mesh(0.01, 0, TURNED)
    t.eq(placed.node_count, plain.node_count)
    -- Every unplaced node must reappear at its image. cube.scad spans 0..20 in x and y,
    -- so the body does not straddle the axis this turn acts about: transposing the 3x3
    -- block sends it to x 102..120 rather than 80..100, and that offset from the axis
    -- *in the plane the turn acts in* is what earns the catch. The loop over all eight
    -- is defence in depth. Do not "simplify" this to a body centred on the axis.
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
      t.ok(found, ("the placement did not send (%g, %g, %g) to (%g, %g, %g)"):format(x, y, z, ex, ey, ez))
    end
    local min, max = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
    for i = 0, placed.node_count - 1 do
      for k = 1, 3 do
        local v = placed.nodes[3 * i + k - 1]
        min[k], max[k] = math.min(min[k], v), math.max(max[k], v)
      end
    end
    t.eq(("%g %g %g %g %g %g"):format(min[1], min[2], min[3], max[1], max[2], max[3]),
      "80 0 0 100 20 20", "the placed nodes do not span the turn of the cube")
    plain:free(); placed:free()
    scene:close()
  end)

  t.test("a B-rep body's FEM mesh: edge chains, vertices, the body's own edge ids and a closed census", function()
    local path = t.fixture("android/app/src/debug/assets/as1-ac-214.stp")
    if not path then return end
    local scene = cadaclysm.open(path)
    local mesh = scene.nodes[2]:fem_mesh(0.05)
    t.eq(mesh.from_mesh, false, "a STEP body is meshed off its brep")
    t.eq(mesh.face_count, 18)
    t.eq(mesh.node_count, 2564)
    t.eq(mesh.triangle_count, 5148)
    t.eq(mesh.watertight, true)
    t.eq(#mesh.open_edges, 0)
    t.eq(#mesh.folded_edges, 0)
    local edges, vertices = mesh.edges, mesh.vertices
    t.eq(#edges, 48)
    t.eq(#vertices, 32)
    -- All three kinds, each node's entity bounded by the list its own kind names.
    local kinds = {}
    for i = 0, mesh.node_count - 1 do
      local kind, entity = mesh.node_kind[i], mesh.node_entity[i]
      kinds[kind] = true
      local bound = (kind == 0 and #vertices) or (kind == 1 and #edges) or (kind == 2 and mesh.face_count)
      t.ok(bound and entity < bound, ("node %d: kind %d entity %d"):format(i, kind, entity))
    end
    t.ok(kinds[0] and kinds[1] and kinds[2], "a brep body's nodes lie on vertices, edges and faces")
    -- `id` is the body's own edge id, not this list's index: the ids ascend, none of
    -- them equals its own index, and the first is already past the edge count.
    local previous = -1
    for i, e in ipairs(edges) do
      t.eq(getmetatable(e), cadaclysm.FemEdge)
      t.ok(e.id > previous, ("edge ids do not ascend at %d: %d after %d"):format(i, e.id, previous))
      previous = e.id
      t.ok(e.id ~= i - 1, ("edge %d's id equals its own index -- id is the index, not the body's id"):format(i - 1))
    end
    t.eq(edges[1].id, 89)
    t.ok(edges[1].id > #edges, "edge 0's id is the file's own number, not a small index")
    -- Every edge: one chain starting at 0, every node in range, and -- the body being
    -- closed -- two real faces. `0` is a real face, so NONE is the only sentinel.
    for i, e in ipairs(edges) do
      t.ok(#e.runs >= 1 and e.runs[1] == 0, ("edge %d's runs do not start at 0"):format(i - 1))
      t.ok(#e.nodes >= 2, ("edge %d has %d nodes"):format(i - 1, #e.nodes))
      for _, n in ipairs(e.nodes) do
        t.ok(n < mesh.node_count, ("edge %d names node %d of %d"):format(i - 1, n, mesh.node_count))
      end
      -- `runs` holds the ABI's own 0-based offsets into a 1-based Lua array, so
      -- `chains()` does that arithmetic once: its pieces rebuild `nodes` exactly and
      -- there is one per run, which is what catches an off-by-one in either direction.
      local rebuilt, chains = {}, e:chains()
      for _, chain in ipairs(chains) do
        for _, n in ipairs(chain) do rebuilt[#rebuilt + 1] = n end
      end
      t.eq(#chains, #e.runs, ("edge %d: %d chains for %d runs"):format(i - 1, #chains, #e.runs))
      t.eq(table.concat(rebuilt, ","), table.concat(e.nodes, ","),
        ("edge %d's chains do not rebuild its nodes"):format(i - 1))
      t.ok(e.faces[1] ~= cadaclysm.NONE and e.faces[2] ~= cadaclysm.NONE,
        ("edge %d of a closed body bounds only one face"):format(i - 1))
      t.ok(e.faces[1] < mesh.face_count and e.faces[2] < mesh.face_count)
      -- `ends` and `faces` are both a pair of uint32 a swap would leave in range: the
      -- one check that separates them is resolving `ends` through `vertices` to the
      -- chain's own first and last node.
      t.eq(e.closed, false)
      local a, b = vertices[e.ends[1] + 1], vertices[e.ends[2] + 1]
      t.ok(a ~= nil and b ~= nil, ("edge %d's ends are not vertex indices"):format(i - 1))
      local first, last = e.nodes[1], e.nodes[#e.nodes]
      t.ok((a.node == first and b.node == last) or (a.node == last and b.node == first),
        ("edge %d: ends %d/%d resolve to nodes %d/%d, not the chain's %d/%d"):format(
          i - 1, e.ends[1], e.ends[2], a.node, b.node, first, last))
    end
    local positioned = 0
    for _, v in ipairs(vertices) do
      t.eq(getmetatable(v), cadaclysm.FemVertex)
      if v.has_position then
        positioned = positioned + 1
        t.eq(#v.point, 3)
      end
      t.ok(v.node == cadaclysm.NONE or v.node < mesh.node_count)
    end
    t.eq(positioned, 32, "every vertex of this body has a position")
    mesh:free()
    -- The brep path refuses what the mesh-only path passes through, in the library's
    -- own words -- which is what proves the wrapper surfaces cadaclysm_last_error.
    t.raises(function() scene.nodes[2]:fem_mesh(0) end, "tolerance must be finite and > 0")
    t.raises(function() scene.nodes[2]:fem_mesh(0.05, -1) end, "max_size must be finite and >= 0")
    t.raises(function() scene.nodes[1]:fem_mesh(0.05) end, "neither a brep nor a mesh")
    scene:close()
  end)

  t.test("a FEM mesh is its own handle: re-meshing the node and closing the scene leave it alone", function()
    local scene = cadaclysm.open(t.fixture("samples/cube.scad"))
    local node = scene.nodes[1]
    t.eq(node.mesh.index_count, 36)
    local mesh = node:fem_mesh()
    -- A FEM mesh is not in the scene's mesh cache, so nothing the scene does to that
    -- cache can stale it: forgetting the meshes frees what a Mesh64 points into and
    -- leaves this untouched. A wrapper that reused the tessellation guard here would
    -- refuse a read the library never refuses.
    scene:forget_meshes()
    t.eq(node.mesh.index_count, 36)
    t.eq(mesh.nodes[0], 0)
    t.eq(mesh.node_count, 8)
    t.eq(#mesh:msh_text() > 0, true)
    scene:close()
    -- And the scene does not own it either: a closed scene neither frees nor stales it.
    t.eq(mesh.node_count, 8)
    t.eq(mesh.triangles[0] < 8, true)
    t.ok(#mesh:msh_text() > 0, "the mesh stopped writing once its scene closed")
    mesh:free()
  end)

  t.test("a FEM mesh held keeps its own arrays alive under collection pressure", function()
    local scene = cadaclysm.open(t.fixture("samples/cube.scad"))
    local node = scene.nodes[1]
    local kept = node:fem_mesh()
    local first = kept.nodes[0]
    for i = 1, 60 do
      local other = node:fem_mesh(0.01 * (1 + i % 3))
      if i % 2 == 0 then other:free() end       -- the rest are left to the collector
    end
    for _ = 1, 3 do collectgarbage() end
    t.eq(kept.freed, false)
    t.eq(kept.nodes[0], first, "the arrays moved or were freed under a mesh still held")
    t.eq(kept.node_count, 8)
    t.ok(#kept:msh_text() > 0)
    kept:free()
    scene:close()
  end)

  t.test("FemEdge:chains cuts the chain where runs says, turning the ABI's zero-based offsets into Lua's own slices", function()
    -- Directly, because no fixture here has a broken chain: an edge's `runs` are the
    -- ABI's offsets **from zero** into a Lua array that counts **from one**, and a
    -- single-run edge cannot tell a wrong conversion from a right one (index 0 of a Lua
    -- array is nil, and appending nil appends nothing). Two runs can.
    local function chains(nodes, runs)
      local out = {}
      for _, chain in ipairs(setmetatable({ nodes = nodes, runs = runs }, cadaclysm.FemEdge):chains()) do
        out[#out + 1] = table.concat(chain, ",")
      end
      return table.concat(out, " | ")
    end
    t.eq(chains({ 5, 6, 7, 8, 9 }, { 0 }), "5,6,7,8,9", "one run is the whole chain")
    t.eq(chains({ 5, 6, 7, 8, 9 }, { 0, 2 }), "5,6 | 7,8,9", "a break at offset 2 cuts after the second node")
    t.eq(chains({ 5, 6, 7, 8, 9 }, { 0, 1, 4 }), "5 | 6,7,8 | 9")
    t.eq(chains({ 5, 6 }, { 0, 1 }), "5 | 6")
  end)

  t.test("ffi types are the header's", function()
    t.eq(ffi.sizeof("CadaclysmOpenOptions"), ffi.abi("64bit") and 96 or ffi.sizeof("CadaclysmOpenOptions"))
    t.eq(ffi.sizeof("CadaclysmMesh"), ffi.abi("64bit") and 48 or ffi.sizeof("CadaclysmMesh"))
  end)

  t.test("links and joints: the mechanism facts", function()
    local scene = cadaclysm.open(t.fixture("samples/mechanism.stp"))
    local links = scene.links
    t.eq(#links, 2)
    t.eq(links[1].name, "base")
    t.eq(links[2].name, "arm")
    for _, l in ipairs(links) do
      t.eq(#l.nodes, 1)
      t.eq(l.nodes[1].name, l.name)
    end
    local joints = scene.joints
    t.eq(#joints, 1)
    local joint = joints[1]
    t.eq(joint.name, "hinge")
    t.eq(joint.start.name, "arm")
    t.eq(joint.start.index, 1)
    t.eq(joint.end_.name, "base")
    t.eq(joint.end_.index, 0)
    scene:close()
  end)

  t.test("links and joints: empty on the cube", function()
    local scene = cadaclysm.open(t.fixture("samples/cube.scad"))
    t.eq(#scene.links, 0)
    t.eq(#scene.joints, 0)
    scene:close()
  end)

  local function is_teal(c)
    return c ~= false and math.abs(c[1] - 0.1) < 1e-6 and math.abs(c[2] - 0.6) < 1e-6 and math.abs(c[3] - 0.55) < 1e-6
  end

  t.test("edge colours follow the edges", function()
    local path = t.fixture("samples/edge-colours.stp")
    local scene = cadaclysm.open(path)
    local body
    for _, n in ipairs(scene.nodes) do
      if n.edges.polyline_count > 0 then body = n; break end
    end
    t.ok(body ~= nil, "no node with edges in edge-colours.stp")
    local pairs_to_check = { { body.edges, body.edge_colours }, { body.surface_edges, body.surface_edge_colours } }
    for _, pair in ipairs(pairs_to_check) do
      local edges, colours = pair[1], pair[2]
      t.eq(#colours, edges.polyline_count)
      local teal_count, none_count = 0, 0
      for _, c in ipairs(colours) do
        if is_teal(c) then teal_count = teal_count + 1 end
        if c == false then none_count = none_count + 1 end
      end
      t.eq(teal_count, 1)
      t.eq(none_count, #colours - 1)
      local styled
      for _, c in ipairs(colours) do if c ~= false then styled = c; break end end
      t.near(styled[1], 0.1, 1e-6); t.near(styled[2], 0.6, 1e-6); t.near(styled[3], 0.55, 1e-6); t.near(styled[4], 1.0, 1e-6)
    end
    scene:close()
  end)

  t.test("an unpainted file has no edge colours", function()
    local scene = cadaclysm.open(t.fixture("samples/cube.scad"))
    for _, n in ipairs(scene.nodes) do
      t.eq(#n.edge_colours, 0)
      t.eq(#n.surface_edge_colours, 0)
    end
    scene:close()
  end)
end
