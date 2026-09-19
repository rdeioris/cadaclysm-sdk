# The assertion kit every `*_test.gd` extends; see run.gd.
extends RefCounted

var label := ""
var failures: Array[String] = []

func _where() -> String:
	# The test file's line that called the assertion.
	for frame in get_stack().slice(2):
		if String(frame["source"]).ends_with("_test.gd"):
			return "line %d" % frame["line"]
	return "?"

func ok(cond: bool, message := "expected true") -> bool:
	if not cond:
		failures.append("%s: %s" % [_where(), message])
	return cond

func eq(actual, expected, message := "") -> bool:
	var same: bool = typeof(actual) == typeof(expected) and actual == expected
	if expected == null or actual == null:
		same = actual == null and expected == null   # a null object is null too
	if not same and (typeof(actual) in [TYPE_INT, TYPE_FLOAT]) and (typeof(expected) in [TYPE_INT, TYPE_FLOAT]):
		same = actual == expected
	if not same:
		failures.append("%s: %s expected %s, got %s" % [_where(), message, var_to_str(expected), var_to_str(actual)])
	return same

func near(actual: float, expected: float, tolerance: float, message := "") -> bool:
	if not (absf(actual - expected) <= tolerance):
		failures.append("%s: %s expected %s +- %s, got %s" % [_where(), message, expected, tolerance, actual])
		return false
	return true

# Call `f`; it must leave a cadaclysm error containing `pattern` in last_error().
func fails(f: Callable, pattern := "") -> String:
	f.call()
	var message := Cadaclysm.last_error()
	if message == "":
		failures.append("%s: expected an error%s" % [_where(), (" containing " + pattern) if pattern else ""])
	elif pattern != "" and not message.contains(pattern):
		failures.append("%s: expected an error containing %s, got %s" % [_where(), pattern, message])
	return message

var _tmp_root := ""

func tmp(name: String) -> String:
	if _tmp_root == "":
		_tmp_root = OS.get_temp_dir().path_join("cadaclysm-godot-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
		DirAccess.make_dir_recursive_absolute(_tmp_root)
	return _tmp_root.path_join(name)

# The repository root: an ancestor of the project holding crates/cadaclysm-capi.
static func root() -> String:
	var dir := ProjectSettings.globalize_path("res://").trim_suffix("/")
	while dir != "" and dir.get_base_dir() != dir:
		if DirAccess.dir_exists_absolute(dir.path_join("crates/cadaclysm-capi")):
			return dir
		dir = dir.get_base_dir()
	return ""

func fixture(rel: String) -> String:
	var r := root()
	if r == "":
		return ""
	var path := r.path_join(rel)
	if not FileAccess.file_exists(path):
		failures.append("%s: fixture missing: %s" % [_where(), path])
		return ""
	return path
