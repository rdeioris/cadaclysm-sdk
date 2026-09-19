# A parametric flange, built by the blacksmith kernel while you watch:
# `godot --path project res://examples/forge/forge.tscn`. Up and down change the bolt
# holes, left and right the boss; S writes the exact solid to flange.stp.
extends Node3D

var holes := 6                  # the two parameters; the kernel works in millimetres
var boss := 14
var part: CadaclysmSolid
var bounds: AABB                # of the upright part, in millimetres

func flange() -> CadaclysmSolid:
	# A disc with a ring of bolt holes: one outline, extruded once.
	var outline := CadaclysmProfile.circle(40)
	for i in holes:
		var a := TAU * i / holes
		outline = outline.with_hole(CadaclysmProfile.circle(4).translate(30 * cos(a), 30 * sin(a)))
	var disc := CadaclysmSolid.extrude(outline, CadaclysmFrame.xy(), 8)
	# A boss on top, and a bore through both.
	var body := disc.join(CadaclysmSolid.cylinder(16, boss).translate(0, 0, 8)) \
		.cut(CadaclysmSolid.cylinder(9, boss + 40).translate(0, 0, -20))
	# Round the circle where the boss meets the disc: the one curved edge at z = 8, r = 16.
	var joint := []
	for edge in body.edges:
		var p: Vector3 = edge.segments[0]
		if not edge.is_line and absf(p.z - 8) < 1e-3 and absf(Vector2(p.x, p.y).length() - 16) < 1e-3:
			joint.append(edge)
	return body.fillet(joint, 3)

func rebuild() -> void:
	var started := Time.get_ticks_usec()
	part = flange()
	var took := (Time.get_ticks_usec() - started) / 1000.0
	var upright := part.rotate(Vector3.ZERO, Vector3.RIGHT, -PI / 2)   # Z up to Y up
	$Millimetres/Body.mesh = upright.array_mesh(0.02)
	$Millimetres/Edges.mesh = upright.edge_mesh(0.02)
	bounds = upright.bounds
	$Hud/Title.text = "%d holes, a %d mm boss: %d faces, built in %.0f ms" % [holes, boss, part.faces, took]

func _ready() -> void:
	rebuild()
	$Camera.frame($Millimetres.transform * bounds)     # the box in metres, as the scene is

func _unhandled_key_input(event: InputEvent) -> void:
	if not event.pressed:
		return
	match event.keycode:
		KEY_UP: holes = mini(holes + 1, 16)
		KEY_DOWN: holes = maxi(holes - 1, 3)
		KEY_RIGHT: boss = mini(boss + 2, 40)
		KEY_LEFT: boss = maxi(boss - 2, 4)
		KEY_S:
			part.step("flange.stp")
			return
		_: return
	rebuild()
