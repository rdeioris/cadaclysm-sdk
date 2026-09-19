# A drawing sheet from a CAD file: three views (ISO first angle), the overall sizes in
# millimetres and a title block. `godot --path project res://examples/drawing/drawing.tscn
# -- part.step`, or drop a file on the window.
extends Control

const INK := Color(0.11, 0.105, 0.10)
const PAPER := Color(0.955, 0.945, 0.915)

var sheet := {}

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	open(args[0] if args.size() > 0 else "res://examples/models/nut.step")
	get_window().files_dropped.connect(func(files): open(files[0]))
	resized.connect(queue_redraw)

func open(path: String) -> void:
	var scene := CadaclysmScene.open(path)              # metres, Y up
	if scene == null:
		push_error(Cadaclysm.last_error())
		return
	sheet = {
		"name": path.get_file(),
		"size": scene.bounds.size,                     # metres
		"front": scene.drawing("front"),               # every edge, seen from the front
		"top": scene.drawing("top"),
		"left": scene.drawing("left"),
	}
	scene.close()
	queue_redraw()

func _draw() -> void:
	var w := size.x
	var h := size.y
	draw_rect(Rect2(Vector2.ZERO, size), PAPER)
	draw_rect(Rect2(24, 24, w - 48, h - 48), INK, false, 2.0)     # the border
	if sheet.is_empty() or sheet["front"]["segments"].is_empty():
		return
	var f: Dictionary = sheet["front"]
	var t: Dictionary = sheet["top"]
	var l: Dictionary = sheet["left"]
	var fw: float = f["hi"].x - f["lo"].x
	var fh: float = f["hi"].y - f["lo"].y
	var lw: float = l["hi"].x - l["lo"].x
	var th: float = t["hi"].y - t["lo"].y

	# One scale for all three views: the front view top left, the view from the left
	# to its right and the view from above below it -- ISO first angle.
	var gap := 0.18 * maxf(fw, fh)
	var s := minf((w - 200) / (fw + gap + lw), (h - 260) / (fh + gap + th))
	var x0 := 96 + (w - 200 - s * (fw + gap + lw)) / 2
	var y0 := 88.0
	view(f, Vector2(x0, y0), s)
	view(l, Vector2(x0 + (fw + gap) * s, y0), s)
	view(t, Vector2(x0, y0 + (fh + gap) * s), s)

	var metres: Vector3 = sheet["size"]
	dimension(Vector2(x0, y0 - 28), Vector2(x0 + fw * s, y0 - 28), metres.x)          # width
	dimension(Vector2(x0 - 32, y0), Vector2(x0 - 32, y0 + fh * s), metres.y)          # height
	var lx := x0 + (fw + gap) * s
	dimension(Vector2(lx, y0 - 28), Vector2(lx + lw * s, y0 - 28), metres.z)          # depth

	# The title block.
	var font := get_theme_default_font()
	var box := Rect2(w - 24 - 380, h - 24 - 112, 380, 112)
	draw_rect(box, INK, false, 2.0)
	draw_line(box.position + Vector2(0, 38), box.position + Vector2(box.size.x, 38), INK, 2.0)
	draw_line(box.position + Vector2(0, 75), box.position + Vector2(box.size.x, 75), INK, 2.0)
	draw_string(font, box.position + Vector2(12, 27), sheet["name"], HORIZONTAL_ALIGNMENT_LEFT, -1, 16, INK)
	draw_string(font, box.position + Vector2(12, 64), "%.1f x %.1f x %.1f mm" % [metres.x * 1000, metres.y * 1000, metres.z * 1000], HORIZONTAL_ALIGNMENT_LEFT, -1, 16, INK)
	draw_string(font, box.position + Vector2(12, 101), "ISO first angle  ·  cadaclysm + Godot", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, INK)

# One view's edges at `s` pixels per metre, its top left corner at `at`.
func view(d: Dictionary, at: Vector2, s: float) -> void:
	draw_set_transform(at - d["lo"] * s, 0.0, Vector2(s, s))
	draw_multiline(d["segments"], INK, 1.6 / s, true)
	draw_set_transform(Vector2.ZERO)

# A dimension line with end ticks from `a` to `b`, its length in millimetres beside it.
func dimension(a: Vector2, b: Vector2, metres: float) -> void:
	var vertical := a.x == b.x
	var tick := Vector2(6, 0) if vertical else Vector2(0, 6)
	draw_line(a, b, INK, 1.0, true)
	draw_line(a - tick, a + tick, INK, 1.0, true)
	draw_line(b - tick, b + tick, INK, 1.0, true)
	var label := "%.1f" % (metres * 1000)
	var font := get_theme_default_font()
	var width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
	if vertical:
		# Read from the right, as a drawing's vertical dimensions are.
		draw_set_transform(Vector2(a.x - 8, (a.y + b.y + width) / 2), -PI / 2)
		draw_string(font, Vector2.ZERO, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, INK)
		draw_set_transform(Vector2.ZERO)
	else:
		draw_string(font, Vector2((a.x + b.x - width) / 2, a.y - 8), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, INK)
