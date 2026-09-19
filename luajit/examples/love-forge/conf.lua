function love.conf(t)
  t.window.title = "cadaclysm + LÖVE: the blacksmith"
  t.window.width, t.window.height = 1280, 720
  t.window.depth = 24 -- 3D needs a depth buffer, which LÖVE leaves off by default
  t.window.msaa = 4
end
