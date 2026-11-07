-- The document on the real kernel: Python's document tests (test_cadaclysm_blacksmith.py, from
-- `plate_document` to the building documents) ported to the JSON-text shape -- ops go in as JSON
-- text, and what comes back as JSON text is checked by substring and pattern.
local bs = require("cadaclysm_blacksmith")

-- Python's `plate_document`: a 10 x 10 rectangle `r1` and its 10 mm extrusion `x1`.
local function plate()
  local doc = bs.Document.new("mm")
  doc:apply('{"op": "add", "node": {"id": "r1", "kind": "profile.rect", "w": 10, "h": 10}}')
  doc:apply('{"op": "add", "node": {"id": "x1", "kind": "solid.extrude", "profile": "r1", "frame": "xy", "distance": 10}}')
  return doc
end

local function add(doc, node, message)
  return doc:apply('{"op": "add", "node": ' .. node .. '}', message)
end

local function set(doc, id, fields)
  return doc:apply('{"op": "set", "id": "' .. id .. '", "fields": ' .. fields .. '}')
end

local function has(text, needle) return text:find(needle, 1, true) ~= nil end

local function count(text, needle)
  local n, at = 0, 1
  while true do
    local i = text:find(needle, at, true)
    if not i then return n end
    n, at = n + 1, i + #needle
  end
end

