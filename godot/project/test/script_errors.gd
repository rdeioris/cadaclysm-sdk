# Collects GDScript runtime errors while a test runs (Godot 4.5+, which has Logger):
# a script error stops the test function where it happened, and without this the runner
# would count the half-run test as passed. cadaclysm's own errors (push_error) are not
# script errors: tests provoke those on purpose.
extends Logger

var errors: Array[String] = []
var _lock := Mutex.new()

func _log_error(function: String, file: String, line: int, code: String, rationale: String,
		_editor_notify: bool, error_type: int, _script_backtraces: Array) -> void:
	if error_type != ERROR_TYPE_SCRIPT:
		return
	_lock.lock()
	errors.append("%s:%d in %s: %s" % [file, line, function, rationale if rationale else code])
	_lock.unlock()

func take() -> Array[String]:
	_lock.lock()
	var out := errors.duplicate()
	errors.clear()
	_lock.unlock()
	return out
