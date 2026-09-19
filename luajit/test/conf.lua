-- Headless in either host: the tests only need LuaJIT.
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
