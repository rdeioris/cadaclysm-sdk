-- Desktop by default. CADACLYSM_LOVR_VR=1 turns the headset on, and the model is
-- then shown at table-top size in front of you rather than at its real size.
-- CADACLYSM_LOVR_BENCH=1 turns vsync off so `--bench` measures the frame rate.
function lovr.conf(t)
  t.identity = "cadaclysm-lovr"
  t.window.title = "cadaclysm + LÖVR"
  t.window.width = 1280
  t.window.height = 800
  t.window.resizable = true
  t.modules.headset = os.getenv("CADACLYSM_LOVR_VR") == "1"
  t.modules.audio = false
  t.modules.physics = false
  t.graphics.vsync = os.getenv("CADACLYSM_LOVR_BENCH") ~= "1"
end
