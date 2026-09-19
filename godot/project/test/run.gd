# The Godot extension's tests: every `*_test.gd` beside this file, headless.
#
#     godot --headless --path <project> --script res://test/run.gd [-- FILTER]
#
# FILTER keeps only the tests whose `file: name` contains it; none left is a failure.
# Exits 1 if any test failed, or stopped on a script error (Godot 4.5+). The libraries are found as the extension documents
# (beside it in addons/cadaclysm/bin, then CADACLYSM_LIBRARY and
# CADACLYSM_BLACKSMITH_LIBRARY).
#
# A test file extends `res://test/suite.gd` and declares `func test_*()` methods.
# Inside one: `ok(cond, message)`, `eq(actual, expected, message)`,
# `near(actual, expected, tolerance, message)`, `fails(callable, pattern)` (calls it,
# expects a cadaclysm error matching `pattern`, returns the message), `tmp(name)` (a
# fresh path under a temp directory) and `fixture(rel)` (a path under the repository
# root, or "" in an SDK checkout -- the test then returns early).
extends SceneTree

func _initialize() -> void:
	var filter := ""
	for a in OS.get_cmdline_user_args():
		filter = a
	var failed := 0
	var passed := 0
	# A script error ends a test function early; on Godot 4.5+ a Logger sees it and the
	# test fails. (Before 4.5 there is no hook, and such a test can pass half-run.)
	var script_errors = null
	if ClassDB.class_exists("Logger"):
		script_errors = load("res://test/script_errors.gd").new()
		OS.call("add_logger", script_errors)
	var files := []
	for f in DirAccess.get_files_at("res://test"):
		if f.ends_with("_test.gd"):
			files.append(f)
	files.sort()
	for f in files:
		var script: GDScript = load("res://test/" + f)
		for m in script.get_script_method_list():
			var name: String = m["name"]
			if not name.begins_with("test_"):
				continue
			var label := "%s: %s" % [f.trim_suffix(".gd"), name.trim_prefix("test_")]
			if filter != "" and not label.contains(filter):
				continue
			var suite = script.new()
			suite.label = label
			suite.call(name)
			if script_errors:
				for e in script_errors.take():
					suite.failures.append("script error, the test stopped here: " + e)
			if suite.failures.is_empty():
				passed += 1
				print("ok    ", label)
			else:
				failed += 1
				print("FAIL  ", label)
				for line in suite.failures:
					print("      ", line)
			if suite is Object and not (suite is RefCounted):
				suite.free()
	print("%d passed, %d failed" % [passed, failed])
	if passed + failed == 0:
		print("no test matched ", filter)
		failed = 1
	quit(1 if failed > 0 else 0)
