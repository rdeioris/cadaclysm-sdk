-- Headless: no window, no graphics, no audio -- the smoke only needs LuaJIT.
-- One file for both hosts, each of which only defines its own global.
if love then
  function love.conf(t)
    t.console = true
    t.window = nil
    t.modules.window = false
    t.modules.graphics = false
    t.modules.audio = false
    t.modules.sound = false
  end
end

if lovr then
  function lovr.conf(t)
    t.window = nil
    t.modules.graphics = false
    t.modules.headset = false
    t.modules.audio = false
    t.modules.physics = false
  end
end
