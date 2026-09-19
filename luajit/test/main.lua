--[[
The LuaJIT wrapper's tests: every `*_test.lua` beside this file, in any LuaJIT host.

    luajit test/main.lua [FILTER]     -- a plain LuaJIT
    lovec test [FILTER]               -- headless LÖVE (conf.lua turns the window off)
    lovr test [FILTER]                -- headless LÖVR

FILTER keeps only the tests whose `file: name` contains it; none left is a failure. The libraries are found as
cadaclysm.lua documents (CADACLYSM_LIBRARY, CADACLYSM_BLACKSMITH_LIBRARY, ...).
`CADACLYSM_TEST_LOG=file` also writes the report there -- LÖVR on Windows prints
to a console of its own. Exits 1 if any test failed.

A test file returns `function(t)` and registers its cases with `t.test(name, fn)`.
Inside a case: `t.ok(cond, message)`, `t.eq(actual, expected, message)`,
`t.near(actual, expected, tolerance, message)`, `t.raises(fn, pattern)` (returns the
error), `t.tmp(name)` (a fresh path under a temp directory) and `t.fixture(rel)`
(a path under the repository root; nil in an SDK checkout, an error when missing
in the repository).
]]

-- The working directory as the host sees it. On Windows, `cmd`'s own `cd`: a shell's
-- PWD there can be an MSYS path (/d/a/...) that a native luajit.exe cannot open.
local function cwd()
  if lovr then return lovr.filesystem.getWorkingDirectory() end
  if package.config:sub(1, 1) == "\\" and io.popen then
    local pipe = io.popen("cd")
    if pipe then
      local dir = pipe:read("*l")
      pipe:close()
      if dir and dir ~= "" then return dir end
    end
  end
  return os.getenv("PWD") or "."
end

local function absolute(p)
  p = p:gsub("\\", "/")
  if p:match("^%a:/") or p:match("^/") then return p end
  return cwd():gsub("\\", "/") .. "/" .. p
end

local here
if love then
  here = absolute(love.filesystem.getSource())
elseif lovr then
  here = absolute(lovr.filesystem.getSource())
else
  here = absolute(arg[0]):match("^(.*)/[^/]*$")
end
local wrapper_dir = here:match("^(.*)/[^/]*$")
local root = wrapper_dir:match("^(.*)/crates/") -- nil in an SDK checkout
package.path = wrapper_dir .. "/?.lua;" .. here .. "/?.lua;" .. package.path

local log = os.getenv("CADACLYSM_TEST_LOG") and assert(io.open(os.getenv("CADACLYSM_TEST_LOG"), "w"))
local function say(line)
  print(line)
  if log then
    log:write(line, "\n")
    log:flush()
  end
end

local filter
for _, a in ipairs(arg or {}) do
  if not a:match("^%-") and a ~= "test" and not a:match("[/\\]test$") and not a:match("main%.lua$") then filter = a end
end

-- ---- the assertion kit -------------------------------------------------------------

local cases = {}
local t = {}
local tmp_root = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/") .. "/cadaclysm-luajit-" .. os.time()
local tmp_made = false

function t.test(name, fn) cases[#cases + 1] = { name = name, fn = fn } end
function t.ok(cond, message)
  if not cond then error(message or "expected a true value", 2) end
end
function t.eq(actual, expected, message)
  if actual ~= expected then
    error(("%sexpected %s, got %s"):format(message and (message .. ": ") or "", tostring(expected), tostring(actual)), 2)
  end
end
function t.near(actual, expected, tolerance, message)
  if math.abs(actual - expected) > (tolerance or 1e-9) then
    error(("%sexpected %s +- %s, got %s"):format(message and (message .. ": ") or "", tostring(expected),
      tostring(tolerance), tostring(actual)), 2)
  end
end
function t.raises(fn, pattern)
  local ok, err = pcall(fn)
  if ok then error("expected an error" .. (pattern and (" matching '" .. pattern .. "'") or ""), 2) end
  if pattern and not tostring(err):find(pattern) then
    error(("expected an error matching '%s', got: %s"):format(pattern, tostring(err)), 2)
  end
  return err
end
function t.tmp(name)
  if not tmp_made then
    os.execute((package.config:sub(1, 1) == "\\" and 'mkdir "%s"' or 'mkdir -p "%s"'):format(
      package.config:sub(1, 1) == "\\" and tmp_root:gsub("/", "\\") or tmp_root))
    tmp_made = true
  end
  return tmp_root .. "/" .. name
end
-- Inside the repository a missing fixture is a failure (a test that returned early
-- would pass having checked nothing); in an SDK checkout there are none, so nil.
function t.fixture(rel)
  if not root then return nil end
  local p = root .. "/" .. rel
  local f = io.open(p, "rb")
  if not f then error("fixture missing: " .. p, 2) end
  f:close()
  return p
end

-- ---- run ---------------------------------------------------------------------------

local files = {}
for _, name in ipairs({ "reader_test", "blacksmith_test" }) do
  local f = io.open(here .. "/" .. name .. ".lua", "rb")
  if f then
    f:close()
    files[#files + 1] = name
  end
end

local passed, failed = 0, 0
say("host " .. (love and ("LÖVE " .. table.concat({ love.getVersion() }, ".", 1, 3))
  or lovr and ("LÖVR " .. table.concat({ lovr.getVersion() }, ".", 1, 3)) or jit.version))
for _, name in ipairs(files) do
  cases = {}
  local ok, err = pcall(function() require(name)(t) end)
  if not ok then
    say("FAIL  " .. name .. " did not load: " .. tostring(err))
    failed = failed + 1
  end
  for _, c in ipairs(cases) do
    if not filter or (name .. ": " .. c.name):find(filter, 1, true) then
      local good, why = xpcall(c.fn, debug.traceback)
      if good then
        passed = passed + 1
        say("ok    " .. name .. ": " .. c.name)
      else
        failed = failed + 1
        say("FAIL  " .. name .. ": " .. c.name .. "\n      " .. tostring(why):gsub("\n", "\n      "))
      end
    end
  end
end
collectgarbage()
say(("%d passed, %d failed"):format(passed, failed))
if passed + failed == 0 then say("FAIL  no test ran" .. (filter and (" (filter '" .. filter .. "')") or "")) failed = 1 end
-- os.exit rather than love/lovr.event.quit: LÖVR 0.19 exits 0 whatever code it is given.
os.exit(failed == 0 and 0 or 1)
