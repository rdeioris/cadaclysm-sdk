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

  t.test("ffi types are the header's", function()
    t.eq(ffi.sizeof("CadaclysmOpenOptions"), ffi.abi("64bit") and 96 or ffi.sizeof("CadaclysmOpenOptions"))
    t.eq(ffi.sizeof("CadaclysmMesh"), ffi.abi("64bit") and 48 or ffi.sizeof("CadaclysmMesh"))
  end)
end
