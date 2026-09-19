# The cadaclysm nut, built by the blacksmith kernel: `godot --path project
# res://examples/nut/nut.tscn`. S writes the exact solid to nut.stp.
extends Node3D

const R := 60.0        # hexagon corner radius, mm
const BORE := 30.0     # bore radius
const THICK := 46.0    # thickness
const CONE := 50.0     # where each chamfer cone meets its ledge
const DEPTH := 5.0     # the chamfer, 45 degrees

var solid: CadaclysmSolid

func nut() -> CadaclysmSolid:
	# The hexagon, a corner on +X, extruded up Z.
	var hexagon := CadaclysmProfile.regular_polygon(Vector2.ZERO, R, 6)
	var hex := CadaclysmSolid.extrude(hexagon, CadaclysmFrame.xy(), THICK)
	# What a lathe would leave: drawn as (radius, height) in the XZ plane and turned
	# about Z -- the bore inside, and at each end a 45-degree chamfer out to a ledge.
	var profile := CadaclysmProfile.polygon([
		Vector2(BORE, 0), Vector2(CONE - DEPTH, 0), Vector2(CONE, DEPTH), Vector2(R + 10, DEPTH),
		Vector2(R + 10, THICK - DEPTH), Vector2(CONE, THICK - DEPTH), Vector2(CONE - DEPTH, THICK),
		Vector2(BORE, THICK)])
	var turned := CadaclysmSolid.revolve_in_plane(profile, CadaclysmFrame.xz(), Vector2(0, 0), Vector2(0, 1), TAU)
	# The nut is what both keep.
	return hex.common(turned)

func _ready() -> void:
	var started := Time.get_ticks_usec()
	solid = nut()
	var took := (Time.get_ticks_usec() - started) / 1000.0
	var upright := solid.rotate(Vector3.ZERO, Vector3.RIGHT, -PI / 2)    # Z up to Y up
	$Millimetres/Body.mesh = upright.array_mesh(0.02)
	$Millimetres/Edges.mesh = upright.edge_mesh(0.02)
	$Camera.frame($Millimetres.transform * upright.bounds)             # the box in metres
	$Hud/Title.text = "%d faces, built in %.0f ms" % [solid.faces, took]

func _unhandled_key_input(event: InputEvent) -> void:
	if event.pressed and event.keycode == KEY_S:
		var written := solid.step("nut.stp")
		$Hud/Keys.text = "wrote nut.stp" if written else Cadaclysm.last_error()