-- The `state` of every row of a status text, in order.
local function states(status)
  local out = {}
  for s in status:gmatch('"state": "(%a+)"') do out[#out + 1] = s end
  return table.concat(out, ",")
end

-- A log's or the tips' commits, in order: `{id, parents = {...}, message, ops}`, `ops` the
-- commit's own text of its ops.
local function commits(text)
  local starts = {}
  local at = 1
  while true do
    local i, _, id = text:find('{"id": "([^"]+)", "parents"', at)
    if not i then break end
    starts[#starts + 1] = { i = i, id = id }
    at = i + 1
  end
  local out = {}
  for k, s in ipairs(starts) do
    local chunk = text:sub(s.i, starts[k + 1] and starts[k + 1].i - 1 or #text)
    local parents = {}
    for p in chunk:match('"parents": (%b[])'):gmatch('"([^"]+)"') do parents[#parents + 1] = p end
    out[k] = { id = s.id, parents = parents, message = chunk:match('^{"id": "[^"]+", "parents": %b[], "message": "([^"]*)"'),
               ops = chunk:match('"ops": (%b[])') }
  end
  return out
end

local function ids(list)
  local out = {}
  for i, c in ipairs(list) do out[i] = c.id end
  return table.concat(out, ",")
end

-- The branch list read: `branch` (nil when detached), `head`, `can_undo`, `can_redo`, and
-- `branches`, name to tip.
local function branch_list(doc)
  local text = doc:branches()
  local map, names = {}, {}
  for name, tip in text:match('"branches": (%b{})'):gmatch('"([^"]+)": "([^"]+)"') do
    map[name] = tip
    names[#names + 1] = name
  end
  table.sort(names)
  return {
    branch = text:match('"branch": "([^"]+)"'),
    head = text:match('"head": "([^"]+)"'),
    can_undo = text:match('"can_undo": (%a+)') == "true",
    can_redo = text:match('"can_redo": (%a+)') == "true",
    branches = map,
    names = table.concat(names, ","),
  }
end

local function volume(doc, id) return doc:result_solid(id):mass().volume end
local function there(doc, id) return doc:result_kind(id) ~= "none" end

local function same_rgb(a, b)
  if a == nil or b == nil then return a == b end
  for i = 1, 3 do
    if math.abs(a[i] - b[i]) > 1e-12 then return false end
  end
  return true
end

local function write(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

-- Python's `bim_wall_document`: a level, a wall type and one 4 m wall.
local function bim_wall()
  local doc = bs.Document.new_bim("mm")
  doc:apply([[{"op": "batch", "ops": [
    {"op": "add", "node": {"id": "l0", "kind": "bim.level", "name": "Ground"}},
    {"op": "add", "node": {"id": "part", "kind": "bim.wall_type", "name": "Partition",
                           "layers": [{"material": "block", "thickness": 100, "function": "structure"}]}},
    {"op": "add", "node": {"id": "w1", "kind": "bim.wall", "level": "l0", "type": "part", "a": [0, 0], "b": [4000, 0]}}]}]])
  return doc
end

-- Python's `test_document_result_types` document.
local function result_types()
  local doc = bs.Document.new()
  add(doc, '{"id": "r", "kind": "profile.rect", "w": 40, "h": 30}')
  add(doc, '{"id": "c", "kind": "profile.circle", "r": 5}')
  add(doc, '{"id": "m", "kind": "profile.translate", "profile": "c", "by": [20, 0]}')
  add(doc, '{"id": "pieces", "kind": "profile.pieces", "profile": "r", "cutters": ["m"]}')
  add(doc, '{"id": "k", "kind": "curve.nurbs", "points": [[0, 0, 0], [10, 5, 0], [20, -5, 0], [30, 0, 0]]}')
  add(doc, '{"id": "cage", "kind": "subd.cuboid", "size": [20, 10, 5], "segments": [2, 1, 1]}')
  add(doc, '{"id": "e", "kind": "solid.extrude", "profile": "r", "frame": "xy", "distance": 2}')
  add(doc, '{"id": "mass", "kind": "measure.mass", "solid": "e"}')
  return doc
end

return function(t)
  t.test("document: P evaluates, and a result outlives the edit that replaced it", function()
    local doc = plate()
    t.eq(states(doc:evaluate()), "ok,ok")
    t.eq(doc:errors(), "[]")
    local solid = doc:result_solid("x1")
    t.eq(getmetatable(solid), bs.Solid)
    t.eq(solid.faces, 6)
    t.eq(getmetatable(doc:result_profile("r1")), bs.Profile)
    t.eq(doc:result_kind("nope"), "none")
    t.raises(function() doc:value("nope") end, "^document_value: ")
    t.raises(function() doc:result_solid("nope") end, "^document_result_solid: ")
    t.raises(function() doc:result_profile("x1") end, "^document_result_profile: ")
    local changed = set(doc, "x1", '{"distance": 20}')
    t.ok(has(changed, '"changed": ["x1"]'), changed)
    t.eq(solid.faces, 6)
    t.near(solid:mass().volume, 1000, 1e-6)
    t.near(volume(doc, "x1"), 2000, 1e-6)
  end)

  t.test("document: save, load and open give the same text; bad text and units refused", function()
    local doc = plate()
    local first = doc:save()
    local loaded = bs.Document.load(first)
    t.eq(loaded:save(), first)
    t.eq(states(loaded:evaluate()), "ok,ok")
    t.eq(loaded:result_solid("x1").faces, 6)
    local path = t.tmp("plate.json")
    write(path, first)
    t.eq(bs.Document.open(path):save(), first)
    t.eq(getmetatable(bs.Document("cm")), bs.Document, "Document(units) is Document.new")
    t.raises(function() bs.Document.load("not a document") end, "^document_load: ")
    t.raises(function() bs.Document.new("furlongs") end, "^document_new: ")
  end)

  t.test("document: undo takes the node away and redo puts it back", function()
    local doc = plate()
    local b = branch_list(doc)
    t.ok(b.can_undo and not b.can_redo)
    t.eq(doc:undo(), true)
    t.ok(not there(doc, "x1") and there(doc, "r1"))
    t.ok(branch_list(doc).can_redo)
    t.eq(doc:redo(), true)
    t.ok(there(doc, "x1"))
    -- Nothing more to redo: false, not a failure.
    t.eq(doc:redo(), false)
    t.ok(not branch_list(doc).can_redo)
    t.eq(doc:undo(), true)
    t.eq(doc:undo(), true)
    t.ok(not branch_list(doc).can_undo)
    t.eq(doc:undo(), false)
    t.eq(doc:evaluate(), "[]", "back at the root: no nodes")
    t.ok(branch_list(doc).can_redo, "both commits to redo")
  end)

  t.test("document: a refusal leaves the document unchanged; a cascade is one commit", function()
    local doc = plate()
    local before, log = doc:save(), doc:log()
    local err = t.raises(function() doc:apply('{"op": "remove", "id": "r1"}') end)
    t.eq(getmetatable(err), bs.BuildError)
    t.eq(tostring(err), "document_apply: r1 is read by x1")
    t.eq(doc:save(), before)
    t.eq(doc:log(), log)
    t.raises(function() add(doc, '{"kind": "no.such.kind"}') end, "^document_apply: ")
    doc:apply('{"op": "remove", "id": "r1", "cascade": true}')
    t.ok(not there(doc, "r1") and not there(doc, "x1"))
    t.eq(#commits(doc:log()), #commits(log) + 1)
    t.raises(function() doc:apply("{not json") end, "^document_apply: ")
  end)

  t.test("document: values, laced lists and the kinds", function()
    local doc = plate()
    add(doc, '{"id": "m", "kind": "measure.mass", "solid": "x1"}')
    local mass = doc:value("m")
    t.near(tonumber(mass:match('"volume": ([-%deE.+]+)')), 1000, 1e-6)

    local laced = bs.Document.new()
    add(laced, '{"id": "w", "kind": "value", "value": "=range(10, 40, 10)"}')
    add(laced, '{"id": "c", "kind": "solid.cuboid", "x": "=w", "y": "=[1, 2]", "z": 1}')
    add(laced, '{"id": "x", "kind": "solid.cuboid", "x": "=w", "y": "=[1, 2]", "z": 1, "lacing": "cross"}')
    local w = {}
    for n in laced:value("w"):gmatch("[-%d.]+") do w[#w + 1] = tonumber(n) end
    t.eq(table.concat(w, ","), "10,20,30")
    t.eq(laced:result_kind("c"), "list")
    for i, want in ipairs({ 10, 40, 60 }) do
      t.near(volume(laced, "c#" .. (i - 1)), want, 1e-6, "longest: the depths' last item repeats")
    end
    t.eq(laced:result_kind("c#3"), "none")
    t.eq(getmetatable(laced:result_solid("c#1")), bs.Solid)
    for i, want in ipairs({ 10, 20, 30, 20, 40, 60 }) do t.near(volume(laced, "x#" .. (i - 1)), want, 1e-6) end
    t.eq(bs.Document.load(laced:save()):save(), laced:save())

    local kinds = bs.Document.kinds()
    t.ok(count(kinds, '"cost":') > 100, "more than 100 kinds")
    for _, name in ipairs({ "profile.rect", "solid.extrude", "measure.mass" }) do
      t.ok(has(kinds, '"name": "' .. name .. '"'), name)
    end
    local bad = bs.Document.new()
    bad:apply('{"op": "param", "name": "k", "value": -5}')
    add(bad, '{"id": "bad", "kind": "profile.rect", "w": "=k", "h": 1}')
    local errors = bad:errors()
    t.eq(count(errors, '"id":'), 1, errors)
    t.ok(errors:match('^%[{"id": "bad", "state": "error", "message": "[^"]+"'), errors)
    t.ok(bad:evaluate(true):match('^%[{"id": "bad"'), "the cheap evaluation's first row")
  end)

  t.test("document: a param op drives a node; a parameter a node reads cannot go", function()
    local doc = bs.Document.new()
    t.eq(doc:params(), "{}")
    doc:apply('{"op": "param", "name": "w", "value": 200}')
    t.eq(doc:params(), '{"w": 200}')
    add(doc, '{"id": "r", "kind": "profile.rect", "w": "=w", "h": 100}')
    add(doc, '{"id": "e", "kind": "solid.extrude", "profile": "r", "frame": "xy", "distance": 10}')
    t.near(volume(doc, "e"), 200 * 100 * 10, 1e-6)
    doc:apply('{"op": "param", "name": "w", "value": 300}')
    t.near(volume(doc, "e"), 300 * 100 * 10, 1e-6)
    t.eq(commits(doc:log())[1].ops, '[{"op": "param", "name": "w", "value": 300}]')
    local before = doc:save()
    t.raises(function() doc:apply('{"op": "param", "name": "w", "value": null}') end, "^document_apply: ")
    t.eq(doc:save(), before)
    t.eq(doc:params(), '{"w": 300}')
  end)

  t.test("document: branches and the log", function()
    local doc = plate()
    local b = branch_list(doc)
    t.eq(b.branch, "main")
    t.eq(b.names, "main")
    t.eq(b.branches.main, b.head)
    doc:branch_new("idea")
    b = branch_list(doc)
    t.eq(b.branch, "idea")
    t.eq(b.names, "idea,main")
    t.eq(b.branches.idea, b.branches.main)
    t.eq(ids(commits(doc:log("main"))), ids(commits(doc:log())))
    doc:switch("main")
    doc:branch_rename("idea", "plan")
    t.eq(branch_list(doc).names, "main,plan")
    doc:branch_delete("plan")
    t.eq(branch_list(doc).names, "main")
    t.raises(function() doc:branch_delete("plan") end, "^document_branch_delete: ")
    t.raises(function() doc:branch_delete("main") end, "^document_branch_delete: ")
    t.raises(function() doc:branch_rename("plan", "x") end, "^document_branch_rename: ")
    t.raises(function() doc:log("plan") end, "^document_log: ")
    t.raises(function() doc:switch("nowhere") end, "^document_branch_switch: ")
    t.eq(doc:tips(), "[]")
    local log = commits(doc:log())
    local root = log[#log].id
    doc:branch_new("early", root) -- with `at` the head stays where it is
    b = branch_list(doc)
    t.eq(b.branches.early, root)
    t.eq(b.branch, "main")
  end)

  t.test("document: the log is newest first, with its messages", function()
    local doc = bs.Document.new()
    add(doc, '{"id": "r1", "kind": "profile.rect", "w": 1, "h": 1}', "first")
    add(doc, '{"id": "r2", "kind": "profile.rect", "w": 2, "h": 2}')
    add(doc, '{"id": "r3", "kind": "profile.rect", "w": 3, "h": 3}', "third")
    local log = commits(doc:log())
    t.eq(#log, 4)
    t.eq(log[1].message, "third")
    t.eq(log[2].message, nil)
    t.eq(log[3].message, "first")
    t.eq(log[4].message, nil)
    for i, id in ipairs({ "r3", "r2", "r1" }) do t.eq(log[i].ops:match('"node": {"id": "(%w+)"'), id) end
    t.eq(log[1].id, branch_list(doc).head)
    t.eq(table.concat(log[1].parents, ","), log[2].id)
    t.eq(#log[4].parents, 0)
  end)

  t.test("document: switch by branch name and by commit id", function()
    local doc = plate()
    local first = commits(doc:log())[2].id -- the commit that added r1
    doc:branch_new("side")
    add(doc, '{"id": "c1", "kind": "profile.circle", "r": 2}')
    t.eq(branch_list(doc).branch, "side")
    t.ok(there(doc, "c1"))
    doc:switch("main")
    t.eq(branch_list(doc).branch, "main")
    t.ok(not there(doc, "c1") and there(doc, "x1"))
    doc:switch("side")
    t.ok(there(doc, "c1"))
    -- A commit id detaches the head.
    doc:switch(first)
    local b = branch_list(doc)
    t.eq(b.branch, nil)
    t.ok(b.head == first and has(doc:branches(), '"branch": null'))
    t.ok(there(doc, "r1") and not there(doc, "x1") and not there(doc, "c1"))
    t.ok(b.branches.main ~= first and not b.can_redo, "no branch to redo along")
    doc:switch("main")
    t.eq(branch_list(doc).branch, "main")
    t.ok(there(doc, "x1"))
  end)

  t.test("document: the tips after an undo and an edit", function()
    local doc = plate()
    t.eq(doc:tips(), "[]")
    local old = commits(doc:log())[1]
    t.eq(doc:undo(), true)
    add(doc, '{"id": "c1", "kind": "profile.circle", "r": 2}', "other way")
    local tips = commits(doc:tips())
    t.eq(ids(tips), old.id)
    t.eq(tips[1].ops:match('"node": {"id": "(%w+)"'), "x1", "a tip is a whole commit")
    local log = commits(doc:log())
    t.eq(table.concat(tips[1].parents, ","), log[2].id)
    t.eq(table.concat(tips[1].parents, ","), table.concat(old.parents, ","))
    t.eq(log[1].message, "other way")
    t.ok(log[1].id ~= old.id)
    -- The abandoned line is still reachable by its commit id.
    doc:switch(old.id)
    t.ok(there(doc, "x1") and not there(doc, "c1"))
    doc:switch("main")
    doc:branch_new("kept", old.id) -- naming the line takes it off the tips
    t.eq(doc:tips(), "[]")
  end)

  t.test("document: a batch is one commit, and an empty one records nothing", function()
    local doc = plate()
    local before = #commits(doc:log())
    local got = doc:batch("slot and fillet", function()
      add(doc, '{"id": "c1", "kind": "profile.circle", "r": 2}')
      add(doc, '{"id": "c2", "kind": "profile.circle", "r": 3}')
      t.ok(there(doc, "c2"), "the ops are live inside the batch")
      return "body's"
    end)
    t.eq(got, "body's", "the body's results come back")
    local log = commits(doc:log())
    t.eq(#log, before + 1)
    t.eq(log[1].message, "slot and fillet")
    t.eq(count(log[1].ops, '"op":'), 2)
    t.eq(doc:undo(), true)
    t.ok(not there(doc, "c1") and not there(doc, "c2"))
    doc:batch(function() end)
    t.eq(#commits(doc:log()), before, "an empty batch records nothing")
  end)

  t.test("document: a batch rolls back on an error and passes the error on", function()
    local doc = plate()
    local before, log = doc:save(), doc:log()
    local err = t.raises(function()
      doc:batch("never", function()
        add(doc, '{"id": "c1", "kind": "profile.circle", "r": 2}')
        set(doc, "r1", '{"w": 20}')
        error("boom", 0)
      end)
    end)
    t.eq(err, "boom")
    t.eq(doc:save(), before)
    t.eq(doc:log(), log)
    t.ok(not there(doc, "c1"))
    t.near(volume(doc, "x1"), 1000, 1e-6)
    -- A refusal inside a batch is the same: it propagates, and the batch is undone.
    t.raises(function()
      doc:batch(function()
        add(doc, '{"id": "c1", "kind": "profile.circle", "r": 2}')
        doc:apply('{"op": "remove", "id": "r1"}')
      end)
    end, "^document_apply: ")
    t.eq(doc:save(), before)
    -- The batch is closed, so a new one opens.
    doc:batch("again", function() add(doc, '{"id": "c1", "kind": "profile.circle", "r": 2}') end)
    t.eq(commits(doc:log())[1].message, "again")
    -- The body's error is the one reported, even when the clean-up itself is refused.
    err = t.raises(function()
      doc:batch(function()
        doc:close() -- nothing left to abort
        error("boom", 0)
      end)
    end)
    t.eq(err, "boom")
    doc = plate()
    doc:batch(function()
      t.raises(function() doc:batch(function() end) end, "^document_batch_begin: ")
    end)
  end)

  t.test("document: a preview is applied and taken back; drag frames replace each other", function()
    local doc = plate()
    local before, log = doc:save(), doc:log()
    doc:preview(function()
      set(doc, "r1", '{"w": 30}')
      add(doc, '{"id": "c1", "kind": "profile.circle", "r": 2}')
      t.near(volume(doc, "x1"), 30 * 10 * 10, 1e-6)
      t.ok(there(doc, "c1"))
    end)
    t.eq(doc:save(), before, "never recorded")
    t.eq(doc:log(), log)
    t.near(volume(doc, "x1"), 1000, 1e-6)
    t.ok(not there(doc, "c1"))
    local err = t.raises(function()
      doc:preview(function()
        set(doc, "r1", '{"w": 40}')
        error("drag cancelled", 0)
      end)
    end)
    t.eq(err, "drag cancelled")
    t.eq(doc:save(), before)
    t.near(volume(doc, "x1"), 1000, 1e-6)
    t.ok(branch_list(doc).can_undo, "the preview left the history alone")
    err = t.raises(function() -- a refused clean-up never hides the body's error
      doc:preview(function()
        doc:close()
        error("drag cancelled", 0)
      end)
    end)
    t.eq(err, "drag cancelled")
    doc = plate()
    doc:preview(function()
      t.raises(function() doc:preview(function() end) end, "^document_preview_begin: ")
    end)

    -- The editor's drag: frames with no scope, each relative to the state before the drag.
    doc = plate()
    before, log = doc:save(), doc:log()
    local changed = doc:preview_frame('{"op": "set", "id": "r1", "fields": {"w": 30}}')
    t.ok(has(changed, '"changed": ["r1"]'), changed)
    t.near(volume(doc, "x1"), 3000, 1e-6)
    doc:preview_frame('{"op": "set", "id": "r1", "fields": {"w": 40}}')
    t.near(volume(doc, "x1"), 4000, 1e-6, "a frame replaces the last, it does not stack")
    doc:end_preview()
    t.near(volume(doc, "x1"), 1000, 1e-6)
    t.eq(doc:save(), before)
    t.eq(doc:log(), log)
  end)

  t.test("document: every result kind reads as its own type", function()
    local doc = result_types()
    t.eq(count(doc:evaluate(), '"state": "ok"'), 8)
    t.eq(doc:result_kind("r"), "profile")
    t.eq(getmetatable(doc:result_profile("r")), bs.Profile)
    t.eq(doc:result_kind("pieces"), "profiles")
    local pieces = doc:result_profiles("pieces")
    t.ok(#pieces >= 2)
    for _, p in ipairs(pieces) do t.eq(getmetatable(p), bs.Profile) end
    t.eq(doc:result_kind("k"), "nurbs")
    local curve = doc:result_nurbs_curve("k")
    t.eq(getmetatable(curve), bs.NurbsCurve)
    t.eq(curve.degree, 3)
    t.eq(doc:result_kind("cage"), "subd")
    t.eq(getmetatable(doc:result_subd("cage")), bs.Subd)
    t.raises(function() doc:result_subd("k") end, "^document_result_subd: ")
    t.raises(function() doc:result_nurbs_curve("cage") end, "^document_result_nurbs_curve: ")
    add(doc, '{"id": "outline", "kind": "curve.polyline", "points": [[0, 0], [10, 0], [10, 5], [3, 9]], "closed": true}')
    t.eq(doc:result_kind("outline"), "curve")
    t.eq(doc:value("outline"), '{"type": "curve", "closed": true}', "a plane curve has no handle: its value")
    t.eq(doc:result_kind("mass"), "value")
    t.ok(doc:value("mass"):match("^{"), "a record")
    t.eq(doc:result_kind("missing"), "none")
    t.raises(function() doc:result_profiles("e") end, "^document_result_profile_count: ")
  end)

  t.test("document: holds a solid and a profile the caller already has", function()
    local part = bs.Solid.cuboid(40, 30, 20):cut(bs.Solid.cylinder(5, 60):translate(0, 0, -20))
    local slot = bs.Profile.slot({ 0, 0 }, 30, 5):with_hole(bs.Profile.circle(2))
    local doc = bs.Document.new()
    local held = doc:add_solid(part)
    local outline = doc:add_profile(slot)
    t.eq(type(held), "string")
    t.ok(held ~= outline)
    add(doc, '{"id": "x", "kind": "solid.extrude", "profile": "' .. outline .. '", "distance": 4}')
    add(doc, '{"id": "c", "kind": "solid.cut", "target": "' .. held .. '", "tool": "x"}')
    t.eq(doc:errors(), "[]")
    -- The very body: the same tables, every number to the bit.
    t.eq(doc:result_solid(held):document_body(), part:document_body())
    t.eq(doc:result_solid(held):mass().volume, part:mass().volume)
    -- The profile is its segments, not a polyline: two arcs and the hole's circle.
    local path = slot:document_path()
    local outer, holes = path:match('^{"start": %b[], "segments": (%b[]), "holes": (%b[])')
    t.eq(count(outer, '"type": "arc"'), 2)
    t.eq(count(holes, '"start"'), 1)
    t.eq(doc:result_profile(outline):document_path(), path)
    local want = bs.Solid.extrude(slot, bs.Frame.xy(), 4)
    t.near(volume(doc, "x"), want:mass().volume, 1e-9 * want:mass().volume)
    t.ok(volume(doc, "c") < part:mass().volume)
    -- The text is in the file: it saves and loads back to the same document.
    local text = doc:save()
    t.eq(bs.Document.load(text):save(), text)
    t.eq(bs.Document.load(text):result_solid(held).faces, part.faces)
    local sheet = doc:add_solid(bs.Solid.face(bs.Profile.rect(10, 10), bs.Frame.xy()), true)
    t.ok(has(doc:save(), '"kind": "sheet.body"'))
    t.eq(doc:result_kind(sheet), "sheet")
    t.eq(doc:result_solid(sheet).faces, 1)
    t.raises(function() add(doc, '{"kind": "solid.body", "body": "not a body"}') end, "must be a body")
  end)

  t.test("document: held colours survive save and load", function()
    local red, green, blue, yellow, grey = { 1, 0, 0 }, { 0, 0.5, 0 }, { 0, 0, 1 }, { 1, 1, 0 }, { 0.25, 0.5, 0.75 }
    local part = bs.Solid.cuboid(1, 1, 1):coloured(red):coloured(green, 2):edges_coloured(blue):edges_coloured(yellow, { 3 })
    local slot = bs.Profile.slot({ 0, 0 }, 30, 5):coloured(grey)
    local doc = bs.Document.new()
    local held = doc:add_solid(part)
    local outline = doc:add_profile(slot)
    local plain = doc:add_profile(bs.Profile.rect(2, 1))
    local back = bs.Document.load(doc:save())
    local got = back:result_solid(held)
    t.ok(same_rgb(got.colour, red))
    t.ok(same_rgb(got:face_colour(2), green) and same_rgb(got:face_colour(0), red))
    t.ok(same_rgb(got:edge_colour(3), yellow) and same_rgb(got:edge_colour(0), blue))
    t.eq(got:document_body(), part:document_body())
    t.ok(same_rgb(back:result_profile(outline).colour, grey))
    t.eq(back:result_profile(plain).colour, nil)
    -- A body written without colours (an older document's) is uncoloured.
    local bare = part:document_body()
    for _, key in ipairs({ "colour", "face_colours", "edges_colour", "edge_colours" }) do
      bare = bare:gsub(', "' .. key .. '": %b[]', "")
    end
    t.ok(not has(bare, "colour"), "every colour key taken out")
    local id = add(back, '{"kind": "solid.body", "body": ' .. bare .. '}'):match('"added": %["([^"]+)"')
    t.eq(back:result_solid(id).colour, nil)
  end)

  t.test("document: a building document exports IFC, after a save and a load too", function()
    local doc = bim_wall()
    local options = '{"schema": "IFC2X3", "timestamp": 0}'
    local text = doc:export_ifc(options)
    t.ok(has(text, "IFCWALLSTANDARDCASE("))
    local saved = t.tmp("wall.json")
    write(saved, doc:save())
    t.eq(bs.Document.open_bim(saved):export_ifc(options), text)
    t.eq(bs.Document.load_bim(doc:save()):export_ifc(options), text)
    local exact = doc:export_ifc('{"geometry": "exact", "timestamp": 0, "name": "Wall"}')
    t.ok(has(exact, "IFCPROJECT(") and has(exact, "'Wall'") and exact ~= text)
  end)

  t.test("document: a refused export names its node", function()
    local doc = bim_wall()
    add(doc, '{"id": "d900", "kind": "bim.door_type", "width": 900, "height": 2100}')
    add(doc, '{"id": "o1", "kind": "bim.door", "host": "w1", "type": "d900", "joins": [], "offset": 3900}')
    local err = t.raises(function() doc:export_ifc('{"timestamp": 0}') end, '^bim_document_export_ifc: {"refusals": ')
    t.ok(tostring(err):find('"node": ?"o1"'), tostring(err))
    t.raises(function() bs.Document.new():export_ifc() end, "not a BIM document")
    t.raises(function() doc:export_ifc('{"schema": "IFC5"}') end, "IFC4 or IFC2X3")
  end)

  t.test("document: the building kinds, and a fresh project guid per document", function()
    local kinds = bs.Document.bim_kinds()
    for _, name in ipairs({ "bim.project", "bim.wall", "solid.extrude" }) do
      t.ok(has(kinds, '"name": "' .. name .. '"'), name)
    end
    t.ok(not has(bs.Document.kinds(), '"name": "bim.wall"'), "a plain document has no bim kinds")
    local function guid(doc) return doc:save():match('"kind": "bim.project"[^}]-"guid": "([^"]+)"') end
    local a, b = guid(bs.Document.new_bim()), guid(bs.Document.new_bim())
    t.eq(#a, 36)
    t.eq(a:sub(15, 15), "4")
    t.ok(a ~= b)
  end)

  t.test("document: results outlive the document; a closed one refuses", function()
    local doc = result_types()
    local solid, profile = doc:result_solid("e"), doc:result_profile("r")
    local curve, cage = doc:result_nurbs_curve("k"), doc:result_subd("cage")
    doc:close()
    collectgarbage()
    collectgarbage()
    t.near(solid:mass().volume, 40 * 30 * 2, 1e-6)
    t.ok(has(profile:document_path(), '"segments"'))
    t.eq(curve.degree, 3)
    t.ok(#cage.faces > 0)
    local err = t.raises(function() doc:save() end, "closed")
    t.eq(tostring(err), "document: closed")
    t.raises(function() doc:apply('{"op": "remove", "id": "r"}') end, "^document: closed")
    t.raises(function() doc:result_kind("r") end, "^document: closed")
    doc:close() -- twice is fine
    t.eq(tostring(doc), "Document(closed)")
    t.ok(tostring(bs.Document.new()):match("^Document%("))
  end)
end
