## A camera that orbits a box: [method frame] fits the box in view, and with
## [member interactive] on, dragging turns it and the wheel zooms. Handy for looking
## at what [method CadaclysmScene.instantiate] builds.
class_name CadaclysmOrbitCamera
extends Camera3D

## Drag with the left or middle button to turn, wheel to zoom.
@export var interactive := true
## Radians per second the view turns by itself; 0 holds still.
@export var turntable_speed := 0.0
## The angle round the vertical, in radians.
@export var yaw := 0.6
## The angle above the horizontal, in radians.
@export var pitch := 0.45

var centre := Vector3.ZERO
var distance := 1.0
var _radius := 1.0

## Look at [param bounds] from just far enough to see all of it -- from every side the
## view turns to, when [member turntable_speed] is not 0.
func frame(bounds: AABB, margin := 1.08) -> void:
	centre = bounds.get_center()
	_radius = maxf(bounds.size.length() * 0.5, 1e-6)
	var aspect := 1.0
	if is_inside_tree():
		var size := get_viewport().get_visible_rect().size
		aspect = size.x / maxf(size.y, 1.0)
	var tan_v := tan(deg_to_rad(fov) * 0.5)
	var tan_h := tan_v * aspect
	if keep_aspect == KEEP_WIDTH:
		tan_h = tan(deg_to_rad(fov) * 0.5)
		tan_v = tan_h / aspect
	# Each corner of the box must fall inside the view: far enough back that its offset
	# across (and up) the picture is within the angle of view at its depth.
	var yaws := [yaw] if turntable_speed == 0.0 else range(16).map(func(i): return TAU * i / 16)
	distance = 0.0
	for y in yaws:
		var back := Vector3(cos(pitch) * sin(y), sin(pitch), cos(pitch) * cos(y))
		var right := Vector3.UP.cross(back).normalized()
		var up := back.cross(right)
		for i in 8:
			var corner := bounds.get_endpoint(i) - centre
			var depth := corner.dot(back)
			distance = maxf(distance, depth + absf(corner.dot(right)) * margin / tan_h)
			distance = maxf(distance, depth + absf(corner.dot(up)) * margin / tan_v)
	distance = maxf(distance, _radius * 0.01)
	_place()

func _process(delta: float) -> void:
	if turntable_speed != 0.0:
		yaw += delta * turntable_speed
		_place()

func _unhandled_input(event: InputEvent) -> void:
	if not interactive:
		return
	if event is InputEventMouseMotion and event.button_mask & (MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_MIDDLE):
		yaw -= event.relative.x * 0.008
		pitch = clampf(pitch + event.relative.y * 0.008, -1.5, 1.5)
		_place()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance *= 0.9
			_place()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance /= 0.9
			_place()

func _place() -> void:
	var direction := Vector3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
	position = centre + direction * distance
	near = maxf(distance - _radius * 2.0, distance * 0.01)
	far = distance + _radius * 4.0
	look_at_from_position(position, centre, Vector3.UP if absf(pitch) < 1.5 else Vector3.FORWARD)
