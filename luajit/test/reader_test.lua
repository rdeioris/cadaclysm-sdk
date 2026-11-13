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
    t.ok(cadaclysm.library_path():match("cadaclysm[%w_]*%.%w+$"), cadaclysm.library_path())
  end)

  t.test("the library says which flavour it is", function()
    local stem = cadaclysm.library_path():match("([^/\\]+)$"):gsub("^lib", ""):gsub("%.%w+$", "")
    local want = ({ cadaclysm = "full", cadaclysm_kernel_reader = "kernel-reader", cadaclysm_reader = "reader" })[stem]
    t.eq(cadaclysm.flavour(), want or "reader")
    if not want then t.eq(cadaclysm.features(), "")
    else t.ok(("," .. cadaclysm.features() .. ","):find(",nodes,", 1, true), "features " .. cadaclysm.features()) end
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

  -- cube.scad is a mesh with no brep in the Reader flavour and an exact box where the reader
  -- library carries the kernel's builder (`cadaclysm-capi`'s `openscad-brep`, every shipped
  -- desktop library): the cube's figures that differ are pinned both ways, by this.
  local function cube_is_exact(scene)
    return scene.nodes[1].brep ~= nil
  end

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
    -- 12 axis sections of the mesh; the exact cube's isocurves are the surfaces' to draw.
    t.eq(node.isocurve_beziers.count, cube_is_exact(scene) and 0 or 12)
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

  t.test("a mesh64 read after forget_meshes is caught, not read; mesh, edges and the node survive it", function()
    local scene = cadaclysm.open(t.fixture("samples/cube.scad"))
    local node = scene.nodes[1]
    local lent, kept, outline = node.mesh64, node.mesh, node.edges
    local triangles = lent.triangle_count
    local early = lent:copy()
    t.ok(lent.positions ~= nil and triangles > 0)
    scene:forget_meshes()
    t.raises(function() return lent.positions end, "forgotten")
    t.raises(function() return lent.indices end, "forgotten")
    t.raises(function() return lent:position(0) end, "forgotten")
    t.raises(function() return lent:copy() end, "forgotten")
    t.eq(lent.triangle_count, triangles)
    t.ok(not lent.is_empty)
    t.eq(kept.positions[0], kept.positions[0])
    t.ok(outline.positions ~= nil and node.can_mesh)
    local again = node.mesh64
    t.eq(again.triangle_count, triangles)
    for i = 0, again.vertex_count * 3 - 1 do t.eq(again.positions[i], early.positions[i]) end
    scene:close()
    t.raises(function() return again.positions end, "closed")
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
    t.eq(triangles, 274)  -- 2026-09-26, d2f866b6 (filler interior at six rows, 15-degree turn bound): 542 -> 522; 2026-10-04, one row along a ruling (the display's filler lays one row along a cylinder's or cone's straight axis, not six): 522 -> 274
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
    t.eq(total, 14)
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
    local sewn, report = brep:sewed()
    t.eq(report.free_before, man.boundary_edges)
    t.eq(brep.manifold.boundary_edges, man.boundary_edges)
    sewn:release()
    scene:close()
    -- The brep outlives the scene; releasing is idempotent and then refused.
    t.eq(brep.manifold.faces, man.faces)
    brep:release()
    brep:release()
    t.raises(function() return brep.pointer end, "released")
  end)

  -- ---- health and healing (Python's test_brep_health_* / test_brep_healed_* and its two decoder tests)
  do
    -- `st203-bapl.stp` (from the STEP AP203 sample set) is not in the repository: it is
    -- looked for in SAMPLE_DIR, else at the repository root, and skipped when absent, as
    -- Python's test does.
    local function st203()
      local dir = os.getenv("SAMPLE_DIR")
      local path
      if dir then
        path = dir .. "/st203-bapl.stp"
        local f = io.open(path, "rb")
        if not f then path = nil else f:close() end
      else
        local ok, found = pcall(t.fixture, "st203-bapl.stp")
        path = ok and found or nil
      end
      if not path then print("      skip: st203-bapl.stp not to hand") end
      return path
    end
    local function breps_of(scene)
      local out = {}
      for _, n in ipairs(scene.nodes) do
        local b = n.brep
        if b ~= nil then out[#out + 1] = b end
      end
      return out
    end
    local function rel(actual, expected, r, message)
      t.ok(math.abs(actual - expected) <= r * math.abs(expected),
        ("%sexpected %.17g (rel %g), got %.17g"):format(message and (message .. ": ") or "", expected, r, actual))
    end

    t.test("brep health reports the free edges of st203-bapl", function()
      local path = st203()
      if not path then return end
      local scene = cadaclysm.open(path)
      local breps = breps_of(scene)
      local body
      for _, b in ipairs(breps) do
        if b.manifold.boundary_edges == 188 then body = b break end
      end
      t.ok(body ~= nil, "the 188-free-edge body")
      local report = body:health()
      t.eq(getmetatable(report), cadaclysm.HealthReport)
      t.eq(#report.free_edges, 188)
      t.eq(#report.wires, 45)
      local sum = 0
      for _, w in ipairs(report.wires) do sum = sum + w.count end
      t.eq(sum, 188)
      local first_wire = report:wire_edges(0)
      t.eq(#first_wire, report.wires[1].count)
      for i, e in ipairs(first_wire) do
        t.eq(e, report.free_edges[i])
        t.eq(e.wire, 0)
      end
      local _, sew = body:sewed()
      t.eq(report.sew_pairs, sew.pairs)
      t.ok(report.tolerance > 0)
      t.eq(report.cracks, nil)
      t.eq(body:health(0 / 0).tolerance, report.tolerance)
      -- the first free edge, read off the C rows: its partner is row 67, 95.015 away, sharing no end
      local first = report.free_edges[1]
      t.eq(getmetatable(first), cadaclysm.FreeEdge)
      t.eq(("%s %s %s %s %s %s"):format(first.trim, first.edge, first.face, first.wire, first.partner, first.shared_ends),
        "0 41363 0 0 67 0")
      rel(first.gap, 95.01496054, 1e-6, "first gap")
      for _, e in ipairs(report.free_edges) do
        if e.partner == nil then t.eq(e.gap, math.huge) else t.ok(e.partner ~= e.trim) end
      end
      rel(report.extent, 253.66439715552204, 1e-12, "extent")
      rel(report.rounding, 1e-7 * report.extent, 1e-12, "rounding")
      rel(report.tolerance, 1e-4 * report.extent, 1e-12, "tolerance")
      t.eq(report.loose_edges, 0)
      t.eq(report.worst_loose, 0)
      t.eq(report.sew_refused, 4)
      t.eq(sew.refused, 4)
      rel(report.sew_worst_gap, sew.worst_gap, 1e-12, "sew worst gap")
      t.ok(report.sew_worst_gap > 0)
      local c = body:health(nil, true).cracks
      t.eq(getmetatable(c), cadaclysm.Cracks)
      t.eq(("%s %d %d %d %d"):format(tostring(c.watertight), c.open, c.folded, c.crossings, #c.edges), "false 0 0 166 0")
      local wide = body:health(5)
      t.eq(#wide.small, 96)
      local edge
      for _, s in ipairs(wide.small) do
        t.ok(s.kind == "short_edge" or s.kind == "sliver_face" or s.kind == "tiny_face", s.kind)
        t.ok(s.size >= 0)
        if s.kind == "short_edge" then
          t.ok(s.size < 5)
          edge = edge or s
        end
      end
      t.eq(edge.index, 41550)
      rel(edge.size, 3.1622776616321775, 1e-9, "the first short edge")
      for _, b in ipairs(breps) do b:release() end
      scene:close()
    end)

    t.test("brep healed heals st203-bapl and leaves the original", function()
      local path = st203()
      if not path then return end
      local scene = cadaclysm.open(path)
      local breps = breps_of(scene)
      local body = breps[2]   -- the 188-free-edge body; the first takes minutes to diagnose
      local same, report = body:healed()
      t.eq(getmetatable(same), cadaclysm.Brep)
      t.eq(getmetatable(report), cadaclysm.HealReport)
      t.ok(same.pointer ~= body.pointer, "a new brep")
      t.eq(report.small_before, 0)
      t.eq(report.free_before, 188)
      t.ok(report.free_after <= 188)
      rel(report.tolerance, 1e-4 * body:health().extent, 1e-12, "default tolerance")
      same:release()
      -- at a tolerance of 5: 96 small features, 28 healed, the rest refused as uneven slivers
      local healed, r = body:healed(5)
      t.eq(r.tolerance, 5)
      t.eq(("%d %d %d %d %d"):format(r.small_before, #r.fixes, r.small_after, r.free_before, r.free_after),
        "96 28 8 188 88")
      t.eq(#r.refused, 8)
      for _, x in ipairs(r.refused) do
        t.eq(getmetatable(x), cadaclysm.HealRefusal)
        t.eq(x.kind .. " " .. x.why, "sliver_face uneven")
      end
      t.eq(("%s %s %d %d"):format(tostring(r.closed_before), tostring(r.closed_after), r.nonmanifold_before,
        r.nonmanifold_after), "false false 0 0")
      t.eq(r.small_after, #healed:health(5).small)
      t.eq(#body:health(5).small, 96, "the input is left as it was")
      local most, short = 0, nil
      for _, f in ipairs(r.fixes) do
        t.eq(getmetatable(f), cadaclysm.HealFix)
        t.ok(f.size >= 0 and f.moved >= 0)
        most = math.max(most, f.moved)
        if f.kind == "short_edge" then short = short or f end
      end
      rel(most, 1.8248105306211464, 1e-9, "the largest fix moved")
      rel(r.moved, 1.581138831332503, 1e-9, "the report moved")
      t.eq(short.index, 41550)
      rel(short.size, 3.1622776616321775, 1e-9, "the first short edge fixed")
      t.eq(body:edge_tolerance(41550), 0)
      t.eq(healed:edge_tolerance(41550), nil)
      t.eq(healed:edge_tolerance(41363), 0)
      t.eq(healed:edge_tolerance(0xFFFFFFF0), nil)
      healed:release()
      -- every kind switched off: nothing healed, every small feature refused as toggled
      local _, off = body:healed(5, false, false, false)
      t.eq(#off.fixes, 0)
      t.eq(#off.refused, 96)
      t.eq(off.free_after, off.free_before)
      local per = { short_edge = 0, sliver_face = 0, tiny_face = 0 }
      for _, x in ipairs(off.refused) do
        t.eq(x.why, "toggled")
        t.eq(x.figure, 0)
        per[x.kind] = per[x.kind] + 1
      end
      t.eq(("%d %d %d"):format(per.short_edge, per.sliver_face, per.tiny_face), "64 26 6")
      -- one kind on: the others are refused as toggled, and only it heals
      local _, edges_only = body:healed(5, true, false, false)
      for _, x in ipairs(edges_only.refused) do
        if x.kind ~= "short_edge" then t.eq(x.why, "toggled") end
      end
      for _, f in ipairs(edges_only.fixes) do t.ok(f.kind == "short_edge" or f.kind == "collapsed_edge", f.kind) end
      for _, b in ipairs(breps) do b:release() end
      scene:close()
      t.raises(function() body:healed() end, "released")
      t.raises(function() body:health() end, "released")
      t.raises(function() body:edge_tolerance(0) end, "released")
    end)

    t.test("the health decoder reads every column of distinct rows", function()
      local none = 0xFFFFFFFF
      local counts = { 2, 1, 1, 2, 1, 0, 0, 1, 0, 3, 4, 5, 1, 0, 11, 12, 13, 2 }
      local sizes = { 0.5, 0.25, 9.0, 7.5, 6.5, 5.5, 4.5, 3.5 }
      local r = cadaclysm._health_report(counts, sizes, { 10, 20, 30, 40, 1, 2, 11, none, 31, 41, none, 0 },
        { 1.5, 2.5, 3.5, math.huge }, { 0, 2, 1 }, { 8.5, 2.5 }, { 1, 77, 4, 99 }, { 0.125, 0.0625 }, { 5, 6 })
      t.eq(("%g %g %g %g"):format(r.tolerance, r.rounding, r.extent, r.worst_gap), "0.5 0.25 9 7.5")
      t.eq(("%d %g %d %d %g"):format(r.loose_edges, r.worst_loose, r.sew_pairs, r.sew_refused, r.sew_worst_gap),
        "3 6.5 4 5 5.5")
      local rows = {}
      for i, e in ipairs(r.free_edges) do
        rows[i] = ("%s,%s,%s,%s,%s,%s,%g,%g"):format(e.trim, tostring(e.edge), e.face, e.wire, tostring(e.partner),
          e.shared_ends, e.length, e.gap)
      end
      t.eq(table.concat(rows, " "), "10,20,30,40,1,2,1.5,2.5 11,nil,31,41,nil,0,3.5,inf")
      t.eq(#r.wires, 1)
      local w = r.wires[1]
      t.eq(getmetatable(w), cadaclysm.FreeWire)
      t.eq(("%d %d %s %g %g"):format(w.first, w.count, tostring(w.closed), w.length, w.widest_gap), "0 2 true 8.5 2.5")
      t.eq(#r.small, 2)
      t.eq(getmetatable(r.small[1]), cadaclysm.SmallFeature)
      t.eq(("%s %d %g"):format(r.small[1].kind, r.small[1].index, r.small[1].size), "collapsed_edge 77 0.125")
      t.eq(("%s %d %g"):format(r.small[2].kind, r.small[2].index, r.small[2].size), "tiny_body 99 0.0625")
      local c = r.cracks
      t.eq(("%s %d %d %d %s"):format(tostring(c.watertight), c.open, c.folded, c.crossings, table.concat(c.edges, " ")),
        "false 11 12 13 5 6")
      counts[13] = 0   -- counts[12], not meshed: no cracks however the other counts read
      local unmeshed = cadaclysm._health_report(counts, sizes, {}, {}, {}, {}, { 5, 1 }, { 1 }, {})
      t.eq(unmeshed.cracks, nil)
      t.eq(unmeshed.small[1].kind, "small_hole")
    end)

    t.test("the heal decoder reads every column of distinct rows", function()
      local r = cadaclysm._heal_report({ 2, 3, 1, 9, 8, 7, 6, 1, 0, 5, 4 }, { 0.5, 0.25 }, { 5, 11, 0, 12 },
        { 1.5, 0.125, 2.5, 0.0625 }, { 3, 21, 9, 4, 22, 3, 2, 23, 10 }, { 0.0, 7.5, 0.0 })
      t.eq(("%g %g %s"):format(r.tolerance, r.moved, tostring(r.guarded)), "0.5 0.25 true")
      t.eq(("%d %d %d %d"):format(r.small_before, r.small_after, r.free_before, r.free_after), "9 8 7 6")
      t.eq(("%s %s %d %d"):format(tostring(r.closed_before), tostring(r.closed_after), r.nonmanifold_before,
        r.nonmanifold_after), "true false 5 4")
      local fixes = {}
      for i, f in ipairs(r.fixes) do fixes[i] = ("%s %d %g %g"):format(f.kind, f.index, f.size, f.moved) end
      t.eq(table.concat(fixes, ", "), "small_hole 11 1.5 0.125, short_edge 12 2.5 0.0625")
      local refusals = {}
      for i, x in ipairs(r.refused) do refusals[i] = ("%s %d %s %g"):format(x.kind, x.index, x.why, x.figure) end
      t.eq(table.concat(refusals, ", "), "tiny_face 21 toggled 0, tiny_body 22 chain 7.5, sliver_face 23 unsupported 0")
      local whys = {}
      for why = 0, 10 do
        local one = cadaclysm._heal_report({ 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, { 0, 0 }, {}, {}, { 0, 0, why }, { 0 })
        whys[#whys + 1] = one.refused[1].why
      end
      t.eq(table.concat(whys, " "), "would_empty_loop closed seam chain neighbours_part uneven non_manifold "
        .. "has_holes body_guard toggled unsupported")
    end)
  end

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
    local named = scene:svg_text({ stroke = "Red" })
    t.ok(named:find('stroke="#ff0000"', 1, true), named:sub(1, 300))

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
    t.ok(fit.shape_name == "box" or fit.shape_name == "hull", fit.shape_name)
    if cube_is_exact(scene) then
      -- The exact cube is fitted as the box it is: no hull to hand over.
      t.eq(fit.shape_name, "box")
      t.eq(fit.hull_vertex_count, 0)
    else
      t.eq(fit.hull_vertex_count, 8)
      local hull = scene.nodes[1]:collision_hull()
      t.eq(hull.vertex_count, 8)
      t.eq(hull.index_count, 36)
      t.ok(hull.positions ~= nil)
    end
    scene:close()
  end)

  t.test("meshlets", function()
    local scene = cadaclysm.open(t.fixture("samples/cube.scad"))
    local mesh = scene.nodes[1].mesh
    local m = cadaclysm.Meshlets.build(mesh.positions, mesh.normals, mesh.indices, mesh.vertex_count, mesh.index_count, 124, 64)
    -- The mesh cube is 36 vertices; the exact cube's mesh shares its corners per face (24).
    local vertices = cube_is_exact(scene) and 24 or 36
    t.eq(m.count, 1)
    t.eq(m:triangle_count(0), 12)
    t.eq(m:vertex_count(0), vertices)
    t.eq(m:level(0), 0)
    local one = m:meshlet(0)
    t.eq(one.triangle_count, 12)
    t.eq(#one.positions, vertices * 3)
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
    t.eq(bracket.triangle_estimate, 12)  -- 2026-10-06, d945a0458 (the estimate calls the mesher's own sampling and stations): bracket 18 -> 12, pin 318 -> 248
    t.eq(pin.triangle_estimate, 248)  -- 2026-10-06, d945a0458 (the estimate calls the mesher's own sampling and stations): bracket 18 -> 12, pin 318 -> 248; 2026-09-26, d2f866b6 (filler interior at six rows, 15-degree turn bound): 480 -> 468; 2026-10-04, one row along a ruling (the display's filler lays one row along a cylinder's or cone's straight axis, not six): 468 -> 318
    t.eq(bracket.surface_edges.polyline_count, 12)
    t.eq(bracket.surface_edges.vertex_count, 24)
    t.eq(bracket.surface_isocurves.polyline_count, 0)
    -- Three rings and three rulings (6 since 53759bef; the rulings were dropped at the trim boundary).
    t.eq(pin.surface_isocurves.polyline_count, 6)
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

    -- Crossings: `samples/dented-box.stp` is a closed B-rep box whose top dips through
    -- its own floor, 296 pairs measured 2026-09-26. `_open_edge_count` and
    -- `_folded_edge_count` are both 0 for this watertight body, so a `crossings` wired to
    -- either of those (rather than its own live `cadaclysm_fem_mesh_crossing_count`)
    -- reads 0 here, not 296 -- once through this reader, and once through the kernel's
    -- own open of the same file, which must agree with it.
    local dented_scene = cadaclysm.open(t.fixture("samples/dented-box.stp"))
    local dented_node
    for _, n in ipairs(dented_scene.nodes) do
      if n.can_mesh then dented_node = n; break end
    end
    local dented_mesh = dented_node:fem_mesh()
    t.eq(dented_mesh.watertight, true)
    t.eq(dented_mesh.from_mesh, false)
    local crossings = dented_mesh.crossings
    t.eq(#crossings, 296)
    t.ok(crossings[1][1] < crossings[1][2], "the first pair is not a < b")
    dented_mesh:free()
    dented_scene:close()
  end)

  t.test("a node's FEM mesh: the mesh-only cube's arrays, census, quality and .msh text", function()
    local scene = cadaclysm.open(t.fixture("samples/cube.scad"))
    local exact = cube_is_exact(scene)
    local mesh = scene.nodes[1]:fem_mesh()
    t.eq(getmetatable(mesh), cadaclysm.FemMesh)
    t.eq(mesh.node_count, 8)
    t.eq(mesh.triangle_count, 12)
    t.eq(mesh.watertight, true)
    if exact then
      -- The exact box: six faces, twelve edges, eight corners, in the file's own space.
      t.eq(mesh.face_count, 6)
      t.eq(mesh.from_mesh, false, "the exact cube has a brep, so the mesh is the brep's")
      t.eq(#mesh.edges, 12)
      t.eq(#mesh.vertices, 8)
    else
      t.eq(mesh.face_count, 1)
      t.eq(mesh.from_mesh, true, "cube.scad is a CSG body with no brep, so the mesh is the scene's own")
      t.eq(#mesh.edges, 0, "a from_mesh body has no brep edges at all")
      t.eq(#mesh.vertices, 0)
    end
    t.eq(#mesh.open_edges, 0)
    t.eq(#mesh.folded_edges, 0)
    t.eq(#mesh.crossings, 0)
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
    for i = 0, exact and -1 or mesh.node_count - 1 do
      -- One face and every node on it: this is what tells node_kind from node_entity
      -- if the two were ever lent from one pointer. (The exact cube's corners lie on vertices.)
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
      function() return mesh.crossings end,
    }
    t.eq(#calls, 7, "a call that takes the handle was added without being swept here")
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
    -- The open sheet, not the cube: it is mesh-only in every flavour, where the cube is an
    -- exact box (which reads both fields) wherever the kernel's builder is linked.
    local scene = cadaclysm.open(t.fixture("samples/open-sheet.scad"))
    local node
    for _, n in ipairs(scene.nodes) do
      if n.can_mesh then node = n break end
    end
    t.ok(node ~= nil, "open-sheet.scad has no meshable node")
    local nan, inf = 0 / 0, math.huge
    -- `fem_mesh_of_mesh` takes no FemOptions at all, so a body with no brep comes back
    -- whatever these say, where the brep path refuses each. A wrapper that checked
    -- either field itself would pass every other test here and be wrong.
    for _, pair in ipairs({ { 0, 0 }, { -1, 0 }, { nan, 0 }, { 0.01, -1 }, { 0.01, nan }, { 0.01, inf } }) do
      local mesh = node:fem_mesh(pair[1], pair[2])
      t.eq(mesh.from_mesh, true, "the open sheet is a mesh-only body")
      t.eq(mesh.node_count, 5, ("tolerance %s, max_size %s"):format(tostring(pair[1]), tostring(pair[2])))
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
    -- 2026-09-26, d2f866b6 (filler interior at six rows, 15-degree turn bound): 2564 -> 1484 nodes, 5148 -> 2988 triangles.
    t.eq(mesh.node_count, 1484)
    t.eq(mesh.triangle_count, 2988)
    t.eq(mesh.watertight, true)
    t.eq(#mesh.open_edges, 0)
    t.eq(#mesh.folded_edges, 0)
    t.eq(#mesh.crossings, 0)
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

    -- the pair: revolute about z, ranged -1.5..1.5, both contact frames at (0, 0, 100)
    local pair = joint.pair
    t.ok(pair ~= nil, "hinge has no pair")
    t.eq(pair.kind, "revolute")
    t.eq(pair.type_name, nil)
    t.eq(pair.pitch, nil)
    for _, raw in ipairs({ pair.raw_frame_start, pair.raw_frame_end }) do
      t.near(raw[13], 0.0, 1e-9, "pair frame origin x")
      t.near(raw[14], 0.0, 1e-9, "pair frame origin y")
      t.near(raw[15], 100.0, 1e-9, "pair frame origin z")
      t.near(raw[9], 0.0, 1e-9, "pair frame z axis x")
      t.near(raw[10], 0.0, 1e-9, "pair frame z axis y")
      t.near(raw[11], 1.0, 1e-9, "pair frame z axis z")
    end
    local freedoms = pair.freedoms
    t.eq(#freedoms, 1)
    t.eq(freedoms[1].motion, "rotation")
    t.eq(freedoms[1].axis, "z")
    t.near(freedoms[1].lower, -1.5, 1e-9)
    t.near(freedoms[1].upper, 1.5, 1e-9)

    -- the state: one named "open", one row (hinge, [0.5])
    local states = scene.states
    t.eq(#states, 1)
    t.eq(states[1].index, 0)
    t.eq(states[1].name, "open")
    t.eq(#states[1].values, 1)
    local row = states[1].values[1]
    t.eq(row.joint.name, "hinge")
    t.eq(row.joint.index, 0)
    t.eq(#row.values, 1)
    t.near(row.values[1], 0.5, 1e-9)
    scene:close()
  end)

  t.test("links and joints: empty on the cube", function()
    local scene = cadaclysm.open(t.fixture("samples/cube.scad"))
    t.eq(#scene.links, 0)
    t.eq(#scene.joints, 0)
    t.eq(#scene.states, 0)
    scene:close()
  end)

  -- m is Pose:raw_transform's return: 16 numbers, column-major, 1-indexed Lua array.
  local function apply(m, p)
    return m[1] * p[1] + m[5] * p[2] + m[9] * p[3] + m[13],
           m[2] * p[1] + m[6] * p[2] + m[10] * p[3] + m[14],
           m[3] * p[1] + m[7] * p[2] + m[11] * p[3] + m[15]
  end

  local function mechanism_parts(scene)
    local links = scene.links
    local base_link, arm_link = links[1], links[2]
    t.eq(base_link.name, "base")
    t.eq(arm_link.name, "arm")
    local hinge = scene.joints[1]
    local state = scene.states[1]
    return base_link, arm_link, hinge, state, arm_link.nodes[1], base_link.nodes[1]
  end

  t.test("a mechanism poses its state", function()
    local scene = cadaclysm.open(t.fixture("samples/mechanism.stp"))
    local base_link, arm_link, hinge, state, arm_node, base_node = mechanism_parts(scene)
    t.eq(scene.base, nil)
    local pose = scene:pose_state(state)
    t.eq(pose.ground.index, base_link.index)
    t.eq(#pose.unsolved, 0)
    t.eq(#pose.out_of_range, 0)
    local q = 0.5 -- the arm is the joint's start, reached from its end: it turns by -q
    local x, y, z = apply(pose:raw_transform(arm_node), { 10, 0, 0 })
    t.near(x, 10 * math.cos(q), 1e-9, "arm point x")
    t.near(y, -10 * math.sin(q), 1e-9, "arm point y")
    t.near(z, 100, 1e-9, "arm point z")
    x, y, z = apply(pose:raw_transform(arm_node), { 0, 0, 0 })
    t.near(x, 0, 1e-9, "arm origin x")
    t.near(y, 0, 1e-9, "arm origin y")
    t.near(z, 100, 1e-9, "arm origin z")
    local base_raw = pose:raw_transform(base_node)
    local base_rest = base_node.raw_transform
    for i = 1, 16 do t.near(base_raw[i], base_rest[i], 0, "base transform[" .. i .. "]") end
    scene:close()
  end)

  t.test("a value past its range is used and reported", function()
    local scene = cadaclysm.open(t.fixture("samples/mechanism.stp"))
    local base_link, arm_link, hinge, state, arm_node, base_node = mechanism_parts(scene)
    local pose = scene:pose({ { joint = hinge, values = { 2.0 } } })
    t.eq(#pose.out_of_range, 1)
    local entry = pose.out_of_range[1]
    t.eq(entry.joint.index, hinge.index)
    t.eq(entry.freedom, 0)
    t.near(entry.value, 2.0, 0)
    local x, y, z = apply(pose:raw_transform(arm_node), { 10, 0, 0 })
    t.near(x, 10 * math.cos(2.0), 1e-9, "arm point x")
    t.near(y, -10 * math.sin(2.0), 1e-9, "arm point y")
    t.near(z, 100, 1e-9, "arm point z")
    scene:close()
  end)

  t.test("the ground can be named", function()
    local scene = cadaclysm.open(t.fixture("samples/mechanism.stp"))
    local base_link, arm_link, hinge, state, arm_node, base_node = mechanism_parts(scene)
    local pose = scene:pose({ { joint = hinge, values = { 0.5 } } }, arm_link)
    t.eq(pose.ground.index, arm_link.index)
    local raw, rest = pose:raw_transform(arm_node), arm_node.raw_transform
    for i = 1, 16 do t.near(raw[i], rest[i], 0, "arm transform[" .. i .. "]") end
    scene:close()
  end)

  t.test("a file's motion sequences read, and a sequence poses like its states", function()
    local scene = cadaclysm.open(t.fixture("samples/mechanism-sequence.stp"))
    local sequences = scene.sequences
    t.eq(#sequences, 2)
    local swing, snap = sequences[1], sequences[2]
    t.eq(swing.name, "swing")
    t.eq(swing.closed, true)
    t.eq(swing.seconds_per_unit, 1)
    t.eq(snap.name, "snap")
    t.eq(snap.closed, false)
    t.eq(snap.seconds_per_unit, nil)
    local function summary(seq)
      local out = {}
      for i, seg in ipairs(seq.segments) do out[i] = ("%s@%g %s"):format(seg.state.name, seg.t, seg.interpolation) end
      return table.concat(out, ",")
    end
    t.eq(summary(swing), "shut@0 linear,open@1 synchronous,wide@2 linear")
    t.eq(summary(snap), "shut@0 discontinuous,wide@0.5 discontinuous")
    t.eq(swing.start, 0)
    t.eq(swing.end_, 2)
    t.eq(snap.end_, 0.5)
    for _, seg in ipairs(swing.segments) do
      local by_sequence = swing:pose(seg.t)
      local by_state = scene:pose_state(seg.state)
      for _, node in ipairs(scene.nodes) do
        local a, b = by_sequence:raw_transform(node), by_state:raw_transform(node)
        for i = 1, 16 do t.near(a[i], b[i], 1e-9, seg.state.name .. " transform[" .. i .. "]") end
      end
    end
    local e = t.raises(function() swing:pose(0 / 0) end)
    t.eq(e.message, "the sequence parameter must be a finite number")
    scene:close()
  end)

  -- IFC work schedules: samples/schedule.ifc, at parity with the Python reference's tests.
  local D, T0 = 86400, 1772438400

  local function names(list)
    local out = {}
    for i, v in ipairs(list) do out[i] = v.name end
    return out
  end
  local function sorted_names(list)
    local out = names(list)
    table.sort(out)
    return out
  end
  local function by_name(rows)
    local out = {}
    for _, e in ipairs(rows) do out[e.node.name] = e end
    return out
  end

  t.test("a file reads its work schedule", function()
    local scene = cadaclysm.open(t.fixture("samples/schedule.ifc"))
    local schedules = scene.schedules
    t.eq(#schedules, 1)
    local s = schedules[1]
    t.eq(s.name, "Programme")
    t.eq(s.identification, "WS-1")
    t.eq(s.kind, "planned")
    t.eq(s.kind_name, "")
    t.eq(s.start, T0)
    t.eq(s.finish, nil)
    local tasks = s.tasks
    t.eq(table.concat(names(tasks), ","), "Slab,Structure,Walls north,Walls south,Topping out,Demolish shed,Fit-out")
    local slab, structure, north, south, topping, shed, fit =
      tasks[1], tasks[2], tasks[3], tasks[4], tasks[5], tasks[6], tasks[7]
    t.eq(north.parent.index, structure.index)
    t.eq(south.parent.index, structure.index)
    t.eq(slab.parent, nil)
    t.eq(slab.kind, "construction")
    t.eq(shed.kind, "demolition")
    t.eq(topping.kind, "notdefined")
    t.eq(slab.kind_name, "")
    t.eq(topping.milestone, true)
    t.eq(slab.milestone, false)
    for _, task in ipairs(tasks) do t.eq(task.schedule_index, 0) end
    t.eq(fit.schedule_index, s.index)
    t.eq(slab.identification, "T1")
    t.eq(slab.status, "COMPLETED")
    local time = slab.time
    t.eq(time.schedule_start, T0)
    t.eq(time.schedule_finish, nil)
    t.eq(time.duration, 10 * D)
    t.eq(time.actual_start, T0)
    t.eq(time.actual_finish, T0 + 8 * D)
    t.eq(time.early_start, nil)
    t.eq(table.concat(sorted_names(south.nodes), ","), "Wall S1,Wall S2")
    t.eq(table.concat(sorted_names(fit.nodes), ","), "Desk,Room")
    local links = s.links
    t.eq(#links, 4)
    local want = {
      { "Slab", "Structure", "finish_start", nil },
      { "Walls north", "Walls south", "start_start", 2 * D },
      { "Walls south", "Topping out", "finish_start", nil },
      { "Topping out", "Fit-out", "finish_start", nil },
    }
    for i, w in ipairs(want) do
      local l = links[i]
      t.eq(l.from.name, w[1])
      t.eq(l.to.name, w[2])
      t.eq(l.kind, w[3])
      t.eq(l.kind_name, "")
      t.eq(l.lag, w[4])
    end
    scene:close()
  end)

  t.test("a schedule says what each element is doing", function()
    local scene = cadaclysm.open(t.fixture("samples/schedule.ifc"))
    local s = scene.schedules[1]
    local states = by_name(s:at(T0 + 3 * D))
    local got = {}
    for name in pairs(states) do got[#got + 1] = name end
    table.sort(got)
    t.eq(table.concat(got, ","), "Desk,Room,Shed,Slab,Wall N1,Wall N2,Wall S1,Wall S2")
    t.eq(states["Slab"].phase, "building")
    t.near(states["Slab"].progress, 0.3, 1e-9, "Slab progress")
    t.eq(states["Shed"].phase, "demolishing")
    t.eq(states["Wall S1"].phase, "unbuilt")
    local late = by_name(s:at(T0 + 32 * D, "actual"))
    t.eq(late["Wall S1"].phase, "building")
    t.eq(late["Wall S1"].variance, 5 * D)
    t.eq(late["Slab"].variance, -2 * D)
    scene:close()
  end)

  t.test("a schedule refuses a bad date and dates word", function()
    local scene = cadaclysm.open(t.fixture("samples/schedule.ifc"))
    local s = scene.schedules[1]
    local e = t.raises(function() s:at(0 / 0) end)
    t.eq(e.message, "the date must be a finite number")
    e = t.raises(function() s:at(T0, "compare") end)
    t.eq(e.message, "dates must be 'scheduled' or 'actual'")
    scene:close()
  end)

  t.test("a file without a schedule has none", function()
    local cube = cadaclysm.open(t.fixture("samples/cube.scad"))
    t.eq(#cube.schedules, 0)
    cube:close()
  end)

  t.test("state values pose like the state", function()
    local scene = cadaclysm.open(t.fixture("samples/mechanism.stp"))
    local base_link, arm_link, hinge, state, arm_node, base_node = mechanism_parts(scene)
    local by_values = scene:pose(state.values):raw_transform(arm_node)
    local by_state = scene:pose_state(state):raw_transform(arm_node)
    for i = 1, 16 do t.near(by_values[i], by_state[i], 1e-12, "transform[" .. i .. "]") end
    local rest = scene:pose({})
    for _, n in ipairs(scene.nodes) do
      local raw, node_rest = rest:raw_transform(n), n.raw_transform
      for i = 1, 16 do t.near(raw[i], node_rest[i], 0, "node " .. n.index .. " transform[" .. i .. "]") end
    end
    scene:close()
  end)

  t.test("a bad pose raises", function()
    local scene = cadaclysm.open(t.fixture("samples/mechanism.stp"))
    local base_link, arm_link, hinge, state, arm_node, base_node = mechanism_parts(scene)
    t.raises(function() scene:pose({ { joint = hinge, values = { 1.0, 2.0 } } }) end, "takes 1 value%(s%)")
    local cube = cadaclysm.open(t.fixture("samples/cube.scad"))
    t.raises(function() cube:pose({}) end, "no mechanism")
    cube:close()
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

  -- ---- Node:silhouette_beziers ------------------------------------------------------------
  -- The fixtures are the repository's own. The box is our STEP writer's, not a Rhino export: Rhino
  -- writes a planar face as a NURBS patch, so the exact-plane path would never be reached and an
  -- empty answer would prove nothing.

  local RHINO = "crates/cadaclysm-acis/tests/fixtures/rhino/"

  --- The body node above the lump holds no shape of its own; the first node with extent is the part.
  local function silhouette_part(scene)
    for _, n in ipairs(scene.nodes) do
      local b = n.bounds64
      for i = 1, 3 do
        if b.max[i] - b.min[i] > 0 then return n end
      end
    end
    error("the fixture has no part with extent")
  end

  t.test("a sphere's silhouette sits on it, in tables of the documented lengths", function()
    local scene = cadaclysm.open(t.fixture(RHINO .. "sphere.sat"))
    local node = silhouette_part(scene)
    local words = { view = "iso", tolerance = 0.1, size = { 1000, 1000 } }
    local rim = node:silhouette_beziers(words)
    t.ok(rim.count > 0, "a sphere gave no rim")
    t.eq(#rim.points, rim.count * 12)
    t.eq(#rim.weights, rim.count * 4)
    for k, w in ipairs(rim.weights) do t.ok(w > 0 and w < math.huge, "weight " .. k .. " is not finite and positive") end
    -- Every control point lies within the library's fit budget of the sphere, at the bounds radius from the
    -- bounds centre. That is NOT because control points lie on the sphere: the silhouette curve does, but a
    -- cubic's interior control points do not. Here they stray up to 3.0e-3, while the end points are on it
    -- to about 1e-14 -- a Bezier interpolates its first and last control point, so for a curve lying on the
    -- sphere those two lie on it exactly. It holds because the arcs are short (half a unit on a radius of
    -- 10), and the budget is the tolerance the library fits the CURVE to, not its control polygon. The
    -- margin is narrow: the curve itself uses nearly the whole budget (3.42e-3 against 3.46e-3), since the
    -- lattice's spacing became a length in space (44efabc88); before, a lattice ten times too fine left it
    -- at 1e-4. So this catches a displaced
    -- or scaled result and a wildly mis-strided unpack. It is blind to a one-CONTROL-POINT slip of the
    -- unpack: that is a shift of 3 doubles, so every point is replaced by ANOTHER control point, which
    -- lies within the same budget, and the worst deviation is the same before and after (3.04e-3 here
    -- on iso, against a budget of about 3.5e-3). A one-DOUBLE slip is another matter: it mixes
    -- coordinates across neighbouring points, leaves the sphere, and is caught (0.87 on iso, 8.8 on
    -- front). The chaining assertion below is what catches the one-control-point slip. The budget also
    -- does NOT pin the eye (a silhouette point is a point of the surface, so it is on the sphere from any
    -- view), the weights (all 1.0 on this fixture) or the radius separately from the centre.
    -- The bound is the library's own budget, `world_tolerance`: extent * (tolerance / width), read off the
    -- options this call was given (`words`, above) rather than copied from their defaults; the node's
    -- bounds diagonal stands in for the extent.
    local b = node.bounds64
    local centre, size = {}, {}
    for i = 1, 3 do
      centre[i] = (b.min[i] + b.max[i]) / 2
      size[i] = b.max[i] - b.min[i]
    end
    local radius = size[1] / 2
    local budget = math.sqrt(size[1] ^ 2 + size[2] ^ 2 + size[3] ^ 2) * (words.tolerance / words.size[1])
    local worst = 0
    for k = 0, rim.count * 4 - 1 do
      local dx, dy, dz = rim.points[k * 3 + 1] - centre[1], rim.points[k * 3 + 2] - centre[2], rim.points[k * 3 + 3] - centre[3]
      worst = math.max(worst, math.abs(math.sqrt(dx * dx + dy * dy + dz * dz) - radius))
    end
    t.ok(radius > 0 and worst <= budget, ("control points stray %g from the bounds centre's radius %g, past the budget %g")
      :format(worst, radius, budget))
    -- Chaining, the assertion that sees an offset slip. The arcs come back in runs, not as one ordered
    -- traversal, so "every arc ends where the next begins" is false: on this fixture 232 of the 235
    -- consecutive pairs have the last control point of one arc equal to the first of the next, to 1e-9 per
    -- coordinate (each of x, y and z is tested, so a passing pair can be up to 1.73e-9 apart): four runs,
    -- the three breaks each a jump of 17 to 20 to the next run's start. A read
    -- shifted by a double or by a control point leaves none (0 of 235), so a slip takes the count from
    -- over two hundred to zero. The count varies with how the sphere is tessellated; what makes a lower
    -- bound of 80 safe is not that it cannot drift but that it sits about three times below the count on
    -- this fixture. It has drifted once: the bound was 400 against 1206 of 1209 until the lattice's
    -- spacing became a length in space (44efabc88) and the same four runs came back in arcs five times
    -- longer. Every slip quoted here is a wrap-around, so the length and the count are preserved and
    -- each denominator stays the unshifted pair count.
    -- The front view's figures are a measurement no test chains, kept because they explain the
    -- threshold: there the property is much weaker (96 of 173 pairs, 55%, against 98.7% here;
    -- 0 after a one-double or a one-control-point slip; 95 of 173 after a whole-curve slip), which
    -- is why the bound is 80 and not near 230.
    -- Its limit: a shift by a whole CURVE (12 doubles) keeps the chaining (231 of 235 still chain
    -- here) and is NOT caught: it survives because the chaining is preserved. A wrap-around slip of
    -- that size reads only inside the allocation, so it is reachable and silent.
    local chained = 0
    for c = 0, rim.count - 2 do
      local last, first = c * 12 + 9, (c + 1) * 12
      if math.abs(rim.points[last + 1] - rim.points[first + 1]) <= 1e-9
          and math.abs(rim.points[last + 2] - rim.points[first + 2]) <= 1e-9
          and math.abs(rim.points[last + 3] - rim.points[first + 3]) <= 1e-9 then
        chained = chained + 1
      end
    end
    t.ok(chained >= 80, ("only %d of %d consecutive arcs chain (last control point = the next one's first), want at least 80")
      :format(chained, rim.count - 1))
    scene:close()
  end)

  -- Asked larger first, so the second call refills the same slot in place: iso gives more curves
  -- than front (236 against 174 here), so a view would show the second answer through the head of
  -- the first. The reverse order can pass with a view. It was front first until the lattice's spacing
  -- became a length in space (44efabc88): front gave 1248 against iso's 1210 then.
  t.test("the answer is the caller's own: a later call on the scene leaves it alone", function()
    local scene = cadaclysm.open(t.fixture(RHINO .. "sphere.sat"))
    local node = silhouette_part(scene)
    local first = node:silhouette_beziers({ view = "iso" })
    local kept_points, kept_weights = {}, {}
    for i = 1, first.count * 12 do kept_points[i] = first.points[i] end
    for i = 1, first.count * 4 do kept_weights[i] = first.weights[i] end
    local kept_count = first.count
    local second = node:silhouette_beziers({ view = "front" })
    t.ok(second.count > 0, "the second view gave no rim")
    t.ok(second.count <= kept_count, ("the larger answer must come first (iso %d, front %d)"):format(kept_count, second.count))
    local differs = second.count ~= kept_count
    for i = 1, math.min(second.count * 12, kept_count * 12) do
      if second.points[i] ~= kept_points[i] then differs = true; break end
    end
    t.ok(differs, "the two views gave the same silhouette, so this cannot tell a copy from a view")
    t.eq(first.count, kept_count)
    for i = 1, kept_count * 12 do
      if first.points[i] ~= kept_points[i] then error("the first answer's point " .. i .. " changed under the second call") end
    end
    for i = 1, kept_count * 4 do
      if first.weights[i] ~= kept_weights[i] then error("the first answer's weight " .. i .. " changed under the second call") end
    end
    scene:close()
  end)

  t.test("an infinite tolerance is refused, and an all-planar body is the empty answer after it", function()
    local scene = cadaclysm.open(t.fixture(RHINO .. "box-chamfer-all.blacksmith.stp"))
    local node = silhouette_part(scene)
    local e = t.raises(function() node:silhouette_beziers({ tolerance = math.huge }) end, "silhouette: ")
    t.eq(getmetatable(e), cadaclysm.CadaclysmError, "a refusal is a CadaclysmError")
    -- The refusal above left its reason in the thread's error slot; the empty answer must not
    -- read it as its own.
    local none
    t.ok(pcall(function() none = node:silhouette_beziers() end), "an empty silhouette is an answer, not an error")
    t.eq(none.count, 0)
    t.eq(#none.points, 0)
    t.eq(#none.weights, 0)
    scene:close()
  end)
end
