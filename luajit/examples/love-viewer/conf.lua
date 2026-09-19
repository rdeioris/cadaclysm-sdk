function love.conf(t)
  t.identity = "cadaclysm-love"
  t.version = "11.5"
  t.window.title = "cadaclysm + LÖVE"
  t.window.width = 1280
  t.window.height = 800
  t.window.resizable = true
  t.window.depth = 24 -- the 3D view needs a depth buffer, which LÖVE leaves off by default
  t.window.msaa = 4
  t.modules.audio = false
  t.modules.sound = false
  t.modules.physics = false
  t.modules.joystick = false
end
