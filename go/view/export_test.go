package view

import "unsafe"

// FindForTest is cvl_find, for view_test.go's refusal test. `find` lives in view.go:
// cgo is not allowed in a _test.go file, so this file has none.
func FindForTest(stem, variable, what string, dirs []string) (string, error) {
	return find(stem, variable, what, dirs)
}

// CheckABIForTest is cvl_check_abi: what Use/UseWgpu/UseTerminal answer a library whose
// cadaclysm_view_abi_version() is `version`.
func CheckABIForTest(version uint32, path string) error { return checkABI(version, path) }

// LodLayoutForTest is CadaclysmViewLod's size and field offsets.
func LodLayoutForTest() (size, minTriangles, motion uintptr) { return lodLayout() }

// SnapLayoutForTest is CadaclysmViewSnap's size and its fields' offsets, in the header's order.
func SnapLayoutForTest() [12]uintptr { return snapLayout() }

// The library's pump answers.
const (
	OpenForTest   = stateOpen
	ClosedForTest = stateClosed
)

// RiggedForTest is a copy of l with the calls named replaced (viewrig's stand-ins).
func RiggedForTest(l *Library, calls map[string]unsafe.Pointer) (*Library, error) {
	return l.rigged(calls)
}

// UseForTest makes l the library in use; the func it returns puts the previous one back.
func UseForTest(l *Library) (restore func()) {
	mu.Lock()
	old := current
	current = l
	mu.Unlock()
	return func() {
		mu.Lock()
		current = old
		mu.Unlock()
	}
}

// ShownForTest is how many of v's items keep something reachable.
func ShownForTest(v *View) int {
	viewsMu.Lock()
	defer viewsMu.Unlock()
	return len(v.owners)
}
